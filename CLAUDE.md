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
    **Experimental core-on-iOS POC** (`--dart-define=MAPLIBRE_EXPERIMENTAL_CORE=true`, default off):
    the same package can alternatively render `mbgl-core` into a Flutter `Texture` like the desktop
    tier, A/B-able against the SDK on one device — the sanctioned §3 escape hatch. Build chain
    verified on this Mac (mbgl-core compiles for iphoneos incl. the Metal headless backend, links,
    and Flutter frameworks+signs the dylib into the device app); on-device render/gestures pending a
    physical device. See the 2026-06-20 decision-log entry.
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
  - **Web — done (A visible map + B control); builds + tests pass on this machine.**
    `maplibre_flutter_web` renders with **maplibre-gl-js** (the global `maplibregl`, pinned
    `5.24.0`) in an `HtmlElementView`, bound via **`dart:js_interop` + `package:web`** (no
    `package:js`, WASM-safe). The script + (required) CSS are **injected into `document.head` at
    runtime** (idempotent/memoised; reuses a consumer-provided global for CSP-locked apps — no
    `index.html` edit needed). Web mirrors the **mobile** tier: maplibre-gl-js owns gestures
    natively, so the controller implements `MapLibreMapController` only (no `MapLibreGestureHandler`,
    no Dart gesture layer). The JS map is built in the platform-view factory; `onReady` completes on
    the JS `'load'` event; camera/style/resize/dispose forward over interop (`LatLng(lat,lng)` ⇄
    maplibre `[lng,lat]` flipped at every boundary; `map.remove()` frees the WebGL context on
    dispose; the `'load'` callback is field-held against GC, §5d). The app widget's `ElementViewHandle`
    branch renders `HtmlElementView`; **`pointer_interceptor` wraps overlay widgets drawn over the
    map** (the example's controls), *not* the map itself. Verified on this Mac: `flutter build web`
    green; browser unit tests (`melos run test:web`, headless Chrome) + the chrome integration test
    pass. On `feat/web-maplibre-gl-js`.
  - **Linux — verified on real hardware (build + GL render + GUI present).**
    `maplibre_flutter_core` has an **OpenGL ES3 + EGL arm** parallel to the macOS Metal arm
    (CMake split by platform; the Metal code is guarded behind `__APPLE__`; `mbl_map_copy_frame`
    is pixel-format-aware, BGRA/RGBA). `maplibre_flutter_linux` is hybrid: a GTK plugin presents
    frames through an `FlPixelBufferTexture` (CPU pixel buffer; zero-copy `FlTextureGL` later),
    controller mirrors macOS minus IOSurface. First validated headless under Mesa software GL
    (llvmpipe) in Docker via `packages/maplibre_flutter_core/docker/`; **now confirmed on real
    Linux hardware** (2026-06-18, Ubuntu 26.04 / Razer Blade): `flutter build linux` builds clean
    first try, the EGL backend creates a context on the **Intel UHD 630 iGPU** (not llvmpipe), and
    both demotiles + OpenFreeMap Liberty render correctly; the GUI app presents a **smooth** map on
    GNOME/Wayland. **HTTP/2 throttling fixed** (cap the curl source's `max-concurrent-requests`,
    §below) and **zero-copy present added via dmabuf** (opt-in `--dart-define=MAPLIBRE_ZEROCOPY=true`;
    CPU `FlPixelBufferTexture` stays the default + fallback). **Key gotcha:** mbgl's render context
    and Flutter's raster context use **different EGLDisplays**, so an `EGLImageKHR` (display-scoped)
    cannot be shared between them — the first EGLImage-blit attempt went white. The fix is a **Linux
    dmabuf** (a kernel buffer fd, cross-display): the core blits into a ring of RGBA8 textures and
    exports each as a dmabuf (`EGL_MESA_image_dma_buf_export`); the GTK plugin imports it into an
    `FlTextureGL` via `EGL_LINUX_DMA_BUF_EXT`. Sync is `glFlush` + the dmabuf's **implicit kernel
    fence** (cross-display-safe; a `glFinish` or an EGLSync handle would stall / can't cross
    displays). **Confirmed working on device** (2026-06-19): renders correctly, interaction
    (pan/zoom/fly-to/style) works, no white screen. The white-screen bug en route: the
    `registerTextureGl` channel handler ran EGL calls on the **platform thread (no current
    context)** → false failure → uncaught `PlatformException` crashed `createMap`; fixed by doing
    all EGL work in the raster-thread `populate` (general rule: **never call EGL/GL on the platform
    thread in a Flutter Linux plugin**). Perf A/B on the **iGPU** is ~parity with the CPU path —
    expected, since unified memory makes the CPU readback a cheap memcpy, not a PCIe transfer;
    zero-copy's win is on **discrete GPUs**. Remaining Linux: optional dGPU testing (NVIDIA driver
    currently version-mismatched). On `feat/desktop-linux-gl`.
  - **Windows — verified on real hardware; the tier now runs on mbgl's VULKAN backend (the
    ANGLE/OpenGL-ES arm described below was replaced after it crashed on fly-to — see the
    2026-06-19 "Windows Vulkan backend implemented" decision-log entry).** The fly-to/heavy-movement
    0xC0000005 crash is **fixed** (no GL `DrawableGL` path under Vulkan; validated on a Windows 11
    Intel UHD 630 box), the CPU present path renders correctly, and zero-copy
    (`maplibre_flutter_core_vk.cpp`, opt-in `MAPLIBRE_ZEROCOPY=true`) works on GPUs that can import
    the legacy D3D shared handle but falls back to CPU on this Intel driver. _Original ANGLE arm
    (history, superseded by Vulkan):_ The CPU pixel-buffer analog of the Linux tier (reuses
    `maplibre_flutter_core`): a new **ANGLE/EGL arm**
    in the core's `src/CMakeLists.txt` (`MLN_WITH_EGL` → ANGLE `libEGL`/`libGLESv2`,
    `platform/windows` sources + the EGL headless backend; vcpkg deps — mirrors
    `platform/windows/windows.cmake`); a hybrid Windows C++ plugin (`MaplibreFlutterWindowsPlugin`:
    `flutter::TextureRegistrar` + `flutter::PixelBufferTexture` presenting `mbl_map_copy_frame` RGBA
    over the `maplibre_flutter/windows/registrar` channel — `MarkTextureFrameAvailable` is
    thread-safe so the frame callback marks frames directly, no main-loop hop); a Dart controller
    mirroring Linux (CPU path only — no zero-copy in v1) reusing the shared desktop gesture + fly-to
    tier; no widget change (`TextureHandle` already handled). **Confirmed on a Windows 11 box**
    (2026-06-19): `flutter build windows` is green and the Windows integration test renders a real
    frame (ANGLE creates a D3D11 EGL context headlessly on the render thread), moves + reads back the
    camera, and swaps styles. **Deps come from vcpkg via the build hook** (`hook/build.dart` installs
    them + passes the vcpkg toolchain file to the CMake configure); with the static triplet **ANGLE
    links statically into `maplibre_flutter_core.dll`** (~14 MB) so there are **no ANGLE DLLs to
    bundle** — it calls the system d3d11/dxgi/d3dcompiler. Zero-copy (D3D11 shared texture) is the
    remaining optional step. On `feat/desktop-windows-angle`.

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

### Public API shape: controller-on-widget, three-bucket properties

The app-facing API follows `webview_flutter`'s split: a user-constructible
**`MapLibreMapController`** (app-facing, in `maplibre_flutter`) wraps the per-platform
**`MapLibreMapPlatformController`** (the thing `createMap` returns, in the platform interface).
Users do `MapLibreMap(controller: c, style: ...)` and drive `c` imperatively; the controller is
**optional** (the widget owns an internal one if omitted). There is **no `onMapCreated`**.

Properties are placed by a **three-bucket rule** (not just "mutable vs not"):

- **Init-only** → widget (`MapOptions.initialCamera`, creation flags).
- **Mutable + declarative/low-frequency** → widget prop (`MapLibreMap.style`; pushed via
  `didUpdateWidget` → platform `setStyle`). Style's single source of truth is the widget — there
  is **no public `controller.setStyle`** (avoids the declarative/imperative conflict).
- **Mutable + imperative/high-frequency/command** → controller, grouped by sub-domain
  **namespace** when the surface is large. Camera lives under `controller.camera`
  (`MapLibreCameraController`: `move`/`getPosition`/fly/fit/… — 20+ ops expected), not as flat
  methods on the controller. This is the sub-manager pattern (Mapbox's `map.annotations`/
  `map.style`); the namespace is a pure app-facing wrapper forwarding to the (flat) platform
  controller, so it doesn't ripple into the interface or the 6 impls.

Mirrors `google_maps_flutter` (`initialCameraPosition` + declarative `style` + imperative camera).
Dispose ownership: the widget disposes only a controller it created; a user-provided controller is
`detach()`ed on unmount and `dispose()`d by the owner. Controller widget-glue (`attach`/`detach`/
`renderHandle`/`gestureHandler`/`setStyle`/`resize`) is `@internal` (needs `package:meta`).

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
   is the single biggest risk — budget for it. *macOS + Linux + **Windows** all done & verified
   on hardware (CPU present + control); zero-copy done on macOS/Linux, optional on Windows.*
4. **Web** — maplibre-gl-js JS interop, `HtmlElementView` + `pointer_interceptor`. *Done (A
   visible map + B control); `flutter build web` + browser unit/integration tests green on this
   machine. Buildable + runnable here (`flutter run -d chrome`), unlike Linux/Windows.*

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

_Append new decisions here with date and rationale._