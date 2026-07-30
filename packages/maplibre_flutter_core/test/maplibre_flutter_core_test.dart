import 'dart:io' show sleep;
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

  // A round-trip cannot detect a mirrored axis (the flip cancels), and the
  // camera centre is symmetric — so orientation needs its own absolute-direction
  // test. mbgl's TransformState works in a BOTTOM-UP y; the shim flips it to the
  // top-left origin Flutter widgets use, and this is what pins that down.
  test('projection is oriented top-left: north is up, east is right', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    map.setCamera(latitude: 0, longitude: 0, zoom: 5);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    final centre = map.project(0, 0)!;
    final north = map.project(1, 0)!;
    final east = map.project(0, 1)!;

    expect(
      north.y,
      lessThan(centre.y),
      reason: 'a point north of centre must project ABOVE it (smaller y)',
    );
    expect(
      east.x,
      greaterThan(centre.x),
      reason: 'a point east of centre must project to the RIGHT of it',
    );
    // Absolute value too, so a regression reads as a concrete mismatch: at this
    // camera 1 degree of latitude is ~45.5 px, so north lands at ~82.5, and the
    // flipped (wrong) answer would be ~173.5.
    expect(north.y, closeTo(82.5, 1.0));
  });

  test('unproject is oriented top-left: above centre is north', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    map.setCamera(latitude: 0, longitude: 0, zoom: 5);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    final above = map.unproject(128, 88)!;
    final right = map.unproject(168, 128)!;

    expect(
      above.latitude,
      greaterThan(0),
      reason: 'a screen point above centre must be north of it',
    );
    expect(
      right.longitude,
      greaterThan(0),
      reason: 'a screen point right of centre must be east of it',
    );
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

  test(
    'batch projection matches single, and bumps generation on change',
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
    },
  );

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

  // Frame-correlated projection: markers must be placed with the transform of
  // the frame ON SCREEN, not the newest one, or they swim against the map while
  // it moves (camera commands apply asynchronously on the render thread).
  test('projects against a requested past generation, not just the newest', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    map.setCamera(latitude: 0, longitude: 0, zoom: 5);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    // Remember the generation of the frame on screen, and where a point lands
    // under it.
    final oldGen = map.presentedGeneration;
    expect(oldGen, greaterThan(0), reason: 'a frame has been presented');
    final before = map.project(0, 0, generation: oldGen)!;

    // Move the camera. NOTE awaitFrame() returns immediately once ANY frame
    // exists, so it cannot be used to wait for the *next* one — poll the
    // presented generation instead, which is the thing under test anyway.
    map.setCamera(latitude: 10, longitude: 0, zoom: 5);
    final deadline = Stopwatch()..start();
    while (map.presentedGeneration == oldGen &&
        deadline.elapsed < const Duration(seconds: 20)) {
      sleep(const Duration(milliseconds: 10));
    }
    expect(
      map.presentedGeneration,
      greaterThan(oldGen),
      reason: 'a newly published frame must advance the presented generation',
    );
    final newest = map.project(0, 0)!;
    expect(
      newest.y,
      isNot(closeTo(before.y, 1.0)),
      reason: 'the newest transform must reflect the move',
    );

    // ...but projecting against the OLD generation still reproduces the old
    // position: the ring really is keyed by generation.
    final replay = map.project(0, 0, generation: oldGen)!;
    expect(replay.x, closeTo(before.x, 0.01));
    expect(replay.y, closeTo(before.y, 0.01));
  });

  test('an unknown generation falls back to the newest transform', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    map.setCamera(latitude: 0, longitude: 0, zoom: 5);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    // Far outside the ring: must degrade gracefully, not return null/garbage.
    final stale = map.project(0, 0, generation: 999999);
    final newest = map.project(0, 0);
    expect(stale, isNotNull);
    expect(stale!.x, closeTo(newest!.x, 0.01));
    expect(stale.y, closeTo(newest.y, 0.01));
  });

  // --- Style sources / layers / images (engine-drawn datasets) ---------------

  /// Counts pixels close to [r],[g],[b] in an RGBA frame — how we prove the
  /// engine actually DREW something, rather than just accepting the calls.
  int countColor(Uint8List f, int r, int g, int b, {int tol = 24}) {
    var n = 0;
    for (var i = 0; i + 3 < f.length; i += 4) {
      if ((f[i] - r).abs() <= tol &&
          (f[i + 1] - g).abs() <= tol &&
          (f[i + 2] - b).abs() <= tol) {
        n++;
      }
    }
    return n;
  }

  /// A geojson FeatureCollection of [count] points spread around (lat, lng).
  String pointsAround(double lat, double lng, int count, double spread) {
    final features = <String>[];
    for (var i = 0; i < count; i++) {
      // Deterministic scatter (no Random, so runs are comparable).
      final dx = ((i * 37) % 100) / 100.0 - 0.5;
      final dy = ((i * 71) % 100) / 100.0 - 0.5;
      features.add(
        '{"type":"Feature","geometry":{"type":"Point","coordinates":'
        '[${lng + dx * spread},${lat + dy * spread}]},"properties":{}}',
      );
    }
    return '{"type":"FeatureCollection","features":[${features.join(",")}]}';
  }

  test('draws a geojson circle layer the engine renders itself', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    map.setCamera(latitude: 60.45, longitude: 22.27, zoom: 9);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    final before = countColor(map.copyFrame()!, 255, 0, 255);

    map.addSourceJson('pts', '''
      {"type":"geojson","data":${pointsAround(60.45, 22.27, 200, 0.4)}}
    ''');
    // Unmistakable magenta, so the count can't be confused with map colours.
    map.addLayerJson('''
      {"id":"pts-circles","type":"circle","source":"pts",
       "paint":{"circle-radius":4,"circle-color":"#ff00ff"}}
    ''');

    // Style mutations are applied on the render thread; wait for the repaint.
    final sw = Stopwatch()..start();
    var after = 0;
    while (sw.elapsed < const Duration(seconds: 20)) {
      after = countColor(map.copyFrame()!, 255, 0, 255);
      if (after > before + 50) break;
      sleep(const Duration(milliseconds: 50));
    }
    expect(
      after,
      greaterThan(before + 50),
      reason: 'the circle layer must actually paint pixels',
    );
    expect(map.writePng('/tmp/maplibre_circles.png'), isTrue);
  });

  test('clusters points in-engine when the source sets cluster: true', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    // Zoomed out, so a dense cluster collapses to a few cluster circles.
    map.setCamera(latitude: 60.45, longitude: 22.27, zoom: 4);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    map.addSourceJson('c', '''
      {"type":"geojson","cluster":true,"clusterRadius":50,"clusterMaxZoom":14,
       "data":${pointsAround(60.45, 22.27, 500, 0.5)}}
    ''');
    // Only CLUSTERS are drawn (point_count exists only on cluster features), so
    // any paint here proves supercluster ran inside the engine.
    map.addLayerJson('''
      {"id":"clusters","type":"circle","source":"c","filter":["has","point_count"],
       "paint":{"circle-radius":14,"circle-color":"#ff00ff"}}
    ''');

    final sw = Stopwatch()..start();
    var painted = 0;
    while (sw.elapsed < const Duration(seconds: 20)) {
      painted = countColor(map.copyFrame()!, 255, 0, 255);
      if (painted > 50) break;
      sleep(const Duration(milliseconds: 50));
    }
    expect(
      painted,
      greaterThan(50),
      reason: 'clustered features must render (filter matches only clusters)',
    );
    expect(map.writePng('/tmp/maplibre_clusters.png'), isTrue);
  });

  // HAZARD, verified: a symbol layer naming a font the style cannot serve makes
  // mbgl request glyphs that 404 — and that does NOT merely lose the text. The
  // failure propagates out of the RENDER itself ("render failed: HTTP status
  // code 404" from renderNow's catch), so no frame is produced at all: the map
  // stops updating, not just that layer.
  //
  // This bit for real: MapLibreLayersController.addPoints used to emit a cluster
  // count label with no `text-font`, so mbgl fell back to "Open Sans Regular,
  // Arial Unicode MS Regular" — served by demotiles, absent from OpenFreeMap
  // Liberty — and switching to Liberty silently killed the whole dataset. Hence
  // clusterTextFont is required for counts and the label layer is omitted
  // otherwise. This test pins the engine behaviour that makes that necessary.
  test('a symbol layer with an unavailable font BLOCKS its whole source', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    map.setCamera(latitude: 60.45, longitude: 22.27, zoom: 4);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    map.addSourceJson('g', '''
      {"type":"geojson","cluster":true,"clusterRadius":50,
       "data":${pointsAround(60.45, 22.27, 300, 0.5)}}
    ''');
    map.addLayerJson('''
      {"id":"g-circles","type":"circle","source":"g","filter":["has","point_count"],
       "paint":{"circle-radius":14,"circle-color":"#ff00ff"}}
    ''');
    // Deliberately bogus font: the glyph fetch must fail.
    map.addLayerJson('''
      {"id":"g-count","type":"symbol","source":"g","filter":["has","point_count"],
       "layout":{"text-field":"x","text-font":["No Such Font Regular"]}}
    ''');

    // Give it well past the time a healthy source needs (the working cluster
    // test above paints within a second).
    final sw = Stopwatch()..start();
    var painted = 0;
    while (sw.elapsed < const Duration(seconds: 8)) {
      painted = countColor(map.copyFrame()!, 255, 0, 255);
      if (painted > 50) break;
      sleep(const Duration(milliseconds: 50));
    }
    expect(
      painted,
      lessThanOrEqualTo(50),
      reason:
          'documents the hazard: the bad glyph fetch blocks the circle layer '
          'too. If this ever starts passing, mbgl has been fixed and the '
          'clusterTextFont guard could be relaxed.',
    );
  });

  // queryRenderedFeatures takes a screen box, and its convention has to MATCH
  // project()'s — a caller works out where something is with project(), then
  // queries there. Verified, not assumed (the projection Y axis was mirrored
  // for exactly this reason).
  test('queries rendered features in the same screen space as project', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    map.setCamera(latitude: 60.45, longitude: 22.27, zoom: 9);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    // One point, well away from the centre so a Y flip would be obvious.
    const lat = 60.55, lng = 22.27;
    map.addSourceJson('q', '''
      {"type":"geojson","data":{"type":"Feature","properties":{"tag":"target"},
       "geometry":{"type":"Point","coordinates":[$lng,$lat]}}}
    ''');
    map.addLayerJson('''
      {"id":"q-c","type":"circle","source":"q",
       "paint":{"circle-radius":10,"circle-color":"#ff00ff"}}
    ''');

    // Wait for it to actually paint before querying what was rendered.
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 20)) {
      if (countColor(map.copyFrame()!, 255, 0, 255) > 20) break;
      sleep(const Duration(milliseconds: 50));
    }

    // Where project() says it is — query a small box around that point.
    final at = map.project(lat, lng, generation: map.presentedGeneration)!;
    final hit = map.queryRenderedFeatures(
      at.x - 12,
      at.y - 12,
      at.x + 12,
      at.y + 12,
    );
    expect(hit, isNotNull);
    expect(
      hit!.contains('target'),
      isTrue,
      reason:
          'querying where project() placed the feature must find it; if this '
          'fails the query box Y convention disagrees with the projection',
    );

    // And the mirrored position must NOT find it, which is what proves the
    // test would catch a flip rather than passing by luck.
    final mirrored = map.queryRenderedFeatures(
      at.x - 12,
      (256 - at.y) - 12,
      at.x + 12,
      (256 - at.y) + 12,
    );
    expect(
      mirrored == null || !mirrored.contains('target'),
      isTrue,
      reason: 'the vertically mirrored box must not match',
    );
  });

  test('rejects malformed style JSON synchronously', () {
    final map = MapLibreCoreMap.create(
      width: 64,
      height: 64,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    expect(
      () => map.addSourceJson('bad', '{not json'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => map.addLayerJson('{"id":"x","type":"nonsense","source":"y"}'),
      throwsA(isA<ArgumentError>()),
    );
    // A well-formed source is accepted.
    map.addSourceJson(
      'ok',
      '{"type":"geojson","data":{"type":"FeatureCollection","features":[]}}',
    );
  });

  test('registers an image usable as a symbol icon', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    map.setCamera(latitude: 60.45, longitude: 22.27, zoom: 9);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    // A solid magenta 16x16 icon — stands in for a Flutter widget painted to
    // an image (the widget-as-engine-marker path).
    const w = 16, h = 16;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      rgba[i * 4] = 255; // r
      rgba[i * 4 + 1] = 0; // g
      rgba[i * 4 + 2] = 255; // b
      rgba[i * 4 + 3] = 255; // a
    }
    map.addImage('pin', rgba, w, h);
    map.addSourceJson('ipts', '''
      {"type":"geojson","data":${pointsAround(60.45, 22.27, 40, 0.3)}}
    ''');
    map.addLayerJson('''
      {"id":"ipins","type":"symbol","source":"ipts",
       "layout":{"icon-image":"pin","icon-allow-overlap":true}}
    ''');

    final sw = Stopwatch()..start();
    var painted = 0;
    while (sw.elapsed < const Duration(seconds: 20)) {
      painted = countColor(map.copyFrame()!, 255, 0, 255);
      if (painted > 50) break;
      sleep(const Duration(milliseconds: 50));
    }
    expect(
      painted,
      greaterThan(50),
      reason: 'the registered icon must render via the symbol layer',
    );
    expect(map.writePng('/tmp/maplibre_icons.png'), isTrue);
  });

  test('setGeoJsonData replaces a source without rebuilding the layer', () {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    map.setCamera(latitude: 60.45, longitude: 22.27, zoom: 9);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    map.addSourceJson(
      'dyn',
      '{"type":"geojson","data":{"type":"FeatureCollection","features":[]}}',
    );
    map.addLayerJson('''
      {"id":"dyn-c","type":"circle","source":"dyn",
       "paint":{"circle-radius":5,"circle-color":"#ff00ff"}}
    ''');

    // Empty source: nothing of ours painted yet.
    map.setGeoJsonData('dyn', pointsAround(60.45, 22.27, 150, 0.3));

    final sw = Stopwatch()..start();
    var painted = 0;
    while (sw.elapsed < const Duration(seconds: 20)) {
      painted = countColor(map.copyFrame()!, 255, 0, 255);
      if (painted > 50) break;
      sleep(const Duration(milliseconds: 50));
    }
    expect(
      painted,
      greaterThan(50),
      reason: 'new data must appear through the existing layer',
    );
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
