import 'dart:typed_data';

import 'package:maplibre_flutter_core/maplibre_flutter_core.dart';
import 'package:test/test.dart';

/// Native render test for the desktop core (CLAUDE.md §7 layer 2 / §8 M1).
///
/// Requires the mbgl-core submodule to be vendored and the CMake build to run —
/// `dart run melos run test:native` runs the build hook first. Until the
/// submodule is initialised (see hook/build.dart for the one-time commands),
/// this fails at the build step by design (the build is deferred, §8 M1).
///
/// Also needs network access to fetch the demo style + tiles.
void main() {
  test('renders a non-blank frame from a style', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    map.setCamera(latitude: 0, longitude: 0, zoom: 1);

    // The render thread produces frames asynchronously (network style + tiles).
    expect(
      map.awaitFrame(const Duration(seconds: 20)),
      isTrue,
      reason: 'a frame should render within the timeout',
    );
    final frame = map.copyFrame();

    expect(frame, isNotNull);
    expect(frame!.length, 256 * 256 * 4);
    expect(
      frame.any((byte) => byte != 0),
      isTrue,
      reason: 'rendered frame should not be entirely blank',
    );

    // Dump a PNG for visual verification of the rendered map.
    expect(map.writePng('/tmp/maplibre_frame.png'), isTrue);
  });

  test('camera round-trips through the native getter', () {
    final map = MapLibreCoreMap.create(
      width: 64,
      height: 64,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    map.setCamera(latitude: 12.5, longitude: -7.25, zoom: 3, bearing: 45);
    final camera = map.getCamera();

    expect(camera.latitude, closeTo(12.5, 1e-6));
    expect(camera.longitude, closeTo(-7.25, 1e-6));
    expect(camera.zoom, closeTo(3, 1e-6));
    expect(camera.bearing, closeTo(45, 1e-6));
  });

  test('resize re-renders at the new frame size', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    map.resize(480, 320);
    // Wait for the render thread to publish the resized (non-square) frame.
    Uint8List? frame;
    for (var i = 0; i < 200; i++) {
      frame = map.copyFrame();
      if (frame != null && frame.length == 480 * 320 * 4) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(frame, isNotNull);
    expect(frame!.length, 480 * 320 * 4);
    expect(map.writePng('/tmp/maplibre_resized.png'), isTrue);
  });

  test('scaleBy zooms the camera in (gesture op)', () async {
    final map = MapLibreCoreMap.create(
      width: 512,
      height: 512,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    map.setCamera(latitude: 0, longitude: 0, zoom: 3);
    final before = map.getCamera().zoom;

    map.scaleBy(2, 256, 256); // zoom in 2x about the centre → zoom + 1
    // The gesture op applies and refreshes the camera cache on the render
    // thread, so the change is observable after a short delay.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (map.getCamera().zoom <= before + 0.5 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(map.getCamera().zoom, greaterThan(before));
  });
}
