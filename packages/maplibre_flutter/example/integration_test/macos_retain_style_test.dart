// 5.9 on real hardware: what survives a style load, and what does not.
//
//   flutter test integration_test/macos_retain_style_test.dart -d macos
//
// WHY IT EXISTS: the unit tests drive a fake style controller, so they prove the
// snapshot/replay bookkeeping and nothing about mbgl. The behaviour being
// guarded is mbgl's — Style::Impl::parse() replaces the layer list, the source
// list AND the runtime image list on every load — and the whole point of the
// feature is what the engine does afterwards.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

// Two real documents, so the swap is a genuine load rather than a no-op.
const _first = 'https://demotiles.maplibre.org/style.json';
const _second = '''
{
  "version": 8,
  "sources": {},
  "layers": [
    {"id": "plain-bg", "type": "background",
     "paint": {"background-color": "#efefef"}}
  ]
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps a map, adds a source + layer + runtime image, then swaps the style
  /// and waits for the new document. Returns the controller.
  Future<MapLibreMapController> run(
    WidgetTester tester, {
    required bool retain,
  }) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);

    Future<void> pump(String style) => tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: style,
          retainRuntimeStyle: retain,
          options: const MapOptions(
            initialCamera: MapCamera(center: LatLng(60.45, 22.27), zoom: 3),
          ),
        ),
      ),
    );

    await pump(_first);
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));

    controller.style
      ..addSourceJson(
        'app-src',
        jsonEncode({
          'type': 'geojson',
          'data': {'type': 'FeatureCollection', 'features': <Object>[]},
        }),
      )
      ..addLayerJson(
        jsonEncode({
          'id': 'app-layer',
          'type': 'circle',
          'source': 'app-src',
          'paint': {'circle-color': '#0000ff'},
        }),
      )
      // Changed AFTER the add: a replay of the original call would lose it.
      ..setPaintProperty('app-layer', 'circle-color', const Color(0xFFFF0000))
      ..addImage(
        'app-icon',
        Uint8List(8 * 8 * 4)..fillRange(0, 256, 255),
        8,
        8,
      );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      controller.style.getLayersOrder(),
      contains('app-layer'),
      reason: 'precondition: the layer is there before the swap',
    );

    await pump(_second);
    // Bounded poll for the new document rather than a delay: only the engine
    // knows when the load finished.
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < const Duration(seconds: 20)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (controller.style.getLayersOrder().contains('plain-bg')) break;
    }
    expect(
      controller.style.getLayersOrder(),
      contains('plain-bg'),
      reason: 'the second document must actually be the live one',
    );
    return controller;
  }

  testWidgets('OFF: the app\'s layer and source go with the old style', (
    tester,
  ) async {
    final controller = await run(tester, retain: false);
    expect(
      controller.style.getLayersOrder(),
      isNot(contains('app-layer')),
      reason:
          'this is mbgl\'s behaviour and every upstream binding\'s: the '
          'app re-adds from onStyleLoaded',
    );
    expect(controller.style.getSourceIds(), isNot(contains('app-src')));
    // The image is the exception, and NOT because of retainRuntimeStyle: an
    // image has no form in a style document, so the engine replays it either
    // way (5.9a).
    expect(
      controller.style.hasImage('app-icon'),
      isTrue,
      reason: 'runtime images survive regardless of the flag',
    );
  });

  testWidgets('ON: the layer and source come back, in their LIVE state', (
    tester,
  ) async {
    final controller = await run(tester, retain: true);
    expect(controller.style.getSourceIds(), contains('app-src'));
    expect(controller.style.getLayersOrder(), contains('app-layer'));

    // Red, not blue: the recolour applied after the add survived, which is what
    // separates a live snapshot from a replay of the original call.
    final colour = controller.style.getPaintProperty(
      'app-layer',
      'circle-color',
    );
    expect(colour, isNotNull);
    expect(
      colour.toString(),
      contains('255'),
      reason:
          'circle-color must be the red set AFTER the add, not the blue '
          'the layer was created with — got $colour',
    );

    // On TOP of the new document, in the order they were added.
    final order = controller.style.getLayersOrder();
    expect(
      order.indexOf('app-layer'),
      greaterThan(order.indexOf('plain-bg')),
      reason: 'replayed layers sit above the incoming document',
    );
  });
}
