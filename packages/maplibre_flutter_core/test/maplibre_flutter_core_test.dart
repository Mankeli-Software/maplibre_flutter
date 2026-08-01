import 'dart:convert';
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
///
/// Waits until every posted command has been applied on the render thread.
///
/// Neither obvious alternative works. `awaitFrame` returns as soon as ANY frame
/// exists, including one rendered before the command landed. And `getCamera`
/// reads a cache that `setCamera` writes SYNCHRONOUSLY on the calling thread
/// before posting the jumpTo, so polling it returns immediately having proved
/// nothing. `projectionGeneration` is bumped inside the posted lambda after the
/// transform is mutated, so wait for it to advance AND then hold still — the
/// style load and resize bump it too, so a single advance can be someone
/// else's. (The same mistake made src/proj_probe.cpp fail ~1 run in 8.)
Future<void> settle(MapLibreCoreMap map) async {
  final before = map.projectionGeneration;
  var last = before;
  var quiet = 0;
  for (var i = 0; i < 400 && quiet < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    final now = map.projectionGeneration;
    if (now == last && now > before) {
      quiet++;
    } else {
      quiet = 0;
      last = now;
    }
  }
}

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
  /// Counts pixels matching (r, g, b) in a frame from [MapLibreCoreMap.copyFrame].
  ///
  /// **Frames are BGRA** (`maplibre_flutter_core.h`, mbl_map_copy_frame), which
  /// this used to ignore: it read byte 0 as red. Every test that existed then
  /// asserted magenta (#ff00ff) or green (#00ff00), and R equals B in both, so
  /// the swap was invisible for the life of the helper — CLAUDE.md §11's
  /// "verify a convention with an ASYMMETRIC fixture", demonstrated the hard
  /// way by the first test that used red and blue.
  int countColor(Uint8List f, int r, int g, int b, {int tol = 24}) {
    var n = 0;
    for (var i = 0; i + 3 < f.length; i += 4) {
      if ((f[i] - b).abs() <= tol &&
          (f[i + 1] - g).abs() <= tol &&
          (f[i + 2] - r).abs() <= tol) {
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

  // What this does NOT assert: that symbol labels stop fading. That is a
  // per-frame opacity ramp inside mbgl's placement, only honoured in Continuous
  // mode, and not observable from a still frame — it needs an on-device look.
  // What it does pin: the call is safe on a live map, before and after a style
  // load (the sticky re-apply path), and does not disturb rendering.
  test('setTransitionOptions is safe and survives a style change', () {
    final map = MapLibreCoreMap.create(
      width: 128,
      height: 128,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
      continuous: true,
    );
    addTearDown(map.dispose);

    // Before the first frame, mid-life, and with every argument exercised.
    map
      ..setTransitionOptions(placementTransitions: false)
      ..setCamera(latitude: 60.45, longitude: 22.27, zoom: 3);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    expect(map.copyFrame(), isNotNull);

    // A style load resets the style's transition options to the document's, so
    // the shim re-applies ours from onDidFinishLoadingStyle. Nothing to read
    // back through the C ABI; this asserts the map keeps rendering through it.
    map
      ..setStyle('https://demotiles.maplibre.org/style.json')
      ..setTransitionOptions(
        duration: const Duration(milliseconds: 120),
        delay: Duration.zero,
        placementTransitions: true,
      );
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    // Continuous mode publishes PARTIAL frames, so a freshly loaded style is
    // legitimately blank for a moment — and awaitFrame returns as soon as any
    // frame exists, including that one. So poll for real content instead of
    // asserting on whichever frame happens to be current.
    bool hasContent() {
      final f = map.copyFrame();
      return f != null && f.any((b) => b != 0);
    }

    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 20) && !hasContent()) {
      sleep(const Duration(milliseconds: 50));
    }
    expect(
      hasContent(),
      isTrue,
      reason: 'still rendering after a style reload',
    );
  });

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

  // ---------------------------------------------------------------------------
  // Convention guards.
  //
  // CLAUDE.md §11 opens by naming this project's recurring failure mode: every
  // coordinate bug so far looked right and rendered something, because it hid
  // behind a symmetry — a static model, a heading of 180, a round trip, the map
  // centre. The tests below deliberately break the symmetry that would hide
  // each convention error, and each one guards a convention that four platforms
  // are about to inherit without anyone being able to run them.
  // ---------------------------------------------------------------------------

  // SYMMETRY BROKEN: pixel ratio. mbgl allocates its framebuffer as
  // `Size * pixelRatio`, so `Size` must be LOGICAL POINTS. At DPR 1 the logical
  // and device spaces coincide exactly, so a tier that passes device pixels
  // renders an identical picture — and DPR 1 is every CI runner and every
  // desktop screenshot taken so far. At DPR 3 it puts every marker at 3x its
  // coordinates and makes gestures move 3x too fast.
  test('mbgl Size is logical points: projection is pixelRatio-invariant', () {
    ({double x, double y}) centreOf(double pixelRatio) {
      final map = MapLibreCoreMap.create(
        width: 512,
        height: 512,
        pixelRatio: pixelRatio,
        styleUri: 'https://demotiles.maplibre.org/style.json',
      );
      addTearDown(map.dispose);
      map.setCamera(latitude: 0, longitude: 0, zoom: 3);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      final p = map.project(0, 0)!;
      return (x: p.x, y: p.y);
    }

    final atOne = centreOf(1);
    final atThree = centreOf(3);

    expect(atOne.x, closeTo(256, 1));
    expect(atOne.y, closeTo(256, 1));
    expect(
      atThree.x,
      closeTo(256, 1),
      reason:
          'the camera centre must project to the middle of the LOGICAL '
          'viewport at any density; 768 here would mean Size was fed device '
          'pixels and multiplied by the ratio a second time',
    );
    expect(atThree.y, closeTo(256, 1));
  });

  // SYMMETRY BROKEN: the anchor point. Gesture anchors are TOP-LEFT origin and
  // pass to mbgl unflipped — the OPPOSITE of the projection rule, which is
  // exactly why it gets "fixed" wrongly (a flip shipped once and mirrored the
  // Windows pinch anchor). Every existing test zooms about the viewport centre,
  // where a flip, a wrong sign and an anchor that is ignored outright all look
  // identical. Anchor in the corners instead, and check an absolute compass
  // direction rather than a round trip.
  test('zoom anchors are top-left origin, proven from the corners', () async {
    final map = MapLibreCoreMap.create(
      width: 512,
      height: 512,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    Future<CoreCamera> zoomAbout(double ax, double ay) async {
      map.setCamera(latitude: 0, longitude: 0, zoom: 3);
      await settle(map);
      map.scaleBy(2, ax, ay);
      await settle(map);
      return map.getCamera();
    }

    // Top-left corner: the point under the anchor stays put while everything
    // magnifies about it, so the centre is pulled toward it — north and west.
    final topLeft = await zoomAbout(0, 0);
    expect(
      topLeft.latitude,
      greaterThan(0),
      reason:
          'anchoring at the TOP-left must move the centre NORTH; if the '
          'shim flipped y this would go south, and a centre-anchored test '
          'could not tell',
    );
    expect(topLeft.longitude, lessThan(0), reason: 'and WEST');

    // Top-right: north again, but east — which a pure y-flip would not change,
    // so this pins the x axis independently.
    final topRight = await zoomAbout(512, 0);
    expect(topRight.latitude, greaterThan(0));
    expect(topRight.longitude, greaterThan(0), reason: 'top-RIGHT is EAST');

    // Bottom-left: south and west. Taken together the three corners pin both
    // axes and rule out the anchor being dropped entirely, which would leave
    // the centre at (0, 0) in all three.
    final bottomLeft = await zoomAbout(0, 512);
    expect(bottomLeft.latitude, lessThan(0), reason: 'BOTTOM-left is SOUTH');
    expect(bottomLeft.longitude, lessThan(0));
  });

  // SYMMETRY BROKEN: pitch. `visible` is false for points behind the camera on
  // a pitched view. The marker overlay pre-fills its flags with `true`, so a
  // tier that never writes them behaves identically to a correct one — at pitch
  // 0, which is MapCamera's default, every example scenario's initial camera,
  // and every other test in this file. Above pitch 0 the failure is not a
  // missing marker but a WRONG one: mbgl mirrors points behind the camera
  // across the horizon, so a marker on the far side of the world paints at a
  // plausible on-screen position and reads as a data bug.
  test('visible is false behind a pitched camera, with finite coordinates', () {
    final map = MapLibreCoreMap.create(
      width: 512,
      height: 512,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    map.setCamera(latitude: 0, longitude: 0, zoom: 14, pitch: 60);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    expect(
      map.project(0, 0)!.visible,
      isTrue,
      reason: 'the camera centre is visible',
    );

    // Pitching tilts the camera back, so it sits SOUTH of and above the centre
    // looking north. The half-space with w <= 0 is therefore behind the viewer
    // — far SOUTH — not past the horizon to the north. (Web mercator is a flat
    // plane, so at pitch 60 every point to the north is still in front, however
    // distant.)
    final ahead = map.project(1, 0)!; // 1 degree north, in front
    final behind = map.project(-1, 0)!; // 1 degree south, behind the camera

    expect(ahead.visible, isTrue);
    expect(
      behind.visible,
      isFalse,
      reason: 'a point behind a pitched camera must report NOT visible',
    );

    // This is the whole point of the flag, and why culling on NaN or on
    // "off-screen" is not a substitute: mbgl MIRRORS points behind the camera
    // across the horizon, so the two land within ~35px of each other, both
    // above the viewport, both perfectly finite. Nothing about the coordinate
    // says one of them is on the wrong side of the world.
    expect(behind.x.isFinite && behind.y.isFinite, isTrue);
    expect(
      (behind.y - ahead.y).abs(),
      lessThan(100),
      reason:
          'the mirrored point is indistinguishable BY POSITION from the '
          'real one — only the flag separates them, which is why a tier that '
          'never writes it paints markers from the far side of the world',
    );
  });

  // SYMMETRY BROKEN: the sign, and the anchor — as two separate facts, because
  // one fixture cannot show both.
  //
  // A CORNER-anchored rotation both turns and translates the world, so "the
  // northern point ends up to the right" simply is not true of it; that only
  // holds about the centre. Conversely a CENTRE-anchored rotation cannot show
  // the anchor was honoured at all, since the centre is a fixed point whether
  // the anchor was applied or silently dropped — and dropped is the live
  // hazard, because mbgl discards CameraOptions::anchor whenever a centre is
  // also set, which is exactly what mbl_map_set_camera always sends.
  test('rotateBy turns the content clockwise', () async {
    final map = MapLibreCoreMap.create(
      width: 512,
      height: 512,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    map.setCamera(latitude: 0, longitude: 0, zoom: 3);
    await settle(map);

    // Baseline: at bearing 0 a point due north projects ABOVE centre.
    final centre = map.project(0, 0)!;
    final north = map.project(1, 0)!;
    expect(north.y, lessThan(centre.y));
    final radius = (north.y - centre.y).abs();

    map.rotateBy(90, 256, 256); // about the centre: isolates the SIGN
    await settle(map);

    // Turning the content 90 degrees clockwise carries the point that was above
    // centre round to the RIGHT of it. A reversed sign puts it to the LEFT at
    // the same distance, which no magnitude-only check could tell apart.
    final moved = map.project(1, 0)!;
    expect(
      moved.x,
      greaterThan(centre.x),
      reason:
          'clockwise must swing the northern point RIGHT; left means the '
          'bearing sign is inverted',
    );
    expect(
      (moved.x - centre.x).abs(),
      closeTo(radius, radius * 0.35),
      reason: 'and at roughly the same radius — rotated, not translated',
    );
    expect(
      moved.y,
      closeTo(centre.y, radius * 0.35),
      reason: 'a quarter turn puts it level with the centre',
    );
  });

  test('rotateBy honours its anchor rather than silently dropping it', () async {
    final map = MapLibreCoreMap.create(
      width: 512,
      height: 512,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    Future<CoreCamera> rotateAbout(double ax, double ay) async {
      map.setCamera(latitude: 0, longitude: 0, zoom: 3);
      await settle(map);
      map.rotateBy(90, ax, ay);
      await settle(map);
      return map.getCamera();
    }

    // The contrast IS the test. Rotating about the viewport centre must leave
    // the camera centre exactly where it was; rotating about a corner must move
    // it. An implementation that dropped the anchor — the get-camera-then-
    // set-camera one, since set_camera always supplies a centre — leaves it
    // unmoved in BOTH cases, and a centre-only test would call that correct.
    final aboutCentre = await rotateAbout(256, 256);
    expect(aboutCentre.latitude, closeTo(0, 1e-6));
    expect(aboutCentre.longitude, closeTo(0, 1e-6));

    final aboutCorner = await rotateAbout(0, 0);
    expect(
      aboutCorner.latitude.abs() + aboutCorner.longitude.abs(),
      greaterThan(1e-3),
      reason:
          'a corner-anchored rotation must move the camera centre; not '
          'moving it means the anchor never reached mbgl',
    );
  });

  test('pitchBy tilts toward the horizon and mbgl clamps at 60', () async {
    final map = MapLibreCoreMap.create(
      width: 512,
      height: 512,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    map.setCamera(latitude: 0, longitude: 0, zoom: 3);
    await settle(map);
    expect(map.getCamera().pitch, closeTo(0, 1e-6));

    // POSITIVE tilts AWAY from straight down. mbgl's own Map::pitchBy
    // subtracts, so an implementation built on it would go the other way and
    // simply clamp to 0 — which looks like "pitch does nothing".
    map.pitchBy(30);
    await settle(map);
    expect(
      map.getCamera().pitch,
      closeTo(30, 0.5),
      reason: 'positive degrees must INCREASE pitch',
    );

    // No Dart-side clamp: this asserts mbgl owns the limit, so a change to
    // DEFAULT_PITCH_MAX shows up here instead of being masked by our own clamp.
    map.pitchBy(60);
    await settle(map);
    expect(
      map.getCamera().pitch,
      closeTo(60, 0.5),
      reason:
          'mbgl clamps to DEFAULT_PITCH_MAX (60), and we do not duplicate it',
    );
  });

  // The C header has promised "URL, file path, or inline JSON" since it was
  // written, and four Dart doc comments repeat it — but every load went to
  // Style::loadURL, so an inline document silently failed. loadJSON existed and
  // was never called.
  test('a style can be the DOCUMENT itself, not just a URL', () async {
    // A complete, self-contained style: no network, no sprite, no glyphs.
    // Magenta background, so "did it load" is a pixel count rather than a guess.
    const inline =
        '{'
        '"version":8,'
        '"name":"inline",'
        '"sources":{},'
        '"layers":[{"id":"bg","type":"background",'
        '"paint":{"background-color":"#ff00ff"}}]'
        '}';
    final map = MapLibreCoreMap.create(
      width: 128,
      height: 128,
      pixelRatio: 1,
      styleUri: inline,
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    await settle(map);

    expect(
      countColor(map.copyFrame()!, 255, 0, 255),
      greaterThan(128 * 128 ~/ 2),
      reason: 'the inline document must actually paint',
    );
  });

  // 5.9. Style::Impl::parse() does `images = makeMutable<ImageImpls>()`
  // (style_impl.cpp:104), so every style load wipes every runtime image. Unlike
  // a source or a layer, an image has no form in a style document — nobody but
  // this layer can put it back, so an app that rasterised a widget into an icon
  // would have found its symbols blank after any style change.
  //
  // Run in BOTH modes on purpose. The last mode-shaped bug here shipped green
  // because the only test used Static and every real tier is Continuous.
  for (final continuous in [false, true]) {
    final mode = continuous ? 'Continuous' : 'Static';
    test('a runtime image survives a style load ($mode mode)', () async {
      const first =
          '{'
          '"version":8,"sources":{},'
          '"layers":[{"id":"bg","type":"background",'
          '"paint":{"background-color":"#101010"}}]'
          '}';
      const second =
          '{'
          '"version":8,"sources":{},'
          '"layers":[{"id":"bg","type":"background",'
          '"paint":{"background-color":"#202020"}}]'
          '}';
      final map = MapLibreCoreMap.create(
        width: 64,
        height: 64,
        pixelRatio: 1,
        styleUri: first,
        continuous: continuous,
      );
      addTearDown(map.dispose);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      await settle(map);

      final pixels = Uint8List(8 * 8 * 4)..fillRange(0, 8 * 8 * 4, 200);
      map.addImage('icon', pixels, 8, 8);
      map.addImage('doomed', Uint8List(4 * 4 * 4), 4, 4);
      await settle(map);
      expect(map.hasImage('icon'), isTrue, reason: 'precondition');

      // An image the app REMOVED must not come back. A replay cache that only
      // ever grows resurrects exactly what was deliberately deleted.
      map.removeImage('doomed');
      await settle(map);

      map.setStyle(second);
      await settle(map);
      // Prove the load actually happened, rather than asserting on a style that
      // never changed — otherwise this passes for the wrong reason.
      expect(
        map.getLayerProperty('bg', 'background-color'),
        contains('32'),
        reason: 'the second document must be the live one (0x20 == 32)',
      );

      expect(
        map.hasImage('icon'),
        isTrue,
        reason: 'the retained image must be re-registered after the load',
      );
      expect(
        map.hasImage('doomed'),
        isFalse,
        reason: 'a removed image must stay removed across a style load',
      );
    });
  }

  // Guards the helper above. An asymmetric colour is the whole point: a frame
  // painted pure RED must be counted as red and NOT as blue. Without this the
  // channel order is only ever exercised by colours where it cannot matter.
  test('countColor reads BGRA, and an asymmetric colour proves it', () async {
    const red =
        '{'
        '"version":8,"sources":{},'
        '"layers":[{"id":"bg","type":"background",'
        '"paint":{"background-color":"#ff0000"}}]'
        '}';
    final map = MapLibreCoreMap.create(
      width: 64,
      height: 64,
      pixelRatio: 1,
      styleUri: red,
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    await settle(map);

    final frame = map.copyFrame()!;
    expect(countColor(frame, 255, 0, 0), 64 * 64);
    expect(
      countColor(frame, 0, 0, 255),
      0,
      reason:
          'a red frame must not read as blue — this is the assertion the '
          'old magenta-only tests could not make',
    );
  });

  // 6.6. mbgl::Feature is a GeoJSONFeature PLUS source/sourceLayer/state, and
  // copying into a feature_collection<double> slices all three off — which is
  // what the shim used to do, so gl-js's MapGeoJSONFeature contract was quietly
  // two-thirds unmet.
  test('a queried feature carries source and state, not just geometry', () async {
    const style =
        '{'
        '"version":8,'
        '"sources":{"pts":{"type":"geojson","data":{'
        '"type":"FeatureCollection","features":['
        '{"type":"Feature","id":5,"properties":{"kind":"city"},'
        '"geometry":{"type":"Point","coordinates":[0,0]}}]}}},'
        '"layers":[{"id":"dots","type":"circle","source":"pts",'
        '"paint":{"circle-radius":20,"circle-color":"#ff00ff"}}]'
        '}';
    final map = MapLibreCoreMap.create(
      width: 128,
      height: 128,
      pixelRatio: 1,
      styleUri: style,
    );
    addTearDown(map.dispose);
    map.setCamera(latitude: 0, longitude: 0, zoom: 14);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    await settle(map);

    map.setFeatureState('pts', '5', '{"selected":true}');
    await settle(map);

    final json = map.queryRenderedFeatures(0, 0, 128, 128);
    expect(json, isNotNull);
    final feature =
        ((jsonDecode(json!) as Map<String, Object?>)['features']!
                    as List<Object?>)
                .single
            as Map<String, Object?>;

    expect(feature['source'], 'pts', reason: 'sliced off before this fix');
    expect(
      feature['state'],
      containsPair('selected', true),
      reason:
          'and so was the feature state — which made it impossible to tell '
          'from a query which features were selected',
    );
    // A geojson source has no source layer, so that one is legitimately absent.
    expect(feature.containsKey('sourceLayer'), isFalse);
    // The GeoJSON itself must still be intact after the augmentation.
    expect(feature['type'], 'Feature');
    expect(feature['id'], 5);
    expect((feature['geometry']! as Map<String, Object?>)['type'], 'Point');
  });

  // 6.5. Asserted against REAL supercluster output — the cluster ids are the
  // engine's, discovered by querying, never hardcoded.
  group('cluster helpers', () {
    const style =
        '{'
        '"version":8,'
        '"sources":{"pts":{"type":"geojson","cluster":true,'
        '"clusterRadius":50,"clusterMaxZoom":14,"data":{'
        '"type":"FeatureCollection","features":['
        '{"type":"Feature","properties":{"n":1},'
        '"geometry":{"type":"Point","coordinates":[0.0000,0.0000]}},'
        '{"type":"Feature","properties":{"n":2},'
        '"geometry":{"type":"Point","coordinates":[0.0004,0.0000]}},'
        '{"type":"Feature","properties":{"n":3},'
        '"geometry":{"type":"Point","coordinates":[0.0000,0.0004]}},'
        '{"type":"Feature","properties":{"n":4},'
        '"geometry":{"type":"Point","coordinates":[0.0004,0.0004]}}'
        ']}}},'
        '"layers":['
        '{"id":"bg","type":"background",'
        '"paint":{"background-color":"#ffffff"}},'
        '{"id":"dots","type":"circle","source":"pts",'
        '"paint":{"circle-radius":18,"circle-color":"#ff00ff"}}'
        ']}';

    /// Boots at a zoom low enough that all four points cluster into one.
    Future<MapLibreCoreMap> boot() async {
      final map = MapLibreCoreMap.create(
        width: 256,
        height: 256,
        pixelRatio: 1,
        styleUri: style,
      );
      addTearDown(map.dispose);
      map.setCamera(latitude: 0.0002, longitude: 0.0002, zoom: 10);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      await settle(map);
      return map;
    }

    /// The engine's own cluster id, from a query — never a guess.
    int clusterIdOf(MapLibreCoreMap map) {
      final json = map.queryRenderedFeatures(0, 0, 256, 256);
      expect(json, isNotNull, reason: 'the cluster must be drawn');
      final features =
          (jsonDecode(json!) as Map<String, Object?>)['features']!
              as List<Object?>;
      for (final f in features) {
        final props =
            (f! as Map<String, Object?>)['properties'] as Map<String, Object?>?;
        final id = props?['cluster_id'];
        if (id is num) return id.toInt();
      }
      fail('no clustered feature came back — the fixture is not clustering');
    }

    test('expansion zoom is a real zoom that splits the cluster', () async {
      final map = await boot();
      final id = clusterIdOf(map);

      final zoom = map.getClusterExpansionZoom('pts', id);
      expect(zoom, isNotNull);
      expect(zoom!, greaterThan(10), reason: 'you must zoom IN to split it');
      expect(zoom, lessThanOrEqualTo(24));

      // The claim is testable, so test it rather than trusting the number:
      // at that zoom the single cluster must no longer be one cluster.
      map.setCamera(latitude: 0.0002, longitude: 0.0002, zoom: zoom.toDouble());
      await settle(map);
      final after =
          (jsonDecode(map.queryRenderedFeatures(0, 0, 256, 256)!)
                  as Map<String, Object?>)['features']!
              as List<Object?>;
      final stillOneCluster =
          after.length == 1 &&
          ((after.first! as Map<String, Object?>)['properties']
                      as Map<String, Object?>?)
                  ?.containsKey('cluster_id') ==
              true;
      expect(
        stillOneCluster,
        isFalse,
        reason: 'expansion zoom that does not expand anything is just a number',
      );
    });

    test(
      'children are the next level down, leaves are the originals',
      () async {
        final map = await boot();
        final id = clusterIdOf(map);

        final children = map.getClusterChildren('pts', id);
        expect(children, isNotNull);
        final childList =
            (jsonDecode(children!) as Map<String, Object?>)['features']!
                as List<Object?>;
        expect(childList, isNotEmpty);

        final leaves = map.getClusterLeaves('pts', id, limit: 100);
        expect(leaves, isNotNull);
        final leafList =
            (jsonDecode(leaves!) as Map<String, Object?>)['features']!
                as List<Object?>;
        expect(
          leafList,
          hasLength(4),
          reason: 'leaves are the ORIGINAL points, all four of them',
        );
        // And they are the originals, not clusters: every one carries the "n"
        // property from the source document.
        expect({
          for (final f in leafList)
            ((f! as Map<String, Object?>)['properties']
                as Map<String, Object?>)['n'],
        }, equals({1, 2, 3, 4}));
      },
    );

    test(
      'leaves page, so a huge cluster cannot be asked for at once',
      () async {
        final map = await boot();
        final id = clusterIdOf(map);

        List<Object?> page(int limit, int offset) =>
            (jsonDecode(
                      map.getClusterLeaves(
                        'pts',
                        id,
                        limit: limit,
                        offset: offset,
                      )!,
                    )
                    as Map<String, Object?>)['features']!
                as List<Object?>;

        expect(page(2, 0), hasLength(2));
        expect(page(2, 2), hasLength(2));
        // The two pages must be DIFFERENT points, or the offset is ignored.
        Set<Object?> ns(List<Object?> fs) => {
          for (final f in fs)
            ((f! as Map<String, Object?>)['properties']
                as Map<String, Object?>)['n'],
        };
        expect(ns(page(2, 0)).intersection(ns(page(2, 2))), isEmpty);
      },
    );

    test('a made-up cluster id is NOT detectable through expansion zoom', () async {
      final map = await boot();
      // supercluster starts from `(cluster_id % 32) - 1` and only then walks
      // the tree (supercluster.hpp:236), so a fabricated id yields a plausible
      // number rather than an error. Pinned because it looks like a bug in us,
      // and because the documented workaround below has to keep working.
      expect(
        map.getClusterExpansionZoom('pts', 999999),
        30,
        reason:
            '999999 % 32 == 31, so the answer is 30 — derived from the id, '
            'not from any cluster',
      );

      // Children IS a real lookup, so that is the existence check we document —
      // and supercluster THROWS std::runtime_error("No cluster with the
      // specified id.") for a made-up one (supercluster.hpp:375). A throw
      // crossing `extern "C"` is undefined behaviour, and this exact call
      // aborted the whole test process before the shim caught it. Null, and a
      // report, is the contract.
      final failures = <String>[];
      map.setDiagnosticCallback((d) {
        if (d.kind == CoreDiagnosticKind.commandFailed) failures.add(d.message);
      });
      addTearDown(() => map.setDiagnosticCallback(null));

      expect(map.getClusterChildren('pts', 999999), isNull);
      await settle(map);
      expect(failures.join('\n'), contains('No cluster'));
    });

    test('an unknown SOURCE answers null without throwing', () async {
      final map = await boot();
      // Unlike a bad cluster id, mbgl handles this itself: RenderOrchestrator
      // returns an empty value for a source it cannot find
      // (render_orchestrator.cpp:719-722). So there is nothing to report.
      expect(map.getClusterChildren('no-such-source', 1), isNull);
      expect(map.getClusterExpansionZoom('no-such-source', 1), isNull);
    });
  });

  // 6.4. Feature state is only worth anything if a style EXPRESSION can read
  // it, so these assert pixels, not the round trip through getFeatureState —
  // a get/set pair that agrees with itself proves storage, not rendering.
  group('feature state', () {
    // Blue by default, red when feature-state "selected" is true. Two features:
    // one gets state, the other must not, so a change that applies to
    // everything cannot pass.
    const style =
        '{'
        '"version":8,'
        '"sources":{"pts":{"type":"geojson","data":{'
        '"type":"FeatureCollection","features":['
        '{"type":"Feature","id":1,"properties":{},'
        '"geometry":{"type":"Point","coordinates":[-0.01,0]}},'
        '{"type":"Feature","id":2,"properties":{},'
        '"geometry":{"type":"Point","coordinates":[0.01,0]}}'
        ']}}},'
        '"layers":['
        '{"id":"bg","type":"background",'
        '"paint":{"background-color":"#ffffff"}},'
        '{"id":"dots","type":"circle","source":"pts",'
        '"paint":{"circle-radius":20,"circle-color":'
        '["case",["boolean",["feature-state","selected"],false],'
        '"#ff0000","#0000ff"]}}'
        ']}';

    Future<MapLibreCoreMap> boot() async {
      final map = MapLibreCoreMap.create(
        width: 256,
        height: 256,
        pixelRatio: 1,
        styleUri: style,
        continuous: true,
      );
      addTearDown(map.dispose);
      map.setCamera(latitude: 0, longitude: 0, zoom: 13);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      await settle(map);
      return map;
    }

    test('state reaches a paint expression, for that feature only', () async {
      final map = await boot();
      final before = map.copyFrame()!;
      expect(
        countColor(before, 0, 0, 255),
        greaterThan(100),
        reason: 'precondition: both circles start blue',
      );
      expect(countColor(before, 255, 0, 0), 0);

      map.setFeatureState('pts', '1', '{"selected":true}');
      await settle(map);

      final after = map.copyFrame()!;
      final red = countColor(after, 255, 0, 0);
      final blue = countColor(after, 0, 0, 255);
      expect(red, greaterThan(100), reason: 'feature 1 must repaint red');
      expect(
        blue,
        greaterThan(100),
        reason:
            'feature 2 must stay blue — a change that hits everything is '
            'indistinguishable from feature state working',
      );
      expect(
        (red - blue).abs(),
        lessThan(red ~/ 2),
        reason:
            'the two circles are the same size, so the counts should be '
            'comparable — a wild difference means one was not drawn',
      );
    });

    test('a set MERGES rather than replacing', () async {
      final map = await boot();
      map.setFeatureState('pts', '1', '{"selected":true}');
      await settle(map);
      map.setFeatureState('pts', '1', '{"hovered":true}');
      await settle(map);

      final state = map.getFeatureState('pts', '1');
      expect(state, isNotNull);
      final decoded = jsonDecode(state!) as Map<String, Object?>;
      expect(
        decoded,
        containsPair('selected', true),
        reason: 'gl-js merges; replacing would silently drop the first key',
      );
      expect(decoded, containsPair('hovered', true));
      // And the render still agrees.
      expect(countColor(map.copyFrame()!, 255, 0, 0), greaterThan(100));
    });

    test('removing one KEY leaves the rest, removing all clears', () async {
      final map = await boot();
      map.setFeatureState('pts', '1', '{"selected":true,"hovered":true}');
      await settle(map);

      map.removeFeatureState('pts', featureId: '1', stateKey: 'selected');
      await settle(map);
      final partial =
          jsonDecode(map.getFeatureState('pts', '1')!) as Map<String, Object?>;
      expect(partial, isNot(contains('selected')));
      expect(partial, containsPair('hovered', true));
      expect(
        countColor(map.copyFrame()!, 255, 0, 0),
        0,
        reason: 'and the paint went back to blue',
      );

      map.removeFeatureState('pts', featureId: '1');
      await settle(map);
      expect(
        jsonDecode(map.getFeatureState('pts', '1')!) as Map<String, Object?>,
        isEmpty,
      );
    });

    test('a feature with no state reports {} — not a failure', () async {
      final map = await boot();
      // "nothing set" and "could not ask" have to be different answers, or a
      // caller cannot tell a timeout from an unstyled feature.
      expect(map.getFeatureState('pts', '2'), '{}');
    });

    test('state for an id NO FEATURE HAS is silently inert', () async {
      final map = await boot();
      // Documented mbgl limitation: no promoteId, no generateId. Worth pinning
      // because the failure mode is "my styling does not change" with no error
      // anywhere, and someone will eventually assume we broke it.
      map.setFeatureState('pts', '999', '{"selected":true}');
      await settle(map);
      expect(countColor(map.copyFrame()!, 255, 0, 0), 0);
      expect(
        map.getFeatureState('pts', '999'),
        '{"selected":true}',
        reason: 'mbgl stores it against that id; nothing ever reads it',
      );
    });
  });

  // 5.11. A model layer used to take the app's id verbatim, putting it in the
  // same namespace as every layer the app adds. Three bugs came out of that
  // overlap; each assertion below is one of them.
  group('model layers live in their own id namespace', () {
    Future<MapLibreCoreMap> boot() async {
      const inline =
          '{'
          '"version":8,"sources":{},'
          '"layers":[{"id":"car","type":"background",'
          '"paint":{"background-color":"#123456"}}]'
          '}';
      final map = MapLibreCoreMap.create(
        width: 64,
        height: 64,
        pixelRatio: 1,
        styleUri: inline,
      );
      addTearDown(map.dispose);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      await settle(map);
      return map;
    }

    test(
      'a model does not collide with a style layer of the same name',
      () async {
        final map = await boot();
        // Deliberately the same name as the background layer in the document.
        map.addTestModel(latitude: 60.45, longitude: 22.27, layerId: 'car');
        await settle(map);

        expect(
          map.getLayerIds(),
          containsAll(<String>['car', 'mbl:model:car']),
          reason: 'the app\'s layer and the model must both exist, separately',
        );

        // Bug 3: this used to remove the app's "car" background layer.
        map.removeModel('car');
        await settle(map);
        expect(
          map.getLayerIds(),
          contains('car'),
          reason: 'removeModel must not touch a style layer of the same name',
        );
        expect(map.getLayerIds(), isNot(contains('mbl:model:car')));
      },
    );

    test('a removed model does not come back on the next style load', () async {
      final map = await boot();
      map.addTestModel(latitude: 60.45, longitude: 22.27, layerId: 'ghost');
      await settle(map);
      expect(map.getLayerIds(), contains('mbl:model:ghost'));

      // Bug 1 + 2: removeLayer dropped the style layer but left the retention,
      // so the style-load replay put it back — and the Dart side kept ticking
      // triggerRepaint for a model the app had removed.
      map.removeLayer('mbl:model:ghost');
      await settle(map);
      map.setStyle('{"version":8,"sources":{},"layers":[]}');
      await settle(map);

      expect(
        map.getLayerIds(),
        isNot(contains('mbl:model:ghost')),
        reason: 'a model removed through removeLayer must stay removed',
      );
    });

    test('a model that was NOT removed still survives a style load', () async {
      final map = await boot();
      map.addTestModel(latitude: 60.45, longitude: 22.27, layerId: 'keeper');
      await settle(map);

      map.setStyle('{"version":8,"sources":{},"layers":[]}');
      await settle(map);
      expect(
        map.getLayerIds(),
        contains('mbl:model:keeper'),
        reason:
            'the retention still has to work — this is the control for the '
            'test above, which would otherwise pass if replay were broken',
      );
    });
  });

  // 6.1-6.3. One style with three labelled points, so a filter has something
  // asymmetric to select and the counts are checkable.
  group('queries', () {
    const style =
        '{'
        '"version":8,'
        '"sources":{"pts":{"type":"geojson","data":{'
        '"type":"FeatureCollection","features":['
        '{"type":"Feature","id":1,"properties":{"kind":"city"},'
        '"geometry":{"type":"Point","coordinates":[0,0]}},'
        '{"type":"Feature","id":2,"properties":{"kind":"town"},'
        '"geometry":{"type":"Point","coordinates":[0.0005,0]}},'
        '{"type":"Feature","id":3,"properties":{"kind":"city"},'
        '"geometry":{"type":"Point","coordinates":[0,0.0005]}}'
        ']}}},'
        '"layers":[{"id":"dots","type":"circle","source":"pts",'
        '"paint":{"circle-radius":20,"circle-color":"#ff0000"}}]'
        '}';

    Future<MapLibreCoreMap> boot() async {
      final map = MapLibreCoreMap.create(
        width: 256,
        height: 256,
        pixelRatio: 1,
        styleUri: style,
      );
      addTearDown(map.dispose);
      map.setCamera(latitude: 0.00025, longitude: 0.00025, zoom: 17);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      await settle(map);
      return map;
    }

    int countFeatures(String? json) {
      if (json == null) return -1;
      final decoded = jsonDecode(json) as Map<String, Object?>;
      return (decoded['features']! as List<Object?>).length;
    }

    test('a filter runs INSIDE the engine, not after the fact', () async {
      final map = await boot();
      final all = map.queryRenderedFeatures(0, 0, 256, 256);
      expect(countFeatures(all), 3, reason: 'precondition: all three drawn');

      final cities = map.queryRenderedFeatures(
        0,
        0,
        256,
        256,
        filterJson: '["==", ["get", "kind"], "city"]',
      );
      expect(countFeatures(cities), 2);
    });

    test(
      'a filter that does not parse is reported, not silently ignored',
      () async {
        final map = await boot();
        final events = <String>[];
        map.setDiagnosticCallback((d) {
          if (d.kind == CoreDiagnosticKind.commandFailed) events.add(d.message);
        });
        addTearDown(() => map.setDiagnosticCallback(null));

        // Matching everything is the one outcome a caller cannot detect, so a
        // broken filter has to say so.
        map.queryRenderedFeatures(
          0,
          0,
          256,
          256,
          filterJson: '["this-is-not-an-operator"]',
        );
        await settle(map);
        expect(events.join('\n'), contains('filter'));
      },
    );

    test('the async form returns the same answer without blocking', () async {
      final map = await boot();
      final sync = map.queryRenderedFeatures(0, 0, 256, 256);
      final async = await map
          .queryRenderedFeaturesAsync(0, 0, 256, 256)
          .timeout(const Duration(seconds: 10));
      expect(countFeatures(async), countFeatures(sync));
      expect(countFeatures(async), 3);
    });

    test('the async form completes even on a dead handle', () async {
      final map = MapLibreCoreMap.create(
        width: 64,
        height: 64,
        pixelRatio: 1,
        styleUri: style,
      );
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      final pending = map.queryRenderedFeaturesAsync(0, 0, 64, 64);
      // A Future that never completes is worse than one that completes empty:
      // the caller has no way to notice.
      expect(await pending.timeout(const Duration(seconds: 10)), isNotNull);
      map.dispose();
    });

    test('querySourceFeatures sees data the RENDERED query cannot', () async {
      final map = await boot();
      // A LAYER FILTER, not visibility: hiding the layer would remove the only
      // reason mbgl has to hold tiles for the source, so the source query would
      // correctly find nothing and the test would prove the opposite of what it
      // claims. With the layer visible but filtered, the tiles stay loaded and
      // the two queries genuinely disagree — which is the whole distinction.
      map.setLayerProperty('dots', 'filter', '["==", ["get", "kind"], "town"]');
      await settle(map);

      expect(
        countFeatures(map.queryRenderedFeatures(0, 0, 256, 256)),
        1,
        reason: 'the rendered query reports what was DRAWN',
      );
      // NOT deduplicated, and deliberately not asserted as 3: mbgl answers this
      // per LOADED TILE, so a point in the overlap of several cached tiles comes
      // back once per tile. gl-js documents the same. A caller that wants unique
      // features has to dedupe by id itself.
      final all = map.querySourceFeatures('pts');
      expect(
        countFeatures(all),
        greaterThanOrEqualTo(3),
        reason: 'the source query ignores styling: all three are still loaded',
      );
      final ids =
          (jsonDecode(all!) as Map<String, Object?>)['features']!
              as List<Object?>;
      expect(
        {for (final f in ids) (f! as Map<String, Object?>)['id']},
        equals({1, 2, 3}),
        reason: 'every feature is reachable, however many times each appears',
      );

      final towns = map.querySourceFeatures(
        'pts',
        filterJson: '["==", ["get", "kind"], "town"]',
      );
      expect(countFeatures(towns), lessThan(countFeatures(all)));
      expect(
        {
          for (final f
              in (jsonDecode(towns!) as Map<String, Object?>)['features']!
                  as List<Object?>)
            (f! as Map<String, Object?>)['id'],
        },
        equals({2}),
        reason: 'the filter applies to the source query too',
      );
    });
  });

  test('getSourceIds omits mbgl\'s annotation source too', () async {
    const inline =
        '{'
        '"version":8,'
        '"sources":{"a":{"type":"geojson","data":{"type":"FeatureCollection",'
        '"features":[]}}},'
        '"layers":[]'
        '}';
    final map = MapLibreCoreMap.create(
      width: 64,
      height: 64,
      pixelRatio: 1,
      styleUri: inline,
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    await settle(map);
    expect(map.getSourceIds(), equals(<String>['a']));
  });

  test(
    'getLayerIds reports the DOCUMENT, not mbgl\'s annotation plumbing',
    () async {
      // mbgl::AnnotationManager::updateStyle() runs on every style load and adds
      // "org.maplibre.annotations.points" whether or not anything uses it. That
      // layer is in no style document, has no gl-js counterpart, and cannot be
      // driven through anything this ABI exposes — so enumerating it makes
      // getLayersOrder report a layer the app can neither have added nor act on.
      //
      // Found by an integration test that loaded a two-line inline style and got
      // back two layers.
      const inline =
          '{'
          '"version":8,'
          '"sources":{},'
          '"layers":[{"id":"bg","type":"background",'
          '"paint":{"background-color":"#ff00ff"}}]'
          '}';
      final map = MapLibreCoreMap.create(
        width: 64,
        height: 64,
        pixelRatio: 1,
        styleUri: inline,
      );
      addTearDown(map.dispose);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      await settle(map);

      expect(
        map.getLayerIds(),
        equals(<String>['bg']),
        reason: 'exactly the document\'s layers, in the document\'s order',
      );
      // Not HIDDEN — still reachable by id, so nothing is unreachable, it is just
      // not enumerated.
      expect(
        map.getLayerJson('org.maplibre.annotations.points'),
        isNotNull,
        reason: 'the layer is still there; the filter is on the listing only',
      );
    },
  );

  test(
    'setStyle also takes a document, and leading space does not fool it',
    () async {
      final map = MapLibreCoreMap.create(
        width: 128,
        height: 128,
        pixelRatio: 1,
        styleUri: 'https://demotiles.maplibre.org/style.json',
      );
      addTearDown(map.dispose);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

      // Whitespace-led, because the sniff has to skip it rather than give up and
      // treat a perfectly good document as a URL.
      map.setStyle(
        '\n  {"version":8,"name":"inline","sources":{},'
        '"layers":[{"id":"bg","type":"background",'
        '"paint":{"background-color":"#00ff00"}}]}',
      );
      final sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 15)) {
        await settle(map);
        if (countColor(map.copyFrame()!, 0, 255, 0) > 128 * 128 ~/ 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        countColor(map.copyFrame()!, 0, 255, 0),
        greaterThan(128 * 128 ~/ 2),
      );
    },
  );

  // --- Sources and images ----------------------------------------------------

  test(
    'getSource reports what mbgl exposes; images list and hasImage',
    () async {
      final map = MapLibreCoreMap.create(
        width: 256,
        height: 256,
        pixelRatio: 1,
        styleUri: 'https://demotiles.maplibre.org/style.json',
      );
      addTearDown(map.dispose);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

      map.addSourceJson(
        'p',
        '{"type":"geojson","data":${pointsAround(0, 0, 3, 0.1)}}',
      );
      await settle(map);

      final json = map.getSourceJson('p');
      expect(json, isNotNull);
      expect(json, contains('"type":"geojson"'));
      expect(map.getSourceJson('no-such-source'), isNull);
      expect(map.getSourceIds(), contains('p'));

      // The demo style brings its OWN sources, so this is not just ours.
      expect(map.getSourceIds()!.length, greaterThan(1));

      // Images: absent, then registered, then listed.
      expect(map.hasImage('probe'), isFalse);
      map.addImage(
        'probe',
        Uint8List.fromList(List<int>.filled(4 * 4 * 4, 255)),
        4,
        4,
      );
      await settle(map);
      expect(map.hasImage('probe'), isTrue);
      expect(map.getImageIds(), contains('probe'));

      map.removeImage('probe');
      await settle(map);
      expect(map.hasImage('probe'), isFalse);
    },
  );

  // --- Layer properties ------------------------------------------------------

  test('ONE entry point sets paint, layout, filter and zoom range', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    map.setCamera(latitude: 60.45, longitude: 22.27, zoom: 5);
    await settle(map);

    map.addSourceJson(
      'p',
      '{"type":"geojson","data":${pointsAround(60.45, 22.27, 40, 0.4)}}',
    );
    map.addLayerJson(
      '{"id":"dots","type":"circle","source":"p",'
      '"paint":{"circle-radius":6,"circle-color":"#ff00ff"}}',
    );
    await settle(map);
    expect(countColor(map.copyFrame()!, 255, 0, 255), greaterThan(20));

    // PAINT — the generated setter path.
    expect(map.setLayerProperty('dots', 'circle-color', '"#00ff00"'), isTrue);
    await settle(map);
    expect(countColor(map.copyFrame()!, 0, 255, 0), greaterThan(20));
    expect(countColor(map.copyFrame()!, 255, 0, 255), 0);

    // LAYOUT / visibility — Layer::setProperty's OWN fallback, not a paint
    // property, reached through the same call.
    expect(map.setLayerProperty('dots', 'visibility', '"none"'), isTrue);
    await settle(map);
    expect(
      countColor(map.copyFrame()!, 0, 255, 0),
      0,
      reason: 'a hidden layer draws nothing',
    );
    expect(map.setLayerProperty('dots', 'visibility', '"visible"'), isTrue);
    await settle(map);
    expect(countColor(map.copyFrame()!, 0, 255, 0), greaterThan(20));

    // ZOOM RANGE — the same entry point again.
    expect(map.setLayerProperty('dots', 'minzoom', '10'), isTrue);
    await settle(map);
    expect(
      countColor(map.copyFrame()!, 0, 255, 0),
      0,
      reason: 'at zoom 5, a minzoom-10 layer is out of range',
    );
    expect(map.setLayerProperty('dots', 'minzoom', '0'), isTrue);
    await settle(map);
    expect(countColor(map.copyFrame()!, 0, 255, 0), greaterThan(20));

    // FILTER — the fourth thing gl-js gives a separate method and mbgl does not.
    expect(
      map.setLayerProperty('dots', 'filter', '["==",["get","nope"],1]'),
      isTrue,
    );
    await settle(map);
    expect(
      countColor(map.copyFrame()!, 0, 255, 0),
      0,
      reason: 'a filter that matches nothing hides everything',
    );
  });

  test('bad JSON fails now; a bad property name reports later', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    final failures = <CoreDiagnostic>[];
    map.setDiagnosticCallback((d) {
      if (d.kind == CoreDiagnosticKind.commandFailed) failures.add(d);
    });
    map.addSourceJson(
      'p',
      '{"type":"geojson","data":${pointsAround(0, 0, 3, 0.1)}}',
    );
    map.addLayerJson(
      '{"id":"dots","type":"circle","source":"p","paint":{"circle-radius":3}}',
    );
    await settle(map);

    // Malformed JSON is knowable without the render thread, so it fails here.
    expect(map.setLayerProperty('dots', 'circle-radius', '{not json'), isFalse);
    // These need the layer, so they can only be reported asynchronously.
    expect(map.setLayerProperty('dots', 'no-such-property', '1'), isTrue);
    expect(map.setLayerProperty('no-such-layer', 'circle-radius', '1'), isTrue);

    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 10) && failures.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final messages = failures.map((d) => d.message).toList();
    expect(messages.any((m) => m.contains('no-such-property')), isTrue);
    expect(
      messages.any((m) => m.contains("no layer with id 'no-such-layer'")),
      isTrue,
    );
  });

  test('moveLayer reorders, and getLayer reads the LIVE layer', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    map.setCamera(latitude: 0, longitude: 0, zoom: 3);

    map.addSourceJson(
      'p',
      '{"type":"geojson","data":${pointsAround(0, 0, 30, 0.6)}}',
    );
    // Two layers over the same points: the one added LAST wins the overlap.
    map.addLayerJson(
      '{"id":"under","type":"circle","source":"p",'
      '"paint":{"circle-radius":12,"circle-color":"#ff00ff"}}',
    );
    map.addLayerJson(
      '{"id":"over","type":"circle","source":"p",'
      '"paint":{"circle-radius":12,"circle-color":"#00ff00"}}',
    );
    await settle(map);
    expect(countColor(map.copyFrame()!, 0, 255, 0), greaterThan(30));

    final order = map.getLayerIds();
    expect(order, isNotNull);
    expect(order!.indexOf('over'), greaterThan(order.indexOf('under')));

    // Put 'over' BENEATH 'under': magenta should now win the overlap.
    map.moveLayer('over', beforeId: 'under');
    await settle(map);
    expect(
      countColor(map.copyFrame()!, 255, 0, 255),
      greaterThan(30),
      reason: 'the draw order actually changed',
    );
    final reordered = map.getLayerIds()!;
    expect(reordered.indexOf('over'), lessThan(reordered.indexOf('under')));

    // getLayer must reflect the LIVE layer, not the document as loaded —
    // Style::getJSON() would still say magenta here.
    map.setLayerProperty('under', 'circle-color', '"#0000ff"');
    await settle(map);

    // NOTE the read side hands back mbgl's NORMALISED form, not the text that
    // went in: a colour comes out as ["rgba",r,g,b,a] with doubles, whatever
    // notation set it. Anything round-tripping getLayerProperty into
    // setLayerProperty has to expect that, so it is pinned here rather than
    // discovered later.
    expect(
      map.getLayerJson('under'),
      contains('"rgba",0.0,0.0,255.0,1.0'),
      reason: '#0000ff normalises to rgba blue',
    );
    expect(map.getLayerProperty('under', 'circle-color'), contains('rgba'));
    expect(map.getLayerProperty('under', 'circle-radius'), '12.0');
    expect(map.getLayerJson('no-such-layer'), isNull);
    expect(map.getLayerProperty('under', 'no-such-property'), isNull);
  });

  // --- Camera commands -------------------------------------------------------

  test('jumpTo applies a PARTIAL camera, leaving the rest alone', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    map.setCamera(latitude: 60.45, longitude: 22.27, zoom: 4, bearing: 30);
    await settle(map);

    // Zoom only. Everything else must survive — that is the whole point of a
    // partial camera, and what a read-modify-write cannot promise because the
    // render thread can move the camera in between.
    map.jumpTo(const CoreCameraOptions(zoom: 9));
    await settle(map);
    final after = map.getCamera();
    expect(after.zoom, closeTo(9, 1e-6));
    expect(after.latitude, closeTo(60.45, 1e-6), reason: 'centre untouched');
    expect(after.longitude, closeTo(22.27, 1e-6));
    expect(after.bearing, closeTo(30, 1e-6), reason: 'bearing untouched');
  });

  // The trap this pins: Transform::startTransition reads
  //   anchor = camera.center ? std::nullopt : camera.anchor
  // so an anchored move that also carries a centre silently becomes a centred
  // one. A test anchored on the map CENTRE cannot detect that, because the
  // centre is a fixed point either way — so this anchors on a corner.
  test('an anchored zoom holds the anchor, not the centre', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    map.setCamera(latitude: 0, longitude: 0, zoom: 4);
    await settle(map);

    // What is under the top-left corner before the zoom?
    const anchor = (x: 0.0, y: 0.0);
    final before = map.unproject(anchor.x, anchor.y)!;

    map.jumpTo(const CoreCameraOptions(zoom: 6, anchor: anchor));
    await settle(map);

    final after = map.unproject(anchor.x, anchor.y)!;
    expect(map.getCamera().zoom, closeTo(6, 1e-6));
    expect(
      after.latitude,
      closeTo(before.latitude, 1e-4),
      reason: 'the anchored point must not move under the zoom',
    );
    expect(after.longitude, closeTo(before.longitude, 1e-4));
    // And the CENTRE must have moved, which is what proves the anchor was
    // honoured rather than silently dropped.
    expect(
      map.getCamera().longitude.abs() + map.getCamera().latitude.abs(),
      greaterThan(1e-3),
      reason: 'zooming about a corner has to shift the centre',
    );
  });

  // CONTINUOUS mode deliberately: mbgl advances transitions from the render
  // loop, so in Static mode — which every other test here uses — easeTo and
  // flyTo create a transition that nothing ever steps. The camera simply never
  // moves. That is a property of the engine, not of this binding, and it is
  // recorded on mbl_map_ease_to in the header.
  test(
    'easeTo animates and reports completion; superseding completes it too',
    () async {
      final map = MapLibreCoreMap.create(
        width: 256,
        height: 256,
        pixelRatio: 1,
        styleUri: 'https://demotiles.maplibre.org/style.json',
        continuous: true,
      );
      addTearDown(map.dispose);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      map.setCamera(latitude: 0, longitude: 0, zoom: 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final finished = <int>[];
      map.setCameraFinishCallback(finished.add);

      map.easeTo(
        const CoreCameraOptions(zoom: 6),
        const CoreAnimationOptions(duration: Duration(milliseconds: 400)),
        token: 11,
      );
      var sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 10) && finished.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(finished, [11], reason: 'a completed ease reports its token');
      // The camera cache has to track an animation mbgl drives itself, or
      // getCamera() reports the pre-animation camera forever after.
      expect(map.getCamera().zoom, closeTo(6, 0.05));

      // Supersede a long flight with a jump. Transform::startTransition invokes
      // the PREVIOUS transitionFinishFn before installing the new one, so the
      // interrupted move completes rather than hanging — which is what lets a
      // Dart Future built on this be safe to await.
      finished.clear();
      map.flyTo(
        const CoreCameraOptions(
          zoom: 14,
          center: (latitude: 60.45, longitude: 22.27),
        ),
        const CoreAnimationOptions(duration: Duration(seconds: 8)),
        token: 22,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      map.jumpTo(const CoreCameraOptions(zoom: 3));
      sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 10) && finished.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(finished, [
        22,
      ], reason: 'a superseded animation completes, it does not hang');
      expect(
        map.getCamera().zoom,
        closeTo(3, 0.05),
        reason: 'the jump won; the flight stopped where it was interrupted',
      );
    },
  );

  test(
    'fitBounds frames the box, and cameraForBounds agrees without moving',
    () async {
      final map = MapLibreCoreMap.create(
        width: 512,
        height: 512,
        pixelRatio: 1,
        styleUri: 'https://demotiles.maplibre.org/style.json',
      );
      addTearDown(map.dispose);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      map.setCamera(latitude: 0, longitude: 0, zoom: 1);
      await settle(map);

      // Asymmetric on both axes so a swapped corner cannot pass by symmetry.
      const bounds = (swLat: 59.33, swLng: 18.06, neLat: 60.45, neLng: 22.27);

      // Compute-only first: it must NOT move the camera.
      final computed = map.cameraForBounds(bounds);
      expect(computed, isNotNull);
      expect(map.getCamera().zoom, closeTo(1, 1e-6), reason: 'no move');
      expect(computed!.zoom!, greaterThan(5), reason: 'a small box zooms in');
      expect(computed.center!.latitude, closeTo(59.89, 0.2));
      expect(computed.center!.longitude, closeTo(20.165, 0.2));

      // Then fit for real, and check the box is actually on screen.
      map.fitBounds(bounds);
      await settle(map);
      final applied = map.getCamera();
      expect(applied.zoom, closeTo(computed.zoom!, 0.01));
      expect(applied.latitude, closeTo(computed.center!.latitude, 1e-3));

      final sw = map.project(bounds.swLat, bounds.swLng)!;
      final ne = map.project(bounds.neLat, bounds.neLng)!;
      // North is UP and east is RIGHT in top-left screen space — absolute
      // directions, not a round-trip (CLAUDE.md §7).
      expect(ne.y, lessThan(sw.y), reason: 'the north edge is higher up');
      expect(ne.x, greaterThan(sw.x), reason: 'the east edge is further right');
      for (final p in [sw, ne]) {
        expect(p.x, inInclusiveRange(-1.0, 513.0));
        expect(p.y, inInclusiveRange(-1.0, 513.0));
      }
    },
  );

  test('getBounds reports the visible region, oriented correctly', () async {
    final map = MapLibreCoreMap.create(
      width: 512,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    map.setCamera(latitude: 60.45, longitude: 22.27, zoom: 6);
    await settle(map);

    final bounds = map.getVisibleBounds();
    expect(bounds, isNotNull);
    expect(bounds!.neLat, greaterThan(bounds.swLat), reason: 'north > south');
    expect(bounds.neLng, greaterThan(bounds.swLng), reason: 'east > west');
    // The camera centre must lie inside what the camera can see.
    expect(bounds.swLat, lessThan(60.45));
    expect(bounds.neLat, greaterThan(60.45));
    expect(bounds.swLng, lessThan(22.27));
    expect(bounds.neLng, greaterThan(22.27));
    // A 2:1 viewport sees more longitude than latitude.
    expect(
      bounds.neLng - bounds.swLng,
      greaterThan(bounds.neLat - bounds.swLat),
      reason: 'a wide viewport spans more longitude',
    );
  });

  test('setBounds constrains the zoom range', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    map.setBounds(const CoreBoundOptions(minZoom: 4, maxZoom: 8));
    await settle(map);

    map.jumpTo(const CoreCameraOptions(zoom: 12));
    await settle(map);
    expect(
      map.getCamera().zoom,
      closeTo(8, 1e-6),
      reason: 'clamped to maxZoom',
    );

    map.jumpTo(const CoreCameraOptions(zoom: 1));
    await settle(map);
    expect(
      map.getCamera().zoom,
      closeTo(4, 1e-6),
      reason: 'clamped to minZoom',
    );

    final read = map.getBoundOptions();
    expect(read, isNotNull);
    expect(read!.minZoom, closeTo(4, 1e-6));
    expect(read.maxZoom, closeTo(8, 1e-6));
  });

  // --- Diagnostics -----------------------------------------------------------
  // Everything here used to be a blank map and total silence: mbgl reports
  // asynchronous failures through MapObserver and its own log, and neither had
  // a route out of the shim.

  test('diagnosticKindMatchesTheHeader', () {
    // ffigen is configured with `enums: Enums.excludeAll`, so these codes are
    // hand-mirrored from MblDiagnosticKind/MblDiagnosticSeverity in
    // src/maplibre_flutter_core.h and nothing generated pins them. This does.
    expect(CoreDiagnosticKind.styleLoaded.code, 0);
    expect(CoreDiagnosticKind.mapLoaded.code, 1);
    expect(CoreDiagnosticKind.mapLoadFailed.code, 2);
    expect(CoreDiagnosticKind.idle.code, 3);
    expect(CoreDiagnosticKind.styleImageMissing.code, 4);
    expect(CoreDiagnosticKind.glyphsError.code, 5);
    expect(CoreDiagnosticKind.spriteError.code, 6);
    expect(CoreDiagnosticKind.renderError.code, 7);
    expect(CoreDiagnosticKind.log.code, 8);
    expect(CoreDiagnosticKind.commandFailed.code, 9);

    expect(CoreDiagnosticSeverity.debug.code, 0);
    expect(CoreDiagnosticSeverity.info.code, 1);
    expect(CoreDiagnosticSeverity.warning.code, 2);
    expect(CoreDiagnosticSeverity.error.code, 3);

    // An unknown code from a newer core must degrade, never throw.
    expect(CoreDiagnosticKind.fromCode(9999), CoreDiagnosticKind.log);
    expect(CoreDiagnosticSeverity.fromCode(9999), CoreDiagnosticSeverity.error);
  });

  // NOTE what is NOT asserted here: idle, and mapLoaded.
  //
  // Neither fires in this configuration — measured, not assumed: a healthy
  // demotiles map observed for 45 s reports styleLoaded once and nothing else,
  // ever. Both are gated on `rendererFullyLoaded` in mbgl's Map::Impl, which is
  // set from `renderMode == RenderMode::Full`, which the renderer only reports
  // when `renderTreeParameters.loaded` is true (renderer_impl.cpp). Something
  // in our continuous setup keeps the render tree from ever reporting loaded.
  // Until that is understood, `onIdle` cannot be built on this event — see the
  // stage-2 run-log entry in docs/api-parity-progress.md.
  test('reports style-loaded from a healthy map', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    final seen = <CoreDiagnostic>[];
    map.setDiagnosticCallback(seen.add);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    // The callback is a NativeCallable.listener, so events arrive on this
    // isolate's event loop — yield until they do.
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 20)) {
      if (seen.any((d) => d.kind == CoreDiagnosticKind.styleLoaded)) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(
      seen.map((d) => d.kind),
      contains(CoreDiagnosticKind.styleLoaded),
      reason: 'fires on every style load — the signal for re-applying layers',
    );

    // And it fires AGAIN on the next load, which is the property the whole
    // event exists for: mbgl drops every app-added layer on a style swap, so a
    // one-shot signal would be useless.
    seen.clear();
    map.setStyle('https://demotiles.maplibre.org/style.json');
    sw.reset();
    while (sw.elapsed < const Duration(seconds: 20)) {
      if (seen.any((d) => d.kind == CoreDiagnosticKind.styleLoaded)) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      seen.map((d) => d.kind),
      contains(CoreDiagnosticKind.styleLoaded),
      reason: 'repeating, not one-shot',
    );
  });

  // Registration cannot precede creation — the caller needs the handle first —
  // and the style often loads within ~200 ms of it. A strictly live stream
  // therefore drops the initial load routinely, which is exactly what broke the
  // example app: onReady waits for that event, and the controller registers
  // after the texture handshake, so the map never became ready.
  test('a style already loaded is replayed to a late listener', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    // Deliberately register LATE: wait for a frame first, by which time the
    // style has certainly loaded and the live event has been and gone.
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));

    final seen = <CoreDiagnostic>[];
    map.setDiagnosticCallback(seen.add);

    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 10)) {
      if (seen.any((d) => d.kind == CoreDiagnosticKind.styleLoaded)) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      seen.map((d) => d.kind),
      contains(CoreDiagnosticKind.styleLoaded),
      reason: 'the load that already happened must still be reported',
    );
    expect(
      seen.where((d) => d.kind == CoreDiagnosticKind.styleLoaded),
      hasLength(1),
      reason: 'replayed once, not once per past load',
    );
  });

  // CONTINUOUS mode, deliberately — and this is the whole point of the test.
  // Continuous uses FrameObserver, Static uses DiagnosticObserver directly, and
  // the replay bookkeeping lived only in the latter. Every SHIPPED tier is
  // continuous, so a Static-only replay test passed while the real app waited
  // for a style-loaded event that never came.
  test('a late listener gets the replay in CONTINUOUS mode too', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
      continuous: true,
    );
    addTearDown(map.dispose);
    // Register LATE, as a real tier must: it can only do so after create
    // returns, and on the texture tiers after a registrar round trip.
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));

    final seen = <CoreDiagnostic>[];
    map.setDiagnosticCallback(seen.add);

    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 10)) {
      if (seen.any((d) => d.kind == CoreDiagnosticKind.styleLoaded)) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      seen.map((d) => d.kind),
      contains(CoreDiagnosticKind.styleLoaded),
      reason:
          'without this the app renders a map and waits for readiness forever',
    );
  });

  test('a style URL that 404s is reported instead of silently blank', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/no-such-style-at-all.json',
    );
    addTearDown(map.dispose);

    final seen = <CoreDiagnostic>[];
    map.setDiagnosticCallback(seen.add);

    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 25)) {
      if (seen.any((d) => d.kind == CoreDiagnosticKind.mapLoadFailed)) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final failure = seen.where(
      (d) => d.kind == CoreDiagnosticKind.mapLoadFailed,
    );
    expect(
      failure,
      isNotEmpty,
      reason: 'this is the whole point: a 404 style used to reach nobody',
    );
    expect(failure.first.severity, CoreDiagnosticSeverity.error);
    expect(failure.first.message, isNotEmpty);
  });

  // The motivating case for hooking mbgl::Log at all: a font the tile server
  // does not serve does not reach MapObserver::onGlyphsError — mbgl logs it and
  // moves on, and the whole source then stops rendering (see the symbol-layer
  // test above). Without the log observer this is invisible from Dart.
  test('a glyph 404 surfaces through the log observer', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);

    final seen = <CoreDiagnostic>[];
    map.setDiagnosticCallback(seen.add);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
    map.setCamera(latitude: 60.45, longitude: 22.27, zoom: 4);

    map.addSourceJson('g', '''
      {"type":"geojson","data":${pointsAround(60.45, 22.27, 20, 0.5)}}
    ''');
    map.addLayerJson('''
      {"id":"g-count","type":"symbol","source":"g",
       "layout":{"text-field":"x","text-font":["No Such Font Regular"]}}
    ''');

    final sw = Stopwatch()..start();
    var glyphFailure = <CoreDiagnostic>[];
    while (sw.elapsed < const Duration(seconds: 25)) {
      glyphFailure = seen
          .where(
            (d) =>
                d.severity == CoreDiagnosticSeverity.error &&
                d.message.contains('No Such Font Regular'),
          )
          .toList();
      if (glyphFailure.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(
      glyphFailure,
      isNotEmpty,
      reason:
          'MapObserver::onGlyphsError is dead in this configuration, so the '
          'log observer is the only hook that sees a missing font',
    );
  });

  // Every mutating call in this ABI is posted to the render thread and returns
  // void, so a removal that matched nothing used to be indistinguishable from
  // one that worked. mbgl hands back a unique_ptr saying which; we used to drop
  // it on the floor.
  test('a removal that matched nothing is reported, not silent', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    addTearDown(map.dispose);
    final failures = <CoreDiagnostic>[];
    map.setDiagnosticCallback((d) {
      if (d.kind == CoreDiagnosticKind.commandFailed) failures.add(d);
    });
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    map.removeLayer('no-such-layer');
    map.removeSource('no-such-source');

    // A source a layer still references: mbgl refuses, and that is the failure
    // people actually hit — the removal appears to do nothing at all.
    map.addSourceJson(
      'held',
      '{"type":"geojson","data":${pointsAround(0, 0, 3, 0.1)}}',
    );
    map.addLayerJson(
      '{"id":"holder","type":"circle","source":"held",'
      '"paint":{"circle-radius":3,"circle-color":"#ff00ff"}}',
    );
    map.removeSource('held');

    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 10) && failures.length < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final messages = failures.map((d) => d.message).toList();
    expect(
      messages.any((m) => m.contains("no layer with id 'no-such-layer'")),
      isTrue,
      reason: 'removeLayer must say the id was not there',
    );
    expect(
      messages.any((m) => m.contains("no source with id 'no-such-source'")),
      isTrue,
    );
    expect(
      messages.any((m) => m.contains("'held' is still in use")),
      isTrue,
      reason: 'in-use and absent are the same null from mbgl; tell them apart',
    );

    // Removing them in the right order succeeds, and says nothing.
    failures.clear();
    map.removeLayer('holder');
    map.removeSource('held');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(failures, isEmpty, reason: 'success must stay quiet');
  });

  test('clearing the callback stops delivery, and dispose is safe', () async {
    final map = MapLibreCoreMap.create(
      width: 256,
      height: 256,
      pixelRatio: 1,
      styleUri: 'https://demotiles.maplibre.org/style.json',
    );
    final seen = <CoreDiagnostic>[];
    map.setDiagnosticCallback(seen.add);
    expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);

    map.setDiagnosticCallback(null);
    seen.clear();
    map.setStyle('https://demotiles.maplibre.org/style.json');
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(seen, isEmpty, reason: 'unregistered means unregistered');

    // Registering again after clearing must work, and must not double-deliver.
    map.setDiagnosticCallback(seen.add);
    map.dispose();
    // A disposed map takes a null registration without throwing (dispose
    // already did it), and never calls back afterwards.
    map.setDiagnosticCallback(null);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
}
