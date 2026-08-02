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

    // mbgl-core is the default renderer on every platform (CLAUDE.md §3), so every
    // arm builds it; the native SDKs live in separate opt-in packages, which is what
    // build-time-excludes them. The old dart-define escape hatch, and the "SDK-only
    // iOS builds still bundle mbgl-core" limitation it caused, are both gone —
    // federation endorses one implementation per platform.
    //
    // iOS builds for BOTH device and Simulator: the CMake arm weak-links Metal on the
    // Simulator (whose stub omits MTLIOErrorDomain/MTLTensorDomain), and Apple-Silicon
    // Simulators have a real host-GPU Metal, so the core renders there too — which
    // makes the Simulator a genuine verification target for this tier, not just a
    // compile check.

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
    //
    // Anything omitted here is silently stale: the build reports success and
    // reuses the previous dylib, so the edit appears not to work. The model /
    // glTF sources and the patches were both missing for exactly that reason —
    // and a patch is doubly deceptive, because even a forced rebuild skips one
    // whose marker is already in the tree, so a patch edit also needs
    // `git -C third_party/maplibre-native checkout -- .` to take effect.
    output.dependencies.addAll([
      src.resolve('maplibre_flutter_core.cpp'),
      src.resolve('maplibre_flutter_core.h'),
      // Compiled into EVERY arm by src/CMakeLists.txt (_shim_sources), not just
      // the Metal one — the 3D model layer and its .glb reader are
      // backend-agnostic.
      src.resolve('maplibre_flutter_core_model.cpp'),
      src.resolve('maplibre_flutter_core_model.hpp'),
      src.resolve('maplibre_flutter_core_gltf.cpp'),
      src.resolve('maplibre_flutter_core_gltf.hpp'),
      src.resolve('maplibre_flutter_core_metal.h'),
      src.resolve('maplibre_flutter_core_metal.mm'),
      src.resolve('maplibre_flutter_core_sim_stubs.mm'),
      src.resolve('maplibre_flutter_core_gl.h'),
      src.resolve('maplibre_flutter_core_gl.cpp'),
      src.resolve('maplibre_flutter_core_vk.h'),
      src.resolve('maplibre_flutter_core_vk.cpp'),
      src.resolve('maplibre_flutter_core_android.h'),
      src.resolve('maplibre_flutter_core_android_http.cpp'),
      src.resolve('maplibre_flutter_core_android_image_stubs.cpp'),
      src.resolve('maplibre_flutter_core_android_present.h'),
      src.resolve('maplibre_flutter_core_android_present.cpp'),
      src.resolve('CMakeLists.txt'),
      // Derived from the same list the applier walks, so a new patch cannot be
      // added without becoming a build input.
      for (final p in _submodulePatches) packageRoot.resolve(p.patch),
    ]);
  });
}

/// The patches applied to the vendored mbgl-native submodule, in the order they
/// must be applied — order is load-bearing, see the sampler-repeat entry.
///
/// Top-level so `output.dependencies` can be derived from it: a patch that is
/// not a declared build input can be edited without triggering a rebuild, and
/// the change then silently never reaches the dylib.
///
/// `windows-dns-os-resolve.patch`: curl's asynchronous DNS resolvers do not work
/// under our libuv-driven curl multi-socket loop on Windows (the threaded
/// resolver never delivers completion; c-ares can't discover the system
/// nameservers), so tile/style requests never resolve and the map stays blank.
/// The patch resolves through the OS resolver and pre-seeds curl's address cache
/// via CURLOPT_RESOLVE (Windows-only `#ifdef`, a no-op on other platforms).
const _submodulePatches = [
  (
    file: 'platform/default/src/mbgl/storage/http_file_source.cpp',
    marker: 'resolveHostViaOS',
    patch: 'patches/windows-dns-os-resolve.patch',
  ),
  // Centre-anchored text is centred on its actual ink, not on Shaping::yOffset.
  //
  // mbgl positions text vertically from a hardcoded constant — `Shaping::yOffset
  // = -17` (of ONE_EM = 24), whose own declaration says "The y offset *should*
  // be part of the font metadata". It stands in for the font's baseline metrics,
  // so any font whose real metrics differ renders centre-anchored text
  // off-centre. maplibre-gl-js carries the identical constant
  // (SHAPING_DEFAULT_OFFSET in src/symbol/shaping.ts), so this is upstream
  // behaviour, not a native-tier divergence.
  //
  // It is most visible on line-placed labels, which should straddle the line but
  // sit above it. Measured with Liberation Sans NLSFI at text-size 15: the ink
  // spanned -9.80..+1.74 px across the line (4.0 px high) at every one of 24
  // orientations; with this patch it spans -5.75..+5.73 px, centred to within
  // 0.25 px. See carta-polaris/flutter-poc/lib/dev/line_anchor_probe.dart.
  //
  // The glyphs already carry what is needed: the quad builder places each at
  // `y - metrics.top * scale` spanning `metrics.height * scale`, so align() can
  // measure the shaped ink and centre that instead. Only centre anchors are
  // touched — top/bottom anchors mean "align this edge" and were already right.
  (
    file: 'src/mbgl/text/shaping.cpp',
    marker: 'MBL_TEXT_CENTRE_ON_INK',
    patch: 'patches/text-centre-anchor-on-ink.patch',
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
  // Metal: make 3D custom-drawable geometry actually depth-test. mtl::Drawable
  // deliberately skips setting its own depth/stencil state when is3D ("handled
  // by the layer group", drawable.cpp:244) — but mtl::TileLayerGroup only
  // computed features3d INSIDE `if (stencilTiles && !empty())`. A layer group
  // with no stencil tiles (which is every CustomDrawableLayer) therefore left
  // features3d false and set no depth state at all, so 3D geometry fell back to
  // painter's order: models did not occlude behind fill-extrusion buildings and
  // did not even self-occlude (a mesh's back faces painted over its front ones).
  // The patch hoists the scan out of that guard; stencil3d stays gated on
  // stencil tiles, so tiled layers are unaffected. Metal-only: the GL
  // (drawable_gl.cpp:46) and Vulkan (drawable.cpp:274) drawables already honour
  // is3D themselves, so Linux/Android/Windows never had this bug.
  (
    file: 'src/mbgl/mtl/tile_layer_group.cpp',
    marker: 'MBL_CUSTOM_3D_DEPTH',
    patch: 'patches/metal-custom-drawable-3d-depth.patch',
  ),
  // Directional lighting for custom geometry, across all four backends.
  //
  // mbgl's CustomGeometryShader is texture x tint with no normals, so 3D models
  // render completely flat — the single biggest thing between a model and
  // looking placed in the scene. This adds a NORMAL vertex attribute and a light
  // vec4 to the drawable UBO, plus a half-lambert term in the shader.
  //
  // The light is in the drawable's own MODEL space rather than world space, so
  // no normal matrix is needed and callers rotate the world light by the model's
  // yaw — which is what keeps a turning model consistently lit. Alpha is left
  // untouched so blended parts stay blended.
  //
  // Touches shader_defines, the shared UBO, all four backend shaders and their
  // attribute tables, plus Interface::GeometryVertex and the attribute wiring.
  // VERIFIED ON METAL ONLY; the GL, Vulkan and WebGPU edits are mechanical
  // mirrors and unverified on hardware.
  (
    file: 'include/mbgl/shaders/custom_geometry_ubo.hpp',
    marker: 'MBL_CUSTOM_GEOMETRY_LIGHTING',
    patch: 'patches/custom-geometry-lighting.patch',
  ),
  // Metal: let custom-geometry textures honour REPEAT wrapping. The Metal
  // CustomGeometryShader declares `constexpr sampler` INSIDE the shader, and a
  // Metal constexpr sampler defaults to address::clamp_to_edge, so it ignores
  // the wrap state mbgl sets on the Texture2D. The GL and Vulkan variants
  // sample through a sampler2D whose wrap mbgl does control, so only Metal was
  // affected. glTF defaults to REPEAT and real models tile (the Khronos
  // BoxTextured sample spans u=[0,6], one unit per face), so clamping collapsed
  // them to a single edge colour that reads as "the texture never bound".
  // Switching to address::repeat is safe: UVs inside [0,1] never sample outside
  // the texture, so clamp and repeat are indistinguishable for them.
  //
  // MUST COME AFTER the lighting patch, and is then normally a no-op: the
  // lighting patch was generated from a working tree that already had this
  // applied, so it carries this change (and this marker) with it. In the other
  // order neither patch applies to a fresh tree and a source build fails —
  // which it did, invisibly, on any machine whose submodule had been patched
  // incrementally in the historical order. Kept as its own entry so the
  // rationale above stays with the change, and so it still applies if the
  // lighting patch is ever regenerated without it.
  (
    file: 'include/mbgl/shaders/mtl/custom_geometry.hpp',
    marker: 'MBL_CUSTOM_GEOMETRY_REPEAT',
    patch: 'patches/metal-custom-geometry-sampler-repeat.patch',
  ),
  // Metal: attach the stencil buffer on the iOS Simulator, so tile clipping
  // masks actually clip there.
  //
  // mtl::HeadlessBackend asks for an offscreen texture with depth AND stencil,
  // but mtl::OffscreenTextureResource creates the stencil texture inside
  // `#if !TARGET_OS_SIMULATOR` — because Metal requires a pipeline's depth and
  // stencil attachment formats to match, which is exactly why the DEPTH texture
  // is allocated as the combined PixelFormatDepth32Float_Stencil8 on the
  // Simulator (Texture2D::getMetalPixelFormat). Upstream then never attaches
  // those stencil bits, so the render pass has a nil stencilAttachment texture,
  // Context::makeDepthStencilState's `if (stencilTarget->texture())` is false,
  // and NO stencil descriptor is ever applied — every stencil test passes.
  //
  // renderTileClippingMasks therefore stops clipping: each tile draws its full
  // BUFFERED geometry over its neighbours. Same-colour fills hide it, but any
  // geometry along the tile-clip edge (a fill-outline-color, a polygon
  // boundary) gets drawn on both sides of every boundary — a pair of grey seam
  // lines straddling each tile edge, ~2x the tile buffer apart. This is the
  // real cause of the "faint sim-only tile seams" the 2026-06-19 entry in
  // docs/decision-log.md wrote off as a simulator Metal-translation quirk.
  //
  // Simulator-only by construction: everywhere else `stencilTexture` exists, so
  // the new branch is dead. VERIFIED by forcing both simulator `#if`s on macOS:
  // without this, a Liberty frame differs from the correct one on 2.05% of
  // pixels, concentrated in one 16px band per tile boundary; with it, the frame
  // is pixel-identical to the correct one (0 differing pixels).
  //
  // Upstream-PR candidate, alongside the text-centring patch.
  (
    file: 'src/mbgl/mtl/offscreen_texture.cpp',
    marker: 'MBL_SIM_STENCIL_ATTACHMENT',
    patch: 'patches/metal-simulator-stencil-attachment.patch',
  ),
  // Offline downloads abort the process under the DEFAULT tile server options.
  //
  // mbgl builds a std::regex out of a TileServerOptions URL template without
  // escaping the template's literal text, and in the ECMAScript grammar an
  // unescaped `{` opens a quantifier. Two of the three built-in configurations
  // carry a brace that is not one of the five tokens createTokenMap knows —
  // MapLibre's glyphs template is "/font/{fontstack}/{start}-{end}.pbf" and its
  // sprites template is "/{path}/sprite{scale}.{format}" — so constructing the
  // regex throws std::regex_error(error_badbrace).
  //
  // Nothing catches it: canonicalize{Source,Glyph,Sprite}URL are called only
  // from OfflineDownload::activateDownload, on mbgl's file-source thread.
  // `mbl_offline_set_download_state(id, Active)` against demotiles therefore
  // killed the host process, which is what stopped offline support shipping the
  // first time (see docs/offline-design.md).
  //
  // Escaping alone would have turned the abort into a silent wrong answer: the
  // gate (isNormalizedSourceURL) recognised any `{...}` while the extractor
  // (createTokenMap) recognises five names, so a template with an unrecognised
  // token passed the gate and came back with an empty map — rebuilding every
  // glyph range in the style as "maplibre://fonts". Both now compile the
  // template the same way, so the gate accepts exactly what the extractor can
  // read.
  //
  // Upstream-PR candidate, and the only one of the three we carry that ships
  // with a committed reproduction: `offline_url_probe` (ctest label `hermetic`)
  // asserts the crashing cases AND the MapTiler expectations from mbgl's own
  // test/util/mapbox.test.cpp that the patch must not change.
  (
    file: 'src/mbgl/util/mapbox.cpp',
    marker: 'MBL_URL_TEMPLATE_ESCAPE',
    patch: 'patches/offline-url-template-regex.patch',
  ),
  // Two more ways the offline download path kills the process, both found while
  // fixing the one above and both the same shape: an unchecked value on mbgl's
  // database thread, where an app has nothing to catch.
  //
  //   * `parser.parse(*styleResponse.data)` dereferences a null `shared_ptr`
  //     when the style request answers with no content — an HTTP 204, or a
  //     stored resource whose blob is NULL. `Response::data` is documented as
  //     present only for non-error, non-notModified responses, and every OTHER
  //     consumer in mbgl checks `noContent` first (style_impl, tile_source,
  //     sprite_loader, geojson_source); offline_download is the one that does
  //     not, in both `activateDownload` and `getStatus`.
  //   * `queueTiles` reads `tileset.tiles[0]` with `operator[]`, and a TileJSON
  //     carrying `"tiles": []` converts successfully — conversion/tileset.cpp
  //     only rejects a missing or non-array member. The render path uses `at()`
  //     for the same read (tile_loader_impl.hpp); this is the one place that
  //     reads past the end.
  //
  // Both are upstream-PR candidates alongside the URL-template patch, and both
  // are one-line guards that return early: a region that cannot be enumerated
  // stops, which is what `requiredResourceCountIsPrecise` staying false already
  // means to a caller.
  (
    file: 'platform/default/src/mbgl/storage/offline_download.cpp',
    marker: 'MBL_OFFLINE_NULL_GUARDS',
    patch: 'patches/offline-download-null-guards.patch',
  ),
];

/// Applies [_submodulePatches] to the vendored mbgl-native submodule.
///
/// Idempotent: each patch is skipped when its marker string is already present
/// (so re-builds and a dev's already-patched tree are no-ops). Fails loudly if a
/// patch is missing or cannot be applied, so a source build never silently
/// produces a core without the fix.
///
/// The marker skip has a consequence worth knowing before editing any patch:
/// against an already-patched tree the edit is skipped, so the old change stays.
/// Reset the submodule (`git -C third_party/maplibre-native checkout -- .`)
/// before rebuilding, or the fix appears not to work.
Future<void> _applySubmodulePatches(
  Uri packageRoot,
  Directory submodule,
  Logger logger,
) async {
  for (final p in _submodulePatches) {
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
    // (os, arch) alone does NOT identify an iOS binary. Device and Simulator are
    // both ios+arm64 yet are genuinely different builds: src/CMakeLists.txt
    // compiles maplibre_flutter_core_sim_stubs.mm into the Simulator only,
    // because the Simulator's Metal stub omits MTLIOErrorDomain and
    // MTLTensorDomain. Downloading one for the other links against symbols that
    // are not there — and it would fail at RUN time, on whichever of the two a
    // consumer happened not to build first.
    final sdkSuffix = os == OS.iOS
        ? '-${input.config.code.iOS.targetSdk == IOSSdk.iPhoneSimulator ? 'simulator' : 'device'}'
        : '';
    final asset = '${os.name}-${arch.name}$sdkSuffix-$libName';
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
