// Stage 6 queries against a real engine on macOS:
//
//   flutter test integration_test/macos_queries_test.dart -d macos
//
// WHY IT EXISTS: the unit tests drive a fake that returns whatever it is handed,
// so they prove the plumbing carries a filter and nothing about whether mbgl
// honours it. The two behaviours worth guarding are both the ENGINE's: a filter
// evaluated inside the renderer, and querySourceFeatures seeing data that
// queryRenderedFeatures cannot.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

// Three labelled points around Turku, close enough to share a screen at z17 and
// asymmetric in both axes so a swapped coordinate cannot pass.
const _style = '''
{
  "version": 8,
  "sources": {
    "pts": {
      "type": "geojson",
      "data": {
        "type": "FeatureCollection",
        "features": [
          {"type": "Feature", "id": 1, "properties": {"kind": "city"},
           "geometry": {"type": "Point", "coordinates": [22.2660, 60.4510]}},
          {"type": "Feature", "id": 2, "properties": {"kind": "town"},
           "geometry": {"type": "Point", "coordinates": [22.2670, 60.4510]}},
          {"type": "Feature", "id": 3, "properties": {"kind": "city"},
           "geometry": {"type": "Point", "coordinates": [22.2660, 60.4516]}}
        ]
      }
    }
  },
  "layers": [
    {"id": "bg", "type": "background",
     "paint": {"background-color": "#ffffff"}},
    {"id": "dots", "type": "circle", "source": "pts",
     "paint": {"circle-radius": 14, "circle-color": "#d32f2f"}}
  ]
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<MapLibreMapController> boot(WidgetTester tester) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: _style,
          options: const MapOptions(
            initialCamera: MapCamera(
              center: LatLng(60.4513, 22.2665),
              zoom: 16,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 600));
    return controller;
  }

  Rect wholeScreen(WidgetTester tester) =>
      Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;

  testWidgets('a filter is evaluated INSIDE the engine', (tester) async {
    final controller = await boot(tester);
    final rect = wholeScreen(tester);

    final all = controller.style.queryRenderedFeatures(rect);
    expect(all, hasLength(3), reason: 'precondition: all three are drawn');

    final cities = controller.style.queryRenderedFeatures(
      rect,
      filter: Expr.equals(Expr.get('kind'), const StyleValue('city')),
    );
    expect(cities, hasLength(2));
    expect(
      cities.map((f) => f.id).toSet(),
      equals({1, 3}),
      reason: 'the engine must select by property, not by position',
    );
  });

  testWidgets('the async form agrees with the sync one', (tester) async {
    final controller = await boot(tester);
    final rect = wholeScreen(tester);
    final sync = controller.style.queryRenderedFeatures(rect);
    final async = await controller.style
        .queryRenderedFeaturesAsync(rect)
        .timeout(const Duration(seconds: 10));
    expect(async.map((f) => f.id).toSet(), sync.map((f) => f.id).toSet());
    expect(async, hasLength(3));
  });

  testWidgets('a point query hits the feature under it, and misses elsewhere', (
    tester,
  ) async {
    final controller = await boot(tester);
    final rect = wholeScreen(tester);

    // Put feature 1 EXACTLY at the screen centre rather than assuming the three
    // points straddle it — at this zoom they span ~46 px, so "near the middle"
    // is not close enough for an 8 px tolerance and the test would be measuring
    // the fixture, not the query.
    await controller.camera.jumpTo(
      const CameraOptions(center: LatLng(60.4510, 22.2660)),
    );
    await tester.pump(const Duration(milliseconds: 600));

    final hit = controller.style.queryRenderedFeaturesAt(rect.center);
    final miss = controller.style.queryRenderedFeaturesAt(
      Offset(rect.right - 4, rect.bottom - 4),
      layerIds: const ['dots'],
    );
    expect(
      hit.map((f) => f.id),
      contains(1),
      reason: 'the padded point must find the feature underneath it',
    );
    expect(
      miss,
      isEmpty,
      reason:
          'and must NOT find them from the far corner — a query that hits '
          'everywhere is indistinguishable from one that works',
    );
  });

  testWidgets('querySourceFeatures sees what the rendered query cannot', (
    tester,
  ) async {
    final controller = await boot(tester);
    final rect = wholeScreen(tester);

    // A layer FILTER, not visibility: hiding the layer removes mbgl's only
    // reason to hold tiles for the source, so the source query would correctly
    // find nothing and the test would prove the opposite of what it claims.
    controller.style.setFilter(
      'dots',
      Expr.equals(Expr.get('kind'), const StyleValue('town')),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      controller.style.queryRenderedFeatures(rect).map((f) => f.id).toSet(),
      equals({2}),
      reason: 'the rendered query reports what was DRAWN',
    );
    // NOT deduplicated — mbgl answers per loaded tile — so compare id SETS.
    expect(
      controller.style.querySourceFeatures('pts').map((f) => f.id).toSet(),
      equals({1, 2, 3}),
      reason: 'the source query ignores styling: all three are still loaded',
    );
  });

  // 6.6: mbgl::Feature carries source/sourceLayer/state, and the shim used to
  // slice all three off by copying into a feature_collection<double>.
  testWidgets('a queried feature carries its source and its state', (
    tester,
  ) async {
    final controller = await boot(tester);
    final rect = wholeScreen(tester);

    controller.style.setFeatureState('pts', 1, {'selected': true});
    await tester.pump(const Duration(milliseconds: 500));

    final features = controller.style.queryRenderedFeatures(rect);
    final one = features.firstWhere((f) => f.id == 1);
    expect(one.source, 'pts');
    expect(
      one.state,
      containsPair('selected', true),
      reason:
          'without this a query cannot tell you which hits are selected, '
          'which is most of what selection UI needs',
    );
    // A GeoJSON source genuinely has no source layer.
    expect(one.sourceLayer, isNull);

    final other = features.firstWhere((f) => f.id == 2);
    expect(other.state, isEmpty, reason: 'state is per feature');
  });

  // 6.7: the tap has to carry the screen point, or there is no route from a tap
  // to the features under it.
  testWidgets('a tap reports both coordinates, and they agree', (tester) async {
    final controller = MapLibreMapController();
    addTearDown(controller.dispose);
    MapTapEvent? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: MapLibreMap(
          controller: controller,
          style: _style,
          onTap: (tap) => tapped = tap,
          options: const MapOptions(
            initialCamera: MapCamera(
              center: LatLng(60.4513, 22.2665),
              zoom: 16,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await controller.onReady.timeout(const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 600));

    final at = wholeScreen(tester).center + const Offset(30, -20);
    await tester.tapAt(at);
    // Past the double-tap window (300 ms), not merely a frame: a map tap is
    // held back until a second tap has been ruled out, so that
    // double-tap-to-zoom cannot also report the taps it is made of.
    await tester.pump(const Duration(milliseconds: 500));

    expect(tapped, isNotNull);
    expect(tapped!.screenPoint.dx, closeTo(at.dx, 1));
    expect(tapped!.screenPoint.dy, closeTo(at.dy, 1));

    // The two coordinates must describe the SAME place: projecting the reported
    // LatLng has to land back on the reported screen point. A round trip is a
    // weak test in general (CLAUDE.md §7), but here the two values come from
    // different code paths — unproject in the widget, project on the
    // controller — so agreement is real evidence.
    final back = controller.project(tapped!.point);
    expect(back, isNotNull);
    expect(back!.dx, closeTo(at.dx, 1.5));
    expect(back.dy, closeTo(at.dy, 1.5));

    // And absolute direction: tapping right of centre must be EAST of centre,
    // tapping above it must be NORTH.
    final centre = (await controller.camera.getCamera()).center;
    expect(
      tapped!.point.longitude,
      greaterThan(centre.longitude),
      reason: 'right of centre is east',
    );
    expect(
      tapped!.point.latitude,
      greaterThan(centre.latitude),
      reason: 'above centre is north — a flipped Y would pass a round trip',
    );
  });
}
