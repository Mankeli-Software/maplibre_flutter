import 'package:flutter/foundation.dart' show immutable;
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart'
    show LatLng;

import 'style_value.dart';

/// The `data` of a `GeoJsonSource`: a URL the engine fetches, or inline GeoJSON.
///
/// The spec types `data` as `*` (anything), so the generated source accepts a
/// bare `Object`. This is the typed way to build one.
@immutable
final class GeoJsonData implements StyleJson {
  const GeoJsonData._(this._value);

  /// A URL the engine fetches the GeoJSON from.
  const GeoJsonData.url(String url) : _value = url;

  /// Inline GeoJSON in map form — a Feature, FeatureCollection or geometry.
  const GeoJsonData.inline(Map<String, Object?> geoJson) : _value = geoJson;

  /// A `FeatureCollection` of plain points built from [points].
  ///
  /// GeoJSON coordinates are `[lng, lat]` — the opposite order to [LatLng].
  /// Flipped here, once, so callers never have to think about it.
  ///
  /// Pass [properties] to attach per-point properties (parallel to [points],
  /// so it must be the same length); features get empty properties otherwise.
  factory GeoJsonData.points(
    List<LatLng> points, {
    List<Map<String, Object?>>? properties,
  }) {
    if (properties != null && properties.length != points.length) {
      throw ArgumentError.value(
        properties.length,
        'properties',
        'must have one entry per point (${points.length})',
      );
    }
    return GeoJsonData._({
      'type': 'FeatureCollection',
      'features': [
        for (var i = 0; i < points.length; i++)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [points[i].longitude, points[i].latitude],
            },
            'properties': properties?[i] ?? const <String, Object?>{},
          },
      ],
    });
  }

  /// A single `LineString` feature through [points], in order.
  ///
  /// The line counterpart to [GeoJsonData.points], for a `LineLayer`. Same
  /// `[lng, lat]` flip, done here.
  factory GeoJsonData.lineThrough(
    List<LatLng> points, {
    Map<String, Object?>? properties,
  }) => GeoJsonData._({
    'type': 'Feature',
    'geometry': {
      'type': 'LineString',
      'coordinates': [
        for (final p in points) [p.longitude, p.latitude],
      ],
    },
    'properties': properties ?? const <String, Object?>{},
  });

  final Object _value;

  /// GeoJSON as given, with no number rewriting: coordinates stay doubles, the
  /// way every other GeoJSON producer emits them.
  @override
  Object? toJson() => _value;
}
