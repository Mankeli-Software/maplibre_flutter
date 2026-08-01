import 'package:flutter/foundation.dart';

import '../lat_lng.dart';
import 'geometry.dart';

/// A GeoJSON `Feature` (RFC 7946 §3.2): an optional [id], a [geometry] and a
/// bag of [properties].
///
/// Mirrors gl-js's GeoJSON `Feature` and `mbgl::GeoJSONFeature`
/// (`include/mbgl/util/feature.hpp`). Query results arrive as the richer
/// [QueriedFeature] subclass.
@immutable
base class GeoJsonFeature {
  const GeoJsonFeature({
    this.id,
    this.geometry,
    this.properties = const <String, Object?>{},
  });

  /// Parses one RFC 7946 feature object.
  ///
  /// Throws a [FormatException] — and nothing else — on anything malformed.
  factory GeoJsonFeature.fromJson(Map<String, Object?> json) => GeoJsonFeature(
    id: _featureId(json['id']),
    geometry: _featureGeometry(json['geometry']),
    properties: _featureProperties(json['properties']),
  );

  /// The feature's own identifier, `null` when it has none.
  ///
  /// RFC 7946 allows a string or a number, and mbgl's `FeatureIdentifier` is
  /// the same union, so this stays `Object?` rather than being forced to
  /// `String`. It is the identifier `setFeatureState` will key on — and mbgl
  /// never parses `promoteId` or `generateId`, so a feature without its own
  /// `id` cannot carry state.
  final Object? id;

  /// The geometry, or `null` — RFC 7946 §3.2 permits an unlocated feature.
  final GeoJsonGeometry? geometry;

  /// The feature's properties. Clustered sources add `point_count`,
  /// `point_count_abbreviated` and `cluster_id`.
  final Map<String, Object?> properties;

  /// This feature as an RFC 7946 object.
  ///
  /// Deliberately **not** routed through the style-spec encoder: that one
  /// rewrites `6.0` to `6`, and these bytes are the one path into mbgl's
  /// GeoJSON parser.
  Map<String, Object?> toJson() => {
    'type': 'Feature',
    if (id != null) 'id': id,
    'geometry': geometry?.toJson(),
    'properties': properties,
  };

  @override
  bool operator ==(Object other) =>
      other is GeoJsonFeature &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.geometry == geometry &&
      mapEquals(other.properties, properties);

  @override
  int get hashCode =>
      Object.hash(id, geometry, Object.hashAll(properties.keys));

  @override
  String toString() => 'GeoJsonFeature(id: $id, $geometry)';
}

/// A GeoJSON `FeatureCollection` (RFC 7946 §3.3).
@immutable
final class GeoJsonFeatureCollection {
  const GeoJsonFeatureCollection(this.features);

  /// Parses one RFC 7946 feature-collection object.
  ///
  /// Throws a [FormatException] — and nothing else — on anything malformed.
  factory GeoJsonFeatureCollection.fromJson(Map<String, Object?> json) {
    final raw = json['features'];
    if (raw is! List<Object?>) {
      throw FormatException(
        'a FeatureCollection needs a "features" list, got ${raw.runtimeType}',
      );
    }
    final features = <GeoJsonFeature>[];
    for (final f in raw) {
      if (f is! Map<String, Object?>) {
        throw FormatException('expected a feature, got ${f.runtimeType}');
      }
      features.add(GeoJsonFeature.fromJson(f));
    }
    return GeoJsonFeatureCollection(features);
  }

  /// The member features.
  final List<GeoJsonFeature> features;

  /// This collection as an RFC 7946 object.
  Map<String, Object?> toJson() => {
    'type': 'FeatureCollection',
    'features': [for (final f in features) f.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is GeoJsonFeatureCollection && listEquals(other.features, features);

  @override
  int get hashCode => Object.hashAll(features);

  @override
  String toString() => 'GeoJsonFeatureCollection(${features.length} features)';
}

/// One feature the engine drew or stored, as returned by the query methods.
///
/// Mirrors gl-js's `MapGeoJSONFeature`: a GeoJSON [GeoJsonFeature] widened with
/// the provenance a query can report. mbgl's own type is `mbgl::Feature`
/// (`include/mbgl/util/feature.hpp`), which is exactly `GeoJSONFeature` plus
/// [source], [sourceLayer] and [state].
///
/// **There is deliberately no `layer` field**, though gl-js has one.
/// `RenderOrchestrator::queryRenderedFeatures` builds its results grouped by
/// layer and then flattens them into a single `std::vector<Feature>`
/// (`src/mbgl/renderer/render_orchestrator.cpp`), so per-feature layer
/// attribution is destroyed inside the engine and the Apple SDK returns the
/// same flattened array. Query one layer at a time if you need to know which
/// layer matched.
@immutable
final class QueriedFeature extends GeoJsonFeature {
  const QueriedFeature({
    super.id,
    super.geometry,
    super.properties,
    this.source,
    this.sourceLayer,
    this.state = const <String, Object?>{},
  });

  /// Parses one queried feature.
  ///
  /// Throws a [FormatException] — and nothing else — on anything malformed.
  factory QueriedFeature.fromJson(Map<String, Object?> json) {
    final source = json['source'];
    final sourceLayer = json['sourceLayer'];
    final state = json['state'];
    return QueriedFeature(
      id: _featureId(json['id']),
      geometry: _featureGeometry(json['geometry']),
      properties: _featureProperties(json['properties']),
      source: source is String ? source : null,
      sourceLayer: sourceLayer is String ? sourceLayer : null,
      state: state is Map<String, Object?> ? state : const <String, Object?>{},
    );
  }

  /// The id of the source this feature came from.
  ///
  /// **Null on every native tier today.** `mbgl::Feature` carries it, but the C
  /// shim copies the query result into a `mapbox::feature::feature_collection`
  /// before serialising, which slices this field, [sourceLayer] and [state] off.
  /// Fixing that is a shim change, tracked as stage 6 of
  /// `docs/api-parity-progress.md`.
  final String? source;

  /// The source layer (vector tile layer) this feature came from, or `null` for
  /// a source that has none. Subject to the same slicing as [source].
  final String? sourceLayer;

  /// The feature state set with `setFeatureState`. Subject to the same slicing
  /// as [source], so empty on every native tier today.
  final Map<String, Object?> state;

  /// Where the engine placed it, when the geometry is a single point — which is
  /// what a circle or symbol layer returns, and what a cluster returns (its own
  /// position, which is not any one of the underlying points).
  ///
  /// `null` for a line or polygon feature. Use [geometry] for those.
  LatLng? get point => switch (geometry) {
    final GeoJsonPoint p => p.coordinates,
    _ => null,
  };

  /// True when this is a cluster rather than a single feature.
  ///
  /// Mirrors Apple's `MLNCluster` protocol, which exposes the same two facts as
  /// `clusterIdentifier` and `clusterPointCount`.
  bool get isCluster => properties['point_count'] != null;

  /// How many points this cluster stands for; 1 for a single feature.
  int get pointCount => (properties['point_count'] as num?)?.toInt() ?? 1;

  /// The cluster's id, or `null` when this is not a cluster. It is what
  /// `getClusterExpansionZoom` and friends take.
  int? get clusterId => (properties['cluster_id'] as num?)?.toInt();

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    if (source != null) 'source': source,
    if (sourceLayer != null) 'sourceLayer': sourceLayer,
    if (state.isNotEmpty) 'state': state,
  };

  @override
  bool operator ==(Object other) =>
      other is QueriedFeature &&
      super == other &&
      other.source == source &&
      other.sourceLayer == sourceLayer &&
      mapEquals(other.state, state);

  @override
  int get hashCode => Object.hash(super.hashCode, source, sourceLayer);

  @override
  String toString() =>
      'QueriedFeature(id: $id, $geometry, cluster: $isCluster, '
      'count: $pointCount)';
}

// --- Shared field parsing ----------------------------------------------------
//
// Split out so GeoJsonFeature and QueriedFeature cannot drift, and so every
// failure is a FormatException rather than an unchecked cast's TypeError.

/// Reads a feature `id`: a string or a number, per RFC 7946 §3.2.
Object? _featureId(Object? raw) {
  if (raw == null) return null;
  if (raw is String || raw is num) return raw;
  throw FormatException(
    'a feature id must be a string or a number, got ${raw.runtimeType}',
  );
}

/// Reads a feature `geometry`, which RFC 7946 allows to be null.
GeoJsonGeometry? _featureGeometry(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map<String, Object?>) {
    throw FormatException('expected a geometry object, got ${raw.runtimeType}');
  }
  return GeoJsonGeometry.fromJson(raw);
}

/// Reads a feature `properties`, which RFC 7946 allows to be null.
Map<String, Object?> _featureProperties(Object? raw) {
  if (raw == null) return const <String, Object?>{};
  if (raw is! Map<String, Object?>) {
    throw FormatException(
      'expected a properties object, got ${raw.runtimeType}',
    );
  }
  return raw;
}
