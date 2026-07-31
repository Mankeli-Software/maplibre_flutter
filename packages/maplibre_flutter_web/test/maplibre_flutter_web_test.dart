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

  test('core module URL defaults to a path an app can actually serve', () {
    // It must be a RELATIVE url resolving against the app's web root, because
    // the artifact belongs next to index.html. The previous default,
    // `assets/packages/maplibre_flutter_core/web/...`, was unreachable by
    // construction: maplibre_flutter_core is a pure-Dart package with no
    // `flutter:` section, so it cannot declare Flutter assets at all.
    expect(coreModuleUrl, endsWith('.js'));
    expect(
      coreModuleUrl,
      isNot(startsWith('assets/packages/maplibre_flutter_core/')),
      reason: 'a pure-Dart package cannot serve Flutter assets',
    );
    expect(
      Uri.parse(coreModuleUrl).isAbsolute,
      isFalse,
      reason: 'relative to the app web root, so any host/base path works',
    );
  });
}
