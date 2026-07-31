import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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

/// A controller that also draws 3D models, recording what the declarative
/// `models:` diff asked for.
class _FakeModelController extends _FakeController
    implements MapLibreModelHost {
  _FakeModelController(super.renderHandle);

  final List<MapLibreModel> added = <MapLibreModel>[];
  final List<MapLibreModel> updated = <MapLibreModel>[];
  final List<String> removed = <String>[];

  @override
  void addModel(MapLibreModel model) => added.add(model);
  @override
  void updateModel(MapLibreModel model) => updated.add(model);
  @override
  void removeModel(String id) => removed.add(id);
  @override
  int? modelPartCount(String assetPath) => 7;
  @override
  int? get renderedFrameCount => 0;
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

  /// Overrides which fake controller `createMap` returns, so a test can supply
  /// one with an extra capability (models, say).
  _FakeController Function(MapLibreRenderHandle)? controllerFactory;
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
    final factory = controllerFactory;
    return lastController = factory != null
        ? factory(handle)
        : gestures
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

  testWidgets('declarative models add, move in place, and remove', (
    tester,
  ) async {
    final platform = _FakePlatform(const TextureHandle(textureId: 9));
    platform.controllerFactory = _FakeModelController.new;
    MapLibreFlutterPlatform.instance = platform;
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);

    Widget map(List<MapLibreModel> models) => Directionality(
      textDirection: TextDirection.ltr,
      child: MapLibreMap(
        controller: controller,
        style: _style,
        options: _options,
        models: models,
      ),
    );

    const a = MapLibreModel(
      id: 'a',
      assetPath: '/tmp/a.glb',
      point: LatLng(1, 2),
    );
    const b = MapLibreModel(
      id: 'b',
      assetPath: '/tmp/b.glb',
      point: LatLng(3, 4),
    );

    await tester.pumpWidget(map(const <MapLibreModel>[a]));
    await tester.pumpAndSettle();
    final host = platform.lastController! as _FakeModelController;
    expect(host.added.map((m) => m.id), <String>['a']);

    // Same mesh, moved: must go through updateModel, NOT a reload — re-adding
    // would re-parse the whole .glb.
    await tester.pumpWidget(
      map(const <MapLibreModel>[
        MapLibreModel(id: 'a', assetPath: '/tmp/a.glb', point: LatLng(5, 6)),
        b,
      ]),
    );
    await tester.pumpAndSettle();
    expect(host.updated.map((m) => m.id), <String>['a']);
    expect(host.added.map((m) => m.id), <String>['a', 'b']);

    // Dropping one removes exactly that one.
    await tester.pumpWidget(map(const <MapLibreModel>[b]));
    await tester.pumpAndSettle();
    expect(host.removed, <String>['a']);
  });

  testWidgets('changing a model asset reloads instead of moving', (
    tester,
  ) async {
    final platform = _FakePlatform(const TextureHandle(textureId: 10));
    platform.controllerFactory = _FakeModelController.new;
    MapLibreFlutterPlatform.instance = platform;
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);

    Widget map(String asset) => Directionality(
      textDirection: TextDirection.ltr,
      child: MapLibreMap(
        controller: controller,
        style: _style,
        options: _options,
        models: <MapLibreModel>[
          MapLibreModel(id: 'a', assetPath: asset, point: const LatLng(1, 2)),
        ],
      ),
    );

    await tester.pumpWidget(map('/tmp/a.glb'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(map('/tmp/other.glb'));
    await tester.pumpAndSettle();

    final host = platform.lastController! as _FakeModelController;
    expect(host.added.length, 2, reason: 'a different mesh must be re-read');
    expect(host.updated, isEmpty);
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

  // The three tests below, together with the touch pinch above, pin the zoom
  // anchor for every input shape that can reach it. They exist because the two
  // anchor rules in this file were fixed independently and the second silently
  // defeated the first: commit 55ee9d4 froze the anchor for the Windows/Linux
  // trackpad focal drift, then commit 1963302 made the anchor follow the live
  // cursor for the Linux GTK focal offset — and since a real pinch always
  // produces pointer moves, the frozen anchor became dead code and a two-finger
  // touch pinch started chasing whichever finger moved last.
  //
  // Each case anchors at a DIFFERENT off-centre position, so no two can pass by
  // coincidence, and none is at the viewport centre — where a dropped anchor and
  // a correct one are indistinguishable.

  testWidgets('trackpad pinch zooms about the live cursor, not the focal', (
    tester,
  ) async {
    // Pins the Linux/GTK fix: a trackpad pinch's gesture focal carries a bogus
    // initial pan offset, so the cursor — not the focal — is the true anchor.
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

    const cursor = Offset(120, 90);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    // Two hovers, a few px apart: one large jump would look like GTK's
    // pointer warp and _onPanZoomStart would (correctly) undo it.
    await tester.sendEventToBinding(mouse.hover(cursor - const Offset(3, 2)));
    await tester.sendEventToBinding(mouse.hover(cursor));
    await tester.pump();

    // The pan-zoom gesture reports a focal far from the cursor — the bug being
    // guarded against — so the two are never confusable.
    const focal = Offset(500, 400);
    final pad = TestPointer(2, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pad.panZoomStart(focal));
    await tester.pump();
    await tester.sendEventToBinding(pad.panZoomUpdate(focal, scale: 2));
    await tester.pump();
    await tester.sendEventToBinding(pad.panZoomEnd());
    await tester.pump();

    expect(controller.scaleCalls, isNotEmpty, reason: 'trackpad pinch zooms');
    for (final call in controller.scaleCalls) {
      expect(
        call.anchor,
        cursor,
        reason: 'trackpad pinch must anchor on the cursor, not the focal',
      );
    }
  });

  testWidgets('scroll-wheel zoom anchors on the scroll event, not the cursor', (
    tester,
  ) async {
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

    // Hover somewhere, then scroll somewhere ELSE. If the anchor came from the
    // tracked cursor rather than the scroll event this reads (140, 110).
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(140, 110)));
    await tester.pump();
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(650, 470),
        scrollDelta: Offset(0, -120),
      ),
    );
    await tester.pump();

    expect(controller.scaleCalls, hasLength(1));
    expect(controller.scaleCalls.single.anchor, const Offset(650, 470));
    expect(
      controller.scaleCalls.single.scale,
      greaterThan(1),
      reason: 'scrolling up zooms in',
    );
  });

  testWidgets('a touch pinch anchors on one frozen point per gesture', (
    tester,
  ) async {
    // The narrow regression guard for the anchor rule itself: on a touchscreen
    // there is no cursor, only PointerMoveEvents from both fingers, so anchoring
    // on the last-moved pointer alternates between them every frame. Distinct
    // from the drift test above, which also asserts the no-pan-while-zooming
    // rule; this one isolates "exactly one anchor, and it is not a finger".
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

    // Start centroid (600, 200) — clear of both other cases' anchors and of the
    // viewport centre. Only the RIGHT finger spreads, so the centroid drifts
    // steadily rightward: an anchor that tracks the fingers ends up far from
    // where the pinch began, and a symmetric fixture could not tell the two
    // apart.
    const left = Offset(560, 200);
    const rightStart = Offset(640, 200);
    final f1 = await tester.startGesture(left, pointer: 11);
    final f2 = await tester.startGesture(rightStart, pointer: 12);
    await tester.pump();
    var right = rightStart;
    for (var i = 1; i <= 8; i++) {
      right = rightStart + Offset(30.0 * i, 0);
      await f2.moveTo(right);
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pump();

    expect(controller.scaleCalls, isNotEmpty, reason: 'touch pinch zooms');
    final anchors = controller.scaleCalls.map((c) => c.anchor).toSet();
    expect(anchors, hasLength(1), reason: 'one frozen anchor for the gesture');

    // The bug anchored on whichever finger moved last — here, the right one at
    // its ever-growing x. Assert the anchor is neither finger and stayed put
    // near the pinch's origin while the centroid drifted ~120px away.
    final anchor = anchors.single;
    expect(anchor.dx, isNot(closeTo(left.dx, 5)));
    expect(anchor.dx, isNot(closeTo(right.dx, 5)));
    expect(
      anchor.dx,
      closeTo((left.dx + rightStart.dx) / 2, 20),
      reason:
          'the anchor froze near the starting centroid, not the drifted one',
    );
  });
}
