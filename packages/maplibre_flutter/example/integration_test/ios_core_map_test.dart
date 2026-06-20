// End-to-end iOS test for the EXPERIMENTAL core renderer (CLAUDE.md §7 layer 5):
// drives a real mbgl-core map (the maplibre_flutter_core Metal arm) composited
// through a Flutter Texture, instead of the default MapLibre Apple SDK / UiKitView.
//
// Run on a REAL iOS DEVICE (not the Simulator — it cannot headless-render Metal,
// and the core dylib is not even built for it) with the experimental flag:
//
//   flutter test integration_test/ios_core_map_test.dart -d <device> \
//     --dart-define=MAPLIBRE_EXPERIMENTAL_CORE=true
//
// Without the dart-define this exercises the SDK/UiKitView path instead (the
// camera round-trip still holds; the render path differs). It needs network access
// (loads the keyless demotiles + OpenFreeMap styles). Every wait is bounded so a
// context/render failure fails the test instead of hanging.
//
// NOTE (CLAUDE.md §7): onReady completing proves mbgl-core produced a first frame
// off-screen, but it does NOT prove the frame has visible map content. A full
// confirmation is a visual/non-blank-pixel check on the device — the same manual
// step every desktop tier used at bring-up.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders a frame and moves the camera (iOS/mbgl-core)', (
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
    // has rendered the first frame off-screen (proving the Metal headless backend,
    // the IOSurface/CVPixelBuffer present path and FFI all work on the device).
    // Bounded so a failure to produce a frame fails the test rather than hanging.
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
