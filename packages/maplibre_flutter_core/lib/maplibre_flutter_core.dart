import 'dart:convert';
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

/// What a [CoreDiagnostic] is about.
///
/// Mirrors `MblDiagnosticKind` in `src/maplibre_flutter_core.h`; the [code]
/// values are part of the C ABI. ffigen is configured with
/// `enums: Enums.excludeAll`, so the mapping is written out here rather than
/// generated — `diagnosticKindMatchesTheHeader` in the native test pins it.
enum CoreDiagnosticKind {
  /// A style finished loading — **every** time, not just the first. A style
  /// load drops every app-added source and layer, so this is when to re-apply
  /// them.
  styleLoaded(0),

  /// The style and its initial resources are all in.
  mapLoaded(1),

  /// The style could not be loaded or parsed.
  mapLoadFailed(2),

  /// Nothing left to draw or fetch.
  idle(3),

  /// A layer asked for an image the style does not have; the message is its id.
  styleImageMissing(4),

  /// A glyph range could not be loaded.
  glyphsError(5),

  /// A sprite could not be loaded.
  spriteError(6),

  /// The renderer raised.
  renderError(7),

  /// An mbgl log record. This is the one that catches a glyph 404 — mbgl logs
  /// that rather than routing it to the observer.
  log(8),

  /// A command the core accepted could not be applied — removing a layer that
  /// is not there, removing a source a layer still uses, or posting anything at
  /// all before the render thread is up. Every mutating call is posted and
  /// returns void, so this is the only way to hear about it.
  commandFailed(9);

  const CoreDiagnosticKind(this.code);

  /// The `MblDiagnosticKind` value.
  final int code;

  /// The kind for [code], or [CoreDiagnosticKind.log] for anything unknown —
  /// a newer core must not crash an older binding.
  static CoreDiagnosticKind fromCode(int code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return CoreDiagnosticKind.log;
  }
}

/// How bad it is. Mirrors `MblDiagnosticSeverity`, itself `mbgl::EventSeverity`.
enum CoreDiagnosticSeverity {
  debug(0),
  info(1),
  warning(2),
  error(3);

  const CoreDiagnosticSeverity(this.code);

  /// The `MblDiagnosticSeverity` value.
  final int code;

  /// The severity for [code], or [CoreDiagnosticSeverity.error] for anything
  /// unknown — an unrecognised severity is not a reason to drop a report.
  static CoreDiagnosticSeverity fromCode(int code) {
    for (final severity in values) {
      if (severity.code == code) return severity;
    }
    return CoreDiagnosticSeverity.error;
  }
}

/// One thing the engine reported.
typedef CoreDiagnostic = ({
  CoreDiagnosticKind kind,
  CoreDiagnosticSeverity severity,
  String message,
});

/// A geographic point, as a record — this package has no Flutter dependency, so
/// it cannot use the platform interface's `LatLng`.
typedef CoreLatLng = ({double latitude, double longitude});

/// A geographic box: south-west and north-east corners, latitude first, per
/// `mbgl::LatLngBounds`.
typedef CoreLatLngBounds = ({
  double swLat,
  double swLng,
  double neLat,
  double neLng,
});

/// A **partial** camera: an unset field is left alone by the engine.
///
/// Mirrors `mbgl::CameraOptions`, whose fields are all `std::optional`. The
/// partiality is the point — "zoom to 12 and leave the rest" must not require
/// reading the camera first, which races the render thread.
class CoreCameraOptions {
  const CoreCameraOptions({
    this.center,
    this.zoom,
    this.bearing,
    this.pitch,
    this.roll,
    this.padding,
    this.anchor,
  });

  final CoreLatLng? center;
  final double? zoom;
  final double? bearing;
  final double? pitch;
  final double? roll;
  final ({double top, double right, double bottom, double left})? padding;

  /// The screen point that stays fixed while zoom/bearing change, in logical
  /// points from the TOP-LEFT.
  ///
  /// **mbgl discards this whenever [center] is set** — so never set both. A
  /// test anchored on the map centre cannot detect the difference, because the
  /// centre is a fixed point either way.
  final ({double x, double y})? anchor;

  /// Whether this would change nothing.
  bool get isEmpty =>
      center == null &&
      zoom == null &&
      bearing == null &&
      pitch == null &&
      roll == null &&
      padding == null &&
      anchor == null;

  @override
  String toString() =>
      'CoreCameraOptions(center: $center, zoom: $zoom, bearing: $bearing, '
      'pitch: $pitch, roll: $roll, padding: $padding, anchor: $anchor)';
}

/// How to animate a camera transition. Mirrors `mbgl::AnimationOptions`.
class CoreAnimationOptions {
  const CoreAnimationOptions({
    this.duration,
    this.easing,
    this.speed,
    this.apexZoom,
  });

  final Duration? duration;

  /// Cubic bezier control points — mbgl's `UnitBezier`.
  final ({double x1, double y1, double x2, double y2})? easing;

  /// flyTo only: average velocity in screenfuls per second (engine default 1.2).
  final double? speed;

  /// flyTo only: the zoom at the apex of the flight arc.
  final double? apexZoom;
}

/// How a camera transition is applied.
enum CoreCameraTransition {
  /// Instant.
  jump(0),

  /// Straight, eased.
  ease(1),

  /// The van Wijk flight path — zoom out, pan, zoom back in.
  fly(2);

  const CoreCameraTransition(this.code);
  final int code;
}

/// Camera constraints. Mirrors `mbgl::BoundOptions`.
class CoreBoundOptions {
  const CoreBoundOptions({
    this.bounds,
    this.minZoom,
    this.maxZoom,
    this.minPitch,
    this.maxPitch,
  });

  /// Constrains the camera CENTRE unless the constrain mode is
  /// [CoreConstrainMode.screen] — Android's semantics, not gl-js's.
  final CoreLatLngBounds? bounds;
  final double? minZoom;
  final double? maxZoom;
  final double? minPitch;

  /// mbgl clamps pitch to 60 degrees regardless of this.
  final double? maxPitch;

  @override
  String toString() =>
      'CoreBoundOptions(bounds: $bounds, minZoom: $minZoom, maxZoom: $maxZoom, '
      'minPitch: $minPitch, maxPitch: $maxPitch)';
}

/// What a camera bound constrains. Mirrors `mbgl::ConstrainMode`.
enum CoreConstrainMode {
  none(0),
  heightOnly(1),
  widthAndHeight(2),

  /// The whole viewport must stay inside the bounds — what gl-js `maxBounds`
  /// means, and what Apple calls `maximumScreenBounds`.
  screen(3);

  const CoreConstrainMode(this.code);
  final int code;
}

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
    double elevationMetres = 0,
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
        elevationMetres,
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

  /// Moves or re-orients an existing model WITHOUT touching its uploaded
  /// geometry — the only sane way to animate one along a path, since re-adding
  /// would re-parse the whole `.glb` every frame.
  ///
  /// A no-op if [layerId] names no model.
  void setModelTransform({
    required String layerId,
    required double latitude,
    required double longitude,
    double scale = 1,
    double headingDegrees = 0,
    double elevationMetres = 0,
  }) {
    _checkAlive();
    final p = layerId.toNativeUtf8();
    try {
      bindings.mbl_map_set_model_transform(
        _handle,
        p.cast(),
        latitude,
        longitude,
        scale,
        headingDegrees,
        elevationMetres,
      );
    } finally {
      malloc.free(p);
    }
  }

  /// Frames the render thread has published since creation.
  ///
  /// Difference it over time for the MAP's frame rate. A Flutter `Ticker`
  /// measures Flutter's vsync, which stays pinned at the display rate however far
  /// behind the map falls, because the map is composited as a texture.
  int get renderedFrameCount {
    _checkAlive();
    return bindings.mbl_map_frame_count(_handle);
  }

  /// How many drawables (draw calls) one instance of the model at [path] costs,
  /// or null if it has not been loaded yet.
  static int? modelPartCount(String path) {
    final p = path.toNativeUtf8();
    try {
      final n = bindings.mbl_model_part_count(p.cast());
      return n == 0 ? null : n;
    } finally {
      malloc.free(p);
    }
  }

  /// Removes a model layer added by [addModel]. A no-op if [layerId] names no
  /// layer.
  void removeModel(String layerId) {
    _checkAlive();
    final p = layerId.toNativeUtf8();
    try {
      bindings.mbl_map_remove_model(_handle, p.cast());
    } finally {
      malloc.free(p);
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
    double elevationMetres = 0,
  }) {
    _checkAlive();
    bindings.mbl_map_add_test_model(
      _handle,
      latitude,
      longitude,
      metresPerUnit,
      spinDegreesPerSecond,
      elevationMetres,
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

  // --- Style sources / layers / images ---------------------------------------
  //
  // Engine-drawn data, for point sets far past what one-widget-per-point can
  // carry. Because mbgl renders these with the map itself they are glued to it
  // by construction, and clustering is built in (`cluster: true` on a geojson
  // source runs supercluster inside the engine).
  //
  // The argument is MapLibre Style Spec JSON — the same documents
  // maplibre-gl-js takes — so expressions, filters and data-driven styling all
  // work without extra API here.
  //
  // The typed layer/source API generated from the vendored style spec lives a
  // level up, in `maplibre_flutter` (`CircleLayer`, `GeoJsonSource`, `Expr` —
  // see docs/typed-style-api.md); it serialises straight to these methods, so
  // raw JSON stays the right primitive here and needs no C ABI counterpart.
  // TODO(typed-style-api): typed coverage up there is the `circle` layer and the
  // `geojson` source so far.

  /// Adds a style source under [id]. Throws [ArgumentError] if [json] is not a
  /// valid source document (reported synchronously — parsing needs no map).
  void addSourceJson(String id, String json) {
    _checkAlive();
    _styleCall(
      (idPtr, jsonPtr, err) =>
          bindings.mbl_map_add_source_json(_handle, idPtr, jsonPtr, err, 512),
      id,
      json,
      'source',
    );
  }

  /// Adds a style layer. [beforeId] inserts it beneath an existing layer (draw
  /// order); null appends on top. Throws [ArgumentError] on invalid JSON.
  void addLayerJson(String json, {String? beforeId}) {
    _checkAlive();
    using((arena) {
      final jsonPtr = json.toNativeUtf8(allocator: arena).cast<ffi.Char>();
      final beforePtr = beforeId == null
          ? ffi.nullptr
          : beforeId.toNativeUtf8(allocator: arena).cast<ffi.Char>();
      final err = arena<ffi.Char>(512);
      final ok = bindings.mbl_map_add_layer_json(
        _handle,
        jsonPtr,
        beforePtr,
        err,
        512,
      );
      if (ok == 0) {
        throw ArgumentError(
          'invalid layer JSON: ${err.cast<Utf8>().toDartString()}',
        );
      }
    });
  }

  /// Replaces the data of an existing geojson source — the cheap path for
  /// dynamic datasets (mbgl re-tiles and re-clusters; no layer rebuild).
  void setGeoJsonData(String sourceId, String geoJson) {
    _checkAlive();
    _styleCall(
      (idPtr, jsonPtr, err) =>
          bindings.mbl_map_set_geojson_data(_handle, idPtr, jsonPtr, err, 512),
      sourceId,
      geoJson,
      'geojson',
    );
  }

  void removeLayer(String id) {
    _checkAlive();
    using((arena) {
      bindings.mbl_map_remove_layer(
        _handle,
        id.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
      );
    });
  }

  void removeSource(String id) {
    _checkAlive();
    using((arena) {
      bindings.mbl_map_remove_source(
        _handle,
        id.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
      );
    });
  }

  /// Style-wide transition behaviour.
  ///
  /// [duration] and [delay] default to the style document's own values (mbgl
  /// uses 300 ms / 0) when null.
  ///
  /// [placementTransitions] `false` stops **symbol** layers fading in and out.
  /// That fade is why a cluster's count label outlives its circle by ~300 ms: a
  /// circle is a feature that simply stops being drawn, while a symbol ramps its
  /// opacity over the transition duration. Turning it off makes them vanish
  /// together — at the cost of the basemap's own labels popping rather than
  /// fading, since this is a property of the style, not of one layer.
  ///
  /// Sticky: re-applied after every style load, which would otherwise reset it.
  /// Only honoured in Continuous mode; mbgl ignores transitions in Static.
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions = true,
  }) {
    _checkAlive();
    bindings.mbl_map_set_transition_options(
      _handle,
      duration?.inMilliseconds ?? -1,
      delay?.inMilliseconds ?? -1,
      placementTransitions ? 1 : 0,
    );
  }

  /// Registers an icon for use as `icon-image` in a symbol layer, from raw
  /// premultiplied RGBA (`width * height * 4` bytes).
  ///
  /// This is how a Flutter widget becomes an engine-drawn marker: paint the
  /// widget to an image, pass its bytes here, and reference [id] from the
  /// layer. [pixelRatio] is the bitmap's scale (2 for @2x); [sdf] makes it a
  /// signed-distance-field icon the style can recolour and scale.
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) {
    _checkAlive();
    final expected = width * height * 4;
    if (rgba.length < expected) {
      throw ArgumentError(
        'rgba is ${rgba.length} bytes, expected $expected for ${width}x$height',
      );
    }
    using((arena) {
      final buf = arena<ffi.Uint8>(expected);
      buf.asTypedList(expected).setRange(0, expected, rgba);
      bindings.mbl_map_add_image(
        _handle,
        id.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
        buf,
        width,
        height,
        pixelRatio,
        sdf ? 1 : 0,
      );
    });
  }

  void removeImage(String id) {
    _checkAlive();
    using((arena) {
      bindings.mbl_map_remove_image(
        _handle,
        id.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
      );
    });
  }

  /// Shared marshalling for the (id, json) -> int style calls.
  void _styleCall(
    int Function(
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    )
    call,
    String id,
    String json,
    String what,
  ) {
    using((arena) {
      final err = arena<ffi.Char>(512);
      final ok = call(
        id.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
        json.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
        err,
      );
      if (ok == 0) {
        throw ArgumentError(
          'invalid $what JSON: ${err.cast<Utf8>().toDartString()}',
        );
      }
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

  /// Turns the map CONTENT clockwise by [degrees] about the anchor.
  ///
  /// The anchor is in the same space as [scaleBy]: logical points, top-left
  /// origin, passed to mbgl unflipped. (Note this is the opposite of the
  /// projection methods, which do flip — see the C header.)
  void rotateBy(double degrees, double anchorX, double anchorY) {
    _checkAlive();
    bindings.mbl_map_rotate_by(_handle, degrees, anchorX, anchorY);
  }

  /// Tilts by [degrees] (positive tilts toward the horizon) about the viewport
  /// centre. Clamped natively to 0..60, so callers need no clamp of their own.
  void pitchBy(double degrees) {
    _checkAlive();
    bindings.mbl_map_pitch_by(_handle, degrees);
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
  ///
  /// [generation] selects which transform to project against: 0 (the default)
  /// uses the newest, while passing [presentedGeneration] projects against the
  /// frame currently on screen — see that getter for why that is what anchored
  /// widgets want.
  int projectBatch(
    int count,
    Float64List inLatLng,
    Float64List outXy, {
    Int32List? visible,
    int generation = 0,
  }) {
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
      generation,
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
  ({double x, double y, bool visible})? project(
    double latitude,
    double longitude, {
    int generation = 0,
  }) {
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
        generation,
      );
      if (ok == 0) return null;
      return (x: x.value, y: y.value, visible: vis.value != 0);
    });
  }

  /// Inverse projection: the geographic point under a screen position (logical
  /// points, top-left origin), for hit-testing a tap or dragging a marker. Null
  /// if no camera/transform exists yet.
  ({double latitude, double longitude})? unproject(
    double x,
    double y, {
    int generation = 0,
  }) {
    _checkAlive();
    return using((arena) {
      final lat = arena<ffi.Double>();
      final lng = arena<ffi.Double>();
      final ok = bindings.mbl_map_lat_lng_for_pixel(
        _handle,
        x,
        y,
        lat,
        lng,
        generation,
      );
      if (ok == 0) return null;
      return (latitude: lat.value, longitude: lng.value);
    });
  }

  /// The features the engine actually DREW inside a screen-space box (logical
  /// points, top-left origin — the same space as [project] and [moveBy]).
  ///
  /// Returns a GeoJSON `FeatureCollection` string, or null if the query failed
  /// or timed out. For a clustered geojson source this returns supercluster's
  /// **cluster features**, carrying `point_count` and their real positions —
  /// information that lives inside the engine and cannot be recomputed in Dart.
  ///
  /// Restrict the query with [layerIds]. Runs on the render thread and waits up
  /// to [timeout]; a busy renderer therefore costs a dropped query rather than a
  /// stalled caller.
  String? queryRenderedFeatures(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
    Duration timeout = const Duration(milliseconds: 200),
  }) {
    _checkAlive();
    return using((arena) {
      final layers = layerIds == null || layerIds.isEmpty
          ? ffi.nullptr
          : layerIds.join(',').toNativeUtf8(allocator: arena).cast<ffi.Char>();
      final out = bindings.mbl_map_query_rendered_features(
        _handle,
        minX,
        minY,
        maxX,
        maxY,
        layers,
        timeout.inMilliseconds,
      );
      if (out == ffi.nullptr) return null;
      try {
        return out.cast<Utf8>().toDartString();
      } finally {
        // Native-allocated; must go back through the library's own free.
        bindings.mbl_string_free(out);
      }
    });
  }

  /// The projection generation of the frame currently ON SCREEN.
  ///
  /// Camera commands are applied asynchronously on the core's render thread, so
  /// [projectionGeneration] (the newest transform) usually runs ahead of the
  /// frame the compositor is showing. Projecting anchored widgets against the
  /// newest transform therefore makes them swim against the map while it moves;
  /// projecting against this generation keeps them glued to it. 0 before the
  /// first frame.
  int get presentedGeneration {
    _checkAlive();
    return bindings.mbl_map_presented_generation(_handle);
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
    setDiagnosticCallback(null);
    setCameraFinishCallback(null);
    if (_projIn != ffi.nullptr) malloc.free(_projIn);
    if (_projOut != ffi.nullptr) malloc.free(_projOut);
    if (_projVis != ffi.nullptr) malloc.free(_projVis);
    bindings.mbl_map_destroy(_handle);
  }

  // --- Diagnostics ------------------------------------------------------------

  /// The registered native callback, held as a FIELD and not a local.
  ///
  /// CLAUDE.md §5e: a `NativeCallable` that only a local refers to can be
  /// collected while the native side still holds its function pointer, and the
  /// callbacks then stop arriving with no error anywhere. Cleared in [dispose],
  /// which also unregisters it natively first.
  ffi.NativeCallable<
    ffi.Void Function(
      ffi.Pointer<ffi.Void>,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Char>,
    )
  >?
  _diagnosticCallable;

  /// Reports what the engine could not do: a style that 404s, a glyph range the
  /// tile server does not serve, a bad sprite — plus the lifecycle events
  /// ([CoreDiagnosticKind.styleLoaded], [CoreDiagnosticKind.idle]).
  ///
  /// Pass null to stop listening. Replacing an existing listener disposes the
  /// old one.
  ///
  /// [onDiagnostic] runs on the **Dart isolate that called this**, not on the
  /// render thread: the native side fires from wherever the event happened, and
  /// this is a `NativeCallable.listener`, so delivery hops back here. That also
  /// means the native message string has to outlive the native call — it does,
  /// because the shim transfers ownership of a heap copy, which is released
  /// here after decoding.
  void setDiagnosticCallback(void Function(CoreDiagnostic)? onDiagnostic) {
    // Unregister BEFORE closing the old callable, so nothing native is holding
    // a pointer into it.
    if (onDiagnostic == null) {
      if (!_disposed) {
        bindings.mbl_map_set_diagnostic_callback(
          _handle,
          ffi.nullptr,
          ffi.nullptr,
        );
      }
      _diagnosticCallable?.close();
      _diagnosticCallable = null;
      return;
    }
    _checkAlive();
    final previous = _diagnosticCallable;
    final callable =
        ffi.NativeCallable<
          ffi.Void Function(
            ffi.Pointer<ffi.Void>,
            ffi.Int32,
            ffi.Int32,
            ffi.Pointer<ffi.Char>,
          )
        >.listener((
          ffi.Pointer<ffi.Void> user,
          int kind,
          int severity,
          ffi.Pointer<ffi.Char> message,
        ) {
          // Ownership of `message` came with the call; release it whatever the
          // handler does, including throw.
          try {
            onDiagnostic((
              kind: CoreDiagnosticKind.fromCode(kind),
              severity: CoreDiagnosticSeverity.fromCode(severity),
              message: message == ffi.nullptr
                  ? ''
                  : message.cast<Utf8>().toDartString(),
            ));
          } finally {
            if (message != ffi.nullptr) bindings.mbl_string_free(message);
          }
        });
    _diagnosticCallable = callable;
    bindings.mbl_map_set_diagnostic_callback(
      _handle,
      callable.nativeFunction,
      ffi.nullptr,
    );
    previous?.close();
  }

  // --- Layer properties -------------------------------------------------------

  /// Sets one style-spec property on [layerId] by its spec [name].
  ///
  /// [valueJson] is a JSON fragment: `12`, `"#ff0000"`, `["get","population"]`.
  /// Returns false if that JSON is malformed — the one failure knowable without
  /// the render thread. A property the layer does not have is reported
  /// asynchronously on the diagnostic channel instead.
  ///
  /// **One call covers paint, layout, `visibility`, `minzoom`, `maxzoom` and
  /// `filter`**, because `mbgl::style::Layer::setProperty` falls through to each
  /// in turn. gl-js splits these into four methods; the ABI does not need to.
  bool setLayerProperty(String layerId, String name, String valueJson) {
    _checkAlive();
    return using((arena) {
      final err = arena<ffi.Char>(512);
      return bindings.mbl_map_set_layer_property(
            _handle,
            layerId.toNativeUtf8(allocator: arena).cast(),
            name.toNativeUtf8(allocator: arena).cast(),
            valueJson.toNativeUtf8(allocator: arena).cast(),
            err,
            512,
          ) !=
          0;
    });
  }

  /// Moves [layerId] beneath [beforeId], or to the top when [beforeId] is null.
  ///
  /// Cheap: `Style::removeLayer` returns the owning pointer and `addLayer` takes
  /// a `before`, so the layer object survives the move — nothing is re-parsed.
  void moveLayer(String layerId, {String? beforeId}) {
    _checkAlive();
    using((arena) {
      bindings.mbl_map_move_layer(
        _handle,
        layerId.toNativeUtf8(allocator: arena).cast(),
        beforeId == null
            ? ffi.nullptr
            : beforeId.toNativeUtf8(allocator: arena).cast(),
      );
    });
  }

  /// One property of [layerId] as JSON, or null if absent or timed out.
  String? getLayerProperty(
    String layerId,
    String name, {
    Duration timeout = const Duration(milliseconds: 250),
  }) {
    _checkAlive();
    return using((arena) {
      final result = bindings.mbl_map_get_layer_property(
        _handle,
        layerId.toNativeUtf8(allocator: arena).cast(),
        name.toNativeUtf8(allocator: arena).cast(),
        timeout.inMilliseconds,
      );
      if (result == ffi.nullptr) return null;
      final json = result.cast<Utf8>().toDartString();
      bindings.mbl_string_free(result);
      return json;
    });
  }

  /// The style's layer ids, bottom-most first. Null on timeout.
  List<String>? getLayerIds({
    Duration timeout = const Duration(milliseconds: 250),
  }) {
    _checkAlive();
    final result = bindings.mbl_map_get_layer_ids(
      _handle,
      timeout.inMilliseconds,
    );
    if (result == ffi.nullptr) return null;
    final json = result.cast<Utf8>().toDartString();
    bindings.mbl_string_free(result);
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    return decoded.whereType<String>().toList();
  }

  /// One layer as its full style-spec JSON, or null if absent or timed out.
  ///
  /// From `Layer::serialize()`, so it reflects the LIVE layer rather than the
  /// style document as it was loaded.
  String? getLayerJson(
    String layerId, {
    Duration timeout = const Duration(milliseconds: 250),
  }) {
    _checkAlive();
    return using((arena) {
      final result = bindings.mbl_map_get_layer_json(
        _handle,
        layerId.toNativeUtf8(allocator: arena).cast(),
        timeout.inMilliseconds,
      );
      if (result == ffi.nullptr) return null;
      final json = result.cast<Utf8>().toDartString();
      bindings.mbl_string_free(result);
      return json;
    });
  }

  // --- Camera commands --------------------------------------------------------

  /// Fills a native MblCameraOptions from [camera] in arena memory.
  ffi.Pointer<bindings.MblCameraOptions> _toNativeCamera(
    Arena arena,
    CoreCameraOptions camera,
  ) {
    final out = arena<bindings.MblCameraOptions>();
    final c = out.ref;
    final center = camera.center;
    if (center != null) {
      c.has_center = 1;
      c.center_lat = center.latitude;
      c.center_lng = center.longitude;
    }
    if (camera.zoom != null) {
      c.has_zoom = 1;
      c.zoom = camera.zoom!;
    }
    if (camera.bearing != null) {
      c.has_bearing = 1;
      c.bearing = camera.bearing!;
    }
    if (camera.pitch != null) {
      c.has_pitch = 1;
      c.pitch = camera.pitch!;
    }
    if (camera.roll != null) {
      c.has_roll = 1;
      c.roll = camera.roll!;
    }
    final padding = camera.padding;
    if (padding != null) {
      c.has_padding = 1;
      c.padding_top = padding.top;
      c.padding_right = padding.right;
      c.padding_bottom = padding.bottom;
      c.padding_left = padding.left;
    }
    final anchor = camera.anchor;
    if (anchor != null) {
      c.has_anchor = 1;
      c.anchor_x = anchor.x;
      c.anchor_y = anchor.y;
    }
    return out;
  }

  CoreCameraOptions _fromNativeCamera(bindings.MblCameraOptions c) =>
      CoreCameraOptions(
        center: c.has_center != 0
            ? (latitude: c.center_lat, longitude: c.center_lng)
            : null,
        zoom: c.has_zoom != 0 ? c.zoom : null,
        bearing: c.has_bearing != 0 ? c.bearing : null,
        pitch: c.has_pitch != 0 ? c.pitch : null,
        roll: c.has_roll != 0 ? c.roll : null,
        padding: c.has_padding != 0
            ? (
                top: c.padding_top,
                right: c.padding_right,
                bottom: c.padding_bottom,
                left: c.padding_left,
              )
            : null,
        anchor: c.has_anchor != 0 ? (x: c.anchor_x, y: c.anchor_y) : null,
      );

  ffi.Pointer<bindings.MblAnimationOptions> _toNativeAnimation(
    Arena arena,
    CoreAnimationOptions? animation,
  ) {
    final out = arena<bindings.MblAnimationOptions>();
    if (animation == null) return out;
    final a = out.ref;
    final duration = animation.duration;
    if (duration != null) {
      a.has_duration = 1;
      a.duration_ms = duration.inMilliseconds;
    }
    final easing = animation.easing;
    if (easing != null) {
      a.has_easing = 1;
      a.easing_x1 = easing.x1;
      a.easing_y1 = easing.y1;
      a.easing_x2 = easing.x2;
      a.easing_y2 = easing.y2;
    }
    if (animation.speed != null) {
      a.has_speed = 1;
      a.speed = animation.speed!;
    }
    if (animation.apexZoom != null) {
      a.has_apex_zoom = 1;
      a.apex_zoom = animation.apexZoom!;
    }
    return out;
  }

  ffi.Pointer<bindings.MblLatLngBounds> _toNativeBounds(
    Arena arena,
    CoreLatLngBounds bounds,
  ) {
    final out = arena<bindings.MblLatLngBounds>();
    out.ref
      ..sw_lat = bounds.swLat
      ..sw_lng = bounds.swLng
      ..ne_lat = bounds.neLat
      ..ne_lng = bounds.neLng;
    return out;
  }

  /// Applies [camera] instantly. Unset fields are left alone.
  void jumpTo(CoreCameraOptions camera) {
    _checkAlive();
    using((arena) {
      bindings.mbl_map_jump_to(_handle, _toNativeCamera(arena, camera));
    });
  }

  /// Transitions to [camera] along a straight, eased path.
  ///
  /// [token], when non-zero, is reported to the callback registered with
  /// [setCameraFinishCallback] once the transition ends — INCLUDING when it is
  /// superseded, which is mbgl's own behaviour.
  void easeTo(
    CoreCameraOptions camera,
    CoreAnimationOptions? animation, {
    int token = 0,
  }) {
    _checkAlive();
    using((arena) {
      bindings.mbl_map_ease_to(
        _handle,
        _toNativeCamera(arena, camera),
        _toNativeAnimation(arena, animation),
        token,
      );
    });
  }

  /// Transitions to [camera] along a van Wijk flight path.
  void flyTo(
    CoreCameraOptions camera,
    CoreAnimationOptions? animation, {
    int token = 0,
  }) {
    _checkAlive();
    using((arena) {
      bindings.mbl_map_fly_to(
        _handle,
        _toNativeCamera(arena, camera),
        _toNativeAnimation(arena, animation),
        token,
      );
    });
  }

  /// Stops any transition in flight, leaving the camera where it got to.
  void cancelTransitions() {
    _checkAlive();
    bindings.mbl_map_cancel_transitions(_handle);
  }

  /// Frames [bounds] under [padding] and applies the result.
  ///
  /// Computed AND applied on the render thread, in one command: the
  /// computation needs the live transform, so splitting it would mean a
  /// blocking round trip with the camera free to move in between.
  void fitBounds(
    CoreLatLngBounds bounds, {
    ({double top, double right, double bottom, double left}) padding = (
      top: 0,
      right: 0,
      bottom: 0,
      left: 0,
    ),
    double? bearing,
    double? pitch,
    CoreCameraTransition transition = CoreCameraTransition.jump,
    CoreAnimationOptions? animation,
    int token = 0,
  }) {
    _checkAlive();
    using((arena) {
      bindings.mbl_map_fit_bounds(
        _handle,
        _toNativeBounds(arena, bounds),
        padding.top,
        padding.right,
        padding.bottom,
        padding.left,
        bearing == null ? 0 : 1,
        bearing ?? 0,
        pitch == null ? 0 : 1,
        pitch ?? 0,
        transition.code,
        _toNativeAnimation(arena, animation),
        token,
      );
    });
  }

  /// The camera that would frame [bounds], WITHOUT moving — gl-js
  /// `cameraForBounds`. Null on timeout.
  ///
  /// Blocks the caller: the computation needs the live transform, which only
  /// the render thread may touch.
  CoreCameraOptions? cameraForBounds(
    CoreLatLngBounds bounds, {
    ({double top, double right, double bottom, double left}) padding = (
      top: 0,
      right: 0,
      bottom: 0,
      left: 0,
    ),
    double? bearing,
    double? pitch,
    Duration timeout = const Duration(milliseconds: 250),
  }) {
    _checkAlive();
    return using((arena) {
      final out = arena<bindings.MblCameraOptions>();
      final ok = bindings.mbl_map_camera_for_lat_lng_bounds(
        _handle,
        _toNativeBounds(arena, bounds),
        padding.top,
        padding.right,
        padding.bottom,
        padding.left,
        bearing == null ? 0 : 1,
        bearing ?? 0,
        pitch == null ? 0 : 1,
        pitch ?? 0,
        timeout.inMilliseconds,
        out,
      );
      return ok == 0 ? null : _fromNativeCamera(out.ref);
    });
  }

  /// The geographic area currently on screen — gl-js `getBounds`. Null on
  /// timeout. Pass [camera] to ask about a hypothetical camera instead.
  CoreLatLngBounds? getVisibleBounds({
    CoreCameraOptions camera = const CoreCameraOptions(),
    Duration timeout = const Duration(milliseconds: 250),
  }) {
    _checkAlive();
    return using((arena) {
      final out = arena<bindings.MblLatLngBounds>();
      final ok = bindings.mbl_map_lat_lng_bounds_for_camera(
        _handle,
        _toNativeCamera(arena, camera),
        timeout.inMilliseconds,
        out,
      );
      if (ok == 0) return null;
      return (
        swLat: out.ref.sw_lat,
        swLng: out.ref.sw_lng,
        neLat: out.ref.ne_lat,
        neLng: out.ref.ne_lng,
      );
    });
  }

  /// Applies camera constraints. Unset fields are left alone.
  void setBounds(CoreBoundOptions options) {
    _checkAlive();
    using((arena) {
      final out = arena<bindings.MblBoundOptions>();
      final b = out.ref;
      final bounds = options.bounds;
      if (bounds != null) {
        b.has_bounds = 1;
        b.bounds
          ..sw_lat = bounds.swLat
          ..sw_lng = bounds.swLng
          ..ne_lat = bounds.neLat
          ..ne_lng = bounds.neLng;
      }
      if (options.minZoom != null) {
        b.has_min_zoom = 1;
        b.min_zoom = options.minZoom!;
      }
      if (options.maxZoom != null) {
        b.has_max_zoom = 1;
        b.max_zoom = options.maxZoom!;
      }
      if (options.minPitch != null) {
        b.has_min_pitch = 1;
        b.min_pitch = options.minPitch!;
      }
      if (options.maxPitch != null) {
        b.has_max_pitch = 1;
        b.max_pitch = options.maxPitch!;
      }
      bindings.mbl_map_set_bounds(_handle, out);
    });
  }

  /// The current camera constraints. Null on timeout; blocks, as above.
  CoreBoundOptions? getBoundOptions({
    Duration timeout = const Duration(milliseconds: 250),
  }) {
    _checkAlive();
    return using((arena) {
      final out = arena<bindings.MblBoundOptions>();
      final ok = bindings.mbl_map_get_bounds(
        _handle,
        timeout.inMilliseconds,
        out,
      );
      if (ok == 0) return null;
      final b = out.ref;
      return CoreBoundOptions(
        bounds: b.has_bounds != 0
            ? (
                swLat: b.bounds.sw_lat,
                swLng: b.bounds.sw_lng,
                neLat: b.bounds.ne_lat,
                neLng: b.bounds.ne_lng,
              )
            : null,
        minZoom: b.has_min_zoom != 0 ? b.min_zoom : null,
        maxZoom: b.has_max_zoom != 0 ? b.max_zoom : null,
        minPitch: b.has_min_pitch != 0 ? b.min_pitch : null,
        maxPitch: b.has_max_pitch != 0 ? b.max_pitch : null,
      );
    });
  }

  /// What a camera bound constrains — the centre, or the whole viewport.
  void setConstrainMode(CoreConstrainMode mode) {
    _checkAlive();
    bindings.mbl_map_set_constrain_mode(_handle, mode.code);
  }

  /// The registered camera-finish callback, held as a FIELD (CLAUDE.md §5e).
  ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Uint64)>?
  _cameraFinishCallable;

  /// Reports the token of each animated move as it ends OR is superseded.
  ///
  /// Superseding fires it too — that is mbgl's own behaviour, and it is what
  /// lets a Dart Future built on this complete rather than hang when a gesture
  /// interrupts a flight.
  void setCameraFinishCallback(void Function(int token)? onFinish) {
    if (onFinish == null) {
      if (!_disposed) {
        bindings.mbl_map_set_camera_finish_callback(
          _handle,
          ffi.nullptr,
          ffi.nullptr,
        );
      }
      _cameraFinishCallable?.close();
      _cameraFinishCallable = null;
      return;
    }
    _checkAlive();
    final previous = _cameraFinishCallable;
    final callable =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Uint64)
        >.listener((ffi.Pointer<ffi.Void> user, int token) {
          onFinish(token);
        });
    _cameraFinishCallable = callable;
    bindings.mbl_map_set_camera_finish_callback(
      _handle,
      callable.nativeFunction,
      ffi.nullptr,
    );
    previous?.close();
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('MapLibreCoreMap used after dispose()');
    }
  }
}
