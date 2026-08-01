import 'dart:typed_data';

/// Optional capability: a platform controller whose renderer can draw data
/// itself, from sources and layers in the map style.
///
/// This is the answer to datasets too large for anchored widgets. A widget
/// marker is a real Flutter widget — interactive, animatable — but it costs one
/// render object painted every camera tick, which tops out in the hundreds.
/// Points added here are drawn by the engine alongside the map, so they are
/// glued to it by construction (same transform, same frame, no lag) and scale
/// to the hundreds of thousands. In exchange they are pictures, not widgets: no
/// child gestures, no per-marker animation.
///
/// Clustering is part of the engine, not this API: set `"cluster": true` on a
/// geojson source and mbgl runs supercluster internally, re-clustering per zoom.
///
/// Implemented by the `mbgl-core` tiers; feature-detected with `is` exactly like
/// [MapLibreGestureHandler] and [MapLibreMapProjector], so renderers that cannot
/// do it (a native SDK tier) simply do not offer it.
///
/// Documents are **MapLibre Style Spec** JSON — the same shape maplibre-gl-js
/// takes — so expressions, filters and data-driven styling work without extra
/// API here.
abstract interface class MapLibreStyleLayers {
  /// Adds a source under [id]. Throws [ArgumentError] if [json] is not a valid
  /// source document.
  void addSourceJson(String id, String json);

  /// Adds a layer. [beforeId] inserts it beneath an existing layer (draw order);
  /// null puts it on top. Throws [ArgumentError] on an invalid document.
  void addLayerJson(String json, {String? beforeId});

  /// Replaces the data of an existing geojson source — the cheap path for
  /// dynamic datasets: the engine re-tiles and re-clusters, and layers reading
  /// the source pick it up with no rebuild.
  /// Replaces a source's data.
  ///
  /// Only a GeoJSON source can have its data replaced — mbgl has no setter on a
  /// vector or raster one — and asking for anything else reports on the error
  /// stream rather than failing quietly.
  void setSourceData(String sourceId, String data);

  /// Replaces a geojson source's data.
  @Deprecated(
    'Renamed to setSourceData: the verb should not bake in the format, which '
    'reads wrong the moment an image or computed source needs an equivalent. '
    'Will be removed in a future release.',
  )
  void setGeoJsonData(String sourceId, String geoJson);

  /// One source as JSON — id, type, attribution, volatile — or null if absent.
  String? getSourceJson(String sourceId);

  /// The style's source ids.
  List<String>? getSourceIds();

  void removeLayer(String id);

  /// Sets one style-spec property on [layerId], by its spec [name].
  ///
  /// [valueJson] is a JSON fragment. **One method covers paint, layout,
  /// `visibility`, `minzoom`, `maxzoom` and `filter`** — `Layer::setProperty`
  /// falls through to each in turn, so the contract needs none of gl-js's split
  /// into four. The app-facing names sit on top of this.
  ///
  /// Returns false only when [valueJson] is malformed, which is the one failure
  /// knowable without the render thread; anything else is reported on the error
  /// stream.
  bool setLayerProperty(String layerId, String name, String valueJson);

  /// Moves [layerId] beneath [beforeId], or to the top when null.
  void moveLayer(String layerId, {String? beforeId});

  /// One property of [layerId] as JSON, or null if absent.
  String? getLayerProperty(String layerId, String name);

  /// The style's layer ids, bottom-most first.
  List<String>? getLayerIds();

  /// One layer's full style-spec JSON, from the LIVE layer rather than the
  /// document as loaded.
  String? getLayerJson(String layerId);

  void removeSource(String id);

  /// Registers an icon for use as `icon-image` in a symbol layer, from raw
  /// premultiplied RGBA (`width * height * 4` bytes).
  ///
  /// This is how a Flutter widget becomes an engine-drawn marker: paint the
  /// widget to an image and register its bytes.
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio,
    bool sdf,
  });

  void removeImage(String id);

  /// Whether the style has an image called [id]. Null when the read timed out,
  /// which is deliberately not false.
  bool? hasImage(String id);

  /// Every image id in the style, including the style's own sprite images.
  List<String>? getImageIds();

  /// Style-wide transition behaviour; see the app-facing
  /// `MapLibreLayersController.setTransitionOptions` for the rationale.
  ///
  /// [duration] and [delay] null means "leave the style's own value".
  /// [placementTransitions] false stops symbol layers fading in and out.
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions,
  });

  /// The features the engine actually DREW inside a screen-space rect (logical
  /// points, top-left origin — the same space as [MapLibreMapProjector]).
  ///
  /// Returns a GeoJSON `FeatureCollection` string, or null if the query failed
  /// or timed out. For a clustered source this returns the **cluster** features
  /// supercluster produced, with their `point_count` and real positions —
  /// state that lives inside the engine and cannot be recomputed from the
  /// original points. That is what makes it possible to draw clusters as
  /// Flutter widgets without reimplementing clustering.
  ///
  /// [filterJson] is a style-spec filter expression as JSON, evaluated inside
  /// the engine — cheaper than fetching everything and filtering in Dart, and
  /// able to reach properties Dart never sees.
  String? queryRenderedFeaturesJson(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
    String? filterJson,
  });

  /// The same query, off the calling thread.
  ///
  /// The synchronous form blocks on a render-thread round trip, which on the UI
  /// isolate stalls frame production — fine for a one-off hit test, wrong for a
  /// query driven by the camera at frame rate, which is the usual reason to run
  /// one. Completes with null if the query failed.
  Future<String?> queryRenderedFeaturesAsyncJson(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
    String? filterJson,
  });

  /// Features in a source's LOADED TILES, drawn or not — gl-js
  /// `querySourceFeatures`. Returns a GeoJSON `FeatureCollection` string, or
  /// null if the query failed.
  ///
  /// Ignores styling and visibility, so it answers "what data is loaded here",
  /// not "what is on screen". Results are **not deduplicated** and only cover
  /// tiles already fetched — see the implementations for why.
  String? querySourceFeaturesJson(
    String sourceId, {
    List<String>? sourceLayers,
    String? filterJson,
  });

  /// Attaches state to one feature — gl-js `setFeatureState`.
  ///
  /// [stateJson] is a JSON object, MERGED into any state already there.
  ///
  /// **Only works on features that carry their own id.** The style spec has
  /// `promoteId` and `generateId` for sources whose features identify
  /// themselves by a property instead, and mbgl implements neither — so state
  /// set against an id no feature has is stored and never read.
  void setFeatureStateJson(
    String sourceId,
    String featureId,
    String stateJson, {
    String? sourceLayer,
  });

  /// One feature's state as a JSON object, `{}` when it has none. Null when the
  /// read failed — which is not the same as `{}`.
  String? getFeatureStateJson(
    String sourceId,
    String featureId, {
    String? sourceLayer,
  });

  /// Removes state. Null [stateKey] clears the feature's whole state; null
  /// [featureId] clears every feature's state in the source.
  void removeFeatureState(
    String sourceId, {
    String? featureId,
    String? sourceLayer,
    String? stateKey,
  });
}
