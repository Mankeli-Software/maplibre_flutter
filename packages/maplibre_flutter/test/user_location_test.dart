// 8.5.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

void main() {
  group('UserLocationPuck', () {
    testWidgets('draws, and sizes the halo by GROUND distance', (tester) async {
      Future<Size> sizeAt(double metresPerPixel) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: UserLocationPuck(
                location: const MapUserLocation(
                  position: LatLng(60.45, 22.27),
                  accuracy: 50,
                ),
                metresPerPixel: metresPerPixel,
              ),
            ),
          ),
        );
        return tester.getSize(find.byType(UserLocationPuck));
      }

      // 50 m of uncertainty is most of the screen at street level and invisible
      // at country level. A fixed pixel radius tells the user nothing, so the
      // widget must actually shrink as the ground resolution coarsens.
      final zoomedIn = await sizeAt(0.5);
      final zoomedOut = await sizeAt(50);
      expect(zoomedIn.width, greaterThan(zoomedOut.width));
    });

    testWidgets('no accuracy means no halo, not a guessed one', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: UserLocationPuck(
              location: MapUserLocation(position: LatLng(60.45, 22.27)),
              metresPerPixel: 1,
            ),
          ),
        ),
      );
      // Falls back to the minimum puck box: inventing a radius would draw
      // confidence the fix does not have.
      expect(tester.getSize(find.byType(UserLocationPuck)), const Size(44, 44));
    });

    testWidgets('it does not eat taps meant for the map', (tester) async {
      var mapTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: GestureDetector(
            // Opaque, like the map's own gesture listener. The DEFAULT
            // (deferToChild) would report no tap at all here — not because the
            // puck swallowed it, but because nothing was hit — which would make
            // this test pass or fail for the wrong reason.
            behavior: HitTestBehavior.opaque,
            onTap: () => mapTapped = true,
            child: const Center(
              child: UserLocationPuck(
                location: MapUserLocation(
                  position: LatLng(60.45, 22.27),
                  accuracy: 500,
                ),
                metresPerPixel: 1,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(UserLocationPuck));
      expect(
        mapTapped,
        isTrue,
        reason:
            'a large accuracy halo covers a lot of map; swallowing taps '
            'under it would make the map feel broken exactly when the fix is '
            'poor',
      );
    });
  });

  group('MapUserLocation', () {
    test('heading and course are separate, deliberately', () {
      const location = MapUserLocation(
        position: LatLng(60.45, 22.27),
        heading: 90,
        course: 270,
      );
      // A passenger holding a phone sideways in a moving car: the device points
      // one way and travel goes another. Collapsing them into one field is the
      // bug this pair exists to prevent, so the types must keep them apart.
      expect(location.heading, isNot(location.course));
    });

    test('value equality, so a rebuild with the same fix is a no-op', () {
      const a = MapUserLocation(position: LatLng(1, 2), accuracy: 5);
      const b = MapUserLocation(position: LatLng(1, 2), accuracy: 5);
      const c = MapUserLocation(position: LatLng(1, 2), accuracy: 6);
      expect(a, b);
      expect(a, isNot(c));
    });
  });
}
