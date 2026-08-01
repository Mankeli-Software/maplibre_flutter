import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show Listenable;

import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:meta/meta.dart';

import 'map_layers_controller.dart';

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

  /// Engine-drawn sources, layers and icons — the scalable annotation path for
  /// datasets past what widget markers can carry, with clustering built in. See
  /// [MapLibreLayersController]; `layers.isSupported` is false on renderers that
  /// cannot do it, and every call is then a no-op.
  final MapLibreLayersController layers = MapLibreLayersController();

  /// Whether a native map is currently bound (true between [attach] and
  /// [detach]/[dispose]).
  bool get isAttached => _platform != null;

  /// What the bound renderer can actually do.
  ///
  /// The tiers have genuinely different ceilings — the web tier has no
  /// projector, so no widget markers — and this is the supported way to ask,
  /// rather than calling something and watching it no-op. All false before
  /// attach, so re-read it after [onReady].
  ///
  /// ```dart
  /// if (controller.capabilities.rotateAndTilt) CompassButton(controller),
  /// ```
  ///
  /// The capability interfaces themselves are exported too, for anything this
  /// object does not cover: `if (controller is MapLibreModelHost)`.
  MapLibreCapabilities get capabilities => MapLibreCapabilities.of(_platform);

  // --- Engine events ----------------------------------------------------------
  //
  // Owned HERE rather than forwarded straight off the platform controller, on
  // purpose: a controller is constructed before the map exists, and the failures
  // worth hearing about — a style that 404s above all — happen during that first
  // load. An app must be able to `controller.onError.listen(...)` immediately,
  // so these are stable objects that the platform's streams are piped into on
  // attach and unpiped from on detach.
  final StreamController<MapLibreError> _errors =
      StreamController<MapLibreError>.broadcast();
  final StreamController<void> _styleLoads = StreamController<void>.broadcast();
  final StreamController<String> _missingImages =
      StreamController<String>.broadcast();
  final List<StreamSubscription<Object?>> _eventSubscriptions =
      <StreamSubscription<Object?>>[];
  bool _styleHasLoaded = false;

  /// What the map could not do: a style that failed to load, glyphs or sprites
  /// that could not be fetched, a command that could not be applied.
  ///
  /// Mirrors gl-js `map.on('error', …)`, as a `Stream` of a `sealed` type so a
  /// handler can switch over the cases exhaustively.
  ///
  /// Safe to listen to before the map exists — that is the point, since the
  /// most valuable error is a first style load that fails. Silent on tiers
  /// without the capability ([MapLibreCapabilities.events]).
  Stream<MapLibreError> get onError => _errors.stream;

  /// Fires every time a style finishes loading, not just the first.
  ///
  /// **This is the moment to re-apply anything added through
  /// [MapLibreLayersController]**: mbgl replaces the whole layer list on a style
  /// load, so every app-added source, layer and image is dropped, and
  /// [MapLibreMap.style] is a declarative property that can change on any
  /// rebuild. Mirrors gl-js `styledata`.
  ///
  /// Replays to a late subscriber: if a style has already loaded when you
  /// listen, you get one event immediately. Without that, whether an app heard
  /// about the FIRST load would depend on whether it subscribed before the map
  /// finished creating — and missing it means the layers mbgl dropped never
  /// come back.
  Stream<void> get onStyleLoaded async* {
    if (_styleHasLoaded) yield null;
    yield* _styleLoads.stream;
  }

  /// The id of an image a layer asked for that the style does not have.
  ///
  /// Register it with [MapLibreLayersController.addImage] or
  /// [MapLibreLayersController.addWidgetIcon] and the engine picks it up.
  /// Mirrors gl-js `styleimagemissing`.
  Stream<String> get onStyleImageMissing => _missingImages.stream;

  void _pipeEvents(MapLibreMapPlatformController platform) {
    if (platform is! MapLibreMapEvents) return;
    final events = platform as MapLibreMapEvents;
    _eventSubscriptions.addAll([
      events.onError.listen((e) {
        if (!_errors.isClosed) _errors.add(e);
      }),
      events.onStyleLoaded.listen((_) {
        _styleHasLoaded = true;
        if (!_styleLoads.isClosed) _styleLoads.add(null);
      }),
      events.onStyleImageMissing.listen((id) {
        if (!_missingImages.isClosed) _missingImages.add(id);
      }),
    ]);
  }

  Future<void> _unpipeEvents() async {
    final subscriptions = List<StreamSubscription<Object?>>.of(
      _eventSubscriptions,
    );
    _eventSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  /// Fires on every camera change — each gesture step, animation frame and
  /// imperative move — for code that must track the view, e.g. re-running
  /// [MapLibreLayersController.queryRenderedFeatures] to keep an overlay in
  /// sync with what the engine drew.
  ///
  /// Null before attach and on renderers that cannot report it. Prefer this to
  /// polling: it fires exactly when something changed, and not otherwise.
  /// Listeners run on the platform thread's frame cadence, so keep them cheap
  /// (or throttle) — a query is a round trip to the render thread.
  Listenable? get onCameraChanged {
    final platform = _platform;
    // Explicit cast rather than relying on promotion: MapLibreMapProjector
    // implements Listenable, but the CFE will not promote across this
    // capability check (analyze accepts it, the compiler does not).
    if (platform is MapLibreMapProjector) return platform as Listenable;
    return null;
  }

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
    layers.attachTo(null);
    await _unpipeEvents();
    await platform?.dispose();
    await _errors.close();
    await _styleLoads.close();
    await _missingImages.close();
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
    layers.attachTo(platform);
    _pipeEvents(platform);
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
    layers.attachTo(null);
    await _unpipeEvents();
    _styleHasLoaded = false;
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

  /// The platform controller's rotate/tilt handler when its renderer offers
  /// one; null otherwise. The widget uses this to decide whether to attach the
  /// twist and shove recognizers — pan and zoom work either way.
  ///
  /// Nothing public is added to [MapLibreMapController] for this: a rotate
  /// GESTURE is not an app-facing command, and the imperative case is already
  /// `controller.camera.move(...copyWith(bearing:))`.
  @internal
  MapLibreRotateHandler? get rotateHandler {
    final platform = _platform;
    return platform is MapLibreRotateHandler
        ? platform as MapLibreRotateHandler
        : null;
  }

  /// The platform controller's projector when its renderer supports anchoring
  /// widgets to geographic points (the default `mbgl-core` tiers); null on tiers
  /// that don't. The widget uses this to decide whether to render the marker
  /// overlay. Feature-detected like [gestureHandler].
  @internal
  MapLibreMapProjector? get projector {
    final platform = _platform;
    return platform is MapLibreMapProjector
        ? platform as MapLibreMapProjector
        : null;
  }

  /// Draws a 3D model inside the map engine, anchored to a geographic point.
  ///
  /// EXPERIMENTAL and imperative for now. The eventual API is a declarative
  /// `MapLibreMap(models: ...)` widget prop, mirroring `markers` under the
  /// three-bucket rule (mutable + declarative -> widget property); this exists so
  /// the renderer can be exercised before that lands. Expect it to change.
  ///
  /// Because the model is drawn by the engine it depth-occludes against 3D
  /// buildings, unlike a widget overlay. Silently does nothing on tiers whose
  /// renderer has no model support (feature-detected like [projector]).
  ///
  /// Throws [ArgumentError] if the `.glb` cannot be loaded, with the native
  /// reason.
  @experimental
  void addModel(MapLibreModel model) {
    final platform = _platform;
    if (platform is MapLibreModelHost) {
      (platform as MapLibreModelHost).addModel(model);
    }
  }

  /// Moves or re-orients a model added by [addModel], without re-uploading its
  /// geometry. Use this to animate a model along a path — re-adding it each
  /// frame would re-parse the whole `.glb` every time.
  @experimental
  void updateModel(MapLibreModel model) {
    final platform = _platform;
    if (platform is MapLibreModelHost) {
      (platform as MapLibreModelHost).updateModel(model);
    }
  }

  /// Frames the RENDERER has published, or null on tiers that cannot report it.
  ///
  /// Difference it over time for the map's true frame rate. A Flutter `Ticker`
  /// measures Flutter's vsync, which stays at the display rate however far behind
  /// the map falls, because the map is composited as a texture.
  @experimental
  int? get renderedFrameCount {
    final platform = _platform;
    return platform is MapLibreModelHost
        ? (platform as MapLibreModelHost).renderedFrameCount
        : null;
  }

  /// How many drawables one instance of the model at [assetPath] costs, or null
  /// if it is not loaded. For reporting real draw-call counts.
  @experimental
  int? modelPartCount(String assetPath) {
    final platform = _platform;
    return platform is MapLibreModelHost
        ? (platform as MapLibreModelHost).modelPartCount(assetPath)
        : null;
  }

  /// Removes a model added by [addModel]. See its caveats.
  @experimental
  void removeModel(String id) {
    final platform = _platform;
    if (platform is MapLibreModelHost) {
      (platform as MapLibreModelHost).removeModel(id);
    }
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

  /// Whether the bound platform tier's texture lags the widget box on resize
  /// (Windows), so the widget should **mask** resizes (hold the surface + cover-fit
  /// while dragging) instead of resizing live. False on tiers that resize cleanly
  /// (mobile/web/macOS). See [MapLibreResizeMaskHint].
  @internal
  bool get debounceResize => _platform is MapLibreResizeMaskHint;
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
