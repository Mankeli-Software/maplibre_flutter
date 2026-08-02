import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/painting.dart' show EdgeInsets;

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
  Stream<void> get onIdle => const Stream<void>.empty();
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

/// A tier that can project and run engine camera commands, for panBy.
class _CameraController extends _FakePlatformController
    with MapLibreCameraTickNotifier
    implements MapLibreMapProjector, MapLibreCameraCommands {
  /// Where the projector claims the camera centre is on screen.
  Offset centreOnScreen = const Offset(100, 100);

  /// The screen point the controller asked to unproject — the whole point of
  /// this fake, since panBy's sign lives in that arithmetic.
  Offset? unprojectedFrom;

  final List<CameraOptions> eased = <CameraOptions>[];

  @override
  int project(List<LatLng> points, List<Offset> out, {List<bool>? visible}) {
    for (var i = 0; i < points.length; i++) {
      out[i] = centreOnScreen;
    }
    return 1;
  }

  @override
  LatLng? unproject(Offset point) {
    unprojectedFrom = point;
    return const LatLng(11, 22);
  }

  @override
  Future<void> jumpTo(CameraOptions camera) async {}
  @override
  Future<void> easeTo(
    CameraOptions camera, {
    CameraAnimation? animation,
  }) async {
    eased.add(camera);
  }

  @override
  Future<void> flyTo(
    CameraOptions camera, {
    CameraAnimation? animation,
  }) async {}
  @override
  Future<void> fitBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    double? bearing,
    double? pitch,
    CameraTransition transition = CameraTransition.ease,
    CameraAnimation? animation,
  }) async {}
  @override
  Future<CameraOptions?> cameraForBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    double? bearing,
    double? pitch,
  }) async => null;
  @override
  Future<LatLngBounds?> getBounds() async => null;
  @override
  Future<void> setCameraConstraints(MapCameraConstraints constraints) async {}
  @override
  Future<MapCameraConstraints?> getCameraConstraints() async => null;
  @override
  Future<void> setConstrainToBounds({required bool wholeViewport}) async {}
  @override
  Future<void> stopCamera() async {}
}

class _CameraPlatform extends MapLibreFlutterPlatform {
  _CameraController? last;
  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => last = _CameraController();
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
    final cam = await c.camera.getCamera();
    expect(cam.center, const LatLng(0, 0));
  });

  test(
    'attach binds a platform controller and forwards camera reads',
    () async {
      final c = MapLibreMapController();
      await c.attach(styleUri: 's', options: _attachOptions);
      expect(c.isAttached, isTrue);
      final cam = await c.camera.getCamera();
      expect(cam.center, const LatLng(10, 20)); // forwarded from the platform
      await c.dispose();
    },
  );

  test('onReady completes once attached', () async {
    final c = MapLibreMapController();
    await c.attach(styleUri: 's', options: _attachOptions);
    await c.onReady; // would hang the test if never completed
    await c.dispose();
  });

  test('attaching twice throws', () async {
    final c = MapLibreMapController();
    await c.attach(styleUri: 's', options: _attachOptions);
    await expectLater(
      () => c.attach(styleUri: 's', options: _attachOptions),
      throwsStateError,
    );
    await c.dispose();
  });

  test('attaching after dispose throws', () async {
    final c = MapLibreMapController();
    await c.dispose();
    expect(c.isDisposed, isTrue);
    await expectLater(
      () => c.attach(styleUri: 's', options: _attachOptions),
      throwsStateError,
    );
  });

  test('dispose tears down the platform controller', () async {
    final c = MapLibreMapController();
    await c.attach(styleUri: 's', options: _attachOptions);
    await c.dispose();
    expect(platform.last!.disposed, isTrue);
    expect(c.isDisposed, isTrue);
    expect(c.isAttached, isFalse);
  });

  test(
    'detach tears down the native map but leaves the controller reusable',
    () async {
      final c = MapLibreMapController();
      await c.attach(styleUri: 's', options: _attachOptions);
      final first = platform.last!;
      await c.detach();
      expect(first.disposed, isTrue);
      expect(c.isAttached, isFalse);
      expect(c.isDisposed, isFalse);

      // Re-attach is allowed and binds a fresh native map.
      await c.attach(styleUri: 's', options: _attachOptions);
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

      await c.attach(styleUri: 's', options: _attachOptions);
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
      await c.attach(styleUri: 's', options: _attachOptions);
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

      await c.attach(styleUri: 's', options: _attachOptions);
      final platform = eventful.last!;
      expect(c.capabilities.events, isTrue);

      await c.detach();
      platform.errors.add(const MapRenderError('after detach'));
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty, reason: 'the pipe is cut on detach');

      await c.dispose();
    });
  });

  // panBy has a sign convention, and the one that matters is that it agrees
  // with a DRAG: dragging right moves the content right, so panBy(+x) must too.
  // MapLibreGestureHandler.moveBy takes the finger delta unchanged, and that
  // path is verified on hardware — this pins the new verb to it.
  test('panBy moves the content the way a drag would', () async {
    final platform = _CameraPlatform();
    MapLibreFlutterPlatform.instance = platform;
    final c = MapLibreMapController();
    await c.attach(styleUri: 's', options: _attachOptions);

    await c.camera.panBy(const Offset(40, 0), duration: Duration.zero);

    // The controller must unproject the point 40 px to the LEFT of the centre:
    // moving THAT point to the centre shifts the content right, which is what
    // dragging right does.
    final asked = platform.last!.unprojectedFrom;
    expect(asked, isNotNull, reason: 'panBy has to ask where it is going');
    expect(asked!.dx, 60, reason: '100 - 40');
    expect(asked.dy, 100, reason: 'no vertical component');
    expect(platform.last!.eased.single.center, const LatLng(11, 22));
    await c.dispose();
  });

  test(
    'a tier without camera commands falls back rather than throwing',
    () async {
      // The web tiers have no MapLibreCameraCommands; jumpTo must still work, by
      // resolving the partial camera against the current one.
      MapLibreFlutterPlatform.instance = _FakePlatform();
      final c = MapLibreMapController();
      await c.attach(styleUri: 's', options: _attachOptions);
      expect(c.capabilities.cameraCommands, isFalse);
      await c.camera.jumpTo(const CameraOptions(zoom: 12));
      // fitBounds has no fallback — there is nothing sensible to compute without
      // the engine — so it must no-op rather than throw.
      await c.camera.fitBounds(
        const LatLngBounds(southwest: LatLng(1, 2), northeast: LatLng(3, 4)),
      );
      expect(await c.camera.getBounds(), isNull);
      await c.dispose();
    },
  );

  group('camera lifecycle and reason', () {
    test('a programmatic move brackets itself with a reason', () async {
      MapLibreFlutterPlatform.instance = _CameraPlatform();
      final c = MapLibreMapController();
      final starts = <Set<MapCameraChangeReason>>[];
      final ends = <Set<MapCameraChangeReason>>[];
      c.onCameraMoveStart.listen(starts.add);
      c.onCameraMoveEnd.listen(ends.add);
      await c.attach(styleUri: 's', options: _attachOptions);

      expect(c.isMoving, isFalse);
      await c.camera.easeTo(const CameraOptions(zoom: 8));
      await Future<void>.delayed(Duration.zero);

      expect(starts, hasLength(1));
      expect(starts.single, {MapCameraChangeReason.programmatic});
      expect(starts.single.isProgrammatic, isTrue);
      expect(starts.single.isGesture, isFalse);
      expect(ends, hasLength(1));
      expect(c.isMoving, isFalse, reason: 'the move is over');
      await c.dispose();
    });

    test('resetNorth reports Apple\'s dedicated reason too', () async {
      MapLibreFlutterPlatform.instance = _CameraPlatform();
      final c = MapLibreMapController();
      final starts = <Set<MapCameraChangeReason>>[];
      c.onCameraMoveStart.listen(starts.add);
      await c.attach(styleUri: 's', options: _attachOptions);

      await c.camera.resetNorth();
      await Future<void>.delayed(Duration.zero);

      // The one "programmatic" move a USER asked for, which is why Apple gives
      // it its own value rather than folding it into programmatic.
      expect(starts.first, contains(MapCameraChangeReason.resetNorth));
      expect(starts.first, contains(MapCameraChangeReason.programmatic));
      expect(starts.first.isRotation, isTrue);
      await c.dispose();
    });

    test('gesture reasons drive isMoving / isZooming / isRotating', () async {
      MapLibreFlutterPlatform.instance = _CameraPlatform();
      final c = MapLibreMapController();
      await c.attach(styleUri: 's', options: _attachOptions);

      // This is what the gesture layer calls.
      c.reportCameraMove(const {
        MapCameraChangeReason.gesturePinch,
      }, ended: false);
      expect(c.isMoving, isTrue);
      expect(c.isZooming, isTrue);
      expect(c.isRotating, isFalse);
      expect(c.movingBecause.isGesture, isTrue);

      // A twisting pinch is BOTH — which is why the payload is a Set.
      c.reportCameraMove(const {
        MapCameraChangeReason.gesturePinch,
        MapCameraChangeReason.gestureRotate,
      }, ended: false);
      expect(c.isZooming, isTrue);
      expect(c.isRotating, isTrue);

      c.reportCameraMove(const {
        MapCameraChangeReason.gesturePinch,
      }, ended: true);
      expect(c.isMoving, isFalse);
      expect(c.isZooming, isFalse);
      await c.dispose();
    });

    test('an end with nothing started is ignored', () async {
      MapLibreFlutterPlatform.instance = _CameraPlatform();
      final c = MapLibreMapController();
      final ends = <Set<MapCameraChangeReason>>[];
      c.onCameraMoveEnd.listen(ends.add);
      await c.attach(styleUri: 's', options: _attachOptions);

      c.reportCameraMove(const {MapCameraChangeReason.gesturePan}, ended: true);
      await Future<void>.delayed(Duration.zero);
      expect(ends, isEmpty, reason: 'no spurious end for a move never started');
      await c.dispose();
    });
  });

  group('style specification', () {
    test('a URL and an inline document pass straight through', () async {
      final platform = _FakePlatform();
      MapLibreFlutterPlatform.instance = platform;
      final c = MapLibreMapController();

      // Only asset:// is rewritten here; the engine itself sniffs a leading {
      // and calls loadJSON instead of loadURL.
      await c.attach(
        styleUri: 'https://example.test/s.json',
        options: _attachOptions,
      );
      await c.dispose();

      final c2 = MapLibreMapController();
      await c2.attach(
        styleUri: '{"version":8,"sources":{},"layers":[]}',
        options: _attachOptions,
      );
      await c2.dispose();
    });

    test('a missing asset names the key rather than failing later', () async {
      MapLibreFlutterPlatform.instance = _FakePlatform();
      final c = MapLibreMapController();
      addTearDown(c.dispose);

      // The alternative is handing the engine a string it cannot parse, which
      // surfaces as a blank map and an error about JSON — pointing nowhere near
      // the actual mistake, a key missing from pubspec.yaml.
      await expectLater(
        c.attach(
          styleUri: 'asset://assets/no/such/style.json',
          options: _attachOptions,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('assets/no/such/style.json'), contains('pubspec')),
          ),
        ),
      );
    });
  });

  // 6.7.
  group('project / unproject', () {
    test('a tier with no projector returns null rather than (0,0)', () {
      MapLibreFlutterPlatform.instance = _FakePlatform();
      final c = MapLibreMapController();
      addTearDown(c.dispose);
      // Offset.zero would be a plausible-looking wrong answer that an overlay
      // would happily draw at the top-left corner.
      expect(c.project(const LatLng(60.45, 22.27)), isNull);
      expect(c.projectAll(const [LatLng(60.45, 22.27)]), isNull);
      expect(c.unproject(Offset.zero), isNull);
    });

    test('projectAll of an empty list is null, not an empty list', () {
      MapLibreFlutterPlatform.instance = _FakePlatform();
      final c = MapLibreMapController();
      addTearDown(c.dispose);
      expect(c.projectAll(const []), isNull);
    });
  });

  // 8.1.
  group('MapLibreSettings', () {
    test('a tier with no cache reports FALSE rather than pretending', () {
      MapLibreFlutterPlatform.instance = _FakePlatform();
      // The base implementation returns false, and that is the point: silently
      // doing nothing is how an app ships believing it has a tile cache.
      expect(MapLibreSettings.configure(cachePath: '/tmp/x.db'), isFalse);
      expect(MapLibreSettings.cachePath, isNull);
    });

    test('the call forwards every argument to the platform', () {
      final platform = _RecordingSettingsPlatform();
      MapLibreFlutterPlatform.instance = platform;
      MapLibreSettings.configure(
        cachePath: '/tmp/tiles.db',
        maximumCacheBytes: 1024,
        apiKey: 'secret',
        tileServer: MapLibreTileServer.mapTiler,
      );
      expect(platform.lastCachePath, '/tmp/tiles.db');
      expect(platform.lastMaxBytes, 1024);
      expect(platform.lastApiKey, 'secret');
      // The key and the server are one setting wearing two names: without the
      // server the engine never reads the key at all, so a configure that drops
      // it on the floor is the bug this argument exists to fix.
      expect(platform.lastTileServer, MapLibreTileServer.mapTiler);
    });
  });
}

/// Records what MapLibreSettings passed down.
class _RecordingSettingsPlatform extends _FakePlatform {
  String? lastCachePath;
  int? lastMaxBytes;
  String? lastApiKey;
  MapLibreTileServer? lastTileServer;

  @override
  bool configureResources({
    String? cachePath,
    int? maximumCacheBytes,
    String? apiKey,
    MapLibreTileServer? tileServer,
  }) {
    lastCachePath = cachePath;
    lastMaxBytes = maximumCacheBytes;
    lastApiKey = apiKey;
    lastTileServer = tileServer;
    return true;
  }
}
