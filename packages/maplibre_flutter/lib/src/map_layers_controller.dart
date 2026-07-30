import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:meta/meta.dart';

/// One feature the engine drew, as returned by
/// [MapLibreLayersController.queryRenderedFeatures].
@immutable
class MapLibreQueriedFeature {
  const MapLibreQueriedFeature({required this.point, required this.properties});

  /// Where the engine placed it. For a cluster this is the cluster's own
  /// position, which is not any one of the underlying points.
  final LatLng point;

  /// The feature's properties. Clustered sources add `point_count`,
  /// `point_count_abbreviated` and `cluster_id`.
  final Map<String, Object?> properties;

  /// True when this is a cluster rather than a single point.
  bool get isCluster => properties['point_count'] != null;

  /// How many points this cluster stands for; 1 for a single point.
  int get pointCount => (properties['point_count'] as num?)?.toInt() ?? 1;

  @override
  String toString() =>
      'MapLibreQueriedFeature($point, cluster: $isCluster, count: $pointCount)';
}

/// Engine-drawn map data: the scalable half of the annotation story.
///
/// Reach for this when there are more points than widgets can carry. The rule of
/// thumb from this repo's own measurements (macOS release):
///
/// * **Widget markers** (`MapLibreMap.markers`) — real Flutter widgets, so they
///   can animate, hold gestures and contain anything. Smooth to roughly a few
///   hundred rich children; each costs a render object painted every camera tick.
/// * **Engine layers** (this class) — drawn by mbgl with the map, so they are
///   glued to it by construction and scale to the hundreds of thousands, with
///   clustering built in. In exchange they are pictures: no child gestures, no
///   per-marker animation.
///
/// The two compose. The usual shape is bulk data here, and a handful of widget
/// markers for the things that must be live.
///
/// Reached from the app-facing controller as `controller.layers`. Only available
/// on renderers that can do it (the `mbgl-core` tiers); [isSupported] tells you.
class MapLibreLayersController {
  MapLibreLayersController();

  MapLibreStyleLayers? _layers;

  /// Whether the bound renderer can draw engine layers at all. False before the
  /// map attaches, and on renderers without the capability — every method below
  /// is a no-op in that case, so feature-detecting is optional.
  bool get isSupported => _layers != null;

  /// Binds the platform controller (called by the widget on attach).
  @internal
  void attachTo(Object? platform) {
    _layers = platform is MapLibreStyleLayers ? platform : null;
  }

  // --- Raw style-spec access --------------------------------------------------
  // MapLibre Style Spec JSON, the same documents maplibre-gl-js takes. This is
  // the full-power escape hatch: expressions, filters, data-driven styling, any
  // layer type.
  //
  // TODO(typed-style-api): a typed Dart layer/source API over this (CircleLayer(
  // circleRadius: ...), expression builders) is the intended end state. JSON is
  // the right primitive underneath, but it is stringly-typed for callers.

  /// Adds a style source under [id]. Throws [ArgumentError] on invalid JSON.
  void addSourceJson(String id, String json) =>
      _layers?.addSourceJson(id, json);

  /// Adds a style layer; [beforeId] inserts beneath an existing layer.
  void addLayerJson(String json, {String? beforeId}) =>
      _layers?.addLayerJson(json, beforeId: beforeId);

  /// Replaces a geojson source's data — the cheap path for live datasets.
  void setGeoJsonData(String sourceId, String geoJson) =>
      _layers?.setGeoJsonData(sourceId, geoJson);

  void removeLayer(String id) => _layers?.removeLayer(id);

  void removeSource(String id) => _layers?.removeSource(id);

  /// Registers an icon (raw premultiplied RGBA) for `icon-image`. See
  /// [addWidgetIcon] to build one from a Flutter widget.
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) => _layers?.addImage(
    id,
    rgba,
    width,
    height,
    pixelRatio: pixelRatio,
    sdf: sdf,
  );

  void removeImage(String id) => _layers?.removeImage(id);

  // --- Queries ----------------------------------------------------------------

  /// The features the engine actually drew inside [rect] (logical pixels in the
  /// map widget's own coordinate space).
  ///
  /// This is how you find out what is on screen without duplicating the
  /// engine's work. On a clustered source it returns the **clusters**
  /// themselves — each with [MapLibreQueriedFeature.pointCount] and the
  /// position mbgl placed it at — so cluster bubbles can be drawn as Flutter
  /// widgets over the top, or hit-tested for a tap, without reimplementing
  /// clustering in Dart.
  ///
  /// Empty when nothing matched, and when the renderer is unavailable or the
  /// query timed out. Restrict to specific [layerIds] to keep results small.
  List<MapLibreQueriedFeature> queryRenderedFeatures(
    Rect rect, {
    List<String>? layerIds,
  }) {
    final json = _layers?.queryRenderedFeaturesJson(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
      layerIds: layerIds,
    );
    if (json == null || json.isEmpty) return const [];
    try {
      final decoded = jsonDecode(json) as Map<String, Object?>;
      final features = decoded['features'] as List<Object?>? ?? const [];
      final out = <MapLibreQueriedFeature>[];
      for (final f in features) {
        final feature = f as Map<String, Object?>;
        final geometry = feature['geometry'] as Map<String, Object?>?;
        if (geometry == null || geometry['type'] != 'Point') continue;
        final coords = geometry['coordinates'] as List<Object?>?;
        if (coords == null || coords.length < 2) continue;
        final properties =
            (feature['properties'] as Map<String, Object?>?) ??
            const <String, Object?>{};
        out.add(
          MapLibreQueriedFeature(
            // GeoJSON is [lng, lat].
            point: LatLng(
              (coords[1] as num).toDouble(),
              (coords[0] as num).toDouble(),
            ),
            properties: properties,
          ),
        );
      }
      return out;
    } on FormatException {
      // Malformed payload should degrade to "nothing found", never throw into a
      // caller that is likely running this on a camera tick.
      return const [];
    }
  }

  // --- Convenience ------------------------------------------------------------

  /// Adds [points] as an engine-drawn circle layer, optionally clustered.
  ///
  /// The common case in one call: builds the GeoJSON, the source and the layers.
  /// With [cluster] on, mbgl runs supercluster internally and this adds cluster
  /// bubbles plus the leftover single points.
  ///
  /// **Cluster counts need a font you know the style has.** Pass
  /// [clusterTextFont] (e.g. `['Open Sans Regular']` for MapLibre demotiles,
  /// `['Noto Sans Regular']` for OpenFreeMap Liberty) to label each bubble with
  /// its point count. It is **null by default and the label layer is then
  /// omitted entirely**, because a library cannot know which fonts a given style
  /// serves: naming one it does not have makes mbgl request glyphs that 404 on
  /// every tile, which at best loses the text and at worst holds up the source.
  ///
  /// Ids are derived from [id] (`<id>`, `<id>-clusters`, `<id>-count`,
  /// `<id>-points`), so [removePoints] can clean them all up.
  void addPoints(
    String id,
    List<LatLng> points, {
    bool cluster = false,
    double radius = 5,
    Color color = const Color(0xFF1565C0),
    Color clusterColor = const Color(0xFFF57C00),
    double clusterRadiusPx = 18,
    int clusterRadius = 50,
    int clusterMaxZoom = 14,
    List<String>? clusterTextFont,
    String? beforeId,
  }) {
    if (_layers == null) return;
    final source = <String, Object?>{
      'type': 'geojson',
      'data': _featureCollection(points),
      if (cluster) ...{
        'cluster': true,
        'clusterRadius': clusterRadius,
        'clusterMaxZoom': clusterMaxZoom,
      },
    };
    addSourceJson(id, jsonEncode(source));

    if (!cluster) {
      addLayerJson(
        jsonEncode({
          'id': id,
          'type': 'circle',
          'source': id,
          'paint': {
            'circle-radius': radius,
            'circle-color': _cssColor(color),
            'circle-stroke-width': 1,
            'circle-stroke-color': '#ffffff',
          },
        }),
        beforeId: beforeId,
      );
      return;
    }

    // `point_count` exists only on features supercluster created, so these two
    // filters partition the source into clusters and leftover single points.
    addLayerJson(
      jsonEncode({
        'id': '$id-clusters',
        'type': 'circle',
        'source': id,
        'filter': ['has', 'point_count'],
        'paint': {
          // Bubble grows with the number of points it stands for.
          'circle-radius': [
            'step',
            ['get', 'point_count'],
            clusterRadiusPx,
            100,
            clusterRadiusPx * 1.35,
            750,
            clusterRadiusPx * 1.75,
          ],
          'circle-color': _cssColor(clusterColor),
          'circle-stroke-width': 2,
          'circle-stroke-color': '#ffffff',
        },
      }),
      beforeId: beforeId,
    );
    // Only when the caller has told us a font the style actually serves —
    // otherwise mbgl falls back to "Open Sans Regular,Arial Unicode MS Regular"
    // and 404s the glyph range on every tile.
    if (clusterTextFont != null) {
      addLayerJson(
        jsonEncode({
          'id': '$id-count',
          'type': 'symbol',
          'source': id,
          'filter': ['has', 'point_count'],
          'layout': {
            'text-field': ['get', 'point_count_abbreviated'],
            'text-font': clusterTextFont,
            'text-size': 12,
            'text-allow-overlap': true,
          },
          'paint': {'text-color': '#ffffff'},
        }),
        beforeId: beforeId,
      );
    }
    addLayerJson(
      jsonEncode({
        'id': '$id-points',
        'type': 'circle',
        'source': id,
        'filter': [
          '!',
          ['has', 'point_count'],
        ],
        'paint': {
          'circle-radius': radius,
          'circle-color': _cssColor(color),
          'circle-stroke-width': 1,
          'circle-stroke-color': '#ffffff',
        },
      }),
      beforeId: beforeId,
    );
  }

  /// Replaces the points of a layer added with [addPoints], without rebuilding
  /// it — the engine re-tiles and re-clusters.
  void setPoints(String id, List<LatLng> points) =>
      setGeoJsonData(id, jsonEncode(_featureCollection(points)));

  /// Removes everything [addPoints] created for [id].
  void removePoints(String id) {
    for (final layer in ['$id-points', '$id-count', '$id-clusters', id]) {
      removeLayer(layer);
    }
    removeSource(id);
  }

  /// Paints [widget] off-screen and registers the result as an icon named [id],
  /// usable as `icon-image` in a symbol layer.
  ///
  /// This is the bridge between the two annotation styles: author the marker as
  /// a Flutter widget, then let the ENGINE draw it thousands of times. The icon
  /// is a snapshot — it will not animate and cannot hold gestures — so use it
  /// for bulk points and keep real widget markers for the interactive few.
  ///
  /// [size] is in logical pixels; [pixelRatio] should be the display's DPR so
  /// the bitmap is crisp (the icon is registered at that scale, so the engine
  /// draws it at the right size).
  Future<void> addWidgetIcon(
    String id,
    Widget widget, {
    required Size size,
    double pixelRatio = 3.0,
    bool sdf = false,
  }) async {
    if (_layers == null) return;
    final image = await rasterizeWidget(
      widget,
      size: size,
      pixelRatio: pixelRatio,
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return;
      addImage(
        id,
        data.buffer.asUint8List(),
        image.width,
        image.height,
        pixelRatio: pixelRatio,
        sdf: sdf,
      );
    } finally {
      image.dispose();
    }
  }

  /// Paints [widget] into an image without ever adding it to the visible tree.
  ///
  /// Builds a throwaway render tree around a [RenderRepaintBoundary] and pumps
  /// it through one layout/paint pass. Exposed because it is useful on its own
  /// (and testable); [addWidgetIcon] is the usual entry point.
  ///
  /// **[size] is a maximum, not a demand.** The widget is laid out under loose
  /// constraints and the image comes out at whatever size it chose, so a marker
  /// that wants more room than you guessed is not silently cropped (text
  /// clipped at an edge is the usual way that shows up). Widgets with no
  /// intrinsic size of their own — a bare [ColoredBox], say — would collapse to
  /// nothing under loose constraints, so those fall back to exactly [size].
  static Future<ui.Image> rasterizeWidget(
    Widget widget, {
    required Size size,
    double pixelRatio = 3.0,
  }) async {
    // First pass: let the widget pick its own size, bounded by `size`.
    final sized = await _paintOnce(
      widget,
      constraints: BoxConstraints.loose(size),
      pixelRatio: pixelRatio,
    );
    if (sized != null) return sized;

    // The widget has no intrinsic size (it collapsed to nothing under loose
    // constraints, as a bare ColoredBox does): give it the box instead.
    final forced = await _paintOnce(
      widget,
      constraints: BoxConstraints.tight(size),
      pixelRatio: pixelRatio,
      forceSize: size,
    );
    if (forced != null) return forced;
    throw StateError('rasterizeWidget produced no image for $widget');
  }

  /// Returns null when the widget laid out to an empty box — rasterizing that
  /// would assert, so the caller re-runs with an explicit size instead.
  static Future<ui.Image?> _paintOnce(
    Widget widget, {
    required BoxConstraints constraints,
    required double pixelRatio,
    Size? forceSize,
  }) async {
    final boundary = RenderRepaintBoundary();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final renderView = RenderView(
      view: view,
      child: RenderPositionedBox(child: boundary),
      configuration: ViewConfiguration(
        logicalConstraints: constraints,
        devicePixelRatio: pixelRatio,
      ),
    );
    final pipelineOwner = PipelineOwner()..rootNode = renderView;
    renderView.prepareInitialFrame();

    final buildOwner = BuildOwner(focusManager: FocusManager());
    final element = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(devicePixelRatio: pixelRatio),
          child: forceSize == null
              ? widget
              : SizedBox.fromSize(size: forceSize, child: widget),
        ),
      ),
    ).attachToRenderTree(buildOwner);

    buildOwner
      ..buildScope(element)
      ..finalizeTree();
    pipelineOwner
      ..flushLayout()
      ..flushCompositingBits()
      ..flushPaint();

    // Check BEFORE rasterizing: toImage on an empty boundary asserts.
    if (boundary.size.isEmpty) {
      pipelineOwner.rootNode = null;
      return null;
    }
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    // Detach the throwaway tree so its render objects are not left rooted.
    pipelineOwner.rootNode = null;
    return image;
  }

  static Map<String, Object?> _featureCollection(List<LatLng> points) => {
    'type': 'FeatureCollection',
    'features': [
      for (final p in points)
        {
          'type': 'Feature',
          // GeoJSON is [lng, lat] — the opposite order to LatLng. Flipped here,
          // once, so callers never have to think about it.
          'geometry': {
            'type': 'Point',
            'coordinates': [p.longitude, p.latitude],
          },
          'properties': const <String, Object?>{},
        },
    ],
  };

  /// The style spec wants CSS colours, not ARGB ints.
  static String _cssColor(Color c) =>
      'rgba(${(c.r * 255).round()},${(c.g * 255).round()},'
      '${(c.b * 255).round()},${c.a})';
}
