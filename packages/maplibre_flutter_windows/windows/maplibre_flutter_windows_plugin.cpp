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

namespace {

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
//
// `buffer` is the LAST-GOOD frame (what `pb` points at); a fresh frame is copied
// into `scratch` first and only swapped into `buffer` on success, so a failed copy
// (no frame yet, or the frame grew between the size query and the copy) never
// corrupts the retained good frame. On a miss the callback re-presents `buffer`
// instead of returning nullptr — a brief stale frame instead of a white flash on
// resize (the macOS/iOS fallbackBuffer() behaviour from commit 9655316, which was
// never ported to this CPU PixelBufferTexture path).
struct MapTexture {
  void* map_handle = nullptr;
  MblCopyFrameFn copy_frame = nullptr;
  MblSetFrameCallbackFn set_frame_callback = nullptr;
  flutter::TextureRegistrar* registrar = nullptr;  // borrowed (engine-lifetime)
  int64_t texture_id = -1;
  std::mutex mutex;
  std::vector<uint8_t> buffer;   // last-good RGBA frame (pb points here)
  std::vector<uint8_t> scratch;  // in-progress copy target; swapped in on success
  bool has_frame = false;        // false until the first successful copy
  uint32_t last_w = 0;
  uint32_t last_h = 0;
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
                // Try to pull a fresh frame into the scratch buffer: query the
                // current frame size first (null dst) so we follow core resizes,
                // then copy the RGBA pixels. On ANY failure — no frame yet, or the
                // frame grew between the query and the copy so the capacity check
                // rejects it (the resize torn-size window) — we leave the retained
                // last-good `buffer` untouched and fall through to re-present it.
                if (tp->copy_frame(tp->map_handle, nullptr, 0, &w, &h, &stride) !=
                        0 &&
                    w != 0 && h != 0) {
                  const size_t need = static_cast<size_t>(w) * h * 4;
                  if (tp->scratch.size() < need) {
                    tp->scratch.resize(need);
                  }
                  if (tp->copy_frame(tp->map_handle, tp->scratch.data(),
                                     tp->scratch.size(), &w, &h, &stride) != 0) {
                    // Success: promote scratch to last-good (O(1) vector swap).
                    std::swap(tp->buffer, tp->scratch);
                    tp->last_w = w;
                    tp->last_h = h;
                    tp->has_frame = true;
                  }
                }
                // Present the last-good frame. Returning nullptr flashes the window
                // background, so only do it before the very first frame exists (the
                // one unavoidable case); during the resize gap re-present the last
                // good frame instead — a brief stale frame, not a white blink.
                if (!tp->has_frame) {
                  return nullptr;
                }
                tp->pb.buffer = tp->buffer.data();  // RGBA, packed (stride==w*4)
                tp->pb.width = tp->last_w;
                tp->pb.height = tp->last_h;
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
