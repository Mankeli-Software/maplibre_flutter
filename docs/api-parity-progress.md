# API parity — progress ledger

**Goal.** Bring `maplibre_flutter`'s public Dart API up to parity with the canonical MapLibre APIs
(maplibre-gl-js, the MapLibre Apple/Android SDKs), by **copying upstream naming and shape** rather
than inventing our own, so the plugin is credible as *the* stable MapLibre Flutter binding.

**Spec.** `docs/api-parity-binding-spec.md` — 703 binding rows, each mapping a canonical API to the
Dart signature to adopt. That document is the source of truth for *what to build and what to call it*.
This file tracks *what is done*.

**Done means:** the goal is reached when every P0 and P1 row in the spec is either implemented,
or explicitly rejected with a recorded reason (mbgl cannot do it), and the ledger says so.

## Status legend

| Mark | Meaning |
| --- | --- |
| `[ ]` | Not started |
| `[~]` | In progress — see the run log for what is half-done |
| `[x]` | Done, gates passed |
| `[-]` | Rejected / not applicable — reason recorded in the run log |

## Stages

Stages are dependency-ordered. **Do not start a stage until every task in the stages above it is
`[x]` or `[-]`.** Within a stage, tasks may be done in any order.

### Stage 0 — Naming policy (no code, ~half a day) — **CLOSED 2026-08-01**

- [x] 0.1 Write the naming policy into `CLAUDE.md` §9: gl-js naming for style/data/camera verbs;
      Android SDK `UiSettings` naming for gesture toggles; Apple SDK shapes for what gl-js lacks
      (offline, snapshotter, location, tile-server/auth, camera-change reason); Flutter value types
      at the boundary (`Duration`, `Color`, `Rect`, `Offset`, `EdgeInsets`, `Alignment`);
      `LatLng`/`LatLngBounds` ordering, never `LngLat`.
- [x] 0.2 Record the three adaptations as deliberate choices: gl-js `on('move')` →
      `Listenable onCameraChanged`; gl-js `on('error')` → `Stream<MapLibreError>`; gl-js `anchor`
      strings → Flutter `Alignment`.
- [x] 0.3 Record — but do not execute — the renames that are cheap now and breaking after 1.0:
      `camera.move()` → `jumpTo`/`easeTo`/`flyTo`; `MapLibreQueriedFeature` → `QueriedFeature`
      (**not** `GeoJsonFeature` — see the run log); `controller.layers` → `controller.style`;
      `setGeoJsonData` → `setSourceData`; `getPosition()` → `getCamera()`; plus
      `addPoints`/`setPoints`/`removePoints` → a recipe name.
- [x] 0.4 Append a dated `docs/decision-log.md` entry for the policy.

### Stage 1 — Value types (pure Dart, zero native work) — **CLOSED 2026-08-01**

No C ABI change, no ffigen regen, no platform-controller ripple, no hardware.

- [x] 1.1 `LatLngBounds` — shape from mbgl `include/mbgl/util/geo.hpp:82`, fields
      `southwest`/`northeast`. **Not** gl-js's lng-first ordering. With
      `fromPoints`/`extend`/`contains`/`intersects`/`center`/`isEmpty`/`crossesAntimeridian`.
- [x] 1.2 Adopt Flutter's `EdgeInsets` as the padding type — do not invent one.
- [x] 1.3 `CameraOptions` (partial camera, every field nullable, incl. `padding` and `anchor`) +
      `CameraAnimation` (duration/curve/speed/minZoom/maxDuration), mirroring
      `include/mbgl/map/camera.hpp:55-115`.
- [x] 1.4 Typed GeoJSON in a `geojson.dart` sub-library: sealed `GeoJsonGeometry` (all seven RFC 7946
      types), `GeoJsonFeature` (id + geometry + properties), `GeoJsonFeatureCollection`, and
      `QueriedFeature` carrying gl-js `MapGeoJSONFeature`'s extras (~~`layer`~~, `source`,
      `sourceLayer`, `state` — **no `layer`**, mbgl destroys it; see the run log).
- [x] 1.5 `MapCameraChangeReason` — Apple `MLNCameraChangeReason.h:30-64` values, as a Dart `Set`.
- [x] 1.6 `MapLibreCapabilities` + re-export the capability interfaces from
      `packages/maplibre_flutter/lib/maplibre_flutter.dart` (today an app cannot even write
      `if (controller is MapLibreModelHost)`).
- [x] 1.7 Harden `LatLng`: normalise/assert NaN, inf, |lat| > 90, wrap longitude. `mbgl::LatLng`
      throws on these and a throw across `extern "C"` is UB.
- [x] 1.8 **P0 defect** — `map_layers_controller.dart:215` drops every non-Point geometry from
      `queryRenderedFeatures`. The C shim already returns the full FeatureCollection.
- [x] 1.9 **P0 defect** — the same method parses and discards the feature `id`.
- [x] 1.10 **P0 defect** — the same method catches `FormatException` while its unchecked casts throw
      `TypeError`, breaking its own documented promise never to throw into a camera-tick caller.
- [x] 1.11 **P0 defect** — `map_layers_controller.dart:365` `setPoints` drops `properties`, making
      data-driven styling impossible through it. (`addPoints` had the same gap; both fixed.)

### Stage 2 — Observer + diagnostics channel — **CLOSED 2026-08-01** (`onIdle` blocked upstream)

Second, not later: `MapLibreMap.style` is a declarative prop and mbgl drops every app-added layer on
style load, so `controller.layers` + a style swap is **broken today with no signal**. Everything
after this stage is undebuggable without it.

- [x] 2.1 `mbl_map_set_diagnostic_callback` fanning out mbgl `MapObserver`: `onDidFailLoadingMap`,
      `onDidFinishLoadingStyle`, `onDidBecomeIdle`, `onStyleImageMissing`, `onGlyphsError`,
      `onSpriteError`, `onRenderError` (`map_observer.hpp:57-94`).
- [x] 2.2 Install `mbgl::Log::setObserver` once behind `std::once_flag`, returning `false` so stderr
      logging survives. **This is the only hook that sees the glyph-404 failure** —
      `MapObserver::onGlyphsError` is dead code in our configuration.
- [x] 2.3 Check the `unique_ptr` return values that `removeSource`/`removeLayer` currently discard
      (`maplibre_flutter_core.cpp:1638`, `:1648`) — a precise synchronous error path needing no
      observer.
- [x] 2.4 Report the silent command drop in `MblMap::post` when `renderLoop == nullptr`
      (`maplibre_flutter_core.cpp:285-292`).
- [x] 2.5 `sealed class MapLibreError` + `Stream<MapLibreError> onError`.
- [~] 2.6 `Stream<void> onStyleLoaded` (repeating) and `Stream<void> onIdle`; `MapLibreMap.onStyleLoaded`
      widget callback. **`onIdle` is blocked** — `onDidBecomeIdle` never fires in our continuous
      configuration; measured, see the run log. `onStyleLoaded` is unblocked and verified.
- [x] 2.7 Pin `onReady` to mean gl-js `load`, and fix the macOS tier which completes it on the first
      **frame** (`maplibre_flutter_macos_controller.dart:141`), contradicting its own dartdoc.
- [x] 2.8 Hold a Dart-side **field** reference to the registered callback (the GC pitfall, CLAUDE.md
      §5e) and add the test for it.

### Stage 3 — Camera commands (over stage-1 types)

Must be verified per hardware tier — CLAUDE.md §11 forbids blind-porting camera changes.

> **Read the spec's "Engine traps that constrain these signatures" preamble before starting this
> stage.** The camera rows were drafted *before* those findings landed in CLAUDE.md §11, so they do
> not reflect them. Three constraints change how — not what — these are implemented:
> `CameraOptions::anchor` is silently discarded whenever `center` is set (`transform.cpp`:
> `anchor = camera.center ? nullopt : camera.anchor`), so anchored `zoomTo(zoom, {around})` /
> `rotateTo(bearing, {around})` **cannot** be get-camera-then-set-camera — `mbl_map_set_camera`
> always sends a centre — and a centre-anchored test cannot detect the bug, because the centre is a
> fixed point either way. `Transform::rotateBy` and `Map::pitchBy` are both broken upstream. Build
> all three on `jumpTo(CameraOptions().withBearing(…).withAnchor(…))` / `.withPitch(…)`, as
> `mbl_map_rotate_by` / `mbl_map_pitch_by` already do.

- [ ] 3.1 Shim `mbl_map_jump_to` / `mbl_map_ease_to` / `mbl_map_fly_to` taking full `CameraOptions`
      (incl. padding + anchor). mbgl has all three natively (`map.hpp:73-75`), so retire the Dart-side
      arc.
- [ ] 3.2 Shim `mbl_map_camera_for_lat_lng_bounds` (`map.hpp:80`), `mbl_map_lat_lng_bounds_for_camera`
      (`:92`), `mbl_map_set_bounds`/`get_bounds` (`:98-101`).
- [ ] 3.3 Dart: `camera.jumpTo/easeTo/flyTo/fitBounds/panBy/panTo/zoomTo/zoomIn/zoomOut/rotateTo/
      resetNorth/stop`, `camera.getBounds()`.
- [ ] 3.4 Dart: `camera.setMaxBounds/setMinZoom/setMaxZoom/setMinPitch/setMaxPitch` (mbgl
      `BoundOptions`, `bound_options.hpp:43-55`).
- [ ] 3.5 `@Deprecated` alias for `move()`; rename `getPosition()` → `getCamera()`.
- [ ] 3.6 Define and document the completion contract: camera `Future`s complete on transition **end**;
      superseded animations complete rather than error.

### Stage 4 — Camera lifecycle + reason (pure Dart, no native work)

Our gesture recognisers live in Dart and are the only thing that knows pan vs pinch vs twist vs shove —
mbgl's `CameraChangeMode` is only `{Immediate, Animated}`. That is a structural advantage; bank it.

- [ ] 4.1 Thread `MapCameraChangeReason` through the Dart gesture layer (`maplibre_map.dart:553-990`)
      and through `moveCamera`.
- [ ] 4.2 `onCameraMoveStart` / `onCameraMoveEnd` streams carrying the reason; keep `onCameraChanged`
      as the continuous `Listenable`.
- [ ] 4.3 `isMoving` / `isZooming` / `isRotating`, backed by mbgl `Map::isPanning/isScaling/isRotating`
      (`map.hpp:66-68`).

### Stage 5 — Style & data operations, mirroring gl-js `Map` one-for-one

Highest row count in the backlog, correctly last among the core stages.

- [ ] 5.1 Rename the namespace `controller.layers` → `controller.style` (it owns sources, images and
      transitions — it is `MLNStyle`, not layers); move queries off it.
- [ ] 5.2 `mbl_map_set_layer_property(map, layerId, name, valueJson)` over `Layer::setProperty`
      (`layer.hpp:144`). **One entry point** covers paint, layout, `visibility`, `minzoom`, `maxzoom`
      **and** `filter` (`layer.cpp:165-190`) — the ABI needs no gl-js-style split.
- [ ] 5.3 `moveLayer(id, beforeId)` — ~15 lines: `Style::removeLayer` returns the owning `unique_ptr`
      and `addLayer` takes `before`; the `Layer` object survives intact.
- [ ] 5.4 Read side: `getLayer(id)`, `getLayersOrder()`, `getPaintProperty`, `getLayoutProperty`,
      `getFilter`. Note `Style::getJSON()` returns the document **as loaded**, not a live
      serialisation — use `getLayers()` + `Layer::serialize()` for the live view.
- [ ] 5.5 `setLayerZoomRange`.
- [ ] 5.6 `getSource(id)` handle with `setData` (renaming `setGeoJsonData`), `isSourceLoaded`.
- [ ] 5.7 `hasImage`, `listImages`, `updateImage`.
- [ ] 5.8 Style from **inline JSON** and from a Flutter asset. `Style::loadJSON` exists
      (`style.hpp:29`) and is never called; five doc comments — including the C header at
      `maplibre_flutter_core.h:41` and `:56` — already promise inline JSON works.
- [ ] 5.9 Re-apply app-added sources, layers and images after a style load (today the shim re-applies
      **only** models and transition options, `maplibre_flutter_core.cpp:890-899`).
- [ ] 5.10 Demote `addPoints`/`setPoints`/`removePoints` to a clearly-named recipe — they have no
      upstream equivalent and currently read as spec API.
- [ ] 5.11 Namespace model layers internally (`mbl:model:<id>`) inside the C shim, closing three live
      bugs: a model deleted via `removeLayer` resurrects on the next style load; its Dart `_models`
      entry keeps a `Ticker` calling `triggerRepaint` forever; and `removeModel(id)` can delete an
      unrelated style layer that took the freed id.

### Stage 6 — Queries and feature state (over stage-1's GeoJSON types)

- [ ] 6.1 `queryRenderedFeatures` overloads: point, `Rect`, `LatLngBounds`, plus a `filter`
      (mbgl `RenderedQueryOptions{layerIDs, filter}`, `renderer/query.hpp:14-24`). Add a
      `Future`-returning form; the current call blocks the UI isolate on a condvar deadline.
- [ ] 6.2 Distinguish "timed out" from "nothing found" — both return `const []` today.
- [ ] 6.3 `querySourceFeatures(sourceId, {sourceLayers, filter})` (`query.hpp:30-38`).
- [ ] 6.4 `setFeatureState` / `getFeatureState` / `removeFeatureState` (`renderer.hpp:74-86`).
      **Constraint:** mbgl never parses `promoteId` or `generateId`, so feature state only works on
      features whose own GeoJSON/MVT `id` is set. Document this loudly.
- [ ] 6.5 Cluster helpers `getClusterExpansionZoom` / `getClusterChildren` / `getClusterLeaves`
      (Apple `MLNShapeSource.h:408-437`), taking the int `cluster_id` (gl-js shape).
- [ ] 6.6 Return `QueriedFeature`; retire `MapLibreQueriedFeature`.
- [ ] 6.7 `MapLibreMap.onTap` must report the screen point, not only the unprojected `LatLng` — today
      there is no supported path from a tap to the features under it.

### Stage 7 — Web parity + verification pass (no new API surface)

- [ ] 7.1 Implement the stage-2 observer on `maplibre_flutter_web` (WASM core). **Check first:** as of
      `cbfa220` the web tier already implements `MapLibreMapProjector` and `MapLibreStyleLayers`.
- [ ] 7.2 Verify every stage 1–6 addition on the unverified native tiers (Linux, Windows, Android),
      flipping 🧪 → ✅ only on evidence.
- [ ] 7.3 Assert real content in tests, never "a frame came back" — non-blank pixels, expected colours,
      a dumped PNG (CLAUDE.md §7).

### Stage 8 — SDK-shaped extras (Apple/Android shapes; gl-js has no vocabulary)

- [ ] 8.1 **Persistent cache** — both render threads build the map with `ResourceOptions::Default()`,
      whose `cachePath` is `":memory:"`, and `mbl_map_create` takes no cache path. There is no
      persistent tile cache at all; this is worse than mbgl's own default.
- [ ] 8.2 API key / auth headers / `transformRequest` — `ResourceOptions::withApiKey` is never called,
      so today the only hatch is embedding a token in the tile URL template.
- [ ] 8.3 Offline: `MLNOfflineStorage` (`:198`, `.packs` `:287`, `-addPackForRegion:` `:310`),
      `MLNOfflinePack`, `MLNTilePyramidOfflineRegion` / `MLNShapeOfflineRegion`.
- [ ] 8.4 Snapshotter: `MLNMapSnapshotter` / `MLNMapSnapshotOptions` (`:70-141`). **Build-system note:**
      `map_snapshotter.cpp` is compiled only on the Apple arm of `src/CMakeLists.txt` — four native
      tiers need a CMake change, not just a C ABI one. `mbl_map_write_png` already exists and is
      wrapped in Dart but is exposed on no public controller.
- [ ] 8.5 Location component: `MLNUserLocation`, `MLNLocationManager`, `MLNUserTrackingMode`.
- [ ] 8.6 Attribution — rendered on the map. **Legal obligation** for many tile providers, and we
      render none; `getSource` cannot read the strings back either.
- [ ] 8.7 Marker `offset` and `zIndex` (gl-js `Marker` has both; ours has only `alignment`).
- [ ] 8.8 `MapOptions` growth: min/max zoom, min/max pitch, `maxBounds`, `constrainMode`.

### Stage 9 — Retire the hand-maintained matrix

- [ ] 9.1 `tool/generate_feature_matrix.dart` deriving rows from code: the `implements` clauses of the
      six platform controllers, the members of the base contract + capability interfaces, the
      `FFI_PLUGIN_EXPORT` list in `maplibre_flutter_core.h`, the `EMSCRIPTEN_BINDINGS` `.function()`
      list, and `v8.json`. Output committed and regen-diffed in CI like ffigen.
- [ ] 9.2 Delete or shrink the hand-maintained tables in `FEATURE_MATRIX.md` to the judgement-bearing
      prose only. An audit found ~44% of sampled cells wrong, and the file had been hand-fixed five
      hours before that audit.

## Run log

Append one entry per run. Newest last.

<!-- template:
### YYYY-MM-DD — <tasks attempted>
- **Done:** 1.1, 1.2
- **Left half-done:** 1.4 — geometry types written, FeatureCollection not yet
- **Deferred / rejected:** none
- **Spec corrections found:** none
- **Gates:** analyze clean / tests green / format applied / no generated-file diff
-->

### 2026-08-01 — Stage 0 (0.1, 0.2, 0.3, 0.4) — stage closed

- **Done:** 0.1, 0.2, 0.3, 0.4. The policy is now operative guidance in a new **CLAUDE.md §9 "API
  naming policy"** subsection (which upstream wins each surface, the three adaptations, the
  deliberate divergences, and the rename table with the stage each lands in). The *why* — including
  what was rejected — is a dated entry at the end of `docs/decision-log.md`.
- **Left half-done:** none.
- **Deferred / rejected:** the six renames are decided and scheduled but deliberately **not
  executed** (that is what 0.3 asks for). The operative half is a constraint on stages 1–8: no new
  API may be added under the old vocabulary, and each rename ships with a `@Deprecated` alias for
  one release.
- **Spec corrections found:** three.
  1. **The spec contradicts itself on gesture-toggle naming.** `:52` and `:241` say commit to the
     Android `UiSettings` vocabulary; the gestures-domain naming section at `:2934` picks gl-js's
     `MapOptions` keys instead and, at its item 5, would demote our shipped
     `rotateGesturesEnabled`/`tiltGesturesEnabled` to `@Deprecated` pass-throughs. Settled for
     **Android**, per the ledger's own 0.1 wording: gl-js's names are DOM-input-flavoured, we ship
     two of the Android names today, and `google_maps_flutter` and `maplibre_gl` have both
     converged on `…GesturesEnabled`. gl-js's *granularity* argument is real and was kept — split a
     coarse Android toggle with the same `…Enabled` suffix rather than importing a gl-js handler
     name. `:2935` is now marked SUPERSEDED in place, with the rejected reasoning kept.
  2. **Ledger 0.3 names the wrong replacement type.** It says `MapLibreQueriedFeature` →
     `GeoJsonFeature`, but 1.4 and 6.6 define `GeoJsonFeature` (id + geometry + properties) and
     `QueriedFeature` (which adds gl-js `MapGeoJSONFeature`'s `layer`/`source`/`sourceLayer`/
     `state`) as *different* types. The replacement is `QueriedFeature`. Ledger row corrected.
  3. **Three different shapes are proposed for camera-change events** — spec camera-domain item 10
     (one `Stream<MapCameraEvent>` with a `phase` field), spec gestures-domain item 4 (Android-named
     `onCameraMoveStarted`/`onCameraMove`/`onCameraIdle` widget callbacks), and ledger 4.2
     (`onCameraMoveStart`/`onCameraMoveEnd` streams + the `onCameraChanged` `Listenable`). Not
     settled here: it is a delivery-mechanism decision, not a naming one, and it wants the stage-2
     observer in hand. **Stage 4 must pick one before writing 4.2**; the ledger's version is the
     default unless stage 2 shows otherwise.
- **Gates:** `analyze` clean (13 packages, no issues) / `test --no-select` green / `format` clean /
  stage-0 gate satisfied — the diff touches only `CLAUDE.md`, `docs/decision-log.md`,
  `docs/api-parity-binding-spec.md` and this file; no `*_generated.dart` and no
  `maplibre_flutter_core.{h,cpp}`.
- **Next run:** Stage 1 is now open. Start with the P0 defects **1.8–1.11**
  (`map_layers_controller.dart:215` drops every non-Point geometry, `:215` discards the feature id,
  the `FormatException`-vs-`TypeError` catch, and `setPoints` dropping `properties`) — they are the
  smallest, are pure Dart, and are testable device-free. Then 1.1/1.2 (`LatLngBounds` + `EdgeInsets`)
  as the value-type spine. Note the trap for 1.4: `GeoJsonFeature.toJson()` must **not** use
  `encodeStyleJson` (it rewrites `6.0` → `6`); test that `60.45` survives byte-identically.

### 2026-08-01 — Stage 1 (1.4, 1.8, 1.9, 1.10, 1.11) — the typed GeoJSON types and the four P0 query defects

- **Done:** 1.4, 1.8, 1.9, 1.10, 1.11.
  - **1.4** — new `geojson.dart` sub-library. The types live in the platform interface
    (`lib/src/geojson/{geometry,feature}.dart`) because stage 6's `setFeatureState` needs them at the
    contract level, and are re-exported as `package:maplibre_flutter/geojson.dart` — the import path
    the spec names — and from `package:maplibre_flutter` itself, since `queryRenderedFeatures`
    returns one. `sealed GeoJsonGeometry` + all seven RFC 7946 types, `GeoJsonFeature`,
    `GeoJsonFeatureCollection`, `QueriedFeature`. Every position flips `[lng, lat]` ⇄
    `LatLng(lat, lng)` exactly once, at parse/serialise. `GeoJsonData` gained matching typed
    constructors (`.feature`, `.featureCollection`, `.geometry`) so the same types work inbound.
    26 new tests in the platform interface, asserted against **absolute directions** (Turku is north
    and east of Stockholm; Rio is south and west of both) rather than round-trips.
  - **1.8/1.9** — `queryRenderedFeatures` now returns `List<QueriedFeature>` with the full geometry
    and the feature `id`. `MapLibreQueriedFeature` survives as a `@Deprecated` typedef, so
    `List<MapLibreQueriedFeature>` still type-checks; the one source-level break is that `.point` is
    now `LatLng?`, which it had to become once non-point geometries stopped being dropped. The
    example is updated.
  - **1.10** — the parser no longer casts. Every read is checked and every failure inside the
    geometry/feature parsers is a `FormatException`, so the method's "never throws into a camera-tick
    caller" promise now actually holds; a single unreadable feature is skipped rather than costing
    the whole frame's results. Tested with strings-for-numbers, a bare string in place of a feature,
    an empty coordinate array and an unknown geometry type — all of which used to throw `TypeError`
    straight past the `on FormatException`.
  - **1.11** — `properties` added to both `setPoints` **and** `addPoints`; the ledger named only
    `setPoints`, but with `addPoints` unable to attach them the feature was half-usable.
- **Left half-done:** none.
- **Deferred / rejected:** `QueriedFeature.source` / `.sourceLayer` / `.state` parse correctly but
  are **null/empty on every native tier today** — `mbgl::Feature` carries all three, but the C shim
  copies the query result into a `mapbox::feature::feature_collection<double>` before
  `stringify` (`maplibre_flutter_core.cpp`, in `mbl_map_query_rendered_features`), which slices them
  off. That is a C ABI change and stage 1's gate forbids one, so it is stage 6's. Documented on the
  fields themselves.
- **Spec corrections found:** two, both from reading the engine rather than the spec.
  1. **`QueriedFeature` must not have a `layer` field**, though ledger 1.4 and spec `:184`/`:231`
     both list one. `RenderOrchestrator::queryRenderedFeatures` builds `resultsByLayer` and then
     flattens it into a single `std::vector<Feature>` before returning, so per-feature layer
     attribution is destroyed inside the engine — the Apple SDK returns the same flattened array.
     Spec `:2564` already said this and is the row that is right. Per-layer querying via `layerIds`
     is the only honest way to get attribution, and the dartdoc says so.
  2. **`mbgl::Feature` *does* carry `source`/`sourceLayer`/`state`** (`include/mbgl/util/feature.hpp`
     — it is `GeoJSONFeature` plus exactly those three), so spec `:2564`'s wider claim that the
     engine destroys all provenance is too strong. Only the `layer` grouping is lost; the other
     three are lost in **our** shim, and are recoverable there. Spec `:3565` has this right.
- **Gates:** `analyze` clean (13 packages) / `test --no-select` green (203 in `maplibre_flutter`, 32
  in the platform interface) / `format` clean / stage-1 gate satisfied — no `*_generated.dart` and no
  `maplibre_flutter_core.{h,cpp}` in the diff.
- **Next run:** 1.1 (`LatLngBounds`, mbgl `geo.hpp:82` shape, `southwest`/`northeast`), 1.2
  (adopt `EdgeInsets`), 1.3 (`CameraOptions` + `CameraAnimation`) and 1.7 (`LatLng` hardening) —
  the value-type spine, all pure Dart. 1.5 and 1.6 close the stage after that.

### 2026-08-01 — Stage 1 (1.1, 1.2, 1.3, 1.7) — the value-type spine

- **Done:** 1.1, 1.2, 1.3, 1.7. All in the platform interface, all pure Dart, 26 new tests.
  - **1.1 `LatLngBounds`** — `southwest`/`northeast` per `mbgl::LatLngBounds`, with `fromPoints`
    (mbgl's `hull`), `world`, `empty`, `singleton`, `extend`/`extendBounds`, `contains`/
    `containsBounds`, `intersects`, `center`, the four corners and four edges, `isValid`/`isEmpty`
    and `crossesAntimeridian`. Not gl-js's `LngLatBounds`, per the stage-0 policy.
  - **1.2 `EdgeInsets`** — adopted as-is for `CameraOptions.padding`; no type invented.
  - **1.3 `CameraOptions` + `CameraAnimation`** — the partial camera (center/zoom/bearing/pitch/roll/
    padding/anchor, all nullable) with `fromCamera`, `applyTo`, `copyWith`; and the animation options
    as `duration` / `easing` / `speed` / `apexZoom`.
  - **1.7 `LatLng` hardening** — the constructor now asserts exactly what `mbgl::LatLng`'s throws on
    (NaN lat, NaN lng, `|lat| > 90` — which also catches infinity — and non-finite lng), plus
    `LatLng.sanitized` for values from outside, `wrapped()` matching `mbgl::util::wrap`'s `[min, max)`
    semantics, and `isValid` for release-build guards. Longitude is deliberately left unbounded
    because mbgl's default is `WrapMode::Unwrapped`.
- **Left half-done:** none.
- **Deferred / rejected:** four things, each with the engine evidence:
  - **`CameraAnimation` has no `curve`** (gl-js `flyTo({curve})`, the van Wijk ρ). `Transform::flyTo`
    hardcodes `rho = 1.42` and only varies it indirectly from `minZoom`; there is no field to bind.
  - **No `maxDuration`** — `mbgl::AnimationOptions` has no counterpart; a flight's duration is
    computed inside the engine. Fixing `duration` is the available lever.
  - **`CameraOptions` omits `centerAltitude` and `fov`**, which mbgl does have. Nothing consumes them
    and adding a named optional field later is source-compatible, so they wait for a caller.
  - **The platform controllers were not switched to `LatLng.sanitized`** at their unproject
    boundaries. They do not need it — `screenCoordinateToLatLng` returns an `mbgl::LatLng`, so the
    value has already passed mbgl's own checks — and stage 1 is meant to cause no controller ripple.
- **Spec corrections found:** one, plus a naming call.
  - Ledger 1.3 lists `CameraAnimation` as `duration/curve/speed/minZoom/maxDuration`. Two of those
    are unbindable (above), and `minZoom` is shipped as **`apexZoom`** per the stage-0 policy —
    `minZoom` already means a hard constraint in the same namespace (`camera.setMinZoom`), so the
    collision would have been permanent.
  - The `easing` field is typed **`Cubic`, not `Curve`**. mbgl takes a `UnitBezier`, which only a
    cubic maps onto; accepting any `Curve` and quietly transmitting four control points would be the
    silent-degradation trap CLAUDE.md §11 is a list of. Flutter's named easings are `Cubic`s and pass
    straight through; `Curves.linear` is not one, and the dartdoc says so.
- **Caught by the new asserts:** `marker_overlay_test.dart`'s fake `unproject` mapped screen pixels
  straight to degrees (`LatLng(o.dy, o.dx)`), producing latitude 222 — impossible, and exactly what
  1.7 exists to stop reaching the shim. The fixture now scales by 10; the direction assertions
  (y→lat, x→lng) are unchanged, which is what the test was actually for.
- **Gates:** `analyze` clean (13 packages) / `test --no-select` green (203 in `maplibre_flutter`, 58
  in the platform interface) / `format` clean / stage-1 gate satisfied — no `*_generated.dart`, no
  `maplibre_flutter_core.{h,cpp}`.
- **Next run:** 1.5 (`MapCameraChangeReason`, Apple's bitmask as a Dart `Set`) and 1.6
  (`MapLibreCapabilities` + re-exporting the capability interfaces) close stage 1. Then stage 2 —
  which is the first stage needing a C ABI change and an ffigen regen on macOS.

### 2026-08-01 — Stage 1 (1.5, 1.6) — stage closed

- **Done:** 1.5, 1.6.
  - **1.5 `MapCameraChangeReason`** — Apple's `MLNCameraChangeReason` value for value, as a Dart
    `enum` used through a `Set`, so `MLNCameraChangeReasonNone` is the empty set and a twisting
    pinch is `{gesturePinch, gestureRotate}` rather than a mask. Apple's own documented groupings
    ship as `anyGesture` / `anyZoom` / `anyRotation` static sets, and a
    `MapCameraChangeReasons` extension gives `isGesture` (Android's coarse `REASON_API_GESTURE`),
    `isProgrammatic`, `isZoom`, `isRotation`, `isTilt`, `isCancelled`. Nothing produces one yet —
    stage 4 threads it through the gesture layer.
  - **1.6 `MapLibreCapabilities`** — `controller.capabilities`, derived in one place by the same
    `is` checks the controller already makes, reporting `projection` / `styleLayers` / `models` /
    `rotateAndTilt` / `gestures`. The five capability interfaces are now **also** exported from
    `package:maplibre_flutter`, so `if (controller is MapLibreModelHost)` works — previously
    impossible, since the app-facing library re-exported only four value types.
- **Left half-done:** none. **Stage 1 is closed**; stage 2 is open.
- **Deferred / rejected:** none.
- **Spec corrections found:** one, resolved by doing both halves.
  - Spec `:224` argues for the value object *instead of* exporting the interfaces ("keeps the
    interfaces internal to implementers"); ledger 1.6 asks for both. Both landed, because they
    answer different questions — `capabilities` is the ergonomic probe, and `is` is the escape
    hatch for anything the value object does not name. The spec's underlying worry is real and is
    handled in the dartdoc instead: these are `abstract interface class`es for **platform packages**
    to implement, and an app that implements one will be broken by the next member added, which
    CLAUDE.md §3 says is a deliberate all-tiers-at-once event.
- **Gates:** `analyze` clean (13 packages) / `test --no-select` green (203 in `maplibre_flutter`,
  65 in the platform interface) / `format` clean / stage-1 gate satisfied — no `*_generated.dart`,
  no `maplibre_flutter_core.{h,cpp}`.
- **Next run:** **stage 2, the observer and diagnostics channel** — and it is a different kind of
  run from the last three. It needs a C ABI change (`mbl_map_set_diagnostic_callback`), an ffigen
  regeneration **on macOS**, an extension to the fake in
  `packages/maplibre_flutter_core/lib/testing.dart`, and a Dart-side **field** reference to the
  registered callback or the GC collects the proxy. Start with 2.1 + 2.2 (the callback and
  `mbgl::Log::setObserver`, which is the only hook that sees a glyph 404), then 2.5/2.6/2.8 on the
  Dart side. 2.3 and 2.4 are independent and small.

### 2026-08-01 — Stage 2 (2.1, 2.2, 2.8) — the diagnostics channel exists

First run of this effort to change the C ABI. Regenerated ffigen on macOS; the committed bindings
are diff-clean.

- **Done:** 2.1, 2.2, 2.8.
  - **2.1 `mbl_map_set_diagnostic_callback`** — one callback carrying `(kind, severity, message)`.
    The observer half is a new `DiagnosticObserver : mbgl::MapObserver` reporting
    `onDidFinishLoadingStyle`, `onDidFinishLoadingMap`, `onDidFailLoadingMap`, `onDidBecomeIdle`,
    `onStyleImageMissing`, `onGlyphsError`, `onSpriteError` and `onRenderError`. `FrameObserver`
    now extends it, so the Continuous map keeps its frame publishing and style re-adds unchanged;
    Static mode gets the diagnostics it previously had none of (it ran on `nullObserver()`).
    `message` ownership transfers to the callee — the receiver is necessarily asynchronous (a Dart
    `NativeCallable.listener`), so a borrowed `const char*` would dangle; Dart releases it with the
    existing `mbl_string_free`.
  - **2.2 `mbgl::Log::setObserver`** — installed once behind `std::once_flag`, the first time any
    map registers a diagnostic callback, returning **false** so mbgl still writes to stderr.
    Process-wide, so it fans out to every map that has a listener. **Verified to be the only hook
    that sees a glyph 404**: the new test adds a symbol layer with a font demotiles does not serve
    and asserts the failure arrives — `MapObserver::onGlyphsError` stays silent, exactly as 2.2
    predicted.
  - **2.8** — the `NativeCallable` is held in a **field** on `MapLibreCoreMap`, not a local, and
    closed only after the native side has been unregistered. `dispose` unregisters first, and
    `mbl_map_destroy` also clears the callback and drops the map from the log fan-out before any
    teardown, so an event in flight on the render thread finds nothing to call.
  - Plus the stage gate's fake: `RecordingCoreMap` gained `setDiagnosticCallback`,
    `diagnosticListener`, `diagnosticRegistrations` and `emitDiagnostic`, so the controller work in
    2.5–2.7 is testable on the VM with no dylib.
- **Left half-done:** none of 2.1/2.2/2.8. Stage 2 continues with 2.3–2.7.
- **Deferred / rejected:** nothing yet — but see the finding below, which constrains 2.6.
- **Finding that changes a later task — `onIdle` cannot be built on `onDidBecomeIdle`.** Measured,
  not assumed: a healthy demotiles map watched for **45 seconds** reports `styleLoaded` once at
  169 ms and **nothing else, ever** — no `mapLoaded`, no `idle`. Both of those are gated on
  `Map::Impl::rendererFullyLoaded`, which is set from `renderMode == RenderMode::Full`
  (`map_impl.cpp`), which `renderer_impl.cpp` only reports when `renderTreeParameters.loaded` is
  true. Something in our continuous configuration keeps the render tree from ever reporting loaded.
  So ledger 2.6's `onIdle` is **blocked pending that investigation** and is marked as such; the
  `onStyleLoaded` half of 2.6 is unblocked and its repeating behaviour is now pinned by a test
  (load, swap style, load again). This is the same shape of finding as 2.2's: the event the design
  assumed is dead, and only measuring showed it.
- **Gates:** `analyze` clean (13 packages) / `test --no-select` green / `test:native` green (32
  tests, 5 of them new) / `format` clean / **stage-2 gate**: ffigen regenerated on macOS and the
  committed bindings are diff-clean; the fake in `packages/maplibre_flutter_core/lib/testing.dart`
  covers the new surface.
- **Next run:** 2.5 (`sealed class MapLibreError` + `Stream<MapLibreError> onError`), 2.6's
  `onStyleLoaded` half, and 2.7 (`onReady` == gl-js `load`, fixing the macOS tier that completes it
  on the first **frame**). That means extending the platform interface with a `MapLibreStyleEvents`
  capability — decided on 2026-07-31 in `docs/decision-log.md` and still unimplemented — which
  lands atomically across all tiers plus the fakes. 2.3 and 2.4 are small, independent and can ride
  along.

### 2026-08-01 — Stage 2 (2.3, 2.4, 2.5, 2.6, 2.7) — stage closed

- **Done:** 2.3, 2.4, 2.5, 2.7, and the `onStyleLoaded` half of 2.6.
  - **2.3** — `removeLayer`/`removeSource` now read the `unique_ptr` mbgl hands back instead of
    discarding it, and report `MBL_DIAG_COMMAND_FAILED`. `removeSource` returns the same null for two
    different failures (no such source, and a layer still references it — `style_impl.cpp` refuses
    and only logs), so the shim checks `getSource` first and tells them apart. "Still in use" is the
    one people actually hit: the removal appears to do nothing at all.
  - **2.4** — `MblMap::post` reports the drop when `renderLoop == nullptr`. That window is between
    `mbl_map_create` returning and the render thread publishing its RunLoop; anything posted into it
    used to vanish without trace, the classic shape being a camera set straight after create that
    simply does not happen.
  - **2.5** — `sealed class MapLibreError` with `MapStyleError` / `MapGlyphsError` /
    `MapSpriteError` / `MapRenderError` / `MapCommandError` / `MapEngineError`, and
    `Stream<MapLibreError> onError`. Log records only become errors at **warning or above** — the
    engine logs a great deal an app cannot act on, and that filter is also what keeps the glyph 404
    (which arrives as an error-level log record and nothing else) visible.
  - **2.6, `onStyleLoaded`** — `Stream<void> onStyleLoaded` (repeating, verified by a native test
    that loads, swaps style and loads again), `Stream<String> onStyleImageMissing` (gl-js
    `styleimagemissing`; free on the same channel and actionable, so not dropped), and the
    `MapLibreMap.onStyleLoaded` widget callback. The widget subscribes **before** attaching, since
    the first style load can beat attach's future.
  - **2.7** — `onReady` now means gl-js `load` on all five core tiers: the initial style loaded
    **and** a frame published. It used to complete on the first frame alone, which is the race the
    2026-07-31 decision-log entry described — add a layer right after awaiting it and the style load
    that follows silently drops the layer. A style that never loads now never completes `onReady`,
    exactly as gl-js never fires `load`; `onError` is how you hear about it. The contract is written
    out on `MapLibreMapPlatformController.onReady`.
  - The capability is `MapLibreMapEvents` in the platform interface, implemented by all five
    `mbgl-core` tiers and feature-detected with `is`; `MapLibreCapabilities` gained `events`. The
    app-facing controller owns its own broadcast controllers and pipes the platform's streams into
    them on attach — a controller exists before the map does, and the most valuable error is a first
    style load that fails, so listening must work immediately.
- **Left half-done / blocked:** `onIdle` only. `MapObserver::onDidBecomeIdle` does not fire in our
  continuous configuration (measured last run: 45 s, one `styleLoaded` and nothing else), so there is
  no event to build it on. 2.6 is `[~]` for that reason and the stage is otherwise closed.
- **Spec corrections found:** one naming call. The 2026-07-31 decision log named this capability
  `MapLibreStyleEvents`. Shipped as **`MapLibreMapEvents`**, because it carries errors as well as
  style events and a name that says "style" would need working around the first time an app wanted
  `onError`. Recorded here rather than silently diverging.
- **Gates:** `analyze` clean (13 packages) / `test --no-select` green (218 in `maplibre_flutter`,
  including 135 conformance assertions across all five tiers) / `test:native` green (33) / `format`
  clean / **stage-2 gate**: ffigen regenerated on macOS, bindings diff-clean (the new diagnostic kind
  is an enum value, and ffigen excludes enums, so no binding changed); the `RecordingCoreMap` fake
  drives the new surface, and the conformance suite now asserts that `onReady` waits for the style,
  that engine failures arrive as typed errors, and that each tier unregisters its diagnostic
  listener on dispose.
- **Next run:** stage 3 — camera commands. Read the stage's preamble first: `CameraOptions::anchor`
  is discarded whenever `center` is set, and `Transform::rotateBy` / `Map::pitchBy` are both broken
  upstream. It also needs hardware verification per tier, macOS first.

### 2026-08-01 — Example app: every stage 0–2 addition, demonstrated and RUN

The first run of this effort to launch the app on hardware rather than stopping at green tests. It
found two bugs the whole suite had missed, both in code added earlier the same day.

- **Demonstrated in `packages/maplibre_flutter/example`:**
  - New **`Typed GeoJSON + queries`** scenario. A `GeoJsonFeatureCollection` of a `GeoJsonPolygon`
    (region), a `GeoJsonLineString` (route), three `GeoJsonPoint` cities and a `GeoJsonMultiPoint`
    (buoys), each with an `id` and `properties`, fed in through `GeoJsonData.feature` /
    `.featureCollection` — no JSON string anywhere. Circle radius is driven by a `population`
    property that arrived through the typed feature. Plus two points added with
    `addPoints(properties:)`, the 1.11 fix.
  - **Tap-to-query.** Verified on macOS: tapping returns a **`MultiPolygon` with `id: 55`** and its
    properties, from the basemap's country layer — a feature the old decoder dropped on the floor
    (1.8) along with its id (1.9).
  - **Engine diagnostics panel** fed by `controller.onError` / `onStyleImageMissing`, and a
    **"Break something"** button that provokes three genuinely different failures. All observed
    live: `MapCommandError(removeLayer: no layer with id …)`, `MapCommandError(removeSource: … is
    still in use)`, and two `MapEngineError`s carrying the glyph 404 that reaches **only** the log
    observer.
  - **`MapLibreMap.onStyleLoaded`** replaced `await Future.delayed(700ms)` in the style toggle. The
    delay was a guess that raced both ways; the callback is the only correct moment.
  - **Capabilities dialog** showing live `MapLibreCapabilities`, the `LatLngBounds` of the engine
    dataset, a partial `CameraOptions`, and `LatLng.sanitized` / `wrapped` against values
    `mbgl::LatLng` would throw on.
  - **"Fit to data"** composing `LatLngBounds.fromPoints` + `CameraOptions.applyTo` — `fitBounds`
    itself is stage 3.
  - The scenario teardown was rewritten from a blanket list of every id any scenario might have used
    into per-scenario undo closures. That blanket removal was invisible until `onError` existed;
    now it reported seven `MapCommandError`s per scenario switch. An error channel makes removing
    optimistically untenable within minutes of existing, which is a fair advertisement for it.
- **NOT demonstrated, because faking it would be dishonest:** `MapCameraChangeReason` has no
  producer until stage 4 threads it through the gesture layer, and `CameraAnimation` has no consumer
  until stage 3 binds `easeTo`/`flyTo`. Both are unit-tested value types today.
- **Two bugs found by running it — both introduced earlier today, both invisible to the tests:**
  1. **`onReady` never completed in the real app.** mbgl's `onDidFinishLoadingStyle` is one-shot and
     fires ~169 ms after create, but a controller can only register its callback *after*
     `mbl_map_create` returns and, on the texture tiers, after the registrar handshake. So the event
     was routinely gone before anyone was listening, and 2.7's new readiness rule waited for it
     forever. **Fixed in the shim**: `mbl_map_set_diagnostic_callback` now replays one
     `MBL_DIAG_STYLE_LOADED` if a style has already loaded. The native tests could not have caught
     this — they register immediately after create, which is the one ordering a real app cannot use.
  2. **The replay was then dropped again, one level up.** The platform controller emitted it into a
     broadcast `StreamController` before `MapLibreMapController.attach` had subscribed, and a
     broadcast stream discards events with no listener. Pure race: the scenario drew on one launch
     and not the next. **Fixed at both levels** — the tier's `onStyleLoaded` and the app-facing one
     replay to a late subscriber. This matters more than a missed notification: this event is what
     tells an app to re-apply the layers mbgl just dropped, so losing it leaves the map permanently
     missing them.
- **Gates:** `analyze` clean (13 packages) / `test --no-select` green (221 in `maplibre_flutter`,
  including 140 conformance assertions) / `test:native` green (34) / `format` clean / ffigen
  diff-clean / **run on macOS hardware**, the reference tier, with screenshots confirming the layers
  draw, the query returns a MultiPolygon with its id, and all five failure kinds reach the panel.
- **Next run:** stage 3, camera commands. Note that the two bugs above are the same shape as what
  stage 3 will face — an event or command that races creation — and that `_applyScenario` in the
  example is now a second consumer of `onStyleLoaded` worth re-reading when `fitBounds` lands.
