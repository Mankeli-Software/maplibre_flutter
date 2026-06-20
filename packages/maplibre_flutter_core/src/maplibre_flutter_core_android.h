// Android-only C ABI for the experimental core-on-Android HTTP bridge (CLAUDE.md
// §3). The NDK ships no curl/TLS, so instead of the default curl http_file_source
// the Android arm implements mbgl::HTTPFileSource and bridges every request out to
// the host app's OkHttp (system trust store + TLS) over these two entry points. The
// Flutter plugin's JNI layer resolves them via dlsym (the symbols are exported from
// the core .so) and wires them to Kotlin.
//
// NOT part of the ffigen-bound surface (maplibre_flutter_core.h): the Dart layer
// never calls these — only the plugin's native code does.
#ifndef MAPLIBRE_FLUTTER_CORE_ANDROID_H
#define MAPLIBRE_FLUTTER_CORE_ANDROID_H

#include "maplibre_flutter_core.h" // FFI_PLUGIN_EXPORT

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Host HTTP callbacks (implemented by the plugin's JNI layer). `start` kicks off an
// async GET for `request_id`/`url`; the host later delivers the result via
// mbl_android_http_respond. `cancel` aborts an in-flight request (best effort).
typedef void (*MblAndroidHttpStart)(uint64_t request_id, const char *url, void *user);
typedef void (*MblAndroidHttpCancel)(uint64_t request_id, void *user);

// Registers the host's HTTP handler. Must be called before the first map is created
// (the style/tile requests start immediately on the render thread). Passing nulls
// makes every request fail (the link-time default until a handler is set).
FFI_PLUGIN_EXPORT void mbl_android_http_set_handler(MblAndroidHttpStart start,
                                                    MblAndroidHttpCancel cancel,
                                                    void *user);

// Delivers a completed request back to mbgl. `status` is the HTTP status (200, 404,
// …) or <= 0 for a transport failure. `data`/`len` is the response body (copied
// before this returns; may be null on error). `etag`/`expires` are optional response
// headers for caching (null to skip). Thread-safe: the response is marshaled onto
// the file source's run loop, so this may be called from any thread (e.g. an OkHttp
// callback). A request_id with no live request (already cancelled) is ignored.
FFI_PLUGIN_EXPORT void mbl_android_http_respond(uint64_t request_id, int32_t status,
                                                const uint8_t *data, size_t len,
                                                const char *etag, const char *expires);

// ---- Zero-copy present (EGL window surface) ----

// Hand the map a Flutter SurfaceProducer's `ANativeWindow` (passed as void*) to
// present into. SYNCHRONOUS: posts to the render thread, which creates an EGL window
// surface sharing mbgl's context, and waits for the result. Returns 1 if zero-copy
// is active (the render thread now blits mbgl's FBO into the window + swaps, no
// readback), 0 if it couldn't be set up (the caller should fall back to the CPU
// readback present). The core takes a ref on the window only on success; on failure
// the caller still owns it.
FFI_PLUGIN_EXPORT int mbl_map_set_android_window(MblMap *m, void *native_window);

// Tear down the zero-copy window surface (render thread). Call before releasing the
// `ANativeWindow`. No-op if zero-copy was never active.
FFI_PLUGIN_EXPORT void mbl_map_clear_android_window(MblMap *m);

// Non-zero if the map is presenting zero-copy into a window surface (the plugin uses
// this to decide whether its CPU frame callback needs to present).
FFI_PLUGIN_EXPORT int mbl_map_android_zero_copy_active(MblMap *m);

#ifdef __cplusplus
}
#endif

#endif // MAPLIBRE_FLUTTER_CORE_ANDROID_H
