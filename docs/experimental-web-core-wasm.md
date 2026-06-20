# Experimental: native-core web rendering (WASM)

_Feasibility study → **working PoC**. Status: **mbgl-core renders an interactive map
(pan / zoom / style / fly-to) in the Flutter web example via WebAssembly — now in **Continuous**
render mode (partial frames stream in as tiles load, no full-frame stall), and the resize
180°-flip bug is fixed.** Verified in headless Edge. Last updated: 2026-06-20
(branch `feat/web-core-wasm-poc`)._

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
| HTTP source | **synchronous** `emscripten_fetch` on a **bounded pool of 8 long-lived fetch worker threads** (queue-fed) — mbgl's file-source worker blocks and can't pump an async callback, so each fetch runs sync off the main thread and delivers the Response back via the RunLoop. The fixed pool (not thread-per-request) keeps fetch concurrency bounded so a request burst can't exhaust the Emscripten pthread pool (`emscripten_http_file_source.cpp`) |
| GL context | WebGL2 on the canvas via `emscripten_webgl_*` (Emscripten EGL has no pbuffer) (`emscripten_gl_backend.cpp`) |
| Render mode | **Continuous** (default): mbgl invalidates on every camera/style change and as tiles stream in; the `HeadlessFrontend`'s `invalidateOnUpdate` renders a frame off the RunLoop and a `MapObserver` presents it (partial → refined). Static `renderStill` kept behind `continuous=false` (`maplibre_flutter_core_web.cpp`) |
| Present | **1:1** blit (no flip) of mbgl's offscreen color FBO → the canvas default framebuffer, keeping mbgl's GL `State<>` cache truthful (`maplibre_flutter_core_web.cpp`) |
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
- **HTTP concurrency**: ✅ done — a **fixed pool of 8 long-lived fetch worker threads** pulls
  requests off a queue, runs a sync fetch, and delivers the Response async via the RunLoop
  (concurrent, contract-correct). This replaced the original thread-per-request design, which could
  spawn up to mbgl's 20 concurrent requests as Emscripten pthreads at once and — together with
  mbgl's other threads — **exhaust the `PTHREAD_POOL_SIZE` pool** ("Tried to spawn a new thread, but
  the thread pool is exhausted"), most visibly when switching to a heavy style (OpenFreeMap Liberty)
  whose tile/glyph/sprite burst broke rendering. See the thread-budget note below.
- **Multiple maps per page**, and an **artifact distribution** story (build hook / CI / prebuilt,
  like the desktop core) so app consumers don't run `emcmake` themselves.

---

## Continuous-mode rendering — DONE (2026-06-20)

The web shim now renders in mbgl **Continuous** mode (default), like the mobile/desktop tiers, so
the map paints partial frames immediately and refines them as tiles stream in — no full-frame stall.
The earlier Static `renderStill` path (one complete frame on demand) is kept behind `continuous=false`.

**What changed** (all in `src/web/maplibre_flutter_core_web.cpp`):
- `WebMap` honors the `continuous` createMap option (already plumbed from Dart via
  `--dart-define=MAPLIBRE_CONTINUOUS`, default true). In Continuous mode it builds the
  `HeadlessFrontend` with `invalidateOnUpdate=true` and constructs the `Map` with
  `MapMode::Continuous` + a `WebFrameObserver` (a `mbgl::MapObserver`) whose
  `onDidFinishRenderingFrame` presents each finished frame and completes `onReady` on the first.
- The render is **driven by the existing per-frame tick**: every camera/style mutation and every
  tile load invalidates the frontend, whose `asyncInvalidate` renders a frame off the libuv-free
  RunLoop on the next `globalTick → runOnce()`. mbgl self-drives — no explicit per-tick `render()`
  call is needed (it mirrors the desktop Continuous path, adapted to the main-thread tick). The
  `rendering_`/`renderStill` machinery is bypassed in Continuous mode; `tick()` only does
  `syncSize()` + `stepAnimation()` and lets mbgl render.
- When idle (style loaded, all tiles in, no animation) mbgl stops invalidating, so it does **not**
  busy-loop — confirmed by the camera-poll test below settling and staying put.

**Verified in headless Edge** (SwiftShader WebGL): the example map renders, drag-pans, and a direct
`animateTo(London, zoom 10, 2000 ms)` eases smoothly through progressive frames and lands exactly on
target (`zoom 1.00→10.00`, `lat 0.00→51.51` over ~10 polled steps), then settles. Console clean.

> **Headless caveat:** a *passive* fly-to (click the FAB, then wait) freezes mid-animation in
> headless Edge because `requestAnimationFrame` goes idle when the page has no compositor and no
> input — `stepAnimation` runs off rAF, so it stops stepping. This is a headless artifact, **not** a
> code bug: in a real visible browser rAF fires continuously at 60 fps. To verify animation headlessly,
> drive it from a page that keeps rAF alive (a self-perpetuating `requestAnimationFrame` loop) — see
> `example/build/web/anim_test.html` + `build/cdp_console.py`, which is how completion was confirmed.

## The resize 180°-flip bug — FIXED (2026-06-20)

**Symptom:** scaling the window flipped the map 180° vertically; it corrected itself on the next pan.

**Root cause** (in `WebMap::present()`): mbgl's `gl::Context` caches the GL framebuffer binding in a
write-through `State<>` wrapper and skips redundant `glBindFramebuffer` calls. The old `present()`
ended with a raw `glBindFramebuffer(GL_FRAMEBUFFER, 0)`, leaving FBO 0 bound while mbgl's cache still
believed its offscreen color FBO was bound. So the **next** render's `renderable.bind()` was a no-op
(cache match) and mbgl rendered straight into FBO 0 (the canvas) — which is **upright** — and the
`present()` blit early-returned (`srcFbo == 0`). That was the steady state, and it looked correct.
A **resize** calls `HeadlessBackend::setSize → resource.reset()`, allocating a fresh offscreen FBO
**id**; the next `bind()` then issues a *real* `glBindFramebuffer`, so for one frame mbgl genuinely
rendered into the offscreen FBO — and the old blit **flipped it vertically** → one upside-down frame,
until the next mutation desynced the cache back to FBO 0 and it "corrected."

**Fix:** make `present()` deterministic and cache-truthful (same discipline as the desktop GL
presenter's `GlStateGuard`): blit mbgl's offscreen color FBO → the canvas default framebuffer **1:1
(no vertical flip)**, then **re-bind mbgl's color FBO** before returning so its `State<>` cache stays
truthful. Now every frame reliably renders into the offscreen FBO and blits straight to the canvas,
upright, including immediately after a resize. (The Y-flip was wrong for the on-screen canvas: it's
the offscreen→CPU/texture convention the desktop CPU readback uses, not offscreen→canvas.) Verified:
captured a screenshot *immediately after* a viewport resize (before any pan) — map stays upright.

## Resize white-blink — FIXED (2026-06-20)

**Symptom:** resizing the window made the map **blink white** (worse while dragging the edge).

**Root cause:** the resize path set `canvas.width/height` (which **clears the WebGL drawing buffer to
transparent** → the white page shows through) in one animation frame, but the new-size frame was only
rendered + blitted on the *next* frame — so the browser composited the cleared canvas in between.

**Fix:** the canvas backing-store resize moved out of `resize()` and **into `present()`, immediately
before the blit** (guarded by `canvasW_/canvasH_` so it only fires on a real change). The clear and
the repaint now happen in the **same animation-frame turn**, so the compositor never reads a cleared
canvas. User-confirmed on real hardware: **no blink at all.**

> **Verifying this headlessly is unreliable** — `drawImage`-based canvas pixel readback returns
> spurious transparent frames under headless SwiftShader (a *static, non-resizing* map showed false
> "blank" frames too), and `Page.startScreencast` throttles/coalesces away the transient. The
> compositor screencast showed no white frames; the real test was a human resizing a real window.

**Resize "skew"/stretch — FIXED via `ResizeObserver` (2026-06-20).** After the blink fix there was a
~1-frame artifact: the previous frame was CSS-scaled to the new size before the correct-size frame
rendered. Root cause: the engine's per-tick `syncSize` *poll* notices Flutter's canvas CSS-box change
one frame late. **What did NOT fix it** (tried, reverted): rendering the new-size frame synchronously
in the resize turn — it collapses the detect→render gap, but detection itself is the frame-late part,
and the extra per-frame render made it slightly worse. **The fix** (as maplibre-gl-js does): a JS
**`ResizeObserver`** on the canvas, wired in `core_web_controller.dart`. Its callback fires *after
layout, before paint*, and calls a new `resizeSync` embind method (`resize()` + one `runOnce()` →
render+present in that same callback), so the correct-size frame is composited in the same paint —
zero lag. The first `resizeSync` also flips the engine's `autoSize_` off so the laggy `syncSize` poll
stops (no double-driving). User-confirmed on real hardware: resize is now smooth. (Edge case left:
a pure devicePixelRatio change with no CSS-box resize won't trigger the observer; rare, acceptable.)

## Zero-copy on web — already effectively in place; no work needed

**Question:** should we build a zero-copy present for web like the desktop tiers, or is it already
zero-copy?

**Answer: it is already effectively zero-copy, and the desktop zero-copy machinery has no analogue
on web.** The desktop "zero-copy" work
(IOSurface on macOS / dmabuf on Linux / D3D11 shared handle on Windows) exists to (1) avoid a
GPU→CPU **readback** and (2) bridge a GPU texture into Flutter's **`Texture` widget / engine texture
registrar** without a CPU copy. Neither applies on web:

- **The canvas _is_ the surface.** Flutter web embeds the map via `HtmlElementView`, which the engine
  renders as a real **DOM `<canvas>`** (a child of `flt-glass-pane`, "slotted" into position) that the
  **browser composites directly** alongside the Flutter scene. There is no Flutter `Texture` and no
  engine texture bridge to feed — so there is nothing for IOSurface/dmabuf/shared-handle to plug into.
- **No CPU readback in the live path.** mbgl (WebGL2) renders into a GPU framebuffer in the **same**
  WebGL context that owns the canvas; `present()` is a single **intra-context GPU blit** (offscreen
  color FBO → canvas default FBO). `readStillImage` (the GPU→CPU readback) is used only by the desktop
  `render()` and the `web_render_probe`/test harness — never by the live web map.
- **The final canvas→screen composite is the browser's job.** Per the WebGL spec, the browser presents
  the canvas drawing buffer to the page compositor; on modern desktop GPUs that is GPU compositing
  (zero-copy). Whether it's truly readback-free is a browser/hardware property, **not** something our
  code controls — and it is identical for maplibre-gl-js. (Our `preserveDrawingBuffer=true`, needed so
  an idle frame keeps showing the last paint, can cost the browser an extra buffer copy — a deliberate
  trade, unrelated to a "zero-copy architecture.")

**Possible micro-optimizations (low value, not pursued):**
- Eliminate the one intra-context blit by rendering mbgl **directly into the canvas default
  framebuffer** (no offscreen FBO). This is orientation-safe (direct-to-FBO-0 is upright) but requires
  a custom GL `RendererBackend`/`Renderable` — mbgl's `HeadlessBackend` always allocates an offscreen
  renderbuffer FBO. The blit is a GPU-local copy of a few MB, fully pipelined; removing it is not worth
  forking the backend.
- Drop `preserveDrawingBuffer` by rendering every browser frame instead of on-invalidation — trades a
  possible compositor copy for always-on rendering (worse for battery). Not worth it.

**The real web perf lever is not zero-copy** — it's the vendored **WebGPU backend**
(`MLN_WITH_WEBGPU`) for faster rendering, plus threading/COOP-COEP and download-size work. See
[Remaining for production](#remaining-for-production-not-blockers-to-the-poc).

## Style-switch thread-pool exhaustion — FIXED (2026-06-20)

**Symptom:** switching the style (e.g. Demotiles → OpenFreeMap Liberty) "broke" the map.

**Root cause — the WASM pthread budget.** Emscripten pre-allocates a fixed `PTHREAD_POOL_SIZE`
(32). mbgl's threads: the background tile pool is **4** (`ThreadPool = ParallelScheduler(3)`), plus
the file-source / sequenced / database threads (~5) and the main thread. The original HTTP source
spawned **one pthread per request**, and mbgl dispatches up to `DEFAULT_MAXIMUM_CONCURRENT_REQUESTS`
= **20** at once — so a heavy style's tile/glyph/sprite burst pushed the live thread count to ~32,
hitting *"Tried to spawn a new thread, but the thread pool is exhausted"* + *"Blocking on the main
thread is very dangerous"* (deadlock risk → broken render).

**Fix:** a **bounded fetch-thread pool** (8 long-lived workers pulling a queue) in
`emscripten_http_file_source.cpp`, replacing thread-per-request. Fetch concurrency is now capped at
8 regardless of mbgl's burst (excess requests queue), so the pool can't be exhausted. Verified:
Demotiles ⇄ Liberty switches with **no "pool exhausted"** errors; Liberty renders correctly (full
labelled world map) and switches back cleanly. (One benign `Blocking on the main thread` warning can
still appear once on a switch — mbgl's old-style teardown briefly syncs on a background task; the map
renders through it, no hang. Eliminating it would need mbgl patching / `PROXY_TO_PTHREAD`; not worth
it.) If a future heavier style needs more headroom, raise `kFetchThreads` and/or `PTHREAD_POOL_SIZE`.

## Fly-to zoom-out arc — DONE (2026-06-20)

The web fly-to (`animateTo` → `stepAnimation`) previously did a straight eased lerp of zoom, so a
long city→city flight at high zoom (e.g. London z10 → Tokyo z10) flew across the world *at z10*
(lots of tiles, no overview). It now does a **zoom-out arc** like gl-js / the desktop tier: it
computes the zoom that would fit both endpoints (`fitZoom` from the angular span vs. the CSS
viewport width) and, **only when that's lower than both endpoints** (so +/- buttons and short hops
don't overshoot — mirrors the macOS fly-to dip fix), dips the zoom toward it at the time-midpoint
via `sin(πt)`. Verified: London z10 → Tokyo z10 dips to **z≈1.8** (≈world view) at the midpoint,
then zooms back to z10.

### Build + test loop (all set up on this Windows box)
- **Toolchain**: emsdk at `C:\emsdk`; real Python at
  `C:\Users\juhot\AppData\Local\Programs\Python\Python312` (the `python` on PATH is the broken
  Windows Store stub — use the full path or prepend this dir); cmake+ninja from VS2022
  (`…\Common7\IDE\CommonExtensions\Microsoft\CMake\{CMake\bin, Ninja}`). In PowerShell: dot-source
  `C:\emsdk\emsdk_env.ps1`, then prepend those three dirs to `$env:PATH`.
- **Build the module** — use ABSOLUTE `-S`/`-B` paths (PowerShell CWD drifts into the submodule); log
  with `Out-File -Encoding utf8` (NOT `Tee-Object`, which writes UTF-16 that breaks `grep`):
  `emcmake cmake -G Ninja -S <repo>\packages\maplibre_flutter_core\web -B <repo>\packages\maplibre_flutter_core\build\wasm`
  then `cmake --build <bld> --target maplibre_flutter_core_wasm`. (~0.5 MB `.js` + ~9.4 MB `.wasm`.)
- **Deploy**: copy `build/wasm/maplibre_flutter_core.{js,wasm}` into BOTH
  `packages/maplibre_flutter/example/web/` and `…/example/build/web/` (the latter is what's served;
  both are git-ignored). Re-run `flutter build web --dart-define=MAPLIBRE_WEB_CORE=true
  --dart-define=MAPLIBRE_WEB_CORE_URL=maplibre_flutter_core.js` **only when the Dart changes**.
- **Serve with COOP/COEP**: `python packages/maplibre_flutter_core/web/serve.py <dir> <port>` (the
  default Flutter server doesn't send them; SharedArrayBuffer / pthreads need them).
- **Test headlessly** — no Chrome on this box; Edge Chromium is identical and at
  `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`. Launch
  `msedge --headless=new --guest --remote-debugging-port=PORT --remote-allow-origins=*
  --enable-unsafe-swiftshader --use-gl=angle --use-angle=swiftshader --no-sandbox --disable-sync
  --user-data-dir=<temp> http://127.0.0.1:PORT/`, then drive it with the `web/cdp_*.py` helpers
  (need `pip install websocket-client`, already installed): `cdp_shot.py` (screenshot after a
  real-time wait — the `--screenshot` flag fires too early for a network map), `cdp_diag.py`
  (captures console + does drags — this is what surfaced the GL blit bug), `cdp_interact.py` (drag
  before/after), `cdp_click.py` (click a button at x,y). **View the PNGs with the Read tool.** The
  FAB coords in the example at 700×820: zoom + ≈(583,445), − ≈(583,510), Fly-to ≈(583,573), style
  toggle ≈(583,637). Edge shows a one-time sign-in interstitial as a separate tab → use `--guest`
  and the CDP scripts' URL-filter (they pick the `127.0.0.1` target).
- **Standalone smoke** (no Flutter): `web/probe/` (engine → PNG) and `web/module_test.html` (the
  embind module → canvas, reads back pixel count).

### Key files (the web tier map)
- `src/web/maplibre_flutter_core_web.cpp` — **the shim/embind module; the Continuous-mode change lives here.**
- `src/web/emscripten_run_loop.cpp` — RunLoop/AsyncTask/Timer (main-thread tick + worker condvar).
- `src/web/emscripten_http_file_source.cpp` — concurrent sync-fetch HTTP source (async delivery).
- `src/web/emscripten_gl_backend.cpp` — WebGL2-on-canvas context; `emscripten_*_stub.cpp` + `include/GLES3/gl3ext.h` — sysroot gaps.
- `web/CMakeLists.txt` — the Emscripten build; `web/serve.py`, `web/cdp_*.py`, `web/module_test.html`, `web/probe/` — the test harness.
- `packages/maplibre_flutter_web/lib/src/core_web/` — Dart interop / loader / controller (likely
  unchanged for Continuous — the module's JS API stays the same).

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
