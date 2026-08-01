import 'package:flutter/foundation.dart';

import 'lat_lng.dart';

/// Where the user is — Apple `MLNUserLocation`.
///
/// **This package does NOT source location, and that is a design decision, not
/// a gap.** Apple's `MLNLocationManager` is a *protocol* precisely so the app
/// can supply the fix; every real app already has a location plugin, its own
/// permission flow and its own accuracy/battery policy, and a map package that
/// took a `geolocator` dependency would be duplicating all three badly — on six
/// platforms, each with different permission rules. Feed
/// `MapLibreMap.userLocation` from whatever you already use.
@immutable
class MapUserLocation {
  const MapUserLocation({
    required this.position,
    this.accuracy,
    this.heading,
    this.course,
  });

  /// The fix.
  final LatLng position;

  /// Horizontal accuracy in METRES, drawn as the halo around the puck. Null
  /// draws no halo — which is honest, rather than picking a number.
  final double? accuracy;

  /// Compass heading in degrees clockwise from true north: where the DEVICE is
  /// pointing. Null hides the direction cone.
  final double? heading;

  /// Direction of travel in degrees clockwise from true north: where the user is
  /// MOVING.
  ///
  /// Distinct from [heading] on purpose, and Apple splits them the same way — a
  /// passenger holding a phone sideways in a moving car has a heading that has
  /// nothing to do with their course. [MapUserTrackingMode] lets you pick which
  /// one drives the camera.
  final double? course;

  @override
  bool operator ==(Object other) =>
      other is MapUserLocation &&
      other.position == position &&
      other.accuracy == accuracy &&
      other.heading == heading &&
      other.course == course;

  @override
  int get hashCode => Object.hash(position, accuracy, heading, course);
}

/// How the camera follows the user — Apple `MLNUserTrackingMode`.
enum MapUserTrackingMode {
  /// The camera does not follow. The puck still draws where the user is.
  none,

  /// The camera keeps the user centred; bearing is left alone.
  follow,

  /// Centred, and rotated so the device's compass [MapUserLocation.heading]
  /// points up.
  followWithHeading,

  /// Centred, and rotated so the direction of travel [MapUserLocation.course]
  /// points up — the one you want for turn-by-turn, where the phone's
  /// orientation is irrelevant.
  followWithCourse,
}
