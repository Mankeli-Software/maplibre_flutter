// Drives the three style FORMS against a real engine on macOS:
//
//   flutter test integration_test/macos_style_forms_test.dart -d macos
//
// WHY IT EXISTS: two of the three forms cannot be proved anywhere else. The
// inline-document form is decided inside the C shim (a leading `{` routes to
// Style::loadJSON instead of loadURL), and the asset form is decided in Dart
// but only pays off if the engine then accepts what rootBundle handed back. A
// fake core would report success for a document mbgl never parsed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

const _url = 'https://demotiles.maplibre.org/style.json';
const _asset = 'asset://assets/styles/nordic_night.json';
const _inline = '''
{
  "version": 8,
  "sources": {},
  "layers": [
    {"id": "bg", "type": "background",
     "paint": {"background-color": "#123456"}}
  ]
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps a map on [style] and waits for the engine to say the style is in.
  Future<MapLibreMapController> boot(WidgetTester tester, String style) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: style,
          options: const MapOptions(
            initialCamera: MapCamera(center: LatLng(60.45, 22.27), zoom: 3),
          ),
        ),
      ),
    );
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));
    return controller;
  }

  testWidgets('a URL loads, and its layers are the served ones', (
    tester,
  ) async {
    final controller = await boot(tester, _url);
    final ids = controller.style.getLayersOrder();
    expect(
      ids,
      contains('countries-fill'),
      reason: 'the demotiles document defines this layer',
    );
  });

  testWidgets('an inline DOCUMENT loads — loadJSON, not loadURL', (
    tester,
  ) async {
    final controller = await boot(tester, _inline);
    final ids = controller.style.getLayersOrder();
    // Asserting the CONTENT, not that a frame came back (CLAUDE.md §7): a
    // document treated as a URL fails asynchronously and leaves an empty style,
    // which still renders and still reports ready.
    expect(ids, equals(<String>['bg']));
    expect(
      controller.style.getPaintProperty('bg', 'background-color'),
      isNotNull,
    );
  });

  testWidgets('a bundled ASSET loads', (tester) async {
    final controller = await boot(tester, _asset);
    final ids = controller.style.getLayersOrder();
    expect(ids, contains('countries-boundary'));
    expect(
      ids,
      contains('geolines'),
      reason: 'the whole bundled document must arrive, not a prefix of it',
    );
  });

  testWidgets('switching FORMS at runtime replaces the whole document', (
    tester,
  ) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);
    Future<void> pump(String style) => tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: style,
          options: const MapOptions(
            initialCamera: MapCamera(center: LatLng(60.45, 22.27), zoom: 3),
          ),
        ),
      ),
    );

    await pump(_url);
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));
    expect(controller.style.getLayersOrder(), contains('countries-fill'));

    // URL -> asset. Bounded poll rather than a delay: the load is asynchronous
    // and only the engine knows when the new document is in.
    await pump(_asset);
    var ids = <String>[];
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < const Duration(seconds: 20)) {
      await tester.pump(const Duration(milliseconds: 100));
      ids = controller.style.getLayersOrder();
      if (ids.contains('geolines')) break;
    }
    expect(ids, contains('geolines'), reason: 'the asset document must land');
    expect(
      ids,
      isNot(contains('countries-label')),
      reason:
          'a style load REPLACES the document; leftovers from the URL style '
          'would mean it merged instead',
    );

    // asset -> inline document.
    await pump(_inline);
    stopwatch.reset();
    while (stopwatch.elapsed < const Duration(seconds: 20)) {
      await tester.pump(const Duration(milliseconds: 100));
      ids = controller.style.getLayersOrder();
      if (ids.length == 1 && ids.first == 'bg') break;
    }
    expect(ids, equals(<String>['bg']));
  });
}
