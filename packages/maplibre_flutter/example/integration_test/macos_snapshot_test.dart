// 8.4 on real hardware.
//
//   flutter test integration_test/macos_snapshot_test.dart -d macos
//
// A snapshotter that returns bytes is easy; one that returns a PICTURE is the
// point. These assert the pixels — a blank buffer of the right size would
// satisfy every other check (CLAUDE.md §7).
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

const _demotiles = 'https://demotiles.maplibre.org/style.json';

/// Distinct colours, coarsely quantised. A flat buffer has one; a map has many.
int _distinctColours(MapSnapshot s) {
  final seen = <int>{};
  for (var i = 0; i + 3 < s.pixels.length; i += 4) {
    seen.add(
      (s.pixels[i] >> 3) << 10 |
          (s.pixels[i + 1] >> 3) << 5 |
          (s.pixels[i + 2] >> 3),
    );
  }
  return seen.length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders a real map with no map on screen', (tester) async {
    final snapshot = await tester.runAsync(
      () => MapLibreSnapshotter.take(
        const MapSnapshotOptions(
          style: _demotiles,
          camera: MapCamera(center: LatLng(60.45, 22.27), zoom: 4),
          size: Size(320, 200),
        ),
      ),
    );

    expect(snapshot, isNotNull);
    expect(snapshot!.width, 320);
    expect(snapshot.height, 200);
    expect(snapshot.pixels.length, 320 * 200 * 4);
    expect(
      _distinctColours(snapshot),
      greaterThan(8),
      reason:
          'a buffer of the right size full of one colour passes every '
          'other assertion here — the picture is the product',
    );
  });

  testWidgets('an inline style renders the colour it asked for, in RGBA', (
    tester,
  ) async {
    // Pure RED: the engine produces BGRA and the snapshot promises RGBA, so an
    // unconverted buffer reads as BLUE. A symmetric colour could not catch that
    // — and this repo has already shipped exactly that mistake once, in a test
    // helper, invisible for months because every fixture was magenta.
    final snapshot = await tester.runAsync(
      () => MapLibreSnapshotter.take(
        const MapSnapshotOptions(
          style:
              '{"version":8,"sources":{},"layers":['
              '{"id":"bg","type":"background",'
              '"paint":{"background-color":"#ff0000"}}]}',
          camera: MapCamera(center: LatLng(0, 0), zoom: 1),
          size: Size(64, 64),
        ),
      ),
    );

    expect(snapshot, isNotNull);
    expect(snapshot!.pixels[0], greaterThan(200), reason: 'R');
    expect(snapshot.pixels[1], lessThan(60), reason: 'G');
    expect(
      snapshot.pixels[2],
      lessThan(60),
      reason:
          'B — blue here means the '
          'BGRA to RGBA conversion was skipped',
    );
  });

  testWidgets('takeImage decodes to a usable ui.Image', (tester) async {
    final image = await tester.runAsync(
      () => MapLibreSnapshotter.takeImage(
        const MapSnapshotOptions(
          style:
              '{"version":8,"sources":{},"layers":['
              '{"id":"bg","type":"background",'
              '"paint":{"background-color":"#00ff00"}}]}',
          camera: MapCamera(center: LatLng(0, 0), zoom: 1),
          size: Size(48, 32),
        ),
      ),
    );

    expect(image, isNotNull);
    expect(image!.width, 48);
    expect(image.height, 32);
    // And it survives a round trip through Flutter's own encoder, which is what
    // a caller will actually do with it.
    final png = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.png),
    );
    expect(png, isNotNull);
    expect(png!.lengthInBytes, greaterThan(0));
    image.dispose();
  });

  testWidgets('a nonsense size is refused rather than rendered', (
    tester,
  ) async {
    final snapshot = await tester.runAsync(
      () => MapLibreSnapshotter.take(
        const MapSnapshotOptions(
          style: _demotiles,
          camera: MapCamera(center: LatLng(0, 0), zoom: 1),
          size: Size.zero,
        ),
      ),
    );
    expect(snapshot, isNull);
  });
}
