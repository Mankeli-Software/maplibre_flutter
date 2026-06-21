import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/maplibre_flutter_core_bindings_generated.dart' as bindings;

/// A camera read back from the native core.
///
/// Plain record — `maplibre_flutter_core` has no Flutter dependency, so it does
/// not use the platform interface's `MapCamera`; the desktop implementation
/// packages adapt between the two.
typedef CoreCamera = ({
  double latitude,
  double longitude,
  double zoom,
  double bearing,
  double pitch,
});

/// A handle to one off-screen MapLibre map rendered by mbgl-core.
///
/// Shared by the desktop implementation packages (macOS now; Windows/Linux
/// later) over the C ABI shim (see `src/maplibre_flutter_core.h`). Rendering is
/// synchronous in M1; the macOS package drives it off the UI isolate and bridges
/// frames into a Flutter texture (CLAUDE.md §5c, §8 M2). Call [dispose] to free
/// native resources.
class MapLibreCoreMap {
  MapLibreCoreMap._(this._handle, this._width, this._height);

  final ffi.Pointer<bindings.MblMap> _handle;
  int _width;
  int _height;
  bool _disposed = false;

  /// Frame width in device pixels.
  int get width => _width;

  /// Frame height in device pixels.
  int get height => _height;

  /// Address of the native `MblMap*`, for handing to a platform plugin's texture
  /// bridge over the registrar channel (CLAUDE.md §3): the plugin reads frames
  /// with [copyFrameFunctionAddress] and registers the frame-ready callback via
  /// [setFrameCallbackFunctionAddress], both against this handle. Treat as opaque.
  int get nativeAddress => _handle.address;

  /// Address of the native `mbl_map_copy_frame` function. A platform plugin
  /// calls it directly (reusing Dart's resolved symbol rather than re-looking it
  /// up in the bundled framework, which is brittle across packaging layouts).
  static int get copyFrameFunctionAddress =>
      ffi.Native.addressOf<
            ffi.NativeFunction<
              ffi.Int Function(
                ffi.Pointer<bindings.MblMap>,
                ffi.Pointer<ffi.Uint8>,
                ffi.Size,
                ffi.Pointer<ffi.Uint32>,
                ffi.Pointer<ffi.Uint32>,
                ffi.Pointer<ffi.Uint32>,
              )
            >
          >(bindings.mbl_map_copy_frame)
          .address;

  /// Address of the native `mbl_map_current_iosurface` function. The macOS
  /// plugin calls it from `copyPixelBuffer` to get the IOSurface backing the
  /// latest zero-copy frame (null when zero-copy is off), wrapping it in a
  /// CVPixelBuffer with no copy. See [copyFrameFunctionAddress].
  static int get currentIOSurfaceFunctionAddress =>
      ffi.Native.addressOf<
            ffi.NativeFunction<
              ffi.Pointer<ffi.Void> Function(ffi.Pointer<bindings.MblMap>)
            >
          >(bindings.mbl_map_current_iosurface)
          .address;

  /// Address of the native `mbl_map_set_frame_callback` function (see
  /// [copyFrameFunctionAddress]).
  static int get setFrameCallbackFunctionAddress =>
      ffi.Native.addressOf<
            ffi.NativeFunction<
              ffi.Void Function(
                ffi.Pointer<bindings.MblMap>,
                ffi.Pointer<
                  ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>
                >,
                ffi.Pointer<ffi.Void>,
              )
            >
          >(bindings.mbl_map_set_frame_callback)
          .address;

  /// Address of the native `mbl_map_current_gl_image` function. The Linux plugin
  /// calls it from `FlTextureGL.populate` to get the dmabuf descriptor for the
  /// latest zero-copy frame (returns 0 when zero-copy is off). See
  /// [copyFrameFunctionAddress].
  static int get currentGlImageFunctionAddress =>
      ffi.Native.addressOf<
            ffi.NativeFunction<
              ffi.Int Function(
                ffi.Pointer<bindings.MblMap>,
                ffi.Pointer<bindings.MblGlDmabufFrame>,
              )
            >
          >(bindings.mbl_map_current_gl_image)
          .address;

  /// Address of the native `mbl_map_current_d3d_handle` function. The Windows
  /// plugin calls it from its `GpuSurfaceTexture` descriptor callback to get the
  /// DXGI shared handle for the latest zero-copy frame (returns 0 when zero-copy
  /// is off). See [copyFrameFunctionAddress].
  static int get currentD3dHandleFunctionAddress =>
      ffi.Native.addressOf<
            ffi.NativeFunction<
              ffi.Int Function(
                ffi.Pointer<bindings.MblMap>,
                ffi.Pointer<ffi.Pointer<ffi.Void>>,
                ffi.Pointer<ffi.Uint32>,
                ffi.Pointer<ffi.Uint32>,
              )
            >
          >(bindings.mbl_map_current_d3d_handle)
          .address;

  /// Creates an off-screen map of [width]x[height] device pixels at
  /// [pixelRatio], loading [styleUri]. Throws if the native map cannot be made.
  ///
  /// [continuous] selects the render mode: false (default) renders one complete
  /// frame per change (Static — simple, blocks on tile loads; used by headless
  /// tests); true renders partial frames immediately and refines as tiles stream
  /// in (Continuous — smooth over uncached/detailed tiles, like the mobile SDK).
  static MapLibreCoreMap create({
    required int width,
    required int height,
    required double pixelRatio,
    required String styleUri,
    bool continuous = false,
  }) {
    final stylePtr = styleUri.toNativeUtf8();
    try {
      final handle = bindings.mbl_map_create(
        width,
        height,
        pixelRatio,
        stylePtr.cast(),
        continuous ? 1 : 0,
      );
      if (handle == ffi.nullptr) {
        throw StateError('mbl_map_create failed for style "$styleUri"');
      }
      return MapLibreCoreMap._(handle, width, height);
    } finally {
      malloc.free(stylePtr);
    }
  }

  /// Enables (or disables) zero-copy presentation. When on, each render GPU-blits
  /// mbgl's frame into a shared texture (no CPU readback): an IOSurface on macOS
  /// (read via [currentIOSurfaceFunctionAddress]) or an EGLImage on Linux (read via
  /// [currentGlImageFunctionAddress]). A no-op if the platform helper can't
  /// initialise; the CPU [copyFrame] path stays available as a fallback. Takes
  /// effect on the next render (so confirm with [isZeroCopyActive] after a frame).
  void setZeroCopy(bool enabled) {
    _checkAlive();
    bindings.mbl_map_set_zero_copy(_handle, enabled ? 1 : 0);
  }

  /// Whether the Linux GL zero-copy presenter is live — true once
  /// [setZeroCopy](true) has been processed on the render thread and the EGLImage
  /// presenter initialised (its EGLDisplay is then non-null). Lets the Linux
  /// controller confirm zero-copy actually activated before committing to the
  /// `FlTextureGL` path, and fall back to the CPU texture otherwise. Always false
  /// on platforms without the GL presenter (e.g. macOS).
  bool isZeroCopyActive() {
    _checkAlive();
    // Linux reports via the GL presenter, Windows via the D3D presenter; the
    // other returns 0 on each platform, so OR-ing them is correct everywhere.
    return bindings.mbl_map_gl_active(_handle) != 0 ||
        bindings.mbl_map_d3d_active(_handle) != 0;
  }

  /// Selects the byte order [copyFrame] emits: true = BGRA (default; macOS
  /// CVPixelBuffer), false = RGBA (Linux `FlPixelBufferTexture`). No effect on
  /// the zero-copy IOSurface path. Set once at setup.
  void setPixelFormatBgra(bool bgra) {
    _checkAlive();
    bindings.mbl_map_set_pixel_format_bgra(_handle, bgra ? 1 : 0);
  }

  /// Replaces the active style (URL, file path, or inline JSON).
  void setStyle(String styleUri) {
    _checkAlive();
    final p = styleUri.toNativeUtf8();
    try {
      bindings.mbl_map_set_style(_handle, p.cast());
    } finally {
      malloc.free(p);
    }
  }

  /// Jumps the camera (no animation in M1).
  void setCamera({
    required double latitude,
    required double longitude,
    double zoom = 0,
    double bearing = 0,
    double pitch = 0,
  }) {
    _checkAlive();
    bindings.mbl_map_set_camera(
      _handle,
      latitude,
      longitude,
      zoom,
      bearing,
      pitch,
    );
  }

  /// Reads the last-set camera.
  CoreCamera getCamera() {
    _checkAlive();
    return using((arena) {
      final lat = arena<ffi.Double>();
      final lng = arena<ffi.Double>();
      final zoom = arena<ffi.Double>();
      final bearing = arena<ffi.Double>();
      final pitch = arena<ffi.Double>();
      bindings.mbl_map_get_camera(_handle, lat, lng, zoom, bearing, pitch);
      return (
        latitude: lat.value,
        longitude: lng.value,
        zoom: zoom.value,
        bearing: bearing.value,
        pitch: pitch.value,
      );
    });
  }

  /// Blocks up to [timeout] until at least one frame has rendered, returning
  /// true if a frame is then available. Intended for initial-readiness and
  /// headless/test use — not the per-frame present path.
  bool awaitFrame(Duration timeout) {
    _checkAlive();
    return bindings.mbl_map_await_frame(_handle, timeout.inMilliseconds) != 0;
  }

  /// Resizes the off-screen surface (device pixels) and triggers a re-render.
  void resize(int width, int height) {
    _checkAlive();
    _width = width;
    _height = height;
    bindings.mbl_map_resize(_handle, width, height);
  }

  /// Pans the map by a screen-space delta in device pixels (for the gesture
  /// layer). The camera cache is refreshed so [getCamera] stays accurate.
  void moveBy(double dx, double dy) {
    _checkAlive();
    bindings.mbl_map_move_by(_handle, dx, dy);
  }

  /// Zooms by [scale] (>1 zooms in) about the anchor point in device pixels.
  void scaleBy(double scale, double anchorX, double anchorY) {
    _checkAlive();
    bindings.mbl_map_scale_by(_handle, scale, anchorX, anchorY);
  }

  /// Returns the latest rendered frame as tightly-packed BGRA (premultiplied
  /// alpha) bytes, or null if none is available yet. Non-blocking — the render
  /// thread produces frames asynchronously; use [awaitFrame] to wait for the
  /// first one.
  Uint8List? copyFrame() {
    _checkAlive();
    final capacity = _width * _height * 4;
    final dst = malloc<ffi.Uint8>(capacity);
    try {
      return using((arena) {
        final w = arena<ffi.Uint32>();
        final h = arena<ffi.Uint32>();
        final stride = arena<ffi.Uint32>();
        final ok = bindings.mbl_map_copy_frame(
          _handle,
          dst,
          capacity,
          w,
          h,
          stride,
        );
        if (ok == 0) return null;
        final length = stride.value * h.value;
        // Copy out of native memory before it is freed.
        return Uint8List.fromList(dst.asTypedList(length));
      });
    } finally {
      malloc.free(dst);
    }
  }

  /// Debug/verification: writes the latest frame to a PNG at [path] using
  /// mbgl's encoder. Returns true on success. Not part of the render path.
  bool writePng(String path) {
    _checkAlive();
    final p = path.toNativeUtf8();
    try {
      return bindings.mbl_map_write_png(_handle, p.cast()) != 0;
    } finally {
      malloc.free(p);
    }
  }

  /// Frees the native map. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    bindings.mbl_map_destroy(_handle);
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('MapLibreCoreMap used after dispose()');
    }
  }
}
