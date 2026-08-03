// The user-reported bug: gestures made over a widget sitting ON TOP of the map
// drove the map anyway — the wheel zoomed it, two trackpad fingers panned it.
//
// The fix is that the map no longer overrides Flutter's own arbitration, so
// NOTHING has to be added to the widget tree: an overlay that hit-tests
// opaquely (every Card, panel and button below) already stops the map, exactly
// as it stops a tap. There used to be an `AbsorbPointerSignal` wrapper for this;
// it is deleted, and these tests are what say it is not needed.
//
// Every test drives a REAL MapLibreMap. That is not incidental: the predecessor
// of this file tested a stand-in wired like the map's scroll HANDLER, and
// passed while the real widget still zoomed — because the real widget also
// registers a global pointer route, and arbitration is a property of everything
// registered, not of the handler.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

class _FakeController implements MapLibreMapPlatformController {
  @override
  final MapLibreRenderHandle renderHandle = const TextureHandle(textureId: 1);
  @override
  Future<void> get onReady => Future<void>.value();
  @override
  Future<MapCamera> getCamera() async => const MapCamera(center: LatLng(0, 0));
  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {}
  @override
  Future<void> setStyle(String styleUri) async {}
  @override
  Future<void> resize(Size size) async {}
  @override
  Future<void> dispose() async {}
}

/// Also a projector — NOT optional here. `MapLibreMap` only builds its tap
/// detector when the controller can project (a tier that cannot has no LatLng
/// to report), so a fake without one makes every "the overlay ate the tap"
/// assertion pass for the wrong reason: there was no tap detector to begin
/// with. The control test at the bottom is what caught that.
class _FakeGestureController extends _FakeController
    implements MapLibreGestureHandler, MapLibreMapProjector {
  final List<Offset> moveCalls = <Offset>[];
  final List<Offset> scaleAnchors = <Offset>[];
  @override
  void moveBy(double dx, double dy) => moveCalls.add(Offset(dx, dy));
  @override
  void scaleBy(double scale, double anchorX, double anchorY) =>
      scaleAnchors.add(Offset(anchorX, anchorY));

  // A hundred logical pixels to the degree, so an 800x600 test surface stays
  // inside the +/-90 latitude LatLng asserts on.
  static const _degreesPerPixel = 0.01;

  @override
  int project(List<LatLng> points, List<Offset> out, {List<bool>? visible}) {
    for (var i = 0; i < points.length; i++) {
      out[i] = Offset(
        points[i].longitude / _degreesPerPixel,
        points[i].latitude / _degreesPerPixel,
      );
    }
    visible?.fillRange(0, visible.length, true);
    return 1;
  }

  @override
  LatLng? unproject(Offset point) =>
      LatLng(point.dy * _degreesPerPixel, point.dx * _degreesPerPixel);

  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _FakePlatform extends MapLibreFlutterPlatform {
  _FakeGestureController? last;
  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => last = _FakeGestureController();
}

const _style = 'https://demotiles.maplibre.org/style.json';
const _options = MapOptions(initialCamera: MapCamera(center: LatLng(0, 0)));

/// Pumps a map with [overlay] on top of it and returns the recording
/// controller. The overlay is placed at (100, 100) and sized by the caller.
/// [taps] counts `MapLibreMap.onTap` firings — the map's tap detector is a
/// different widget from its gesture layer, so it has to be asserted separately.
Future<_FakeGestureController> _pumpMapUnder(
  WidgetTester tester,
  Widget overlay, {
  List<MapTapEvent>? taps,
}) async {
  final platform = _FakePlatform();
  MapLibreFlutterPlatform.instance = platform;
  await tester.pumpWidget(
    MaterialApp(
      home: Stack(
        fit: StackFit.expand,
        children: [
          MapLibreMap(style: _style, options: _options, onTap: taps?.add),
          Positioned(left: 100, top: 100, child: overlay),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
  return platform.last!;
}

Future<void> _wheelAt(WidgetTester tester, Offset at) async {
  final mouse = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(mouse.hover(at));
  await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
  await tester.pump();
}

Future<void> _trackpadPanAt(WidgetTester tester, Offset at) async {
  final pad = TestPointer(2, PointerDeviceKind.trackpad);
  await tester.sendEventToBinding(pad.hover(at));
  await tester.sendEventToBinding(pad.panZoomStart(at));
  await tester.sendEventToBinding(
    pad.panZoomUpdate(at, pan: const Offset(40, 0)),
  );
  await tester.sendEventToBinding(pad.panZoomEnd());
  await tester.pump();
}

void main() {
  // The shapes an app actually puts over a map. Each is asserted at its OWN
  // centre, via `tester.getCenter` — a 48-pixel IconButton placed at (100, 100)
  // does not reach a hardcoded (200, 200), and probing the empty space beside it
  // reads as a pass while proving nothing.
  final cases = <String, (Widget, Type)>{
    'a Card': (
      const SizedBox(width: 200, height: 200, child: Card(child: Text('x'))),
      Card,
    ),
    'a coloured Container': (
      Container(width: 200, height: 200, color: Colors.blue),
      Container,
    ),
    'an IconButton': (
      IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
      IconButton,
    ),
    'an ElevatedButton': (
      ElevatedButton(onPressed: () {}, child: const Text('go')),
      ElevatedButton,
    ),
    'a ListView': (
      SizedBox(
        width: 200,
        height: 200,
        child: ListView(children: const [SizedBox(height: 400)]),
      ),
      ListView,
    ),
  };

  cases.forEach((name, spec) {
    final (widget, target) = spec;
    testWidgets('$name stops every gesture reaching the map — unwrapped', (
      tester,
    ) async {
      final taps = <MapTapEvent>[];
      final map = await _pumpMapUnder(tester, widget, taps: taps);
      final at = tester.getCenter(find.byType(target).last);

      await _wheelAt(tester, at);
      expect(map.scaleAnchors, isEmpty, reason: '$name must eat the wheel');

      await _trackpadPanAt(tester, at);
      expect(map.moveCalls, isEmpty, reason: '$name must eat two fingers');

      await tester.dragFrom(at, const Offset(60, 0));
      await tester.pump();
      expect(map.moveCalls, isEmpty, reason: '$name must eat a drag');

      await tester.tapAt(at);
      await tester.pump();
      expect(taps, isEmpty, reason: '$name must eat a tap');
    });
  });

  // The control. A fix that made the map ignore every gesture would pass every
  // assertion above and be far worse than the bug.
  testWidgets('the bare map still zooms, pans and reports taps', (
    tester,
  ) async {
    final taps = <MapTapEvent>[];
    final map = await _pumpMapUnder(
      tester,
      const SizedBox.shrink(), // nothing over the point we probe
      taps: taps,
    );

    await _wheelAt(tester, const Offset(500, 400));
    expect(map.scaleAnchors, <Offset>[const Offset(500, 400)]);

    await _trackpadPanAt(tester, const Offset(500, 400));
    expect(map.moveCalls, isNotEmpty);

    await tester.tapAt(const Offset(500, 400));
    await tester.pump();
    expect(taps, hasLength(1));
  });

  // Deliberate, and the one shape that still passes through. A box that paints
  // nothing and claims nothing is asking to be transparent to input; Flutter
  // treats it that way for taps and we match. The fix for an app that wants
  // otherwise is `HitTestBehavior.opaque` on its own widget — plain Flutter, no
  // map-specific wrapper.
  testWidgets('an unpainted SizedBox does NOT stop the map', (tester) async {
    final map = await _pumpMapUnder(
      tester,
      const SizedBox(width: 200, height: 200),
    );
    await _wheelAt(tester, const Offset(200, 200));
    expect(map.scaleAnchors, hasLength(1));
  });

  testWidgets('...and HitTestBehavior.opaque is all it takes to fix that', (
    tester,
  ) async {
    final map = await _pumpMapUnder(
      tester,
      const SizedBox(
        width: 200,
        height: 200,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          child: SizedBox.expand(),
        ),
      ),
    );
    await _wheelAt(tester, const Offset(200, 200));
    expect(map.scaleAnchors, isEmpty);
  });

  testWidgets('a scrollable over the map scrolls itself, not the map', (
    tester,
  ) async {
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final map = await _pumpMapUnder(
      tester,
      SizedBox(
        width: 200,
        height: 200,
        child: ListView.builder(
          controller: scrollController,
          itemCount: 100,
          itemBuilder: (_, i) => SizedBox(height: 40, child: Text('$i')),
        ),
      ),
    );

    // DOWN, not up: a list already at offset 0 cannot scroll up, and asserting
    // "it moved" against a clamp proves nothing.
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(200, 200)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pump();

    expect(scrollController.offset, greaterThan(0));
    expect(map.scaleAnchors, isEmpty);
  });
}
