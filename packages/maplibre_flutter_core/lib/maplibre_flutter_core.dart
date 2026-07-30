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

  // Reused native scratch buffers for [projectBatch], grown on demand and freed
  // in [dispose], so the per-frame projection path allocates nothing.
  ffi.Pointer<ffi.Double> _projIn = ffi.nullptr;
  ffi.Pointer<ffi.Double> _projOut = ffi.nullptr;
  ffi.Pointer<ffi.Int> _projVis = ffi.nullptr;
  int _projCapacity = 0; // in points

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

  /// Loads a binary glTF (`.glb`) from [path] and draws it anchored at
  /// [latitude]/[longitude] as a layer named [layerId] (re-using an id replaces
  /// the previous model).
  ///
  /// [scale] multiplies the model's own units, so 1.0 renders a glTF authored in
  /// metres at life size and the model keeps its ground footprint across zooms.
  /// [headingDegrees] yaws it clockwise from north (a glTF's -Z "forward" faces
  /// north at 0); [spinDegreesPerSecond] adds a continuous yaw on top.
  ///
  /// Throws [ArgumentError] if the file cannot be loaded, with the native
  /// reason. The file is parsed synchronously on the calling isolate — only the
  /// GPU upload is deferred — so expect this to block for a file read.
  ///
  /// Supported subset, bounded by what mbgl's built-in geometry shader can draw:
  /// triangles, POSITION + TEXCOORD_0, node transforms baked in, all primitives
  /// merged, the first base-colour texture and factor used. No skins or
  /// animations, no Draco/meshopt, no external buffers or images, and at most
  /// 65535 vertices (mbgl's indices are uint16). There is no lighting, so bake
  /// it into the texture and animate by moving rather than deforming.
  ///
  /// Call after the style has loaded — changing the style drops the layer.
  void addModel({
    required String layerId,
    required String path,
    required double latitude,
    required double longitude,
    double scale = 1,
    double headingDegrees = 0,
    double spinDegreesPerSecond = 0,
  }) {
    _checkAlive();
    const errorCapacity = 512;
    final layerPtr = layerId.toNativeUtf8();
    final pathPtr = path.toNativeUtf8();
    final errPtr = malloc<ffi.Char>(errorCapacity);
    try {
      final ok = bindings.mbl_map_add_model(
        _handle,
        layerPtr.cast(),
        pathPtr.cast(),
        latitude,
        longitude,
        scale,
        headingDegrees,
        spinDegreesPerSecond,
        errPtr,
        errorCapacity,
      );
      if (ok == 0) {
        throw ArgumentError(
          'failed to load model "$path": ${errPtr.cast<Utf8>().toDartString()}',
        );
      }
    } finally {
      malloc.free(layerPtr);
      malloc.free(pathPtr);
      malloc.free(errPtr);
    }
  }

  /// Adds the 3D-model spike's test mesh — a spinning, per-face-coloured
  /// pyramid — anchored at [latitude]/[longitude].
  ///
  /// EXPERIMENTAL, and not a stable API: this exists to answer whether an mbgl
  /// [CustomDrawableLayer] renders and depth-occludes on each tier. Expect it to
  /// be replaced by a real model API (caller-supplied mesh + texture).
  ///
  /// Asynchronous — the layer is added on the render thread. Call after the
  /// style has loaded; changing the style drops the layer.
  void addTestModel({
    required double latitude,
    required double longitude,
    double metresPerUnit = 50,
    double spinDegreesPerSecond = 90,
  }) {
    _checkAlive();
    bindings.mbl_map_add_test_model(
      _handle,
      latitude,
      longitude,
      metresPerUnit,
      spinDegreesPerSecond,
    );
  }

  /// Asks mbgl for one more frame.
  ///
  /// Continuous mode is update-driven, not vsync-driven: with nothing
  /// invalidating the map an animated layer renders once and stops. Anything
  /// driving an animation must pump this (e.g. from a [Ticker]).
  void triggerRepaint() {
    _checkAlive();
    bindings.mbl_map_trigger_repaint(_handle);
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

  /// Projects [count] geographic points — read interleaved as
  /// `[lat0, lng0, lat1, lng1, …]` from the first `2 * count` entries of
  /// [inLatLng] — to screen positions written into the first `2 * count` entries
  /// of [outXy] (`[x0, y0, …]`), in one FFI call. Passing [count] explicitly lets
  /// callers reuse over-sized buffers across frames. Positions are logical points,
  /// top-left origin (the same screen space as [moveBy]/[scaleBy], i.e. Flutter's
  /// widget box). When [visible] is given, its first [count] entries are set to 1
  /// for points in front of the camera and 0 for points behind it on a pitched view.
  ///
  /// Returns the projection generation used — a counter that bumps on every
  /// camera change — or 0 if no camera/transform exists yet (in which case
  /// nothing is written). Reuses native scratch buffers, so the hot path does no
  /// allocation. [outXy] (and [visible], if given) must be at least [count] long.
  int projectBatch(int count, Float64List inLatLng, Float64List outXy,
      {Int32List? visible}) {
    _checkAlive();
    if (count <= 0) return bindings.mbl_map_proj_generation(_handle);
    _ensureProjCapacity(count);
    _projIn.asTypedList(count * 2).setRange(0, count * 2, inLatLng);
    final gen = bindings.mbl_map_pixels_for_lat_lngs(
      _handle,
      _projIn,
      count,
      _projOut,
      visible != null ? _projVis : ffi.nullptr,
    );
    if (gen == 0) return 0;
    outXy.setRange(0, count * 2, _projOut.asTypedList(count * 2));
    if (visible != null) {
      for (var i = 0; i < count; i++) {
        visible[i] = _projVis[i]; // Pointer<Int> has no asTypedList; index it.
      }
    }
    return gen;
  }

  /// Projects a single geographic point to a screen position (logical points,
  /// top-left origin), with a [visible] flag (false = behind a pitched camera).
  /// Null if no camera/transform exists yet.
  ({double x, double y, bool visible})? project(double latitude, double longitude) {
    _checkAlive();
    return using((arena) {
      final x = arena<ffi.Double>();
      final y = arena<ffi.Double>();
      final vis = arena<ffi.Int>();
      final ok = bindings.mbl_map_pixel_for_lat_lng(
        _handle,
        latitude,
        longitude,
        x,
        y,
        vis,
      );
      if (ok == 0) return null;
      return (x: x.value, y: y.value, visible: vis.value != 0);
    });
  }

  /// Inverse projection: the geographic point under a screen position (logical
  /// points, top-left origin), for hit-testing a tap or dragging a marker. Null
  /// if no camera/transform exists yet.
  ({double latitude, double longitude})? unproject(double x, double y) {
    _checkAlive();
    return using((arena) {
      final lat = arena<ffi.Double>();
      final lng = arena<ffi.Double>();
      final ok = bindings.mbl_map_lat_lng_for_pixel(_handle, x, y, lat, lng);
      if (ok == 0) return null;
      return (latitude: lat.value, longitude: lng.value);
    });
  }

  /// The current projection generation — a counter that bumps on every camera
  /// change (0 before the first frame). Lets a caller cheaply detect whether a
  /// reprojection is needed.
  int get projectionGeneration {
    _checkAlive();
    return bindings.mbl_map_proj_generation(_handle);
  }

  void _ensureProjCapacity(int count) {
    if (count <= _projCapacity) return;
    if (_projIn != ffi.nullptr) malloc.free(_projIn);
    if (_projOut != ffi.nullptr) malloc.free(_projOut);
    if (_projVis != ffi.nullptr) malloc.free(_projVis);
    _projIn = malloc<ffi.Double>(count * 2);
    _projOut = malloc<ffi.Double>(count * 2);
    _projVis = malloc<ffi.Int>(count);
    _projCapacity = count;
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
    if (_projIn != ffi.nullptr) malloc.free(_projIn);
    if (_projOut != ffi.nullptr) malloc.free(_projOut);
    if (_projVis != ffi.nullptr) malloc.free(_projVis);
    bindings.mbl_map_destroy(_handle);
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('MapLibreCoreMap used after dispose()');
    }
  }
}
