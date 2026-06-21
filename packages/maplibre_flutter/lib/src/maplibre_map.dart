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
  });

  /// MapLibre style document: a URL, asset path, or inline JSON.
  ///
  /// Declarative — change it (e.g. via `setState`) to switch styles at runtime.
  /// This is the single source of truth for the map's style (CLAUDE.md §3).
  final String style;

  /// Optional externally-owned controller for driving the map imperatively.
  ///
  /// Omit it and the widget creates and owns one (disposed when the widget is
  /// removed). When provided, **you** own it: call
  /// [MapLibreMapController.dispose] when done. One controller per map.
  final MapLibreMapController? controller;

  /// Init-only configuration (e.g. the initial camera). Changes after the first
  /// build are ignored; use the [controller] for runtime camera moves.
  final MapOptions options;

  @override
  State<MapLibreMap> createState() => _MapLibreMapState();
}

class _MapLibreMapState extends State<MapLibreMap> {
  // Set only when the widget owns the controller (none was provided).
  MapLibreMapController? _internalController;
  MapLibreMapController get _controller =>
      widget.controller ?? _internalController!;

  Future<void>? _attach;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _internalController = MapLibreMapController();
    }
    _attach = _controller.attach(style: widget.style, options: widget.options);
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
      setState(() {
        _attach = _controller.attach(
          style: widget.style,
          options: widget.options,
        );
      });
    } else if (widget.style != oldWidget.style) {
      // Declarative style: push the new style to the native map.
      _controller.setStyle(widget.style);
    }
  }

  @override
  void dispose() {
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
        return _MapEmbed(controller: _controller);
      },
    );
  }
}

/// Resolves the render split (CLAUDE.md §3) to a concrete embed widget. This is
/// the only place that branches on [MapLibreRenderHandle].
class _MapEmbed extends StatelessWidget {
  const _MapEmbed({required this.controller});

  final MapLibreMapController controller;

  @override
  Widget build(BuildContext context) {
    final handle = controller.renderHandle!;
    switch (handle) {
      case TextureHandle(:final textureId):
        return _TextureMapView(controller: controller, textureId: textureId);
      case PlatformViewHandle():
        return _PlatformView(handle: handle);
      case ElementViewHandle(:final viewType):
        // Web tier: the maplibre-gl-js map is the host `<div>` registered under
        // [viewType] by the web controller's view factory. It is the top DOM
        // element, so it receives pointer/scroll/gesture events natively — no
        // Dart gesture layer (web mirrors the mobile tier, CLAUDE.md §3).
        // Flutter widgets drawn *over* the map need `PointerInterceptor`
        // (handled by the app, e.g. the example's controls), not the map itself.
        return HtmlElementView(viewType: viewType);
    }
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
  const _TextureMapView({required this.controller, required this.textureId});

  final MapLibreMapController controller;
  final int textureId;

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
          map = _DesktopMapGestures(handler: gestures, child: map);
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
class _DesktopMapGestures extends StatefulWidget {
  const _DesktopMapGestures({required this.handler, required this.child});

  final MapLibreGestureHandler handler;
  final Widget child;

  @override
  State<_DesktopMapGestures> createState() => _DesktopMapGesturesState();
}

class _DesktopMapGesturesState extends State<_DesktopMapGestures>
    with SingleTickerProviderStateMixin {
  Offset _lastFocalPoint = Offset.zero;
  double _lastScale = 1;

  // Anchor a pinch zooms about. Tracks the focal point while the gesture is only
  // panning, then FREEZES at pinch onset and stays put for the rest of the zoom.
  // Rationale: a trackpad pinch on Windows/Linux arrives as a two-finger scale
  // gesture whose focal *centroid drifts* as the fingers spread (macOS instead
  // reports the stable cursor). Zooming about the live, drifting centroid — and
  // panning by its delta — slid the map away from the cursor. A frozen anchor
  // makes pinch zoom about a stable point (≈ the cursor) on every desktop tier;
  // it's a no-op on macOS, where the focal doesn't drift.
  Offset _zoomAnchor = Offset.zero;

  // Pan inertia ("fling"): when the drag is released with velocity, keep panning
  // and decay it, so the custom rendering engines (desktop core + core-on-mobile)
  // feel like the native SDKs / gl-js. Driven by a Ticker; the velocity decays
  // exponentially.
  Ticker? _inertiaTicker;
  Offset _inertiaVelocity = Offset.zero; // logical px/s
  Duration _lastInertiaElapsed = Duration.zero;

  // Velocity decay time constant; lower = stops sooner. Distance glided ≈ v0·tau.
  static const double _inertiaTauSeconds = 0.3;
  // Stop the fling once it slows below this.
  static const double _inertiaMinSpeed = 16; // px/s
  // Only fling if released faster than this (ignore slow/precise drags).
  static const double _inertiaStartSpeed = 120; // px/s

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
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final focal = details.localFocalPoint;
    final dx = focal.dx - _lastFocalPoint.dx;
    final dy = focal.dy - _lastFocalPoint.dy;
    _lastFocalPoint = focal;

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
        widget.handler.moveBy(pdx, pdy);
      }
      // Track a smoothed drag velocity for the release fling — only for a pure
      // pan, so a zoom's focal drift never becomes pan velocity.
      final nowUs = _clock.elapsedMicroseconds;
      final dt = (nowUs - _lastMoveUs) / 1e6;
      _lastMoveUs = nowUs;
      if (dt > 0 && dt < 0.1) {
        final instant = Offset(pdx / dt, pdy / dt); // px/s
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
        // the frozen focal anchor only if no pointer position is known yet.
        final anchor = _lastPointerPos == Offset.zero
            ? _zoomAnchor
            : _lastPointerPos;
        widget.handler.scaleBy(relative, anchor.dx, anchor.dy);
      }
      _lastScale = details.scale;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // Pan inertia only. Never fling a gesture that zoomed (its focal drift isn't a
    // pan flick) — that was the "map also moves when zoomed" funkiness. A two-finger
    // *pan* (no scale change) still flings. Fling only if released while still moving
    // (not after a pause) and fast enough, using our tracked velocity, not the
    // unreliable details.velocity.
    if (_gestureHadScale) return;
    final sinceMoveUs = _clock.elapsedMicroseconds - _lastMoveUs;
    if (sinceMoveUs > 100000) return; // released after a pause → no fling
    if (_dragVelocity.distance < _inertiaStartSpeed) return;
    _inertiaVelocity = _dragVelocity;
    _lastInertiaElapsed = Duration.zero;
    // Reuse a single Ticker for the State's life — SingleTickerProviderStateMixin
    // forbids creating a second one, so a per-fling createTicker() throws on the
    // second pan-release. Stop (no-op if idle) then restart from elapsed zero.
    (_inertiaTicker ??= createTicker(_onInertiaTick))
      ..stop()
      ..start();
  }

  void _onInertiaTick(Duration elapsed) {
    final dt = (elapsed - _lastInertiaElapsed).inMicroseconds / 1e6;
    _lastInertiaElapsed = elapsed;
    if (dt <= 0) return;
    final dx = _inertiaVelocity.dx * dt;
    final dy = _inertiaVelocity.dy * dt;
    if (dx != 0 || dy != 0) {
      widget.handler.moveBy(dx, dy);
    }
    _inertiaVelocity *= math.exp(-dt / _inertiaTauSeconds);
    if (_inertiaVelocity.distance < _inertiaMinSpeed) {
      _stopInertia();
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_globalPointerRoute);
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
  Offset _blockedAnchorFor(RenderBox box, Offset origin, Offset cursor, int viewId) =>
      _hits(box, cursor, viewId)
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
    final isPanZoom = event is PointerPanZoomStartEvent ||
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
      _blockedAnchor = _blockedAnchorFor(box, origin, cursor, event.viewId);
    } else if (event is PointerPanZoomUpdateEvent) {
      if (!_blockedPanZoom) return;
      final zooming = (event.scale - 1.0).abs() > 0.02;
      if (!zooming) {
        final pdx = event.panDelta.dx * _panGain;
        final pdy = event.panDelta.dy * _panGain;
        if (pdx != 0 || pdy != 0) widget.handler.moveBy(pdx, pdy);
      }
      if (event.scale > 0) {
        final relative = event.scale / _blockedLastScale;
        if (relative != 1.0) {
          widget.handler.scaleBy(relative, _blockedAnchor.dx, _blockedAnchor.dy);
        }
        _blockedLastScale = event.scale;
      }
    } else if (event is PointerPanZoomEndEvent) {
      _blockedPanZoom = false;
      _inTrackpadPanZoom = false;
    } else if (event is PointerScrollEvent) {
      // Local path handles it when the event routes to the map.
      if (_hits(box, event.position, event.viewId)) return;
      if (!mapRect.contains(cursor)) return;
      _stopInertia();
      final anchor = _blockedAnchorFor(box, origin, cursor, event.viewId);
      final factor = math.pow(2.0, -event.scrollDelta.dy / 120.0).toDouble();
      if (factor != 1.0) widget.handler.scaleBy(factor, anchor.dx, anchor.dy);
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      _stopInertia(); // a scroll-zoom cancels any in-flight pan glide
      // Scroll up (negative dy) zooms in, about the pointer.
      final factor = math.pow(2.0, -event.scrollDelta.dy / 120.0).toDouble();
      if (factor != 1.0) {
        widget.handler.scaleBy(
          factor,
          event.localPosition.dx,
          event.localPosition.dy,
        );
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

  void _onPointerDown(PointerDownEvent e) {
    _lastPointerPos = e.localPosition;
  }

  void _onPointerMove(PointerMoveEvent e) {
    _lastPointerPos = e.localPosition;
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
      child: GestureDetector(
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: widget.child,
      ),
    );
  }
}
