import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/geojson.dart';

import 'formatters.dart';
import 'locale.dart';

/// One rendered map feature, as assistive technology will hear it.
@immutable
class MapSemanticFeature {
  const MapSemanticFeature({
    required this.label,
    required this.point,
    this.value,
    this.id,
  });

  /// What is spoken. Never empty — a feature with nothing to say is dropped
  /// rather than announced as a blank.
  final String label;

  /// Extra facts read after the label: "One way, southwest to northeast".
  final String? value;

  /// Where it sits, for the node's rect.
  final LatLng point;

  /// Used to keep a node's identity across a pan, so assistive-technology focus
  /// does not jump mid-utterance.
  final Object? id;
}

/// Turns a queried feature into something worth announcing, or null to drop it.
typedef MapFeatureDescriber =
    MapSemanticFeature? Function(QueriedFeature feature, String layerId);

/// Exposes the map's own rendered content — roads, places, POIs — as semantics
/// nodes.
///
/// **Opt-in, and `layerIds` has no default.** Apple ships an allowlist of Mapbox
/// Streets source-layer names gated behind an `isMapboxStreets` check, so
/// copying it would reproduce a feature that is dead on every MapLibre style,
/// and guessing a schema would announce wrong names. A wrong announcement is
/// worse than silence. The honest consequence is that the most differentiating
/// part of this design reaches only apps that read the docs — the same outcome
/// Apple's vendor gate produces, by a different route and for a better reason.
@immutable
class MapFeatureSemantics {
  const MapFeatureSemantics({
    required this.layerIds,
    this.labelProperties = const <String>['name:{lang}', 'name_{lang}', 'name'],
    this.describe,
    this.maxNodes = 32,
  });

  /// Which style layers to read. Required, deliberately.
  final List<String> layerIds;

  /// Property names to try for the spoken name, in order. `{lang}` is replaced
  /// with the locale's language code. Two spellings because OpenMapTiles uses
  /// `name:en` and Mapbox uses `name_en`, and one list covers both.
  final List<String> labelProperties;

  /// Overrides the default describer for full control. Returning null drops the
  /// feature, which is the right answer when a layer is decorative.
  final MapFeatureDescriber? describe;

  /// Hard cap on nodes per settle.
  ///
  /// Apple caps nothing, and a dense POI style yields hundreds of swipe stops —
  /// which in Flutter is hundreds of real semantics nodes. The number is an
  /// honest guess: nobody knows how many stops a user tolerates before the map
  /// is worse than silence.
  final int maxNodes;
}

/// The default describer, ported from `MLNPlaceFeatureAccessibilityElement` and
/// `MLNRoadFeatureAccessibilityElement`.
///
/// Pure and exported so it is testable without a map.
MapSemanticFeature? describeMapLibreFeature(
  QueriedFeature feature,
  String layerId, {
  MapLibreLocale locale = const MapLibreLocale(),
  List<String> labelProperties = const <String>[
    'name:{lang}',
    'name_{lang}',
    'name',
  ],
  String languageCode = 'en',
}) {
  final point = representativePoint(feature.geometry);
  if (point == null) return null;

  final name = _firstString(feature.properties, labelProperties, languageCode);
  final ref = feature.properties['ref']?.toString();
  final facts = <String>[];

  // Apple's fact order, verbatim: ref, then oneway, then divided, then the
  // direction the road runs.
  if (ref != null && ref.isNotEmpty) {
    facts.add(
      locale.getUIString(
        'ROAD_REF_A11Y_FMT',
        args: <String, Object?>{'ref': ref},
      ),
    );
  }
  if (feature.properties['oneway']?.toString() == 'true') {
    facts.add(locale.getUIString('ROAD_ONEWAY_A11Y_VALUE'));
  }
  if (feature.geometry is GeoJsonMultiLineString) {
    facts.add(locale.getUIString('ROAD_DIVIDED_A11Y_VALUE'));
  }
  final ends = _lineEnds(feature.geometry);
  if (ends != null) {
    facts.add(
      locale.getUIString(
        'ROAD_DIRECTION_A11Y_FMT',
        args: <String, Object?>{
          'from': compassDirectionName(
            _bearing(ends.$1, ends.$2),
            locale: locale,
          ),
          'to': compassDirectionName(
            _bearing(ends.$2, ends.$1),
            locale: locale,
          ),
        },
      ),
    );
  }

  final label = name ?? (facts.isNotEmpty ? facts.removeAt(0) : null);
  // A feature with no name and no facts is dropped rather than announced as a
  // blank stop on the swipe path.
  if (label == null || label.isEmpty) return null;

  return MapSemanticFeature(
    label: label,
    value: facts.isEmpty
        ? null
        : facts.join(locale.getUIString('LIST_SEPARATOR')),
    point: point,
    id: feature.id,
  );
}

String? _firstString(
  Map<String, Object?> properties,
  List<String> keys,
  String languageCode,
) {
  for (final key in keys) {
    final resolved = key.replaceAll('{lang}', languageCode);
    final value = properties[resolved];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}

/// A single point standing for a whole geometry, for the node's rect.
///
/// A `SemanticsNode` carries a rect and a transform and no path, so a road
/// degrades from Apple's stroked polyline to one sample. Explore-by-touch along
/// a motorway will not follow it — documented, not hidden.
LatLng? representativePoint(GeoJsonGeometry? geometry) => switch (geometry) {
  GeoJsonPoint(:final coordinates) => coordinates,
  GeoJsonMultiPoint(:final coordinates) => _middle(coordinates),
  GeoJsonLineString(:final coordinates) => _middle(coordinates),
  GeoJsonMultiLineString(:final coordinates) =>
    coordinates.isEmpty ? null : _middle(coordinates.first),
  GeoJsonPolygon(:final coordinates) =>
    coordinates.isEmpty ? null : _middle(coordinates.first),
  GeoJsonMultiPolygon(:final coordinates) =>
    coordinates.isEmpty || coordinates.first.isEmpty
        ? null
        : _middle(coordinates.first.first),
  GeoJsonGeometryCollection(:final geometries) =>
    geometries.isEmpty ? null : representativePoint(geometries.first),
  null => null,
};

LatLng? _middle(List<LatLng> points) =>
    points.isEmpty ? null : points[points.length ~/ 2];

/// The two ends of a line, in Apple's order: last, then first.
(LatLng, LatLng)? _lineEnds(GeoJsonGeometry? geometry) {
  final List<LatLng> line = switch (geometry) {
    GeoJsonLineString(:final coordinates) => coordinates,
    GeoJsonMultiLineString(:final coordinates) =>
      coordinates.isEmpty ? const <LatLng>[] : coordinates.first,
    _ => const <LatLng>[],
  };
  if (line.length < 2) return null;
  return (line.last, line.first);
}

/// Initial bearing from [a] to [b], degrees clockwise from true north.
double _bearing(LatLng a, LatLng b) {
  final phi1 = a.latitude * math.pi / 180;
  final phi2 = b.latitude * math.pi / 180;
  final dLambda = (b.longitude - a.longitude) * math.pi / 180;
  final y = math.sin(dLambda) * math.cos(phi2);
  final x =
      math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}
