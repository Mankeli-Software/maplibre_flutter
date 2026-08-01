import 'dart:math' as math;

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
    implements MapLibreGestureHandler, MapLibreRotateHandler {
  _FakeGestureController(super.renderHandle);
  final List<Offset> moveCalls = <Offset>[]; // (dx, dy)
  final List<({double scale, Offset anchor})> scaleCalls =
      <({double scale, Offset anchor})>[];
  final List<({double degrees, Offset anchor})> rotateCalls =
      <({double degrees, Offset anchor})>[];
  final List<double> pitchCalls = <double>[];
  @override
  void moveBy(double dx, double dy) => moveCalls.add(Offset(dx, dy));
  @override
  void scaleBy(double scale, double anchorX, double anchorY) =>
      scaleCalls.add((scale: scale, anchor: Offset(anchorX, anchorY)));
  @override
  void rotateBy(double degrees, double anchorX, double anchorY) =>
      rotateCalls.add((degrees: degrees, anchor: Offset(anchorX, anchorY)));
  @override
  void pitchBy(double degrees) => pitchCalls.add(degrees);
}

/// Pans and zooms but offers NO rotate capability — the graceful-degradation
/// case that justifies MapLibreRotateHandler being a separate interface.
class _FakeGestureOnlyController extends _FakeController
    implements MapLibreGestureHandler {
  _FakeGestureOnlyController(super.renderHandle);
  final List<Offset> moveCalls = <Offset>[];
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

  // --- rotate / tilt ---------------------------------------------------------
  //
  // The recognizers are where rotation is most likely to be silently wrong, and
  // none of it can be checked on hardware for four of the five tiers. Each case
  // below targets one specific way it can break.

  Future<_FakeGestureController> pumpGestureMap(
    WidgetTester tester, {
    bool rotate = true,
    bool tilt = true,
  }) async {
    final platform = _FakePlatform(
      const TextureHandle(textureId: 9),
      gestures: true,
    );
    MapLibreFlutterPlatform.instance = platform;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MapLibreMap(
          style: _style,
          options: _options,
          rotateGesturesEnabled: rotate,
          tiltGesturesEnabled: tilt,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return platform.lastController! as _FakeGestureController;
  }

  /// Twists two fingers about [centre] by [degrees], in steps.
  Future<void> twist(
    WidgetTester tester,
    Offset centre,
    double degrees, {
    double radius = 100,
    int steps = 10,
  }) async {
    Offset at(double angleDeg, double sign) {
      final r = angleDeg * math.pi / 180;
      return centre + Offset(math.cos(r), math.sin(r)) * radius * sign;
    }

    final f1 = await tester.startGesture(at(0, 1), pointer: 21);
    final f2 = await tester.startGesture(at(0, -1), pointer: 22);
    await tester.pump();
    for (var i = 1; i <= steps; i++) {
      final a = degrees * i / steps;
      await f1.moveTo(at(a, 1));
      await f2.moveTo(at(a, -1));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pump();
  }

  testWidgets('a twist below the deadzone does not rotate, but still zooms', (
    tester,
  ) async {
    final c = await pumpGestureMap(tester);
    // 4 degrees, under the 8 degree deadzone, while the fingers also spread.
    const centre = Offset(400, 300);
    final f1 = await tester.startGesture(
      centre - const Offset(100, 0),
      pointer: 31,
    );
    final f2 = await tester.startGesture(
      centre + const Offset(100, 0),
      pointer: 32,
    );
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      final r = 4 * i / 8 * math.pi / 180;
      final len = 100 + 8.0 * i;
      await f1.moveTo(centre - Offset(math.cos(r), math.sin(r)) * len);
      await f2.moveTo(centre + Offset(math.cos(r), math.sin(r)) * len);
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pump();

    expect(
      c.rotateCalls,
      isEmpty,
      reason:
          'a small incidental twist during an ordinary pinch must not turn '
          'the map — that is what the deadzone is for',
    );
    expect(c.scaleCalls, isNotEmpty, reason: 'the pinch must still zoom');
  });

  testWidgets('a twist past the deadzone rotates with the CORRECT SIGN', (
    tester,
  ) async {
    final c = await pumpGestureMap(tester);
    // Fingers sweep CLOCKWISE on screen (increasing angle in Flutter's y-down
    // space). Assert against that absolute direction, never a round trip: a
    // sign error is symmetric and survives any there-and-back check.
    await twist(tester, const Offset(400, 300), 40);

    expect(c.rotateCalls, isNotEmpty, reason: 'a 40 degree twist must rotate');
    final total = c.rotateCalls.fold<double>(0, (a, r) => a + r.degrees);
    expect(
      total,
      greaterThan(0),
      reason:
          'a CLOCKWISE on-screen twist must emit POSITIVE degrees; the '
          'engine shim turns that into a decreasing bearing',
    );
    // Deadzone consumed, so the emitted total is the travel past it, not the
    // full 40 degrees.
    expect(total, lessThan(40));
    expect(total, greaterThan(20));
  });

  testWidgets('an anticlockwise twist emits negative degrees', (tester) async {
    final c = await pumpGestureMap(tester);
    await twist(tester, const Offset(400, 300), -40);
    final total = c.rotateCalls.fold<double>(0, (a, r) => a + r.degrees);
    expect(total, lessThan(0));
  });

  testWidgets('the rotate anchor is one frozen point for the whole gesture', (
    tester,
  ) async {
    final c = await pumpGestureMap(tester);
    await twist(tester, const Offset(300, 500), 40);
    final anchors = c.rotateCalls.map((r) => r.anchor).toSet();
    expect(
      anchors,
      hasLength(1),
      reason:
          'rotating about a moving anchor makes the map lurch; it must use '
          'the same frozen anchor the pinch zoom does',
    );
  });

  // --- Camera-change reason ------------------------------------------------
  //
  // The gesture layer is the ONLY thing in the stack that can tell these apart:
  // mbgl reports just {Immediate, Animated}. So these assertions are the whole
  // proof that the reason is real rather than guessed.

  /// Pumps a gesture map bound to [controller], so its reason streams can be
  /// observed. The plain [pumpGestureMap] lets the widget own its controller.
  Future<_FakeGestureController> pumpGestureMapWith(
    WidgetTester tester,
    MapLibreMapController controller,
  ) async {
    final platform = _FakePlatform(
      const TextureHandle(textureId: 19),
      gestures: true,
    );
    MapLibreFlutterPlatform.instance = platform;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MapLibreMap(
          controller: controller,
          style: _style,
          options: _options,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return platform.lastController! as _FakeGestureController;
  }

  testWidgets('a drag reports gesturePan, bracketed by start and end', (
    tester,
  ) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);
    final starts = <Set<MapCameraChangeReason>>[];
    final ends = <Set<MapCameraChangeReason>>[];
    controller.onCameraMoveStart.listen(starts.add);
    controller.onCameraMoveEnd.listen(ends.add);
    await pumpGestureMapWith(tester, controller);

    await tester.drag(find.byType(MapLibreMap), const Offset(60, 40));
    await tester.pumpAndSettle();

    expect(starts, isNotEmpty, reason: 'a drag must report a start');
    expect(starts.first, contains(MapCameraChangeReason.gesturePan));
    expect(starts.first.isGesture, isTrue);
    expect(
      starts.first.isProgrammatic,
      isFalse,
      reason: 'a finger is not app code',
    );
    expect(ends, isNotEmpty, reason: 'and an end when the finger lifts');
    expect(controller.isMoving, isFalse);
  });

  testWidgets('a twisting pinch reports BOTH pinch and rotate', (tester) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);
    final starts = <Set<MapCameraChangeReason>>[];
    controller.onCameraMoveStart.listen(starts.add);
    await pumpGestureMapWith(tester, controller);

    // Two fingers separating AND twisting: the case that makes the payload a
    // Set rather than a single value.
    const centre = Offset(400, 400);
    final f1 = await tester.startGesture(
      centre - const Offset(60, 0),
      pointer: 61,
    );
    final f2 = await tester.startGesture(
      centre + const Offset(60, 0),
      pointer: 62,
    );
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      final angle = i * 0.06; // well past the rotate deadzone
      final r = 60.0 + i * 6; // and separating, so it zooms too
      final dx = math.cos(angle) * r;
      final dy = math.sin(angle) * r;
      await f1.moveTo(centre - Offset(dx, dy));
      await f2.moveTo(centre + Offset(dx, dy));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    final union = starts.fold<Set<MapCameraChangeReason>>(
      <MapCameraChangeReason>{},
      (acc, r) => acc..addAll(r),
    );
    expect(union, contains(MapCameraChangeReason.gesturePinch));
    expect(union, contains(MapCameraChangeReason.gestureRotate));
    expect(union.isZoom, isTrue);
    expect(union.isRotation, isTrue);
  });

  testWidgets('a shove reports gestureTilt, not pan', (tester) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);
    final starts = <Set<MapCameraChangeReason>>[];
    controller.onCameraMoveStart.listen(starts.add);
    await pumpGestureMapWith(tester, controller);

    const left = Offset(350, 400);
    const right = Offset(450, 400);
    final f1 = await tester.startGesture(left, pointer: 71);
    final f2 = await tester.startGesture(right, pointer: 72);
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      final dy = -8.0 * i;
      await f1.moveTo(left + Offset(0, dy));
      await f2.moveTo(right + Offset(0, dy));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    final union = starts.fold<Set<MapCameraChangeReason>>(
      <MapCameraChangeReason>{},
      (acc, r) => acc..addAll(r),
    );
    expect(
      union,
      contains(MapCameraChangeReason.gestureTilt),
      reason: 'a shove is a tilt, and only this layer can say so',
    );
    expect(union.isTilt, isTrue);
  });

  testWidgets('a two-finger vertical shove tilts and does NOT pan', (
    tester,
  ) async {
    final c = await pumpGestureMap(tester);
    const left = Offset(350, 400);
    const right = Offset(450, 400);
    final f1 = await tester.startGesture(left, pointer: 41);
    final f2 = await tester.startGesture(right, pointer: 42);
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      final dy = -8.0 * i; // upward, together, separation unchanged
      await f1.moveTo(left + Offset(0, dy));
      await f2.moveTo(right + Offset(0, dy));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pump();

    expect(c.pitchCalls, isNotEmpty, reason: 'a shove must tilt');
    expect(
      c.pitchCalls.fold<double>(0, (a, b) => a + b),
      greaterThan(0),
      reason: 'fingers moving UP must INCREASE pitch, as in the native SDKs',
    );
    // Some pan before the shove is recognised is unavoidable and correct: any
    // threshold-based detector watches a little travel before committing, and
    // the SDK is no different. What matters is that panning STOPS once the
    // shove latches — without the mode latch the map would be dragged the whole
    // 64px of the gesture rather than the ~12px it takes to recognise it.
    final pannedDy = c.moveCalls.fold<double>(0, (a, m) => a + m.dy.abs());
    expect(
      pannedDy,
      lessThan(20),
      reason:
          'the map must stop panning once the shove latches; the fingers '
          'travel 64px, so a total near that means the latch never fired',
    );
  });

  testWidgets('a shove whose fingers are not perfectly parallel still tilts', (
    tester,
  ) async {
    // The test above moves both fingers by IDENTICAL deltas, which pins
    // ScaleUpdateDetails.rotation at exactly 0.0 — so it passed even while the
    // shove deadzone compared the RAW WRAPPED rotation (CLAUDE.md §11: Flutter
    // derives it from atan2 differences, so the first update of any two-finger
    // gesture can report ~-6.2 rad). No real pair of fingers is parallel to the
    // pixel, so that bug made shove-to-tilt unusable on a device while every
    // test stayed green. One pixel of divergence is enough to catch it.
    final c = await pumpGestureMap(tester);
    const left = Offset(350, 400);
    const right = Offset(450, 400);
    final f1 = await tester.startGesture(left, pointer: 61);
    final f2 = await tester.startGesture(right, pointer: 62);
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      final dy = -8.0 * i;
      await f1.moveTo(left + Offset(0, dy - 1)); // 1px out of step
      await f2.moveTo(right + Offset(0, dy));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pump();

    expect(
      c.pitchCalls,
      isNotEmpty,
      reason:
          'a shove must tilt even when the fingers are a pixel out of step; '
          'thresholding the raw wrapped rotation rejects it outright',
    );
    expect(
      c.pitchCalls.fold<double>(0, (a, b) => a + b),
      greaterThan(0),
      reason: 'fingers moving UP must INCREASE pitch',
    );
  });

  testWidgets('a two-finger horizontal pan still pans and does NOT tilt', (
    tester,
  ) async {
    // The regression guard for the shove detector. A shove and a two-finger pan
    // are both "focal moves with scale ~1 and rotation ~0", so a detector built
    // on focalDelta.dy would silently break panning — which works today.
    final c = await pumpGestureMap(tester);
    const left = Offset(350, 400);
    const right = Offset(450, 400);
    final f1 = await tester.startGesture(left, pointer: 51);
    final f2 = await tester.startGesture(right, pointer: 52);
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      final dx = 10.0 * i;
      await f1.moveTo(left + Offset(dx, 0));
      await f2.moveTo(right + Offset(dx, 0));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pump();

    expect(c.moveCalls, isNotEmpty, reason: 'a two-finger pan must still pan');
    expect(c.pitchCalls, isEmpty, reason: 'a horizontal pan is not a shove');
  });

  testWidgets('a secondary-button drag rotates and tilts, without panning', (
    tester,
  ) async {
    // Without this a mouse-only user cannot rotate at all, on any desktop tier.
    final c = await pumpGestureMap(tester);
    final mouse = await tester.startGesture(
      const Offset(400, 300),
      pointer: 61,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await mouse.moveTo(const Offset(460, 260));
    await tester.pump();
    await mouse.up();
    await tester.pump();

    expect(
      c.rotateCalls.fold<double>(0, (a, r) => a + r.degrees),
      greaterThan(0),
      reason: 'dragging RIGHT turns the content clockwise, as in gl-js',
    );
    expect(
      c.pitchCalls.fold<double>(0, (a, b) => a + b),
      greaterThan(0),
      reason: 'dragging UP tilts toward the horizon',
    );
    expect(
      c.moveCalls,
      isEmpty,
      reason:
          'a secondary drag must not also pan; onScaleStart fires for it '
          'too, which is why this path lives on the raw Listener',
    );
  });

  testWidgets('rotateGesturesEnabled: false suppresses only rotation', (
    tester,
  ) async {
    final c = await pumpGestureMap(tester, rotate: false);
    await twist(tester, const Offset(400, 300), 40);
    expect(c.rotateCalls, isEmpty);
    expect(
      c.scaleCalls,
      isNotEmpty,
      reason: 'disabling rotation must not disable zoom',
    );
  });

  testWidgets('tiltGesturesEnabled: false suppresses only tilt', (
    tester,
  ) async {
    final c = await pumpGestureMap(tester, tilt: false);
    const left = Offset(350, 400);
    const right = Offset(450, 400);
    final f1 = await tester.startGesture(left, pointer: 71);
    final f2 = await tester.startGesture(right, pointer: 72);
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      await f1.moveTo(left + Offset(0, -8.0 * i));
      await f2.moveTo(right + Offset(0, -8.0 * i));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pump();
    expect(c.pitchCalls, isEmpty);
  });

  testWidgets('a controller without MapLibreRotateHandler still pans and zooms', (
    tester,
  ) async {
    // The graceful-degradation proof that justifies rotate/tilt being a
    // SEPARATE capability rather than two more members on MapLibreGestureHandler.
    final platform = _FakePlatform(const TextureHandle(textureId: 9))
      ..controllerFactory = _FakeGestureOnlyController.new;
    MapLibreFlutterPlatform.instance = platform;
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MapLibreMap(style: _style, options: _options),
      ),
    );
    await tester.pumpAndSettle();
    final c = platform.lastController! as _FakeGestureOnlyController;

    expect(_gestureLayer(), findsOneWidget, reason: 'still gets the layer');
    await twist(tester, const Offset(400, 300), 40);
    expect(
      c.scaleCalls,
      isNotEmpty,
      reason: 'a tier with no rotate capability must still zoom, not throw',
    );
  });

  // The user-reported bug: scrolling over a widget sitting ON TOP of the map
  // zoomed the map anyway. Two independent causes, so two tests against the
  // REAL gesture layer rather than a stand-in.
  testWidgets('the wheel still zooms when nothing above claims it', (
    tester,
  ) async {
    final platform = _FakePlatform(
      const TextureHandle(textureId: 1),
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

    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(120, 90)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
    await tester.pump();
    // Pin the anchor too: a scroll whose position was lost would still zoom,
    // and the overlay test below depends on the position being honoured.
    expect(controller.scaleCalls.single.anchor, const Offset(120, 90));

    // The control. Routing through PointerSignalResolver must not cost the map
    // its own wheel zoom — a fix that made the map ignore every scroll would
    // pass the test below and be worse than the bug.
    expect(controller.scaleCalls, hasLength(1));
    expect(controller.scaleCalls.single.scale, greaterThan(1));
  });

  // NOTE: the overlay-vs-map arbitration tests live in
  // test/gestures_over_overlay_test.dart — they are a matrix over real overlay
  // widgets and belong together, not scattered through this file.
}
