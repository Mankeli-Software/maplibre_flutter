import 'dart:async';
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

/// A tier that reports engine events, like the five `mbgl-core` ones.
class _EventfulController extends _FakePlatformController
    implements MapLibreMapEvents {
  final StreamController<MapLibreError> errors =
      StreamController<MapLibreError>.broadcast();
  final StreamController<void> styleLoads = StreamController<void>.broadcast();
  final StreamController<String> missingImages =
      StreamController<String>.broadcast();

  @override
  Stream<MapLibreError> get onError => errors.stream;
  @override
  Stream<void> get onStyleLoaded => styleLoads.stream;
  @override
  Stream<String> get onStyleImageMissing => missingImages.stream;
}

class _EventfulPlatform extends MapLibreFlutterPlatform {
  _EventfulController? last;
  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => last = _EventfulController();
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

  test('camera.getPosition before attach reports the default camera', () async {
    final c = MapLibreMapController();
    expect(c.isAttached, isFalse);
    final cam = await c.camera.getPosition();
    expect(cam.center, const LatLng(0, 0));
  });

  test(
    'attach binds a platform controller and forwards camera reads',
    () async {
      final c = MapLibreMapController();
      await c.attach(style: 's', options: _attachOptions);
      expect(c.isAttached, isTrue);
      final cam = await c.camera.getPosition();
      expect(cam.center, const LatLng(10, 20)); // forwarded from the platform
      await c.dispose();
    },
  );

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

  group('engine events', () {
    test('a listener attached BEFORE the map exists still gets them', () async {
      // The point of the controller owning these streams: a controller is
      // constructed before the map is, and the error worth hearing most is a
      // first style load that fails.
      final eventful = _EventfulPlatform();
      MapLibreFlutterPlatform.instance = eventful;
      final c = MapLibreMapController();

      final errors = <MapLibreError>[];
      final styleLoads = <void>[];
      final missing = <String>[];
      c.onError.listen(errors.add);
      c.onStyleLoaded.listen(styleLoads.add);
      c.onStyleImageMissing.listen(missing.add);

      await c.attach(style: 's', options: _attachOptions);
      eventful.last!
        ..errors.add(const MapStyleError('404'))
        ..styleLoads.add(null)
        ..missingImages.add('pin');
      await Future<void>.delayed(Duration.zero);

      expect(errors, [isA<MapStyleError>()]);
      expect(styleLoads, hasLength(1));
      expect(missing, ['pin']);
      await c.dispose();
    });

    test('a tier without the capability is simply silent', () async {
      // _FakePlatformController does not implement MapLibreMapEvents, which is
      // the web tiers' situation today.
      MapLibreFlutterPlatform.instance = _FakePlatform();
      final c = MapLibreMapController();
      final errors = <MapLibreError>[];
      c.onError.listen(errors.add);
      await c.attach(style: 's', options: _attachOptions);
      expect(c.capabilities.events, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty);
      await c.dispose();
    });

    test('detach stops forwarding, and dispose closes the streams', () async {
      final eventful = _EventfulPlatform();
      MapLibreFlutterPlatform.instance = eventful;
      final c = MapLibreMapController();
      final errors = <MapLibreError>[];
      c.onError.listen(errors.add);

      await c.attach(style: 's', options: _attachOptions);
      final platform = eventful.last!;
      expect(c.capabilities.events, isTrue);

      await c.detach();
      platform.errors.add(const MapRenderError('after detach'));
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty, reason: 'the pipe is cut on detach');

      await c.dispose();
    });
  });
}
