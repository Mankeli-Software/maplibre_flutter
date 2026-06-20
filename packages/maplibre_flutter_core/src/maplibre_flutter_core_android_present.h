// Zero-copy present helper for the experimental core-on-Android path (CLAUDE.md §3)
// — the Android analog of the macOS Metal/IOSurface, Windows Vulkan/D3D, and Linux
// GL/dmabuf presenters. Instead of a GPU->CPU readback (the stuttery default), the
// shim renders mbgl into its offscreen FBO, then calls in here to GPU-blit that FBO
// into an EGL **window surface** created from the Flutter SurfaceProducer's
// `ANativeWindow`, and `eglSwapBuffers` to present it — GPU-to-GPU, no readback.
//
// The window surface SHARES mbgl's existing EGLContext (so no resource sharing is
// needed): every call runs on mbgl's render thread with that context current (inside
// a gfx::BackendScope). Create captures the current EGLDisplay/EGLContext + mbgl's
// own draw/read surfaces (to restore); present temporarily makes the window surface
// current for the blit+swap, then restores mbgl's surfaces + framebuffer binding so
// mbgl's GL state cache stays truthful.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Opaque presenter owning the EGL window surface + the saved mbgl EGL state.
typedef struct MblAndroidPresenter MblAndroidPresenter;

// Create a presenter for `native_window` (an `ANativeWindow*`, passed as void*).
// MUST be called with mbgl's EGL context current (inside a BackendScope): it reads
// the current display/context/surfaces via eglGetCurrent*. Chooses a window-capable
// RGBA8 ES3 config and creates an EGL window surface. Returns NULL on any failure
// (e.g. a config the driver won't accept on this surface) so the caller falls back
// to the CPU readback present.
MblAndroidPresenter* mbl_android_presenter_create(void* native_window);

// Blit the currently-bound draw framebuffer (the shim binds mbgl's color renderable
// immediately before calling, so GL_DRAW_FRAMEBUFFER_BINDING is mbgl's color FBO)
// into the window surface, flipping vertically to match top-down image space, then
// eglSwapBuffers. Restores mbgl's surfaces + draw-framebuffer binding before
// returning. Returns 1 on success, 0 on failure. Render thread, context current.
int mbl_android_presenter_present(MblAndroidPresenter* p);

// Destroy the EGL window surface and free the presenter. MUST run on the render
// thread with mbgl's context current (it eglMakeCurrent's mbgl's surfaces back).
void mbl_android_presenter_destroy(MblAndroidPresenter* p);

#ifdef __cplusplus
}
#endif
