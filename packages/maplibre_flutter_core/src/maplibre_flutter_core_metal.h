// Zero-copy present helper for the macOS Metal desktop core (CLAUDE.md §8 M5,
// "true zero-copy"). The C ABI shim (maplibre_flutter_core.cpp) renders a frame
// into mbgl-core's own offscreen Metal texture, then calls in here to copy that
// texture — on the GPU — into an IOSurface-backed BGRA texture that Flutter can
// present without any CPU readback or swizzle.
//
// This is plain C so the C++ shim can call it without pulling in Objective-C;
// the implementation is Objective-C++ (maplibre_flutter_core_metal.mm).
#pragma once

#include <IOSurface/IOSurfaceRef.h>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque blitter owning the RGBA->BGRA compute pipeline and a small ring of
// IOSurface-backed BGRA textures. Lazily initialised from the first source
// texture's MTLDevice (the blit must run on the same device mbgl-core renders
// with — cross-device textures cannot be shared).
typedef struct MblMetalBlitter MblMetalBlitter;

// Called when a blit's GPU work has completed (on a Metal-owned thread): `user`
// is the pointer passed to mbl_metal_blitter_blit, `surface` the now-ready
// IOSurface. Must be cheap and thread-safe.
typedef void (*MblBlitDoneFn)(void* user, IOSurfaceRef surface);

// Allocates a blitter. The Metal device/pipeline are created on the first blit,
// from the source texture's device.
MblMetalBlitter* mbl_metal_blitter_create(void);

// Encodes a GPU compute pass copying the rendered `src_texture` (an
// `id<MTLTexture>` / `MTL::Texture*` passed as void*, RGBA8) into the next ring
// IOSurface (BGRA8, the swizzle implicit in the format), on `command_queue` (an
// `id<MTLCommandQueue>` / `MTL::CommandQueue*` as void* — pass mbgl's own queue so
// the blit is GPU-ordered after the render and before the next one). Does NOT
// block: `on_done(user, surface)` fires on GPU completion. Returns 1 if the blit
// was committed (so on_done will fire), 0 on failure (caller should fall back).
int mbl_metal_blitter_blit(MblMetalBlitter* blitter, void* src_texture,
                           void* command_queue, MblBlitDoneFn on_done,
                           void* user);

// Frees the blitter and its ring of IOSurfaces/textures, after waiting for any
// in-flight blit to complete (so no completion handler fires afterward).
void mbl_metal_blitter_destroy(MblMetalBlitter* blitter);

#ifdef __cplusplus
}
#endif
