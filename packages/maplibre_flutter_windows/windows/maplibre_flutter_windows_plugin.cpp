// Native (Win32) half of the Windows maplibre_flutter plugin. Owns the Flutter
// texture registrar and presents mbgl-core frames — rendered off-screen by
// maplibre_flutter_core's ANGLE/OpenGL-ES + EGL arm and read over FFI — through a
// flutter::PixelBufferTexture. The CPU pixel-buffer analog of the macOS IOSurface
// / Linux dmabuf zero-copy paths (D3D-shared-texture zero-copy is a later step).
//
// The shim's C functions are resolved by Dart (which already loads them for FFI)
// and handed here as integer addresses over the bootstrap method channel; we cast
// them to typed C function pointers — no LoadLibrary/GetProcAddress, so the core's
// packaging layout doesn't matter (same rationale as the macOS/Linux sides).
//
// NOTE: not yet built/run on real Windows hardware (written on Linux) — CLAUDE.md §8.
#include "include/maplibre_flutter_windows/maplibre_flutter_windows_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <vector>

// DIAG (temporary): crash-stack dumper for the fly-to/fast-pan access violation.
#include <windows.h>
#include <dbghelp.h>
#include <cstdio>
#include <cstring>

namespace {

// DIAG: walk + print the faulting thread's stack on an unhandled exception (the
// 0xC0000005 under heavy movement). Uses dbghelp + the x64 .pdata unwind info, so
// it works on optimized builds; mbgl frames show as maplibre_flutter_core.dll+RVA
// (resolve via the linker .map), our plugin/runner frames resolve to names.
LONG WINAPI MblCrashFilter(EXCEPTION_POINTERS* ep) {
  HANDLE proc = GetCurrentProcess();
  SymSetOptions(SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES | SYMOPT_UNDNAME);
  SymInitialize(proc, nullptr, TRUE);
  fprintf(stderr, "[mbl-crash] code=0x%08lx addr=%p\n",
          ep->ExceptionRecord->ExceptionCode,
          ep->ExceptionRecord->ExceptionAddress);
  fflush(stderr);
  CONTEXT ctx = *ep->ContextRecord;
  char symBuf[sizeof(SYMBOL_INFO) + 512] = {};
  auto* sym = reinterpret_cast<SYMBOL_INFO*>(symBuf);
  sym->SizeOfStruct = sizeof(SYMBOL_INFO);
  sym->MaxNameLen = 511;
  for (int i = 0; i < 48 && ctx.Rip != 0; i++) {
    const DWORD64 pc = ctx.Rip;
    HMODULE hmod = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(pc), &hmod);
    char modPath[MAX_PATH] = "?";
    if (hmod) GetModuleFileNameA(hmod, modPath, MAX_PATH);
    const char* mod = strrchr(modPath, '\\');
    mod = mod ? mod + 1 : modPath;
    const DWORD64 rva = hmod ? (pc - reinterpret_cast<DWORD64>(hmod)) : 0;
    DWORD64 disp = 0;
    if (SymFromAddr(proc, pc, &disp, sym)) {
      fprintf(stderr, "[mbl-crash] #%02d %s!%s+0x%llx (rva 0x%llx)\n", i, mod,
              sym->Name, disp, rva);
    } else {
      fprintf(stderr, "[mbl-crash] #%02d %s+0x%llx\n", i, mod, rva);
    }
    fflush(stderr);
    // Manual x64 unwind via in-memory .pdata (no PDB needed; reliable on /O2).
    DWORD64 imageBase = 0;
    PRUNTIME_FUNCTION rf = RtlLookupFunctionEntry(pc, &imageBase, nullptr);
    if (rf == nullptr) {
      if (ctx.Rsp == 0) break; // leaf: return addr at [Rsp]
      ctx.Rip = *reinterpret_cast<DWORD64*>(ctx.Rsp);
      ctx.Rsp += 8;
    } else {
      void* handlerData = nullptr;
      DWORD64 establisher = 0;
      RtlVirtualUnwind(UNW_FLAG_NHANDLER, imageBase, pc, rf, &ctx, &handlerData,
                       &establisher, nullptr);
    }
  }
  return EXCEPTION_EXECUTE_HANDLER;
}

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResult;

// C ABI of the maplibre_flutter_core shim functions we call by address (identical
// to the Linux/macOS plugins' typedefs).
typedef int (*MblCopyFrameFn)(void* map, uint8_t* dst, size_t cap, uint32_t* w,
                              uint32_t* h, uint32_t* stride);
typedef void (*MblFrameCallback)(void* user);
typedef void (*MblSetFrameCallbackFn)(void* map, MblFrameCallback cb,
                                      void* user);
// Zero-copy: returns the latest frame's DXGI shared handle + size
// (mbl_map_current_d3d_handle). Returns 0 if no zero-copy frame is available.
typedef int (*MblCurrentD3dHandleFn)(void* map, void** out_handle, uint32_t* w,
                                     uint32_t* h);

int64_t ArgInt(const EncodableMap& m, const char* key) {
  auto it = m.find(EncodableValue(std::string(key)));
  if (it == m.end()) return 0;
  if (auto p = std::get_if<int64_t>(&it->second)) return *p;
  if (auto p = std::get_if<int32_t>(&it->second)) return *p;
  return 0;
}

// One registered texture bound to a core map. `buffer`/`pb` are read on the raster
// thread by the PixelBufferTexture copy callback and written there too; the core
// frame callback only marks a frame available (it doesn't touch the buffer). The
// mutex guards the whole query+copy so the engine never reads a half-written
// buffer, and `buffer`/`pb` outlive the returned pointer (kept until the next copy
// and until UnregisterTexture's completion).
struct MapTexture {
  void* map_handle = nullptr;
  MblCopyFrameFn copy_frame = nullptr;
  MblSetFrameCallbackFn set_frame_callback = nullptr;
  flutter::TextureRegistrar* registrar = nullptr;  // borrowed (engine-lifetime)
  int64_t texture_id = -1;
  std::mutex mutex;
  std::vector<uint8_t> buffer;  // RGBA; lives until the next copy
  FlutterDesktopPixelBuffer pb{};
  // Zero-copy (GpuSurfaceTexture) path: the D3D handle getter + the descriptor we
  // hand back. A map uses either the pixel-buffer or the GPU-surface path, not both.
  MblCurrentD3dHandleFn current_d3d = nullptr;
  FlutterDesktopGpuSurfaceDescriptor gpu_desc{};
  std::unique_ptr<flutter::TextureVariant> variant;
};

// Called on the core's render thread when a new frame is published. Windows'
// TextureRegistrar::MarkTextureFrameAvailable is thread-safe, so — unlike the GTK
// side's g_idle_add hop — we call it directly.
void OnFrameReady(void* user) {
  auto* t = static_cast<MapTexture*>(user);
  if (t->registrar != nullptr) {
    t->registrar->MarkTextureFrameAvailable(t->texture_id);
  }
}

class MaplibreFlutterWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar) {
    static bool s_crashFilterInstalled = false;
    if (!s_crashFilterInstalled) {
      s_crashFilterInstalled = true;
      SetUnhandledExceptionFilter(MblCrashFilter);  // DIAG: dump crash stack
    }
    auto plugin = std::make_unique<MaplibreFlutterWindowsPlugin>(registrar);
    auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "maplibre_flutter/windows/registrar",
        &flutter::StandardMethodCodec::GetInstance());
    auto* raw = plugin.get();
    channel->SetMethodCallHandler(
        [raw](const MethodCall<EncodableValue>& call,
              std::unique_ptr<MethodResult<EncodableValue>> result) {
          raw->HandleMethodCall(call, std::move(result));
        });
    raw->channel_ = std::move(channel);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit MaplibreFlutterWindowsPlugin(flutter::PluginRegistrarWindows* r)
      : textures_(r->texture_registrar()) {}
  ~MaplibreFlutterWindowsPlugin() override = default;

 private:
  void HandleMethodCall(const MethodCall<EncodableValue>& call,
                        std::unique_ptr<MethodResult<EncodableValue>> result) {
    const std::string& method = call.method_name();

    if (method == "registerTexture") {
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      if (args == nullptr) {
        result->Error("bad_args", "registerTexture requires a map");
        return;
      }
      const int64_t map_handle = ArgInt(*args, "mapHandle");
      const int64_t copy_fn = ArgInt(*args, "copyFrameFn");
      const int64_t set_cb_fn = ArgInt(*args, "setFrameCallbackFn");
      if (map_handle == 0 || copy_fn == 0 || set_cb_fn == 0) {
        result->Error("bad_args",
                      "registerTexture requires mapHandle + function addresses");
        return;
      }

      auto t = std::make_unique<MapTexture>();
      t->map_handle = reinterpret_cast<void*>(map_handle);
      t->copy_frame = reinterpret_cast<MblCopyFrameFn>(copy_fn);
      t->set_frame_callback = reinterpret_cast<MblSetFrameCallbackFn>(set_cb_fn);
      t->registrar = textures_;
      MapTexture* tp = t.get();

      t->variant = std::make_unique<flutter::TextureVariant>(
          flutter::PixelBufferTexture(
              // Runs on the raster thread when the engine pulls a frame.
              [tp](size_t /*width*/,
                   size_t /*height*/) -> const FlutterDesktopPixelBuffer* {
                std::lock_guard<std::mutex> lock(tp->mutex);
                uint32_t w = 0, h = 0, stride = 0;
                // Query the current frame size first (null dst) so we follow core
                // resizes, then copy the RGBA pixels.
                if (tp->copy_frame(tp->map_handle, nullptr, 0, &w, &h, &stride) ==
                        0 ||
                    w == 0 || h == 0) {
                  return nullptr;
                }
                const size_t need = static_cast<size_t>(w) * h * 4;
                if (tp->buffer.size() < need) {
                  tp->buffer.resize(need);
                }
                if (tp->copy_frame(tp->map_handle, tp->buffer.data(),
                                   tp->buffer.size(), &w, &h, &stride) == 0) {
                  return nullptr;
                }
                tp->pb.buffer = tp->buffer.data();  // RGBA, packed (stride==w*4)
                tp->pb.width = w;
                tp->pb.height = h;
                tp->pb.release_callback = nullptr;
                tp->pb.release_context = nullptr;
                return &tp->pb;
              }));

      const int64_t id = textures_->RegisterTexture(t->variant.get());
      t->texture_id = id;  // set before wiring the callback so the first frame
                           // marks a valid id
      tp->set_frame_callback(tp->map_handle, OnFrameReady, tp);
      registered_[id] = std::move(t);
      result->Success(EncodableValue(id));
    } else if (method == "registerTextureGpu") {
      // Zero-copy: present mbgl's frame as a Flutter GpuSurfaceTexture backed by a
      // DXGI shared handle (the core blits into a shared D3D11 texture ring). The
      // descriptor callback runs on the raster thread; it reads the current handle
      // from the core (mbl_map_current_d3d_handle, by address) — no D3D/GL calls.
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      if (args == nullptr) {
        result->Error("bad_args", "registerTextureGpu requires a map");
        return;
      }
      const int64_t map_handle = ArgInt(*args, "mapHandle");
      const int64_t cur_fn = ArgInt(*args, "currentD3dHandleFn");
      const int64_t set_cb_fn = ArgInt(*args, "setFrameCallbackFn");
      if (map_handle == 0 || cur_fn == 0 || set_cb_fn == 0) {
        result->Error("bad_args",
                      "registerTextureGpu requires mapHandle + function addresses");
        return;
      }

      auto t = std::make_unique<MapTexture>();
      t->map_handle = reinterpret_cast<void*>(map_handle);
      t->current_d3d = reinterpret_cast<MblCurrentD3dHandleFn>(cur_fn);
      t->set_frame_callback = reinterpret_cast<MblSetFrameCallbackFn>(set_cb_fn);
      t->registrar = textures_;
      MapTexture* tp = t.get();

      t->variant = std::make_unique<flutter::TextureVariant>(
          flutter::GpuSurfaceTexture(
              kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
              // Runs on the raster thread when the engine pulls a frame.
              [tp](size_t /*width*/, size_t /*height*/)
                  -> const FlutterDesktopGpuSurfaceDescriptor* {
                void* handle = nullptr;
                uint32_t w = 0, h = 0;
                if (tp->current_d3d(tp->map_handle, &handle, &w, &h) == 0 ||
                    handle == nullptr) {
                  return nullptr;
                }
                tp->gpu_desc.struct_size =
                    sizeof(FlutterDesktopGpuSurfaceDescriptor);
                tp->gpu_desc.handle = handle;  // owned by the core's texture ring
                tp->gpu_desc.width = w;
                tp->gpu_desc.height = h;
                tp->gpu_desc.visible_width = w;
                tp->gpu_desc.visible_height = h;
                tp->gpu_desc.format = kFlutterDesktopPixelFormatRGBA8888;
                tp->gpu_desc.release_callback = nullptr;
                tp->gpu_desc.release_context = nullptr;
                return &tp->gpu_desc;
              }));

      const int64_t id = textures_->RegisterTexture(t->variant.get());
      t->texture_id = id;
      tp->set_frame_callback(tp->map_handle, OnFrameReady, tp);
      registered_[id] = std::move(t);
      result->Success(EncodableValue(id));
    } else if (method == "unregisterTexture") {
      const auto* id_v = std::get_if<int64_t>(call.arguments());
      if (id_v != nullptr) {
        auto it = registered_.find(*id_v);
        if (it != registered_.end()) {
          // Stop the core firing frames first, then unregister (async); drop our
          // owning entry only once the engine confirms it's done reading.
          it->second->set_frame_callback(it->second->map_handle, nullptr,
                                         nullptr);
          const int64_t id = *id_v;
          textures_->UnregisterTexture(id,
                                       [this, id]() { registered_.erase(id); });
        }
      }
      result->Success();
    } else {
      result->NotImplemented();
    }
  }

  flutter::TextureRegistrar* textures_;  // borrowed
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::map<int64_t, std::unique_ptr<MapTexture>> registered_;  // owning
};

}  // namespace

void MaplibreFlutterWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  MaplibreFlutterWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
