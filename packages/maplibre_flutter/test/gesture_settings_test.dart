// MapGestureSettings: the container, the master switch, and the per-gesture
// toggles.
//
// Every test drives a REAL MapLibreMap for the reason gestures_over_overlay_test
// records at length: this widget also registers a global pointer route, so a
// stand-in wired like the handler can pass while the real map still moves.
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
  Future<void> resize(Size size, double devicePixelRatio) async {}
  @override
  Future<void> dispose() async {}
}

/// Records what reached the engine. Also a projector, because `MapLibreMap`
/// only builds its tap detector when the controller can project — without one,
/// "taps still work" would pass for the wrong reason.
class _RecordingController extends _FakeController
    implements
        MapLibreGestureHandler,
        MapLibreRotateHandler,
        MapLibreMapProjector {
  final List<Offset> moves = <Offset>[];
  final List<double> scales = <double>[];
  final List<double> rotations = <double>[];
  final List<double> pitches = <double>[];

  @override
  void moveBy(double dx, double dy) => moves.add(Offset(dx, dy));
  @override
  void scaleBy(double scale, double anchorX, double anchorY) =>
      scales.add(scale);
  @override
  void rotateBy(double degrees, double anchorX, double anchorY) =>
      rotations.add(degrees);
  @override
  void pitchBy(double degrees) => pitches.add(degrees);

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
  _RecordingController? last;
  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => last = _RecordingController();
}

const _style = 'https://demotiles.maplibre.org/style.json';
const _options = MapOptions(initialCamera: MapCamera(center: LatLng(0, 0)));

Future<_RecordingController> _pumpMap(
  WidgetTester tester, {
  MapGestureSettings gestures = const MapGestureSettings(),
  List<MapTapEvent>? taps,
}) async {
  final platform = _FakePlatform();
  MapLibreFlutterPlatform.instance = platform;
  await tester.pumpWidget(
    MaterialApp(
      home: MapLibreMap(
        style: _style,
        options: _options,
        gestures: gestures,
        onTap: taps?.add,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return platform.last!;
}

Future<void> _dragAcross(WidgetTester tester) async {
  final gesture = await tester.startGesture(const Offset(400, 300));
  await gesture.moveBy(const Offset(-60, 0));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _wheel(WidgetTester tester) async {
  final mouse = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(mouse.hover(const Offset(400, 300)));
  await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
  await tester.pump();
}

Future<void> _pinch(WidgetTester tester) async {
  final a = await tester.startGesture(const Offset(360, 300));
  final b = await tester.startGesture(const Offset(440, 300));
  await a.moveBy(const Offset(-60, 0));
  await b.moveBy(const Offset(60, 0));
  await tester.pump();
  await a.up();
  await b.up();
  await tester.pumpAndSettle();
}

void main() {
  group('the value type', () {
    test('has value equality, so didUpdateWidget can diff it', () {
      expect(
        const MapGestureSettings(),
        const MapGestureSettings(),
        reason: 'two default instances must be equal, not merely equivalent',
      );
      expect(
        const MapGestureSettings().hashCode,
        const MapGestureSettings().hashCode,
      );
      expect(
        const MapGestureSettings(zoomGesturesEnabled: false),
        isNot(const MapGestureSettings()),
      );
    });

    test('copyWith leaves unnamed fields alone', () {
      const all = MapGestureSettings();
      final one = all.copyWith(rotateGesturesEnabled: false);
      expect(one.rotateGesturesEnabled, isFalse);
      expect(one.tiltGesturesEnabled, isTrue);
      expect(one.scrollGesturesEnabled, isTrue);
      expect(one.interactive, isTrue);
      // Null means "leave alone", which is what makes the deprecated
      // pass-throughs on MapLibreMap expressible at all.
      expect(one.copyWith(rotateGesturesEnabled: null), one);
    });

    test('none disables everything', () {
      expect(MapGestureSettings.none.interactive, isFalse);
    });
  });

  group('interactive: false', () {
    testWidgets('the map does not pan, zoom or rotate', (tester) async {
      final map = await _pumpMap(tester, gestures: MapGestureSettings.none);
      await _dragAcross(tester);
      await _wheel(tester);
      await _pinch(tester);
      expect(map.moves, isEmpty);
      expect(map.scales, isEmpty);
      expect(map.rotations, isEmpty);
    });

    testWidgets('but taps still fire', (tester) async {
      // Every upstream SDK behaves this way, and it is the useful behaviour:
      // the reason to build a non-interactive map — a locator in a form, a
      // thumbnail in a list — is usually that tapping it opens a real one.
      final taps = <MapTapEvent>[];
      await _pumpMap(tester, gestures: MapGestureSettings.none, taps: taps);
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(taps, hasLength(1));
    });

    testWidgets('a default map DOES pan — the control', (tester) async {
      // Without this, every assertion above would pass on a map whose gesture
      // layer was never attached for some unrelated reason.
      final map = await _pumpMap(tester);
      await _dragAcross(tester);
      expect(map.moves, isNotEmpty);
    });
  });

  group('per-gesture toggles', () {
    testWidgets('scrollGesturesEnabled: false stops the pan, not the zoom', (
      tester,
    ) async {
      final map = await _pumpMap(
        tester,
        gestures: const MapGestureSettings(scrollGesturesEnabled: false),
      );
      await _dragAcross(tester);
      expect(map.moves, isEmpty);

      await _wheel(tester);
      expect(map.scales, isNotEmpty, reason: 'the toggles must be independent');
    });

    testWidgets('zoomGesturesEnabled: false stops the wheel and the pinch', (
      tester,
    ) async {
      final map = await _pumpMap(
        tester,
        gestures: const MapGestureSettings(zoomGesturesEnabled: false),
      );
      await _wheel(tester);
      await _pinch(tester);
      expect(map.scales, isEmpty);
    });

    testWidgets('zoomGesturesEnabled: false leaves the pan working', (
      tester,
    ) async {
      final map = await _pumpMap(
        tester,
        gestures: const MapGestureSettings(zoomGesturesEnabled: false),
      );
      await _dragAcross(tester);
      expect(map.moves, isNotEmpty);
    });

    testWidgets('a disabled pan does not glide on release either', (
      tester,
    ) async {
      // The drag is ignored and then the fling slides the map anyway — the
      // failure mode of gating the recogniser's updates but not its release.
      final map = await _pumpMap(
        tester,
        gestures: const MapGestureSettings(scrollGesturesEnabled: false),
      );
      final gesture = await tester.startGesture(const Offset(400, 300));
      for (var i = 0; i < 5; i++) {
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(map.moves, isEmpty);
    });
  });

  group('the deprecated props', () {
    testWidgets('still work, and win over the container', (tester) async {
      // The migration contract: code written against the old props keeps
      // behaving exactly as it did.
      final platform = _FakePlatform();
      MapLibreFlutterPlatform.instance = platform;
      await tester.pumpWidget(
        MaterialApp(
          home: MapLibreMap(
            style: _style,
            options: _options,
            // ignore: deprecated_member_use_from_same_package
            rotateGesturesEnabled: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final widget = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(widget.effectiveGestures.rotateGesturesEnabled, isFalse);
      expect(
        widget.effectiveGestures.tiltGesturesEnabled,
        isTrue,
        reason: 'an unset deprecated prop must not override the container',
      );
    });

    testWidgets('unset, the container decides', (tester) async {
      final platform = _FakePlatform();
      MapLibreFlutterPlatform.instance = platform;
      await tester.pumpWidget(
        MaterialApp(
          home: MapLibreMap(
            style: _style,
            options: _options,
            gestures: const MapGestureSettings(rotateGesturesEnabled: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final widget = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(widget.effectiveGestures.rotateGesturesEnabled, isFalse);
    });
  });
}
