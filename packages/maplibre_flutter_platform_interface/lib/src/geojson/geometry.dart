import 'package:flutter/foundation.dart';

import '../lat_lng.dart';

/// A GeoJSON geometry — the seven types of RFC 7946 §3.1, sealed so a `switch`
/// over them is exhaustive.
///
/// Mirrors the `geometry` of gl-js's `MapGeoJSONFeature` and of `mbgl::Feature`
/// (`include/mbgl/util/feature.hpp`). Named `GeoJson…` rather than bare `Point`
/// / `Polygon` because those collide with `dart:ui`, `dart:math` and Flutter;
/// gl-js sets the same precedent with `MapGeoJSONFeature`.
///
/// **Positions are [LatLng] on this side of the boundary.** GeoJSON writes them
/// as `[longitude, latitude]` — the opposite order — and every constructor here
/// and every [toJson] does that flip exactly once, so callers never have to.
/// CLAUDE.md §11 names axis order the #1 recurring bug class in this project.
///
/// RFC 7946 permits a third position element (altitude); it is accepted and
/// dropped, because [LatLng] has no altitude.
@immutable
sealed class GeoJsonGeometry {
  const GeoJsonGeometry();

  /// Parses one RFC 7946 geometry object.
  ///
  /// Throws a [FormatException] — and nothing else — on anything malformed, so
  /// a caller can make one `on FormatException` its whole error contract.
  factory GeoJsonGeometry.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    if (type is! String) {
      throw const FormatException('geometry has no "type" string');
    }
    if (type == 'GeometryCollection') {
      final raw = _list(json['geometries'], 'geometries');
      return GeoJsonGeometryCollection([
        for (final g in raw) GeoJsonGeometry.fromJson(_object(g, 'geometry')),
      ]);
    }
    final coordinates = _list(json['coordinates'], 'coordinates');
    return switch (type) {
      'Point' => GeoJsonPoint(_position(coordinates)),
      'MultiPoint' => GeoJsonMultiPoint(_positions(coordinates)),
      'LineString' => GeoJsonLineString(_positions(coordinates)),
      'MultiLineString' => GeoJsonMultiLineString(_positionLists(coordinates)),
      'Polygon' => GeoJsonPolygon(_positionLists(coordinates)),
      'MultiPolygon' => GeoJsonMultiPolygon([
        for (final p in coordinates) _positionLists(_list(p, 'coordinates')),
      ]),
      _ => throw FormatException('unknown geometry type "$type"'),
    };
  }

  /// The RFC 7946 `type` string, e.g. `Point`.
  String get type;

  /// This geometry as an RFC 7946 object, positions back in `[lng, lat]`.
  ///
  /// Numbers are emitted as plain doubles with no rewriting — unlike the style
  /// encoder, which turns `6.0` into `6`. These bytes are what mbgl's GeoJSON
  /// parser reads.
  Map<String, Object?> toJson();
}

/// RFC 7946 `Point`.
@immutable
final class GeoJsonPoint extends GeoJsonGeometry {
  const GeoJsonPoint(this.coordinates);

  /// The position.
  final LatLng coordinates;

  @override
  String get type => 'Point';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'coordinates': _encode(coordinates),
  };

  @override
  bool operator ==(Object other) =>
      other is GeoJsonPoint && other.coordinates == coordinates;

  @override
  int get hashCode => Object.hash(type, coordinates);

  @override
  String toString() => 'GeoJsonPoint($coordinates)';
}

/// RFC 7946 `MultiPoint`.
@immutable
final class GeoJsonMultiPoint extends GeoJsonGeometry {
  const GeoJsonMultiPoint(this.coordinates);

  /// The positions.
  final List<LatLng> coordinates;

  @override
  String get type => 'MultiPoint';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'coordinates': [for (final p in coordinates) _encode(p)],
  };

  @override
  bool operator ==(Object other) =>
      other is GeoJsonMultiPoint && listEquals(other.coordinates, coordinates);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(coordinates));

  @override
  String toString() => 'GeoJsonMultiPoint(${coordinates.length} positions)';
}

/// RFC 7946 `LineString`.
@immutable
final class GeoJsonLineString extends GeoJsonGeometry {
  const GeoJsonLineString(this.coordinates);

  /// The positions, in order.
  final List<LatLng> coordinates;

  @override
  String get type => 'LineString';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'coordinates': [for (final p in coordinates) _encode(p)],
  };

  @override
  bool operator ==(Object other) =>
      other is GeoJsonLineString && listEquals(other.coordinates, coordinates);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(coordinates));

  @override
  String toString() => 'GeoJsonLineString(${coordinates.length} positions)';
}

/// RFC 7946 `MultiLineString`.
@immutable
final class GeoJsonMultiLineString extends GeoJsonGeometry {
  const GeoJsonMultiLineString(this.coordinates);

  /// One list of positions per line.
  final List<List<LatLng>> coordinates;

  @override
  String get type => 'MultiLineString';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'coordinates': [
      for (final line in coordinates) [for (final p in line) _encode(p)],
    ],
  };

  @override
  bool operator ==(Object other) =>
      other is GeoJsonMultiLineString &&
      _nestedEquals(other.coordinates, coordinates);

  @override
  int get hashCode => Object.hash(type, _nestedHash(coordinates));

  @override
  String toString() => 'GeoJsonMultiLineString(${coordinates.length} lines)';
}

/// RFC 7946 `Polygon`: an exterior ring followed by any interior rings.
@immutable
final class GeoJsonPolygon extends GeoJsonGeometry {
  const GeoJsonPolygon(this.coordinates);

  /// The rings. The first is the exterior ring; the rest are holes.
  ///
  /// RFC 7946 requires each ring to be closed (first position == last) and
  /// wound right-hand-rule; neither is enforced here, and mbgl does not
  /// require it either.
  final List<List<LatLng>> coordinates;

  @override
  String get type => 'Polygon';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'coordinates': [
      for (final ring in coordinates) [for (final p in ring) _encode(p)],
    ],
  };

  @override
  bool operator ==(Object other) =>
      other is GeoJsonPolygon && _nestedEquals(other.coordinates, coordinates);

  @override
  int get hashCode => Object.hash(type, _nestedHash(coordinates));

  @override
  String toString() => 'GeoJsonPolygon(${coordinates.length} rings)';
}

/// RFC 7946 `MultiPolygon`.
@immutable
final class GeoJsonMultiPolygon extends GeoJsonGeometry {
  const GeoJsonMultiPolygon(this.coordinates);

  /// One ring list per polygon.
  final List<List<List<LatLng>>> coordinates;

  @override
  String get type => 'MultiPolygon';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'coordinates': [
      for (final polygon in coordinates)
        [
          for (final ring in polygon) [for (final p in ring) _encode(p)],
        ],
    ],
  };

  @override
  bool operator ==(Object other) {
    if (other is! GeoJsonMultiPolygon) return false;
    if (other.coordinates.length != coordinates.length) return false;
    for (var i = 0; i < coordinates.length; i++) {
      if (!_nestedEquals(other.coordinates[i], coordinates[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    type,
    Object.hashAll([for (final p in coordinates) _nestedHash(p)]),
  );

  @override
  String toString() => 'GeoJsonMultiPolygon(${coordinates.length} polygons)';
}

/// RFC 7946 `GeometryCollection`.
@immutable
final class GeoJsonGeometryCollection extends GeoJsonGeometry {
  const GeoJsonGeometryCollection(this.geometries);

  /// The member geometries. RFC 7946 discourages, but permits, nesting another
  /// collection here.
  final List<GeoJsonGeometry> geometries;

  @override
  String get type => 'GeometryCollection';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'geometries': [for (final g in geometries) g.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is GeoJsonGeometryCollection &&
      listEquals(other.geometries, geometries);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(geometries));

  @override
  String toString() => 'GeoJsonGeometryCollection(${geometries.length})';
}

// --- Parsing helpers ---------------------------------------------------------
//
// Every one of these throws FormatException rather than letting an unchecked
// cast throw TypeError, so `on FormatException` really is the whole contract.
// That promise is load-bearing: queryRenderedFeatures runs on camera ticks and
// documents that it never throws into its caller.

List<Object?> _list(Object? value, String what) {
  if (value is List<Object?>) return value;
  throw FormatException(
    'expected a list for "$what", got ${value.runtimeType}',
  );
}

Map<String, Object?> _object(Object? value, String what) {
  if (value is Map<String, Object?>) return value;
  throw FormatException(
    'expected an object for "$what", got '
    '${value.runtimeType}',
  );
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  throw FormatException('expected a number, got ${value.runtimeType}');
}

/// One GeoJSON position: `[lng, lat]`, optionally with an altitude we drop.
LatLng _position(List<Object?> coordinates) {
  if (coordinates.length < 2) {
    throw FormatException(
      'a position needs at least [lng, lat], got ${coordinates.length} values',
    );
  }
  // GeoJSON is [lng, lat]; LatLng is (lat, lng).
  return LatLng(_double(coordinates[1]), _double(coordinates[0]));
}

List<LatLng> _positions(List<Object?> raw) => [
  for (final p in raw) _position(_list(p, 'position')),
];

List<List<LatLng>> _positionLists(List<Object?> raw) => [
  for (final l in raw) _positions(_list(l, 'positions')),
];

/// A position back in GeoJSON's own order, as plain doubles.
List<double> _encode(LatLng point) => [point.longitude, point.latitude];

bool _nestedEquals(List<List<LatLng>> a, List<List<LatLng>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!listEquals(a[i], b[i])) return false;
  }
  return true;
}

int _nestedHash(List<List<LatLng>> value) =>
    Object.hashAll([for (final l in value) Object.hashAll(l)]);
