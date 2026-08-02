// `controller.snapshot()` — the pixels of the map that is ON SCREEN.
//
// Distinct from `MapLibreSnapshotter`, which renders a new off-screen map: the
// C ABI, the Dart wrapper and the core's own tests for this all existed and
// were reachable from no public API at all.
library;

import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

class _PlainController implements MapLibreMapPlatformController {
  _PlainController({this.frame});

  final MapSnapshot? frame;
  int captures = 0;

  @override
  final MapLibreRenderHandle renderHandle = const TextureHandle(textureId: 7);
  @override
  Future<void> get onReady => Future<void>.value();
  @override
  Future<MapCamera> getCamera() async => const MapCamera(center: LatLng(0, 0));
  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {}
  @override
  Future<void> setStyle(String styleUri) async {}
  @override
  Future<void> resize(Size size, double devicePixelRatio) async {}
  @override
  Future<void> dispose() async {}
}

class _CapableController extends _PlainController
    implements MapLibreMapCapture {
  _CapableController({super.frame});

  @override
  Future<MapSnapshot?> captureFrame() async {
    captures++;
    return frame;
  }
}

class _Platform extends MapLibreFlutterPlatform {
  _Platform(this._controller);
  final MapLibreMapPlatformController _controller;
  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => _controller;
}

const _options = MapOptions(initialCamera: MapCamera(center: LatLng(0, 0)));

MapSnapshot _redPixel() => MapSnapshot(
  pixels: Uint8List.fromList(const [255, 0, 0, 255]),
  width: 1,
  height: 1,
);

Future<MapLibreMapController> _attached(
  MapLibreMapPlatformController platform,
) async {
  MapLibreFlutterPlatform.instance = _Platform(platform);
  final controller = MapLibreMapController();
  await controller.attach(styleUri: 's', options: _options);
  return controller;
}

void main() {
  test('returns the frame the tier handed back', () async {
    final platform = _CapableController(frame: _redPixel());
    final controller = await _attached(platform);

    final shot = await controller.snapshot();
    expect(platform.captures, 1);
    expect(shot, isNotNull);
    expect(shot!.width, 1);
    expect(shot.height, 1);
    // RGBA, so a red pixel is R first. The whole reason the channel swap lives
    // in the core rather than in five controllers is that two tiers emit BGRA
    // and would otherwise hand back blue here — silently, since a map is mostly
    // greys and greens.
    expect(shot.pixels, orderedEquals(const [255, 0, 0, 255]));
  });

  test('is null before the first frame, having still asked', () async {
    final platform = _CapableController();
    final controller = await _attached(platform);
    expect(await controller.snapshot(), isNull);
    expect(
      platform.captures,
      1,
      reason: 'null must mean "no frame yet", not "never tried"',
    );
  });

  test('is null — not an error — on a tier that cannot capture', () async {
    // The web tiers: the map is a DOM canvas whose pixels Flutter never sees.
    final controller = await _attached(_PlainController());
    expect(await controller.snapshot(), isNull);
    expect(await controller.snapshotImage(), isNull);
  });

  test('snapshotImage decodes to a ui.Image', () async {
    final controller = await _attached(_CapableController(frame: _redPixel()));
    final image = await controller.snapshotImage();
    expect(image, isNotNull);
    expect(image!.width, 1);
    expect(image.height, 1);
    image.dispose();
  });
}
