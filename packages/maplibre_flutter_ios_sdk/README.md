# maplibre_flutter_ios_sdk

Opt-in **MapLibre Apple SDK** implementation of
[`maplibre_flutter`](https://pub.dev/packages/maplibre_flutter).

The default iOS renderer is the shared `mbgl-core` engine (the
`maplibre_flutter_ios` package, endorsed automatically). Depend on **this** package
to render with the native MapLibre Apple SDK instead:

```yaml
dependencies:
  maplibre_flutter: ^0.0.2
  maplibre_flutter_ios_sdk: ^0.0.2 # overrides the core default on iOS
```

> **Important (iOS):** the default `maplibre_flutter_ios` and this SDK package both
> ultimately build on mbgl. To avoid duplicate mbgl symbols in an A/B build that
> pulls both, exclude the core iOS package for that build via a
> `dependency_overrides` entry (or a dedicated example flavor). The published core
> default needs no override.

## Why choose it

- **Native SDK feature stack** — the MapLibre Apple SDK's native gesture/fling
  inertia, location, annotations, and accessibility.
- **A/B testing** — compare the native SDK against the shared core engine.

How it works: renders `MLNMapView` inside a `UiKitView` (`PlatformViewHandle`);
control flows Dart → the Objective-C runtime → a Foundation-only swiftgen shim
(`MapLibreController`/`MapRegistry`) that forwards to a MapLibre-backed `ops`
implementation, with no data-path method channel (CLAUDE.md §3, §5b). Packaged for
both Swift Package Manager and CocoaPods (§9).

> Note: the swiftgen module name equals this package name
> (`maplibre_flutter_ios_sdk`), so the bound classes' module-qualified runtime
> names resolve. Regenerate with `dart run tool/swiftgen.dart` after changing the
> `@objc` shim surface.
