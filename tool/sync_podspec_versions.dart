// Rewrites each Apple podspec's `s.version` from its package's pubspec.
//
// `melos version` bumps pubspecs and CHANGELOGs and knows nothing about
// podspecs, so the two drift silently — they already had, by a full patch
// release on maplibre_flutter_macos and maplibre_flutter_ios. Nothing catches
// it until `pod lib lint` during a release, which CLAUDE.md §6 makes a
// precondition for publishing.
//
// Run as a melos `version` post-hook (so a bump can never leave them behind),
// or by hand:
//
//   dart run tool/sync_podspec_versions.dart          # rewrite
//   dart run tool/sync_podspec_versions.dart --check  # CI: fail on drift
//
// Pub versions can carry build metadata (`0.0.2+1`) which CocoaPods rejects, so
// that suffix is stripped — `+1` is a Dart-side republish and not a distinct
// pod version.
import 'dart:io';

void main(List<String> args) {
  final checkOnly = args.contains('--check');
  final packages = Directory('packages');
  if (!packages.existsSync()) {
    stderr.writeln('run this from the repository root');
    exit(2);
  }

  var drifted = 0;
  var updated = 0;

  for (final entry in packages.listSync().whereType<Directory>()) {
    final pubspec = File('${entry.path}/pubspec.yaml');
    if (!pubspec.existsSync()) continue;

    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync())?.group(1);
    if (version == null) continue;
    final podVersion = version.split('+').first;

    // Only this package's OWN podspec, at packages/<pkg>/{ios,macos}/<pkg>.podspec.
    //
    // Deliberately not a recursive walk. The first version of this did walk, and
    // it rewrote the vendored mbgl submodule's SSZipArchive.podspec, Flutter's
    // own ephemeral Flutter.podspec/FlutterMacOS.podspec, and several other
    // plugins' podspecs reached through example/ios/.symlinks — stamping this
    // package's version onto all of them. A version-sync tool that can reach
    // outside its package is a liability, so the paths are enumerated.
    final name = entry.path.split(Platform.pathSeparator).last;
    final candidates = [
      File('${entry.path}/ios/$name.podspec'),
      File('${entry.path}/macos/$name.podspec'),
    ].where((f) => f.existsSync());

    for (final podspec in candidates) {
      final source = podspec.readAsStringSync();
      final match = RegExp(
        r"""(s\.version\s*=\s*)(['"])([^'"]*)\2""",
      ).firstMatch(source);
      if (match == null) continue;
      if (match.group(3) == podVersion) continue;

      drifted++;
      final rel = podspec.path;
      if (checkOnly) {
        stderr.writeln(
          'DRIFT $rel: podspec ${match.group(3)} != pubspec $podVersion',
        );
        continue;
      }
      podspec.writeAsStringSync(
        source.replaceRange(
          match.start,
          match.end,
          '${match.group(1)}${match.group(2)}$podVersion${match.group(2)}',
        ),
      );
      stdout.writeln('synced $rel -> $podVersion');
      updated++;
    }
  }

  if (checkOnly && drifted > 0) {
    stderr.writeln(
      '\n$drifted podspec(s) out of sync. Run: '
      'dart run tool/sync_podspec_versions.dart',
    );
    exit(1);
  }
  stdout.writeln(
    checkOnly ? 'all podspecs match their pubspecs' : 'updated $updated',
  );
}
