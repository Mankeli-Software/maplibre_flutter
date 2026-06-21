// The implementation imports dart:ui_web / dart:js_interop, which only exist on
// the web compiler — so these tests run under `flutter test --platform chrome`
// and are skipped on the default VM run (and thus by `melos run test`).
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:maplibre_flutter_web/maplibre_flutter_web.dart';
import 'package:maplibre_flutter_web/src/core_web/core_wasm_loader.dart';

void main() {
  test('registerWith installs the core (WASM) platform instance', () {
    // The Registrar is ignored (no message channel on the data path); a bare
    // instance is enough to drive registration.
    MapLibreFlutterWeb.registerWith(Registrar());
    expect(MapLibreFlutterPlatform.instance, isA<MapLibreFlutterWeb>());
  });

  test('core module URL defaults to the bundled plugin asset path', () {
    // The WASM artifact ships as a maplibre_flutter_core web asset; the default
    // loader URL must resolve there (override with MAPLIBRE_WEB_CORE_URL).
    expect(
      coreModuleUrl,
      startsWith('assets/packages/maplibre_flutter_core/web/'),
    );
    expect(coreModuleUrl, endsWith('.js'));
  });
}
