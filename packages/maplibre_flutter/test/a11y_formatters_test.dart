import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/src/a11y/formatters.dart';
import 'package:maplibre_flutter/src/a11y/locale.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart'
    show LatLng, MapCamera;

/// These two formatters are where a sign flip goes unnoticed, so every
/// assertion here is against an ABSOLUTE direction from an ASYMMETRIC fixture —
/// never a round trip (CLAUDE.md §11). A round trip survives a mirrored rose
/// and a swapped hemisphere pair; "90 degrees is east" does not.
void main() {
  group('compassDirectionName', () {
    // The four cardinals are the whole ballgame: get one wrong and the rose is
    // rotated or reflected, and both failures render plausible text.
    test('the cardinals are absolute', () {
      expect(compassDirectionName(0), 'north');
      expect(compassDirectionName(90), 'east');
      expect(compassDirectionName(180), 'south');
      expect(compassDirectionName(270), 'west');
    });

    // A reflected rose passes the cardinals (they are symmetric about the
    // north-south axis) and fails here, which is the point of testing them.
    test('the intercardinals distinguish a reflected rose', () {
      expect(compassDirectionName(45), 'northeast');
      expect(compassDirectionName(135), 'southeast');
      expect(compassDirectionName(225), 'southwest');
      expect(compassDirectionName(315), 'northwest');
    });

    test('the 32-point names are the ones Apple speaks', () {
      expect(compassDirectionName(202.5), 'south-southwest');
      expect(compassDirectionName(11.25), 'north by east');
      expect(compassDirectionName(67.5), 'east-northeast');
      expect(compassDirectionName(348.75), 'north by west');
    });

    // Each point owns 11.25°, so the seam sits 5.625° off it. Rounding the
    // wrong way here is a half-point error, which reads as a plausible
    // neighbouring direction rather than as a bug.
    test('bucket boundaries land on the nearer point', () {
      expect(compassDirectionName(5.624), 'north');
      expect(compassDirectionName(5.626), 'north by east');
      expect(compassDirectionName(84.374), 'east by north');
      expect(compassDirectionName(84.376), 'east');
    });

    // mbgl lets a camera bearing accumulate rather than wrapping it, so the
    // formatter has to take 450 and -270 and mean the same thing by them.
    test('an unwrapped bearing still resolves', () {
      expect(compassDirectionName(360), 'north');
      expect(compassDirectionName(450), 'east');
      expect(compassDirectionName(-90), 'west');
      expect(compassDirectionName(-270), 'east');
      expect(compassDirectionName(-0.001), 'north');
    });

    test('the short style is for labels, not for speech', () {
      expect(compassDirectionName(90, style: MapCompassStyle.short), 'E');
      expect(compassDirectionName(45, style: MapCompassStyle.short), 'NE');
      expect(compassDirectionName(270, style: MapCompassStyle.short), 'W');
    });

    test('an override reaches the formatter', () {
      const locale = MapLibreLocale(<String, String>{'COMPASS_E_LONG': 'itä'});
      expect(compassDirectionName(90, locale: locale), 'itä');
      // Untouched keys still resolve from the default table.
      expect(compassDirectionName(270, locale: locale), 'west');
    });
  });

  group('formatCoordinate', () {
    // All four sign combinations, because the hemisphere words are the part a
    // swapped pair would render plausibly. Helsinki is north-east, Sydney
    // south-east, New York north-west, Buenos Aires south-west — no two share
    // a hemisphere pair, so no single flip can pass all four.
    test('every hemisphere combination is absolute', () {
      final helsinki = formatCoordinate(const LatLng(60.17, 24.94));
      expect(helsinki, contains('north'));
      expect(helsinki, contains('east'));
      expect(helsinki, isNot(contains('south')));
      expect(helsinki, isNot(contains('west')));

      final sydney = formatCoordinate(const LatLng(-33.87, 151.21));
      expect(sydney, contains('south'));
      expect(sydney, contains('east'));

      final newYork = formatCoordinate(const LatLng(40.71, -74.01));
      expect(newYork, contains('north'));
      expect(newYork, contains('west'));

      final buenosAires = formatCoordinate(const LatLng(-34.60, -58.38));
      expect(buenosAires, contains('south'));
      expect(buenosAires, contains('west'));
    });

    test('latitude is spoken before longitude', () {
      final s = formatCoordinate(const LatLng(60.17, 24.94));
      expect(s.indexOf('north'), lessThan(s.indexOf('east')));
    });

    test('degrees, minutes and seconds', () {
      expect(
        formatCoordinate(const LatLng(60.17, 24.94)),
        '60°10′12″ north, 24°56′24″ east',
      );
    });

    // Upstream returns the bare magnitude on the equator and the prime
    // meridian, because neither belongs to a hemisphere.
    test('zero picks no hemisphere', () {
      final s = formatCoordinate(const LatLng(0, 0));
      expect(s, isNot(contains('north')));
      expect(s, isNot(contains('south')));
      expect(s, isNot(contains('east')));
      expect(s, isNot(contains('west')));
      expect(s, '0°, 0°');
    });

    // A second of latitude is about 30 m and a z3 tile is a continent, so
    // precision the user cannot act on is noise, not detail.
    test('zoom gates precision', () {
      const point = LatLng(60.17, 24.94);
      expect(formatCoordinate(point, zoom: 3), '60° north, 25° east');
      expect(formatCoordinate(point, zoom: 10), '60°10′ north, 24°56′ east');
      expect(
        formatCoordinate(point, zoom: 21),
        '60°10′12″ north, 24°56′24″ east',
      );
      // Omitting zoom keeps upstream's defaults, which allow both.
      expect(formatCoordinate(point), formatCoordinate(point, zoom: 21));
    });

    test('the gating thresholds are exclusive, as upstream', () {
      const point = LatLng(60.17, 24.94);
      expect(formatCoordinate(point, zoom: 8), isNot(contains('′')));
      expect(formatCoordinate(point, zoom: 8.01), contains('′'));
      expect(formatCoordinate(point, zoom: 20), isNot(contains('″')));
      expect(formatCoordinate(point, zoom: 20.01), contains('″'));
    });

    test('an override reaches the formatter', () {
      const locale = MapLibreLocale(<String, String>{
        'COORD_N_MEDIUM': '{latitude} pohjoista',
      });
      expect(
        formatCoordinate(const LatLng(60.17, 24.94), locale: locale),
        contains('pohjoista'),
      );
    });
  });

  group('describeCamera', () {
    test('names where the map is, how close, and who to credit', () {
      final alt = describeCamera(
        const MapCamera(center: LatLng(60.17, 24.94), zoom: 12.4),
        attribution: '© OpenStreetMap contributors',
      );
      // Absolute hemispheres, not a round trip.
      expect(alt, contains('north'));
      expect(alt, contains('east'));
      expect(alt, contains('Zoom 12.'));
      // Licence condition and SC 1.1.1 discharged by the same string.
      expect(alt, contains('© OpenStreetMap contributors'));
    });

    test('a turned camera says which way it faces', () {
      final alt = describeCamera(
        const MapCamera(center: LatLng(0, 0), zoom: 3, bearing: 90),
      );
      expect(alt, contains('Facing east.'));
    });

    test('a north-up camera does not', () {
      final alt = describeCamera(
        const MapCamera(center: LatLng(0, 0), zoom: 3),
      );
      expect(alt, isNot(contains('Facing')));
    });
  });
}
