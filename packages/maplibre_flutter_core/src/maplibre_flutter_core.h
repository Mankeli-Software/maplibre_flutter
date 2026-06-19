// C ABI shim over MapLibre Native (mbgl-core). Dart FFI cannot bind C++, so this
// header exposes a plain-C surface (opaque handle + functions) that ffigen binds
// (CLAUDE.md §5c). It must stay free of any mbgl/C++ includes so ffigen parses it
// against the bare toolchain. The implementation lives in maplibre_flutter_core.cpp.
//
// Threading: each MblMap owns a dedicated render thread that exclusively creates
// and drives the mbgl Map/RunLoop/HeadlessFrontend (mbgl is single-thread-affine).
// Commands are marshaled onto that thread; rendered frames are published to an
// internal buffer and announced via a frame-ready callback. Getters read cached
// state. All functions below are safe to call from any thread.
//
// Generated bindings: lib/src/maplibre_flutter_core_bindings_generated.dart
// (committed, regenerated with `dart run tool/ffigen.dart`, never hand-edited).
#ifndef MAPLIBRE_FLUTTER_CORE_H
#define MAPLIBRE_FLUTTER_CORE_H

#include <stddef.h>
#include <stdint.h>

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to one off-screen MapLibre map (owns an mbgl::Map + headless
// Metal backend + RunLoop on its own render thread). Created/destroyed from Dart.
typedef struct MblMap MblMap;

// Frame-ready callback, invoked on the render thread after a new frame has been
// rendered into the internal buffer. `user` is the pointer passed to
// mbl_map_set_frame_callback. Must be cheap and thread-safe: the macOS plugin
// uses it to call FlutterTextureRegistry.textureFrameAvailable. Do NOT call back
// into the map from here.
typedef void (*MblFrameCallback)(void *user);

// Create an off-screen map of `width`x`height` device pixels at `pixel_ratio`,
// loading `style_uri` (URL, file path, or inline JSON). Spawns the render thread
// and starts loading the style. Returns NULL on failure. Does not block on the
// style load — use mbl_map_await_frame or the frame callback to know when a
// frame exists.
//
// `continuous`: 0 = Static mode (each camera/style change renders one complete
// frame, blocking until all its tiles load — simple, used by headless/tests);
// 1 = Continuous mode (render partial frames immediately and refine as tiles
// stream in, like the mobile SDK — smooth interaction over uncached/detailed
// tiles, no per-frame network stall). The public API is identical either way.
FFI_PLUGIN_EXPORT MblMap *mbl_map_create(uint32_t width, uint32_t height,
                                         float pixel_ratio,
                                         const char *style_uri, int continuous);

// Replace the active style (URL, file path, or inline JSON). Triggers a re-render.
FFI_PLUGIN_EXPORT void mbl_map_set_style(MblMap *map, const char *style_uri);

// Jump the camera and trigger a re-render (no animation in M2; M3 adds duration).
FFI_PLUGIN_EXPORT void mbl_map_set_camera(MblMap *map, double lat, double lng,
                                          double zoom, double bearing,
                                          double pitch);

// Read the last-set camera into the (nullable) out params. Cheap (cached).
FFI_PLUGIN_EXPORT void mbl_map_get_camera(MblMap *map, double *out_lat,
                                          double *out_lng, double *out_zoom,
                                          double *out_bearing,
                                          double *out_pitch);

// Resize the off-screen surface and trigger a re-render.
FFI_PLUGIN_EXPORT void mbl_map_resize(MblMap *map, uint32_t width,
                                      uint32_t height);

// Pan the map by a screen-space delta (device pixels) and re-render. For the
// shared desktop gesture layer.
FFI_PLUGIN_EXPORT void mbl_map_move_by(MblMap *map, double dx, double dy);

// Zoom by `scale` (>1 zooms in) about the anchor point (device pixels) and
// re-render.
FFI_PLUGIN_EXPORT void mbl_map_scale_by(MblMap *map, double scale,
                                        double anchor_x, double anchor_y);

// Register (or clear, with NULL) the frame-ready callback. See MblFrameCallback.
FFI_PLUGIN_EXPORT void mbl_map_set_frame_callback(MblMap *map,
                                                  MblFrameCallback callback,
                                                  void *user);

// Block up to `timeout_ms` until at least one frame has been rendered. Returns 1
// if a frame is available, 0 on timeout. Intended for headless/test use and for
// an initial readiness wait — not for the per-frame present path.
FFI_PLUGIN_EXPORT int mbl_map_await_frame(MblMap *map, uint32_t timeout_ms);

// Copy the latest rendered frame as tightly-packed BGRA (premultiplied alpha)
// into `dst` (capacity `dst_capacity` bytes); non-blocking. BGRA matches the
// macOS CVPixelBuffer format so the texture bridge needs no swizzle. Writes the
// frame dimensions/row stride to the (nullable) out params. Returns 1 on success,
// 0 if no frame yet or the buffer is too small. Safe to call from the raster
// thread (the plugin calls it from copyPixelBuffer).
//
// A null `dst` is "query mode": it writes the current frame dimensions/stride
// and returns 1 (if a frame exists) without copying — lets the caller size a
// destination buffer first, so the texture can follow resizes automatically.
FFI_PLUGIN_EXPORT int mbl_map_copy_frame(MblMap *map, uint8_t *dst,
                                         size_t dst_capacity,
                                         uint32_t *out_width,
                                         uint32_t *out_height,
                                         uint32_t *out_stride);

// Enable (1) or disable (0) zero-copy presentation. When enabled, each render
// GPU-blits mbgl's rendered frame into a shared texture (no CPU readback): on macOS
// an IOSurface-backed BGRA texture (mbl_map_current_iosurface), on Linux/desktop GL
// an EGLImage-backed RGBA texture exposed via mbl_map_current_gl_image. A no-op
// (the CPU mbl_map_copy_frame path stays in use) if the platform helper can't
// initialise. Off by default. Call before or during use; takes effect next render.
FFI_PLUGIN_EXPORT void mbl_map_set_zero_copy(MblMap *map, int enabled);

// Select the byte order mbl_map_copy_frame writes: 1 = BGRA (default; matches the
// macOS CVPixelBuffer), 0 = RGBA (e.g. Linux FlPixelBufferTexture). mbgl renders
// RGBA, so BGRA costs a per-pixel swizzle and RGBA is a straight copy. Set once at
// setup; does not affect the zero-copy/IOSurface path (always BGRA).
FFI_PLUGIN_EXPORT void mbl_map_set_pixel_format_bgra(MblMap *map, int bgra);

// Return the IOSurface (as an opaque pointer; an IOSurfaceRef on macOS) backing
// the latest zero-copy frame, or NULL if zero-copy is off or no frame exists yet.
// The macOS plugin wraps it in a CVPixelBuffer for the texture with no copy. The
// surface is owned by the map and reused across frames (a small ring), so read it
// promptly from the present path. Safe to call from the raster thread.
FFI_PLUGIN_EXPORT void *mbl_map_current_iosurface(MblMap *map);

// A zero-copy GL frame published as a Linux dmabuf — a kernel buffer fd that is
// shareable ACROSS EGLDisplays/contexts (mbgl's render context and Flutter's raster
// context use different displays, so an EGLImage handle cannot cross between them; a
// dmabuf can). The plugin imports this into Flutter's context via
// EGL_LINUX_DMA_BUF_EXT. `fd` is process-wide and owned by the core (the plugin must
// NOT close it). `fd < 0` means "no frame".
typedef struct MblGlDmabufFrame {
  int32_t fd;          // dmabuf file descriptor (process-wide; core owns it)
  uint32_t fourcc;     // DRM FourCC pixel format
  uint32_t stride;     // plane-0 row pitch in bytes
  uint32_t offset;     // plane-0 byte offset
  uint64_t modifier;   // DRM format modifier (DRM_FORMAT_MOD_INVALID if none)
  uint64_t generation; // bumped on resize (the fd changes); for the plugin's cache
  uint32_t ring_index; // which ring slot (0..N-1)
  uint32_t width;
  uint32_t height;
} MblGlDmabufFrame;

// Latest zero-copy GL frame for the Linux FlTextureGL present (called by address
// from the plugin's populate callback on the raster thread). Fills *out with the
// current dmabuf descriptor and returns 1 if a zero-copy GL frame is available, 0
// otherwise (zero-copy off, no frame yet, tearing down, or non-Linux). Reads only
// mutex-guarded state — no GL/EGL calls — so it is safe on the raster thread.
FFI_PLUGIN_EXPORT int mbl_map_current_gl_image(MblMap *map,
                                               MblGlDmabufFrame *out);

// Non-zero (1) if the GL zero-copy presenter is live (its dmabuf exporter
// initialised), 0 otherwise. Lets the plugin/Dart confirm zero-copy actually
// activated before committing to the FlTextureGL path. 0 on non-Linux.
FFI_PLUGIN_EXPORT int mbl_map_gl_active(MblMap *map);

// Windows D3D11 zero-copy: the latest frame published as a DXGI shared handle (a
// legacy IDXGIResource::GetSharedHandle from a shared D3D11 texture). The Windows
// plugin hands it to a Flutter GpuSurfaceTexture (DxgiSharedHandle), which ANGLE
// re-opens on Flutter's device via EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE. Fills
// *out_handle and the (nullable) size out params and returns 1 if a zero-copy D3D
// frame is available, 0 otherwise (zero-copy off, no frame yet, tearing down, or
// non-Windows). Reads only mutex-guarded state — no D3D/GL/EGL calls — so it is
// safe on the raster thread.
FFI_PLUGIN_EXPORT int mbl_map_current_d3d_handle(MblMap *map, void **out_handle,
                                                 uint32_t *out_width,
                                                 uint32_t *out_height);

// Non-zero (1) if the D3D11 zero-copy presenter is live, 0 otherwise. Lets the
// plugin/Dart confirm zero-copy activated before committing to the
// GpuSurfaceTexture path. 0 on non-Windows.
FFI_PLUGIN_EXPORT int mbl_map_d3d_active(MblMap *map);

// Debug/verification: encode the latest frame to a PNG file at `path` using
// mbgl's own PNG encoder. Returns 1 on success, 0 if no frame or the write failed.
FFI_PLUGIN_EXPORT int mbl_map_write_png(MblMap *map, const char *path);

// Stop the render thread and free all resources. The handle is invalid after.
FFI_PLUGIN_EXPORT void mbl_map_destroy(MblMap *map);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // MAPLIBRE_FLUTTER_CORE_H
