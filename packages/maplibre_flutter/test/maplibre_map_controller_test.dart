import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

class _FakePlatformController implements MapLibreMapPlatformController {
  bool disposed = false;
  @override
  MapLibreRenderHandle get renderHandle => const TextureHandle(textureId: 1);
  @override
  Future<void> get onReady => Future<void>.value();
  @override
  Future<MapCamera> getCamera() async =>
      const MapCamera(center: LatLng(10, 20), zoom: 5);
  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {}
  @override
  Future<void> setStyle(String styleUri) async {}
  @override
  Future<void> resize(Size size, double devicePixelRatio) async {}
  @override
  Future<void> dispose() async => disposed = true;
}

class _FakePlatform extends MapLibreFlutterPlatform {
  _FakePlatformController? last;
  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => last = _FakePlatformController();
}

const _attachOptions = MapOptions(
  initialCamera: MapCamera(center: LatLng(1, 2), zoom: 3),
);

void main() {
  late _FakePlatform platform;
  setUp(() => MapLibreFlutterPlatform.instance = platform = _FakePlatform());

  test('getCamera before attach reports the default initial camera', () async {
    final c = MapLibreMapController();
    expect(c.isAttached, isFalse);
    final cam = await c.getCamera();
    expect(cam.center, const LatLng(0, 0));
  });

  test('attach binds a platform controller and forwards getCamera', () async {
    final c = MapLibreMapController();
    await c.attach(style: 's', options: _attachOptions);
    expect(c.isAttached, isTrue);
    final cam = await c.getCamera();
    expect(cam.center, const LatLng(10, 20)); // forwarded from the platform
    await c.dispose();
  });

  test('onReady completes once attached', () async {
    final c = MapLibreMapController();
    await c.attach(style: 's', options: _attachOptions);
    await c.onReady; // would hang the test if never completed
    await c.dispose();
  });

  test('attaching twice throws', () async {
    final c = MapLibreMapController();
    await c.attach(style: 's', options: _attachOptions);
    await expectLater(
      () => c.attach(style: 's', options: _attachOptions),
      throwsStateError,
    );
    await c.dispose();
  });

  test('attaching after dispose throws', () async {
    final c = MapLibreMapController();
    await c.dispose();
    expect(c.isDisposed, isTrue);
    await expectLater(
      () => c.attach(style: 's', options: _attachOptions),
      throwsStateError,
    );
  });

  test('dispose tears down the platform controller', () async {
    final c = MapLibreMapController();
    await c.attach(style: 's', options: _attachOptions);
    await c.dispose();
    expect(platform.last!.disposed, isTrue);
    expect(c.isDisposed, isTrue);
    expect(c.isAttached, isFalse);
  });

  test(
    'detach tears down the native map but leaves the controller reusable',
    () async {
      final c = MapLibreMapController();
      await c.attach(style: 's', options: _attachOptions);
      final first = platform.last!;
      await c.detach();
      expect(first.disposed, isTrue);
      expect(c.isAttached, isFalse);
      expect(c.isDisposed, isFalse);

      // Re-attach is allowed and binds a fresh native map.
      await c.attach(style: 's', options: _attachOptions);
      expect(c.isAttached, isTrue);
      expect(platform.last, isNot(same(first)));
      await c.dispose();
    },
  );
}
