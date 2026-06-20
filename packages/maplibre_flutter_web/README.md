# maplibre_flutter_web

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

The web implementation of [`maplibre_flutter`](../maplibre_flutter). Don't depend on this package
directly — depend on `maplibre_flutter`, which endorses it for web.

## How it works

Web renders with [maplibre-gl-js](https://maplibre.org/maplibre-gl-js/docs/) (pinned **5.24.0**) —
the same MapLibre rendering you get natively elsewhere, drawn by the browser's own WebGL — embedded
in an `HtmlElementView`. It is bound with **`dart:js_interop` + `package:web`** (no `package:js`, so
it is WASM-safe and works under `dart2wasm`). The `maplibregl.Map` is built in the platform-view
factory, and the controller's `onReady` completes on the JS `'load'` event.

Like the mobile tier (and unlike the desktop core tier), web follows the **SDK model**:
maplibre-gl-js owns gestures, inertia, and zoom natively, so the controller implements
`MapLibreMapController` **only** — there is no Dart gesture layer on web. `LatLng(lat, lng)` is
flipped to maplibre's `[lng, lat]` at every boundary, and `map.remove()` frees the WebGL context on
dispose (browsers cap the number of live contexts).

The maplibre-gl-js script and its (required) CSS are **injected into `document.head` at runtime** the
first time a map is created — idempotent, and no `index.html` edit needed.

## Setup

Nothing is required for the map itself. Two things to know:

1. **CSP-locked apps.** If your Content-Security-Policy blocks runtime-injected remote scripts, add
   the pinned script + stylesheet to your `web/index.html` `<head>` instead — the plugin detects the
   existing global and skips injection:

   ```html
   <link href="https://unpkg.com/maplibre-gl@5.24.0/dist/maplibre-gl.css" rel="stylesheet" />
   <script src="https://unpkg.com/maplibre-gl@5.24.0/dist/maplibre-gl.js"></script>
   ```

2. **Flutter widgets drawn over the map.** On web the map is a DOM element under the Flutter scene,
   so buttons / drawers / modals painted on top of it must wrap in
   [`PointerInterceptor`](https://pub.dev/packages/pointer_interceptor) or their taps leak through to
   the map (see the example app's controls). This is **not** needed for the map widget itself — it
   receives pointer / scroll events natively.

## Experimental: native-core rendering (WASM)

An **opt-in, build-time-flagged spike** renders web through the same native MapLibre engine
(`mbgl-core`) the desktop tier uses, compiled to WebAssembly, instead of maplibre-gl-js — so feature
parity can be maintained in one engine with no separate web SDK. It is **off by default** and not
yet functional end-to-end (it needs a separately built WASM artifact):

```bash
flutter build web --dart-define=MAPLIBRE_WEB_CORE=true
```

With the flag off (the default), nothing changes — maplibre-gl-js renders as described above. See the
[feasibility study](https://github.com/Mankeli-Software/maplibre_flutter/blob/main/docs/experimental-web-core-wasm.md)
for the architecture, build path, and status.
