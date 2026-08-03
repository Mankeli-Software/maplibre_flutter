// A marker is part of the MAP, not a panel over it.
//
// Every map anyone has used behaves this way: tapping a pin selects it, and
// dragging from a pin pans the map underneath. The distinction is not
// cosmetic — pins cover the interesting parts of a map, so if they swallow
// pans the map becomes unusable exactly where the user is looking.
//
// This is the counterpart to gestures_over_overlay_test.dart, which asserts the
// opposite for app-supplied overlays: a Card over the map MUST stop it. Both
// behaviours come from the same hit-test mechanism, so they have to be pinned
// together or fixing one silently breaks the other.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

class _Controller
    with MapLibreCameraTickNotifier
    implements
        MapLibreMapPlatformController,
        MapLibreGestureHandler,
        MapLibreMapProjector {
  final List<Offset> moves = <Offset>[];
  final List<double> scales = <double>[];

  @override
  final MapLibreRenderHandle renderHandle = const TextureHandle(textureId: 1);

  @override
  void moveBy(double dx, double dy) => moves.add(Offset(dx, dy));
  @override
  void scaleBy(double scale, double anchorX, double anchorY) =>
      scales.add(scale);

  // Ten logical pixels to the degree, so a marker can be placed at an exact
  // screen point while staying inside LatLng's +/-90 latitude assert.
  static const _pxPerDegree = 10.0;

  @override
  int project(List<LatLng> points, List<Offset> out, {List<bool>? visible}) {
    for (var i = 0; i < points.length; i++) {
      out[i] = Offset(
        points[i].longitude * _pxPerDegree,
        points[i].latitude * _pxPerDegree,
      );
    }
    visible?.fillRange(0, visible.length, true);
    return 1;
  }

  @override
  LatLng? unproject(Offset point) =>
      LatLng(point.dy / _pxPerDegree, point.dx / _pxPerDegree);

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
  Future<void> dispose() async => disposeCameraTick();
}

class _Platform extends MapLibreFlutterPlatform {
  _Controller? last;
  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => last = _Controller();
}

const _style = 'https://demotiles.maplibre.org/style.json';
const _options = MapOptions(initialCamera: MapCamera(center: LatLng(0, 0)));

/// A marker at (300, 200) whose child is OPAQUE — a coloured box, which is what
/// a real pin is. A transparent child would pass hits through by accident and
/// prove nothing.
Future<_Controller> _pumpMarkerMap(
  WidgetTester tester, {
  List<String>? tapped,
}) async {
  final platform = _Platform();
  MapLibreFlutterPlatform.instance = platform;
  await tester.pumpWidget(
    MaterialApp(
      home: MapLibreMap(
        style: _style,
        options: _options,
        markers: [
          MapLibreMarker(
            point: const LatLng(20, 30), // -> Offset(300, 200)
            child: GestureDetector(
              onTap: () => tapped?.add('pin'),
              child: Container(width: 40, height: 40, color: Colors.red),
            ),
          ),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
  return platform.last!;
}

void main() {
  testWidgets('dragging FROM a marker pans the map', (tester) async {
    final map = await _pumpMarkerMap(tester);
    // SEVERAL steps, unlike gesture_settings_test's deliberately minimal one.
    // The marker carries the app's own tap recogniser, so down-on-a-pin puts a
    // tap and the map's scale recogniser in the arena together, and the scale
    // one is not declared the winner until the pointer has clearly moved. That
    // is the arena doing its job — it is what makes tap-selects-pin and
    // drag-pans-map distinguishable at all — and a real drag emits a move per
    // frame. It is not the map adding a recogniser of its own, which is what
    // that other file guards against.
    final gesture = await tester.startGesture(const Offset(300, 200));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      map.moves,
      isNotEmpty,
      reason:
          'a pin covers the map; if it swallows pans the map is unusable '
          'exactly where the user is looking',
    );
  });

  testWidgets('the wheel over a marker still zooms the map', (tester) async {
    final map = await _pumpMarkerMap(tester);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(300, 200)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
    await tester.pump();

    expect(map.scales, isNotEmpty);
  });

  testWidgets('a pinch centred on a marker still zooms', (tester) async {
    final map = await _pumpMarkerMap(tester);
    final a = await tester.startGesture(const Offset(290, 200));
    final b = await tester.startGesture(const Offset(310, 200));
    await a.moveBy(const Offset(-60, 0));
    await b.moveBy(const Offset(60, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    expect(map.scales, isNotEmpty);
  });

  testWidgets('but TAPPING a marker still hits the marker, not the map', (
    tester,
  ) async {
    // The other half, and the reason this cannot be fixed by simply making the
    // overlay ignore pointers: the marker's own tap must keep working.
    final tapped = <String>[];
    final map = await _pumpMarkerMap(tester, tapped: tapped);
    await tester.tapAt(const Offset(300, 200));
    await tester.pumpAndSettle();

    expect(tapped, ['pin']);
    expect(map.moves, isEmpty);
  });

  testWidgets('a tap on empty map does not reach the marker', (tester) async {
    final tapped = <String>[];
    await _pumpMarkerMap(tester, tapped: tapped);
    await tester.tapAt(const Offset(80, 80));
    await tester.pumpAndSettle();

    expect(tapped, isEmpty);
  });
}
