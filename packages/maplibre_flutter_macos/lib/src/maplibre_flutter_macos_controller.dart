import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:maplibre_flutter_core/maplibre_flutter_core.dart' as core;
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Bootstrap channel for the texture registrar.
///
/// The one sanctioned platform-channel use (CLAUDE.md §3/§10): the engine's
/// texture registrar is only reachable from the native plugin, so Dart hands it
/// the core map's native handle (and the core's resolved function addresses) to
/// bind a `Texture` to. Registration only — the per-frame data path is native +
/// FFI (the core's render thread → the texture's `copyPixelBuffer`).
const MethodChannel _registrar = MethodChannel(
  'maplibre_flutter/macos/registrar',
);

/// Controller for a map composited through a Flutter `Texture` (desktop tier).
///
/// macOS drives `mbgl-core` over FFI (via `maplibre_flutter_core`): the core
/// renders off-screen on its own thread into a BGRA buffer; the native plugin's
/// `MapLibreTexture` copies that into a `CVPixelBuffer` for the `Texture`. This
/// controller creates the core map, registers the texture, forwards
/// camera/style, and resizes the off-screen surface to the widget. (§8 M2–M3.)
class MapLibreFlutterMacosController
    with MapLibreCameraTickNotifier
    implements
        MapLibreMapPlatformController,
        MapLibreGestureHandler,
        MapLibreMapProjector,
        MapLibreStyleLayers {
  MapLibreFlutterMacosController._(this._coreMap, this._textureId) {
    _pollReady();
  }

  final core.MapLibreCoreMap _coreMap;
  final int _textureId;

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
  static Future<MapLibreFlutterMacosController> create(
    String style,
    MapOptions options,
  ) async {
    final camera = options.initialCamera;
    // Render at the display's real pixel ratio (like a native map view), NOT 1. The
    // core's framebuffer is mbgl `Size * pixelRatio`, so passing logical points as the
    // size + the real DPR makes mbgl lay out tiles/lines on the device pixel grid; the
    // device-pixel texture then composites 1:1 with no resampling (pr=1 rendered a 1x
    // map blown up — more area, tiny labels, tile edges on fractional device pixels).
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
    // Zero-copy present (GPU blit into an IOSurface) is on by default; flip it
    // off for an A/B against the CPU-readback path with
    // `--dart-define=MAPLIBRE_ZEROCOPY=false`.
    coreMap.setZeroCopy(
      const bool.fromEnvironment('MAPLIBRE_ZEROCOPY', defaultValue: true),
    );
    coreMap.setCamera(
      latitude: camera.center.latitude,
      longitude: camera.center.longitude,
      zoom: camera.zoom,
      bearing: camera.bearing,
      pitch: camera.pitch,
    );

    final textureId = await _registrar
        .invokeMethod<int>('registerTexture', <String, Object?>{
          'mapHandle': coreMap.nativeAddress,
          'copyFrameFn': core.MapLibreCoreMap.copyFrameFunctionAddress,
          'setFrameCallbackFn':
              core.MapLibreCoreMap.setFrameCallbackFunctionAddress,
          'currentIOSurfaceFn':
              core.MapLibreCoreMap.currentIOSurfaceFunctionAddress,
        });

    return MapLibreFlutterMacosController._(coreMap, textureId ?? -1);
  }

  /// Polls until the first frame has rendered, then completes [onReady] (mirrors
  /// the mobile controllers' readiness handshake). Stops on dispose.
  void _pollReady() {
    if (_disposed || _ready.isCompleted) return;
    if (_coreMap.awaitFrame(Duration.zero)) {
      _ready.complete();
      // The first frame implies the transform snapshot exists; tick so any glued
      // overlay reprojects from off-screen to its real position.
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
    // Desktop has no usable native flyTo, so step an eased arc and render each
    // frame on the working (complete-frame) Static path. ~30fps; the core's
    // render thread paces the actual frames.
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
  Future<void> setStyle(String styleUri) async => _coreMap.setStyle(styleUri);

  @override
  Future<void> resize(Size size, double devicePixelRatio) async {
    if (_disposed) return;
    // Pass LOGICAL points as mbgl's size; the core multiplies by the pixelRatio set
    // at create to produce the device-pixel texture. (devicePixelRatio is unused
    // here — the core already knows the density.)
    final w = size.width.round();
    final h = size.height.round();
    if (w <= 0 || h <= 0 || (w == _renderWidth && h == _renderHeight)) return;
    _renderWidth = w;
    _renderHeight = h;
    _coreMap.resize(w, h);
    // The viewport size feeds the projection; tick so glued overlays reproject.
    // (Best-effort: the snapshot updates on the render thread; the next camera
    // change reconciles any sub-frame lag during an active drag-resize.)
    notifyCameraChanged();
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
