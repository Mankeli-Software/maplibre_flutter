import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

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

  /// Layers by id, so getLayerJson can answer per-layer the way a real style
  /// does. `layers` stays insertion-ordered for tests that assert order.
  final Map<String, String> layersById = {};

  /// Every beforeId the controller passed, in order.
  final List<String?> beforeIds = [];

  @override
  void addLayerJson(String json, {String? beforeId}) {
    layers.add(json);
    beforeIds.add(beforeId);
    final decoded = jsonDecode(json);
    if (decoded is Map<String, Object?> && decoded['id'] is String) {
      layersById[decoded['id']! as String] = json;
    }
  }

  /// Recorded source-data replacements.
  final List<({String sourceId, String data})> sourceData = [];
  String? sourceJsonResult;
  List<String>? sourceIdsResult;

  @override
  void setSourceData(String sourceId, String data) {
    sourceData.add((sourceId: sourceId, data: data));
    lastData = data;
  }

  @override
  String? getSourceJson(String sourceId) =>
      sourceJsonResult ?? sources[sourceId];

  @override
  List<String>? getSourceIds() => sourceIdsResult;

  @override
  void setGeoJsonData(String sourceId, String geoJson) => lastData = geoJson;
  @override
  void removeLayer(String id) {
    removedLayers.add(id);
    layersById.remove(id);
    layers.removeWhere((json) {
      final decoded = jsonDecode(json);
      return decoded is Map<String, Object?> && decoded['id'] == id;
    });
  }

  /// Recorded per-property mutations, so a test can assert the exact JSON.
  final List<({String layerId, String name, String valueJson})> properties = [];
  final List<({String layerId, String? beforeId})> moves = [];

  /// Reads a test can steer.
  String? propertyResult;
  List<String>? layerIdsResult;
  String? layerJsonResult;

  @override
  bool setLayerProperty(String layerId, String name, String valueJson) {
    properties.add((layerId: layerId, name: name, valueJson: valueJson));
    return true;
  }

  @override
  void moveLayer(String layerId, {String? beforeId}) =>
      moves.add((layerId: layerId, beforeId: beforeId));

  @override
  String? getLayerProperty(String layerId, String name) => propertyResult;

  @override
  List<String>? getLayerIds() => layerIdsResult;

  @override
  String? getLayerJson(String layerId) =>
      layerJsonResult ?? layersById[layerId];
  @override
  void removeSource(String id) {
    removedSources.add(id);
    sources.remove(id);
  }

  @override
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) => images[id] = (w: width, h: height, pr: pixelRatio, bytes: rgba.length);
  bool? hasImageResult;
  List<String>? imageIdsResult;

  @override
  bool? hasImage(String id) => hasImageResult;

  @override
  List<String>? getImageIds() => imageIdsResult;

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
    String? filterJson,
  }) {
    queriedRect = Rect.fromLTRB(minX, minY, maxX, maxY);
    queriedFilter = filterJson;
    return queryJson;
  }

  /// The filter the controller passed down, so a test can assert it reached the
  /// engine rather than being applied in Dart.
  String? queriedFilter;

  @override
  Future<String?> queryRenderedFeaturesAsyncJson(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
    String? filterJson,
  }) async => queryRenderedFeaturesJson(
    minX,
    minY,
    maxX,
    maxY,
    layerIds: layerIds,
    filterJson: filterJson,
  );

  /// Recorded source queries.
  final List<
    ({String sourceId, List<String>? sourceLayers, String? filterJson})
  >
  sourceQueries =
      <({String sourceId, List<String>? sourceLayers, String? filterJson})>[];

  /// What [querySourceFeaturesJson] returns.
  String? sourceQueryResult;

  @override
  String? querySourceFeaturesJson(
    String sourceId, {
    List<String>? sourceLayers,
    String? filterJson,
  }) {
    sourceQueries.add((
      sourceId: sourceId,
      sourceLayers: sourceLayers,
      filterJson: filterJson,
    ));
    return sourceQueryResult;
  }

  @override
  void setFeatureStateJson(
    String sourceId,
    String featureId,
    String stateJson, {
    String? sourceLayer,
  }) => featureStates['$sourceId/$featureId'] = stateJson;

  /// Feature state as the double saw it.
  final Map<String, String> featureStates = <String, String>{};

  /// What [getFeatureStateJson] returns.
  String? featureStateResult = '{}';

  @override
  String? getFeatureStateJson(
    String sourceId,
    String featureId, {
    String? sourceLayer,
  }) => featureStateResult;

  @override
  void removeFeatureState(
    String sourceId, {
    String? featureId,
    String? sourceLayer,
    String? stateKey,
  }) {
    if (featureId == null) {
      featureStates.removeWhere((key, _) => key.startsWith('$sourceId/'));
      return;
    }
    featureStates.remove('$sourceId/$featureId');
  }
}

void main() {
  test('is a no-op (not a crash) before attach / on unsupported renderers', () {
    final layers = MapLibreStyleController();
    expect(layers.isSupported, isFalse);
    // None of these should throw when nothing is bound.
    layers
      ..addCircleLayersFromPoints('x', const [LatLng(1, 2)])
      ..setPointsData('x', const [LatLng(3, 4)])
      ..removeCircleLayersFromPoints('x')
      ..addSourceJson('s', '{}')
      ..addLayerJson('{}')
      ..removeImage('i');
  });

  test('addPoints builds a geojson source with lng,lat order', () {
    final rec = _RecordingLayers();
    final layers = MapLibreStyleController()..attachTo(rec);
    expect(layers.isSupported, isTrue);

    layers.addCircleLayersFromPoints('pts', const [LatLng(60.45, 22.27)]);

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

  test(
    'addCircleLayersFromPoints(cluster: true) sets cluster options and partitions layers',
    () {
      final rec = _RecordingLayers();
      final layers = MapLibreStyleController()..attachTo(rec);

      layers.addCircleLayersFromPoints(
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
      expect(decoded.map((l) => l['id']), [
        'c-clusters',
        'c-count',
        'c-points',
      ]);

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
    },
  );

  // Regression: addPoints used to emit the count label with no `text-font`, so
  // mbgl fell back to "Open Sans Regular,Arial Unicode MS Regular" — present in
  // demotiles, absent from OpenFreeMap Liberty. On Liberty every tile 404'd its
  // glyphs, which does not merely drop the text: it stops the whole source from
  // rendering, so the dataset silently vanished after a style toggle.
  test('omits the cluster count layer unless a font is named', () {
    final rec = _RecordingLayers();
    final layers = MapLibreStyleController()..attachTo(rec);

    layers.addCircleLayersFromPoints('c', const [LatLng(1, 2)], cluster: true);

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
    final layers = MapLibreStyleController()..attachTo(rec);

    layers.addCircleLayersFromPoints(
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
    final layers = MapLibreStyleController()..attachTo(rec);

    layers
      ..addCircleLayersFromPoints('c', const [LatLng(1, 2)], cluster: true)
      ..removeCircleLayersFromPoints('c');

    expect(
      rec.removedLayers,
      containsAll(['c-clusters', 'c-count', 'c-points']),
    );
    expect(rec.removedSources, ['c']);
  });

  test('setPoints replaces data without touching layers', () {
    final rec = _RecordingLayers();
    final layers = MapLibreStyleController()..attachTo(rec);

    layers
      ..addCircleLayersFromPoints('p', const [LatLng(1, 2)])
      ..setPointsData('p', const [LatLng(5, 6), LatLng(7, 8)]);

    expect(rec.layers, hasLength(1), reason: 'no new layers on a data update');
    final data = jsonDecode(rec.lastData!) as Map<String, Object?>;
    expect((data['features'] as List), hasLength(2));
  });

  test('addPoints and setPoints carry per-point properties', () {
    final rec = _RecordingLayers();
    final layers = MapLibreStyleController()..attachTo(rec);

    // Without these, data-driven styling — the whole point of an engine layer —
    // is unreachable through this API.
    layers.addCircleLayersFromPoints(
      'p',
      const [LatLng(60.45, 22.27)],
      properties: const [
        {'kind': 'harbour'},
      ],
    );
    final added =
        ((jsonDecode(rec.sources['p']!) as Map<String, Object?>)['data']
                as Map)['features']
            as List;
    expect(((added.single as Map)['properties'] as Map)['kind'], 'harbour');

    layers.setPointsData(
      'p',
      const [LatLng(59.33, 18.06)],
      properties: const [
        {'kind': 'city'},
      ],
    );
    final updated =
        (jsonDecode(rec.lastData!) as Map<String, Object?>)['features'] as List;
    expect(((updated.single as Map)['properties'] as Map)['kind'], 'city');

    // The bytes are the one path into mbgl's GeoJSON parser, so no number
    // rewriting: 60.45 must not come out as 60 (the style encoder does that).
    expect(rec.lastData, contains('18.06'));
    expect(rec.lastData, contains('59.33'));
  });

  test('queryRenderedFeatures parses clusters and single points', () {
    final rec = _RecordingLayers();
    final layers = MapLibreStyleController()..attachTo(rec);
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
    expect(found[0].clusterId, 7);
    // Flipped back from GeoJSON's [lng, lat].
    expect(found[0].point!.latitude, closeTo(60.45, 1e-9));
    expect(found[0].point!.longitude, closeTo(22.27, 1e-9));

    expect(found[1].isCluster, isFalse);
    expect(found[1].pointCount, 1, reason: 'a lone point counts as one');
    expect(found[1].clusterId, isNull);
  });

  test('queryRenderedFeatures keeps every geometry type, not just points', () {
    final rec = _RecordingLayers();
    final layers = MapLibreStyleController()..attachTo(rec);
    // Turku (north-east) and Stockholm (south-west of it) — asymmetric on both
    // axes, so a swapped or mirrored coordinate cannot pass by symmetry.
    rec.queryJson = jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'id': 'road-7',
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [22.27, 60.45],
              [18.06, 59.33],
            ],
          },
          'properties': {'name': 'E18'},
        },
        {
          'type': 'Feature',
          'id': 12,
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              [
                [22.0, 60.0],
                [23.0, 60.0],
                [23.0, 61.0],
                [22.0, 60.0],
              ],
            ],
          },
          'properties': <String, Object?>{},
        },
      ],
    });

    final found = layers.queryRenderedFeatures(Rect.largest);
    expect(found, hasLength(2), reason: 'a line and a fill both answer now');

    final line = found[0];
    expect(line.id, 'road-7', reason: 'the feature id used to be discarded');
    expect(line.properties['name'], 'E18');
    expect(line.point, isNull, reason: 'a line has no single point');
    final geometry = line.geometry;
    expect(geometry, isA<GeoJsonLineString>());
    final coordinates = (geometry! as GeoJsonLineString).coordinates;
    // Absolute directions, not a round-trip: the first vertex is the NORTHERN
    // and EASTERN one. A symmetric flip would survive a round-trip test.
    expect(coordinates.first.latitude, closeTo(60.45, 1e-9));
    expect(coordinates.first.longitude, closeTo(22.27, 1e-9));
    expect(coordinates.first.latitude, greaterThan(coordinates.last.latitude));
    expect(
      coordinates.first.longitude,
      greaterThan(coordinates.last.longitude),
    );

    expect(found[1].id, 12, reason: 'a numeric id stays a number');
    expect(found[1].geometry, isA<GeoJsonPolygon>());
    expect(
      (found[1].geometry! as GeoJsonPolygon).coordinates.single,
      hasLength(4),
    );
  });

  test('queryRenderedFeatures degrades to empty, never throws', () {
    final rec = _RecordingLayers();
    final layers = MapLibreStyleController()..attachTo(rec);

    // Runs on camera ticks, so a bad/absent payload must not blow up the frame.
    rec.queryJson = null;
    expect(layers.queryRenderedFeatures(Rect.largest), isEmpty);
    rec.queryJson = '{not json';
    expect(layers.queryRenderedFeatures(Rect.largest), isEmpty);
    // Valid JSON, wrong shape at the top level.
    rec.queryJson = '[]';
    expect(layers.queryRenderedFeatures(Rect.largest), isEmpty);
    rec.queryJson = jsonEncode({'type': 'FeatureCollection', 'features': 3});
    expect(layers.queryRenderedFeatures(Rect.largest), isEmpty);
  });

  test('one unreadable feature does not lose the readable ones', () {
    final rec = _RecordingLayers();
    final layers = MapLibreStyleController()..attachTo(rec);
    // These used to throw TypeError, which the `on FormatException` catch did
    // not cover — the method's own dartdoc promised it never throws.
    rec.queryJson = jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        'not a feature at all',
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': ['22.27', '60.45'], // strings, not numbers
          },
          'properties': <String, Object?>{},
        },
        {
          'type': 'Feature',
          'geometry': {'type': 'Point', 'coordinates': <Object?>[]},
          'properties': <String, Object?>{},
        },
        {
          'type': 'Feature',
          'geometry': {'type': 'Sphere', 'coordinates': <Object?>[]},
          'properties': <String, Object?>{},
        },
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [22.27, 60.45],
          },
          'properties': {'ok': true},
        },
      ],
    });

    final found = layers.queryRenderedFeatures(Rect.largest);
    expect(found, hasLength(1));
    expect(found.single.properties['ok'], isTrue);
  });

  // NOTE both rasterizer tests run inside tester.runAsync. RenderRepaintBoundary
  // .toImage() waits on a real callback from the engine's raster pipeline, which
  // flutter_test's fake async never delivers — without runAsync these hang until
  // the 10-minute timeout rather than failing. The production path is unaffected.

  testWidgets('rasterizeWidget paints a widget off-screen', (tester) async {
    await tester.runAsync(() async {
      // Deliberately never added to the visible tree.
      final image = await MapLibreStyleController.rasterizeWidget(
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
      final layers = MapLibreStyleController()..attachTo(rec);

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

  group('per-property mutation', () {
    test('gl-js names all funnel to ONE engine call', () {
      final rec = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(rec);

      // gl-js splits these four ways; mbgl's Layer::setProperty handles them
      // all, so the split is a naming convenience and nothing more.
      style
        ..setPaintProperty('dots', 'circle-color', const Color(0xFF00FF00))
        ..setLayoutProperty('dots', 'circle-sort-key', 3)
        ..setLayerVisible('dots', visible: false)
        ..setFilter('dots', Expr.has('point_count'))
        ..setLayerZoomRange('dots', minZoom: 4, maxZoom: 12);

      expect(rec.properties.map((p) => p.name), [
        'circle-color',
        'circle-sort-key',
        'visibility',
        'filter',
        'minzoom',
        'maxzoom',
      ]);
      // Encoded by the SAME serialiser the typed layers use, so there is no
      // second encoder to drift: a Color becomes #rrggbb, an Expression becomes
      // its JSON array.
      expect(rec.properties[0].valueJson, '"#00ff00"');
      expect(rec.properties[2].valueJson, '"none"');
      expect(rec.properties[3].valueJson, '["has","point_count"]');
      expect(rec.properties[4].valueJson, '4');
    });

    test('setLayerVisible(true) sets visible, not the absence of none', () {
      final rec = _RecordingLayers();
      MapLibreStyleController()
        ..attachTo(rec)
        ..setLayerVisible('dots', visible: true);
      expect(rec.properties.single.valueJson, '"visible"');
    });

    test('moveLayer forwards its beforeId, and null means the top', () {
      final rec = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(rec);
      style
        ..moveLayer('a', beforeId: 'b')
        ..moveLayer('a');
      expect(rec.moves, [
        (layerId: 'a', beforeId: 'b'),
        (layerId: 'a', beforeId: null),
      ]);
    });

    test('every mutator is a no-op before attach', () {
      // The whole surface has to survive being called on an unbound controller,
      // because an app cannot always know when attach happened.
      final style = MapLibreStyleController();
      expect(style.isSupported, isFalse);
      style
        ..setPaintProperty('a', 'circle-color', const Color(0xFF000000))
        ..setLayerVisible('a', visible: true)
        ..setFilter('a', null)
        ..setLayerZoomRange('a', minZoom: 1)
        ..moveLayer('a');
      expect(style.getLayersOrder(), isEmpty);
      expect(style.getLayer('a'), isNull);
      expect(style.getPaintProperty('a', 'circle-color'), isNull);
    });
  });

  group('the read side', () {
    test('decodes JSON, and reports absence as null', () {
      final rec = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(rec);

      rec.propertyResult = '["rgba",0.0,0.0,255.0,1.0]';
      expect(style.getPaintProperty('dots', 'circle-color'), [
        'rgba',
        0.0,
        0.0,
        255.0,
        1.0,
      ]);

      rec.propertyResult = '["has","point_count"]';
      expect(style.getFilter('dots'), ['has', 'point_count']);

      rec.propertyResult = null;
      expect(style.getLayoutProperty('dots', 'visibility'), isNull);

      // Malformed JSON must not throw into a caller that is probably rebuilding
      // a widget.
      rec.propertyResult = '{not json';
      expect(style.getPaintProperty('dots', 'circle-color'), isNull);
    });

    test('getLayersOrder and getLayer', () {
      final rec = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(rec);

      rec.layerIdsResult = const ['background', 'water', 'dots'];
      expect(style.getLayersOrder(), ['background', 'water', 'dots']);

      rec.layerJsonResult = '{"id":"dots","type":"circle","source":"p"}';
      expect(style.getLayer('dots'), {
        'id': 'dots',
        'type': 'circle',
        'source': 'p',
      });

      rec.layerJsonResult = null;
      expect(style.getLayer('nope'), isNull);
    });
  });

  group('sources', () {
    test('getSource returns a handle, or null when absent', () {
      final rec = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(rec);

      rec.sourceJsonResult =
          '{"id":"p","type":"geojson","attribution":"© Someone",'
          '"volatile":false}';
      final source = style.getSource('p');
      expect(source, isNotNull);
      expect(source!.id, 'p');
      expect(source.type, 'geojson');
      expect(source.attribution, '© Someone');
      expect(source.isVolatile, isFalse);
      expect(source.supportsSetData, isTrue);

      rec.sourceJsonResult = null;
      expect(style.getSource('nope'), isNull);
    });

    test('a non-geojson source reports that its data cannot be replaced', () {
      // An engine limit, not a missing binding: mbgl has no data setter on a
      // vector or raster source.
      final rec = _RecordingLayers()
        ..sourceJsonResult =
            '{"id":"v","type":"vector","attribution":null,"volatile":false}';
      final source = (MapLibreStyleController()..attachTo(rec)).getSource('v')!;
      expect(source.supportsSetData, isFalse);
      expect(source.type, 'vector');
    });

    test('setData accepts typed GeoJSON, and encodes it verbatim', () {
      final rec = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(rec);

      style.setSourceData(
        'p',
        GeoJsonData.featureCollection(
          const GeoJsonFeatureCollection([
            GeoJsonFeature(geometry: GeoJsonPoint(LatLng(60.45, 22.27))),
          ]),
        ),
      );
      // Coordinates must survive as doubles — these bytes are the one path into
      // mbgl's GeoJSON parser, so the style encoder's 6.0 -> 6 rewrite must not
      // apply to them.
      expect(rec.sourceData.single.data, contains('22.27'));
      expect(rec.sourceData.single.data, contains('60.45'));

      // A raw string passes straight through, unwrapped.
      style.setSourceData('p', '{"type":"FeatureCollection","features":[]}');
      expect(
        rec.sourceData.last.data,
        '{"type":"FeatureCollection","features":[]}',
      );
    });

    test('the handle setData reaches the same call', () {
      final rec = _RecordingLayers()
        ..sourceJsonResult =
            '{"id":"p","type":"geojson","attribution":null,"volatile":false}';
      final style = MapLibreStyleController()..attachTo(rec);
      style.getSource('p')!.setData('{"type":"FeatureCollection"}');
      expect(rec.sourceData.single.sourceId, 'p');
    });

    test('getSourceIds, and every source call is safe before attach', () {
      final rec = _RecordingLayers()..sourceIdsResult = const ['a', 'b'];
      final style = MapLibreStyleController()..attachTo(rec);
      expect(style.getSourceIds(), ['a', 'b']);

      final unbound = MapLibreStyleController();
      expect(unbound.getSourceIds(), isEmpty);
      expect(unbound.getSource('a'), isNull);
      unbound.setSourceData('a', '{}');
    });
  });

  group('images', () {
    test('updateImage is addImage — mbgl permits it, so this is a name', () {
      final rec = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(rec);
      final pixels = Uint8List(4 * 4 * 4);

      style.addImage('pin', pixels, 4, 4, pixelRatio: 2);
      style.updateImage('pin', pixels, 4, 4, pixelRatio: 2, sdf: true);

      expect(rec.images.length, 1, reason: 'same id, so the map holds one');
      expect(rec.images['pin']!.pr, 2);
    });

    test('hasImage keeps "could not ask" apart from "not there"', () {
      final rec = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(rec);

      rec.hasImageResult = true;
      expect(style.hasImage('pin'), isTrue);
      rec.hasImageResult = false;
      expect(style.hasImage('pin'), isFalse);
      // A timeout must not read as absence, or a caller re-rasterises on every
      // hiccup.
      rec.hasImageResult = null;
      expect(style.hasImage('pin'), isNull);
    });

    test('listImages includes the style sprite, and is safe unbound', () {
      final rec = _RecordingLayers()
        ..imageIdsResult = const ['airport-15', 'pin'];
      expect((MapLibreStyleController()..attachTo(rec)).listImages(), [
        'airport-15',
        'pin',
      ]);
      expect(MapLibreStyleController().listImages(), isEmpty);
      expect(MapLibreStyleController().hasImage('pin'), isNull);
    });
  });

  // 5.9b. Off by default, matching every upstream binding: mbgl drops the whole
  // document on load and gl-js/Apple/Android all require the app to re-add.
  group('retainRuntimeStyle', () {
    ({MapLibreStyleController style, _RecordingLayers platform}) build({
      required bool retain,
    }) {
      final platform = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(platform);
      style.retainRuntimeStyle = retain;
      return (style: style, platform: platform);
    }

    test('off: a style load takes the app\'s layers with it', () {
      final (style: style, platform: platform) = build(retain: false);
      style
        ..addSourceJson('pts', '{"type":"geojson","data":{}}')
        ..addLayerJson('{"id":"dots","type":"circle","source":"pts"}');

      style.snapshotForRetain();
      platform.layersById.clear();
      platform.layers.clear();
      platform.sources.clear();
      style.replayRetained();

      expect(platform.layers, isEmpty, reason: 'nothing to replay when off');
      expect(platform.sources, isEmpty);
    });

    test('on: sources and layers come back, sources first', () {
      final (style: style, platform: platform) = build(retain: true);
      style
        ..addSourceJson('pts', '{"type":"geojson","data":{}}')
        ..addLayerJson('{"id":"dots","type":"circle","source":"pts"}')
        ..addLayerJson('{"id":"labels","type":"symbol","source":"pts"}');

      style.snapshotForRetain();
      // The style load: mbgl drops everything.
      platform.layersById.clear();
      platform.layers.clear();
      platform.sources.clear();
      style.replayRetained();

      expect(
        platform.sources.keys,
        equals(['pts']),
        reason:
            'a layer whose source is missing is rejected outright, so the '
            'source has to be back before the layer is re-added',
      );
      expect(
        platform.layersById.keys,
        equals(['dots', 'labels']),
        reason: 'and in the order the app added them',
      );
    });

    test('on: the snapshot is the LIVE state, not the original add', () {
      final (style: style, platform: platform) = build(retain: true);
      style
        ..addSourceJson('pts', '{"type":"geojson","data":{}}')
        ..addLayerJson('{"id":"dots","type":"circle","source":"pts"}');

      // A property changed AFTER the add. Replaying the add JSON would lose it
      // silently — which is the whole reason this snapshots serialize() instead
      // of remembering what the app passed in.
      platform.layersById['dots'] =
          '{"id":"dots","type":"circle","source":"pts",'
          '"paint":{"circle-color":"#ff0000"}}';

      style.snapshotForRetain();
      platform.layersById.clear();
      platform.layers.clear();
      style.replayRetained();

      expect(platform.layers.single, contains('#ff0000'));
    });

    test('on: a replay carries the LATEST source data, not the first', () {
      final (style: style, platform: platform) = build(retain: true);
      style
        ..addSourceJson(
          'live',
          '{"type":"geojson","data":{"type":"FeatureCollection",'
              '"features":[]}}',
        )
        ..setSourceData('live', '{"type":"FeatureCollection","features":[1]}');

      style.snapshotForRetain();
      platform.sources.clear();
      style.replayRetained();

      // Restoring the data the source was CREATED with would silently rewind a
      // live dataset — and the map would still draw, so nothing would look
      // wrong.
      expect(platform.sources['live'], contains('[1]'));
    });

    test('on: a removed layer stays removed', () {
      final (style: style, platform: platform) = build(retain: true);
      style
        ..addSourceJson('pts', '{"type":"geojson","data":{}}')
        ..addLayerJson('{"id":"dots","type":"circle","source":"pts"}')
        ..addLayerJson('{"id":"gone","type":"circle","source":"pts"}')
        ..removeLayer('gone')
        ..removeSource('pts');

      style.snapshotForRetain();
      platform.layersById.clear();
      platform.layers.clear();
      platform.sources.clear();
      style.replayRetained();

      // The classic failure of a replay cache that only ever grows.
      expect(platform.layersById.keys, equals(['dots']));
      expect(platform.sources, isEmpty, reason: 'the source was removed too');
    });

    test('on: beforeId is deliberately NOT restored', () {
      final (style: style, platform: platform) = build(retain: true);
      style.addLayerJson(
        '{"id":"dots","type":"circle","source":"pts"}',
        beforeId: 'a-layer-in-the-outgoing-document',
      );

      style.snapshotForRetain();
      platform.layersById.clear();
      platform.layers.clear();
      platform.beforeIds.clear();
      style.replayRetained();

      expect(
        platform.beforeIds,
        equals([null]),
        reason:
            'beforeId named a layer in the OUTGOING document; an '
            'unresolvable one is an error, not a fallback, so the replay puts '
            'the layer on top instead',
      );
    });

    test('replaying twice does not double-add', () {
      final (style: style, platform: platform) = build(retain: true);
      style.addLayerJson('{"id":"dots","type":"circle","source":"pts"}');
      style.snapshotForRetain();
      platform.layers.clear();
      style
        ..replayRetained()
        ..replayRetained();
      expect(platform.layers.length, 1, reason: 'the snapshot is consumed');
    });
  });

  // 5.10. The recipe invents four ids; before the handle, undoing that meant
  // knowing the scheme, and only removePoints did.
  group('point-layer recipe', () {
    test('the handle reports the ids the recipe invented', () {
      final platform = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(platform);

      final plain = style.addCircleLayersFromPoints('plain', const [
        LatLng(60, 22),
      ]);
      expect(plain.layerIds, equals(['plain']));
      expect(plain.sourceId, 'plain');
      expect(plain.clustered, isFalse);

      final clustered = style.addCircleLayersFromPoints(
        'bulk',
        const [LatLng(60, 22)],
        cluster: true,
        clusterTextFont: const ['Open Sans Regular'],
      );
      expect(
        clustered.layerIds,
        equals(['bulk-clusters', 'bulk-count', 'bulk-points']),
        reason: 'bottom-most first, and the caller never guesses the scheme',
      );
    });

    test('no clusterTextFont means no count layer, and the handle says so', () {
      final platform = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(platform);
      final handle = style.addCircleLayersFromPoints('bulk', const [
        LatLng(60, 22),
      ], cluster: true);
      // Omitted on purpose: naming a font the style does not serve makes mbgl
      // 404 the glyph range on every tile.
      expect(handle.layerIds, isNot(contains('bulk-count')));
      expect(platform.layersById.keys, isNot(contains('bulk-count')));
    });

    test('remove() cleans up everything the recipe made', () {
      final platform = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(platform);
      style
          .addCircleLayersFromPoints(
            'bulk',
            const [LatLng(60, 22)],
            cluster: true,
            clusterTextFont: const ['Open Sans Regular'],
          )
          .remove();

      expect(platform.layersById, isEmpty);
      expect(platform.sources, isEmpty);
    });

    test('the deprecated names still work, and land on the same layers', () {
      final platform = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(platform);
      // ignore: deprecated_member_use_from_same_package
      style.addPoints('bulk', const [LatLng(60, 22)]);
      expect(platform.layersById.keys, equals(['bulk']));
      // ignore: deprecated_member_use_from_same_package
      style.removePoints('bulk');
      expect(platform.layersById, isEmpty);
    });
  });

  // 6.1-6.3.
  group('queries', () {
    const collection =
        '{"type":"FeatureCollection","features":['
        '{"type":"Feature","id":7,"properties":{"kind":"city"},'
        '"geometry":{"type":"Point","coordinates":[22.27,60.45]}}]}';

    test('a point query pads into a box rather than asking for zero area', () {
      final platform = _RecordingLayers()..queryJson = collection;
      final style = MapLibreStyleController()..attachTo(platform);

      style.queryRenderedFeaturesAt(const Offset(100, 50), tolerance: 8);
      // A literal point misses a circle the user was plainly aiming at, which
      // is why gl-js and both SDKs pad a tap too.
      expect(platform.queriedRect, const Rect.fromLTRB(92, 42, 108, 58));
    });

    test('a filter is handed to the ENGINE, not applied in Dart', () {
      final platform = _RecordingLayers()..queryJson = collection;
      final style = MapLibreStyleController()..attachTo(platform);

      style.queryRenderedFeatures(
        const Rect.fromLTRB(0, 0, 10, 10),
        filter: Expr.equals(Expr.get('kind'), const StyleValue('city')),
      );
      // The EXACT document, not `contains`: a filter built with the wrong
      // arity still contains both words, and the engine silently ignores it —
      // which is how the first version of this test passed over a filter mbgl
      // rejected as unparseable.
      expect(platform.queriedFilter, equals('["==",["get","kind"],"city"]'));
    });

    test(
      'the sync query stays silent on failure — it runs on camera ticks',
      () {
        final platform = _RecordingLayers()..queryJson = null;
        final style = MapLibreStyleController()..attachTo(platform);
        expect(
          style.queryRenderedFeatures(const Rect.fromLTRB(0, 0, 10, 10)),
          isEmpty,
          reason:
              'throwing into a paint callback is worse than a lost frame of '
              'query results',
        );
      },
    );

    test('the async query THROWS on failure, which is the whole point', () {
      final platform = _RecordingLayers()..queryJson = null;
      final style = MapLibreStyleController()..attachTo(platform);
      expect(
        style.queryRenderedFeaturesAsync(const Rect.fromLTRB(0, 0, 10, 10)),
        throwsA(isA<MapQueryException>()),
      );
    });

    test('an unattached controller reports it rather than answering empty', () {
      final style = MapLibreStyleController();
      expect(
        style.queryRenderedFeaturesAsync(const Rect.fromLTRB(0, 0, 10, 10)),
        throwsA(isA<MapQueryException>()),
      );
    });

    test('querySourceFeatures forwards the source layers and the filter', () {
      final platform = _RecordingLayers()..sourceQueryResult = collection;
      final style = MapLibreStyleController()..attachTo(platform);

      final features = style.querySourceFeatures(
        'roads',
        sourceLayers: const ['transportation'],
        filter: Expr.equals(Expr.get('kind'), const StyleValue('city')),
      );
      expect(features, hasLength(1));
      expect(features.single.id, 7);
      expect(platform.sourceQueries.single.sourceId, 'roads');
      expect(
        platform.sourceQueries.single.sourceLayers,
        equals(['transportation']),
      );
      expect(
        platform.sourceQueries.single.filterJson,
        equals('["==",["get","kind"],"city"]'),
      );
    });

    test(
      'a geographic query needs a projector, and says so by returning empty',
      () {
        // _RecordingLayers is not a projector, so the bounds cannot be projected.
        final platform = _RecordingLayers()..queryJson = collection;
        final style = MapLibreStyleController()..attachTo(platform);
        expect(
          style.queryRenderedFeaturesIn(
            const LatLngBounds(
              southwest: LatLng(59, 18),
              northeast: LatLng(61, 23),
            ),
          ),
          isEmpty,
        );
        expect(
          platform.queriedRect,
          isNull,
          reason: 'and it must not fall through to a wrong box',
        );
      },
    );
  });

  // 6.4.
  group('feature state', () {
    test('a set is JSON-encoded and keyed by source and feature', () {
      final platform = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(platform);
      style.setFeatureState('pts', 7, {'selected': true, 'score': 3});
      expect(
        platform.featureStates['pts/7'],
        equals('{"selected":true,"score":3}'),
      );
    });

    test('a numeric and a string id reach the engine the same way', () {
      final platform = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(platform);
      style
        ..setFeatureState('pts', 7, {'a': 1})
        ..setFeatureState('pts', '7', {'a': 1});
      // GeoJSON ids may be either; mbgl keys on the string form, so 7 and '7'
      // must not become two different features.
      expect(platform.featureStates.keys, equals(['pts/7']));
    });

    test('a failed read is null, an empty state is a map', () {
      final platform = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(platform);

      platform.featureStateResult = '{}';
      expect(style.getFeatureState('pts', 1), isEmpty);
      platform.featureStateResult = null;
      expect(
        style.getFeatureState('pts', 1),
        isNull,
        reason: '"could not ask" must stay distinguishable from "nothing set"',
      );
    });

    test('removing without a featureId clears the whole source', () {
      final platform = _RecordingLayers();
      final style = MapLibreStyleController()..attachTo(platform);
      style
        ..setFeatureState('pts', 1, {'a': 1})
        ..setFeatureState('pts', 2, {'a': 1})
        ..setFeatureState('other', 1, {'a': 1})
        ..removeFeatureState('pts');
      expect(platform.featureStates.keys, equals(['other/1']));
    });
  });
}
