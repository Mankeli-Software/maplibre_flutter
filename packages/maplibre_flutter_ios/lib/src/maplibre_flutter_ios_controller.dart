import 'dart:async';

import 'package:objective_c/objective_c.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'maplibre_flutter_ios_bindings.g.dart' as bindings;

/// iOS view type registered by the native plugin
/// (`MaplibreFlutterIosPlugin.viewType`).
const String kIosMapViewType = 'maplibre_flutter/ios';

/// Controller for a map embedded as a `UiKitView` (mobile SDK tier).
///
/// Mirrors the Android controller. A Dart-minted [_mapId] is handed to the
/// native view via `creationParams`; the native side registers a
/// `MapLibreController` in `MapRegistry` under that id, which this resolves over
/// the swiftgen bindings ([bindings.MapRegistry.get]) to drive the map. No
/// data-path method channel is involved (CLAUDE.md §10).
class MapLibreFlutterIosController implements MapLibreMapController {
  MapLibreFlutterIosController(this._options) : _mapId = _nextMapId++ {
    _pollReady();
  }

  final MapOptions _options;
  final int _mapId;

  static int _nextMapId = 1;

  /// Bound native controller, resolved lazily once the view exists and the map
  /// is ready. `package:objective_c` manages the ObjC lifetime via finalizers,
  /// so unlike the JNI side there is no manual release.
  bindings.MapLibreController? _native;
  bool _disposed = false;

  final Completer<void> _ready = Completer<void>();

  @override
  MapLibreRenderHandle get renderHandle => PlatformViewHandle(
    viewType: kIosMapViewType,
    id: _mapId,
    creationParams: _creationParams(),
  );

  @override
  Future<void> get onReady => _ready.future;

  Map<String, Object?> _creationParams() {
    final camera = _options.initialCamera;
    return <String, Object?>{
      'mapId': _mapId,
      'styleUri': _options.styleUri,
      'lat': camera.center.latitude,
      'lng': camera.center.longitude,
      'zoom': camera.zoom,
      'bearing': camera.bearing,
      'pitch': camera.pitch,
    };
  }

  /// The bound controller once the native map is ready, else null (best-effort:
  /// the view may not be created or the style still loading — callers no-op).
  bindings.MapLibreController? _resolve() {
    if (_disposed) return null;
    final existing = _native;
    if (existing != null && existing.isReady) return existing;
    final found = bindings.MapRegistry.get(_mapId);
    if (found == null) {
      _native = null;
      return null;
    }
    _native = found;
    return found.isReady ? found : null;
  }

  /// Polls until the native map is ready, then completes [onReady]. Stops once
  /// resolved; never completes if the map is disposed first.
  void _pollReady() {
    if (_disposed || _ready.isCompleted) return;
    if (_resolve() != null) {
      _ready.complete();
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 50), _pollReady);
  }

  @override
  Future<MapCamera> getCamera() async {
    final c = _resolve();
    if (c == null) return _options.initialCamera;
    return MapCamera(
      center: LatLng(c.lat, c.lng),
      zoom: c.zoom,
      bearing: c.bearing,
      pitch: c.pitch,
    );
  }

  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {
    final c = _resolve();
    if (c == null) return;
    c.moveCameraWithLat(
      camera.center.latitude,
      lng: camera.center.longitude,
      zoom: camera.zoom,
      bearing: camera.bearing,
      pitch: camera.pitch,
      durationMs: duration?.inMilliseconds ?? 0,
    );
  }

  @override
  Future<void> setStyle(String styleUri) async {
    final c = _resolve();
    if (c == null) return;
    c.setStyle(styleUri.toNSString());
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _native = null;
    // Native MapRegistry entry is removed by MapLibrePlatformView.deinit.
  }
}
