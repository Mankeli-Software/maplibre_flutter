import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

/// Records the documents that reached the platform, so the generated JSON can
/// be asserted verbatim rather than described.
class _RecordingLayers implements MapLibreStyleLayers {
  final Map<String, String> sources = {};
  final List<String> layers = [];
  final List<String?> beforeIds = [];
  String? lastData;

  @override
  void addSourceJson(String id, String json) => sources[id] = json;
  @override
  void addLayerJson(String json, {String? beforeId}) {
    layers.add(json);
    beforeIds.add(beforeId);
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
  String? getSourceJson(String sourceId) => sourceJsonResult;

  @override
  List<String>? getSourceIds() => sourceIdsResult;

  @override
  void setGeoJsonData(String sourceId, String geoJson) => lastData = geoJson;
  @override
  void removeLayer(String id) {}
  @override
  void removeSource(String id) {}
  @override
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) {}
  @override
  bool? hasImage(String id) => null;
  @override
  List<String>? getImageIds() => null;

  @override
  void removeImage(String id) {}

  ({Duration? duration, Duration? delay, bool placement})? transitions;

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
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions = true,
  }) => transitions = (
    duration: duration,
    delay: delay,
    placement: placementTransitions,
  );
  @override
  String? queryRenderedFeaturesJson(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
    String? filterJson,
  }) => null;

  @override
  Future<String?> queryRenderedFeaturesAsyncJson(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
    String? filterJson,
  }) async => null;

  @override
  String? querySourceFeaturesJson(
    String sourceId, {
    List<String>? sourceLayers,
    String? filterJson,
  }) => null;

  @override
  void setFeatureStateJson(
    String sourceId,
    String featureId,
    String stateJson, {
    String? sourceLayer,
  }) {}

  @override
  String? getFeatureStateJson(
    String sourceId,
    String featureId, {
    String? sourceLayer,
  }) => null;

  @override
  void removeFeatureState(
    String sourceId, {
    String? featureId,
    String? sourceLayer,
    String? stateKey,
  }) {}
}

void main() {
  group('generated layers', () {
    // The point of the typed API is that it serialises to exactly the style
    // JSON we used to hand-write, so these expectations are spelled out in
    // full: any drift in key names, key order or number/colour formatting is a
    // failure, not a silently different document.
    test('CircleLayer serialises to the hand-written equivalent', () {
      const layer = CircleLayer(
        id: 'pts',
        source: 'src',
        circleRadius: StyleValue(6),
        circleColor: StyleValue(Color(0xFF1565C0)),
        circleStrokeWidth: StyleValue(1),
        circleStrokeColor: StyleValue(Color(0xFFFFFFFF)),
      );

      expect(
        jsonEncode(layer.toJson()),
        '{"id":"pts","type":"circle","source":"src","paint":'
        '{"circle-radius":6,"circle-color":"#1565c0",'
        '"circle-stroke-width":1,"circle-stroke-color":"#ffffff"}}',
      );
    });

    test('emits layout, paint and the common layer keys in spec order', () {
      final layer = CircleLayer(
        id: 'all',
        source: 'src',
        metadata: const {'maplibre:owner': 'test'},
        sourceLayer: 'points',
        minZoom: 4,
        maxZoom: 14.5,
        filter: Expr.has('point_count'),
        circleSortKey: const StyleValue(2),
        visibility: StyleVisibility.none,
        circleRadius: const StyleValue(6),
        circleRadiusTransition: const StyleTransition(duration: 250, delay: 0),
        circleTranslate: const StyleValue([1, -2]),
        circlePitchAlignment: const StyleValue(CirclePitchAlignment.map),
      );

      expect(
        jsonEncode(layer.toJson()),
        '{"id":"all","type":"circle",'
        '"metadata":{"maplibre:owner":"test"},"source":"src",'
        '"source-layer":"points","minzoom":4,"maxzoom":14.5,'
        '"filter":["has","point_count"],'
        '"layout":{"circle-sort-key":2,"visibility":"none"},'
        '"paint":{"circle-radius":6,'
        '"circle-radius-transition":{"duration":250,"delay":0},'
        '"circle-translate":[1,-2],"circle-pitch-alignment":"map"}}',
      );
    });

    test('omits layout and paint entirely when nothing is set', () {
      const layer = CircleLayer(id: 'bare', source: 'src');
      expect(layer.toJson().keys, ['id', 'type', 'source']);
      expect(layer.type, 'circle');
    });

    test('an expression is accepted wherever a constant is', () {
      // Expression extends StyleValue<Never>, so it is assignable to every
      // StyleValue<T> property. This is a compile-time claim; the assertion
      // just pins the serialisation.
      final layer = CircleLayer(
        id: 'dd',
        source: 'src',
        circleRadius: Expr.step(Expr.get('point_count'), 18, 100, 24),
        circleColor: Expr.get('color'),
      );

      expect(
        (layer.toJson()['paint']! as Map<String, Object?>)['circle-radius'],
        [
          'step',
          ['get', 'point_count'],
          18,
          100,
          24,
        ],
      );
    });

    test('produces the documents the native render tests prove render', () {
      // The typed API cannot be checked against the GPU from here: the engine
      // tests live in maplibre_flutter_core, which must not depend on the
      // app-facing package. So pin equality with the exact documents
      // packages/maplibre_flutter_core/test/maplibre_flutter_core_test.dart
      // adds to a real map and then counts magenta pixels for.
      const nativeCircleLayer = '''
        {"id":"pts-circles","type":"circle","source":"pts",
         "paint":{"circle-radius":4,"circle-color":"#ff00ff"}}
      ''';
      const nativeClusterLayer = '''
        {"id":"clusters","type":"circle","source":"c","filter":["has","point_count"],
         "paint":{"circle-radius":14,"circle-color":"#ff00ff"}}
      ''';
      const magenta = Color(0xFFFF00FF);

      expect(
        const CircleLayer(
          id: 'pts-circles',
          source: 'pts',
          circleRadius: StyleValue(4),
          circleColor: StyleValue(magenta),
        ).toJson(),
        jsonDecode(nativeCircleLayer),
      );
      expect(
        CircleLayer(
          id: 'clusters',
          source: 'c',
          filter: Expr.has('point_count'),
          circleRadius: const StyleValue(14),
          circleColor: const StyleValue(magenta),
        ).toJson(),
        jsonDecode(nativeClusterLayer),
      );
    });

    test('SymbolLayer: enums, string arrays and a formatted text field', () {
      final layer = SymbolLayer(
        id: 'labels',
        source: 'pts',
        textField: Expr.get('name'),
        textFont: const StyleValue(['Noto Sans Regular']),
        textSize: const StyleValue(12),
        textAnchor: const StyleValue(TextAnchor.top),
        textOffset: const StyleValue([0, 1.1]),
        textTransform: const StyleValue(TextTransform.uppercase),
        iconImage: const StyleValue('pin'),
        iconAllowOverlap: const StyleValue(true),
        textColor: const StyleValue(Color(0xFFFFFFFF)),
        textHaloWidth: const StyleValue(1.5),
      );

      expect(
        jsonEncode(layer.toJson()),
        // Key order is the spec's own, not the order the arguments were written
        // in — that is what makes the output stable across regenerations.
        '{"id":"labels","type":"symbol","source":"pts","layout":'
        '{"icon-allow-overlap":true,"icon-image":"pin",'
        '"text-field":["get","name"],"text-font":["Noto Sans Regular"],'
        '"text-size":12,"text-anchor":"top","text-transform":"uppercase",'
        '"text-offset":[0,1.1]},'
        '"paint":{"text-color":"#ffffff","text-halo-width":1.5}}',
      );
    });

    test('LineLayer: enum layout values and a dasharray', () {
      const layer = LineLayer(
        id: 'route',
        source: 'route',
        lineCap: StyleValue(LineCap.round),
        lineJoin: StyleValue(LineJoin.round),
        lineColor: StyleValue(Color(0xFF5E35B1)),
        lineWidth: StyleValue(2),
        lineDasharray: StyleValue([2, 1.5]),
      );

      expect(
        jsonEncode(layer.toJson()),
        '{"id":"route","type":"line","source":"route",'
        '"layout":{"line-cap":"round","line-join":"round"},'
        '"paint":{"line-color":"#5e35b1","line-width":2,'
        '"line-dasharray":[2,1.5]}}',
      );
    });

    test('a sourceless layer type has no source, source-layer or filter', () {
      // `background` draws no features, so the generator omits those three
      // rather than letting a caller write an invalid document.
      const layer = BackgroundLayer(
        id: 'bg',
        backgroundColor: StyleValue(Color(0xFF102027)),
      );
      expect(jsonEncode(layer.toJson()), '''
{"id":"bg","type":"background","paint":{"background-color":"#102027"}}''');
      expect(layer.toJson().containsKey('source'), isFalse);
    });

    test('a constant-only property takes no expression', () {
      // `visibility` is `property-type: constant` in the spec, so the generator
      // gives it the plain enum type — there is no StyleValue to smuggle an
      // expression through. Documented here because it is a design guarantee.
      const layer = CircleLayer(
        id: 'v',
        source: 'src',
        visibility: StyleVisibility.visible,
      );
      expect(
        (layer.toJson()['layout']! as Map<String, Object?>)['visibility'],
        'visible',
      );
    });
  });

  group('generated sources', () {
    test('GeoJsonSource serialises to the hand-written equivalent', () {
      final source = GeoJsonSource(
        data: GeoJsonData.points(const [LatLng(60.45, 22.27)]),
        cluster: true,
        clusterRadius: 50,
        clusterMaxZoom: 14,
      );

      // Keys follow the spec's own order: type, data, then the options.
      expect(
        jsonEncode(source.toJson()),
        '{"type":"geojson","data":{"type":"FeatureCollection","features":'
        '[{"type":"Feature","geometry":{"type":"Point","coordinates":'
        '[22.27,60.45]},"properties":{}}]},'
        '"cluster":true,"clusterRadius":50,"clusterMaxZoom":14}',
      );
    });

    test(
      'non-geojson sources generate too, with spec-correct type strings',
      () {
        // `raster-dem` is the case worth pinning: the SCHEMA key is
        // `source_raster_dem`, but the type string in a style document is
        // hyphenated, so the generator takes it from the schema's own enum.
        const dem = RasterDemSource(
          tiles: ['https://tiles.test/{z}/{x}/{y}.png'],
          encoding: RasterDemEncoding.terrarium,
          tileSize: 256,
        );
        expect(
          jsonEncode(dem.toJson()),
          '{"type":"raster-dem",'
          '"tiles":["https://tiles.test/{z}/{x}/{y}.png"],'
          '"tileSize":256,"encoding":"terrarium"}',
        );

        // Same-named enums on different sources stay distinct types.
        const vector = VectorSource(
          url: 'https://tiles.test/tiles.json',
          scheme: VectorScheme.tms,
        );
        expect(
          jsonEncode(vector.toJson()),
          '{"type":"vector","url":"https://tiles.test/tiles.json",'
          '"scheme":"tms"}',
        );

        // An array-of-pairs property (image coordinates) nests correctly.
        const image = ImageSource(
          url: 'https://x.test/overlay.png',
          coordinates: [
            [21.0, 61.0],
            [22.0, 61.0],
            [22.0, 60.0],
            [21.0, 60.0],
          ],
        );
        expect((image.toJson()['coordinates']! as List).first, [21, 61]);
      },
    );

    test('a url data source is just the string', () {
      const source = GeoJsonSource(
        data: GeoJsonData.url('https://example.test/points.geojson'),
      );
      expect(
        jsonEncode(source.toJson()),
        '{"type":"geojson","data":"https://example.test/points.geojson"}',
      );
    });

    test('GeoJsonData.points flips to [lng, lat] and keeps doubles', () {
      final data =
          GeoJsonData.points(const [LatLng(1, 2)]).toJson()!
              as Map<String, Object?>;
      final feature =
          (data['features']! as List).single as Map<String, Object?>;
      // Coordinates stay doubles: mbgl's GeoJSON parser is fed exactly what
      // every other GeoJSON producer emits.
      expect(((feature['geometry']! as Map)['coordinates']! as List), <double>[
        2,
        1,
      ]);
      expect(jsonEncode(feature['geometry']), contains('[2.0,1.0]'));
    });

    test('GeoJsonData.points attaches per-point properties', () {
      final data =
          GeoJsonData.points(
                const [LatLng(1, 2), LatLng(3, 4)],
                properties: const [
                  {'name': 'a'},
                  {'name': 'b'},
                ],
              ).toJson()!
              as Map<String, Object?>;
      final features = (data['features']! as List).cast<Map<String, Object?>>();
      expect(features.map((f) => (f['properties']! as Map)['name']), [
        'a',
        'b',
      ]);
    });

    test('GeoJsonData.points rejects mismatched properties', () {
      expect(
        () => GeoJsonData.points(
          const [LatLng(1, 2)],
          properties: const [{}, {}],
        ),
        throwsArgumentError,
      );
    });

    test('the typed constructors emit RFC 7946 with no number rewriting', () {
      // The style encoder turns 6.0 into 6; GeoJsonData deliberately opts out,
      // because these bytes are the one path into mbgl's GeoJSON parser.
      final feature = GeoJsonData.feature(
        const GeoJsonFeature(
          id: 'probe',
          geometry: GeoJsonPoint(LatLng(60.45, 6)),
        ),
      );
      expect(jsonEncode(feature.toJson()), contains('[6.0,60.45]'));
      expect(jsonEncode(feature.toJson()), contains('"id":"probe"'));

      final collection = GeoJsonData.featureCollection(
        const GeoJsonFeatureCollection([
          GeoJsonFeature(geometry: GeoJsonPoint(LatLng(60.45, 22.27))),
        ]),
      );
      final decoded =
          jsonDecode(jsonEncode(collection.toJson())) as Map<String, Object?>;
      expect(decoded['type'], 'FeatureCollection');
      expect((decoded['features']! as List), hasLength(1));

      final geometry = GeoJsonData.geometry(
        const GeoJsonLineString([LatLng(60.45, 22.27), LatLng(59.33, 18.06)]),
      );
      final line = geometry.toJson()! as Map<String, Object?>;
      expect(line['type'], 'LineString');
      // Absolute directions: the first vertex is the northern, eastern one,
      // and GeoJSON puts longitude first.
      expect((line['coordinates']! as List).first, [22.27, 60.45]);
    });
  });

  group('value encoding', () {
    test('whole numbers serialise as ints, fractions as doubles', () {
      const layer = CircleLayer(
        id: 'n',
        source: 's',
        circleRadius: StyleValue(18),
        circleBlur: StyleValue(0.5),
      );
      final paint = layer.toJson()['paint']! as Map<String, Object?>;
      expect(paint['circle-radius'], 18);
      expect(jsonEncode(paint['circle-radius']), '18');
      expect(paint['circle-blur'], 0.5);
    });

    test('opaque colours are hex, translucent ones rgba', () {
      const opaque = CircleLayer(
        id: 'c',
        source: 's',
        circleColor: StyleValue(Color(0xFFF57C00)),
      );
      const faded = CircleLayer(
        id: 'c',
        source: 's',
        circleColor: StyleValue(Color(0x80F57C00)),
      );
      expect((opaque.toJson()['paint']! as Map)['circle-color'], '#f57c00');
      expect(
        (faded.toJson()['paint']! as Map)['circle-color'],
        startsWith('rgba(245,124,0,'),
      );
    });

    test('StyleValue equality is by value', () {
      expect(const StyleValue<double>(6), const StyleValue<double>(6));
      expect(const StyleValue<double>(6), isNot(const StyleValue<double>(7)));
      expect(Expr.get('a'), Expr.get('a'));
      expect(Expr.get('a'), isNot(Expr.get('b')));
    });
  });

  group('expressions', () {
    test('drops arguments the caller omitted', () {
      expect(Expr.zoom().toJson(), ['zoom']);
      expect(Expr.get('name').toJson(), ['get', 'name']);
      expect(Expr.has('point_count').toJson(), ['has', 'point_count']);
    });

    test('keeps an explicit null, which is meaningful in the spec', () {
      // `_unset` is a distinct sentinel precisely so `["literal", null]` is
      // expressible.
      expect(Expr.literal(null).toJson(), ['literal', null]);
    });

    test('nests expressions, colours and enums', () {
      expect(Expr.not(Expr.has('point_count')).toJson(), [
        '!',
        ['has', 'point_count'],
      ]);
      expect(Expr.raw(['to-color', const Color(0xFF00FF00)]).toJson(), [
        'to-color',
        '#00ff00',
      ]);
      expect(Expr.raw(['literal', CirclePitchAlignment.viewport]).toJson(), [
        'literal',
        'viewport',
      ]);
    });

    test('symbolic and reserved operators are renamed, not dropped', () {
      // The spec name is what ends up in the JSON; only the Dart method name
      // differs, and every one of the 84 operators has a builder.
      expect(Expr.notEquals(Expr.get('a'), 1).toJson()[0], '!=');
      expect(Expr.sum(1, 2).toJson()[0], '+');
      expect(Expr.lessThanOrEqual(1, 2).toJson()[0], '<=');
      expect(Expr.caseOf(true, 1, 2).toJson()[0], 'case');
      expect(Expr.variable('x').toJson()[0], 'var');
      expect(Expr.isIn('a', 'abc').toJson()[0], 'in');
      expect(Expr.toStringOp(1).toJson()[0], 'to-string');
    });
  });

  group('controller', () {
    test('addLayer / addSource forward the encoded document', () {
      final rec = _RecordingLayers();
      final layers = MapLibreStyleController()..attachTo(rec);

      layers
        ..addSource(
          'src',
          const GeoJsonSource(data: GeoJsonData.url('https://x.test/a.json')),
        )
        ..addLayer(
          const CircleLayer(id: 'l', source: 'src'),
          beforeId: 'labels',
        );

      expect(rec.sources['src'], contains('"type":"geojson"'));
      expect(rec.layers.single, '{"id":"l","type":"circle","source":"src"}');
      expect(rec.beforeIds.single, 'labels', reason: 'beforeId is forwarded');
    });

    test('addLayer / addSource are no-ops before attach', () {
      final layers = MapLibreStyleController();
      expect(
        () => layers
          ..addSource('s', const GeoJsonSource(data: GeoJsonData.url('u')))
          ..addLayer(const CircleLayer(id: 'l', source: 's')),
        returnsNormally,
      );
    });
  });

  group('addPoints on the typed API', () {
    // addPoints used to build these documents by hand. Pinning them verbatim is
    // the proof that the generated layers express what we hand-rolled — the
    // point of definition-of-done item 4 in docs/typed-style-api.md.
    test('unclustered: one source, one circle layer', () {
      final rec = _RecordingLayers();
      final layers = MapLibreStyleController()..attachTo(rec);

      layers.addCircleLayersFromPoints('pts', const [LatLng(60.45, 22.27)]);

      expect(
        rec.sources['pts'],
        '{"type":"geojson","data":{"type":"FeatureCollection","features":'
        '[{"type":"Feature","geometry":{"type":"Point","coordinates":'
        '[22.27,60.45]},"properties":{}}]}}',
      );
      expect(
        rec.layers.single,
        '{"id":"pts","type":"circle","source":"pts","paint":'
        '{"circle-radius":5,"circle-color":"#1565c0",'
        '"circle-stroke-width":1,"circle-stroke-color":"#ffffff"}}',
      );
    });

    test('clustered: cluster options, complementary filters, step radius', () {
      final rec = _RecordingLayers();
      final layers = MapLibreStyleController()..attachTo(rec);

      layers.addCircleLayersFromPoints('c', const [
        LatLng(1, 2),
      ], cluster: true);

      expect(
        rec.sources['c'],
        endsWith('"cluster":true,"clusterRadius":50,"clusterMaxZoom":14}'),
      );
      expect(rec.layers, hasLength(2));
      expect(
        rec.layers[0],
        '{"id":"c-clusters","type":"circle","source":"c",'
        '"filter":["has","point_count"],"paint":{"circle-radius":'
        '["step",["get","point_count"],18,100,24.3,750,31.5],'
        '"circle-color":"#f57c00","circle-stroke-width":2,'
        '"circle-stroke-color":"#ffffff"}}',
      );
      expect(
        rec.layers[1],
        '{"id":"c-points","type":"circle","source":"c",'
        '"filter":["!",["has","point_count"]],"paint":{"circle-radius":5,'
        '"circle-color":"#1565c0","circle-stroke-width":1,'
        '"circle-stroke-color":"#ffffff"}}',
      );
    });

    test('setPoints re-encodes the feature collection only', () {
      final rec = _RecordingLayers();
      final layers = MapLibreStyleController()..attachTo(rec);

      layers.setPointsData('p', const [LatLng(1, 2)]);

      expect(
        rec.lastData,
        '{"type":"FeatureCollection","features":[{"type":"Feature",'
        '"geometry":{"type":"Point","coordinates":[2.0,1.0]},'
        '"properties":{}}]}',
      );
    });
  });
}
