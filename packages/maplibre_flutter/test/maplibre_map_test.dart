import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

class _FakeController implements MapLibreMapController {
  _FakeController(this.renderHandle);
  @override
  final MapLibreRenderHandle renderHandle;
  bool disposed = false;
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
  Future<void> dispose() async => disposed = true;
}

class _FakePlatform extends MapLibreFlutterPlatform {
  _FakePlatform(this.handle);
  final MapLibreRenderHandle handle;
  _FakeController? lastController;
  @override
  Future<MapLibreMapController> createMap(MapOptions options) async =>
      lastController = _FakeController(handle);
}

const _options = MapOptions(
  styleUri: 'https://demotiles.maplibre.org/style.json',
  initialCamera: MapCamera(center: LatLng(0, 0)),
);

void main() {
  testWidgets('desktop handle renders a Texture', (tester) async {
    MapLibreFlutterPlatform.instance = _FakePlatform(
      const TextureHandle(textureId: 7),
    );

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MapLibreMap(options: _options),
      ),
    );
    await tester.pumpAndSettle();

    final texture = tester.widget<Texture>(find.byType(Texture));
    expect(texture.textureId, 7);
  });

  testWidgets('android PlatformViewHandle renders a PlatformViewLink', (
    tester,
  ) async {
    // Reset inline (not addTearDown): the framework's debug-var invariant check
    // runs at the end of the test body, before registered tearDowns.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      MapLibreFlutterPlatform.instance = _FakePlatform(
        const PlatformViewHandle(
          viewType: 'maplibre_flutter/android',
          creationParams: {'styleUri': 'https://example.com/style.json'},
        ),
      );

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: MapLibreMap(options: _options),
        ),
      );
      await tester.pumpAndSettle();

      final link = tester.widget<PlatformViewLink>(
        find.byType(PlatformViewLink),
      );
      expect(link.viewType, 'maplibre_flutter/android');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS PlatformViewHandle renders a UiKitView', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      MapLibreFlutterPlatform.instance = _FakePlatform(
        const PlatformViewHandle(
          viewType: 'maplibre_flutter/ios',
          creationParams: {'styleUri': 'https://example.com/style.json'},
        ),
      );

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: MapLibreMap(options: _options),
        ),
      );
      await tester.pumpAndSettle();

      final view = tester.widget<UiKitView>(find.byType(UiKitView));
      expect(view.viewType, 'maplibre_flutter/ios');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('onMapCreated fires and dispose tears down the controller', (
    tester,
  ) async {
    final platform = _FakePlatform(const TextureHandle(textureId: 1));
    MapLibreFlutterPlatform.instance = platform;

    MapLibreMapController? created;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MapLibreMap(options: _options, onMapCreated: (c) => created = c),
      ),
    );
    await tester.pumpAndSettle();
    expect(created, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(platform.lastController!.disposed, isTrue);
  });
}
