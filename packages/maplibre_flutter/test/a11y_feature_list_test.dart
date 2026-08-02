import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

const _markers = <MapLibreMarker>[
  MapLibreMarker(
    point: LatLng(60.17, 24.94),
    semanticLabel: 'Helsinki Cathedral',
    semanticValue: 'Landmark',
    child: SizedBox.shrink(),
  ),
  // No label: the list falls back to a spoken coordinate, so a marker is never
  // an unnameable row.
  MapLibreMarker(point: LatLng(-33.87, 151.21), child: SizedBox.shrink()),
];

Future<void> pumpList(
  WidgetTester tester, {
  List<MapLibreMarker> markers = _markers,
  ValueChanged<MapLibreMarker>? onSelected,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MapLibreFeatureList(
        controller: MapLibreMapController(),
        markers: markers,
        onSelected: onSelected,
        flyToOnSelect: false,
        emptyBuilder: (_) => const Text('The map could not be loaded'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every marker is a named, activatable row', (tester) async {
    await pumpList(tester);
    expect(
      find.semantics.byLabel('Helsinki Cathedral').evaluate().single,
      isSemantics(
        label: 'Helsinki Cathedral',
        value: 'Landmark',
        isButton: true,
        hasTapAction: true,
      ),
    );
  });

  // A marker with no label must still be reachable — silence is not an option
  // for the one surface that exists precisely so nothing is unreachable.
  testWidgets('an unlabelled marker falls back to its coordinate', (
    tester,
  ) async {
    await pumpList(tester);
    // Sydney: south and east, asserted absolutely rather than by round trip.
    final rows = find.semantics.byLabel(RegExp('south')).evaluate();
    expect(rows, hasLength(1));
    expect(rows.single.label, contains('east'));
  });

  testWidgets('selecting a row reports it', (tester) async {
    MapLibreMarker? picked;
    await pumpList(tester, onSelected: (m) => picked = m);
    tester.semantics.tap(find.semantics.byLabel('Helsinki Cathedral'));
    await tester.pumpAndSettle();
    expect(picked?.semanticLabel, 'Helsinki Cathedral');
  });

  // The case an empty list would otherwise present as "there is nothing here".
  testWidgets('empty says why rather than showing nothing', (tester) async {
    await pumpList(tester, markers: const <MapLibreMarker>[]);
    expect(find.text('The map could not be loaded'), findsOne);
  });

  testWidgets('rows are conformant targets', (tester) async {
    await pumpList(tester);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  });
}
