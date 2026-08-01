// Shared "the map is actually VISIBLE" helpers for the integration tests.
//
// WHY THIS FILE EXISTS: the Windows blank-map bug passed a green integration
// test, because that test asserted `onReady` completed and the camera read back
// — both true of a map rendering nothing at all. CLAUDE.md §7 states the rule
// that came out of it: "a frame came back" does not prove the map is visible,
// so assert real content. This was written once in the iOS test and nowhere
// else; it lives here so every tier can use the same assertion.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rasterises the widget tree under [key] and returns its pixels as RGBA.
///
/// MUST run inside `tester.runAsync`: `RenderRepaintBoundary.toImage` waits on a
/// real raster-pipeline callback, and `flutter_test`'s fake async never delivers
/// it, so calling it directly hangs to the 10-minute timeout (CLAUDE.md §11).
///
/// This is Flutter's own raster path, not a screen grab — which matters on
/// Windows, where GDI capture shows the ANGLE/D3D external texture as WHITE
/// even when it renders correctly (CLAUDE.md §11).
Future<ByteData> capturePixels(WidgetTester tester, Key key) async {
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
/// A blank map is uniform; a rendered basemap is not. COUNTING rather than
/// sampling one pixel means a stray artefact cannot pass for a map.
int nonBlankPixels(ByteData rgba) {
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

/// How many DISTINCT colours the frame contains, coarsely quantised.
///
/// The stronger of the two checks. A map that failed to load its tiles but drew
/// its background is uniformly one non-white colour, which [nonBlankPixels]
/// happily counts as content; a real basemap has land, water, borders and
/// labels. Quantising to 5 bits per channel keeps antialiasing from inflating
/// the count into meaninglessness.
int distinctColours(ByteData rgba) {
  final seen = <int>{};
  for (var i = 0; i + 3 < rgba.lengthInBytes; i += 4) {
    seen.add(
      (rgba.getUint8(i) >> 3) << 10 |
          (rgba.getUint8(i + 1) >> 3) << 5 |
          (rgba.getUint8(i + 2) >> 3),
    );
  }
  return seen.length;
}

/// Asserts the map under [key] is drawing a real basemap, not a blank surface.
///
/// [minDistinct] is deliberately low: the point is to separate "a map" from
/// "one flat colour", not to pin a particular style's palette.
Future<void> expectMapIsVisible(
  WidgetTester tester,
  Key key, {
  int minDistinct = 8,
  String? reason,
}) async {
  final pixels = await capturePixels(tester, key);
  final total = pixels.lengthInBytes ~/ 4;
  final nonBlank = nonBlankPixels(pixels);
  final colours = distinctColours(pixels);
  expect(
    nonBlank,
    greaterThan(total ~/ 20),
    reason:
        'the map area is essentially blank ($nonBlank of $total pixels have '
        'any colour) — this is exactly what the Windows blank-map bug looked '
        'like to a test that only checked onReady${reason == null ? '' : '. $reason'}',
  );
  expect(
    colours,
    greaterThanOrEqualTo(minDistinct),
    reason:
        'only $colours distinct colours: the surface has content but no MAP — '
        'a background that painted while every tile failed looks like this',
  );
}
