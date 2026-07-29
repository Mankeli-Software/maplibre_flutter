import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart'
    show LatLng, MapLibreMapProjector;

import 'marker.dart';

/// Composites [markers] above the map, each glued to its geographic point.
///
/// Uses a [Flow]: the delegate repaints on every camera change (it listens to the
/// [projector]) and re-positions each child at the projected screen point — with
/// **no relayout and no widget rebuild**, so it stays smooth during pan/zoom/
/// fly-to/inertia. [Flow] hit-tests children at their painted positions, so a
/// marker's own gestures (tap, drag) work and empty space falls through to the
/// map's gesture layer beneath.
///
/// Stateful only to track the marker currently being dragged: a dragged marker is
/// positioned by the live pointer (in overlay space) instead of by its
/// (declarative) [MapLibreMarker.point], so it follows the finger immediately and
/// never double-moves even if the app also updates `point` from the drag callbacks.
class MarkerOverlay extends StatefulWidget {
  const MarkerOverlay({
    super.key,
    required this.projector,
    required this.markers,
  });

  final MapLibreMapProjector projector;
  final List<MapLibreMarker> markers;

  @override
  State<MarkerOverlay> createState() => _MarkerOverlayState();
}

class _MarkerOverlayState extends State<MarkerOverlay>
    with SingleTickerProviderStateMixin {
  // Index of the marker being dragged, and its live position in overlay-space
  // logical pixels (anchor projected at drag start, then moved by pointer delta).
  int? _dragIndex;
  Offset _dragScreen = Offset.zero;

  // Repaint source for the delegate: camera ticks from the controller PLUS a
  // per-frame tick while the map is moving.
  //
  // A camera tick alone is not enough. The controller ticks when it *issues* a
  // command, but the core applies it (and publishes the resulting frame) later
  // on its render thread — so frames keep arriving after the last tick. Since
  // markers are projected against the frame on screen, the overlay has to
  // re-run that projection every frame while movement is in flight, or it
  // freezes on whichever frame happened to be current at the last command.
  final _RepaintTick _repaint = _RepaintTick();
  // Created eagerly in initState, NOT lazily: createTicker() does an inherited-
  // widget lookup, so a lazy `late final` would construct it inside dispose()
  // when the camera never ticked — an ancestor lookup on a deactivated element.
  late final Ticker _ticker;
  Duration _activeUntil = Duration.zero;
  Duration _now = Duration.zero;

  // How long to keep frame-ticking after the last camera change. Covers the
  // render-thread latency between a command and the frame that shows it.
  static const Duration _settleWindow = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onFrame);
    widget.projector.addListener(_onCameraChanged);
  }

  @override
  void didUpdateWidget(MarkerOverlay old) {
    super.didUpdateWidget(old);
    if (old.projector != widget.projector) {
      old.projector.removeListener(_onCameraChanged);
      widget.projector.addListener(_onCameraChanged);
    }
  }

  @override
  void dispose() {
    widget.projector.removeListener(_onCameraChanged);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _onCameraChanged() {
    _activeUntil = _now + _settleWindow;
    if (!_ticker.isActive) _ticker.start();
    _repaint.tick();
  }

  void _onFrame(Duration elapsed) {
    _now = elapsed;
    if (elapsed > _activeUntil) {
      _ticker.stop(); // idle: stop repainting until the camera moves again
      return;
    }
    _repaint.tick();
  }

  // Scratch reused across a drag to project a single point without allocation.
  final List<LatLng> _one = <LatLng>[const LatLng(0, 0)];
  final List<Offset> _oneOut = <Offset>[Offset.zero];

  Offset _projectOne(LatLng p) {
    _one[0] = p;
    widget.projector.project(_one, _oneOut);
    return _oneOut[0];
  }

  void _onDragStart(int i) {
    final marker = widget.markers[i];
    setState(() {
      _dragIndex = i;
      _dragScreen = _projectOne(marker.point);
    });
    marker.onDragStart?.call(marker.point);
  }

  void _onDragUpdate(int i, Offset delta) {
    setState(() => _dragScreen += delta);
    final ll = widget.projector.unproject(_dragScreen);
    if (ll != null) widget.markers[i].onDragUpdate?.call(ll);
  }

  void _onDragEnd(int i) {
    final ll = widget.projector.unproject(_dragScreen);
    if (ll != null) widget.markers[i].onDragEnd?.call(ll);
    setState(() => _dragIndex = null);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Flow(
        delegate: _MarkerFlowDelegate(
          projector: widget.projector,
          repaint: _repaint,
          markers: widget.markers,
          dragIndex: _dragIndex,
          dragScreen: _dragScreen,
        ),
        children: [
          for (var i = 0; i < widget.markers.length; i++)
            _wrap(i, widget.markers[i]),
        ],
      ),
    );
  }

  Widget _wrap(int i, MapLibreMarker marker) {
    Widget child = marker.child;
    // Cache the child's painting in its own layer so a camera tick only moves
    // the layer rather than re-painting the content (see the field's doc for
    // when this is a pessimisation).
    if (marker.repaintBoundary) child = RepaintBoundary(child: child);
    if (marker.draggable) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _onDragStart(i),
        onPanUpdate: (d) => _onDragUpdate(i, d.delta),
        onPanEnd: (_) => _onDragEnd(i),
        onPanCancel: () => _onDragEnd(i),
        child: child,
      );
    }
    // Honor the marker's identity so child state survives list reorders. Flow
    // matches children positionally; a key keeps the right element with the
    // right marker. Fall back to the position when none is given.
    return KeyedSubtree(key: marker.key ?? ValueKey<int>(i), child: child);
  }
}

/// Exposes [ChangeNotifier.notifyListeners] (which is `@protected`) so the
/// overlay state can drive the delegate's repaints.
class _RepaintTick extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _MarkerFlowDelegate extends FlowDelegate {
  _MarkerFlowDelegate({
    required this.projector,
    required Listenable repaint,
    required this.markers,
    required this.dragIndex,
    required this.dragScreen,
  }) : super(repaint: repaint);

  final MapLibreMapProjector projector;
  final List<MapLibreMarker> markers;
  final int? dragIndex;
  final Offset dragScreen;

  // Reused across the per-camera-tick repaints of a single delegate instance, so
  // a moving map does no per-frame allocation. Sized once for this marker list.
  late final List<LatLng> _points = [for (final m in markers) m.point];
  late final List<Offset> _out = List<Offset>.filled(
    markers.length,
    Offset.zero,
  );
  late final List<bool> _visible = List<bool>.filled(markers.length, true);

  // Let each marker size to its own content. The default returns the (tight)
  // overlay constraints, which would force every marker to fill the whole map.
  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      constraints.loosen();

  @override
  void paintChildren(FlowPaintingContext context) {
    final gen = markers.isEmpty
        ? 0
        : projector.project(_points, _out, visible: _visible);
    final Size overlay = context.size;

    for (var i = 0; i < markers.length; i++) {
      final bool dragged = i == dragIndex;

      // Not projectable (no transform yet, or behind a pitched camera): skip
      // the child entirely rather than parking it off-screen. Skipping costs no
      // matrix and no paint, and `Flow` only hit-tests children it painted, so
      // it also leaves no phantom hit target.
      if (!dragged && (gen == 0 || !_visible[i])) continue;

      final size = context.getChildSize(i) ?? Size.zero;
      final a = markers[i].alignment;
      // The point in [child]'s box that should land on the geographic point.
      final anchorX = (a.x + 1) / 2 * size.width;
      final anchorY = (a.y + 1) / 2 * size.height;
      final pos = dragged ? dragScreen : _out[i];
      final dx = pos.dx - anchorX;
      final dy = pos.dy - anchorY;

      // Viewport cull. A marker whose box lies wholly outside the map contributes
      // nothing, so don't pay a transform + paint for it. This is what makes a
      // large cluster cheap once the camera zooms into part of it; a cluster that
      // is *entirely* on screen still costs one paint per marker, which is the
      // real ceiling of one-widget-per-point (see the class doc).
      if (!dragged &&
          (dx + size.width < 0 ||
              dy + size.height < 0 ||
              dx > overlay.width ||
              dy > overlay.height)) {
        continue;
      }

      context.paintChild(i, transform: Matrix4.translationValues(dx, dy, 0));
    }
  }

  @override
  bool shouldRepaint(_MarkerFlowDelegate old) =>
      old.projector != projector ||
      old.dragIndex != dragIndex ||
      old.dragScreen != dragScreen ||
      !identical(old.markers, markers);
}
