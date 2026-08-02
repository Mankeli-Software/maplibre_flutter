import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

QueriedFeature _feature(GeoJsonGeometry geometry, Map<String, Object?> props) =>
    QueriedFeature(geometry: geometry, properties: props);

// South-west to north-east, which is the orientation Apple's own test uses.
final _swToNe = GeoJsonLineString(const <LatLng>[LatLng(0, 0), LatLng(1, 1)]);
final _swToNeDivided = GeoJsonMultiLineString(const <List<LatLng>>[
  <LatLng>[LatLng(0, 0), LatLng(1, 1)],
]);

void main() {
  group('the road describer, ported from MLNRoadFeatureAccessibilityElement', () {
    // Apple's own suite has exactly these two cases, and they are NOT the same
    // fixture: the one-way case is a single polyline and the divided case is a
    // multi-polyline with no `oneway` at all.
    test("Apple's one-way case", () {
      final d = describeMapLibreFeature(
        _feature(_swToNe, const {'ref': '42', 'oneway': 'true'}),
        'road',
      )!;
      expect(
        '${d.label}, ${d.value}',
        'Route 42, One way, southwest to northeast',
      );
    });

    test("Apple's divided case", () {
      final d = describeMapLibreFeature(
        _feature(_swToNeDivided, const {'ref': '42'}),
        'road',
      )!;
      expect(
        '${d.label}, ${d.value}',
        'Route 42, Divided road, southwest to northeast',
      );
    });

    // ABSOLUTE, not a round trip: a road running due east must say so, and a
    // mirrored rose would render just as plausibly.
    test('a due-east road runs west to east', () {
      final d = describeMapLibreFeature(
        _feature(
          GeoJsonLineString(const <LatLng>[LatLng(0, 0), LatLng(0, 5)]),
          const {'ref': '1'},
        ),
        'road',
      )!;
      expect(d.value, contains('west to east'));
    });

    test('a due-north road runs south to north', () {
      final d = describeMapLibreFeature(
        _feature(
          GeoJsonLineString(const <LatLng>[LatLng(0, 0), LatLng(5, 0)]),
          const {'ref': '1'},
        ),
        'road',
      )!;
      expect(d.value, contains('south to north'));
    });

    test('a named road leads with its name, not its number', () {
      final d = describeMapLibreFeature(
        _feature(_swToNe, const {'name': 'Mannerheimintie', 'ref': '51'}),
        'road',
      )!;
      expect(d.label, 'Mannerheimintie');
      expect(d.value, contains('Route 51'));
    });
  });

  group('places', () {
    test('a localized name wins over the plain one', () {
      final d = describeMapLibreFeature(
        _feature(const GeoJsonPoint(LatLng(60.17, 24.94)), const {
          'name': 'Helsinki',
          'name:en': 'Helsinki City',
        }),
        'place_label',
      )!;
      expect(d.label, 'Helsinki City');
    });

    test('the underscore spelling is covered too', () {
      final d = describeMapLibreFeature(
        _feature(const GeoJsonPoint(LatLng(60.17, 24.94)), const {
          'name_en': 'Helsinki City',
        }),
        'place_label',
      )!;
      expect(d.label, 'Helsinki City');
    });

    // A blank stop on the swipe path is worse than one fewer stop.
    test('a feature with nothing to say is dropped', () {
      expect(
        describeMapLibreFeature(
          _feature(const GeoJsonPoint(LatLng(0, 0)), const {}),
          'poi',
        ),
        isNull,
      );
    });

    test('a feature with no geometry is dropped', () {
      expect(
        describeMapLibreFeature(
          QueriedFeature(properties: const {'name': 'Nowhere'}),
          'poi',
        ),
        isNull,
      );
    });
  });

  group('representativePoint', () {
    test('every geometry reduces to one point', () {
      expect(
        representativePoint(const GeoJsonPoint(LatLng(1, 2))),
        const LatLng(1, 2),
      );
      expect(
        representativePoint(
          GeoJsonLineString(const <LatLng>[LatLng(0, 0), LatLng(1, 1)]),
        ),
        const LatLng(1, 1),
      );
      expect(
        representativePoint(
          GeoJsonPolygon(const <List<LatLng>>[
            <LatLng>[LatLng(0, 0), LatLng(2, 2), LatLng(0, 0)],
          ]),
        ),
        const LatLng(2, 2),
      );
    });

    test('an empty geometry yields nothing rather than the origin', () {
      // Returning LatLng(0, 0) would put a node in the Gulf of Guinea, which
      // is the map equivalent of the Flow layout-origin trap.
      expect(representativePoint(const GeoJsonMultiPoint(<LatLng>[])), isNull);
      expect(representativePoint(null), isNull);
    });
  });
}
