import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart'
    show LatLng;

/// A Flutter widget glued to a geographic point on a [MapLibreMap].
///
/// Pass a list of these to [MapLibreMap.markers]. Each [child] is composited
/// above the map and kept locked to [point] as the map pans/zooms/rotates/tilts —
/// it stays a real, interactive Flutter widget (tap, gestures, animations all
/// work inside it).
///
/// Markers are **declarative**: to move one, change [point] and rebuild (the same
/// model as [MapLibreMap.style]). For interactive repositioning set [draggable]
/// and update [point] from [onDragEnd]/[onDragUpdate].
@immutable
class MapLibreMarker {
  const MapLibreMarker({
    required this.point,
    required this.child,
    this.alignment = Alignment.center,
    this.offset = Offset.zero,
    this.zIndex = 0,
    this.draggable = false,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.key,
    this.repaintBoundary = false,
  });

  /// The geographic point the marker is anchored to.
  final LatLng point;

  /// The widget drawn at [point].
  final Widget child;

  /// Which part of [child] sits on [point]. Defaults to the child's center; use
  /// e.g. [Alignment.bottomCenter] for a pin whose tip marks the spot.
  final Alignment alignment;

  /// A fixed screen-space nudge applied AFTER [alignment], in logical points —
  /// gl-js `Marker({offset})`.
  ///
  /// [alignment] and this are not alternatives. Alignment answers "which part
  /// of the widget is the anchor", which is a property of the artwork; offset
  /// answers "and then move it a bit", which is how you separate two markers on
  /// the same point, or clear a callout from the pin it belongs to. Positive
  /// [Offset.dy] moves it DOWN, as everywhere else in Flutter.
  ///
  /// It does not scale with zoom — that is the point of it being screen-space.
  final Offset offset;

  /// Paint order among markers. Higher draws on top; equal values keep list
  /// order — gl-js `Marker.setZIndex`.
  ///
  /// Without this, overlapping markers stack in whatever order the list
  /// happens to be in, so the one you most want visible is the one that
  /// disappears behind its neighbours. The sort is STABLE, so markers at the
  /// same zIndex never shuffle between frames — a marker that flickers between
  /// two positions as data updates is worse than one drawn underneath.
  final int zIndex;

  /// When true, the marker can be dragged across the map. While dragging it
  /// follows the pointer and reports the geographic point under it via
  /// [onDragUpdate]; on release it reports the final point via [onDragEnd]. Keep
  /// [point] in sync with those callbacks so the marker settles correctly.
  final bool draggable;

  /// Called when a drag begins (the marker's current [point]).
  final ValueChanged<LatLng>? onDragStart;

  /// Called repeatedly while dragging, with the geographic point under the
  /// pointer. Only fired when [draggable] is true.
  final ValueChanged<LatLng>? onDragUpdate;

  /// Called when a drag ends, with the final geographic point. Only fired when
  /// [draggable] is true.
  final ValueChanged<LatLng>? onDragEnd;

  /// Optional identity for the marker, used to match widgets across rebuilds
  /// (preserves child state when the list reorders).
  final Key? key;

  /// Wrap [child] in an explicit [RepaintBoundary].
  ///
  /// **Defaults to false, and you probably do not need it.** The intuition is
  /// that a boundary stops the child re-painting as the camera moves — but the
  /// overlay uses a `Flow`, which already composites each child through its own
  /// transform layer, so moving a marker replays a retained layer either way.
  /// A test measures exactly this: the child paints zero extra times per camera
  /// tick with OR without the flag, and on-device testing likewise showed no
  /// frame-time difference from toggling it.
  ///
  /// Kept as an escape hatch for children that invalidate themselves for other
  /// reasons, where isolating them from the overlay may still help. It costs one
  /// compositing layer per marker, so measure before using it at scale rather
  /// than assuming a win.
  final bool repaintBoundary;
}
