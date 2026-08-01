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
  @override
  void addLayerJson(String json, {String? beforeId}) => layers.add(json);
  @override
  void setGeoJsonData(String sourceId, String geoJson) => lastData = geoJson;
  @override
  void removeLayer(String id) => removedLayers.add(id);

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
  String? getLayerJson(String layerId) => layerJsonResult;
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
    final layers = MapLibreStyleController();
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
    final layers = MapLibreStyleController()..attachTo(rec);
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
    final layers = MapLibreStyleController()..attachTo(rec);

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
    final layers = MapLibreStyleController()..attachTo(rec);

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
    final layers = MapLibreStyleController()..attachTo(rec);

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
    final layers = MapLibreStyleController()..attachTo(rec);

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
    final layers = MapLibreStyleController()..attachTo(rec);

    layers
      ..addPoints('p', const [LatLng(1, 2)])
      ..setPoints('p', const [LatLng(5, 6), LatLng(7, 8)]);

    expect(rec.layers, hasLength(1), reason: 'no new layers on a data update');
    final data = jsonDecode(rec.lastData!) as Map<String, Object?>;
    expect((data['features'] as List), hasLength(2));
  });

  test('addPoints and setPoints carry per-point properties', () {
    final rec = _RecordingLayers();
    final layers = MapLibreStyleController()..attachTo(rec);

    // Without these, data-driven styling — the whole point of an engine layer —
    // is unreachable through this API.
    layers.addPoints(
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

    layers.setPoints(
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
}
