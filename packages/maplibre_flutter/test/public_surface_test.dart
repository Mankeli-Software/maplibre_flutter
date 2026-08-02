// What an app can NAME with only `package:maplibre_flutter` imported.
//
// This file imports the public library and **nothing else**, deliberately.
// Adding the platform-interface import would make all of it compile regardless
// of the export list, which is exactly the hole it exists to close:
// `controller.onError` shipped returning a sealed type whose cases an app could
// not name, so the exhaustive `switch` the sealed type was chosen for — the
// adaptation CLAUDE.md §9 records — did not compile for anybody outside this
// repo.
//
// Behaviour that needs a fake platform lives in snapshot_test.dart; the seam it
// needs (`MapLibreFlutterPlatform`) is deliberately NOT public API.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

/// The reason `MapLibreError` is sealed rather than a string-keyed event.
///
/// No `default` arm and no `_` catch-all, so this compiles only while every
/// subclass is both exported and accounted for. Adding a seventh error case
/// breaks the build here — which is the contract working, not a broken test.
String describe(MapLibreError error) => switch (error) {
  MapStyleError() => 'style',
  MapGlyphsError() => 'glyphs',
  MapSpriteError() => 'sprite',
  MapRenderError() => 'render',
  MapCommandError() => 'command',
  MapEngineError() => 'engine',
};

void main() {
  group('the error hierarchy is nameable from outside', () {
    test('an exhaustive switch covers every case', () {
      expect(describe(const MapStyleError('x')), 'style');
      expect(describe(const MapGlyphsError('x')), 'glyphs');
      expect(describe(const MapSpriteError('x')), 'sprite');
      expect(describe(const MapRenderError('x')), 'render');
      expect(describe(const MapCommandError('x')), 'command');
      expect(describe(const MapEngineError('x')), 'engine');
    });

    test('the base type carries the engine message', () {
      const MapLibreError error = MapStyleError('404 on the style');
      expect(error.message, '404 on the style');
    });
  });

  test('the capability interfaces are nameable, so `is` works', () {
    // Feature detection is the documented way to ask what a tier can do
    // (CLAUDE.md §3). An app that cannot name the interface cannot ask.
    Object? probe;
    expect(probe is MapLibreMapEvents, isFalse);
    expect(probe is MapLibreMapCapture, isFalse);
    expect(probe is MapLibreStyleLayers, isFalse);
    expect(probe is MapLibreModelHost, isFalse);
    probe = null;
  });

  test('the gesture and snapshot value types are nameable', () {
    const gestures = MapGestureSettings(zoomGesturesEnabled: false);
    expect(gestures.zoomGesturesEnabled, isFalse);
    expect(MapGestureSettings.none.interactive, isFalse);
  });
}
