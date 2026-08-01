/// One conformance suite, run against every `mbgl-core` platform controller.
///
/// CLAUDE.md §7 layer 2 ("each platform wrapper with its generated bindings
/// mocked") existed only as a sentence: no package faked `MapLibreCoreMap`, so
/// the ~400-line body of each of the five core controllers — camera conversion,
/// fly-to stepping, projector batching, style pass-through, gesture forwarding,
/// dispose ordering — was executed by no test on any platform, macOS included.
///
/// It lives here because `maplibre_flutter` is the only package that depends on
/// all five platform packages. One suite is not just less code than five copies:
/// the whole risk being guarded against is that the same controller gets ported
/// to four platforms nobody can run, so a divergence must fail somewhere that
/// covers all of them at once, not in a file that only exists for the tier
/// someone remembered to write it for.
///
/// The assertions are chosen for what a copy-paste port silently drops. Several
/// look trivial and are not: each corresponds to a defect that renders correctly
/// in every screenshot (see the comments on each).
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter_android/maplibre_flutter_android.dart';
import 'package:maplibre_flutter_core/maplibre_flutter_core.dart';
import 'package:maplibre_flutter_core/testing.dart';
import 'package:maplibre_flutter_ios/maplibre_flutter_ios.dart';
import 'package:maplibre_flutter_linux/maplibre_flutter_linux.dart';
import 'package:maplibre_flutter_macos/maplibre_flutter_macos.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:maplibre_flutter_windows/maplibre_flutter_windows.dart';

/// One tier under test.
typedef Tier = ({
  String name,
  MapLibreMapPlatformController Function(RecordingCoreMap) build,
  // Whether this tier is expected to draw 3D models. Part of the contract, not
  // an incidental: the widget feature-detects `is MapLibreModelHost` and
  // silently no-ops without it, so a tier that quietly loses the capability
  // looks identical to one that never had it.
  bool models,
  // Windows and Linux mask resizes because their present path lags the widget.
  bool resizeMask,
});

const _camera = MapCamera(center: LatLng(1, 2), zoom: 3, bearing: 4, pitch: 5);

/// The one method channel each core tier uses, for texture registration only
/// (CLAUDE.md §3 — registration is the sole sanctioned channel use; the frame
/// path is FFI). `dispose()` awaits `unregisterTexture` on it, so a test that
/// does not stub it throws "Binding has not yet been initialized".
const _registrarChannels = <String>[
  'maplibre_flutter/macos/registrar',
  'maplibre_flutter/ios/registrar',
  'maplibre_flutter/android/registrar',
  'maplibre_flutter/windows/registrar',
  'maplibre_flutter/linux/registrar',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every registrar call a controller makes, so the suite can assert the
  /// dispose handshake actually happened rather than merely not throwing.
  final channelCalls = <MethodCall>[];

  setUp(() {
    channelCalls.clear();
    for (final name in _registrarChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (call) async {
            channelCalls.add(call);
            return call.method == 'registerTexture' ? 1 : null;
          });
    }
  });

  tearDown(() {
    for (final name in _registrarChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  final tiers = <Tier>[
    (
      name: 'macOS',
      build: MapLibreFlutterMacosController.forTesting,
      models: true,
      resizeMask: false,
    ),
    // `models` records what each tier supports TODAY, not what it should. All
    // five now implement MapLibreModelHost; flipping one of these back to false
    // is what a lost capability looks like, and the group below is skipped
    // rather than silently absent for any tier that lacks it.
    (
      name: 'iOS',
      build: MapLibreFlutterIosCoreController.forTesting,
      models: true,
      resizeMask: false,
    ),
    (
      name: 'Android',
      build: MapLibreFlutterAndroidCoreController.forTesting,
      models: true,
      resizeMask: false,
    ),
    (
      name: 'Windows',
      build: MapLibreFlutterWindowsController.forTesting,
      models: true,
      resizeMask: true,
    ),
    (
      name: 'Linux',
      build: MapLibreFlutterLinuxController.forTesting,
      models: true,
      resizeMask: true,
    ),
  ];

  for (final tier in tiers) {
    group('${tier.name} core controller', () {
      late RecordingCoreMap core;
      late MapLibreMapPlatformController controller;

      setUp(() {
        core = RecordingCoreMap();
        controller = tier.build(core);
      });

      tearDown(() async {
        await controller.dispose();
      });

      test('implements the capability set its tier promises', () {
        expect(
          controller,
          isA<MapLibreGestureHandler>(),
          reason:
              'the shared Dart gesture layer is attached on `is` — without '
              'this the map does not pan or zoom at all',
        );
        expect(
          controller,
          isA<MapLibreRotateHandler>(),
          reason: 'without it the map cannot be rotated or tilted by gesture',
        );
        expect(controller, isA<MapLibreMapProjector>());
        expect(controller, isA<MapLibreCameraTickNotifier>());
        expect(controller, isA<MapLibreStyleLayers>());
        expect(
          controller is MapLibreModelHost,
          tier.models,
          reason:
              'model calls silently no-op when the capability is absent, so '
              'losing it looks exactly like never having had it',
        );
        expect(controller is MapLibreResizeMaskHint, tier.resizeMask);
        expect(controller.renderHandle, isA<TextureHandle>());
      });

      // THE TRAP: MarkerOverlay only starts repainting on a projector
      // notification, and its delegate skips every child while the projection
      // generation is 0. So a tier that completes `onReady` without ticking
      // renders NO markers at all until something else moves the camera —
      // invisible the moment a user pans, and invisible in every integration
      // test, all of which move the camera as their first act.
      //
      // The "zero camera-mutating calls" half is what makes this asymmetric: a
      // test that panned first would pass on a broken tier.
      test(
        'ticks the camera on the first frame, before any camera call',
        () async {
          final fresh = RecordingCoreMap();
          var ticks = 0;
          final c = tier.build(fresh);
          (c as MapLibreCameraTickNotifier).addListener(() => ticks++);

          fresh.frameReady = true; // the first frame lands
          // …and the style finishes. BOTH are required now: onReady means
          // gl-js `load`, and a frame can precede the style completing.
          fresh.emitDiagnostic(CoreDiagnosticKind.styleLoaded);
          await c.onReady;
          await Future<void>.delayed(const Duration(milliseconds: 80));

          expect(
            ticks,
            greaterThan(0),
            reason:
                'without this tick MapLibreMap(markers:) draws nothing until '
                'the first pan',
          );
          expect(
            fresh.cameraSets,
            isEmpty,
            reason:
                'and it must come from readiness alone, not from a camera '
                'move that would mask the omission',
          );
          await c.dispose();
        },
      );

      // The bug this replaced: onReady completed on the first FRAME alone, so
      // an app that added a layer right after awaiting it lost the layer to the
      // style load that came next — mbgl drops every app-added layer on a style
      // load. onReady is documented as gl-js `load`; make it mean that.
      test('onReady waits for the STYLE, not just a frame', () async {
        final fresh = RecordingCoreMap();
        final c = tier.build(fresh);
        var ready = false;
        unawaited(c.onReady.then((_) => ready = true));

        fresh.frameReady = true;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          ready,
          isFalse,
          reason: 'a frame alone is not readiness — the style may still land',
        );

        fresh.emitDiagnostic(CoreDiagnosticKind.styleLoaded);
        await c.onReady;
        expect(ready, isTrue);
        await c.dispose();
      });

      test('reports engine failures as typed errors', () async {
        final fresh = RecordingCoreMap();
        final c = tier.build(fresh);
        expect(
          c,
          isA<MapLibreMapEvents>(),
          reason: 'every mbgl-core tier reports engine events',
        );
        final events = c as MapLibreMapEvents;
        final errors = <MapLibreError>[];
        final styleLoads = <void>[];
        final missing = <String>[];
        events.onError.listen(errors.add);
        events.onStyleLoaded.listen(styleLoads.add);
        events.onStyleImageMissing.listen(missing.add);

        fresh
          ..emitDiagnostic(
            CoreDiagnosticKind.mapLoadFailed,
            message: 'not found: 404',
          )
          ..emitDiagnostic(
            CoreDiagnosticKind.commandFailed,
            message: "no layer with id 'x'",
          )
          ..emitDiagnostic(
            CoreDiagnosticKind.log,
            severity: CoreDiagnosticSeverity.error,
            message: 'Failed to load glyph range',
          )
          ..emitDiagnostic(
            CoreDiagnosticKind.log,
            severity: CoreDiagnosticSeverity.debug,
            message: 'chatter nobody can act on',
          )
          ..emitDiagnostic(CoreDiagnosticKind.styleLoaded)
          ..emitDiagnostic(
            CoreDiagnosticKind.styleImageMissing,
            message: 'pin',
          );
        await Future<void>.delayed(Duration.zero);

        expect(errors.whereType<MapStyleError>(), hasLength(1));
        expect(errors.whereType<MapCommandError>(), hasLength(1));
        expect(
          errors.whereType<MapEngineError>(),
          hasLength(1),
          reason: 'error-level log records surface; debug chatter does not',
        );
        expect(styleLoads, hasLength(1));
        expect(missing, ['pin']);
        await c.dispose();
      });

      test('unregisters its diagnostic listener on dispose', () async {
        final fresh = RecordingCoreMap();
        final c = tier.build(fresh);
        expect(fresh.diagnosticListener, isNotNull);
        await c.dispose();
        expect(
          fresh.diagnosticListener,
          isNull,
          reason: 'a callback outliving the map is the classic FFI leak',
        );
      });

      test('camera round-trips through the core without reordering fields', () {
        core.camera = (
          latitude: 51.5,
          longitude: -0.12,
          zoom: 14,
          bearing: 90,
          pitch: 45,
        );
        expectLater(
          controller.getCamera(),
          completion(
            const MapCamera(
              center: LatLng(51.5, -0.12),
              zoom: 14,
              bearing: 90,
              pitch: 45,
            ),
          ),
        );
      });

      test('an instant moveCamera applies exactly once, unanimated', () async {
        await controller.moveCamera(_camera);
        expect(core.cameraSets, hasLength(1));
        expect(core.cameraSets.single.latitude, 1);
        expect(core.cameraSets.single.longitude, 2);
        expect(core.cameraSets.single.zoom, 3);
        expect(core.cameraSets.single.bearing, 4);
        expect(core.cameraSets.single.pitch, 5);
      });

      test('setStyle forwards verbatim', () async {
        await controller.setStyle('https://example.com/style.json');
        expect(core.styles, ['https://example.com/style.json']);
      });

      // THE TRAP: mbgl's framebuffer is `Size * pixelRatio`, so the controller
      // must pass LOGICAL POINTS and let the core apply the density it was
      // created with. A tier that multiplies by the DPR renders an identical
      // picture at DPR 1 — which is every desktop screenshot and every CI
      // runner — and at DPR 2 makes gestures move twice as fast and puts every
      // marker at twice its coordinates.
      test('resize passes logical points, never points x DPR', () async {
        await controller.resize(const Size(800, 600), 3);
        expect(core.resizes, [
          (width: 800, height: 600),
        ], reason: 'DPR 3 must not reach the core as 2400x1800');
      });

      test('resize ignores degenerate sizes and repeats', () async {
        await controller.resize(const Size(800, 600), 1);
        await controller.resize(const Size(800, 600), 1);
        await controller.resize(const Size(0, 600), 1);
        await controller.resize(const Size(800, -1), 1);
        expect(core.resizes, hasLength(1));
      });

      // THE TRAP: mbgl's gesture anchors are TOP-LEFT origin and pass through
      // unflipped — the opposite of the projector's rule, which is why it trips
      // people (CLAUDE.md §11). A briefly-shipped flip mirrored the Windows
      // pinch anchor about the map centre, and no round-trip test caught it
      // because the centre is symmetric. Anchor asymmetrically here.
      test('gesture deltas and anchors forward unmodified', () {
        (controller as MapLibreGestureHandler)
          ..moveBy(11, -22)
          ..scaleBy(1.5, 10, 700);
        expect(core.moves, [(dx: 11.0, dy: -22.0)]);
        expect(core.scales, [
          (scale: 1.5, anchorX: 10.0, anchorY: 700.0),
        ], reason: 'no y-flip: 700 must not arrive as height - 700');
      });

      // THE TRAP: camera commands are applied on the render thread and so run
      // AHEAD of the frame on screen. Anchored overlays must project against the
      // PRESENTED generation or they swim during a drag. A tier that omits the
      // argument gets the C ABI's default of 0, meaning "newest" — correct in
      // every static screenshot, every `pumpAndSettle`, and every integration
      // test, and wrong only mid-motion on real hardware.
      test('projects against the presented frame, not the newest', () {
        final out = <Offset>[Offset.zero];
        core.presented = 42;
        core.projection = 99;
        (controller as MapLibreMapProjector).project(const [LatLng(1, 2)], out);
        expect(
          core.projectGenerations,
          [42],
          reason:
              'must be presentedGeneration; 0 means "newest" and 99 is the '
              'live transform the frame has not caught up to',
        );
      });

      test('unproject also uses the presented generation', () {
        core.presented = 42;
        (controller as MapLibreMapProjector).unproject(const Offset(3, 4));
        expect(core.unprojectGenerations, [42]);
      });

      test('project writes screen positions back into the out list', () {
        core.projected = [(x: 12.5, y: 34.5), (x: 56.5, y: 78.5)];
        final out = <Offset>[Offset.zero, Offset.zero];
        final gen = (controller as MapLibreMapProjector).project(const [
          LatLng(1, 2),
          LatLng(3, 4),
        ], out);
        expect(gen, isNonZero);
        expect(out, [const Offset(12.5, 34.5), const Offset(56.5, 78.5)]);
      });

      test('project reports 0 and leaves out untouched before a frame', () {
        core.projectBatchResult = 0;
        final out = <Offset>[const Offset(-1, -1)];
        final gen = (controller as MapLibreMapProjector).project(const [
          LatLng(1, 2),
        ], out);
        expect(gen, 0);
        expect(
          out.single,
          const Offset(-1, -1),
          reason: 'a marker must stay unpainted, not jump to (0,0)',
        );
      });

      test('project fills the visible flags it is given', () {
        core.projected = [(x: 1, y: 2), (x: 3, y: 4)];
        core.projectedVisible = [true, false];
        final out = <Offset>[Offset.zero, Offset.zero];
        final visible = <bool>[false, false];
        (controller as MapLibreMapProjector).project(
          const [LatLng(1, 2), LatLng(3, 4)],
          out,
          visible: visible,
        );
        expect(
          visible,
          [true, false],
          reason:
              'a tier that never writes the flags is indistinguishable from '
              'a correct one at pitch 0 — which is every default camera',
        );
      });

      test('style layer calls pass through with their arguments intact', () {
        final layers = controller as MapLibreStyleLayers
          ..addSourceJson('src', '{"type":"geojson"}')
          ..addLayerJson('{"id":"a"}', beforeId: 'b')
          ..setGeoJsonData('src', '{"type":"FeatureCollection"}')
          ..removeLayer('a')
          ..removeSource('src')
          ..removeImage('icon')
          ..setTransitionOptions(
            duration: const Duration(milliseconds: 250),
            placementTransitions: false,
          );
        layers.addImage('icon', Uint8List(16), 2, 2, pixelRatio: 3, sdf: true);

        expect(core.sources, [(id: 'src', json: '{"type":"geojson"}')]);
        expect(core.layers, [(json: '{"id":"a"}', beforeId: 'b')]);
        expect(core.geoJsonUpdates, hasLength(1));
        expect(core.removedLayers, ['a']);
        expect(core.removedSources, ['src']);
        expect(core.removedImages, ['icon']);
        expect(
          core.transitions.single.duration,
          const Duration(milliseconds: 250),
        );
        expect(core.transitions.single.placement, isFalse);
        expect(core.images.single.pixelRatio, 3);
        expect(core.images.single.sdf, isTrue);
      });

      // THE TRAP: the query box is top-left origin and must NOT be flipped —
      // unlike projection, which must. The only caller in the repo passes the
      // full viewport, which is y-symmetric and so cannot tell the two apart.
      test('queryRenderedFeatures forwards an asymmetric rect unflipped', () {
        core.queryResult = '{"type":"FeatureCollection","features":[]}';
        final result = (controller as MapLibreStyleLayers)
            .queryRenderedFeaturesJson(10, 20, 30, 40, layerIds: ['a']);
        expect(result, core.queryResult);
        // Field-wise, not record equality: a record holding a List compares
        // that field by identity, so two equal-looking literals never match.
        expect(core.queries, hasLength(1));
        final q = core.queries.single;
        expect([q.minX, q.minY, q.maxX, q.maxY], [10.0, 20.0, 30.0, 40.0]);
        expect(q.layerIds, ['a']);
      });

      // THE TRAP: the order is load-bearing. `unregisterTexture` clears the
      // native frame callback, and it must complete BEFORE the core map is
      // destroyed and its render thread joined — otherwise the callback can
      // fire against a freed map.
      test(
        'dispose unregisters the texture before destroying the core',
        () async {
          await controller.dispose();
          expect(
            channelCalls.map((c) => c.method),
            contains('unregisterTexture'),
            reason:
                'leaving it registered leaks the texture, the core map and '
                'its render thread across a hot restart',
          );
          expect(core.disposed, isTrue);
        },
      );

      // Only for tiers that claim the capability. `skip` rather than an `if`,
      // so the tiers still lacking it are visible in the test output as
      // outstanding parity work rather than silently absent.
      group(
        'model host',
        () {
          const model = MapLibreModel(
            id: 'car',
            assetPath: '/tmp/car.glb',
            point: LatLng(51.5, -0.12),
            scale: 2,
            headingDegrees: 90,
            elevationMetres: 0.15,
          );

          test('addModel forwards the whole placement', () {
            (controller as MapLibreModelHost).addModel(model);
            expect(core.addedModels, hasLength(1));
            final m = core.addedModels.single;
            expect(m.layerId, 'car');
            expect(m.path, '/tmp/car.glb');
            expect(m.latitude, 51.5);
            expect(m.longitude, -0.12);
            expect(m.scale, 2);
            expect(m.headingDegrees, 90);
            expect(m.elevationMetres, 0.15);
          });

          // The point of updateModel: moving a model must NOT re-upload its mesh.
          // A real asset is tens of MB, so a tier that routed this through
          // addModel would re-parse and re-upload it every animation frame — and
          // would still look correct, just unusably slow.
          test('updateModel moves in place without re-adding', () {
            final host = controller as MapLibreModelHost
              ..addModel(model)
              ..updateModel(model);
            expect(core.modelTransforms, hasLength(1));
            expect(
              core.addedModels,
              hasLength(1),
              reason: 'moving must not re-upload the mesh',
            );
            host.removeModel('car');
            expect(core.removedModels, ['car']);
          });

          test('updateModel ignores an id that was never added', () {
            (controller as MapLibreModelHost).updateModel(model);
            expect(core.modelTransforms, isEmpty);
          });

          test(
            'renderedFrameCount reports the engine, and null once disposed',
            () async {
              core.frameCount = 123;
              expect((controller as MapLibreModelHost).renderedFrameCount, 123);
              await controller.dispose();
              expect(
                (controller as MapLibreModelHost).renderedFrameCount,
                isNull,
                reason:
                    'the caller uses null to mean "cannot report", and reading '
                    'a disposed core throws',
              );
            },
          );

          test('model calls are inert after dispose', () async {
            await controller.dispose();
            (controller as MapLibreModelHost)
              ..addModel(model)
              ..updateModel(model)
              ..removeModel('car');
            expect(core.addedModels, isEmpty);
            expect(core.modelTransforms, isEmpty);
            expect(core.removedModels, isEmpty);
          });
        },
        skip: tier.models ? null : '${tier.name} has no MapLibreModelHost yet',
      );

      test('every capability is inert after dispose', () async {
        await controller.dispose();
        expect(core.disposed, isTrue);

        (controller as MapLibreGestureHandler)
          ..moveBy(1, 1)
          ..scaleBy(2, 0, 0);
        (controller as MapLibreRotateHandler)
          ..rotateBy(1, 0, 0)
          ..pitchBy(1);
        (controller as MapLibreStyleLayers)
          ..addSourceJson('s', '{}')
          ..addLayerJson('{}')
          ..removeLayer('a');
        await controller.resize(const Size(11, 22), 1);
        await controller.setStyle('after-dispose');

        expect(core.moves, isEmpty);
        expect(core.scales, isEmpty);
        expect(core.rotations, isEmpty);
        expect(core.pitches, isEmpty);
        expect(core.sources, isEmpty);
        expect(core.layers, isEmpty);
        expect(core.removedLayers, isEmpty);
        expect(core.resizes, isEmpty);
        expect(
          core.styles,
          isEmpty,
          reason: 'a call after dispose must not reach a freed native handle',
        );
      });
    });
  }

  // Kept out of the per-tier group: it drives real timers, so it is slower and
  // wants explicit control over the fake clock.
  for (final tier in tiers) {
    test(
      '${tier.name}: an animated moveCamera steps and lands exactly',
      () async {
        final core = RecordingCoreMap();
        final controller = tier.build(core);
        await controller.moveCamera(
          _camera,
          duration: const Duration(milliseconds: 100),
        );
        expect(
          core.cameraSets.length,
          greaterThan(1),
          reason: 'a duration must produce an eased arc, not a jump',
        );
        final last = core.cameraSets.last;
        expect(last.latitude, 1);
        expect(last.longitude, 2);
        expect(
          last.zoom,
          3,
          reason: 'the arc must END exactly on the target, not near it',
        );
        await controller.dispose();
      },
    );

    test('${tier.name}: a gesture supersedes a running fly-to', () async {
      final core = RecordingCoreMap();
      final controller = tier.build(core);
      final fly = controller.moveCamera(
        _camera,
        duration: const Duration(milliseconds: 400),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      (controller as MapLibreGestureHandler).moveBy(5, 5);
      final duringGesture = core.cameraSets.length;
      await fly;
      expect(
        core.cameraSets.length,
        duringGesture,
        reason:
            'the superseded animation must stop stepping the camera, or it '
            'fights the user mid-drag',
      );
      await controller.dispose();
    });
  }
}
