import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_cmake/native_toolchain_cmake.dart';

/// Build hook for maplibre_flutter_core.
///
/// Builds the C ABI shim (src/maplibre_flutter_core.cpp) linked against mbgl-core
/// (from the vendored submodule) via CMake, and registers the produced dynamic
/// library under the asset id the ffigen `@Native` bindings resolve
/// (`src/maplibre_flutter_core_bindings_generated.dart`) — CLAUDE.md §5c.
///
/// Distribution (CLAUDE.md §12): app consumers download a prebuilt per-(os,arch)
/// binary; this source build runs for development / CI artifact production, or
/// when `MAPLIBRE_FLUTTER_BUILD_FROM_SOURCE=1`. The prebuilt-download branch is
/// added in the distribution step; until then this always builds from source.
///
/// NOTE: the native_toolchain_cmake 0.2.5 API surface used here is reconciled at
/// the first source build (the package is experimental).
void main(List<String> args) async {
  await build(args, (input, output) async {
    // hooks runs each build in a fresh isolate; allow setting a level on this
    // (non-root) logger.
    hierarchicalLoggingEnabled = true;
    final logger = Logger('maplibre_flutter_core.build')
      ..level = Level.ALL
      // ignore: avoid_print
      ..onRecord.listen((r) => print(r.message));

    // Some hook invocations (notably `flutter run` on desktop) don't request
    // code assets; native_toolchain_cmake unconditionally reads
    // `input.config.code`, which throws when the code-assets extension is
    // absent. There is nothing for us to build in that case.
    if (!input.config.buildCodeAssets) {
      return;
    }

    final packageRoot = input.packageRoot;
    final submodule = Directory.fromUri(
      packageRoot.resolve('third_party/maplibre-native/'),
    );
    final vendored = submodule.existsSync() && submodule.listSync().isNotEmpty;
    if (!vendored) {
      // Build deferred (CLAUDE.md §8 M1 / §12): no vendored source and no
      // prebuilt wired yet. Skip the native build so analyze, ffigen, and the
      // example app stay usable; any FFI call into the core fails at runtime
      // until the build runs. Vendor the source once, pinned to
      // MBGL_CORE_VERSION:
      //   git submodule add https://github.com/maplibre/maplibre-native.git \
      //       packages/maplibre_flutter_core/third_party/maplibre-native
      //   ( cd packages/maplibre_flutter_core/third_party/maplibre-native \
      //     && git checkout "$(cat ../../MBGL_CORE_VERSION)" \
      //     && git submodule update --init --recursive )
      logger.warning(
        'maplibre_flutter_core: mbgl-core not vendored at ${submodule.path}; '
        'skipping native build (deferred — see hook comments, CLAUDE.md §8 M1).',
      );
      return;
    }

    // Build the shim target; it pulls in mbgl-core. The CMakeLists wires
    // CORE_ONLY + the Metal headless platform attach and uses ccache when
    // present, so repeat builds (and CI) are cheap after the first.
    final src = packageRoot.resolve('src/');
    final builder = CMakeBuilder.create(
      name: input.packageName,
      sourceDir: src,
      generator: Generator.ninja,
      targets: ['maplibre_flutter_core'],
    );
    await builder.run(input: input, output: output, logger: logger);

    // Find the built shared library in the build output and register it under
    // the ffigen @Native asset id (must equal the bindings path). The link mode
    // follows the build's link-mode preference.
    await output.findAndAddCodeAssets(
      input,
      names: {
        input.packageName: 'src/${input.packageName}_bindings_generated.dart',
      },
      logger: logger,
    );

    // The hooks runner caches build outputs keyed on the hook + config, not the
    // native sources; declare them so edits to the shim or CMake config trigger
    // a rebuild. (mbgl-core itself is pinned by the submodule revision.)
    output.dependencies.addAll([
      src.resolve('maplibre_flutter_core.cpp'),
      src.resolve('maplibre_flutter_core.h'),
      src.resolve('CMakeLists.txt'),
    ]);
  });
}
