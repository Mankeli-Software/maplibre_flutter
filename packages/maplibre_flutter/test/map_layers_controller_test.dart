import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Records what reached the platform, so the generated style JSON can be
/// asserted rather than guessed at.
class _RecordingLayers implements MapLibreStyleLayers {
  final Map<String, String> sources = {};
  final List<String> layers = [];
  final List<String> removedLayers = [];
  final List<String> removedSources = [];
  final Map<String, ({int w, int h, double pr, int bytes})> images = {};
  String? lastData;

  @override
  void addSourceJson(String id, String json) => sources[id] = json;
  @override
  void addLayerJson(String json, {String? beforeId}) => layers.add(json);
  @override
  void setGeoJsonData(String sourceId, String geoJson) => lastData = geoJson;
  @override
  void removeLayer(String id) => removedLayers.add(id);
  @override
  void removeSource(String id) => removedSources.add(id);
  @override
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) => images[id] = (w: width, h: height, pr: pixelRatio, bytes: rgba.length);
  @override
  void removeImage(String id) {}

  ({Duration? duration, Duration? delay, bool placement})? transitions;
  @override
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions = true,
  }) => transitions = (
    duration: duration,
    delay: delay,
    placement: placementTransitions,
  );

  /// Canned query payload, plus the rect the controller asked for.
  String? queryJson;
  Rect? queriedRect;
  @override
  String? queryRenderedFeaturesJson(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
  }) {
    queriedRect = Rect.fromLTRB(minX, minY, maxX, maxY);
    return queryJson;
  }
}

void main() {
  test('is a no-op (not a crash) before attach / on unsupported renderers', () {
    final layers = MapLibreLayersController();
    expect(layers.isSupported, isFalse);
    // None of these should throw when nothing is bound.
    layers
      ..addPoints('x', const [LatLng(1, 2)])
      ..setPoints('x', const [LatLng(3, 4)])
      ..removePoints('x')
      ..addSourceJson('s', '{}')
      ..addLayerJson('{}')
      ..removeImage('i');
  });

  test('addPoints builds a geojson source with lng,lat order', () {
    final rec = _RecordingLayers();
    final layers = MapLibreLayersController()..attachTo(rec);
    expect(layers.isSupported, isTrue);

    layers.addPoints('pts', const [LatLng(60.45, 22.27)]);

    final src = jsonDecode(rec.sources['pts']!) as Map<String, Object?>;
    expect(src['type'], 'geojson');
    expect(src.containsKey('cluster'), isFalse, reason: 'not requested');
    final feature =
        ((src['data'] as Map)['features'] as List).single
            as Map<String, Object?>;
    final coords = (feature['geometry'] as Map)['coordinates'] as List;
    // GeoJSON is [lng, lat] — the flip is the classic bug, so pin it.
    expect(coords[0], closeTo(22.27, 1e-9));
    expect(coords[1], closeTo(60.45, 1e-9));

    // One plain circle layer when clustering is off.
    expect(rec.layers, hasLength(1));
    final layer = jsonDecode(rec.layers.single) as Map<String, Object?>;
    expect(layer['type'], 'circle');
    expect(layer['source'], 'pts');
  });

  test('addPoints(cluster: true) sets cluster options and partitions layers', () {
    final rec = _RecordingLayers();
    final layers = MapLibreLayersController()..attachTo(rec);

    layers.addPoints(
      'c',
      const [LatLng(1, 2), LatLng(3, 4)],
      cluster: true,
      clusterRadius: 60,
      clusterMaxZoom: 12,
      // Named so the count layer is emitted — see the font-guard test below.
      clusterTextFont: ['Open Sans Regular'],
    );

    final src = jsonDecode(rec.sources['c']!) as Map<String, Object?>;
    expect(src['cluster'], isTrue);
    expect(src['clusterRadius'], 60);
    expect(src['clusterMaxZoom'], 12);

    // Cluster bubbles + count labels + leftover single points.
    expect(rec.layers, hasLength(3));
    final decoded = rec.layers
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();
    expect(decoded.map((l) => l['id']), ['c-clusters', 'c-count', 'c-points']);

    // point_count only exists on features supercluster created, so these two
    // filters must be exact complements or points get drawn twice / not at all.
    expect(decoded[0]['filter'], ['has', 'point_count']);
    expect(decoded[2]['filter'], [
      '!',
      ['has', 'point_count'],
    ]);
    expect(
      decoded[1]['type'],
      'symbol',
      reason: 'count labels are a symbol layer',
    );
  });

  // Regression: addPoints used to emit the count label with no `text-font`, so
  // mbgl fell back to "Open Sans Regular,Arial Unicode MS Regular" — present in
  // demotiles, absent from OpenFreeMap Liberty. On Liberty every tile 404'd its
  // glyphs, which does not merely drop the text: it stops the whole source from
  // rendering, so the dataset silently vanished after a style toggle.
  test('omits the cluster count layer unless a font is named', () {
    final rec = _RecordingLayers();
    final layers = MapLibreLayersController()..attachTo(rec);

    layers.addPoints('c', const [LatLng(1, 2)], cluster: true);

    final ids = rec.layers
        .map((l) => (jsonDecode(l) as Map<String, Object?>)['id'])
        .toList();
    expect(ids, ['c-clusters', 'c-points']);
    expect(
      rec.layers.any((l) => l.contains('text-field')),
      isFalse,
      reason: 'no text layer without a known-good font',
    );
  });

  test('adds the count layer with the given font when one is named', () {
    final rec = _RecordingLayers();
    final layers = MapLibreLayersController()..attachTo(rec);

    layers.addPoints(
      'c',
      const [LatLng(1, 2)],
      cluster: true,
      clusterTextFont: ['Noto Sans Regular'],
    );

    final count =
        rec.layers
                .map((l) => jsonDecode(l) as Map<String, Object?>)
                .firstWhere((l) => l['id'] == 'c-count')['layout']
            as Map<String, Object?>;
    expect(count['text-font'], ['Noto Sans Regular']);
    expect(count['text-field'], ['get', 'point_count_abbreviated']);
  });

  test('removePoints tears down every layer addPoints created', () {
    final rec = _RecordingLayers();
    final layers = MapLibreLayersController()..attachTo(rec);

    layers
      ..addPoints('c', const [LatLng(1, 2)], cluster: true)
      ..removePoints('c');

    expect(
      rec.removedLayers,
      containsAll(['c-clusters', 'c-count', 'c-points']),
    );
    expect(rec.removedSources, ['c']);
  });

  test('setPoints replaces data without touching layers', () {
    final rec = _RecordingLayers();
    final layers = MapLibreLayersController()..attachTo(rec);

    layers
      ..addPoints('p', const [LatLng(1, 2)])
      ..setPoints('p', const [LatLng(5, 6), LatLng(7, 8)]);

    expect(rec.layers, hasLength(1), reason: 'no new layers on a data update');
    final data = jsonDecode(rec.lastData!) as Map<String, Object?>;
    expect((data['features'] as List), hasLength(2));
  });

  test('queryRenderedFeatures parses clusters and single points', () {
    final rec = _RecordingLayers();
    final layers = MapLibreLayersController()..attachTo(rec);
    rec.queryJson = jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [22.27, 60.45], // [lng, lat]
          },
          'properties': {'point_count': 42, 'cluster_id': 7},
        },
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [18.06, 59.33],
          },
          'properties': <String, Object?>{},
        },
      ],
    });

    final found = layers.queryRenderedFeatures(
      const Rect.fromLTRB(0, 0, 400, 300),
    );

    expect(rec.queriedRect, const Rect.fromLTRB(0, 0, 400, 300));
    expect(found, hasLength(2));

    expect(found[0].isCluster, isTrue);
    expect(found[0].pointCount, 42);
    // Flipped back from GeoJSON's [lng, lat].
    expect(found[0].point.latitude, closeTo(60.45, 1e-9));
    expect(found[0].point.longitude, closeTo(22.27, 1e-9));

    expect(found[1].isCluster, isFalse);
    expect(found[1].pointCount, 1, reason: 'a lone point counts as one');
  });

  test('queryRenderedFeatures degrades to empty, never throws', () {
    final rec = _RecordingLayers();
    final layers = MapLibreLayersController()..attachTo(rec);

    // Runs on camera ticks, so a bad/absent payload must not blow up the frame.
    rec.queryJson = null;
    expect(layers.queryRenderedFeatures(Rect.largest), isEmpty);
    rec.queryJson = '{not json';
    expect(layers.queryRenderedFeatures(Rect.largest), isEmpty);
    // Non-point geometry is skipped rather than mis-parsed.
    rec.queryJson = jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [0, 0],
              [1, 1],
            ],
          },
          'properties': <String, Object?>{},
        },
      ],
    });
    expect(layers.queryRenderedFeatures(Rect.largest), isEmpty);
  });

  // NOTE both rasterizer tests run inside tester.runAsync. RenderRepaintBoundary
  // .toImage() waits on a real callback from the engine's raster pipeline, which
  // flutter_test's fake async never delivers — without runAsync these hang until
  // the 10-minute timeout rather than failing. The production path is unaffected.

  testWidgets('rasterizeWidget paints a widget off-screen', (tester) async {
    await tester.runAsync(() async {
      // Deliberately never added to the visible tree.
      final image = await MapLibreLayersController.rasterizeWidget(
        const ColoredBox(color: Color(0xFF00FF00)),
        size: const Size(10, 10),
        pixelRatio: 2,
      );
      addTearDown(image.dispose);

      expect(image.width, 20, reason: '10 logical px at DPR 2');
      expect(image.height, 20);

      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(data, isNotNull);
      final bytes = data!.buffer.asUint8List();
      expect(bytes.length, 20 * 20 * 4);
      // Centre pixel should be the green we painted, not transparent.
      final centre = ((20 ~/ 2) * 20 + 20 ~/ 2) * 4;
      expect(bytes[centre + 1], greaterThan(200), reason: 'green channel');
      expect(bytes[centre + 3], 255, reason: 'opaque');
    });
  });

  testWidgets('addWidgetIcon registers the rasterized widget as an icon', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final rec = _RecordingLayers();
      final layers = MapLibreLayersController()..attachTo(rec);

      await layers.addWidgetIcon(
        'pin',
        const ColoredBox(color: Color(0xFFFF0000)),
        size: const Size(8, 8),
        pixelRatio: 2,
      );

      expect(rec.images.containsKey('pin'), isTrue);
      final img = rec.images['pin']!;
      expect(img.w, 16);
      expect(img.h, 16);
      expect(img.pr, 2);
      expect(
        img.bytes,
        16 * 16 * 4,
        reason: 'raw RGBA of the rasterized image',
      );
    });
  });
}
