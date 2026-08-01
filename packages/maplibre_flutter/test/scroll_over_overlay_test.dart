// The bug: scrolling the wheel over a widget SITTING ON TOP of the map zoomed
// the map anyway.
//
// A pointer signal is offered to every Listener under the cursor, and Flutter
// arbitrates with PointerSignalResolver — first registrant wins, innermost
// first. The map's handler acted directly instead of registering, so it won
// unconditionally; and a plain overlay registers nothing, so even a correct map
// would still have zoomed. Both halves are needed, and both are tested here.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

/// Stands in for the map: a Listener that zooms on scroll, wired the way
/// MapLibreMap's gesture layer is.
class _ScrollTarget extends StatelessWidget {
  const _ScrollTarget({required this.onScroll});

  final VoidCallback onScroll;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent) return;
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        onScroll();
      });
    },
    child: const SizedBox.expand(),
  );
}

Future<void> _scrollAt(
  WidgetTester tester,
  Offset at, {
  double dy = -120,
}) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  pointer.hover(at);
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  testWidgets('a bare overlay does NOT stop the scroll — this is the trap', (
    tester,
  ) async {
    var zooms = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            _ScrollTarget(onScroll: () => zooms++),
            // A TRANSLUCENT overlay — the shape that actually bites. An
            // opaque, coloured box does stop the hit test and so stops the
            // scroll by accident; the ones that do not are exactly the ones
            // nobody expects: a modal barrier, an unpainted panel, anything
            // hit-testing translucently. It takes the pointer and registers no
            // signal handler, so the map underneath still gets the wheel.
            Positioned(
              left: 100,
              top: 100,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) {},
                child: const SizedBox(width: 200, height: 200),
              ),
            ),
          ],
        ),
      ),
    );

    await _scrollAt(tester, const Offset(200, 200));
    expect(
      zooms,
      1,
      reason: 'the map underneath still gets it — the documented trap',
    );
  });

  testWidgets('AbsorbPointerSignal stops it', (tester) async {
    var zooms = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            _ScrollTarget(onScroll: () => zooms++),
            Positioned(
              left: 100,
              top: 100,
              child: AbsorbPointerSignal(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) {},
                  child: const SizedBox(width: 200, height: 200),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    await _scrollAt(tester, const Offset(200, 200));
    expect(zooms, 0, reason: 'the overlay claimed the signal');

    // And OFF the overlay the map still zooms — an absorber that swallowed
    // everything would pass the assertion above while breaking the map.
    await _scrollAt(tester, const Offset(20, 20));
    expect(zooms, 1);
  });

  testWidgets('it absorbs the GAPS in a panel, not just the painted parts', (
    tester,
  ) async {
    var zooms = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            _ScrollTarget(onScroll: () => zooms++),
            Positioned(
              left: 0,
              top: 0,
              child: AbsorbPointerSignal(
                child: SizedBox(
                  width: 300,
                  height: 300,
                  // Two small buttons with a lot of empty space between them:
                  // to the person using it, the gap is still "over the panel".
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(width: 20, height: 20, color: Colors.blue),
                      Container(width: 20, height: 20, color: Colors.blue),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    await _scrollAt(tester, const Offset(150, 150));
    expect(zooms, 0);
  });

  testWidgets('a scrollable INSIDE it still scrolls', (tester) async {
    var zooms = 0;
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            _ScrollTarget(onScroll: () => zooms++),
            Positioned(
              left: 0,
              top: 0,
              child: AbsorbPointerSignal(
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: 100,
                    itemBuilder: (_, i) =>
                        SizedBox(height: 40, child: Text('$i')),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // DOWN, not up: a list already at offset 0 cannot scroll up, and asserting
    // "it moved" against a clamp proves nothing.
    await _scrollAt(tester, const Offset(100, 100), dy: 120);
    // The list sits INSIDE the absorber, so it registers first and wins — an
    // absorber that broke its own children would be useless for a panel.
    expect(scrollController.offset, greaterThan(0));
    expect(zooms, 0);
  });
}
