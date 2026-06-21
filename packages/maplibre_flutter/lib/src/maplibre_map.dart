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
      _zoomAnchor = focal;
      if (dx != 0 || dy != 0) {
        widget.handler.moveBy(dx, dy);
      }
      // Track a smoothed drag velocity for the release fling — only for a pure
      // pan, so a zoom's focal drift never becomes pan velocity.
      final nowUs = _clock.elapsedMicroseconds;
      final dt = (nowUs - _lastMoveUs) / 1e6;
      _lastMoveUs = nowUs;
      if (dt > 0 && dt < 0.1) {
        final instant = Offset(dx / dt, dy / dt); // px/s
        const a = 0.6; // EMA weight toward the most recent sample
        _dragVelocity = _dragVelocity * (1 - a) + instant * a;
      }
    }

    if (details.scale > 0) {
      final relative = details.scale / _lastScale;
      if (relative != 1.0) {
        // Zoom about the frozen anchor (≈ the cursor), not the live focal.
        widget.handler.scaleBy(relative, _zoomAnchor.dx, _zoomAnchor.dy);
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
    _inertiaTicker?.stop();
    _inertiaTicker?.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: GestureDetector(
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: widget.child,
      ),
    );
  }
}
