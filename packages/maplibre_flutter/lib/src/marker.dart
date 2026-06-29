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
    this.draggable = false,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.key,
  });

  /// The geographic point the marker is anchored to.
  final LatLng point;

  /// The widget drawn at [point].
  final Widget child;

  /// Which part of [child] sits on [point]. Defaults to the child's center; use
  /// e.g. [Alignment.bottomCenter] for a pin whose tip marks the spot.
  final Alignment alignment;

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
}
