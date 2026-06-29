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

class _MarkerOverlayState extends State<MarkerOverlay> {
  // Index of the marker being dragged, and its live position in overlay-space
  // logical pixels (anchor projected at drag start, then moved by pointer delta).
  int? _dragIndex;
  Offset _dragScreen = Offset.zero;

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

class _MarkerFlowDelegate extends FlowDelegate {
  _MarkerFlowDelegate({
    required this.projector,
    required this.markers,
    required this.dragIndex,
    required this.dragScreen,
  }) : super(repaint: projector);

  final MapLibreMapProjector projector;
  final List<MapLibreMarker> markers;
  final int? dragIndex;
  final Offset dragScreen;

  // Reused across the per-camera-tick repaints of a single delegate instance, so
  // a moving map does no per-frame allocation. Sized once for this marker list.
  late final List<LatLng> _points = [for (final m in markers) m.point];
  late final List<Offset> _out = List<Offset>.filled(markers.length, Offset.zero);
  late final List<bool> _visible = List<bool>.filled(markers.length, true);

  // Park markers here until a projection exists / when they are behind the
  // camera, so they neither flash at the origin nor leave a phantom hit target.
  static const Offset _offscreen = Offset(-100000, -100000);

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
    for (var i = 0; i < markers.length; i++) {
      final size = context.getChildSize(i) ?? Size.zero;
      final a = markers[i].alignment;
      // The point in [child]'s box that should land on the geographic point.
      final anchorX = (a.x + 1) / 2 * size.width;
      final anchorY = (a.y + 1) / 2 * size.height;

      Offset pos;
      if (i == dragIndex) {
        pos = dragScreen; // dragged: follow the pointer, not the declarative point
      } else if (gen == 0 || !_visible[i]) {
        pos = _offscreen; // no projection yet, or behind a pitched camera
      } else {
        pos = _out[i];
      }
      context.paintChild(
        i,
        transform: Matrix4.translationValues(pos.dx - anchorX, pos.dy - anchorY, 0),
      );
    }
  }

  @override
  bool shouldRepaint(_MarkerFlowDelegate old) =>
      old.projector != projector ||
      old.dragIndex != dragIndex ||
      old.dragScreen != dragScreen ||
      !identical(old.markers, markers);
}
