// Zero-copy present helper for the Windows (ANGLE / OpenGL ES on Direct3D 11)
// core — the D3D analog of maplibre_flutter_core_metal.h (macOS/IOSurface) and
// maplibre_flutter_core_gl.h (Linux/dmabuf). The C ABI shim renders a frame into
// mbgl-core's offscreen FBO, then calls in here to GPU-blit that FBO into one of a
// small ring of shared D3D11 textures, and publishes the slot's DXGI shared
// handle. The Windows plugin hands that handle to a Flutter GpuSurfaceTexture
// (kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle), which ANGLE opens on Flutter's
// own device via EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE — so the frame reaches the
// screen with no CPU readback (mirrors the macOS Metal->IOSurface path).
//
// Why a DXGI shared handle (not the D3D11 texture pointer): mbgl's render context
// and Flutter's raster context are separate ANGLE EGLDisplays backed by separate
// D3D11 devices. A legacy DXGI shared handle (IDXGIResource::GetSharedHandle, from
// a D3D11_RESOURCE_MISC_SHARED texture) is the cross-device-safe token ANGLE
// re-opens on the consumer device; an ID3D11Texture2D* would be device-scoped.
//
// Sync: like Flutter's own external_texture_d3d.cc, there is NO keyed mutex. The
// producer glFlush()es so the blit is submitted, and a ring of N slots keeps the
// producer from overwriting a slot the consumer may still be sampling.
//
// Threading: every function here runs on mbgl's render thread with mbgl's EGL
// context current (inside a gfx::BackendScope). The cross-thread getter the
// plugin's GpuSurfaceTexture callback uses lives in the core shim (it only reads
// the stored handle under a mutex and never touches D3D/EGL on the raster thread).
#pragma once

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque presenter: owns ANGLE's D3D11 device, the EGL entry points, and a ring of
// shared D3D11 textures (each wrapped as an ANGLE pbuffer + a destination FBO),
// plus a generation counter and a deferred-destroy list so a slot is never freed
// while the raster thread might still be sampling it.
typedef struct MblD3dPresenter MblD3dPresenter;

// Create a presenter. Requires mbgl's EGL context current. Queries ANGLE's backing
// ID3D11Device (EGL_ANGLE_device_d3d) and resolves the pbuffer-from-D3D-texture
// entry points (EGL_ANGLE_d3d_texture_client_buffer). Returns NULL if the config
// is unsupported (e.g. a non-D3D11 ANGLE backend) so the caller falls back to the
// CPU mbl_map_copy_frame path.
MblD3dPresenter *mbl_d3d_presenter_create(void);

// (Re)allocate the ring for width x height device pixels and bump the generation.
// The previous ring is RETIRED (not freed immediately) and destroyed only after a
// full ring cycle of subsequent presents, so no texture the raster thread may
// still sample is freed underneath it. Returns 1 on success, 0 on failure. No-op
// (returns 1) if the size is unchanged. Render thread, context current.
int mbl_d3d_presenter_resize(MblD3dPresenter *p, uint32_t width,
                             uint32_t height);

// Blit the currently-bound draw framebuffer (the shim binds mbgl's color
// renderable immediately before calling, so GL_DRAW_FRAMEBUFFER_BINDING is
// reliably mbgl's color FBO) into the next ring slot, flipping vertically to match
// the CPU path's top-down image, then glFlush() so the blit is submitted. On
// success writes the slot's DXGI shared handle to *out_handle and returns 1;
// returns 0 on failure (caller falls back to CPU readback). Render thread, context
// current, inside a BackendScope.
int mbl_d3d_presenter_present(MblD3dPresenter *p, void **out_handle);

// Destroy the ring (EGL surfaces + GL textures/FBOs + D3D11 textures, including any
// retired slots) and free the presenter. Render thread, context current. The shim
// guarantees no raster-thread read is in flight (it clears the published handle
// before calling this).
void mbl_d3d_presenter_destroy(MblD3dPresenter *p);

#ifdef __cplusplus
}
#endif
