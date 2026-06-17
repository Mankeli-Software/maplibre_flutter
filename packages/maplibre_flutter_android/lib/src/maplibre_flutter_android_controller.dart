import 'package:jni/jni.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'maplibre_flutter_android_bindings.g.dart';

/// Android view type registered by the native plugin
/// (`MaplibreFlutterAndroidPlugin.VIEW_TYPE`).
const String kAndroidMapViewType = 'maplibre_flutter/android';

/// Controller for a map embedded as an `AndroidView` (mobile SDK tier).
///
/// The native side renders the map; this drives it over jnigen. A Dart-minted
/// [_mapId] is handed to the native view through `creationParams`; the view
/// registers a `MapLibreController` in the native `MapRegistry` under that id,
/// and we look it up here ([_resolve]) to call the bound methods. No data-path
/// method channel is involved (CLAUDE.md §10).
class MapLibreFlutterAndroidController implements MapLibreMapController {
  MapLibreFlutterAndroidController(this._options) : _mapId = _nextMapId++;

  final MapOptions _options;
  final int _mapId;

  static int _nextMapId = 1;

  /// The bound native controller, looked up lazily once the view exists and the
  /// map is ready. Held as a field so the JNI global ref survives (CLAUDE.md
  /// §5d) and is released exactly once in [dispose].
  MapLibreController? _native;
  bool _disposed = false;

  @override
  MapLibreRenderHandle get renderHandle => PlatformViewHandle(
    viewType: kAndroidMapViewType,
    id: _mapId,
    creationParams: _creationParams(),
  );

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

  /// Returns the bound controller once the native map is ready, else null.
  ///
  /// The view may not be created yet (or the style still loading) when the app
  /// first calls a control method, so this is best-effort: callers no-op when
  /// it returns null rather than throwing.
  MapLibreController? _resolve() {
    if (_disposed) return null;
    final existing = _native;
    if (existing != null && existing.isReady) return existing;

    // (Re)look-up: register() returns null until the view factory has run.
    existing?.release();
    final found = MapRegistry.get(_mapId);
    if (found == null) {
      _native = null;
      return null;
    }
    _native = found;
    return found.isReady ? found : null;
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
    c.moveCamera(
      camera.center.latitude,
      camera.center.longitude,
      camera.zoom,
      camera.bearing,
      camera.pitch,
      duration?.inMilliseconds ?? 0,
    );
  }

  @override
  Future<void> setStyle(String styleUri) async {
    final c = _resolve();
    if (c == null) return;
    final jStyle = styleUri.toJString();
    try {
      c.style = jStyle;
    } finally {
      jStyle.release();
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _native?.release();
    _native = null;
    // The native MapRegistry entry is removed by MapLibrePlatformView.dispose()
    // when the AndroidView tears down.
  }
}
