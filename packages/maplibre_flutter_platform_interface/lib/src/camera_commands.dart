import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show EdgeInsets;

import 'camera_options.dart';
import 'lat_lng_bounds.dart';

/// How a camera change is applied.
enum CameraTransition {
  /// Instant. gl-js `jumpTo`.
  jump,

  /// A straight, eased path. gl-js `easeTo`.
  ease,

  /// The van Wijk flight — zoom out, pan, zoom back in — which is what makes a
  /// long jump legible instead of a blur. gl-js `flyTo`.
  fly,
}

/// Limits on where the camera may go.
///
/// One object rather than five setter pairs, because that is how the engine
/// models it: `mbgl::BoundOptions` (`bound_options.hpp:13-56`) carries exactly
/// these five fields and is applied by a single `Map::setBounds`. The
/// app-facing controller still offers gl-js's individual `setMinZoom` /
/// `setMaxBounds` / … names on top.
@immutable
class MapCameraConstraints {
  const MapCameraConstraints({
    this.bounds,
    this.minZoom,
    this.maxZoom,
    this.minPitch,
    this.maxPitch,
  });

  /// The area the camera may look at.
  ///
  /// **What this constrains depends on the constrain mode**, and the two
  /// upstreams disagree under the same word. gl-js's `maxBounds` constrains
  /// what is VISIBLE; mbgl's `BoundOptions::bounds` constrains the camera
  /// CENTRE unless the mode is `Screen`. The app-facing `setMaxBounds` picks
  /// gl-js's meaning and sets the mode to match — setting this field directly
  /// gets mbgl's.
  final LatLngBounds? bounds;

  /// The furthest out the camera may zoom. Engine default 0.
  final double? minZoom;

  /// The closest in the camera may zoom. Engine default 22.
  final double? maxZoom;

  /// The flattest pitch, in degrees. Engine default 0.
  final double? minPitch;

  /// The steepest pitch, in degrees.
  ///
  /// **mbgl clamps to 60° regardless** (`util::DEFAULT_PITCH_MAX`), so a larger
  /// value here is silently reduced rather than rejected.
  final double? maxPitch;

  MapCameraConstraints copyWith({
    LatLngBounds? bounds,
    double? minZoom,
    double? maxZoom,
    double? minPitch,
    double? maxPitch,
  }) => MapCameraConstraints(
    bounds: bounds ?? this.bounds,
    minZoom: minZoom ?? this.minZoom,
    maxZoom: maxZoom ?? this.maxZoom,
    minPitch: minPitch ?? this.minPitch,
    maxPitch: maxPitch ?? this.maxPitch,
  );

  @override
  bool operator ==(Object other) =>
      other is MapCameraConstraints &&
      other.bounds == bounds &&
      other.minZoom == minZoom &&
      other.maxZoom == maxZoom &&
      other.minPitch == minPitch &&
      other.maxPitch == maxPitch;

  @override
  int get hashCode => Object.hash(bounds, minZoom, maxZoom, minPitch, maxPitch);

  @override
  String toString() =>
      'MapCameraConstraints(bounds: $bounds, minZoom: $minZoom, '
      'maxZoom: $maxZoom, minPitch: $minPitch, maxPitch: $maxPitch)';
}

/// Native camera commands, over the partial [CameraOptions] type.
///
/// An **optional capability**: feature-detect it with `is`, like the others
/// (CLAUDE.md §3). The five `mbgl-core` tiers implement it.
///
/// **The completion contract.** Every `Future` here completes when the
/// transition ENDS — and a superseded transition completes rather than
/// erroring. That is not a choice made here but the engine's own behaviour:
/// `Transform::startTransition` invokes the previous transition's finish
/// function before installing the new one, so interrupting a flight with a
/// gesture resolves its `Future` instead of leaving it hanging forever.
///
/// **Animation needs continuous rendering.** mbgl advances transitions from its
/// render loop, so [easeTo] and [flyTo] only animate on a continuously-rendering
/// map. Every shipped tier is continuous; the headless test harness is not.
abstract interface class MapLibreCameraCommands {
  /// Applies [camera] instantly. Unset fields are left alone.
  Future<void> jumpTo(CameraOptions camera);

  /// Transitions to [camera] along a straight, eased path.
  Future<void> easeTo(CameraOptions camera, {CameraAnimation? animation});

  /// Transitions to [camera] along a van Wijk flight path.
  Future<void> flyTo(CameraOptions camera, {CameraAnimation? animation});

  /// Frames [bounds] under [padding].
  ///
  /// Computed and applied in one engine command: the computation needs the live
  /// transform, so a compute-then-move split would let the camera change in
  /// between.
  Future<void> fitBounds(
    LatLngBounds bounds, {
    EdgeInsets padding,
    double? bearing,
    double? pitch,
    CameraTransition transition,
    CameraAnimation? animation,
  });

  /// The camera that would frame [bounds], without moving — gl-js
  /// `cameraForBounds`. Null if the engine could not answer in time.
  Future<CameraOptions?> cameraForBounds(
    LatLngBounds bounds, {
    EdgeInsets padding,
    double? bearing,
    double? pitch,
  });

  /// The geographic area currently on screen — gl-js `getBounds`. Null if the
  /// engine could not answer in time.
  Future<LatLngBounds?> getBounds();

  /// Applies camera limits. Unset fields are left alone.
  Future<void> setCameraConstraints(MapCameraConstraints constraints);

  /// The current camera limits. Null if the engine could not answer in time.
  Future<MapCameraConstraints?> getCameraConstraints();

  /// Whether [MapCameraConstraints.bounds] constrains the whole viewport
  /// (gl-js `maxBounds`) rather than just the camera centre (mbgl's default).
  Future<void> setConstrainToBounds({required bool wholeViewport});

  /// Stops any transition in flight, leaving the camera where it reached.
  /// gl-js `stop`; mbgl `Map::cancelTransitions`.
  Future<void> stopCamera();
}
