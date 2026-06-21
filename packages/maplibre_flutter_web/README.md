# maplibre_flutter_web

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

The default web implementation of [`maplibre_flutter`](../maplibre_flutter). Don't depend on this
package directly — depend on `maplibre_flutter`, which endorses it for web.

## How it works

Web renders with the shared **`mbgl-core`** C++ engine — the same engine every other platform uses —
compiled to **WebAssembly** and drawing through **WebGL2** into a `<canvas>` hosted in an
`HtmlElementView`. (A WebGPU backend exists in the core for later use.) Because it is the same engine
everywhere, feature parity is maintained in one place rather than tracked against a separate web SDK.

The WASM/canvas path owns its own gestures: raw pointer and wheel events are handled directly in the
engine glue, so the controller implements the platform controller only — there is no Dart gesture
layer on web. `pointer_interceptor` is still used in the example to wrap Flutter overlay widgets drawn
over the map, but it is **not** applied to the map itself.

## The WASM artifact

The WebAssembly module — `maplibre_flutter_core.js` plus `maplibre_flutter_core.wasm` (~9–10 MB) — is
a **separate Emscripten build** and is **not** produced by `flutter build web`. It is loaded at
runtime, by default from:

```
assets/packages/maplibre_flutter_core/web/maplibre_flutter_core.js
```

Override the location with `--dart-define=MAPLIBRE_WEB_CORE_URL=...`. See
[`docs/experimental-web-core-wasm.md`](https://github.com/Mankeli-Software/maplibre_flutter/blob/main/docs/experimental-web-core-wasm.md)
for how to build and serve it.

## Hosting requirement

The threaded WASM build requires **cross-origin isolation**. Your server must send both of these
response headers, or the module will not start:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

## Optional: maplibre-gl-js renderer

To render with [maplibre-gl-js](https://maplibre.org/maplibre-gl-js/docs/) instead — the mature
reference web renderer, CDN-loaded in kilobytes and needing no special hosting headers — add the
`maplibre_flutter_web_gljs` package to your app. As a direct dependency it overrides this endorsed
default. This is useful for an A/B comparison against the WASM path or for maximum browser coverage.

This stack is still maturing: the WASM path is newer and heavier than gl-js, so for the broadest
compatibility today many apps will add the gl-js package.
