import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Directory;
import 'dart:isolate';

import 'package:maplibre_flutter_core/maplibre_flutter_core.dart';
import 'package:maplibre_flutter_core/src/maplibre_flutter_core_bindings_generated.dart'
    as bindings;
import 'package:test/test.dart';

/// What a Flutter hot restart does to the core, reproduced without Flutter.
///
/// A hot restart replaces the root isolate group and runs no `dispose()`, so
/// every map the old isolate created survives natively, still holding the
/// function pointers of `NativeCallable`s whose isolate is gone. mbgl's log
/// observer is process-wide and fans out to every map with a diagnostic
/// callback, so the first log record from ANY map afterwards called into a
/// freed trampoline: SIGSEGV with the pc equal to the faulting address, under
/// `DiagnosticLogObserver::onRecord`. The VEJO app hit it on every hot restart
/// with a style whose glyph server 404s some ranges.
///
/// A crash takes the whole test process down, so this file is its own isolate
/// on purpose, and "the process is still here" is the assertion.
///
/// Needs network access for the demo style, like the main native test.
void main() {
  test(
    'a dead isolate group\'s callbacks are never called (hot restart)',
    () async {
      final messages = ReceivePort();
      final exited = ReceivePort();
      addTearDown(messages.close);
      addTearDown(exited.close);
      final ready = messages.first;
      final gone = exited.first;

      // spawnUri, not spawn: a new isolate GROUP, as a hot restart makes. Its
      // trampolines are freed with the group, which is what made calling them
      // fault rather than merely misbehave.
      await Isolate.spawnUri(
        // Absolute: `dart test` runs from a temp copy, so a relative URI
        // resolves against the wrong directory.
        Directory.current.uri.resolve('test/support/abandon_map.dart'),
        const [],
        messages.sendPort,
        onExit: exited.sendPort,
      );
      final abandoned = await ready.timeout(const Duration(seconds: 30));
      expect(
        abandoned,
        isA<int>().having((a) => a, 'address', isNot(0)),
        reason: 'the abandoned map should have come up first',
      );
      await gone.timeout(const Duration(seconds: 10));
      // Destroyed last, from here — which is also what an app's next start
      // would do with such a map if it could: tear it down while its
      // callbacks still name the dead isolate.
      addTearDown(
        () => bindings.mbl_map_destroy(
          ffi.Pointer<bindings.MblMap>.fromAddress(abandoned as int),
        ),
      );

      // Now make mbgl log, from a map this isolate owns. Every record is fanned
      // out to the abandoned map too; before the fix the first one crashed.
      final map = MapLibreCoreMap.create(
        width: 64,
        height: 64,
        pixelRatio: 1,
        styleUri: 'https://demotiles.maplibre.org/style.json',
      );
      addTearDown(map.dispose);
      final seen = <CoreDiagnostic>[];
      map.setDiagnosticCallback(seen.add);
      expect(map.awaitFrame(const Duration(seconds: 20)), isTrue);
      map
        ..setCamera(latitude: 60.45, longitude: 22.27, zoom: 4)
        ..addSourceJson('g', '''
          {"type":"geojson","data":{"type":"Point","coordinates":[22.27,60.45]}}
        ''')
        // A font the server does not have: mbgl logs the glyph 404.
        ..addLayerJson('''
          {"id":"g-label","type":"symbol","source":"g",
           "layout":{"text-field":"x","text-font":["No Such Font Regular"]}}
        ''');

      final sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 25) &&
          !seen.any((d) => d.kind == CoreDiagnosticKind.log)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        seen.where((d) => d.kind == CoreDiagnosticKind.log),
        isNotEmpty,
        reason:
            'a log record has to have gone through the observer, or this '
            'proved nothing about the fan-out',
      );
      // Still alive after the fan-out reached the abandoned map. Give the
      // engine a moment more to log, since the glyph ranges fail one by one.
      await Future<void>.delayed(const Duration(seconds: 1));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
