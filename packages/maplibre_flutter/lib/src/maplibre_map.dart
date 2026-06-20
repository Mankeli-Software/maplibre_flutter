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
class _TextureMapView extends StatelessWidget {
  const _TextureMapView({required this.controller, required this.textureId});

  final MapLibreMapController controller;
  final int textureId;

  @override
  Widget build(BuildContext context) {
    Widget map = Texture(textureId: textureId);
    if (controller.gestureHandler case final gestures?) {
      map = _DesktopMapGestures(handler: gestures, child: map);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (size.isFinite && !size.isEmpty) {
            controller.resize(size, dpr);
          }
        });
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

  void _stopInertia() {
    _inertiaTicker?.stop();
  }

  void _onScaleStart(ScaleStartDetails details) {
    _stopInertia(); // a new gesture cancels any ongoing fling
    _lastFocalPoint = details.localFocalPoint;
    _lastScale = 1;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final focal = details.localFocalPoint;
    final dx = focal.dx - _lastFocalPoint.dx;
    final dy = focal.dy - _lastFocalPoint.dy;
    if (dx != 0 || dy != 0) {
      widget.handler.moveBy(dx, dy);
    }
    _lastFocalPoint = focal;

    if (details.scale > 0) {
      final relative = details.scale / _lastScale;
      if (relative != 1.0) {
        widget.handler.scaleBy(relative, focal.dx, focal.dy);
      }
      _lastScale = details.scale;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // Pan inertia only (not pinch-zoom). Single-pointer drag end carries the fling
    // velocity in details.velocity.
    if (details.pointerCount > 1) return;
    final velocity = details.velocity.pixelsPerSecond;
    if (velocity.distance < _inertiaStartSpeed) return;
    _inertiaVelocity = velocity;
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
