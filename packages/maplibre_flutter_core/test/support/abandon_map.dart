// Spawned by test/isolate_shutdown_test.dart into its OWN isolate group, which
// is what a Flutter hot restart throws away: the map below is never disposed,
// so the native side keeps it, its render thread and its callbacks, while the
// Dart code those callbacks point at is gone.
//
// Not a test itself (no `_test.dart` suffix), so `dart test` does not run it.
import 'dart:isolate';

import 'package:maplibre_flutter_core/maplibre_flutter_core.dart';

Future<void> main(List<String> args, SendPort reply) async {
  final map = MapLibreCoreMap.create(
    width: 64,
    height: 64,
    pixelRatio: 1,
    styleUri: 'https://demotiles.maplibre.org/style.json',
  );
  map
    ..setDiagnosticCallback((_) {})
    ..setCameraFinishCallback((_) {});
  // Wait for the render thread to be running, so the map is live when this
  // isolate dies rather than still starting up.
  map.awaitFrame(const Duration(seconds: 20));
  // The address, so the test can destroy the map afterwards: it would otherwise
  // count as a live map for every later test in this process, and the
  // configure-before-the-first-map tests refuse to run with one alive.
  reply.send(map.nativeAddress);
  // Deliberately NOT map.dispose(): a hot restart never runs it. Killed rather
  // than left to finish, because an open NativeCallable keeps its isolate
  // alive — and a hot restart does not ask either.
  Isolate.current.kill(priority: Isolate.immediate);
}
