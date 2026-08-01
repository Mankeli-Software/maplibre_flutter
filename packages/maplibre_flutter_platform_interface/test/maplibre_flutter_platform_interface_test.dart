import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

class _FakeController implements MapLibreMapPlatformController {
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
  Future<void> resize(Size size, double devicePixelRatio) async {}
  @override
  Future<void> dispose() async {}
}

class _FakePlatform extends MapLibreFlutterPlatform {
  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => _FakeController();
}

/// Does not extend [MapLibreFlutterPlatform], so the token guard must reject it.
class _ImplementsPlatform implements MapLibreFlutterPlatform {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A minimal projector built on the shared tick mixin, to exercise the
/// [MapLibreMapProjector] contract + camera-tick notifications.
class _FakeProjector
    with MapLibreCameraTickNotifier
    implements MapLibreMapProjector {
  @override
  int project(List<LatLng> points, List<Offset> out, {List<bool>? visible}) {
    for (var i = 0; i < points.length; i++) {
      out[i] = Offset(points[i].longitude, points[i].latitude);
      if (visible != null) visible[i] = true;
    }
    return 1;
  }

  @override
  LatLng? unproject(Offset point) => LatLng(point.dy, point.dx);
}

void main() {
  test('instance throws until an implementation registers', () {
    expect(() => MapLibreFlutterPlatform.instance, throwsUnimplementedError);
  });

  test('a valid implementation can register and create a map', () async {
    MapLibreFlutterPlatform.instance = _FakePlatform();
    final controller = await MapLibreFlutterPlatform.instance.createMap(
      style: 'https://demotiles.maplibre.org/style.json',
      options: const MapOptions(initialCamera: MapCamera(center: LatLng(0, 0))),
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

  group('MapLibreMapProjector', () {
    test('project fills outputs and unproject inverts it', () {
      final p = _FakeProjector();
      final out = List<Offset>.filled(2, Offset.zero);
      final visible = List<bool>.filled(2, false);
      final gen = p.project(
        const [LatLng(10, 20), LatLng(-5, 33)],
        out,
        visible: visible,
      );
      expect(gen, 1);
      expect(out[0], const Offset(20, 10)); // (lng, lat)
      expect(out[1], const Offset(33, -5));
      expect(visible, [true, true]);
      expect(p.unproject(const Offset(20, 10)), const LatLng(10, 20));
    });

    test('camera tick notifies listeners until removed/disposed', () {
      final p = _FakeProjector();
      var ticks = 0;
      void listener() => ticks++;
      p.addListener(listener);

      p.notifyCameraChanged();
      p.notifyCameraChanged();
      expect(ticks, 2);

      p.removeListener(listener);
      p.notifyCameraChanged();
      expect(ticks, 2, reason: 'removed listener should not fire');

      p.disposeCameraTick(); // must not throw
    });

    // The engine runs easeTo/flyTo/fitBounds itself and calls back only at the
    // END, so a camera that ticks solely where Dart applies a step goes silent
    // for the whole flight — which is exactly how widget markers came to freeze
    // mid-fly-to while engine-drawn ones tracked.
    testWidgets('an engine animation ticks for its whole duration', (
      tester,
    ) async {
      final p = _FakeProjector();
      var ticks = 0;
      p.addListener(() => ticks++);

      final flight = Completer<void>();
      final wrapped = p.tickWhileAnimating(flight.future);

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        ticks,
        greaterThan(3),
        reason: 'roughly a tick a frame while the engine is flying',
      );

      final duringFlight = ticks;
      flight.complete();
      await wrapped;
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        ticks,
        duringFlight + 1,
        reason:
            'one final tick on landing, then silence — a ticker left '
            'running would repaint every frame forever',
      );

      p.disposeCameraTick();
    });

    testWidgets('overlapping flights keep ticking until the LAST one lands', (
      tester,
    ) async {
      final p = _FakeProjector();
      var ticks = 0;
      p.addListener(() => ticks++);

      // A flyTo superseded by a second one: mbgl fires the first's finish fn
      // when the second installs itself, so both resolve. Stopping on the first
      // would strand the overlay for the rest of the flight that is actually
      // running.
      final first = Completer<void>();
      final second = Completer<void>();
      p.tickWhileAnimating(first.future);
      p.tickWhileAnimating(second.future);

      first.complete();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = ticks;
      await tester.pump(const Duration(milliseconds: 100));
      expect(ticks, greaterThan(mid), reason: 'the second flight is still up');

      second.complete();
      await tester.pump();
      final landed = ticks;
      await tester.pump(const Duration(milliseconds: 500));
      expect(ticks, landed, reason: 'both landed, so it stops');

      p.disposeCameraTick();
    });

    testWidgets('disposing mid-flight cancels the ticker', (tester) async {
      final p = _FakeProjector();
      final flight = Completer<void>();
      p.tickWhileAnimating(flight.future);
      await tester.pump(const Duration(milliseconds: 50));

      p.disposeCameraTick();
      // A live Timer here would outlive the controller and tick a disposed
      // ChangeNotifier, which throws.
      await tester.pump(const Duration(milliseconds: 200));
      flight.complete();
      await tester.pump(const Duration(milliseconds: 200));
    });
  });
}
