import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

class _FakeController implements MapLibreMapController {
  @override
  MapLibreRenderHandle get renderHandle => const TextureHandle(textureId: 1);
  @override
  Future<void> get onReady => Future<void>.value();
  @override
  Future<MapCamera> getCamera() async => const MapCamera(center: LatLng(0, 0));
  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {}
  @override
  Future<void> setStyle(String styleUri) async {}
  @override
  Future<void> dispose() async {}
}

class _FakePlatform extends MapLibreFlutterPlatform {
  @override
  Future<MapLibreMapController> createMap(MapOptions options) async =>
      _FakeController();
}

/// Does not extend [MapLibreFlutterPlatform], so the token guard must reject it.
class _ImplementsPlatform implements MapLibreFlutterPlatform {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('instance throws until an implementation registers', () {
    expect(() => MapLibreFlutterPlatform.instance, throwsUnimplementedError);
  });

  test('a valid implementation can register and create a map', () async {
    MapLibreFlutterPlatform.instance = _FakePlatform();
    final controller = await MapLibreFlutterPlatform.instance.createMap(
      const MapOptions(
        styleUri: 'https://demotiles.maplibre.org/style.json',
        initialCamera: MapCamera(center: LatLng(0, 0)),
      ),
    );
    expect(controller.renderHandle, isA<TextureHandle>());
  });

  test(
    'token guard rejects an implementation that bypasses the base class',
    () {
      expect(
        () => MapLibreFlutterPlatform.instance = _ImplementsPlatform(),
        throwsA(isA<AssertionError>()),
      );
    },
  );

  test('LatLng and MapCamera have value equality', () {
    expect(const LatLng(1, 2), const LatLng(1, 2));
    expect(
      const MapCamera(center: LatLng(1, 2), zoom: 3),
      const MapCamera(center: LatLng(1, 2), zoom: 3),
    );
  });
}
