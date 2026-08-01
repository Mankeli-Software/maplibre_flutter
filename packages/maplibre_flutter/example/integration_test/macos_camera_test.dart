// End-to-end macOS camera test (CLAUDE.md §7 layer 5): drives a real mbgl-core
// map through the engine-native camera commands added in stage 3. Run on macOS,
// which is this project's reference tier:
//
//   flutter test integration_test/macos_camera_test.dart -d macos
//
// It needs network access (keyless demotiles) and a Metal-capable GPU. Every
// wait is bounded, so a failure to render or to finish a transition fails the
// test instead of hanging.
//
// WHY THIS EXISTS AT ALL: the unit and conformance suites drive a FAKE core, so
// they prove the plumbing and nothing about the engine. Twice already in this
// effort a change passed a fully green suite and was broken the moment the app
// ran — an `onReady` that never completed, and a style-loaded event dropped by
// a broadcast stream. Screenshots proved poor at telling those apart; assertions
// on a real map do not.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

import 'pixel_assertions.dart';

const _demotiles = 'https://demotiles.maplibre.org/style.json';

/// Turku and Stockholm: asymmetric on BOTH axes and in both signs, so a swapped
/// or mirrored coordinate cannot pass by symmetry (CLAUDE.md §7).
const _turku = LatLng(60.4518, 22.2666);
const _stockholm = LatLng(59.3293, 18.0686);

const _mapKey = Key('map');

Future<MapLibreMapController> _boot(WidgetTester tester) async {
  final controller = MapLibreMapController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        key: _mapKey,
        child: MapLibreMap(
          controller: controller,
          style: _demotiles,
          options: const MapOptions(
            initialCamera: MapCamera(center: LatLng(0, 0), zoom: 2),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await controller.onReady.timeout(const Duration(seconds: 30));
  return controller;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the tier reports engine camera commands', (tester) async {
    final controller = await _boot(tester);
    expect(
      controller.capabilities.cameraCommands,
      isTrue,
      reason: 'macOS is an mbgl-core tier; it must run native transitions',
    );
  });

  // Every other test in this file asserts engine STATE — real content, but all
  // of it true of a map that draws nothing. This one asserts the picture, once,
  // so the rest can keep testing what they are actually about (CLAUDE.md §7).
  testWidgets('the map is actually visible, not just ready', (tester) async {
    await _boot(tester);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await expectMapIsVisible(tester, _mapKey);
  });

  // THE regression that made the example app unusable: the app renders a map
  // and then waits forever for a style-loaded event that already happened.
  //
  // A real tier can only register its diagnostic callback after mbl_map_create
  // returns — and on the texture tiers after a registrar round trip — by which
  // time a style has usually loaded (~170 ms). So the live event is missed and
  // everything depends on the replay. Continuous mode uses FrameObserver, which
  // overrode onDidFinishLoadingStyle WITHOUT delegating, so the replay
  // bookkeeping never ran and the app hung on "loading the style".
  testWidgets('onStyleLoaded reaches a subscriber that arrives late', (
    tester,
  ) async {
    final controller = await _boot(tester);

    // Subscribe only NOW — after onReady, so the first style load is long past.
    final loads = <void>[];
    final subscription = controller.onStyleLoaded.listen(loads.add);
    addTearDown(subscription.cancel);

    final stopwatch = Stopwatch()..start();
    while (loads.isEmpty && stopwatch.elapsed < const Duration(seconds: 10)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      loads,
      isNotEmpty,
      reason:
          'a late subscriber must still be told the style is in — otherwise an '
          'app that gates itself on this waits forever over a working map',
    );
  });

  testWidgets('jumpTo applies a PARTIAL camera and leaves the rest', (
    tester,
  ) async {
    final controller = await _boot(tester);
    await controller.camera.jumpTo(
      CameraOptions.fromCamera(
        const MapCamera(center: _turku, zoom: 6, bearing: 30),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // Zoom only — the whole point of a partial camera is that nothing else
    // moves, and that it needs no read-modify-write to say so.
    await controller.camera.jumpTo(const CameraOptions(zoom: 9));
    await tester.pump(const Duration(milliseconds: 300));

    final after = await controller.camera.getCamera();
    expect(after.zoom, closeTo(9, 0.01));
    expect(after.center.latitude, closeTo(_turku.latitude, 0.01));
    expect(after.center.longitude, closeTo(_turku.longitude, 0.01));
    expect(after.bearing, closeTo(30, 0.01), reason: 'bearing untouched');
  });

  testWidgets('easeTo completes on transition END, not on a timer', (
    tester,
  ) async {
    final controller = await _boot(tester);
    await controller.camera.jumpTo(const CameraOptions(zoom: 2));
    await tester.pump(const Duration(milliseconds: 200));

    final stopwatch = Stopwatch()..start();
    final move = controller.camera.easeTo(
      CameraOptions(center: _stockholm, zoom: 7),
      duration: const Duration(milliseconds: 600),
    );
    // Integration binding drives real frames, so pump until it resolves.
    var done = false;
    unawaited(move.then((_) => done = true));
    while (!done && stopwatch.elapsed < const Duration(seconds: 15)) {
      await tester.pump(const Duration(milliseconds: 32));
    }

    expect(done, isTrue, reason: 'the Future must resolve, not hang');
    expect(
      stopwatch.elapsedMilliseconds,
      greaterThan(300),
      reason: 'it must wait for the animation, not return immediately',
    );
    final after = await controller.camera.getCamera();
    expect(after.zoom, closeTo(7, 0.2));
    expect(after.center.latitude, closeTo(_stockholm.latitude, 0.2));
  });

  // The contract that makes awaiting safe. mbgl fires the previous transition's
  // finish function when a new one starts, so an interrupted flight resolves
  // rather than leaving a Future outstanding forever.
  testWidgets('a superseded flight completes rather than hanging', (
    tester,
  ) async {
    final controller = await _boot(tester);
    var flown = false;
    unawaited(
      controller.camera
          .flyTo(
            CameraOptions(center: _turku, zoom: 14),
            duration: const Duration(seconds: 8),
          )
          .then((_) => flown = true),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Supersede it.
    await controller.camera.jumpTo(const CameraOptions(zoom: 3));
    final stopwatch = Stopwatch()..start();
    while (!flown && stopwatch.elapsed < const Duration(seconds: 10)) {
      await tester.pump(const Duration(milliseconds: 32));
    }
    expect(flown, isTrue, reason: 'the interrupted flight must complete');

    final after = await controller.camera.getCamera();
    expect(after.zoom, closeTo(3, 0.3), reason: 'the jump won');
  });

  testWidgets('fitBounds puts the box on screen, oriented correctly', (
    tester,
  ) async {
    final controller = await _boot(tester);
    const bounds = LatLngBounds(southwest: _stockholm, northeast: _turku);

    // cameraForBounds must NOT move anything.
    await controller.camera.jumpTo(const CameraOptions(zoom: 2));
    await tester.pump(const Duration(milliseconds: 200));
    final computed = await controller.camera.cameraForBounds(bounds);
    expect(computed, isNotNull);
    expect(computed!.zoom, isNotNull);
    expect(
      (await controller.camera.getCamera()).zoom,
      closeTo(2, 0.01),
      reason: 'cameraForBounds computes, it does not move',
    );

    await controller.camera.fitBounds(
      bounds,
      transition: CameraTransition.jump,
    );
    await tester.pump(const Duration(milliseconds: 400));

    final visible = await controller.camera.getBounds();
    expect(visible, isNotNull);
    // North is up and east is right — absolute directions, never a round trip.
    expect(visible!.north, greaterThan(visible.south));
    expect(visible.east, greaterThan(visible.west));
    // The requested box has to be INSIDE what is now visible.
    expect(
      visible.south,
      lessThanOrEqualTo(bounds.south + 0.01),
      reason: 'the south edge must be on screen',
    );
    expect(visible.north, greaterThanOrEqualTo(bounds.north - 0.01));
    expect(visible.west, lessThanOrEqualTo(bounds.west + 0.01));
    expect(visible.east, greaterThanOrEqualTo(bounds.east - 0.01));
  });

  testWidgets('camera constraints clamp the zoom, and read back', (
    tester,
  ) async {
    final controller = await _boot(tester);
    await controller.camera.setMinZoom(4);
    await controller.camera.setMaxZoom(8);
    await tester.pump(const Duration(milliseconds: 200));

    await controller.camera.jumpTo(const CameraOptions(zoom: 14));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      (await controller.camera.getCamera()).zoom,
      closeTo(8, 0.01),
      reason: 'clamped to maxZoom by the engine, not by us',
    );

    await controller.camera.jumpTo(const CameraOptions(zoom: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect((await controller.camera.getCamera()).zoom, closeTo(4, 0.01));

    final limits = await controller.camera.getConstraints();
    expect(limits, isNotNull);
    expect(limits!.minZoom, closeTo(4, 0.01));
    expect(limits.maxZoom, closeTo(8, 0.01));
  });

  testWidgets('an anchored zoom holds the anchor, not the centre', (
    tester,
  ) async {
    final controller = await _boot(tester);
    await controller.camera.setMinZoom(0);
    await controller.camera.setMaxZoom(22);
    await controller.camera.jumpTo(
      CameraOptions.fromCamera(const MapCamera(center: LatLng(0, 0), zoom: 4)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final before = await controller.camera.getCamera();
    // Anchor on a CORNER. A centre-anchored test cannot detect a dropped
    // anchor, because the centre is a fixed point either way — which is exactly
    // how mbgl's `anchor = camera.center ? nullopt : camera.anchor` hides.
    await controller.camera.zoomTo(6, around: Offset.zero);
    await tester.pump(const Duration(milliseconds: 300));

    final after = await controller.camera.getCamera();
    expect(after.zoom, closeTo(6, 0.01));
    expect(
      (after.center.latitude - before.center.latitude).abs() +
          (after.center.longitude - before.center.longitude).abs(),
      greaterThan(0.001),
      reason:
          'zooming about a corner must shift the centre; if the centre is '
          'unchanged the anchor was silently dropped',
    );
  });

  testWidgets('stop halts a flight where it reached', (tester) async {
    final controller = await _boot(tester);
    await controller.camera.jumpTo(const CameraOptions(zoom: 2));
    await tester.pump(const Duration(milliseconds: 200));

    unawaited(
      controller.camera.flyTo(
        CameraOptions(center: _turku, zoom: 15),
        duration: const Duration(seconds: 6),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await controller.camera.stop();
    await tester.pump(const Duration(milliseconds: 300));

    final stopped = await controller.camera.getCamera();
    await tester.pump(const Duration(milliseconds: 500));
    final later = await controller.camera.getCamera();
    expect(
      later.zoom,
      closeTo(stopped.zoom, 0.05),
      reason: 'the camera must stay where stop() left it',
    );
  });

  // 8.8: the constraints apply from MapOptions, before app code gets control.
  testWidgets('MapOptions constraints are in force by onReady', (tester) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: _demotiles,
          options: const MapOptions(
            initialCamera: MapCamera(center: _turku, zoom: 6),
            minZoom: 4,
            maxZoom: 9,
            maxBounds: LatLngBounds(
              southwest: LatLng(55, 4),
              northeast: LatLng(71, 32),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));

    // The point of putting these on MapOptions rather than only on the
    // controller: an app that awaits onReady and immediately moves must already
    // be working against them.
    final limits = await controller.camera.getConstraints();
    expect(limits, isNotNull);
    expect(limits!.minZoom, closeTo(4, 0.01));
    expect(limits.maxZoom, closeTo(9, 0.01));

    await controller.camera.jumpTo(const CameraOptions(zoom: 20));
    await tester.pump(const Duration(milliseconds: 300));
    expect((await controller.camera.getCamera()).zoom, closeTo(9, 0.01));

    // And the bounds hold: a jump far outside the box must land inside it.
    await controller.camera.jumpTo(
      CameraOptions.fromCamera(
        const MapCamera(center: LatLng(-33.9, 151.2), zoom: 5),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    final after = await controller.camera.getCamera();
    expect(
      after.center.latitude,
      greaterThan(40),
      reason:
          'Sydney is nowhere near the Nordics; maxBounds must have clamped '
          'the camera rather than being accepted and ignored',
    );
  });

  // 2.6b: onIdle was rejected in stage 2 as "never fires". It does — the
  // rejection's test had used Static mode, and mbgl gates the whole idle branch
  // on Continuous. Every shipped tier is Continuous, so this is the mode that
  // matters.
  testWidgets('onIdle fires once the map settles, and again after a move', (
    tester,
  ) async {
    final controller = await _boot(tester);
    final idles = <void>[];
    final subscription = controller.onIdle.listen(idles.add);
    addTearDown(subscription.cancel);

    Future<bool> waitForIdle() async {
      final before = idles.length;
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < const Duration(seconds: 20)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (idles.length > before) return true;
      }
      return false;
    }

    expect(
      await waitForIdle(),
      isTrue,
      reason: 'a map with its tiles in has nothing left to draw',
    );

    // And it RECURS. That is the difference between a state and a one-shot, and
    // it is why the stream is not replayed to late subscribers.
    await controller.camera.jumpTo(
      CameraOptions.fromCamera(const MapCamera(center: _stockholm, zoom: 7)),
    );
    expect(
      await waitForIdle(),
      isTrue,
      reason: 'the map re-enters idle after every interaction',
    );
  });
}
