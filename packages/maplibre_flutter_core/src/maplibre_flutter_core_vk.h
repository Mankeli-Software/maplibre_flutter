// Zero-copy present helper for the Windows (Vulkan) core — the Vulkan analog of
// maplibre_flutter_core_metal.h (macOS/IOSurface) and the now-removed _d3d.h
// (ANGLE-GL). The Windows core renders with mbgl's Vulkan headless backend; this
// helper imports mbgl's rendered color VkImage into a small ring of *shared D3D11*
// textures (BGRA8) and publishes each slot's DXGI shared handle. The Windows plugin
// hands that handle to a Flutter GpuSurfaceTexture
// (kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle), which ANGLE re-opens on Flutter's
// own D3D11 device via EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE — so the frame reaches
// the screen with no CPU readback (mirrors the macOS Metal->IOSurface path).
//
// Why this is Vulkan, not ANGLE/GL: the GL renderer crashed under rapid tile churn (a
// DrawableGL/VAO resource-lifetime bug that ANGLE's strict D3D11 validation faults on).
// Vulkan has no GL path, and the D3D11 interop below keeps the zero-copy present.
//
// Direction (create-in-D3D11, import-into-Vulkan): the handle Flutter/ANGLE consumes
// MUST come from a real D3D11 texture, so we create the shared D3D11 texture on a D3D11
// device pinned to the SAME adapter as mbgl's Vulkan device (matched by LUID), then
// import it into Vulkan as external memory (VK_KHR_external_memory_win32, handle type
// D3D11_TEXTURE_KMT for the legacy IDXGIResource::GetSharedHandle the ANGLE share-handle
// path requires) and blit mbgl's frame into it.
//
// Sync: no keyed mutex (ANGLE's legacy share-handle path never Acquire/Release-s one).
// The producer's full GPU completion IS the sync — mbgl's Context::submitOneTimeCommand
// submits the blit with a fence and waits on it (the analog of the GL path's glFinish) —
// and a ring of N slots keeps the producer from overwriting a slot Flutter may still be
// sampling.
//
// Threading: every function runs on mbgl's render thread with mbgl's Vulkan context
// current (inside a gfx::BackendScope). The cross-thread getter the plugin's
// GpuSurfaceTexture callback uses lives in the core shim (it only reads the stored
// handle under a mutex; it never touches Vulkan/D3D on the raster thread).
#pragma once

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque presenter: owns the LUID-matched D3D11 device, a ring of shared D3D11 textures
// (each imported into Vulkan as a VkImage), plus a generation counter and a deferred-
// destroy list so a slot is never freed while the raster thread might still sample it.
typedef struct MblVkPresenter MblVkPresenter;

// Create a presenter. `backend` is the mbgl::vulkan::RendererBackend* (as void*) of the
// map's headless backend; the helper keeps it to reach the device/queue/pool/allocator/
// dispatcher/physical-device and, each present, mbgl's rendered color image. Queries the
// Vulkan device LUID (needs VK_KHR_get_physical_device_properties2 — enabled by the
// windows-vulkan-external-memory mbgl patch), creates a D3D11 device on the matching DXGI
// adapter, and resolves the Win32 external-memory entry points. Returns NULL if the config
// is unsupported (no valid LUID, no external-memory extensions, adapter/device-creation
// failure) so the caller falls back to the CPU mbl_map_copy_frame path. Render thread,
// mbgl Vulkan context current.
MblVkPresenter *mbl_vk_presenter_create(void *backend);

// (Re)allocate the ring for width x height device pixels and bump the generation. The
// previous ring is RETIRED (not freed immediately) and destroyed only after a full ring
// cycle of subsequent presents, so no texture the raster thread may still sample is freed
// underneath it. Returns 1 on success, 0 on failure. No-op (returns 1) if the size is
// unchanged. Render thread, context current.
int mbl_vk_presenter_resize(MblVkPresenter *p, uint32_t width, uint32_t height);

// Blit mbgl's just-rendered color image (fetched internally via the backend's headless
// renderable getAcquiredImage(), which for the headless backend is left in
// TRANSFER_SRC_OPTIMAL after render) into the next ring slot, flipping vertically to match
// the CPU path's top-down image, via mbgl's Context::submitOneTimeCommand (records the
// blit + barriers, submits with a fence, and WAITS for GPU completion). On success writes
// the slot's DXGI shared handle to *out_handle and returns 1; returns 0 on failure (caller
// falls back to CPU readback). Render thread, context current, inside a BackendScope.
int mbl_vk_presenter_present(MblVkPresenter *p, void **out_handle);

// Destroy the ring (Vulkan images/memory + D3D11 textures, including retired slots), the
// D3D11 device, and the presenter. Render thread, context current. The shim guarantees no
// raster-thread read is in flight (it clears the published handle before calling this).
void mbl_vk_presenter_destroy(MblVkPresenter *p);

#ifdef __cplusplus
}
#endif
