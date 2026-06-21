# Plan: make mbgl-core the primary renderer on every platform

**Status:** proposed (2026-06-21). **Owner decisions:** federated package split *now*;
web flips to mbgl-core WASM as default too.

This plan inverts the project's renderer strategy: **mbgl-core becomes the default,
endorsed renderer on all six platforms.** The native SDKs (MapLibre Android/Apple) and
maplibre-gl-js become **secondary, opt-in** paths that live in their own federated
packages, so they are **build-time excluded** from the default build (no binary bloat, no
iOS duplicate-symbol blocker). Zero-copy present becomes the default everywhere it is
supported, with a disable flag and automatic CPU fallback. Then the documentation is
reframed for an initial publish.

> **This reverses two locked decisions** — CLAUDE.md §3 "two tiers" and the 2026-06-19
> "rejected unify-on-one-pipeline" entry, which kept mobile SDKs for native feel/stability
> and made core-on-mobile an opt-in escape hatch. The reversal is intentional. A
> matching §12 decision-log entry is part of this plan (Phase 4). The maturity tradeoff
> (core-on-mobile is POC-grade; native gesture-feel A/B vs the SDK is still open) is
> accepted; the native-feel A/B is recommended before tagging a `stable` release.

---

## 1. Why a `--dart-define` cannot do this

Renderer selection today is a Dart `const bool.fromEnvironment(...)` (`MAPLIBRE_EXPERIMENTAL_CORE`
on mobile, `MAPLIBRE_WEB_CORE` on web). That const tree-shakes the unused **Dart**
controller branch — but it is **invisible to native compilation**. The build hook
(`hook/build.dart`), Gradle, and the iOS podspec/`Package.swift` run in sanitized build
phases that never see dart-defines. Result today:

- **iOS:** `MapLibre.framework` (SDK) **and** `maplibre_flutter_core.framework` both bundle
  unconditionally → duplicate mbgl ObjC classes (the known production blocker) + ~7 MB dead
  weight on SDK builds.
- **Android:** SDK `.aar` **and** core `.so` both bundle unconditionally.
- **Web:** gl-js is CDN-loaded (negligible), but the 9.4 MB core-WASM artifact is not yet
  bundled/distributed at all.

**Conclusion:** the only mechanism that truly excludes the unselected renderer's native
code — and the only one that fixes the iOS duplicate-symbol blocker — is **package
separation (federation).** The choice becomes "is the `_sdk`/`_gljs` package in the app's
pubspec," not a dart-define. That is the spine of this plan.

---

## 2. End-state package layout

Default (core) impls — **endorsed by `maplibre_flutter`**, pulled automatically:

| Package | After | Change |
| --- | --- | --- |
| `maplibre_flutter_android` | **core-only** (mbgl-core GL ES3/EGL → `Texture`) | strip SDK controller + jnigen + SDK gradle dep + `AndroidView` plugin → move to `_sdk`; drop the dart-define branch (always core) |
| `maplibre_flutter_ios` | **core-only** (mbgl-core Metal → `Texture`) | strip SDK controller + swiftgen + Apple SDK SPM/Pod + `UiKitView` plugin → move to `_sdk`; always core. **Kills the duplicate-symbol blocker** (core build no longer links the Apple SDK) |
| `maplibre_flutter_web` | **core-WASM-only** (mbgl-core WASM → canvas/`HtmlElementView`) | strip gl-js controller/loader/interop → move to `_gljs`; always core. **Requires WASM artifact productionization (Phase 3)** |
| `maplibre_flutter_macos` | unchanged (already core) | — |
| `maplibre_flutter_linux` | unchanged renderer | flip zero-copy default ON |
| `maplibre_flutter_windows` | unchanged renderer | flip zero-copy default ON |

New opt-in (secondary) impls — **NOT endorsed**; an app adds them explicitly to A/B:

| New package | Renderer | Receives |
| --- | --- | --- |
| `maplibre_flutter_android_sdk` | MapLibre Android SDK 11.x (jnigen, `AndroidView`) | the moved Android SDK code |
| `maplibre_flutter_ios_sdk` | MapLibre Apple SDK 6.x (swiftgen, `UiKitView`) | the moved iOS SDK code |
| `maplibre_flutter_web_gljs` | maplibre-gl-js 5.x (`HtmlElementView`) | the moved gl-js code |

Net: **10 → 13 workspace members.** Platform interface, `maplibre_flutter_core`, and the
app-facing widget/controller are **unchanged in their public API** (confirmed: the widget
already switches on the sealed `MapLibreRenderHandle`; a core controller returns
`TextureHandle` and implements `MapLibreGestureHandler`, so the shared Dart gesture layer
auto-engages on mobile with zero widget change).

### Endorsement & A/B mechanics

`maplibre_flutter/pubspec.yaml` sets `default_package: maplibre_flutter_<platform>` (now the
core package). A plain `maplibre_flutter` dependency therefore yields a **core-only, clean,
smaller** build — the publish-critical property.

To A/B with an SDK, the app adds e.g. `maplibre_flutter_ios_sdk` (which
`implements: maplibre_flutter` for iOS); Flutter's resolution prefers a directly-depended
implementation over the default_package, so it overrides to the SDK path.

**Known federation wrinkle (must document, see §6):** the endorsed core package is still a
transitive dep of `maplibre_flutter`, so an A/B-SDK build pulls *both* packages — which on
iOS would reintroduce duplicate symbols. The A/B-SDK recipe therefore uses
`dependency_overrides` (or a dedicated example flavor pubspec) to drop the core package for
that build. **The published default (core) is always clean;** only the dev A/B-SDK build
needs the override.

---

## 3. Zero-copy: default ON everywhere supported

| Platform | Today | Action |
| --- | --- | --- |
| macOS | ON | none |
| iOS (core) | ON | none |
| Android (core) | code says ON, 2026-06-20 log says OFF — **reconcile** | verify; keep ON (renderer-name probe → CPU fallback on emulator/software GL) |
| Linux | OFF | `defaultValue: false → true` (`maplibre_flutter_linux_controller.dart`); has capability poll + CPU `FlPixelBufferTexture` fallback |
| Windows | OFF | `defaultValue: false → true` (`maplibre_flutter_windows_controller.dart`); has capability poll + CPU `PixelBufferTexture` fallback (Intel driver → CPU automatically) |

Keep `--dart-define=MAPLIBRE_ZEROCOPY=false` as the documented disable. All paths already
have automatic CPU fallback, so flipping the default is low-risk. **Minor follow-up:** with
default ON, unsupported hardware runs the GPU-interop setup + ~1 s capability poll before
falling back — consider trimming the poll or making it async so startup isn't penalized.

---

## 4. Phased sequence (each phase stays green)

### Phase 0 — Prep & safety net
- Branch `feat/core-primary-inversion`.
- **Before moving any code,** confirm the example runs the core path on each platform via
  the *current* dart-define (`--dart-define=MAPLIBRE_EXPERIMENTAL_CORE=true` mobile,
  `MAPLIBRE_WEB_CORE=true` web) on sim/emulator and, where possible, device. We must know
  core works as a default before relying on it.

### Phase 1 — Zero-copy defaults + docs mindset shift (fast, independent, low-risk)
- Flip Linux + Windows zero-copy defaults; reconcile the Android default.
- Full documentation sweep (§5). Ships the strategy reframe immediately, decoupled from the
  package churn.

### Phase 2 — Mobile federated split
- **2a Android:** scaffold `maplibre_flutter_android_sdk`; move the SDK controller, jnigen
  bindings + `tool/jnigen.dart`, the SDK Gradle dep, and the `AndroidView` plugin there.
  **Regenerate jnigen** against the new package (gradle resolution + class package change).
  Strip those from `maplibre_flutter_android`, make it core-only (delete the dart-define
  branch). Point endorsement default → core.
- **2b iOS:** symmetric. Scaffold `maplibre_flutter_ios_sdk`; move the SDK controller,
  swiftgen bindings + `tool/swiftgen.dart`, the Apple SDK SPM + Pod deps, and the `UiKitView`
  plugin there. **Regenerate swiftgen** — note §5b: the Swift module name must equal the
  package name, so the bound classes' module-qualified runtime names change with the rename.
  `maplibre_flutter_ios` becomes core-only → **duplicate-symbol blocker resolved** (its build
  no longer links the Apple SDK).
- Verify per platform: default example builds **core-only** (smaller, no SDK
  framework/`.aar`); the `_sdk` override builds **SDK-only**.

### Phase 3 — Web split + WASM productionization (riskiest; may gate publish)
- Scaffold `maplibre_flutter_web_gljs`; move the gl-js controller/loader/interop there.
  `maplibre_flutter_web` becomes core-WASM-only.
- **Solve WASM artifact distribution** (the new burden from the web-flip decision):
  - Bundle `maplibre_flutter_core.js` + `.wasm` as `flutter.assets` so `flutter build web`
    ships them; default the loader URL to the bundled asset path.
  - CI: add an Emscripten build job (extend `build-core.yml`) producing + versioning the
    artifact in lockstep with the desktop core (or commit a prebuilt — large, less ideal).
  - **COOP/COEP:** the threaded build needs `Cross-Origin-Opener-Policy: same-origin` +
    `Cross-Origin-Embedder-Policy: require-corp` on the host. Ship a ready serve config +
    docs; evaluate a **single-thread fallback variant** for header-less hosting.
  - Browser coverage: ship the WebGL2 variant (already built via `MLN_WITH_OPENGL`) as the
    baseline; WebGPU for perf later.

### Phase 4 — CI matrix, tests, docs finalize, version prep
- Dual CI per mobile platform: build example **core default** AND **`_sdk` override**. Web:
  **core-WASM** build (emscripten in CI) AND the **`_gljs` override**.
- Keep sim + device runnable: example must run `-d ios` (sim+device), `-d android`
  (emu+device), `-d chrome`, and the three desktops.
- Update endorsement/selection unit tests; widget tests largely unchanged (render-agnostic).
- New CLAUDE.md §12 decision-log entry (the reversal + rationale + date). CHANGELOGs.
  `melos version` prep across all 13 members.

---

## 5. Documentation sweep (publish-readiness)

- **CLAUDE.md §3** decision table: Android/iOS/Web rows → mbgl-core primary; SDK/gl-js = opt-in
  secondary *package*. Rewrite "The two tiers" → "one core tier on all platforms; optional
  native-SDK / gl-js tier behind separate packages." Note `sharedDarwinSource` still banned.
- **CLAUDE.md §2** per-platform statuses: drop "Experimental … default off"; core is the
  default. **§4** layout: add the 3 new packages. **§8** build order: reflect inversion.
- **READMEs:** root, `maplibre_flutter`, `_android`, `_ios`, `_web`, and new READMEs for the 3
  `_sdk`/`_gljs` packages. Flip "How it works" intros from SDK-primary to core-primary; add an
  "Optional: native SDK / gl-js renderer" section pointing at the opt-in package.
- **`docs/experimental-web-core-wasm.md`:** core-WASM is now the web default (restructure /
  retitle away from "experimental"); fold in the artifact-distribution + COOP/COEP guidance.
- CHANGELOGs for every touched package.

---

## 6. Risks & open items

1. **Web WASM productionization is the top publish risk.** Artifact distribution, COOP/COEP
   header requirement, browser coverage, and ~9.4 MB download are real consumer burdens.
   Single-thread fallback + asset bundling + CI build are prerequisites to calling web
   "core-default, publish-ready."
2. **Federation override pulls both packages.** A/B-SDK builds (esp. iOS) must drop the core
   package via `dependency_overrides`/an example flavor or they re-link duplicate symbols.
   Document the recipe. The published core default is clean.
3. **Binding regen on rename.** Moving swiftgen/jnigen bound classes into the renamed `_sdk`
   packages forces regeneration with new module/package-qualified names (swiftgen module ==
   package name, §5b; jnigen gradle resolution + class package, §5a).
4. **Core-on-mobile maturity.** Shipping core as the mobile default trades the SDK's native
   feel/inertia/accessibility for the shared Dart gesture tier. Run the native-feel A/B on
   device before tagging `stable`.
5. **A/B ergonomics get heavier.** The choice is now a dependency swap + `pub get` + rebuild,
   not a one-line dart-define. Provide example flavors / a helper script.
6. **minSdk floor.** Core needs Android API 26; an SDK-only app could target 21, but the core
   default sets the floor at 26 — document.
7. **Zero-copy startup cost on unsupported HW** (the ~1 s poll) — trim/async as a follow-up.
8. **Android zero-copy default contradiction** (code vs. 2026-06-20 log) — reconcile in Phase 1.
