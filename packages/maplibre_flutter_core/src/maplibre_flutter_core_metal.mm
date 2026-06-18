// Objective-C++ implementation of the zero-copy present helper (see
// maplibre_flutter_core_metal.h). Runs a Metal compute pass that copies
// mbgl-core's rendered RGBA texture into an IOSurface-backed BGRA texture; the
// RGBA->BGRA swizzle is implicit in the pixel-format conversion (we read logical
// RGBA from the source and write logical RGBA into a BGRA texture, which Metal
// stores in BGRA byte order — exactly what Flutter's CVPixelBuffer expects).
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include "maplibre_flutter_core_metal.h"

#include <cstdio>

namespace {

// Number of IOSurfaces cycled through, so a frame Flutter is still presenting is
// not overwritten by the next render. Renders are on demand (not a 60fps loop),
// so contention is low; 3 is ample.
constexpr int kRingSize = 3;

// Compute kernel: copy src[gid] -> dst[gid]. src is RGBA8, dst is BGRA8, so the
// channel swap happens for free in Metal's format conversion.
constexpr const char* kShaderSource = R"(
#include <metal_stdlib>
using namespace metal;
kernel void rgba_to_bgra(texture2d<float, access::read>  src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
  dst.write(src.read(gid), gid);
}
)";

} // namespace

struct MblMetalBlitter {
  id<MTLDevice> device = nil;
  id<MTLComputePipelineState> pipeline = nil;

  // Ring of IOSurface-backed BGRA textures, recreated when the frame size
  // changes. Each surface is retained for the blitter's lifetime.
  IOSurfaceRef surfaces[kRingSize] = {nullptr};
  id<MTLTexture> textures[kRingSize] = {nil};
  uint32_t ringWidth = 0;
  uint32_t ringHeight = 0;
  int next = 0;

  // The most recently committed blit, so destroy() can drain in-flight GPU work
  // before tearing down (no completion handler fires after free).
  id<MTLCommandBuffer> lastCommandBuffer = nil;

  // Lazily builds the device/pipeline from the source texture's device (the blit
  // runs on mbgl's command queue, passed per-call).
  bool ensureInit(id<MTLTexture> src) {
    if (pipeline != nil) {
      return true;
    }
    device = src.device;
    if (device == nil) {
      return false;
    }
    NSError* err = nil;
    id<MTLLibrary> lib =
        [device newLibraryWithSource:@(kShaderSource) options:nil error:&err];
    if (lib == nil) {
      fprintf(stderr, "maplibre_flutter_core: shader compile failed: %s\n",
              err.localizedDescription.UTF8String);
      return false;
    }
    id<MTLFunction> fn = [lib newFunctionWithName:@"rgba_to_bgra"];
    pipeline = [device newComputePipelineStateWithFunction:fn error:&err];
    if (pipeline == nil) {
      fprintf(stderr, "maplibre_flutter_core: pipeline creation failed: %s\n",
              err.localizedDescription.UTF8String);
      return false;
    }
    return true;
  }

  void releaseRing() {
    for (int i = 0; i < kRingSize; ++i) {
      textures[i] = nil;
      if (surfaces[i] != nullptr) {
        CFRelease(surfaces[i]);
        surfaces[i] = nullptr;
      }
    }
  }

  // (Re)creates the IOSurface ring for the given size.
  bool ensureRing(uint32_t w, uint32_t h) {
    if (ringWidth == w && ringHeight == h && textures[0] != nil) {
      return true;
    }
    releaseRing();
    for (int i = 0; i < kRingSize; ++i) {
      NSDictionary* props = @{
        (id)kIOSurfaceWidth : @(w),
        (id)kIOSurfaceHeight : @(h),
        (id)kIOSurfaceBytesPerElement : @4,
        (id)kIOSurfacePixelFormat : @((unsigned)kCVPixelFormatType_32BGRA),
      };
      IOSurfaceRef surf = IOSurfaceCreate((CFDictionaryRef)props);
      if (surf == nullptr) {
        releaseRing();
        return false;
      }
      MTLTextureDescriptor* desc = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                       width:w
                                      height:h
                                   mipmapped:NO];
      desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
      desc.storageMode = MTLStorageModeShared;
      id<MTLTexture> tex = [device newTextureWithDescriptor:desc
                                                  iosurface:surf
                                                      plane:0];
      if (tex == nil) {
        CFRelease(surf);
        releaseRing();
        return false;
      }
      surfaces[i] = surf;
      textures[i] = tex;
    }
    ringWidth = w;
    ringHeight = h;
    next = 0;
    return true;
  }
};

MblMetalBlitter* mbl_metal_blitter_create(void) { return new MblMetalBlitter(); }

int mbl_metal_blitter_blit(MblMetalBlitter* b, void* src_texture,
                           void* command_queue, MblBlitDoneFn on_done,
                           void* user) {
  if (b == nullptr || src_texture == nullptr || command_queue == nullptr) {
    return 0;
  }
  @autoreleasepool {
    id<MTLTexture> src = (__bridge id<MTLTexture>)src_texture;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)command_queue;
    const uint32_t w = (uint32_t)src.width;
    const uint32_t h = (uint32_t)src.height;
    if (w == 0 || h == 0) {
      return 0;
    }
    if (!b->ensureInit(src) || !b->ensureRing(w, h)) {
      return 0;
    }

    const int slot = b->next;
    b->next = (b->next + 1) % kRingSize;
    id<MTLTexture> dst = b->textures[slot];
    IOSurfaceRef surface = b->surfaces[slot];

    // Encode on mbgl's own queue so the blit is ordered after the render that
    // just completed and before the next render overwrites the source texture —
    // no CPU wait needed for correctness.
    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:b->pipeline];
    [enc setTexture:src atIndex:0];
    [enc setTexture:dst atIndex:1];
    const MTLSize tg = MTLSizeMake(16, 16, 1);
    const MTLSize grid = MTLSizeMake((w + tg.width - 1) / tg.width,
                                     (h + tg.height - 1) / tg.height, 1);
    [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
    [enc endEncoding];
    if (on_done != nullptr) {
      [cmd addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
        on_done(user, surface);
      }];
    }
    [cmd commit];
    b->lastCommandBuffer = cmd;
    return 1;
  }
}

void mbl_metal_blitter_destroy(MblMetalBlitter* b) {
  if (b == nullptr) {
    return;
  }
  // Drain any in-flight blit so its completion handler can't fire after free.
  [b->lastCommandBuffer waitUntilCompleted];
  b->lastCommandBuffer = nil;
  b->releaseRing();
  delete b;
}
