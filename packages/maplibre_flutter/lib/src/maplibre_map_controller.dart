import 'dart:async';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/animation.dart' show Cubic;
import 'package:flutter/painting.dart' show EdgeInsets;

import 'package:flutter/foundation.dart' show FlutterError, Listenable;

import 'package:maplibre_flutter_platform_interface/geojson.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:meta/meta.dart';

import 'map_style_controller.dart';

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

  /// The map's STYLE: engine-drawn sources, layers, images and the style-wide
  /// transition — the scalable annotation path for datasets past what widget
  /// markers can carry, with clustering built in.
  ///
  /// Mirrors Apple's `MLNStyle`, which owns exactly this set. See
  /// [MapLibreStyleController]; `style.isSupported` is false on renderers that
  /// cannot do it, and every call is then a no-op.
  ///
  /// Note this is a NAMESPACE, not a setter: the style DOCUMENT is the
  /// declarative [MapLibreMap.style] widget property, and there is deliberately
  /// no public `controller.setStyle` (CLAUDE.md §3).
  final MapLibreStyleController style = MapLibreStyleController();

  /// The style namespace.
  @Deprecated(
    'Renamed to controller.style: this owns sources, images and the style-wide '
    'transition as well as layers. Will be removed in a future release.',
  )
  MapLibreStyleController get layers => style;

  /// The features the engine actually drew inside [rect] (logical pixels in the
  /// map widget's own coordinate space).
  ///
  /// Queries live on the MAP, not on the style — both upstreams agree
  /// (gl-js `map.queryRenderedFeatures`, Apple `-visibleFeaturesInRect:`), and
  /// asking "what did you draw" is a question about the rendered map rather
  /// than about the style document.
  ///
  /// See [MapLibreStyleController.queryRenderedFeatures] for the full contract.
  List<QueriedFeature> queryRenderedFeatures(
    Rect rect, {
    List<String>? layerIds,
  }) => style.queryRenderedFeatures(rect, layerIds: layerIds);

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
  final StreamController<void> _idles = StreamController<void>.broadcast();
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

  // --- Camera lifecycle -------------------------------------------------------
  //
  // The REASON is synthesised here, not read from the engine: mbgl's own
  // `MapObserver` carries only `CameraChangeMode {Immediate, Animated}`, so
  // every SDK builds the richer reason in its platform layer. Ours is the Dart
  // gesture layer, which is the only thing in the stack that can tell a pan
  // from a pinch from a twist from a shove.

  final StreamController<Set<MapCameraChangeReason>> _moveStarts =
      StreamController<Set<MapCameraChangeReason>>.broadcast();
  final StreamController<Set<MapCameraChangeReason>> _moveEnds =
      StreamController<Set<MapCameraChangeReason>>.broadcast();
  Set<MapCameraChangeReason> _movingBecause = const {};

  /// Fires when the camera starts moving, saying why — gl-js `movestart`,
  /// Apple `-mapView:regionWillChangeWithReason:animated:`.
  ///
  /// The payload is a **Set**, because one gesture legitimately carries several
  /// reasons at once: a twisting pinch is `{gesturePinch, gestureRotate}`. It
  /// re-fires if a gesture grows a reason mid-flight, so a listener filtering on
  /// [MapCameraChangeReasons.isRotation] is not stuck with the first
  /// classification.
  ///
  /// This is NOT a replacement for [onCameraChanged], which is the cheap
  /// per-frame `Listenable` an overlay repaints from. These are the discrete
  /// bookends.
  Stream<Set<MapCameraChangeReason>> get onCameraMoveStart =>
      _moveStarts.stream;

  /// Fires when the camera stops moving, with the reasons it moved for — gl-js
  /// `moveend`, Apple `-mapView:regionDidChangeWithReason:animated:`.
  Stream<Set<MapCameraChangeReason>> get onCameraMoveEnd => _moveEnds.stream;

  /// Why the camera is moving right now; empty when it is still.
  Set<MapCameraChangeReason> get movingBecause => _movingBecause;

  /// Whether the camera is moving at all — gl-js `isMoving`.
  ///
  /// Covers gestures and programmatic transitions alike. mbgl has
  /// `Map::isPanning/isScaling/isRotating` too, but those are unbound and would
  /// need a render-thread round trip per call; this is synchronous and free
  /// because the Dart layer already knows.
  bool get isMoving => _movingBecause.isNotEmpty;

  /// Whether the zoom is changing — gl-js `isZooming`.
  bool get isZooming => _movingBecause.isZoom;

  /// Whether the bearing is changing — gl-js `isRotating`.
  bool get isRotating => _movingBecause.isRotation;

  /// Reports a camera movement's start or end. Called by the gesture layer and
  /// by the camera namespace; not app API.
  @internal
  void reportCameraMove(
    Set<MapCameraChangeReason> reasons, {
    required bool ended,
  }) {
    if (_disposed) return;
    if (ended) {
      if (_movingBecause.isEmpty) return; // nothing was started
      final was = _movingBecause;
      _movingBecause = const {};
      if (!_moveEnds.isClosed) _moveEnds.add(was);
      return;
    }
    _movingBecause = reasons;
    if (!_moveStarts.isClosed) _moveStarts.add(reasons);
  }

  /// The id of an image a layer asked for that the style does not have.
  ///
  /// Register it with [MapLibreLayersController.addImage] or
  /// [MapLibreLayersController.addWidgetIcon] and the engine picks it up.
  /// Mirrors gl-js `styleimagemissing`.
  Stream<String> get onStyleImageMissing => _missingImages.stream;

  /// Fires when the map has nothing left to draw or fetch — gl-js `idle`.
  ///
  /// The signal for "the map has SETTLED", which `onReady` is too early for and
  /// `onStyleLoaded` is orthogonal to: take a screenshot here, run a query
  /// against a fully-loaded view, or drop a loading indicator.
  ///
  /// It recurs — the map re-enters idle after every interaction — so treat it
  /// as a state, not a one-shot. Never fires on a renderer that cannot report
  /// it; check `capabilities` rather than waiting forever.
  Stream<void> get onIdle => _idles.stream;

  void _pipeEvents(MapLibreMapPlatformController platform) {
    if (platform is! MapLibreMapEvents) return;
    final events = platform as MapLibreMapEvents;
    _eventSubscriptions.addAll([
      events.onError.listen((e) {
        if (!_errors.isClosed) _errors.add(e);
      }),
      events.onStyleLoaded.listen((_) {
        _styleHasLoaded = true;
        // Replay before the app hears about the load, so an app listener that
        // inspects the style sees the finished picture rather than a half-built
        // one. (The engine has already replayed images and models by this point,
        // for the same reason.)
        style.replayRetained();
        if (!_styleLoads.isClosed) _styleLoads.add(null);
      }),
      events.onStyleImageMissing.listen((id) {
        if (!_missingImages.isClosed) _missingImages.add(id);
      }),
      events.onIdle.listen((_) {
        if (!_idles.isClosed) _idles.add(null);
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
    style.attachTo(null);
    await _unpipeEvents();
    await platform?.dispose();
    await _moveStarts.close();
    await _moveEnds.close();
    await _errors.close();
    await _styleLoads.close();
    await _idles.close();
    await _missingImages.close();
  }

  // ---------------------------------------------------------------------------
  // Widget glue — driven by [MapLibreMap], not app code.
  // ---------------------------------------------------------------------------

  /// Resolves a style specification to something the engine can load.
  ///
  /// Three forms are supported, and the engine already understood two: a URL,
  /// and the style DOCUMENT itself as JSON (the C shim sniffs a leading `{`).
  /// This adds the third — `asset://path/listed/in/pubspec.yaml` — by reading
  /// the Flutter asset here, because the engine has no idea what a Flutter
  /// asset is and the six platform packages should not each learn.
  static Future<String> _resolveStyle(String style) async {
    const prefix = 'asset://';
    if (!style.startsWith(prefix)) return style;
    final key = style.substring(prefix.length);
    try {
      return await rootBundle.loadString(key);
    } on FlutterError catch (error) {
      // A missing asset is a build-time mistake, so say which key failed
      // rather than handing the engine a string it will fail to parse.
      throw ArgumentError.value(
        style,
        'style',
        'no such Flutter asset "$key" — is it listed in pubspec.yaml? ($error)',
      );
    }
  }

  /// Binds this controller to a freshly created native map. Called by
  /// [MapLibreMap] when it mounts. Throws if the controller is already attached
  /// to a map or has been disposed.
  @internal
  Future<void> attach({
    required String styleUri,
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
      style: await _resolveStyle(styleUri),
      options: options,
    );
    // Disposed or detached while createMap was in flight — drop the native map.
    if (_disposed || !_attached) {
      await platform.dispose();
      return;
    }
    _platform = platform;
    style.attachTo(platform);
    _pipeEvents(platform);
    // Constraints BEFORE onReady completes, so app code that awaits onReady and
    // then moves the camera is already working against them.
    //
    // Honest about what this guarantees: the commands are queued immediately
    // after the native map exists, not passed into its construction, so the
    // engine may render at most one unconstrained frame. Passing them through
    // mbl_map_create would close that gap and is a wider ABI change than the
    // frame is worth.
    await _applyInitialConstraints(options);
    platform.onReady.then((_) {
      if (!_ready.isCompleted) _ready.complete();
    });
  }

  /// Pushes [MapOptions]'s camera constraints to the engine.
  Future<void> _applyInitialConstraints(MapOptions options) async {
    if (!options.hasConstraints) return;
    if (options.minZoom case final v?) await camera.setMinZoom(v);
    if (options.maxZoom case final v?) await camera.setMaxZoom(v);
    if (options.minPitch case final v?) await camera.setMinPitch(v);
    if (options.maxPitch case final v?) await camera.setMaxPitch(v);
    if (options.maxBounds case final v?) await camera.setMaxBounds(v);
  }

  /// Tears down the native map but leaves the controller reusable (re-[attach]
  /// is allowed). Called by the widget on unmount when it does **not** own the
  /// controller; the owner still calls [dispose].
  @internal
  Future<void> detach() async {
    final platform = _platform;
    _platform = null;
    _attached = false;
    style.attachTo(null);
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

  /// Where [point] falls on screen, in logical points with a top-left origin —
  /// gl-js `map.project`.
  ///
  /// Null before the first frame and on a tier that cannot project. Note this
  /// projects against the **presented** frame, not the newest camera: camera
  /// commands are applied on the render thread and usually run ahead of what is
  /// on screen, so projecting against the latest transform makes anchored
  /// overlays swim (CLAUDE.md §11).
  Offset? project(LatLng point) {
    final projector = this.projector;
    if (projector == null) return null;
    final out = <Offset>[Offset.zero];
    // Generation 0 means no frame has been presented, so `out` is untouched —
    // returning Offset.zero would be a plausible-looking wrong answer.
    if (projector.project(<LatLng>[point], out) == 0) return null;
    return out.single;
  }

  /// Projects many points in one call — gl-js has no equivalent, and this is
  /// the reason to have it: a marker overlay projects everything it draws on
  /// every camera tick, and one call per marker at 120 Hz is the difference
  /// between smooth and not.
  ///
  /// Returns null before the first frame or on a tier that cannot project.
  /// [visible] (same length as [points], if supplied) reports false for points
  /// behind the camera on a pitched view — which project to a meaningless
  /// position rather than simply being off screen.
  List<Offset>? projectAll(List<LatLng> points, {List<bool>? visible}) {
    final projector = this.projector;
    if (projector == null || points.isEmpty) return null;
    final out = List<Offset>.filled(points.length, Offset.zero);
    if (projector.project(points, out, visible: visible) == 0) return null;
    return out;
  }

  /// The geographic point under a screen position — gl-js `map.unproject`.
  ///
  /// Null before the first frame and on a tier that cannot project.
  LatLng? unproject(Offset screenPoint) => projector?.unproject(screenPoint);

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
  Future<void> setStyle(String styleUri) async {
    // Snapshot BEFORE the swap. This is the only moment it can be taken: the
    // style-loaded event fires after mbgl has already dropped everything.
    style.snapshotForRetain();
    await _platform?.setStyle(await _resolveStyle(styleUri));
  }

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
  ///
  /// Named for `MLNMapCamera` and for the platform interface beneath, both of
  /// which already say "camera"; Android's word for the same thing is
  /// `CameraPosition`, which is where the old name came from.
  Future<MapCamera> getCamera() async {
    final platform = _owner._platform;
    if (platform == null) {
      return _owner._options?.initialCamera ??
          const MapCamera(center: LatLng(0, 0));
    }
    return platform.getCamera();
  }

  /// The current camera.
  @Deprecated(
    'Renamed to getCamera(), matching MLNMapCamera and the platform interface. '
    'Will be removed in a future release.',
  )
  Future<MapCamera> getPosition() => getCamera();

  /// Moves the camera to [target], animating over [duration] when non-null.
  @Deprecated(
    'Split into jumpTo / easeTo / flyTo, which is what upstream calls these '
    'and what they actually are: move(duration:) was never an ease — it flew. '
    'Will be removed in a future release.',
  )
  Future<void> move(MapCamera target, {Duration? duration}) async =>
      _owner._platform?.moveCamera(target, duration: duration);

  // --- gl-js verbs ------------------------------------------------------------
  //
  // Every one of these runs in the ENGINE (mbgl has jumpTo/easeTo/flyTo
  // natively) on tiers that report [MapLibreCapabilities.cameraCommands], and
  // falls back to the old whole-camera `moveCamera` elsewhere so the web tiers
  // keep working.
  //
  // COMPLETION CONTRACT: the returned Future completes when the transition
  // ENDS, and a superseded transition completes rather than erroring — so
  // awaiting a flyTo that a gesture interrupts resolves instead of hanging.

  MapLibreCameraCommands? get _commands {
    final platform = _owner._platform;
    return platform is MapLibreCameraCommands
        ? platform as MapLibreCameraCommands
        : null;
  }

  /// Resolves [options] against the current camera, for the fallback path on
  /// tiers that cannot take a partial camera.
  Future<MapCamera> _resolve(CameraOptions options) async =>
      options.applyTo(await getCamera());

  /// Brackets a programmatic move with start/end reports, so
  /// [MapLibreMapController.onCameraMoveStart] fires for app-driven moves as
  /// well as gestures.
  ///
  /// [extra] adds to the reason set — `resetNorth` reports
  /// `{programmatic, resetNorth}`, exactly as Apple does.
  Future<void> _reported(
    Future<void> Function() move, {
    Set<MapCameraChangeReason> extra = const {},
  }) async {
    final reasons = {MapCameraChangeReason.programmatic, ...extra};
    _owner.reportCameraMove(reasons, ended: false);
    try {
      await move();
    } finally {
      _owner.reportCameraMove(reasons, ended: true);
    }
  }

  /// Applies [camera] instantly. Unset fields are left alone.
  ///
  /// ```dart
  /// // Zoom in without touching centre, bearing or pitch:
  /// await controller.camera.jumpTo(const CameraOptions(zoom: 12));
  /// ```
  Future<void> jumpTo(CameraOptions camera) => _reported(() async {
    final commands = _commands;
    if (commands != null) return commands.jumpTo(camera);
    await _owner._platform?.moveCamera(await _resolve(camera));
  });

  /// Transitions to [camera] along a straight, eased path — gl-js `easeTo`.
  ///
  /// This was simply unreachable before: the old `move(duration:)` stepped a
  /// flight arc, so an eased straight-line move had no API at all.
  Future<void> easeTo(
    CameraOptions camera, {
    Duration duration = const Duration(milliseconds: 300),
    Cubic? easing,
  }) => _reported(() async {
    final commands = _commands;
    if (commands != null) {
      return commands.easeTo(
        camera,
        animation: CameraAnimation(duration: duration, easing: easing),
      );
    }
    await _owner._platform?.moveCamera(
      await _resolve(camera),
      duration: duration,
    );
  });

  /// Transitions to [camera] along a van Wijk flight — gl-js `flyTo`.
  ///
  /// [apexZoom] is the zoom at the top of the arc (gl-js and mbgl both call it
  /// `minZoom`; renamed because `minZoom` already means a hard constraint on
  /// this same object). [speed] is in screenfuls per second, engine default 1.2.
  Future<void> flyTo(
    CameraOptions camera, {
    Duration? duration,
    Cubic? easing,
    double? speed,
    double? apexZoom,
  }) => _reported(() async {
    final commands = _commands;
    if (commands != null) {
      return commands.flyTo(
        camera,
        animation: CameraAnimation(
          duration: duration,
          easing: easing,
          speed: speed,
          apexZoom: apexZoom,
        ),
      );
    }
    await _owner._platform?.moveCamera(
      await _resolve(camera),
      duration: duration ?? const Duration(milliseconds: 1200),
    );
  });

  /// Frames [bounds] under [padding] — gl-js `fitBounds`.
  Future<void> fitBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    double? bearing,
    double? pitch,
    CameraTransition transition = CameraTransition.ease,
    Duration duration = const Duration(milliseconds: 500),
  }) async {
    final commands = _commands;
    if (commands == null) return;
    return commands.fitBounds(
      bounds,
      padding: padding,
      bearing: bearing,
      pitch: pitch,
      transition: transition,
      animation: CameraAnimation(duration: duration),
    );
  }

  /// The camera that would frame [bounds], without moving — gl-js
  /// `cameraForBounds`. Null on tiers without the capability.
  Future<CameraOptions?> cameraForBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    double? bearing,
    double? pitch,
  }) async => _commands?.cameraForBounds(
    bounds,
    padding: padding,
    bearing: bearing,
    pitch: pitch,
  );

  /// The geographic area currently on screen — gl-js `getBounds`.
  Future<LatLngBounds?> getBounds() async => _commands?.getBounds();

  /// Pans by a screen-space delta, in logical pixels — gl-js `panBy`.
  ///
  /// **Positive [offset] moves the CONTENT that way**, i.e. `panBy(Offset(100,
  /// 0))` does what dragging 100 px to the right does. That is this plugin's
  /// own drag convention, which is verified on hardware
  /// ([MapLibreGestureHandler.moveBy] takes the finger delta unchanged).
  ///
  /// gl-js negates its argument internally before handing it on, so its sign
  /// may be the opposite; maplibre-gl-js is not vendored here, so that is
  /// recorded as unchecked rather than claimed either way. Match the drag.
  Future<void> panBy(
    Offset offset, {
    Duration duration = const Duration(milliseconds: 300),
  }) async {
    final current = await getCamera();
    // Composed rather than bound to Map::moveBy, because moveBy has no
    // animation on our C ABI and the eased version is the useful one.
    final platform = _owner._platform;
    if (platform is! MapLibreMapProjector) return;
    final projector = platform as MapLibreMapProjector;
    final centre = <Offset>[Offset.zero];
    projector.project(<LatLng>[current.center], centre);
    final target = projector.unproject(centre.single - offset);
    if (target == null) return;
    await easeTo(CameraOptions(center: target), duration: duration);
  }

  /// Pans to [center] — gl-js `panTo`.
  Future<void> panTo(
    LatLng center, {
    Duration duration = const Duration(milliseconds: 300),
  }) => easeTo(CameraOptions(center: center), duration: duration);

  /// Zooms to an absolute level — gl-js `zoomTo`.
  ///
  /// [around] holds a screen point fixed instead of the centre. **Do not pass a
  /// centre alongside it** — mbgl discards the anchor whenever a centre is set.
  Future<void> zoomTo(double zoom, {Offset? around, Duration? duration}) async {
    final camera = CameraOptions(zoom: zoom, anchor: around);
    if (duration == null) return jumpTo(camera);
    return easeTo(camera, duration: duration);
  }

  /// Zooms in one level — gl-js `zoomIn`.
  Future<void> zoomIn({Offset? around, Duration? duration}) async =>
      zoomTo((await getCamera()).zoom + 1, around: around, duration: duration);

  /// Zooms out one level — gl-js `zoomOut`.
  Future<void> zoomOut({Offset? around, Duration? duration}) async =>
      zoomTo((await getCamera()).zoom - 1, around: around, duration: duration);

  /// Turns to an absolute bearing in degrees clockwise from north — gl-js
  /// `rotateTo`. [around] holds a screen point fixed; see [zoomTo].
  Future<void> rotateTo(
    double bearing, {
    Offset? around,
    Duration? duration,
  }) async {
    final camera = CameraOptions(bearing: bearing, anchor: around);
    if (duration == null) return jumpTo(camera);
    return easeTo(camera, duration: duration);
  }

  /// Puts north back at the top — gl-js `resetNorth`.
  Future<void> resetNorth({
    Duration duration = const Duration(milliseconds: 300),
  }) => _reported(
    () => easeTo(const CameraOptions(bearing: 0), duration: duration),
    // Apple gives the compass tap its own reason rather than folding it into
    // `programmatic`, and it is genuinely useful: it is the one "programmatic"
    // move a USER asked for.
    extra: {MapCameraChangeReason.resetNorth},
  );

  /// Levels the map — gl-js `resetNorthPitch` without the north half.
  Future<void> resetPitch({
    Duration duration = const Duration(milliseconds: 300),
  }) => easeTo(const CameraOptions(pitch: 0), duration: duration);

  /// Stops any transition in flight, leaving the camera where it reached —
  /// gl-js `stop`.
  Future<void> stop() async {
    await _commands?.stopCamera();
    // Apple reports an interrupted transition as its own reason; do the same,
    // so a listener can tell "arrived" from "was cut short".
    _owner.reportCameraMove(const {
      MapCameraChangeReason.transitionCancelled,
    }, ended: true);
  }

  // --- Constraints ------------------------------------------------------------

  /// Constrains the area the camera may show — gl-js `setMaxBounds`.
  ///
  /// **gl-js semantics**, deliberately: the whole VIEWPORT is kept inside
  /// [bounds]. mbgl's own `BoundOptions::bounds` constrains only the camera
  /// CENTRE under the same word, so this also sets the constrain mode. Pass
  /// null to remove the constraint.
  Future<void> setMaxBounds(LatLngBounds? bounds) async {
    final commands = _commands;
    if (commands == null) return;
    await commands.setConstrainToBounds(wholeViewport: bounds != null);
    await commands.setCameraConstraints(
      MapCameraConstraints(bounds: bounds ?? LatLngBounds.world()),
    );
  }

  /// The current max-bounds constraint, if any.
  Future<LatLngBounds?> getMaxBounds() async =>
      (await _commands?.getCameraConstraints())?.bounds;

  /// The furthest out the camera may zoom — gl-js `setMinZoom`.
  Future<void> setMinZoom(double minZoom) async =>
      _commands?.setCameraConstraints(MapCameraConstraints(minZoom: minZoom));

  /// The closest in the camera may zoom — gl-js `setMaxZoom`.
  Future<void> setMaxZoom(double maxZoom) async =>
      _commands?.setCameraConstraints(MapCameraConstraints(maxZoom: maxZoom));

  /// The flattest pitch, in degrees — gl-js `setMinPitch`.
  Future<void> setMinPitch(double minPitch) async =>
      _commands?.setCameraConstraints(MapCameraConstraints(minPitch: minPitch));

  /// The steepest pitch, in degrees — gl-js `setMaxPitch`.
  ///
  /// **mbgl clamps to 60° regardless**, so a larger value is silently reduced.
  Future<void> setMaxPitch(double maxPitch) async =>
      _commands?.setCameraConstraints(MapCameraConstraints(maxPitch: maxPitch));

  /// Every camera limit currently in force.
  Future<MapCameraConstraints?> getConstraints() async =>
      _commands?.getCameraConstraints();
}
