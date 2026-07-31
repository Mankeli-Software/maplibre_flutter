# MapLibre Feature Parity Matrix — `maplibre_flutter`

This document tracks, feature by feature, which parts of the MapLibre feature surface are wired
through the `maplibre_flutter` plugin API on each platform — Android, iOS, macOS, Windows, Linux,
and Web. The stated goal of the project is **full parity**: every platform should eventually support
every MapLibre feature the underlying engine can express. This matrix is the parity *backlog* —
it is deliberately exhaustive so the gap between "what the engine can do" and "what we have bound"
is always visible. Rows come from the canonical MapLibre feature surface (style-spec, gl-js, and the
native SDKs); cells reflect what is actually wired in this repo today.

_Last updated: 2026-07-31_ (cross-platform parity push: `MapLibreModelHost` on all five native
tiers, rotate/tilt gestures, iOS verified on a Simulator)._ Engines in play: **`mbgl-core`** (pinned by
`MBGL_CORE_VERSION`) is the default renderer on **every** platform since the 2026-06-21
core-primary inversion; the MapLibre Android SDK 11.11.0, Apple SDK 6.27.0 and
maplibre-gl-js 5.24.0 are **opt-in** packages (`maplibre_flutter_{android,ios}_sdk`,
`maplibre_flutter_web_gljs`).

Two consequences for reading this matrix:

- **All five native columns are one engine.** Android, iOS, macOS, Windows and Linux run the
  same `mbgl-core` through the same C ABI and the same Dart tier, so a feature wired on one is
  wired on all five. They differ only in what has been *run on hardware* — hence 🧪 below.
- **The Web column means the WASM core**, which is the default. Rows marked **web_only** are
  gl-js features: reachable today only by adding the opt-in `maplibre_flutter_web_gljs`
  package, and not implemented in our web binding either way.

For what landed most recently, what is verified where, and the ordered per-platform backlog,
see **`docs/cross-platform-continuation.md`**.

## Legend

| Symbol | Meaning |
| ------ | ------- |
| ✅ | **Supported** — wired through the plugin API and verified (example-app demo or test). |
| 🧪 | **Wired, unverified here** — the binding exists and is shared with a platform where it IS verified, but it has never been run on this one. Code, not evidence. |
| 🟡 | **Partial** — some of the feature works, but not the whole API surface. |
| ❌ | **Not yet** — the platform's engine supports it, but the binding has not been written. |
| 🚧 | **Planned-engine** — the platform's rendering engine is not wired *at all*. No platform is in this state today (every platform renders); retained for any future not-yet-wired engine. |
| ➖ | **N/A** — the feature does not exist on that engine (e.g. offline storage on Web, DOM markers on native). |

### Key distinction — ✅ vs 🧪

**🧪 exists because five platforms share one engine and one binding, but only some have been
run.** When a capability is forwarded by all five native controllers, the *code* is equally
present everywhere; claiming ✅ on that basis would be asserting evidence that does not exist.
So the platform it was developed and demonstrated on gets ✅ and the others get 🧪 until someone
runs them. Most of today's 🧪 cells are macOS-developed features awaiting a Linux, Windows,
Android or iOS run — see `docs/cross-platform-continuation.md` for how to clear them.

### Key distinction — ❌ vs ➖

**❌ means "the engine CAN do it, we just haven't bound it yet."** Almost every cell in this matrix is
❌ today, because the current Dart contract intentionally exposes only a minimal surface: **map
creation, camera (get / move / jump / fly), style swapping, gestures, resize, and lifecycle.** Nothing
else is plumbed through the platform interface yet.

The engine-capability ceiling underneath each platform is very high:

- **Android** → MapLibre Android SDK 11.11.0 (full style-spec, layers, sources, expressions, annotations, offline, snapshotter, location).
- **iOS** → MapLibre Apple SDK 6.27.0 (same breadth via `MLNMapView`).
- **macOS / Windows / Linux** → `mbgl-core` (full Mapbox/MapLibre style-spec, layers, sources, expressions, 3D terrain, hillshade).
- **Web** → maplibre-gl-js 5.24.0 (the widest surface of all — globe, sky, DOM markers, built-in controls).

So a ❌ is **binding work**, not a platform limitation. A ➖, by contrast, is a *true* limitation:
the feature has no equivalent on that engine and never will (e.g. `maplibregl.Marker` is a DOM node
that cannot exist on a native GL surface; `OfflineManager` has no maplibre-gl-js counterpart).
Treat the count of ❌ as the parity backlog and the count of ➖ as the irreducible platform divergence.

---

## Current reality (what actually works TODAY)

Derived strictly from the current implementation status in this repo. Since the core-primary
inversion every platform runs `mbgl-core`, so this splits by **binding tier**, not by OS.

**The five native platforms** (Android, iOS, macOS, Windows, Linux) — `mbgl-core` via ffigen into a
Flutter `Texture`, driven by one shared Dart tier:

- **Camera**: `getCamera` / `moveCamera` (jump or eased), a Dart-side fly arc, `resize`, `onReady`,
  `dispose`. Bearing and pitch are settable, and since 2026-07-31 there ARE rotate and pitch
  gestures: a two-finger twist, a two-finger vertical shove for tilt, and a secondary-button /
  ctrl drag. The example keeps its rotate/tilt buttons as the keyboardless path.
- **Gestures**: pan (with inertia/fling ported from the native SDK model) and zoom-about-anchor,
  implemented once in Dart over the engine. Rotate and pitch landed 2026-07-31; double-tap and
quick-zoom are still missing.
- **Widget markers**: real Flutter widgets glued to a `LatLng` (`MapLibreMap.markers`) — tappable,
  draggable, animatable — positioned from a synchronous projection snapshot that is correlated to
  the frame actually on screen, so they do not swim during movement.
- **Engine sources / layers / images**: `controller.layers` takes MapLibre Style Spec JSON for any
  source or layer type, plus `setGeoJsonData`, `addImage` / `removeImage`, and `addWidgetIcon`
  (a Flutter widget rasterised into a style image). In-engine clustering works (`cluster: true`).
- **Typed style API**: generated from the vendored style spec — all 10 layer types, all 6 source
  types, 33 enums, all 84 expression operators — serialising to the JSON path above.
- **Queries**: `queryRenderedFeatures(rect)`, returning what the engine actually drew (including
  the clusters it created, with `point_count`).
- **Style transitions**: `setTransitionOptions` (duration / delay / placement fade), style-wide.
- **Camera-change notification**: `onCameraChanged`, a `Listenable` ticked at every camera change.
- **3D `.glb` models**: `addModel` / `updateModel` / `removeModel` and `MapLibreMap(models:)`,
  drawn inside the engine so they depth-occlude against buildings. **macOS/Metal only.**

Verified on hardware: **macOS** for everything above. Linux and Windows have the whole binding but
have only been run for camera / style / gestures. iOS and Android likewise, and their most recent
device runs predate the annotation work.

**Web** (`maplibre_flutter_web`, the WASM core in a `<canvas>`): map construction, `setStyle`,
camera get/set, fly, `resize`, dispose, and gestures owned by the engine glue. **None** of the
annotation, layer, query, projection or model surface is bound on web — no projector, no
`MapLibreStyleLayers`, no model host. This is the largest single gap in the matrix.

**Opt-in renderers**: adding `maplibre_flutter_android_sdk` / `_ios_sdk` swaps that platform to the
native SDK and its native gestures (rotate, pitch, double-tap, quick-zoom) but takes the shared
Dart annotation tier out of play; `maplibre_flutter_web_gljs` swaps web to maplibre-gl-js. Neither
opt-in package binds anything beyond camera + style today.

> Bottom line: camera, style, gestures, **widget markers, engine sources/layers/images, the typed
> style API, queries and transitions** are wired on the native tier — verified on macOS, 🧪 on the
> other four. Web has none of it. 3D models are wired on all five native tiers (verified on
> macOS and iOS, both Metal; GL and Vulkan unrun) and remain unavailable on web.

---

## 1. Sources

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| Vector source (`type='vector'`) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Vector source — `url` (TileJSON) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Vector source — `tiles` (URL templates) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Vector source — `bounds` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Vector source — `scheme` (xyz/tms) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Vector source — `minzoom` / `maxzoom` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Vector source — `attribution` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Vector source — `promoteId` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Vector source — `volatile` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Vector source — `encoding` (mvt/mlt) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: MLT encoding exercised in gl-js; not in mbgl-core/native. |
| Raster source (`type='raster'`) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Raster source — `tileSize` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Raster source — url/tiles/bounds/scheme/zoom/attribution/volatile | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Raster-DEM source (`type='raster-dem'`) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Raster-DEM — `encoding` (mapbox/terrarium/custom) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Raster-DEM — custom encoding factors | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Raster-DEM — url/tiles/bounds/zoom/tileSize/attribution/volatile | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| GeoJSON source (`type='geojson'`) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS via `layers.addPoints` / `GeoJsonSource`, incl. in-engine clustering with pixel-asserted native tests. |
| GeoJSON — `data` (inline or URL) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS via `layers.addPoints` / `GeoJsonSource`, incl. in-engine clustering with pixel-asserted native tests. |
| GeoJSON — `maxzoom` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| GeoJSON — `buffer` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| GeoJSON — `tolerance` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| GeoJSON — `filter` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| GeoJSON — `lineMetrics` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| GeoJSON — `generateId` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| GeoJSON — `promoteId` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| GeoJSON — `attribution` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| GeoJSON clustering — `cluster` | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS via `layers.addPoints` / `GeoJsonSource`, incl. in-engine clustering with pixel-asserted native tests. |
| GeoJSON clustering — `clusterRadius` | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS via `layers.addPoints` / `GeoJsonSource`, incl. in-engine clustering with pixel-asserted native tests. |
| GeoJSON clustering — `clusterMaxZoom` | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS via `layers.addPoints` / `GeoJsonSource`, incl. in-engine clustering with pixel-asserted native tests. |
| GeoJSON clustering — `clusterMinPoints` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| GeoJSON clustering — `clusterProperties` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Image source (`type='image'`) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Image source — `url` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Image source — `coordinates` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addSourceJson` takes the whole spec document (mbgl `convertJSON<Source>`), and the generated typed API has a field for it. |
| Video source (`type='video'`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: no `VideoSource` in MapLibre Native. |
| Video source — `urls` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Video source — `coordinates` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Canvas source (`type='canvas'`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: DOM `<canvas>`, no native equivalent. |
| Canvas source — canvas/coordinates/animate options | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Canvas source — play / pause / getCanvas | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| CustomGeometrySource / `MLNComputedShapeSource` | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android/iOS SDK concept); no gl-js or mbgl-core surface. |
| CustomGeometrySource — options | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only**. |
| Add source at runtime — `addSource` | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `layers.addSource` / `removeSource`, typed or raw JSON. |
| Remove source at runtime — `removeSource` | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `layers.addSource` / `removeSource`, typed or raw JSON. |
| Get source — `getSource` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Source loaded state — `isSourceLoaded` / `loaded` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| All tiles loaded — `areTilesLoaded` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| GeoJSON `setData` | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `layers.setGeoJsonData` — the engine re-tiles and re-clusters; no layer rebuild. |
| GeoJSON `updateData` (incremental diff) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| GeoJSON `getData` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| GeoJSON `getBounds` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| GeoJSON `setClusterOptions` (runtime) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| Cluster expansion zoom — `getClusterExpansionZoom` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Cluster children — `getClusterChildren` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Cluster leaves — `getClusterLeaves` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Image / Video `setCoordinates` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Video setCoordinates is web-only; image is cross-platform. |
| Image `updateImage` / `setImage` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Vector / Raster `setTiles` (runtime) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| Vector / Raster `setUrl` (runtime) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `querySourceFeatures` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Feature state — `setFeatureState` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Feature state — `getFeatureState` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Feature state — `removeFeatureState` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |

---

## 2. Layers

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| Background layer | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Background paint properties | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Fill layer | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Fill paint properties | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Fill layout (sort-key, visibility) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Line layer | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS: `LineLayer` with dasharray + zoom-interpolated width. |
| Line paint properties | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS: `LineLayer` with dasharray + zoom-interpolated width. |
| Line layout properties | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS: `LineLayer` with dasharray + zoom-interpolated width. |
| Symbol layer | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS: `SymbolLayer` cluster counts and widget-derived `icon-image`. |
| Symbol icon paint/layout | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS: `SymbolLayer` cluster counts and widget-derived `icon-image`. |
| Symbol text paint/layout | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS: `SymbolLayer` cluster counts and widget-derived `icon-image`. |
| Symbol placement and collision | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Circle layer | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS: `CircleLayer` / `addPoints`, incl. data-driven colour and radius. |
| Circle paint properties | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS: `CircleLayer` / `addPoints`, incl. data-driven colour and radius. |
| Fill-extrusion layer | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Fill-extrusion paint properties | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Raster layer | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Raster paint properties | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Heatmap layer | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Heatmap paint properties | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Hillshade layer | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Hillshade paint properties | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Color-relief layer | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Color-relief paint properties | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Sky / atmosphere (root `sky`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: no sky in MapLibre Native `LayerFactory`. |
| Custom layer (WebGL) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: `CustomLayerInterface` over WebGL. |
| Custom layer (native C++) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**: `mbgl::style::CustomLayer` / `CustomLayerHost`. |
| Universal layer properties | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| Layer visibility (`layout.visibility`) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible: `addLayerJson` takes the whole spec document (mbgl `convertJSON<Layer>`), and the generated typed API covers every property. |
| `addLayer` (+ beforeId) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `layers.addLayer` (typed) / `addLayerJson` / `removeLayer`; beforeId supported. |
| `removeLayer` | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `layers.addLayer` (typed) / `addLayerJson` / `removeLayer`; beforeId supported. |
| `moveLayer` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `getLayer` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `getLayersOrder` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `setLayoutProperty` / `getLayoutProperty` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setPaintProperty` / `getPaintProperty` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setFilter` / `getFilter` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setLayerZoomRange` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Layer slot / before insertion (`slot`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Named `slot` insertion points are emerging in the spec. |

---

## 3. Data-driven styling: expressions, filters, feature-state, transitions, functions

Expressions are evaluated **inside the engine**, but they are now *buildable from Dart*: the
generated `Expr` class has a builder for every one of the 84 operators in the spec, plus
`Expr.raw` for anything it does not model, and an `Expression` is assignable to any typed style
property. So "can I construct and send this?" is yes on the native tier; what stays ❌ is
*inspecting or mutating* an existing layer's expression at runtime (`getFilter`, `setPaintProperty`),
which needs C ABI that does not exist yet.

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| Decision expressions (case/match/coalesce/==/!=/all/any/!) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| Ramp/scale/curve (step / interpolate) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| Color-space interpolation (interpolate-hcl / -lab) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| Math expressions (+ - * / % ^ trig logs rounding) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| Geometric math — `distance` | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| Type expressions (assertions & coercions) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| Lookup expressions (at/in/index-of/slice/length/get/has) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| String expressions (concat/upcase/downcase/resolved-locale) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| `split` / `join` string expressions | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: not yet in mbgl-core. |
| Color construction (rgb/rgba/to-rgba) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| Variable binding (`let` / `var`) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| Feature data (get/has/properties/geometry-type/id) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS: `Expr.get`/`has` filters partition clustered sources, and `Expr.interpolate` over `Expr.zoom()` drives line width. |
| `feature-state` expression | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Paint-only; not in filters. |
| `within` expression | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| `line-progress` expression | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| `accumulated` expression | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| `zoom` expression | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Verified on macOS: `Expr.get`/`has` filters partition clustered sources, and `Expr.interpolate` over `Expr.zoom()` drives line width. |
| `heatmap-density` expression | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| `sky-radial-progress` expression | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: ties to sky layer. |
| `global-state` expression | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: native tracking issue #3302 open. |
| `setGlobalStateProperty` API | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `elevation` expression (color-relief) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: not in mbgl-core's expression set. |
| Legacy expression-based filters | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| Legacy (deprecated) filter syntax | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Buildable from Dart via the generated `Expr` builders (or `Expr.raw`); sent as part of a layer document. |
| Runtime filter API (set/get) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setFeatureState` API | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `getFeatureState` API | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `removeFeatureState` API | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Runtime paint/layout property API | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Property transitions (transitionable paint props) | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Per-property `*-transition` is a field on every generated layer (`StyleTransition`). |
| Transition object (duration, delay) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `layers.setTransitionOptions(duration:, delay:, placementTransitions:)` — style-wide, sticky across style loads. Continuous mode only. |
| Zoom functions (legacy) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Predecessor to zoom interpolate. |
| Property (data-driven) functions (legacy) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Zoom-and-property functions (legacy) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |

---

## 4. Camera & projection

This is the **most-implemented** domain — camera control is the wired surface today.

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| `jumpTo` (instant camera set) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `moveCamera` with 0 duration; Web uses `jumpTo` directly. |
| `easeTo` (eased camera transition) | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | Native/macOS animate via duration; Web `easeTo` declared but unused (uses flyTo). |
| `flyTo` (flight-curve transition) | 🟡 | ✅ | ✅ | ✅ | ✅ | ✅ | iOS uses `MLNMapView.fly`; macOS uses a Dart eased arc; Android animates via `animateCamera`. |
| `panBy` (pan by pixel offset) | ❌ | ❌ | 🟡 | 🟡 | 🟡 | ❌ | macOS exposes `moveBy` as a gesture primitive, not a public camera op. |
| `panTo` (pan to location) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Reachable via moveCamera(center) today, but no dedicated panTo. |
| `zoomTo` (animate to zoom) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Reachable via moveCamera(zoom). |
| `zoomIn` (increment zoom) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Example app does this by reading + incrementing camera. |
| `zoomOut` (decrement zoom) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `rotateTo` (animate to bearing) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Reachable via moveCamera(bearing). |
| `rotateBy` (gesture delta) | ✅ | ✅ | ✅ | ✅ | ✅ | ➖ | `mbl_map_rotate_by` + `MapLibreRotateHandler`. NOT built on mbgl's `Map::rotateBy`, which is broken upstream (`pow(2,x)+pow(2,y)`). |
| `pitchBy` (relative pitch) | ✅ | ✅ | ✅ | ✅ | ✅ | ➖ | `mbl_map_pitch_by`. NOT mbgl's `Map::pitchBy`, which SUBTRACTS its argument. |
| `scaleBy` (relative zoom around anchor) | ❌ | ❌ | ✅ | ✅ | ✅ | ➖ | **native_only** primitive; macOS wires it as the zoom gesture. |
| `resetNorth` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `resetNorthPitch` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `snapToNorth` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `fitBounds` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `fitScreenCoordinates` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `cameraForBounds` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `cameraForLatLngs` / `cameraForGeometry` | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `setBearing` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Reachable via moveCamera(bearing). |
| `setPitch` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Reachable via moveCamera(pitch). |
| `setRoll` (roll/bank angle) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `setCenter` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Reachable via moveCamera(center). |
| `setZoom` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Reachable via moveCamera(zoom). |
| Camera elevation (center above sea level) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| Padding (viewport edge insets) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `around` (anchor for transition) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `offset` (screen-pixel target offset) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| Animation duration | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Plumbed through `moveCamera({duration})` / `flyTo`. |
| Animation easing function | ❌ | ❌ | 🟡 | 🟡 | 🟡 | ❌ | macOS uses a fixed eased arc; no caller-supplied easing. |
| `animate` flag | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `essential` animation flag | ➖ | ➖ | ➖ | ➖ | ➖ | 🟡 | **web_only**; web flyTo passes `essential: true` internally. |
| Animation transition/finish callbacks | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| flyTo `speed` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| flyTo `curve` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| flyTo `minZoom` (apex zoom) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| flyTo `screenSpeed` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| flyTo `maxDuration` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `freezeElevation` during animation | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `setMinZoom` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setMaxZoom` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setMinPitch` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setMaxPitch` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setMaxBounds` (pan constraint) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setConstrainMode` | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `setNorthOrientation` | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `setViewportMode` | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Mercator projection | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Default and implicit on every engine. |
| Globe projection | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: no globe in MapLibre Native / mbgl-core. |
| Vertical-perspective projection | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `setProjection` / `getProjection` (runtime) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Projection transition via interpolate | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `setProjectionMode` / `getProjectionMode` | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**: distinct from gl-js globe. |
| `setVerticalFieldOfView` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `setCenterClampedToGround` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `FreeCameraOptions` (free 3D camera) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |

---

## 5. User interaction / gesture handlers

**Corrected for the core-primary inversion.** Android and iOS no longer get the native SDK's
gesture stack by default — they run `mbgl-core` and the same shared Dart gesture tier as the
desktop platforms. That tier implements **pan (with inertia/fling) and zoom-about-anchor**, and
**pan (with inertia/fling)**, **zoom-about-anchor**, **rotate** and **tilt**. Double-tap and
quick-zoom are still missing. Adding `maplibre_flutter_android_sdk` / `_ios_sdk` restores the SDK's
full native gesture set on that platform.

Rotate and tilt landed 2026-07-31 (`MapLibreRotateHandler` over `mbl_map_rotate_by` /
`mbl_map_pitch_by`): a two-finger twist past an 8° deadzone, a two-finger vertical shove for tilt,
a secondary-button / ctrl drag for both, and trackpad twist through the overlay-blocked route.
Enable/disable is `MapLibreMap.rotateGesturesEnabled` / `.tiltGesturesEnabled`. Covered by 11
device-free widget tests; the FEEL is unverified on hardware, and rotate INERTIA is deliberately
not implemented (it needs `TickerProviderStateMixin`, and the single-ticker constraint in the
gesture state is load-bearing).

Bearing and pitch remain reachable imperatively (`moveCamera`), which is what the example's
rotate/tilt buttons use — kept as the keyboardless path. What is still ❌ below is either a missing
gesture or per-gesture tuning (sensitivity, inertia), which is not exposed.

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| Drag-pan gesture (works) | ✅ | ✅ | ✅ | 🧪 | 🧪 | ✅ | Shared Dart tier over `moveBy`, with an inertia/fling model ported from the native SDK. Verified on macOS, Android and iOS device runs. |
| Drag-pan enable/disable toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Drag-pan inertia options | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: `DragPanOptions`. |
| Horizontal-scroll-only pan toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Scroll-zoom gesture (works) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Shared Dart tier over `scaleBy`. Trackpad pinch anchoring was a real bug on Windows/Linux and is fixed + regression-tested. |
| Scroll-zoom enable/disable toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Scroll-zoom around-center option | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Scroll-zoom rate tuning | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Box-zoom handler | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (shift-drag). |
| Double-click-zoom gesture | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | REGRESSED by the inversion: was an SDK gesture on Android/iOS. The Dart tier has no double-tap. Restored by the opt-in `_sdk` packages. |
| Double-click-zoom enable/disable toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Quick-zoom gesture (double-tap-hold-drag) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only** SDK gesture; only via the opt-in `_sdk` packages now. |
| Touch zoom-rotate (pinch) gesture | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Pinch zoom AND twist-to-rotate, past an 8° deadzone, about one frozen anchor. Unrun on hardware for all but macOS/iOS. |
| Touch zoom-rotate enable/disable toggle | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | `MapLibreMap.rotateGesturesEnabled` (widget prop — bucket 2, not `MapOptions`). |
| Touch zoom-rotate: rotation sub-toggle | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Touch zoom-rotate around-center option | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Touch-pitch gesture | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Two-finger vertical "shove", detected from raw pointer positions — `ScaleUpdateDetails` carries no per-pointer data, and a shove is otherwise indistinguishable from a two-finger pan. |
| Touch-pitch enable/disable toggle | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | `MapLibreMap.tiltGesturesEnabled`. |
| Drag-rotate gesture | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Secondary-button or ctrl+primary drag: horizontal turns, vertical tilts (gl-js's DragRotateHandler). On the raw `Listener`, since `onScaleStart` fires for secondary drags too. |
| Drag-rotate enable/disable toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `pitchWithRotate` option | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `rollEnabled` option | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `bearingSnap` option | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Keyboard handler | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Keyboard handler: rotation sub-toggle | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Cooperative gestures handler | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Global interactive toggle | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: `MapOptions.interactive`. |
| Enable/disable all gestures at once | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**: `UiSettings.setAllGesturesEnabled`. |
| `clickTolerance` option | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Inertia / reduce-motion toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | gl-js `reduceMotion`; native per-gesture velocity toggles. |
| Fling (pan) velocity animation toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Scale (zoom) velocity animation toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Rotate velocity animation toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Increase-rotate-threshold-when-scaling | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Disable-rotate-when-scaling | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Gesture focal point | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Handler `isActive()` introspection | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |

---

## 6. Annotations & controls

DOM-based markers, popups, and the built-in web controls (`NavigationControl`, `ScaleControl`,
`GeolocateControl`, etc.) are **web_only** — they are HTML elements with no native GL equivalent.
Native annotation/ornament APIs are **native_only** (Android/iOS SDK). None are wired yet.

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| **`maplibre_flutter` widget markers** (`MapLibreMap.markers`) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | **Our own tier, no MapLibre equivalent**: real Flutter widgets glued to a `LatLng` via the projector, positioned against the presented frame. Verified on macOS. |
| Widget marker — tap / drag callbacks | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | A marker's own `GestureDetector` works; empty space falls through to the map. Dragging is positioned from the live pointer. |
| Widget marker — alignment, viewport culling, repaint boundary | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Off-screen markers are culled; `repaintBoundary` (default on) rasterises rich children once. |
| Map tap → LatLng (`MapLibreMap(onTap:)`) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Unprojects the tap; marker hits win by hit-test order. |
| **Engine-drawn point helper** (`layers.addPoints`, optional clustering) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | One call builds the geojson source + circle layers (+ a symbol count layer); scales to 50k+ where widgets cannot. |
| **Flutter widget → style image** (`layers.addWidgetIcon`) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Rasterises a widget off-screen and registers it as `icon-image`, so bulk points are styled with Flutter widgets. A snapshot: no gestures, no animation. |
| **3D `.glb` model** (`controller.addModel`, `MapLibreMap(models:)`) | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | **Our own extension** over mbgl `CustomDrawableLayer`; depth-occludes against buildings. macOS/Metal only — see §9. |
| Marker (DOM marker) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: `maplibregl.Marker`. |
| Marker custom element | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Marker color / scale / anchor / offset | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Marker draggable + drag events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Marker rotation / rotationAlignment / pitchAlignment | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Marker opacity / opacityWhenCovered | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Marker subpixelPositioning | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Marker className / CSS management | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Marker lngLat get/set, getElement | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Marker bound popup | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Marker add/remove | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Popup (+ all options: closeButton/anchor/offset/maxWidth/…) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: `maplibregl.Popup`. |
| Popup content (HTML/text/DOM) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Popup trackPointer | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Popup lifecycle and events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| NavigationControl (+ showZoom/showCompass/visualizePitch) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| ScaleControl (+ maxWidth/unit) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| AttributionControl (+ compact/customAttribution) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| GeolocateControl (+ tracking/showUserLocation/options/trigger) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| FullscreenControl (+ container/events) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| TerrainControl | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| LogoControl | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| GlobeControl | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js 5.x). |
| `addControl` / `removeControl` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Control positions | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `IControl` (custom control interface) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Native point annotation (Android, legacy) | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android), deprecated. |
| Native polyline/polygon (Android, legacy) | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android), deprecated. |
| Native annotation plugin Symbol (Android) | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| Native annotation plugin Line/Fill/Circle (Android) | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| Native annotation interaction listeners (Android) | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| Native point annotation (iOS, `MLNPointAnnotation`) | ➖ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (iOS). |
| Native shape annotations (iOS, `MLNPolyline`/`MLNPolygon`) | ➖ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (iOS). |
| Native annotation view (iOS, `MLNAnnotationView`) | ➖ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (iOS). |
| Native annotation image (iOS, `MLNAnnotationImage`) | ➖ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (iOS). |
| Native annotation callout/popup (iOS) | ➖ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (iOS). |
| Native compass ornament | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android/iOS SDK ornament). |
| Native attribution ornament | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only**. |
| Native logo ornament | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only**. |
| Native scale bar ornament (iOS) | ➖ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (iOS). |
| Native zoom/navigation controls (ornaments) | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only**. |
| Native user-location component / puck (Android) | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| Native user-location display (iOS, `MLNUserLocation`) | ➖ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (iOS). |

---

## 7. Events & queries

The only lifecycle signal wired today is **`onReady`** (a one-shot future on the controller, fed by the
native "map loaded" / web `'load'` callback). The web controller uses `on`/`off` internally to drive
`onReady`, but does not expose general event subscription to Dart. No public event stream, no query APIs.

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| `onReady` (map loaded / first frame) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | The single lifecycle signal currently exposed (`load`-equivalent). |
| `load` event (public subscription) | ❌ | ❌ | ❌ | ❌ | ❌ | 🟡 | Web uses it internally for onReady; not exposed as a Dart stream. |
| `idle` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Android caches camera off an idle listener, but no public event. |
| `render` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `styledata` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `styledataloading` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `sourcedata` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `sourcedataloading` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `dataloading` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `data` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `dataabort` / `sourcedataabort` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `styleimagemissing` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `error` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `remove` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `resize` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `webglcontextlost` / `webglcontextrestored` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `cooperativegestureprevented` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `click` event | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | ❌ | `MapLibreMap(onTap:)` reports the unprojected LatLng of a tap on the map. No per-layer hit-test callback (compose with queryRenderedFeatures). |
| `dblclick` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `mousedown` / `mouseup` / `mousemove` events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (pointer events). |
| `mouseenter` / `mouseleave` (per-layer) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `mouseover` / `mouseout` events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `contextmenu` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Web right-click; native has long-press instead. |
| `wheel` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `touchstart`/`touchend`/`touchmove`/`touchcancel` events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Native long-press (`OnMapLongClickListener`) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Native fling (`OnFlingListener`) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `movestart` / `move` / `moveend` events | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | ❌ | `controller.onCameraChanged` is a Listenable ticked on every camera change — enough to drive overlays, but not discrete start/move/end events. |
| `dragstart` / `drag` / `dragend` events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `zoomstart` / `zoom` / `zoomend` events | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `rotatestart` / `rotate` / `rotateend` events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (named events). |
| `pitchstart` / `pitch` / `pitchend` events | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `boxzoomstart` / `boxzoomend` / `boxzoomcancel` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `isMoving` / `isZooming` / `isRotating` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Native camera-move listeners (`OnCameraMove*`) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Native gesture-detail listeners (Rotate/Scale/Shove) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `queryRenderedFeatures` | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `layers.queryRenderedFeatures(rect)` → parsed features incl. engine-made clusters with `point_count`. Rect only (no point/geometry overload), no filter argument. |
| `querySourceFeatures` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `queryTerrainElevation` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Terrain itself is web_only today (see §10). |
| `getCameraTargetElevation` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `project` (LngLat → pixel) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `MapLibreMapProjector`, synchronous and lock-light, projected against the frame ON SCREEN (not the newest transform) so anchored widgets do not swim. Batched for the marker overlay. |
| `unproject` (pixel → LngLat) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `MapLibreMapProjector`, synchronous and lock-light, projected against the frame ON SCREEN (not the newest transform) so anchored widgets do not swim. Batched for the marker overlay. |
| Native projection toScreen/fromScreen | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `getBounds` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setMaxBounds` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `getMaxBounds` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `cameraForBounds` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Native camera-for-bounds / -geometry | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Native `latLngBoundsFromCamera` | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `on` (subscribe) | ❌ | ❌ | ❌ | ❌ | ❌ | 🟡 | Web interop has `on`; used internally, not a public Dart API. |
| `once` (subscribe one-shot) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `off` (unsubscribe) | ❌ | ❌ | ❌ | ❌ | ❌ | 🟡 | Web interop has `off`; used internally on dispose. |
| `listens` (has listeners) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |

---

## 8. Images / sprites / glyphs / localization

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| `addImage` (runtime) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `layers.addImage(id, rgba, w, h, pixelRatio:, sdf:)`; raw premultiplied RGBA. |
| `addImages` (batch) | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android `Style.addImages`). |
| `addImageAsync` / `addImagesAsync` | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| `updateImage` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `removeImage` | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | `layers.addImage(id, rgba, w, h, pixelRatio:, sdf:)`; raw premultiplied RGBA. |
| `hasImage` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `getImage` / `imageForName` | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `loadImage` (from URL) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `listImages` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| SDF icons | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Both are parameters of `addImage`. |
| Stretchable images (stretchX/stretchY) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Content box (`content`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Text-fit constraints (textFitWidth/Height) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js metadata). |
| pixelRatio (high-DPI images) | 🧪 | 🧪 | ✅ | 🧪 | 🧪 | ❌ | Both are parameters of `addImage`. |
| Animated / dynamic images (`StyleImageInterface`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `styleimagemissing` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (event form); native is in §7. |
| Sprite root property (single source) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Loaded via style JSON; no runtime sprite API. |
| Multiple sprite sources | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Sprite JSON index format | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| High-DPI @2x sprites | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `addSprite` (runtime) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `setSprite` (runtime) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `getSprite` (runtime) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `removeSprite` (runtime) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| Glyphs root property | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Loaded via style JSON. |
| Glyph range loading (256-codepoint PBF) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Engine-internal; no API. |
| `setGlyphs` (runtime) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `getGlyphs` (runtime) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| Local ideograph font family (CJK local glyphs) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Construction-time option; not wired into MapOptions. |
| RTL text plugin (`setRTLTextPlugin`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: native bundles ICU in-core. |
| RTL plugin status (`getRTLTextPluginStatus`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `localizeLabels` (label localization) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Language switching (setLanguage pattern) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: expression-rewrite / plugin pattern. |

---

## 9. 3D & atmosphere

3D terrain, sky, fog and globe atmosphere are **web_only** (maplibre-gl-js) — and note that on web
they are reachable only through the opt-in gl-js package, not our default WASM core.

What changed: **hillshade and fill-extrusion are now expressible** on the native tier, because any
layer document can be sent (typed or raw), so they are 🧪 rather than ❌ — the binding exists,
nobody has run them. The root `light` object still has no binding. And `maplibre_flutter` now has
its own **3D model** layer, which is not a MapLibre feature at all: MapLibre has no model layer in
the spec, in gl-js, or in Native, so this is an extension over mbgl's `CustomDrawableLayer`.

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| 3D terrain (`setTerrain`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `getTerrain` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| terrain `source` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| terrain `exaggeration` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| raster-dem source | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| raster-dem encoding (mapbox/terrarium/custom) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** for the encoding enum specifically. |
| Hillshade layer | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| hillshade-illumination-direction | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| hillshade-illumination-altitude | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| hillshade-illumination-anchor | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| hillshade-exaggeration | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| hillshade-shadow-color | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| hillshade-highlight-color | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| hillshade-accent-color | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| hillshade-method | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Sky layer (style `sky` property) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| sky-color | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| horizon-color | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| sky-horizon-blend | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| atmosphere-blend | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Fog (terrain fog via sky) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| fog-color | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| fog-ground-blend | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| horizon-fog-blend | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `setLight` / 3D lighting | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Cross-engine. |
| light anchor | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| light position | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| light color | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| light intensity | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Fill-extrusion 3D buildings | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| fill-extrusion-height | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| fill-extrusion-base | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| fill-extrusion-color | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| fill-extrusion-opacity | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| fill-extrusion-pattern | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| fill-extrusion-translate | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| fill-extrusion-translate-anchor | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| fill-extrusion-vertical-gradient | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 | ❌ | Expressible via a typed layer or `addLayerJson`; never run. |
| Globe projection | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| vertical-perspective projection | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Projection interpolation/transition | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `setProjection` / `getProjection` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Globe atmosphere | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| **3D `.glb` model layer** (`maplibre_flutter` extension) | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | Not a MapLibre feature: no model layer exists in the spec, gl-js or Native. Ours draws glTF through mbgl `CustomDrawableLayer`. Verified on macOS/Metal. |
| Model — geo-anchored placement, scale, heading, elevation | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | `MapLibreModel`; `updateModel` moves one per frame without re-parsing the .glb. |
| Model — depth occlusion against fill-extrusion | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | Needed an mbgl patch: `mtl::TileLayerGroup` never computed `features3d` for a layer group with no stencil tiles. **Metal-only patch.** |
| Model — per-material mesh splitting, shared GPU textures | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | Draw calls scale with parts, not instances; meshes are shared between instances. |
| Model — directional lighting | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | mbgl's custom-geometry shader has no normals; our patch adds a NORMAL attribute + half-lambert across all four backends, but **only the Metal edits have been run** — GL/Vulkan/WebGPU are unverified mirrors. |
| Model — texture REPEAT wrapping | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | Metal `constexpr sampler` defaulted to clamp-to-edge, collapsing tiled glTF textures to an edge colour. **Metal-only patch.** |

---

## 10. Native-only: offline, location component, snapshotter, native annotations

These are **native_only** by definition — maplibre-gl-js has no offline manager, no SDK location
component, and no snapshotter. macOS/Windows/Linux run on `mbgl-core`, which *does* have offline +
snapshotter primitives in the C++ core, so those rows are ❌ (bindable) on the desktop tier rather
than ➖. The Android/iOS SDK-level annotation managers are ➖ on desktop (SDK-specific). Windows and
Linux share macOS's `mbgl-core` engine, so their cells match the macOS column.

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| OfflineManager (offline storage manager) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**: SDK / `mbgl::DefaultFileSource`. |
| Create offline region | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Tile-pyramid offline region | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Shape (GeoJSON) offline region | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| List / retrieve offline regions | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Offline region download control | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Offline region status / progress observer | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Offline region metadata | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Delete offline region | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Invalidate offline region | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Offline tile count limit | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Merge offline regions database | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Ambient cache | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Set maximum ambient cache size | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Clear ambient cache | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Invalidate ambient cache | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Set maximum ambient cache age | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Put resource into ambient cache | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Reset / pack offline database | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Set offline database path | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Location component (user-location puck) | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only**: Android/iOS SDK; web uses GeolocateControl (§6). |
| Activate / enable location component | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| Location render modes | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| Location camera tracking modes | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android/iOS). |
| Zoom / tilt / padding while tracking | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| Force location update / location engine | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| Compass / bearing engine | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only**. |
| Location component styling options | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| Location interaction & state listeners | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| iOS user-location annotation view | ➖ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (iOS). |
| Map snapshotter (static image API) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**: also `mbgl::MapSnapshotter` on desktop. |
| Snapshotter options (size/camera/region/style) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Snapshotter logo / attribution toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Snapshotter add images / style builder | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| Snapshot result with coordinate projection | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Annotation plugin managers (Symbol/Line/Circle/Fill) | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android plugin). |
| Annotation drag / click / long-click listeners | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android plugin). |
| MarkerView plugin (Android-view markers) | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android plugin). |
| Legacy marker / polyline / polygon annotations | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only**, deprecated. |
| iOS annotation views & images | ➖ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (iOS). |

---

## How to update this matrix

1. **Flip a cell to ✅ only with proof.** A cell becomes ✅ exclusively when the feature is wired
   through the **plugin API** and demonstrated by a **verified example-app run** *or* an automated
   **test** (unit/widget/integration). Reading the engine docs is not enough; "the SDK supports it"
   keeps the cell ❌.
2. **Use 🟡 honestly.** If only part of a feature works (e.g. `easeTo` declared but unused; `flyTo`
   with a fixed easing instead of caller-supplied curve), mark 🟡 and note exactly what is missing.
3. **❌ is the binding backlog.** Keep ❌ wherever the engine *can* do it but no binding exists. Do
   not downgrade ❌ to ➖ to make the matrix look better — ➖ is reserved for genuine engine limits.
4. **Keep ALL FIVE native columns in lockstep — as 🧪, not ✅.** Since the core-primary inversion,
   Android, iOS, macOS, Windows and Linux share one `mbgl-core` engine and one Dart tier, so a feature
   wired on one is wired on all five. Mark the platform you actually ran ✅ and the rest 🧪; do not
   promote 🧪 to ✅ by inference, and do not leave a shared binding as ❌ on the platforms you have not
   run — ❌ would claim the code is absent when it is not.
5. **Clearing a 🧪 is a hardware run, and it is cheap.** Build the example on that platform and drive
   the relevant scenario; `docs/cross-platform-continuation.md` lists what to check per platform. If it
   fails, the cell goes to 🟡 or ❌ with a note saying what broke — that is a finding, not a setback.
6. **Respect `native_only` / `web_only`.** A feature flagged `web_only` is ➖ on all native columns;
   `native_only` is ➖ on Web. Re-check these flags when a feature graduates across engines (e.g. if
   globe/sky ever land in MapLibre Native, flip those native ➖ cells to ❌).
7. **Regenerate the row list when MapLibre ships new features.** Re-derive the canonical feature
   surface (style-spec, gl-js, native SDK changelogs) periodically and add new rows; never silently
   drop a row — a removed/deprecated feature stays, annotated as deprecated.
8. **Keep `_Last updated:`** current and note the engine versions in play (Android SDK 11.11.0,
   Apple SDK 6.27.0, mbgl-core pinned via `MBGL_CORE_VERSION`, maplibre-gl-js 5.24.0) whenever they bump.
