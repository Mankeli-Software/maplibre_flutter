import 'package:flutter/foundation.dart';

import 'lat_lng.dart';

/// Immutable description of the map camera.
///
/// This is render-agnostic: every platform (native view or texture) reports and
/// accepts the same camera, so the public API never branches per platform.
@immutable
class MapCamera {
  const MapCamera({
    required this.center,
    this.zoom = 0,
    this.bearing = 0,
    this.pitch = 0,
  });

  /// Geographic point at the centre of the viewport.
  final LatLng center;

  /// Zoom level; 0 is fully zoomed out.
  final double zoom;

  /// Rotation in degrees, clockwise from true north.
  final double bearing;

  /// Tilt in degrees away from a straight-down view.
  final double pitch;

  MapCamera copyWith({
    LatLng? center,
    double? zoom,
    double? bearing,
    double? pitch,
  }) => MapCamera(
    center: center ?? this.center,
    zoom: zoom ?? this.zoom,
    bearing: bearing ?? this.bearing,
    pitch: pitch ?? this.pitch,
  );

  @override
  bool operator ==(Object other) =>
      other is MapCamera &&
      other.center == center &&
      other.zoom == zoom &&
      other.bearing == bearing &&
      other.pitch == pitch;

  @override
  int get hashCode => Object.hash(center, zoom, bearing, pitch);

  @override
  String toString() =>
      'MapCamera(center: $center, zoom: $zoom, bearing: $bearing, pitch: $pitch)';
}
