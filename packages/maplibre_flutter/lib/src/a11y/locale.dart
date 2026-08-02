import 'package:flutter/foundation.dart';

/// Every user-visible string the map speaks or labels, and the patch map that
/// replaces them.
///
/// This is a flat `Map<String, String>` patched over a default table, not a
/// `LocalizationsDelegate` + `.arb` set, and that is a deliberate choice with
/// three reasons behind it.
///
/// **The keys are upstream's, so upstream's translations line up 1:1.** The
/// first half of [defaultLocale] is maplibre-gl-js's `defaultLocale`
/// (`src/ui/default_locale.ts`) verbatim — an app that already ships gl-js
/// translations can hand them straight to [MapLibreLocale.new]. The second half
/// takes the MapLibre Apple SDK's `*_A11Y_*` key names, and Apple ships 24
/// translated locales of them under BSD-3. Inventing our own key names would
/// throw both away, which is exactly what CLAUDE.md §9 forbids.
///
/// **`flutter_localizations` + `intl` would be avoidable dependencies.** This
/// package already declines `url_launcher` for attribution links and
/// `geolocator` for the location puck; a localization stack is a much larger
/// dependency than either, imposed on every consumer for a table of forty-odd
/// strings.
///
/// **And it would be a third generated-code surface.** ffigen and the typed
/// style API are both guarded by regen-diff jobs that CI — being
/// `workflow_dispatch`-only — never runs. A third one would rot the same way,
/// silently.
///
/// ## Importing upstream translations
///
/// Keys with no placeholder import verbatim. Keys carrying one need a
/// mechanical rewrite of Apple's positional `%@`/`%d`/`%1$@` into our named
/// `{placeholder}` form: Dart has no positional format string, and a named
/// placeholder survives a translator reordering the sentence, which is the
/// normal case in German and Finnish.
///
/// **`MAP_A11Y_VALUE_ZOOM` is deliberately absent, and must stay absent.**
/// Apple speaks a magnification factor (`Zoom %dx.`, fed `round(zoomLevel) + 1`),
/// we speak the zoom level itself (§5.1 divergence 2 — Flutter's
/// increase/decrease actions make Apple's off-by-one contradict the spoken
/// value). Carrying Apple's key would mean an app importing Apple's 24 locales
/// gets a string that is *wrong in every one of them*, with nothing to catch it.
/// Our equivalent is [kZoomValueKey]. Any future string whose meaning diverges
/// from Apple's gets a new key for the same reason.
@immutable
class MapLibreLocale {
  /// A locale that patches [defaultLocale] with [overrides].
  ///
  /// A key absent from [overrides] falls through to the default table, so a
  /// partial translation is legitimate and an app can override one string
  /// without restating forty.
  const MapLibreLocale([this.overrides = const <String, String>{}]);

  /// The strings this locale replaces, keyed exactly as [defaultLocale] is.
  ///
  /// Unknown keys are permitted and ignored — a full gl-js translation table
  /// contains keys for controls we do not ship.
  final Map<String, String> overrides;

  /// The key for the map's spoken zoom, which is **not** Apple's
  /// `MAP_A11Y_VALUE_ZOOM`.
  ///
  /// Named so the divergence documented on [MapLibreLocale] is greppable from
  /// the call sites rather than only from this file.
  static const String kZoomValueKey = 'Map.ValueZoom';

  /// The built-in English strings.
  ///
  /// Provenance is marked per block. Do not add a key here under an upstream
  /// name unless the string means what upstream's means.
  static const Map<String, String> defaultLocale = <String, String>{
    // maplibre-gl-js `src/ui/default_locale.ts`, verbatim — all 25 keys.
    'AttributionControl.ToggleAttribution': 'Toggle attribution',
    'AttributionControl.MapFeedback': 'Map feedback',
    'FullscreenControl.Enter': 'Enter fullscreen',
    'FullscreenControl.Exit': 'Exit fullscreen',
    'GeolocateControl.FindMyLocation': 'Find my location',
    'GeolocateControl.LocationNotAvailable': 'Location not available',
    'LogoControl.Title': 'MapLibre logo',
    'Map.Title': 'Map',
    'Marker.Title': 'Map marker',
    'NavigationControl.ResetBearing':
        'Drag to rotate map, click to reset north',
    'NavigationControl.ZoomIn': 'Zoom in',
    'NavigationControl.ZoomOut': 'Zoom out',
    'Popup.Close': 'Close popup',
    'ScaleControl.Feet': 'ft',
    'ScaleControl.Meters': 'm',
    'ScaleControl.Kilometers': 'km',
    'ScaleControl.Miles': 'mi',
    'ScaleControl.NauticalMiles': 'nm',
    'GlobeControl.Enable': 'Enable globe',
    'GlobeControl.Disable': 'Disable globe',
    'TerrainControl.Enable': 'Enable terrain',
    'TerrainControl.Disable': 'Disable terrain',
    'CooperativeGesturesHandler.WindowsHelpText':
        'Use Ctrl + scroll to zoom the map',
    'CooperativeGesturesHandler.MacHelpText': 'Use ⌘ + scroll to zoom the map',
    'CooperativeGesturesHandler.MobileHelpText':
        'Use two fingers to move the map',

    // MapLibre Apple SDK, `platform/ios/resources/Base.lproj/Localizable.strings`.
    // These carry no placeholder, so Apple's 24 locales import unchanged.
    'ANNOTATION_A11Y_HINT': 'Shows more info',
    'CLOSE_CALLOUT_A11Y_HINT': 'Returns to the map',
    'COMPASS_A11Y_LABEL': 'Compass',
    'COMPASS_A11Y_HINT': 'Rotates the map to face due north',
    'INFO_A11Y_LABEL': 'About this map',
    'INFO_A11Y_HINT': 'Shows credits, a feedback form, and more',
    'USER_DOT_TITLE': 'You Are Here',
    'ROAD_ONEWAY_A11Y_VALUE': 'One way',
    'ROAD_DIVIDED_A11Y_VALUE': 'Divided road',

    // A key, never a literal: Apple localizes it, and French uses '; '.
    'LIST_SEPARATOR': ', ',

    // Apple keys whose values hold a placeholder — import after rewriting
    // `%@`/`%1$@` to the named form.
    'ROAD_REF_A11Y_FMT': 'Route {ref}',
    'ROAD_DIRECTION_A11Y_FMT': '{from} to {to}',

    // Apple `en.lproj/Localizable.stringsdict`, as `.one`/`.other` pairs. Our
    // wording says "marker" where Apple says "annotation" — the same referent
    // under this package's vocabulary, so the translations still apply.
    'MAP_A11Y_VALUE_ANNOTATIONS.one': '{count} marker visible.',
    'MAP_A11Y_VALUE_ANNOTATIONS.other': '{count} markers visible.',

    // MLNCompassDirectionFormatter's 32-point rose, `Foundation` table, both
    // unit styles, verbatim key names and default values.
    'COMPASS_N_SHORT': 'N',
    'COMPASS_NbE_SHORT': 'NbE',
    'COMPASS_NNE_SHORT': 'NNE',
    'COMPASS_NEbN_SHORT': 'NEbN',
    'COMPASS_NE_SHORT': 'NE',
    'COMPASS_NEbE_SHORT': 'NEbE',
    'COMPASS_ENE_SHORT': 'ENE',
    'COMPASS_EbN_SHORT': 'EbN',
    'COMPASS_E_SHORT': 'E',
    'COMPASS_EbS_SHORT': 'EbS',
    'COMPASS_ESE_SHORT': 'ESE',
    'COMPASS_SEbE_SHORT': 'SEbE',
    'COMPASS_SE_SHORT': 'SE',
    'COMPASS_SEbS_SHORT': 'SEbS',
    'COMPASS_SSE_SHORT': 'SSE',
    'COMPASS_SbE_SHORT': 'SbE',
    'COMPASS_S_SHORT': 'S',
    'COMPASS_SbW_SHORT': 'SbW',
    'COMPASS_SSW_SHORT': 'SSW',
    'COMPASS_SWbS_SHORT': 'SWbS',
    'COMPASS_SW_SHORT': 'SW',
    'COMPASS_SWbW_SHORT': 'SWbW',
    'COMPASS_WSW_SHORT': 'WSW',
    'COMPASS_WbS_SHORT': 'WbS',
    'COMPASS_W_SHORT': 'W',
    'COMPASS_WbN_SHORT': 'WbN',
    'COMPASS_WNW_SHORT': 'WNW',
    'COMPASS_NWbW_SHORT': 'NWbW',
    'COMPASS_NW_SHORT': 'NW',
    'COMPASS_NWbN_SHORT': 'NWbN',
    'COMPASS_NNW_SHORT': 'NNW',
    'COMPASS_NbW_SHORT': 'NbW',
    'COMPASS_N_LONG': 'north',
    'COMPASS_NbE_LONG': 'north by east',
    'COMPASS_NNE_LONG': 'north-northeast',
    'COMPASS_NEbN_LONG': 'northeast by north',
    'COMPASS_NE_LONG': 'northeast',
    'COMPASS_NEbE_LONG': 'northeast by east',
    'COMPASS_ENE_LONG': 'east-northeast',
    'COMPASS_EbN_LONG': 'east by north',
    'COMPASS_E_LONG': 'east',
    'COMPASS_EbS_LONG': 'east by south',
    'COMPASS_ESE_LONG': 'east-southeast',
    'COMPASS_SEbE_LONG': 'southeast by east',
    'COMPASS_SE_LONG': 'southeast',
    'COMPASS_SEbS_LONG': 'southeast by south',
    'COMPASS_SSE_LONG': 'south-southeast',
    'COMPASS_SbE_LONG': 'south by east',
    'COMPASS_S_LONG': 'south',
    'COMPASS_SbW_LONG': 'south by west',
    'COMPASS_SSW_LONG': 'south-southwest',
    'COMPASS_SWbS_LONG': 'southwest by south',
    'COMPASS_SW_LONG': 'southwest',
    'COMPASS_SWbW_LONG': 'southwest by west',
    'COMPASS_WSW_LONG': 'west-southwest',
    'COMPASS_WbS_LONG': 'west by south',
    'COMPASS_W_LONG': 'west',
    'COMPASS_WbN_LONG': 'west by north',
    'COMPASS_WNW_LONG': 'west-northwest',
    'COMPASS_NWbW_LONG': 'northwest by west',
    'COMPASS_NW_LONG': 'northwest',
    'COMPASS_NWbN_LONG': 'northwest by north',
    'COMPASS_NNW_LONG': 'north-northwest',
    'COMPASS_NbW_LONG': 'north by west',

    // MLNCoordinateFormatter, `Foundation` table. Only the medium unit style is
    // ported: it is the one MLNMapView and MLNUserLocationAnnotationView use,
    // and formatCoordinate exposes no style to select the others with.
    'COORD_N_MEDIUM': '{latitude} north',
    'COORD_S_MEDIUM': '{latitude} south',
    'COORD_E_MEDIUM': '{longitude} east',
    'COORD_W_MEDIUM': '{longitude} west',
    'COORD_FMT_MEDIUM': '{latitude}, {longitude}',
    'COORD_DEG_MEDIUM': '{degrees}°',
    'COORD_MIN_MEDIUM': '{minutes}′',
    'COORD_SEC_MEDIUM': '{seconds}″',
    'COORD_DM_MEDIUM': '{degrees}{minutes}',
    'COORD_DMS_MEDIUM': '{degrees}{minutes}{seconds}',

    // Ours. No upstream ships a keyboard or accessibility-action vocabulary for
    // a map, so these follow gl-js's `Namespace.Name` spelling rather than
    // Apple's SCREAMING_SNAKE.
    'Map.ValueZoom': 'Zoom {zoom}.',
    'Map.ValueCenter': 'Centred on {coordinate}.',
    'Map.ValueBearing': 'Facing {direction}.',
    'Map.ValuePitch': 'Tilted {pitch} degrees.',
    'Map.Hint': 'Swipe up or down to zoom. Use the actions to pan and rotate.',

    // Load state. Announced FIRST when it is not `ready`, because a blank map
    // and an ocean produce the same camera summary — "Zoom 12. 0 markers
    // visible." — and a sighted user can tell them apart at a glance. This is
    // the gap gl-js has too: it announces no errors at all, anywhere.
    'Map.Loading': 'Map loading.',
    'Map.LoadFailed': 'The map could not be loaded.',
    'Map.PartiallyLoaded': 'Some of the map could not be loaded.',

    'Action.PanNorth': 'Pan north',
    'Action.PanSouth': 'Pan south',
    'Action.PanEast': 'Pan east',
    'Action.PanWest': 'Pan west',
    'Action.RotateLeft': 'Rotate left',
    'Action.RotateRight': 'Rotate right',
    'Action.ResetNorth': 'Reset north',
    'Action.TiltUp': 'Tilt up',
    'Action.TiltDown': 'Tilt down',
    'Action.ResetTilt': 'Reset tilt',
    'Controls.Expand': 'Show map controls',
    'Controls.Collapse': 'Hide map controls',
  };

  /// The string for [key], with every `{name}` in it replaced from [args].
  ///
  /// A missing key **asserts**, copying gl-js's `_getUIString` throw. That
  /// throw is the only thing standing between a typo and a control that ships
  /// with no accessible name at all, which no test that merely looks for a node
  /// would catch. Release builds fall through to [defaultLocale] and, failing
  /// that, return the key itself — visible in a screen reader and greppable in
  /// a bug report, which a blank string is not.
  String getUIString(
    String key, {
    Map<String, Object?> args = const <String, Object?>{},
  }) {
    final value = overrides[key] ?? defaultLocale[key];
    assert(
      value != null,
      'No string for "$key". Add it to MapLibreLocale.defaultLocale, or pass '
      'it in the overrides map.',
    );
    return _substitute(value ?? key, args);
  }

  /// The `.one`/`.other` variant of [key] for [count], with `{count}` bound.
  ///
  /// The key convention mirrors Apple's `Localizable.stringsdict`, so
  /// `MAP_A11Y_VALUE_ANNOTATIONS` here is the same string it is there.
  ///
  /// **This is two plural categories, and CLDR defines six.** Russian, Polish
  /// and Czech need `few` and `many`; Arabic needs `zero`, `two` and `few`;
  /// Welsh needs all six. Every one of them lands on `.other` here, so a
  /// Russian translation reads correctly for 1 and for 5 and wrongly for 2. The
  /// honest fix is `intl`, and the cost of `intl` is the dependency this class
  /// exists to avoid. An app that needs real plural rules should override the
  /// map value through `MapSemanticsValue.custom` and format the count itself.
  String plural(
    String key,
    int count, {
    Map<String, Object?> args = const <String, Object?>{},
  }) {
    final variant = count == 1 ? '.one' : '.other';
    return getUIString(
      '$key$variant',
      args: <String, Object?>{'count': count, ...args},
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MapLibreLocale && mapEquals(other.overrides, overrides);

  @override
  int get hashCode => Object.hashAllUnordered(
    overrides.entries.map((e) => Object.hash(e.key, e.value)),
  );
}

/// `{name}` → `args['name']`.
///
/// Named rather than positional because Dart has no `printf`, and because a
/// translator moving `{count}` to the end of the sentence — which German and
/// Finnish routinely require — must not silently swap two substitutions.
String _substitute(String template, Map<String, Object?> args) {
  if (!template.contains('{')) return template;
  return template.replaceAllMapped(_placeholder, (match) {
    final name = match.group(1)!;
    assert(
      args.containsKey(name),
      'No argument "$name" for "$template". Placeholders are named, so a '
      'missing one is a call-site bug, not a translation bug.',
    );
    return args.containsKey(name) ? '${args[name]}' : match.group(0)!;
  });
}

final RegExp _placeholder = RegExp(r'\{(\w+)\}');
