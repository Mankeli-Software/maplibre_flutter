import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/src/attribution_bar.dart';
import 'package:maplibre_flutter/src/marker.dart';
import 'package:maplibre_flutter/src/marker_overlay.dart';
import 'package:maplibre_flutter/src/user_location_puck.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Projects a [LatLng] straight to an [Offset], so a fixture can place a marker
/// on or off screen by choosing its coordinates.
class _FakeProjector
    with MapLibreCameraTickNotifier
    implements MapLibreMapProjector {
  // Centred on a 200x200 overlay and spread out enough that a degree or ten of
  // longitude is the difference between on screen and far off it. Real
  // coordinates, because LatLng rightly refuses anything outside ±90.
  Offset Function(LatLng) projectFn = (p) =>
      Offset(100 + p.longitude * 80, 100 + p.latitude * 80);
  bool Function(LatLng)? visibleFn;
  int generation = 1;

  @override
  int project(List<LatLng> points, List<Offset> out, {List<bool>? visible}) {
    for (var i = 0; i < points.length; i++) {
      out[i] = projectFn(points[i]);
      if (visible != null) visible[i] = visibleFn?.call(points[i]) ?? true;
    }
    return generation;
  }

  @override
  LatLng? unproject(Offset point) => LatLng(point.dy, point.dx);
}

Widget _app(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(data: const MediaQueryData(), child: child),
);

/// Pumps twice: the visibility sync is deliberately one frame behind, because
/// which markers were painted is only known during paint.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  group('attribution links', () {
    const attributions = <MapAttribution>[
      MapAttribution(
        html:
            '© <a href="https://openstreetmap.org/copyright">OpenStreetMap</a> contributors',
        text: '© OpenStreetMap contributors',
        links: <AttributionLink>[
          AttributionLink(
            text: 'OpenStreetMap',
            url: 'https://openstreetmap.org/copyright',
          ),
        ],
      ),
    ];

    testWidgets('a link is a link, not just a tappable run of text', (
      tester,
    ) async {
      var tapped = '';
      await tester.pumpWidget(
        _app(
          MapLibreAttributionBar(
            attributions: attributions,
            onLinkTap: (url) => tapped = url,
          ),
        ),
      );

      // One node carrying BOTH the role and the action. Asserting only that a
      // node exists would pass against the pre-fix tree, which already had a
      // tappable node — the defect was the missing role.
      expect(
        find.semantics.byLabel('OpenStreetMap').evaluate().single,
        isSemantics(label: 'OpenStreetMap', isLink: true, hasTapAction: true),
      );

      await tester.tap(find.text('OpenStreetMap'));
      expect(tapped, 'https://openstreetmap.org/copyright');
    });

    testWidgets('two links are two nodes, not one merged credit', (
      tester,
    ) async {
      // The regression that `container: true` fixes. Annotating without a node
      // boundary merges every link up into the paragraph, producing ONE node
      // labelled with the whole credit and carrying a single tap action — so
      // the second link is unreachable and the first announces the wrong URL.
      final tapped = <String>[];
      await tester.pumpWidget(
        _app(
          MapLibreAttributionBar(
            attributions: const <MapAttribution>[
              MapAttribution(
                html: 'x',
                text: '© OpenStreetMap contributors, © CARTO',
                links: <AttributionLink>[
                  AttributionLink(
                    text: 'OpenStreetMap',
                    url: 'https://openstreetmap.org/copyright',
                  ),
                  AttributionLink(
                    text: 'CARTO',
                    url: 'https://carto.com/attributions',
                  ),
                ],
              ),
            ],
            onLinkTap: tapped.add,
          ),
        ),
      );

      expect(
        find.semantics.byLabel('OpenStreetMap').evaluate().single,
        isSemantics(label: 'OpenStreetMap', isLink: true, hasTapAction: true),
      );
      expect(
        find.semantics.byLabel('CARTO').evaluate().single,
        isSemantics(label: 'CARTO', isLink: true, hasTapAction: true),
      );

      // Each node's tap must carry its OWN url, which is the half a
      // node-existence assertion would miss entirely.
      await tester.tap(find.text('CARTO'));
      await tester.tap(find.text('OpenStreetMap'));
      expect(tapped, <String>[
        'https://carto.com/attributions',
        'https://openstreetmap.org/copyright',
      ]);
    });

    testWidgets('with no tap handler the credit stays plain text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(const MapLibreAttributionBar(attributions: attributions)),
      );
      expect(find.semantics.byLabel('OpenStreetMap'), findsNothing);
      // The credit itself is still displayed — that is the licence condition.
      expect(find.textContaining('OpenStreetMap'), findsOneWidget);
    });
  });

  group('user location puck', () {
    testWidgets('announces itself', (tester) async {
      await tester.pumpWidget(
        _app(
          const UserLocationPuck(
            location: MapUserLocation(position: LatLng(60.17, 24.94)),
            metresPerPixel: 1,
          ),
        ),
      );
      expect(find.semantics.byLabel('You Are Here'), findsOne);
    });

    testWidgets('the label is overridable', (tester) async {
      await tester.pumpWidget(
        _app(
          const UserLocationPuck(
            location: MapUserLocation(position: LatLng(60.17, 24.94)),
            metresPerPixel: 1,
            semanticLabel: 'Your position, accurate to 30 metres',
          ),
        ),
      );
      expect(
        find.semantics.byLabel('Your position, accurate to 30 metres'),
        findsOne,
      );
      expect(find.semantics.byLabel('You Are Here'), findsNothing);
    });
  });

  group('the Flow cull must not leak into the semantics tree', () {
    Future<_FakeProjector> pumpOverlay(
      WidgetTester tester, {
      required List<MapLibreMarker> markers,
    }) async {
      final projector = _FakeProjector();
      await tester.pumpWidget(
        _app(
          Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: MarkerOverlay(projector: projector, markers: markers),
            ),
          ),
        ),
      );
      await _settle(tester);
      return projector;
    }

    testWidgets('a marker culled by the viewport publishes no node', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        markers: const <MapLibreMarker>[
          // Projects to the middle of the 200x200 overlay.
          MapLibreMarker(point: LatLng(0, 0), child: Text('inside')),
          // Projects to (900, 900) — the delegate `continue`s past this one.
          MapLibreMarker(point: LatLng(10, 10), child: Text('outside')),
        ],
      );

      expect(find.semantics.byLabel('inside'), findsOne);
      // The regression: before the fix this was a node at the overlay's layout
      // origin, so a screen reader read it out as though it were on screen.
      expect(find.semantics.byLabel('outside'), findsNothing);
    });

    testWidgets('a marker the projector cannot place publishes no node', (
      tester,
    ) async {
      final projector = await pumpOverlay(
        tester,
        markers: const <MapLibreMarker>[
          MapLibreMarker(point: LatLng(0, 0), child: Text('placeable')),
          MapLibreMarker(
            point: LatLng(0.5, 0.5),
            child: Text('behind the horizon'),
          ),
        ],
      );
      projector
        ..visibleFn = ((p) => p.latitude != 0.5)
        ..notifyCameraChanged();
      await _settle(tester);

      expect(find.semantics.byLabel('placeable'), findsOne);
      expect(find.semantics.byLabel('behind the horizon'), findsNothing);
    });

    testWidgets('a marker that comes back on screen comes back to the tree', (
      tester,
    ) async {
      final projector = await pumpOverlay(
        tester,
        markers: const <MapLibreMarker>[
          MapLibreMarker(point: LatLng(10, 10), child: Text('offscreen')),
        ],
      );
      expect(find.semantics.byLabel('offscreen'), findsNothing);

      // Pan so the marker projects inside the overlay again.
      projector
        ..projectFn = ((p) => Offset(p.longitude * 10, p.latitude * 10))
        ..notifyCameraChanged();
      await _settle(tester);

      expect(find.semantics.byLabel('offscreen'), findsOne);
    });

    testWidgets('a marker that stays on screen keeps its node identity', (
      tester,
    ) async {
      // The sync must only fire when the visible SET changes. If it setStates
      // on every tick the node is rebuilt under the assistive technology's
      // feet, which reads as focus jumping mid-sentence — the same guarantee
      // Apple's element-reuse cache buys and loses whenever the host app omits
      // a delegate method.
      final projector = await pumpOverlay(
        tester,
        markers: const <MapLibreMarker>[
          MapLibreMarker(point: LatLng(0, 0), child: Text('steady')),
        ],
      );
      final int before = find.semantics.byLabel('steady').evaluate().single.id;

      for (var i = 0; i < 20; i++) {
        projector.notifyCameraChanged();
        await _settle(tester);
      }

      expect(find.semantics.byLabel('steady').evaluate().single.id, before);
      expect(tester.takeException(), isNull);
    });
  });
}
