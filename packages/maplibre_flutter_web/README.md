# maplibre_flutter_web

The web implementation of [`maplibre_flutter`](../maplibre_flutter).

Do not depend on this package directly; depend on `maplibre_flutter`, which
endorses this implementation for web.

## How it works

Web renders with [maplibre-gl-js](https://maplibre.org/maplibre-gl-js/docs/) —
the same MapLibre rendering you get natively elsewhere, drawn by the browser's
own WebGL — embedded in an `HtmlElementView`. It is bound with `dart:js_interop`
+ `package:web` (no `package:js`, WASM-safe). maplibre-gl-js owns gestures and
inertia natively, so there is no Dart gesture layer on web (it mirrors the
mobile tier, not the desktop core tier).

The maplibre-gl-js script and its (required) CSS are **injected at runtime** into
`document.head` the first time a map is created — no `index.html` edit needed.

## Setup

Nothing is required for the map itself. Two things to know:

1. **CSP-locked apps.** If your Content-Security-Policy blocks runtime-injected
   remote scripts, add the pinned script + stylesheet to your `web/index.html`
   `<head>` instead — the plugin detects the existing global and skips
   injection:

   ```html
   <link href="https://unpkg.com/maplibre-gl@5.24.0/dist/maplibre-gl.css" rel="stylesheet" />
   <script src="https://unpkg.com/maplibre-gl@5.24.0/dist/maplibre-gl.js"></script>
   ```

2. **Flutter widgets drawn over the map.** On web the map is a DOM element under
   the Flutter scene, so buttons/drawers/modals painted on top of it must wrap in
   [`PointerInterceptor`](https://pub.dev/packages/pointer_interceptor) or their
   taps leak through to the map. See the example app's controls. (This is not
   needed for the map widget itself — it receives pointer/scroll events
   natively.)
