import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_flutter_core/maplibre_flutter_core.dart' as core;
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Bootstrap channel for the texture registrar (experimental core path).
///
/// The one sanctioned platform-channel use (CLAUDE.md §3/§10): the engine's
/// texture registrar (a `SurfaceProducer`) is only reachable from the native
/// plugin, so Dart hands it the core map's native handle and the core's resolved
/// FFI function addresses to bind a `Texture` to. Registration only — the
/// per-frame data path is native + FFI (the core's render thread calls a frame
/// callback; the plugin's native code then `copyFrame`s into the producer's
/// `Surface` via `ANativeWindow`). Mirrors the iOS channel
/// `maplibre_flutter/ios/registrar`.
const MethodChannel _registrar = MethodChannel(
  'maplibre_flutter/android/registrar',
);

/// EXPERIMENTAL controller: renders Android via `mbgl-core` (OpenGL ES + a
/// Flutter `Texture`) instead of the MapLibre Android SDK (`MapView`/`AndroidView`).
///
/// This is the desktop core tier ported to Android, gated behind
/// `--dart-define=MAPLIBRE_EXPERIMENTAL_CORE=true` (CLAUDE.md §3 escape hatch;
/// the 2026-06-19 decision keeps the SDK the default on mobile). It drives the
/// shared `maplibre_flutter_core` over FFI: the core renders off-screen on its
/// own thread into an RGBA frame; the native plugin presents that frame into a
/// `SurfaceProducer`'s `Surface` (a CPU `ANativeWindow` blit). By returning a
/// [TextureHandle] and implementing [MapLibreGestureHandler] it reuses the shared
/// desktop Dart gesture + fly-to tier with no widget or interface change —
/// feature parity with the macOS/Linux/Windows/iOS-core controllers.
class MapLibreFlutterAndroidCoreController
    with MapLibreCameraTickNotifier
    implements
        MapLibreMapPlatformController,
        MapLibreGestureHandler,
        MapLibreMapProjector,
        MapLibreStyleLayers {
  MapLibreFlutterAndroidCoreController._(
    this._coreMap,
    this._textureId,
    this._dpr,
  ) {
    _pollReady();
  }

  /// Builds a controller around an already-created core map, bypassing
  /// [create]'s native texture registration.
  ///
  /// Exists so the controller body can be tested on the VM against
  /// `RecordingCoreMap` (`package:maplibre_flutter_core/testing.dart`) with no
  /// dylib, GPU or device. [create] is unusable for that: it calls
  /// `MapLibreCoreMap.create` and a `registerTexture` method channel. The
  /// ~400 lines below — camera conversion, fly-to stepping, projector batching,
  /// style pass-through, dispose ordering — are otherwise executed by no test on
  /// any platform (CLAUDE.md §7 layer 2).
  @visibleForTesting
  MapLibreFlutterAndroidCoreController.forTesting(
    core.MapLibreCoreMap coreMap, {
    int textureId = 0,
    double devicePixelRatio = 1.0,
  }) : _coreMap = coreMap,
       // ignore: prefer_initializing_formals
       _textureId = textureId,
       _dpr = devicePixelRatio {
    _pollReady();
  }

  final core.MapLibreCoreMap _coreMap;
  final int _textureId;

  /// Device pixel ratio captured at create — used to size the producer's
  /// `Surface` in device pixels (mbgl's framebuffer is logical `Size * dpr`).
  final double _dpr;

  bool _disposed = false;
  // Bumped to supersede a running fly-to animation (a new move or a gesture).
  int _animToken = 0;
  final Completer<void> _ready = Completer<void>();

  // Initial off-screen size in LOGICAL points; replaced once the widget reports
  // its real size via [resize]. The texture self-sizes to whatever the core
  // renders, so this is only the size of the very first frame(s).
  static const int _initialWidth = 512;
  static const int _initialHeight = 512;
  int _renderWidth = _initialWidth;
  int _renderHeight = _initialHeight;

  /// Creates the core map, registers an engine texture bound to it, and returns
  /// a controller. [onReady] completes once the first frame has rendered.
  static Future<MapLibreFlutterAndroidCoreController> create(
    String style,
    MapOptions options,
  ) async {
    final camera = options.initialCamera;
    // Register the OkHttp HTTP bridge with mbgl-core BEFORE creating the map: the
    // core's render thread starts fetching the style + tiles the moment it's created,
    // and the NDK core has no built-in HTTP (CLAUDE.md §3). Idempotent native-side.
    await _registrar.invokeMethod<void>('ensureHttpBridge');
    // Render at the device's real pixel ratio (like the SDK), NOT 1. The core's
    // framebuffer is mbgl `Size * pixelRatio`, so passing logical points as the
    // size + the real DPR lays tiles/lines out on the device pixel grid; the
    // resulting device-pixel texture composites 1:1 with no resampling
    // (pixelRatio 1 left tile edges on fractional device pixels → faint seams).
    final dpr =
        ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0;
    final coreMap = core.MapLibreCoreMap.create(
      width: _initialWidth,
      height: _initialHeight,
      pixelRatio: dpr,
      styleUri: style,
      // Continuous render (partial frames that refine as tiles load) is on by
      // default; --dart-define=MAPLIBRE_CONTINUOUS=false uses the blocking
      // Static path for an A/B.
      continuous: const bool.fromEnvironment(
        'MAPLIBRE_CONTINUOUS',
        defaultValue: true,
      ),
    );
    // Android presents the CPU frame as RGBA into the SurfaceProducer's Surface
    // (an ARGB_8888-compatible ANativeWindow), so emit RGBA, not BGRA.
    coreMap.setPixelFormatBgra(false);
    coreMap.setCamera(
      latitude: camera.center.latitude,
      longitude: camera.center.longitude,
      zoom: camera.zoom,
      bearing: camera.bearing,
      pitch: camera.pitch,
    );

    final textureId = await _registrar.invokeMethod<int>('registerTexture', <
      String,
      Object?
    >{
      'mapHandle': coreMap.nativeAddress,
      'copyFrameFn': core.MapLibreCoreMap.copyFrameFunctionAddress,
      'setFrameCallbackFn':
          core.MapLibreCoreMap.setFrameCallbackFunctionAddress,
      // Initial producer size in DEVICE pixels (mbgl renders Size * dpr).
      'widthPx': (_initialWidth * dpr).round(),
      'heightPx': (_initialHeight * dpr).round(),
      // Try the zero-copy present (EGL window surface, no readback) by default —
      // real-device GPUs composite it (the smooth path). The core auto-falls-back to
      // the CPU ANativeWindow present on GL renderers that can't composite a
      // foreign-EGL buffer in a Flutter SurfaceProducer (the Android emulator /
      // software GL render white), so the map still shows there. Set
      // --dart-define=MAPLIBRE_ZEROCOPY=false to force the CPU present everywhere.
      'zeroCopy': const bool.fromEnvironment(
        'MAPLIBRE_ZEROCOPY',
        defaultValue: true,
      ),
    });

    return MapLibreFlutterAndroidCoreController._(
      coreMap,
      textureId ?? -1,
      dpr,
    );
  }

  /// Polls until the first frame has rendered, then completes [onReady] (mirrors
  /// the desktop controllers' readiness handshake). Stops on dispose.
  void _pollReady() {
    if (_disposed || _ready.isCompleted) return;
    if (_coreMap.awaitFrame(Duration.zero)) {
      _ready.complete();
      // The first frame implies the transform snapshot exists; tick so any
      // glued overlay reprojects from off-screen to its real position.
      // Without this MapLibreMap(markers:) draws NOTHING until the first pan:
      // MarkerOverlay only starts repainting on a projector notification, and
      // its delegate skips every child while the projection generation is 0.
      notifyCameraChanged();
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 50), _pollReady);
  }

  @override
  MapLibreRenderHandle get renderHandle => TextureHandle(textureId: _textureId);

  @override
  Future<void> get onReady => _ready.future;

  @override
  Future<MapCamera> getCamera() async {
    final c = _coreMap.getCamera();
    return MapCamera(
      center: LatLng(c.latitude, c.longitude),
      zoom: c.zoom,
      bearing: c.bearing,
      pitch: c.pitch,
    );
  }

  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {
    final token = ++_animToken; // supersede any running animation
    final ms = duration?.inMilliseconds ?? 0;
    if (_disposed || ms <= 0) {
      _applyCamera(camera);
      return;
    }
    // The core has no usable native flyTo, so step an eased arc and render each
    // frame. ~30fps; the core's render thread paces the actual frames.
    final start = await getCamera();
    if (_disposed || token != _animToken) return;
    const frameMs = 33;
    final steps = math.max(1, (ms / frameMs).round());
    for (var i = 1; i <= steps; i++) {
      if (_disposed || token != _animToken) return;
      _applyCamera(flyCameraAt(start, camera, i / steps));
      await Future<void>.delayed(const Duration(milliseconds: frameMs));
    }
    if (!_disposed && token == _animToken) _applyCamera(camera);
  }

  void _applyCamera(MapCamera camera) {
    _coreMap.setCamera(
      latitude: camera.center.latitude,
      longitude: camera.center.longitude,
      zoom: camera.zoom,
      bearing: camera.bearing,
      pitch: camera.pitch,
    );
    notifyCameraChanged(); // reproject glued widget overlays
  }

  @override
  Future<void> setStyle(String styleUri) async {
    // Guarded like every other forward: the core throws StateError once
    // disposed, and the widget pushes its declarative `style` prop from
    // didUpdateWidget, which can land during teardown.
    if (_disposed) return;
    _coreMap.setStyle(styleUri);
  }

  @override
  Future<void> resize(Size size, double devicePixelRatio) async {
    if (_disposed) return;
    // Pass LOGICAL points as mbgl's size; the core multiplies by the pixelRatio
    // set at create to produce the device-pixel texture. (devicePixelRatio is
    // unused here — the core already knows the density.)
    final w = size.width.round();
    final h = size.height.round();
    if (w <= 0 || h <= 0 || (w == _renderWidth && h == _renderHeight)) return;
    _renderWidth = w;
    _renderHeight = h;
    _coreMap.resize(w, h);
    notifyCameraChanged(); // viewport size feeds the projection
    // Keep the producer's Surface sized to the device-pixel frame (Impeller backs
    // it with a fixed-size ImageReader, so a stale size mismatches the buffer).
    unawaited(
      _registrar.invokeMethod<void>('resizeTexture', <String, Object?>{
        'textureId': _textureId,
        'widthPx': (w * _dpr).round(),
        'heightPx': (h * _dpr).round(),
      }),
    );
  }

  @override
  void moveBy(double dx, double dy) {
    if (_disposed) return;
    _animToken++; // a gesture supersedes any running fly-to
    // mbgl's screen coordinates are logical points (Size = logical points),
    // matching the widget's gesture deltas — no DPR scaling.
    _coreMap.moveBy(dx, dy);
    notifyCameraChanged(); // reproject glued widget overlays
  }

  @override
  void scaleBy(double scale, double anchorX, double anchorY) {
    if (_disposed) return;
    _animToken++; // a gesture supersedes any running fly-to
    _coreMap.scaleBy(scale, anchorX, anchorY);
    notifyCameraChanged(); // reproject glued widget overlays
  }

  // --- MapLibreStyleLayers ----------------------------------------------------
  // Straight pass-through to the core: mbgl owns the style, and the shim already
  // validates the JSON synchronously and marshals the mutation onto the render
  // thread. Silently ignored after dispose (matches the rest of this controller,
  // where late calls from a torn-down widget are a no-op rather than a throw).

  @override
  void addSourceJson(String id, String json) {
    if (_disposed) return;
    _coreMap.addSourceJson(id, json);
  }

  @override
  void addLayerJson(String json, {String? beforeId}) {
    if (_disposed) return;
    _coreMap.addLayerJson(json, beforeId: beforeId);
  }

  @override
  void setGeoJsonData(String sourceId, String geoJson) {
    if (_disposed) return;
    _coreMap.setGeoJsonData(sourceId, geoJson);
  }

  @override
  void removeLayer(String id) {
    if (_disposed) return;
    _coreMap.removeLayer(id);
  }

  @override
  void removeSource(String id) {
    if (_disposed) return;
    _coreMap.removeSource(id);
  }

  @override
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) {
    if (_disposed) return;
    _coreMap.addImage(
      id,
      rgba,
      width,
      height,
      pixelRatio: pixelRatio,
      sdf: sdf,
    );
  }

  @override
  void removeImage(String id) {
    if (_disposed) return;
    _coreMap.removeImage(id);
  }

  @override
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions = true,
  }) {
    if (_disposed) return;
    _coreMap.setTransitionOptions(
      duration: duration,
      delay: delay,
      placementTransitions: placementTransitions,
    );
  }

  @override
  String? queryRenderedFeaturesJson(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
  }) {
    if (_disposed) return null;
    return _coreMap.queryRenderedFeatures(
      minX,
      minY,
      maxX,
      maxY,
      layerIds: layerIds,
    );
  }

  // --- MapLibreMapProjector ---------------------------------------------------
  // Projection runs synchronously over the core's lock-free transform snapshot,
  // so it is cheap to call from a Flow paint every camera tick. Screen space is
  // logical points, top-left origin (matching the gesture deltas above).

  // Reused across frames so projecting markers every camera tick allocates
  // nothing on the Dart side (the core reuses native buffers in turn).
  Float64List _projIn = Float64List(0);
  Float64List _projOut = Float64List(0);
  Int32List _projVis = Int32List(0);

  @override
  int project(List<LatLng> points, List<ui.Offset> out, {List<bool>? visible}) {
    if (_disposed || points.isEmpty) return 0;
    final n = points.length;
    if (_projIn.length < n * 2) {
      _projIn = Float64List(n * 2);
      _projOut = Float64List(n * 2);
      _projVis = Int32List(n);
    }
    for (var i = 0; i < n; i++) {
      _projIn[i * 2] = points[i].latitude;
      _projIn[i * 2 + 1] = points[i].longitude;
    }
    // Project against the transform of the frame ON SCREEN, not the newest one.
    // Camera commands apply asynchronously on the render thread, so the newest
    // transform typically leads the visible frame — projecting against it makes
    // markers swim/lag during movement. (0 before the first frame, which the
    // core treats as "newest".)
    final gen = _coreMap.projectBatch(
      n,
      _projIn,
      _projOut,
      visible: _projVis,
      generation: _coreMap.presentedGeneration,
    );
    if (gen == 0) return 0;
    for (var i = 0; i < n; i++) {
      out[i] = ui.Offset(_projOut[i * 2], _projOut[i * 2 + 1]);
      if (visible != null) visible[i] = _projVis[i] != 0;
    }
    return gen;
  }

  @override
  LatLng? unproject(ui.Offset point) {
    if (_disposed) return null;
    // Same frame the user is looking at (and the same one project() used), so a
    // tap maps to the point actually under the cursor mid-movement.
    final r = _coreMap.unproject(
      point.dx,
      point.dy,
      generation: _coreMap.presentedGeneration,
    );
    return r == null ? null : LatLng(r.latitude, r.longitude);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    disposeCameraTick();
    // Unregister first (clears the native frame callback and stops the engine
    // pulling frames), then destroy the core map (joins its render thread).
    await _registrar.invokeMethod<void>('unregisterTexture', _textureId);
    _coreMap.dispose();
  }
}
