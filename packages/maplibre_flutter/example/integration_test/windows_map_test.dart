// End-to-end Windows desktop test (CLAUDE.md §7 layer 5): drives a real mbgl-core
// map (the maplibre_flutter_core ANGLE/OpenGL-ES + EGL arm) composited through a
// Flutter Texture. Run on a Windows device:
//
//   flutter test integration_test/windows_map_test.dart -d windows
//
// It needs network access (loads the keyless demotiles + OpenFreeMap styles) and a
// GPU/ANGLE-capable context. Every wait is bounded so a context/render failure fails
// the test instead of hanging.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders a frame and moves the camera (Windows/mbgl-core)', (
    tester,
  ) async {
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

    // The Texture mounts and createMap returns; onReady completes once mbgl-core
    // has rendered the first frame off-screen (proving the ANGLE/EGL context,
    // headless GL backend and FFI present path all work). Bounded so a failure to
    // produce a frame fails the test rather than hanging.
    await tester.pump();
    expect(controller, isNotNull);
    await controller!.onReady.timeout(const Duration(seconds: 30));

    // Jump the camera, then read it back: exercises the Dart -> FFI -> Dart bridge.
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
