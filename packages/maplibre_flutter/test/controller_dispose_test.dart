import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

/// Regression cover for a hang that cost most of a session and was twice
/// mis-attributed — first to `MapLibreMapController.dispose`, then to
/// `StreamController.close`. **Neither is involved.**
///
/// `await subscription.cancel()` inside `testWidgets` stops the fake-async zone
/// draining microtasks, so every subsequent `await` in that test never
/// completes. Reproduced with zero plugin code; identical code in a plain
/// `test()` finishes instantly, which is exactly what makes it read as a
/// product bug. See CLAUDE.md §11.
void main() {
  // The proof that it is not ours. If this ever starts failing, Flutter has
  // fixed the underlying behaviour and the `unawaited` dance below can go.
  testWidgets('awaiting cancel() strands the zone — not our code', (
    tester,
  ) async {
    final ctrl = StreamController<int>.broadcast();
    final sub = ctrl.stream.listen((_) {});
    var reachedEnd = false;
    unawaited(() async {
      await sub.cancel();
      await Future<void>.value();
      reachedEnd = true;
    }());
    // Give the zone every chance to drain. It will not.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      reachedEnd,
      isFalse,
      reason:
          'Flutter appears to have fixed the fake-async cancel() stall — '
          'delete the unawaited() workarounds and this test.',
    );
  });

  testWidgets('dispose completes when cancel is not awaited', (tester) async {
    final controller = MapLibreMapController();
    final sub = controller.onCameraMoveEnd.listen((_) {});
    // THE WORKAROUND: not awaited. With `await sub.cancel()` here, the dispose
    // below never returns and the test dies on the ten-minute timeout.
    unawaited(sub.cancel());
    await controller.dispose();
  });

  testWidgets('dispose completes with a live subscription', (tester) async {
    final controller = MapLibreMapController();
    controller.onCameraMoveEnd.listen((_) {});
    await controller.dispose();
  });

  testWidgets('dispose is idempotent', (tester) async {
    final controller = MapLibreMapController();
    await controller.dispose();
    await controller.dispose();
  });

  test('outside testWidgets, awaiting cancel is completely fine', () async {
    // The same code in a plain test. This is the contrast that makes the trap
    // so hard to recognise from a failure alone.
    final controller = MapLibreMapController();
    final sub = controller.onCameraMoveEnd.listen((_) {});
    await sub.cancel();
    await controller.dispose();
  });
}
