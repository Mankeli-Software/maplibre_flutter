// Zero-copy present helper for the non-Apple (Linux/desktop OpenGL ES) core — the
// GL analog of maplibre_flutter_core_metal.h. The C ABI shim renders a frame into
// mbgl-core's offscreen renderbuffer FBO, then calls in here to GPU-blit that FBO
// into one of a small ring of RGBA8 textures, each backed by a persistent
// EGLImageKHR. Because an EGLImageKHR handle is EGLDisplay-scoped (not
// context-scoped), Flutter's raster GL context can sample the very same image via
// glEGLImageTargetTexture2DOES — so the frame reaches an FlTextureGL with no CPU
// readback (mirrors the macOS Metal→IOSurface path).
//
// Threading: every function here runs on mbgl's render thread with mbgl's EGL
// context current (inside a gfx::BackendScope). The cross-thread getter that the
// FlTextureGL populate callback uses lives in the core shim (it only reads stored
// fields under a mutex and never touches GL/EGL on the raster thread).
//
// This helper is mbgl-agnostic (pure GL/EGL); the shim does the one mbgl-specific
// step — binding mbgl's color renderable so the FBO is reliably current — before
// calling mbl_gl_presenter_present.
#pragma once

#include <cstdint>

#include "maplibre_flutter_core.h" // MblGlDmabufFrame

#ifdef __cplusplus
extern "C" {
#endif

// Opaque presenter: owns a ring of N RGBA8 textures (each with a persistent
// EGLImageKHR + a destination FBO), a generation counter, and a deferred-free
// list so a ring slot is never destroyed while the raster thread might still be
// sampling it. EGLImageKHR is not reference-counted (unlike IOSurface), so the
// ring + generation + deferred destroy emulate that safety.
typedef struct MblGlPresenter MblGlPresenter;

// Create a presenter. Resolves the EGL/GL extension entry points via
// eglGetProcAddress and probes the required extensions (EGL_KHR_image_base,
// EGL_KHR_gl_texture_2D_image, GL_OES_EGL_image). Returns NULL if any is missing
// (e.g. a software-GL config) so the caller falls back to CPU readback. Must be
// called with mbgl's EGL context current (inside a BackendScope).
MblGlPresenter* mbl_gl_presenter_create(void);

// (Re)allocate the ring for width x height device pixels and bump the generation.
// The previous ring's textures/images are RETIRED (not freed immediately) and
// destroyed only after a full ring cycle of subsequent presents, so no image the
// raster thread may still sample is freed underneath it. Returns 1 on success, 0
// on failure. No-op (returns 1) if the size is unchanged. Render thread, context
// current.
int mbl_gl_presenter_resize(MblGlPresenter* p, uint32_t width, uint32_t height);

// Blit the currently-bound draw framebuffer (the shim binds mbgl's color
// renderable immediately before calling, so GL_DRAW_FRAMEBUFFER_BINDING is
// reliably mbgl's color FBO) into the next ring slot, flipping vertically to match
// the CPU path's top-down image, then glFinish() so the frame is GPU-complete.
// Restores the framebuffer binding to mbgl's FBO before returning so mbgl's GL
// state cache stays truthful. On success fills *out with the slot's dmabuf
// descriptor (fd is the slot's persistent exported dmabuf, owned by the presenter)
// and returns 1; returns 0 on failure (caller falls back to CPU readback). Render
// thread, context current, inside a BackendScope.
int mbl_gl_presenter_present(MblGlPresenter* p, MblGlDmabufFrame* out);

// Destroy the ring (eglDestroyImageKHR + glDeleteTextures + glDeleteFramebuffers,
// including any retired slots) and free the presenter. Render thread, context
// current. The shim guarantees no raster-thread import is in flight (it clears the
// published descriptor and stops handing out images before calling this).
void mbl_gl_presenter_destroy(MblGlPresenter* p);

#ifdef __cplusplus
}
#endif
