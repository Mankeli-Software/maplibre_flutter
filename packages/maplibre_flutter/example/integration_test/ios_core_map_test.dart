// End-to-end iOS test for the default core renderer (CLAUDE.md §7 layer 5):
// drives a real mbgl-core map (the maplibre_flutter_core Metal arm) composited
// through a Flutter Texture — the iOS default (the MapLibre Apple SDK is the
// opt-in maplibre_flutter_ios_sdk package).
//
//   flutter test integration_test/ios_core_map_test.dart -d <device>
//
// Runs on a real iOS device or an Apple-Silicon Simulator, which has a real
// host-GPU Metal. Needs network access (keyless demotiles + OpenFreeMap). Every
// wait is bounded so a context/render failure fails rather than hangs.
//
// WHY IT ASSERTS PIXELS. The previous version of this file checked only that
// `onReady` completed, the camera round-tripped, and a style swap did not
// throw — and said so in its own header. CLAUDE.md §7 forbids exactly that: the
// Windows blank-map bug passed a green integration test for that reason. A
// frame arriving proves the Metal backend, the IOSurface/CVPixelBuffer present
// path and FFI all work; it proves nothing about what is on screen.
//
// Simulator-only artefact, already bisected and NOT a bug to chase: faint 1-px
// tile seams appear in the Simulator's offscreen Metal and are confirmed absent
// on a physical iPhone. Nothing asserted here depends on them.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

const _demotiles = 'https://demotiles.maplibre.org/style.json';
const _liberty = 'https://tiles.openfreemap.org/styles/liberty';

/// Rasterises the widget tree under [key] and returns its pixels.
///
/// MUST run inside `tester.runAsync`: `RenderRepaintBoundary.toImage` waits on a
/// real raster-pipeline callback, and `flutter_test`'s fake async never delivers
/// it, so calling it directly hangs to the 10-minute timeout (CLAUDE.md §11).
Future<ByteData> _capture(WidgetTester tester, Key key) async {
  final boundary =
      tester.renderObject(find.byKey(key)) as RenderRepaintBoundary;
  final data = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return bytes;
  });
  expect(data, isNotNull, reason: 'rasterising the map produced no bytes');
  return data!;
}

/// How many pixels differ noticeably from pure white and pure black.
///
/// A blank map is uniform; a rendered basemap is not. Counting rather than
/// sampling one pixel means a stray artefact cannot pass for a map.
int _nonBlankPixels(ByteData rgba) {
  var count = 0;
  for (var i = 0; i + 3 < rgba.lengthInBytes; i += 4) {
    final r = rgba.getUint8(i);
    final g = rgba.getUint8(i + 1);
    final b = rgba.getUint8(i + 2);
    final nearWhite = r > 245 && g > 245 && b > 245;
    final nearBlack = r < 10 && g < 10 && b < 10;
    if (!nearWhite && !nearBlack) count++;
  }
  return count;
}

/// Pumps a bounded number of frames.
///
/// NOT `pumpAndSettle`: it waits for the frame pipeline to go idle, and on a
/// live map it never does. The marker overlay runs a repaint ticker while the
/// camera is settling, and a model with a non-zero spin drives `triggerRepaint`
/// forever by design — so `pumpAndSettle` times out on exactly the scenarios
/// worth testing.
Future<void> pumpFrames(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Lets REAL time pass, then pumps frames.
///
/// `tester.pump` alone is not enough for anything the engine does: mbgl renders
/// on its own thread in real time, so tiles, the first transform snapshot and
/// the projector tick all need wall-clock time that only `runAsync` allows to
/// elapse. A marker whose projection is not ready yet is SKIPPED by the overlay
/// delegate and its child stays parked at the origin — which reads as "the
/// marker is in the wrong place" rather than "the map has not caught up".
Future<void> settleMap(WidgetTester tester, {int seconds = 4}) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(seconds: seconds)));
  await pumpFrames(tester, frames: 30);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders visible map content, not just a frame', (tester) async {
    const mapKey = Key('map');
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: mapKey,
          child: MapLibreMap(
            controller: controller,
            style: _demotiles,
            options: const MapOptions(
              initialCamera: MapCamera(center: LatLng(51.5, -0.13), zoom: 5),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));

    // Tiles arrive after the first frame, so settle before sampling.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 8)),
    );
    await pumpFrames(tester);

    final pixels = await _capture(tester, mapKey);
    final drawn = _nonBlankPixels(pixels);
    expect(
      drawn,
      greaterThan(1000),
      reason:
          'the map area is uniform — a frame arrived but nothing is on it, '
          'which is exactly what the Windows blank-map bug looked like',
    );
  });

  testWidgets('camera round-trips and the style prop is declarative', (
    tester,
  ) async {
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

    await pumpWithStyle(_demotiles);
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));

    await controller.camera.jumpTo(
      CameraOptions.fromCamera(
        const MapCamera(center: LatLng(51.5, -0.13), zoom: 6),
      ),
    );
    final cam = await controller.camera.getCamera();
    expect(cam.center.latitude, closeTo(51.5, 0.5));
    expect(cam.center.longitude, closeTo(-0.13, 0.5));
    expect(cam.zoom, closeTo(6, 0.5));

    await pumpWithStyle(_liberty);
    await tester.pump();
    final after = await controller.camera.getCamera();
    expect(after.zoom, closeTo(6, 0.5));
  });

  testWidgets('widget markers land in the right ABSOLUTE direction', (
    tester,
  ) async {
    // CLAUDE.md §7: test projections against absolute directions, never only
    // round-trips. A symmetric Y flip survives every round-trip test, and the
    // camera centre is symmetric too — so both are blind to an inverted axis.
    // North must be UP and east must be RIGHT on screen, full stop.
    const centre = LatLng(51.5, -0.13);
    const north = Key('north');
    const east = Key('east');
    const middle = Key('middle');

    final controller = MapLibreMapController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: _demotiles,
          options: const MapOptions(
            initialCamera: MapCamera(center: centre, zoom: 8),
          ),
          markers: const [
            MapLibreMarker(
              point: centre,
              child: SizedBox(key: middle, width: 12, height: 12),
            ),
            // Deliberately modest offsets. The overlay CULLS a marker whose
            // box lies wholly outside the map, and a phone viewport is only
            // ~400pt wide — at zoom 8 that is about a third of a degree of
            // longitude, so a point 0.6 degrees east is legitimately off-screen
            // and its absence would read as a projection bug.
            MapLibreMarker(
              point: LatLng(51.7, -0.13), // due north
              child: SizedBox(key: north, width: 12, height: 12),
            ),
            MapLibreMarker(
              point: LatLng(51.5, 0.02), // due east
              child: SizedBox(key: east, width: 12, height: 12),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));
    await settleMap(tester);

    // Markers must be painted WITHOUT any gesture first: the projector ticks on
    // the first frame precisely so the overlay does not wait for a pan.
    final middleAt = tester.getCenter(find.byKey(middle));
    final northAt = tester.getCenter(find.byKey(north));
    final eastAt = tester.getCenter(find.byKey(east));

    expect(
      northAt.dy,
      lessThan(middleAt.dy),
      reason: 'a marker NORTH of centre must sit ABOVE it on screen',
    );
    expect(
      eastAt.dx,
      greaterThan(middleAt.dx),
      reason: 'a marker EAST of centre must sit to its RIGHT',
    );
    // And the axes must not be swapped: due north moves only vertically.
    expect(northAt.dx, closeTo(middleAt.dx, 4));
    expect(eastAt.dy, closeTo(middleAt.dy, 4));
  });

  testWidgets('engine layers draw and queryRenderedFeatures finds them', (
    tester,
  ) async {
    const centre = LatLng(51.5, -0.13);
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: _demotiles,
          options: const MapOptions(
            initialCamera: MapCamera(center: centre, zoom: 10),
          ),
        ),
      ),
    );
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));

    expect(
      controller.style.isSupported,
      isTrue,
      reason: 'the iOS core tier must offer MapLibreStyleLayers',
    );

    // Settle BEFORE adding anything. `onReady` completes on the first FRAME,
    // which can precede the style finishing its load — and loading a style
    // drops every app-added source and layer, with no event to tell you it
    // happened. Adding immediately after onReady is therefore a race that
    // silently loses the layer. (This is the missing style-loaded event the
    // contract still owes; the example app papers over it with a hardcoded
    // 700ms delay.)
    await settleMap(tester, seconds: 5);

    controller.style
      ..addSourceJson('pts', '''
        {"type":"geojson","data":{"type":"Feature",
         "properties":{"tag":"probe"},
         "geometry":{"type":"Point","coordinates":[-0.13,51.5]}}}
      ''')
      ..addLayerJson('''
        {"id":"pts-c","type":"circle","source":"pts",
         "paint":{"circle-radius":14,"circle-color":"#ff00ff"}}
      ''');

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 5)),
    );
    await pumpFrames(tester);

    // Query where the feature actually is, not the whole viewport: a
    // full-viewport box is y-symmetric and so cannot detect a flipped box.
    final size = tester.getSize(find.byType(MapLibreMap));
    final at = Offset(size.width / 2, size.height / 2);
    final found = controller.queryRenderedFeatures(
      Rect.fromCenter(center: at, width: 40, height: 40),
    );
    expect(
      found.any((f) => f.properties['tag'] == 'probe'),
      isTrue,
      reason:
          'the engine drew the circle at the map centre, so a small box '
          'there must find it',
    );

    // And the vertically mirrored box must NOT match — which is what proves
    // this would catch a flipped query rect rather than passing by luck.
    final mirrored = controller.queryRenderedFeatures(
      Rect.fromCenter(
        center: Offset(at.dx, size.height - at.dy - size.height / 4),
        width: 40,
        height: 40,
      ),
    );
    expect(mirrored.any((f) => f.properties['tag'] == 'probe'), isFalse);
  });

  testWidgets('3D models load and the engine keeps producing frames', (
    tester,
  ) async {
    // The engine reads a real filesystem path natively and knows nothing about
    // Flutter's asset bundle, so copy the bundled .glb out first. Under the iOS
    // sandbox this lands in the app container and needs no entitlement.
    final bytes = await rootBundle.load('assets/models/demo_vehicle.glb');
    final file = File('${Directory.systemTemp.path}/demo_vehicle.glb');
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);

    final controller = MapLibreMapController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: _demotiles,
          options: const MapOptions(
            initialCamera: MapCamera(
              center: LatLng(51.50735, -0.12776),
              zoom: 19,
              pitch: 55,
            ),
          ),
          models: [
            MapLibreModel(
              id: 'demo',
              assetPath: file.path,
              point: const LatLng(51.50735, -0.12776),
              elevationMetres: 0.15,
              spinDegreesPerSecond: 45,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));
    await pumpFrames(tester);

    // modelPartCount is non-null only after the .glb actually parsed, so this
    // distinguishes "loaded" from "silently failed and drew nothing".
    expect(
      // ignore: experimental_member_use
      controller.modelPartCount(file.path),
      isNotNull,
      reason: 'iOS implements MapLibreModelHost, so the mesh must have parsed',
    );

    // A spinning model must keep the engine rendering. Measuring with a Flutter
    // Ticker instead would report Flutter's vsync, which stays pinned at the
    // display rate however far behind the map falls — the map is a texture, so
    // Flutter has nothing to wait for.
    // ignore: experimental_member_use
    final before = controller.renderedFrameCount;
    expect(before, isNotNull);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 3)),
    );
    expect(
      // ignore: experimental_member_use
      controller.renderedFrameCount,
      greaterThan(before!),
      reason:
          'the repaint pump must drive the spin; continuous mode is '
          'update-driven, not vsync-driven, so without it the model renders '
          'once and stops',
    );
  });
}
