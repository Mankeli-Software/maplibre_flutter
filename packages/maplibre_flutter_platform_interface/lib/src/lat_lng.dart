import 'package:flutter/foundation.dart';

/// A geographic coordinate: WGS84 latitude/longitude in degrees.
@immutable
class LatLng {
  const LatLng(this.latitude, this.longitude);

  /// Degrees north of the equator, in `[-90, 90]`.
  final double latitude;

  /// Degrees east of the prime meridian, in `[-180, 180]`.
  final double longitude;

  @override
  bool operator ==(Object other) =>
      other is LatLng &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'LatLng($latitude, $longitude)';
}
