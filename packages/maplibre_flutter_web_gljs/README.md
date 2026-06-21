# maplibre_flutter_web_gljs

Opt-in **maplibre-gl-js** web implementation of
[`maplibre_flutter`](https://pub.dev/packages/maplibre_flutter).

The default web renderer is `mbgl-core` compiled to WebAssembly (the
`maplibre_flutter_web` package, endorsed automatically). Depend on **this** package
to render with maplibre-gl-js instead:

```yaml
dependencies:
  maplibre_flutter: ^0.0.2
  maplibre_flutter_web_gljs: ^0.0.2 # overrides the core WASM default on web
```

## Why choose it

- **Mature reference renderer** — maplibre-gl-js is the canonical web map engine.
- **Tiny + CDN-cached** — the script/CSS load from a CDN (KBs), versus the
  multi-MB WASM artifact the core path ships.
- **No special hosting** — does not need the `COOP`/`COEP` response headers the
  threaded WASM build requires.
- **A/B testing** — compare gl-js against the native core engine on the same app.

How it works: renders inside an `HtmlElementView`; maplibre-gl-js owns gestures
and inertia natively, so this implements the platform controller only (no Dart
gesture layer). The script + (required) CSS are injected at runtime, idempotently,
reusing a consumer-provided global if present. See CLAUDE.md §3 and the root
README for the full architecture.
