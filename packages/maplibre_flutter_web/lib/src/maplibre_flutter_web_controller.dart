import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' show Size;
import 'dart:ui_web' as ui_web;

import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:web/web.dart' as web;

import 'maplibre_gl_interop.dart';
import 'maplibre_gl_loader.dart';

/// Controller for a map rendered by maplibre-gl-js inside an `HtmlElementView`
/// (CLAUDE.md §3, web tier).
///
/// Web mirrors the **mobile** tier, not the desktop tier: maplibre-gl-js owns
/// pan/zoom/rotate gestures and inertia natively, so this implements
/// [MapLibreMapController] only — *not* [MapLibreGestureHandler]. The app-facing
/// widget therefore skips its Dart gesture layer for `ElementViewHandle`.
///
/// The JS map is built inside the platform-view factory (which the engine runs
/// when the `HtmlElementView` mounts — *after* [create] returns and the view is
/// laid out, mirroring how the desktop controllers return before the first
/// frame). [onReady] completes on the JS `'load'` event.
class MapLibreFlutterWebController implements MapLibreMapController {
  MapLibreFlutterWebController._(this._viewType, this._initialCamera);

  /// Monotonic id source for unique platform-view type names. View-type
  /// collisions silently reuse a factory, so every map gets its own.
  static int _nextId = 0;

  final String _viewType;
  final MapCamera _initialCamera;
  final Completer<void> _ready = Completer<void>();

  MaplibreMap? _map;
  bool _disposed = false;
  // Hold the JS 'load' callback for the controller's lifetime (GC pitfall,
  // CLAUDE.md §5d); cleared on dispose.
  JSFunction? _onLoad;

  /// Loads maplibre-gl-js, registers a view factory that builds the map when the
  /// `HtmlElementView` mounts, and returns the controller.
  static Future<MapLibreFlutterWebController> create(MapOptions options) async {
    await ensureMaplibreLoaded();

    final viewType = 'maplibre_flutter/web/${_nextId++}';
    final camera = options.initialCamera;
    final controller = MapLibreFlutterWebController._(viewType, camera);

    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final div = web.HTMLDivElement()
        ..style.width = '100%'
        ..style.height = '100%';

      final map = MaplibreMap(
        MaplibreMapOptions(
          container: div,
          style: options.styleUri.toJS,
          center: _lngLat(camera.center),
          zoom: camera.zoom,
          bearing: camera.bearing,
          pitch: camera.pitch,
        ),
      );

      final onLoad = ((JSAny _) {
        if (!controller._ready.isCompleted) controller._ready.complete();
      }).toJS;
      map.on('load', onLoad);

      controller._map = map;
      controller._onLoad = onLoad;
      return div;
    });

    return controller;
  }

  /// Our `LatLng(lat, lng)` → maplibre's `[lng, lat]`.
  static JSArray<JSNumber> _lngLat(LatLng c) =>
      <JSNumber>[c.longitude.toJS, c.latitude.toJS].toJS;

  @override
  MapLibreRenderHandle get renderHandle =>
      ElementViewHandle(viewType: _viewType);

  @override
  Future<void> get onReady => _ready.future;

  @override
  Future<MapCamera> getCamera() async {
    final map = _map;
    // Before the factory builds the map, report the initial camera (contract).
    if (map == null) return _initialCamera;
    final c = map.getCenter();
    return MapCamera(
      center: LatLng(c.lat, c.lng), // flip back from [lng, lat]
      zoom: map.getZoom(),
      bearing: map.getBearing(),
      pitch: map.getPitch(),
    );
  }

  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {
    final map = _map;
    if (map == null || _disposed) return;
    final ms = duration?.inMilliseconds ?? 0;
    if (ms <= 0) {
      map.jumpTo(
        CameraLiteral(
          center: _lngLat(camera.center),
          zoom: camera.zoom,
          bearing: camera.bearing,
          pitch: camera.pitch,
        ),
      );
      return;
    }
    // flyTo derives its length from speed/curve unless given an explicit
    // duration; pass it (and essential) so web matches the other tiers'
    // fixed-duration fly-to and animates even under prefers-reduced-motion.
    map.flyTo(
      CameraLiteral(
        center: _lngLat(camera.center),
        zoom: camera.zoom,
        bearing: camera.bearing,
        pitch: camera.pitch,
        duration: ms.toDouble(),
        essential: true,
      ),
    );
  }

  @override
  Future<void> setStyle(String styleUri) async => _map?.setStyle(styleUri.toJS);

  @override
  Future<void> resize(Size size, double devicePixelRatio) async {
    // The host div is CSS 100% and maplibre-gl-js reads its box and the device
    // pixel ratio itself; just prompt a recompute after a layout change.
    _map?.resize();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final map = _map;
    if (map != null) {
      final onLoad = _onLoad;
      if (onLoad != null) map.off('load', onLoad);
      map.remove(); // frees the WebGL context + worker
    }
    _map = null;
    _onLoad = null;
  }
}
