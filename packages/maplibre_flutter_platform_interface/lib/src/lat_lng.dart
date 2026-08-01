import 'package:flutter/foundation.dart';

/// A geographic coordinate: WGS84 latitude/longitude in degrees.
///
/// Field order is `(latitude, longitude)` — mbgl's and the Android SDK's, never
/// gl-js's `LngLat`. GeoJSON's `[lng, lat]` is flipped at the boundary, once,
/// wherever one is parsed or written. CLAUDE.md §11 names that flip the #1
/// recurring bug class in this project.
///
/// **Validity is asserted, because mbgl throws.** `mbgl::LatLng`'s constructor
/// throws `std::domain_error` on a NaN latitude or longitude, on
/// `|latitude| > 90`, and on a non-finite longitude
/// (`include/mbgl/util/geo.hpp`) — and a C++ throw crossing an `extern "C"`
/// boundary is undefined behaviour, so an invalid value reaching the shim is
/// not a catchable error but a crash of unspecified shape. The asserts below
/// mirror those four checks exactly, so a debug build fails at the construction
/// site instead. When the numbers come from somewhere you do not control, build
/// the coordinate with [LatLng.sanitized] rather than checking by hand.
///
/// Longitude is deliberately **not** range-checked: mbgl's default is
/// `WrapMode::Unwrapped`, and an unwrapped longitude is how a camera crosses
/// the antimeridian without spinning the long way round. [wrapped] applies the
/// wrap where you want it.
@immutable
class LatLng {
  const LatLng(this.latitude, this.longitude)
    : assert(
        latitude == latitude, // NaN is the only value not equal to itself.
        'latitude must not be NaN — mbgl::LatLng throws on it, and it would '
        'throw across the FFI boundary, which is UB',
      ),
      assert(
        longitude == longitude,
        'longitude must not be NaN — mbgl::LatLng throws on it, and it would '
        'throw across the FFI boundary, which is UB',
      ),
      assert(
        latitude >= -90.0 && latitude <= 90.0,
        'latitude must be between -90 and 90 — mbgl::LatLng throws otherwise. '
        'This also rejects infinity.',
      ),
      assert(
        longitude > double.negativeInfinity && longitude < double.infinity,
        'longitude must be finite — mbgl::LatLng throws otherwise',
      );

  /// Makes any pair of doubles safe to hand to the engine.
  ///
  /// NaN becomes 0, latitude is clamped to ±90, and longitude is wrapped into
  /// `[-180, 180)`. Use this at a boundary where the numbers are not yours —
  /// user input, a decoded payload, a computation that can divide by zero —
  /// because the alternative is undefined behaviour rather than an exception.
  factory LatLng.sanitized(double latitude, double longitude) => LatLng(
    latitude.isNaN ? 0.0 : latitude.clamp(-90.0, 90.0).toDouble(),
    longitude.isFinite ? _wrapLongitude(longitude) : 0.0,
  );

  /// Degrees north of the equator, in `[-90, 90]`.
  final double latitude;

  /// Degrees east of the prime meridian.
  ///
  /// Not constrained to `[-180, 180]`: an unwrapped value is meaningful, and is
  /// what lets mbgl take the short way across the antimeridian.
  final double longitude;

  /// Whether this coordinate is one mbgl will accept.
  ///
  /// False exactly when `mbgl::LatLng`'s constructor would throw. The asserts
  /// make an invalid instance unconstructible in a debug build, so this is for
  /// guarding a boundary in release.
  bool get isValid =>
      !latitude.isNaN &&
      latitude >= -90.0 &&
      latitude <= 90.0 &&
      longitude.isFinite;

  /// This coordinate with its longitude wrapped into `[-180, 180)`.
  ///
  /// Mirrors `mbgl::LatLng::wrapped()`, whose arithmetic is `mbgl::util::wrap`
  /// — inclusive of the minimum, exclusive of the maximum, so `180` wraps to
  /// `-180`.
  LatLng wrapped() => LatLng(latitude, _wrapLongitude(longitude));

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

/// `mbgl::util::wrap(value, -180, 180)` — modular, into `[min, max)`.
double _wrapLongitude(double longitude) {
  const min = -180.0;
  const max = 180.0;
  if (longitude >= min && longitude < max) return longitude;
  if (longitude == max) return min;
  // Dart's `%` returns a non-negative result for a positive divisor, unlike
  // C's fmod, so mbgl's `value < min` correction has no counterpart here.
  return min + (longitude - min) % (max - min);
}
