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
    MapLibreMapController? controller;
    await tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          options: const MapOptions(
            styleUri: 'https://demotiles.maplibre.org/style.json',
            initialCamera: MapCamera(center: LatLng(0, 0), zoom: 1),
          ),
          onMapCreated: (c) => controller = c,
        ),
      ),
    );

    // The HtmlElementView mounts, the view factory builds the JS map, and its
    // 'load' event completes onReady — proving maplibre-gl-js loaded a style.
    await tester.pumpAndSettle();
    expect(controller, isNotNull);
    await controller!.onReady;

    // Jump the camera, then read it back: exercises the Dart->JS->Dart bridge
    // and the LatLng(lat,lng) <-> [lng,lat] conversion in both directions.
    await controller!.moveCamera(
      const MapCamera(center: LatLng(51.5, -0.13), zoom: 6),
    );
    final cam = await controller!.getCamera();
    expect(cam.center.latitude, closeTo(51.5, 0.5));
    expect(cam.center.longitude, closeTo(-0.13, 0.5));
    expect(cam.zoom, closeTo(6, 0.5));

    // Swapping styles must not throw and the map must keep reporting a camera.
    await controller!.setStyle('https://tiles.openfreemap.org/styles/liberty');
    final after = await controller!.getCamera();
    expect(after.zoom, closeTo(6, 0.5));
  });
}
