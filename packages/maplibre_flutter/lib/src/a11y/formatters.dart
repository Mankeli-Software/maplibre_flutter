import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart'
    show LatLng, MapCamera;

import 'locale.dart';

/// How verbose a compass direction reads.
///
/// Ports `NSFormattingUnitStyle` as MLNCompassDirectionFormatter uses it: it
/// treats `medium` and `long` identically, so there are two cases here, not
/// three.
enum MapCompassStyle {
  /// `NE`. For a visible label with no room, never for speech — a screen
  /// reader pronounces it letter by letter.
  short,

  /// `northeast`. The default, and what Apple's compass button and road
  /// elements both speak.
  long,
}

/// The 32-point rose, in the order MLNCompassDirectionFormatter lists it —
/// clockwise from north, one point every 11.25°.
///
/// These double as the key stems (`COMPASS_${stem}_LONG`) and as the `short`
/// style's own English values, exactly as upstream's two parallel arrays do.
const List<String> _compassPoints = <String>[
  'N', 'NbE', 'NNE', 'NEbN', 'NE', 'NEbE', 'ENE', 'EbN', //
  'E', 'EbS', 'ESE', 'SEbE', 'SE', 'SEbS', 'SSE', 'SbE',
  'S', 'SbW', 'SSW', 'SWbS', 'SW', 'SWbW', 'WSW', 'WbS',
  'W', 'WbN', 'WNW', 'NWbW', 'NW', 'NWbN', 'NNW', 'NbW',
];

/// The name of the compass point [bearing] degrees clockwise from true north.
///
/// A port of `-[MLNCompassDirectionFormatter stringFromDirection:]`, keys and
/// bucketing arithmetic both. The keys are Apple's verbatim (`COMPASS_N_LONG`,
/// `COMPASS_NbE_LONG`, …) so its translations of the `Foundation` table drop
/// straight into a [MapLibreLocale]; the arithmetic is copied rather than
/// rewritten because "round to the nearest 32nd" has a boundary at every
/// 5.625°, and re-deriving it is how one ends up off by half a point.
///
/// [bearing] is unwrapped: 450 and -270 both read as east, matching mbgl, where
/// a camera bearing accumulates rather than wrapping.
String compassDirectionName(
  double bearing, {
  MapCompassStyle style = MapCompassStyle.long,
  MapLibreLocale locale = const MapLibreLocale(),
}) {
  final count = _compassPoints.length;
  final point = _wrap(
    (_wrap(bearing, 0, 360) / 360 * count).roundToDouble(),
    0,
    count.toDouble(),
  ).toInt();
  final suffix = style == MapCompassStyle.short ? 'SHORT' : 'LONG';
  return locale.getUIString('COMPASS_${_compassPoints[point]}_$suffix');
}

/// [point] spoken as degrees, minutes and seconds with a hemisphere.
///
/// A port of `-[MLNCoordinateFormatter stringFromCoordinate:]` in its medium
/// unit style: `60°10′12″ north, 24°56′24″ east`.
///
/// **This is the only thing that tells a blind user where the map is** when the
/// style names nothing on screen — the map's spoken value has no other source
/// of place.
///
/// [zoom] gates precision the way MLNUserLocationAnnotationView does
/// (`MLNUserLocationAnnotationView.m:64-65`): minutes above zoom 8, seconds
/// above zoom 20. Announcing arc-seconds at z3 is noise nobody can act on —
/// a second of latitude is about 30 m, and a z3 tile is a continent. Omitting
/// [zoom] keeps MLNCoordinateFormatter's own defaults, which allow both.
String formatCoordinate(
  LatLng point, {
  double? zoom,
  MapLibreLocale locale = const MapLibreLocale(),
}) {
  final allowsMinutes = zoom == null || zoom > 8;
  final allowsSeconds = zoom == null || zoom > 20;
  return locale.getUIString(
    'COORD_FMT_MEDIUM',
    args: <String, Object?>{
      'latitude': _formatDegrees(
        point.latitude,
        placeholder: 'latitude',
        positiveKey: 'COORD_N_MEDIUM',
        negativeKey: 'COORD_S_MEDIUM',
        allowsMinutes: allowsMinutes,
        allowsSeconds: allowsSeconds,
        locale: locale,
      ),
      'longitude': _formatDegrees(
        point.longitude,
        placeholder: 'longitude',
        positiveKey: 'COORD_E_MEDIUM',
        negativeKey: 'COORD_W_MEDIUM',
        allowsMinutes: allowsMinutes,
        allowsSeconds: allowsSeconds,
        locale: locale,
      ),
    },
  );
}

/// `-[MLNCoordinateFormatter stringFromLocationDegrees:positiveFormat:negativeFormat:]`.
///
/// The three branches, the floor-versus-round split between them, and the
/// exactly-zero case that drops the hemisphere are all upstream's. The
/// asymmetry worth knowing about: the degrees-only branch *rounds* the whole
/// degrees while the other two *floor* them, so 60.7° alone reads "61°" but
/// with minutes allowed reads "60°42′".
String _formatDegrees(
  double degrees, {
  required String placeholder,
  required String positiveKey,
  required String negativeKey,
  required bool allowsMinutes,
  required bool allowsSeconds,
  required MapLibreLocale locale,
}) {
  final absolute = degrees.abs();
  final minutes = (absolute - absolute.floorToDouble()) * 60;
  final seconds = (minutes - minutes.floorToDouble()) * 60;

  String degreesString(int value) =>
      locale.getUIString('COORD_DEG_MEDIUM', args: {'degrees': value});
  String minutesString(int value) =>
      locale.getUIString('COORD_MIN_MEDIUM', args: {'minutes': value});
  String secondsString(int value) =>
      locale.getUIString('COORD_SEC_MEDIUM', args: {'seconds': value});

  final String string;
  if (seconds.truncateToDouble() > 0 && allowsSeconds) {
    string = locale.getUIString(
      'COORD_DMS_MEDIUM',
      args: <String, Object?>{
        'degrees': degreesString(absolute.floor()),
        'minutes': minutesString(minutes.floor()),
        'seconds': secondsString(seconds.round()),
      },
    );
  } else if (minutes.truncateToDouble() > 0 && allowsMinutes) {
    string = locale.getUIString(
      'COORD_DM_MEDIUM',
      args: <String, Object?>{
        'degrees': degreesString(absolute.floor()),
        'minutes': minutesString(minutes.round()),
      },
    );
  } else {
    string = degreesString(absolute.round());
  }

  // The equator and the prime meridian belong to no hemisphere, so upstream
  // returns the bare magnitude rather than picking one.
  if (degrees == 0) return string;
  return locale.getUIString(
    degrees > 0 ? positiveKey : negativeKey,
    args: <String, Object?>{placeholder: string},
  );
}

/// MLNCompassDirectionFormatter's `wrap` macro, into `[min, max)`.
///
/// The double modulo is upstream's, where it exists because C's `fmod` keeps
/// the dividend's sign. Dart's `%` is already non-negative for a positive
/// divisor, so the first pass is redundant here — kept anyway so the two
/// implementations stay line-comparable.
double _wrap(double value, double min, double max) {
  final range = max - min;
  return ((value - min) % range + range) % range + min;
}

/// Alt text for a still image of the map at [camera].
///
/// **A snapshot is the most common real-world map-accessibility failure**: an
/// image of a map in a share card, a list tile, an export or a PDF, with no text
/// alternative at all. It is also the easiest to fix, because the camera and the
/// style are both known at the moment the image is made — and it is the one case
/// [MapLibreFeatureList] cannot reach, since that binds to a live controller and
/// a snapshot has none.
///
/// Apple's `MLNMapSnapshot` carries `attributionInfos` for the same reason. Pass
/// [attribution] and the credit is part of the alt text, which discharges the
/// licence condition and SC 1.1.1 in one string.
///
/// ```dart
/// final image = await snapshotter.takeImage(...);
/// Image(
///   image: ...,
///   semanticLabel: describeCamera(camera, attribution: '© OpenStreetMap'),
/// );
/// ```
String describeCamera(
  MapCamera camera, {
  String? attribution,
  MapLibreLocale locale = const MapLibreLocale(),
}) {
  final facts = <String>[
    locale.getUIString(
      'Map.ValueCenter',
      args: <String, Object?>{
        'coordinate': formatCoordinate(
          camera.center,
          zoom: camera.zoom,
          locale: locale,
        ),
      },
    ),
    locale.getUIString(
      'Map.ValueZoom',
      args: <String, Object?>{'zoom': camera.zoom.round()},
    ),
    if (camera.bearing % 360 != 0)
      locale.getUIString(
        'Map.ValueBearing',
        args: <String, Object?>{
          'direction': compassDirectionName(camera.bearing, locale: locale),
        },
      ),
    if (attribution != null && attribution.isNotEmpty) attribution,
  ];
  return facts.join(' ');
}
