# maplibre_flutter_android_sdk

Opt-in **MapLibre Android SDK** implementation of
[`maplibre_flutter`](https://pub.dev/packages/maplibre_flutter).

The default Android renderer is the shared `mbgl-core` engine (the
`maplibre_flutter_android` package, endorsed automatically). Depend on **this**
package to render with the native MapLibre Android SDK instead:

```yaml
dependencies:
  maplibre_flutter: ^0.0.2
  maplibre_flutter_android_sdk: ^0.0.2 # overrides the core default on Android
```

## Why choose it

- **Native SDK feature stack** — the MapLibre Android SDK's native gesture/fling
  inertia, location component, annotations, and accessibility.
- **A/B testing** — compare the native SDK against the shared core engine.

How it works: renders the SDK's `MapView` inside an `AndroidView`
(`PlatformViewHandle`); control flows Dart → jni → a thin Kotlin/Java shim
(`MapRegistry`/`MapLibreController`), with no data-path method channel
(CLAUDE.md §3, §5b). Smaller `minSdk` (21) than the core path (26).

> Note: the jnigen-bound shim classes keep their original
> `dev.maplibreflutter.maplibre_flutter_android` source package (only the gradle
> `namespace` differs) so the committed bindings stay valid; regenerate with
> `dart run tool/jnigen.dart` after changing their public API (the example app
> must depend on this package for jnigen's classpath resolution).
