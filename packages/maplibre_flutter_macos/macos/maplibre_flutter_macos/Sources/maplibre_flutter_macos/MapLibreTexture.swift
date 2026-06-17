import CoreVideo
import FlutterMacOS
import Foundation

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

// Invoked as a C function pointer on the core's render thread when a frame is
// ready. `user` is the MapLibreTexture passed unretained at registration.
private let mblFrameReady: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
  user in
  guard let user = user else { return }
  Unmanaged<MapLibreTexture>.fromOpaque(user).takeUnretainedValue().onFrameReady()
}

/// Bridges one core `MblMap*`'s rendered frames into a Flutter `Texture`
/// (CPU readback, CLAUDE.md §8 M2). The render thread calls `onFrameReady`;
/// Flutter then pulls `copyPixelBuffer`, which sizes itself to the current frame
/// (so it follows core resizes) and copies the latest BGRA frame out.
final class MapLibreTexture: NSObject, FlutterTexture {
  private let mapHandle: UnsafeMutableRawPointer
  private weak var registry: FlutterTextureRegistry?
  private var textureId: Int64 = 0

  private let copyFrameFn: CopyFrameFn
  private let setFrameCallbackFn: SetFrameCallbackFn

  // Reused IOSurface-backed buffer pool (recreated only on size change) so we
  // don't allocate a fresh CVPixelBuffer every frame; the pool recycles buffers
  // freed by the engine, which also avoids tearing. (CLAUDE.md §8 M5.)
  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0

  init(
    mapHandle: UnsafeMutableRawPointer, copyFrameAddress: Int,
    setFrameCallbackAddress: Int, registry: FlutterTextureRegistry
  ) {
    self.mapHandle = mapHandle
    self.copyFrameFn = unsafeBitCast(
      UnsafeMutableRawPointer(bitPattern: copyFrameAddress)!, to: CopyFrameFn.self)
    self.setFrameCallbackFn = unsafeBitCast(
      UnsafeMutableRawPointer(bitPattern: setFrameCallbackAddress)!,
      to: SetFrameCallbackFn.self)
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
    // Query the current frame size first (null dst), so the buffer always
    // matches the core's render surface even after a resize.
    var w: UInt32 = 0
    var h: UInt32 = 0
    var stride: UInt32 = 0
    guard copyFrameFn(mapHandle, nil, 0, &w, &h, &stride) != 0, w > 0, h > 0
    else { return nil }
    let width = Int(w)
    let height = Int(h)

    guard let pool = pixelBufferPool(width: width, height: height) else {
      return nil
    }
    var pixelBuffer: CVPixelBuffer?
    guard
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        == kCVReturnSuccess, let buffer = pixelBuffer
    else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let base = CVPixelBufferGetBaseAddress(buffer)?
        .assumingMemoryBound(to: UInt8.self)
    else { return nil }

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
    if ok == 0 { return nil }
    return Unmanaged.passRetained(buffer)
  }
}
