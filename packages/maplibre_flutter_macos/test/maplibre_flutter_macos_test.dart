import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter_macos/maplibre_flutter_macos.dart';
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
}
