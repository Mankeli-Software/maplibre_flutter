# maplibre_flutter_core — web (WASM) build

**Experimental.** Tooling for the opt-in native-core web renderer: compiling MapLibre Native
(`mbgl-core`) to WebAssembly so Flutter web can render through the same engine as the desktop tier
instead of maplibre-gl-js. Off by default; see
[`docs/experimental-web-core-wasm.md`](../../../docs/experimental-web-core-wasm.md) for the full
design, status, and remaining work.

> This is **not** built by `flutter build web` or `hook/build.dart` (those are for desktop native
> assets). It is a standalone Emscripten build whose output (`.js` glue + `.wasm`) is served as a
> web asset and loaded at runtime by the web package's `core_web` controller.

## `probe/` — feasibility probe (works today)

`probe/CMakeLists.txt` is the minimal empirical test: configure + compile `mbgl-core` under
Emscripten with `CORE_ONLY` + the OpenGL (→ WebGL2) backend. It proves the portable engine builds
to WASM (435/435 objects, 0 errors → `libmbgl-core.a`, ~17.5 MB). It does **not** produce a running
map — that needs the platform layer (see the design doc).

### Reproduce

Prerequisites: the [Emscripten SDK](https://emscripten.org/docs/getting_started/downloads.html)
(`emsdk install latest && emsdk activate latest`), a real Python, plus CMake + Ninja (e.g. the ones
bundled with Visual Studio 2022).

```sh
# activate Emscripten in this shell (emsdk_env.ps1 on Windows)
source /path/to/emsdk/emsdk_env.sh

cd packages/maplibre_flutter_core/web
emcmake cmake -G Ninja -S probe -B ../build/wasm-probe
cmake --build ../build/wasm-probe --target mbgl-core
# → ../build/wasm-probe/mbgl/libmbgl-core.a
```

`../build/` is git-ignored — artifacts are not committed.

## Remaining work to a running map

The probe builds the engine; a rendering build additionally needs the platform layer ported to the
browser (a `fetch` HTTP source, an Emscripten run loop, a WebGL2 canvas backend, stubbed storage),
a web C-shim, and an embind JS module matching
`packages/maplibre_flutter_web/lib/src/core_web/core_wasm_interop.dart`. The ordered plan is in the
design doc.
