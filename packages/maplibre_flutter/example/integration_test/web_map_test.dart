// End-to-end web test (CLAUDE.md §7 layer 5): drives a real maplibre-gl-js map
// in a browser. Run with a chromedriver on :4444:
//
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/web_map_test.dart \
//     -d chrome
//
// It needs network access (loads the keyless demotiles style).
@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loads a style and moves the camera both ways', (tester) async {
    const demotiles = 'https://demotiles.maplibre.org/style.json';
    const liberty = 'https://tiles.openfreemap.org/styles/liberty';
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);

    Future<void> pumpWithStyle(String style) => tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: style,
          options: const MapOptions(
            initialCamera: MapCamera(center: LatLng(0, 0), zoom: 1),
          ),
        ),
      ),
    );

    await pumpWithStyle(demotiles);

    // The HtmlElementView mounts, the view factory builds the JS map, and its
    // 'load' event completes onReady — proving maplibre-gl-js loaded a style.
    await tester.pumpAndSettle();
    await controller.onReady;

    // Jump the camera, then read it back: exercises the Dart->JS->Dart bridge
    // and the LatLng(lat,lng) <-> [lng,lat] conversion in both directions.
    await controller.camera.move(
      const MapCamera(center: LatLng(51.5, -0.13), zoom: 6),
    );
    final cam = await controller.camera.getPosition();
    expect(cam.center.latitude, closeTo(51.5, 0.5));
    expect(cam.center.longitude, closeTo(-0.13, 0.5));
    expect(cam.zoom, closeTo(6, 0.5));

    // Style is declarative: rebuilding with a new `style` must push it to the
    // native map without throwing, and the map must keep reporting a camera.
    await pumpWithStyle(liberty);
    await tester.pumpAndSettle();
    final after = await controller.camera.getPosition();
    expect(after.zoom, closeTo(6, 0.5));
  });
}
