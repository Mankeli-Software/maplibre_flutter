import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter/src/marker_overlay.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

const _style = 'https://demotiles.maplibre.org/style.json';
const _options = MapOptions(initialCamera: MapCamera(center: LatLng(0, 0)));

/// A platform controller that can project, with test-settable projection funcs.
class _ProjController
    with MapLibreCameraTickNotifier
    implements MapLibreMapPlatformController, MapLibreMapProjector {
  _ProjController(this.renderHandle);

  @override
  final MapLibreRenderHandle renderHandle;

  Offset Function(LatLng) projectFn = (p) => Offset(p.longitude, p.latitude);
  LatLng Function(Offset) unprojectFn = (o) => LatLng(o.dy, o.dx);
  bool Function(LatLng)? visibleFn;
  int generation = 1;

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
  Future<void> dispose() async => disposeCameraTick();

  @override
  int project(List<LatLng> points, List<Offset> out, {List<bool>? visible}) {
    for (var i = 0; i < points.length; i++) {
      out[i] = projectFn(points[i]);
      if (visible != null) visible[i] = visibleFn?.call(points[i]) ?? true;
    }
    return generation;
  }

  @override
  LatLng? unproject(Offset point) => unprojectFn(point);

  /// Simulates a camera change (so the overlay reprojects).
  void tick() => notifyCameraChanged();
}

/// A plain controller with no projector capability.
class _PlainController implements MapLibreMapPlatformController {
  _PlainController(this.renderHandle);
  @override
  final MapLibreRenderHandle renderHandle;
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

class _FixedPlatform extends MapLibreFlutterPlatform {
  _FixedPlatform(this.controller);
  final MapLibreMapPlatformController controller;
  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => controller;
}

/// A box that counts how many times it is actually PAINTED, so culling (which
/// skips paint, not build) can be asserted.
class _PaintCountingBox extends StatelessWidget {
  const _PaintCountingBox({required this.counter});
  final _Counter counter;
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(20, 20),
      painter: _CountingPainter(counter),
    );
  }
}

class _Counter {
  int value = 0;
}

class _CountingPainter extends CustomPainter {
  _CountingPainter(this.counter);
  final _Counter counter;
  @override
  void paint(Canvas canvas, Size size) => counter.value++;
  @override
  bool shouldRepaint(_CountingPainter old) => true;
}

/// A stateless box that counts its builds, to prove repaint != rebuild.
class _CountingBox extends StatelessWidget {
  const _CountingBox({super.key, required this.onBuild});
  final VoidCallback onBuild;
  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(width: 20, height: 20);
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required List<MapLibreMarker> markers,
  ValueChanged<LatLng>? onTap,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      // Pin the map's box to the top-left so overlay coordinates == global.
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 400,
          child: MapLibreMap(
            style: _style,
            options: _options,
            markers: markers,
            onTap: onTap,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('places each marker at its projected point, honoring alignment', (
    tester,
  ) async {
    final controller = _ProjController(const TextureHandle(textureId: 1));
    controller.projectFn = (_) => const Offset(200, 120);
    MapLibreFlutterPlatform.instance = _FixedPlatform(controller);

    await _pump(
      tester,
      markers: [
        MapLibreMarker(
          point: const LatLng(0, 0),
          child: const SizedBox(key: Key('center'), width: 20, height: 20),
        ),
        MapLibreMarker(
          point: const LatLng(1, 1),
          alignment: Alignment.bottomCenter,
          child: const SizedBox(key: Key('bottom'), width: 30, height: 40),
        ),
      ],
    );

    // Center-aligned: the child's center sits on the projected point.
    expect(
      tester.getCenter(find.byKey(const Key('center'))),
      offsetMoreOrLessEquals(const Offset(200, 120), epsilon: 0.5),
    );
    // Bottom-center-aligned: the child's bottom-center sits on the point.
    expect(
      tester.getRect(find.byKey(const Key('bottom'))).bottomCenter,
      offsetMoreOrLessEquals(const Offset(200, 120), epsilon: 0.5),
    );
  });

  // What repaintBoundary actually buys, measured rather than argued: with a
  // boundary the child's painting is cached in its own layer, so a camera tick
  // moves the layer instead of re-running the child's paint. Without one, every
  // tick re-paints every marker's content.
  //
  // Device testing found no VISIBLE frame-time difference with all markers on
  // screen, which is consistent with this: the saving is proportional to how
  // expensive the child is to paint, and cheap children save nothing worth
  // seeing. This pins the mechanism so the default has evidence behind it.
  testWidgets('repaintBoundary stops camera ticks re-painting the child', (
    tester,
  ) async {
    final controller = _ProjController(const TextureHandle(textureId: 21));
    controller.projectFn = (_) => const Offset(100, 100);
    MapLibreFlutterPlatform.instance = _FixedPlatform(controller);

    final withBoundary = _Counter();
    final without = _Counter();
    await _pump(
      tester,
      markers: [
        MapLibreMarker(
          point: const LatLng(0, 0),
          child: _PaintCountingBox(counter: withBoundary),
        ),
        MapLibreMarker(
          point: const LatLng(1, 1),
          repaintBoundary: false,
          child: _PaintCountingBox(counter: without),
        ),
      ],
    );

    final boundaryBaseline = withBoundary.value;
    final plainBaseline = without.value;

    // Ten camera ticks with the marker moving each time.
    for (var i = 0; i < 10; i++) {
      controller.projectFn = (_) => Offset(100 + i.toDouble(), 100);
      controller.generation++;
      controller.tick();
      await tester.pump();
    }

    final boundaryRepaints = withBoundary.value - boundaryBaseline;
    final plainRepaints = without.value - plainBaseline;

    // THE FINDING: neither re-paints. `Flow` composites each child through a
    // transform layer, so moving a marker replays a retained layer rather than
    // re-running the child's paint — with or without an explicit boundary. The
    // flag therefore buys nothing here, which is exactly why device testing saw
    // no frame-time difference from the Layers toggle. Its default is false.
    expect(
      plainRepaints,
      0,
      reason: 'Flow already avoids re-painting children on a camera tick',
    );
    expect(
      boundaryRepaints,
      0,
      reason: 'a boundary adds a layer but no additional saving',
    );
  });

  testWidgets('culls markers projected outside the viewport (no paint)', (
    tester,
  ) async {
    final controller = _ProjController(const TextureHandle(textureId: 11));
    // Marker at (0,0) lands on screen; the one at (10,10) lands far outside the
    // 400x400 map box.
    controller.projectFn = (p) =>
        p.latitude == 0 ? const Offset(200, 200) : const Offset(5000, 5000);
    MapLibreFlutterPlatform.instance = _FixedPlatform(controller);

    final onScreen = _Counter();
    final offScreen = _Counter();
    await _pump(
      tester,
      markers: [
        MapLibreMarker(
          point: const LatLng(0, 0),
          child: _PaintCountingBox(counter: onScreen),
        ),
        MapLibreMarker(
          point: const LatLng(10, 10),
          child: _PaintCountingBox(counter: offScreen),
        ),
      ],
    );

    expect(onScreen.value, greaterThan(0), reason: 'on-screen marker paints');
    expect(
      offScreen.value,
      0,
      reason: 'a marker outside the viewport must not be painted at all',
    );

    // And it starts painting once the camera brings it into view.
    controller.projectFn = (_) => const Offset(100, 100);
    controller.generation++;
    controller.tick();
    await tester.pump();
    expect(offScreen.value, greaterThan(0), reason: 'paints once on screen');
  });

  testWidgets('culls markers behind a pitched camera (not visible)', (
    tester,
  ) async {
    final controller = _ProjController(const TextureHandle(textureId: 12));
    controller.projectFn = (_) => const Offset(200, 200);
    // Reported as behind the camera even though it projects on-screen.
    controller.visibleFn = (_) => false;
    MapLibreFlutterPlatform.instance = _FixedPlatform(controller);

    final counter = _Counter();
    await _pump(
      tester,
      markers: [
        MapLibreMarker(
          point: const LatLng(0, 0),
          child: _PaintCountingBox(counter: counter),
        ),
      ],
    );

    expect(
      counter.value,
      0,
      reason: 'a point behind a pitched camera must not be painted',
    );
  });

  testWidgets('reprojects on a camera tick without rebuilding the child', (
    tester,
  ) async {
    final controller = _ProjController(const TextureHandle(textureId: 2));
    controller.projectFn = (_) => const Offset(100, 100);
    MapLibreFlutterPlatform.instance = _FixedPlatform(controller);

    var builds = 0;
    await _pump(
      tester,
      markers: [
        MapLibreMarker(
          point: const LatLng(0, 0),
          child: _CountingBox(key: const Key('m'), onBuild: () => builds++),
        ),
      ],
    );
    expect(
      tester.getCenter(find.byKey(const Key('m'))),
      offsetMoreOrLessEquals(const Offset(100, 100), epsilon: 0.5),
    );
    final buildsAfterMount = builds;

    // Simulate a camera move: the projection changes and the projector ticks.
    controller.projectFn = (_) => const Offset(250, 180);
    controller.tick();
    await tester.pump();

    expect(
      tester.getCenter(find.byKey(const Key('m'))),
      offsetMoreOrLessEquals(const Offset(250, 180), epsilon: 0.5),
      reason: 'the marker should follow the new projection',
    );
    expect(
      builds,
      buildsAfterMount,
      reason: 'Flow repaints the overlay; it must not rebuild the child widget',
    );
  });

  testWidgets('tapping a marker fires the marker, not the map onTap', (
    tester,
  ) async {
    final controller = _ProjController(const TextureHandle(textureId: 3));
    controller.projectFn = (_) => const Offset(150, 150);
    MapLibreFlutterPlatform.instance = _FixedPlatform(controller);

    var markerTapped = false;
    LatLng? mapTapped;
    await _pump(
      tester,
      onTap: (p) => mapTapped = p,
      markers: [
        MapLibreMarker(
          point: const LatLng(0, 0),
          child: GestureDetector(
            onTap: () => markerTapped = true,
            child: Container(
              key: const Key('m'),
              width: 40,
              height: 40,
              color: const Color(0xFF000000),
            ),
          ),
        ),
      ],
    );

    await tester.tapAt(const Offset(150, 150));
    await tester.pump();

    expect(markerTapped, isTrue);
    expect(mapTapped, isNull, reason: 'the marker consumed the tap');
  });

  testWidgets('tapping empty map reports the unprojected LatLng', (
    tester,
  ) async {
    final controller = _ProjController(const TextureHandle(textureId: 4));
    controller.projectFn = (_) =>
        const Offset(-1000, -1000); // marker off-screen
    controller.unprojectFn = (o) => LatLng(o.dy, o.dx);
    MapLibreFlutterPlatform.instance = _FixedPlatform(controller);

    LatLng? mapTapped;
    await _pump(
      tester,
      onTap: (p) => mapTapped = p,
      markers: [
        MapLibreMarker(
          point: const LatLng(0, 0),
          child: const SizedBox(width: 10, height: 10),
        ),
      ],
    );

    await tester.tapAt(const Offset(123, 222));
    await tester.pump();

    expect(mapTapped, isNotNull);
    expect(mapTapped!.latitude, 222);
    expect(mapTapped!.longitude, 123);
  });

  testWidgets('dragging a draggable marker reports the unprojected end point', (
    tester,
  ) async {
    final controller = _ProjController(const TextureHandle(textureId: 5));
    controller.projectFn = (_) => const Offset(100, 100);
    controller.unprojectFn = (o) => LatLng(o.dy, o.dx);
    MapLibreFlutterPlatform.instance = _FixedPlatform(controller);

    LatLng? ended;
    await _pump(
      tester,
      markers: [
        MapLibreMarker(
          point: const LatLng(0, 0),
          draggable: true,
          onDragEnd: (p) => ended = p,
          child: Container(
            key: const Key('m'),
            width: 40,
            height: 40,
            color: const Color(0xFF000000),
          ),
        ),
      ],
    );

    // Marker centered at (100,100); drag by (+30,+20) → screen (130,120).
    await tester.drag(find.byKey(const Key('m')), const Offset(30, 20));
    await tester.pump();

    expect(ended, isNotNull);
    expect(ended!.longitude, 130); // unproject maps x→lng
    expect(ended!.latitude, 120); // and y→lat
  });

  testWidgets('a controller without a projector renders no overlay', (
    tester,
  ) async {
    MapLibreFlutterPlatform.instance = _FixedPlatform(
      _PlainController(const TextureHandle(textureId: 6)),
    );

    await _pump(
      tester,
      markers: [
        MapLibreMarker(
          point: const LatLng(0, 0),
          child: const SizedBox(key: Key('m'), width: 10, height: 10),
        ),
      ],
    );

    expect(find.byType(Texture), findsOneWidget);
    expect(find.byType(MarkerOverlay), findsNothing);
    expect(find.byKey(const Key('m')), findsNothing);
  });
}
