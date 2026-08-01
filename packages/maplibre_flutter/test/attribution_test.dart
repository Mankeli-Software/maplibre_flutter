// 8.6. Attribution is a LICENCE CONDITION for most tile providers, not a
// nicety — so the parsing has to survive the fragments providers actually ship,
// and the widget has to be on by default.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

void main() {
  group('MapAttribution.parse', () {
    test('pulls the link out of the fragment OSM actually ships', () {
      final a = MapAttribution.parse(
        '<a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> '
        'contributors',
      );
      expect(a.text, 'OpenStreetMap contributors');
      expect(a.links.single.text, 'OpenStreetMap');
      expect(a.links.single.url, 'https://www.openstreetmap.org/copyright');
    });

    test('handles several links, single quotes and extra attributes', () {
      final a = MapAttribution.parse(
        "<a href='https://a.example' target='_blank'>A</a> and "
        '<a class="x" href="https://b.example">B</a>',
      );
      expect(a.text, 'A and B');
      expect(a.links.map((l) => l.url), [
        'https://a.example',
        'https://b.example',
      ]);
    });

    test('plain text with no markup survives unchanged', () {
      final a = MapAttribution.parse('© Some Provider');
      expect(a.text, '© Some Provider');
      expect(a.links, isEmpty);
    });

    test('malformed markup keeps the words rather than dropping them', () {
      // A credit that renders as nothing is a licence breach, so the parser
      // must degrade to showing too much rather than too little.
      final a = MapAttribution.parse('<a href="x">Provider  unterminated');
      expect(a.text, contains('Provider'));
      expect(a.html, contains('unterminated'));
    });

    test('an anchor with no href still contributes its words', () {
      final a = MapAttribution.parse('<a>Provider</a> data');
      expect(a.text, 'Provider data');
      expect(a.links, isEmpty);
    });
  });

  group('MapLibreAttributionBar', () {
    Future<void> pump(
      WidgetTester tester,
      List<MapAttribution> attributions, {
      ValueChanged<String>? onLinkTap,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            MapLibreAttributionBar(
              attributions: attributions,
              onLinkTap: onLinkTap,
            ),
          ],
        ),
      ),
    );

    testWidgets('renders the credit', (tester) async {
      await pump(tester, [
        MapAttribution.parse(
          '<a href="https://osm.example">OpenStreetMap</a> contributors',
        ),
      ]);
      expect(find.textContaining('OpenStreetMap'), findsOneWidget);
    });

    testWidgets('takes no space when there is nothing to credit', (
      tester,
    ) async {
      await pump(tester, const []);
      // An empty white chip floating over the map would be a bug, not a credit.
      expect(find.byType(DecoratedBox), findsNothing);
    });

    testWidgets('links are plain text until onLinkTap is given', (
      tester,
    ) async {
      final one = MapAttribution.parse('<a href="https://x.example">X</a> y');
      await pump(tester, [one]);
      expect(find.byType(GestureDetector), findsNothing);

      String? tapped;
      await pump(tester, [one], onLinkTap: (url) => tapped = url);
      await tester.tap(find.text('X'));
      expect(tapped, 'https://x.example');
    });

    testWidgets('several sources are separated, not run together', (
      tester,
    ) async {
      await pump(tester, [
        MapAttribution.parse('A'),
        MapAttribution.parse('B'),
      ]);
      expect(find.textContaining('A · B'), findsOneWidget);
    });
  });
}
