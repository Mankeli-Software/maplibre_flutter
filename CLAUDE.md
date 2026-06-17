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
- **TODO (build order, Section 8):** native side of every platform impl is a stub —
  `createMap()` throws `UnimplementedError`. Platform packages declare only `dartPluginClass`
  (web: `pluginClass`); the hybrid `pluginClass` + native folders land per platform as its
  build-order step is implemented. No `mbgl-core` submodule yet; the core shim is still the
  template `sum`/`sum_long_running`.

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

- Requires the Android project to be **built at least once** before generating.
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
- Prefer **`ObjCCompatibleSwiftFileInput`** (for already-`@objc` Swift we control) over
  `SwiftFileInput` — fewer surprises.
- Always set ffigen **`include` filters** to your own interfaces/protocols, or you generate
  hundreds of lines of `NSObject`/`NSString` bindings.
- For observer/notification callbacks use **`implementAsListener(...)`** (non-blocking).
- **SDK-version workaround:** `Target.iOSArm64Latest()` can throw `FormatException`; resolve
  the SDK path/version via `xcrun --sdk iphoneos --show-sdk-path/--show-sdk-version` and
  build `Target` manually.
- Produces **two** files — Dart bindings (`lib/src/..._ios.g.dart`) and ObjC glue
  (`ios/Classes/....m`). **Commit both.** The `.m` must be covered by the podspec
  (`s.source_files = 'Classes/**/*'`).
- **SPM (+ CocoaPods) packaging** is mandatory — see Section 9.

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
1. **Android** ← *current focus after base* — jnigen + Kotlin SDK, `AndroidView`. Lowest risk.
2. **iOS** — swiftgen + Apple SDK, `UiKitView`. Mirrors Android; completes the mobile tier.
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
  `maplibre_flutter_android`, `maplibre_flutter_ios`, …). Still engage the MapLibre org
  before publishing.
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

_Append new decisions here with date and rationale._