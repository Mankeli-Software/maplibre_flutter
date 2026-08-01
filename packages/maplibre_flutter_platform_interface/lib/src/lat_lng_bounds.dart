import 'package:flutter/foundation.dart';

import 'lat_lng.dart';

/// A rectangular geographic area, as its south-west and north-east corners.
///
/// Shaped after `mbgl::LatLngBounds` (`include/mbgl/util/geo.hpp`), which is
/// also what the Android SDK and Apple's `MLNCoordinateBoundsMake(sw, ne)`
/// agree on. Deliberately **not** gl-js's `LngLatBounds`: our point type is
/// [LatLng] and importing a longitude-first name would re-open the axis-order
/// bug class CLAUDE.md §11 calls this project's most recurrent.
///
/// The corner pair is the whole representation, so a bounds that
/// [crossesAntimeridian] is expressed with `northeast.longitude` numerically
/// less than `southwest.longitude` — the same convention mbgl uses.
@immutable
class LatLngBounds {
  /// The area between two corners.
  ///
  /// No ordering is enforced: an inverted pair is a valid *empty* bounds and is
  /// how [LatLngBounds.empty] works, matching mbgl. Use [isValid] to check.
  const LatLngBounds({required this.southwest, required this.northeast});

  /// The smallest bounds containing both points — mbgl's `hull()`.
  factory LatLngBounds.fromPoints(Iterable<LatLng> points) {
    if (points.isEmpty) {
      throw ArgumentError.value(points, 'points', 'must not be empty');
    }
    var south = double.infinity;
    var west = double.infinity;
    var north = double.negativeInfinity;
    var east = double.negativeInfinity;
    for (final point in points) {
      south = point.latitude < south ? point.latitude : south;
      north = point.latitude > north ? point.latitude : north;
      west = point.longitude < west ? point.longitude : west;
      east = point.longitude > east ? point.longitude : east;
    }
    return LatLngBounds(
      southwest: LatLng(south, west),
      northeast: LatLng(north, east),
    );
  }

  /// The whole unwrapped world — mbgl's `world()`.
  factory LatLngBounds.world() => const LatLngBounds(
    southwest: LatLng(-90, -180),
    northeast: LatLng(90, 180),
  );

  /// The identity element for [extend]: an inverted bounds that contains
  /// nothing, so extending it by a point yields exactly that point. mbgl's
  /// `empty()`.
  factory LatLngBounds.empty() => const LatLngBounds(
    southwest: LatLng(90, 180),
    northeast: LatLng(-90, -180),
  );

  /// The bounds consisting of a single point — mbgl's `singleton()`.
  factory LatLngBounds.singleton(LatLng point) =>
      LatLngBounds(southwest: point, northeast: point);

  /// The south-west corner: the minimum latitude and longitude.
  final LatLng southwest;

  /// The north-east corner: the maximum latitude and longitude.
  final LatLng northeast;

  /// The southern edge's latitude.
  double get south => southwest.latitude;

  /// The western edge's longitude.
  double get west => southwest.longitude;

  /// The northern edge's latitude.
  double get north => northeast.latitude;

  /// The eastern edge's longitude.
  double get east => northeast.longitude;

  /// The south-east corner.
  LatLng get southeast => LatLng(south, east);

  /// The north-west corner.
  LatLng get northwest => LatLng(north, west);

  /// The midpoint of the two corners.
  LatLng get center => LatLng((south + north) / 2, (west + east) / 2);

  /// Whether the corners are the right way round — mbgl's `valid()`.
  bool get isValid => south <= north && west <= east;

  /// Whether this bounds contains nothing at all — mbgl's `isEmpty()`, and the
  /// exact negation of [isValid].
  bool get isEmpty => south > north || west > east;

  /// Whether the eastern edge lies west of the western one once both are
  /// wrapped, i.e. the area spans the 180th meridian. mbgl's
  /// `crossesAntimeridian()`.
  bool get crossesAntimeridian =>
      southwest.wrapped().longitude > northeast.wrapped().longitude;

  /// The smallest bounds containing this one and [point] — mbgl's `extend`,
  /// as a value rather than a mutation.
  LatLngBounds extend(LatLng point) => LatLngBounds(
    southwest: LatLng(
      point.latitude < south ? point.latitude : south,
      point.longitude < west ? point.longitude : west,
    ),
    northeast: LatLng(
      point.latitude > north ? point.latitude : north,
      point.longitude > east ? point.longitude : east,
    ),
  );

  /// The smallest bounds containing this one and [other].
  LatLngBounds extendBounds(LatLngBounds other) =>
      extend(other.southwest).extend(other.northeast);

  /// Whether [point] lies inside this bounds, edges included.
  ///
  /// Longitudes are compared unwrapped, like mbgl's default
  /// `LatLng::Unwrapped` — so a bounds that [crossesAntimeridian] should be
  /// tested against a point on the same side of the wrap.
  bool contains(LatLng point) =>
      point.latitude >= south &&
      point.latitude <= north &&
      point.longitude >= west &&
      point.longitude <= east;

  /// Whether [other] lies entirely inside this bounds.
  bool containsBounds(LatLngBounds other) =>
      contains(other.southwest) && contains(other.northeast);

  /// Whether this bounds and [other] share any area, edges included.
  bool intersects(LatLngBounds other) =>
      other.north >= south &&
      other.south <= north &&
      other.east >= west &&
      other.west <= east;

  LatLngBounds copyWith({LatLng? southwest, LatLng? northeast}) => LatLngBounds(
    southwest: southwest ?? this.southwest,
    northeast: northeast ?? this.northeast,
  );

  @override
  bool operator ==(Object other) =>
      other is LatLngBounds &&
      other.southwest == southwest &&
      other.northeast == northeast;

  @override
  int get hashCode => Object.hash(southwest, northeast);

  @override
  String toString() => 'LatLngBounds(sw: $southwest, ne: $northeast)';
}
