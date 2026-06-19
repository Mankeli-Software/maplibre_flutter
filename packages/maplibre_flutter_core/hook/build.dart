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
    final buildFromSource =
        Platform.environment['MAPLIBRE_FLUTTER_BUILD_FROM_SOURCE'] == '1';

    // Distribution (CLAUDE.md §12). Developers and CI build from the vendored
    // mbgl-core submodule (no network); app consumers (no submodule) download a
    // prebuilt per-(os,arch) binary published by the `build-core` CI workflow.
    // MAPLIBRE_FLUTTER_BUILD_FROM_SOURCE=1 keeps the source path even without a
    // submodule (and is set by the artifact-producing CI).
    if (!vendored) {
      if (!buildFromSource && await _tryPrebuilt(input, output, logger)) {
        return;
      }
      logger.warning(
        'maplibre_flutter_core: mbgl-core not vendored at ${submodule.path} and '
        'no prebuilt binary available; skipping the native build (FFI calls into '
        'the core will fail at runtime). Vendor the source once, pinned to '
        'MBGL_CORE_VERSION:\n'
        '  git submodule update --init --recursive',
      );
      return;
    }

    // Build the shim target; it pulls in mbgl-core. The CMakeLists wires
    // CORE_ONLY + the per-platform headless backend attach and uses ccache when
    // present, so repeat builds (and CI) are cheap after the first.
    final src = packageRoot.resolve('src/');
    final targetOS = input.config.code.targetOS;

    // Windows: mbgl-core's deps (ANGLE for EGL/GLES, curl, libpng/jpeg/webp, libuv,
    // dlfcn-win32) come from vcpkg. Provision them and hand CMake the vcpkg toolchain
    // file (CLAUDE.md §9). macOS uses system frameworks and Linux uses pkg-config /
    // system packages, so this provisioning is Windows-only.
    final defines = <String, String?>{};
    if (targetOS == OS.windows) {
      await _provisionWindowsVcpkg(input, src, logger, defines);
    }

    final builder = CMakeBuilder.create(
      name: input.packageName,
      sourceDir: src,
      generator: Generator.ninja,
      targets: ['maplibre_flutter_core'],
      defines: defines,
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
      src.resolve('maplibre_flutter_core_metal.h'),
      src.resolve('maplibre_flutter_core_metal.mm'),
      src.resolve('maplibre_flutter_core_gl.h'),
      src.resolve('maplibre_flutter_core_gl.cpp'),
      src.resolve('CMakeLists.txt'),
    ]);
  });
}

/// Maps a Dart [Architecture] to the vcpkg Windows triplet name (matches the
/// custom overlay triplets under src/vcpkg-triplets/).
String _windowsTriplet(Architecture arch) => switch (arch) {
  Architecture.x64 => 'x64-windows',
  Architecture.arm64 => 'arm64-windows',
  _ => throw UnsupportedError(
    'maplibre_flutter_core: unsupported Windows architecture: $arch',
  ),
};

/// Resolves the vcpkg root: `$VCPKG_ROOT` if set, else `C:\vcpkg`.
Uri _vcpkgRoot() {
  final env = Platform.environment['VCPKG_ROOT'];
  if (env != null && env.trim().isNotEmpty) {
    return Directory(env.trim()).uri;
  }
  return Directory(r'C:\vcpkg').uri;
}

/// Ensures mbgl-core's native dependencies are installed via vcpkg (classic mode)
/// and populates [defines] with the vcpkg toolchain file + triplet so the CMake
/// configure resolves them. Idempotent: the (slow) install is skipped once ANGLE's
/// vcpkg config is present. The ANGLE runtime DLLs are bundled beside the app by
/// maplibre_flutter_windows's windows/CMakeLists.txt (bundled_libraries).
Future<void> _provisionWindowsVcpkg(
  BuildInput input,
  Uri src,
  Logger logger,
  Map<String, String?> defines,
) async {
  final vcpkgRoot = _vcpkgRoot();
  final vcpkgExe = File.fromUri(vcpkgRoot.resolve('vcpkg.exe'));
  if (!vcpkgExe.existsSync()) {
    throw Exception(
      'maplibre_flutter_core: vcpkg not found at ${vcpkgExe.path}. Install it and '
      'set VCPKG_ROOT (git clone https://github.com/microsoft/vcpkg C:\\vcpkg && '
      'C:\\vcpkg\\bootstrap-vcpkg.bat).',
    );
  }
  final triplet = _windowsTriplet(input.config.code.targetArchitecture);
  final overlayTriplets = src.resolve('vcpkg-triplets/');
  final toolchain = vcpkgRoot.resolve('scripts/buildsystems/vcpkg.cmake');

  // `egl` pulls in `angle` (the EGL/GLES implementation, which provides the
  // unofficial-angle CMake config our CMakeLists find_package()s); the rest mirror
  // mbgl's Get-VendorPackages.ps1. ICU is the vendored builtin (vendor/icu.cmake),
  // so it is intentionally not installed here.
  final angleConfig = File.fromUri(
    vcpkgRoot.resolve(
      'installed/$triplet/share/unofficial-angle/unofficial-angle-config.cmake',
    ),
  );
  if (!angleConfig.existsSync()) {
    const ports = [
      'curl',
      'dlfcn-win32',
      'libuv',
      'libjpeg-turbo',
      'libpng',
      'libwebp',
      'egl',
      'opengl-registry',
    ];
    logger.info(
      'maplibre_flutter_core: installing vcpkg deps ($triplet) — the first build '
      'compiles ANGLE and can take many minutes: ${ports.join(' ')}',
    );
    final result = await Process.run(vcpkgExe.path, [
      'install',
      ...ports,
      '--triplet',
      triplet,
      '--overlay-triplets=${overlayTriplets.toFilePath()}',
      '--clean-after-build',
      '--disable-metrics',
    ], workingDirectory: vcpkgRoot.toFilePath());
    if (result.exitCode != 0) {
      logger.severe(result.stdout.toString());
      logger.severe(result.stderr.toString());
      throw Exception(
        'maplibre_flutter_core: vcpkg install failed (exit ${result.exitCode}).',
      );
    }
  } else {
    logger.info(
      'maplibre_flutter_core: vcpkg deps already present ($triplet); skipping install.',
    );
  }

  defines['CMAKE_TOOLCHAIN_FILE'] = toolchain.toFilePath();
  defines['VCPKG_TARGET_TRIPLET'] = triplet;
  defines['VCPKG_MANIFEST_MODE'] = 'OFF';
  // (VCPKG_OVERLAY_TRIPLETS is only needed at `vcpkg install` time, above — the
  // classic-mode toolchain reads the already-installed tree at configure, so passing
  // it to CMake just warns "manually-specified variable not used".)
}

/// GitHub release that hosts the prebuilt core binaries, keyed by package
/// version (published by the `build-core` CI workflow).
const _releaseBaseUrl =
    'https://github.com/Mankeli-Software/maplibre_flutter/releases/download';

/// Tries to download + register a prebuilt core binary for the target os/arch.
/// Returns true if a prebuilt was used; false (or on any error) to fall back to
/// a source build. Integrity rests on HTTPS to the trusted release host.
Future<bool> _tryPrebuilt(
  BuildInput input,
  BuildOutputBuilder output,
  Logger logger,
) async {
  try {
    final version = _packageVersion(input.packageRoot);
    if (version == null) return false;
    final os = input.config.code.targetOS;
    final arch = input.config.code.targetArchitecture;
    final libName = os.dylibFileName(input.packageName);
    final asset = '${os.name}-${arch.name}-$libName';
    final url = Uri.parse(
      '$_releaseBaseUrl/maplibre_flutter_core-v$version/$asset',
    );
    final dest = File.fromUri(input.outputDirectory.resolve(libName));
    if (!await _download(url, dest)) return false;

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/${input.packageName}_bindings_generated.dart',
        linkMode: DynamicLoadingBundled(),
        file: dest.uri,
      ),
    );
    logger.info('maplibre_flutter_core: using prebuilt binary $url');
    return true;
  } catch (e) {
    logger.info(
      'maplibre_flutter_core: no prebuilt ($e); building from source.',
    );
    return false;
  }
}

/// GETs [url] into [dest] (following redirects). Returns false on a non-200.
Future<bool> _download(Uri url, File dest) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      return false;
    }
    await dest.parent.create(recursive: true);
    await response.pipe(dest.openWrite());
    return true;
  } finally {
    client.close(force: true);
  }
}

/// Reads `version:` from the package's pubspec.yaml.
String? _packageVersion(Uri packageRoot) {
  final pubspec = File.fromUri(packageRoot.resolve('pubspec.yaml'));
  if (!pubspec.existsSync()) return null;
  for (final line in pubspec.readAsLinesSync()) {
    final m = RegExp(r'^version:\s*(\S+)').firstMatch(line);
    if (m != null) return m.group(1);
  }
  return null;
}
