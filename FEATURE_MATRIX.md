# MapLibre Feature Parity Matrix — `maplibre_flutter`

This document tracks, feature by feature, which parts of the MapLibre feature surface are wired
through the `maplibre_flutter` plugin API on each platform — Android, iOS, macOS, Windows, Linux,
and Web. The stated goal of the project is **full parity**: every platform should eventually support
every MapLibre feature the underlying engine can express. This matrix is the parity *backlog* —
it is deliberately exhaustive so the gap between "what the engine can do" and "what we have bound"
is always visible. Rows come from the canonical MapLibre feature surface (style-spec, gl-js, and the
native SDKs); cells reflect what is actually wired in this repo today.

_Last updated: 2026-06-19_

---

## Legend

| Symbol | Meaning |
| ------ | ------- |
| ✅ | **Supported** — wired through the plugin API and verified (example-app demo or test). |
| 🟡 | **Partial** — some of the feature works, but not the whole API surface. |
| ❌ | **Not yet** — the platform's engine supports it, but the binding has not been written. |
| 🚧 | **Planned-engine** — the platform's rendering engine is not wired *at all*. No platform is in this state today (every platform renders); retained for any future not-yet-wired engine. |
| ➖ | **N/A** — the feature does not exist on that engine (e.g. offline storage on Web, DOM markers on native). |

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

Derived strictly from the current implementation status in this repo:

- **Android** (MapLibre Android SDK 11.11.0, `AndroidView`): `getCamera`, `moveCamera` (with optional
  animation), `setStyle`, `onReady`, `dispose`. Camera reads are served from a cached state updated by
  an idle listener; mutations marshal to the main looper. **Gestures (pan / zoom / rotate / tilt) work
  natively via the SDK platform view.** `resize` is a no-op (the `AndroidView` auto-sizes). No layers,
  sources, annotations, events, or queries are exposed.
- **iOS** (MapLibre Apple SDK 6.27.0, `UiKitView`): at parity with Android — `getCamera`, `moveCamera`
  (animated via `MLNMapView.fly` / instant via `setCamera`), `setStyle`, `onReady`, `dispose`.
  **Gestures handled natively by the SDK.** `resize` is a no-op. Nothing beyond camera + style wired.
- **macOS** (mbgl-core via ffigen, Flutter `Texture`): `getCamera` / `setCamera`, `moveCamera` (Dart-side
  eased fly arc), `setStyle`, `resize`, plus **pan (`moveBy`) and zoom (`scaleBy`) gestures implemented
  in the shared Dart tier** (no native gesture views). Off-screen headless rendering with zero-copy
  Metal present and Continuous/Static render modes. No layer/source/query/event/annotation APIs.
- **Windows** (mbgl-core via ffigen on the **Vulkan** backend, Flutter `Texture`): at parity with the
  rest of the desktop tier — `getCamera` / `setCamera`, `moveCamera` (Dart-side eased fly arc),
  `setStyle`, `resize`, plus **pan (`moveBy`) and zoom (`scaleBy`) gestures from the shared Dart tier**.
  CPU pixel-buffer present is the verified-on-device default; D3D11 shared-texture zero-copy is opt-in but falls back to CPU on the Intel test GPU (untested on discrete GPUs). No
  layer/source/query/event/annotation APIs.
- **Linux** (mbgl-core via ffigen on the **OpenGL ES / EGL** backend, `FlTextureGL`): same wired surface
  as macOS/Windows — camera, `setStyle`, `resize`, and the shared Dart pan/zoom tier. CPU pixel-buffer
  present by default; dmabuf zero-copy is opt-in. Verified on device. No layer/source/query/event/
  annotation APIs.
- **Web** (maplibre-gl-js 5.24.0, `HtmlElementView`): Map construction, `setStyle`, `jumpTo`, `flyTo`,
  `getCamera` (`getCenter` / `getZoom` / `getBearing` / `getPitch`), `resize`, `remove` (dispose),
  and `on` / `off` event subscription used internally. **All gestures (pan / zoom / rotate / pitch /
  inertia) delegated to maplibre-gl-js natively.** `easeTo` is declared in interop but not yet called.
  No layers, markers, popups, controls, or source management wired.

> Bottom line: across all platforms, only **camera + style (+ gestures)** are wired today. Everything
> else in the tables below is ❌ (binding backlog) or ➖ (true N/A). The three desktop platforms
> (macOS, Windows, Linux) share one `mbgl-core` engine and one Dart control/gesture tier, so their
> columns are identical.

---

## 1. Sources

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| Vector source (`type='vector'`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Loaded indirectly via style JSON, but no runtime source API. |
| Vector source — `url` (TileJSON) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Vector source — `tiles` (URL templates) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Vector source — `bounds` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Vector source — `scheme` (xyz/tms) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Vector source — `minzoom` / `maxzoom` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Vector source — `attribution` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Vector source — `promoteId` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Required for feature-state on vector tiles. |
| Vector source — `volatile` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Vector source — `encoding` (mvt/mlt) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: MLT encoding exercised in gl-js; not in mbgl-core/native. |
| Raster source (`type='raster'`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Raster source — `tileSize` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Raster source — url/tiles/bounds/scheme/zoom/attribution/volatile | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Shared tiled-source options. |
| Raster-DEM source (`type='raster-dem'`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Raster-DEM — `encoding` (mapbox/terrarium/custom) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Raster-DEM — custom encoding factors | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | redFactor/greenFactor/blueFactor/baseShift. |
| Raster-DEM — url/tiles/bounds/zoom/tileSize/attribution/volatile | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON source (`type='geojson'`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON — `data` (inline or URL) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON — `maxzoom` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON — `buffer` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON — `tolerance` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON — `filter` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON — `lineMetrics` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Enables line-gradient. |
| GeoJSON — `generateId` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON — `promoteId` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON — `attribution` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Android `GeoJsonOptions` lacks `withAttribution`. |
| GeoJSON clustering — `cluster` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON clustering — `clusterRadius` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON clustering — `clusterMaxZoom` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON clustering — `clusterMinPoints` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| GeoJSON clustering — `clusterProperties` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | map/reduce aggregates. |
| Image source (`type='image'`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Image source — `url` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Image source — `coordinates` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Video source (`type='video'`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: no `VideoSource` in MapLibre Native. |
| Video source — `urls` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Video source — `coordinates` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Canvas source (`type='canvas'`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: DOM `<canvas>`, no native equivalent. |
| Canvas source — canvas/coordinates/animate options | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Canvas source — play / pause / getCanvas | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| CustomGeometrySource / `MLNComputedShapeSource` | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android/iOS SDK concept); no gl-js or mbgl-core surface. |
| CustomGeometrySource — options | ❌ | ❌ | ➖ | ➖ | ➖ | ➖ | **native_only**. |
| Add source at runtime — `addSource` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Remove source at runtime — `removeSource` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Get source — `getSource` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Source loaded state — `isSourceLoaded` / `loaded` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| All tiles loaded — `areTilesLoaded` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| GeoJSON `setData` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Primary dynamic-data update path. |
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
| Background layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Renders if present in style JSON; no runtime layer API. |
| Background paint properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | background-color / -pattern / -opacity. |
| Fill layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Fill paint properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | fill-color / -opacity / -outline-color / -pattern / -antialias / -translate. |
| Fill layout (sort-key, visibility) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Line layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Line paint properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | line-color / -width / -dasharray / -gradient / -offset / -blur / -gap-width. |
| Line layout properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | line-cap / -join / -miter-limit / -round-limit / -sort-key. |
| Symbol layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Symbol icon paint/layout | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | icon-image / -size / -rotate / -anchor / -offset / -color / -halo-*. |
| Symbol text paint/layout | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | text-field / -font / -size / -anchor / -color / -halo-* / -transform. |
| Symbol placement and collision | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | symbol-placement / -spacing / *-allow-overlap / *-ignore-placement. |
| Circle layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Circle paint properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | circle-radius / -color / -blur / -stroke-* / -pitch-scale / -pitch-alignment. |
| Fill-extrusion layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Fill-extrusion paint properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | -color / -height / -base / -opacity / -pattern / -vertical-gradient. |
| Raster layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Raster paint properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | raster-opacity / -hue-rotate / -brightness-* / -saturation / -contrast / -resampling. |
| Heatmap layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Heatmap paint properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | heatmap-radius / -weight / -intensity / -color / -opacity. |
| Hillshade layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Hillshade paint properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | See §9 for the full per-property breakdown. |
| Color-relief layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Newer style-spec layer type. |
| Color-relief paint properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | color-relief-color / -opacity. |
| Sky / atmosphere (root `sky`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: no sky in MapLibre Native `LayerFactory`. |
| Custom layer (WebGL) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: `CustomLayerInterface` over WebGL. |
| Custom layer (native C++) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**: `mbgl::style::CustomLayer` / `CustomLayerHost`. |
| Universal layer properties | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | id / type / source / source-layer / minzoom / maxzoom / filter / metadata. |
| Layer visibility (`layout.visibility`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `addLayer` (+ beforeId) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `removeLayer` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
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

Expressions are evaluated **inside the engine** when a style is loaded — so they "work" wherever the
style loads, but there is no Dart API to build, inspect, or set them at runtime. They are marked ❌
(no runtime/data-path binding) until a styling API is exposed.

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| Decision expressions (case/match/coalesce/==/!=/all/any/!) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Engine-evaluated via style JSON only. |
| Ramp/scale/curve (step / interpolate) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | linear / exponential / cubic-bezier. |
| Color-space interpolation (interpolate-hcl / -lab) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Math expressions (+ - * / % ^ trig logs rounding) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Geometric math — `distance` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Type expressions (assertions & coercions) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | array/string/number/boolean/object/typeof/to-*/format/image/number-format. |
| Lookup expressions (at/in/index-of/slice/length/get/has) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| String expressions (concat/upcase/downcase/resolved-locale) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `split` / `join` string expressions | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: not yet in mbgl-core. |
| Color construction (rgb/rgba/to-rgba) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Variable binding (`let` / `var`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Feature data (get/has/properties/geometry-type/id) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `feature-state` expression | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Paint-only; not in filters. |
| `within` expression | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `line-progress` expression | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | For line-gradient. |
| `accumulated` expression | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Cluster property accumulation. |
| `zoom` expression | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `heatmap-density` expression | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `sky-radial-progress` expression | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: ties to sky layer. |
| `global-state` expression | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: native tracking issue #3302 open. |
| `setGlobalStateProperty` API | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `elevation` expression (color-relief) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: not in mbgl-core's expression set. |
| Legacy expression-based filters | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Legacy (deprecated) filter syntax | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Auto-converted to expressions. |
| Runtime filter API (set/get) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `setFeatureState` API | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `getFeatureState` API | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `removeFeatureState` API | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Runtime paint/layout property API | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Property transitions (transitionable paint props) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Transition object (duration, delay) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
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
| `rotateBy` (gesture delta) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only** primitive. |
| `pitchBy` (relative pitch) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only** primitive. |
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

Pan / zoom / rotate / pitch gestures **work today** on Android, iOS, and Web — handled natively by the
SDK / maplibre-gl-js — and on macOS, Windows, and Linux via the shared Dart gesture tier (pan + zoom).
What is ❌ below is
the **per-gesture configuration / toggle API** (enable/disable, sensitivity, inertia tuning), none of
which is exposed through the plugin interface yet.

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| Drag-pan gesture (works) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Native SDK / gl-js; macOS via Dart `moveBy`. |
| Drag-pan enable/disable toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Drag-pan inertia options | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**: `DragPanOptions`. |
| Horizontal-scroll-only pan toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Scroll-zoom gesture (works) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | macOS via Dart `scaleBy`. |
| Scroll-zoom enable/disable toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Scroll-zoom around-center option | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Scroll-zoom rate tuning | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Box-zoom handler | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (shift-drag). |
| Double-click-zoom gesture | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ | Native SDK / gl-js; macOS Dart tier has no double-tap yet. |
| Double-click-zoom enable/disable toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Quick-zoom gesture (double-tap-hold-drag) | ✅ | ✅ | ❌ | ❌ | ❌ | ➖ | **native_only** SDK gesture; works via the platform view. |
| Touch zoom-rotate (pinch) gesture | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ | macOS Dart tier has no pinch-rotate yet. |
| Touch zoom-rotate enable/disable toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Touch zoom-rotate: rotation sub-toggle | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Touch zoom-rotate around-center option | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Touch-pitch gesture | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ | Native SDK / gl-js. |
| Touch-pitch enable/disable toggle | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Drag-rotate gesture | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ | Native SDK / gl-js. |
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
| `click` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Native: `OnMapClickListener`. |
| `dblclick` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `mousedown` / `mouseup` / `mousemove` events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (pointer events). |
| `mouseenter` / `mouseleave` (per-layer) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `mouseover` / `mouseout` events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `contextmenu` event | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Web right-click; native has long-press instead. |
| `wheel` event | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `touchstart`/`touchend`/`touchmove`/`touchcancel` events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Native long-press (`OnMapLongClickListener`) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Native fling (`OnFlingListener`) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `movestart` / `move` / `moveend` events | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Native: `OnCameraMove*Listener`. |
| `dragstart` / `drag` / `dragend` events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `zoomstart` / `zoom` / `zoomend` events | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `rotatestart` / `rotate` / `rotateend` events | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (named events). |
| `pitchstart` / `pitch` / `pitchend` events | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `boxzoomstart` / `boxzoomend` / `boxzoomcancel` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `isMoving` / `isZooming` / `isRotating` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Native camera-move listeners (`OnCameraMove*`) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| Native gesture-detail listeners (Rotate/Scale/Shove) | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `queryRenderedFeatures` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `querySourceFeatures` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `queryTerrainElevation` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Terrain itself is web_only today (see §10). |
| `getCameraTargetElevation` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `project` (LngLat → pixel) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `unproject` (pixel → LngLat) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
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
| `addImage` (runtime) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `addImages` (batch) | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android `Style.addImages`). |
| `addImageAsync` / `addImagesAsync` | ❌ | ➖ | ➖ | ➖ | ➖ | ➖ | **native_only** (Android). |
| `updateImage` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `removeImage` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| `hasImage` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `getImage` / `imageForName` | ❌ | ❌ | ❌ | ❌ | ❌ | ➖ | **native_only**. |
| `loadImage` (from URL) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| `listImages` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js). |
| SDF icons | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Stretchable images (stretchX/stretchY) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Content box (`content`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Text-fit constraints (textFitWidth/Height) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** (gl-js metadata). |
| pixelRatio (high-DPI images) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
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

3D terrain, sky, fog, globe atmosphere are **web_only** (maplibre-gl-js). DEM sources, hillshade,
3D lighting, and fill-extrusion exist on every engine (✅-capable once bound) but are not yet wired.

| Feature | Android | iOS | macOS | Windows | Linux | Web | Notes |
| ------- | :-----: | :-: | :---: | :-----: | :---: | :-: | ----- |
| 3D terrain (`setTerrain`) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `getTerrain` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| terrain `source` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| terrain `exaggeration` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| raster-dem source | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | Cross-engine (also in §1). |
| raster-dem encoding (mapbox/terrarium/custom) | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only** for the encoding enum specifically. |
| Hillshade layer | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| hillshade-illumination-direction | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| hillshade-illumination-altitude | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| hillshade-illumination-anchor | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| hillshade-exaggeration | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| hillshade-shadow-color | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| hillshade-highlight-color | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| hillshade-accent-color | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
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
| Fill-extrusion 3D buildings | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| fill-extrusion-height | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| fill-extrusion-base | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| fill-extrusion-color | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| fill-extrusion-opacity | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| fill-extrusion-pattern | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| fill-extrusion-translate | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| fill-extrusion-translate-anchor | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| fill-extrusion-vertical-gradient | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | |
| Globe projection | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| vertical-perspective projection | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Projection interpolation/transition | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| `setProjection` / `getProjection` | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |
| Globe atmosphere | ➖ | ➖ | ➖ | ➖ | ➖ | ❌ | **web_only**. |

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
4. **Keep the desktop columns in lockstep.** macOS, Windows, and Linux share one `mbgl-core` engine and
   one Dart control/gesture tier, so a feature wired on one is wired on all three — their columns should
   stay identical. Update the macOS column, then mirror it to Windows and Linux.
5. **Respect `native_only` / `web_only`.** A feature flagged `web_only` is ➖ on all native columns;
   `native_only` is ➖ on Web. Re-check these flags when a feature graduates across engines (e.g. if
   globe/sky ever land in MapLibre Native, flip those native ➖ cells to ❌).
6. **Regenerate the row list when MapLibre ships new features.** Re-derive the canonical feature
   surface (style-spec, gl-js, native SDK changelogs) periodically and add new rows; never silently
   drop a row — a removed/deprecated feature stays, annotated as deprecated.
7. **Keep `_Last updated:`** current and note the engine versions in play (Android SDK 11.11.0,
   Apple SDK 6.27.0, mbgl-core pinned via `MBGL_CORE_VERSION`, maplibre-gl-js 5.24.0) whenever they bump.
