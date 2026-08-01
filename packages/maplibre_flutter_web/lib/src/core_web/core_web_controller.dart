/// **Experimental** web controller that renders with the native MapLibre engine
/// (`mbgl-core`) compiled to WASM, instead of maplibre-gl-js.
///
/// Selected at build time with `--dart-define=MAPLIBRE_WEB_CORE=true`; off by
/// default. The goal is one rendering engine across every platform (so feature
/// parity is maintained in one place) with no per-platform SDKs. See
/// `docs/experimental-web-core-wasm.md` for the full design and status.
///
/// This mirrors the structure of `MapLibreFlutterWebController` (the gl-js path):
/// the engine renders into a `<canvas>` hosted by an `HtmlElementView`, built in
/// the platform-view factory when the view mounts.
///
/// The WASM/JS glue owns canvas pointer gestures (as gl-js does), so this
/// deliberately does NOT implement [MapLibreGestureHandler] or
/// [MapLibreRotateHandler] — the widget only attaches its Dart gesture layer in
/// the `TextureHandle` branch, so those would be dead code here. It does
/// implement the projector, camera tick and style layers, which is what makes
/// widget markers, engine layers and the typed style API reachable on web.
///
/// [MapLibreModelHost] is absent by necessity, not oversight: `MapLibreModel`
/// takes a filesystem path the engine opens natively, and the Emscripten arm
/// compiles neither the glTF reader nor the model layer
/// (see docs/decision-log.md).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;
import 'dart:ui_web' as ui_web;

import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:web/web.dart' as web;

import 'core_wasm_interop.dart';
import 'core_wasm_loader.dart';

/// Continuous vs Static render mode, shared with the desktop tier's flag name.
const bool _continuous = bool.fromEnvironment(
  'MAPLIBRE_CONTINUOUS',
  defaultValue: true,
);

class MapLibreCoreWebController
    with MapLibreCameraTickNotifier
    implements
        MapLibreMapPlatformController,
        MapLibreMapProjector,
        MapLibreStyleLayers {
  MapLibreCoreWebController._(this._viewType, this._initialCamera);

  static int _nextId = 0;

  final String _viewType;
  final MapCamera _initialCamera;
  final Completer<void> _ready = Completer<void>();

  CoreMap? _map;
  // Observes canvas size changes to drive timely (before-paint) resizes; held against
  // GC and disconnected on dispose.
  web.ResizeObserver? _resizeObserver;
  bool _disposed = false;

  /// Loads the WASM module, registers a view factory that builds the map into a
  /// `<canvas>` when the `HtmlElementView` mounts, and returns the controller.
  static Future<MapLibreCoreWebController> create(
    String style,
    MapOptions options,
  ) async {
    // Throws a clear error if the experimental artifact isn't built/served.
    final module = await ensureCoreModuleLoaded();

    final viewType = 'maplibre_flutter/web-core/${_nextId++}';
    final camera = options.initialCamera;
    final controller = MapLibreCoreWebController._(viewType, camera);

    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final canvas = web.HTMLCanvasElement()
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.display = 'block';

      final dpr = web.window.devicePixelRatio;

      final map = module.createMap(
        CoreMapOptions(
          canvas: canvas,
          styleUri: style,
          lat: camera.center.latitude,
          lng: camera.center.longitude,
          zoom: camera.zoom,
          bearing: camera.bearing,
          pitch: camera.pitch,
          pixelRatio: dpr,
          continuous: _continuous,
        ),
      );

      // The module holds this callback to fire it once the first frame is up, so
      // the JS proxy stays reachable from JS (no Dart-side GC anchor needed).
      map.onReady(
        (() {
          if (!controller._ready.isCompleted) controller._ready.complete();
          // The first frame implies a transform exists; tick so any glued
          // overlay reprojects from off-screen to its real position. Without
          // this MapLibreMap(markers:) draws nothing until the camera moves —
          // the same defect the four native tiers had.
          controller.notifyCameraChanged();
        }).toJS,
      );

      // Every camera change inside the module — including its own C++ gesture
      // handlers, which the Dart gesture layer never sees — has to reach the
      // overlay, or markers swim during a drag.
      map.onCameraChanged(
        (() {
          if (!controller._disposed) controller.notifyCameraChanged();
        }).toJS,
      );

      controller._map = map;

      // Observe canvas size changes and push the new size to the engine with a
      // synchronous render. ResizeObserver fires after layout / before paint, so the
      // correctly-sized frame is composited in the same paint — no 1-frame stretch
      // (the engine's per-tick auto-size notices a CSS-box change a frame late). It
      // also fires once on observe(), covering the initial size. Held against GC and
      // disconnected on dispose.
      final observer = web.ResizeObserver(
        (JSArray<JSAny?> entries, web.ResizeObserver obs) {
          if (controller._disposed) return;
          final m = controller._map;
          if (m == null) return;
          final dpr = web.window.devicePixelRatio;
          final rect = canvas.getBoundingClientRect();
          // LOGICAL (CSS) size. mbgl allocates its framebuffer as
          // `Size * pixelRatio`, so multiplying here applied the ratio twice —
          // at DPR 2 the framebuffer was 4x the canvas and only its bottom-left
          // quadrant was blitted. Identical at DPR 1, which is the only
          // configuration this tier has been run in.
          final w = rect.width;
          final h = rect.height;
          if (w >= 1 && h >= 1) m.resizeSync(w, h, dpr);
        }.toJS,
      );
      observer.observe(canvas);
      controller._resizeObserver = observer;

      return canvas;
    });

    return controller;
  }

  @override
  MapLibreRenderHandle get renderHandle =>
      ElementViewHandle(viewType: _viewType);

  @override
  Future<void> get onReady => _ready.future;

  @override
  Future<MapCamera> getCamera() async {
    final map = _map;
    if (map == null) return _initialCamera;
    final c = map.getCamera();
    return MapCamera(
      center: LatLng(c.lat, c.lng),
      zoom: c.zoom,
      bearing: c.bearing,
      pitch: c.pitch,
    );
  }

  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {
    final map = _map;
    if (map == null || _disposed) return;
    final ms = duration?.inMilliseconds ?? 0;
    if (ms > 0) {
      map.animateTo(
        camera.center.latitude,
        camera.center.longitude,
        camera.zoom,
        camera.bearing,
        camera.pitch,
        ms.toDouble(),
      );
    } else {
      map.setCamera(
        camera.center.latitude,
        camera.center.longitude,
        camera.zoom,
        camera.bearing,
        camera.pitch,
      );
    }
  }

  @override
  Future<void> setStyle(String styleUri) async => _map?.setStyle(styleUri);

  @override
  Future<void> resize(Size size, double devicePixelRatio) async {
    final map = _map;
    if (map == null || _disposed) return;
    // LOGICAL points plus the ratio, matching the five native tiers: mbgl sizes
    // its framebuffer as `Size * pixelRatio` itself, and the shim scales to
    // device pixels once, in present(), when it blits to the canvas.
    map.resize(size.width, size.height, devicePixelRatio);
  }

  // --- MapLibreMapProjector -------------------------------------------------
  //
  // Screen positions are logical pixels, top-left origin — the same contract the
  // native tiers meet. That only became true once the shim stopped treating
  // mbgl's Size as device pixels; before that the space in the transform and the
  // space on screen disagreed at any DPR but 1.
  //
  // No presented-vs-newest generation split here, and that is not an omission:
  // on web the map, the frontend and the run loop all live on the browser main
  // thread, so there is no render thread for the camera to run ahead of. The
  // returned generation is a monotonic counter purely so callers can tell
  // "projected" from "no transform yet" (0).
  int _projGeneration = 0;

  @override
  int project(List<LatLng> points, List<Offset> out, {List<bool>? visible}) {
    final map = _map;
    if (map == null || _disposed || points.isEmpty) return 0;

    final input = <JSNumber>[];
    for (final p in points) {
      input.add(p.latitude.toJS);
      input.add(p.longitude.toJS);
    }
    final flat = map.projectBatch(input.toJS).toDart;
    if (flat.length < points.length * 3) return 0;

    for (var i = 0; i < points.length; i++) {
      final x = (flat[i * 3]! as JSNumber).toDartDouble;
      final y = (flat[i * 3 + 1]! as JSNumber).toDartDouble;
      out[i] = Offset(x, y);
      if (visible != null) {
        visible[i] = (flat[i * 3 + 2]! as JSNumber).toDartInt != 0;
      }
    }
    return ++_projGeneration;
  }

  @override
  LatLng? unproject(Offset point) {
    final map = _map;
    if (map == null || _disposed) return null;
    final o = map.unproject(point.dx, point.dy);
    return LatLng(o.lat, o.lng);
  }

  // --- MapLibreStyleLayers --------------------------------------------------
  //
  // Guarded like the native tiers: a call after dispose must be inert, not a
  // crash into a freed module.

  @override
  void addSourceJson(String id, String json) {
    final map = _map;
    if (map == null || _disposed) return;
    final error = map.addSourceJson(id, json).toDart;
    if (error.isNotEmpty) throw ArgumentError(error);
  }

  @override
  void addLayerJson(String json, {String? beforeId}) {
    final map = _map;
    if (map == null || _disposed) return;
    final error = map.addLayerJson(json, beforeId ?? '').toDart;
    if (error.isNotEmpty) throw ArgumentError(error);
  }

  @override
  void setSourceData(String sourceId, String data) =>
      setGeoJsonData(sourceId, data);

  @override
  String? getSourceJson(String sourceId) => null;

  @override
  List<String>? getSourceIds() => null;

  @override
  void setGeoJsonData(String sourceId, String geoJson) {
    final map = _map;
    if (map == null || _disposed) return;
    final error = map.setGeoJsonData(sourceId, geoJson).toDart;
    if (error.isNotEmpty) throw ArgumentError(error);
  }

  // The WASM shim does not export these yet — the embind module predates them
  // (stage 7.1 brings this tier up to the contract). Honest no-ops and nulls
  // rather than a plausible-looking lie: an app can tell the difference through
  // MapLibreCapabilities and the null returns, whereas a fabricated value would
  // silently be wrong.

  @override
  bool setLayerProperty(String layerId, String name, String valueJson) => false;

  @override
  void moveLayer(String layerId, {String? beforeId}) {}

  @override
  String? getLayerProperty(String layerId, String name) => null;

  @override
  List<String>? getLayerIds() => null;

  @override
  String? getLayerJson(String layerId) => null;

  @override
  void removeLayer(String id) {
    if (_disposed) return;
    _map?.removeLayer(id);
  }

  @override
  void removeSource(String id) {
    if (_disposed) return;
    _map?.removeSource(id);
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
    _map?.addImage(id, rgba.toJS, width, height, pixelRatio, sdf);
  }

  @override
  bool? hasImage(String id) => null;

  @override
  List<String>? getImageIds() => null;

  @override
  void removeImage(String id) {
    if (_disposed) return;
    _map?.removeImage(id);
  }

  @override
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions = true,
  }) {
    if (_disposed) return;
    // Negative means "leave the style's own value", matching the C ABI.
    _map?.setTransitionOptions(
      duration?.inMilliseconds ?? -1,
      delay?.inMilliseconds ?? -1,
      placementTransitions,
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
    final map = _map;
    if (map == null || _disposed) return null;
    final ids = layerIds == null
        ? null
        : <JSString>[for (final id in layerIds) id.toJS].toJS;
    final json = map.queryRenderedFeatures(minX, minY, maxX, maxY, ids).toDart;
    return json.isEmpty ? null : json;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    disposeCameraTick();
    _disposed = true;
    _resizeObserver?.disconnect();
    _resizeObserver = null;
    _map?.destroy();
    _map = null;
  }
}
