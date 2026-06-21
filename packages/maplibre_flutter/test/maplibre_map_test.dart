import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

class _FakeController implements MapLibreMapPlatformController {
  _FakeController(this.renderHandle);
  @override
  final MapLibreRenderHandle renderHandle;
  bool disposed = false;
  String? lastStyle;
  @override
  Future<void> get onReady => Future<void>.value();
  @override
  Future<MapCamera> getCamera() async => const MapCamera(center: LatLng(0, 0));
  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {}
  @override
  Future<void> setStyle(String styleUri) async => lastStyle = styleUri;
  @override
  Future<void> resize(Size size, double devicePixelRatio) async {}
  @override
  Future<void> dispose() async => disposed = true;
}

/// A desktop-style controller that also drives gestures in Dart. Records the
/// gesture calls so tests can assert what the widget gesture layer forwarded.
class _FakeGestureController extends _FakeController
    implements MapLibreGestureHandler {
  _FakeGestureController(super.renderHandle);
  final List<Offset> moveCalls = <Offset>[]; // (dx, dy)
  final List<({double scale, Offset anchor})> scaleCalls =
      <({double scale, Offset anchor})>[];
  @override
  void moveBy(double dx, double dy) => moveCalls.add(Offset(dx, dy));
  @override
  void scaleBy(double scale, double anchorX, double anchorY) =>
      scaleCalls.add((scale: scale, anchor: Offset(anchorX, anchorY)));
}

class _FakePlatform extends MapLibreFlutterPlatform {
  _FakePlatform(this.handle, {this.gestures = false});
  final MapLibreRenderHandle handle;
  final bool gestures;
  _FakeController? lastController;
  String? lastInitialStyle;
  int createCount = 0;

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async {
    createCount++;
    lastInitialStyle = style;
    return lastController = gestures
        ? _FakeGestureController(handle)
        : _FakeController(handle);
  }
}

const _style = 'https://demotiles.maplibre.org/style.json';
const _options = MapOptions(initialCamera: MapCamera(center: LatLng(0, 0)));

Finder _gestureLayer() => find.ancestor(
  of: find.byType(Texture),
  matching: find.byType(GestureDetector),
);

void main() {
  testWidgets('desktop handle renders a Texture and passes the style', (
    tester,
  ) async {
    final platform = _FakePlatform(const TextureHandle(textureId: 7));
    MapLibreFlutterPlatform.instance = platform;

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MapLibreMap(style: _style, options: _options),
      ),
    );
    await tester.pumpAndSettle();

    final texture = tester.widget<Texture>(find.byType(Texture));
    expect(texture.textureId, 7);
    expect(platform.lastInitialStyle, _style);
  });

  testWidgets('android PlatformViewHandle renders a PlatformViewLink', (
    tester,
  ) async {
    // Reset inline (not addTearDown): the framework's debug-var invariant check
    // runs at the end of the test body, before registered tearDowns.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      MapLibreFlutterPlatform.instance = _FakePlatform(
        const PlatformViewHandle(viewType: 'maplibre_flutter/android'),
      );

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: MapLibreMap(style: _style, options: _options),
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
        const PlatformViewHandle(viewType: 'maplibre_flutter/ios'),
      );

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: MapLibreMap(style: _style, options: _options),
        ),
      );
      await tester.pumpAndSettle();

      final view = tester.widget<UiKitView>(find.byType(UiKitView));
      expect(view.viewType, 'maplibre_flutter/ios');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('an internal controller is disposed when the widget unmounts', (
    tester,
  ) async {
    final platform = _FakePlatform(const TextureHandle(textureId: 1));
    MapLibreFlutterPlatform.instance = platform;

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MapLibreMap(style: _style, options: _options),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(platform.lastController!.disposed, isTrue);
  });

  testWidgets(
    'a provided controller survives unmount (detached, not disposed) and reattaches',
    (tester) async {
      final platform = _FakePlatform(const TextureHandle(textureId: 2));
      MapLibreFlutterPlatform.instance = platform;
      final controller = MapLibreMapController();

      Widget map() => Directionality(
        textDirection: TextDirection.ltr,
        child: MapLibreMap(
          controller: controller,
          style: _style,
          options: _options,
        ),
      );

      await tester.pumpWidget(map());
      await tester.pumpAndSettle();
      expect(controller.isAttached, isTrue);

      // Unmount: the native map is torn down, but the controller object is not
      // disposed (we did not create it) and becomes reusable.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(platform.lastController!.disposed, isTrue);
      expect(controller.isDisposed, isFalse);
      expect(controller.isAttached, isFalse);

      // Re-mounting with the same controller attaches a fresh native map.
      await tester.pumpWidget(map());
      await tester.pumpAndSettle();
      expect(controller.isAttached, isTrue);
      expect(platform.createCount, 2);

      controller.dispose();
    },
  );

  testWidgets('changing the style prop pushes setStyle without recreating', (
    tester,
  ) async {
    final platform = _FakePlatform(const TextureHandle(textureId: 3));
    MapLibreFlutterPlatform.instance = platform;
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);

    Widget map(String style) => Directionality(
      textDirection: TextDirection.ltr,
      child: MapLibreMap(
        controller: controller,
        style: style,
        options: _options,
      ),
    );

    await tester.pumpWidget(map(_style));
    await tester.pumpAndSettle();

    const newStyle = 'https://tiles.openfreemap.org/styles/liberty';
    await tester.pumpWidget(map(newStyle));
    await tester.pumpAndSettle();

    expect(platform.lastController!.lastStyle, newStyle);
    expect(platform.createCount, 1); // declarative style change, no recreate
  });

  testWidgets('a gesture-capable controller gets the Dart gesture layer', (
    tester,
  ) async {
    // Desktop controller implements MapLibreGestureHandler -> gesture layer.
    MapLibreFlutterPlatform.instance = _FakePlatform(
      const TextureHandle(textureId: 4),
      gestures: true,
    );
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MapLibreMap(style: _style, options: _options),
      ),
    );
    await tester.pumpAndSettle();
    expect(_gestureLayer(), findsOneWidget);
  });

  testWidgets('a non-gesture controller gets no Dart gesture layer', (
    tester,
  ) async {
    MapLibreFlutterPlatform.instance = _FakePlatform(
      const TextureHandle(textureId: 5),
    );
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MapLibreMap(style: _style, options: _options),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Texture), findsOneWidget);
    expect(_gestureLayer(), findsNothing);
  });

  testWidgets(
    'pinch zoom freezes its anchor and does not pan from focal drift',
    (tester) async {
      // Regression: a trackpad pinch on Windows/Linux arrives as a two-finger
      // scale gesture whose focal centroid DRIFTS as the fingers spread (macOS
      // reports the stable cursor). The desktop gesture layer must zoom about a
      // FROZEN anchor and not pan by the drift — otherwise the map slides away
      // from the cursor while zooming.
      final platform = _FakePlatform(
        const TextureHandle(textureId: 9),
        gestures: true,
      );
      MapLibreFlutterPlatform.instance = platform;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: MapLibreMap(style: _style, options: _options),
        ),
      );
      await tester.pumpAndSettle();
      final controller = platform.lastController! as _FakeGestureController;

      // Two fingers start ~(400,300) (centroid), 100px apart, then spread to
      // 300px (3x zoom) while the centroid slides up-left to ~(250,150).
      final g1 = await tester.startGesture(const Offset(350, 300), pointer: 1);
      final g2 = await tester.startGesture(const Offset(450, 300), pointer: 2);
      await tester.pump();
      const steps = 12;
      for (var i = 1; i <= steps; i++) {
        final t = i / steps;
        final cx = 400 + (250 - 400) * t;
        final cy = 300 + (150 - 300) * t;
        final half = (100 + (300 - 100) * t) / 2;
        await g1.moveTo(Offset(cx - half, cy));
        await g2.moveTo(Offset(cx + half, cy));
        await tester.pump();
      }
      await g1.up();
      await g2.up();
      await tester.pump();

      // The pinch zoomed.
      expect(controller.scaleCalls, isNotEmpty, reason: 'pinch should zoom');
      // Every zoom is about the SAME anchor (frozen), not the drifting focal.
      final anchors = controller.scaleCalls.map((c) => c.anchor).toSet();
      expect(
        anchors.length,
        1,
        reason: 'zoom anchor must be frozen, not follow the drifting centroid',
      );
      // The frozen anchor stayed near the START centroid (~400,300), not the
      // drifted end (~250,150).
      final a = anchors.single;
      expect(
        a.dx,
        greaterThan(330),
        reason: 'anchor near start x, not drifted',
      );
      expect(
        a.dy,
        greaterThan(260),
        reason: 'anchor near start y, not drifted',
      );
      // No meaningful pan applied from the focal drift during the zoom.
      final totalPan = controller.moveCalls.fold<double>(
        0,
        (s, m) => s + m.dx.abs() + m.dy.abs(),
      );
      expect(
        totalPan,
        lessThan(20),
        reason: 'focal drift must not become a pan while zooming',
      );
    },
  );
}
