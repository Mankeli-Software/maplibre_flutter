# Building the native engine from source

**Right now this is the only way to use `maplibre_flutter`.** Prebuilt binaries of the
native engine are not published yet, so adding the package from pub.dev alone will not
give you a working map. This page explains why, what to do instead, and what will change.

---

## Why a source build is needed today

Every native platform renders through `mbgl-core`, the MapLibre Native C++ engine. It is
vendored in this repository as a **git submodule** and compiled by the build hook
(`packages/maplibre_flutter_core/hook/build.dart`) using CMake.

That submodule is multiple gigabytes, so it is `.pubignore`d — it is deliberately *not*
part of the published pub.dev archive. The build hook is designed to close that gap by
downloading a prebuilt per-`(os, arch)` binary instead:

```
if (no submodule) {
  try a prebuilt download          ← the intended path for app consumers
  otherwise: warn, skip the native build
} else {
  build from the pinned source     ← what happens in this repo
}
```

**The prebuilt half is not live yet.** The workflow that produces those binaries
(`.github/workflows/build-core.yml`) still has its release-tag trigger commented out, so
no release carries engine artifacts. With no submodule and no prebuilt, the hook logs:

```
maplibre_flutter_core: mbgl-core not vendored at <path> and no prebuilt binary
available; skipping the native build (FFI calls into the core will fail at runtime).
```

The app then builds and launches, but the map fails as soon as it calls into the engine.
Note that a plain `git:` dependency does **not** rescue you either — pub clones without
`--recursive`, so the submodule is still missing.

---

## The setup that works

Clone the repository with submodules, then point your app at it with a path dependency.

**1. Clone with the engine vendored**

```bash
git clone https://github.com/Mankeli-Software/maplibre_flutter.git
cd maplibre_flutter
git submodule update --init --recursive     # pinned to MBGL_CORE_VERSION
```

The submodule checkout is large and slow — that is the engine source, and it is expected.

**2. Depend on it by path**

```yaml
# your_app/pubspec.yaml
dependencies:
  maplibre_flutter:
    path: ../maplibre_flutter/packages/maplibre_flutter
```

You depend only on `maplibre_flutter`; it endorses the per-platform implementations, which
resolve transitively from the same checkout.

**3. Build as usual**

```bash
flutter run -d <android|ios|macos|windows|linux>
```

**Budget several minutes for the first build of each platform** — `mbgl-core` is a large
C++ project compiled from scratch. Later builds are incremental and fast. If you want to
confirm the engine works before wiring it into your own app, run the example first:

```bash
cd packages/maplibre_flutter/example
flutter run -d macos     # or android / ios / windows / linux
```

---

## Toolchain prerequisites

You need the ordinary native toolchain for each platform you build. These are listed in
[CONTRIBUTING.md](../CONTRIBUTING.md#prerequisites); the engine-specific points are:

| Platform | Needs |
| --- | --- |
| **All native** | A C++ toolchain and CMake |
| **Android** | NDK, plus CMake ≥ 3.25 (`sdkmanager 'cmake;3.31.4'` — the SDK's bundled 3.22.1 is too old). `minSdk 26`. |
| **Windows** | Visual Studio 2022 + "Desktop development with C++", and [vcpkg](https://vcpkg.io) at `VCPKG_ROOT` — the build hook runs `vcpkg install` itself. Developer Mode and long paths enabled. |
| **iOS / macOS** | Xcode. The engine builds via CMake, not SPM, even though the plugin glue ships as a Swift package. |
| **Linux** | GTK, clang, CMake. |
| **Web** | Different story — see below. |

The hook also applies a few committed patches to the pinned submodule
(`packages/maplibre_flutter_core/patches/`) before building. This is idempotent and
automatic; you do not need to apply them yourself.

### Web is a separate build

Web does not go through `hook/build.dart` at all — the engine is compiled to WebAssembly
with Emscripten as a standalone step, producing `.js` + `.wasm` artifacts. That toolchain
and its current status are documented in
[experimental-web-core-wasm.md](experimental-web-core-wasm.md).

If you only need web today, the opt-in `maplibre_flutter_web_gljs` package renders with
maplibre-gl-js and requires **no native build at all**.

---

## Forcing a source build

Set `MAPLIBRE_FLUTTER_BUILD_FROM_SOURCE=1` to take the source path even when a prebuilt
would otherwise be downloaded. This is what CI uses when producing artifacts, and it is
useful for testing engine changes against a published version.

```bash
MAPLIBRE_FLUTTER_BUILD_FROM_SOURCE=1 flutter run -d macos
```

It only helps if the source is actually present — it does not fetch the submodule for you.

---

## Troubleshooting

**"mbgl-core not vendored … skipping the native build"** — the submodule is missing. Run
`git submodule update --init --recursive` from the repository root.

**The map is blank but there are no errors** — a blank map is usually the engine running
fine while tiles fail to load. Check network access and the style URL; it is not normally
a build problem.

**Windows: vcpkg or MSVC errors on first build** — confirm `VCPKG_ROOT` is set and that
Developer Mode plus long-path support are enabled. The hook installs the vcpkg
dependencies on first run, which takes a while.

---

## What will change

Once `build-core.yml` is enabled, tagging a `maplibre_flutter_core-v<version>` release
will build the engine for each supported `(os, arch)` and attach the binaries to that
GitHub release. From then on the ordinary flow works with **no submodule, no C++
toolchain, and no multi-minute first build**:

```yaml
dependencies:
  maplibre_flutter: ^0.0.3     # binaries fetched automatically by the build hook
```

Both paths resolve to the same ffigen asset id, so nothing about your Dart code changes —
only where the compiled engine comes from. This page will be updated when that lands.
