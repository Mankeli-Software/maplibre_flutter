# Validation matrix — core-primary inversion

What still needs validating after the inversion (`feat/core-primary-inversion`), and on which
device. The inversion is **code-complete and analyze/build-verified on the dev Mac**; what
remains is **on-device render + interaction** confirmation, because building proves the SDK is
excluded but not that the core path looks/feels right.

## Already verified on the dev Mac (don't redo)

- `melos analyze` green across all 13 members; `melos format` clean.
- `melos test:web` (both web packages, headless Chrome) + `flutter build web` green.
- `flutter build apk --debug` → bundles `libmaplibre_flutter_core.so` + `libmaplibre_flutter_android_jni.so`, **no MapLibre Android SDK `.so`** (SDK excluded).
- `flutter build ios --simulator` → bundles `maplibre_flutter_core.framework` + `maplibre_flutter_ios.framework`, **no `MapLibre.framework`**, **zero duplicate-class warnings** (duplicate-symbol blocker gone).
- iOS swiftgen bindings regenerated (`dart run tool/swiftgen.dart`) → byte-identical to committed.
- Known **pre-existing** failing VM test (NOT from this work): `maplibre_map_test.dart › "pinch
  zoom freezes its anchor"` — fails on base `e6a677e` too; a gesture-anchor question, separate.

## Follow-up: smooth / springy pinch-to-zoom (unimplemented feature)

Pinch-to-zoom works but is **not smooth/springy yet** — this is a missing feature, not a bug.
The pinch applies the raw per-frame `scaleBy` directly (`maplibre_map.dart` `_onScaleUpdate`,
`TODO(pinch-zoom)`), so the zoom tracks the gesture 1:1 with no interpolation toward the target
and no release momentum (no easing/spring), unlike the pan fling. Implement gesture
interpolation + a zoom-release inertia/spring so the zoom eases and settles smoothly. Schedule
alongside the on-device gesture-feel A/B (matrix #6/#10/#12).

(Separate and unrelated: the pre-existing `"pinch zoom freezes its anchor"` test failure noted
above is about the zoom *anchor*, not about smoothing.)

## The matrix

Priority: **P0** = validates a headline claim of the inversion (core-as-default render, or
SDK-exclusion at runtime). **P1** = zero-copy default behavior. **P2** = regression / nice-to-have.

| # | Pri | Platform | Device | Validate | Command | Pass criterion |
|---|-----|----------|--------|----------|---------|----------------|
| 1 | P0 | iOS | **physical iPhone** | Core is the default renderer, on device | `flutter run -d <iphone>` (no flags) | Real map renders, retina-sharp, smooth pan/zoom/fly-to + style toggle. No SDK in the bundle. |
| 2 | P0 | iOS | physical iPhone | **SDK opt-in override + swiftgen rename resolves at runtime** | add `maplibre_flutter_ios_sdk` + `dependency_overrides` to drop `maplibre_flutter_ios` (see recipe), `flutter run -d <iphone>` | MLNMapView/UiKitView map renders; camera/style work → proves the renamed `maplibre_flutter_ios_sdk.MapLibreController` ObjC lookup resolves. No `maplibre_flutter_core.framework` in the bundle. |
| 3 | P1 | iOS | physical iPhone | Zero-copy default (IOSurface) | #1, watch perf | Smooth; if you set `--dart-define=MAPLIBRE_ZEROCOPY=false` it still renders (CPU fallback). |
| 4 | P2 | iOS | Apple-Silicon Simulator | Core renders on sim | `flutter run -d <sim>` | Map renders (faint tile seams are a known **sim-only** cosmetic quirk — ignore; clean on device). |
| 5 | P0 | Android | **physical device** | Core is the default renderer, on device | `flutter run -d <android>` (no flags) | Real map renders, crisp, smooth pan/zoom/fly-to + style toggle. |
| 6 | P1 | Android | physical device | **Zero-copy default (EGL window surface) — first real-device test** | #5; map must not be white | Map renders (zero-copy composites on a real GPU). If white, that's the SurfaceProducer/EGL path failing — set `--dart-define=MAPLIBRE_ZEROCOPY=false` and confirm CPU path renders, then file it. |
| 7 | P0 | Android | physical device | **SDK opt-in override + jnigen still resolves** | add `maplibre_flutter_android_sdk` (see recipe), `flutter run -d <android>` | AndroidView/MapView renders; camera/style work → proves the jnigen bindings resolve with the kept source package + new gradle namespace. |
| 8 | P2 | Android | arm64 emulator | Core renders via CPU fallback | `flutter run -d emulator` | Map renders (NOT white) — emulator can't composite zero-copy, so the CPU `ANativeWindow` present must catch it. |
| 9 | P0 | Windows | **Windows 11 box** | Core default renders + interactive; no fly-to crash | `flutter run -d windows` | Map renders, pan/zoom/fly-to + style work; rapid fly-to/zoom does **not** crash (Vulkan backend). |
| 10 | P1 | Windows | Windows 11 box (Intel UHD 630) | **Zero-copy now default — must fall back cleanly on Intel** | #9 | Map renders (the D3D11 legacy-shared-handle import is unsupported on this Intel driver, so it must auto-fall-back to CPU — confirm not white, no crash). On a discrete GPU it would use the GPU path (untested). |
| 11 | P0 | Linux | **Razer Blade (Ubuntu)** | Core default renders + interactive | `flutter run -d linux` | Map renders, pan/zoom/fly-to + style work. |
| 12 | P1 | Linux | Razer Blade (Intel iGPU) | Zero-copy now default (dmabuf) | #11 | Map renders (dmabuf activates or falls back to CPU — either way not white). `MAPLIBRE_ZEROCOPY=false` forces CPU. |
| 13 | P2 | macOS | dev Mac | Regression — core default unchanged | `flutter run -d macos` | Map renders, smooth (this platform was already core; the inversion didn't touch it). |
| 14 | P0 | Web | Chrome/Edge | **gl-js opt-in override renders** | add `maplibre_flutter_web_gljs` (see recipe), `flutter run -d chrome` | maplibre-gl-js map renders + interactive (no special server needed). |
| 15 | P0 | Web | Chrome/Edge + **COOP/COEP server** | Core-WASM default renders | build the WASM artifact (emsdk, on the Windows box) → serve with COOP/COEP → load the example | mbgl-core WASM map renders + pans. **Blocked until WASM artifact productionization is done** (asset bundling + serve config). Until then the default web build compiles but the loader throws a clear "artifact missing" error. |

## A/B recipe — switching a platform to its opt-in renderer

The default build uses mbgl-core everywhere. To validate an opt-in renderer, add its package to
**`packages/maplibre_flutter/example/pubspec.yaml`** and re-run:

```yaml
dependencies:
  maplibre_flutter: ^0.0.2
  # pick the platform(s) you're A/B-ing:
  maplibre_flutter_android_sdk: ^0.0.2   # Android → MapLibre Android SDK
  maplibre_flutter_ios_sdk: ^0.0.2       # iOS → MapLibre Apple SDK
  maplibre_flutter_web_gljs: ^0.0.2      # Web → maplibre-gl-js

# iOS ONLY: the core iOS package is still pulled transitively (it's the endorsed default), and
# both build on mbgl → duplicate symbols. Exclude it for the SDK A/B build:
dependency_overrides:
  # there is no clean "remove a transitive dep" in pub; the practical A/B is a dedicated example
  # flavor pubspec that depends on the impl packages directly without maplibre_flutter's iOS
  # default. For Android/web, just adding the *_sdk/_gljs package is enough (no duplicate-symbol
  # issue), since the override simply wins endorsement.
```

> Android + web: adding the `*_sdk` / `*_gljs` package is sufficient — it wins endorsement, and
> the core native code on the *other* platforms is unaffected. The duplicate-symbol caveat is
> iOS-specific (both paths build on mbgl). For a clean iOS SDK-only build, use an example flavor
> whose pubspec depends on `maplibre_flutter_ios_sdk` (and not the core iOS package) directly.
> `git checkout` the example's pubspec churn after A/B testing.

## What each P0 de-risks

- **#1 / #5 / #9 / #11** — the core engine is genuinely the default and looks/feels right on real
  hardware on every platform (build ≠ renders-correctly; assert real map content, not just a frame).
- **#2** — the iOS swiftgen module rename (`maplibre_flutter_ios_sdk.*`) resolves over the ObjC
  runtime on device (the one thing the byte-identical regen can't prove without running).
- **#7** — the Android jnigen bindings still resolve after the package split.
- **#14 / #15** — the opt-in override mechanism works on web; the WASM default actually renders.
