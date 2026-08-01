// Drives the EXAMPLE APP itself on macOS:
//
//   flutter test integration_test/example_app_test.dart -d macos
//
// Every other test here pumps a bare MapLibreMap. This one pumps the real
// MapDemoPage, because the app wires things a bare widget does not — it holds
// its own controller, subscribes to the event streams before attaching, gates
// its whole UI on `onReady`, and rebuilds the scenario from `onStyleLoaded`.
//
// WHY IT EXISTS: `onReady` failing to complete has now bitten three times, and
// every time the symptom was a dead UI rather than a failing test — the scenario
// dropdown greys out, because it is disabled until the map is ready. A bare-map
// test cannot catch that. This can.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_flutter_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app becomes ready and its controls enable', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    // Pump until the app reports ready, bounded so a hang fails rather than
    // spinning. `pumpAndSettle` is wrong here: the map ticks continuously.
    final stopwatch = Stopwatch()..start();
    var enabled = false;
    while (!enabled && stopwatch.elapsed < const Duration(seconds: 40)) {
      await tester.pump(const Duration(milliseconds: 100));
      final dropdown = tester.widget<DropdownButton<Scenario>>(
        find.byType(DropdownButton<Scenario>).first,
      );
      enabled = dropdown.onChanged != null;
    }

    expect(
      enabled,
      isTrue,
      reason:
          'the scenario dropdown is disabled until onReady completes, so a '
          'dropdown that never enables means the app never became usable — '
          'which is exactly how this failed before, silently',
    );
  });

  testWidgets('every scenario can be selected and applied', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    // Wait for ready, as above.
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < const Duration(seconds: 40)) {
      await tester.pump(const Duration(milliseconds: 100));
      final dropdown = tester.widget<DropdownButton<Scenario>>(
        find.byType(DropdownButton<Scenario>).first,
      );
      if (dropdown.onChanged != null) break;
    }

    final dropdown = tester.widget<DropdownButton<Scenario>>(
      find.byType(DropdownButton<Scenario>).first,
    );
    expect(dropdown.onChanged, isNotNull, reason: 'never became ready');
    expect(
      dropdown.items,
      isNotNull,
      reason: 'the dropdown must offer the scenarios',
    );
    expect(
      dropdown.items!.length,
      greaterThanOrEqualTo(10),
      reason: 'every demo is a scenario, not a stray button',
    );

    // Selecting each one must not throw. The scenarios tear down and rebuild
    // engine state, which is where an id typo or a removal order mistake shows
    // up — and since stage 2 those now report on controller.onError rather than
    // failing silently.
    for (final item in dropdown.items!) {
      dropdown.onChanged!(item.value);
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pump(const Duration(milliseconds: 500));
  });
}
