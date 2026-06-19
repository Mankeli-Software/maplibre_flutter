# maplibre_flutter_platform_interface

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

The common platform interface for the [`maplibre_flutter`](../maplibre_flutter) plugin. Every
platform implementation extends `MapLibreFlutterPlatform`; app code depends on
`maplibre_flutter`, not this package.

This contract is the spine of the federated plugin — it is deliberately **render-agnostic**, so
the same public Dart API drives a native SDK view, a desktop GPU texture, or a web DOM element
without the caller ever knowing which.

## The contract

### `MapLibreFlutterPlatform`

The entrypoint each implementation registers via its `registerWith()`. There is **no default
`MethodChannel` implementation** — `MapLibreFlutterPlatform.instance` throws `UnimplementedError`
until a platform package sets it (the project keeps method channels off the data path; bindings
carry the traffic instead). It extends Flutter's `PlatformInterface` with a private token, so an
implementation that forgets to call `super` is rejected. Its one method, `createMap(MapOptions)`,
returns a `MapLibreMapController`.

### `MapLibreMapController`

A handle to one live map. The contract is identical on every platform; only `renderHandle`
reveals how the map is embedded:

- `renderHandle` — the embedding strategy (see below).
- `onReady` — completes once the native map exists and has loaded its initial style. Until then
  camera reads report the initial camera and mutations are best-effort no-ops, so callers should
  await it before driving the map.
- `getCamera()` / `moveCamera(camera, {duration})` — read and set the camera; implementations
  animate when `duration` is non-null.
- `setStyle(styleUri)` — replace the active style (URL, asset path, or inline JSON).
- `resize(size, devicePixelRatio)` — desktop sizes its off-screen surface to the widget; the
  mobile/web platform-view tier auto-sizes and ignores it (default no-op).
- `dispose()` — release native resources, callbacks, and the texture/view registration.

### `MapLibreRenderHandle` — the render split

A `sealed` type with exactly three variants; the app-facing widget switches on it and nothing
else does:

| Handle | Embed as | Tier |
| ------ | -------- | ---- |
| `PlatformViewHandle` (`viewType`, `creationParams`) | `AndroidView` / `UiKitView` | Mobile SDK |
| `TextureHandle` (`textureId`) | `Texture` | Desktop core |
| `ElementViewHandle` (`viewType`) | `HtmlElementView` | Web |

`creationParams` is how the mobile tier passes initial config (style + camera) through the
platform-view registrar rather than a data-path channel.

### `MapLibreGestureHandler`

An optional interface the **desktop** (texture) controllers also implement, exposing `moveBy(dx, dy)`
and `scaleBy(scale, anchorX, anchorY)` in logical pixels. The widget drives these from Flutter
gestures so the whole desktop tier shares one pan/zoom implementation. Mobile and web controllers
do **not** implement it — their native views / maplibre-gl-js own gestures — so the widget skips
its Dart gesture layer for them.

### Value types

`LatLng`, `MapCamera` (center / zoom / bearing / pitch, with `copyWith`), and `MapOptions`
(`styleUri` + `initialCamera`) are immutable and re-exported by `maplibre_flutter`.

## Stability

Freezing this API early matters: churn in the contract is the most expensive kind, because every
implementation tracks it. New capability is added here first, deliberately, then implemented per
platform — never the other way around.
