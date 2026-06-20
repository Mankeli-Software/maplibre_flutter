import 'dart:async';
import 'dart:ui' show Size;

import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:meta/meta.dart';

/// Imperative handle to a [MapLibreMap].
///
/// Construct one, hand it to [MapLibreMap.controller], then drive the map once
/// [onReady] completes:
///
/// ```dart
/// final controller = MapLibreMapController();
///
/// // in build():
/// MapLibreMap(controller: controller, style: styleUri);
///
/// // elsewhere:
/// await controller.onReady;
/// await controller.camera.move(MapCamera(center: LatLng(51.5, -0.13), zoom: 6));
/// ```
///
/// The controller is **optional** — omit it and [MapLibreMap] creates and owns
/// one internally. When you do provide one, you own it: call [dispose] when
/// you are done (typically from your `State.dispose`).
///
/// Imperative APIs are grouped into namespaces by sub-domain rather than flattened
/// onto this class (the camera API alone is large): camera control lives under
/// [camera]. The map's *style* is **not** here — it is a declarative property of
/// the [MapLibreMap] widget (CLAUDE.md §3).
///
/// This is the app-facing controller. It wraps the per-platform
/// [MapLibreMapPlatformController] that the registered platform creates when the
/// widget mounts; everything imperative the public API needs forwards to it.
class MapLibreMapController {
  /// Creates an unbound controller. No native map exists until the controller
  /// is passed to a [MapLibreMap], which [attach]es it.
  MapLibreMapController();

  MapLibreMapPlatformController? _platform;
  MapOptions? _options;
  final Completer<void> _ready = Completer<void>();
  bool _attached = false;
  bool _disposed = false;

  /// Camera control: move, animate, fly, fit, query, … See
  /// [MapLibreCameraController]. Grouped into its own namespace because the
  /// camera surface is large (the sub-manager pattern map SDKs use for big
  /// sub-domains, e.g. Mapbox's annotation/style managers).
  late final MapLibreCameraController camera = MapLibreCameraController._(this);

  /// Whether a native map is currently bound (true between [attach] and
  /// [detach]/[dispose]).
  bool get isAttached => _platform != null;

  /// Whether [dispose] has been called. A disposed controller cannot be reused.
  bool get isDisposed => _disposed;

  /// Completes once the native map exists and has loaded its initial style.
  /// Until then [MapLibreCameraController.getPosition] reports the initial camera
  /// and [MapLibreCameraController.move] is a best-effort no-op. Does not complete
  /// if the controller is disposed before the map becomes ready.
  Future<void> get onReady => _ready.future;

  /// Releases the native map and this controller. Call this when you own the
  /// controller (you constructed it and passed it to a [MapLibreMap]). Safe to
  /// call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final platform = _platform;
    _platform = null;
    _attached = false;
    await platform?.dispose();
  }

  // ---------------------------------------------------------------------------
  // Widget glue — driven by [MapLibreMap], not app code.
  // ---------------------------------------------------------------------------

  /// Binds this controller to a freshly created native map. Called by
  /// [MapLibreMap] when it mounts. Throws if the controller is already attached
  /// to a map or has been disposed.
  @internal
  Future<void> attach({
    required String style,
    required MapOptions options,
  }) async {
    if (_disposed) {
      throw StateError('This MapLibreMapController has been disposed.');
    }
    if (_attached) {
      throw StateError(
        'This MapLibreMapController is already attached to a MapLibreMap. Use a '
        'separate controller for each map.',
      );
    }
    _attached = true;
    _options = options;
    final platform = await MapLibreFlutterPlatform.instance.createMap(
      style: style,
      options: options,
    );
    // Disposed or detached while createMap was in flight — drop the native map.
    if (_disposed || !_attached) {
      await platform.dispose();
      return;
    }
    _platform = platform;
    platform.onReady.then((_) {
      if (!_ready.isCompleted) _ready.complete();
    });
  }

  /// Tears down the native map but leaves the controller reusable (re-[attach]
  /// is allowed). Called by the widget on unmount when it does **not** own the
  /// controller; the owner still calls [dispose].
  @internal
  Future<void> detach() async {
    final platform = _platform;
    _platform = null;
    _attached = false;
    await platform?.dispose();
  }

  /// How the widget should embed this map. Null until [attach] resolves.
  @internal
  MapLibreRenderHandle? get renderHandle => _platform?.renderHandle;

  /// The platform controller's Dart gesture handler when it drives gestures in
  /// Dart (desktop tier); null on mobile/web. The widget uses this to decide
  /// whether to attach its Dart gesture layer.
  @internal
  MapLibreGestureHandler? get gestureHandler {
    // The render handle and the gesture-handler interface are unrelated types,
    // so `is` does not promote across them — cast inside the guard.
    final platform = _platform;
    return platform is MapLibreGestureHandler
        ? platform as MapLibreGestureHandler
        : null;
  }

  /// Applies a new style. The public source of truth for style is the
  /// [MapLibreMap.style] property (declarative), so the widget calls this on
  /// change; app code changes the widget property instead.
  @internal
  Future<void> setStyle(String style) async => _platform?.setStyle(style);

  /// Reports the embedding view's size so the desktop texture tier can resize
  /// its off-screen surface. A no-op on the mobile/web tiers.
  @internal
  Future<void> resize(Size size, double devicePixelRatio) async =>
      _platform?.resize(size, devicePixelRatio);
}

/// Camera control for a [MapLibreMap], reached via [MapLibreMapController.camera].
///
/// Lives in its own namespace (rather than as flat methods on
/// [MapLibreMapController]) because the camera API is large. Every method is a
/// no-op / reports the initial camera until the map is ready
/// ([MapLibreMapController.onReady]).
class MapLibreCameraController {
  MapLibreCameraController._(this._owner);

  final MapLibreMapController _owner;

  /// The current camera. Before the map is ready, reports the initial camera.
  Future<MapCamera> getPosition() async {
    final platform = _owner._platform;
    if (platform == null) {
      return _owner._options?.initialCamera ??
          const MapCamera(center: LatLng(0, 0));
    }
    return platform.getCamera();
  }

  /// Moves the camera to [target], animating over [duration] when non-null.
  /// A best-effort no-op before the map is ready.
  Future<void> move(MapCamera target, {Duration? duration}) async =>
      _owner._platform?.moveCamera(target, duration: duration);

  // Further camera operations (flyTo, fitBounds, zoomBy/zoomTo, rotateBy,
  // pitchBy, jumpTo, easeTo, …) are added here, each forwarding to the bound
  // [MapLibreMapPlatformController].
}
