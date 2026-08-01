import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter_platform_interface/geojson.dart';

/// Asymmetric on BOTH axes and in BOTH signs, so no mirrored or swapped axis
/// can pass by symmetry. Turku is north and east of Stockholm; Rio is south and
/// west of both. CLAUDE.md §7: absolute directions, never round-trips.
const _turku = LatLng(60.45, 22.27);
const _stockholm = LatLng(59.33, 18.06);
const _rio = LatLng(-22.91, -43.17);

void main() {
  group('positions', () {
    test('parse flips GeoJSON [lng, lat] into LatLng(lat, lng)', () {
      final point =
          GeoJsonGeometry.fromJson({
                'type': 'Point',
                'coordinates': [22.27, 60.45],
              })
              as GeoJsonPoint;

      expect(point.coordinates.latitude, closeTo(60.45, 1e-12));
      expect(point.coordinates.longitude, closeTo(22.27, 1e-12));
      // Absolute: Turku is far NORTH (lat > lng), which is only true one way
      // round. A swap would give lat 22.27, which is south of the equator's
      // Mediterranean latitudes and would still "round-trip" fine.
      expect(point.coordinates.latitude, greaterThan(50));
      expect(point.coordinates.longitude, lessThan(30));
    });

    test('serialise puts them back in [lng, lat]', () {
      final json = const GeoJsonPoint(_turku).toJson();
      expect(json['coordinates'], [22.27, 60.45]);
    });

    test('southern and western hemispheres keep their signs', () {
      final json = const GeoJsonPoint(_rio).toJson();
      expect(json['coordinates'], [-43.17, -22.91]);
      final back =
          GeoJsonGeometry.fromJson(json.cast<String, Object?>())
              as GeoJsonPoint;
      expect(back.coordinates.latitude, lessThan(0));
      expect(back.coordinates.longitude, lessThan(0));
      expect(
        back.coordinates.latitude,
        greaterThan(back.coordinates.longitude),
      );
    });

    test('a third element (altitude) is accepted and dropped', () {
      final point =
          GeoJsonGeometry.fromJson({
                'type': 'Point',
                'coordinates': [22.27, 60.45, 133.0],
              })
              as GeoJsonPoint;
      expect(point.coordinates, _turku);
    });
  });

  group('the seven RFC 7946 geometries', () {
    test('each round-trips through JSON with its own type string', () {
      final geometries = <GeoJsonGeometry>[
        const GeoJsonPoint(_turku),
        const GeoJsonMultiPoint([_turku, _stockholm]),
        const GeoJsonLineString([_turku, _stockholm, _rio]),
        const GeoJsonMultiLineString([
          [_turku, _stockholm],
          [_stockholm, _rio],
        ]),
        const GeoJsonPolygon([
          [_turku, _stockholm, _rio, _turku],
        ]),
        const GeoJsonMultiPolygon([
          [
            [_turku, _stockholm, _rio, _turku],
          ],
        ]),
        const GeoJsonGeometryCollection([
          GeoJsonPoint(_turku),
          GeoJsonLineString([_stockholm, _rio]),
        ]),
      ];

      for (final geometry in geometries) {
        final decoded = jsonDecode(jsonEncode(geometry.toJson()));
        final back = GeoJsonGeometry.fromJson(decoded as Map<String, Object?>);
        expect(back, geometry, reason: '${geometry.type} did not survive');
        expect(back.type, geometry.type);
      }
    });

    test('a polygon keeps its rings in order, exterior first', () {
      const polygon = GeoJsonPolygon([
        [_turku, _stockholm, _rio, _turku],
        [_stockholm, _rio, _turku, _stockholm],
      ]);
      final rings = polygon.toJson()['coordinates']! as List<Object?>;
      expect(rings, hasLength(2));
      expect((rings.first! as List).first, [22.27, 60.45]);
    });
  });

  group('parse failures are FormatException, never TypeError', () {
    // The whole error contract of queryRenderedFeatures rests on this: it
    // catches FormatException, and an unchecked cast would throw TypeError
    // straight past it into a camera-tick caller.
    final bad = <String, Map<String, Object?>>{
      'no type': {
        'coordinates': [1, 2],
      },
      'type is not a string': {'type': 7},
      'unknown type': {'type': 'Sphere', 'coordinates': <Object?>[]},
      'coordinates missing': {'type': 'Point'},
      'coordinates not a list': {'type': 'Point', 'coordinates': 'here'},
      'position too short': {
        'type': 'Point',
        'coordinates': [1],
      },
      'position not numeric': {
        'type': 'Point',
        'coordinates': ['1', '2'],
      },
      'nested shape wrong': {
        'type': 'LineString',
        'coordinates': [1, 2],
      },
      'collection members not objects': {
        'type': 'GeometryCollection',
        'geometries': ['nope'],
      },
    };

    bad.forEach((name, json) {
      test(name, () {
        expect(
          () => GeoJsonGeometry.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });
    });
  });

  group('GeoJsonFeature', () {
    test('carries id, geometry and properties', () {
      final feature = GeoJsonFeature.fromJson({
        'type': 'Feature',
        'id': 'harbour-1',
        'geometry': {
          'type': 'Point',
          'coordinates': [22.27, 60.45],
        },
        'properties': {'name': 'Turku'},
      });

      expect(feature.id, 'harbour-1');
      expect(feature.geometry, const GeoJsonPoint(_turku));
      expect(feature.properties['name'], 'Turku');
    });

    test('id may be a number, and null geometry is legal', () {
      final feature = GeoJsonFeature.fromJson({
        'type': 'Feature',
        'id': 12,
        'geometry': null,
        'properties': null,
      });
      expect(feature.id, 12);
      expect(feature.geometry, isNull);
      expect(feature.properties, isEmpty);
    });

    test('a non-scalar id is a FormatException', () {
      expect(
        () => GeoJsonFeature.fromJson({
          'type': 'Feature',
          'id': <String>['nope'],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('toJson does not rewrite numbers the way the style encoder does', () {
      // docs/decision-log.md: encodeStyleJson turns 6.0 into 6. These bytes are
      // the one path into mbgl's GeoJSON parser, so they must stay verbatim.
      const feature = GeoJsonFeature(
        geometry: GeoJsonPoint(LatLng(60.45, 6.0)),
        properties: {'height': 6.0},
      );
      final encoded = jsonEncode(feature.toJson());
      expect(encoded, contains('60.45'));
      expect(encoded, contains('6.0'));
      expect(encoded, isNot(contains('[6,')));
    });

    test('a feature collection round-trips', () {
      const collection = GeoJsonFeatureCollection([
        GeoJsonFeature(id: 1, geometry: GeoJsonPoint(_turku)),
        GeoJsonFeature(geometry: GeoJsonLineString([_stockholm, _rio])),
      ]);
      final back = GeoJsonFeatureCollection.fromJson(
        jsonDecode(jsonEncode(collection.toJson())) as Map<String, Object?>,
      );
      expect(back, collection);
    });

    test('a malformed member fails the whole collection', () {
      expect(
        () => GeoJsonFeatureCollection.fromJson({
          'type': 'FeatureCollection',
          'features': ['not a feature'],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => GeoJsonFeatureCollection.fromJson({'type': 'FeatureCollection'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('QueriedFeature', () {
    test('exposes the cluster facts Apple MLNCluster names', () {
      final cluster = QueriedFeature.fromJson({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [22.27, 60.45],
        },
        'properties': {
          'point_count': 42,
          'point_count_abbreviated': '42',
          'cluster_id': 7,
        },
      });

      expect(cluster.isCluster, isTrue);
      expect(cluster.pointCount, 42);
      expect(cluster.clusterId, 7);
      expect(cluster.point, _turku);
    });

    test('point is null for anything that is not a Point', () {
      const line = QueriedFeature(
        geometry: GeoJsonLineString([_turku, _stockholm]),
      );
      expect(line.point, isNull);
      expect(line.isCluster, isFalse);
      expect(line.pointCount, 1);
      expect(line.clusterId, isNull);
    });

    test('reads source, sourceLayer and state when the shim sends them', () {
      // Native tiers do not send these yet — the C shim slices them off — so
      // this pins the parse for when stage 6 stops slicing.
      final feature = QueriedFeature.fromJson({
        'type': 'Feature',
        'id': 3,
        'geometry': {
          'type': 'Point',
          'coordinates': [22.27, 60.45],
        },
        'properties': <String, Object?>{},
        'source': 'harbours',
        'sourceLayer': 'ports',
        'state': {'hovered': true},
      });

      expect(feature.source, 'harbours');
      expect(feature.sourceLayer, 'ports');
      expect(feature.state['hovered'], isTrue);
      expect(feature.toJson()['source'], 'harbours');
    });

    test('defaults to no provenance rather than throwing', () {
      final feature = QueriedFeature.fromJson({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [22.27, 60.45],
        },
        'properties': <String, Object?>{},
      });
      expect(feature.source, isNull);
      expect(feature.sourceLayer, isNull);
      expect(feature.state, isEmpty);
      expect(feature.toJson().containsKey('source'), isFalse);
    });

    test('equality distinguishes it from a plain feature', () {
      const queried = QueriedFeature(id: 1, geometry: GeoJsonPoint(_turku));
      const plain = GeoJsonFeature(id: 1, geometry: GeoJsonPoint(_turku));
      expect(queried == plain, isFalse);
      expect(plain == queried, isFalse);
      expect(
        queried,
        const QueriedFeature(id: 1, geometry: GeoJsonPoint(_turku)),
      );
      expect(
        queried,
        isNot(const QueriedFeature(id: 1, geometry: GeoJsonPoint(_stockholm))),
      );
    });
  });
}
