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

### Stage 1 — Value types (pure Dart, zero native work)

No C ABI change, no ffigen regen, no platform-controller ripple, no hardware.

- [ ] 1.1 `LatLngBounds` — shape from mbgl `include/mbgl/util/geo.hpp:82`, fields
      `southwest`/`northeast`. **Not** gl-js's lng-first ordering. With
      `fromPoints`/`extend`/`contains`/`intersects`/`center`/`isEmpty`/`crossesAntimeridian`.
- [ ] 1.2 Adopt Flutter's `EdgeInsets` as the padding type — do not invent one.
- [ ] 1.3 `CameraOptions` (partial camera, every field nullable, incl. `padding` and `anchor`) +
      `CameraAnimation` (duration/curve/speed/minZoom/maxDuration), mirroring
      `include/mbgl/map/camera.hpp:55-115`.
- [ ] 1.4 Typed GeoJSON in a `geojson.dart` sub-library: sealed `GeoJsonGeometry` (all seven RFC 7946
      types), `GeoJsonFeature` (id + geometry + properties), `GeoJsonFeatureCollection`, and
      `QueriedFeature` carrying gl-js `MapGeoJSONFeature`'s extras (`layer`, `source`, `sourceLayer`,
      `state`).
- [ ] 1.5 `MapCameraChangeReason` — Apple `MLNCameraChangeReason.h:30-64` values, as a Dart `Set`.
- [ ] 1.6 `MapLibreCapabilities` + re-export the capability interfaces from
      `packages/maplibre_flutter/lib/maplibre_flutter.dart` (today an app cannot even write
      `if (controller is MapLibreModelHost)`).
- [ ] 1.7 Harden `LatLng`: normalise/assert NaN, inf, |lat| > 90, wrap longitude. `mbgl::LatLng`
      throws on these and a throw across `extern "C"` is UB.
- [ ] 1.8 **P0 defect** — `map_layers_controller.dart:215` drops every non-Point geometry from
      `queryRenderedFeatures`. The C shim already returns the full FeatureCollection.
- [ ] 1.9 **P0 defect** — the same method parses and discards the feature `id`.
- [ ] 1.10 **P0 defect** — the same method catches `FormatException` while its unchecked casts throw
      `TypeError`, breaking its own documented promise never to throw into a camera-tick caller.
- [ ] 1.11 **P0 defect** — `map_layers_controller.dart:365` `setPoints` drops `properties`, making
      data-driven styling impossible through it.

### Stage 2 — Observer + diagnostics channel (one C ABI callback, one Dart fan-out)

Second, not later: `MapLibreMap.style` is a declarative prop and mbgl drops every app-added layer on
style load, so `controller.layers` + a style swap is **broken today with no signal**. Everything
after this stage is undebuggable without it.

- [ ] 2.1 `mbl_map_set_diagnostic_callback` fanning out mbgl `MapObserver`: `onDidFailLoadingMap`,
      `onDidFinishLoadingStyle`, `onDidBecomeIdle`, `onStyleImageMissing`, `onGlyphsError`,
      `onSpriteError`, `onRenderError` (`map_observer.hpp:57-94`).
- [ ] 2.2 Install `mbgl::Log::setObserver` once behind `std::once_flag`, returning `false` so stderr
      logging survives. **This is the only hook that sees the glyph-404 failure** —
      `MapObserver::onGlyphsError` is dead code in our configuration.
- [ ] 2.3 Check the `unique_ptr` return values that `removeSource`/`removeLayer` currently discard
      (`maplibre_flutter_core.cpp:1638`, `:1648`) — a precise synchronous error path needing no
      observer.
- [ ] 2.4 Report the silent command drop in `MblMap::post` when `renderLoop == nullptr`
      (`maplibre_flutter_core.cpp:285-292`).
- [ ] 2.5 `sealed class MapLibreError` + `Stream<MapLibreError> onError`.
- [ ] 2.6 `Stream<void> onStyleLoaded` (repeating) and `Stream<void> onIdle`; `MapLibreMap.onStyleLoaded`
      widget callback.
- [ ] 2.7 Pin `onReady` to mean gl-js `load`, and fix the macOS tier which completes it on the first
      **frame** (`maplibre_flutter_macos_controller.dart:141`), contradicting its own dartdoc.
- [ ] 2.8 Hold a Dart-side **field** reference to the registered callback (the GC pitfall, CLAUDE.md
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
