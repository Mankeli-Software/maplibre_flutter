# Decision log — archive

Every decision, root-cause and gotcha recorded while building `maplibre_flutter`, in
chronological order. **This is history, not guidance** — it is the audit trail behind
`CLAUDE.md`, kept verbatim so nothing is lost, and moved out of `CLAUDE.md` (which is
loaded into every session's context) once it passed ~1500 lines.

- For **what is true now**, read `CLAUDE.md`.
- For the **rules that still bite**, read `CLAUDE.md` §11 "Hard-won rules".
- Read an entry here when you need the *why* behind a decision, or when you hit a bug
  that smells like one already solved. `grep` is the intended access pattern.

Entries below are unedited. Where an entry says a native SDK / maplibre-gl-js is "the
default" and `mbgl-core` is "experimental / opt-in", that was true when written and was
**inverted on 2026-06-21** — see that date's entry.

---

- **AGP 9+ compatibility required** for the Android package: namespace in Gradle, built-in
  Kotlin (drop `kotlin-android`), Java 17. Stay back-compatible with supported older AGP.
- **Swift Package Manager is the primary Apple dependency manager**, but CocoaPods support is
  kept in parallel until Flutter retires it.
- **2026-06-17 — Renamed package `maplibre_native` → `maplibre_flutter`** (and the repo
  folder). Motivation: reduce the naming collision with the upstream MapLibre Native C++
  project and read as the Flutter binding rather than implying it *is* MapLibre Native.
  Applies to the root package and all derived federated package names (`maplibre_flutter_core`,
  `maplibre_flutter_android`, `maplibre_flutter_ios`, …). 
- Android = jnigen-SDK (not core) for speed and maturity.
- iOS = SDK + `UiKitView`; macOS moved to the desktop core+texture tier so both Apple
  platforms are *not* built together — chosen for "best mobile experience first, desktop
  brought to par after."
- Ship mobile tier before desktop tier.
- **2026-06-17 — Federated monorepo scaffolded (base architecture, Section 8 step 0).**
  Repo is now a pub workspace + melos with 10 members (Section 4). Notable choices made
  during scaffolding: (1) **melos pinned to `7.8.1`** to avoid the `cli_util` clash with
  ffigen (see Section 6); melos config lives in the root `pubspec.yaml` `melos:` block.
  (2) **No `MethodChannel` default** in the platform interface — `instance` throws until a
  platform registers (Section 10: no method channels on the data path). (3) The render
  split is expressed by a single `sealed MapLibreRenderHandle` (`PlatformViewHandle` /
  `TextureHandle` / `ElementViewHandle`); the `MapLibreMap` widget is the only place that
  branches on it. (4) Platform packages register via **`dartPluginClass`** (web:
  `pluginClass`); the hybrid `pluginClass` + native folders are deferred to each platform's
  build-order step, and `createMap()` throws `UnimplementedError` until then. (5) Core
  bindings moved to `lib/src/`, so the build-hook asset id is `src/<pkg>_bindings_generated.dart`.
- **2026-06-17 — example moved under `packages/maplibre_flutter/example`** (was
  `packages/example`). It is the app-facing package's own example (`path: ../`); workspace
  member path and Section 4/6 references updated.
- **2026-06-17 — Made the nine federated packages pub.dev-publishable.** Dropped
  `publish_to: none` from all nine; root + `example` stay private. Sibling deps converted
  from `path:` to **version constraints** (`^0.0.1`) — the pub workspace still links them
  locally, so this is dev-transparent but lets pub resolve them when published. Added per-
  package `LICENSE` (**BSD-3-Clause**, holder Mankeli Solutions Oy). melos `command.version`
  block (conventionalCommits + updateDependentsConstraints + linkToCommits) and a
  `publish:dry-run` script added (Section 6). Fixed root `.gitignore` `/build/`→`build/`
  (root-anchored glob let nested package `build/` artifacts leak into the publish archive —
  13 MB → 4 KB). Rationale: publishing readiness is part of the "official binding" pitch.

- **2026-06-17 — Android milestone A: a MapLibre map renders (Section 8 step 1, part 1).**
  Chose "visible map first, control layer second." Built the hybrid Android plugin: native
  `android/` module (AGP 9, `namespace`, **no `kotlin-android`** — built-in Kotlin, Java 17,
  `org.maplibre.gl:android-sdk:11.11.0`), a `PlatformViewFactory` registered by
  `MaplibreFlutterAndroidPlugin` (`pluginClass`), and `MapLibrePlatformView` building a `MapView`
  with `textureMode(true)` (so it composites under Flutter's default Virtual-Display `AndroidView`)
  + minimal lifecycle + style/camera from `creationParams`. Interface change: added
  **`creationParams` to `PlatformViewHandle`** (additive) so the mobile tier passes initial
  config through the platform-view registrar, not a data-path method channel. `MapLibreMap._embed`
  now branches `PlatformViewHandle`→`AndroidView` on `defaultTargetPlatform == android` (iOS
  deferred to its step). Camera/style controller methods throw `UnimplementedError('milestone B')`.
  **Toolchain note:** Flutter 3.44's migrator forcibly re-adds `android.builtInKotlin=false` to the
  example `gradle.properties`; left as Flutter-managed. The plugin module does **not** apply
  `kotlin-android` and builds either way, so it stays §9-compliant for the AGP 10 end-state.
  Verified: `melos analyze`/`test`/`format` green; `flutter build apk --debug` green with
  `libmaplibre.so` bundled. On-device frame still needs manual `flutter run -d <android>`.

- **2026-06-17 — Android milestone B: Dart drives the map over jnigen (Section 8 step 1, part 2).**
  Control flows Dart → jni → a thin Java shim, no method channel on the data path. Dart mints a
  `mapId`, passes it via `creationParams`; `MapLibrePlatformView` calls `MapRegistry.register(mapId)`
  and `controller.attachMap(map)` once the map is ready; the Dart controller looks the controller
  up with `MapRegistry.get(mapId)` and calls `getCamera`/`moveCamera`/`setStyle`. **Bound shim
  classes are Java** (`MapRegistry`, `MapLibreController` under `android/src/main/java/`) because
  jnigen 0.16 can't read AGP 9's Kotlin-2.3 metadata (Section 5a) — a deliberate deviation from
  §5's "Kotlin in `android/`", scoped to just the two summarised classes. The SDK is **main-thread
  only**, so the controller marshals every command onto the main looper and caches the camera from
  an idle listener for cheap getter reads. Dart holds the controller's JNI ref in a field and
  `release()`s it once in `dispose()` (§5d). Deps: `jni: ^1.0.0`, `jnigen: ^0.16.0` (resolved
  cleanly in the workspace). Example gained zoom / fly-to / style-toggle buttons (toggles
  demotiles ↔ OpenFreeMap Liberty — both keyless). Verified: `melos analyze`(`--fatal-infos`)/
  `test`/`format` green; `flutter build apk --debug` green with `libdartjni.so` + `libmaplibre.so`
  bundled. Button behaviour still needs a manual device run before moving to iOS.

- **2026-06-17 — iOS milestones A + B (Section 8 step 2); mobile tier complete.** Hybrid plugin,
  dual-packaged SPM + CocoaPods (§9), MapLibre Apple SDK 6.27.0, `MLNMapView` via `UiKitView`.
  Control mirrors Android (Dart → ObjC runtime → shim → SDK, no method channel) but adapts to a
  key swiftgen difference: **swiftgen compiles its inputs**, so the bound classes
  (`MapLibreController`, `MapRegistry`) are **Foundation-only** and forward through an internal
  `MapLibreMapOps` protocol to `MapLibreMapBackend` (the only file importing MapLibre, *not* a
  swiftgen input). Notable swiftgen findings, all now in §5b: `ObjCCompatibleSwiftFileInput`
  emits **no `.m`** (so SPM's no-mixed-language rule is moot); the bound class is looked up by its
  **module-qualified** runtime name, so **no `@objc(ExplicitName)`** and the Swift module must
  equal the package name in both SPM and Pod; use **named Swift params** for clean Dart selectors;
  `objective_c` pinned **`<9.4.1`** (its `hooks ^2.0.0` clashes with core's `hooks ^1.0.0` in the
  one shared workspace resolution — same family as the melos pin). Reverted all flutter-generated
  example `ios`/`macos` project churn (xcconfig/pbxproj/Podfiles) — flutter re-applies integration
  at build time, nothing to commit. Verified: `melos analyze`(`--fatal-infos`)/`test`/`format`
  green; example builds on the simulator via **both** SPM and CocoaPods. Device-sim frame + button
  behaviour still need a manual run.

- **2026-06-18 — macOS desktop tier (M0–M5) merged to main (§8 step 3, part 1).** mbgl-core via
  CMake-in-build-hook (`native_toolchain_cmake`) + C-shim + ffigen in `maplibre_flutter_core`;
  a dedicated render thread renders headless into BGRA; `maplibre_flutter_macos` is a hybrid Swift
  plugin feeding frames into a Flutter `Texture`; control mirrors the mobile controllers over FFI;
  gestures shared in Dart (`maplibre_flutter`). Verified: `flutter run -d macos` builds + launches
  clean, no runtime errors. Decisions reaffirmed during the build: render via `HeadlessFrontend`
  (Static mode — `renderFrame()`/`readStillImage()`, not the Static-only `render()`); a **Continuous
  render loop was tried and reverted twice** (it produced blank/partial frames — `invalidateOnUpdate`
  suppressed tile-load repaints), so animation is Dart-stepped on the working Static render; keep
  `code_assets ^1.0.0` / `hooks ^1.0.0` (do not bump — breaks the `objective_c <9.4.1` cap chain);
  macOS sandbox needs `com.apple.security.network.client`.
  - **TODO — true zero-copy deferred.** M5 ships a reused **IOSurface-backed `CVPixelBufferPool`**
    (no per-frame alloc, no tearing), but `copyPixelBuffer` still **CPU-copies** the frame out of
    the core via `copyFrameFn`. True zero-copy = give the core one IOSurface-backed Metal texture
    and have its `RendererBackend` draw straight into it (no readback), then present that surface
    through the Metal `FlutterTexture` path. Marked at `MapLibreTexture.swift` (`TODO(zero-copy)`).
    Revisit before/with the Windows (ANGLE) + Linux (`FlTextureGL`) surfaces, which share the same
    backend question.

- **2026-06-18 — macOS desktop made production-smooth (supersedes the zero-copy TODO above).**
  Four changes, all merged to `main`, took the macOS map from "renders, but janky zoom/fly-to" to
  smooth on device:
  - **Coalesce renders (`perf(core)`):** the render thread drains the whole command queue then
    renders once at the latest state, instead of one render per command — a burst of camera updates
    (fly-to / gesture stream) drops stale intermediate frames rather than falling behind.
  - **Zero-copy present (`feat(macos)`):** replaced the per-frame GPU→CPU `readStillImage` + CPU
    BGRA swizzle with a GPU compute blit of mbgl's rendered texture into an IOSurface-backed BGRA
    texture (swizzle implicit in the pixel-format conversion). The blit runs on **mbgl's own command
    queue** (GPU-ordered after the render, before the next — no race on mbgl's single internal
    texture) and is **async** (completion handler publishes; no CPU `waitUntilCompleted` stall). A
    3-deep IOSurface ring + Swift CVPixelBuffer cache avoid per-frame alloc. Code:
    `maplibre_flutter_core_metal.{h,mm}`. NOTE: a first cut that waited synchronously on a *separate*
    queue was **slower** than the CPU path — the async + same-queue design is what made it a win.
    This is "true-enough" zero-copy (one GPU blit, no CPU copy); patching mbgl to render straight
    into the IOSurface (no blit) was evaluated and parked — the async blit is cheap and avoids
    forking the submodule.
  - **Continuous render mode (`feat(core)`):** the real fix for fly-to over detailed/uncached tiles.
    A second render-thread main runs an mbgl `RunLoop` with `MapMode::Continuous` +
    `HeadlessFrontend(invalidateOnUpdate=true)` and a `MapObserver::onDidFinishRenderingFrame` that
    publishes each frame (partial → refines as tiles stream in). Commands marshal via
    `RunLoop::invoke`; `destroy` stops the loop. Verified that `present()`+`swap()` (commit +
    waitUntilCompleted) run **before** the observer fires, so the texture is final when we blit.
    **This is the path that went blank twice before** — the prior failures were Continuous driven
    wrong (no proper loop / `invalidateOnUpdate` off / reading partial too early), not Continuous
    itself. Selected per map via `mbl_map_create`'s `continuous` flag; **Static stays the default**
    (headless tests rely on its synchronous complete frame).
  - **Fly-to dip fix (`fix(macos)`):** the eased arc only dips zoom below the lower endpoint when
    fitting the two centers actually needs it (`fit < min(start,target)`) — kills the +/- button
    overshoot while keeping the zoom-out arc for real long flights.
  Both perf paths default **on** (`--dart-define=MAPLIBRE_ZEROCOPY` / `MAPLIBRE_CONTINUOUS` flip to
  the CPU/Static fallbacks for A/B). The macOS-tier work branches were squashed into `main` via
  fast-forward and deleted; `feat/core-distribution` remains the next focus.

- **2026-06-18 — Core distribution: prebuilt artifacts + source fallback + CI (extends the
  2026-06-17 "all nine publishable" decision).** `hook/build.dart` now resolves the native
  library two ways: app consumers (no submodule, the pub.dev archive — `third_party/` is
  `.pubignore`d) **download a prebuilt per-`(os,arch)` binary** from the GitHub release matching
  the package version (`maplibre_flutter_core-v<version>`); developers/CI (submodule vendored)
  **build from the pinned `MBGL_CORE_VERSION` source** via `native_toolchain_cmake`. The branch is
  `if (!vendored) { tryPrebuilt unless MAPLIBRE_FLUTTER_BUILD_FROM_SOURCE=1, else warn } else
  source-build`; both paths end at the same ffigen `@Native` asset id
  (`src/maplibre_flutter_core_bindings_generated.dart`). Local dev is unaffected — the submodule is
  vendored, so it always source-builds. Prebuilt integrity rests on HTTPS to the trusted release
  host; download failure falls back to the warning (FFI fails loudly at call time, never silently
  mis-renders). Asset name `<os>-<arch>-<dylibFileName>` (e.g.
  `macos-arm64-libmaplibre_flutter_core.dylib`) matches what `_tryPrebuilt()` requests. Two CI
  workflows added: **`.github/workflows/ci.yml`** (macOS quality gate — format/analyze/test/
  test:native with `MAPLIBRE_FLUTTER_BUILD_FROM_SOURCE=1` + recursive submodule + ccache cache +
  ffigen-regen `git diff --exit-code`, §7 layer 6) and **`.github/workflows/build-core.yml`** (on
  a `maplibre_flutter_core-v*` tag: cmake-build the dylib for arm64 + x64, upload to the release).
  Linux/Windows arms join both workflows when those platforms land. **Both workflows are committed
  with their automatic triggers commented out — `on:` is `workflow_dispatch` only — so nothing runs
  on GitHub until the cost is reviewed; re-enable by uncommenting the `push`/`pull_request`/`tags`
  blocks (marked DISABLED in each file).** Verified: analyze 10/10; `test:native` source-builds and
  passes (fallback intact). The workflows run only on GitHub (not locally executable).

- **2026-06-18 — Web tier shipped (§8 step 4; on `feat/web-maplibre-gl-js`, off `main`, not yet
  merged).** `maplibre_flutter_web` now renders maplibre-gl-js in an `HtmlElementView`. Built on
  this Mac in parallel with Linux/Windows (which need real hardware) because web is the one
  platform fully buildable **and** runnable here (`flutter run -d chrome`). Decisions made:
  - **Interop = `dart:js_interop` + `package:web` only** (extension types over `JSObject`; no
    `package:js`/`dart:js` — those are discontinued and break under WASM). Three files:
    `maplibre_gl_interop.dart` (extension types for the `maplibregl.Map` ctor + setStyle / jumpTo /
    easeTo / flyTo / getters / resize / remove / on / off), `maplibre_gl_loader.dart`,
    `maplibre_flutter_web_controller.dart`. Only `web: ^1.1.1` added as a dep (`dart:js_interop`,
    `dart:ui_web` ship with the SDK).
  - **Web is the *mobile* tier model, not the desktop tier.** maplibre-gl-js owns
    gestures/inertia natively, so the controller implements `MapLibreMapController` **only** — *not*
    `MapLibreGestureHandler`. The widget's `_DesktopMapGestures` layer was already gated on a
    `MapLibreGestureHandler` controller, so it correctly skips web. No interface change was needed —
    `ElementViewHandle` + the widget branch already existed; the branch just swapped its
    `_UnimplementedEmbed` stub for `HtmlElementView(viewType:)`.
  - **JS map built in the platform-view factory, not in `createMap`.** The host `<div>` doesn't
    exist until the `HtmlElementView` mounts (after `createMap` returns), so the factory builds
    `new maplibregl.Map({container: div, ...})` and `onReady` completes on the JS `'load'` event —
    mirroring how the desktop controllers return before the first frame.
  - **Runtime script/CSS injection is the default** (zero-config DX), with detect-and-skip if a
    consumer pre-loaded the global via `index.html` (the CSP escape hatch). Both existing MapLibre
    Flutter web packages require manual `index.html`; we inject + fall back. The **CSS is mandatory**
    (controls/markers break without it). maplibre-gl-js pinned to exactly **`5.24.0`** (5.x stable;
    6.x is prerelease) in the CDN URLs — a unit test guards it stays `5.x`.
  - **Gotchas captured in code:** `LatLng(lat,lng)` ⇄ maplibre `[lng,lat]` flipped at every
    boundary (#1 bug source); `map.remove()` on dispose (browsers cap ~16 WebGL contexts); the JS
    `'load'` callback is held in a field against GC (§5d); `flyTo` is passed an explicit `duration`
    + `essential: true` so it matches the other tiers' fixed-duration fly-to and animates under
    prefers-reduced-motion; per-map unique `viewType`.
  - **`pointer_interceptor` is for OVERLAYS, not the map.** The map *is* the top DOM element and
    receives pointer/scroll natively; `PointerInterceptor` wraps Flutter controls drawn *over* it
    (the example's FAB column) so their taps don't leak through. Added to the **example** (+
    `integration_test`) deps — *not* the app-facing package.
  - **Tooling:** the web package's tests are `@TestOn('browser')` (the impl imports
    `dart:ui_web`/`js_interop`), so a VM `flutter test` errors with "no tests found". Split the melos
    lanes: **`test` now `ignore`s `maplibre_flutter_web`**; new **`test:web`** runs `flutter test
    --platform chrome`. Added a **`web` job to `ci.yml`** (ubuntu, no submodule: `flutter build web`
    + `test:web` + a headless-Chrome `flutter drive` integration test); the workflow stays DISABLED
    (workflow_dispatch only) like the rest. Verified on this Mac: `melos analyze` clean; `melos run
    test` (VM) + `melos run test:web` (Chrome) + `flutter build web` all green. The **headless-Chrome
    `flutter drive` integration test passes locally** (chromedriver 149 matched to Chrome 149): a
    real maplibre-gl-js map loads a style, jumps the camera and reads it back (exercising the
    `LatLng(lat,lng)` ⇄ `[lng,lat]` round-trip), then swaps styles. Only an interactive
    `flutter run -d chrome` visual frame check is the remaining manual step.
- **2026-06-18 — Linux desktop: OpenGL/EGL core arm + GTK plugin (§8 step 3, part 2; on
  `feat/desktop-linux-gl`, not yet merged).** Added a GL (ES3 + EGL) arm to `maplibre_flutter_core`
  parallel to the macOS Metal arm. Key CMake finding: on non-Apple there's **no bazel/SDK problem**
  (that's Darwin-only), but `CORE_ONLY=OFF` drags in glfw + the unconditional `test`/`benchmark`/
  `render-test` subdirs — so we keep **`CORE_ONLY=ON` on Linux too** (mbgl's root CMake `return()`s
  early) and **hand-attach** the default platform + `gl/headless_backend` + `linux/headless_backend_egl`
  + `gl_functions` + libuv/curl/png/jpeg/webp/ICU, mirroring `linux.cmake`. `cmake/opengl.cmake`
  (included before the `CORE_ONLY return()`, line ~997) compiles the GL renderer. The Metal
  zero-copy code is guarded behind `__APPLE__`; off-Apple `mbl_map_set_zero_copy`/`current_iosurface`
  are no-ops and the CPU `mbl_map_copy_frame` path is used. **Present:** GL has **no public texture
  handle** (unlike Metal's `getMetalTexture()`), so Linux uses a **CPU pixel-buffer**
  `FlPixelBufferTexture` (RGBA — added `mbl_map_set_pixel_format_bgra`, BGRA for macOS); zero-copy
  `FlTextureGL` (shared GL context — the §8 "biggest risk") is deferred. `flyCameraAt` moved to the
  shared platform interface (macOS + Linux + Windows share it).
  - **Mac-side verification via Docker (key enabler):** mbgl's EGL **pbuffer/surfaceless** backend
    runs under **Mesa llvmpipe** in a headless container, so the Linux GL core was built + rendered
    (a correct demotiles PNG, right-side-up, correct colours) **on the macOS dev machine before any
    Linux hardware**. `packages/maplibre_flutter_core/docker/` holds the Dockerfile + run script; a
    CI Linux job can reuse them. Verified: macOS analyze 10/10 + Flutter/native tests green (Metal
    path unchanged); Linux GL core builds + renders in Docker.
  - **NOT yet verified:** the GTK present (`FlPixelBufferTexture`) + interaction on real Linux —
    `flutter run -d linux` is pending hardware. The GTK plugin/controller were written on macOS
    (unbuildable here). Pixel-format/flip confirmed correct via the Docker PNG (the gotchas the
    plan flagged).

- **2026-06-18 — Linux desktop tier verified on real hardware (§8 step 3, Linux).** Set up a
  Razer Blade (Ubuntu 26.04, Intel UHD 630) as the Linux build/test box (Flutter 3.44.2; verified
  26.04 apt deps — note `libstdc++-15-dev` + modern `libgl*/libegl*` Mesa names; recursive
  mbgl-native submodule) and ran `feat/desktop-linux-gl` on it. `flutter build linux --debug` built
  **clean on the first try** (mbgl-core GL/EGL arm + GTK `FlPixelBufferTexture` plugin). The EGL
  headless backend creates a context on the **real Intel iGPU** (not Docker llvmpipe), and the core
  renders **both** demotiles and OpenFreeMap Liberty correctly (proven by compiling `render_harness`
  standalone against the already-built `libmaplibre_flutter_core.so` — no mbgl rebuild). The GUI app
  presents a **smooth** map on GNOME/Wayland (user-confirmed). Two real follow-ups found and being
  worked next on this branch: the curl HTTP source trips HTTP/2 `ENHANCE_YOUR_CALM` under
  Continuous-mode burst (cap `max-concurrent-requests`), and zero-copy `FlTextureGL` (EGLImage blit)
  to replace the CPU pixel-buffer present. Autonomous screenshots on GNOME/Wayland need
  `gnome-screenshot` (the DBus/portal path is locked down).

- **2026-06-19 — Linux HTTP/2 throttle fix + zero-copy via dmabuf (on `feat/desktop-linux-gl`).**
  Two follow-ups from the hardware bring-up:
  - **HTTP fix (`fix(core)`):** the non-Apple core's curl HTTP source multiplexed mbgl's default 20
    concurrent tile requests onto one HTTP/2 connection and tile servers answered with
    `ENHANCE_YOUR_CALM`. Cap the Network `OnlineFileSource`'s `max-concurrent-requests` to 6 (env
    `MAPLIBRE_MAX_CONCURRENT_REQUESTS`) from the render thread after map creation, non-Apple only
    (macOS uses the NSURLSession source). `FileSourceManager::getFileSource` keys the shared source
    by `baseURL|apiKey|cachePath|ctx`, so requesting it with the same `ResourceOptions::Default()`
    the Map uses returns that instance. Verified the cap throttles (cap=1 serializes, ~0.95s vs
    ~0.58s at cap=20) and the map still renders.
  - **Zero-copy via dmabuf, NOT EGLImage (`feat`):** the first cut shared the rendered GL texture
    cross-context with an `EGLImageKHR` (mirroring the macOS IOSurface path). It went **white** on
    device — root cause: **mbgl's render context and Flutter's GTK raster context use different
    EGLDisplays**, and an EGLImage handle is EGLDisplay-scoped, so it can't cross. An adversarial
    design review had flagged exactly this. Fix: share via a **Linux dmabuf** (a kernel fd, not
    display-scoped). The core (`maplibre_flutter_core_gl.cpp`) blits mbgl's color FBO into a ring of
    3 RGBA8 textures and exports each as a dmabuf (`EGL_MESA_image_dma_buf_export`, persistent per
    slot); the GTK plugin imports it into an `FlTextureGL` (`EGL_LINUX_DMA_BUF_EXT`), re-importing
    only on the generation bump a resize triggers. Correctness details the review forced (all in the
    code): the source FBO is taken from mbgl's renderable `bind()` (NOT a guessed
    `GL_DRAW_FRAMEBUFFER_BINDING`), every helper brackets its GL work with save/restore so mbgl's
    `State<>` bind cache stays truthful, the ring is generation-keyed with deferred destroy (dmabuf
    fds aren't refcounted), and a single vertical flip in the blit matches the CPU path. Gated
    **off** by default (`--dart-define=MAPLIBRE_ZEROCOPY=true`); the CPU `FlPixelBufferTexture` path
    is unchanged and the fallback. Runtime-validated on device: zero-copy activates, dmabuf imports
    with **zero** errors (vs the EGLImage flood of "mismatch"), app stable. **On-screen visual A/B
    still pending** (couldn't screenshot the Wayland window non-interactively — `gnome-screenshot`
    blocks on a portal dialog; never call it from an automated shell).

- **2026-06-19 — Linux zero-copy confirmed working on device; white-screen fix + v2 sync + perf
  note.** The dmabuf `FlTextureGL` rendered white on first hardware run. Root cause: the
  `registerTextureGl` method-channel handler ran its EGL probing on the **platform thread, which has
  no current EGL context**, so `eglGetCurrentDisplay()` was `EGL_NO_DISPLAY`, the dmabuf-support
  check failed, and the resulting `PlatformException` (no Dart guard) crashed `createMap()`. Fix
  (commit `88996bd`): all EGL entry-point resolution + dmabuf-support detection happens lazily in the
  first `populate()` (raster thread, context current); the handler only registers; the Dart
  controller guards the channel call and falls back to CPU on failure. **General rule: never call
  EGL/GL on the platform thread in a Flutter Linux plugin — only on the raster thread (populate /
  texture callbacks).** **v2 sync:** the per-frame `glFinish` stall was replaced with `glFlush` +
  the dmabuf's **implicit kernel fence** (the producer's write fence on the buffer's dma_resv; the
  consumer's sample auto-waits cross-context). An EGLSync handle was NOT used — it is EGLDisplay-
  scoped like the EGLImage, so it can't cross the mbgl/Flutter display boundary; the explicit
  fallback (if a driver lacks implicit dma-buf sync) is an `EGL_ANDROID_native_fence_sync` fd passed
  beside the dmabuf fd. **Perf:** A/B on the Intel **iGPU** was ~parity with the CPU
  `FlPixelBufferTexture` path — expected, since unified memory makes the avoided CPU readback a cheap
  same-RAM memcpy, not a PCIe transfer; zero-copy's real win is on discrete GPUs. This box is a
  hybrid-graphics laptop (iGPU + NVIDIA GTX 1070 Mobile, Optimus on-demand); apps default to the
  iGPU and the NVIDIA driver is currently version-mismatched, so the dGPU is untested.

- **2026-06-19 — Rejected "unify the whole stack on one rendering pipeline" (keep mobile SDKs,
  keep maplibre-gl-js on web).** Question raised: now that the desktop core (`mbgl-core` via
  ffigen) is hardened, should we ditch the Android/iOS native SDKs and render mobile ourselves
  off the same core, and/or compile the core to WASM for web — one engine everywhere? Decided
  **no** on both, reaffirming the §3 two-tier split. Rationale:
  - **Feasibility is not the question.** `mbgl-core` is literally the C++ engine both mobile SDKs
    already wrap (MapLibre Native = one core + per-platform frontends), and an Emscripten WASM/
    WebGL2 target for the core exists. So either unification is *possible*; it is not *worth it*.
  - **Mobile — keep the SDKs.** What unification would remove is exactly what the SDK buys, on the
    highest-stakes platforms: native gesture/fling/inertia feel, location component, native
    annotations, accessibility, DPI/lifecycle. Plus it re-opens the GL/Metal-context-+-threading
    risk (the single biggest desktop risk) on two more platforms, and makes us own the CMake/NDK/
    Apple native build matrix for 5 platforms instead of 3. For a project whose pitch is *stability*,
    hand-rolled mobile rendering on the platforms most users run is a trust regression. The
    maintenance pain that motivates unification (three binding toolchains — jnigen/swiftgen/ffigen)
    does **not** justify it: the **public Dart API is already unified** (§3); only the impl behind
    the platform interface diverges. We'd be trading proven feature/quality for impl tidiness.
  - **Web — keep maplibre-gl-js.** Two senses of "web + WASM": (1) the *Flutter app* compiling to
    **dart2wasm** is **already supported** — the web tier deliberately uses `dart:js_interop` +
    `package:web` (WASM-safe; gl-js stays JS, called over interop from either build). (2) Compiling
    *the core* to WASM to replace gl-js = maturity regression (gl-js is the reference web renderer,
    CDN-cached, KBs) for MBs of WASM download + Emscripten threading (SharedArrayBuffer/COOP-COEP),
    GL-context and font/text friction. Not worth it.
  - **The only real unification target is desktop** (macOS + Windows + Linux all on the core) —
    already the plan (§8 step 3), and macOS + Linux already ship on it. Payoff and risk both live
    there; finish **Windows** on the core rather than expanding the core's blast radius to mobile/web.
  - **Escape hatch, not a commitment:** if mobile-SDK maintenance ever dominates, the move is to
    offer core-on-mobile as an **opt-in/experimental** path, A/B it against the SDK, and switch only
    if native feel + integration match — never rip the SDK out up front.
- **2026-06-19 — Windows tier scaffolded on Linux (§8 step 3, Windows; on `feat/desktop-windows-angle`,
  not yet built).** Wrote the whole `maplibre_flutter_windows` tier as the **CPU pixel-buffer analog
  of the Linux tier**, leveraging the just-finished Linux work as the template — without a Windows
  machine, which can only build/run it. The core (`maplibre_flutter_core`) is **unchanged except a
  new `elseif(WIN32)` arm** in `src/CMakeLists.txt` that hand-attaches `platform/windows` +
  `platform/default` sources + the **ANGLE** EGL headless backend (`MLN_WITH_EGL` → vcpkg
  `unofficial::angle::libEGL`/`libGLESv2`), mirroring `platform/windows/windows.cmake` minus the
  glfw/test apps `CORE_ONLY` skips — the C ABI, ffigen bindings, shim, and build hook are already
  cross-platform. The hybrid plugin uses `flutter::TextureRegistrar` + `flutter::PixelBufferTexture`;
  vs the GTK plugin, `MarkTextureFrameAvailable` is thread-safe so the frame callback marks frames
  **directly** from the render thread (no `g_idle_add` hop), and the raster-thread copy callback +
  shared buffer are mutex-guarded. The Dart controller mirrors Linux **minus the zero-copy block**
  (D3D-shared-texture zero-copy is a later step; v1 is CPU pixel-buffer only). No widget change
  (`TextureHandle`). **Verified on Linux:** pub resolves, `flutter analyze` clean, the controller
  unit test passes, and `flutter pub get` correctly regenerated the example's Windows
  `generated_plugin_registrant.cc` to call `MaplibreFlutterWindowsPluginRegisterWithRegistrar`
  (confirming the plugin naming) — that churn is NOT committed (regenerates on Windows, like the iOS
  SPM/Pod churn, §5b). **Needs a Windows machine** for: vcpkg/ANGLE setup (Get-VendorPackages.ps1),
  the MSVC/Ninja core build (hook/build.dart may need a vcvars64 env + the vcpkg toolchain file),
  ANGLE DLL bundling (libEGL/libGLESv2/d3dcompiler_47 next to the .exe), and confirming ANGLE
  windowless headless rendering + the present path. Risks captured in the windows-tier design.

- **2026-06-19 — Windows desktop tier verified on real hardware (§8 step 3, Windows; completes the
  desktop tier).** Set up a fresh Windows 11 box end-to-end (it had none of the toolchain): Flutter
  3.44.2 stable at `C:\src\flutter`; **Visual Studio 2022 Community + "Desktop development with C++"**
  (MSVC 14.44, Win10 SDK 10.0.26100) via winget; **vcpkg at `C:\vcpkg`** (`VCPKG_ROOT` set); Developer
  Mode + system `LongPathsEnabled` (registry, elevated); recursive mbgl-native submodule; melos
  `dart pub global activate`d (its scripts shell out to a bare `melos`, not on PATH on a fresh box).
  `flutter build windows` + the new Windows integration test both green; all 10 packages analyze
  clean and unit tests pass. What the scaffold (written on Linux) got wrong, fixed here:
  - **vcpkg wiring was missing.** `hook/build.dart` now, on Windows, runs `vcpkg install` (idempotent;
    skipped once ANGLE's config exists) and passes `CMAKE_TOOLCHAIN_FILE` + `VCPKG_TARGET_TRIPLET` +
    `VCPKG_MANIFEST_MODE=OFF` via `CMakeBuilder.create(defines: …)`. Key `native_toolchain_cmake`
    0.2.5 facts: on Windows it sets **no** toolchain file (only `-DCMAKE_SYSTEM_NAME=Windows`) and,
    with `useVcvars: true` (default), injects the vcvars64 MSVC env into the Ninja build — so passing
    the vcpkg toolchain via `defines` is free of conflicts. Deps mirror mbgl's `Get-VendorPackages.ps1`
    (`curl dlfcn-win32 libuv libjpeg-turbo libpng libwebp egl opengl-registry`); **`egl` pulls
    `angle`** (which provides `unofficial-angle`); **ICU is the vendored builtin** (not installed).
  - **Custom static triplet** (`src/vcpkg-triplets/`, `VCPKG_LIBRARY_LINKAGE static` + dynamic CRT,
    release-only) → deps link into `maplibre_flutter_core.dll`. **ANGLE built STATIC too** (1.1 GB
    `ANGLE.lib`; the vcpkg `angle` port honors static linkage), so it links into the core DLL (~14 MB
    after dead-strip) and there are **NO ANGLE runtime DLLs to ship** — it calls system d3d11/dxgi/
    d3dcompiler. The plugin's `bundled_libraries` is conditional (bundles libEGL/libGLESv2 only if a
    future dynamic triplet produces them); the hook does NOT register ANGLE DLLs as code assets.
  - **The shim's non-Apple branch referenced the Linux GL zero-copy presenter** (dmabuf), which is
    Linux-only and isn't compiled on Windows → would be a link error. Fix: `maplibre_flutter_core_gl.cpp`
    body is guarded `#if !defined(_WIN32)`, with **no-op presenter stubs** on Windows
    (`mbl_gl_presenter_create()` returns NULL → the shim stays on the CPU `mbl_map_copy_frame` path);
    the file is now compiled on Windows too.
  - **Three CORE_ONLY-on-MSVC gotchas** (mbgl's own `windows.cmake` handles them, but we hand-attach):
    (1) upstream forces MSVC **`/WX`** (warnings-as-errors) UNCONDITIONALLY (not gated on
    `MLN_WITH_WERROR`) → a newer MSVC than upstream's CI fails on new warnings; we append **`/WX-`**
    (last flag wins) to `mbgl-compiler-options` + **`/bigobj`**. (2) `libuv` (static) exports only
    `libuv::uv_a`; the `$<IF:…,libuv::uv_a,libuv::uv>` genex still NAMES `libuv::uv`, and CMake
    validates every `::` target in `target_link_libraries` even in an unselected genex branch →
    resolve with `if(TARGET libuv::uv_a)` instead. (3) the **builtin ICU** path was never exercised
    before (macOS uses Darwin i18n; the Linux box had system ICU): mbgl's stripped vendored ICU has
    **no `unicode/numberformatter.h`**, so `i18n/number_format.cpp` must compile with
    `MBGL_USE_BUILTIN_ICU` — but `set_source_files_properties` is **directory-scoped** and silently
    no-ops for `mbgl-core` (defined in the submodule subdir); define it on the **target**
    (`target_compile_definitions(mbgl-core PRIVATE MBGL_USE_BUILTIN_ICU)`) and add the builtin ICU
    include dir to mbgl-core (collator/bidi need `<unicode/…>`). *(The Linux arm has the same latent
    directory-scope bug; harmless there only because that machine had system ICU.)*
  - **General Windows-plugin facts** confirmed: Flutter on Windows needs **Developer Mode** (plugin
    symlinks) and is happiest with **long paths** enabled; the `dartPluginClass` + `pluginClass` hybrid
    in the pubspec is what makes Flutter build the native plugin (regenerated
    `generated_plugin_registrant.cc` calls `MaplibreFlutterWindowsPluginRegisterWithRegistrar`).
  - **Remaining (optional):** D3D11-shared-texture zero-copy present (parity with macOS IOSurface /
    Linux dmabuf); a visual `flutter run -d windows` frame check (integration test already renders);
    arm64-windows (triplet + path exist, untested); prebuilt-core distribution + a Windows CI arm.

- **2026-06-19 — Windows map was blank: curl's DNS resolver hangs; fixed via OS-resolver +
  CURLOPT_RESOLVE (on `feat/desktop-windows-angle`).** The Windows tier built + the integration
  test passed, but the GUI map rendered **blank** — because the integration test only asserts that
  *a* frame of the right size comes back (`onReady` + camera round-trip), never that the frame has
  map content. Root-caused with the headless `render_harness` (built standalone against the core
  DLL, `-DMAPLIBRE_FLUTTER_BUILD_HARNESS=ON`): mbgl-core itself produced a blank frame, so the
  present path was **not** the bug. Tracing into mbgl's curl http_file_source (temporary `fprintf`
  instrumentation, reverted) showed: requests reach `curl_multi_add_handle`, the timer backs off
  (0→1→…→200 ms) forever, but `handleSocket` is **never called** → curl never opens a socket → zero
  TCP connections, zero errors, blank map. **curl's async DNS resolver never completes under our
  libuv-driven curl multi-socket loop on Windows.** Confirmed it's *only* DNS: pre-seeding the IP
  via `CURLOPT_RESOLVE` made curl connect → TLS (Schannel) → `GET`→`200` → tiles → the harness PNG
  rendered the full world map (1.9 KB blank → 184 KB real). Ruled out (all verified on-device):
  `getaddrinfo` works in-process **and** on a worker thread (curl's exact threaded-resolver
  pattern), IPv6, SSL (curl has Schannel), the CURLSH share handle (shares nothing), `iphlpapi`
  linkage, and our event-loop wiring (run_loop/timer/async/thread sources **match upstream
  windows.cmake** exactly). Tried c-ares (`vcpkg curl[c-ares]`): it integrates with the loop
  (`handleSocket` fires, resolution completes) but **fails to discover the system DNS servers** on
  Windows ("Could not contact DNS servers"; works only with an explicit `CURLOPT_DNS_SERVERS`) — a
  curl-8.20 ↔ c-ares-1.34 sysconfig gap (`nslookup` proves a process *can* send UDP:53 directly, so
  not a firewall).
  - **Fix (primary):** resolve through the **OS resolver** (`getaddrinfo` — always reflects current
    system DNS, handles IPv4/IPv6 + network changes) and pre-seed curl's address cache via
    `CURLOPT_RESOLVE` in mbgl's curl `http_file_source.cpp` (Windows-only `#ifdef`, no-op on
    Linux/macOS), which makes curl skip its own (broken) resolver entirely. mbgl is a **pinned
    vendored submodule with no patch mechanism**, so the change ships as a committed patch
    (`packages/maplibre_flutter_core/patches/windows-dns-os-resolve.patch`) applied **idempotently
    by the build hook** (`_applySubmodulePatches` in `hook/build.dart`: marker-presence check →
    `git apply --ignore-whitespace` → verify marker, fail loud). Validated end-to-end: pristine
    submodule → `flutter build windows` → hook auto-applies the patch → green.
  - **Fix (fallback):** build curl with the **c-ares** feature (`curl[core,non-http,ssl,c-ares]` in
    the build hook's vcpkg install, gated by `share/c-ares/c-ares-config.cmake`, `--recurse`). The
    OS-resolver patch is the working path; c-ares matters only if `getaddrinfo` ever fails — then
    curl falls back to c-ares which **fails fast** instead of the default threaded resolver, which
    would **hang the request slot** (and could jam the file source on a transient DNS hiccup).
  - **Verified on device (user-confirmed):** the map renders and is interactive (fly-to works).
  - **General rule:** an integration test that only checks "a frame came back" does **not** prove
    the map is visible — assert real content (or do a visual/PNG check). The §7 Windows test should
    gain a non-blank-pixel assertion.
  - **Known follow-ups (NOT fixed):** (1) **janky pan/zoom + fly-to** — the CPU pixel-buffer present
    does an ANGLE D3D11 GPU→CPU readback **every frame**, and Continuous mode renders on every map
    update, so the costly readback runs constantly; the real fix is the deferred **D3D11
    shared-texture zero-copy** present (Static mode `--dart-define=MAPLIBRE_CONTINUOUS=false`
    coalesces renders and is a lighter stopgap). (2) **crash on fast movement** — a native
    **0xC0000005 access violation** under rapid rendering (logged `Invalid geometry in line layer`
    just before; no WER dump — HKCU LocalDumps doesn't take, needs HKLM/elevation); not reproducible
    via synthetic SendInput, so it needs a debugger (cdb/WinDbg) on a user-reproduced run to get a
    stack. Both are present-path/stability items, separate from the (now fixed) DNS blank-map bug.

- **2026-06-19 — Windows D3D11 zero-copy present (works, smooth) + fly-to/heavy-move crash
  root-caused to an mbgl GL bug; Vulkan chosen as the fix (next session). On
  `feat/desktop-windows-angle`, committed `1a51d00`.** Two things after the DNS fix above:
  - **Zero-copy present (done, user-confirmed smooth).** The D3D11 analog of macOS IOSurface /
    Linux dmabuf: a new `maplibre_flutter_core_d3d.{h,cpp}` queries ANGLE's `ID3D11Device`
    (`EGL_D3D11_DEVICE_ANGLE`), keeps a ring of 3 **shared D3D11 textures**, wraps each as an ANGLE
    pbuffer (`eglCreatePbufferFromClientBuffer(EGL_D3D_TEXTURE_ANGLE)`), blits mbgl's color FBO into
    the next slot (eglMakeCurrent the pbuffer → glBlitFramebuffer, vertical flip, glFinish for
    cross-device sync since a legacy DXGI shared handle has no keyed mutex), and publishes the slot's
    **legacy `IDXGIResource::GetSharedHandle`**. The Windows plugin presents it as a Flutter
    **`GpuSurfaceTexture`** (`kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`), which ANGLE re-opens on
    Flutter's own device via `EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE` — no CPU readback. The shim's
    non-Apple zero-copy code now branches `#if defined(_WIN32)` (D3D presenter) vs Linux (GL/dmabuf);
    new C API `mbl_map_current_d3d_handle` / `mbl_map_d3d_active`. **Key gotcha: the shared texture
    MUST be `DXGI_FORMAT_B8G8R8A8_UNORM` (BGRA)** — ANGLE's share-handle path only accepts BGRA8;
    RGBA8 → Flutter logs `external_texture_d3d.cc: Binding D3D surface failed` and the map is white.
    glBlitFramebuffer copies by logical channel, so RGBA-source → BGRA-target keeps colours correct.
    Opt-in `--dart-define=MAPLIBRE_ZEROCOPY=true` (CPU `PixelBufferTexture` stays default + fallback);
    if the D3D presenter fails it falls back to CPU. CMake links `unofficial::angle::libEGL/libGLESv2
    + d3d11 + dxgi`, defines `KHRONOS_STATIC` on the shim, and resolves the EGL/GLES headers via
    `find_path` (ANGLE's vcpkg include dir doesn't propagate from mbgl's PRIVATE link). **ffigen
    couldn't run here (no libclang on Windows)**, so the two new bindings were hand-added to
    `maplibre_flutter_core_bindings_generated.dart` in exact ffigen style — **regenerate on macOS
    before merge** (`dart run tool/ffigen.dart`) to confirm no diff (CI §7 layer 6).
  - **Crash on fly-to / heavy movement (NOT fixed; root-caused).** Pre-existing 0xC0000005 access
    violation (happens on the CPU path too). Caught via a temporary unhandled-exception stack dumper
    in the plugin (`MblCrashFilter`, RtlVirtualUnwind + the linker `/MAP`) — these **TEMPORARY
    diagnostics are committed in `1a51d00`; revert them once Windows is stable**. Symbolized stack:
    `gl::DrawableGL::draw → glDrawElements → ANGLE StateManager11::syncVertexBuffersAndInputLayout`
    (AV) under `TileLayerGroupGL::render`. **Root cause = an mbgl GL resource-lifetime bug**: a tile
    drawable's VAO still references vertex buffers freed during rapid tile churn; ANGLE's strict D3D11
    validation derefs the freed buffer (native GL drivers often paper over it). mbgl's
    `indexLength>0 && VAO.isValid()` guard only checks the VAO name, not its buffers' liveness.
  - **Research (delegated; conclusions):** (1) **mbgl bump won't help** — our pin `fa8a9c8e3` is 1
    docs-only commit behind `main`; all buffer fixes (#4291 etc.) already present. (2) **ANGLE update
    low-probability** — the dangling buffer originates on mbgl's side. (3) **Native WGL**
    (`MLN_WITH_OPENGL` without `MLN_WITH_EGL`; mbgl ships `headless_backend_wgl.cpp`) would dodge the
    crash cheaply BUT **kills the D3D11 zero-copy path** (native-GL texture has no D3D11 interop →
    CPU present only) and adds GL-driver fragility. (4) **Vulkan** (`MLN_WITH_VULKAN`) genuinely
    sidesteps the crash (no GL/ANGLE path) **and keeps zero-copy** via `VK_KHR_external_memory_win32`
    → D3D11 shared handle → Flutter's ANGLE surface; it's MapLibre's Android default and in the
    upstream FFI Windows matrix.
  - **DECISION: implement the Vulkan backend for the Windows desktop tier** (next session) — the only
    path that is both stable AND keeps the smooth zero-copy present. Scope: a Vulkan arm in the core
    `src/CMakeLists.txt` (`MLN_WITH_VULKAN`, Vulkan-Headers/loader vcpkg deps, mbgl's
    `vulkan/headless_backend`), a Vulkan→D3D11-shared-texture present helper (replacing the GL blit),
    and the plugin's `GpuSurfaceTexture` path reused. Also worth filing an upstream mbgl issue for the
    `DrawableGL`/VAO-retains-freed-VBO lifetime gap.

- **2026-06-19 — Windows Vulkan backend implemented; the fly-to/heavy-movement crash is FIXED
  (validated on hardware). Zero-copy present is blocked on this Intel iGPU's driver, with a
  graceful CPU fallback. On `feat/desktop-windows-angle`.** Replaced the crashing ANGLE/OpenGL-ES
  core arm with mbgl's **Vulkan** headless backend (the decision recorded in `1a51d00`/`55a3767`).
  - **CMake (core `src/CMakeLists.txt` WIN32 arm):** flip to `MLN_WITH_VULKAN` (OpenGL/EGL/Metal
    OFF — `cmake/validate-backend-options.cmake` requires exactly one backend). The root's
    `cmake/vulkan.cmake` (~line 999) + `vendor/vulkan.cmake` (~1220) auto-attach the Vulkan
    renderer + shaders + glslang/SPIRV/VMA/Vulkan-Headers (both run **before** the CORE_ONLY
    `return()`, self-guarded on the flag), so we hand-attach only the single default-platform
    `platform/default/src/mbgl/vulkan/headless_backend.cpp` + the `vendor/Vulkan-Headers/include`
    path. Dropped ANGLE entirely (`find_package(unofficial-angle)`, the libEGL/libGLESv2 links,
    `KHRONOS_STATIC`); mbgl uses a runtime `vk::detail::DynamicLoader` (loads the driver-shipped
    `vulkan-1.dll`), so there is **nothing new to link or bundle** and the core DLL is ~11 MB
    (vs ~14 MB with static ANGLE). Build-hook vcpkg ports drop `egl`+`opengl-registry` (idempotency
    gate re-keyed off the c-ares + libuv configs). The shim's Vulkan present helper additionally
    needs mbgl's **private `src/`** on its include path (the public Vulkan headers pull
    `src/mbgl/gfx/*.hpp`).
  - **CRASH FIXED + validated on device.** The 0xC0000005 lived in `gl::DrawableGL::draw` /
    `TileLayerGroupGL::render` — GL renderer classes that **do not exist** under Vulkan. Confirmed
    via ~30 rapid fly-to/zoom/style-toggle iterations (~18s of the exact tile-churn that crashed):
    **no crash**, 360+ frames published, top-left pixel changing as the camera moved. The temporary
    crash diagnostics from `1a51d00` (`MblCrashFilter` + dbghelp + the `/MAP` link option) are now
    **reverted** (Windows is stable).
  - **CPU present path is the validated default.** `mbl_map_copy_frame`/`readStillImage` is
    backend-agnostic and works unchanged on Vulkan: the `render_harness` renders demotiles + the
    OpenFreeMap Liberty vector style correctly, and the "Invalid geometry in line layer" warning
    that *preceded* the GL crash now just logs and completes. On an iGPU the readback is a cheap
    unified-memory memcpy. **GOTCHA: GDI screen capture (CopyFromScreen / PrintWindow even with
    PW_RENDERFULLCONTENT) CANNOT capture Flutter's ANGLE/D3D flip-model external texture — it shows
    the map area WHITE even when the map renders correctly** (the prior ANGLE session's screenshots
    show the identical white map area under a working map). Verify rendering via core diagnostics /
    the harness PNG, never a GDI screenshot.
  - **Zero-copy (`maplibre_flutter_core_vk.{h,cpp}`, opt-in `--dart-define=MAPLIBRE_ZEROCOPY=true`):
    written, but BLOCKED on this Intel UHD 630 driver.** The helper LUID-matches mbgl's Vulkan
    device to a DXGI adapter, creates a D3D11 device there, builds a ring of shared D3D11 BGRA
    textures, imports each into Vulkan (`VK_KHR_external_memory_win32`), blits mbgl's
    `getAcquiredImage()` into the slot via `vulkan::Context::submitOneTimeCommand` (which submits
    with a fence and waits — the analog of the GL path's `glFinish`), and publishes the legacy DXGI
    shared handle for the **unchanged** plugin `GpuSurfaceTexture` path. **The conflict:** Flutter's
    consumer (engine `external_texture_d3d.cc` → `EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE`) requires a
    **legacy** shared handle (`GetSharedHandle`, no keyed mutex), but this Intel driver can only
    import the **NT** handle into Vulkan (a `vkGetPhysicalDeviceImageFormatProperties2` probe shows
    `D3D11_TEXTURE` importable, `D3D11_TEXTURE_KMT`/legacy **NOT SUPPORTED**) — mutually exclusive
    for one texture. The helper detects this (`vkGetMemoryWin32HandlePropertiesKHR` returns
    `memoryTypeBits=0`), logs it, and **falls back to CPU**. It should work on discrete NVIDIA/AMD
    GPUs (which typically support the legacy import) — UNTESTED there (this hybrid laptop's NVIDIA
    driver is version-mismatched). A near-zero-copy path on Intel would be NT-import + a GPU-local
    `D3D11::CopyResource` into a legacy texture (deferred). Details in memory
    `windows-vulkan-d3d11-interop`.
  - **mbgl patch** `patches/windows-vulkan-external-memory.patch` (marker `MBL_WIN32_EXTERNAL_MEMORY`,
    applied idempotently by the build hook exactly like the DNS patch): appends
    `VK_KHR_get_physical_device_properties2` to `getInstanceExtensions()` (the 1.0 instance needs it
    for the device-LUID `VkPhysicalDeviceIDProperties` query) and the external-memory device
    extensions in `initDevice()` — **enabled-if-available** (deliberately NOT added to the required
    set used for device *selection*, so a GPU lacking them still initialises and just uses CPU). All
    `#ifdef _WIN32`-guarded and only compiled under the Vulkan backend → inert on the macOS (Metal)
    and Linux (GL) tiers.
  - **No ffigen regen needed:** the C ABI (`maplibre_flutter_core.h`) is unchanged — the present
    helper's `mbl_d3d_presenter_*`→`mbl_vk_presenter_*` rename is internal (not an ffigen input),
    and the public `mbl_map_current_d3d_handle`/`mbl_map_d3d_active` are kept (the output is still a
    D3D shared handle). `maplibre_flutter_core_d3d.{h,cpp}` deleted (replaced by `_vk`). Verified:
    `flutter build windows` green; `melos analyze` (`--fatal-infos`) + `format` green across all 10
    packages.

- **2026-06-20 — Web-via-core (`mbgl-core` → WASM) feasibility validated; scaffolded as an opt-in,
  build-time-flagged experiment that does NOT replace maplibre-gl-js.** Revisits the §3 lock
  (Web = maplibre-gl-js) and the 2026-06-19 "rejected unify-on-one-pipeline" entry — but stays
  **consistent with that entry's explicit escape hatch** (offer core rendering as an opt-in/
  experimental path, A/B it, don't rip the SDK out up front). Motivation: render web through the same
  `mbgl-core` the desktop tier uses, so feature parity is maintained once (in the core C ABI) with no
  separate web SDK to track. **Feasibility = GO.** Deciding fact: our pinned submodule already vendors
  mbgl-core's **WebGPU** backend (`platform/default/.../mbgl/webgpu/headless_backend.{hpp,cpp}`,
  `option(MLN_WITH_WEBGPU)`, `cmake/webgpu.cmake` + Dawn) — selected by the **same backend-flag pattern
  we already ship for the Windows Vulkan tier**; upstream released the WebGPU renderer Oct 2025
  targeting an Emscripten web build, and mbgl-core already runs in browsers via WASM (Qt-for-WASM +
  community `maplibre-native-wasm`). So the web target is "emcmake the existing engine with
  `MLN_WITH_WEBGPU`, present into a `<canvas>`, bind the C ABI to JS" — not a new engine. Best perf =
  WebGPU, with a WebGL2 (`MLN_WITH_OPENGL`) fallback for browser coverage. **Scaffolded this session
  (gl-js untouched and still the default):** build flag `--dart-define=MAPLIBRE_WEB_CORE=true` selects
  `MapLibreCoreWebController` in `MapLibreFlutterWeb` (compile-time const → the unused path
  tree-shakes); new `packages/maplibre_flutter_web/lib/src/core_web/` — `core_wasm_interop.dart` (the
  JS/WASM contract mirroring the C ABI), `core_wasm_loader.dart` (module load, clear error if the
  artifact is missing), `core_web_controller.dart` (the platform controller `MapLibreMapPlatformController`, canvas-hosted;
  gestures owned by the WASM/JS glue, so NO platform-interface or widget change). Full study +
  architecture + phased plan + blockers in **`docs/experimental-web-core-wasm.md`**. **Deferred as
  separate efforts (per the user):** the actual Emscripten build/artifact (the Phase-1 "build spike" —
  needs the emsdk toolchain) and the "full core API" parity expansion. Key open blockers: a
  canvas-targeted backend (the webgpu headless backend is offscreen), COOP/COEP for pthreads (or
  single-thread jank), MBs download size vs gl-js's KBs, and a `fetch`-based file source (no curl under
  WASM). Verified: `flutter analyze packages/maplibre_flutter_web` clean; gl-js default path unchanged.

- **2026-06-20 — Public API reshaped to controller-on-widget + declarative style (§3 "Public API
  shape"; on `feat/controller-on-widget-api`).** Replaced the `onMapCreated`-returns-controller API
  (google_maps_flutter/maplibre_gl style) with the `webview_flutter` split: a user-constructible
  app-facing **`MapLibreMapController`** wraps the per-platform controller. Rationale: the
  controller-passed-to-widget pattern is the more modern, idiomatic Flutter shape
  (`webview_flutter` v4, `VideoPlayerController`, `flutter_map`); pre-publish, so done cleanly with
  no deprecation. Changes:
  - **Interface rename:** the abstract controller `MapLibreMapController` → **`MapLibreMapPlatformController`**
    (platform_interface, the thing `createMap` returns). The name `MapLibreMapController` is now the
    **app-facing wrapper** in `maplibre_flutter` (user constructs it, optional — the widget owns one
    if omitted; forwards camera/query/lifecycle to the bound platform controller; queues nothing,
    just no-ops before attach per the existing "best-effort before onReady" contract).
  - **Two-phase lifecycle preserved:** the widget's FutureBuilder waits on `attach()` (renderHandle
    ready, post-`createMap`) to mount the embed — NOT on `onReady` (first frame) — so the texture/view
    mounts as early as before. `onReady` is forwarded from the platform controller.
  - **Three-bucket property rule (the design principle, now in §3):** init-only → widget
    (`MapOptions.initialCamera`); mutable+declarative → widget prop (`MapLibreMap.style`, pushed via
    `didUpdateWidget`→ platform `setStyle`); mutable+imperative/high-freq → controller (camera/fly).
    **`styleUri` removed from `MapOptions`**; style is now `MapLibreMap.style` (single source of
    truth — **no public `controller.setStyle`**, which would reintroduce the declarative/imperative
    conflict). `createMap` signature is now `({required String style, required MapOptions options})`.
    Camera stays imperative (never declarative — google_maps_flutter does the same; animating a
    camera through `setState` is wrong). **Camera is namespaced under `controller.camera`**
    (`MapLibreCameraController`: `move`/`getPosition` now, 20+ ops planned) rather than flat methods
    on the controller — the sub-manager pattern, chosen because the camera API is large. The
    namespace is a pure app-facing wrapper forwarding to the (flat) platform controller's
    `moveCamera`/`getCamera`, so the platform interface + 6 impls are untouched.
  - **Dispose ownership:** widget disposes only a controller it created; a user-provided controller
    is `detach()`ed (native torn down) on unmount and the owner calls `dispose()`. `didUpdateWidget`
    handles controller-swap (detach/dispose old, attach new) and style-change. Controller widget-glue
    (`attach`/`detach`/`renderHandle`/`gestureHandler`/`setStyle`/`resize`) is **`@internal`** — added
    `meta: ^1.15.0` to `maplibre_flutter` (flutter/foundation doesn't re-export `@internal`; resolved
    to 1.18.0, no workspace conflict). The widget reads `controller.gestureHandler` (the bound
    platform controller iff it's a `MapLibreGestureHandler`) to decide the desktop Dart gesture layer,
    replacing the old `controller is MapLibreGestureHandler` check.
  - **Mechanical ripple, no native/binding changes:** all 6 impls implement the renamed type and take
    `style` as a param instead of reading `options.styleUri`; native render/control logic untouched;
    no ffigen/jnigen/swiftgen regen. Tests: rewrote the widget test (style/options, dispose-vs-detach
    ownership, declarative style→setStyle, gesture-layer branch) + new `maplibre_map_controller_test`
    (pre-attach getCamera default, attach/forward, double-attach + post-dispose-attach throw,
    detach-reuse); integration tests (web/windows) construct a controller and swap style by re-pumping
    with a new `style`. Verified on this Mac: `melos analyze` (`--fatal-infos`) + `test` (VM) +
    `test:web` (Chrome) + `test:native` (source-build) + `format` all green; READMEs updated.

- **2026-06-20 — Experimental core-on-iOS POC (the §3 escape hatch), on `feat/ios-core-poc`.**
  Built a proof of concept that renders iOS via the desktop `mbgl-core` tier (Metal + a Flutter
  `Texture`) instead of the MapLibre Apple SDK, gated behind `--dart-define=MAPLIBRE_EXPERIMENTAL_CORE`
  (default off), to A/B core-vs-SDK on one device before any commitment. This is exactly the
  opt-in/experimental path the 2026-06-19 "rejected unification" decision sanctioned — NOT a default
  change; the SDK + `UiKitView` stays the iOS default. Scoped to **interactive parity with the
  desktop tier** (frame + camera + Dart-stepped fly-to + style swap + pan/zoom gestures).
  - **The Dart/widget/interface needed ZERO change.** `_MapEmbed` already maps `TextureHandle →
    Texture` with no platform guard, so an iOS controller that returns a `TextureHandle` and
    `implements MapLibreGestureHandler` reuses the entire shared desktop Dart tier (gestures, the
    `flyCameraAt` arc, the camera namespace) automatically. New files are a Dart controller
    (`maplibre_flutter_ios_core_controller.dart`, a near-verbatim port of the macOS controller),
    a Swift `MapLibreCoreTexture.swift` (port of macOS `MapLibreTexture.swift`, `FlutterMacOS →
    Flutter`), a texture-registrar handler added to `MaplibreFlutterIosPlugin` beside the UiKitView
    factory (`maplibre_flutter/ios/registrar`; `messenger()`/`textures()` are METHODS on iOS), and a
    `bool.fromEnvironment` branch in `maplibre_flutter_ios.dart` `createMap`. `maplibre_flutter_core`
    is an unconditional dep; the Metal blitter + shim + ffigen bindings port as-is (they are
    Metal/IOSurface/CoreVideo/Foundation only, no AppKit, and `#if defined(__APPLE__)` already covers
    iOS). `sharedDarwinSource` stays banned (§3), so the Swift texture file is a fresh copy.
  - **The only real work was the native build chain — and it's verified at the build level on this
    Mac.** `mbgl-core` now compiles for **iphoneos including `mtl/headless_backend.cpp`**, the shim
    links, and Flutter **auto-wraps the `DynamicLoadingBundled` dylib into a code-signed
    `maplibre_flutter_core.framework`** bundled into the device `.app` (the feared App-Store "no loose
    dylib" issue is handled by Flutter, as the pre-build adversarial review predicted). Verified
    green: `flutter build ios --no-codesign` (device) bundles the core (app 22.9 → 30.3 MB; binary is
    arm64/iOS-device/minos 13); the default `flutter build ios --simulator` (SDK path) still builds;
    `melos analyze` 10/10, `format`, VM `test`, and `test:native` (macOS still renders a non-blank
    frame — the shared `metal.mm` change is safe) all pass.
  - **Four iOS-only deltas found + fixed in `maplibre_flutter_core` (all on the shared Apple arm,
    macOS unaffected):** (1) `if(APPLE)` in `src/CMakeLists.txt` is true for iOS too under
    native_toolchain_cmake's leetal toolchain, so split with `CMAKE_SYSTEM_NAME STREQUAL "iOS"` and
    drop `-framework CoreServices`/`IOKit` + the `platform/macos/src` include (AppKit-tied, unused by
    the headless path). (2) mbgl hard-codes `ghc::filesystem` on iOS (`TARGET_OS_IPHONE` in
    `action_journal_impl.cpp`) vs `std::filesystem` on macOS, so link `mbgl-vendor-filesystem` for iOS
    (as upstream `platform/ios/ios.cmake` does; the target exists in CORE_ONLY). (3)
    `maplibre_flutter_core_metal.mm` used `<IOSurface/IOSurface.h>` (the macOS-only umbrella); iOS
    ships no umbrella, so use `<IOSurface/IOSurfaceRef.h>` (the C API exists on both Darwins, provides
    everything the file uses). (4) `mbgl/mtl.cpp`'s static init references `MTLIOErrorDomain` /
    `MTLTensorDomain`, which exist in the iphoneos Metal SDK but **NOT the iphonesimulator stub**, so
    the dylib can't even link for the simulator.
  - **Gating + the Simulator: it RENDERS on the Simulator too.** The hook builds mbgl-core for every
    iOS target (it can't read the dart-define — on iOS Flutter runs the hook from an Xcode build phase
    with a sanitized environment, so neither dart-defines nor shell env vars reach `hook/build.dart`;
    KNOWN POC LIMITATION: SDK-only iOS builds therefore also bundle mbgl-core, ~7 MB — production fix
    is a separate opt-in package). The Simulator first failed to LINK: mbgl's `mtl.cpp` static init
    references `MTLIOErrorDomain`/`MTLTensorDomain`, which exist in the iphoneos Metal SDK but are
    ABSENT from the iphonesimulator Metal stub, and mbgl links Metal strongly so `-weak_framework Metal`
    can't relax it. Fix: a Simulator-only `maplibre_flutter_core_sim_stubs.mm` that defines those two
    symbols locally (mbgl only captures the constants, never uses MTLIO/tensors for rendering); the
    device SDK exports the real ones (the file is empty under `!TARGET_OS_SIMULATOR`). Wired via a new
    CMake `_apple_is_ios_sim` (`CMAKE_OSX_SYSROOT MATCHES Simulator`).
  - **Verified ON THE SIMULATOR (iPhone 17, iOS 26.4) — the device-gated unknowns are answered.**
    `flutter run -d <sim> --dart-define=MAPLIBRE_EXPERIMENTAL_CORE=true` launches and a `simctl`
    screenshot shows a correct demotiles world map (land/water colours right → BGRA/RGBA swizzle
    correct), no runtime errors. So: mbgl `mtl::HeadlessBackend` **renders a non-blank frame** under
    CORE_ONLY+Metal on the **Apple-Silicon Simulator's real host-GPU Metal**, and
    `CVPixelBufferCreateWithIOSurface` **presents through the iOS external-texture pipeline** — both
    confirmed, not just assumed (and a real device shares the same Metal path). Remaining open item is
    only the native-FEEL A/B: how the shared Dart pan/zoom compares to the SDK's inertia/fling. (§7:
    this was a real-content visual check, not just "a frame came back".) Camera/move/fly-to/style FFI
    is already covered by `test:native`.
  - **Approach was workflow-driven:** a fan-out understanding pass over the macOS/iOS/core/interface
    tiers + an adversarial stress pass on the four riskiest native assumptions (iOS native-asset
    bundling, mbgl iOS CMake, Metal→FlutterTexture present, dart-define gating) front-ran the build
    and called every fix above before the first compile.
  - **On-device-sim verification + two render findings (the iOS controller hardcoded the wrong
    pixelRatio; a residual seam is sim-specific).** Ran the core path on the iPhone-17 Simulator and
    found two things:
    1. **pixelRatio bug (FIXED).** The iOS core controller created the map at `pixelRatio: 1` and
       resized to *device* pixels — but the shim builds the framebuffer as mbgl `Size × pixelRatio`,
       so at pr=1 the map rendered as a low-density 1× map blown up (3× the area, tiny labels) and
       tile/line geometry landed on fractional device pixels. Fixed to pass the **real DPR** (from
       `PlatformDispatcher.instance.implicitView`) + LOGICAL-point sizing (resize/moveBy/scaleBy drop
       the `× DPR`), matching the Apple SDK. User-confirmed on device-sim: map now renders at proper
       retina density and is smooth. (The macOS/Linux/Windows controllers share the pr=1 pattern —
       likely the same latent issue; not yet changed, out of the iOS POC's scope.)
    2. **Residual tile seams were SIMULATOR-ONLY (offscreen Metal) — CONFIRMED CLEAN ON DEVICE.**
       Faint 1-px tile-boundary seams showed on the *sim* (subtle on Liberty, obvious on demotiles'
       solid overzoom fills, zoom-dependent). Bisected exhaustively: the raw mbgl frame on **macOS
       native Metal is clean** at every zoom; **all four iOS present configs** (zero-copy/CPU ×
       Continuous/Static) showed the **identical** seams (so NOT zero-copy, Continuous, or Flutter's
       Texture compositing — `FilterQuality.none` made no difference); and the **iOS SDK** (on-screen
       MLNMapView, same mbgl Metal) was clean at the same view. So the seam was specifically our
       **headless OFFSCREEN Metal render on the iOS Simulator** (macOS native Metal headless = clean,
       iOS on-screen = clean, only iOS-sim offscreen seamed) → a **simulator Metal-translation quirk**.
       **Verified on a physical iPhone 17 Pro Max (iOS 26.5.1): the map renders smooth with NO white
       lines.** So real-device native Metal renders the headless offscreen frame cleanly, like macOS —
       no mbgl `mtl::HeadlessBackend` patch needed. (Seam-detection method during the hunt: a
       brightness-spike detector over `simctl` screenshots — the seams are 1-px hairlines lost to
       viewer downscaling; quantitative column/row profiles caught them.)
  - **Device run surfaced the production blocker the always-build tradeoff implies: duplicate mbgl
    ObjC classes.** With the experimental flag on, the app bundles BOTH `MapLibre.framework` (the SDK,
    still an unconditional iOS dep) and `maplibre_flutter_core.framework` (our mbgl-core) — and since
    the SDK is *built on* mbgl, the runtime logs duplicate-class warnings (`MBGLBundleCanary`,
    `MLNNativeNetworkManager`, …; "may cause spurious casting failures and mysterious crashes"). It
    ran fine here, but this is exactly why production must move the core path to a **separate opt-in
    package** so SDK-path apps never link both — the §3/probe-4 conclusion, now concretely motivated.
  - **NET POC RESULT: SUCCESS.** core-on-iOS renders a real MapLibre map on a physical device —
    smooth, retina, correct — over the desktop mbgl-core tier (Metal → Flutter Texture), gated behind
    `--dart-define=MAPLIBRE_EXPERIMENTAL_CORE` with the Apple SDK still the default. The build→bundle→
    codesign→run chain works on device. The escape hatch is proven viable; remaining before it could
    be more than a POC: a separate opt-in package (duplicate-symbol + binary-size fix) and the native
    gesture-feel A/B vs the SDK (inertia/fling).
  - **pixelRatio fix ported to the desktop controllers (macOS/Linux/Windows had the same latent
    pr=1).** Applied the identical change (create at the real DPR from `PlatformDispatcher.implicitView`
    + logical-point sizing/gestures, drop the per-call `× DPR`) to all three desktop controllers, so
    they render at proper retina density instead of a 1× map blown up. **macOS user-confirmed** (smooth,
    correct element sizes); Linux/Windows are the same mechanical change (iOS device + macOS verified)
    but their run-check needs that hardware. The four core controllers now duplicate this logic — a
    later DRY pass could hoist it into a shared base/mixin.

- **2026-06-20 — Experimental core-on-Android POC (the §3 escape hatch), on `feat/android-core-poc`.**
  Renders Android via the desktop `mbgl-core` tier (OpenGL ES3 + EGL → a Flutter `Texture`) instead of
  the MapLibre Android SDK (`MapView`/`AndroidView`), gated behind
  `--dart-define=MAPLIBRE_EXPERIMENTAL_CORE=true` (default off; the SDK + `AndroidView` stays the default).
  Mirrors the iOS core POC, including the same opt-in/A-B posture the 2026-06-19 "rejected unification"
  decision sanctioned. **Verified on the arm64 Android emulator (Pixel 9 Pro, API 35, Impeller GLES):**
  real demotiles **and** OpenFreeMap Liberty maps render, pan (gesture) + zoom + declarative style-swap
  all work, tiles/glyphs stream over the OkHttp bridge, no crash. The SDK path (flag off) still renders
  with the core `.so` co-bundled — no duplicate-symbol/`UnsatisfiedLink` crash (separate `.so`s, hidden
  visibility; the iOS ObjC-runtime duplicate-class hazard doesn't recur on Android C++).
  - **The Dart/widget/interface needed ZERO change** (same as iOS-core): the new Android core controller
    (`maplibre_flutter_android_core_controller.dart`) is a near-verbatim port of the iOS-core controller —
    `implements MapLibreMapPlatformController, MapLibreGestureHandler`, returns a `TextureHandle`, drives
    `maplibre_flutter_core` over the **existing** ffigen-bound C ABI — so it reuses the whole shared
    desktop Dart tier (gestures, the `flyCameraAt` arc, the camera namespace) with no interface/widget
    edits. A `bool.fromEnvironment` branch in `maplibre_flutter_android.dart` selects it. **No
    ffigen/jnigen regen:** the Dart layer uses the already-bound core API, and the new Android present/HTTP
    C entries are plugin-native-only (never called from Dart). `maplibre_flutter_core: ^0.0.2` is an
    UNCONDITIONAL dep (the `.so` bundles even on SDK-only builds — the known POC cost; the hook can't read
    the dart-define).
  - **Native build chain (`maplibre_flutter_core`): a new `elseif(ANDROID)` arm in `src/CMakeLists.txt`**,
    a near-copy of the Linux GL/EGL arm (same default-platform sources + `gl/headless_backend` + the reused
    `platform/linux/headless_backend_egl.cpp`, which mbgl's own `android.cmake` also reuses). Deltas: the
    NDK ships none of curl/libuv/png/jpeg/webp, so **libuv + libpng are vendored via `FetchContent`** (zlib
    from the NDK), **JPEG+WebP are stubbed** (`maplibre_flutter_core_android_image_stubs.cpp` — raster-only
    formats a vector POC never fetches; libjpeg-turbo also refuses `add_subdirectory`), builtin ICU
    (target-scoped form), and `EGL`/`GLESv3` are NDK system libs. The `_gl.cpp` dmabuf presenter is
    no-op-stubbed on Android (`#if defined(_WIN32) || defined(__ANDROID__)`) so the shim links on the CPU
    path. Gotchas: **minSdk bumped to 26** (mbgl's default `thread.cpp` calls `pthread_getname_np`, bionic
    API 26); **mbgl's root CMake requires CMake ≥3.25** so the Android SDK's bundled 3.22.1 fails — install
    `cmake;3.31.4` via `sdkmanager` (native_toolchain_cmake then prefers it); the `FetchContent` static
    targets (`uv_a`/`png_static`) must be linked on the **shim**, not `mbgl-core` (mbgl `export()`s
    mbgl-core and demands every privately-linked target be in an export set — `png_static` is not). The
    build hook needs NO Android code (native_toolchain_cmake auto-injects the NDK toolchain).
  - **HTTP = a custom `mbgl::HTTPFileSource` bridged to Kotlin OkHttp over JNI** (`*_android_http.cpp`),
    replacing the curl source: the NDK has no curl/TLS and curl+CA-store+async-DNS is the trap Windows hit,
    whereas OkHttp gives the system trust store + TLS for free (how the real Android SDK does HTTP) — but
    decoupled from mbgl's heavy JNI framework. The core stays C-only: a tiny C API
    (`mbl_android_http_set_handler`/`mbl_android_http_respond`, in `maplibre_flutter_core_android.h`, NOT
    ffigen-bound) that the plugin's JNI layer `dlsym`s from the core `.so` and wires to OkHttp. The
    handler is registered (via an `ensureHttpBridge` channel call) BEFORE `mbl_map_create`, because the
    style's first requests fire immediately on the render thread. **THE bug that ate the session: the
    response-delivery `loop->invoke` lambda held the request-registry mutex while calling mbgl's callback,
    and that callback synchronously DELETES the `AsyncRequest` (the curl ref even warns "calling callback
    may delete this"), whose destructor re-locks the same non-recursive mutex → the file-source thread
    deadlocked mid-callback.** Symptom was maximally confusing: OkHttp got the style (200, 77 KB), my
    `deliver alive=1` log fired, but mbgl never applied the style and requested zero tiles → blank map.
    Fix: release the registry lock BEFORE `deliver`. After that, all 8 style/tilejson/tile/glyph requests
    fired and the map rendered. **General rule: never hold a lock across an mbgl `FileSource::Callback` —
    it can re-enter and destroy the request.**
  - **Present = a pure-NDK `ANativeWindow` CPU blit** (`maplibre_flutter_android_jni.cpp`): the core
    renders off-screen; its frame callback (registered via the FFI `setFrameCallback` address passed over
    the registrar channel, like iOS) copies the latest RGBA frame and `ANativeWindow_lock` →
    row-copy-honoring-stride → `unlockAndPost`s it into a Flutter **`SurfaceProducer`** Surface. Chose
    `SurfaceProducer` (`TextureRegistry.createSurfaceProducer()`), NOT the legacy `SurfaceTexture` (broken
    under Impeller). NO EGL window surface and NO new core C ABI for present — the existing `copyFrame` +
    `setFrameCallback` suffice; the function addresses are reinterpret_cast from `jlong` (no dlsym, mirrors
    iOS). The producer Surface is volatile (Impeller backs it with a fixed-size `ImageReader`), so the
    plugin re-registers from `onSurfaceAvailable`/`onSurfaceCleanup` and on resize (the Dart `resize` sends
    a `resizeTexture` channel call with the device-pixel size → `producer.setSize` + rebind). The plugin
    JNI `.cpp` is built by a gradle `externalNativeBuild` CMake block (separate from the core hook) into
    `libmaplibre_flutter_android_jni.so`; both `.so`s bundle into the APK's jniLibs via native-assets.
    pixelRatio is correct (create at the real DPR, logical-point sizing) — labels are crisp, no seams.
  - **NET POC RESULT: SUCCESS.** core-on-Android renders a real, interactive MapLibre map on the emulator
    over the desktop `mbgl-core` tier (GL ES → Flutter `Texture`), gated behind the dart-define with the
    SDK still default. Remaining before more than a POC: a separate opt-in package (the duplicate-mbgl /
    always-bundled-`.so` + binary-size fix, same as iOS), JPEG/WebP for raster styles, the native
    gesture-feel A/B vs the SDK, and a **physical-device** run (only the emulator is verified so far).
  - **Zero-copy present attempted; works on the core side but the emulator's SurfaceProducer won't
    composite it — opt-in, default off.** The CPU `ANativeWindow` blit present (`glReadPixels` every frame)
    stutters, badly on the emulator (its software-translated GL makes the readback very slow). Built the
    proper fix — an EGL window surface from the SurfaceProducer's `ANativeWindow`, blitting mbgl's FBO +
    `eglSwapBuffers` (GPU→GPU, no readback): new `maplibre_flutter_core_android_present.{h,cpp}` + core C
    entries `mbl_map_set_android_window`/`clear`/`android_zero_copy_active` (synchronous, render-thread;
    the plugin `dlsym`s them and gates the CPU frame callback on the flag so only one producer writes the
    window). **Instrumentation proved the core side is correct:** mbgl's user FBO holds the rendered frame
    (sampled a real ocean pixel `216,242,255`), the blit is `glError`-free, and `eglSwapBuffers` succeeds —
    yet **Flutter shows white.** So Flutter's Impeller `SurfaceProducer` does not composite buffers produced
    by a *foreign* EGL window surface on the emulator (the CPU `ANativeWindow_lock/post` path composites
    fine; the producer-side EGL path does not). Two gotchas found en route: (1) try zero-copy BEFORE any CPU
    present — `ANativeWindow_lock` CPU-connects the window and `eglCreateWindowSurface` then fails
    "already connected to another API" (EGL_BAD_ALLOC); (2) the window config must be `EGL_WINDOW_BIT`+RGBA8
    and validated against mbgl's pbuffer-config context via a probe `eglMakeCurrent` (else EGL_BAD_MATCH).
    **Decision: keep zero-copy as opt-in (`--dart-define=MAPLIBRE_ZEROCOPY=true`, default false on Android);
    the CPU present is the default so the app is never white.**
  - **The white is a CONFIRMED emulator limitation, not a code bug — do not keep trying to fix it on an
    emulator.** A web-research pass (flutter/engine source + issues) + exhaustive testing established it: on
    API 29+ `createSurfaceProducer()` returns an **`ImageReaderSurfaceProducer`** (a `HardwareBuffer` /
    `ImageFormat.PRIVATE` consumer), and frame acquisition is automatic via `OnImageAvailableListener` (so
    **`scheduleFrame()` is NOT the trigger** — tried it, still white). The Android emulator's GL drivers can't
    import a **GL-rendered HardwareBuffer produced by a *foreign* EGL context** as a sampled texture (a
    CPU-written buffer is always importable — hence CPU composites, GPU/EGL doesn't); this is a well-documented
    emulator bug (flutter/flutter #149328 blank-on-emulator, #143720 fence-never-signalled, #171992
    near-white). **Everything was tried and ALL render white on the emulator:** the default ImageReader path,
    `producer.scheduleFrame()` (periodic), forcing the legacy SurfaceTexture path
    (`FlutterRenderer.debugForceSurfaceProducerGlTextures = true`), AND both emulator GPU modes
    (`-gpu swiftshader_indirect` AND `-gpu host`). The producer-EGL-surface present is the *standard* path on
    real hardware, so zero-copy needs a **physical device** to validate — there's no emulator workaround.
    (Don't force the SurfaceTexture path in shipping code: it breaks under Impeller-Vulkan; the default
    ImageReader producer is correct for real devices.) For the emulator, the CPU present is the only option;
    its stutter is largely the emulator's slow GL readback (use a hardware-GPU emulator to reduce it).
- **2026-06-20 — Web-via-core WASM: empirical build started; the engine compiles to WebAssembly (on
  `feat/web-core-wasm-poc`).** Acting on the 2026-06-20 feasibility decision, branched off latest main
  (after merging the controller-on-widget API rework and conforming the web scaffold:
  `MapLibreMapController`→`MapLibreMapPlatformController`; `createMap`/`create` now take
  `(style, options)`). Set up the Emscripten toolchain on the Windows box: **emsdk** + a real Python
  (the winget Python is shadowed by the Windows Store `python.exe` execution alias — point
  `EMSDK_PYTHON` at `…\Programs\Python\Python312\python.exe`) + VS2022's bundled cmake/ninja. **Key
  result: `mbgl-core` both configures AND compiles to WASM** with `MLN_WITH_CORE_ONLY` +
  `MLN_WITH_OPENGL` — 435/435 objects, **0 errors** → `libmbgl-core.a` (~17.5 MB) + vendored deps
  (freetype/harfbuzz/…). This contradicts the upstream blocker
  ([maplibre-native#2554](https://github.com/maplibre/maplibre-native/issues/2554), "can't run
  emcmake without errors" — still open/unsolved): our pinned core builds cleanly. Reproducible probe
  at `packages/maplibre_flutter_core/web/probe/` (its `../build/` is git-ignored). **Remaining work =
  the platform layer + glue, NOT the core:** curl→`fetch` HTTP source; libuv→browser `RunLoop` (the
  hard part); pthreads (Emscripten + COOP/COEP); EGL-pbuffer→WebGL2-on-canvas; sqlite/offline stub; a
  web C-shim; and an embind JS module matching `core_wasm_interop.dart`. Realistic effort to a
  rendering PoC: **week(s)** of platform-port work (run loop riskiest) — materially de-risked but not
  finished this pass. Full status + ordered next steps in `docs/experimental-web-core-wasm.md`.
  maplibre-gl-js remains the default; nothing here affects it.

- **2026-06-20 — Web-via-core WASM PoC COMPLETE: mbgl-core renders an interactive map in Flutter web
  (experimental, opt-in; on `feat/web-core-wasm-poc`).** Followed the 2026-06-20 feasibility decision
  through to a working build of the whole platform-layer port. The native MapLibre engine, compiled to
  WebAssembly, **renders + pans a map in the Flutter web example** — verified in headless Edge (crisp
  full-world demotiles map; a scripted drag pans Atlantic→Asia; module read-back showed a fully-painted
  canvas). Solves what upstream maplibre-native#2554 left open. **What was built**
  (`packages/maplibre_flutter_core/src/web/` + `web/`):
  - **Run loop** (`emscripten_run_loop.cpp`): libuv-free `RunLoop`/`AsyncTask`/`Timer`. The main thread
    doesn't block (per-frame `runOnce()` tick via `emscripten_set_main_loop`); **mbgl worker threads**
    (`util::Thread`, e.g. `OnlineFileSource`) block on a condvar and process their queue — the key
    insight, since a futex-blocked pthread can't pump its JS event loop.
  - **HTTP source** (`emscripten_http_file_source.cpp`): **synchronous** `emscripten_fetch` — same
    reason: the file-source worker blocks, so it can't receive an async callback. (Serialises tiles per
    worker; parallelism is a production follow-up.)
  - **GL backend** (`emscripten_gl_backend.cpp`): WebGL2 on the canvas via `emscripten_webgl_*`
    (Emscripten EGL has no pbuffer). Present = blit mbgl's color FBO → the canvas default framebuffer.
  - **embind module** (`maplibre_flutter_core_web.cpp`): `MaplibreFlutterCore` →
    `createMap/setStyle/setCamera/getCamera/resize/moveBy/scaleBy/animateTo/onReady/destroy`. Canvas
    registered via `specialHTMLTargets` (decoupled from DOM-attach), auto-sized to CSS×DPR each frame,
    gestures from raw pointer/wheel events; fly-to eased in the render loop.
  - **Sysroot-gap stubs**: webp-decode, `sched_setscheduler` no-op, `<GLES3/gl3ext.h>` shim.
  - **Build**: standalone `emcmake` (NOT `hook/build.dart`) → `maplibre_flutter_core.js` (~0.5 MB) +
    `.wasm` (~9.4 MB), `-pthread`, served with COOP/COEP. **Dart loader** passes `mainScriptUrlOrBlob`
    (the glue `<script>` is injected dynamically → no `document.currentScript`, else startup hangs at
    `library_fetch_init`).
  - **Gotchas**: `PTHREAD_POOL_SIZE` must be pre-allocated (a synchronous thread spawn from a blocking
    main thread deadlocks otherwise — "thread pool is exhausted"); append `-Wno-error` to
    `mbgl-compiler-options` (Emscripten's newer clang flags warnings upstream's `-Werror` CI doesn't —
    same family as the Windows `/WX-` trick); GDI/SwiftShader caveats moot here (real WebGL via Edge).
  gl-js stays the **default**; the core path is opt-in `--dart-define=MAPLIBRE_WEB_CORE=true`. Full
  how-to-build/run + the production-remaining list (WebGPU backend for perf — already vendored; ~9.4 MB
  download size; COOP/COEP deployment; serial-fetch parallelism; multi-map; artifact distribution) in
  `docs/experimental-web-core-wasm.md`. Verified: web-package `flutter analyze` clean; `flutter build
  web` green; renders + interactive on device (headless Edge).

- **2026-06-20 — Web-via-core WASM: Continuous-mode rendering + resize-flip fix + zero-copy research
  (on `feat/web-core-wasm-poc`).** Finished the PoC's two remaining issues and answered the zero-copy
  question. All in `packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp` (one source
  file; Dart already plumbed the flag). Verified in headless Edge.
  - **Continuous mode (was Static `renderStill`).** `WebMap` now honors the `continuous` createMap
    option (default true, from `--dart-define=MAPLIBRE_CONTINUOUS`): it builds the `HeadlessFrontend`
    with `invalidateOnUpdate=true` and the `Map` with `MapMode::Continuous` + a `WebFrameObserver`
    (`mbgl::MapObserver`) whose `onDidFinishRenderingFrame` presents each finished frame (partial →
    refined as tiles stream in) and fires `onReady` on the first. **Key insight:** mbgl self-drives —
    no per-tick `render()` call. Every map mutation / tile load invalidates the frontend, whose
    `asyncInvalidate` renders off the existing libuv-free RunLoop on the next `globalTick → runOnce()`.
    `tick()` in Continuous mode does only `syncSize()` + `stepAnimation()`; the `rendering_`/`renderStill`
    machinery is bypassed (kept for `continuous=false`). Idle = mbgl stops invalidating (no busy-loop;
    confirmed by a camera-poll settling). Fixes the stutter-under-tile-load the Static path had.
  - **Resize 180°-flip bug FIXED.** Root cause in `present()`: mbgl's `gl::Context` caches the
    framebuffer binding in a write-through `State<>` wrapper and skips redundant `glBindFramebuffer`
    calls; the old `present()` ended with a raw `glBindFramebuffer(GL_FRAMEBUFFER, 0)`, desyncing the
    cache. So mbgl's NEXT `renderable.bind()` was a no-op and it rendered straight into **FBO 0** (the
    canvas) — **upright** — and `present()` early-returned (`srcFbo==0`). That was the (correct-looking)
    steady state. A resize → `HeadlessBackend::setSize → resource.reset()` allocates a **new offscreen
    FBO id**, so the next `bind()` issues a *real* glBindFramebuffer → for one frame mbgl rendered into
    the offscreen FBO, which the old blit **Y-flipped** → one upside-down frame, until the next mutation
    desynced back to FBO 0. **Two-part fix** (mirrors the desktop GL presenter's `GlStateGuard`): blit
    the offscreen color FBO → canvas FBO 0 **1:1 (no flip)**, and **re-bind mbgl's color FBO** before
    returning so the cache stays truthful. The Y-flip was the offscreen→CPU/texture convention (desktop
    readback), **wrong** for offscreen→on-screen-canvas. Now every frame deterministically renders into
    the offscreen FBO and blits upright — verified by screenshotting *immediately after* a resize
    (before any pan): no flip.
  - **Zero-copy on web: already effectively in place; NO work needed; the desktop machinery has no
    analogue.** Desktop zero-copy (IOSurface/dmabuf/D3D11-shared-handle) exists to avoid a GPU→CPU
    readback and bridge a GPU texture into Flutter's **`Texture`/engine texture registrar**. On web
    neither applies: Flutter embeds the map via **`HtmlElementView`** = a real DOM `<canvas>` (child of
    `flt-glass-pane`, slotted) the **browser composites directly** — there is no Flutter `Texture` to
    feed. mbgl (WebGL2) renders into a GPU FBO in the **same** context that owns the canvas; `present()`
    is a single **intra-context GPU blit** (offscreen FBO → canvas FBO 0); `readStillImage` (the only
    CPU readback) is used solely by the desktop `render()` + the test probe, never the live web path.
    The final canvas→screen composite is the browser's (GPU compositing on modern HW); not under our
    control and identical for gl-js. Possible micro-opts (not pursued, negligible): render mbgl directly
    into FBO 0 to drop the one blit (needs a custom GL backend — `HeadlessBackend` always makes an
    offscreen FBO; orientation-safe since direct-to-FBO-0 is upright), or drop `preserveDrawingBuffer`.
    **The real web perf lever is the vendored WebGPU backend, not zero-copy.**
  - **No Dart/interface/binding changes** (the JS API is unchanged); `flutter analyze` of the web
    package stays clean. Build/verify recap unchanged (emsdk + real Python + VS2022 cmake/ninja →
    `emcmake` the `maplibre_flutter_core_wasm` target → deploy `.js`/`.wasm` → serve COOP/COEP →
    headless Edge + `cdp_*.py`). **Headless caveat:** a passive fly-to freezes mid-flight because
    headless `requestAnimationFrame` goes idle without a compositor/input (`stepAnimation` runs off
    rAF); it is NOT a bug — a real browser runs rAF at 60fps, and an rAF-kept-alive page
    (`anim_test.html`) confirmed `animateTo` eases smoothly to the exact target and settles.
  - **Follow-up (same session) — style-switch thread-pool exhaustion FIXED + fly-to zoom-out arc
    added.** On-device testing surfaced two more issues:
    - **"Broke after switching tiles" = WASM pthread-pool exhaustion.** Switching to a heavy style
      (OpenFreeMap Liberty) hit *"Tried to spawn a new thread, but the thread pool is exhausted"* +
      *"Blocking on the main thread is very dangerous"* (deadlock risk → broken render). Root cause:
      `PTHREAD_POOL_SIZE`=32, and the original `emscripten_http_file_source.cpp` spawned **one pthread
      per request** while mbgl dispatches up to `DEFAULT_MAXIMUM_CONCURRENT_REQUESTS`=20 at once — so
      Liberty's tile/glyph/sprite burst + mbgl's other threads (background pool=4, file-source/
      sequenced/db ~5, main) hit ~32. Fix: a **bounded fetch-thread pool** (8 long-lived workers
      pulling a queue) replacing thread-per-request — fetch concurrency is capped regardless of the
      burst, excess requests queue. Verified in headless Edge: Demotiles ⇄ Liberty switches with no
      "pool exhausted", Liberty renders a correct labelled world map and switches back cleanly. (A
      benign one-time `Blocking on the main thread` from mbgl's old-style teardown can still log; the
      map renders through it.) **Caching gotcha during verify:** a warm browser profile served the
      cached pre-fix `.wasm` despite `Cache-Control: no-store`; relaunch headless Edge with a fresh
      `--user-data-dir` to load a rebuilt module.
    - **Fly-to "zoom-back" arc.** Web `animateTo` did a straight zoom lerp, so London z10 → Tokyo z10
      flew across the world at z10. Added a zoom-out arc (in `stepAnimation`): compute the zoom that
      fits both endpoints (`fitZoom` from angular span vs CSS viewport width) and dip toward it at the
      time-midpoint via `sin(πt)`, **only when it's below both endpoints** (so +/- buttons / short
      hops don't overshoot — mirrors the macOS fly-to dip fix). Verified: London→Tokyo dips to z≈1.8
      mid-flight then back to z10. Both fixes are in the two web files only (no Dart/interface change).
    - **Resize white-blink FIXED.** Resizing blinked white because the resize path set
      `canvas.width/height` (which clears the WebGL drawing buffer → white page shows through) in one
      animation frame, but rendered+blitted the new size only on the *next* frame, so the compositor
      saw the cleared canvas in between. Fix: move the canvas backing-store resize **into `present()`,
      right before the blit** (guarded by `canvasW_/canvasH_`), so clear+repaint are in the same rAF
      turn — the compositor never sees a cleared canvas. **User-confirmed on real hardware: no blink.**
      Verify note: headless can't measure this — `drawImage` WebGL readback returns spurious transparent
      frames under SwiftShader (a *static* map showed false blanks), and `Page.startScreencast`
      coalesces the transient; the compositor screencast showed no white. **Resize "skew"/stretch FIXED via
      `ResizeObserver`.** After the blink fix, a ~1-frame stretch remained (prev frame CSS-scaled to
      the new size before the new-size frame renders) because the engine's per-tick `syncSize` *poll*
      notices Flutter's CSS-box change a frame late. A synchronous render in the resize turn was
      **tried and reverted** (detection is the frame-late part, not detect→render; extra render made it
      worse). Fix (as gl-js does): a JS `ResizeObserver` on the canvas (in `core_web_controller.dart`)
      whose callback — fired after layout, before paint — calls a new `resizeSync` embind method
      (`resize()` + one `runOnce()` → render+present in the same callback), so the correct-size frame
      composits in the same paint (zero lag). First `resizeSync` flips the engine's `autoSize_` off so
      the laggy poll stops (no double-driving). **User-confirmed: resize is now smooth.** This change
      touches Dart too (interop `resizeSync` + the observer wiring + dispose `disconnect()`), so it
      needs a `flutter build web` (not just the wasm rebuild). Edge case left: a pure DPR change with
      no CSS resize won't trigger the observer (rare).
    - **Verified end-to-end on real hardware** (user, in-browser): continuous render is smooth,
      resize no longer blinks, Demotiles⇄Liberty switches cleanly, fly-to arcs out and back.
    - **Map "stuck"/blank on a REAL GPU FIXED — present() must `glFlush`.** A later A/B (native vs
      gl-js, real GPU) surfaced: the map intermittently stopped *displaying* (pans registered but not
      drawn; a window resize made it jump to the correct position), and switching to Liberty went
      blank. The engine was fine — a canvas pixel read-back showed the canvas *had* the rendered map
      (~16k colours for Liberty), and both the standalone engine and the **headless** Flutter app
      (ANGLE→SwiftShader) rendered Liberty correctly; it only broke in the **Flutter app on a real
      GPU** (ANGLE→D3D11, Edge/Windows). Root cause: `present()` blitted (offscreen FBO → canvas) but
      never flushed, so on ANGLE/D3D11 the blit could sit unsubmitted at the end of the rAF callback
      and the browser composited a **stale** canvas. A resize "fixed" it only because `resizeSync`
      does an explicit `runOnce()` + `canvas.width` change (forces flush+recomposite). Fix:
      **`glFlush()` after the blit** in `present()` (non-blocking, cheap per frame) so the compositor
      always gets the latest frame; also wrapped `globalTick` in **try/catch** so an uncaught
      exception can't stop rAF. Found via a temporary heartbeat (tick/present counters) that showed
      the loop kept firing while "stuck" → a composite problem, not a dead loop. **User-confirmed:
      cannot reproduce the stuck or the Liberty blank after the fix.** **General rule:** on web, after
      blitting to the canvas in an rAF callback, `glFlush()` — don't assume the implicit
      pre-composite flush submits a `glBlitFramebuffer`, especially under ANGLE/D3D11 with a second
      WebGL context (Flutter's CanvasKit) on the page.

- **2026-06-21 — Windows/Linux trackpad pinch-zoom drifted from the cursor; root cause was the
  PINCH gesture path (focal-centroid drift), NOT the present/texture mapping (on `main`, commit
  `55ee9d4`).** Long-standing "scroll/pinch zoom does not follow the cursor on Windows" bug, fixed.
  - **The prior diagnosis was wrong and cost time.** It had concluded the bug was "below Dart — in
    the Windows native present/texture mapping (Vulkan arm)." This session disproved that with
    deterministic measurements: (1) driving the platform controller's `scaleBy` with known anchors
    moves the camera *toward* the anchor correctly in all 4 directions + center; (2) a real
    mouse-wheel `PointerScrollEvent` through the full widget stack does the same; (3) a dumped
    world-map PNG from the core readback is north-up/east-right (not mirrored/flipped) and a
    zoom-about-the-NE-corner correctly anchors NE; (4) the Windows plugin presents the RGBA frame
    1:1, and on this Intel box the displayed texture *is* that CPU readback. So the controller,
    core, mbgl math, DPR handling, and present were all correct — the mouse-wheel zoom was never
    broken.
  - **Real root cause: the user zooms with a TRACKPAD PINCH, a different code path.** Wheel zoom
    goes through `_DesktopMapGestures._onPointerSignal`; a pinch goes through `_onScaleUpdate`
    (`GestureDetector.onScaleUpdate`). On Windows/Linux a trackpad pinch arrives as a two-finger
    *scale gesture* whose focal **centroid drifts** as the fingers spread — live logging showed the
    focal slide ~90px left and ~130px up (off-screen) during one pinch while `scale` went 1.0→1.74.
    macOS instead reports the **stable cursor** as the focal (its magnify gesture), which is why
    macOS worked. `_onScaleUpdate` faithfully (a) `moveBy`'d the focal delta and (b) `scaleBy`'d
    about the *live, drifting* focal, so the map slid away from the cursor while zooming. (Same
    "janky pan/zoom" family flagged in the 2026-06-19 Windows entries, but the *anchor* wrongness —
    not just frame rate — was the focal drift.)
  - **Fix (`maplibre_flutter/lib/src/maplibre_map.dart`):** freeze the zoom anchor (`_zoomAnchor`)
    at pinch onset and stop panning from focal drift while `zooming`; only pan + track the anchor on
    non-zoom frames. Mathematically: a combined pan+zoom must be EITHER (live focal + compensating
    `moveBy`) OR (frozen anchor + no `moveBy`) — the old code did the former with a noisy focal; the
    fix does the latter, which is stable. No-op on macOS (focal doesn't drift, so frozen ≈ live and
    the during-zoom `moveBy` was already ~0); two-finger pan + inertia unchanged (the `!zooming`
    path). Guarded by a **device-free widget regression test** in `maplibre_map_test.dart`: a
    synthetic drifting-centroid two-finger pinch through the real widget asserts every `scaleBy`
    uses one frozen anchor (near the start, not the drifted end) and no pan is applied — runs in
    plain `melos test`, no hardware.
  - **LESSON: the input device matters — confirm HOW the user reproduces before diagnosing.**
    "Zoom doesn't follow the cursor" had a completely different cause for trackpad-pinch vs
    mouse-wheel; the wheel path was a red herring the prior session verified "correct" and then
    wrongly extrapolated to "must be the present." Diagnose the *actual* gesture path
    (`_onScaleUpdate` vs `_onPointerSignal`), and for a "displayed content looks wrong" report,
    verify the rendered pixels directly (a PNG/visual check) rather than reasoning from "pan works."
  - **Aside:** `flutter build windows --release` failed once at the CMake `INSTALL.vcxproj` step
    this session (debug builds fine throughout) — looked transient (a stale-artifact / running-app
    file lock), not investigated; flag if it recurs.

- **2026-06-21 — Windows pinch-zoom regressed by a blind-ported Linux anchor flip; reverted to
  pass-through (on `main`, commit `43d2992`).** The Linux desktop-gesture fix (`1963302`) added a
  Y-flip to the **Windows** controller's `scaleBy` (`_coreMap.scaleBy(scale, anchorX, _renderHeight
  - anchorY)`) "because Windows shares the same core present path" — but it was **never
  HW-verified on Windows** and contradicted its own commit message (which said Windows "gets the
  matching raw-anchor scaleBy", yet the diff applied a *flipped* anchor). On hardware it mirrored
  the anchor vertically: a top-of-widget trackpad pinch zoomed about the bottom ("zooms to random
  positions"). **Root cause confirmed by an adversarial-verify workflow** (git history + both
  present paths + the Dart anchor-source change): the desktop present-path blit (Windows Vulkan
  `blitImage` `maplibre_flutter_core_vk.cpp:420`; Linux GL `glBlitFramebuffer` dst-Y inverted
  `maplibre_flutter_core_gl.cpp:305`) flips only the **pixel buffer** (mbgl's bottom-up framebuffer
  → the top-down texture/CPU-readback convention); it does **NOT** change mbgl's top-left
  `ScreenCoordinate` anchor space, which already matches Flutter's top-left gesture coords. The core
  C ABI (`mbl_map_scale_by` → `mbgl::ScreenCoordinate{x,y}`) applies **no internal anchor
  transform**, identically on all desktop platforms — so the anchor convention is **pass-through,
  no flip**, the same value the **hardware-verified Linux** controller uses (and the pre-`1963302`
  Windows state at `55ee9d4`). Fix: revert Windows `scaleBy` to `anchorX, anchorY`. **Only that one
  file changed** — Linux controller and the shared `maplibre_map.dart` gesture layer (the
  `_lastPointerPos` anchor-source change, which is sound and orthogonal to the flip) are untouched,
  so Linux's HW-verified behaviour is unaffected. User-confirmed on Windows hardware: trackpad pinch
  now zooms on the cursor. **LESSON: never blind-port one platform's controller change to a sibling
  citing a shared core — HW-verify it there, or leave it on the proven convention. "Verified on
  Linux = pass-through" must be copied as pass-through, not transformed into a flip.**

- **2026-06-21 — Core-primary inversion: mbgl-core is now the DEFAULT renderer on every
  platform; the native SDKs + maplibre-gl-js are opt-in, build-time-excluded packages (§3 "One
  engine, optional native renderers"). On `feat/core-primary-inversion`.** Reverses the §3
  two-tier lock and the 2026-06-19 "keep mobile SDKs" decision (core-on-mobile was an opt-in
  escape hatch there); extends the 2026-06-19 desktop-only unification to mobile + web. The
  escape-hatch posture flips: **core is the default everywhere, the SDK/gl-js is the escape
  hatch.** Rationale: one engine = feature parity maintained once; the duplicate-mbgl-symbol iOS
  blocker is eliminated; and the SDK/gl-js no longer bloat the default build.
  - **Why a `--dart-define` can't do it:** the `MAPLIBRE_EXPERIMENTAL_CORE` / `MAPLIBRE_WEB_CORE`
    consts only tree-shook the **Dart** branch; the build hook / Gradle / podspec / Package.swift
    never see a dart-define, so both renderers' **native** code always shipped (iOS bundled BOTH
    `MapLibre.framework` + `maplibre_flutter_core.framework` → duplicate mbgl symbols). The only
    mechanism that build-time-excludes the unselected renderer is **package separation
    (federation)** — the choice is "which package is in pubspec," not a flag.
  - **Structure (10 → 13 packages):** `maplibre_flutter_{android,ios}` are now **core-only**
    (always return a `TextureHandle`; the dart-define is gone). The SDK paths moved to new opt-in
    **`maplibre_flutter_android_sdk`** (jnigen, `AndroidView`) and **`maplibre_flutter_ios_sdk`**
    (swiftgen, `UiKitView`). `maplibre_flutter_web` is now **core-WASM-only**; gl-js moved to
    **`maplibre_flutter_web_gljs`**. An app adds an `_sdk`/`_gljs` package to **override** the
    endorsed core default for that platform (a direct dep beats `default_package`); absent, that
    renderer's native code never ships. `maplibre_flutter`'s endorsement `default_package` names
    are **unchanged** (they point at the now-core packages), so federation needed no edit.
  - **iOS duplicate-symbol blocker FIXED:** `maplibre_flutter_ios`'s `Package.swift` + podspec no
    longer depend on the MapLibre Apple SDK (only the Metal/IOSurface texture bridge remains), so
    the core build doesn't link mbgl twice. **Verified:** the default `flutter build ios
    --simulator` app bundle contains `maplibre_flutter_core.framework` + `maplibre_flutter_ios.framework`
    but **no `MapLibre.framework`**, with **zero** duplicate-class warnings.
  - **Android SDK excluded from the default build — verified:** the default `flutter build apk`
    bundles `libmaplibre_flutter_core.so` + `libmaplibre_flutter_android_jni.so` and **no MapLibre
    Android SDK `.so`**. The core package dropped `jni`/`jnigen` + the `org.maplibre.gl:android-sdk`
    gradle dep; the SDK package lowers `minSdk` 26→21 (no mbgl-core there).
  - **Binding-regen avoidance (no Android/iOS toolchain regen needed for correctness):** the moved
    Android Kotlin/Java keep their original `dev.maplibreflutter.maplibre_flutter_android` **source
    package** (only the new gradle `namespace` differs), so the committed jnigen bindings stay
    valid. The moved iOS swiftgen module is renamed to `maplibre_flutter_ios_sdk` (SPM target = pod
    = module = package name, §5b), so the bindings' two module-qualified `objc.getClass(...)`
    lookups point at `maplibre_flutter_ios_sdk.*` — **regenerated via `dart run tool/swiftgen.dart`
    and confirmed byte-identical to the committed file** (the regen needs only the Xcode iphoneos
    SDK via `xcrun`; no device).
  - **Zero-copy is now default-ON everywhere supported:** flipped Linux (dmabuf) + Windows (D3D11)
    `MAPLIBRE_ZEROCOPY` false→true; macOS/iOS/Android-core were already on. All paths probe the
    native presenter and fall back to CPU automatically, so unsupported drivers still render.
    Disable with `--dart-define=MAPLIBRE_ZEROCOPY=false`.
  - **A/B ergonomics + the iOS caveat:** A/B is now "add the `_sdk`/`_gljs` dependency + rebuild,"
    not a dart-define. Because the iOS core default and the SDK package both build on mbgl, an A/B
    build that pulls *both* must drop the core iOS package via `dependency_overrides` (or a
    dedicated example flavor) to avoid duplicate symbols; the published core default is clean.
  - **Verified:** `melos analyze` green across all 13 packages; `melos test:web` (both web pkgs,
    headless Chrome) + `flutter build web` green; `flutter build apk --debug` + `flutter build ios
    --simulator` green with the SDK frameworks/`.so` correctly absent. The plan lives in
    `docs/core-primary-inversion-plan.md`.
  - **Remaining (follow-ups, not blockers):** the Web WASM artifact productionization (asset bundling + COOP/COEP serve config +
    single-thread fallback + a CI emscripten job) before web is publish-ready; a CI matrix that
    builds the example both core-default and with each `_sdk`/`_gljs` override; and the
    native-feel A/B (gesture inertia/fling) vs the SDKs before tagging a `stable` release.

- **2026-06-29 — Glued widget markers (anchor Flutter widgets to LatLng): projection in the
  shim + a Flow overlay, macOS-first.** New feature: place real,
  interactive Flutter widgets locked to a geographic point on the map (`MapLibreMap(markers: […])`),
  smooth through pan/zoom/rotate/pitch/fly-to/inertia, plus tap→LatLng and draggable markers.
  Scoped (per the user) to a full vertical slice verified on **macOS**; the other tiers are a small
  per-controller addition next. **No mbgl submodule patch** — mbgl already exposes the projection
  we need; everything new lives in our own shim/Dart.
  - **Projection lives in the engine, exposed synchronously (the key enabler).** mbgl's pinned
    `Map` has `pixelForLatLng`/`pixelsForLatLngs`/`latLngForPixel` and `getTransfromState()`
    (mbgl's real spelling — note the typo) returning a copyable `mbgl::TransformState`. The shim
    snapshots a **copy** of that TransformState on the render thread after every camera/size change
    (`updateProjState`, called from `set_camera`/`move_by`/`scale_by`/`resize`), guarded by a
    dedicated `projMutex` + a `projGeneration` counter. New C ABI
    (`mbl_map_pixel_for_lat_lng`/`mbl_map_pixels_for_lat_lngs` (batch, returns generation)/
    `mbl_map_lat_lng_for_pixel`/`mbl_map_proj_generation`) copies the snapshot out under the lock,
    releases it, and runs **pure projection math on the thread-confined copy** — so projection is
    cheap, lock-free of the render thread, callable from Flutter's UI thread every frame, and exact
    for bearing/pitch (`latLngToScreenCoordinate(latLng, vec4&)`; `clip[3] > 0` ⇒ in front of the
    camera = visible). Screen space is **logical points, top-left origin** = the gesture/anchor
    space = Flutter's widget box (confirmed against the controllers' post-2026-06-20 logical-point
    sizing), so the overlay needs no DPR conversion. **Gotcha:** `mbgl::LatLng`'s ctor THROWS
    `std::domain_error` on NaN/inf/|lat|>90; a throw across the `extern "C"` boundary is UB, so the
    projection functions sanitize (reject non-finite, clamp lat) before constructing a LatLng. The
    shim now needs mbgl's private `src/` on its include path on every platform (for
    `transform_state.hpp`) — added unconditionally in `src/CMakeLists.txt` (Windows already had it).
  - **Per-frame camera tick to Dart.** New additive platform-interface capability
    `MapLibreMapProjector implements Listenable` (`project`/`unproject`) + a reusable
    `MapLibreCameraTickNotifier` mixin (owns a private `ChangeNotifier`, since the controllers'
    `dispose()` is async and would clash with `ChangeNotifier.dispose`). The macOS controller mixes
    it in and calls `notifyCameraChanged()` at the **existing Dart camera choke points**
    (`_applyCamera`/`moveBy`/`scaleBy`) — so one call per choke point covers gestures, the
    Dart-stepped fly-to loop, the inertia ticker, and imperative moves — plus on first-frame ready
    and on resize so the overlay reprojects from off-screen to its real position. Feature-detected
    with `is` (like `MapLibreGestureHandler`); a controller without it simply renders no overlay.
  - **`Flow` is the overlay primitive.** `MarkerOverlay` (in `maplibre_flutter`) uses a
    `FlowDelegate(repaint: projector)`: it reprojects all markers in **one batch call** and
    re-positions children via paint-time transforms on each camera tick — **no relayout, no widget
    rebuild** (a regression test asserts the child isn't rebuilt) — and `Flow` hit-tests children at
    their painted positions, so a marker's own `GestureDetector` works and empty space falls through
    to the map's gesture layer. `getConstraintsForChild` is loosened (the default forces children to
    fill the map). Markers behind a pitched camera / pre-first-frame are parked off-screen via the
    `visible` flag. A dragged marker is positioned by the **live pointer** (overlay space), not its
    declarative `point`, so it follows the finger and never double-moves even when the app also
    updates `point` from the drag callbacks.
  - **Public API (three-bucket rule):** markers are mutable+declarative → a widget prop
    `MapLibreMap(markers: List<MapLibreMarker>, onTap: ValueChanged<LatLng>)`; `MapLibreMarker`
    (`point`/`child`/`alignment`/`draggable`/`onDrag*`) is exported from `maplibre_flutter`. No
    `controller.setMarkers` (same single-source-of-truth model as `style`). `_MapEmbed` wraps the
    embed in a `Stack` (map below, overlay on top) only when a projector exists; map taps go through
    a `GestureDetector(onTapUp)` that unprojects (marker taps win by hit-test order). Threads through
    with **zero platform-interface controller changes** beyond the additive projector capability.
  - **Tests:** native ctest-style FFI tests (centre↔viewport-centre, screen↔LatLng round-trip incl.
    bearing+pitch, batch==single, generation bump); widget tests with a mocked projector (placement
    + alignment, reproject-without-rebuild, marker-tap-vs-map-tap, tap→unproject, draggable end
    point, no-projector graceful); a platform-interface test for the tick mixin.
  - **NOT yet built/verified — no Dart/Flutter toolchain or mbgl submodule in this remote env.**
    All code is written to the established conventions but unbuilt here. **Before merge, on macOS:**
    (1) `dart run tool/ffigen.dart` to regenerate `maplibre_flutter_core_bindings_generated.dart` —
    the 4 new bindings were hand-added in ffigen style (same as the 2026-06-19 Windows session) and
    must be confirmed byte-identical (CI §7.6 diff check); (2) `melos run test:native` (projection
    math); (3) `melos analyze`/`test`/`format`; (4) `flutter run -d macos` to confirm markers stay
    glued through drag/zoom/pinch/fly-to/inertia, taps fire, dragging drops at the right LatLng, and
    map-tap reports a sensible LatLng. **Follow-ups:** add the projector to the Linux/Windows/
    iOS-core/Android-core controllers (≈10 lines each) + web (gl-js `map.project`, wasm-core embind);
    temporal-swim correlation via `projGeneration`/presented-frame on slow-present tiers if needed.

- **2026-07-29 — Two-tier map annotations: widget markers + engine-drawn layers (on
  `feat/glued-widget-markers`).** Started from a bundled commit that glued interactive Flutter
  widgets to LatLng points (macOS-first, written in a container with no toolchain, so never
  built). Verified it, fixed two projection defects, made it fast, then added the scalable
  second tier. **The settled architecture is a HYBRID, and it matches what every MapLibre SDK
  does:**
  - **Widget markers** (`MapLibreMap.markers`) — real Flutter widgets glued to a point: gestures,
    animation, arbitrary content. **Measured ceiling ≈500 rich markers smooth in release on
    macOS**; each costs a render object painted every camera tick. This is maplibre-gl-js's DOM
    `Marker` / the mobile SDKs' view annotations.
  - **Engine layers** (`controller.layers`) — points in the STYLE, drawn by mbgl with the map:
    glued by construction, GPU-scaled to 100k+, clustering built in. Pictures, not widgets — no
    child gestures, no per-marker animation. This is what the SDKs' bulk annotation APIs are
    actually built on.
  - **Bridge:** `layers.addWidgetIcon()` paints a Flutter widget off-screen
    (`RenderObjectToWidgetAdapter` + a throwaway `RenderRepaintBoundary`, one layout/paint pass)
    and registers the RGBA as a style image, so **bulk points are styled with Flutter widgets
    rather than asset sprites**. The icon is a snapshot — that is the tradeoff.
  - **Style API takes MapLibre Style Spec JSON, not typed setters.** mbgl's `convertJSON<T>`
    (via the private `src/mbgl/style/conversion/json.hpp`, already on the shim's include path)
    buys the whole spec — expressions, filters, data-driven styling, cluster options — for seven
    C functions instead of hundreds of property accessors. **Clustering therefore needed no code
    of its own:** `"cluster": true` on a geojson source runs supercluster inside the engine.
    Parsing runs synchronously on the calling thread (it needs no map) so bad JSON throws
    immediately; only the mutation is posted to the render thread. **TODO(typed-style-api):** a
    typed Dart layer/source API over the JSON is the agreed end goal, deliberately out of PoC scope.
  - **Y-AXIS BUG (would have shipped):** `TransformState::latLngToScreenCoordinate` returns a
    **bottom-up** y — its internal `size.height - y` converts *into* GL's convention, not out of
    it — and `screenCoordinateToLatLng` expects the same. The shim passed both through while
    documenting them as top-left, so markers tracked correctly left/right and **inverted
    vertically**. **Every existing projection test was blind to it**: a round-trip cancels a
    symmetric flip and the camera centre is symmetric. **Rule: test projections against absolute
    directions (north is up), never only round-trips.**
  - **MARKERS LAGGED THE MAP — a synchronisation gap, not throughput.** Camera commands are
    posted to the render thread and applied there, so the newest transform runs *ahead* of the
    frame the compositor shows; projecting against it makes anchored widgets swim. Fix: the core
    keeps a ring of 8 transforms keyed by generation, tags each published frame with the
    generation it was drawn with, and `mbl_map_presented_generation()` lets callers project
    against **the frame actually on screen**. Gotchas found: only the Continuous path was tagged
    at first (every headless test runs **Static**, via `renderCpu`, and saw generation 0); the
    generation must be recorded **before** bumping `frameCount`, which is the signal `awaitFrame`
    and the present path wake on; and `awaitFrame()` returns as soon as ANY frame exists, so it
    cannot be used to wait for the *next* one.
  - **Perf work:** the Flow overlay never culled — `paintChild` ran for every marker including
    ones parked off-screen, and the core's `visible` flag only means "in front of a pitched
    camera". Added viewport culling (frame times now fall when the cluster pans off-screen,
    user-confirmed) and `MapLibreMarker.repaintBoundary` (default true) so a rich child
    rasterises once and camera ticks move a layer instead of repainting content — documented as a
    *pessimisation* for thousands of trivial markers.
  - **Flutter gotchas worth keeping:** `createTicker()` does an inherited-widget lookup, so a lazy
    `late final _ticker = createTicker(...)` constructs it inside `dispose()` when it never ran —
    asserting on a deactivated element; create it in `initState`. And `RenderRepaintBoundary
    .toImage()` waits on a real raster-pipeline callback that `flutter_test`'s fake async never
    delivers — rasterizer tests **must** use `tester.runAsync` or they hang to the 10-minute timeout.
  - **Status: macOS only, not yet device-verified for the sync fix.** Linux/Windows/iOS-core/
    Android-core controllers still project against the newest transform (two lines each,
    deliberately NOT blind-ported — see the 2026-06-21 pinch-anchor regression). Native suite
    18/18 with pixel assertions (clusters verified by eye in dumped PNGs); `maplibre_flutter`
    30 passing with the one pre-existing `"pinch zoom freezes its anchor"` failure that also
    fails on `main`.

- **2026-07-30 — Style API takes spec JSON for now; a typed API should be GENERATED. Design
  recorded in `docs/typed-style-api.md` (NOT implemented).** `controller.layers` exposes
  `addSourceJson`/`addLayerJson`/`setGeoJsonData` taking MapLibre Style Spec JSON, plus typed
  convenience for the common case (`addPoints(cluster: true, …)`, `addWidgetIcon`,
  `queryRenderedFeatures → List<MapLibreQueriedFeature>`). Rationale: seven C functions over
  mbgl's `convertJSON<T>` buy the **entire** spec — every layer type, expressions, filters,
  data-driven styling — for a fraction of the surface of typed accessors, and it is the shape
  gl-js users know. Cost: a bad document is a runtime `ArgumentError`, not a compile error.
  - **When it is built, generate it.** Measured from the spec vendored in our own submodule
    (`third_party/maplibre-native/scripts/style-spec-reference/v8.json`): **10 layer types, 138
    paint+layout properties, 84 expression operators.** Hand-maintaining that drifts from the
    spec on every core bump, silently.
  - **Precedent: mbgl already generates its own C++ layer classes from that same file**
    (`scripts/generate-style-code.mjs` + `include/mbgl/style/layers/layer.hpp.ejs`). A Dart
    generator uses the identical source of truth and tracks the pinned `MBGL_CORE_VERSION`.
  - **No C ABI change needed** — a typed layer is a pure Dart façade that serialises to the
    existing `addLayerJson`; the raw methods stay as the escape hatch. Expressions get builders
    plus a raw hatch (84 operators is too many to model perfectly up front). CI regen-diff check
    like ffigen so spec drift fails visibly. Suggested order: circle, symbol, line, fill, rest.

- **2026-07-30 — Typed style API BUILT, generated from the vendored spec: `circle` layer +
  `geojson` source, end to end (on `feat/typed-style-api`).** Executes the design recorded the
  same day (entry above) rather than re-deriving it. Generator
  `packages/maplibre_flutter/tool/generate_style_api.dart` reads
  `third_party/maplibre-native/scripts/style-spec-reference/v8.json` and emits
  `lib/src/style/generated/*.g.dart` (committed, `dart format`ed by the generator so the files are
  byte-stable); `.github/workflows/ci.yml` regenerates + `git diff --exit-code`s it beside the
  ffigen check, so an mbgl bump that moves the spec fails visibly. **No C ABI change** — a typed
  layer serialises to the existing `addLayerJson`, as designed. New public surface:
  `layers.addLayer(StyleLayer, beforeId:)` / `layers.addSource(String, StyleSource)` alongside the
  raw JSON methods, which stay public as the escape hatch. `addPoints`/`setPoints` are
  **reimplemented on the typed API** (the cluster-count layer is `symbol`, so it stays raw JSON
  until the generator covers that type). Nothing was hand-written per-property: the allowlists
  `_layerTypes`/`_sourceTypes` are the entire cost of widening coverage.
  - **The ergonomics trick that made typed properties viable: `Expression extends
    StyleValue<Never>`.** Dart generics are covariant, so `StyleValue<Never> <: StyleValue<T>` for
    every `T` — which is what lets ONE `StyleValue<double>?` parameter accept both
    `const StyleValue(6)` and `Expr.step(...)` without degrading to `Object?` (which the design
    doc explicitly rejected). Properties the spec marks `property-type: constant` (e.g.
    `visibility`) are generated as their plain type instead, so an expression the engine would
    reject is *not expressible*.
  - **The spec carries NO arity information for expressions**, so all 84 operator builders are
    uniformly variadic to 10 args with an `identical`-checked `_unset` sentinel (an explicit
    `null` survives — `["literal", null]` is real). Overflow is a compile error, not silent
    truncation; `Expr.raw` is the hatch. Curated name mapping only where Dart forces it: symbolic
    ops, reserved words (`case`/`var`/`in`), `to-string` → `toStringOp` (a static `toString`
    collides with `Object.toString`), and **`visibility` → `StyleVisibility`** (bare `Visibility`
    collides with the Flutter widget). The generator **throws** on a collision, a reserved word or
    an unmapped spec type — a silent `Object` fallback is how a generated API rots.
  - **Serialisation is byte-compatible with hand-written style JSON**: whole numbers emit as ints
    (`6`, not `6.0`), opaque colours as `#rrggbb` (translucent as `rgba(...)`), keys in spec order
    (`id, type, metadata, source, source-layer, minzoom, maxzoom, filter, layout, paint`). GeoJSON
    coordinates deliberately skip the int rewriting and stay doubles (`GeoJsonData.toJson()`
    returns its data as given) — the one path whose bytes previously went to mbgl's GeoJSON parser,
    left unchanged on purpose.
  - **Generated files emit only the imports they use** — an unused import is a warning and
    `melos run analyze` is `--fatal-infos`.
  - **Verified on this Mac:** generator is idempotent (re-run is byte-identical); `melos analyze`
    green across all 13 packages; `melos format` green; 22 new tests in
    `maplibre_flutter/test/style_api_test.dart` pass, full `melos test` is 58 passing with only
    the **pre-existing** `"pinch zoom freezes its anchor"` failure (re-confirmed failing with this
    branch's changes stashed). §7-layer-5 note: the typed API cannot be checked against the GPU
    from `maplibre_flutter` (the engine tests live in `maplibre_flutter_core`, which must not
    depend on the app-facing package), so a test pins the typed output **equal to the exact
    documents `maplibre_flutter_core_test.dart` already renders and verifies by counting painted
    pixels** — the closest the dependency graph allows.

- **2026-07-30 (same session, second pass) — Typed style API widened from `circle` to the WHOLE
  spec; the allowlist was deleted rather than extended; the example now demonstrates it.** Driven
  by a concrete need: the example's icon scenarios and `addPoints`' cluster-count label are
  `symbol` layers, so a circle-only API left raw JSON in both the library and the example. Rather
  than add `symbol` to the allowlist, the generator now **discovers** coverage from the spec —
  every type in `layer.type.values`, every `source_*` schema — so a layer type added by a future
  spec generates itself and CI's regen diff surfaces it. Keeping a hand-picked list would
  reintroduce exactly the drift this design exists to prevent. Output went 2.3k → **5.6k lines:
  10 layer classes, 6 source classes, 33 enums, 84 expression builders.**
  - **What the remaining nine layer types actually cost:** only new *spec-type* mappings, no
    per-property work — `padding` and `numberArray` → `List<double>`, `colorArray` →
    `List<Color>`, `variableAnchorOffsetCollection` → `List<Object>` (its elements genuinely
    alternate anchor-name/offset-pair), arrays **of enum** (`text-variable-anchor` carries its
    `values` on the property itself, so the whole def is handed down), and arrays whose `value` is
    a nested *schema* rather than a type name (a source's `coordinates` → `List<List<double>>`).
  - **Three traps the widening exposed**, all now handled in the generator: (1) **a source's
    `type` string is NOT its schema key** — `source_raster_dem` describes `"type": "raster-dem"`
    — so the discriminator is read from the schema's own single-valued `type` enum, not derived
    from the key; (2) source schemas contain a **`"*"` wildcard property key** (extra TileJSON
    fields on raster/vector) which cannot be a Dart field and is skipped, with `addSourceJson`
    as the hatch; (3) **enum names collide across sources** — `scheme` exists on both `raster` and
    `vector`, and `encoding` means different things on `vector` (mvt/mlt) vs `raster-dem`
    (terrarium/mapbox/custom) — so **source** enums are prefixed with their source type
    (`VectorScheme`, `RasterDemEncoding`) while layer enums keep the property name (already unique,
    since property names carry the layer). Identical values under one name still share an enum
    (every layer has `visibility`); genuinely different values under one name throws.
  - **`background` is generated without `source`, `source-layer` or `filter`** (it draws no
    features), so an invalid document is not expressible.
  - **Import emission is name-driven, not file-driven** — layers and sources both reference
    generated enums, and a file must not import itself (the first cut had `style_enums.g.dart`
    importing `style_enums.g.dart`, which `--fatal-infos` caught).
  - **The library now contains ZERO raw style JSON**: `addPoints`' cluster-count layer is a typed
    `SymbolLayer`. Added `GeoJsonData.lineThrough(points)` as the LineString counterpart to
    `GeoJsonData.points`.
  - **New example scenario "Typed style API"** (`_applyTypedStyle`), which uses `addSource` /
    `addLayer` directly with no `addPoints` and no JSON: a `GeoJsonSource` carrying **per-point
    properties**, a `CircleLayer` coloured by `Expr.match(Expr.get('kind'), …)` on real
    `dart:ui` Colors *inside the expression* and sized by `Expr.interpolate` over
    `Expr.get('pop')`, a `SymbolLayer` labelled from `Expr.get('name')` with `TextAnchor.top` +
    halo, and a dashed `LineLayer` (`LineCap.round`, `lineDasharray`, width interpolated over
    `Expr.zoom()`). The example's two remaining hand-rolled JSON documents (the icon scenarios)
    are now typed as well.
  - **Verified:** `melos analyze` (`--fatal-infos`) green across all 13 packages **and the
    example**; generator idempotent; `maplibre_flutter` 62 passing with only the pre-existing
    `"pinch zoom freezes its anchor"` failure. Earlier the same session the **clustered engine
    path was confirmed on macOS with real pixels** (50k points → engine clusters, labelled, orange
    `#f57c00`, `ui 0.3ms raster 0.3ms`), which proves mbgl accepts the generated documents
    including the new hex-colour and int-number encodings. The new typed scenario itself is
    **written and analysing but not yet eyeballed on device** — that run is the outstanding check.

- **2026-07-30 — Cluster count labels outlived their bubbles: mbgl's SYMBOL placement fade.
  Fixed by exposing the engine's own knob (a new C ABI function), opt-in.** Reported symptom: in
  the engine-clustering scenario the count text lingered "a few frames" after the cluster circle
  had gone. **Pre-existing and unrelated to the typed style API** — the `c-count` document is
  unchanged apart from key order and colour spelling.
  - **Cause:** symbol layers fade, circle layers do not. `Placement::symbolFadeChange`
    (`src/mbgl/text/placement.cpp:1277`) returns 1.0 (instant) only when placement transitions are
    disabled or the duration is zero; otherwise labels ramp opacity over
    `transitionOptions.duration`, default `util::DEFAULT_TRANSITION_DURATION` = **300 ms**
    (`include/mbgl/util/constants.hpp:59`) ≈ 18 frames at 60 fps. A circle is a feature that simply
    stops being drawn on the next frame, so the two disagree. Only applies in **Continuous** mode
    (`render_orchestrator.cpp:178` substitutes default `TransitionOptions()` in Static) — which is
    the desktop default. maplibre-gl-js behaves identically (`fadeDuration`, default 300).
  - **Fix:** new `mbl_map_set_transition_options(map, duration_ms, delay_ms, placement_transitions)`
    over `mbgl::style::Style::setTransitionOptions`. `enablePlacementTransitions = false` is the
    **surgical** knob — it stops the symbol fade while leaving paint-property transitions alone,
    whereas `duration: 0` would flatten those too. Negative ms means "leave the document's value".
  - **STICKY, and that is the non-obvious part:** loading a style **overwrites** the style's
    transition options with the document's (`style_impl.cpp:106`, `transitionOptions =
    parser.transition`) — the same hazard as a style swap wiping sources and layers. So the shim
    remembers the request on `MblMap` and re-applies it from a new
    `FrameObserver::onDidFinishLoadingStyle`. That observer exists only on the Continuous path,
    which is exactly where transitions are honoured, so no Static-path plumbing was needed.
  - **Default is unchanged (engine behaviour), because the knob is style-wide, not per layer:**
    turning it off also stops the *basemap's* labels fading while panning.
  - **FINAL DECISION (user, on device): do NOT override the style's defaults — the artifact is
    accepted as an engine limitation.** Two mitigations were tried and both rejected:
    `placementTransitions: false` (fixes the lingering count, but the basemap's labels then pop in
    and out — worse than the bug) and a short `duration` (80 ms, which keeps every fade and cuts the
    overhang from ~18 frames to ~2). The objection to the second is the principle, not the number:
    **every lever mbgl offers here is style-wide**, so any mitigation means overriding the style
    document's own transition behaviour. So the example applies nothing, the library default is
    untouched, and a cluster count outliving its bubble by ~300 ms is documented rather than fought.
    maplibre-gl-js behaves identically.
  - **The knob still ships**, as an opt-in escape hatch for apps that decide differently —
    `controller.layers.setTransitionOptions(duration:, delay:, placementTransitions:)` — with the
    trade-off spelled out in its dartdoc. Note for future work: `Placement::getUpdatePeriod` clamps
    the placement *recalculation* period at `max(300ms, duration)`, so shortening `duration`
    shortens only the fade, not how often placement runs. The genuinely per-layer fix, if this ever
    matters enough, is to draw the bubble as an **SDF symbol icon in the same layer as the count**
    (`icon-image` + `icon-size` stepped by `point_count`) so bubble and text are ONE symbol and
    cannot disengage at any duration.
  - **Ripple:** one method added to the platform interface's `MapLibreStyleLayers`, forwarded by all
    five core controllers (macOS/Linux/Windows/iOS/Android). Blind-porting was acceptable here,
    unlike the 2026-06-21 pinch-anchor regression, because these are **verbatim pass-throughs of
    scalars to the identical core call with no coordinate or convention transform** — there is
    nothing platform-specific to get wrong. Only macOS is behaviourally verified.
  - **Test honesty:** the native test pins that the call is safe on a live map before the first
    frame, mid-life, and across a style load (the sticky path), and that rendering continues. It
    does **not** assert the fade is gone — that is a per-frame opacity ramp, invisible in a still
    frame, and needs an on-device look.
- **2026-07-30 — Animated 3D models (.glb) render inside mbgl, depth-occluding against
  buildings; three Metal-only mbgl bugs and one of our own fixed along the way. On
  `feat/3d-model-spike`, verified on macOS/Metal.** MapLibre has **no model layer** — not in
  the style spec, not in gl-js, not in Native, not on the roadmap (upstream closed
  maplibre-native #3096 with "can now be done using plugins"; #2806 is open and dormant). Every
  3D model on a MapLibre map is drawn through an escape hatch. Of the three, only one is usable
  here: **`CustomDrawableLayer`**, whose `CustomGeometryShader` exists for Metal, Vulkan, GL and
  WebGPU and whose factory is registered unconditionally. The raw `CustomLayer` is a dead end —
  `CustomLayerFactory` is gated on `#ifdef MLN_RENDER_BACKEND_OPENGL`
  (`layer_manager.cpp:82`), so `addLayer` would `assert(false)` on Metal and Vulkan.
  - **What ships:** a hand-written GLB reader (`src/maplibre_flutter_core_gltf.{hpp,cpp}`) using
    mbgl's **already-vendored rapidjson** + mbgl's image decoder — **no new dependency, no
    FetchContent, no build-time network** on any arm. The mesh is split into **parts**, one
    drawable each, because mbgl's `IndexVector` is `uint16` (65536-vertex ceiling **per
    drawable, not per model**) and because one texture per model would smear a single material
    over everything. A real Sketchfab car (509k verts, 728k tris, 149 primitives, 64 materials,
    20 images) renders correctly at 149 draw calls. Parts split by re-indexing when a single
    primitive exceeds the ceiling; textures upload once per distinct image; `KHR_texture_transform`
    is baked into UVs; `extensionsRequired` is validated and unsupported entries refused rather
    than silently rendering wrong geometry.
  - **API:** `mbl_map_add_model` / `mbl_map_set_model_transform` / `mbl_map_remove_model` →
    `MapLibreModelHost` + `MapLibreModel` (optional platform-interface capability,
    feature-detected with `is` exactly like `MapLibreMapProjector`) → `@experimental`
    `controller.addModel/updateModel/removeModel`. **Parsing is synchronous on the CALLING
    thread** (pure file/CPU work, no mbgl access), which is what lets a bad file report an error
    instead of vanishing into a render-thread log. **Moving a model mutates a shared
    `MblModelPlacement` the tweaker re-reads per frame** — re-adding to move would re-parse the
    whole .glb every frame. The eventual API is a declarative `MapLibreMap(models:)` prop per the
    §3 three-bucket rule; the imperative trio is scaffolding.
  - **THREE METAL-ONLY mbgl BUGS.** Each is patched via the existing `patches/` + build-hook
    mechanism, and each affects **only Metal** — GL (Linux/Android) and Vulkan (Windows) handle
    all three correctly, though that is reasoned from source and **not yet measured on those
    tiers**:
    1. **No depth testing at all** (`patches/metal-custom-drawable-3d-depth.patch`, marker
       `MBL_CUSTOM_3D_DEPTH`). `mtl::Drawable` skips its own depth state when `is3D` ("handled by
       the layer group", `drawable.cpp:244`), but `mtl::TileLayerGroup` only computed `features3d`
       INSIDE `if (stencilTiles && !empty())` — and every `CustomDrawableLayer` has no stencil
       tiles, so nothing set a depth state and 3D fell back to painter's order. Measured: an 18 m
       model at the centre of the Empire State Building's footprint went 844 px → **0 px**, fully
       hidden. **Note: upstream `main` still has this** — PR #4364 does NOT fix it (it only adds
       `nearClippedProjectionMatrix` to `MLNCustomStyleLayer`), so a submodule bump would not have
       helped. Worth filing upstream.
    2. **Texture wrap ignored** (`patches/metal-custom-geometry-sampler-repeat.patch`, marker
       `MBL_CUSTOM_GEOMETRY_REPEAT`). The Metal `CustomGeometryShader` declares `constexpr
       sampler` INSIDE the shader, and a Metal `constexpr sampler` defaults to
       `address::clamp_to_edge`, ignoring the wrap state mbgl sets on the Texture2D. glTF defaults
       to REPEAT and models tile deliberately (Khronos BoxTextured spans u=[0,6]; the car spans
       u=[-34.98, 3.91]), so clamping collapsed them to one edge colour that reads as "the texture
       never bound".
    3. **Heading rotated backwards** (in our tweaker, not a patch). Map model space is X east, Y
       south, Z up — **east × south = down, so the frame is LEFT-handed** and the standard
       `rotate_z` is already clockwise from above. Negating it, which looks right if you assume a
       right-handed frame, made heading run backwards. Invisible for a static model and for
       heading 180 (symmetric), and only exposed once heading swept: a model driving a circle
       counter-rotated against its path.
  - **OUR OWN BUG, found by the spike: the projector's Y axis was inverted.**
    `TransformState::latLngToScreenCoordinate` returns a **bottom-left-origin** y
    (`transform_state.cpp:775` does `size.height - y`), but mbgl's **gesture anchors are
    top-left** — confirmed independently by zooming about (0,0) and watching the camera move
    north-west. The shim passed `sc.y` straight through while its header claimed both spaces
    matched, so **every widget marker would have been mirrored vertically about the map centre**.
    Fixed in all three projection entry points; `src/proj_probe.cpp` guards the signs. It survived
    because the marker/projector work (`532d3c3`) was written but never run — same class as the
    2026-06-21 Windows anchor-flip.
  - **Other gotchas worth keeping:** mbgl's model matrix takes **X/Y in world pixels but Z in
    METRES** (`camera.cpp:104`), so scaling all three axes uniformly — as upstream's flat-geometry
    example does — squashes a model into a decal; upstream's `itemScale * 2^zoom *
    pixelsToGLUnits[0]` is not physically meaningful (~300x too large at z15) and
    `metres / metresPerPixel` is the correct form. Continuous mode is **update-driven, not
    vsync-driven**, so a placement change (which never touches mbgl) needs an explicit
    `Map::triggerRepaint()` or a moving model only advances when something else redraws.
    A **style reload drops every custom layer**, so the shim retains each model's parsed mesh +
    placement and re-adds from `onDidFinishLoadingStyle` (free — the mesh is shared and
    immutable). mbgl clamps pitch to **`DEFAULT_PITCH_MAX` = 60°**. Under the **macOS sandbox** an
    app can only read its own container, so a model path in `~/Downloads` fails with "cannot
    open" without an entitlement — **this applies to iOS too and argues for taking bytes rather
    than a path** before the API stabilises.
  - **Verification is pixel-based throughout**, per the §7 lesson from the Windows blank-map bug:
    `model_harness` asserts the model renders, is anchored where `mbl_map_pixel_for_lat_lng`
    projects, animates, survives a style change, and moves on `set_model_transform`;
    `gltf_probe` covers parse-level invariants and negative cases (text .gltf, a synthesized
    70002-vertex GLB); `proj_probe` covers projection signs; `drive_probe` renders a model at four
    quarters of a circular path to check facing against travel. All behind
    `MAPLIBRE_FLUTTER_BUILD_HARNESS=ON`, not shipped.
  - **Remaining:** the unlit ceiling stands — **no normals, no lighting, one texture per part, no
    skeletal animation** (bake lighting in; animate by moving, not deforming). Lighting would need
    `NORMAL` plumbed through plus a patched shader, and is the single biggest visual win left.
    GL/Vulkan/Android/iOS tiers need HW verification (expected to need no patches). The declarative
    `MapLibreMap(models:)` prop is still to come. A per-frame `triggerRepaint` while animating
    costs power on CPU-present tiers.
  - **LESSON, repeated four times this session:** every one of these bugs was a
    coordinate-or-graphics-state assumption that looked right and rendered *something* — a
    bottom-left y read as top-left, a uniform XYZ scale, `Clamp` because "UVs are in [0,1]", a
    right-handed rotation in a left-handed frame. Each hid behind a symmetry (a static model, a
    heading of 180, UVs that happened to fit) and only surfaced when a case broke it. Take the
    convention from the source data or the spec and **verify it with an asymmetric fixture**;
    do not infer it from what usually works.

## 2026-07-31 — mbgl centres text on a hardcoded baseline, not on font metrics (patched)

Found while building the first real third-party consumer of this plugin (Carta Polaris, a
Finnish nautical chart). Its swept-depth labels use `symbol-placement: line-center` +
`text-anchor: center` and should straddle the fairway line; they sat ~4 px above it.

- **Root cause, upstream and shared with the web.** Both engines position text vertically from a
  hardcoded constant instead of the font's baseline metrics — `Shaping::yOffset = -17`
  (`include/mbgl/text/glyph.hpp`, whose own comment says "The y offset *should* be part of the
  font metadata") and the identical `SHAPING_DEFAULT_OFFSET = -17` in maplibre-gl-js
  `src/symbol/shaping.ts`. `ONE_EM` is 24, so it is a fixed -0.708 em assumption, calibrated by
  Mapbox against DIN Pro. Any font with different metrics renders centre-anchored text off-centre.
  **Not a native-tier divergence** — the web app shows it too.
- **Patched:** `patches/text-centre-anchor-on-ink.patch` (marker `MBL_TEXT_CENTRE_ON_INK`), one
  function in `src/mbgl/text/shaping.cpp`. Centre on the shaped glyphs' actual ink extent rather
  than the constant: the quad builder already places each glyph at `y - metrics.top * scale`
  spanning `metrics.height * scale`, and `PositionedGlyph` carries those metrics, so `align()` can
  measure the ink and centre it. Only centre anchors touched. Measured over 24 orientations at 15
  degree increments: ink went from -9.80..+1.74 px (4.03 px off) to -5.75..+5.73 px (within
  0.25 px). Real-chart regression check clean — hundreds of point labels unmoved.
- **The style cannot fix it**, both ruled out by measurement, which is why patching the engine was
  the only route: `text-offset` is applied in the glyph's own frame, which flips with the line's
  digitisation direction (a value centring bearings 0-180 drives 195-345 twice as far out);
  `text-translate` has no effect at all on line-placed labels (12.9 px of requested shift produced
  under 0.3 px of movement).
- **The collision box is deliberately left alone**, after getting this backwards twice. It is built
  from `shaping.top`/`bottom`, which is *already* symmetric about the anchor (the existing shaping
  tests assert -36/+36, -24/+24, ...); the ink was the thing off-centre inside it. Centring the ink
  brings the two into agreement, so shifting the box as well would move it back off the ink and
  break those assertions. `symbol_layout.cpp`'s second hardcoded `baselineOffset = 7.0f` is not a
  conflict either: it serves only `evaluateRadialOffset`/`evaluateVariableOffset` and every call
  site skips it for `Center`/`Left`/`Right` — exactly the `verticalAlign == 0.5` set this touches.
- **Tested, and the test was verified to fail without the fix:** `src/shaping_probe.cpp` (behind
  `MAPLIBRE_FLUTTER_BUILD_HARNESS=ON`) drives `mbgl::getShaping` directly with synthetic glyph
  metrics — no map, no GPU, no fonts. 4 failures unpatched, 0 patched, with the box and
  edge-anchor assertions holding in *both*, which is what shows the change is confined to centre
  anchors. `patches/text-centre-anchor-on-ink-tests.patch` carries the same cases as gtest cases
  for mbgl's own suite, for the upstream PR.
- **Edge anchors keep the old behaviour and are still skewed** by the same constant (`text-anchor:
  top` with ink 11 above the baseline lands at -16..-5 where it should hang at 0..+11). Fixing them
  would move every top/bottom-anchored label in every style, so it is a deliberate follow-up.
- **Prior art:** no MapLibre issue exists (`SHAPING_DEFAULT_OFFSET` and `yOffset baseline` return
  zero results org-wide). mapbox/mapbox-gl-js#154 and #191 have been open since **2013**; #154 even
  proposes this exact approach ("or the shaped text bbox?"). Mapbox fixed their own side in GL JS
  v2 (#8781, 2021) — post-fork and proprietary, so MapLibre cannot take it and **that diff was
  deliberately not consulted**.
- **Outstanding:** open the upstream issue + PRs (native and web). Tracked in
  `docs/cross-platform-continuation.md` and written up with evidence images in
  `docs/upstream-text-centring/`.
- **LESSON (again, §11):** the first three verdicts this produced were all wrong, and every one was
  the *instrument*, not the renderer — window traffic-light buttons counted as data, transparent
  rounded corners read as black ink, and an arbitrary SVD sign that made a constant offset look
  like it flipped with angle. The fixture places lines on an exact 15 degree grid specifically so
  the measurement can self-test: if a fitted angle is not a multiple of 15, the tool refuses to
  report a verdict. Build the self-check before trusting the measurement.

## 2026-07-31 — Cross-platform parity push: verification floor first, then iOS, then the GL tiers

Bringing Android, iOS, Windows, Linux and Web to parity with macOS, and adding the missing
rotate/tilt gesture. The audit that opened this work measured the gap from source rather than
from `FEATURE_MATRIX.md`, and the docs turned out to be wrong in **both** directions.

### The capability gap was smaller than documented, and iOS was the cheapest tier, not the dearest

`MapLibreModelHost` was the **only** missing capability on the four non-macOS native tiers.
Projector, camera tick, style layers, transitions and queries were all genuinely written — just
unrun. And the continuation doc's recommended order of attack ("Linux (GL) first, the patch edits
are smallest there") was backwards: `src/CMakeLists.txt` puts the model and glTF sources in
`_shim_sources` before any platform branch, `hook/build.dart` applies every patch with no OS gate,
and **iOS runs the same Metal backend as macOS** — so the two patches the docs called "macOS-only"
already applied to it and 3D on iOS was pure Dart forwarding. iOS is also the one non-macOS tier
that can be verified today, on an Apple-Silicon Simulator.

### Four defects that made the verification loop unable to report anything

Fixed before any parity work, because each would have let a blind port ship "verified":

1. **`melos run test` was red**, and `failFast` cancelled the three other test-bearing packages —
   so CI's regen-diff gates, which run after it, could never have fired. Root cause was a **live
   touch bug**, not a stale test: two anchor fixes collided (55ee9d4 froze the pinch anchor for
   the Windows/Linux focal drift; 1963302 then made it follow the cursor for the GTK offset), and
   since a real pinch always produces pointer moves, the frozen anchor became dead code on every
   path. On a touchscreen there is no cursor at all, so the anchor alternated between the two
   fingers. Gated on `_inTrackpadPanZoom || _pointers.length <= 1` — both halves load-bearing,
   because they disagree exactly where it matters and agree on macOS, the only tier we can run.
2. **The native harness did not compile** (`proj_probe`/`model_harness` called the projection C ABI
   with the pre-`generation` arity), so every "verify with the harness" plan was dead on arrival.
3. **3D models aborted the process at exit** — SIGABRT, *after* printing ALL CHECKS PASSED.
   Uploaded textures hung off the **global** mesh cache, outlived every map, and were released at
   static-destruction time with the gfx context already gone. Split it: the parsed mesh stays
   global (the expensive part), the textures moved to `MblMap::gpuByPath` and are released on the
   render thread inside a `BackendScope`. This was a real crash-on-exit for any app drawing a
   model, plus a latent cross-context sharing bug with two map widgets.
4. **`hook/build.dart` did not declare the model/glTF sources or `patches/`** as build inputs, so
   editing any of them silently reused the previous dylib. Compounded by the marker check, which
   skips a patch already present — a patch edit also needs a submodule reset.

### The GL attribute-order bug — three auditors, one line, every model wrong

`ShaderProgramGL::create` indexes the attribute table **by GL attribute location**
(`assert(attributesInfo[location].name == name)`). The lighting patch inserted `a_normal` at vector
index 1 while the shader declares `location 1 = a_uv, 2 = a_normal`, so texcoords fed `a_normal`
and normals fed `a_uv` on every GL model draw — Linux, Android **and** the future web-WASM arm.
Debug aborts on the assert; Release renders garbage silently. Not "an unverified mirror of the
Metal edit" as the patch header claimed: wrong, and it would have shipped.

Also guarded `normalize(vec3(0))` in all four backend shaders. `GeometryVertex::normal` defaults to
`{0,0,0}` and its comment claimed "Zero is legal and yields flat ambient shading" — untrue by
construction; Metal survives only because MSL `saturate` collapses NaN to 0, and GLSL's
`clamp(NaN,0,1)` is undefined. `mblMakeTestPyramid` never set normals, so the one mesh every
harness draws was exactly the degenerate case.

### GL 3D stencil: evaluated, deliberately NOT patched

Same *shape* as `metal-custom-drawable-3d-depth.patch`. `gl/drawable_gl.cpp` skips stencil when
`is3D` ("handled by the layer group"), but `gl/layer_group_gl.cpp` computes `features3d`/`stencil3d`
only **inside** `if (stencilTiles && !stencilTiles->empty())` — and a `CustomDrawableLayer` never
has stencil tiles. So a 3D custom drawable on GL inherits whatever stencil state the previous draw
left, rather than a defined one. Vulkan does not have this: `vulkan/drawable.cpp` handles `is3D`
itself via `parameters.stencilModeFor3D()`.

Not patched, for two reasons. The consequence depends on the leftover state — if it is
`disabled()` the model draws correctly, so the model may well render fine without any change; and
stacking a second speculative patch on top of the attribute-order fix would make neither
diagnosable. **Decide it with a GL run** (Mesa/llvmpipe via `docker/run-render-test.sh`), which
could not be done here because docker was not available on the authoring machine.

### Duplication over abstraction for the model host, on purpose

The review asked for a shared mixin instead of four copies. Neither candidate home works:
`maplibre_flutter_core` is pure Dart and the repaint pump needs a Flutter `Ticker` — adding Flutter
there would also break `melos run test:native`, whose package filter is `flutter: false` — while
the platform interface has no dependency on core and would have to restate the core's entire model
API to express the mixin's requirements. Four copies of ~70 lines of pass-through, held together by
one conformance suite that runs the same assertions against every tier, is the better trade. **The
suite is what makes the duplication safe**, and flipping a tier's `models: true` is what proves its
port landed rather than merely compiled.

### The device-free floor, and what it caught immediately

CLAUDE.md §7 layer 2 ("each platform wrapper with its generated bindings mocked") existed only as a
sentence — implemented zero times for zero platforms, macOS included. Every fake in the repo
implemented the *platform interface*, one level above the FFI wrapper. Added `RecordingCoreMap`
(`maplibre_flutter_core/lib/testing.dart`, pure Dart) plus a `forTesting` constructor per
controller, and one conformance suite in `maplibre_flutter` — the only package depending on all
five platform packages, which is also why it is one suite and not five.

On its first run it found that **`setStyle` had no dispose guard on any of the five**, unlike every
other forward; the core throws `StateError` once disposed and the widget pushes its declarative
`style` prop from `didUpdateWidget`, which can land during teardown. It also confirmed the
first-frame `notifyCameraChanged()` was **macOS-only**, which meant `MapLibreMap(markers:)` rendered
nothing at all on the other four tiers until something else moved the camera — invisible after the
first pan, and invisible in all three integration tests, which move the camera as their first act.

**LESSON (§11 again):** three of the guards written for this push were wrong on the first attempt,
and every time the *instrument* was wrong, not the code under test. The `visible`-at-pitch guard
assumed points behind a pitched camera lie to the north (web mercator is a flat plane — they lie
south, behind the tilted viewer); the model-harness palette check asserted all four pyramid faces
in one frame (at most two faces of a pyramid are ever visible); and its colour classifier read
RGBA when `mbl_map_copy_frame` emits **BGRA**, which silently matched only green, the one target
symmetric under an R/B swap. Verify the instrument against a known-good and a known-bad case
before trusting its verdict.

## 2026-07-31 — Two design questions the parity audit deadlocked on, settled

Two items came back from the audit with two auditors proposing opposite things. Both are public-API
decisions rather than defects, so recording the call here per §3/§12.

### 1. A style load drops app-added layers. Add an EVENT; do not silently re-add them.

mbgl replaces the layer list on every style load, so every source and layer an app added is gone.
The shim already re-asserts transition options and re-adds *models* from
`onDidFinishLoadingStyle` — models are our own abstraction over `CustomDrawableLayer`, so we own
their lifetime — but app-added layers are the app's, and there is **no signal** that they vanished.
The example papers over it with a hardcoded `Future.delayed(700ms)`, and the new iOS integration
test hit the same race: adding a layer right after `onReady` loses it, because `onReady` fires on
the first FRAME, which can precede the style completing.

One auditor proposed re-injecting app layers in C++ from `onDidFinishLoadingStyle`. **Rejected.**
It would make the five native tiers diverge from both web tiers *and* from upstream
maplibre-gl-js, whose `setStyle` drops runtime layers identically — so it would break parity rather
than restore it — and it would resurrect layers an app deliberately removed before a style swap.
There is also no correct answer for ordering: `beforeId` may name a layer the new style does not
have.

**Decision: extend the contract with a style-loaded event** (a `MapLibreStyleEvents` capability,
feature-detected like the others), so an app can re-apply its own layers deterministically instead
of guessing with a delay. That keeps every tier on the same semantics as gl-js. NOT YET
IMPLEMENTED — it is a contract addition touching all seven tiers, and CLAUDE.md is explicit that
interface churn is the most expensive kind, so it wants its own change rather than being smuggled
into a parity push. Until then the workaround is documented where it bites: the iOS integration
test explains the race at the call site.

### 2. `PointerInterceptor` for markers over a DOM map. Keep the existing decision.

Filed three times with three different scopes, and one version proposed reversing the 2026-06
decision above (`pointer_interceptor` is for OVERLAYS, not the map; it was deliberately added to
the *example*, not the app-facing package).

**Decision: keep it.** Widget markers are drawn in the Flutter overlay above the platform view, so
on the DOM-backed tiers they are subject to the same rule as any other control drawn over the map —
which is the app's concern and is already demonstrated in the example. Pulling
`pointer_interceptor` into `maplibre_flutter` would add a dependency every native tier pays for and
never uses, to solve a problem only two web tiers have, and only for apps that put interactive
widgets over the map. Revisit if and when web markers are actually wired (they are not: neither web
tier implements `MapLibreMapProjector`, so there is no marker overlay on web at all today) — at
which point it can be measured rather than predicted.

### 3. 3D models on web: deferred, with the reason recorded rather than a bare ❌.

`MapLibreModel.assetPath` is documented as a real filesystem path — the engine opens it natively —
and web has no filesystem. The Emscripten arm also compiles neither the glTF reader nor the model
layer (`web/CMakeLists.txt` builds one translation unit). Giving web models a route needs a
bytes-based model API on the contract *plus* those sources in the WASM build; it is not a wiring
gap. The example now says so at the point of failure instead of handing over a path that could
never be opened.

## 2026-08-01 — CI stays `workflow_dispatch`-only; the jobs land anyway

The parity push enabled the `push` / `pull_request` triggers in `ci.yml`, on the reasoning that
the regen-diff gates had never once fired and four platforms had no automated coverage of their
native code at all. **Reverted at the maintainer's direction** — the cost review that disabled
them has not concluded, and that decision was not the parity push's to make.

What is kept: every job. `ios`, `android`, `linux`, `windows` (compile gates for the four tiers
that cannot be run on hardware here), `web-wasm` (the only thing anywhere that compiles the
Emscripten module), plus `test:harness` and `verify:podspecs` on the macOS job. They are written,
correct as far as static checking goes, and one click away in the Actions tab.

What that costs, stated so it is not forgotten: committed codegen can drift silently, and
`dart analyze` remains the only automated check over four platforms' Swift, Kotlin, C++ and CMake.
Run the workflow by hand after a core bump or a change to a native tier.

No runs were triggered by the branch push, incidentally — the trigger was scoped to
`push: branches: [main]` plus `pull_request`, and a feature branch with no PR matches neither.

## 2026-08-01 — The iOS-Simulator tile seams were never a "translation quirk": mbgl never attaches the stencil buffer there

Reported as doubled grey lines on every tile seam in the Carta Polaris PoC on the iPhone-17
Simulator, and suspected to be a regression from the parity push. **It is neither a regression
nor a simulator rendering quirk — it is a real upstream mbgl bug, and it is now fixed.**

**What the pixels said.** Measured off the Simulator screenshot rather than eyeballed: two
near-vertical lines at x=563.2/576.7 and two near-horizontal at y=1827.3/1840.8, spacing
**13.48 px in both axes** (and identical at every band sampled), on a tile pitch of ~1739 px.
Each pair straddles the boundary symmetrically at ±6.74 px, each line hard-edged on the OUTSIDE
and antialiased on the INSIDE, with the fill between them **bit-identical** to the fill outside.
That geometry is not a duplicated scene and not a per-line casing — it is two tiles each drawing
their clip-BUFFER overhang into the other, i.e. tile clipping masks doing nothing.

**Root cause**, all upstream, all `TARGET_OS_SIMULATOR`-gated:

1. `mtl::HeadlessBackend` (platform/default, line 22) asks for an offscreen texture with depth
   **and stencil**.
2. `mtl::OffscreenTextureResource` builds the stencil texture inside `#if !TARGET_OS_SIMULATOR`
   — deliberately, because Metal requires a pipeline's depth and stencil attachment formats to
   match, which is precisely why the DEPTH texture is allocated as the combined
   `PixelFormatDepth32Float_Stencil8` there (`Texture2D::getMetalPixelFormat`).
3. But `bind()` only ever sets `stencilAttachment` from `stencilTexture`. Those combined stencil
   bits are never attached, so the attachment's texture is nil.
4. `Context::makeDepthStencilState` guards with `if (stencilTarget->texture())` — false — so **no
   stencil descriptor is applied to any state**, and every stencil test passes.
5. `renderTileClippingMasks` therefore clips nothing. Same-colour fills hide it; geometry lying
   along the tile-clip edge (a `fill-outline-color`, a polygon boundary) is drawn on both sides
   of every boundary. Hence a pair of seam lines ~2x the tile buffer apart.

**This supersedes the 2026-06-19 finding** that recorded the faint 1-px sim seams as "a simulator
Metal-translation quirk … no mbgl `mtl::HeadlessBackend` patch needed". That bisect was sound as
far as it went (macOS headless clean, iOS on-screen clean, all four present configs identical) but
it stopped at *which tier*, never asking what the simulator `#if`s exclude. Same root cause; the
sea-chart style just makes it obvious where demotiles only showed hairlines.

**Proof, on macOS, with no device.** Forcing both simulator `#if`s on (the `offscreen_texture`
stencil skip and the `texture2d` combined format) and rendering Liberty at z14:

| build | vs the correct frame |
| --- | --- |
| simulator conditions, unfixed | **2.05 % of pixels differ**, concentrated in exactly one 16-px band per tile boundary (x≈412, y≈93) |
| simulator conditions + the fix | **0 pixels differ** (max channel delta 1) |
| macOS with the patch applied | **0 pixels differ** — the new branch is dead off-Simulator |

**The fix**: `patches/metal-simulator-stencil-attachment.patch`, marker `MBL_SIM_STENCIL_ATTACHMENT`
— attach the combined depth texture as the stencil attachment when no separate stencil texture
exists. Simulator-only by construction. Verified to apply to a pristine submodule.
**Upstream-PR candidate**, alongside the text-centring patch.

**Not from this branch, and worth being precise about why:** the submodule pin is byte-identical
between `main` and `HEAD` (`git diff main...HEAD -- third_party/maplibre-native` is empty) and no
patch of ours touches `offscreen_texture.cpp`. What changed was visibility, not behaviour.

### Found in the same pass: `_isShove` thresholded the raw wrapped rotation (this one IS from the branch)

`maplibre_map.dart:805` compared `details.rotation` against the rotate deadzone — the exact trap
§11 documents and that the rotate latch 40 lines below already avoids by using the unwrapped
`_rotationAccum`. Flutter derives that value from `atan2` differences, so the first update of any
two-finger gesture can report ~-6.2 rad; any shove whose fingers were not parallel to the pixel was
rejected outright, making **shove-to-tilt unusable on a device while every test stayed green** —
the existing test moves both fingers by identical deltas, pinning `rotation` at exactly 0.0.
Fixed to use `_rotationAccum`, plus a regression test that puts one finger a single pixel out of
step. Introduced by `6f9fc7e`.

### Reported, deliberately NOT changed: the rotate deadzone leaves a residual bearing

Once the rotate mode latches, per-frame deltas are applied from the latch frame on, so the
deadzone slop is never given back: a pinch that grazes 8° and ends just past it leaves a permanent
sub-degree bearing. The Simulator screenshot was at **+0.33°** with no rotation intended, which is
exactly this. It is a behavioural choice (subtract-the-deadzone vs clamp-the-deadzone), not an
unambiguous defect, and gesture feel is still pending the native-feel A/B — so it is recorded here
rather than changed unasked.

_Append new decisions here with date and rationale._