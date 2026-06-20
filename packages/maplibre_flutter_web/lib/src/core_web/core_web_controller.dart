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
/// the platform-view factory when the view mounts. The WASM/JS glue owns canvas
/// pointer gestures (as gl-js does), so this implements [MapLibreMapController]
/// only — no Dart gesture layer and no platform-interface change.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' show Size;
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

class MapLibreCoreWebController implements MapLibreMapController {
  MapLibreCoreWebController._(this._viewType, this._initialCamera);

  static int _nextId = 0;

  final String _viewType;
  final MapCamera _initialCamera;
  final Completer<void> _ready = Completer<void>();

  CoreMap? _map;
  bool _disposed = false;

  /// Loads the WASM module, registers a view factory that builds the map into a
  /// `<canvas>` when the `HtmlElementView` mounts, and returns the controller.
  static Future<MapLibreCoreWebController> create(MapOptions options) async {
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
          styleUri: options.styleUri,
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
        }).toJS,
      );

      controller._map = map;
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
    // TODO(web-core): honour `duration` with an animated transition (reuse the
    // shared desktop fly-arc, or a JS-side easeTo). For now this is instant —
    // see docs/experimental-web-core-wasm.md.
    map.setCamera(
      camera.center.latitude,
      camera.center.longitude,
      camera.zoom,
      camera.bearing,
      camera.pitch,
    );
  }

  @override
  Future<void> setStyle(String styleUri) async => _map?.setStyle(styleUri);

  @override
  Future<void> resize(Size size, double devicePixelRatio) async {
    final map = _map;
    if (map == null || _disposed) return;
    // The engine renders into the canvas backing store, which is sized in device
    // pixels (the C ABI `mbl_map_resize` takes device pixels; `mbl_map_create`
    // takes the ratio separately).
    map.resize(
      size.width * devicePixelRatio,
      size.height * devicePixelRatio,
      devicePixelRatio,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _map?.destroy();
    _map = null;
  }
}
