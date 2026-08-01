import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/geojson.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:meta/meta.dart';

import 'style/style.dart';
import 'style/style_encoding.dart';

/// One feature the engine drew.
///
/// Renamed to [QueriedFeature], which mirrors gl-js's `MapGeoJSONFeature` and
/// carries the full [GeoJsonFeature.geometry] and [GeoJsonFeature.id] this type
/// never had.
///
/// One source-compatibility note: [QueriedFeature.point] is now `LatLng?`,
/// because a line or polygon feature has no single point — it used to be
/// non-null only because every non-point geometry was silently dropped.
@Deprecated(
  'Renamed to QueriedFeature (gl-js MapGeoJSONFeature). Note that .point is '
  'now nullable, since non-point geometries are no longer dropped. '
  'Will be removed in a future release.',
)
typedef MapLibreQueriedFeature = QueriedFeature;

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
/// Reached from the app-facing controller as `controller.style`. Only available
/// on renderers that can do it (the `mbgl-core` tiers); [isSupported] tells you.
///
/// **Named for what it is.** This object owns sources, images and the
/// style-wide transition as well as layers — it is Apple's `MLNStyle`, whose
/// `sources` / `layers` / `-setImage:forName:` / `transition` it mirrors — so
/// `layers` was a misnomer that would only get worse as `getSource`, `hasImage`
/// and `listImages` land on it. `controller.style` does not conflict with the
/// rule against a public `controller.setStyle`: that rule is about the style
/// DOCUMENT being a widget property, and a namespace is not a setter.
class MapLibreStyleController {
  MapLibreStyleController();

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

  // --- Typed style-spec access ------------------------------------------------
  // Generated from the MapLibre Style Spec vendored in the mbgl-core submodule
  // (`tool/generate_style_api.dart`), so it tracks the pinned core version.
  // Serialises to the JSON methods below — there is no separate transport.
  //
  // Coverage is the whole spec: every layer type, every source type, every
  // expression operator, all discovered from the spec rather than listed by
  // hand. The JSON methods stay public as the hatch for anything the spec does
  // not describe.

  /// Adds a typed style [layer]; [beforeId] inserts beneath an existing layer.
  ///
  /// ```dart
  /// controller.layers.addLayer(
  ///   CircleLayer(
  ///     id: 'pts',
  ///     source: 'pts',
  ///     circleRadius: const StyleValue(6),
  ///     circleColor: Expr.get('color'),
  ///   ),
  /// );
  /// ```
  void addLayer(StyleLayer layer, {String? beforeId}) =>
      addLayerJson(jsonEncode(layer.toJson()), beforeId: beforeId);

  /// Adds a typed style [source] under [id].
  void addSource(String id, StyleSource source) =>
      addSourceJson(id, jsonEncode(source.toJson()));

  // --- Raw style-spec access --------------------------------------------------
  // MapLibre Style Spec JSON, the same documents maplibre-gl-js takes. This is
  // the full-power escape hatch, and stays public: every layer type, every
  // expression, anything the typed API above does not cover yet.

  /// Adds a style source under [id]. Throws [ArgumentError] on invalid JSON.
  void addSourceJson(String id, String json) =>
      _layers?.addSourceJson(id, json);

  /// Adds a style layer; [beforeId] inserts beneath an existing layer.
  void addLayerJson(String json, {String? beforeId}) =>
      _layers?.addLayerJson(json, beforeId: beforeId);

  /// Replaces a source's data — the cheap path for live datasets.
  ///
  /// gl-js spells this `getSource(id).setData(...)`, and [getSource] gives you
  /// that shape; this is the flat form underneath. Only a GeoJSON source can
  /// have its data replaced (mbgl has no setter on a vector or raster one), and
  /// asking for anything else reports on `controller.onError`.
  void setSourceData(String sourceId, Object data) => _layers?.setSourceData(
    sourceId,
    data is String ? data : jsonEncode(encodeStyleJson(data)),
  );

  /// Replaces a geojson source's data.
  @Deprecated(
    'Renamed to setSourceData: the verb should not bake in the format, which '
    'reads wrong the moment an image or computed source needs an equivalent. '
    'Will be removed in a future release.',
  )
  void setGeoJsonData(String sourceId, String geoJson) =>
      setSourceData(sourceId, geoJson);

  /// A handle to one source — gl-js `map.getSource(id)`.
  ///
  /// Null when the source does not exist. The handle is a thin view, not a
  /// snapshot: [MapLibreSource.setData] talks to the live map.
  MapLibreSource? getSource(String sourceId) {
    final json = _layers?.getSourceJson(sourceId);
    if (json == null) return null;
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) return null;
    return MapLibreSource._(
      this,
      id: sourceId,
      type: decoded['type'] as String? ?? 'unknown',
      attribution: decoded['attribution'] as String?,
      isVolatile: decoded['volatile'] as bool? ?? false,
    );
  }

  /// The style's source ids — the read side [getSource] iterates.
  List<String> getSourceIds() => _layers?.getSourceIds() ?? const [];

  void removeLayer(String id) => _layers?.removeLayer(id);

  // --- Per-property mutation --------------------------------------------------
  //
  // gl-js splits this into setPaintProperty / setLayoutProperty / setFilter /
  // setLayerZoomRange, so those names are here — but they are ONE engine call.
  // `Layer::setProperty` dispatches to the generated paint/layout setters and
  // then handles visibility, minzoom, maxzoom and filter itself, so the C ABI
  // needed no split at all.
  //
  // Before this, changing one property meant removing the layer and adding it
  // back.

  /// Sets a paint property — gl-js `setPaintProperty`.
  ///
  /// ```dart
  /// controller.style.setPaintProperty('dots', 'circle-color', Colors.teal);
  /// controller.style.setPaintProperty(
  ///   'dots', 'circle-radius', Expr.get('magnitude'),
  /// );
  /// ```
  ///
  /// [value] is anything the typed style API accepts — a constant, a [Color],
  /// an [Expression] — encoded by the same serialiser the layer classes use, so
  /// there is no second encoder to drift.
  void setPaintProperty(String layerId, String name, Object? value) =>
      _setProperty(layerId, name, value);

  /// Sets a layout property — gl-js `setLayoutProperty`. Same call underneath
  /// as [setPaintProperty]; the split is gl-js's, not the engine's.
  void setLayoutProperty(String layerId, String name, Object? value) =>
      _setProperty(layerId, name, value);

  /// Shows or hides a layer — the `visibility` layout property.
  void setLayerVisible(String layerId, {required bool visible}) =>
      _setProperty(layerId, 'visibility', visible ? 'visible' : 'none');

  /// Replaces a layer's filter — gl-js `setFilter`. Pass null to clear it.
  void setFilter(String layerId, Expression? filter) =>
      _setProperty(layerId, 'filter', filter);

  /// The zoom range a layer draws in — gl-js `setLayerZoomRange`.
  void setLayerZoomRange(String layerId, {double? minZoom, double? maxZoom}) {
    if (minZoom != null) _setProperty(layerId, 'minzoom', minZoom);
    if (maxZoom != null) _setProperty(layerId, 'maxzoom', maxZoom);
  }

  /// Moves [layerId] beneath [beforeId], or to the top when [beforeId] is null
  /// — gl-js `moveLayer`.
  ///
  /// Cheap: the engine hands the layer object between positions rather than
  /// rebuilding it, so nothing is re-parsed or re-uploaded.
  void moveLayer(String layerId, {String? beforeId}) =>
      _layers?.moveLayer(layerId, beforeId: beforeId);

  void _setProperty(String layerId, String name, Object? value) => _layers
      ?.setLayerProperty(layerId, name, jsonEncode(encodeStyleJson(value)));

  // --- The read side ----------------------------------------------------------
  //
  // There was none at all before this: you could add a layer and never ask the
  // engine anything about it again.

  /// One paint property as decoded JSON, or null if the layer or property does
  /// not exist — gl-js `getPaintProperty`.
  ///
  /// **The engine's NORMALISED form comes back, not what you set.** A colour
  /// returns as `['rgba', r, g, b, a]` with doubles whatever notation set it,
  /// and numbers return as doubles. Round-tripping a read straight into a write
  /// is fine; comparing it to your input string is not.
  Object? getPaintProperty(String layerId, String name) =>
      _decodeProperty(layerId, name);

  /// One layout property — gl-js `getLayoutProperty`. Same call as
  /// [getPaintProperty]; see it for the normalisation caveat.
  Object? getLayoutProperty(String layerId, String name) =>
      _decodeProperty(layerId, name);

  /// A layer's filter as decoded JSON — gl-js `getFilter`.
  Object? getFilter(String layerId) => _decodeProperty(layerId, 'filter');

  /// The style's layer ids, bottom-most first — gl-js `getLayersOrder`.
  ///
  /// Includes the basemap's own layers, which is what makes it useful for
  /// picking a `beforeId`.
  List<String> getLayersOrder() => _layers?.getLayerIds() ?? const [];

  /// One layer's full style-spec document, decoded — gl-js `getLayer`.
  ///
  /// Read from the LIVE layer (`Layer::serialize()`), so it reflects everything
  /// set since it was added. `Style::getJSON()` would not: that returns the
  /// document as it was loaded.
  Map<String, Object?>? getLayer(String layerId) {
    final json = _layers?.getLayerJson(layerId);
    if (json == null) return null;
    final decoded = jsonDecode(json);
    return decoded is Map<String, Object?> ? decoded : null;
  }

  Object? _decodeProperty(String layerId, String name) {
    final json = _layers?.getLayerProperty(layerId, name);
    if (json == null) return null;
    try {
      return jsonDecode(json);
    } on FormatException {
      return null;
    }
  }

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

  /// Style-wide transition behaviour.
  ///
  /// The reason this is exposed: **symbol layers fade, circle layers do not.**
  /// When a clustered source re-clusters, a cluster's circle stops being drawn
  /// on the next frame while its count label ramps its opacity down over
  /// [duration] (300 ms by default), so the number appears to hang in the air
  /// for a few frames after its bubble has gone.
  ///
  /// Two ways to deal with that, and the gentler one is usually right:
  ///
  /// ```dart
  /// // Keeps every fade, shrinks the mismatch to a couple of frames.
  /// layers.setTransitionOptions(duration: const Duration(milliseconds: 80));
  ///
  /// // Removes it entirely — see the caveat below.
  /// layers.setTransitionOptions(placementTransitions: false);
  /// ```
  ///
  /// [placementTransitions] `false` makes symbols appear and disappear
  /// instantly, but it is a property of the **style**, not of one layer, so the
  /// basemap's own labels stop fading as well — they pop in and out while
  /// panning. Shortening [duration] avoids that, and only shortens the fade:
  /// mbgl clamps how often it recomputes placement at `max(300ms, duration)`.
  ///
  /// [duration] also governs paint-property transitions, and [delay] their
  /// start; null leaves the style document's own values. Both survive a style
  /// change (which would otherwise reset them), and apply to the continuous
  /// render mode only.
  ///
  /// Defaults are the engine's own behaviour, which is also what
  /// maplibre-gl-js does (its `fadeDuration`).
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions = true,
  }) => _layers?.setTransitionOptions(
    duration: duration,
    delay: delay,
    placementTransitions: placementTransitions,
  );

  // --- Queries ----------------------------------------------------------------

  /// The features the engine actually drew inside [rect] (logical pixels in the
  /// map widget's own coordinate space).
  ///
  /// This is how you find out what is on screen without duplicating the
  /// engine's work. On a clustered source it returns the **clusters**
  /// themselves — each with [QueriedFeature.pointCount] and the position mbgl
  /// placed it at — so cluster bubbles can be drawn as Flutter widgets over the
  /// top, or hit-tested for a tap, without reimplementing clustering in Dart.
  ///
  /// Every geometry type comes back, so a fill or line layer answers as well as
  /// a circle one; reach for [QueriedFeature.point] when you know it is a point
  /// and [GeoJsonFeature.geometry] otherwise.
  ///
  /// Empty when nothing matched, and when the renderer is unavailable or the
  /// query timed out — those cases are not distinguished today. Restrict to
  /// specific [layerIds] to keep results small; that is also the only way to
  /// learn which layer a feature came from, because mbgl flattens its
  /// per-layer results before returning them.
  ///
  /// Mirrors gl-js `map.queryRenderedFeatures(geometry?, options?)` and Apple's
  /// `-visibleFeaturesInRect:` (`MLNMapView.h`).
  List<QueriedFeature> queryRenderedFeatures(
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
    // Runs on camera ticks, so this must not throw into its caller — and that
    // promise only holds because every read below is checked. Unchecked casts
    // throw TypeError, which `on FormatException` would not have caught.
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map<String, Object?>) return const [];
    final features = decoded['features'];
    if (features is! List<Object?>) return const [];
    final out = <QueriedFeature>[];
    for (final f in features) {
      if (f is! Map<String, Object?>) continue;
      try {
        out.add(QueriedFeature.fromJson(f));
      } on FormatException {
        // One unreadable feature should not lose the rest of the frame's.
        continue;
      }
    }
    return out;
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
  ///
  /// [properties] attaches one property map per point, parallel to [points],
  /// which is what data-driven styling reads (`Expr.get('…')`).
  void addPoints(
    String id,
    List<LatLng> points, {
    List<Map<String, Object?>>? properties,
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
    addSource(
      id,
      GeoJsonSource(
        data: GeoJsonData.points(points, properties: properties),
        cluster: cluster ? true : null,
        clusterRadius: cluster ? clusterRadius.toDouble() : null,
        clusterMaxZoom: cluster ? clusterMaxZoom.toDouble() : null,
      ),
    );

    // A single circle layer over the whole source when there is no clustering.
    if (!cluster) {
      addLayer(
        _circles(id: id, source: id, radius: radius, color: color),
        beforeId: beforeId,
      );
      return;
    }

    // `point_count` exists only on features supercluster created, so these two
    // filters partition the source into clusters and leftover single points.
    addLayer(
      CircleLayer(
        id: '$id-clusters',
        source: id,
        filter: Expr.has('point_count'),
        // Bubble grows with the number of points it stands for.
        circleRadius: Expr.step(
          Expr.get('point_count'),
          clusterRadiusPx,
          100,
          clusterRadiusPx * 1.35,
          750,
          clusterRadiusPx * 1.75,
        ),
        circleColor: StyleValue(clusterColor),
        circleStrokeWidth: const StyleValue(2),
        circleStrokeColor: const StyleValue(_white),
      ),
      beforeId: beforeId,
    );
    // Only when the caller has told us a font the style actually serves —
    // otherwise mbgl falls back to "Open Sans Regular,Arial Unicode MS Regular"
    // and 404s the glyph range on every tile.
    if (clusterTextFont != null) {
      addLayer(
        SymbolLayer(
          id: '$id-count',
          source: id,
          filter: Expr.has('point_count'),
          textField: Expr.get('point_count_abbreviated'),
          textFont: StyleValue(clusterTextFont),
          textSize: const StyleValue(12),
          textAllowOverlap: const StyleValue(true),
          textColor: const StyleValue(_white),
        ),
        beforeId: beforeId,
      );
    }
    addLayer(
      _circles(
        id: '$id-points',
        source: id,
        radius: radius,
        color: color,
        filter: Expr.not(Expr.has('point_count')),
      ),
      beforeId: beforeId,
    );
  }

  /// The plain-points circle layer, shared by the clustered and unclustered
  /// paths so they cannot drift apart.
  static CircleLayer _circles({
    required String id,
    required String source,
    required double radius,
    required Color color,
    Expression? filter,
  }) => CircleLayer(
    id: id,
    source: source,
    filter: filter,
    circleRadius: StyleValue(radius),
    circleColor: StyleValue(color),
    circleStrokeWidth: const StyleValue(1),
    circleStrokeColor: const StyleValue(_white),
  );

  static const _white = Color(0xFFFFFFFF);

  /// Replaces the points of a layer added with [addPoints], without rebuilding
  /// it — the engine re-tiles and re-clusters.
  ///
  /// [properties] attaches one property map per point, parallel to [points], so
  /// data-driven styling (`Expr.get('…')`) keeps working across an update.
  /// Omitting it clears the properties, exactly as passing new data does in
  /// gl-js `source.setData`.
  void setPoints(
    String id,
    List<LatLng> points, {
    List<Map<String, Object?>>? properties,
  }) => setGeoJsonData(
    id,
    jsonEncode(GeoJsonData.points(points, properties: properties).toJson()),
  );

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
}

/// The style namespace.
@Deprecated(
  'Renamed to MapLibreStyleController: it owns sources, images and the '
  'style-wide transition as well as layers, which is Apple MLNStyle rather '
  'than a layer list. Will be removed in a future release.',
)
typedef MapLibreLayersController = MapLibreStyleController;

/// One source of the current style — gl-js `map.getSource(id)`'s return.
///
/// A thin view onto the live map rather than a snapshot: [setData] reaches the
/// engine. Obtained from [MapLibreStyleController.getSource].
class MapLibreSource {
  const MapLibreSource._(
    this._style, {
    required this.id,
    required this.type,
    required this.attribution,
    required this.isVolatile,
  });

  final MapLibreStyleController _style;

  /// The source's id in the style document.
  final String id;

  /// Its style-spec type: `geojson`, `vector`, `raster`, `raster-dem`, …
  final String type;

  /// The attribution string the tile provider requires be shown, if it declares
  /// one.
  ///
  /// **Reading it is not displaying it.** Nothing renders attribution today,
  /// which is a legal obligation for many providers — tracked as its own task.
  /// This at least makes the string reachable, which it was not before.
  final String? attribution;

  /// Whether mbgl keeps this source's data out of persistent storage.
  final bool isVolatile;

  /// Whether this source's data can be replaced with [setData].
  ///
  /// Only GeoJSON sources can: mbgl has no data setter on a vector or raster
  /// one, so this is an engine limit rather than a missing binding.
  bool get supportsSetData => type == 'geojson';

  /// Replaces this source's data — gl-js `source.setData(...)`.
  ///
  /// Takes a [GeoJsonData], a typed `GeoJsonFeatureCollection`, or a raw JSON
  /// string. Reports on `controller.onError` if this source cannot take it.
  void setData(Object data) => _style.setSourceData(id, data);

  @override
  String toString() => 'MapLibreSource($id, type: $type)';
}
