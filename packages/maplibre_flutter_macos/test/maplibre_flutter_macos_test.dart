import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter_macos/maplibre_flutter_macos.dart';
import 'package:maplibre_flutter_macos/src/fly_animation.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registerWith installs the platform instance', () {
    MapLibreFlutterMacos.registerWith();
    expect(MapLibreFlutterPlatform.instance, isA<MapLibreFlutterMacos>());
  });

  // createMap() drives mbgl-core over FFI and the native texture registrar, so
  // the core dylib must be built and loaded — it cannot run in a pure-Dart unit
  // test. It is exercised end-to-end by the example app's integration test
  // (a real rendered frame in the Texture); see CLAUDE.md §7 layer 5.

  group('flyCameraAt', () {
    const start = MapCamera(center: LatLng(0, 0), zoom: 1);
    const target = MapCamera(center: LatLng(51.5, -0.13), zoom: 10);

    test('endpoints: t=0 is the start, t=1 is the target', () {
      final a = flyCameraAt(start, target, 0);
      expect(a.center.latitude, closeTo(0, 1e-6));
      expect(a.zoom, closeTo(1, 1e-6));

      final b = flyCameraAt(start, target, 1);
      expect(b.center.latitude, closeTo(51.5, 1e-6));
      expect(b.center.longitude, closeTo(-0.13, 1e-6));
      expect(b.zoom, closeTo(10, 1e-6));
    });

    test('mid-flight is partway between start and target', () {
      final m = flyCameraAt(start, target, 0.5);
      expect(m.center.latitude, greaterThan(0));
      expect(m.center.latitude, lessThan(51.5));
    });

    test('a far flight zooms out below both endpoints mid-flight', () {
      const london = MapCamera(center: LatLng(51.5, -0.13), zoom: 10);
      const tokyo = MapCamera(center: LatLng(35.68, 139.77), zoom: 10);
      final m = flyCameraAt(london, tokyo, 0.5);
      expect(m.zoom, lessThan(10), reason: 'should dip to a fitting zoom');
    });

    test('takes the shortest longitude path across the antimeridian', () {
      const a = MapCamera(center: LatLng(0, 170), zoom: 2);
      const b = MapCamera(center: LatLng(0, -170), zoom: 2);
      final lng = flyCameraAt(a, b, 0.5).center.longitude;
      final near180 = (lng - 180).abs() < 5 || (lng + 180).abs() < 5;
      expect(
        near180,
        isTrue,
        reason: 'should cross the antimeridian, not pan the long way through 0',
      );
    });
  });
}
