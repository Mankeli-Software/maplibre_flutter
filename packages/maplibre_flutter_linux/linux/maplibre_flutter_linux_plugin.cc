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

// For the zero-copy GL present path: import the core's EGLImage frame into a
// Flutter-context texture (GLES3 core first, then the extension header).
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <vector>

// Set MAPLIBRE_GL_DEBUG=1 to trace the zero-copy FlTextureGL present path.
static bool mfl_gl_debug() {
  static int v = -1;
  if (v < 0) v = (getenv("MAPLIBRE_GL_DEBUG") != nullptr) ? 1 : 0;
  return v != 0;
}

// C ABI of the maplibre_flutter_core shim functions we call by address.
typedef int (*MblCopyFrameFn)(void* map, uint8_t* dst, size_t cap, uint32_t* w,
                              uint32_t* h, uint32_t* stride);
typedef void (*MblFrameCallback)(void* user);
typedef void (*MblSetFrameCallbackFn)(void* map, MblFrameCallback cb,
                                      void* user);
// Zero-copy GL present: the latest frame as a Linux dmabuf descriptor (shareable
// across mbgl's and Flutter's distinct EGLDisplays). Layout MUST match
// MblGlDmabufFrame in maplibre_flutter_core.h.
struct MblGlDmabufFrame {
  int32_t fd;
  uint32_t fourcc;
  uint32_t stride;
  uint32_t offset;
  uint64_t modifier;
  uint64_t generation;
  uint32_t ring_index;
  uint32_t width;
  uint32_t height;
};
typedef int (*MblCurrentGlImageFn)(void* map, MblGlDmabufFrame* out);

#ifndef DRM_FORMAT_MOD_INVALID
#define DRM_FORMAT_MOD_INVALID 0x00ffffffffffffffULL
#endif

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

// ===== FlTextureGL subclass: zero-copy present of the core's dmabuf frame =====
// The core (maplibre_flutter_core's GL arm) blits each frame into a ring of textures
// and exports each as a dmabuf fd. Here we import that dmabuf into Flutter's raster
// GL context via EGL_LINUX_DMA_BUF_EXT (no CPU readback). A dmabuf is a kernel buffer
// fd, so it crosses the distinct EGLDisplays mbgl and Flutter use (an EGLImage handle
// could not). populate() runs on the raster thread with Flutter's GL context current.
// We cache one imported EGLImage + texture per ring slot, re-importing only when a
// slot's generation changes (a resize gives new dmabufs).
G_DECLARE_FINAL_TYPE(MaplibreFlutterLinuxGlTexture,
                     maplibre_flutter_linux_gl_texture, MAPLIBRE_FLUTTER_LINUX,
                     GL_TEXTURE, FlTextureGL)

#define MFL_GL_RING 3

struct _MaplibreFlutterLinuxGlTexture {
  FlTextureGL parent_instance;
  void* map_handle;
  MblCurrentGlImageFn current_gl_image;
  MblSetFrameCallbackFn set_frame_callback;
  FlTextureRegistrar* registrar;  // borrowed
  // EGL entry points + dmabuf-import support, resolved lazily on the first
  // populate() (the raster thread, where Flutter's EGL context IS current — the
  // platform thread that runs registerTextureGl has no current context).
  bool egl_ready;
  bool egl_ok;
  PFNEGLCREATEIMAGEKHRPROC create_image;
  PFNEGLDESTROYIMAGEKHRPROC destroy_image;
  PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target_texture;
  GLuint tex[MFL_GL_RING];
  EGLImageKHR image[MFL_GL_RING];
  guint64 generation[MFL_GL_RING];
};

G_DEFINE_TYPE(MaplibreFlutterLinuxGlTexture, maplibre_flutter_linux_gl_texture,
              fl_texture_gl_get_type())

static gboolean maplibre_flutter_linux_gl_texture_populate(
    FlTextureGL* texture, uint32_t* target, uint32_t* name, uint32_t* width,
    uint32_t* height, GError** error) {
  MaplibreFlutterLinuxGlTexture* self =
      MAPLIBRE_FLUTTER_LINUX_GL_TEXTURE(texture);

  // Resolve EGL/GLES dmabuf-import entry points + support on the FIRST call —
  // here Flutter's EGL context is current (it is NOT on the platform thread that
  // ran registerTextureGl, so this can't be done at registration).
  if (!self->egl_ready) {
    self->egl_ready = true;
    EGLDisplay dpy = eglGetCurrentDisplay();
    const char* exts =
        dpy != EGL_NO_DISPLAY ? eglQueryString(dpy, EGL_EXTENSIONS) : nullptr;
    self->create_image = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
        eglGetProcAddress("eglCreateImageKHR"));
    self->destroy_image = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
        eglGetProcAddress("eglDestroyImageKHR"));
    self->image_target_texture =
        reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
            eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    self->egl_ok = dpy != EGL_NO_DISPLAY && exts != nullptr &&
                   strstr(exts, "EGL_EXT_image_dma_buf_import") != nullptr &&
                   self->create_image != nullptr &&
                   self->destroy_image != nullptr &&
                   self->image_target_texture != nullptr;
    if (mfl_gl_debug()) {
      fprintf(stderr,
              "[mfl-gl] egl setup: ok=%d dpy=%p dmabuf_import=%d create=%p "
              "target=%p\n",
              self->egl_ok, (void*)dpy,
              exts && strstr(exts, "EGL_EXT_image_dma_buf_import") ? 1 : 0,
              (void*)self->create_image, (void*)self->image_target_texture);
    }
  }
  if (!self->egl_ok) {
    g_set_error(error, g_quark_from_static_string("maplibre_flutter_linux"), 0,
                "EGL dmabuf import unavailable in the raster context");
    return FALSE;
  }

  MblGlDmabufFrame f;
  if (self->current_gl_image(self->map_handle, &f) == 0 || f.fd < 0 ||
      f.ring_index >= MFL_GL_RING) {
    static int nf = 0;
    if (mfl_gl_debug() && nf < 16) {
      fprintf(stderr, "[mfl-gl] populate: NO FRAME (#%d)\n", ++nf);
    }
    g_set_error(error, g_quark_from_static_string("maplibre_flutter_linux"), 0,
                "no zero-copy GL frame available");
    return FALSE;
  }
  const uint32_t ring = f.ring_index;
  EGLDisplay dpy = eglGetCurrentDisplay();  // Flutter's raster display
  static int dbgCalls = 0;
  const bool dbg = mfl_gl_debug() && dbgCalls < 16;
  if (dbg) {
    fprintf(stderr,
            "[mfl-gl] populate #%d ring=%u fd=%d gen=%llu %ux%u fourcc=0x%08x "
            "mod=0x%llx dpy=%p\n",
            ++dbgCalls, ring, f.fd, (unsigned long long)f.generation, f.width,
            f.height, f.fourcc, (unsigned long long)f.modifier, (void*)dpy);
  }

  if (self->tex[ring] == 0) {
    glGenTextures(1, &self->tex[ring]);
  }
  glBindTexture(GL_TEXTURE_2D, self->tex[ring]);

  // (Re)import the dmabuf into an EGLImage on Flutter's display when this slot's
  // generation changes (a resize swaps the dmabuf fds); steady-state frames reuse
  // the cached image since the producer re-blits the same buffer in place.
  if (self->image[ring] == EGL_NO_IMAGE_KHR ||
      self->generation[ring] != f.generation) {
    if (self->image[ring] != EGL_NO_IMAGE_KHR) {
      self->destroy_image(dpy, self->image[ring]);
      self->image[ring] = EGL_NO_IMAGE_KHR;
    }
    EGLint attrs[32];
    int n = 0;
    attrs[n++] = EGL_WIDTH;                     attrs[n++] = (EGLint)f.width;
    attrs[n++] = EGL_HEIGHT;                    attrs[n++] = (EGLint)f.height;
    attrs[n++] = EGL_LINUX_DRM_FOURCC_EXT;      attrs[n++] = (EGLint)f.fourcc;
    attrs[n++] = EGL_DMA_BUF_PLANE0_FD_EXT;     attrs[n++] = f.fd;
    attrs[n++] = EGL_DMA_BUF_PLANE0_OFFSET_EXT; attrs[n++] = (EGLint)f.offset;
    attrs[n++] = EGL_DMA_BUF_PLANE0_PITCH_EXT;  attrs[n++] = (EGLint)f.stride;
    if (f.modifier != DRM_FORMAT_MOD_INVALID) {
      attrs[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT;
      attrs[n++] = (EGLint)(f.modifier & 0xFFFFFFFF);
      attrs[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT;
      attrs[n++] = (EGLint)(f.modifier >> 32);
    }
    attrs[n++] = EGL_NONE;
    self->image[ring] = self->create_image(dpy, EGL_NO_CONTEXT,
                                           EGL_LINUX_DMA_BUF_EXT, nullptr, attrs);
    if (self->image[ring] == EGL_NO_IMAGE_KHR) {
      g_set_error(error, g_quark_from_static_string("maplibre_flutter_linux"), 0,
                  "failed to import dmabuf as EGLImage (0x%x)", eglGetError());
      return FALSE;
    }
    self->image_target_texture(GL_TEXTURE_2D,
                               static_cast<GLeglImageOES>(self->image[ring]));
    self->generation[ring] = f.generation;
  }

  // Sampler params live on the consumer texture (the import carries none; an
  // unfiltered/mip-incomplete texture samples black).
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  if (dbg) {
    GLenum e = glGetError();
    fprintf(stderr,
            "[mfl-gl] populate #%d -> name=%u %ux%u img=%p glErr=0x%x\n",
            dbgCalls, self->tex[ring], f.width, f.height,
            (void*)self->image[ring], e);
  }
  *target = GL_TEXTURE_2D;
  *name = self->tex[ring];
  *width = f.width;
  *height = f.height;
  return TRUE;
}

static void maplibre_flutter_linux_gl_texture_dispose(GObject* object) {
  MaplibreFlutterLinuxGlTexture* self =
      MAPLIBRE_FLUTTER_LINUX_GL_TEXTURE(object);
  if (self->set_frame_callback != nullptr && self->map_handle != nullptr) {
    self->set_frame_callback(self->map_handle, nullptr, nullptr);
    self->set_frame_callback = nullptr;
  }
  // The imported texture names live in Flutter's raster GL context, which is not
  // current here, so they cannot be glDeleteTextures'd — a small, bounded leak per
  // map dispose (acceptable for the experimental zero-copy path).
  G_OBJECT_CLASS(maplibre_flutter_linux_gl_texture_parent_class)->dispose(object);
}

static void maplibre_flutter_linux_gl_texture_class_init(
    MaplibreFlutterLinuxGlTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate =
      maplibre_flutter_linux_gl_texture_populate;
  G_OBJECT_CLASS(klass)->dispose = maplibre_flutter_linux_gl_texture_dispose;
}

static void maplibre_flutter_linux_gl_texture_init(
    MaplibreFlutterLinuxGlTexture* self) {
  for (int i = 0; i < MFL_GL_RING; i++) {
    self->image[i] = EGL_NO_IMAGE_KHR;
  }
}

static gboolean mark_frame_available_gl(gpointer user_data) {
  MaplibreFlutterLinuxGlTexture* self =
      MAPLIBRE_FLUTTER_LINUX_GL_TEXTURE(user_data);
  static int n = 0;
  if (mfl_gl_debug() && n < 16) {
    fprintf(stderr, "[mfl-gl] mark_frame_available_gl #%d registrar=%p\n", ++n,
            (void*)self->registrar);
  }
  if (self->registrar != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(self->registrar,
                                                      FL_TEXTURE(self));
  }
  g_object_unref(self);
  return G_SOURCE_REMOVE;
}

static void on_frame_ready_gl(void* user) {
  static int n = 0;
  if (mfl_gl_debug() && n < 16) {
    fprintf(stderr, "[mfl-gl] on_frame_ready_gl #%d\n", ++n);
  }
  auto* self = MAPLIBRE_FLUTTER_LINUX_GL_TEXTURE(user);
  g_idle_add(mark_frame_available_gl, g_object_ref(self));
}

// ===== The plugin =====
G_DECLARE_FINAL_TYPE(MaplibreFlutterLinuxPlugin, maplibre_flutter_linux_plugin,
                     MAPLIBRE_FLUTTER_LINUX, PLUGIN, GObject)

struct _MaplibreFlutterLinuxPlugin {
  GObject parent_instance;
  FlTextureRegistrar* registrar;  // borrowed (engine-lifetime)
  // Owning refs to registered textures (CPU FlPixelBufferTexture or zero-copy
  // FlTextureGL — held as the common base so both kinds coexist).
  std::map<int64_t, FlTexture*>* textures;
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
      (*self->textures)[id] = FL_TEXTURE(texture);  // our owning ref
      texture->set_frame_callback(texture->map_handle, on_frame_ready, texture);
      g_autoptr(FlValue) result = fl_value_new_int(id);
      response =
          FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else if (strcmp(method, "registerTextureGl") == 0) {
    // Zero-copy GL present: bind an FlTextureGL that imports the core map's dmabuf
    // ring into Flutter's raster context. The EGL entry points + dmabuf-import
    // support are resolved lazily on the first populate() — this handler runs on
    // the platform thread, which has NO current EGL context.
    const int64_t map_handle = arg_int(args, "mapHandle");
    const int64_t cur_fn = arg_int(args, "currentGlImageFn");
    const int64_t set_cb_fn = arg_int(args, "setFrameCallbackFn");
    if (map_handle == 0 || cur_fn == 0 || set_cb_fn == 0) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad_args", "registerTextureGl requires map handle + function addresses",
          nullptr));
    } else {
      auto* texture = MAPLIBRE_FLUTTER_LINUX_GL_TEXTURE(g_object_new(
          maplibre_flutter_linux_gl_texture_get_type(), nullptr));
      texture->map_handle = reinterpret_cast<void*>(map_handle);
      texture->current_gl_image =
          reinterpret_cast<MblCurrentGlImageFn>(cur_fn);
      texture->set_frame_callback =
          reinterpret_cast<MblSetFrameCallbackFn>(set_cb_fn);
      texture->registrar = self->registrar;
      fl_texture_registrar_register_texture(self->registrar,
                                            FL_TEXTURE(texture));
      const int64_t id = fl_texture_get_id(FL_TEXTURE(texture));
      (*self->textures)[id] = FL_TEXTURE(texture);  // our owning ref
      texture->set_frame_callback(texture->map_handle, on_frame_ready_gl,
                                  texture);
      if (mfl_gl_debug()) {
        fprintf(stderr, "[mfl-gl] registerTextureGl OK id=%ld registrar=%p\n",
                (long)id, (void*)self->registrar);
      }
      g_autoptr(FlValue) result = fl_value_new_int(id);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
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
  self->textures = new std::map<int64_t, FlTexture*>();
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
