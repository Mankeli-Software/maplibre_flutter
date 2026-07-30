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
  void setGeoJsonData(String sourceId, String geoJson);

  void removeLayer(String id);

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
}
