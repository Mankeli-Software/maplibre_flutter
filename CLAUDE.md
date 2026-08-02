# CLAUDE.md — maplibre_flutter

Guidance for Claude Code (and humans) working in this repository. Read this before making
structural changes. When a decision here conflicts with an ad-hoc request, surface the
conflict rather than silently diverging.

**This file is operative guidance: what is true now, and the rules that still bite.**
History and detail live in dedicated documents — keep them there, not here:

| You want | Read |
| --- | --- |
| Why a decision was made; the root cause of a bug already solved | `docs/decision-log.md` — the full archive, in date order. `grep` it. |
| What to do next, per platform | `docs/cross-platform-continuation.md` |
| Whether feature X is wired on platform Y | `FEATURE_MATRIX.md` |

---

## 1. What this project is

`maplibre_flutter` is a Flutter plugin that renders [MapLibre](https://maplibre.org) vector
maps **natively on every platform** — Android, iOS, macOS, Windows, Linux and Web. The
differentiator versus `maplibre_gl` / `maplibre` is that **one engine drives all six
platforms**: the MapLibre Native C++ core (`mbgl-core`), drawn off-screen and composited
through Flutter, with no `maplibre-gl-js` WebView on desktop.

**Long-term goal:** become the *stable* MapLibre Flutter binding. **Quality and test coverage
are the pitch** — a working native demo plus serious tests is what makes adoption credible.
Prioritize accordingly.

---

## 2. Where the project stands

All six platforms render and are interactive on real hardware. `mbgl-core` (vendored git
submodule, pinned by `MBGL_CORE_VERSION`) is the default renderer everywhere.

| Platform | Backend | Present path | Run on |
| --- | --- | --- | --- |
| **macOS** | Metal | IOSurface zero-copy | device — **the reference tier**, everything is verified here first |
| **Linux** | GL ES3 + EGL | dmabuf zero-copy | hardware (Ubuntu 26.04, Intel iGPU) |
| **Windows** | Vulkan | D3D11 shared handle, CPU fallback | hardware (Win 11; zero-copy falls back to CPU on that Intel driver) |
| **iOS** | Metal | IOSurface zero-copy | physical iPhone 17 Pro Max |
| **Android** | GL ES3 + EGL | CPU `ANativeWindow` blit into a `SurfaceProducer` | arm64 emulator only — needs a physical device |
| **Web** | WASM + WebGL2 | intra-context blit to `<canvas>` | headless Edge + a real GPU |

Opt-in renderer packages (§3), all working: `maplibre_flutter_android_sdk` (jnigen /
`AndroidView`), `maplibre_flutter_ios_sdk` (swiftgen / `UiKitView`),
`maplibre_flutter_web_gljs` (maplibre-gl-js 5.24.0).

### What is not done

- **Running the four unrun tiers.** As of 2026-07-31 all five `mbgl-core` tiers implement every
  capability macOS does — markers, engine layers, queries, the typed style API, 3D models,
  rotate/tilt. macOS and **iOS** (Apple-Silicon Simulator, 5/5 integration tests incl. pixel and
  absolute-direction assertions) have been run; **Android, Windows and Linux have not**. They are
  covered by a 120-assertion controller conformance suite, and by per-platform compile-gate CI jobs
  that are WRITTEN BUT NOT AUTO-TRIGGERED (see the CI item below) — neither of which is the same as
  working. → `docs/cross-platform-continuation.md`.
- **3D models: three of four backends verified.** macOS and iOS on Metal (hardware/Simulator), GL
  under Mesa llvmpipe and Vulkan under Mesa lavapipe, both in
  `packages/maplibre_flutter_core/docker` — all passing the full model_harness including the
  four-face rotation sweep. Unrun: the Windows D3D11 present path and the Android GL ES arm, both
  genuinely platform-bound.
- **Web is the real gap.** Neither web tier implements projector / camera-tick / style-layers, so
  no markers, no engine layers, no typed style API there. The WASM shim's Size/DPR bug is fixed and
  a `web-wasm` CI job exists to compile the Emscripten module — but CI is dispatch-only, so it has
  not run, and none of that C++ has been compiled anywhere.
  → `docs/experimental-web-core-wasm.md`.
- **CI is `workflow_dispatch`-only** pending a cost review, so nothing runs automatically. The
  consequences are real and worth restating: the ffigen and typed-style-API regen-diff checks never
  fire, so committed codegen can drift silently; and the iOS/Android/Linux/Windows compile gates
  and the `web-wasm` Emscripten job never run, leaving `dart analyze` as the only automated check
  over four platforms' native code. All the jobs are written — run them by hand from the Actions
  tab after a core bump or a native change. Uncommenting the triggers in `.github/workflows/ci.yml`
  remains the single highest-value CI action available.
- **Native-feel A/B** (inertia/fling, and now the rotate deadzone + shove and drag sensitivities)
  against the SDKs before tagging anything stable. Rotate INERTIA is deliberately not implemented:
  it needs `TickerProviderStateMixin`, and the single-ticker constraint in the gesture state is
  load-bearing.
- **Upstream PRs not opened** for the text-centring patch we carry
  (`patches/text-centre-anchor-on-ink.patch`). It fixes a real MapLibre defect — centre-anchored
  text is centred on a hardcoded baseline constant, not on font metrics — that affects the web
  engine identically. Needs an issue + PR on `maplibre-native` and a PR on `maplibre-gl-js`
  (mirror written, untested).
  → `docs/upstream-text-centring/`.
- **Upstream PR not opened** for the Simulator stencil patch we carry
  (`patches/metal-simulator-stencil-attachment.patch`). mbgl's offscreen Metal renderable never
  attaches the stencil buffer under `TARGET_OS_SIMULATOR`, so every stencil test passes and tile
  clipping masks stop clipping — silently, with no Metal validation error. Affects every consumer
  rendering offscreen Metal on the Simulator. Needs an issue + PR on `maplibre-native`; no gl-js
  mirror (Metal-specific). The one gap in the submission is a committed test — the defect cannot
  execute on macOS, so only a forced reproduction proves it.
  → `docs/upstream-simulator-stencil/`.
- ~~Known failing test: `"pinch zoom freezes its anchor…"`~~ — FIXED 2026-07-31, and it was never
  a stale test: two anchor fixes had collided and left a live touch bug where a two-finger pinch
  anchored on whichever finger moved last. `melos run test` had been red because of it, and
  `failFast` was cancelling three other packages behind it.

---

## 3. Locked architecture decisions

Settled. Revisit only with an explicit decision and an entry appended to `docs/decision-log.md`.

| Decision | Choice |
| --- | --- |
| Package name | `maplibre_flutter` |
| Structure | Package-separated **federated plugin**, **melos** monorepo + pub workspaces |
| Android | **`mbgl-core` via ffigen** (GL ES) + Flutter `Texture` (SurfaceProducer). _Opt-in:_ Android SDK via jnigen (`AndroidView`) in `maplibre_flutter_android_sdk`. |
| iOS | **`mbgl-core` via ffigen** (Metal) + Flutter `Texture` (IOSurface). _Opt-in:_ Apple SDK via swiftgen (`UiKitView`) in `maplibre_flutter_ios_sdk`. |
| macOS | **`mbgl-core` via ffigen** + Metal external texture (`FlutterTexture`) |
| Windows | **`mbgl-core` via ffigen** + Vulkan + GPU-surface / pixel-buffer texture |
| Linux | **`mbgl-core` via ffigen** + GL ES + `FlTextureGL` |
| Web | **`mbgl-core` compiled to WASM** (WebGL2) → `<canvas>` in `HtmlElementView`. _Opt-in:_ maplibre-gl-js (`dart:js_interop`) in `maplibre_flutter_web_gljs`. |

### One engine, optional native renderers

`mbgl-core` is the **default, endorsed renderer on every platform** — one engine, drawn
off-screen and composited through Flutter's texture pipeline (a `<canvas>` via WASM on web).
Gestures and camera are implemented once in Dart over the engine, so a feature wired on one
native platform is wired on all five.

The mature native renderers stay as **opt-in, build-time-excluded** packages, for A/B testing
and for apps that want a native SDK's gesture / annotation / location stack. An app adds one to
**override** the endorsed default for that platform (a direct dependency beats
`default_package`); absent, that renderer's native code never ships.

> **A `--dart-define` cannot do this.** It only tree-shakes Dart; the build hook, Gradle,
> the podspec and `Package.swift` never see it, so both renderers' *native* code would always
> ship. **Package separation is the only mechanism that build-time-excludes a renderer.**

**Do not use `sharedDarwinSource`** — the iOS core package, the iOS SDK package and macOS are
separate federated packages with their own Swift; they diverge by design.

### Rendering is split, the public API is not

Every platform renders off-screen and composites through Flutter's texture pipeline **or** a
platform view. The platform interface is **render-agnostic** — a `sealed MapLibreRenderHandle`
(`TextureHandle` / `PlatformViewHandle` / `ElementViewHandle`); the `MapLibreMap` widget is the
only place that branches on it. The public Dart API (camera, style, layers, sources, queries) is
**identical** across platforms; all divergence stays behind the interface.

> Texture / platform-view registration needs the engine's registrar, reachable only from a
> **native plugin class** — so most platform packages are **hybrid** (`dartPluginClass` +
> `pluginClass`) even when the heavy lifting is FFI.

**Optional capabilities are feature-detected with `is`**, not added to the base contract:
`MapLibreGestureHandler`, `MapLibreMapProjector`, `MapLibreCameraTickNotifier`,
`MapLibreStyleLayers`, `MapLibreModelHost`. A platform that does not implement one degrades
gracefully (e.g. no projector ⇒ no marker overlay). This is how new capabilities land without
rippling through all impls.

**Extend the interface deliberately, not per-platform.** Do not build a platform feature before
the interface can express it — churn in the contract is the most expensive kind of churn.

### Public API shape: controller-on-widget, three-bucket properties

Follows `webview_flutter`'s split: a user-constructible **`MapLibreMapController`** (app-facing,
in `maplibre_flutter`) wraps the per-platform **`MapLibreMapPlatformController`** (what
`createMap` returns, in the platform interface). Users write
`MapLibreMap(controller: c, style: …)` and drive `c` imperatively. The controller is **optional**
(the widget owns an internal one if omitted). There is **no `onMapCreated`**.

Place every property by the **three-bucket rule**:

- **Init-only** → widget (`MapOptions.initialCamera`, creation flags).
- **Mutable + declarative / low-frequency** → widget prop (`MapLibreMap.style`, `.markers`,
  `.models`; pushed via `didUpdateWidget`). The widget is the single source of truth — so there
  is deliberately **no public `controller.setStyle`**.
- **Mutable + imperative / high-frequency / command** → controller, grouped into a
  **namespace** when the surface is large: `controller.camera`, `controller.layers`. The
  namespace is a pure app-facing wrapper forwarding to the flat platform controller, so it does
  not ripple into the interface or the impls.

Dispose ownership: the widget disposes only a controller it created; a user-provided controller
is `detach()`ed on unmount and `dispose()`d by its owner. Controller widget-glue
(`attach`/`detach`/`renderHandle`/`gestureHandler`/`setStyle`/`resize`) is `@internal`.

---

## 4. Repository layout

```
maplibre_flutter/                      # repo root: pub workspace + melos (config in root pubspec.yaml)
└─ packages/
   ├─ maplibre_flutter/                # app-facing: public API + MapLibreMap widget; endorses impls
   │  ├─ example/                      # shared example app (also the manual test harness)
   │  └─ tool/generate_style_api.dart  # typed style API generator (from the vendored style spec)
   ├─ maplibre_flutter_platform_interface/
   ├─ maplibre_flutter_core/           # C-shim over mbgl-core + ffigen bindings; used by ALL native platforms
   │  ├─ third_party/maplibre-native/  # vendored submodule, pinned by MBGL_CORE_VERSION
   │  ├─ patches/                      # mbgl patches, applied idempotently by hook/build.dart
   │  └─ src/web/                      # Emscripten/WASM platform layer + embind module
   ├─ maplibre_flutter_android/        # DEFAULT: core (GL ES) + Texture       (hybrid)
   ├─ maplibre_flutter_ios/            # DEFAULT: core (Metal) + Texture       (hybrid)
   ├─ maplibre_flutter_macos/          # core + Metal texture                  (hybrid)
   ├─ maplibre_flutter_windows/        # core + Vulkan texture                 (hybrid)
   ├─ maplibre_flutter_linux/          # core + GL texture                     (hybrid)
   ├─ maplibre_flutter_web/            # DEFAULT: core → WASM → <canvas>
   ├─ maplibre_flutter_android_sdk/    # OPT-IN: jnigen → Android SDK          (AndroidView)
   ├─ maplibre_flutter_ios_sdk/        # OPT-IN: swiftgen → Apple SDK          (UiKitView)
   └─ maplibre_flutter_web_gljs/       # OPT-IN: maplibre-gl-js via JS interop
```

All **twelve** packages are publishable; only the workspace root and `example` are private.
Siblings depend on each other by **version constraint** (`^x.y.z`), not `path:` — the workspace
links them locally for dev, and `melos version`'s `updateDependentsConstraints` keeps them in
lockstep. Each package carries its own `LICENSE` (BSD-3-Clause), `README.md` and `CHANGELOG.md`.

---

## 5. Binding generators

We use code generators, not method channels. Each is configured by a **Dart script in `tool/`**
(no YAML) and run on demand. **Generated files are committed and never hand-edited.**

### 5a. ffigen — the core (`maplibre_flutter_core/tool/ffigen.dart`)

The primary binding path — every native platform goes through it.

- Dart FFI cannot bind C++: write a **thin C ABI shim** over `mbgl-core`'s C++ API in
  `maplibre_flutter_core/src/`, expose it in a header, and ffigen that header.
- Compiled by `hook/build.dart` via `native_toolchain_cmake`. The asset id is
  `src/maplibre_flutter_core_bindings_generated.dart`.
- **The hook resolves the library two ways.** Submodule vendored (dev/CI) ⇒ build from the
  pinned source. No submodule (a pub.dev consumer; `third_party/` is `.pubignore`d) ⇒ download a
  prebuilt per-`(os,arch)` binary from the matching GitHub release. Force the former with
  `MAPLIBRE_FLUTTER_BUILD_FROM_SOURCE=1`.
- **Regenerate on macOS** (`dart run tool/ffigen.dart`) after any header change and confirm no
  diff — libclang is not available on every box, so bindings sometimes get hand-added in ffigen
  style and *must* be reconciled before merge.
- Long-running calls belong on a **helper isolate**, not the UI isolate, or they drop frames.

### 5b. jnigen — the opt-in Android SDK package (`tool/jnigen.dart`)

Only `maplibre_flutter_android_sdk` uses this.

- **Bind Java, not Kotlin**, for classes in `Config.classes`. jnigen 0.16's summarizer maxes out
  at Kotlin metadata 2.1.0; AGP 9's built-in Kotlin emits 2.3 → `IllegalArgumentException` then
  `FormatException: Unexpected end of input`. So the summarised shim classes (`MapRegistry`,
  `MapLibreController`) are **Java** under `android/src/main/java/`; the rest of the module stays
  Kotlin (only *listed* classes are summarised).
- Keep the bound surface to **primitives + `String`** so SDK types are never summarised.
- Requires the Android project to be **built at least once first** (jnigen reads the *release*
  compile jar), and rebuilt after changing bound classes:
  `./gradlew :maplibre_flutter_android_sdk:bundleLibCompileToJarRelease --rerun-tasks`.
  If generation throws `Unexpected end of input`, rebuild with
  `--no-daemon --refresh-dependencies --rerun-tasks`.
- `addGradleDeps: true` + `androidExample: '../maplibre_flutter/example'` (no example of its own).
- Runtime is `package:jni` **1.0+**, plus `package:jni_flutter` for `Context`/`Activity`
  (`Activity` access currently goes through `PlatformDispatcher.instance.engineId`).
- **`@Keep` everything bound** (`@get:Keep` for Kotlin properties) so R8 does not strip it.
- Callbacks: a Kotlin `interface` → jnigen emits `implement()` + `$Mixin`; use `onX$async: true`
  for non-blocking listeners. `.release()` long-lived JObjects in `dispose()`.

### 5c. swiftgen — the opt-in iOS SDK package (`tool/swiftgen.dart`)

Still experimental — pin versions, expect rough edges. Only `maplibre_flutter_ios_sdk` uses it.

- Exposed Swift must be **`@objc public`** on an **`NSObject`** subclass, with ObjC-compatible
  types only (no Swift structs, payload enums or generics across the boundary).
- **swiftgen COMPILES its inputs** (unlike jnigen, which reads bytecode), so an input must build
  against the **bare SDK** and **cannot import a third-party framework**. Pattern: bound classes
  are Foundation-only and forward through an internal Swift `protocol`; all `MLN*` code lives in a
  **non-input** backend file. Mirrors the Android Java-shim split.
- **Never `@objc(ExplicitName)`.** swiftgen looks the class up by its **module-qualified** runtime
  name (`<module>.<Class>`), which a plain `@objc` gives you. The Swift **module name must equal
  the package name** in both SPM (target) and CocoaPods (pod) or `objc.getClass` fails at runtime.
- **Use named Swift parameters** on multi-arg methods, or you get `unnamed$1…` in Dart.
- Restrict generation with `FfiGeneratorOptions(objectiveC: ObjectiveC(interfaces: Interfaces(
  include: (d) => d.originalName == 'YourClass')))`, else you bind half of Foundation.
- `Target.iOSArm64Latest()` can throw `FormatException`; resolve the SDK via
  `xcrun --sdk iphoneos --show-sdk-path` and build the `Target` by hand.
- Use **`ObjCCompatibleSwiftFileInput`** — it emits no ObjC `.m` in practice, so SPM's
  no-mixed-language rule never bites.

### 5d. Typed style API — generated from the spec (`maplibre_flutter/tool/generate_style_api.dart`)

Reads `third_party/maplibre-native/scripts/style-spec-reference/v8.json` (the same file mbgl
generates its own C++ layer classes from) and emits `lib/src/style/generated/*.g.dart`:
10 layer types, 6 source types, 33 enums, 84 expression builders. Coverage is **discovered from
the spec, never allowlisted**, so a spec change surfaces in CI's regen-diff instead of rotting.

- **No C ABI involved** — a typed layer is a pure Dart façade serialising to `addLayerJson`. The
  raw JSON methods stay public as the escape hatch.
- The generator **throws** on a name collision, a reserved word or an unmapped spec type. A
  silent `Object` fallback is how a generated API rots — keep it throwing.
- `Expression extends StyleValue<Never>` is what makes typed properties ergonomic: Dart generics
  are covariant, so one `StyleValue<double>?` parameter accepts both a constant and an expression
  without degrading to `Object?`.

### 5e. Cross-platform Dart wrapper

Bridge with abstract class + factory, each platform file importing only its own bindings.
**Keep a Dart-side field reference to every callback you register** (not just a local) or the GC
can collect the proxy and silently break callbacks. Clear it on dispose.

---

## 6. Tooling & commands

> **melos is pinned to `7.8.1`, not `^7.8.2`.** 7.8.2 bumped `cli_util` to `^0.5.0` but
> `ffigen 20.1.1` pins `cli_util ^0.4.2`, and a pub workspace shares **one** resolution. Bump the
> moment ffigen relaxes it. Same family: **`objective_c` is capped `<9.4.1`** (9.4.1 wants
> `hooks ^2.0.0`, clashing with core's `hooks ^1.0.0`). Melos config lives in the root
> `pubspec.yaml` `melos:` block — melos 7 ignores `melos.yaml` for pub workspaces, and derives
> the package list from `workspace:`.

```bash
# Workspace setup
flutter pub get                       # flutter, not dart — members depend on the Flutter SDK

# Codegen (run from the owning package; outputs are committed)
dart run tool/ffigen.dart             # core — run on macOS
dart run tool/jnigen.dart             # android_sdk — build android once first
dart run tool/swiftgen.dart           # ios_sdk
dart run tool/generate_style_api.dart # maplibre_flutter — typed style API

# Quality (melos is a dev_dependency → `dart run melos …`)
dart run melos run analyze            # dart analyze --fatal-infos, every package
dart run melos run test --no-select   # Flutter packages, VM (web packages excluded — browser-only)
dart run melos run test:web           # the two web packages, headless Chrome
dart run melos run test:native        # pure-Dart/FFI (maplibre_flutter_core); builds the shim
dart run melos run format

# Manual verification
cd packages/maplibre_flutter/example && flutter run -d <android|ios|macos|windows|linux|chrome>

# Release
melos version                         # coordinated bump from Conventional Commits
dart run melos run publish:dry-run    # must be clean first
melos publish
```

---

## 7. Testing strategy (first-class)

Extensive tests are a project goal, not an afterthought. Layers:

1. **Platform-interface unit tests** — the contract is the spine; test it with a mock impl.
   Churn here is the most expensive kind.
2. **Dart-wrapper unit tests** — each platform wrapper with its generated bindings mocked:
   right native calls, right callback/lifecycle references (the GC pitfall deserves a test).
3. **Widget/golden tests** — `MapLibreMap`: correct render-handle branch, lifecycle, dispose,
   gesture behaviour (the pinch-anchor regression test runs device-free).
4. **Native tests** — the C shim via ctest-style harnesses behind
   `MAPLIBRE_FLUTTER_BUILD_HARNESS=ON` (`render_harness`, `model_harness`, `gltf_probe`,
   `proj_probe`, `drive_probe`), plus Kotlin/Swift where logic lives below the binding.
5. **Integration tests** (`integration_test/`) — a real map on a real device per platform.
6. **CI matrix** — one runner per OS; because codegen output is committed, CI also regenerates
   and `git diff --exit-code`s it (ffigen + the typed style API).

**Two rules that came from real escaped bugs — apply them or the test is theatre:**

- **"A frame came back" does not prove the map is visible.** The Windows blank-map bug passed a
  green integration test for exactly that reason. Assert real content: non-blank pixels, expected
  colours, a dumped PNG.
- **Test projections and transforms against absolute directions** (north is up, east is right),
  **never only round-trips.** A symmetric Y flip survived every round-trip test we had, and the
  camera centre is symmetric too — so both were blind to an inverted axis.

---

## 8. Platform build & toolchain requirements

### Android — AGP 9+

The Android packages must build under **AGP 9+** while staying back-compatible with older AGP
that current Flutter supports.

- **Declare `namespace`** in `android {}` — the manifest `package` attribute is gone.
- **Do NOT apply `org.jetbrains.kotlin.android`.** AGP 9 ships built-in Kotlin and applying it
  *fails the build*. (`android.builtInKotlin=false` is a temporary escape hatch removed before
  AGP 10 — do not depend on it. Flutter's migrator re-adds it to the *example*; that is
  Flutter-managed and fine.)
- **Java 17+** (`JavaVersion.VERSION_17`, Kotlin `jvmTarget = JVM_17`).
- Library module (`LibraryExtension`); AGP 9's new DSL removed CommonExtension parameterization.
  `android.newDsl=false` defers adoption if needed.
- Ship **consumer R8/ProGuard keep rules** for jnigen-bound classes and verify minified builds —
  AGP 9.1 changed R8's default repackaging.
- Core-on-Android needs **minSdk 26** (mbgl's `thread.cpp` calls `pthread_getname_np`) and
  **CMake ≥ 3.25** (`sdkmanager 'cmake;3.31.4'` — the SDK's bundled 3.22.1 fails).
- Migration guide: https://docs.flutter.dev/release/breaking-changes/migrate-to-agp-9

### Apple — Swift Package Manager, and keep CocoaPods

Both, until Flutter drops CocoaPods, so neither migrated nor unmigrated apps break.

- **Layout**: `ios/<package>/Package.swift` + `Sources/<package>/`.
- **`Package.swift`**: `swift-tools-version: 5.9`; `.iOS("13.0")` / `.macOS("10.15")`; the
  **library name uses `-`** where the package name has `_`; depend on `FlutterFramework`.
- **Keep the `.podspec` in sync** with the `Sources/…` paths.
- `.gitignore` `.build/` and `.swiftpm/`.
- **CI must build the example both ways**: `flutter config --enable-swift-package-manager`, then
  `--no-enable-swift-package-manager`.
- Flutter applies SPM/Pod integration at **build time**; the resulting churn in the example's
  `ios`/`macos` xcconfig / pbxproj / Podfiles is **ephemeral and must not be committed**.
- macOS uses `Package.swift` too, but the `mbgl-core` C/C++ build is driven by **CMake via the
  core package**, never SPM.
- Recommended for editing: add the plugin as a **local Swift package** in the example app so
  Xcode resolves symbols properly.

### Windows

Visual Studio 2022 + "Desktop development with C++"; **vcpkg** at `VCPKG_ROOT` (the build hook
runs `vcpkg install` and passes the toolchain file via CMake defines); Developer Mode **and**
`LongPathsEnabled` (Flutter plugin symlinks + deep paths). A custom static triplet links deps
into `maplibre_flutter_core.dll`, so there are no runtime DLLs to bundle.

---

## 9. Conventions

- **Casing of "MapLibre":** Dart **identifiers** use brand casing `MapLibre` (`MapLibreMap`,
  `MapLibreMapController`). **Package names, file names, library names, asset ids and pubspec
  keys stay snake_case `maplibre_…`.** So `class MapLibreMap` lives in `maplibre_flutter`.
- **Dart style:** `dart format`; `dart analyze --fatal-infos` clean (an unused import in a
  *generated* file is therefore a build break). Public API gets dartdoc.
- **Commits:** Conventional Commits — they drive `melos version`.
- **Generated code:** committed, never hand-edited, regenerated only via `tool/` scripts.
- **Native source:** Kotlin/Java in `android/`, `@objc` Swift in `ios/`, C++/C-shim in
  `maplibre_flutter_core/src/`.
- **No method channels on the data path** — bindings only. Channel use is limited to what the
  texture/platform-view registrar requires.
- **mbgl is a pinned submodule with no upstream patch mechanism.** Changes to it ship as a
  committed patch in `maplibre_flutter_core/patches/`, applied **idempotently** by
  `hook/build.dart` (marker check → `git apply` → verify marker → fail loud). **Patch order
  matters** and patches must be regenerated against a *pristine* submodule.
- **Always use the newest stable packages.** Check pub.dev before adding or pinning anything;
  run `flutter pub outdated` across the workspace periodically. Re-verify any version named in
  this file rather than trusting it. (Exceptions: the melos and `objective_c` pins in §6, which
  exist for a documented reason.)

### API naming policy

**Settled 2026-08-01.** Rationale in `docs/decision-log.md`; per-row citations in
`docs/api-parity-binding-spec.md`. **Copy upstream naming and shape; do not invent our own.**
Where the three canonical APIs disagree, the winner is fixed here so it is not re-litigated
feature by feature — that is how a binding ends up with `getPosition` next to `setGeoJsonData`
next to `addPoints`, three vocabularies in one class.

| Surface | Vocabulary to copy |
| --- | --- |
| Style / source / layer / image / camera **verbs** | **maplibre-gl-js.** `jumpTo`/`easeTo`/`flyTo`/`fitBounds`/`panBy`/`zoomTo`/`rotateTo`/`resetNorth`/`stop`; `addSource`/`addLayer`/`moveLayer`/`getLayersOrder`; `setPaintProperty`/`setLayoutProperty`/`setFilter`/`setLayerZoomRange`; `setData`; `queryRenderedFeatures`/`querySourceFeatures`/`setFeatureState`; `addImage`/`hasImage`/`listImages`; `setMinZoom`/`setMaxZoom`/`setMinPitch`/`setMaxPitch`/`setMaxBounds`. It is the only upstream whose vocabulary is style-spec-adjacent and complete. |
| Coordinate and camera **nouns** | **mbgl / Android.** `LatLng`, `LatLngBounds(southwest:, northeast:)`, `center`, `zoom`, `bearing`, `pitch`, `anchor`. **Never `LngLat`/`LngLatBounds`** — our point type is `LatLng(lat, lng)` and axis order is the #1 bug class (§11). `anchor` beats gl-js's `around` because mbgl (`camera.hpp`) and every line of our shim already say anchor. `bearing` not `direction`/`heading`; `pitch` not `tilt`; `zoom` not `zoomLevel`. |
| Gesture enable/disable **toggles** | **Android SDK `UiSettings`.** `rotateGesturesEnabled`, `tiltGesturesEnabled` (both already shipped), plus `scrollGesturesEnabled`, `zoomGesturesEnabled`, `doubleTapZoomEnabled`, `quickZoomEnabled`. gl-js's names are DOM-input-flavoured — `scrollZoom`, `boxZoom`, `dragRotate` mean nothing on a phone — and `google_maps_flutter` and `maplibre_gl` have both converged on `…GesturesEnabled`. **Where Android's toggle is coarser than the gestures we actually recognise, split it with the same `…Enabled` suffix; never mix in a gl-js handler name.** |
| What gl-js has **no vocabulary for** | **Apple SDK shapes.** Offline (`MLNOfflineStorage` / `MLNOfflinePack` / `MLNTilePyramidOfflineRegion`), snapshotter (`MLNMapSnapshotter` / `MLNMapSnapshotOptions`), location (`MLNUserLocation` / `MLNLocationManager` / `MLNUserTrackingMode`), tile-server & auth (`MLNSettings` / `MLNTileServerOptions` — a static configure-before-first-map surface, because mbgl caches file sources by `(type, ResourceOptions)` so per-map keys would mint a second cache DB), camera-change reason (`MLNCameraChangeReason`, a bitmask). |
| Boundary **value types** | **Flutter's own.** `Duration` (never ms ints), `Color` (never CSS strings), `Rect`, `Offset`, `EdgeInsets` (never a bespoke `PaddingOptions`), `Alignment`, `Curve` (a `Cubic` maps 1:1 onto mbgl's `UnitBezier`), `Size` + `devicePixelRatio`. Sizes are **logical points** everywhere, never CSS or device pixels. |

**Three deliberate adaptations** — Flutter idiom beats upstream mechanism, and each is a choice,
not an accident:

1. gl-js `map.on('move', …)` → **`Listenable onCameraChanged`**, so it drops into
   `ListenableBuilder`/`Flow(repaint:)`. A `Stream` would force a rebuild per camera tick at
   60–120 Hz. It is *not* a substitute for the discrete signals: `onCameraMoveStart` /
   `onCameraMoveEnd` carry the reason separately.
2. gl-js `map.on('error', …)` → **`Stream<MapLibreError>`** over a `sealed class MapLibreError`,
   so failures are exhaustively switchable instead of string-keyed.
3. gl-js's nine `anchor` **strings** (`'bottom-left'`, …) → Flutter **`Alignment`**. Note the word
   is overloaded and both senses are kept: a marker's `Alignment` **anchor**, and the camera's
   pixel **anchor** (gl-js `around`).

**Deliberate divergences, each with a reason:** `LatLngBounds` over gl-js `LngLatBounds` (above);
`apexZoom` for gl-js `flyTo({minZoom})`, because `minZoom` already means a hard constraint in the
same namespace; Apple's persistent-vs-transient padding **split** carrying gl-js's word `padding`;
declarative widget props with no public `controller.setStyle` (§3).

**Renames.** Each is cheap now and breaking after 1.0, so each lands with a `@Deprecated` alias
for one release. **Do not add new API under a left-hand name.** DONE ones are listed so the
deprecated aliases are recognisable as scheduled removals rather than live API:

| Today | Becomes | Stage |
| --- | --- | --- |
| ~~`camera.move(MapCamera, {Duration?})`~~ | `camera.jumpTo` / `easeTo` / `flyTo` — DONE, `move` is deprecated | 3 |
| ~~`camera.getPosition()`~~ | `camera.getCamera()` — DONE, matches the platform interface and `MLNMapCamera` | 3 |
| ~~`controller.layers`~~ | `controller.style` — DONE; it owns sources, images and transitions | 5 |
| ~~`layers.setGeoJsonData(id, json)`~~ | `style.setSourceData(id, data)` / `style.getSource(id).setData(…)` — DONE | 5 |
| ~~`layers.addPoints` / `setPoints` / `removePoints`~~ | `style.addCircleLayersFromPoints` (returns a `MapLibrePointLayers` owning its generated ids) / `setPointsData` / `removeCircleLayersFromPoints` — DONE. It is a macro over one source and up to three layers, not spec API | 5 |
| `MapLibreQueriedFeature` | `QueriedFeature` (gl-js `MapGeoJSONFeature`) over a sealed `GeoJsonFeature` | 1, 6 |

---

## 10. Key references

- Flutter — developing packages & plugins: https://docs.flutter.dev/packages-and-plugins/developing-packages
- Flutter — migrate to AGP 9: https://docs.flutter.dev/release/breaking-changes/migrate-to-agp-9
- Flutter — SPM for plugin authors: https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors
- jnigen & swiftgen in 2026 (Roszkowski): https://roszkowski.dev/2026/swiftgen-jnigen/
- MapLibre Native platform docs: https://maplibre.org/maplibre-native/docs/book/platforms/
- MapLibre Style Spec: https://maplibre.org/maplibre-style-spec/ — machine-readable copy vendored
  at `third_party/maplibre-native/scripts/style-spec-reference/v8.json`
- Prior art (KMP, same core-on-desktop move): maplibre-compose

### Documents in this repo

| Document | What it is |
| --- | --- |
| `docs/decision-log.md` | **The archive.** Every decision, root cause and gotcha, in date order. |
| `docs/cross-platform-continuation.md` | What to do next, per platform. Read before picking the work back up. |
| `FEATURE_MATRIX.md` | Per-feature × per-platform parity backlog. |
| `docs/building-from-source.md` | How consumers build the engine today, and why prebuilts aren't live yet. |
| `docs/upstream-text-centring/` | An upstream MapLibre defect we patch: centre-anchored text is not centred. Evidence images, measurements, and the **TODO to open the upstream PRs**. |
| `docs/upstream-simulator-stencil/` | An upstream MapLibre defect we patch: the offscreen Metal renderable never attaches the stencil buffer on the iOS Simulator, so tile clipping masks stop clipping. Evidence images, measurements, and the **TODO to open the upstream PR**. |
| `docs/accessibility.md` | The state of the art across every MapLibre binding, what WCAG 2.2 actually demands of a map, and the design. **No Flutter map package ships accessible map content** — this is the gap. |
| `docs/upstream-apple-a11y-vendor-gate/` | An upstream MapLibre defect we do NOT patch: the Apple SDK's per-feature VoiceOver elements are gated behind `isMapboxStreets`, so they are dead on every non-Mapbox style. The highest-leverage a11y fix in the ecosystem, and the **TODO to open the upstream PR**. |
| `docs/typed-style-api.md` | Design of the generated typed style API (built). |
| `docs/experimental-web-core-wasm.md` | mbgl-core → WASM: status, build steps, what's left. |
| `docs/3d-models-research.md` | How 3D models work in MapLibre; the implementation plan. |
| `docs/core-primary-inversion-{plan,validation}.md` | The 2026-06-21 inversion and its validation matrix. |

---

## 11. Hard-won rules

Each of these cost a debugging session. They are not general advice — they are this codebase's
specific traps. The *why* for every one is in `docs/decision-log.md`.

### Coordinates and conventions

> **The recurring failure mode of this project.** Every one of these looked right and rendered
> *something*, hiding behind a symmetry — a static model, a heading of 180°, a round-trip, the
> map centre. Take a convention from the source data or the spec and **verify it with an
> asymmetric fixture**; never infer it from what usually works.

- `TransformState::latLngToScreenCoordinate` returns a **bottom-left-origin y**; mbgl's **gesture
  anchors are top-left**. The shim flips. Getting this wrong mirrors every marker vertically
  about the map centre and no round-trip test will catch it.
- **Gesture anchors pass through to mbgl unchanged on every desktop platform** — no flip. The
  present-path blit flips the *pixel buffer* only. **Never blind-port one platform's controller
  change to a sibling citing a shared core**: that exact move flipped the Windows pinch anchor.
  Verify on that hardware, or leave it on the proven convention.
- The **input device matters**. Trackpad pinch (`onScaleUpdate`, a drifting focal centroid on
  Windows/Linux) and mouse wheel (`onPointerSignal`) are different code paths with different
  bugs. Confirm *how* the user reproduces before diagnosing.
- **The map must never outrank Flutter's own arbitration, and the thing that can is the GLOBAL
  POINTER ROUTE** in `_DesktopMapGestures`. It bypasses hit testing entirely, so while it fired on
  "the pointer is inside the map's rectangle" no widget an app could place above the map was able to
  stop the map stealing the wheel and the trackpad. It is now gated on the true cursor
  *hit-testing* to the map, which is all it was ever for (GTK reports a stale pan-zoom position).
  **Keep it that narrow.** An overlay that hit-tests opaquely then stops the map by itself, and apps
  need nothing in their widget tree — which is the bar for this API. Note web is a different
  mechanism entirely: the map is a DOM element there, so overlays need `PointerInterceptor`.
- **A stand-in test that reproduces the HANDLER proves nothing about a widget that also registers a
  global route.** One passed while the real `MapLibreMap` still zoomed, and the mismatch was written
  off as an unexplained anomaly for half a day. Arbitration is a property of everything registered,
  not of the handler — so a fix about arbitration must be tested against the real widget.
- **Decoration is paint; paint has no bearing on hit testing.** A `DecoratedBox` looks solid and
  hit-tests as a hole — that is why the attribution bar leaked gestures to the map. `Container(color:)`
  and `ColoredBox` are opaque; `DecoratedBox` is not.
- mbgl's **model matrix takes X/Y in world pixels but Z in metres**, and map model space is
  **left-handed** (X east, Y south, Z up) — so the standard `rotate_z` is already clockwise from
  above; negating it runs headings backwards.

### Threading and GPU

- **Never call EGL/GL on the platform thread in a Flutter Linux plugin** — only on the raster
  thread (`populate` / texture callbacks). It has no current context, and the resulting
  `PlatformException` crashed `createMap`.
- **`EGLImageKHR` and `EGLSync` are EGLDisplay-scoped** and cannot cross mbgl's render context to
  Flutter's raster context — they use different displays. Share via a **dmabuf** (kernel fd) on
  Linux, IOSurface on Apple, a D3D11 shared handle on Windows.
- Windows: Flutter's consumer needs a **legacy** DXGI shared handle (no keyed mutex); some drivers
  can only import the NT handle into Vulkan. Detect and fall back to CPU. ANGLE share-handle
  textures **must be `DXGI_FORMAT_B8G8R8A8_UNORM`** or the map is white.
- Web: **`glFlush()` after blitting to the canvas** in an rAF callback. Under ANGLE/D3D11 the blit
  can sit unsubmitted and the browser composites a stale canvas.
- **Never hold a lock across an mbgl `FileSource::Callback`** — it can re-enter and destroy the
  request, deadlocking on a non-recursive mutex. Release before delivering.
- Bracket any GL work you do around mbgl with save/restore: its `State<>` bind cache skips
  redundant binds, so desyncing it makes mbgl render into the wrong framebuffer.
- Coalesce render commands — drain the queue and render once at the latest state. Zero-copy's win
  is on **discrete** GPUs; on unified memory it is ~parity with the CPU readback.
- Continuous mode is **update-driven, not vsync-driven**: a change that never touches mbgl needs
  an explicit `Map::triggerRepaint()`.
- Camera commands are applied on the render thread, so the newest transform runs *ahead* of the
  frame on screen. Anchored overlays must project against the **presented** generation
  (`mbl_map_presented_generation`) or they swim.
- **An engine-native camera animation reports only its END.** `easeTo`/`flyTo`/`fitBounds` run
  inside mbgl and fire `transitionFinishFn` once (on finish *or* supersession) — so a controller
  that ticks the camera only where Dart applies a step is silent for the whole flight, and every
  glued widget overlay freezes until it lands. `_awaitCameraMove` returns through
  `tickWhileAnimating` for exactly this reason. **Any new engine-driven animated command must do the
  same**; only `jumpTo` and the Dart-stepped `moveCamera(duration:)` tick on their own.

### mbgl behaviour

- **Loading a style overwrites style-level state** — transition options are replaced by the
  document's, and **every custom layer is dropped**. Re-apply from `onDidFinishLoadingStyle`.
- **mbgl injects its own annotation layers into EVERY style**, on every load:
  `AnnotationManager::updateStyle()` adds `org.maplibre.annotations.points` (and
  `…annotations.shape.<n>` per shape) whether or not anything uses them. They are in no style
  document and have no gl-js counterpart, so `mbl_map_get_layer_ids` filters them out of the
  listing by prefix — reachable by id, just not enumerated. A `contains` assertion cannot see this;
  assert the exact layer list.
- The style JSON path buys the whole spec through `convertJSON<T>`. Parse **synchronously on the
  calling thread** (it needs no map) so bad JSON throws immediately; post only the mutation.
- `mbgl::LatLng`'s constructor **throws on NaN/inf/|lat|>90**, and a throw across `extern "C"` is
  UB. Sanitize before constructing.
- Symbol layers **fade** (300 ms placement transition) and circle layers do not — hence cluster
  counts outliving their bubbles. Every mbgl lever here is style-wide; we deliberately do not
  work around it. `layers.setTransitionOptions` exists as an opt-in escape hatch.
- `IndexVector` is **uint16** — 65536 vertices per *drawable*, so large meshes must be split.
- Raw `CustomLayer` is a dead end off OpenGL (`CustomLayerFactory` is `#ifdef`-gated);
  `CustomDrawableLayer` is the portable escape hatch.
- Pitch is clamped to `DEFAULT_PITCH_MAX` = 60°.
- **Two of mbgl's own camera primitives are broken; do not use either.**
  `Transform::rotateBy` computes `sqrt(pow(2, offset.x) + pow(2, offset.y))` — 2ˣ+2ʸ, not x²+y² —
  so its centre-nudge heuristic always fires left/above centre and never right/below.
  `Map::pitchBy` **subtracts** its argument, so `pitchBy(+10)` tilts down. Build both on
  `jumpTo(CameraOptions().withBearing(…).withAnchor(…))` / `.withPitch(…)`, as
  `mbl_map_rotate_by`/`mbl_map_pitch_by` do. Both are upstream-PR candidates.
- **`CameraOptions::anchor` is silently discarded whenever `center` is set**
  (`transform.cpp`: `anchor = camera.center ? nullopt : camera.anchor`). Since `mbl_map_set_camera`
  always sends a centre, an anchored rotate/zoom can never be implemented as get-camera-then-
  set-camera — and a centre-anchored test cannot detect it, because the centre is a fixed point
  either way.
- **`ScaleUpdateDetails.rotation` arrives WRAPPED.** Flutter derives it from `atan2` differences, so
  a geometric 4.6° twist can be reported as −6.203 rad. Thresholding the raw value means the
  deadzone is exceeded on the first update of *any* two-finger gesture. Unwrap each frame's delta
  into (−π, π] and accumulate your own total.

### Verification traps

- **GDI screen capture cannot capture Flutter's ANGLE/D3D external texture** — `CopyFromScreen`
  and `PrintWindow` show the map area **white** even when it renders correctly. Verify with core
  diagnostics or a harness PNG, never a Windows screenshot.
- **`Flow` reports the LAYOUT origin for a child it did not paint**, so `tester.getCenter` on a
  marker the overlay skipped returns ~(0,0) rather than throwing — which reads as "the marker is in
  the wrong place" instead of "it was culled". Check whether the point is actually on screen before
  believing a projection failure.
- **The Android emulator cannot composite a GPU-produced `SurfaceProducer` buffer** (a foreign
  EGL context's HardwareBuffer). Zero-copy reads as white there in *every* configuration; it is a
  documented emulator bug, not ours. Do not chase it — use a physical device. CPU present works.
- **"Simulator-only" is a symptom, not a diagnosis.** The iOS-Simulator tile seams were written
  off for six weeks as a Metal-translation quirk because they were clean on device and on macOS.
  The actual cause was a real upstream bug: `mtl::OffscreenTextureResource` creates the stencil
  texture inside `#if !TARGET_OS_SIMULATOR` and never attaches the combined depth-stencil
  texture it allocates instead, so `makeDepthStencilState` applies no stencil descriptor and
  **every stencil test passes** — tile clipping masks stop clipping and each tile draws its
  buffered overhang over its neighbours. Fixed by `patches/metal-simulator-stencil-attachment.patch`.
  When a platform is the only one showing an artifact, look for what that platform's `#if`s
  actually exclude before concluding the platform is lying.
- A warm browser profile serves a cached `.wasm` despite `Cache-Control: no-store` — relaunch
  headless Edge with a fresh `--user-data-dir` after rebuilding.

### Flutter / Dart

- **`createTicker()` does an inherited-widget lookup**, so a lazy `late final _ticker = …`
  constructs it inside `dispose()` when it never ran, asserting on a deactivated element. Create
  tickers in `initState`.
- **`RenderRepaintBoundary.toImage()` waits on a real raster-pipeline callback** that
  `flutter_test`'s fake async never delivers. Rasterizer tests **must** use `tester.runAsync` or
  they hang to the 10-minute timeout.
- `pointer_interceptor` on web is for **overlays drawn over the map**, not the map itself — the
  map is the top DOM element and gets pointer events natively.
- `LatLng(lat, lng)` ⇄ maplibre `[lng, lat]` — flip at *every* boundary. The #1 source of web bugs.

### Build system

- **A new `extern "C"` entry point in `maplibre_flutter_core.cpp` must go AFTER the anonymous
  namespace closes.** One opens at ~line 371 and does not close for another 900 lines, so a function
  added "next to the code it relates to" silently gets internal linkage, is dead-stripped, and fails
  at runtime with `dlsym: symbol not found` — while the header, the declaration and
  `FFI_PLUGIN_EXPORT` all look right. `nm` showing the symbol absent *entirely* (not even mangled) is
  the tell.

- **`set_source_files_properties` is directory-scoped** and silently no-ops for a target defined
  in a submodule subdirectory. Use `target_compile_definitions`.
- Upstream mbgl forces warnings-as-errors unconditionally on some arms; append the relaxing flag
  last (`/WX-` on MSVC, `-Wno-error` under Emscripten) when a newer compiler than upstream's CI
  flags something new. Also `/bigobj` on MSVC.
- `CORE_ONLY=ON` everywhere — otherwise mbgl's root CMake drags in glfw, tests and render-test.
  We hand-attach the platform sources per arm instead.
- Exactly **one** renderer backend flag may be set (`validate-backend-options.cmake`).
- Emscripten: `PTHREAD_POOL_SIZE` must be pre-allocated, and fetches need a **bounded worker
  pool** — thread-per-request exhausts the pool on a heavy style and deadlocks.

---

## 12. Decision log

Moved to **`docs/decision-log.md`** — it had grown past 1500 lines and is history, not guidance.
**Append new decisions there**, with the date and the rationale, and pull anything with ongoing
operative value up into §11 here.
