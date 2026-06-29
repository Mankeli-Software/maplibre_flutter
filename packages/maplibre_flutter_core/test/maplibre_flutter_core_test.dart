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

  test('projects the camera centre to the viewport centre', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    map.setCamera(latitude: 12.0, longitude: 34.0, zoom: 4);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    // The camera centre always lands at the middle of the viewport (no insets).
    final p = map.project(12.0, 34.0);
    expect(p, isNotNull);
    expect(p!.x, closeTo(128, 0.5));
    expect(p.y, closeTo(128, 0.5));
    expect(p.visible, isTrue);
  });

  test('round-trips screen <-> latLng (project ∘ unproject == identity)', () {
    final map = MapLibreCoreMap.create(
      width: 320,
      height: 240,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    map.setCamera(latitude: 0, longitude: 0, zoom: 3);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    for (final (x, y) in const [(200.0, 100.0), (40.0, 200.0), (310.0, 30.0)]) {
      final ll = map.unproject(x, y);
      expect(ll, isNotNull, reason: 'unproject ($x,$y)');
      final back = map.project(ll!.latitude, ll.longitude);
      expect(back, isNotNull);
      expect(back!.x, closeTo(x, 0.5));
      expect(back.y, closeTo(y, 0.5));
    }
  });

  test('batch projection matches single, and bumps generation on change',
      () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    map.setCamera(latitude: 0, longitude: 0, zoom: 3);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    final input = Float64List.fromList([10, 20, -5, 33, 0, 0]);
    final out = Float64List(6);
    final visible = Int32List(3);
    final gen = map.projectBatch(3, input, out, visible: visible);
    expect(gen, greaterThan(0));
    expect(gen, map.projectionGeneration);

    for (var i = 0; i < 3; i++) {
      final single = map.project(input[i * 2], input[i * 2 + 1]);
      expect(out[i * 2], closeTo(single!.x, 1e-9));
      expect(out[i * 2 + 1], closeTo(single.y, 1e-9));
      expect(visible[i] != 0, single.visible);
    }

    // A camera change advances the projection generation.
    map.setCamera(latitude: 1, longitude: 1, zoom: 4);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (map.projectionGeneration <= gen &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(map.projectionGeneration, greaterThan(gen));
  });

  test('projection is exact under bearing + pitch', () {
    final map = MapLibreCoreMap.create(
      width: 400,
      height: 300,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    map.setCamera(
      latitude: 40.0,
      longitude: -3.0,
      zoom: 5,
      bearing: 30,
      pitch: 40,
    );
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    // Centre is still centred under rotation/tilt.
    final centre = map.project(40.0, -3.0);
    expect(centre!.x, closeTo(200, 0.5));
    expect(centre.y, closeTo(150, 0.5));

    // An off-centre, near-camera point still round-trips exactly under pitch.
    final ll = map.unproject(250, 200);
    final back = map.project(ll!.latitude, ll.longitude);
    expect(back!.x, closeTo(250, 0.5));
    expect(back.y, closeTo(200, 0.5));
  });

  test('projection returns null before any frame/transform exists', () {
    final map = MapLibreCoreMap.create(
      width: 128,
      height: 128,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    // No camera set yet and no frame awaited: the snapshot may not exist.
    if (map.projectionGeneration == 0) {
      expect(map.project(0, 0), isNull);
      expect(map.unproject(0, 0), isNull);
    }
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
