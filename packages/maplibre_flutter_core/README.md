# maplibre_flutter_core

Shared desktop core: a thin C ABI shim over MapLibre Native (`mbgl-core`) plus
the committed `ffigen` bindings used by the macOS, Windows, and Linux
implementation packages.

* Native shim: `src/maplibre_flutter_core.{h,c}` (built by `hook/build.dart`).
* Regenerate bindings: `dart run tool/ffigen.dart`.

`mbgl-core` is vendored as a git submodule and built via CMake (CLAUDE.md §4–5).
