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

    // The Texture mounts and createMap returns; onReady completes once mbgl-core
    // has rendered the first frame off-screen (proving the ANGLE/EGL context,
    // headless GL backend and FFI present path all work). Bounded so a failure to
    // produce a frame fails the test rather than hanging.
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));

    // Jump the camera, then read it back: exercises the Dart -> FFI -> Dart bridge.
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
    await tester.pump();
    final after = await controller.camera.getPosition();
    expect(after.zoom, closeTo(6, 0.5));
  });
}
