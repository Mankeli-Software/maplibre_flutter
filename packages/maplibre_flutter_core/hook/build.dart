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

    // Apply our committed patches to the vendored mbgl-native submodule before
    // building (idempotent). Currently a single Windows-only DNS workaround in
    // mbgl's curl http_file_source — see _applySubmodulePatches.
    await _applySubmodulePatches(packageRoot, submodule, logger);

    // Build the shim target; it pulls in mbgl-core. The CMakeLists wires
    // CORE_ONLY + the per-platform headless backend attach and uses ccache when
    // present, so repeat builds (and CI) are cheap after the first.
    final src = packageRoot.resolve('src/');
    final targetOS = input.config.code.targetOS;

    // iOS is the EXPERIMENTAL core-on-mobile path (CLAUDE.md §3): the mobile tier ships
    // the MapLibre Apple SDK by default, and a dart-define selects the mbgl-core path at
    // the Dart layer. mbgl-core is built for BOTH iOS device and Simulator: the CMake arm
    // weak-links Metal on the Simulator (whose stub omits MTLIOErrorDomain/MTLTensorDomain),
    // and Apple-Silicon Simulators have a real host-GPU Metal, so the core renders there
    // too. KNOWN POC LIMITATION: the hook can't see the dart-define, so SDK-only iOS builds
    // also bundle mbgl-core (build time + ~binary size); the production fix is a separate
    // opt-in package (federation endorses one impl per platform). Other platforms
    // (macOS/Linux/Windows) always build.

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
      src.resolve('maplibre_flutter_core_sim_stubs.mm'),
      src.resolve('maplibre_flutter_core_gl.h'),
      src.resolve('maplibre_flutter_core_gl.cpp'),
      src.resolve('maplibre_flutter_core_vk.h'),
      src.resolve('maplibre_flutter_core_vk.cpp'),
      src.resolve('CMakeLists.txt'),
    ]);
  });
}

/// Applies our committed patches to the vendored mbgl-native submodule.
///
/// Idempotent: each patch is skipped when its marker string is already present
/// (so re-builds and a dev's already-patched tree are no-ops). Fails loudly if a
/// patch is missing or cannot be applied, so a source build never silently
/// produces a core without the fix.
///
/// `windows-dns-os-resolve.patch`: curl's asynchronous DNS resolvers do not work
/// under our libuv-driven curl multi-socket loop on Windows (the threaded
/// resolver never delivers completion; c-ares can't discover the system
/// nameservers), so tile/style requests never resolve and the map stays blank.
/// The patch resolves through the OS resolver and pre-seeds curl's address cache
/// via CURLOPT_RESOLVE (Windows-only `#ifdef`, a no-op on other platforms).
Future<void> _applySubmodulePatches(
  Uri packageRoot,
  Directory submodule,
  Logger logger,
) async {
  const patches = [
    (
      file: 'platform/default/src/mbgl/storage/http_file_source.cpp',
      marker: 'resolveHostViaOS',
      patch: 'patches/windows-dns-os-resolve.patch',
    ),
    // Windows Vulkan zero-copy: enable the D3D11<->Vulkan external-memory extensions
    // (and the instance Properties2 extension for the device-LUID query) so the
    // Vulkan->D3D11 shared-texture present can import mbgl's rendered image. The added
    // device extensions are enabled-if-available (never required for device selection),
    // and the code is #ifdef _WIN32-guarded + only compiled under the Vulkan backend, so
    // this is inert on the macOS (Metal) and Linux (GL) tiers.
    (
      file: 'src/mbgl/vulkan/renderer_backend.cpp',
      marker: 'MBL_WIN32_EXTERNAL_MEMORY',
      patch: 'patches/windows-vulkan-external-memory.patch',
    ),
  ];
  for (final p in patches) {
    final target = File.fromUri(submodule.uri.resolve(p.file));
    if (target.existsSync() && target.readAsStringSync().contains(p.marker)) {
      continue; // already applied
    }
    final patchFile = File.fromUri(packageRoot.resolve(p.patch));
    if (!patchFile.existsSync()) {
      throw Exception(
        'maplibre_flutter_core: missing patch ${patchFile.path}.',
      );
    }
    final result = await Process.run('git', [
      'apply',
      '--ignore-whitespace',
      patchFile.path,
    ], workingDirectory: submodule.path);
    if (result.exitCode != 0 || !target.readAsStringSync().contains(p.marker)) {
      logger.severe(result.stdout.toString());
      logger.severe(result.stderr.toString());
      throw Exception(
        'maplibre_flutter_core: failed to apply ${p.patch} to the mbgl-native '
        'submodule (exit ${result.exitCode}).',
      );
    }
    logger.info('maplibre_flutter_core: applied ${p.patch}.');
  }
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

  // The Windows core renders with mbgl's *Vulkan* backend, whose headers + loader +
  // glslang/SPIRV/VMA are all vendored in the mbgl submodule (vendor/Vulkan-Headers,
  // vendor/VulkanMemoryAllocator, vendor/glslang) and the vulkan-1.dll loader ships
  // with every Windows GPU driver — so there is NO vcpkg port for Vulkan. The former
  // ANGLE/GL ports (`egl`, `opengl-registry`) are therefore dropped. The rest mirror
  // mbgl's Get-VendorPackages.ps1. ICU is the vendored builtin (vendor/icu.cmake), so
  // it is intentionally not installed here.
  //
  // curl is built with the c-ares feature: its default threaded DNS resolver hangs
  // under our libuv-driven curl multi-socket loop on Windows. (The OS-resolver patch
  // in _applySubmodulePatches is the primary fix; c-ares is the fallback resolver — it
  // fails a request fast instead of hanging the slot if getaddrinfo ever fails.)
  // c-ares's + libuv's configs gate the (slow) install (ANGLE's config is gone now).
  final caresConfig = File.fromUri(
    vcpkgRoot.resolve('installed/$triplet/share/c-ares/c-ares-config.cmake'),
  );
  final libuvConfig = File.fromUri(
    vcpkgRoot.resolve('installed/$triplet/share/libuv/libuvConfig.cmake'),
  );
  if (!caresConfig.existsSync() || !libuvConfig.existsSync()) {
    const ports = [
      // ssl -> schannel on Windows (uses the Windows cert store); c-ares -> a
      // socket-based async resolver that integrates with our event loop.
      'curl[core,non-http,ssl,c-ares]',
      'dlfcn-win32',
      'libuv',
      'libjpeg-turbo',
      'libpng',
      'libwebp',
    ];
    logger.info(
      'maplibre_flutter_core: installing vcpkg deps ($triplet) — the first build '
      'can take several minutes: ${ports.join(' ')}',
    );
    final result = await Process.run(vcpkgExe.path, [
      'install',
      ...ports,
      '--triplet',
      triplet,
      '--overlay-triplets=${overlayTriplets.toFilePath()}',
      // --recurse: allow rebuilding curl when its feature set changes (e.g. an
      // existing install predating the c-ares feature).
      '--recurse',
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
