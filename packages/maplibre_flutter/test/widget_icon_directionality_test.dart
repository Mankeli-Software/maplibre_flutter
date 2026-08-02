import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/src/map_style_controller.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// The fixture is deliberately ASYMMETRIC — red then blue, never mirrored — so
/// a dropped [Directionality] cannot hide behind an icon that looks the same
/// either way round, which is exactly why nobody hit this: real icons are
/// usually a single centred glyph.
const _redThenBlue = Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    SizedBox(
      width: 10,
      height: 10,
      child: ColoredBox(color: Color(0xFFFF0000)),
    ),
    SizedBox(
      width: 10,
      height: 10,
      child: ColoredBox(color: Color(0xFF0000FF)),
    ),
  ],
);

const _fixtureSize = Size(20, 10);

/// Reads one pixel out of a raw RGBA buffer.
({int r, int g, int b, int a}) _pixel(
  Uint8List bytes,
  int width,
  int x,
  int y,
) {
  final i = (y * width + x) * 4;
  return (r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3]);
}

Future<Uint8List> _rgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

void _expectRed(({int r, int g, int b, int a}) px, {required String where}) {
  expect(px.r, greaterThan(200), reason: 'red at $where');
  expect(px.b, lessThan(60), reason: 'not blue at $where');
}

void _expectBlue(({int r, int g, int b, int a}) px, {required String where}) {
  expect(px.b, greaterThan(200), reason: 'blue at $where');
  expect(px.r, lessThan(60), reason: 'not red at $where');
}

void main() {
  // NOTE every test here runs inside tester.runAsync. RenderRepaintBoundary
  // .toImage() waits on a real callback from the engine's raster pipeline,
  // which flutter_test's fake async never delivers — without runAsync these
  // hang until the 10-minute timeout rather than failing.

  testWidgets('ltr rasterization puts the leading child on the LEFT', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final image = await MapLibreStyleController.rasterizeWidget(
        _redThenBlue,
        size: _fixtureSize,
        pixelRatio: 1,
        textDirection: TextDirection.ltr,
      );
      addTearDown(image.dispose);
      expect(image.width, 20);

      final bytes = await _rgba(image);
      _expectRed(_pixel(bytes, 20, 5, 5), where: 'x=5, the left half');
      _expectBlue(_pixel(bytes, 20, 15, 5), where: 'x=15, the right half');
    });
  });

  testWidgets('rtl rasterization puts the leading child on the RIGHT', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final image = await MapLibreStyleController.rasterizeWidget(
        _redThenBlue,
        size: _fixtureSize,
        pixelRatio: 1,
        textDirection: TextDirection.rtl,
      );
      addTearDown(image.dispose);

      final bytes = await _rgba(image);
      // Absolute, not a round trip: the first child of the Row is red, and
      // under rtl it must land at the RIGHT edge of the bitmap.
      _expectRed(_pixel(bytes, 20, 15, 5), where: 'x=15, the right half');
      _expectBlue(_pixel(bytes, 20, 5, 5), where: 'x=5, the left half');
    });
  });

  testWidgets('a textScaler of 2 rasterizes visibly larger than 1', (
    tester,
  ) async {
    await tester.runAsync(() async {
      const label = Text('Aa', style: TextStyle(fontSize: 12));
      const cap = Size(400, 200);

      final plain = await MapLibreStyleController.rasterizeWidget(
        label,
        size: cap,
        pixelRatio: 1,
        mediaQuery: const MediaQueryData(),
      );
      addTearDown(plain.dispose);
      final scaled = await MapLibreStyleController.rasterizeWidget(
        label,
        size: cap,
        pixelRatio: 1,
        mediaQuery: const MediaQueryData(textScaler: TextScaler.linear(2)),
      );
      addTearDown(scaled.dispose);

      expect(scaled.width, greaterThan(plain.width));
      expect(scaled.height, greaterThan(plain.height));
    });
  });

  testWidgets('addWidgetIcon(context:) forwards the ambient Directionality', (
    tester,
  ) async {
    final rec = _RecordingLayers();
    final style = MapLibreStyleController()..attachTo(rec);
    final context = await _contextUnder(
      tester,
      textDirection: TextDirection.rtl,
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
    );

    await tester.runAsync(() async {
      await style.addWidgetIcon(
        'pin',
        _redThenBlue,
        size: _fixtureSize,
        pixelRatio: 1,
        context: context,
      );
    });

    final icon = rec.images['pin']!;
    expect(icon.width, 20);
    _expectRed(_pixel(icon.rgba, 20, 15, 5), where: 'x=15, the right half');
    _expectBlue(_pixel(icon.rgba, 20, 5, 5), where: 'x=5, the left half');
  });

  testWidgets('without a context nothing changes: ltr, and no text scaling', (
    tester,
  ) async {
    final rec = _RecordingLayers();
    final style = MapLibreStyleController()..attachTo(rec);
    // The app IS rtl at 2x text — and an existing caller that passes no context
    // must be unaffected by that, or upgrading silently resizes every icon.
    final context = await _contextUnder(
      tester,
      textDirection: TextDirection.rtl,
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
    );

    await tester.runAsync(() async {
      await style.addWidgetIcon(
        'pin',
        _redThenBlue,
        size: _fixtureSize,
        pixelRatio: 1,
      );
      await style.addWidgetIcon(
        'label',
        const Text('Aa', style: TextStyle(fontSize: 12)),
        size: const Size(400, 200),
        pixelRatio: 1,
      );
      await style.addWidgetIcon(
        'label-scaled',
        const Text('Aa', style: TextStyle(fontSize: 12)),
        size: const Size(400, 200),
        pixelRatio: 1,
        context: context,
      );
    });

    final pin = rec.images['pin']!;
    _expectRed(_pixel(pin.rgba, 20, 5, 5), where: 'x=5, the left half');
    _expectBlue(_pixel(pin.rgba, 20, 15, 5), where: 'x=15, the right half');
    // Same widget, same call, one with the ambient 2x scaler and one without.
    expect(
      rec.images['label-scaled']!.width,
      greaterThan(rec.images['label']!.width),
    );
  });
}

/// Pumps a tree under [textDirection] and [data] and hands back a context
/// inside it. Pumping stays OUTSIDE runAsync — only the rasterization needs a
/// real raster pipeline.
Future<BuildContext> _contextUnder(
  WidgetTester tester, {
  required TextDirection textDirection,
  required MediaQueryData data,
}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MediaQuery(
      data: data,
      child: Directionality(
        textDirection: textDirection,
        child: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return captured;
}

/// Keeps the registered bitmap itself, which is the only way to assert WHERE
/// the icon painted rather than merely that one was registered.
///
/// noSuchMethod rather than thirty stubs: [MapLibreStyleLayers] is a wide
/// interface and this test exercises exactly one member of it.
class _RecordingLayers implements MapLibreStyleLayers {
  final Map<
    String,
    ({int width, int height, double pixelRatio, Uint8List rgba})
  >
  images = {};

  @override
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) => images[id] = (
    width: width,
    height: height,
    pixelRatio: pixelRatio,
    rgba: rgba,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
