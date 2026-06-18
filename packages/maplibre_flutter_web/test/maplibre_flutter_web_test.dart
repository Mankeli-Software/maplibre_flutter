// The implementation imports dart:ui_web / dart:js_interop, which only exist on
// the web compiler — so these tests run under `flutter test --platform chrome`
// and are skipped on the default VM run (and thus by `melos run test`).
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:maplibre_flutter_web/maplibre_flutter_web.dart';
import 'package:maplibre_flutter_web/src/maplibre_gl_loader.dart';

void main() {
  test('registerWith installs the platform instance', () {
    // The Registrar is ignored (no message channel on the data path); a bare
    // instance is enough to drive registration.
    MapLibreFlutterWeb.registerWith(Registrar());
    expect(MapLibreFlutterPlatform.instance, isA<MapLibreFlutterWeb>());
  });

  test('pinned maplibre-gl-js version is a stable 5.x release', () {
    // Guards against an accidental jump to a prerelease (e.g. 6.0.0-x); bump
    // deliberately alongside the interop surface (CLAUDE.md §10).
    expect(maplibreGlVersion, matches(RegExp(r'^5\.\d+\.\d+$')));
  });
}
