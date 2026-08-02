import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart'
    show CustomSemanticsAction, SemanticsAction, SemanticsNode;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

const _style = 'https://demotiles.maplibre.org/style.json';
const _options = MapOptions(initialCamera: MapCamera(center: LatLng(0, 0)));

/// Records every camera command, and projects with **north up**: screen y grows
/// downward, so a higher latitude is a smaller y. That sign is the whole point
/// of the pan assertions below.
class _A11yController
    with MapLibreCameraTickNotifier
    implements
        MapLibreMapPlatformController,
        MapLibreCameraCommands,
        MapLibreMapProjector {
  _A11yController(this.renderHandle);

  @override
  final MapLibreRenderHandle renderHandle;

  MapCamera camera = const MapCamera(center: LatLng(0, 0), zoom: 12.4);

  MapCameraConstraints? constraints;

  final List<CameraOptions> jumps = <CameraOptions>[];
  final List<CameraOptions> eases = <CameraOptions>[];
  final List<CameraOptions> flies = <CameraOptions>[];
  final List<CameraAnimation?> easeAnimations = <CameraAnimation?>[];

  @override
  Future<void> get onReady => Future<void>.value();
  @override
  Future<MapCamera> getCamera() async => camera;
  @override
  Future<void> moveCamera(MapCamera c, {Duration? duration}) async {}
  @override
  Future<void> setStyle(String styleUri) async {}
  @override
  Future<void> resize(Size size, double devicePixelRatio) async {}
  @override
  Future<void> dispose() async => disposeCameraTick();

  @override
  int project(List<LatLng> points, List<Offset> out, {List<bool>? visible}) {
    for (var i = 0; i < points.length; i++) {
      // 10 px per degree. A degree per pixel would turn a half-viewport pan
      // into 300 degrees of latitude, which LatLng rightly refuses.
      out[i] = Offset(points[i].longitude * 10, -points[i].latitude * 10);
      if (visible != null) visible[i] = true;
    }
    return 1;
  }

  @override
  LatLng? unproject(Offset point) => LatLng(-point.dy / 10, point.dx / 10);

  @override
  Future<void> jumpTo(CameraOptions c) async => jumps.add(c);
  @override
  Future<void> easeTo(CameraOptions c, {CameraAnimation? animation}) async {
    eases.add(c);
    easeAnimations.add(animation);
  }

  @override
  Future<void> flyTo(CameraOptions c, {CameraAnimation? animation}) async =>
      flies.add(c);
  @override
  Future<void> fitBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    double? bearing,
    double? pitch,
    CameraTransition transition = CameraTransition.jump,
    CameraAnimation? animation,
  }) async {}
  @override
  Future<CameraOptions?> cameraForBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    double? maxZoom,
    double? bearing,
    double? pitch,
  }) async => null;
  @override
  Future<LatLngBounds?> getBounds() async => null;
  @override
  Future<void> setCameraConstraints(MapCameraConstraints constraints) async {}
  @override
  Future<MapCameraConstraints?> getCameraConstraints() async => constraints;
  @override
  Future<void> setConstrainToBounds({required bool wholeViewport}) async {}
  @override
  Future<void> stopCamera() async {}
}

class _Platform extends MapLibreFlutterPlatform {
  _Platform({
    this.providesOwnSemantics = false,
    this.initialCamera = const MapCamera(center: LatLng(0, 0), zoom: 12.4),
    this.initialConstraints,
  });

  final bool providesOwnSemantics;

  /// Set at CONSTRUCTION, not after the pump: the controls read the camera and
  /// the constraints once on mount, so anything assigned afterwards is a frame
  /// too late and the test silently asserts the defaults.
  final MapCamera initialCamera;
  final MapCameraConstraints? initialConstraints;
  _A11yController? last;

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => last =
      _A11yController(
          TextureHandle(
            textureId: 1,
            providesOwnSemantics: providesOwnSemantics,
          ),
        )
        ..camera = initialCamera
        ..constraints = initialConstraints;
}

/// Pumps the map, then drives the 100 ms settle so the value is computed.
Future<_A11yController> _pumpMap(
  WidgetTester tester, {
  MapLibreSemantics semantics = const MapLibreSemantics(),
}) async {
  final platform = _Platform();
  MapLibreFlutterPlatform.instance = platform;
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: MapLibreMap(
          style: _style,
          options: _options,
          semantics: semantics,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pumpAndSettle();
  return platform.last!;
}

SemanticsNode _mapNode() => find.semantics.byLabel('Map').evaluate().single;

void main() {
  group('the spoken value', () {
    const camera = MapCamera(center: LatLng(60.17, 24.94), zoom: 12.4);
    const locale = MapLibreLocale();

    test('zoom is the level, with no off-by-one', () {
      // Apple speaks `round(zoomLevel + 1)`, so its spoken zoom disagrees with
      // its own zoomLevel property. Ours agrees with getCamera().zoom.
      const summary = MapSemanticsSummary(
        camera: camera,
        viewport: Size(200, 200),
      );
      expect(summary.describe(locale), 'Zoom 12. 0 markers visible.');
    });

    test('a marker count is pluralised', () {
      const one = MapSemanticsSummary(
        camera: camera,
        viewport: Size(200, 200),
        visibleMarkerCount: 1,
      );
      const many = MapSemanticsSummary(
        camera: camera,
        viewport: Size(200, 200),
        visibleMarkerCount: 4,
      );
      expect(one.describe(locale), contains('1 marker visible.'));
      expect(many.describe(locale), contains('4 markers visible.'));
    });

    // The whole reason MapLoadState exists: without it these two are the same
    // sentence, and one of them means the map is broken.
    test('a failed style does not sound like an empty ocean', () {
      const ocean = MapSemanticsSummary(
        camera: camera,
        viewport: Size(200, 200),
      );
      const broken = MapSemanticsSummary(
        camera: camera,
        viewport: Size(200, 200),
        loadState: MapLoadState.failed,
      );
      expect(ocean.describe(locale), isNot(contains('could not be loaded')));
      expect(
        broken.describe(locale),
        startsWith('The map could not be loaded.'),
      );
      expect(ocean.describe(locale), isNot(broken.describe(locale)));
    });

    test('load state leads the sentence', () {
      const loading = MapSemanticsSummary(
        camera: camera,
        viewport: Size(200, 200),
        loadState: MapLoadState.loading,
      );
      const degraded = MapSemanticsSummary(
        camera: camera,
        viewport: Size(200, 200),
        loadState: MapLoadState.degraded,
      );
      expect(loading.describe(locale), startsWith('Map loading.'));
      expect(degraded.describe(locale), startsWith('Some of the map'));
    });

    test('centre, bearing and pitch are opt-in and absolute', () {
      const tilted = MapSemanticsSummary(
        camera: MapCamera(
          center: LatLng(60.17, 24.94),
          zoom: 12.4,
          bearing: 90,
          pitch: 30,
        ),
        viewport: Size(200, 200),
      );
      const parts = MapCameraSummaryValue(
        center: true,
        bearing: true,
        pitch: true,
      );
      final spoken = tilted.describe(locale, parts: parts);
      // Absolute: bearing 90 is east and Helsinki is north-east. A mirrored
      // rose or a swapped hemisphere pair would render just as plausibly.
      expect(spoken, contains('Facing east.'));
      expect(spoken, contains('north'));
      expect(spoken, contains('east'));
      expect(spoken, contains('Tilted 30 degrees.'));
      // Off by default, because this is spoken on every settle.
      expect(tilted.describe(locale), isNot(contains('Facing')));
    });

    test('a north-up map says nothing about its bearing', () {
      const northUp = MapSemanticsSummary(
        camera: camera,
        viewport: Size(200, 200),
      );
      expect(
        northUp.describe(
          locale,
          parts: const MapCameraSummaryValue(bearing: true),
        ),
        isNot(contains('Facing')),
      );
    });
  });

  group('the map node', () {
    testWidgets('is a labelled region with a value', (tester) async {
      await _pumpMap(tester);
      expect(
        _mapNode(),
        isSemantics(
          label: 'Map',
          value: 'Zoom 12. 0 markers visible.',
          hasIncreaseAction: true,
          hasDecreaseAction: true,
        ),
      );
    });

    testWidgets('excluded() publishes nothing', (tester) async {
      await _pumpMap(tester, semantics: const MapLibreSemantics.excluded());
      expect(find.semantics.byLabel('Map'), findsNothing);
    });

    testWidgets('a tier with its own tree is left alone', (tester) async {
      final platform = _Platform(providesOwnSemantics: true);
      MapLibreFlutterPlatform.instance = platform;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(),
            child: MapLibreMap(style: _style, options: _options),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The Apple SDK and gl-js tiers already announce the map; a second node
      // would describe it twice.
      expect(find.semantics.byLabel('Map'), findsNothing);
    });
  });

  group('the Android scroll/increase collision', () {
    // AccessibilityBridge lowers SCROLL_UP, SCROLL_LEFT and INCREASE all onto
    // ACTION_SCROLL_FORWARD and dispatches through a first-match chain with
    // SCROLL_UP first. A node carrying both makes ZOOM UNREACHABLE on Android —
    // and a test asserting that both actions merely EXIST passes while the
    // feature is dead on device. So this asserts the absence.
    testWidgets('Android exposes zoom and no scroll actions', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await _pumpMap(tester);
        expect(
          _mapNode(),
          isSemantics(
            hasIncreaseAction: true,
            hasDecreaseAction: true,
            hasScrollUpAction: false,
            hasScrollDownAction: false,
            hasScrollLeftAction: false,
            hasScrollRightAction: false,
          ),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    for (final platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      testWidgets('$platform exposes both zoom and all four scrolls', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await _pumpMap(tester);
          expect(
            _mapNode(),
            isSemantics(
              hasIncreaseAction: true,
              hasDecreaseAction: true,
              hasScrollUpAction: true,
              hasScrollDownAction: true,
              hasScrollLeftAction: true,
              hasScrollRightAction: true,
            ),
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('panning stays reachable on Android through custom actions', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final controller = await _pumpMap(tester);
        final node = _mapNode();
        final action = node
            .getSemanticsData()
            .customSemanticsActionIds!
            .map(CustomSemanticsAction.getAction)
            .firstWhere((a) => a!.label == 'Pan north')!;
        tester.semantics.performAction(
          find.semantics.byLabel('Map'),
          SemanticsAction.customAction,
          args: CustomSemanticsAction.getIdentifier(action),
        );
        await tester.pumpAndSettle();
        // If this breaks, Android loses panning entirely.
        expect(controller.eases.single.center!.latitude, greaterThan(0));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('the actions move the camera the right way', () {
    // flutter_test reports TargetPlatform.android by default, where the scroll
    // actions are deliberately absent (see the collision group above), so these
    // have to run somewhere they exist. The override is reset INLINE in a
    // finally, not in tearDown: the binding verifies foundation debug vars are
    // unset before tearDown ever runs.
    Future<void> onDesktop(
      WidgetTester tester,
      Future<void> Function(_A11yController controller) body,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body(await _pumpMap(tester));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<void> expectPan(
      WidgetTester tester,
      SemanticsAction action,
      void Function(LatLng centre) check,
    ) => onDesktop(tester, (controller) async {
      tester.semantics.performAction(find.semantics.byLabel('Map'), action);
      await tester.pumpAndSettle();
      check(controller.eases.single.center!);
    });

    testWidgets('increase snaps to a whole zoom level', (tester) async {
      await onDesktop(tester, (controller) async {
        tester.semantics.performAction(
          find.semantics.byLabel('Map'),
          SemanticsAction.increase,
        );
        await tester.pumpAndSettle();
        // 12.4 snaps to 12 and then steps, exactly as Apple does, so repeated
        // swipes land on clean levels instead of drifting. NOT 13.4.
        expect(controller.jumps.single.zoom, 13.0);
      });
    });

    testWidgets('decrease snaps the same way', (tester) async {
      await onDesktop(tester, (controller) async {
        tester.semantics.performAction(
          find.semantics.byLabel('Map'),
          SemanticsAction.decrease,
        );
        await tester.pumpAndSettle();
        expect(controller.jumps.single.zoom, 11.0);
      });
    });

    // ABSOLUTE directions, never a round trip. Flutter documents onScrollDown
    // as "a user moving their finger across the screen from top to bottom", and
    // camera.panBy takes a finger delta — so a finger moving DOWN drags the map
    // down and reveals what is NORTH of it.
    testWidgets('scrollDown moves the camera north', (tester) async {
      await expectPan(tester, SemanticsAction.scrollDown, (c) {
        expect(c.latitude, greaterThan(0));
      });
    });

    testWidgets('scrollUp moves the camera south', (tester) async {
      await expectPan(tester, SemanticsAction.scrollUp, (c) {
        expect(c.latitude, lessThan(0));
      });
    });

    testWidgets('scrollLeft moves the camera east', (tester) async {
      await expectPan(tester, SemanticsAction.scrollLeft, (c) {
        expect(c.longitude, greaterThan(0));
      });
    });

    testWidgets('scrollRight moves the camera west', (tester) async {
      await expectPan(tester, SemanticsAction.scrollRight, (c) {
        expect(c.longitude, lessThan(0));
      });
    });
  });

  group('reduced motion', () {
    Future<_A11yController> pumpWith(
      WidgetTester tester, {
      required bool disableAnimations,
      MapLibreMapController? controller,
    }) async {
      final platform = _Platform();
      MapLibreFlutterPlatform.instance = platform;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: MapLibreMap(
              style: _style,
              options: _options,
              controller: controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return platform.last!;
    }

    testWidgets('easeTo is clamped to zero, not skipped', (tester) async {
      final controller = MapLibreMapController();
      final fake = await pumpWith(
        tester,
        disableAnimations: true,
        controller: controller,
      );
      await controller.camera.easeTo(const CameraOptions(zoom: 5));
      await tester.pumpAndSettle();
      // Clamped rather than dropped: gl-js still fires the whole event
      // sequence, so an app's state machine cannot diverge between a
      // reduced-motion user and everyone else.
      expect(fake.easeAnimations.single!.duration, Duration.zero);
      expect(fake.eases.single.zoom, 5);
      controller.dispose();
    });

    testWidgets('flyTo degrades to a jump carrying only the destination', (
      tester,
    ) async {
      final controller = MapLibreMapController();
      final fake = await pumpWith(
        tester,
        disableAnimations: true,
        controller: controller,
      );
      await controller.camera.flyTo(
        const CameraOptions(
          center: LatLng(60.17, 24.94),
          zoom: 9,
          anchor: Offset(10, 20),
        ),
        speed: 3,
        apexZoom: 2,
      );
      await tester.pumpAndSettle();

      expect(fake.flies, isEmpty);
      final jump = fake.jumps.single;
      expect(jump.center, const LatLng(60.17, 24.94));
      expect(jump.zoom, 9);
      // Dropping the anchor is the CORRECTNESS half, not tidiness: a flight
      // that carried its anchor into a jump lands somewhere else.
      expect(jump.anchor, isNull);
      controller.dispose();
    });

    testWidgets('essential survives', (tester) async {
      final controller = MapLibreMapController();
      final fake = await pumpWith(
        tester,
        disableAnimations: true,
        controller: controller,
      );
      await controller.camera.flyTo(
        const CameraOptions(zoom: 9),
        essential: true,
      );
      await controller.camera.easeTo(
        const CameraOptions(zoom: 4),
        essential: true,
      );
      await tester.pumpAndSettle();
      expect(fake.flies.single.zoom, 9);
      expect(fake.easeAnimations.single!.duration, isNot(Duration.zero));
      controller.dispose();
    });

    testWidgets('without the setting nothing changes', (tester) async {
      final controller = MapLibreMapController();
      final fake = await pumpWith(
        tester,
        disableAnimations: false,
        controller: controller,
      );
      await controller.camera.flyTo(const CameraOptions(zoom: 9), speed: 3);
      await tester.pumpAndSettle();
      expect(fake.flies.single.zoom, 9);
      expect(fake.jumps, isEmpty);
      controller.dispose();
    });

    // The bookends must complete identically in both modes, or an app's state
    // machine diverges between a reduced-motion user and everyone else. That is
    // exactly why easeTo is CLAMPED to zero rather than skipped.
    for (final reduced in <bool>[true, false]) {
      testWidgets('a move still starts and ends with reduceMotion=$reduced', (
        tester,
      ) async {
        final controller = MapLibreMapController();
        final fake = await pumpWith(
          tester,
          disableAnimations: reduced,
          controller: controller,
        );
        expect(controller.isMoving, isFalse);

        await controller.camera.flyTo(const CameraOptions(zoom: 9));
        await tester.pumpAndSettle();

        // Exactly one command either way — reduce motion changes WHICH command,
        // never how many.
        expect(fake.jumps.length + fake.flies.length, 1);
        // `_reported` fired its end bookend, so the camera is not stuck moving.
        expect(controller.isMoving, isFalse);
      });
    }
  });

  group('controls — the SC 2.5.1 / 2.5.7 deliverable', () {
    Future<_A11yController> pumpControls(
      WidgetTester tester, {
      MapControls controls = const MapControls(),
      double bearing = 0,
      MapCameraConstraints? constraints,
    }) async {
      final platform = _Platform(
        initialCamera: MapCamera(
          center: const LatLng(0, 0),
          zoom: 12.4,
          bearing: bearing,
        ),
        initialConstraints: constraints,
      );
      MapLibreFlutterPlatform.instance = platform;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: MapLibreMap(
              style: _style,
              options: _options,
              controls: controls,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return platform.last!;
    }

    Future<void> expand(WidgetTester tester) async {
      tester.semantics.tap(find.semantics.byLabel('Show map controls'));
      await tester.pumpAndSettle();
    }

    testWidgets('are on by default, behind one disclosure button', (
      tester,
    ) async {
      await pumpControls(tester);
      // Discoverable and operable, which is what WCAG asks for — not
      // permanently visible, which is what gets a default deleted.
      expect(find.semantics.byLabel('Show map controls'), findsOne);
      expect(find.semantics.byLabel('Zoom in'), findsNothing);

      await expand(tester);
      expect(find.semantics.byLabel('Zoom in'), findsOne);
      expect(find.semantics.byLabel('Zoom out'), findsOne);
      expect(find.semantics.byLabel('Pan north'), findsOne);
    });

    testWidgets('MapControls.none() ships nothing', (tester) async {
      await pumpControls(tester, controls: const MapControls.none());
      expect(find.semantics.byLabel('Show map controls'), findsNothing);
      expect(find.semantics.byLabel('Zoom in'), findsNothing);
    });

    testWidgets('expanded() needs no disclosure step', (tester) async {
      await pumpControls(tester, controls: const MapControls.expanded());
      expect(find.semantics.byLabel('Show map controls'), findsNothing);
      expect(find.semantics.byLabel('Zoom in'), findsOne);
    });

    testWidgets('zoom in snaps to a whole level', (tester) async {
      final controller = await pumpControls(
        tester,
        controls: const MapControls.expanded(),
      );
      tester.semantics.tap(find.semantics.byLabel('Zoom in'));
      await tester.pumpAndSettle();
      expect(controller.jumps.single.zoom, 13.0);
    });

    // ABSOLUTE directions again: the pad is the 2.5.7 alternative to dragging,
    // so it has to move the map the same way a drag would.
    testWidgets('the pan pad moves the camera the right way', (tester) async {
      final controller = await pumpControls(
        tester,
        controls: const MapControls.expanded(),
      );
      tester.semantics.tap(find.semantics.byLabel('Pan north'));
      await tester.pumpAndSettle();
      expect(controller.eases.single.center!.latitude, greaterThan(0));

      controller.eases.clear();
      tester.semantics.tap(find.semantics.byLabel('Pan east'));
      await tester.pumpAndSettle();
      expect(controller.eases.single.center!.longitude, greaterThan(0));
    });

    // One pump per test, deliberately: a second pumpWidget reuses the element,
    // so createMap never runs again and the new fake platform stays empty.
    testWidgets('the compass is hidden on a north-up map', (tester) async {
      await pumpControls(tester);
      await expand(tester);
      expect(find.semantics.byLabel('Compass'), findsNothing);
    });

    testWidgets('the compass appears once the map is turned', (tester) async {
      await pumpControls(tester, bearing: 42);
      await expand(tester);
      expect(find.semantics.byLabel('Compass'), findsOne);
    });

    testWidgets('expanded() shows the compass even north-up', (tester) async {
      await pumpControls(tester, controls: const MapControls.expanded());
      expect(find.semantics.byLabel('Compass'), findsOne);
    });

    testWidgets('the compass resets north', (tester) async {
      final controller = await pumpControls(
        tester,
        controls: const MapControls.expanded(),
        bearing: 42,
      );
      tester.semantics.tap(find.semantics.byLabel('Compass'));
      await tester.pumpAndSettle();
      // resetNorth eases rather than jumps, and reports its own reason.
      expect(controller.eases.single.bearing, 0);
    });

    testWidgets('a rotate-disabled map grows no compass', (tester) async {
      final platform = _Platform();
      MapLibreFlutterPlatform.instance = platform;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(),
            child: MapLibreMap(
              style: _style,
              options: _options,
              rotateGesturesEnabled: false,
              controls: MapControls.expanded(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Auto-suppressed: a button that resets a rotation the map can never have
      // is worse than no button.
      expect(find.semantics.byLabel('Compass'), findsNothing);
    });

    testWidgets('zoom in is disabled at the max, and says so', (tester) async {
      await pumpControls(
        tester,
        controls: const MapControls.expanded(),
        constraints: const MapCameraConstraints(maxZoom: 12.4),
      );
      // One property gives the visual, hasEnabledState and isEnabled together.
      // gl-js needs two explicit calls and forgetting them was its issue #361.
      expect(
        find.semantics.byLabel('Zoom in').evaluate().single,
        isSemantics(isEnabled: false, hasEnabledState: true),
      );
      expect(
        find.semantics.byLabel('Zoom out').evaluate().single,
        isSemantics(isEnabled: true, hasEnabledState: true),
      );
    });

    testWidgets('every control meets the tap-target and label guidelines', (
      tester,
    ) async {
      await pumpControls(tester, controls: const MapControls.expanded());
      // 48x48 is Android's guideline, above WCAG 2.5.8's 24 and Apple's 44.
      // gl-js ships 29x29 and that is its still-open issue #363.
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    });
  });
}
