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

### Stage 3 — Camera commands — **CLOSED 2026-08-01**, verified on macOS hardware

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

- [x] 3.1 Shim `mbl_map_jump_to` / `mbl_map_ease_to` / `mbl_map_fly_to` taking full `CameraOptions`
      (incl. padding + anchor). mbgl has all three natively (`map.hpp:73-75`), so retire the Dart-side
      arc.
- [x] 3.2 Shim `mbl_map_camera_for_lat_lng_bounds` (`map.hpp:80`), `mbl_map_lat_lng_bounds_for_camera`
      (`:92`), `mbl_map_set_bounds`/`get_bounds` (`:98-101`).
- [x] 3.3 Dart: `camera.jumpTo/easeTo/flyTo/fitBounds/panBy/panTo/zoomTo/zoomIn/zoomOut/rotateTo/
      resetNorth/stop`, `camera.getBounds()`.
- [x] 3.4 Dart: `camera.setMaxBounds/setMinZoom/setMaxZoom/setMinPitch/setMaxPitch` (mbgl
      `BoundOptions`, `bound_options.hpp:43-55`).
- [x] 3.5 `@Deprecated` alias for `move()`; rename `getPosition()` → `getCamera()`.
- [x] 3.6 Define and document the completion contract: camera `Future`s complete on transition **end**;
      superseded animations complete rather than error.

### Stage 4 — Camera lifecycle + reason — **CLOSED 2026-08-01**

Our gesture recognisers live in Dart and are the only thing that knows pan vs pinch vs twist vs shove —
mbgl's `CameraChangeMode` is only `{Immediate, Animated}`. That is a structural advantage; bank it.

- [x] 4.1 Thread `MapCameraChangeReason` through the Dart gesture layer (`maplibre_map.dart:553-990`)
      and through `moveCamera`.
- [x] 4.2 `onCameraMoveStart` / `onCameraMoveEnd` streams carrying the reason; keep `onCameraChanged`
      as the continuous `Listenable`.
- [x] 4.3 `isMoving` / `isZooming` / `isRotating`, backed by mbgl `Map::isPanning/isScaling/isRotating`
      (`map.hpp:66-68`).

### Stage 5 — Style & data operations, mirroring gl-js `Map` one-for-one

Highest row count in the backlog, correctly last among the core stages.

- [ ] 5.1 Rename the namespace `controller.layers` → `controller.style` (it owns sources, images and
      transitions — it is `MLNStyle`, not layers); move queries off it.
- [x] 5.2 `mbl_map_set_layer_property(map, layerId, name, valueJson)` over `Layer::setProperty`
      (`layer.hpp:144`). **One entry point** covers paint, layout, `visibility`, `minzoom`, `maxzoom`
      **and** `filter` (`layer.cpp:165-190`) — the ABI needs no gl-js-style split.
- [x] 5.3 `moveLayer(id, beforeId)` — ~15 lines: `Style::removeLayer` returns the owning `unique_ptr`
      and `addLayer` takes `before`; the `Layer` object survives intact.
- [x] 5.4 Read side: `getLayer(id)`, `getLayersOrder()`, `getPaintProperty`, `getLayoutProperty`,
      `getFilter`. Note `Style::getJSON()` returns the document **as loaded**, not a live
      serialisation — use `getLayers()` + `Layer::serialize()` for the live view.
- [x] 5.5 `setLayerZoomRange`.
- [x] 5.6 `getSource(id)` handle with `setData` (renaming `setGeoJsonData`); **`isSourceLoaded`
      REJECTED** — mbgl cannot answer it, see the run log.
- [x] 5.7 `hasImage`, `listImages`, `updateImage`.
- [x] 5.8 Style from **inline JSON** and from a Flutter asset. Both forms work and are verified on
      macOS hardware; `asset://` is ours, resolved in Dart. Also fixed `getLayersOrder` reporting
      mbgl's own annotation layer — found by this task's integration test, see the run log.
- [x] 5.9a Runtime **images** survive a style load, in both render modes. Split from 5.9b below
      because only images are un-re-addable by the app: `Style::Impl::parse()` wipes them
      (`style_impl.cpp:104`) and an image has no form in a style document.
- [x] 5.9b Opt-in `MapLibreMap.retainRuntimeStyle` replaying app-added **sources and layers**.
      Deliberately NOT automatic — every upstream binding requires the app to re-add from the
      style-loaded event, and an automatic replay collides with an app that does.
- [x] 5.10 `addPoints`/`setPoints`/`removePoints` demoted to a named recipe:
      `addCircleLayersFromPoints` returning a `MapLibrePointLayers` handle that owns the ids it
      invented, plus `setPointsData` / `removeCircleLayersFromPoints`. Old names kept as
      `@Deprecated` aliases for one release.
- [x] 5.11 Model layers namespaced `mbl:model:<id>` inside the C shim, closing all three bugs.
      Still enumerated by `getLayersOrder` — unlike mbgl's annotation layers, a model layer IS the
      app's, so `moveLayer` and queries must be able to name it.

### Stage 6 — Queries and feature state (over stage-1's GeoJSON types)

- [x] 6.1 `queryRenderedFeatures` overloads: `Rect`, `queryRenderedFeaturesAt(Offset)`,
      `queryRenderedFeaturesIn(LatLngBounds)`, all taking a typed `Expression` filter evaluated
      inside the engine, plus `queryRenderedFeaturesAsync` over a new non-blocking C entry point.
- [x] 6.2 Distinguished, but only on the ASYNC path: `queryRenderedFeaturesAsync` throws
      `MapQueryException`; the sync forms still return `const []` for both cases, deliberately —
      they run on camera ticks and must not throw into a paint callback.
- [x] 6.3 `querySourceFeatures(sourceId, {sourceLayers, filter})`, with mbgl's two surprises
      (loaded tiles only, results NOT deduplicated) documented at all three layers.
- [x] 6.4 `setFeatureState` / `getFeatureState` / `removeFeatureState`, with the no-`promoteId`
      constraint documented at all four layers and pinned by a test.
- [x] 6.5 `getClusterExpansionZoom` / `getClusterChildren` / `getClusterLeaves` over mbgl's
      feature-extension mechanism, taking gl-js's integer `cluster_id`.
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

### 2026-08-01 — Stage 3 (3.1–3.6) — stage closed, verified on hardware

- **Done:** all six, plus the stage gate (hardware verification).
  - **3.1/3.2 C ABI** — `mbl_map_jump_to` / `ease_to` / `fly_to` over an `MblCameraOptions` struct
    (every field with a `has_` flag, mirroring `mbgl::CameraOptions`' `std::optional`s), plus
    `mbl_map_fit_bounds`, `camera_for_lat_lng_bounds`, `lat_lng_bounds_for_camera`,
    `set_bounds` / `get_bounds`, `set_constrain_mode` and `cancel_transitions`. `fitBounds` is
    **fused** — computed and applied in one render-thread command — because the computation needs
    the live transform and a compute-then-move split would let the camera change in between.
  - **3.3/3.4 Dart** — `camera.jumpTo/easeTo/flyTo/fitBounds/panBy/panTo/zoomTo/zoomIn/zoomOut/
    rotateTo/resetNorth/resetPitch/stop`, `getBounds`, `cameraForBounds`, and the five gl-js
    constraint setters. A new `MapLibreCameraCommands` capability carries them, implemented by all
    five `mbgl-core` tiers; tiers without it fall back to the old whole-camera `moveCamera`, so the
    web tiers keep working.
  - **3.5** — `getPosition()` → `getCamera()` and `move()` → `jumpTo`/`easeTo`/`flyTo`, both as
    `@Deprecated` aliases. Every call site in the example and the integration tests is migrated.
  - **3.6** — the completion contract is real, not just documented: `easeTo`/`flyTo`/`fitBounds`
    return a `Future` completed by an engine callback (`AnimationOptions::transitionFinishFn`)
    carrying a token. A **superseded** transition completes too, because
    `Transform::startTransition` invokes the previous finish function before installing its own —
    so awaiting a flight a gesture interrupts resolves instead of hanging.
- **Two engine findings, both caught by running rather than by tests:**
  1. **The camera cache did not track engine-driven animations.** `updateCameraCache` ran only when
     a command was ISSUED, so during and after an `easeTo` — which mbgl advances itself —
     `getCamera()` reported the pre-animation camera, permanently. Fixed by refreshing the cache in
     `publishCurrentFrame`, next to the projection snapshot that was already re-taken per frame for
     exactly this reason.
  2. **Animated moves need Continuous mode.** mbgl advances transitions from its render loop, so in
     Static mode `easeTo`/`flyTo` create a transition nothing ever steps and the camera never moves.
     Every shipped tier is continuous; the headless test harness defaults to Static, which is why
     the first version of the completion test "passed" its token assertion while the camera sat
     still. Recorded on `mbl_map_ease_to`.
- **Spec corrections found:** one, on `panBy`'s sign. gl-js negates its argument internally, and
  maplibre-gl-js is not vendored here, so rather than claim a parity that cannot be checked the
  method is documented against **our own drag convention** — positive x moves the content right,
  exactly like dragging right, which `MapLibreGestureHandler.moveBy` already does and which is
  verified on hardware. A test pins it.
- **Gates:** `analyze` clean / `test --no-select` green (258 in `maplibre_flutter`, 170 conformance
  assertions across five tiers) / `test:native` green (40) / `format` clean / ffigen regenerated on
  macOS and diff-clean / **`integration_test/macos_camera_test.dart` — 8 tests, run on macOS
  hardware**, covering the partial camera, the completion contract, supersession, fitBounds
  orientation, constraint clamping, and the anchored zoom (anchored on a CORNER, since a
  centre-anchored test cannot detect a dropped anchor).
- **Example:** a "Camera verbs" button runs jumpTo → easeTo → flyTo → rotateTo → resetNorth →
  zoomIn/zoomOut-about-a-corner in sequence, each awaited so the steps cannot overlap; a
  "Constrain to Nordics" button demonstrates gl-js `setMaxBounds` semantics; "Fit to data" now calls
  the real `fitBounds` instead of the hand-rolled centre-and-guess it used before; and every
  read-modify-write `move(camera.copyWith(...))` in the app is now a partial-camera call.
- **Next run:** stage 4 — camera lifecycle and reason. Pure Dart, no C ABI. Note 4.2's shape is not
  yet settled (three proposals; see that task's note).

### 2026-08-01 — Stage 4 (4.1, 4.2, 4.3) — stage closed

Pure Dart, no C ABI, exactly as the stage predicted — and it banks the structural advantage the
stage header names: mbgl's `MapObserver` carries only `CameraChangeMode {Immediate, Animated}`, so
every SDK synthesises the richer reason in its platform layer, and **ours is in Dart**, the one
place in the stack that can tell a pan from a pinch from a twist from a shove.

- **4.1** — every gesture path in `_DesktopMapGesturesState` now reports its reason: the scale
  recognizer's pan/pinch, the two-finger twist and shove, the secondary-drag rotate and tilt, the
  trackpad pan/pinch/twist fallback, and the mouse wheel. Reasons are **accumulated, not decided up
  front**: a gesture that grows a second reason mid-flight — a pinch that starts twisting —
  re-reports, so a listener filtering on `isRotation` is not stuck with the first classification.
  A wheel notch reports start and end together, since a scroll has no release event.
- **4.2** — `controller.onCameraMoveStart` / `onCameraMoveEnd`, each carrying a
  `Set<MapCameraChangeReason>`. The Set is load-bearing: a twisting pinch really is
  `{gesturePinch, gestureRotate}`, and collapsing that to one value would lose information the
  layer went to the trouble of having. `onCameraChanged` stays exactly as it was — it is the cheap
  per-frame `Listenable` the marker overlay repaints from, and these are the discrete bookends.
  Programmatic moves bracket themselves too, so `easeTo` reports `{programmatic}` and `resetNorth`
  reports `{programmatic, resetNorth}` (Apple gives the compass tap its own value, and it earns it:
  it is the one "programmatic" move a user asked for). `stop()` reports `transitionCancelled`.
- **4.3** — `isMoving` / `isZooming` / `isRotating` plus `movingBecause`, derived from the live
  reason set. Deliberately **not** bound to mbgl's `Map::isPanning/isScaling/isRotating`: those
  would need a render-thread round trip per call, and the Dart layer already knows the answer
  synchronously and for free.
- **Shape decision settled.** The task carried three competing proposals (spec camera item 10's
  single `Stream<MapCameraEvent>` with a phase field; spec gestures item 4's Android-named widget
  callbacks; ledger 4.2's two streams). **Shipped the ledger's**: two streams, reason-only payload.
  A phase field would be redundant when the stream itself is the phase, and the current camera is
  already available synchronously from `onCameraChanged` — putting a snapshot in the event would
  have forced an async read at emit time for data the listener can already reach.
- **Gates:** `analyze` clean / `test --no-select` green / `format` clean / no generated-file or C
  ABI diff — this stage needed neither.
- **Example:** a live badge shows WHY the camera is moving while you drag, pinch, twist or shove —
  including both reasons at once for a twisting pinch — and colours itself by whether the user or
  the app caused it.
- **Next run:** stage 5, style and data operations. Highest row count in the backlog (11 tasks), and
  the first task is the `controller.layers` → `controller.style` rename, which touches every call
  site in the example.

### 2026-08-01 — Stage 5 (5.1) + a P0 regression the USER found by running the app

**5.1 done:** `controller.layers` → `controller.style` (Apple's `MLNStyle` is what the object
actually is — sources, images and the style-wide transition, not a layer list), with the class
renamed `MapLibreStyleController` and `@Deprecated` aliases for both. `queryRenderedFeatures` moved
to the controller ROOT, where both upstreams agree queries belong (gl-js `map.queryRenderedFeatures`,
Apple `-visibleFeaturesInRect:`), keeping a forward on the style namespace. The `attach` parameter
`style:` became `styleUri:` — it now shadowed the new field.

**The regression, and why every test missed it.** The user reported the example stuck on "loading
the style". It was: `attached=true, style=false` while the map rendered perfectly.

`FrameObserver::onDidFinishLoadingStyle` overrode `DiagnosticObserver`'s **without delegating**, and
the base is where `styleLoadCount` is bumped — the bookkeeping that lets a late-registering callback
be told about a style that has already loaded. **Continuous mode uses FrameObserver, and every
shipped tier is continuous.** So the count never moved, the replay never fired, and the live event
had already been missed — a real tier can only register after `mbl_map_create` returns and, on the
texture tiers, after a registrar round trip, by which time the style has usually loaded (~170 ms).

Three test layers were green throughout:
- the native replay test used **Static** mode (`continuous: false` is the default), which routes
  through `DiagnosticObserver` directly and therefore did the bookkeeping;
- the conformance suite drives a fake core, so it never exercised the observer at all;
- `macos_camera_test` awaited `onReady` but subscribed to nothing late, and its own timing let it
  see the live event.

Fixed by delegating, and pinned by two tests chosen to fail without the fix: a **continuous-mode**
replay test in the native suite, and an integration test that subscribes to `onStyleLoaded` only
AFTER `onReady` — the exact shape of what the app does.

**Also from the report — the example's structure was wrong.** Each demo is supposed to be a
`Scenario` case ("one thing under test at a time"; the file's own comment says the app used to be a
pile of interacting toggles and that this was unclear). The stage 2-4 demos had been added as global
BUTTONS instead. They are now scenarios — `cameraVerbs`, `cameraConstraints`, `diagnostics`,
`capabilities` — each with its own teardown, and the control bar is back to actions that make sense
anywhere plus a couple that appear only for their scenario.

**And the app no longer gates its whole UI on `onReady`.** It enables on ATTACH, because
`_applyScenario` re-runs from `onStyleLoaded` anyway; a slow or 404ing style used to make the demo
untestable. The loading label now names what is outstanding (the map / the style / the first frame)
and counts seconds, so a wait can never again be indistinguishable from a hang.

- **Gates:** `analyze` clean / `test --no-select` green / `test:native` green (41) / `format` clean /
  ffigen diff-clean / `macos_camera_test` 9 tests and `example_app_test` 2 tests, both on macOS
  hardware.
- **Lesson worth keeping:** the harness default (Static) differed from every shipped configuration
  (Continuous), and that gap hid a P0 for two commits. When a mode flag exists, at least one test
  must use the one that ships.

### 2026-08-01 — Stage 5 (5.2, 5.3, 5.4, 5.5) — the layer surface stops being write-once

Before this, changing one property meant removing the layer and adding it back, and there was **no
getter of any kind** — which is why the spec has no rows for the read side: you cannot regress what
never existed.

- **5.2** — `mbl_map_set_layer_property(map, layerId, name, valueJson)`. The finding the ledger
  predicted holds up: **one entry point covers paint, layout, `visibility`, `minzoom`, `maxzoom`
  AND `filter`**, because `Layer::setProperty` dispatches to the generated setters and then handles
  the rest itself (`layer.cpp:165-190`). gl-js's four-way split is a naming convenience, and the C
  ABI needed none of it. Verified by a native test that drives all four through the same call and
  counts pixels after each.
  Malformed JSON fails **synchronously** (it is knowable without the render thread); an unknown
  property or layer reports on the diagnostic channel, since those need the layer.
- **5.3** — `moveLayer`. ~20 lines, as predicted: `Style::removeLayer` returns the owning
  `unique_ptr` and `addLayer` takes a `before`, so the layer object survives the move with nothing
  re-parsed. Tested by overlapping two circle layers and asserting which colour wins.
- **5.4** — `getLayer` / `getLayersOrder` / `getPaintProperty` / `getLayoutProperty` / `getFilter`,
  over `Layer::getProperty` and `Layer::serialize()`. **Not `Style::getJSON()`** — that returns the
  document as LOADED and would not show anything the app changed, which the test pins by setting a
  colour and reading it back.
- **5.5** — `setLayerZoomRange`, which falls out of 5.2.
- **Finding worth carrying:** the read side returns mbgl's **normalised** form, not the text that
  went in. `"#0000ff"` comes back as `["rgba",0.0,0.0,255.0,1.0]`, and numbers come back as doubles.
  Round-tripping a read into a write is fine; comparing it to the input string is not. Documented on
  `getPaintProperty` and pinned by a test, because it is exactly the kind of thing that looks like a
  bug the first time someone hits it.
- **The interface break was the intended kind.** Adding five members to `MapLibreStyleLayers` broke
  all six controllers plus three test doubles at compile time, which is the mechanism CLAUDE.md §3
  describes. The web tier gets honest no-ops and nulls rather than plausible lies — an app can tell
  through the null returns; a fabricated value would silently be wrong.
- **Gates:** `analyze` clean / `test --no-select` green / `test:native` green (44) / `format` clean /
  ffigen regenerated on macOS.
- **Next:** 5.6 (`getSource` handle + `setSourceData`), 5.7 (image surface), 5.8 (inline-JSON and
  asset styles — five doc comments already promise this works), then 5.9-5.11.

### 2026-08-01 — Stage 5 (5.6) — the source handle, and one half rejected

- **Done:** `getSource(id)` returns a `MapLibreSource` handle — id, type, attribution, volatile
  flag, and `setData` — which is gl-js's `map.getSource(id).setData(...)` shape over a flat
  `setSourceData` on the contract (CLAUDE.md §3: flat at the interface, handle-shaped app-side, so a
  new source type costs zero contract churn). `setGeoJsonData` renamed with `@Deprecated` aliases at
  both levels.
- **`isSourceLoaded` is REJECTED — the engine cannot answer it.** `RenderSource::isLoaded()` exists
  but only inside `src/mbgl/renderer/`; the public `Renderer` exposes nothing for it, and
  `mbgl::style::Source` has no loaded state at all. Exposing it through `Renderer` would be a small,
  self-contained upstream PR — worth weighing alongside the two patches this project already
  carries. Recorded here rather than shipped as something that always returns true.
- **Two findings:**
  - `mbgl::style::Source` has no `serialize()` the way `Layer` does, so `getSource` reports what the
    public API actually exposes rather than inventing a style-spec document for it.
  - **`Source::getAttribution()` is reachable, and is now surfaced.** That is the string many tile
    providers legally require be displayed, and it had no route to Dart at all before — which is
    half of why 8.6 was filed. Reading it is still not displaying it, but the data is no longer
    unreachable.
- Also: `setSourceData`'s two failure paths (no such source; source is not GeoJSON, which is an
  engine limit rather than a missing binding) moved off `fprintf(stderr)` onto the diagnostic
  channel, which is where 2.3 put the rest of them.
- **Gates:** `analyze` clean / `test --no-select` green / `format` clean / ffigen regenerated.

### 2026-08-01 — Stage 5 (5.7) — the image surface

- **`updateImage` is a NAME, not a code path.** mbgl's own comment on
  `Style::Impl::addImage` reads "We permit using addImage to update", so this forwards to
  `addImage`. It exists because reaching for `addImage` to *change* something reads like a mistake
  at the call site.
- **`hasImage` returns `bool?`, and the null matters.** A timed-out read is deliberately not
  `false`: code deciding whether to register an image needs "could not ask" distinguishable from
  "not there", or it re-rasterises a widget icon on every hiccup. The C ABI carries that as `-1`.
- **`listImages` needed one internal header, and nearly did not work at all.** The public `Style`
  has `getImage()` but no `getImages()`. `Style::Impl::images` is **private** — the first attempt
  failed to compile against it — but `Style::Impl::getImageImpls()` is a public accessor on that
  internal class, so the list is reachable without patching mbgl. Coupling recorded in the shim with
  `style_impl.hpp` as the grep marker for a core bump.
  Verified against a real style, where the count exceeds our own additions — it includes the
  style's own sprite images, which is what makes the call useful for finding an icon name to reuse.
- **Gates:** `analyze` clean / `test --no-select` green / `test:native` green (45) / `format` clean /
  ffigen regenerated.

### 2026-08-01 — Stage 5 (5.8) — a style is a URL, a document, or a bundled asset

- **The header had promised inline JSON since M2 and nothing implemented it.** `mbl_map_create` and
  `mbl_map_set_style` both documented "(URL, file path, or inline JSON)"; both called
  `Style::loadURL` unconditionally, and mbgl resolves a JSON document as a *relative URL* rather
  than failing — so the symptom was an empty map and total silence. Now one `loadStyleSpec()` sniffs
  the first non-whitespace character for `{` and routes to `Style::loadJSON`, at all three load
  sites. Whitespace-led documents are covered by a test, because the obvious `spec[0] == '{'`
  would have shipped a sniff that a leading newline defeats.
- **`asset://` is OURS, and deliberately resolved in Dart.** The engine has no idea what a Flutter
  asset is, and teaching six platform packages to read one would be six implementations of
  `rootBundle`. `MapLibreMapController` reads it and hands the engine the document, so every tier
  gets it for free. A missing key throws an `ArgumentError` naming the key and pointing at
  `pubspec.yaml` — the alternative was handing the engine a string it fails to parse, which
  surfaces as a blank map and an error about JSON, nowhere near the actual mistake.
- **`getLayersOrder` was reporting a layer that is in no style document.**
  `mbgl::AnnotationManager::updateStyle()` runs on every style load and injects
  `org.maplibre.annotations.points` whether or not anything uses it, so the read side shipped in
  5.4 answered a two-layer inline style with three layers. It has no gl-js counterpart and cannot
  be driven through anything this ABI exposes. Now filtered from the ENUMERATION by prefix (shape
  annotations are `…annotations.shape.<n>`, one per shape) — still reachable by id through
  `mbl_map_get_layer_json`, so nothing is unreachable, it is just not listed.
  **Found only because a test asserted the exact layer list rather than `contains`** — every
  earlier test of this call used `contains` and was blind to it.
- **Example app:** new `styleForms` scenario cycling the three forms, with a bundled
  `assets/styles/nordic_night.json`. The global style toggle is hidden while it is on screen, since
  the scenario owns the style.
- **Gates:** `analyze` clean / `test --no-select` green / `test:native` green (48) / `format` clean /
  4 macOS integration tests (`macos_style_forms_test.dart`) green on hardware /
  `example_app_test.dart` green.
- **Harness note:** two integration-test FILES in one `flutter test -d macos` invocation fails the
  second app launch ("Unable to start the app on the device"). Run them one file at a time.

### 2026-08-01 — Stage 5 (5.9a) — runtime images survive a style load

- **The defect:** `Style::Impl::parse()` does `images = makeMutable<ImageImpls>()`
  (`style_impl.cpp:104` — verified against the pinned submodule, not quoted from the spec), so every
  style load wiped every runtime image. An app that rasterised a Flutter widget into an engine icon
  (`addWidgetIcon`, the whole point of the engineIcons scenario) got blank symbols the moment
  `MapLibreMap.style` changed, with no error — `onStyleImageMissing` fires, but nothing was
  listening for a case that used to be impossible.
- **Where the line is drawn, and why it is not "everything the app added".** A source or a layer has
  a form in a style document, so an app can re-add it from the style-loaded event — that is what
  gl-js, Apple (`MLNStyle.h:32-36`) and Android all require. These three cannot be re-added by
  anyone else: transition options (style-global, no document form in our API), runtime images (pure
  registrations), and model layers (`CustomDrawableLayer`s over an uploaded GPU mesh — re-adding one
  from Dart re-reads and re-parses a .glb). So the shim replays exactly those, and
  `replayRetainedStyleState()` says so in a comment rather than growing by accretion.
- **The replay moved into the BASE observer, and `FrameObserver`'s override is gone.** Static mode
  had no re-apply at all — not even the models it has retained since the 3D work — because the
  re-adds lived in the Continuous-only subclass. That is the same shape as the bug that made the
  app hang last run: an override that forgot to delegate. There is now no override to forget.
- **A retained image must also stay REMOVED.** `mbl_map_remove_image` drops the retention first;
  without that the next style load resurrects exactly what the app deleted, which is the standard
  failure of a replay cache that only ever grows. Tested.
- **Both render modes are tested, deliberately.** Last run's mode-shaped bug shipped green because
  the only test used Static and every shipped tier is Continuous. The test also asserts the second
  document is actually live before checking the image, so it cannot pass by the style never having
  changed.
- **5.9b (sources/layers) split out, not silently dropped.** Automatic replay collides with an app
  that follows the documented pattern and re-adds from `onStyleLoaded` — the second add reports
  through `onError`. It belongs behind an opt-in `MapLibreMap.retainRuntimeStyle`, which is what the
  spec recommends (row at `api-parity-binding-spec.md:2087`).
- **Gates:** `analyze` clean / `test --no-select` green / `test:native` green (50) / `format` clean.

### 2026-08-01 — Stage 5 (5.9b) — MapLibreMap.retainRuntimeStyle

- **Off by default, and that is the parity-correct default.** mbgl drops the whole document on
  load; gl-js, Apple (`MLNStyle.h:32-36`) and Android all tell the app to re-add from the
  style-loaded event, which we surfaced in 2.5. Automatic replay would also double-add for any app
  that follows that documented pattern, and the second add arrives as `onError` noise. So it is a
  flag, and its dartdoc says "pick one" in as many words.
- **Layers and sources are retained by DIFFERENT mechanisms, because mbgl only lets one of them
  round-trip.** `Layer::serialize()` returns the live layer, so a layer is snapshotted out of the
  engine immediately before the swap — which is what makes a `setPaintProperty` applied after the
  add survive, where replaying the original `addLayer` call would silently lose it. **`Source` has
  no `serialize()` at all**, so `mbl_map_get_source_json` can only ever return a descriptor (id,
  type, attribution, volatile) — enough for 5.6's handle, useless for re-adding. Sources are
  therefore replayed from the document the app passed, with `setSourceData` folding into it so a
  replay carries the LATEST data. Restoring a live dataset's first data would rewind it silently,
  and the map would still draw.
  **Found by the integration test, not by the unit tests** — the fake returned whatever it was
  handed, so the round-trip looked fine until a real engine answered with a descriptor.
- **The snapshot has exactly one valid moment.** It is taken in `setStyle`, before the push: the
  style-loaded event fires after `Style::Impl::parse()` has already dropped everything.
- **`beforeId` is deliberately not restored.** It named a layer in the OUTGOING document, which the
  incoming one need not contain, and an unresolvable `beforeId` is an error rather than a fallback.
  Replayed layers land on top in insertion order; an app that needs interleaving does it itself
  from `onStyleLoaded`, where it knows what the new document holds.
- **`getSourceIds` leaked `org.maplibre.annotations`**, the same way `getLayersOrder` leaked the
  annotation LAYER in 5.8 — AnnotationManager injects both. Filtered by the same prefix, tested.
- **A `didUpdateWidget` crash caught in review, not by a test:** syncing the flag at the top of
  `didUpdateWidget` dereferences `_controller` before the controller-swap branch creates the
  internal one, so swapping a provided controller for none would have thrown. The sync now happens
  inside each branch, after the controller is known good.
- **Example app:** new `retainRuntimeStyle` scenario with an ON/OFF toggle and a layer recoloured
  after its add, so the live-snapshot behaviour is visible rather than asserted.
- **Gates:** `analyze` clean / `test --no-select` green / `test:native` green (51) / `format` clean /
  2 macOS integration tests (`macos_retain_style_test.dart`) green on hardware.

### 2026-08-01 — Stage 5 (5.10) — the points recipe stops pretending to be spec API

- **The complaint was never the convenience, it was the neighbourhood.** `addPoints` sat next to
  `addLayer` on a namespace that is otherwise a 1:1 mirror of gl-js's `Map` style methods, so it
  read as spec API when it is a macro over one source and up to three layers — and it invented ids
  (`<id>`, `<id>-clusters`, `<id>-count`, `<id>-points`) that were private knowledge only
  `removePoints` had. gl-js has no equivalent at all; the canonical shape there is exactly what
  this expands to.
- **The handle is the actual fix.** `addCircleLayersFromPoints` returns `MapLibrePointLayers`, and
  `remove()` / `setData()` need no ids, while `layerIds` hands over the real ones for `moveLayer` or
  a query filter. `_labelled` tracks whether the count layer was built, so the list is honest when
  no `clusterTextFont` was given — that omission is deliberate (naming a font the style does not
  serve makes mbgl 404 the glyph range on every tile) and the handle should not claim a layer that
  is not there.
- **A section comment now marks the boundary** in `map_style_controller.dart`: everything above is a
  gl-js method, everything below is a recipe. That is cheaper to maintain than remembering.
- The example app migrated to the new names in the same commit — it is the first consumer, and a
  deprecation nobody has walked is a deprecation that does not compile.
- **Gates:** `analyze` clean / 292 `maplibre_flutter` tests green / `format` clean.

### 2026-08-01 — Stage 5 (5.11) — model layers get their own id namespace

- **One overlap, three bugs.** A model layer took the app's id verbatim, so it shared a namespace
  with every layer the app added. That produced: `removeLayer("car")` dropping the style layer while
  leaving `m->models` holding it, so the next style load replayed a model the app had removed (and
  the Dart side went on ticking `triggerRepaint` for it); and `removeModel("car")` calling
  `removeLayer("car")`, which would happily delete an unrelated style layer of that name. Prefixing
  with `mbl:model:` removes the overlap by construction — `:` is not a character mbgl's own layer
  ids use.
- **Namespaced at exactly one place.** `addModelLayer` converts once; `m->models`, the style-load
  replay and the transform lookup all speak the style id from there down, so the replay loop needed
  no change and there is one line where the two namespaces meet.
- **Still enumerated, deliberately.** Unlike mbgl's annotation layers (filtered in 5.8), a model
  layer is the app's own, so `getLayersOrder` reports it and `moveLayer` can reorder it. That makes
  `removeLayer("mbl:model:x")` reachable, so it now drops the retention too — the fix has to hold on
  every route to it, not just the polite one.
- **`mbl_map_add_test_model` grew a `layer_id`** (NULL keeps the old `mbl-test-model`). Without it
  the shim could only ever have one test model, and none of the three regressions above could be
  written without shipping a `.glb` into the core package's tests. ffigen regenerated on macOS.
- **The third test is the control.** "a model that was NOT removed still survives a style load"
  exists because the other two would both pass if the replay were simply broken.
- **Gates:** `analyze` clean / `test --no-select` green / `test:native` green (54) / `format` clean /
  ffigen regenerated, no unexplained diff.

### 2026-08-01 — Stage 6 (6.1-6.3) — the query surface

- **The async form is a real C entry point, not a Future wrapped round a blocking call.**
  `mbl_map_query_rendered_features_async` posts the query and fires `MblQueryCallback` on the render
  thread; Dart binds it with `NativeCallable.listener` and one callable per query, closed inside its
  own handler. The synchronous form waits on a condvar with a deadline, which on the UI isolate
  stalls frame production — tolerable for a one-off hit test, wrong for a query driven by the camera
  at 60-120 Hz, which is the usual reason to run one. It calls back even when the handle is null,
  because a Future that never completes is worse than one that completes empty.
- **6.2 is answered on the async path only, and that is a decision.** The sync queries run on camera
  ticks; throwing there would throw into a paint callback. They keep the best-effort `const []`
  contract and say so in the dartdoc. An async caller can afford to handle failure, and a Future is
  where a failure belongs in Dart, so that is where `MapQueryException` lives.
- **A filter that does not PARSE is reported through `onError`, not ignored.** Matching everything is
  the one outcome a caller cannot detect from the result.
  **That check immediately caught a bug in this run's own test:** `Expr.equals` takes positional
  arguments, and `Expr.equals([a, b])` builds `["==", [["get","kind"],"city"]]`, which mbgl rejects.
  The unit test had asserted the filter JSON `contains('kind')` and `contains('city')` — both true of
  the malformed document — so only the hardware test caught it. Both assertions are now on the exact
  JSON.
- **`querySourceFeatures` returns 12 features for 3 points**, because mbgl answers per LOADED TILE
  and a point in the overlap of several cached tiles comes back once per tile. gl-js behaves the
  same. Documented in the header, the core wrapper and the app-facing dartdoc; the tests compare id
  SETS rather than counts.
- **Two test premises had to be corrected, both by the engine.** Hiding a layer to prove
  `querySourceFeatures` sees more than `queryRenderedFeatures` proves the opposite: with no visible
  layer, mbgl has no reason to hold tiles for the source, so both return nothing. The honest fixture
  is a layer FILTER — the layer stays visible, the tiles stay loaded, and the two queries genuinely
  disagree. Separately, a point query aimed at "roughly the middle" was measuring the fixture rather
  than the query; the camera now puts a known feature exactly at the screen centre.
- **`queryRenderedFeaturesIn` projects all FOUR corners and drops the ones behind the camera.**
  Under a bearing the south-west corner is not the left-most point on screen, so projecting two
  corners yields a box that clips the other two out. It refuses (rather than querying the origin)
  when no frame has been presented.
- **Web tier refuses a filtered query instead of ignoring the filter.** The embind module takes no
  filter and adding one means C++ in `src/web/` that nothing currently compiles. Returning more
  features than asked for is invisible to the caller; returning null is not. `querySourceFeatures`
  is likewise null there. → 7.1.
- **Gates:** `analyze` clean / `test --no-select` green / `test:native` green (59) / `format` clean /
  4 macOS integration tests (`macos_queries_test.dart`) green on hardware / ffigen regenerated.

### 2026-08-01 — Stage 6 (6.4) — feature state, and a test helper that had been lying

- **The tests assert PIXELS, not a round trip.** A `set`/`get` pair that agrees with itself proves
  storage; feature state is only worth anything if a style expression can read it, so the fixture is
  two circles painted through `["case", ["boolean", ["feature-state","selected"], false], red, blue]`
  and the assertions are on how many red and blue pixels come back. Two features, so a change that
  repaints everything cannot pass as feature state working.
- **`countColor` had been reading BGRA as RGBA for the life of the helper.** Frames are BGRA
  (`mbl_map_copy_frame`), and it indexed byte 0 as red. Every test that existed asserted magenta
  (#ff00ff) or green (#00ff00) — **R equals B in both**, so the swap was invisible. The first test to
  use red and blue found it immediately. This is CLAUDE.md §11's "verify a convention with an
  ASYMMETRIC fixture" happening to us again, in the test layer this time. Fixed, and pinned by a
  test that paints a pure red frame and asserts it does NOT read as blue — the assertion the old
  colours could not make. No existing test changed meaning.
- **mbgl implements neither `promoteId` nor `generateId`** — verified by grepping the pinned
  submodule, no hits outside the spec JSON — so feature state only works on features carrying their
  own id. The failure mode is the worst kind: nothing throws, nothing repaints, mbgl stores the state
  against an id nothing reads, and the only symptom is that your styling does not change. Documented
  in the C header, the core wrapper, the platform interface and the app-facing dartdoc, and pinned by
  a test that sets state for a nonexistent id and asserts both that no pixel changed and that mbgl
  kept it anyway.
- **A `set` MERGES**, matching gl-js; replacing would silently drop keys a previous call set. Tested,
  because "it looked right" and "it merged" are the same picture until the second key matters.
- **`triggerRepaint` after every mutation.** Feature state changes nothing mbgl invalidates on its
  own — the tiles are untouched — so without it the repaint never happens in Continuous mode, which
  is every shipped tier.
- **State JSON is parsed on the CALLING thread**, like the other JSON paths here, so a bad object is
  reported before anything is posted rather than failing invisibly on the render thread.
- **Gates:** `analyze` clean / `test --no-select` green / `test:native` green (65) / `format` clean /
  ffigen regenerated.

### 2026-08-01 — Stage 6 (6.5) — cluster helpers, and two upstream traps

- **gl-js's shape, not Apple's.** mbgl wants a whole cluster FEATURE and Apple hands it the cluster
  shape, but the only thing it reads off that feature is the `cluster_id` property
  (`render_geojson_source.cpp:133`) — so the shim builds a synthetic feature carrying just the id,
  and every caller passes the integer gl-js passes. That also spares an app keeping the cluster
  feature alive between the query that produced it and the question.
- **TRAP 1: supercluster THROWS for a cluster id that does not exist**
  (`std::runtime_error("No cluster with the specified id.")`, `supercluster.hpp:375`), and a throw
  crossing `extern "C"` is undefined behaviour — CLAUDE.md §11 already names this for
  `mbgl::LatLng`, and it bit again here. The first test to pass a made-up id **aborted the whole
  test process** (`libc++abi: terminating`, exit 134). Now caught in the shim and reported through
  `onError`. Note the contrast with an unknown SOURCE, which mbgl handles itself by returning an
  empty value (`render_orchestrator.cpp:719-722`) — so one of the two bad inputs was fatal and the
  other was not, which is exactly the sort of asymmetry only a test finds.
- **TRAP 2: `getClusterExpansionZoom` cannot tell you an id is bogus.** It starts from
  `(cluster_id % 32) - 1` — the zoom is encoded in the id's own low bits — and only then walks the
  tree (`supercluster.hpp:236`). So `999999` confidently answers `30`. Documented at all three
  layers with the real number, and `getClusterChildren` is named as the existence check, because
  that one really does fail. Pinned by a test, since a plausible number looks like our bug.
- **The expansion-zoom test proves the zoom EXPANDS**, rather than asserting it is in a range: it
  moves the camera there and checks the single cluster is no longer a single cluster. A zoom that
  does not expand anything is just a number.
- **Cluster ids in tests come from querying the engine**, never hardcoded — supercluster's ids are
  an implementation detail and a test that hardcodes one is testing the fixture.
- **Gates:** `analyze` clean / `test --no-select` green / `test:native` green (70) / `format` clean /
  ffigen regenerated.

