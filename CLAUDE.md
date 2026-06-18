# CLAUDE.md — maplibre_flutter

Guidance for Claude Code (and humans) working in this repository. Read this before
making structural changes. When a decision here conflicts with an ad-hoc request,
surface the conflict rather than silently diverging.

---

## 1. What this project is

`maplibre_flutter` is a Flutter plugin that renders [MapLibre](https://maplibre.org)
vector maps **natively on every platform** — Android, iOS, macOS, Windows, Linux, and
Web. The differentiator versus existing packages (`maplibre_gl`, `maplibre`) is **true
native rendering on desktop** instead of a `maplibre-gl-js` WebView. On desktop we drive
the MapLibre Native C++ core (`mbgl-core`) directly.

**Long-term goal:** become the *stable* MapLibre Flutter binding. This has
consequences that must be respected throughout:

- **Quality and test coverage are the pitch.** A working native-desktop demo plus
  serious tests is what makes adoption credible. Prioritize accordingly.

---

## 2. Current status & migration

The repo was initialised with `flutter create --template=package_ffi maplibre_flutter`,
which produces a **single FFI package** (`lib/`, `src/`, `hook/build.dart`,
`tool/ffigen.dart`) — the recommended way to build and bundle native code since Flutter
3.38. That is **not** the final shape.

**Target shape:** a melos-managed monorepo of federated packages (Section 4). Migrate as
follows, and keep this section updated as steps complete:

- [x] Convert the repo root into a **pub workspace** + melos (Section 6).
- [x] Repurpose the generated FFI package as `packages/maplibre_flutter_core` (the
      `mbgl-core` C-shim + `ffigen` bindings used by the desktop platforms).
- [x] Scaffold the app-facing package, the platform-interface package, and the per-platform
      implementation packages.
- [x] Wire endorsement so app users depend only on `maplibre_flutter`.

The federated structure now exists (all 10 members resolve, analyze, and test). What
is scaffolded vs. still TODO:

- **Done:** pub workspace + melos config (in root `pubspec.yaml`, not `melos.yaml`);
  `maplibre_flutter_core` (renamed FFI pkg, bindings under `lib/src/`, `tool/ffigen.dart`,
  hook asset id fixed to `src/...`); the render-agnostic platform interface + `MapLibreMap`
  widget that switches `Texture` vs platform-view; six platform impl packages registering
  via the interface; example app on the new API; tests for interface/widget/core.
- **In progress (build order, Section 8):**
  - **Android — milestones A + B done.** Hybrid plugin: native module (`android/`, AGP 9,
    built-in Kotlin, MapLibre Android SDK 11.11.0) registers an `AndroidView` factory;
    `MapLibrePlatformView` (Kotlin) builds a `MapView` (`textureMode(true)`, minimal lifecycle)
    from `creationParams`. **Milestone B control layer:** Dart mints a `mapId` → native
    `MapRegistry` registers a `MapLibreController` under it → Dart looks it up over **jnigen** and
    drives camera/style (`getCamera`/`moveCamera`/`setStyle`), main-thread-marshaled in the
    controller. **The two jnigen-bound classes (`MapRegistry`, `MapLibreController`) are Java, not
    Kotlin** — jnigen 0.16's summarizer can't read AGP 9's Kotlin-2.3 metadata (Section 5a). Bindings
    committed at `lib/src/maplibre_flutter_android_bindings.g.dart` (`tool/jnigen.dart`). Example app
    has working zoom / fly-to / style-toggle buttons. `flutter build apk --debug` green;
    `libmaplibre.so` + `libdartjni.so` bundled. Milestone A render confirmed on device; B button
    behaviour pending a device run.
  - **iOS — milestones A + B done.** Hybrid plugin packaged for **both SPM and CocoaPods**
    (§9): native module under `ios/maplibre_flutter_ios/` (`Package.swift` + `Sources/…`, plus
    `maplibre_flutter_ios.podspec`), MapLibre Apple SDK 6.27.0. `MaplibreFlutterIosPlugin`
    registers a `UiKitView` factory; `MapLibrePlatformView` builds an `MLNMapView` from
    `creationParams`. **Milestone B control via swiftgen:** Dart mints `mapId` → native
    `MapRegistry` registers a `MapLibreController` → Dart resolves it over the ObjC runtime and
    drives camera/style. **swiftgen-bound classes are Foundation-only** (`MapLibreController`,
    `MapRegistry`); all `MLN*` usage is quarantined in `MapLibreMapBackend` (not a swiftgen
    input) behind an internal `ops` protocol, because **swiftgen compiles its inputs** and can't
    see the MapLibre framework (Section 5b). Bindings committed at
    `lib/src/maplibre_flutter_ios_bindings.g.dart` (`tool/swiftgen.dart`). Example buttons work
    on iOS unchanged. SPM **and** CocoaPods example builds green; device frame pending a sim run.
  - **macOS — desktop tier complete; smooth on device.** `maplibre_flutter_core` drives `mbgl-core`
    (vendored submodule, pinned `MBGL_CORE_VERSION`) over a C-shim + ffigen, built via
    `native_toolchain_cmake` in `hook/build.dart`, on a dedicated render thread. Two perf wins make
    it production-smooth: **(1) zero-copy present** — the render thread GPU-blits mbgl's Metal
    texture into an IOSurface-backed BGRA texture (compute swizzle, async on mbgl's command queue),
    which `maplibre_flutter_macos`'s hybrid Swift plugin wraps in a CVPixelBuffer for a Flutter
    `Texture` with no CPU readback; **(2) Continuous render mode** — partial frames publish
    immediately and refine as tiles stream in (no per-frame network stall), so fly-to is smooth even
    over detailed/uncached tiles. Both default on, each with a CPU/Static fallback behind a
    `--dart-define` (`MAPLIBRE_ZEROCOPY`, `MAPLIBRE_CONTINUOUS`); Static + CPU-readback stay the
    headless-test path. Control mirrors the mobile controllers over FFI; gestures + the eased fly-to
    arc live in the shared desktop tier (`maplibre_flutter`). Verified on device: rendering solid,
    smooth gestures/zoom/fly-to, stable when idle. Core **distribution** (prebuilt artifacts + CI)
    is the next focus, on `feat/core-distribution`.
  - **Windows / Linux / Web** native sides are still stubs — `createMap()` throws
    `UnimplementedError`; those packages declare only `dartPluginClass` (web: `pluginClass`).
    Windows/Linux will reuse `maplibre_flutter_core`'s `mbgl-core` integration with a
    platform-specific surface.

Still check the tree before editing — package contents are skeletons.

---

## 3. Locked architecture decisions

These are settled. Revisit only with an explicit decision and a note appended to
Section 11.

| Decision     | Choice                                                                                              |
| ------------ | --------------------------------------------------------------------------------------------------- |
| Package name | `maplibre_flutter`                                                                                  |
| Structure    | Package-separated **federated plugin**, **melos** monorepo + pub workspaces                         |
| Android      | **jnigen** against the Kotlin MapLibre SDK; `AndroidView` / `SurfaceTexture`                        |
| iOS          | **swiftgen** against the MapLibre Apple SDK (`MLNMapView`); **`UiKitView` platform view**           |
| macOS        | **`mbgl-core` via ffigen** + **Metal external texture** (`FlutterTexture`)                          |
| Windows      | **`mbgl-core` via ffigen** + OpenGL via ANGLE + GPU-surface/pixel-buffer texture                    |
| Linux        | **`mbgl-core` via ffigen** + native OpenGL + `FlTextureGL`                                          |
| Web          | **maplibre-gl-js** via `dart:js_interop` + `package:web`; `HtmlElementView` + `pointer_interceptor` |

### The two tiers

- **Mobile tier (Android + iOS):** wrap the mature official native SDKs. Best native feel,
  lowest risk, shipped first. Gestures/annotations/location come from the SDK.
- **Desktop tier (macOS + Windows + Linux):** one shared `mbgl-core` integration rendered
  into a GPU texture. macOS lives here (not paired with iOS) so it inherits the same
  hardened core as Windows/Linux. Gestures/camera implemented once in Dart over the core.

Because iOS uses the SDK and macOS uses the core, **do not use `sharedDarwinSource`** — the
two Darwin platforms diverge by design.

### Rendering is split, the public API is not

Every native platform renders **off-screen and composites through Flutter's texture
pipeline OR a platform view**. The platform interface must be **render-agnostic**: mobile
returns a native view to embed; desktop returns a `textureId` for a `Texture` widget. The
public Dart API (camera, style, layers, sources, queries) is **identical** across all
platforms. All divergence stays behind the platform interface.

> Note: texture/platform-view registration needs the engine's texture/view registrar,
> which is only reachable from a **native plugin class**. So most platform packages are
> **hybrid** (`dartPluginClass` + `pluginClass`) even when the heavy lifting is FFI/jnigen/swiftgen.

---

## 4. Repository layout (target)

```
maplibre_flutter/                      # repo root: pub workspace + melos
├─ pubspec.yaml                       # workspace members + melos dev_dep
├─ melos.yaml                         # (or melos block in root pubspec)
├─ CLAUDE.md
└─ packages/
   ├─ maplibre_flutter/                # app-facing: public API + MapLibreMap widget; endorses impls
   │  └─ example/                      # shared example app (also the manual test harness)
   ├─ maplibre_flutter_platform_interface/
   ├─ maplibre_flutter_core/           # C-shim over mbgl-core + ffigen bindings (desktop shared)
   ├─ maplibre_flutter_android/        # jnigen → Kotlin SDK     (hybrid)
   ├─ maplibre_flutter_ios/            # swiftgen → Apple SDK     (hybrid: UiKitView factory)
   ├─ maplibre_flutter_macos/          # ffigen → core + Metal texture (hybrid)
   ├─ maplibre_flutter_windows/        # ffigen → core + texture  (hybrid)
   ├─ maplibre_flutter_linux/          # ffigen → core + texture  (hybrid)
   └─ maplibre_flutter_web/            # maplibre-gl-js via JS interop
```

`mbgl-core` and `maplibre-gl-native` source are vendored as a **git submodule** under
`maplibre_flutter_core` and built via `hook/build.dart` + CMake.

---

## 5. Binding generators

We use code generators rather than method channels. Each generator is configured by a
**Dart script in `tool/`** (the current convention — no more YAML) and run on demand.
**Generated files are committed.** Never hand-edit generated `*.g.dart` / `*.m`.

### 5a. jnigen — Android (`tool/jnigen.dart`)

- **Bind Java, not Kotlin, for the classes in `Config.classes`.** jnigen 0.16's ASM
  summarizer uses a `kotlinx-metadata-jvm` that maxes out at Kotlin metadata 2.1.0, but AGP 9's
  built-in Kotlin emits 2.3 metadata → `IllegalArgumentException: ... version 2.3.0, while
  maximum supported version is 2.1.0` then `FormatException: Unexpected end of input`. So the
  jnigen-summarised shim classes (e.g. `MapRegistry`, `MapLibreController`) live in
  `android/src/main/java/...` as **Java**. The rest of the module stays Kotlin — only *listed*
  classes are summarised, and referenced `org.maplibre.*` types stay opaque `JObject`. Revisit
  if jnigen bumps its metadata lib.
- Keep the bound surface **primitives + `String`** so referenced SDK types are never summarised
  (avoids both the metadata issue and binding bloat).
- Requires the Android project to be **built at least once** before generating — and rebuilt
  after changing the bound classes, since jnigen reads the **release** compile jar. Quick path:
  `./gradlew :maplibre_flutter_android:bundleLibCompileToJarRelease --rerun-tasks` in
  `packages/maplibre_flutter/example/android`, then re-run the tool.
- `addGradleDeps: true` + `androidExample: '../maplibre_flutter/example'` (this plugin has no
  example of its own; the app-facing example builds it).
- Uses `jni` **1.0+** runtime (`package:jni`, plus `package:jni_flutter` for `Context`/
  `Activity`; current `Activity` access needs `PlatformDispatcher.instance.engineId`).
- List **every** class to bind in `Config.classes`. Output a single file under `lib/src/`.
- **Callbacks:** define a Kotlin `interface`; jnigen generates `implement()` + `$Mixin`.
  Use `onX$async: true` for non-blocking listener callbacks (we almost always want this).
- **Annotate everything bound with `@Keep`** (`@get:Keep` for Kotlin properties) so R8 does
  not strip it.
- **Memory:** references are GC-managed, but call `.release()` on long-lived JObjects /
  callbacks in `dispose()`.
- **Regen quirk:** if generation throws `Unexpected end of input`, rebuild gradle without
  cache: `./gradlew :maplibre_flutter_android:assembleDebug --no-daemon --refresh-dependencies --rerun-tasks` then re-run the tool.
- **AGP 9+ build config** is mandatory — see Section 9.

### 5b. swiftgen — iOS (`tool/swiftgen.dart`)

swiftgen is **still experimental** — pin versions and expect rough edges.

- Swift exposed to Dart must be **`@objc public`** and classes must inherit **`NSObject`**.
  Only ObjC-compatible types (no Swift structs, enums-with-payload, or generics across the
  boundary).
- Use **`ObjCCompatibleSwiftFileInput`** for already-`@objc` Swift we control (no wrapper
  layer). With it, **no ObjC `.m` glue is emitted** in practice (the `Output.objectiveCFile`
  path is required but stays unwritten) — so the SPM "no mixed Swift+ObjC in one target" rule
  never bites, and the bindings work purely over the ObjC runtime via `package:objective_c`.
- **swiftgen COMPILES its input files** (unlike jnigen, which reads compiled bytecode). So an
  input must build against the **bare SDK** — it **cannot import a third-party framework**
  (e.g. `MapLibre`). Pattern (see `maplibre_flutter_ios`): keep the bound classes Foundation-only
  and forward to an internal Swift `protocol`; put all `MLN*` code in a **non-input** backend
  file that implements the protocol. Mirrors the Android Java-shim split.
- **Do NOT use `@objc(ExplicitName)`.** swiftgen looks the class up by its **module-qualified**
  runtime name (`<module>.<Class>`, e.g. `maplibre_flutter_ios.MapLibreController`), which is the
  Swift default for a plain `@objc` class. An explicit name unqualifies the runtime class and
  breaks `objc.getClass`. The Swift **module name must equal the plugin package name** in both
  SPM (target name) and CocoaPods (pod name) so the qualified name matches at runtime.
- **Use named Swift parameters** on multi-arg methods (`func moveCamera(lat:lng:…)`), or the
  ObjC selector `moveCamera::::` generates ugly Dart params (`unnamed$1…`). Named labels →
  `moveCameraWithLat(lat, {lng, zoom, …})`.
- Restrict generation with **`FfiGeneratorOptions(objectiveC: ObjectiveC(interfaces:
  Interfaces(include: (d) => d.originalName == 'YourClass')))`**, else you bind half of
  Foundation. (A `SEVERE` enum warning about pulled-in `NS*` enums is non-fatal.)
- **SDK-version workaround:** `Target.iOSArm64Latest()` can throw `FormatException`; resolve the
  SDK path via `xcrun --sdk iphoneos --show-sdk-path` and build `Target(triple:'arm64-apple-ios13.0', sdk:…)`.
- Commit the generated **`lib/src/..._bindings.g.dart`**. Deps: `objective_c` + `ffi` (runtime);
  `swiftgen` + `ffigen`/`logging`/`pub_semver` (the tool imports these directly). **`objective_c`
  is capped `<9.4.1`** — 9.4.1 needs `hooks ^2.0.0`, clashing with core's `hooks ^1.0.0` in the
  shared workspace resolution (same single-resolution constraint as the melos pin, §6).
- **SPM + CocoaPods both build** (§9). Flutter applies the example's SPM/Pod integration at
  **build time** (ephemeral) — toggling `--enable-swift-package-manager` mutates the example's
  `ios`/`macos` xcconfig + pbxproj + generates Podfiles; `git checkout` that churn after CI-style
  dual builds, it is regenerated on demand and should not be committed.

### 5c. ffigen — desktop core (`tool/ffigen.dart`)

- Dart FFI cannot bind C++ directly: write a **thin C ABI shim** over `mbgl-core`'s C++ API
  in `maplibre_flutter_core/src/`, expose it via a header, and `ffigen` that header.
- Compiled by `hook/build.dart` (CMake). Long-running calls go on a **helper isolate**
  (see `sumAsync` pattern in the template) to avoid dropping frames.

### 5d. Cross-platform Dart wrapper

Neither generator emits a unified API. Bridge with the **abstract-class + factory** pattern,
each platform file importing only its own bindings:

```dart
abstract class MapLibreFlutterPlatform {
  // ... render-agnostic contract (see Section 3) ...
}
// app-facing widget picks UiKitView/AndroidView vs Texture(textureId) internally.
```

**Keep a Dart-side field reference to every callback** you register (not just a local), or
the Dart GC can collect the proxy and silently break callbacks. Clear it on dispose.

---

## 6. Tooling & commands

Pin current versions before relying on these (jni 1.x, ffigen, swiftgen-experimental —
**always check pub.dev for the newest stable**, see Section 10; melos↔pub-workspace config
has shifted across 6→7).

> **melos is pinned to `7.8.1`, not `^7.8.2`.** melos 7.8.2 bumped `cli_util` to `^0.5.0`,
> but `ffigen 20.1.1` (used by `maplibre_flutter_core`) pins `cli_util ^0.4.2`, and a pub
> workspace shares **one** resolution. 7.8.1 is the newest melos still on `cli_util ^0.4.2`.
> Bump it the moment ffigen relaxes `cli_util`. melos config lives in the **root
> `pubspec.yaml` `melos:` block** (melos 7 ignores `melos.yaml` for pub workspaces); the
> package list is derived from the `workspace:` field.

```bash
# Workspace setup
flutter pub get                               # resolves all workspace members (flutter, not dart — members depend on the Flutter SDK)

# Codegen (run from the owning package)
dart run tool/jnigen.dart                      # android — build android once first
dart run tool/swiftgen.dart                    # ios
dart run tool/ffigen.dart                      # core/desktop

# Quality (via melos scripts; melos is a dev_dependency → `dart run melos ...`)
dart run melos run analyze
dart run melos run test --no-select            # flutter packages; --no-select runs all non-interactively
dart run melos run test:native                 # pure-Dart/FFI (maplibre_flutter_core)
dart run melos run format

# Per-platform example builds (manual verification)
cd packages/maplibre_flutter/example && flutter run -d <android|ios|macos|windows|linux|chrome>

# Release
melos version                                  # coordinated bump, Conventional Commits (command.version block)
dart run melos run publish:dry-run             # `dart pub publish --dry-run` in every non-private package
melos publish                                  # publish in dependency order (after dry-run is clean)
```

All nine federated packages are **publishable** (no `publish_to: none`); only the
workspace root and `example` stay private. Siblings depend on each other by **version
constraint** (`^x.y.z`), not `path:` — the pub workspace links them locally for dev, and
`command.version.updateDependentsConstraints` keeps the constraints in lockstep on bump.
Each package carries its own `LICENSE` (BSD-3-Clause), `README.md`, and `CHANGELOG.md`.

---

## 7. Testing strategy (first-class)

Extensive tests are a project goal, not an afterthought. Layers:

1. **Platform-interface unit tests** — the contract is the spine; test it with a mock
   implementation. Freeze this API early; churn here is the most expensive kind.
2. **Dart-wrapper unit tests** — each platform wrapper with its **generated bindings
   mocked**, verifying we call the right native methods and manage callback/lifecycle
   references correctly (the GC-reference pitfall above deserves explicit tests).
3. **Widget/golden tests** — `MapLibreMap` widget: correct branch (platform view vs
   `Texture`) per platform, lifecycle, dispose.
4. **Native unit tests** — Kotlin (JUnit), Swift (XCTest), and C++ shim (ctest/GoogleTest)
   for logic that lives below the binding.
5. **Integration tests** (`integration_test/`) — real map on a real device/emulator per
   platform: style loads, camera moves, a frame is actually produced.
6. **CI matrix** — one runner per platform; each native target must build on its own OS.
   Codegen outputs are committed, so CI also **verifies generated files are up to date**
   (regenerate and `git diff --exit-code`).

Reference: Flutter "Testing plugins" and "Handle plugin code in tests".

---

## 8. Build order (one platform at a time)

Build the base architecture first, then implement platforms in this order. Keep the
**current focus** marker accurate.

0. **Base architecture** — workspace + melos, platform-interface contract, app-facing widget
   shell that switches view-vs-texture, and an end-to-end **solid-colour texture** through a
   `Texture` widget on one platform to prove the plumbing (no MapLibre yet).
1. **Android** — jnigen + Kotlin SDK, `AndroidView`. Lowest risk. *Done (A visible map + B jnigen
   control); confirmed on device.*
2. **iOS** — swiftgen + Apple SDK, `UiKitView`. Mirrors Android; completes the mobile tier.
   *Done (A visible map + B swiftgen control); SPM + CocoaPods both build. Device sim frame
   pending. ← current focus moves to step 3 (desktop core).*
3. **Desktop core** — `maplibre_flutter_core`: C-shim + `mbgl-core` submodule + ffigen, render
   a real frame into a texture. Then **Linux** (`FlTextureGL`) → **Windows** (ANGLE + GPU
   surface) → **macOS** (Metal). Start with CPU readback (pixel-buffer) for correctness, then
   optimise to zero-copy GPU texture sharing. The **Linux GL-context/threading** integration
   is the single biggest risk — budget for it.
4. **Web** — maplibre-gl-js JS interop, `HtmlElementView` + `pointer_interceptor`.

Do not start a platform before the platform interface can express what it needs; extend the
interface deliberately, not per-platform.

---

## 9. Platform build & toolchain requirements

### Android — must be AGP 9+ compatible

The Android implementation package must build cleanly under **Android Gradle Plugin 9+**
(while staying back-compatible with the older AGP versions current Flutter still supports).
In `maplibre_flutter_android/android/build.gradle(.kts)`:

- **Declare `namespace`** in the `android {}` block. The manifest `package` attribute is gone
  as of AGP 8/9 and is no longer a valid place to set it.
- **Do NOT apply `org.jetbrains.kotlin.android` (`kotlin-android`).** AGP 9 ships **built-in
  Kotlin** and applying that plugin now *fails the build* ("no longer required since AGP 9").
  Rely on built-in Kotlin. (`android.builtInKotlin=false` is only a temporary escape hatch,
  removed before AGP 10 — do not depend on it.)
- **Java 17+**: `sourceCompatibility`/`targetCompatibility = JavaVersion.VERSION_17` and Kotlin
  `jvmTarget = JVM_17`.
- This is a **library** module (`LibraryExtension`). If custom Gradle/variant code is added,
  account for AGP 9's new-DSL changes (CommonExtension parameterization removed; block methods
  moved onto `LibraryExtension`). `android.newDsl=false` can defer new-DSL adoption if needed.
- Ship **consumer R8/ProGuard keep rules** for the jnigen-bound classes (we already `@Keep`;
  AGP 9.1 changed R8's default repackaging, so explicitly verify release/minified builds).
- After the above, re-confirm jnigen's gradle resolution (`addGradleDeps: true`,
  `androidExample: 'example'`) still works under AGP 9.
- Follow the official migration guide: https://docs.flutter.dev/release/breaking-changes/migrate-to-agp-9

### Apple (iOS + macOS) — Swift Package Manager, keep CocoaPods

Native Apple dependencies (MapLibre SDK on iOS; any helper libs / glue on macOS) are managed
with **Swift Package Manager**, while **also keeping CocoaPods** until Flutter drops it.
Flutter's SPM support is still maturing and off by default, and plugins are expected to support
**both** so neither migrated nor unmigrated apps break.

- **Layout** per Apple package: `ios/maplibre_flutter_ios/Package.swift` +
  `Sources/maplibre_flutter_ios/`. Add `Sources/<name>/include/<name>/` when exposing ObjC
  headers — swiftgen's generated `.m` plus any public headers live under `Sources/<name>/`.
- **`Package.swift`**: `swift-tools-version: 5.9`; platforms `.iOS("13.0")` / `.macOS("10.15")`
  (raise if the MapLibre SDK requires newer); **library name uses `-`** when the package name
  has `_` → `.library(name: "maplibre-flutter-ios", targets: ["maplibre_flutter_ios"])`; depend on
  `FlutterFramework` (new in Flutter 3.41); set env `sdk: ^3.11.0`, `flutter: ">=3.41.0"`.
- **Keep `.podspec` in sync** (its `source_files` pointing at the new `Sources/...` paths) so
  CocoaPods consumers still build. The swiftgen `.m` must sit where *both* SPM and the podspec
  pick it up.
- **`.gitignore`**: add `.build/` and `.swiftpm/`.
- **Toggle for testing**: `flutter config --enable-swift-package-manager`. **CI must build the
  example app both ways** — SPM on, then `--no-enable-swift-package-manager` (CocoaPods) — both
  green.
- Recommended: add the plugin as a **local Swift package** in the example app for proper Xcode
  editing support.
- **macOS** uses `Package.swift` the same way even though its renderer is the C++ core — the
  Metal/texture glue and any Apple deps go through `macos/maplibre_flutter_macos/`. The
  `mbgl-core` C/C++ build itself is driven by **CMake via the core package**, not SPM.
- Reference: https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors

---

## 10. Conventions

- **Casing of "MapLibre":** Dart **identifiers** (classes, widgets, enums) use the
  brand casing **`MapLibre`** (capital L) — `MapLibreMap`, `MapLibreFlutterPlatform`,
  `MapLibreMapController`, `MapLibreRenderHandle`. **Package names, file names, library
  names, asset ids, and the `maplibre_flutter` pubspec keys stay snake_case `maplibre_…`**
  (lowercase) — do not rename those. So: `class MapLibreMap` lives in `maplibre_flutter`.
- **Dart style:** `dart format`, `flutter analyze` clean. Public API gets dartdoc.
- **Commits:** Conventional Commits (drives `melos version`).
- **Generated code:** committed, never hand-edited, regenerated via `tool/` scripts only.
- **Native source:** Kotlin in `android/`, `@objc` Swift in `ios/`, C++/C-shim in
  `maplibre_flutter_core/src/`.
- **No method channels** for the data path — bindings only. (Platform-channel use is limited
  to what the platform-view/texture registrar requires.)
- **Always use the newest stable packages.** Before adding or pinning *any* dependency,
  check its current latest stable on pub.dev and pin to that (e.g. melos `^7.8.2` as of this
  writing — verify, it moves). Periodically run `dart pub outdated` / `flutter pub outdated`
  across the workspace and bump; do not let majors go stale. This stack (jni, ffigen, swiftgen,
  melos, MapLibre SDKs) ships fast — treat "is there a newer version?" as a standing check, and
  re-verify versions named anywhere in this file rather than trusting them.
- **Toolchain floors:** Android = AGP 9+ / Java 17 / built-in Kotlin (no `kotlin-android`);
  Apple = SPM **and** CocoaPods. Details in Section 9.

---

## 11. Key references

- Flutter — Developing packages & plugins: https://docs.flutter.dev/packages-and-plugins/developing-packages
- Flutter — Migrate to AGP 9: https://docs.flutter.dev/release/breaking-changes/migrate-to-agp-9
- Flutter — Swift Package Manager for plugin authors: https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors
- AGP 9.0 release notes: https://developer.android.com/build/releases/agp-9-0-0-release-notes
- jnigen & swiftgen in 2026 (Roszkowski): https://roszkowski.dev/2026/swiftgen-jnigen/
- Example: screen_brightness_monitor: https://github.com/orestesgaolin/screen_brightness_monitor
- Example: display_brightness: https://github.com/Mankeli-Software/display_brightness
- MapLibre Native platforms/core docs: https://maplibre.org/maplibre-native/docs/book/platforms/
- Prior art (KMP, same core-on-desktop move): maplibre-compose

---

## 12. Decision log

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

_Append new decisions here with date and rationale._