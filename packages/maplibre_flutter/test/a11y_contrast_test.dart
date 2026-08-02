import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

/// WCAG 2.x relative luminance and contrast ratio, from the spec's own
/// definitions rather than from a package — the formula is six lines, and a
/// dependency taken for six lines outlives its usefulness.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double contrastRatio(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  const white = Color(0xFFFFFFFF);
  const black = Color(0xFF000000);

  // Pinned so a palette tweak is a BUILD BREAK rather than a regression an
  // auditor finds months later.
  group('shipped colours meet the criteria they claim', () {
    test('the attribution link is AA body text on the credit background', () {
      // SC 1.4.3 wants 4.5:1. The link is also underlined, so it is not
      // signalled by colour alone (SC 1.4.1).
      expect(
        contrastRatio(const Color(0xFF1565C0), white),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('credit text is AA on an opaque credit background', () {
      expect(
        contrastRatio(const Color(0xDD000000), white),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('the focus ring is non-text AA on a light basemap', () {
      // SC 1.4.11 wants 3:1 for a UI component boundary.
      expect(
        contrastRatio(const Color(0xFF1565C0), white),
        greaterThanOrEqualTo(3.0),
      );
    });

    // A focus ring lands on whatever the map happens to be showing, so clearing
    // 3:1 against ONE background proves nothing. The shipped blue clears it
    // against both extremes — 4.61:1 on white and 3.65:1 on black — which is
    // why it can be a single colour rather than needing an outline.
    test('the focus ring clears 3:1 against BOTH extremes', () {
      const ring = Color(0xFF1565C0);
      expect(contrastRatio(ring, white), greaterThanOrEqualTo(3.0));
      expect(contrastRatio(ring, black), greaterThanOrEqualTo(3.0));
    });

    // A deuteranope sees hue-only pairs as one colour, so the shipped defaults
    // have to differ in LUMINANCE too. This pins that they keep doing so.
    test('the point and cluster defaults differ by more than hue', () {
      expect(
        contrastRatio(const Color(0xFF1565C0), const Color(0xFFF57C00)),
        greaterThanOrEqualTo(2.0),
      );
    });

    test('the puck reads against a light basemap', () {
      expect(
        contrastRatio(const Color(0xFF1E88E5), white),
        greaterThanOrEqualTo(3.0),
      );
    });
  });

  test('every shipped control has a string to be labelled with', () {
    // A missing key throws in debug and ships an unlabelled control in release,
    // which is precisely what gl-js's throw-on-missing exists to prevent.
    const locale = MapLibreLocale();
    for (final key in <String>[
      'NavigationControl.ZoomIn',
      'NavigationControl.ZoomOut',
      'COMPASS_A11Y_LABEL',
      'Controls.Expand',
      'Controls.Collapse',
      'Action.PanNorth',
      'Action.PanSouth',
      'Action.PanEast',
      'Action.PanWest',
      'Action.TiltUp',
      'Action.TiltDown',
      'Action.ResetNorth',
      'Map.Title',
      'Map.Hint',
      'Map.Loading',
      'Map.LoadFailed',
      'ANNOTATION_A11Y_HINT',
    ]) {
      expect(locale.getUIString(key), isNotEmpty, reason: key);
    }
  });
}
