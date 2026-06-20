import CoreVideo
import FlutterMacOS
import Foundation
import IOSurface

// The shim's C functions are addressed by Dart (which already resolves them for
// FFI) and handed to us as integers over the registrar channel. We cast those
// addresses to typed C function pointers — no dlopen/dlsym, so packaging the
// core as a framework vs a bare dylib doesn't matter.
private typealias CopyFrameFn = @convention(c) (
  UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int,
  UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
  UnsafeMutablePointer<UInt32>?
) -> Int32

private typealias SetFrameCallbackFn = @convention(c) (
  UnsafeMutableRawPointer?,
  (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
  UnsafeMutableRawPointer?
) -> Void

// Returns the IOSurface (as a raw pointer) backing the latest zero-copy frame,
// or null when zero-copy is off / no frame yet.
private typealias CurrentIOSurfaceFn = @convention(c) (UnsafeMutableRawPointer?)
  -> UnsafeMutableRawPointer?

// Invoked as a C function pointer on the core's render thread when a frame is
// ready. `user` is the MapLibreTexture passed unretained at registration.
private let mblFrameReady: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
  user in
  guard let user = user else { return }
  Unmanaged<MapLibreTexture>.fromOpaque(user).takeUnretainedValue().onFrameReady()
}

/// Bridges one core `MblMap*`'s rendered frames into a Flutter `Texture`
/// (CLAUDE.md §8 M5). The render thread calls `onFrameReady`; Flutter then pulls
/// `copyPixelBuffer`. Two present paths:
///   - Zero-copy: the core GPU-blits its rendered frame into an IOSurface; we
///     wrap that IOSurface in a CVPixelBuffer with no copy (`currentIOSurfaceFn`
///     returns it). The fast path.
///   - CPU readback (fallback / when zero-copy is off): copy the latest BGRA
///     frame out of the core via `copyFrameFn` into a pooled CVPixelBuffer.
/// Both size themselves to the current frame, so they follow core resizes.
final class MapLibreTexture: NSObject, FlutterTexture {
  private let mapHandle: UnsafeMutableRawPointer
  private weak var registry: FlutterTextureRegistry?
  private var textureId: Int64 = 0

  private let copyFrameFn: CopyFrameFn
  private let setFrameCallbackFn: SetFrameCallbackFn
  private let currentIOSurfaceFn: CurrentIOSurfaceFn?

  // CPU-readback path only: a reused IOSurface-backed buffer pool (recreated on
  // size change) so we don't allocate a fresh CVPixelBuffer every frame.
  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0

  // Zero-copy path: cache one CVPixelBuffer per ring IOSurface so we don't wrap a
  // fresh one every present (the ring is small + stable). Cleared when it grows
  // past a couple of ring sizes (i.e. after surface-set churn from a resize).
  private var bufferCache: [UnsafeRawPointer: CVPixelBuffer] = [:]

  // The last buffer successfully handed to the engine (either present path).
  // Returned as a fallback when a fresh frame isn't ready yet — chiefly mid-resize,
  // when the core hasn't rendered the new size — so the texture briefly shows a
  // stale/stretched image instead of flashing the white window background.
  private var lastBuffer: CVPixelBuffer?

  /// A `+1` on the last good buffer, or nil if we've never produced one (first
  /// frame). Used so a transient failure presents the previous frame, not white.
  private func fallbackBuffer() -> Unmanaged<CVPixelBuffer>? {
    if let last = lastBuffer { return Unmanaged.passRetained(last) }
    return nil
  }

  init(
    mapHandle: UnsafeMutableRawPointer, copyFrameAddress: Int,
    setFrameCallbackAddress: Int, currentIOSurfaceAddress: Int,
    registry: FlutterTextureRegistry
  ) {
    self.mapHandle = mapHandle
    self.copyFrameFn = unsafeBitCast(
      UnsafeMutableRawPointer(bitPattern: copyFrameAddress)!, to: CopyFrameFn.self)
    self.setFrameCallbackFn = unsafeBitCast(
      UnsafeMutableRawPointer(bitPattern: setFrameCallbackAddress)!,
      to: SetFrameCallbackFn.self)
    self.currentIOSurfaceFn =
      UnsafeMutableRawPointer(bitPattern: currentIOSurfaceAddress)
      .map { unsafeBitCast($0, to: CurrentIOSurfaceFn.self) }
    self.registry = registry
    super.init()
  }

  /// Registers with the engine and wires the core's frame-ready callback.
  func register() -> Int64 {
    guard let registry = registry else { return 0 }
    textureId = registry.register(self)
    setFrameCallbackFn(
      mapHandle, mblFrameReady, Unmanaged.passUnretained(self).toOpaque())
    return textureId
  }

  func unregister() {
    setFrameCallbackFn(mapHandle, nil, nil)
    registry?.unregisterTexture(textureId)
  }

  /// Render thread → engine. `textureFrameAvailable` is thread-safe.
  func onFrameReady() {
    registry?.textureFrameAvailable(textureId)
  }

  /// An IOSurface-backed pool sized to the current frame, recreated only when
  /// the size changes.
  private func pixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
    if let pool = pool, poolWidth == width, poolHeight == height {
      return pool
    }
    let pixelBufferAttrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let poolAttrs: [String: Any] = [
      kCVPixelBufferPoolMinimumBufferCountKey as String: 3
    ]
    var newPool: CVPixelBufferPool?
    guard
      CVPixelBufferPoolCreate(
        kCFAllocatorDefault, poolAttrs as CFDictionary,
        pixelBufferAttrs as CFDictionary, &newPool) == kCVReturnSuccess
    else { return nil }
    pool = newPool
    poolWidth = width
    poolHeight = height
    return newPool
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    // Zero-copy fast path: if the core has a rendered IOSurface, wrap it in a
    // CVPixelBuffer directly (no readback, no copy). Falls through to the CPU
    // path if zero-copy is off, no frame exists yet, or wrapping fails.
    if let iosurfaceFn = currentIOSurfaceFn,
      let surfacePtr = iosurfaceFn(mapHandle)
    {
      // The getter hands us a +1 retained surface so a concurrent ring teardown on
      // the render thread can't free it mid-wrap (was an EXC_BAD_ACCESS on resize).
      // Balance that +1 on every exit; CVPixelBufferCreateWithIOSurface and the
      // cache take their own refs, so the surface stays alive while we use it.
      let surfaceHandle = Unmanaged<IOSurfaceRef>.fromOpaque(surfacePtr)
      defer { surfaceHandle.release() }
      let surface = surfaceHandle.takeUnretainedValue()

      // Reuse a cached CVPixelBuffer for this surface, but only while it still
      // matches the surface's live size: a resize recreates the ring and the
      // allocator may reuse a freed address, which would otherwise hit a stale
      // (wrong-size) cache entry.
      if let cached = bufferCache[surfacePtr],
        CVPixelBufferGetWidth(cached) == IOSurfaceGetWidth(surface),
        CVPixelBufferGetHeight(cached) == IOSurfaceGetHeight(surface)
      {
        lastBuffer = cached
        return Unmanaged.passRetained(cached)
      }
      bufferCache.removeValue(forKey: surfacePtr)

      var pixelBuffer: Unmanaged<CVPixelBuffer>?
      if CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault, surface, nil, &pixelBuffer) == kCVReturnSuccess,
        let buffer = pixelBuffer
      {
        // Retain into the cache (held for reuse) and hand a separate +1 back.
        let pb = buffer.takeRetainedValue()
        if bufferCache.count >= 6 { bufferCache.removeAll() }
        bufferCache[surfacePtr] = pb
        lastBuffer = pb
        return Unmanaged.passRetained(pb)
      }
    }

    // Query the current frame size first (null dst), so the buffer always
    // matches the core's render surface even after a resize.
    var w: UInt32 = 0
    var h: UInt32 = 0
    var stride: UInt32 = 0
    guard copyFrameFn(mapHandle, nil, 0, &w, &h, &stride) != 0, w > 0, h > 0
    else { return fallbackBuffer() }
    let width = Int(w)
    let height = Int(h)

    guard let pool = pixelBufferPool(width: width, height: height) else {
      return fallbackBuffer()
    }
    var pixelBuffer: CVPixelBuffer?
    guard
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        == kCVReturnSuccess, let buffer = pixelBuffer
    else { return fallbackBuffer() }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let base = CVPixelBufferGetBaseAddress(buffer)?
        .assumingMemoryBound(to: UInt8.self)
    else { return fallbackBuffer() }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let tightRow = width * 4
    let ok: Int32
    if bytesPerRow == tightRow {
      ok = copyFrameFn(mapHandle, base, bytesPerRow * height, &w, &h, &stride)
    } else {
      // CVPixelBuffer rows are padded; copy into a tight temp then row-copy.
      let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: tightRow * height)
      defer { tmp.deallocate() }
      ok = copyFrameFn(mapHandle, tmp, tightRow * height, &w, &h, &stride)
      if ok != 0 {
        for row in 0..<height {
          memcpy(base + row * bytesPerRow, tmp + row * tightRow, tightRow)
        }
      }
    }
    if ok == 0 { return fallbackBuffer() }
    lastBuffer = buffer
    return Unmanaged.passRetained(buffer)
  }
}
