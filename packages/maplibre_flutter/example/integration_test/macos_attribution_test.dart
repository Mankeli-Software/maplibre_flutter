// 8.6 against real tile servers.
//
//   flutter test integration_test/macos_attribution_test.dart -d macos
//
// WHY ON HARDWARE: a source's attribution usually is NOT in the style document
// — it comes from the TileJSON the source points at, which mbgl fetches after
// the style loads. So whether we can read it at all is a question about mbgl's
// fetch timing, and a fake cannot answer it. This is a licence condition, so
// "we probably read it eventually" is not good enough to assume.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

const _liberty = 'https://tiles.openfreemap.org/styles/liberty';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("a real style's attribution is readable and rendered", (
    tester,
  ) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: _liberty,
          options: const MapOptions(
            initialCamera: MapCamera(center: LatLng(60.45, 22.27), zoom: 8),
          ),
        ),
      ),
    );
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));

    // Poll: the attribution arrives with the TileJSON, not with the style, so
    // it is legitimately absent for a moment after onReady.
    var attributions = <MapAttribution>[];
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < const Duration(seconds: 20)) {
      await tester.pump(const Duration(milliseconds: 200));
      attributions = controller.style.getAttributions();
      if (attributions.isNotEmpty) break;
    }

    expect(
      attributions,
      isNotEmpty,
      reason:
          'OpenFreeMap Liberty is OpenStreetMap-derived, so it declares a '
          'credit we are legally required to show. Reading none means we are '
          'shipping a licence breach, not a cosmetic gap',
    );
    expect(
      attributions.map((a) => a.text).join(' ').toLowerCase(),
      contains('openstreetmap'),
    );
    // The controller sees them the moment the TileJSON lands; the WIDGET picks
    // them up on its own retry tick, so give it one before asserting on screen.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.textContaining('OpenStreetMap').evaluate().isNotEmpty) break;
    }

    // And it must actually be ON SCREEN, since displaying it is the condition.
    expect(find.byType(MapLibreAttributionBar), findsOneWidget);
    expect(find.textContaining('OpenStreetMap'), findsWidgets);
  });

  testWidgets('showAttribution: false renders nothing', (tester) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: _liberty,
          showAttribution: false,
          options: const MapOptions(
            initialCamera: MapCamera(center: LatLng(60.45, 22.27), zoom: 8),
          ),
        ),
      ),
    );
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 2));

    expect(find.byType(MapLibreAttributionBar), findsNothing);
    // The strings are still READABLE — the opt-out is about who renders them,
    // not about hiding them.
    expect(controller.style.getAttributions(), isNotEmpty);
  });
}
