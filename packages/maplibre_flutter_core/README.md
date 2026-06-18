# maplibre_flutter_core

Shared desktop core: a thin C ABI shim over MapLibre Native (`mbgl-core`) plus
the committed `ffigen` bindings used by the macOS, Windows, and Linux
implementation packages.

* Native shim: `src/maplibre_flutter_core.{h,cpp}` (built by `hook/build.dart`).
* Regenerate bindings: `dart run tool/ffigen.dart`.

`mbgl-core` is vendored as a git submodule and built via CMake (CLAUDE.md §4–5).

## Distribution

`mbgl-core` is large and slow to compile, so the build hook resolves the native
library two ways (CLAUDE.md §12):

* **App consumers** (no submodule, as published on pub.dev) — the hook downloads
  a prebuilt per-`(os, arch)` binary from the GitHub release matching the package
  version (`maplibre_flutter_core-v<version>`), produced by the `build-core` CI
  workflow. No C++ toolchain or multi-minute first build required.
* **Developers / CI** (this repo, submodule vendored) — the hook builds from the
  pinned `MBGL_CORE_VERSION` source via CMake. Set
  `MAPLIBRE_FLUTTER_BUILD_FROM_SOURCE=1` to force this path even without a
  submodule (the CI artifact job does).

Vendor the source once before building from this repo:

```sh
git submodule update --init --recursive
```

`third_party/` is `.pubignore`d, so the published archive stays small; the
prebuilt download fills the gap for consumers.
