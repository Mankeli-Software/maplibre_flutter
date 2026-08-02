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
    this.semanticLabel,
    this.semanticValue,
    this.semanticHint,
    this.onTap,
    this.keyboardStep = 20,
  });

  /// The geographic point the marker is anchored to.
  final LatLng point;

  /// What a screen reader calls this marker — Apple `MLNAnnotation.title`.
  ///
  /// **Null leaves the child's own semantics completely alone**, which is
  /// deliberate and is maplibre-gl-js's stated boundary for custom marker
  /// elements: *"it's up to the user to handle it"*. Not-wrapping is a stronger
  /// guarantee in Flutter than not-clobbering is in the DOM — an app whose
  /// marker child is already a labelled `IconButton` keeps exactly the tree it
  /// built.
  ///
  /// Supply it and the marker becomes one labelled node instead, which is what
  /// makes a pin made of bare `CustomPaint` reachable at all.
  final String? semanticLabel;

  /// Extra detail read after the label — Apple `MLNAnnotation.subtitle`.
  final String? semanticValue;

  /// What activating it does. Defaults to Apple's `ANNOTATION_A11Y_HINT`
  /// ("Shows more info") when [onTap] is given.
  final String? semanticHint;

  /// Called when the marker is activated, by tap or by assistive technology.
  ///
  /// Distinct from a `GestureDetector` inside [child]: this one is also what
  /// VoiceOver, TalkBack and a keyboard reach.
  final VoidCallback? onTap;

  /// Logical pixels a [draggable] marker moves per assistive-technology nudge.
  ///
  /// This is the SC 2.5.7 (Dragging Movements) discharge for markers: without
  /// it the only way to move one is a path-based drag, which is exactly what
  /// that criterion forbids as the sole mechanism. The nudge fires the same
  /// [onDragStart]/[onDragUpdate]/[onDragEnd] sequence a pointer drag does, so
  /// an app needs no second code path.
  final double keyboardStep;

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
