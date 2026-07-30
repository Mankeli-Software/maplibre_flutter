// GENERATED CODE - DO NOT MODIFY BY HAND
//
// Generated from the MapLibre Style Spec (v8) vendored at
// ../maplibre_flutter_core/third_party/maplibre-native/scripts/style-spec-reference/v8.json
// by tool/generate_style_api.dart. Run that to regenerate.

import 'package:flutter/foundation.dart' show immutable;

import '../style_encoding.dart';
import '../style_layer.dart';
import 'style_enums.g.dart';

/// A `vector` style source.
///
/// Generated from the spec schema `source_vector`. Add one with
/// `controller.layers.addSource(id, source)`.
@immutable
final class VectorSource extends StyleSource {
  /// Creates a `vector` source.
  const VectorSource({
    this.url,
    this.tiles,
    this.bounds,
    this.scheme,
    this.minZoom,
    this.maxZoom,
    this.attribution,
    this.promoteId,
    this.volatile,
    this.encoding,
  });

  @override
  String get type => 'vector';

  /// A URL to a TileJSON resource. Supported protocols are `http:` and
  /// `https:`.
  ///
  /// Spec: `url`.
  final String? url;

  /// An array of one or more tile source URLs, as in the TileJSON spec.
  ///
  /// Spec: `tiles`.
  final List<String>? tiles;

  /// An array containing the longitude and latitude of the southwest and
  /// northeast corners of the source's bounding box in the following order:
  /// `[sw.lng, sw.lat, ne.lng, ne.lat]`. When this property is included in a
  /// source, no tiles outside of the given bounds are requested by MapLibre.
  ///
  /// Spec: `bounds`. Defaults to `[-180,-85.051129,180,85.051129]`.
  final List<double>? bounds;

  /// Influences the y direction of the tile coordinates. The global-mercator
  /// (aka Spherical Mercator) profile is assumed.
  ///
  /// Spec: `scheme`. Defaults to `"xyz"`.
  final VectorScheme? scheme;

  /// Minimum zoom level for which tiles are available, as in the TileJSON spec.
  ///
  /// Spec: `minzoom`. Defaults to `0`.
  final double? minZoom;

  /// Maximum zoom level for which tiles are available, as in the TileJSON spec.
  /// Data from tiles at the maxzoom are used when displaying the map at higher
  /// zoom levels.
  ///
  /// Spec: `maxzoom`. Defaults to `22`.
  final double? maxZoom;

  /// Contains an attribution to be displayed when the map is shown to a user.
  ///
  /// Spec: `attribution`.
  final String? attribution;

  /// A property to use as a feature id (for feature state). Either a property
  /// name, or an object of the form `{<sourceLayer>: <propertyName>}`. If
  /// specified as a string for a vector tile source, the same property is used
  /// across all its source layers.
  ///
  /// Spec: `promoteId`.
  final Object? promoteId;

  /// A setting to determine whether a source's tiles are cached locally.
  ///
  /// Spec: `volatile`. Defaults to `false`.
  final bool? volatile;

  /// The encoding used by this source. Mapbox Vector Tiles encoding is used by
  /// default.
  ///
  /// Spec: `encoding`. Defaults to `"mvt"`.
  final VectorEncoding? encoding;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    if (url != null) 'url': encodeStyleJson(url),
    if (tiles != null) 'tiles': encodeStyleJson(tiles),
    if (bounds != null) 'bounds': encodeStyleJson(bounds),
    if (scheme != null) 'scheme': encodeStyleJson(scheme),
    if (minZoom != null) 'minzoom': encodeStyleJson(minZoom),
    if (maxZoom != null) 'maxzoom': encodeStyleJson(maxZoom),
    if (attribution != null) 'attribution': encodeStyleJson(attribution),
    if (promoteId != null) 'promoteId': encodeStyleJson(promoteId),
    if (volatile != null) 'volatile': encodeStyleJson(volatile),
    if (encoding != null) 'encoding': encodeStyleJson(encoding),
  };
}

/// A `raster` style source.
///
/// Generated from the spec schema `source_raster`. Add one with
/// `controller.layers.addSource(id, source)`.
@immutable
final class RasterSource extends StyleSource {
  /// Creates a `raster` source.
  const RasterSource({
    this.url,
    this.tiles,
    this.bounds,
    this.minZoom,
    this.maxZoom,
    this.tileSize,
    this.scheme,
    this.attribution,
    this.volatile,
  });

  @override
  String get type => 'raster';

  /// A URL to a TileJSON resource. Supported protocols are `http:` and
  /// `https:`.
  ///
  /// Spec: `url`.
  final String? url;

  /// An array of one or more tile source URLs, as in the TileJSON spec.
  ///
  /// Spec: `tiles`.
  final List<String>? tiles;

  /// An array containing the longitude and latitude of the southwest and
  /// northeast corners of the source's bounding box in the following order:
  /// `[sw.lng, sw.lat, ne.lng, ne.lat]`. When this property is included in a
  /// source, no tiles outside of the given bounds are requested by MapLibre.
  ///
  /// Spec: `bounds`. Defaults to `[-180,-85.051129,180,85.051129]`.
  final List<double>? bounds;

  /// Minimum zoom level for which tiles are available, as in the TileJSON spec.
  ///
  /// Spec: `minzoom`. Defaults to `0`.
  final double? minZoom;

  /// Maximum zoom level for which tiles are available, as in the TileJSON spec.
  /// Data from tiles at the maxzoom are used when displaying the map at higher
  /// zoom levels.
  ///
  /// Spec: `maxzoom`. Defaults to `22`.
  final double? maxZoom;

  /// The minimum visual size to display tiles for this layer. Only configurable
  /// for raster layers.
  ///
  /// Spec: `tileSize`, in pixels. Defaults to `512`.
  final double? tileSize;

  /// Influences the y direction of the tile coordinates. The global-mercator
  /// (aka Spherical Mercator) profile is assumed.
  ///
  /// Spec: `scheme`. Defaults to `"xyz"`.
  final RasterScheme? scheme;

  /// Contains an attribution to be displayed when the map is shown to a user.
  ///
  /// Spec: `attribution`.
  final String? attribution;

  /// A setting to determine whether a source's tiles are cached locally.
  ///
  /// Spec: `volatile`. Defaults to `false`.
  final bool? volatile;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    if (url != null) 'url': encodeStyleJson(url),
    if (tiles != null) 'tiles': encodeStyleJson(tiles),
    if (bounds != null) 'bounds': encodeStyleJson(bounds),
    if (minZoom != null) 'minzoom': encodeStyleJson(minZoom),
    if (maxZoom != null) 'maxzoom': encodeStyleJson(maxZoom),
    if (tileSize != null) 'tileSize': encodeStyleJson(tileSize),
    if (scheme != null) 'scheme': encodeStyleJson(scheme),
    if (attribution != null) 'attribution': encodeStyleJson(attribution),
    if (volatile != null) 'volatile': encodeStyleJson(volatile),
  };
}

/// A `raster-dem` style source.
///
/// Generated from the spec schema `source_raster_dem`. Add one with
/// `controller.layers.addSource(id, source)`.
@immutable
final class RasterDemSource extends StyleSource {
  /// Creates a `raster-dem` source.
  const RasterDemSource({
    this.url,
    this.tiles,
    this.bounds,
    this.minZoom,
    this.maxZoom,
    this.tileSize,
    this.attribution,
    this.encoding,
    this.redFactor,
    this.blueFactor,
    this.greenFactor,
    this.baseShift,
    this.volatile,
  });

  @override
  String get type => 'raster-dem';

  /// A URL to a TileJSON resource. Supported protocols are `http:` and
  /// `https:`.
  ///
  /// Spec: `url`.
  final String? url;

  /// An array of one or more tile source URLs, as in the TileJSON spec.
  ///
  /// Spec: `tiles`.
  final List<String>? tiles;

  /// An array containing the longitude and latitude of the southwest and
  /// northeast corners of the source's bounding box in the following order:
  /// `[sw.lng, sw.lat, ne.lng, ne.lat]`. When this property is included in a
  /// source, no tiles outside of the given bounds are requested by MapLibre.
  ///
  /// Spec: `bounds`. Defaults to `[-180,-85.051129,180,85.051129]`.
  final List<double>? bounds;

  /// Minimum zoom level for which tiles are available, as in the TileJSON spec.
  ///
  /// Spec: `minzoom`. Defaults to `0`.
  final double? minZoom;

  /// Maximum zoom level for which tiles are available, as in the TileJSON spec.
  /// Data from tiles at the maxzoom are used when displaying the map at higher
  /// zoom levels.
  ///
  /// Spec: `maxzoom`. Defaults to `22`.
  final double? maxZoom;

  /// The minimum visual size to display tiles for this layer. Only configurable
  /// for raster layers.
  ///
  /// Spec: `tileSize`, in pixels. Defaults to `512`.
  final double? tileSize;

  /// Contains an attribution to be displayed when the map is shown to a user.
  ///
  /// Spec: `attribution`.
  final String? attribution;

  /// The encoding used by this source. Mapbox Terrain RGB is used by default.
  ///
  /// Spec: `encoding`. Defaults to `"mapbox"`.
  final RasterDemEncoding? encoding;

  /// Value that will be multiplied by the red channel value when decoding. Only
  /// used on custom encodings.
  ///
  /// Spec: `redFactor`. Defaults to `1.0`.
  final double? redFactor;

  /// Value that will be multiplied by the blue channel value when decoding.
  /// Only used on custom encodings.
  ///
  /// Spec: `blueFactor`. Defaults to `1.0`.
  final double? blueFactor;

  /// Value that will be multiplied by the green channel value when decoding.
  /// Only used on custom encodings.
  ///
  /// Spec: `greenFactor`. Defaults to `1.0`.
  final double? greenFactor;

  /// Value that will be added to the encoding mix when decoding. Only used on
  /// custom encodings.
  ///
  /// Spec: `baseShift`. Defaults to `0.0`.
  final double? baseShift;

  /// A setting to determine whether a source's tiles are cached locally.
  ///
  /// Spec: `volatile`. Defaults to `false`.
  final bool? volatile;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    if (url != null) 'url': encodeStyleJson(url),
    if (tiles != null) 'tiles': encodeStyleJson(tiles),
    if (bounds != null) 'bounds': encodeStyleJson(bounds),
    if (minZoom != null) 'minzoom': encodeStyleJson(minZoom),
    if (maxZoom != null) 'maxzoom': encodeStyleJson(maxZoom),
    if (tileSize != null) 'tileSize': encodeStyleJson(tileSize),
    if (attribution != null) 'attribution': encodeStyleJson(attribution),
    if (encoding != null) 'encoding': encodeStyleJson(encoding),
    if (redFactor != null) 'redFactor': encodeStyleJson(redFactor),
    if (blueFactor != null) 'blueFactor': encodeStyleJson(blueFactor),
    if (greenFactor != null) 'greenFactor': encodeStyleJson(greenFactor),
    if (baseShift != null) 'baseShift': encodeStyleJson(baseShift),
    if (volatile != null) 'volatile': encodeStyleJson(volatile),
  };
}

/// A `geojson` style source.
///
/// Generated from the spec schema `source_geojson`. Add one with
/// `controller.layers.addSource(id, source)`.
@immutable
final class GeoJsonSource extends StyleSource {
  /// Creates a `geojson` source.
  const GeoJsonSource({
    required this.data,
    this.maxZoom,
    this.attribution,
    this.buffer,
    this.filter,
    this.tolerance,
    this.cluster,
    this.clusterRadius,
    this.clusterMaxZoom,
    this.clusterMinPoints,
    this.clusterProperties,
    this.lineMetrics,
    this.generateId,
    this.promoteId,
  });

  @override
  String get type => 'geojson';

  /// A URL to a GeoJSON file, or inline GeoJSON.
  ///
  /// Spec: `data`.
  final Object data;

  /// Maximum zoom level at which to create vector tiles (higher means greater
  /// detail at high zoom levels).
  ///
  /// Spec: `maxzoom`. Defaults to `18`.
  final double? maxZoom;

  /// Contains an attribution to be displayed when the map is shown to a user.
  ///
  /// Spec: `attribution`.
  final String? attribution;

  /// Size of the tile buffer on each side. A value of 0 produces no buffer. A
  /// value of 512 produces a buffer as wide as the tile itself. Larger values
  /// produce fewer rendering artifacts near tile edges and slower performance.
  ///
  /// Spec: `buffer`. Defaults to `128`.
  final double? buffer;

  /// An expression for filtering features prior to processing them for
  /// rendering.
  ///
  /// Spec: `filter`.
  final Object? filter;

  /// Douglas-Peucker simplification tolerance (higher means simpler geometries
  /// and faster performance).
  ///
  /// Spec: `tolerance`. Defaults to `0.375`.
  final double? tolerance;

  /// If the data is a collection of point features, setting this to true
  /// clusters the points by radius into groups. Cluster groups become new
  /// `Point` features in the source with additional properties:
  ///
  /// * `cluster` Is `true` if the point is a cluster
  ///
  /// * `cluster_id` A unique id for the cluster to be used in conjunction with
  /// the [cluster inspection
  /// methods](https://maplibre.org/maplibre-gl-js/docs/API/classes/GeoJSONSource/#getclusterexpansionzoom)
  ///
  /// * `point_count` Number of original points grouped into this cluster
  ///
  /// * `point_count_abbreviated` An abbreviated point count
  ///
  /// Spec: `cluster`. Defaults to `false`.
  final bool? cluster;

  /// Radius of each cluster if clustering is enabled. A value of 512 indicates
  /// a radius equal to the width of a tile.
  ///
  /// Spec: `clusterRadius`. Defaults to `50`.
  final double? clusterRadius;

  /// Max zoom on which to cluster points if clustering is enabled. Defaults to
  /// one zoom less than maxzoom (so that last zoom features are not clustered).
  /// Clusters are re-evaluated at integer zoom levels so setting clusterMaxZoom
  /// to 14 means the clusters will be displayed until z15.
  ///
  /// Spec: `clusterMaxZoom`.
  final double? clusterMaxZoom;

  /// Minimum number of points necessary to form a cluster if clustering is
  /// enabled. Defaults to `2`.
  ///
  /// Spec: `clusterMinPoints`.
  final double? clusterMinPoints;

  /// An object defining custom properties on the generated clusters if
  /// clustering is enabled, aggregating values from clustered points. Has the
  /// form `{"property_name": [operator, map_expression]}`. `operator` is any
  /// expression function that accepts at least 2 operands (e.g. `"+"` or
  /// `"max"`) — it accumulates the property value from clusters/points the
  /// cluster contains; `map_expression` produces the value of a single point.
  ///
  /// Example: `{"sum": ["+", ["get", "scalerank"]]}`.
  ///
  /// For more advanced use cases, in place of `operator`, you can use a custom
  /// reduce expression that references a special `["accumulated"]` value, e.g.:
  ///
  /// `{"sum": [["+", ["accumulated"], ["get", "sum"]], ["get", "scalerank"]]}`
  ///
  /// Spec: `clusterProperties`.
  final Object? clusterProperties;

  /// Whether to calculate line distance metrics. This is required for line
  /// layers that specify `line-gradient` values.
  ///
  /// Spec: `lineMetrics`. Defaults to `false`.
  final bool? lineMetrics;

  /// Whether to generate ids for the geojson features. When enabled, the
  /// `feature.id` property will be auto assigned based on its index in the
  /// `features` array, over-writing any previous values.
  ///
  /// Spec: `generateId`. Defaults to `false`.
  final bool? generateId;

  /// A property to use as a feature id (for feature state). Either a property
  /// name, or an object of the form `{<sourceLayer>: <propertyName>}`.
  ///
  /// Spec: `promoteId`.
  final Object? promoteId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'data': encodeStyleJson(data),
    if (maxZoom != null) 'maxzoom': encodeStyleJson(maxZoom),
    if (attribution != null) 'attribution': encodeStyleJson(attribution),
    if (buffer != null) 'buffer': encodeStyleJson(buffer),
    if (filter != null) 'filter': encodeStyleJson(filter),
    if (tolerance != null) 'tolerance': encodeStyleJson(tolerance),
    if (cluster != null) 'cluster': encodeStyleJson(cluster),
    if (clusterRadius != null) 'clusterRadius': encodeStyleJson(clusterRadius),
    if (clusterMaxZoom != null)
      'clusterMaxZoom': encodeStyleJson(clusterMaxZoom),
    if (clusterMinPoints != null)
      'clusterMinPoints': encodeStyleJson(clusterMinPoints),
    if (clusterProperties != null)
      'clusterProperties': encodeStyleJson(clusterProperties),
    if (lineMetrics != null) 'lineMetrics': encodeStyleJson(lineMetrics),
    if (generateId != null) 'generateId': encodeStyleJson(generateId),
    if (promoteId != null) 'promoteId': encodeStyleJson(promoteId),
  };
}

/// A `video` style source.
///
/// Generated from the spec schema `source_video`. Add one with
/// `controller.layers.addSource(id, source)`.
@immutable
final class VideoSource extends StyleSource {
  /// Creates a `video` source.
  const VideoSource({required this.urls, required this.coordinates});

  @override
  String get type => 'video';

  /// URLs to video content in order of preferred format.
  ///
  /// Spec: `urls`.
  final List<String> urls;

  /// Corners of video specified in longitude, latitude pairs.
  ///
  /// Spec: `coordinates`.
  final List<List<double>> coordinates;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'urls': encodeStyleJson(urls),
    'coordinates': encodeStyleJson(coordinates),
  };
}

/// A `image` style source.
///
/// Generated from the spec schema `source_image`. Add one with
/// `controller.layers.addSource(id, source)`.
@immutable
final class ImageSource extends StyleSource {
  /// Creates a `image` source.
  const ImageSource({required this.url, required this.coordinates});

  @override
  String get type => 'image';

  /// URL that points to an image.
  ///
  /// Spec: `url`.
  final String url;

  /// Corners of image specified in longitude, latitude pairs.
  ///
  /// Spec: `coordinates`.
  final List<List<double>> coordinates;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'url': encodeStyleJson(url),
    'coordinates': encodeStyleJson(coordinates),
  };
}
