# Experimental: native-core web rendering (WASM)

_Feasibility study → **working PoC**. Status: **mbgl-core renders an interactive map in the
Flutter web example via WebAssembly (experimental, opt-in).** Last updated: 2026-06-20 (branch
`feat/web-core-wasm-poc`)._

## TL;DR

**Can we drop maplibre-gl-js on web and render through our own `mbgl-core` engine instead, so
feature parity is maintained in one place and no separate web SDK is needed? — Yes, feasibly,
and sooner than expected.**

The deciding fact: **MapLibre Native's WebGPU renderer is already vendored in our pinned
`mbgl-core` submodule** (`platform/default/.../mbgl/webgpu/headless_backend.{hpp,cpp}`,
`option(MLN_WITH_WEBGPU)`, `cmake/webgpu.cmake`, Dawn wiring). It is selected by the *exact same
backend-flag pattern* we already ship in production for the Windows **Vulkan** tier. The web
target is therefore "build the existing engine with the Emscripten toolchain, select
`MLN_WITH_WEBGPU`, present into a `<canvas>`, and bind the C ABI to JS" — not a new engine.

**Recommendation:** pursue it as a **build-time-flagged, opt-in experiment** (`MAPLIBRE_WEB_CORE`),
keeping maplibre-gl-js the default until the core path matches it on **download size, performance,
and feature parity**. This is exactly the "offer core rendering as an opt-in/experimental path,
A/B it, don't rip the SDK out up front" escape hatch recorded in CLAUDE.md §12 (2026-06-19).

---

## Implementation status (2026-06-20, branch `feat/web-core-wasm-poc`)

It works: the native MapLibre engine, compiled to WebAssembly, **renders and pans a map inside
the Flutter web example** — no maplibre-gl-js. This is the path upstream's library-compilation
effort ([maplibre/maplibre-native#2554](https://github.com/maplibre/maplibre-native/issues/2554),
open/unsolved — "can't figure out how to run `emcmake` without errors") never reached.

**Verified on hardware (Windows 11 + emsdk, headless Edge / SwiftShader WebGL):**

| Step | Result |
| ---- | ------ |
| `emcmake` build: `mbgl-core` + platform layer + embind shim → `maplibre_flutter_core.js` (~0.5 MB) + `.wasm` (~9.4 MB) | ✅ links, 0 errors |
| Render a map frame to a canvas | ✅ fully-painted demotiles (read back 11 498 distinct colours) |
| Run in the **Flutter web example** behind `--dart-define=MAPLIBRE_WEB_CORE=true` | ✅ crisp full-world map renders |
| **Interactive** | ✅ drag-pans (verified Atlantic→Asia), wheel-zooms, fly-to animates |

**The platform layer that makes it work** (`packages/maplibre_flutter_core/src/web/`):

| Piece | How |
| ----- | --- |
| Run loop / async / timer | libuv-free `RunLoop`: non-blocking + per-frame tick on the main thread, blocking + condvar event-processing on mbgl worker threads (`emscripten_run_loop.cpp`) |
| HTTP source | **synchronous** `emscripten_fetch` — mbgl's file-source worker blocks and can't pump an async callback (`emscripten_http_file_source.cpp`) |
| GL context | WebGL2 on the canvas via `emscripten_webgl_*` (Emscripten EGL has no pbuffer) (`emscripten_gl_backend.cpp`) |
| Present | blit mbgl's color FBO → the canvas default framebuffer (`maplibre_flutter_core_web.cpp`) |
| Threads | Emscripten `-pthread`; `PTHREAD_POOL_SIZE` pre-allocated to avoid the main-thread thread-spawn deadlock |
| Sysroot gaps | webp-decode stub, `sched_setscheduler` no-op, `<GLES3/gl3ext.h>` shim |
| JS API | embind module `MaplibreFlutterCore` — `createMap/setStyle/setCamera/getCamera/resize/moveBy/scaleBy/animateTo/onReady/destroy` |
| Canvas + gestures | canvas registered in `specialHTMLTargets`; auto-sized to CSS×DPR each frame; drag/wheel from raw pointer events drive moveBy/scaleBy |
| Dart loader | injects the glue script + passes `mainScriptUrlOrBlob` (dynamic inject → no `document.currentScript`, else startup hangs at `library_fetch_init`) |

### Build + run the example with the core renderer

```sh
# 1. Build the WASM module (emsdk on PATH: `source emsdk_env`)
cd packages/maplibre_flutter_core/web
emcmake cmake -G Ninja -S . -B ../build/wasm
cmake --build ../build/wasm --target maplibre_flutter_core_wasm
#    -> ../build/wasm/maplibre_flutter_core.{js,wasm}

# 2. Drop the artifact next to the app and build with the flag
cp ../build/wasm/maplibre_flutter_core.js ../build/wasm/maplibre_flutter_core.wasm \
   ../../maplibre_flutter/example/web/
cd ../../maplibre_flutter/example
flutter build web --dart-define=MAPLIBRE_WEB_CORE=true \
                  --dart-define=MAPLIBRE_WEB_CORE_URL=maplibre_flutter_core.js

# 3. Serve with COOP/COEP (SharedArrayBuffer); the default Flutter server doesn't set them
python ../../maplibre_flutter_core/web/serve.py build/web 8100   # http://127.0.0.1:8100
```

Standalone verification harnesses live next to the build: `web/probe/` (engine renders to a
PNG), `web/module_test.html` (the embind module renders to a canvas), `web/cdp_shot.py` /
`web/cdp_interact.py` (headless screenshot + a scripted drag).

### Remaining for production (not blockers to the PoC)

- **WebGPU backend** for performance — already vendored (`MLN_WITH_WEBGPU`); the PoC uses the
  portable OpenGL→WebGL2 path. WebGPU is the eventual default once it's solid.
- **Download size**: the ~9.4 MB `.wasm` vs gl-js's ~KBs — brotli, code-split, lazy-load.
- **Deployment headers**: the threaded build needs COOP/COEP from the host (or ship a
  single-threaded build for header-less hosting).
- **HTTP concurrency**: the synchronous fetch serialises tiles per worker — parallelise (a fetch
  thread pool, or an async path that pumps the worker event loop).
- **Multiple maps per page**, and an **artifact distribution** story (build hook / CI / prebuilt,
  like the desktop core) so app consumers don't run `emcmake` themselves.

---

## Why do this at all

Today web rides **maplibre-gl-js** — a separate codebase with its own feature surface and release
cadence. Every feature we bind (layers, sources, expressions, queries…) has to be wired twice:
once against the desktop/mobile engine surface and once against gl-js. Rendering web through the
**same `mbgl-core`** the desktop tier already uses collapses that to one place:

- **One engine, one feature surface.** Parity work happens once, in the core C ABI.
- **No extra SDK** to track, version-pin, or CSP-whitelist.
- **Consistent rendering** across desktop and web (same tiles, same text shaping, same styling).

The cost side (and why it stays opt-in for now) is download size and the Emscripten build matrix —
see [Tradeoffs](#tradeoffs).

---

## What's already true (this is what makes it feasible)

- **The WebGPU backend is in our submodule.** `mbgl/webgpu/headless_backend.{hpp,cpp}` exists, and
  the root CMake exposes `option(MLN_WITH_WEBGPU "Build with WebGPU renderer" OFF)` +
  `include(cmake/webgpu.cmake)` + Dawn integration — the same shape as `cmake/vulkan.cmake` /
  `cmake/metal.cmake` / `cmake/opengl.cmake` that our desktop arms already use.
- **Same selection pattern we already ship.** Our `packages/maplibre_flutter_core/src/CMakeLists.txt`
  picks a backend per platform (`APPLE → Metal`, `WIN32 → Vulkan`, `else → OpenGL`). The web arm is
  one more `elseif` that sets `MLN_WITH_WEBGPU ON` — see [the CMake arm](#the-cmake-arm).
- **Upstream shipped the WebGPU renderer in Oct 2025** (supports both `wgpu` and Dawn), explicitly
  aiming at an Emscripten web target for "significantly better performance" than the WebGL path.
- **`mbgl-core` already runs in browsers.** It can target WebGL via Emscripten today (the
  Qt-for-WASM precedent), and there's a community `maplibre-native-wasm` build — so WASM
  compilation of the engine is proven, not speculative.
- **Our C ABI is portable and already the integration surface.** `maplibre_flutter_core.h`
  (opaque handle + plain-C functions, no C++ leakage) is exactly what an Emscripten build exports
  to JS. The web controller drives the same operations the desktop controllers drive over FFI.

---

## Architecture

```
 build time (separate Emscripten build, NOT `flutter build web`)
 ┌──────────────────────────────────────────────────────────────────────┐
 │ emcmake cmake … -DMLN_WITH_WEBGPU=ON   (mbgl-core + C shim)           │
 │   → maplibre_flutter_core.js  (MODULARIZE glue, EXPORT_NAME=          │
 │       MaplibreFlutterCore)  +  maplibre_flutter_core.wasm            │
 │   exports a JS API mirroring the C ABI (createMap/setCamera/…)        │
 └──────────────────────────────────────────────────────────────────────┘

 run time (Flutter web app built with --dart-define=MAPLIBRE_WEB_CORE=true)
 ┌──────────────────────────────────────────────────────────────────────┐
 │ MapLibreFlutterWeb.createMap                                          │
 │   └─ MapLibreCoreWebController.create            (core_web_controller)│
 │        ├─ ensureCoreModuleLoaded()               (core_wasm_loader)   │
 │        │    inject <script src=…core.js>; await MaplibreFlutterCore() │
 │        └─ registerViewFactory(viewType) → <canvas>                    │
 │             module.createMap({canvas, style, camera, pixelRatio})     │
 │             → engine renders WebGPU/WebGL2 directly into the canvas   │
 │ widget embeds ElementViewHandle(viewType) as an HtmlElementView       │
 └──────────────────────────────────────────────────────────────────────┘
```

- **Present path is simpler than desktop.** The WebGPU/WebGL2 context binds to the `<canvas>`; the
  engine renders straight into it and the browser composites it. There is **no readback and no
  texture bridge** — the canvas *is* the surface. (The desktop zero-copy machinery —
  IOSurface/dmabuf/D3D shared handles — has no analogue or need here.)
- **Control** (camera/style/resize) forwards over `dart:js_interop` to the module. `onReady`
  completes when the engine reports its first frame.
- **Gestures stay in the renderer**, as they do for gl-js: the WASM/JS glue listens to canvas
  pointer/wheel events and calls the engine's `moveBy`/`scaleBy`. So web keeps the "renderer owns
  gestures" model — **no Dart gesture layer and no platform-interface change** (the controller
  implements `MapLibreMapController` only, like the gl-js controller).

### The JS/WASM contract

The Emscripten build must expose a JS surface that mirrors the C ABI. The authoritative,
type-checked definition is **`packages/maplibre_flutter_web/lib/src/core_web/core_wasm_interop.dart`**:

| JS (`CoreMap`)              | C ABI (`maplibre_flutter_core.h`) |
| --------------------------- | --------------------------------- |
| `module.createMap(opts)`    | `mbl_map_create`                  |
| `setStyle(uri)`             | `mbl_map_set_style`               |
| `setCamera(lat,lng,z,b,p)`  | `mbl_map_set_camera`              |
| `getCamera()`               | `mbl_map_get_camera`              |
| `resize(w,h,ratio)`         | `mbl_map_resize`                  |
| `moveBy(dx,dy)`             | `mbl_map_move_by`                 |
| `scaleBy(s,ax,ay)`          | `mbl_map_scale_by`                |
| `onReady(cb)`               | `mbl_map_await_frame` / frame cb  |
| `destroy()`                 | `mbl_map_destroy`                 |

Exposed via Emscripten `embind` (cleanest — gives the object-oriented `CoreMap` shape directly) or
`cwrap` over `EXPORTED_FUNCTIONS` plus a thin hand-written JS class. Coordinates are `lat,lng`
(matching the C ABI), so — unlike gl-js — there is **no `[lng,lat]` flip** on this boundary.

### The CMake arm

One `elseif` in `packages/maplibre_flutter_core/src/CMakeLists.txt`, mirroring the Windows Vulkan
arm (the WebGPU renderer + shaders + Dawn are wired automatically by the root `cmake/webgpu.cmake`,
which runs before the `CORE_ONLY` `return()` and is keyed on the flag — setting the flag is the
whole trigger):

```cmake
elseif(EMSCRIPTEN)
  # WebGPU arm (web). Best performance; needs a browser with WebGPU. For broad
  # coverage, build a second artifact with MLN_WITH_OPENGL ON (WebGL2) instead.
  set(MLN_WITH_CORE_ONLY ON CACHE BOOL "" FORCE)
  set(MLN_WITH_METAL    OFF CACHE BOOL "" FORCE)
  set(MLN_WITH_VULKAN   OFF CACHE BOOL "" FORCE)
  set(MLN_WITH_OPENGL   OFF CACHE BOOL "" FORCE)
  set(MLN_WITH_WEBGPU   ON  CACHE BOOL "" FORCE)
endif()
```

Then hand-attach `platform/default/src/mbgl/webgpu/headless_backend.cpp` (mirroring how the Windows
arm hand-attaches the Vulkan headless backend) plus the default-platform sources, and add the
Emscripten link flags (`-sMODULARIZE -sEXPORT_NAME=MaplibreFlutterCore -sUSE_WEBGPU`/WebGL2,
`-pthread` if threaded, `-sALLOW_MEMORY_GROWTH`, `--bind` for embind). This is **not** driven by
`hook/build.dart` (that builds Dart native assets for desktop); the web artifact is a standalone
`emcmake` build whose output is served as a web asset and fetched at runtime by `core_wasm_loader`.

> ⚠️ The `webgpu/headless_backend` renders *headless* (offscreen). The web build needs a
> canvas-targeted variant (render into the canvas default framebuffer, or blit offscreen→canvas).
> This is the main engine-side build task — see [Open questions](#open-questions--blockers).

---

## Resource loading (the file source)

`mbgl`'s default HTTP source uses libcurl — there are no sockets/curl under WASM. Replace it with a
**`fetch`-based file source** (Emscripten `emscripten_fetch`, or a JS `OnlineFileSource` that calls
`fetch()`), which is the standard approach the existing browser builds use. `mbgl`'s file source is
pluggable, so this is additive. Optional tile caching via IndexedDB.

---

## Threading

`mbgl` uses worker threads (tile parsing, etc.). Emscripten pthreads require `SharedArrayBuffer`,
which requires the page be **cross-origin isolated** — the server must send:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

and every cross-origin resource (tiles, fonts, the WASM itself) must be CORS/CORP-compatible. This
is the single biggest **deployment** constraint.

- **Threaded build (recommended for perf):** ship the COOP/COEP headers; document them for
  consumers. Tile work runs off the main thread.
- **Single-threaded fallback:** no pthreads / no SAB / no special headers — trivial to deploy, but
  tile work runs on the main thread (jank under load). Useful for environments that can't set
  headers.

Offer both build variants; pick per deployment.

---

## Tradeoffs

| Dimension        | maplibre-gl-js (default) | Native core (WASM, experimental) |
| ---------------- | ------------------------ | -------------------------------- |
| First-load size  | ~KBs, CDN-cached         | **MBs** (engine + ICU + Dawn glue) — the main regression. Mitigate with brotli, streaming compile, caching, splitting. |
| Runtime perf     | hand-tuned WebGL         | **WebGPU ≥ gl-js** on modern browsers (upstream's whole motivation); WebGL2 fallback ~parity-ish but heavier |
| Browser coverage | universal (WebGL)        | WebGPU = Chrome/Edge now, Safari 18+/Firefox rolling out → **need the WebGL2 fallback** |
| Feature parity   | gl-js's own surface      | **same surface as desktop/mobile core** — the entire point |
| Deployment       | drop-in `<script>`       | serve WASM asset (+ COOP/COEP if threaded) |
| Maintenance      | none (upstream CDN)      | we own an Emscripten build matrix + JS glue |

---

## What's scaffolded today (in this repo)

Opt-in plumbing only — the gl-js path is untouched and remains the default.

- **Build flag:** `--dart-define=MAPLIBRE_WEB_CORE=true` selects the core path in
  `MapLibreFlutterWeb.createMap` (compile-time const, so the unused path tree-shakes away).
  `--dart-define=MAPLIBRE_WEB_CORE_URL=…` points at the served `.js` glue;
  `MAPLIBRE_CONTINUOUS` is reused for render mode.
- **`lib/src/core_web/core_wasm_interop.dart`** — the JS/WASM contract (the table above), type-checked.
- **`lib/src/core_web/core_wasm_loader.dart`** — loads + instantiates the module, memoised. If the
  flag is on but the artifact is missing, it throws a **clear, actionable** error.
- **`lib/src/core_web/core_web_controller.dart`** — `MapLibreMapController` over the module:
  canvas-hosting view factory, camera/style/resize/dispose, `onReady`.

The one missing piece is the **WASM artifact itself** (the Emscripten build) — that is the spike below.

---

## Phased plan (go-forward)

1. **Build spike (standalone, no Flutter):** `emcmake` the core with `MLN_WITH_WEBGPU`,
   single-threaded, a `fetch` file source, a canvas-targeted backend; render one frame in a plain
   HTML page. *Proves the engine paints in a browser.*
2. **Export the JS API:** embind (or `cwrap`) to satisfy the `core_wasm_interop` contract.
3. **Flutter integration:** point the scaffolded controller at the real module; verify map + camera
   + style behind the flag in the example app.
4. **Gestures + animation:** canvas gestures in the glue; `moveCamera(duration)` via a JS easing or
   the shared desktop fly-arc.
5. **Threaded build + COOP/COEP; A/B vs gl-js** (perf + size); size optimization (brotli, split).
6. **CI:** an Emscripten build job; publish the artifact.
7. **Graduation decision:** keep gl-js default, or promote the core path once parity + perf + size
   are acceptable.

The natural next session is **Phase 1** (the "build spike" — it needs the Emscripten toolchain).

---

## Open questions / blockers

- **Canvas-target backend:** `webgpu/headless_backend` is offscreen; needs a canvas-default-framebuffer
  path (or offscreen→canvas blit). Main engine-side build task.
- **WebGPU coverage:** ship a **WebGL2 fallback** artifact (`MLN_WITH_OPENGL`) and feature-detect
  `navigator.gpu`.
- **COOP/COEP** for threads, or accept single-thread jank.
- **Download size:** MBs; needs compression + caching strategy before this could be a default.
- **Text/glyphs (ICU)** in WASM: size + correctness; `mbgl` bundles ICU (we already exercise the
  builtin-ICU path on the Windows tier).
- **Multiple maps per page:** one WebGPU/WebGL context per module instance — instantiate one module
  per map, or share via offscreen canvases. Decide during integration.
- **Maintenance:** we take on an Emscripten build + the JS glue as a supported surface.

---

## Decision

**GO, experimental and opt-in.** Keep maplibre-gl-js the default; gate the core path behind
`MAPLIBRE_WEB_CORE`. Revisit promotion after the Phase-1 spike gives real size/perf numbers. Record
graduation (or abandonment) in CLAUDE.md §12.

## Sources

- [Native: WebGPU support — maplibre/maplibre-native Discussion #2606](https://github.com/maplibre/maplibre-native/discussions/2606)
- [WebGPU Renderer — MapLibre roadmap](https://maplibre.org/roadmap/maplibre-native/webgpu/)
- [MapLibre Native platforms docs](https://maplibre.org/maplibre-native/docs/book/platforms/index.html)
- [birkskyum/maplibre-native-wasm](https://github.com/birkskyum/maplibre-native-wasm)
