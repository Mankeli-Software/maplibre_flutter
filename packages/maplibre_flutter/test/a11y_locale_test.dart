import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/src/a11y/locale.dart';

/// maplibre-gl-js `src/ui/default_locale.ts` @ 74590c62, restated here rather
/// than derived from the table under test — the point is to catch a typo made
/// while transcribing it, which a self-referential loop could not.
const Map<String, String> _glJsDefaultLocale = <String, String>{
  'AttributionControl.ToggleAttribution': 'Toggle attribution',
  'AttributionControl.MapFeedback': 'Map feedback',
  'FullscreenControl.Enter': 'Enter fullscreen',
  'FullscreenControl.Exit': 'Exit fullscreen',
  'GeolocateControl.FindMyLocation': 'Find my location',
  'GeolocateControl.LocationNotAvailable': 'Location not available',
  'LogoControl.Title': 'MapLibre logo',
  'Map.Title': 'Map',
  'Marker.Title': 'Map marker',
  'NavigationControl.ResetBearing': 'Drag to rotate map, click to reset north',
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
};

void main() {
  group('defaultLocale', () {
    test('carries every gl-js key with its exact upstream value', () {
      for (final entry in _glJsDefaultLocale.entries) {
        expect(
          MapLibreLocale.defaultLocale[entry.key],
          entry.value,
          reason: 'gl-js key ${entry.key} must be verbatim',
        );
      }
      expect(_glJsDefaultLocale.length, 25);
    });

    test('carries the Apple a11y strings verbatim', () {
      expect(
        MapLibreLocale.defaultLocale['ANNOTATION_A11Y_HINT'],
        'Shows more info',
      );
      expect(
        MapLibreLocale.defaultLocale['CLOSE_CALLOUT_A11Y_HINT'],
        'Returns to the map',
      );
      expect(MapLibreLocale.defaultLocale['COMPASS_A11Y_LABEL'], 'Compass');
      expect(
        MapLibreLocale.defaultLocale['COMPASS_A11Y_HINT'],
        'Rotates the map to face due north',
      );
      expect(MapLibreLocale.defaultLocale['INFO_A11Y_LABEL'], 'About this map');
      expect(
        MapLibreLocale.defaultLocale['INFO_A11Y_HINT'],
        'Shows credits, a feedback form, and more',
      );
      expect(MapLibreLocale.defaultLocale['USER_DOT_TITLE'], 'You Are Here');
      expect(MapLibreLocale.defaultLocale['ROAD_ONEWAY_A11Y_VALUE'], 'One way');
      expect(
        MapLibreLocale.defaultLocale['ROAD_DIVIDED_A11Y_VALUE'],
        'Divided road',
      );
    });

    test('does not carry Apple MAP_A11Y_VALUE_ZOOM, whose meaning diverges', () {
      // Apple speaks a magnification factor fed `round(zoomLevel) + 1`; we
      // speak the zoom level. Defining the key would silently mistranslate the
      // map's value in all 24 of Apple's locales.
      expect(
        MapLibreLocale.defaultLocale.containsKey('MAP_A11Y_VALUE_ZOOM'),
        isFalse,
      );
      expect(
        const MapLibreLocale().getUIString(
          MapLibreLocale.kZoomValueKey,
          args: {'zoom': 12},
        ),
        'Zoom 12.',
      );
    });

    test('LIST_SEPARATOR is a key an app can localize, not a literal', () {
      expect(const MapLibreLocale().getUIString('LIST_SEPARATOR'), ', ');
      // French typography puts a semicolon here.
      const french = MapLibreLocale(<String, String>{'LIST_SEPARATOR': ' ; '});
      expect(french.getUIString('LIST_SEPARATOR'), ' ; ');
    });
  });

  group('getUIString', () {
    test('asserts on a missing key in debug', () {
      expect(
        () => const MapLibreLocale().getUIString('NoSuch.Key'),
        throwsAssertionError,
      );
    });

    test('an override wins, and an unlisted key still falls back', () {
      const finnish = MapLibreLocale(<String, String>{
        'Map.Title': 'Kartta',
        'NavigationControl.ZoomIn': 'Lähennä',
      });
      expect(finnish.getUIString('Map.Title'), 'Kartta');
      expect(finnish.getUIString('NavigationControl.ZoomIn'), 'Lähennä');
      expect(finnish.getUIString('NavigationControl.ZoomOut'), 'Zoom out');
    });

    test('substitutes named placeholders', () {
      expect(
        const MapLibreLocale().getUIString(
          'ROAD_REF_A11Y_FMT',
          args: {'ref': '42'},
        ),
        'Route 42',
      );
    });

    test('binds each placeholder by name, not by position', () {
      // Asymmetric on purpose: swapping the two arguments must be visible.
      expect(
        const MapLibreLocale().getUIString(
          'ROAD_DIRECTION_A11Y_FMT',
          args: {'from': 'southwest', 'to': 'northeast'},
        ),
        'southwest to northeast',
      );
      // A translation that reorders the sentence still binds correctly.
      const reordered = MapLibreLocale(<String, String>{
        'ROAD_DIRECTION_A11Y_FMT': 'kohteeseen {to} kohteesta {from}',
      });
      expect(
        reordered.getUIString(
          'ROAD_DIRECTION_A11Y_FMT',
          args: {'from': 'southwest', 'to': 'northeast'},
        ),
        'kohteeseen northeast kohteesta southwest',
      );
    });

    test('asserts when a placeholder has no argument', () {
      expect(
        () => const MapLibreLocale().getUIString('ROAD_REF_A11Y_FMT'),
        throwsAssertionError,
      );
      expect(
        () => const MapLibreLocale().getUIString(
          'ROAD_REF_A11Y_FMT',
          args: {'wrongName': '42'},
        ),
        throwsAssertionError,
      );
    });
  });

  group('plural', () {
    test('picks .one for exactly one and .other for everything else', () {
      const locale = MapLibreLocale();
      expect(
        locale.plural('MAP_A11Y_VALUE_ANNOTATIONS', 1),
        '1 marker visible.',
      );
      expect(
        locale.plural('MAP_A11Y_VALUE_ANNOTATIONS', 0),
        '0 markers visible.',
      );
      expect(
        locale.plural('MAP_A11Y_VALUE_ANNOTATIONS', 7),
        '7 markers visible.',
      );
    });

    test('an override applies per variant', () {
      const locale = MapLibreLocale(<String, String>{
        'MAP_A11Y_VALUE_ANNOTATIONS.one': '{count} merkki näkyvissä.',
      });
      expect(
        locale.plural('MAP_A11Y_VALUE_ANNOTATIONS', 1),
        '1 merkki näkyvissä.',
      );
      expect(
        locale.plural('MAP_A11Y_VALUE_ANNOTATIONS', 2),
        '2 markers visible.',
      );
    });
  });

  test('equality is by override content, so it is safe in didUpdateWidget', () {
    expect(
      const MapLibreLocale(<String, String>{'Map.Title': 'Kartta'}),
      const MapLibreLocale(<String, String>{'Map.Title': 'Kartta'}),
    );
    expect(
      const MapLibreLocale(<String, String>{'Map.Title': 'Kartta'}),
      isNot(const MapLibreLocale(<String, String>{'Map.Title': 'Karte'})),
    );
    expect(const MapLibreLocale(), const MapLibreLocale());
  });
}
