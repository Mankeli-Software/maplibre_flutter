import 'dart:ui' show Offset;

import 'package:flutter/animation.dart' show Cubic;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show EdgeInsets;

import 'camera.dart';
import 'lat_lng.dart';

/// A **partial** camera: every field is optional, and an omitted one means
/// "leave it alone".
///
/// Mirrors `mbgl::CameraOptions` (`include/mbgl/map/camera.hpp`), which is what
/// `jumpTo` / `easeTo` / `flyTo` take, and gl-js's `CameraOptions`, which is the
/// same idea. The distinction from [MapCamera] is the point: [MapCamera] is a
/// full snapshot, so "zoom to 12 and leave everything else" through it needs a
/// read-modify-write that races the render thread against any live gesture.
///
/// Padding is Flutter's own [EdgeInsets] rather than a bespoke
/// `PaddingOptions`: it is a type the caller already owns, it composes with
/// `MediaQuery.padding`, and `dart analyze` checks it.
@immutable
class CameraOptions {
  const CameraOptions({
    this.center,
    this.zoom,
    this.bearing,
    this.pitch,
    this.roll,
    this.padding,
    this.anchor,
  });

  /// Every field of [camera], as a partial camera.
  factory CameraOptions.fromCamera(
    MapCamera camera, {
    EdgeInsets? padding,
    Offset? anchor,
  }) => CameraOptions(
    center: camera.center,
    zoom: camera.zoom,
    bearing: camera.bearing,
    pitch: camera.pitch,
    padding: padding,
    anchor: anchor,
  );

  /// Geographic point to put at the centre of the viewport.
  final LatLng? center;

  /// Zoom level; 0 is fully zoomed out.
  final double? zoom;

  /// Rotation in degrees, clockwise from true north. mbgl wraps it to
  /// `[0, 360)`.
  final double? bearing;

  /// Tilt in degrees away from a straight-down view.
  ///
  /// mbgl clamps this to `util::DEFAULT_PITCH_MAX` = 60°
  /// (`include/mbgl/util/constants.hpp`); a larger value is silently reduced,
  /// not rejected.
  final double? pitch;

  /// Camera roll in degrees.
  ///
  /// A real engine field (`CameraOptions::roll`, read by `Transform::easeTo`),
  /// not a web-only one — it is simply unbound in our C ABI today, so setting
  /// it has no effect until the stage-3 shim lands.
  final double? roll;

  /// Padding around the interior of the view, which moves the frame of
  /// reference for [center].
  ///
  /// This is the transient, per-call padding — Apple's `edgePadding:`. The
  /// persistent one (Apple's `contentInset`, for a bottom sheet that covers the
  /// map for as long as it is up) belongs on the widget.
  final EdgeInsets? padding;

  /// The screen point that stays fixed while [zoom] and [bearing] change, in
  /// logical pixels from the **top-left** of the map — mbgl's own convention
  /// for `CameraOptions::anchor`, unlike its bottom-left-origin projection.
  ///
  /// gl-js calls this `around`; mbgl calls it `anchor` and so does every line of
  /// our shim, so `anchor` it is.
  ///
  /// **mbgl discards this whenever [center] is set** — `transform.cpp` reads
  /// `anchor = camera.center ? nullopt : camera.anchor`. An anchored zoom or
  /// rotate therefore cannot be expressed as read-camera-then-write-camera, and
  /// a test that anchors on the map centre cannot detect the difference,
  /// because the centre is a fixed point either way. Send the partial options
  /// down; never fill in [center] on the way.
  final Offset? anchor;

  /// Whether this would change nothing.
  bool get isEmpty =>
      center == null &&
      zoom == null &&
      bearing == null &&
      pitch == null &&
      roll == null &&
      padding == null &&
      anchor == null;

  /// This partial camera resolved against [base]: each unset field takes
  /// [base]'s value.
  ///
  /// Note that the result cannot carry [anchor] — a [MapCamera] always has a
  /// centre, and mbgl drops the anchor whenever a centre is present. Use this
  /// for the unanchored cases only.
  MapCamera applyTo(MapCamera base) => MapCamera(
    center: center ?? base.center,
    zoom: zoom ?? base.zoom,
    bearing: bearing ?? base.bearing,
    pitch: pitch ?? base.pitch,
  );

  CameraOptions copyWith({
    LatLng? center,
    double? zoom,
    double? bearing,
    double? pitch,
    double? roll,
    EdgeInsets? padding,
    Offset? anchor,
  }) => CameraOptions(
    center: center ?? this.center,
    zoom: zoom ?? this.zoom,
    bearing: bearing ?? this.bearing,
    pitch: pitch ?? this.pitch,
    roll: roll ?? this.roll,
    padding: padding ?? this.padding,
    anchor: anchor ?? this.anchor,
  );

  @override
  bool operator ==(Object other) =>
      other is CameraOptions &&
      other.center == center &&
      other.zoom == zoom &&
      other.bearing == bearing &&
      other.pitch == pitch &&
      other.roll == roll &&
      other.padding == padding &&
      other.anchor == anchor;

  @override
  int get hashCode =>
      Object.hash(center, zoom, bearing, pitch, roll, padding, anchor);

  @override
  String toString() =>
      'CameraOptions(center: $center, zoom: $zoom, bearing: $bearing, '
      'pitch: $pitch, roll: $roll, padding: $padding, anchor: $anchor)';
}

/// How a camera transition should be animated.
///
/// Mirrors `mbgl::AnimationOptions` (`include/mbgl/map/camera.hpp`) with gl-js's
/// names where the two differ, and Flutter's value types at the boundary:
/// [Duration] rather than milliseconds, [Cubic] rather than a raw
/// `UnitBezier`.
///
/// Two gl-js `flyTo` options are deliberately absent because the engine cannot
/// honour them:
///
/// * `curve` — the van Wijk ρ. `Transform::flyTo` hardcodes `rho = 1.42` and
///   only varies it indirectly, from [apexZoom]. There is no field to bind.
/// * `maxDuration` — `AnimationOptions` has no counterpart; the duration of a
///   flight is computed inside the engine. Pass [duration] to fix it outright.
@immutable
class CameraAnimation {
  const CameraAnimation({
    this.duration,
    this.easing,
    this.speed,
    this.apexZoom,
  });

  /// An instant transition: the camera jumps.
  static const CameraAnimation none = CameraAnimation();

  /// How long the transition takes.
  ///
  /// For a flight, leaving this null lets the engine derive the duration from
  /// the distance and [speed], which is the behaviour that makes `flyTo` feel
  /// right over both short and intercontinental hops.
  final Duration? duration;

  /// The timing curve, as mbgl's `UnitBezier` — hence [Cubic] specifically,
  /// which maps onto it one-for-one, rather than any [Curve].
  ///
  /// Flutter's named easings are `Cubic` instances and can be passed straight
  /// through (`Curves.ease`, `Curves.easeIn`, `Curves.easeInOut`, …).
  /// `Curves.linear` is not one — write `const Cubic(0, 0, 1, 1)`.
  final Cubic? easing;

  /// Average velocity of a flight, in screenfuls per second. gl-js's `speed`;
  /// mbgl's `AnimationOptions::velocity`. The engine's default is 1.2.
  final double? speed;

  /// The zoom level at the apex of a flight's arc — how far out it pulls before
  /// coming back down.
  ///
  /// gl-js and mbgl both call this `minZoom`; renamed here because `minZoom`
  /// already means a hard camera constraint (`camera.setMinZoom`) in the same
  /// namespace, and the collision would be permanent. Apple's name for the same
  /// idea is `peakAltitude:`.
  final double? apexZoom;

  /// Whether this describes an instant change.
  bool get isInstant =>
      duration == null && easing == null && speed == null && apexZoom == null;

  CameraAnimation copyWith({
    Duration? duration,
    Cubic? easing,
    double? speed,
    double? apexZoom,
  }) => CameraAnimation(
    duration: duration ?? this.duration,
    easing: easing ?? this.easing,
    speed: speed ?? this.speed,
    apexZoom: apexZoom ?? this.apexZoom,
  );

  @override
  bool operator ==(Object other) =>
      other is CameraAnimation &&
      other.duration == duration &&
      other.easing == easing &&
      other.speed == speed &&
      other.apexZoom == apexZoom;

  @override
  int get hashCode => Object.hash(duration, easing, speed, apexZoom);

  @override
  String toString() =>
      'CameraAnimation(duration: $duration, easing: $easing, speed: $speed, '
      'apexZoom: $apexZoom)';
}
