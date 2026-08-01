/// Typed GeoJSON: the seven RFC 7946 geometries, `Feature`,
/// `FeatureCollection`, and the query-result type the map returns.
///
/// A sub-library so an app can take the data types without the rest of the
/// platform interface. `package:maplibre_flutter` re-exports all of it.
///
/// Positions are [LatLng] throughout — GeoJSON's own `[lng, lat]` order is
/// flipped exactly once, at the parse/serialise boundary.
library;

export 'src/geojson/feature.dart';
export 'src/geojson/geometry.dart';
export 'src/lat_lng.dart' show LatLng;
