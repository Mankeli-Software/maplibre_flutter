import 'package:flutter/animation.dart' show Cubic, Curves;
import 'package:flutter/painting.dart' show EdgeInsets, Offset;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Asymmetric on both axes and in both signs — the only fixture shape that can
/// catch a swapped or mirrored coordinate. CLAUDE.md §7.
const _turku = LatLng(60.45, 22.27);
const _stockholm = LatLng(59.33, 18.06);
const _rio = LatLng(-22.91, -43.17);

void main() {
  group('LatLng hardening', () {
    // mbgl::LatLng's constructor throws std::domain_error on each of these, and
    // a C++ throw across `extern "C"` is UB — so the assert has to fire here,
    // at the construction site, rather than the crash happening over there.
    test('rejects NaN latitude', () {
      expect(() => LatLng(double.nan, 0), throwsAssertionError);
    });

    test('rejects NaN longitude', () {
      expect(() => LatLng(0, double.nan), throwsAssertionError);
    });

    test('rejects a latitude past the poles', () {
      expect(() => LatLng(90.001, 0), throwsAssertionError);
      expect(() => LatLng(-90.001, 0), throwsAssertionError);
      expect(() => LatLng(double.infinity, 0), throwsAssertionError);
      // The poles themselves are legal.
      expect(const LatLng(90, 0).isValid, isTrue);
      expect(const LatLng(-90, 0).isValid, isTrue);
    });

    test('rejects an infinite longitude', () {
      expect(() => LatLng(0, double.infinity), throwsAssertionError);
      expect(() => LatLng(0, double.negativeInfinity), throwsAssertionError);
    });

    test('accepts an unwrapped longitude, because mbgl does', () {
      // WrapMode::Unwrapped is mbgl's default, and an unwrapped longitude is
      // how a camera crosses the antimeridian the short way.
      expect(const LatLng(0, 200).isValid, isTrue);
      expect(const LatLng(0, -540).isValid, isTrue);
    });

    test('wrapped() matches mbgl::util::wrap — [min, max)', () {
      expect(const LatLng(0, 190).wrapped().longitude, closeTo(-170, 1e-9));
      expect(const LatLng(0, -190).wrapped().longitude, closeTo(170, 1e-9));
      expect(
        const LatLng(0, 180).wrapped().longitude,
        -180,
        reason: 'max wraps',
      );
      expect(const LatLng(0, -180).wrapped().longitude, -180);
      expect(const LatLng(0, 0).wrapped().longitude, 0);
      // 540 = one and a half turns east; wrapping lands on the antimeridian.
      expect(const LatLng(0, 540).wrapped().longitude, -180);
      expect(_turku.wrapped(), _turku, reason: 'already in range');
      expect(const LatLng(60.45, 190).wrapped().latitude, 60.45);
    });

    test('sanitized makes any pair safe', () {
      expect(LatLng.sanitized(double.nan, double.nan), const LatLng(0, 0));
      expect(LatLng.sanitized(120, 0).latitude, 90);
      expect(LatLng.sanitized(-120, 0).latitude, -90);
      expect(LatLng.sanitized(double.infinity, 0).latitude, 90);
      expect(LatLng.sanitized(0, double.infinity).longitude, 0);
      expect(LatLng.sanitized(60.45, 190).longitude, closeTo(-170, 1e-9));
      // A good value passes through untouched, signs and all.
      expect(LatLng.sanitized(-22.91, -43.17), _rio);
    });

    test('isValid agrees with the asserts', () {
      expect(_turku.isValid, isTrue);
      expect(LatLng.sanitized(double.nan, 400).isValid, isTrue);
    });
  });

  group('LatLngBounds', () {
    // Turku is north AND east of Stockholm, so which corner is which is
    // decidable — a symmetric fixture would not be.
    const nordic = LatLngBounds(southwest: _stockholm, northeast: _turku);

    test('corners and edges are the ones mbgl names', () {
      expect(nordic.south, 59.33);
      expect(nordic.west, 18.06);
      expect(nordic.north, 60.45);
      expect(nordic.east, 22.27);
      expect(nordic.southeast, const LatLng(59.33, 22.27));
      expect(nordic.northwest, const LatLng(60.45, 18.06));
      // North is up, east is right — absolute, not a round-trip.
      expect(nordic.north, greaterThan(nordic.south));
      expect(nordic.east, greaterThan(nordic.west));
    });

    test('center is the midpoint of the corners', () {
      expect(nordic.center.latitude, closeTo(59.89, 1e-9));
      expect(nordic.center.longitude, closeTo(20.165, 1e-9));
    });

    test('fromPoints hulls them, in any order', () {
      final hull = LatLngBounds.fromPoints(const [_turku, _rio, _stockholm]);
      expect(hull.north, 60.45, reason: 'Turku is the northernmost');
      expect(hull.south, -22.91, reason: 'Rio is the southernmost');
      expect(hull.east, 22.27, reason: 'Turku is the easternmost');
      expect(hull.west, -43.17, reason: 'Rio is the westernmost');
      expect(
        LatLngBounds.fromPoints(const [_rio, _stockholm, _turku]),
        hull,
        reason: 'order must not matter',
      );
    });

    test('fromPoints rejects an empty iterable', () {
      expect(() => LatLngBounds.fromPoints(const []), throwsArgumentError);
    });

    test('empty() is the identity for extend', () {
      final empty = LatLngBounds.empty();
      expect(empty.isEmpty, isTrue);
      expect(empty.isValid, isFalse);
      expect(empty.extend(_turku), LatLngBounds.singleton(_turku));
    });

    test('world() covers everything', () {
      final world = LatLngBounds.world();
      expect(world.contains(_turku), isTrue);
      expect(world.contains(_rio), isTrue);
      expect(world.isValid, isTrue);
    });

    test('extend grows only in the direction it must', () {
      final grown = nordic.extend(_rio);
      expect(grown.south, -22.91);
      expect(grown.west, -43.17);
      expect(grown.north, 60.45, reason: 'unchanged — Rio is south of it');
      expect(grown.east, 22.27, reason: 'unchanged — Rio is west of it');
      expect(nordic.extend(_turku), nordic, reason: 'already inside');
    });

    test('contains is inclusive of the edges', () {
      expect(nordic.contains(_turku), isTrue);
      expect(nordic.contains(_stockholm), isTrue);
      expect(nordic.contains(const LatLng(60, 20)), isTrue);
      expect(nordic.contains(_rio), isFalse);
      // Just outside on one axis only, each way round.
      expect(nordic.contains(const LatLng(60.46, 20)), isFalse);
      expect(nordic.contains(const LatLng(60, 22.28)), isFalse);
      expect(nordic.contains(const LatLng(59.32, 20)), isFalse);
      expect(nordic.contains(const LatLng(60, 18.05)), isFalse);
    });

    test('containsBounds and intersects', () {
      const inner = LatLngBounds(
        southwest: LatLng(59.5, 19),
        northeast: LatLng(60, 21),
      );
      expect(nordic.containsBounds(inner), isTrue);
      expect(inner.containsBounds(nordic), isFalse);
      expect(nordic.intersects(inner), isTrue);
      expect(inner.intersects(nordic), isTrue);
      expect(
        nordic.intersects(LatLngBounds.singleton(_rio)),
        isFalse,
        reason: 'a different hemisphere entirely',
      );
      // Touching along one edge counts, matching contains' inclusivity.
      expect(
        nordic.intersects(
          const LatLngBounds(
            southwest: LatLng(60.45, 22.27),
            northeast: LatLng(70, 30),
          ),
        ),
        isTrue,
      );
    });

    test('crossesAntimeridian', () {
      // 170°E to 170°W: the short way round goes over the 180th meridian, so
      // the eastern corner is numerically the smaller one.
      const overTheLine = LatLngBounds(
        southwest: LatLng(-10, 170),
        northeast: LatLng(10, -170),
      );
      expect(overTheLine.crossesAntimeridian, isTrue);
      expect(nordic.crossesAntimeridian, isFalse);
      expect(LatLngBounds.world().crossesAntimeridian, isFalse);
    });
  });

  group('CameraOptions', () {
    test('is empty when nothing is set, and partial otherwise', () {
      expect(const CameraOptions().isEmpty, isTrue);
      expect(const CameraOptions(zoom: 12).isEmpty, isFalse);
      expect(const CameraOptions(zoom: 12).center, isNull);
    });

    test('applyTo fills only the unset fields', () {
      const base = MapCamera(
        center: _stockholm,
        zoom: 4,
        bearing: 30,
        pitch: 10,
      );
      final moved = const CameraOptions(zoom: 12).applyTo(base);
      expect(moved.zoom, 12);
      expect(moved.center, _stockholm, reason: 'untouched');
      expect(moved.bearing, 30);
      expect(moved.pitch, 10);

      final recentred = CameraOptions(center: _turku).applyTo(base);
      expect(recentred.center, _turku);
      expect(recentred.zoom, 4);
    });

    test('fromCamera round-trips a full camera', () {
      const base = MapCamera(center: _turku, zoom: 9, bearing: 45, pitch: 20);
      expect(CameraOptions.fromCamera(base).applyTo(base), base);
      expect(
        CameraOptions.fromCamera(
          base,
          padding: const EdgeInsets.only(bottom: 120),
        ).padding,
        const EdgeInsets.only(bottom: 120),
      );
    });

    test('carries padding as EdgeInsets and an anchor as an Offset', () {
      const options = CameraOptions(
        zoom: 14,
        padding: EdgeInsets.fromLTRB(8, 16, 8, 120),
        anchor: Offset(100, 40),
      );
      expect(options.padding!.bottom, 120);
      // Top-left origin, per mbgl's own comment on CameraOptions::anchor.
      expect(options.anchor, const Offset(100, 40));
      // The anchor cannot survive a resolve, because mbgl drops it whenever a
      // centre is present — applyTo returns a MapCamera, which always has one.
      expect(
        options.applyTo(const MapCamera(center: _turku)),
        isA<MapCamera>(),
      );
    });

    test('copyWith and equality cover every field', () {
      const options = CameraOptions(
        center: _turku,
        zoom: 9,
        bearing: 45,
        pitch: 20,
        roll: 5,
        padding: EdgeInsets.all(4),
        anchor: Offset(1, 2),
      );
      expect(options.copyWith(), options);
      expect(options.copyWith(zoom: 10), isNot(options));
      expect(options.copyWith(zoom: 10).zoom, 10);
      expect(options.copyWith(zoom: 10).roll, 5);
      expect(options.hashCode, options.copyWith().hashCode);
    });
  });

  group('CameraAnimation', () {
    test('none is instant', () {
      expect(CameraAnimation.none.isInstant, isTrue);
      expect(
        const CameraAnimation(duration: Duration(seconds: 1)).isInstant,
        isFalse,
      );
    });

    test("takes Flutter's Cubic easings directly", () {
      // Curves.easeInOut IS a Cubic, which is what maps onto mbgl's UnitBezier.
      const animation = CameraAnimation(easing: Curves.easeInOut);
      expect(animation.easing, isA<Cubic>());
      expect(animation.isInstant, isFalse);
    });

    test('apexZoom is the flight apex, not a constraint', () {
      const flight = CameraAnimation(speed: 1.4, apexZoom: 3);
      expect(flight.apexZoom, 3);
      expect(flight.speed, 1.4);
      expect(flight.copyWith(speed: 2).apexZoom, 3);
      expect(flight, const CameraAnimation(speed: 1.4, apexZoom: 3));
    });
  });
}
