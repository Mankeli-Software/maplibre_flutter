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
