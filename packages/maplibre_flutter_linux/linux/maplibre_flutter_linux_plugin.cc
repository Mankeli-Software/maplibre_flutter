// Native (GTK) half of the Linux maplibre_flutter plugin. Owns the Flutter
// texture registrar and presents mbgl-core frames — rendered off-screen by
// maplibre_flutter_core's OpenGL/EGL arm and read over FFI — through an
// FlPixelBufferTexture. Mirrors the macOS plugin (MaplibreFlutterMacosPlugin)
// minus the Metal/IOSurface zero-copy path; this is the CPU pixel-buffer present.
//
// The shim's C functions are resolved by Dart (which already loads them for FFI)
// and handed here as integer addresses over the bootstrap method channel; we cast
// them to typed C function pointers — no dlopen/dlsym, so the core's packaging
// layout doesn't matter (same rationale as the macOS Swift side).
//
// NOTE: not yet built/run on real Linux hardware (developed on macOS) — CLAUDE.md §8.
#include "include/maplibre_flutter_linux/maplibre_flutter_linux_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstdint>
#include <cstring>
#include <map>
#include <vector>

// C ABI of the maplibre_flutter_core shim functions we call by address.
typedef int (*MblCopyFrameFn)(void* map, uint8_t* dst, size_t cap, uint32_t* w,
                              uint32_t* h, uint32_t* stride);
typedef void (*MblFrameCallback)(void* user);
typedef void (*MblSetFrameCallbackFn)(void* map, MblFrameCallback cb,
                                      void* user);

// ===== FlPixelBufferTexture subclass: reads the latest RGBA frame =====
G_DECLARE_FINAL_TYPE(MaplibreFlutterLinuxTexture,
                     maplibre_flutter_linux_texture, MAPLIBRE_FLUTTER_LINUX,
                     TEXTURE, FlPixelBufferTexture)

struct _MaplibreFlutterLinuxTexture {
  FlPixelBufferTexture parent_instance;
  void* map_handle;
  MblCopyFrameFn copy_frame;
  MblSetFrameCallbackFn set_frame_callback;
  FlTextureRegistrar* registrar;  // borrowed
  std::vector<uint8_t>* buffer;   // backing store kept alive across frames
};

G_DEFINE_TYPE(MaplibreFlutterLinuxTexture, maplibre_flutter_linux_texture,
              fl_pixel_buffer_texture_get_type())

static gboolean maplibre_flutter_linux_texture_copy_pixels(
    FlPixelBufferTexture* texture, const uint8_t** out_buffer, uint32_t* width,
    uint32_t* height, GError** error) {
  MaplibreFlutterLinuxTexture* self = MAPLIBRE_FLUTTER_LINUX_TEXTURE(texture);
  uint32_t w = 0, h = 0, stride = 0;
  // Query the current frame size first (null dst) so we follow core resizes.
  if (self->copy_frame(self->map_handle, nullptr, 0, &w, &h, &stride) == 0 ||
      w == 0 || h == 0) {
    g_set_error(error, g_quark_from_static_string("maplibre_flutter_linux"), 0,
                "no frame available yet");
    return FALSE;
  }
  const size_t needed = static_cast<size_t>(w) * h * 4;
  if (self->buffer->size() < needed) {
    self->buffer->resize(needed);
  }
  if (self->copy_frame(self->map_handle, self->buffer->data(),
                       self->buffer->size(), &w, &h, &stride) == 0) {
    g_set_error(error, g_quark_from_static_string("maplibre_flutter_linux"), 0,
                "copy_frame failed");
    return FALSE;
  }
  *out_buffer = self->buffer->data();  // RGBA; lives until the next copy
  *width = w;
  *height = h;
  return TRUE;
}

static void maplibre_flutter_linux_texture_dispose(GObject* object) {
  MaplibreFlutterLinuxTexture* self = MAPLIBRE_FLUTTER_LINUX_TEXTURE(object);
  if (self->set_frame_callback != nullptr && self->map_handle != nullptr) {
    self->set_frame_callback(self->map_handle, nullptr, nullptr);
    self->set_frame_callback = nullptr;
  }
  delete self->buffer;
  self->buffer = nullptr;
  G_OBJECT_CLASS(maplibre_flutter_linux_texture_parent_class)->dispose(object);
}

static void maplibre_flutter_linux_texture_class_init(
    MaplibreFlutterLinuxTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      maplibre_flutter_linux_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->dispose = maplibre_flutter_linux_texture_dispose;
}

static void maplibre_flutter_linux_texture_init(
    MaplibreFlutterLinuxTexture* self) {
  self->buffer = new std::vector<uint8_t>();
}

// Runs on the GTK main thread (marshaled from the render thread): tell the engine
// a new frame is ready, which pulls copy_pixels.
static gboolean mark_frame_available(gpointer user_data) {
  MaplibreFlutterLinuxTexture* self = MAPLIBRE_FLUTTER_LINUX_TEXTURE(user_data);
  if (self->registrar != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(self->registrar,
                                                      FL_TEXTURE(self));
  }
  g_object_unref(self);  // balance the ref taken in on_frame_ready
  return G_SOURCE_REMOVE;
}

// Called on the core's render thread (the registrar isn't thread-safe, so hop to
// the main loop). Holds a ref across the hop so the texture can't be freed first.
static void on_frame_ready(void* user) {
  auto* self = MAPLIBRE_FLUTTER_LINUX_TEXTURE(user);
  g_idle_add(mark_frame_available, g_object_ref(self));
}

// ===== The plugin =====
G_DECLARE_FINAL_TYPE(MaplibreFlutterLinuxPlugin, maplibre_flutter_linux_plugin,
                     MAPLIBRE_FLUTTER_LINUX, PLUGIN, GObject)

struct _MaplibreFlutterLinuxPlugin {
  GObject parent_instance;
  FlTextureRegistrar* registrar;  // borrowed (engine-lifetime)
  std::map<int64_t, MaplibreFlutterLinuxTexture*>* textures;
};

G_DEFINE_TYPE(MaplibreFlutterLinuxPlugin, maplibre_flutter_linux_plugin,
              G_TYPE_OBJECT)

static int64_t arg_int(FlValue* args, const char* key) {
  FlValue* v = fl_value_lookup_string(args, key);
  return (v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_INT)
             ? fl_value_get_int(v)
             : 0;
}

static void handle_method_call(MaplibreFlutterLinuxPlugin* self,
                               FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "registerTexture") == 0) {
    const int64_t map_handle = arg_int(args, "mapHandle");
    const int64_t copy_fn = arg_int(args, "copyFrameFn");
    const int64_t set_cb_fn = arg_int(args, "setFrameCallbackFn");
    if (map_handle == 0 || copy_fn == 0 || set_cb_fn == 0) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad_args", "registerTexture requires mapHandle + function addresses",
          nullptr));
    } else {
      auto* texture = MAPLIBRE_FLUTTER_LINUX_TEXTURE(g_object_new(
          maplibre_flutter_linux_texture_get_type(), nullptr));
      texture->map_handle = reinterpret_cast<void*>(map_handle);
      texture->copy_frame = reinterpret_cast<MblCopyFrameFn>(copy_fn);
      texture->set_frame_callback =
          reinterpret_cast<MblSetFrameCallbackFn>(set_cb_fn);
      texture->registrar = self->registrar;
      fl_texture_registrar_register_texture(self->registrar,
                                            FL_TEXTURE(texture));
      const int64_t id = fl_texture_get_id(FL_TEXTURE(texture));
      (*self->textures)[id] = texture;  // our owning ref
      texture->set_frame_callback(texture->map_handle, on_frame_ready, texture);
      g_autoptr(FlValue) result = fl_value_new_int(id);
      response =
          FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else if (strcmp(method, "unregisterTexture") == 0) {
    const int64_t id = (args != nullptr &&
                        fl_value_get_type(args) == FL_VALUE_TYPE_INT)
                           ? fl_value_get_int(args)
                           : 0;
    auto it = self->textures->find(id);
    if (it != self->textures->end()) {
      fl_texture_registrar_unregister_texture(self->registrar,
                                              FL_TEXTURE(it->second));
      g_object_unref(it->second);  // drop our ref → dispose clears the callback
      self->textures->erase(it);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  handle_method_call(MAPLIBRE_FLUTTER_LINUX_PLUGIN(user_data), method_call);
}

static void maplibre_flutter_linux_plugin_dispose(GObject* object) {
  MaplibreFlutterLinuxPlugin* self = MAPLIBRE_FLUTTER_LINUX_PLUGIN(object);
  delete self->textures;
  self->textures = nullptr;
  G_OBJECT_CLASS(maplibre_flutter_linux_plugin_parent_class)->dispose(object);
}

static void maplibre_flutter_linux_plugin_class_init(
    MaplibreFlutterLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = maplibre_flutter_linux_plugin_dispose;
}

static void maplibre_flutter_linux_plugin_init(
    MaplibreFlutterLinuxPlugin* self) {
  self->textures = new std::map<int64_t, MaplibreFlutterLinuxTexture*>();
}

void maplibre_flutter_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  auto* plugin = MAPLIBRE_FLUTTER_LINUX_PLUGIN(
      g_object_new(maplibre_flutter_linux_plugin_get_type(), nullptr));
  plugin->registrar = fl_plugin_registrar_get_texture_registrar(registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "maplibre_flutter/linux/registrar", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
