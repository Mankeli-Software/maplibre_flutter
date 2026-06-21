# maplibre_flutter_ios

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

The iOS implementation of [`maplibre_flutter`](../maplibre_flutter). Don't depend on this package
directly — depend on `maplibre_flutter`, which endorses it for iOS.

## How it works

This is the **default, endorsed** iOS renderer. It renders with the shared **mbgl-core** C++ engine
(via [`maplibre_flutter_core`](../maplibre_flutter_core)) through **Metal**, drawn off-screen and
presented into a Flutter `Texture` — exactly like macOS. The texture is a `CVPixelBuffer` backed by
mbgl's Metal/IOSurface frame, so `createMap` returns a `TextureHandle` and the **shared desktop Dart
gesture + fly-to tier** drives pan/zoom and the eased camera arc.

### No MapLibre Apple SDK, no symbol duplication

This package no longer links the MapLibre Apple SDK at all — its `Package.swift` and `.podspec`
declare **no** MapLibre dependency. The native engine ships solely via the `maplibre_flutter_core`
build hook, so there is **no mbgl symbol duplication**. This resolves the duplicate-symbol production
blocker that the earlier SDK-plus-core approach hit.

### Rendering — `Texture` over FFI

The native plugin (`MaplibreFlutterIosPlugin`) registers a single texture-registrar `MethodChannel`
(`maplibre_flutter/ios/registrar`); there is no platform-view factory and no method channel on the
per-frame data path. Frames flow over FFI, and the present is a Metal/IOSurface → `CVPixelBuffer`
bridge ported from the macOS tier:

- **Zero-copy present** — wrapping mbgl's IOSurface directly with no readback — is the **default**.
  Disable it with `--dart-define=MAPLIBRE_ZEROCOPY=false`.
- **Continuous render mode** obeys `--dart-define=MAPLIBRE_CONTINUOUS`.

## Packaging — SPM and CocoaPods

The package ships for **both** Swift Package Manager and CocoaPods, so neither migrated nor
unmigrated apps break:

- SPM: `ios/maplibre_flutter_ios/Package.swift` + `Sources/maplibre_flutter_ios/`, depending on
  `FlutterFramework`.
- CocoaPods: `maplibre_flutter_ios.podspec`, kept in sync with the same sources.

The Swift sources are just the texture bridge (`MapLibreCoreTexture.swift` — Metal / IOSurface /
CoreVideo only, with no MapLibre import) plus the plugin.

## Optional: native Apple SDK renderer

To render with the MapLibre Apple SDK instead — a native `MLNMapView` embedded via `UiKitView`, for
A/B testing or to lean on the SDK's native gesture/inertia/accessibility stack — add the
`maplibre_flutter_ios_sdk` package to your app. As a direct dependency it overrides this endorsed
default for iOS.

> ⚠️ **Caveat for A/B builds.** Because both renderers ultimately build on mbgl, a build that pulls
> in *both* the core default and the SDK package will produce **duplicate mbgl symbols**. In that
> case, exclude this core iOS package via `dependency_overrides` so only the SDK's copy is linked.
> The published core default (used on its own) needs no override.
