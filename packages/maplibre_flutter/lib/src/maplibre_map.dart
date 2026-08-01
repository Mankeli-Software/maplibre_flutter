import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'maplibre_map_controller.dart';
import 'marker.dart';
import 'marker_overlay.dart';

/// The public map widget.
///
/// Renders a MapLibre map natively on every platform. Internally it asks the
/// registered [MapLibreFlutterPlatform] to create a map, then embeds the result
/// based on its [MapLibreRenderHandle]: a platform view on mobile/web or a
/// [Texture] on desktop. The branch is an implementation detail — callers see
/// one widget and one [MapLibreMapController].
///
/// Drive the map with a [MapLibreMapController]: construct one, pass it as
/// [controller], and call its methods once [MapLibreMapController.onReady]
/// completes. Omit [controller] and the widget creates and owns one internally.
class MapLibreMap extends StatefulWidget {
  const MapLibreMap({
    super.key,
    required this.style,
    this.controller,
    this.options = const MapOptions(),
    this.markers = const <MapLibreMarker>[],
    this.models = const <MapLibreModel>[],
    this.onTap,
    this.onStyleLoaded,
    this.rotateGesturesEnabled = true,
    this.tiltGesturesEnabled = true,
    this.retainRuntimeStyle = false,
  });

  /// The MapLibre style, in any of three forms:
  ///
  /// * a **URL** — `https://demotiles.maplibre.org/style.json`;
  /// * the **document itself** as JSON — anything starting with `{`;
  /// * a **Flutter asset** — `asset://assets/styles/dark.json`, which must be
  ///   listed in your `pubspec.yaml`.
  ///
  /// Declarative — change it (e.g. via `setState`) to switch styles at runtime.
  /// This is the single source of truth for the map's style (CLAUDE.md §3).
  ///
  /// **A style load drops every source and layer added through
  /// `controller.style`**, so re-apply them from [onStyleLoaded] rather than
  /// after a delay — or set [retainRuntimeStyle] and let the widget do it.
  final String style;

  /// Flutter widgets glued to geographic points, composited above the map and
  /// kept locked to their points as the map moves (see [MapLibreMarker]).
  /// Declarative — change the list (e.g. via `setState`) to add/move/remove them.
  /// Rendered only on tiers whose renderer can project coordinates (the default
  /// `mbgl-core` tiers); ignored elsewhere.
  final List<MapLibreMarker> markers;

  /// 3D models drawn INSIDE the map engine and anchored to geographic points.
  ///
  /// Declarative — change the list (e.g. via `setState`) to add, move or remove
  /// them. Unlike [markers], which are Flutter widgets composited above the map,
  /// these are real geometry in the scene, so they depth-occlude against 3D
  /// buildings and each other.
  ///
  /// Rendered only on tiers whose renderer supports models (the default
  /// `mbgl-core` tiers); ignored elsewhere.
  ///
  /// For PER-FRAME animation (driving a model along a route) prefer the
  /// controller's `updateModel`: rebuilding the widget tree every frame to move a
  /// model is the wrong tool, and the same high-frequency reasoning is why the
  /// camera is imperative (CLAUDE.md §3 three-bucket rule).
  final List<MapLibreModel> models;

  /// Called when the map (not a marker) is tapped, with the geographic point
  /// under the tap. Only fires on tiers that can project coordinates.
  final ValueChanged<LatLng>? onTap;

  /// Called each time a style finishes loading — **every** time, including
  /// after [style] changes, not just the first.
  ///
  /// This is the moment to re-apply anything added through
  /// `controller.layers`: mbgl replaces the entire layer list on a style load,
  /// so every app-added source, layer and image is dropped. Since [style] is a
  /// declarative property that can change on any rebuild, there is no other
  /// correct moment — before this existed the workaround was a hardcoded delay.
  ///
  /// Mirrors gl-js `styledata`. Only fires on tiers that report engine events
  /// ([MapLibreCapabilities.events]).
  final VoidCallback? onStyleLoaded;

  /// Whether the user can turn the map — a two-finger twist, or a
  /// secondary-button / ctrl drag with a mouse.
  ///
  /// A widget prop rather than a [MapOptions] field, per the three-bucket rule:
  /// this is mutable, declarative and low-frequency. [MapOptions] is init-only
  /// and is handed to `createMap`, so it never reaches the gesture layer, which
  /// lives entirely in the widget.
  ///
  /// Has no effect on tiers whose renderer handles its own gestures.
  final bool rotateGesturesEnabled;

  /// Whether the user can tilt the map — a two-finger vertical "shove", or the
  /// vertical component of a secondary-button / ctrl drag.
  ///
  /// The engine clamps pitch to 0..60 degrees.
  final bool tiltGesturesEnabled;

  /// Optional externally-owned controller for driving the map imperatively.
  ///
  /// Omit it and the widget creates and owns one (disposed when the widget is
  /// removed). When provided, **you** own it: call
  /// [MapLibreMapController.dispose] when done. One controller per map.
  final MapLibreMapController? controller;

  /// Init-only configuration (e.g. the initial camera). Changes after the first
  /// build are ignored; use the [controller] for runtime camera moves.
  final MapOptions options;

  /// Carry app-added sources and layers across a style change.
  ///
  /// Off by default, which is the behaviour of every upstream binding: mbgl
  /// drops the whole document on load, and gl-js, the Apple SDK
  /// (`MLNStyle.h:32-36`) and the Android SDK all tell you to re-add from the
  /// style-loaded event. [onStyleLoaded] is that event.
  ///
  /// Turn it on and the widget snapshots each source and layer **as it stands**
  /// just before the swap — including every `setPaintProperty`, `setFilter` and
  /// `setLayerZoomRange` applied since it was added — and re-adds them once the
  /// new style is in, before [onStyleLoaded] fires.
  ///
  /// Two things to know before you rely on it:
  ///
  /// * **Do not also re-add from [onStyleLoaded].** Both will run, the second
  ///   add fails, and the failure arrives on `controller.onError`. Pick one.
  /// * **Layers land on top** of the new document, in the order you added them.
  ///   `beforeId` is not restored, because it named a layer in the OUTGOING
  ///   document that the incoming one need not contain. If your layers have to
  ///   sit under the new basemap's labels, leave this off and place them
  ///   yourself from [onStyleLoaded], where you know what the new document has.
  ///
  /// Runtime images and 3D models are retained by the engine either way — they
  /// have no form in a style document, so nothing else could put them back.
  final bool retainRuntimeStyle;

  @override
  State<MapLibreMap> createState() => _MapLibreMapState();
}

class _MapLibreMapState extends State<MapLibreMap> {
  // Set only when the widget owns the controller (none was provided).
  MapLibreMapController? _internalController;
  MapLibreMapController get _controller =>
      widget.controller ?? _internalController!;

  Future<void>? _attach;
  StreamSubscription<void>? _styleLoads;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _internalController = MapLibreMapController();
    }
    // Subscribe BEFORE attaching: the first style load is the one an app most
    // wants to hear about, and it can complete before attach's future does.
    _styleLoads = _controller.onStyleLoaded.listen((_) {
      if (mounted) widget.onStyleLoaded?.call();
    });
    _controller.style.retainRuntimeStyle = widget.retainRuntimeStyle;
    _attach = _controller.attach(
      styleUri: widget.style,
      options: widget.options,
    );
    _applyModelsWhenAttached(const <MapLibreModel>[], widget.models);
  }

  /// Applies a model diff once the native map exists.
  ///
  /// Loading parses the `.glb` synchronously and throws on a bad file, so failures
  /// are reported through [FlutterError] rather than becoming an unhandled async
  /// error or a silently missing model.
  void _applyModelsWhenAttached(
    List<MapLibreModel> previous,
    List<MapLibreModel> next,
  ) {
    _attach?.then((_) {
      if (!mounted) return;
      _syncModels(previous, next);
    });
  }

  void _syncModels(List<MapLibreModel> previous, List<MapLibreModel> next) {
    final before = <String, MapLibreModel>{for (final m in previous) m.id: m};
    final after = <String, MapLibreModel>{for (final m in next) m.id: m};

    for (final id in before.keys) {
      if (!after.containsKey(id)) _controller.removeModel(id);
    }
    for (final model in next) {
      final old = before[model.id];
      try {
        if (old == null || !model.isSamePlacementSourceAs(old)) {
          // New, a different mesh, or a changed spin: has to be (re)loaded.
          _controller.addModel(model);
        } else if (model != old) {
          // Placement only — move it in place. Re-adding would re-parse the
          // whole .glb, which for a real model is tens of megabytes.
          _controller.updateModel(model);
        }
      } on ArgumentError catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'maplibre_flutter',
            context: ErrorDescription(
              'while loading model "${model.id}" from "${model.assetPath}"',
            ),
          ),
        );
      }
    }
  }

  @override
  void didUpdateWidget(MapLibreMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      // The controller was swapped. Release the old binding (dispose if we
      // owned it, else just detach the native map), then attach the new one.
      if (oldWidget.controller == null) {
        _internalController?.dispose();
        _internalController = null;
      } else {
        oldWidget.controller!.detach();
      }
      if (widget.controller == null) {
        _internalController = MapLibreMapController();
      }
      // Only now is `_controller` safe to read: swapping a provided controller
      // for none leaves BOTH null until the line above runs.
      _controller.style.retainRuntimeStyle = widget.retainRuntimeStyle;
      setState(() {
        _attach = _controller.attach(
          styleUri: widget.style,
          options: widget.options,
        );
      });
    } else {
      // Sync the flag BEFORE the style push: flipping retainRuntimeStyle on in
      // the same rebuild that changes the style should retain, not miss by one.
      _controller.style.retainRuntimeStyle = widget.retainRuntimeStyle;
      if (widget.style != oldWidget.style) {
        // Declarative style: push the new style to the native map.
        _controller.setStyle(widget.style);
      }
    }
    if (!identical(widget.models, oldWidget.models)) {
      // A style change drops custom layers, but the core re-adds retained models
      // itself, so this only has to handle what the caller actually changed.
      _applyModelsWhenAttached(oldWidget.models, widget.models);
    }
  }

  @override
  void dispose() {
    _styleLoads?.cancel();
    _styleLoads = null;
    // Dispose the controller only if we created it; otherwise just tear down the
    // native map and leave the owner's controller object intact.
    if (widget.controller == null) {
      _internalController?.dispose();
    } else {
      widget.controller!.detach();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _attach,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            _controller.renderHandle == null) {
          return const SizedBox.shrink();
        }
        return _MapEmbed(
          controller: _controller,
          markers: widget.markers,
          onTap: widget.onTap,
          rotateGesturesEnabled: widget.rotateGesturesEnabled,
          tiltGesturesEnabled: widget.tiltGesturesEnabled,
        );
      },
    );
  }
}

/// Resolves the render split (CLAUDE.md §3) to a concrete embed widget. This is
/// the only place that branches on [MapLibreRenderHandle].
class _MapEmbed extends StatelessWidget {
  const _MapEmbed({
    required this.controller,
    this.markers = const <MapLibreMarker>[],
    this.onTap,
    this.rotateGesturesEnabled = true,
    this.tiltGesturesEnabled = true,
  });

  final MapLibreMapController controller;
  final List<MapLibreMarker> markers;
  final ValueChanged<LatLng>? onTap;
  final bool rotateGesturesEnabled;
  final bool tiltGesturesEnabled;

  @override
  Widget build(BuildContext context) {
    final handle = controller.renderHandle!;
    Widget map;
    switch (handle) {
      case TextureHandle(:final textureId):
        map = _TextureMapView(
          controller: controller,
          textureId: textureId,
          rotateGesturesEnabled: rotateGesturesEnabled,
          tiltGesturesEnabled: tiltGesturesEnabled,
        );
      case PlatformViewHandle():
        map = _PlatformView(handle: handle);
      case ElementViewHandle(:final viewType):
        // Web tier: the maplibre-gl-js map is the host `<div>` registered under
        // [viewType] by the web controller's view factory. It is the top DOM
        // element, so it receives pointer/scroll/gesture events natively — no
        // Dart gesture layer (web mirrors the mobile tier, CLAUDE.md §3).
        // Flutter widgets drawn *over* the map need `PointerInterceptor`
        // (handled by the app, e.g. the example's controls), not the map itself.
        map = HtmlElementView(viewType: viewType);
    }

    // Anchored widgets need a projector. Absent one (a tier that can't project),
    // skip the overlay + map-tap entirely — graceful degradation (CLAUDE.md §3).
    final projector = controller.projector;
    if (projector == null) return map;

    // Map taps: a tap on a marker is consumed by the marker (it sits on top of
    // the Stack, so it is hit-tested first); a tap on empty space falls through
    // the (transparent) overlay to this detector and reports a LatLng.
    if (onTap case final onTap?) {
      map = GestureDetector(
        onTapUp: (details) {
          final point = projector.unproject(details.localPosition);
          if (point != null) onTap(point);
        },
        child: map,
      );
    }

    if (markers.isEmpty) return map;
    return Stack(
      fit: StackFit.expand,
      children: [
        map,
        Positioned.fill(
          child: MarkerOverlay(projector: projector, markers: markers),
        ),
      ],
    );
  }
}

/// Desktop tier: embeds the rendered map [Texture]. Reports the view's size +
/// DPR so the core renders at the right resolution and aspect ratio (and follows
/// window resizes), and drives pan/zoom from Flutter gestures when the controller
/// supports it (CLAUDE.md §3: the desktop tier handles gestures in Dart).
///
/// On tiers whose texture *lags* the widget box during a resize
/// ([MapLibreMapController.debounceResize] — the Windows CPU-readback present), it
/// also **masks** the resize: while the window is actively being dragged it holds
/// the core at one size and cover-fits that frozen frame to the moving box (a
/// small uniform crop, not a stretch), pushing the real resize once the drag
/// settles. Because the widget itself decides when to resize, it always knows the
/// frozen frame's size ([_committedSize]) — no produced-size feedback needed.
class _TextureMapView extends StatefulWidget {
  const _TextureMapView({
    required this.controller,
    required this.textureId,
    this.rotateGesturesEnabled = true,
    this.tiltGesturesEnabled = true,
  });

  final MapLibreMapController controller;
  final int textureId;
  final bool rotateGesturesEnabled;
  final bool tiltGesturesEnabled;

  @override
  State<_TextureMapView> createState() => _TextureMapViewState();
}

class _TextureMapViewState extends State<_TextureMapView> {
  // Masked tiers only: the size the core is currently rendering — i.e. the size
  // of the frame the texture is showing. We cover-fit this frozen frame to the
  // (possibly different) box while a drag is in flight. Null until the first
  // layout / on non-masked tiers (which resize live and render the bare texture).
  Size? _committedSize;
  Timer? _resizeDebounce;

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    super.dispose();
  }

  // Drive the core's resize during layout (before paint), the desktop-core analog
  // of the web tier's ResizeObserver-driven resize. On masked tiers, debounce it
  // during an active drag so the produced frame stays frozen at [_committedSize]
  // (giving the cover-fit below a stable, known size to mask with) and apply the
  // first sizing immediately so the map fills the window on load. Other tiers
  // resize live every layout — their present catches up within ~a frame.
  void _syncSize(Size size, double dpr) {
    if (!size.isFinite || size.isEmpty) return;
    if (!widget.controller.debounceResize) {
      widget.controller.resize(size, dpr);
      return;
    }
    if (_committedSize == null) {
      _committedSize = size; // first sizing: apply immediately
      widget.controller.resize(size, dpr);
      return;
    }
    if (size == _committedSize) return;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      widget.controller.resize(size, dpr);
      setState(() => _committedSize = size);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        _syncSize(size, dpr);

        Widget map = Texture(textureId: widget.textureId);

        // Mask the resize stretch on lagging tiers: cover-fit the frozen frame
        // (rendered at [_committedSize]) to the current box UNIFORMLY, so it crops
        // slightly instead of stretching. In steady state _committedSize == box,
        // so cover is an exact uniform scale (no crop) — identical to the bare
        // texture. Gestures wrap OUTSIDE this fit stack so pointer coordinates stay
        // in widget-box (logical) space.
        final committed = _committedSize;
        if (committed != null && size.isFinite && !size.isEmpty) {
          map = SizedBox.fromSize(
            size: size,
            child: ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox.fromSize(size: committed, child: map),
              ),
            ),
          );
        }

        if (widget.controller.gestureHandler case final gestures?) {
          map = _DesktopMapGestures(
            handler: gestures,
            onCameraMove: widget.controller.reportCameraMove,
            // Null on a tier without the capability, which simply means no
            // rotate or tilt — pan and zoom are unaffected.
            rotator: widget.controller.rotateHandler,
            rotateEnabled: widget.rotateGesturesEnabled,
            tiltEnabled: widget.tiltGesturesEnabled,
            child: map,
          );
        }
        return map;
      },
    );
  }
}

/// Embeds a native view. The mobile tier reaches here: Android composites the
/// map's `SurfaceView` via Hybrid Composition, iOS embeds `MLNMapView` via
/// `UiKitView`. The concrete view factory is registered by each platform
/// package.
class _PlatformView extends StatelessWidget {
  const _PlatformView({required this.handle});

  final PlatformViewHandle handle;

  @override
  Widget build(BuildContext context) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _AndroidView(handle: handle);
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: handle.viewType,
          creationParams: handle.creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
      default:
        return _UnimplementedEmbed(
          label: 'platform view "${handle.viewType}" on $defaultTargetPlatform',
        );
    }
  }
}

/// Android embed via **Hybrid Composition** (`PlatformViewLink` +
/// `PlatformViewsService.initSurfaceAndroidView`), so the map's `SurfaceView`
/// composites directly in the view hierarchy with correct gestures and
/// accessibility — unlike the plain `AndroidView` (texture-layer) path, which
/// shunts SurfaceViews into a virtual display. On capable devices (Flutter
/// 3.44+, Android API 34+, Vulkan) this is transparently upgraded to Hybrid
/// Composition Plus (HCPP) when the app manifest sets
/// `io.flutter.embedding.android.EnableHcpp`; otherwise it falls back to
/// classic Hybrid Composition.
class _AndroidView extends StatelessWidget {
  const _AndroidView({required this.handle});

  final PlatformViewHandle handle;

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: handle.viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        );
      },
      onCreatePlatformView: (params) {
        return PlatformViewsService.initSurfaceAndroidView(
            id: params.id,
            viewType: handle.viewType,
            layoutDirection: TextDirection.ltr,
            creationParams: handle.creationParams,
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
    );
  }
}

class _UnimplementedEmbed extends StatelessWidget {
  const _UnimplementedEmbed({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    assert(() {
      debugPrint('MapLibreMap: embedding for $label not wired yet.');
      return true;
    }());
    return const SizedBox.shrink();
  }
}

/// Translates pointer gestures over a desktop map `Texture` into relative camera
/// moves on a [MapLibreGestureHandler]: drag (or trackpad) pans, pinch or the
/// scroll wheel zooms about the pointer. The desktop tier handles gestures in
/// Dart so every desktop platform shares this behaviour (CLAUDE.md §3).
/// What a single gesture has committed to doing.
///
/// Latched on the first threshold crossing and held until the gesture ends, so
/// the recognizers cannot bleed into one another.
/// `none` doubles as "pan/zoom", which is the default behaviour: it is NOT
/// latched, so rotate and shove stay able to take over the moment they cross
/// their thresholds. Latching a pan mode on the first update — when rotation is
/// necessarily still ~0 — makes rotation permanently unreachable.
enum _GestureMode { none, rotate, shove }

class _DesktopMapGestures extends StatefulWidget {
  const _DesktopMapGestures({
    required this.handler,
    required this.child,
    this.rotator,
    this.rotateEnabled = true,
    this.tiltEnabled = true,
    this.onCameraMove,
  });

  final MapLibreGestureHandler handler;
  final MapLibreRotateHandler? rotator;
  final bool rotateEnabled;
  final bool tiltEnabled;

  /// Reports the start and end of a user-driven camera change, and WHY.
  ///
  /// This layer is the only thing in the stack that knows a pan from a pinch
  /// from a twist from a shove: mbgl's own `CameraChangeMode` is just
  /// `{Immediate, Animated}`, so every SDK synthesises the richer reason in its
  /// platform layer. Ours is in Dart, which is a structural advantage worth
  /// banking rather than an accident.
  final void Function(
    Set<MapCameraChangeReason> reasons, {
    required bool ended,
  })?
  onCameraMove;

  final Widget child;

  @override
  State<_DesktopMapGestures> createState() => _DesktopMapGesturesState();
}

class _DesktopMapGesturesState extends State<_DesktopMapGestures>
    with SingleTickerProviderStateMixin {
  Offset _lastFocalPoint = Offset.zero;
  double _lastScale = 1;

  // Which interaction this gesture has committed to, latched on the first
  // threshold crossing and held until the gesture ends.
  //
  // Without a latch the recognizers bleed into each other: a twist drags the
  // map with it, and a shove both zooms and turns. The MapLibre Android SDK
  // does the same — its shove is mutually exclusive with scale AND rotate, and
  // it disables the move gesture outright while shoving
  // (MapGestureDetector.java).
  _GestureMode _mode = _GestureMode.none;

  /// The reasons reported for the gesture in progress, or null between them.
  ///
  /// Accumulated rather than decided up front, because one gesture legitimately
  /// carries several: a twisting pinch is `{gesturePinch, gestureRotate}`, which
  /// is exactly why the payload is a Set and not a single value.
  Set<MapCameraChangeReason>? _liveReasons;

  /// Starts (or widens) the reported reason set for the gesture in progress.
  void _reportReason(MapCameraChangeReason reason) {
    final live = _liveReasons;
    if (live == null) {
      _liveReasons = {reason};
      widget.onCameraMove?.call({reason}, ended: false);
      return;
    }
    if (live.add(reason)) {
      // A gesture that grows a second reason mid-flight — a pinch that starts
      // twisting — re-reports rather than staying silent, so a listener
      // filtering on `isRotation` is not stuck with the first classification.
      widget.onCameraMove?.call(Set.of(live), ended: false);
    }
  }

  /// Ends the reported gesture, if one was reported.
  void _endReasons() {
    final live = _liveReasons;
    _liveReasons = null;
    if (live != null) widget.onCameraMove?.call(live, ended: true);
  }

  // ScaleUpdateDetails.rotation is CUMULATIVE radians since the gesture began,
  // not a per-frame delta — applying it directly would spin the map by an
  // ever-growing amount every frame.
  //
  // Worse, it arrives WRAPPED. Flutter derives it from atan2 differences, so a
  // geometric 4.6-degree twist can be reported as -6.203 rad — the same angle
  // the other way round. Comparing that raw value against a deadzone means the
  // deadzone is exceeded on the very first update of any two-finger gesture, so
  // a pinch would immediately latch to rotate; measured, not assumed, from an
  // instrumented run. Hence: unwrap each frame's delta into (-pi, pi] and keep
  // our own running total to threshold against.
  double _lastRawRotation = 0;
  double _rotationAccum = 0;
  Offset _rotateAnchor = Offset.zero;

  /// Wraps [radians] into (-pi, pi].
  static double _normalizeAngle(double radians) {
    const twoPi = 2 * math.pi;
    var x = radians % twoPi;
    if (x > math.pi) x -= twoPi;
    if (x <= -math.pi) x += twoPi;
    return x;
  }

  // Where each pointer was when the shove detector last sampled, so the
  // per-finger dy can be measured. ScaleUpdateDetails carries only a focal
  // point, a scale and a rotation — no per-pointer positions — which is why a
  // shove cannot be recognised from it at all (see [_maybeShove]).
  final Map<int, Offset> _shoveOrigin = <int, Offset>{};

  // Secondary-button / ctrl drag: the mouse path to rotate and tilt, since a
  // mouse can neither twist nor shove. Without it, rotation is unreachable on
  // Windows, Linux and macOS-with-a-mouse.
  int? _dragRotatePointer;
  Offset _dragRotateLast = Offset.zero;

  // Anchor a pinch zooms about. Tracks the focal point while the gesture is only
  // panning, then FREEZES at pinch onset and stays put for the rest of the zoom.
  // Rationale: a trackpad pinch on Windows/Linux arrives as a two-finger scale
  // gesture whose focal *centroid drifts* as the fingers spread (macOS instead
  // reports the stable cursor). Zooming about the live, drifting centroid — and
  // panning by its delta — slid the map away from the cursor. A frozen anchor
  // makes pinch zoom about a stable point (≈ the cursor) on every desktop tier;
  // it's a no-op on macOS, where the focal doesn't drift.
  Offset _zoomAnchor = Offset.zero;

  // Pan inertia ("fling"): on release with velocity, ease the camera by a glide
  // offset over a computed duration, so the custom rendering engines (desktop core
  // + core-on-mobile) feel like the native SDKs / gl-js. The model is ported from
  // the MapLibre Native Android SDK (MapGestureDetector.onFling): both the glide
  // offset and the animation duration scale with the release speed, so the fling
  // correlates with how hard you flicked — bounded by a speed cap + a max distance.
  Ticker? _inertiaTicker;
  Offset _flingOffset = Offset.zero; // total glide for this fling (logical px)
  double _flingDurationMs = 0;
  Offset _flingApplied = Offset.zero; // glide applied so far (logical px)

  // Only fling if released faster than this (ignore slow/precise drags).
  static const double _inertiaStartSpeed = 120; // logical px/s
  // Cap the release speed. The Android SDK leans on the OS max-fling velocity; we
  // cap explicitly so a velocity spike can't produce a runaway glide.
  static const double _inertiaMaxSpeed = 5000; // logical px/s
  // SDK fling formula (MapGestureDetector.onFling):
  //   animationTime(ms) = speed / (7 / tiltFactor) + base
  // tiltFactor is 1.5 in the 2D (no-tilt) case → divisor 10.5; base is the SDK's
  // ANIMATION_DURATION_FLING_BASE. Clamp very fast flicks to a max duration.
  static const double _flingTimeDivisor = 10.5;
  static const double _flingBaseTimeMs = 150;
  static const double _flingMaxTimeMs = 1000;
  // SDK glide factor (their 0.28): offset = velocity * animationTime * factor,
  // tuned so the glide begins ≈ at the pre-release pan speed.
  static const double _flingOffsetFactor = 0.28;
  // Hard cap on glide distance — "a max distance the map can move even for a very
  // fast flick" (the Google-Maps-like bound the velocity cap also enforces).
  static const double _flingMaxDistance = 1000; // logical px
  // Floor for a velocity sample's dt. High-refresh (120Hz ProMotion) and coalesced
  // touch events can fire sub-millisecond apart; a tiny dt makes the instantaneous
  // pdx/dt explode into a bogus multi-thousand-px/s spike that the EMA latches onto
  // (the "a small flick spins the world 10-20× at zoom 0" bug). One ~120Hz frame.
  static const double _minVelocitySampleDt = 1 / 120; // ≈ 0.0083 s

  // We track the drag velocity ourselves (EMA of focal deltas over time) rather
  // than trusting ScaleEndDetails.velocity, which is unreliable / often ~zero for
  // single-pointer drags — that was why the fling never fired on the desktop/core
  // tier. Mirrors the web-core C++ velocity tracking.
  final Stopwatch _clock = Stopwatch()..start();
  Offset _dragVelocity = Offset.zero; // logical px/s
  int _lastMoveUs = 0;
  // True once a gesture has zoomed (pinch / scale change). Such a gesture must not
  // fling a pan on release — the focal drift of a zoom isn't a pan flick.
  bool _gestureHadScale = false;

  // True while a trackpad two-finger pan-zoom gesture is active (set from the raw
  // PointerPanZoom events). Used to scope the Linux trackpad pan gain to that path
  // only — never a mouse click-drag (single pointer) or the scroll-wheel path.
  bool _inTrackpadPanZoom = false;

  // The live pointer (cursor) position, tracked from hover/move/down. Used as the
  // pinch zoom anchor: a trackpad pinch's gesture focal carries GTK's bogus initial
  // pan offset (~tens of px), so it doesn't sit on the cursor — the real pointer
  // position does. On macOS the cursor == focal, so this is equivalent there.
  Offset _lastPointerPos = Offset.zero;
  // The pointer position one hover ago. On Linux, GTK warps the pointer to the
  // two-finger centroid when a trackpad gesture begins, firing one spurious
  // large-delta hover just before PointerPanZoomStart; that would anchor the pinch
  // off the cursor. We keep the prior position so the gesture start can undo it.
  Offset _prevPointerPos = Offset.zero;

  // Every pointer currently down, by id. Two things need it:
  //
  //  1. Telling a TOUCH pinch (two real pointers) from a TRACKPAD pinch (zero
  //     pointers down — the gesture arrives as PointerPanZoom). Only the latter
  //     may anchor on the cursor; see [_anchorOnCursor].
  //  2. Recognising a two-finger vertical "shove" for tilt, which
  //     `ScaleUpdateDetails` cannot express — it carries a focal point, a scale
  //     and a rotation, but no per-pointer positions, and a shove is otherwise
  //     indistinguishable from a two-finger pan.
  final Map<int, Offset> _pointers = <int, Offset>{};

  // Whether the pinch may zoom about the live cursor rather than the frozen
  // focal anchor.
  //
  // The cursor override exists for ONE case: a trackpad pinch's gesture focal
  // carries GTK's bogus initial pan offset, so it sits ~tens of px off the
  // cursor while the cursor itself is on the right point (see [_lastPointerPos]).
  // It must NOT apply to a real touch pinch: there is no cursor on a touchscreen,
  // only `PointerMoveEvent`s from both fingers, so [_lastPointerPos] becomes
  // "whichever finger moved last" and the anchor alternates between the two on
  // every frame — the map then chases the fingers instead of zooming about a
  // stable point.
  //
  // Both halves of the condition are deliberate, because they disagree exactly
  // where it matters. `_inTrackpadPanZoom` alone would silently drop back to the
  // frozen focal — reverting the Linux fix — under an embedder that synthesises
  // the scale gesture without emitting `PointerPanZoomStart`. A pointer-count
  // test alone would keep the cursor anchor for a mouse click-drag that left a
  // pointer down. Either regression is invisible on macOS, where the cursor and
  // the focal are the same point.
  bool get _anchorOnCursor => _inTrackpadPanZoom || _pointers.length <= 1;

  // Global-route fallback state. A trackpad pinch / two-finger pan / scroll fires at
  // the cursor position; if an overlay widget (e.g. app controls) sits on top of the
  // map there, the event hit-tests to the overlay and the map's own gesture layer
  // never sees it — so after tapping an overlay button the next pinch does nothing
  // until you click the map. Native and web maps don't let controls block zoom, so
  // we add a global pointer route: when a pan-zoom/scroll lands within the map's
  // bounds but the map's render box is NOT in the hit path (an overlay blocked it),
  // we drive the map from here. When the map IS hit, the normal Listener/Gesture
  // path handles it and the global route stays out (so there is no double-handling).
  bool _blockedPanZoom = false;
  double _blockedLastScale = 1;
  double _blockedLastRotation = 0;
  double _blockedRotationAccum = 0;
  Offset _blockedAnchor = Offset.zero;
  // The true cursor position (global coords), tracked from every hover/move via the
  // global route. Linux's GTK embedder can report a STALE position on trackpad
  // pan-zoom/scroll events (the last click location) — after tapping an overlay
  // control the pinch still reports the control's position even after the cursor has
  // moved onto the map. So for routing/anchoring we trust this, not event.position.
  Offset? _globalCursorPos;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_globalPointerRoute);
  }

  // Linux's GTK embedder reports touchpad two-finger pan deltas ~2x larger than the
  // equivalent pointer motion (verified from the raw PointerPanZoom stream: the
  // focal delta we apply equals GTK's panDelta, which is itself doubled), so the
  // map slid twice as fast as the fingers — "not natural like other platforms".
  // Scale the pan back on the Linux trackpad pan path only. macOS routes two-finger
  // swipes through scroll (zoom), not this path, and a mouse drag is a single
  // pointer — both already track 1:1 and must stay so.
  static const double _kLinuxTrackpadPanGain = 0.25;

  // Twist must exceed this before it latches. The MapLibre Android SDK uses 3
  // degrees, but backs it with a speed-adaptive second gate we are not porting;
  // at 3 degrees alone an ordinary pinch visibly jitters the bearing, so this is
  // deliberately coarser.
  static const double _kRotateDeadzoneDegrees = 8;

  // Degrees of tilt per logical pixel of two-finger vertical travel. The SDK's
  // SHOVE_PIXEL_CHANGE_FACTOR.
  static const double _kShoveDegreesPerPixel = 0.1;

  // A shove is two fingers moving vertically TOGETHER. Each must travel at
  // least this far, in the same direction, staying near-vertical, while the
  // scale and rotation stay inside their own deadzones.
  static const double _kShoveMinTravel = 12;
  static const double _kShoveMaxHorizontalRatio =
      0.36; // ~20 degrees off vertical

  // Mouse drag-rotate sensitivity. Starting points for the native-feel A/B
  // against the SDKs; horizontal drives bearing, vertical drives pitch, as in
  // maplibre-gl-js's DragRotateHandler.
  static const double _kDragRotateDegreesPerPixel = 0.8;
  static const double _kDragPitchDegreesPerPixel = 0.5;

  double get _panGain =>
      (_inTrackpadPanZoom && defaultTargetPlatform == TargetPlatform.linux)
      ? _kLinuxTrackpadPanGain
      : 1.0;

  void _stopInertia() {
    _inertiaTicker?.stop();
  }

  void _onScaleStart(ScaleStartDetails details) {
    _stopInertia(); // a new gesture cancels any ongoing fling
    _lastFocalPoint = details.localFocalPoint;
    _lastScale = 1;
    _dragVelocity = Offset.zero;
    _lastMoveUs = _clock.elapsedMicroseconds;
    _gestureHadScale = false;
    _zoomAnchor = details.localFocalPoint;
    _mode = _GestureMode.none;
    _lastRawRotation = 0;
    _rotationAccum = 0;
    _rotateAnchor = Offset.zero;
    _shoveOrigin.clear();
  }

  /// True when this gesture is a two-finger vertical shove (tilt).
  ///
  /// Detected from raw pointer positions, NOT from the focal delta: a shove and
  /// a two-finger PAN are both "focal moves vertically with scale ~1 and
  /// rotation ~0", so approximating it from `focalDelta.dy` would silently
  /// break panning, which works today. What separates them is that in a shove
  /// both fingers move the same way while their separation holds — which
  /// `ScaleUpdateDetails` cannot express, since it carries no per-pointer
  /// positions.
  bool _isShove(ScaleUpdateDetails details) {
    if (_pointers.length != 2) {
      _shoveOrigin.clear();
      return false;
    }
    // Seed on the first update that actually has two pointers. _onScaleStart
    // fires when the recognizer wins the arena, which is typically while only
    // one pointer is down — seeding there leaves a single entry and the shove
    // can never be recognised.
    if (_shoveOrigin.length != 2 ||
        !_pointers.keys.every(_shoveOrigin.containsKey)) {
      _shoveOrigin
        ..clear()
        ..addAll(_pointers);
      return false; // no travel measured yet
    }
    if ((details.scale - 1.0).abs() > 0.02) return false;
    // The UNWRAPPED total, exactly as the rotate latch below uses. Comparing
    // `details.rotation` here read the raw wrapped value, which Flutter derives
    // from atan2 differences — so a shove whose fingers are not perfectly
    // parallel (i.e. every real one) reported a large rotation on its first
    // update, tripped this deadzone and was never recognised as a shove.
    if (_rotationAccum.abs() > _kRotateDeadzoneDegrees * math.pi / 180) {
      return false;
    }
    final ids = _pointers.keys.toList();
    final a = _pointers[ids[0]]! - (_shoveOrigin[ids[0]] ?? Offset.zero);
    final b = _pointers[ids[1]]! - (_shoveOrigin[ids[1]] ?? Offset.zero);
    if (a.dy.sign != b.dy.sign) return false; // must move together
    if (a.dy.abs() < _kShoveMinTravel || b.dy.abs() < _kShoveMinTravel) {
      return false;
    }
    // Near-vertical: a diagonal two-finger drag is a pan, not a shove.
    if (a.dx.abs() > a.dy.abs() * _kShoveMaxHorizontalRatio) return false;
    if (b.dx.abs() > b.dy.abs() * _kShoveMaxHorizontalRatio) return false;
    return true;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // A secondary-button / ctrl drag is handled entirely on the raw Listener
    // (see [_isRotateDrag]). The scale recognizer still receives it, so without
    // this the map would pan underneath the rotation.
    if (_dragRotatePointer != null) return;

    final focal = details.localFocalPoint;
    final dx = focal.dx - _lastFocalPoint.dx;
    final dy = focal.dy - _lastFocalPoint.dy;
    _lastFocalPoint = focal;

    final rotator = widget.rotator;

    // Unwrap this frame's rotation and accumulate our own total; see
    // [_lastRawRotation] for why the reported value cannot be used directly.
    final rotationDelta = _normalizeAngle(details.rotation - _lastRawRotation);
    _lastRawRotation = details.rotation;
    _rotationAccum += rotationDelta;

    // --- latch the mode on the first threshold crossing ----------------------
    if (_mode == _GestureMode.none && rotator != null) {
      if (widget.tiltEnabled && _isShove(details)) {
        _mode = _GestureMode.shove;
      } else if (widget.rotateEnabled &&
          _rotationAccum.abs() > _kRotateDeadzoneDegrees * math.pi / 180) {
        _mode = _GestureMode.rotate;
        // Freeze the anchor at the latch. _zoomAnchor keeps tracking the focal
        // while a gesture is not scaling, so reading it per-frame would rotate
        // about a drifting point and make the map lurch.
        _rotateAnchor = _zoomAnchor;
      }
    }

    if (_mode == _GestureMode.shove && rotator != null) {
      // Both fingers moved together; use the mean travel since the last sample.
      final ids = _pointers.keys.toList();
      final a = _pointers[ids[0]]! - (_shoveOrigin[ids[0]] ?? Offset.zero);
      final b = _pointers[ids[1]]! - (_shoveOrigin[ids[1]] ?? Offset.zero);
      final meanDy = (a.dy + b.dy) / 2;
      _shoveOrigin
        ..clear()
        ..addAll(_pointers);
      if (meanDy != 0) {
        // Fingers moving UP increase pitch (SDK convention). No Dart-side
        // clamp — the engine clamps to 0..60.
        _reportReason(MapCameraChangeReason.gestureTilt);
        rotator.pitchBy(-_kShoveDegreesPerPixel * meanDy);
      }
      // A shove must not also pan or zoom; the SDK disables move while shoving.
      return;
    }

    if (_mode == _GestureMode.rotate && rotator != null) {
      // Positive is a clockwise on-screen twist, which is the convention the C
      // shim takes; the bearing sign lives there, not here.
      if (rotationDelta != 0) {
        final anchor = _rotateAnchor;
        _reportReason(MapCameraChangeReason.gestureRotate);
        rotator.rotateBy(rotationDelta * 180 / math.pi, anchor.dx, anchor.dy);
      }
      // Fall through: a twist still zooms if the fingers also spread, which is
      // how every native map behaves. It must not PAN, which the `zooming`
      // branch below already prevents.
    }

    // NOTE: `none` is NOT latched to panZoom here. Pan and zoom are the default
    // behaviour and run while the mode is still undecided, so rotate and shove
    // stay able to take over the moment they cross their thresholds. Latching
    // panZoom on the first update — when rotation is necessarily still ~0 —
    // makes rotation permanently unreachable.

    // A *scaling* gesture is a zoom (pinch) — detect by scale change, NOT by finger
    // count: a two-finger drag with scale ≈ 1 is a pan and should still fling.
    final zooming = (details.scale - 1.0).abs() > 0.02;

    if (zooming) {
      _gestureHadScale = true;
      // Freeze the zoom anchor: do NOT pan by the focal delta while zooming. On
      // Windows/Linux trackpads the focal centroid drifts as the fingers spread,
      // and applying that drift as a pan (plus a moving zoom anchor) slid the map
      // away from the cursor (see [_zoomAnchor]).
    } else {
      // Pure pan (or pre-pinch): track the focal so the zoom anchor is the point
      // under the gesture right before the pinch starts, and pan by the delta.
      // Apply the pan gain (Linux trackpad only — see [_panGain]) so the map tracks
      // the fingers 1:1; scale the velocity too so the release fling matches.
      _zoomAnchor = focal;
      final gain = _panGain;
      final pdx = dx * gain;
      final pdy = dy * gain;
      if (pdx != 0 || pdy != 0) {
        _reportReason(MapCameraChangeReason.gesturePan);
        widget.handler.moveBy(pdx, pdy);
      }
      // Track a smoothed drag velocity for the release fling — only for a pure
      // pan, so a zoom's focal drift never becomes pan velocity.
      final nowUs = _clock.elapsedMicroseconds;
      final dt = (nowUs - _lastMoveUs) / 1e6;
      _lastMoveUs = nowUs;
      if (dt > 0 && dt < 0.1) {
        // Floor dt to one frame so a sub-ms burst can't turn a small move into a
        // huge instantaneous speed (see [_minVelocitySampleDt]); a real fast flick
        // still reports its true speed (large pdx over a real frame).
        final measuredDt = math.max(dt, _minVelocitySampleDt);
        final instant = Offset(pdx / measuredDt, pdy / measuredDt); // px/s
        const a = 0.6; // EMA weight toward the most recent sample
        _dragVelocity = _dragVelocity * (1 - a) + instant * a;
      }
    }

    if (details.scale > 0) {
      final relative = details.scale / _lastScale;
      if (relative != 1.0) {
        // Zoom about the real cursor position, not the gesture focal: a trackpad
        // pinch's focal carries GTK's bogus initial pan offset so it sits ~tens of
        // px off the cursor. The live pointer position (hover/move-tracked) is on
        // the cursor; on macOS cursor == focal so this is equivalent. Fall back to
        // the frozen focal anchor if no pointer position is known yet, or when
        // this is a real multi-touch pinch, where there is no cursor to speak of
        // and [_lastPointerPos] would alternate between the fingers — see
        // [_anchorOnCursor].
        //
        // TODO(pinch-zoom): smooth / springy pinch-to-zoom is not implemented yet
        // (a missing feature, not a bug). The pinch applies the raw per-frame
        // `scaleBy` directly, so the zoom tracks the gesture 1:1 with no
        // interpolation toward the target and no release momentum — unlike the pan
        // fling below. Add gesture interpolation + a zoom-release inertia/spring so
        // the zoom eases and settles smoothly.
        final anchor = (_anchorOnCursor && _lastPointerPos != Offset.zero)
            ? _lastPointerPos
            : _zoomAnchor;
        _reportReason(MapCameraChangeReason.gesturePinch);
        widget.handler.scaleBy(relative, anchor.dx, anchor.dy);
      }
      _lastScale = details.scale;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // The gesture is over as far as the fingers are concerned. Inertia below
    // keeps moving the map, but it is a continuation of the same pan rather
    // than a new reason, and `onCameraChanged` still fires throughout.
    _endReasons();
    // Pan inertia only. Never fling a gesture that zoomed (its focal drift isn't a
    // pan flick) — that was the "map also moves when zoomed" funkiness. A two-finger
    // *pan* (no scale change) still flings. Fling only if released while still moving
    // (not after a pause) and fast enough, using our tracked velocity, not the
    // unreliable details.velocity.
    if (_gestureHadScale) return;
    final sinceMoveUs = _clock.elapsedMicroseconds - _lastMoveUs;
    if (sinceMoveUs > 100000) return; // released after a pause → no fling
    var velocity = _dragVelocity;
    final speed = velocity.distance;
    if (speed < _inertiaStartSpeed) return;
    // Cap the release speed (belt-and-braces with the dt floor).
    if (speed > _inertiaMaxSpeed) {
      velocity = velocity * (_inertiaMaxSpeed / speed);
    }
    // SDK fling model: derive the animation duration and the glide offset from the
    // release speed, then ease the camera by that offset (below). Both scale with
    // speed, so a harder flick glides farther and longer.
    final durationMs =
        (velocity.distance / _flingTimeDivisor + _flingBaseTimeMs).clamp(
          _flingBaseTimeMs,
          _flingMaxTimeMs,
        );
    var offset = velocity * (durationMs / 1000.0 * _flingOffsetFactor);
    final distance = offset.distance;
    if (distance > _flingMaxDistance) {
      offset = offset * (_flingMaxDistance / distance); // hard max glide
    }
    _flingOffset = offset;
    _flingDurationMs = durationMs;
    _flingApplied = Offset.zero;
    // Reuse a single Ticker for the State's life — SingleTickerProviderStateMixin
    // forbids creating a second one, so a per-fling createTicker() throws on the
    // second pan-release. Stop (no-op if idle) then restart from elapsed zero.
    (_inertiaTicker ??= createTicker(_onInertiaTick))
      ..stop()
      ..start();
  }

  void _onInertiaTick(Duration elapsed) {
    final t = (elapsed.inMicroseconds / 1000.0 / _flingDurationMs).clamp(
      0.0,
      1.0,
    );
    // Decelerating ease (≈ the SDK's fling curve): the glide starts near the
    // release speed and slows to a stop over the duration.
    final eased = Curves.easeOutCubic.transform(t);
    final target = _flingOffset * eased;
    final delta = target - _flingApplied;
    _flingApplied = target;
    if (delta.dx != 0 || delta.dy != 0) {
      widget.handler.moveBy(delta.dx, delta.dy);
    }
    if (t >= 1.0) _stopInertia();
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _globalPointerRoute,
    );
    _inertiaTicker?.stop();
    _inertiaTicker?.dispose();
    super.dispose();
  }

  // True when [globalPos] hit-tests to this map's gesture box (so the normal
  // Listener/GestureDetector path will handle it and the global route must not).
  bool _hits(RenderBox box, Offset globalPos, int viewId) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, globalPos, viewId);
    for (final entry in result.path) {
      if (entry.target == box) return true;
    }
    return false;
  }

  // Resolve the zoom anchor (map-local) for a blocked gesture: the true cursor when
  // it is over the map, otherwise the map centre (cursor is over an overlay → no map
  // point under it, so zoom about centre like the +/- buttons).
  Offset _blockedAnchorFor(
    RenderBox box,
    Offset origin,
    Offset cursor,
    int viewId,
  ) => _hits(box, cursor, viewId)
      ? cursor - origin
      : Offset(box.size.width / 2, box.size.height / 2);

  // See [_blockedPanZoom]: drive the map from a global route when an overlay blocks
  // the pointer from reaching the map's own gesture layer (or when the embedder
  // reports a stale pan-zoom position, see [_globalCursorPos]).
  void _globalPointerRoute(PointerEvent event) {
    // Track the true cursor everywhere (the global route sees hovers over overlays
    // too); pan-zoom/scroll positions can be stale on Linux.
    if (event is PointerHoverEvent || event is PointerMoveEvent) {
      _globalCursorPos = event.position;
    }
    final isPanZoom =
        event is PointerPanZoomStartEvent ||
        event is PointerPanZoomUpdateEvent ||
        event is PointerPanZoomEndEvent;
    if (!isPanZoom && event is! PointerScrollEvent) return;

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final mapRect = origin & box.size;
    final cursor = _globalCursorPos ?? event.position; // prefer the true cursor

    if (event is PointerPanZoomStartEvent) {
      // If the event itself routes to the map, the local path handles it — stay out.
      if (_hits(box, event.position, event.viewId)) {
        _blockedPanZoom = false;
        return;
      }
      // Else an overlay (or a stale pan-zoom position) blocked the map. Take over,
      // but only if the true cursor is within the map.
      if (!mapRect.contains(cursor)) {
        _blockedPanZoom = false;
        return;
      }
      _blockedPanZoom = true;
      _stopInertia();
      _inTrackpadPanZoom = true;
      _blockedLastScale = 1;
      _blockedLastRotation = 0;
      _blockedRotationAccum = 0;
      _blockedAnchor = _blockedAnchorFor(box, origin, cursor, event.viewId);
    } else if (event is PointerPanZoomUpdateEvent) {
      if (!_blockedPanZoom) return;
      final zooming = (event.scale - 1.0).abs() > 0.02;
      if (!zooming) {
        final pdx = event.panDelta.dx * _panGain;
        final pdy = event.panDelta.dy * _panGain;
        if (pdx != 0 || pdy != 0) {
          _reportReason(MapCameraChangeReason.gesturePan);
          widget.handler.moveBy(pdx, pdy);
        }
      }
      if (event.scale > 0) {
        final relative = event.scale / _blockedLastScale;
        if (relative != 1.0) {
          _reportReason(MapCameraChangeReason.gesturePinch);
          widget.handler.scaleBy(
            relative,
            _blockedAnchor.dx,
            _blockedAnchor.dy,
          );
        }
        _blockedLastScale = event.scale;
      }
      // Forward rotation too. PointerPanZoomUpdateEvent carries it (a macOS
      // trackpad twist), and dropping it here would reproduce exactly the bug
      // class this fallback exists for: a gesture that works over the map but
      // silently does nothing once an overlay covers the cursor.
      final rotator = widget.rotator;
      if (rotator != null && widget.rotateEnabled) {
        final deltaRadians = _normalizeAngle(
          event.rotation - _blockedLastRotation,
        );
        _blockedRotationAccum += deltaRadians;
        if (_blockedRotationAccum.abs() >
                _kRotateDeadzoneDegrees * math.pi / 180 &&
            deltaRadians != 0) {
          _reportReason(MapCameraChangeReason.gestureRotate);
          rotator.rotateBy(
            deltaRadians * 180 / math.pi,
            _blockedAnchor.dx,
            _blockedAnchor.dy,
          );
        }
        _blockedLastRotation = event.rotation;
      }
    } else if (event is PointerPanZoomEndEvent) {
      _blockedPanZoom = false;
      _inTrackpadPanZoom = false;
      _endReasons();
    } else if (event is PointerScrollEvent) {
      // Local path handles it when the event routes to the map.
      if (_hits(box, event.position, event.viewId)) return;
      if (!mapRect.contains(cursor)) return;
      _stopInertia();
      final anchor = _blockedAnchorFor(box, origin, cursor, event.viewId);
      final factor = math.pow(2.0, -event.scrollDelta.dy / 120.0).toDouble();
      if (factor != 1.0) {
        // A wheel notch is a whole gesture: report it and end it at once, since
        // there is no release event to hang an end on.
        _reportReason(MapCameraChangeReason.gesturePinch);
        widget.handler.scaleBy(factor, anchor.dx, anchor.dy);
        _endReasons();
      }
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      _stopInertia(); // a scroll-zoom cancels any in-flight pan glide
      // Scroll up (negative dy) zooms in, about the pointer.
      final factor = math.pow(2.0, -event.scrollDelta.dy / 120.0).toDouble();
      if (factor != 1.0) {
        // A wheel notch is a whole gesture — start and end together, since a
        // scroll has no release event to hang an end on.
        _reportReason(MapCameraChangeReason.gesturePinch);
        widget.handler.scaleBy(
          factor,
          event.localPosition.dx,
          event.localPosition.dy,
        );
        _endReasons();
      }
    }
  }

  // A trackpad pan-zoom gesture brackets the synthesized scale gesture. Track that
  // we're in one so [_panGain] can scope the Linux pan correction to this path.
  // GTK warps the pointer to the gesture centroid right as a two-finger gesture
  // begins, firing one spurious large-delta hover just before this. That moved the
  // pinch zoom anchor off the cursor (worse after a pan, where the fingers land
  // further from the cursor). If the last hover was such a jump, restore the
  // pre-warp position so the zoom anchors where the cursor actually is. Gated to
  // trackpad pan-zoom starts, so a real fast mouse move is never affected.
  static const double _kPointerWarpThreshold = 60; // logical px in one hover

  void _onPanZoomStart(PointerPanZoomStartEvent e) {
    _inTrackpadPanZoom = true;
    if ((_lastPointerPos - _prevPointerPos).distance > _kPointerWarpThreshold) {
      _lastPointerPos = _prevPointerPos;
    }
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent e) {
    _inTrackpadPanZoom = false;
  }

  // Track the live cursor so the pinch can zoom about it (see [_lastPointerPos]).
  void _onPointerHover(PointerHoverEvent e) {
    _prevPointerPos = _lastPointerPos;
    _lastPointerPos = e.localPosition;
  }

  // A mouse can neither twist nor shove, so without a drag path rotation is
  // unreachable on Windows, Linux and macOS-with-a-mouse. Follows gl-js's
  // DragRotateHandler: secondary button (or ctrl + primary), horizontal drives
  // bearing and vertical drives pitch.
  //
  // Deliberately on the raw Listener rather than the GestureDetector:
  // `onScaleStart` fires for a secondary drag too, so routing it through the
  // gesture recognizer would pan the map underneath the rotation.
  bool _isRotateDrag(PointerDownEvent e) =>
      widget.rotator != null &&
      (widget.rotateEnabled || widget.tiltEnabled) &&
      (e.buttons & kSecondaryMouseButton != 0 ||
          (e.buttons & kPrimaryMouseButton != 0 &&
              HardwareKeyboard.instance.isControlPressed));

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    _lastPointerPos = e.localPosition;
    if (_dragRotatePointer == null && _isRotateDrag(e)) {
      _dragRotatePointer = e.pointer;
      _dragRotateLast = e.localPosition;
      _stopInertia();
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    _pointers[e.pointer] = e.localPosition;
    _lastPointerPos = e.localPosition;

    if (e.pointer == _dragRotatePointer) {
      final rotator = widget.rotator;
      final delta = e.localPosition - _dragRotateLast;
      _dragRotateLast = e.localPosition;
      if (rotator == null) return;
      if (widget.rotateEnabled && delta.dx != 0) {
        // Dragging RIGHT turns the content clockwise, matching gl-js.
        _reportReason(MapCameraChangeReason.gestureRotate);
        rotator.rotateBy(
          delta.dx * _kDragRotateDegreesPerPixel,
          _lastPointerPos.dx,
          _lastPointerPos.dy,
        );
      }
      if (widget.tiltEnabled && delta.dy != 0) {
        // Dragging UP tilts toward the horizon.
        _reportReason(MapCameraChangeReason.gestureTilt);
        rotator.pitchBy(-delta.dy * _kDragPitchDegreesPerPixel);
      }
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointers.remove(e.pointer);
    if (e.pointer == _dragRotatePointer) {
      _dragRotatePointer = null;
      _endReasons(); // the secondary-drag rotate ends with its own pointer
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _pointers.remove(e.pointer);
    if (e.pointer == _dragRotatePointer) {
      _dragRotatePointer = null;
      _endReasons();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      onPointerPanZoomStart: _onPanZoomStart,
      onPointerPanZoomEnd: _onPanZoomEnd,
      onPointerHover: _onPointerHover,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: widget.child,
      ),
    );
  }
}
