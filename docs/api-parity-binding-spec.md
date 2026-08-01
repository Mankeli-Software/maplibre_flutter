# MapLibre API Parity — Binding Spec

Companion to `FEATURE_MATRIX.md`. The matrix answers *what is wired where*; this document answers **what the binding should be called and what shape it should have**, by copying the canonical MapLibre APIs instead of inventing our own.

Anchored on three sources, all readable locally:

- **MapLibre Apple SDK 6.27.0** — 164 public headers under `packages/maplibre_flutter_ios/ios/maplibre_flutter_ios/.build/artifacts/maplibre-gl-native-distribution/MapLibre/MapLibre.xcframework/ios-arm64/MapLibre.framework/Headers/`
- **mbgl-core** — `packages/maplibre_flutter_core/third_party/maplibre-native/include/mbgl/` (the hard ceiling for all six tiers)
- **maplibre-gl-js 5.x** — not vendored; rows marked *(unverified)* were written from knowledge rather than from the docs.

`ours` is determined by **reading our code**, never from `FEATURE_MATRIX.md`. Where the two disagree, the row says so — the matrix is known to drift.

**Priorities.** P0 = a real defect, or a blocker for an ordinary app. P1 = table stakes every competing plugin ships. P2 = expected but survivable. P3 = long tail.

## Totals

703 binding rows across 11 domains.

| Priority | Rows | Missing entirely (`ours: none`) | Needs a new C ABI entry point |
| --- | --- | --- | --- |
| P0 | 51 | 30 | 26 |
| P1 | 178 | 122 | 97 |
| P2 | 233 | 159 | 120 |
| P3 | 241 | 175 | 73 |

## Engine traps that constrain these signatures

Recorded in `CLAUDE.md` §11 **after** the camera rows below were drafted, so the camera domain does
not reflect them. They change how three proposed signatures must be implemented, not what they are
called:

- **`CameraOptions::anchor` is silently discarded whenever `center` is set** (`transform.cpp`:
  `anchor = camera.center ? nullopt : camera.anchor`). The proposed `zoomTo(zoom, {around})` /
  `rotateTo(bearing, {around})` therefore **cannot** be implemented as get-camera-then-set-camera —
  `mbl_map_set_camera` always sends a centre, so the anchor would be dropped every time. And a
  centre-anchored test cannot detect the bug, because the centre is a fixed point either way.
- **`Transform::rotateBy` is broken upstream** — it computes `sqrt(pow(2, offset.x) + pow(2, offset.y))`
  (2ˣ+2ʸ, not x²+y²), so its centre-nudge heuristic always fires left/above centre.
- **`Map::pitchBy` subtracts its argument**, so `pitchBy(+10)` tilts down.

Build all three on `jumpTo(CameraOptions().withBearing(…).withAnchor(…))` / `.withPitch(…)`, as
`mbl_map_rotate_by` / `mbl_map_pitch_by` already do. Both defects are upstream-PR candidates.

## Build order

Dependency-ordered. Each stage assumes the ones above it.

### Stage 1 — 0 — Decide and record the naming policy (a half-day, no code)

Every rename below is cheap now and breaking after 1.0. Naming decided per-feature is how a binding ends up with `getPosition` returning a `MapCamera` next to a `setGeoJsonData` next to an `addPoints` — three vocabularies in one class. This stage costs nothing and is the actual answer to "don't solo the API design".

- Write the policy into CLAUDE.md §9: gl-js naming for style/data/camera verbs; Android SDK `UiSettings` naming for gesture toggles; Apple SDK shapes for what gl-js lacks (offline, snapshotter, location, tile-server/auth, camera-change reason); Flutter value types at the boundary (Duration, Color, Rect, Offset, EdgeInsets, Alignment); `LatLng`/`LatLngBounds` ordering, never `LngLat`
- Record the three adaptations explicitly so they are choices, not accidents: gl-js `on('move')` → `Listenable onCameraChanged`; gl-js `on('error')` → `Stream<MapLibreError>`; gl-js `anchor` strings → Flutter `Alignment`
- Re-derive FEATURE_MATRIX.md rows from code — three drifts already found: :425 says `repaintBoundary` default on (marker.dart:26 says false), :636 says models are macOS-only ✅ (they are wired on all five native tiers per commits de30016/0a4650e), :423 frames widget markers as having no MapLibre equivalent (gl-js `Marker` is exactly it)

**Closes at once:** None directly; prevents re-litigating naming in every stage below.


### Stage 2 — 1 — Value types (pure Dart in the platform interface, zero native work)

These are the nouns every later verb needs, and none of them touches the C ABI, ffigen, or five platform controllers — so they can land in one PR, fully unit-tested, with zero hardware verification. Doing them last is how a binding ends up with `queryRenderedFeatures` returning a bespoke struct that has to be deprecated at 1.0.

- `LatLngBounds` (mbgl geo.hpp:82 shape: fromPoints/extend/contains/center/world)
- Adopt Flutter `EdgeInsets` as the padding type — do not invent one
- `CameraOptions` (all-optional partial camera incl. `padding` and `anchor`) + `CameraAnimation` (duration/curve/speed/minZoom/maxDuration), mirroring mbgl camera.hpp:55-115
- `GeoJsonGeometry` sealed hierarchy + `GeoJsonFeature` + `QueriedFeature` (gl-js `MapGeoJSONFeature`), in a `geojson.dart` sub-library
- `CameraChangeReason` enum (Apple MLNCameraChangeReason.h:30-64, as a `Set`)
- `MapLibreCapabilities` + re-export it from `maplibre_flutter.dart`
- `LatLng` hardening: assert/normalise NaN, |lat|>90, longitude wrap (mbgl's own `LatLng` throws, and a throw across `extern "C"` is UB — CLAUDE.md §11)

**Closes at once:** `fitBounds`, `getBounds`, `setMaxBounds`, `getMaxBounds`, `cameraForBounds`, native camera-for-bounds/-geometry, native latLngBoundsFromCamera, source `bounds`, GeoJSON `getBounds`, viewport padding (FEATURE_MATRIX.md:308, 318, 527-531, 177) all become implementable; the `queryRenderedFeatures`/`querySourceFeatures`/`setFeatureState` cluster (:187, :275, :534-535) gets its return and identifier types; the four flyTo tuning rows (:326-330) get their options object.


### Stage 3 — 2 — The observer + diagnostics channel (one C ABI callback, one Dart fan-out)

Second, not later, for two independent reasons. (a) CORRECTNESS: `MapLibreMap.style` is a declarative prop and mbgl drops every custom layer on style load, so `controller.layers` + a style swap is broken TODAY with no signal an app can hook — `onStyleLoaded` is the fix, and it must exist before the layer surface grows. (b) ECONOMICS: every stage after this is currently undebuggable — a 404ing style, a missing glyph range, a bad sprite all produce a blank map in total silence, and each subsequent feature would otherwise pay that debugging tax again.

- `mbl_map_set_diagnostic_callback` fanning out mbgl `MapObserver` events: onDidFailLoadingMap, onDidFinishLoadingStyle, onDidBecomeIdle, onStyleImageMissing, onGlyphsError, onSpriteError, onRenderError (map_observer.hpp:57-94)
- `Stream<MapLibreError> onError` + `sealed class MapLibreError` variants
- `Stream<void> onStyleLoaded` (repeating) and `Stream<void> onIdle`; `MapLibreMap.onStyleLoaded` widget callback
- Pin down `onReady` == gl-js `load`, and fix the macOS tier which currently completes it on first FRAME (maplibre_flutter_macos_controller.dart:141)
- Keep a Dart-side field reference to the registered callback (CLAUDE.md §5e — the GC pitfall) and add the test for it

**Closes at once:** FEATURE_MATRIX.md §7 events block: `load` (public), `idle`, `styledata`, `sourcedata`, `styleimagemissing`, `error` (:485-495) — six rows from one callback. Also retires the "a green integration test does not prove the map is visible" trap (CLAUDE.md §7) by giving tests a real failure signal.


### Stage 4 — 3 — Camera commands, over stage-1 types

Needs stage 1's `CameraOptions`/`LatLngBounds`/`EdgeInsets` and stage 2's error channel. Landing `flyTo` natively also removes the awkward fact that our public `flyTo` behaviour lives in a Dart curve (fly_animation.dart:14) that no upstream shares — and CLAUDE.md §11 explicitly warns against blind-porting camera changes across tiers, so this is the stage that must be run on each platform's hardware.

- Shim: `mbl_map_jump_to` / `mbl_map_ease_to` / `mbl_map_fly_to` taking the full `CameraOptions` (incl. padding + anchor) — mbgl already has all three natively (map.hpp:73-75), so retire the Dart-side arc where the engine can do better
- Shim: `mbl_map_camera_for_lat_lng_bounds` (map.hpp:80), `mbl_map_lat_lng_bounds_for_camera` (:92), `mbl_map_set_bounds`/`get_bounds` (:98-101)
- Dart: `camera.jumpTo/easeTo/flyTo/fitBounds/panBy/zoomTo/zoomIn/zoomOut/rotateTo/resetNorth/stop`, `camera.getBounds()`, `camera.setMaxBounds/setMinZoom/setMaxZoom/setMinPitch/setMaxPitch` (mbgl `BoundOptions`, bound_options.hpp:43-55)
- `@Deprecated` alias for `move()`; rename `getPosition()` → `getCamera()`
- Define the completion contract: camera Futures complete on transition END, superseded animations complete rather than error

**Closes at once:** `easeTo` 🟡→✅ and `flyTo` 🟡→✅ (:294-295), `fitBounds` (:308), padding (:318), flyTo speed/curve/minZoom/maxDuration (:326-330), `getBounds`/`setMaxBounds`/`getMaxBounds`/`cameraForBounds` (:527-531). Roughly a dozen rows on one shim change.


### Stage 5 — 4 — Camera lifecycle + reason (pure Dart, no native work)

Depends on stage 2's event plumbing and stage 3's commands (a `flyTo` must be able to say `programmatic`). Free of C ABI work because — unlike mbgl, whose `CameraChangeMode` is only {Immediate, Animated} (map_observer.hpp:37) — OUR gesture recognisers are in Dart and are the only thing that knows pan vs pinch vs twist vs shove. That is a structural advantage of the Dart gesture layer worth banking early.

- Thread `CameraChangeReason` through the Dart gesture layer (maplibre_map.dart:553-990) and through `moveCamera`
- `onCameraMoveStart` / `onCameraMoveEnd` streams with the reason payload; keep `onCameraChanged` as the continuous `Listenable`
- Optional but nearly free once reasons exist: `isMoving`/`isZooming`/`isRotating` (gl-js), backed by mbgl `Map::isPanning/isScaling/isRotating` (map.hpp:66-68)

**Closes at once:** `movestart`/`move`/`moveend` 🟡→✅ (:509), `zoomstart`/`zoom`/`zoomend` (:511), `pitchstart`/`pitch`/`pitchend` (:513), native camera-move listeners (:517), `isMoving`/`isZooming`/`isRotating` (:515).


### Stage 6 — 5 — Style/data operations, mirroring gl-js `Map` one-for-one

Highest ROW COUNT in the matrix but correctly LAST among the core stages: it needs stage 2 (a `setPaintProperty` on a missing layer must report something), stage 1's value types (`setFilter` takes an `Expression`, `setPaintProperty` takes a `StyleValue`, both of which already exist in the generated typed API), and it is the stage most likely to want renaming — which stage 0 has by then settled. Note the typed style API means `setPaintProperty` needs no new encoder: style_encoding.dart:9 already serialises everything.

- Rename the namespace `controller.layers` → `controller.style` (matches `MLNStyle`, which is what the object actually is), move queries off it
- `moveLayer(id, beforeId)`, `getLayer(id)`, `getLayersOrder()`, `setPaintProperty`, `getPaintProperty`, `setLayoutProperty`, `getLayoutProperty`, `setFilter`, `getFilter`, `setLayerZoomRange`
- `getSource(id)` handle with `setData` (renaming `setGeoJsonData`), `isSourceLoaded`
- `hasImage`, `listImages`, `updateImage`
- Demote `addPoints`/`setPoints`/`removePoints` to a clearly-named recipe (`addCircleLayerFromPoints`, or an `annotations.circles` manager à la Android's `CircleManager`)

**Closes at once:** The whole §2-§5 layer/paint/layout backlog stops being "expressible only by re-adding the layer": every per-property setter row, plus draw-order (`moveLayer`), plus the read side (`getLayer`, `getLayersOrder`, `getFilter`) that has no row today because we never had a getter at all.


### Stage 7 — 6 — Queries and feature state, over stage-1's GeoJSON types

Every item is blocked on the typed Feature from stage 1 and on the source handle from stage 5. `setFeatureState` in particular is unimplementable without a feature identifier type. Landing it here also finally makes the Point-only parser (map_layers_controller.dart:215) a non-issue rather than a silent data loss.

- `queryRenderedFeatures` overloads: point, `Rect`, `LatLngBounds`, plus a `filter` argument (mbgl `RenderedQueryOptions{layerIDs, filter}`, renderer/query.hpp:14-24) — we currently expose rect-only, no filter
- `querySourceFeatures(sourceId, {sourceLayers, filter})` (mbgl `SourceQueryOptions`, query.hpp:30-38)
- `setFeatureState` / `getFeatureState` / `removeFeatureState` (mbgl renderer.hpp:74-86 — note the Apple SDK has NO equivalent, so here our ceiling beats the reference SDK)
- Cluster helpers: `getClusterExpansionZoom` / `getClusterChildren` / `getClusterLeaves` (Apple MLNShapeSource.h:408-437)
- Return `QueriedFeature`; retire `MapLibreQueriedFeature`

**Closes at once:** `setFeatureState` API (:187, :275), `querySourceFeatures` (:534), `queryRenderedFeatures` "rect only, no filter" caveat (:533), plus the cluster-interaction rows that currently have no home.


### Stage 8 — 7 — Web parity pass (no new API surface)

Deliberately AFTER the contract stabilises. Web is the largest single gap in the matrix (FEATURE_MATRIX.md:110-113: no projector, no layers, no models), and implementing it against a contract that is about to be renamed means doing it twice. Everything before this stage is contract work that web will have to satisfy anyway.

- Implement `MapLibreMapProjector`, `MapLibreStyleLayers` and the stage-2 observer on `maplibre_flutter_web` (WASM core)
- Verify every stage 1-6 addition on the four unverified native tiers (Linux, Windows, Android, iOS) — CLAUDE.md §11 forbids blind-porting camera/anchor changes between tiers

**Closes at once:** Converts a large block of ❌ and 🧪 in the Web column and the four unverified native columns to ✅ without adding a single API name — the matrix's 🧪-vs-✅ distinction exists precisely for this stage.


### Stage 9 — 8 — SDK-shaped extras, where gl-js has no vocabulary (use Apple/Android shapes)

Last, and only because the ordering question was asked — each of these is a self-contained subsystem with its own C ABI surface, none blocks anything above it, and all four have a mature Apple shape to copy verbatim so there is no design risk. Offline and snapshotter both consume stage-1 `LatLngBounds`/`MapCamera`, which is the only real dependency.

- Offline: `MLNOfflineStorage` (MLNOfflineStorage.h:198, `.packs` :287, `-addPackForRegion:` :310, `-removePack:` :339), `MLNOfflinePack`, `MLNTilePyramidOfflineRegion` / `MLNShapeOfflineRegion`
- Snapshotter: `MLNMapSnapshotter` / `MLNMapSnapshotOptions` (styleURL, camera, coordinateBounds, size, scale, showsLogo, showsAttribution — MLNMapSnapshotter.h:70-141) — note it already needs stage-1 `LatLngBounds` and `MapCamera`
- Location component: `MLNUserLocation`, `MLNLocationManager`, `MLNUserTrackingMode` (MLNMapView.h:590, :637)
- Tile server / auth / network: `MLNTileServerOptions`, `MLNNetworkConfiguration`, `MLNSettings`; logging: `MLNLoggingConfiguration`

**Closes at once:** FEATURE_MATRIX.md §6 (offline), §9 (snapshotter) and the user-location rows (:470-472, :679) — all currently ❌/native_only across the board.


## Foundations to land first

Missing structural pieces that every later binding depends on.

### `LatLngBounds` and viewport padding (`EdgeInsets`) value types. We have neither: the platform interface ships only `LatLng` (lat_lng.dart:5) and `MapCamera` (camera.dart:10-28, four non-optional fields), and the C ABI has no bounds call at all (packages/maplibre_flutter_core/src/maplibre_flutter_core.h exposes only set/get_camera at :60/:65).

**Unblocks:** Everything that names a rectangle of the world, which is a large share of the backlog: `fitBounds`, `getBounds`, `setMaxBounds`/`getMaxBounds`, `cameraForBounds`, `latLngBoundsForCamera`, source `bounds`, offline region definition, snapshotter `coordinateBounds`, bounds-shaped `queryRenderedFeatures`, and GeoJSON `getBounds`. FEATURE_MATRIX.md:308, 318, 527-531 lists six of these as ❌ and they are one type away. Padding additionally unblocks the single most-requested real-world camera behaviour — centring the map in the visible area when a bottom sheet or side panel covers part of it — which is literally inexpressible today because `MapCamera` has no padding field and `mbl_map_set_camera` has no padding parameter.

```dart
`class LatLngBounds { const LatLngBounds({required LatLng southwest, required LatLng northeast}); factory LatLngBounds.fromPoints(Iterable<LatLng>); LatLngBounds extend(LatLng); bool contains(LatLng); LatLng get center; static LatLngBounds get world; }` — mbgl's `LatLngBounds` shape verbatim (include/mbgl/util/geo.hpp:82-165: `world()`, `singleton()`, `hull()`, `southwest()`, `northeast()`, `extend()`, `contains()`), and Apple's `MLNCoordinateBounds{sw, ne}` (MLNGeometry.h:72-77). NAME: `LatLngBounds`, not gl-js's `LngLatBounds` — our point type is `LatLng` and importing the flipped axis-order name would re-open this repo's #1 bug class. For padding: REUSE Flutter's `EdgeInsets` rather than inventing a type — it is the same name mbgl uses (`mbgl::EdgeInsets`, geo.hpp:183, with top/left/bottom/right) and the same name Apple uses (`UIEdgeInsets` in `-setVisibleCoordinateBounds:edgePadding:animated:`, MLNMapView.h:1202, and the `contentInset` property, :1610).
```

### A partial/optional camera type — `CameraOptions` — distinct from the full `MapCamera` snapshot. Today every command takes a fully-populated `MapCamera` (maplibre_map_controller.dart:308, contract :28), so "zoom to 12, leave everything else" requires an async `getPosition()` + `copyWith`, which races the render thread against any in-flight gesture.

**Unblocks:** All of stage-3 camera work, and it is a prerequisite for padding and anchored zoom. mbgl's `CameraOptions` is entirely `std::optional` and carries fields we cannot express AT ALL: `padding`, `anchor`, `roll`, `fov`, `centerAltitude` (include/mbgl/map/camera.hpp:55-84). `anchor` is what makes `zoomTo` about a point correct, and it is the same field the gesture layer already needs. Also unblocks `AnimationOptions` (duration, velocity, minZoom apex, easing curve — camera.hpp:96-115), which is what `flyTo(speed:, curve:, maxDuration:)` serialises into; FEATURE_MATRIX.md:326-330 marks all four flyTo tuning rows ❌/web_only purely for lack of this type.

```dart
`@immutable class CameraOptions { const CameraOptions({LatLng? center, double? zoom, double? bearing, double? pitch, EdgeInsets? padding, Offset? anchor}); }` plus `class CameraAnimation { const CameraAnimation({Duration? duration, Curve? curve, double? speed, double? minZoom, Duration? maxDuration}); }`. Names are mbgl's and gl-js's (which agree). Keep `MapCamera` as the READ type returned by `getCamera()` (it mirrors `MLNMapCamera`, MLNMapCamera.h:24-49) — upstream also separates the two, and conflating them is why `move()` cannot express a partial change.
```

### Typed GeoJSON: `GeoJsonFeature` / `GeoJsonGeometry` / `GeoJsonFeatureCollection`. Today GeoJSON is a `String` on the way in (style_layers.dart:36, `addSourceJson`/`setGeoJsonData`) and a lossy hand-parsed `MapLibreQueriedFeature` on the way out (map_layers_controller.dart:208-238, which drops all non-Point geometry, the feature id, and layer/source provenance). `GeoJsonData` only knows two constructors, `.points()` and `.lineThrough()` (geojson_data.dart:28, :59).

**Unblocks:** The largest single collapse available. It is simultaneously the return type of `queryRenderedFeatures` and `querySourceFeatures`; the input type of geojson sources (so users can build polygons and multi-geometries, not just points and one line); the identifier half of `setFeatureState`/`getFeatureState`/`removeFeatureState` (mbgl HAS this — include/mbgl/renderer/renderer.hpp:74-86 — while the Apple SDK does NOT, so this is a place where our engine ceiling beats the reference SDK; FEATURE_MATRIX.md:187 and :275 both mark it ❌); the cluster helper family (`leavesOfCluster:`/`childrenOfCluster:`/`zoomLevelForExpandingCluster:`, MLNShapeSource.h:408-437, i.e. gl-js `getClusterLeaves`/`getClusterChildren`/`getClusterExpansionZoom`); and hit-testing markers against real drawn features.

```dart
A `package:maplibre_flutter/geojson.dart` sub-library: `sealed class GeoJsonGeometry` with `GeoJsonPoint`/`GeoJsonLineString`/`GeoJsonPolygon`/`GeoJsonMulti*`/`GeoJsonGeometryCollection`; `class GeoJsonFeature { Object? id; GeoJsonGeometry? geometry; Map<String,Object?> properties; }`; and for query results `class QueriedFeature extends GeoJsonFeature { String layer; String source; String? sourceLayer; Map<String,Object?> state; }` — i.e. gl-js `MapGeoJSONFeature` (verified). Use the `GeoJson…` prefix because bare `Point`/`Polygon`/`Feature` collide with `dart:ui`, `dart:math` and Flutter; gl-js sets the precedent with `MapGeoJSONFeature`. Every constructor does the `[lng, lat]` ⇄ `LatLng(lat, lng)` flip ONCE, the way `GeoJsonData.points` already does (geojson_data.dart:47).
```

### A diagnostics / error channel. Today: only the two synchronous JSON parses report anything (`mbl_map_add_source_json` / `mbl_map_add_layer_json` return 0 + an `err` buffer, maplibre_flutter_core.h:181-189, surfacing as `ArgumentError`); everything else is fire-and-forget `void` (`removeLayer`, `removeSource`, `addImage`, `setStyle` — core.h:198-211, style_layers.dart:38-56); and NONE of mbgl's asynchronous failures reach Dart at all.

**Unblocks:** Debuggability of every future binding — this is the one that makes all subsequent work cheaper rather than adding a feature. mbgl already reports `onDidFailLoadingMap(MapLoadError, string)` (include/mbgl/map/map_observer.hpp:59), `onStyleImageMissing` (:67), `onGlyphsError` (:82), `onSpriteError` (:90) and `onRenderError` (:94); Apple surfaces every one of them (`-mapView:didFailLoadingMap:withError:` MLNMapViewDelegate.h:219, `-mapView:didFailToLoadImage:` :339, `-mapViewRendererDidError:` :515); gl-js has the `error` event. Today a style URL that 404s, or the glyph-range 404 storm that `addPoints` explicitly warns about (map_layers_controller.dart:248-254, 313-316), produces a blank map and total silence. FEATURE_MATRIX.md:495 marks the `error` event ❌ on all six.

```dart
`Stream<MapLibreError> get onError` on the controller (ADAPTED from gl-js `on('error')` — a `Stream` is the Flutter idiom for discrete, low-frequency, possibly-bursty events, as against the `Listenable` used for the continuous camera tick), with `sealed class MapLibreError` variants `StyleLoadError`, `StyleImageMissing(String name)`, `GlyphsError`, `SpriteError`, `RenderError`, `TileError` — one per mbgl observer callback so the mapping is mechanical. Plus a `MapLibreMap.onError` widget callback for the common case, and one C ABI entry point, `mbl_map_set_diagnostic_callback`, that fans out all of them (avoid one callback per event type — that is contract churn multiplied by five tiers).
```

### A real map-observer surface beyond the one-shot `onReady`: at minimum `onStyleLoaded` (repeating), `onIdle`, and discrete `onMoveStart`/`onMoveEnd`.

**Unblocks:** `onStyleLoaded` is not a nice-to-have — it is REQUIRED FOR CORRECTNESS of two features we already ship together. CLAUDE.md §11 and mbgl's own behaviour: loading a style drops every custom layer and resets transition options. `MapLibreMap.style` is a declarative widget prop (maplibre_map.dart:44) that can change at any rebuild, and `controller.layers` adds layers the engine will silently discard on the next style swap; there is no signal an app can hook to re-add them. (The C shim papers over one case — transition options are re-applied automatically, core.h:222-226 — and the model host re-adds retained models, maplibre_map.dart:197-198 — but app-added layers are on their own.) `onIdle` unblocks "the map has settled, now query it" and screenshot/test synchronisation; `onMoveEnd` unblocks debounced reprojection and the analytics/telemetry pattern every map app writes.

```dart
On the controller: `Stream<void> get onStyleLoaded`, `Stream<void> get onIdle`, `Stream<CameraChange> get onCameraMoveStart/onCameraMoveEnd`. Names follow mbgl `onDidFinishLoadingStyle` / `onDidBecomeIdle` (map_observer.hpp:64, :66) and Apple `-mapView:didFinishLoadingStyle:` / `-mapViewDidBecomeIdle:` (MLNMapViewDelegate.h:321, :299), shortened to gl-js's `styledata`-era vocabulary in Flutter form. Also add a `MapLibreMap.onStyleLoaded` widget callback, since re-applying layers after a style swap is a widget-lifecycle concern.
```

### Camera-change REASON. `onCameraChanged` (maplibre_map_controller.dart:75) fires with no payload at all, so a listener cannot tell a user pan from a programmatic `flyTo`.

**Unblocks:** The "don't fight the user" logic every real map app needs: cancel follow-user-location on a user pan but not on a programmatic recentre; suppress a tile refetch during a fling; distinguish gesture-driven from animation-driven redraws. It is also the payload that makes `onMoveStart`/`onMoveEnd` worth having. IMPORTANT ENGINE NOTE: mbgl CANNOT supply this — `MapObserver::CameraChangeMode` is only `{Immediate, Animated}` (include/mbgl/map/map_observer.hpp:37-40). Apple's rich enum (MLNCameraChangeReason.h:30-64: Programmatic, ResetNorth, GesturePan, GesturePinch, GestureRotate, GestureZoomIn, GestureZoomOut, GestureOneFingerZoom, GestureTilt, TransitionCancelled) is produced by the SDK's own gesture recognisers. For us that is GOOD NEWS: our gesture layer is in Dart (maplibre_map.dart:553-990) and is the only code that knows pan vs pinch vs twist vs shove — so we can produce Apple-grade granularity WITHOUT any C ABI work, provided the type is defined before more camera code lands.

```dart
`enum CameraChangeReason { programmatic, gesturePan, gesturePinch, gestureRotate, gestureTilt, gestureDoubleTapZoom, gestureQuickZoom, resetNorth, inertia, transitionCancelled }` — Apple's bit list, lower-camelCased, minus the bitmask (Dart has `Set<CameraChangeReason>` and a pinch-plus-rotate really is two reasons, which is exactly the case MLNCameraChangeReason.h:13-15 calls out). Carry it on the camera-change signal and thread it through `moveCamera`.
```

### A defined command-completion contract. `MapLibreStyleLayers` methods all return `void` (style_layers.dart:27-67), forwarded as `void` (map_layers_controller.dart:106-139), while camera commands return `Future<void>` whose meaning differs per tier — macOS awaits the whole animation arc (maplibre_flutter_macos_controller.dart:173-192) but the contract only promises the command was issued (platform_interface .../maplibre_map_controller.dart:27-28).

**Unblocks:** Testability and sequencing of every subsequent binding: `await camera.flyTo(...)` then query; `await layers.addSource(...)` then `addLayer`; integration tests that do not sleep. Upstream both provides this and is explicit about it: Apple's completion handlers (`-flyToCamera:completionHandler:`, MLNMapView.h:1408; `-setVisibleCoordinateBounds:edgePadding:animated:completionHandler:`, :1202), gl-js's `moveend`. Note the engine constraint that forces the design: style mutations are POSTED to the render thread and errors detectable only there are merely logged (maplibre_flutter_core.h:176-180), so a truthful `Future` needs either an ack from the render thread or an explicit "fire-and-forget, errors arrive on onError" contract.

```dart
Write the rule into the platform interface once: camera commands return `Future<void>` completing when the transition FINISHES (and completing early, not erroring, when superseded — `_animToken` already models this, maplibre_flutter_macos_controller.dart:174); style mutations stay synchronous `void` with failures delivered on `onError`. Add `camera.stop()` (gl-js `stop()`, mbgl `Map::cancelTransitions()`, map.hpp:62) so a superseded animation has a name.
```

### Runtime capability discovery for APPS. The capability interfaces are not exported from the app-facing package at all — `packages/maplibre_flutter/lib/maplibre_flutter.dart:7-8` re-exports only `LatLng`, `MapCamera`, `MapLibreModel`, `MapOptions` — so an app cannot write `if (controller is MapLibreModelHost)`. The only probe that exists is `layers.isSupported` (map_layers_controller.dart:63); models, projection and rotate silently no-op instead (maplibre_map_controller.dart:215-263).

**Unblocks:** Graceful degradation, which is not optional given the actual matrix: web-WASM today has no projector, no `MapLibreStyleLayers` and no model host (FEATURE_MATRIX.md:110-113), and the opt-in SDK tiers deliberately abstain from the Dart gesture/annotation layer. Without a probe, a cross-platform app cannot decide between widget markers and engine layers, cannot hide a "3D model" affordance on web, and cannot write a meaningful test matrix. It also unblocks HONEST DOCS: today the answer to "does this work on web?" is only in a markdown file.

```dart
One small value object rather than exporting five interfaces (keeps the interfaces internal to implementers, per CLAUDE.md §3): `class MapLibreCapabilities { final bool projection, styleLayers, models, rotateAndTilt, dartGestures; }` exposed as `controller.capabilities`, derived by the existing `is` checks in one place. No upstream analogue — gl-js and the SDKs each have exactly one renderer — so this is a federated-plugin-specific primitive and should be named for what it is.
```

## Where we invented an API upstream already named

| Ours | Upstream | Recommendation |
| --- | --- | --- |
| `MapLibreQueriedFeature` — `{LatLng point, Map<String,Object?> properties}` plus `isCluster`/`pointCount` getters (packages/maplibre_flutter/lib/src/map_layers_controller.dart:15-35). The parser hard-drops everything that is not a Point (map_layers_controller.dart:215 `if (geometry['type'] != 'Point') continue`) and never reads `id`, `layer`, `source`, `sourceLayer` or `state`. | gl-js `Map.queryRenderedFeatures(): MapGeoJSONFeature[]` — a GeoJSON `Feature` (id, geometry, properties) plus `layer`, `source`, `sourceLayer`, `state` (gljs_verified: true, fetched from maplibre.org/maplibre-gl-js/docs/API/classes/Map/). Apple returns `NSArray<id<MLNFeature>>` (MLNMapView.h:2074 `visibleFeaturesAtPoint:`, :2176 `visibleFeaturesInRect:`), where `MLNFeature` is `identifier` + `attributes` (MLNFeature.h:40,72,132) with `MLNPointFeatureCluster` (MLNFeature.h:185) and `MLNCluster.clusterIdentifier`/`clusterPointCount` (MLNCluster.h:43-49) for clusters. mbgl's own type is `mbgl::Feature` (include/mbgl/util/feature.hpp). | RENAME before 1.0, and it is the highest-value rename in the codebase. Kill `MapLibreQueriedFeature` and return `List<GeoJsonFeature>` where `GeoJsonFeature` carries `id`, `geometry` (a real sealed `GeoJsonGeometry`), `properties`, plus the query extras `layer`, `source`, `sourceLayer`, `state` — i.e. gl-js `MapGeoJSONFeature` verbatim. Keep `isCluster`/`pointCount` as extension getters (they mirror `MLNCluster`). Reason: today a polygon or line query silently returns nothing, `setFeatureState` is unimplementable (it needs source+sourceLayer+id, mbgl renderer.hpp:74-86), and `querySourceFeatures` has no return type to use. Prefix the GeoJSON types `GeoJson…` rather than bare `Feature`/`Point`/`Polygon`, which collide with `dart:ui`/`dart:math`/Flutter — gl-js itself does this with `MapGeoJSONFeature`. |
| `MapLibreCameraController.move(MapCamera target, {Duration? duration})` — the single camera command (packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:308; contract at packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:28). A source comment even lists the missing names as a TODO (maplibre_map_controller.dart:311-313). | Three distinct verbs everywhere. mbgl: `Map::jumpTo(CameraOptions)`, `easeTo(CameraOptions, AnimationOptions)`, `flyTo(CameraOptions, AnimationOptions)` (include/mbgl/map/map.hpp:73-75). gl-js: `jumpTo` / `easeTo` / `flyTo` / `panTo` / `panBy` / `zoomTo` / `zoomIn` / `zoomOut` / `rotateTo` / `resetNorth` / `fitBounds` (gljs_verified: true). Apple: `-setCamera:animated:` (MLNMapView.h:1332) vs `-flyToCamera:completionHandler:` (MLNMapView.h:1408) vs `-flyToCamera:withDuration:peakAltitude:` (MLNMapView.h:1446). | RENAME AND SPLIT before 1.0 — this one is actively misleading, not just unidiomatic. `move(duration: > 0)` does NOT ease: the desktop controllers step our van-Wijk-ish arc (packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:173-192 calling `flyCameraAt`, packages/maplibre_flutter_platform_interface/lib/src/fly_animation.dart:14), so `move(duration:)` IS `flyTo` while `move()` is `jumpTo`, and `easeTo` (a straight-line eased transition) is simply not reachable. Ship `camera.jumpTo(...)`, `camera.easeTo(..., duration:, curve:)`, `camera.flyTo(..., duration:, speed:, curve:, maxDuration:)` matching gl-js, plus `panBy`, `zoomTo`, `rotateTo`, `resetNorth`, `fitBounds`. Keep `move` only as a `@Deprecated` alias for one release. FEATURE_MATRIX.md:293-295 already flags this honestly as `jumpTo` ✅ / `easeTo` 🟡 / `flyTo` 🟡. |
| `MapLibreCameraController.getPosition()` returning `MapCamera` (packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:297). | Apple: `MLNMapView.camera` (an `MLNMapCamera`, MLNMapCamera.h:24-49) and `MLNMapProjection.camera` (MLNMapProjection.h:26). Android SDK: `MapLibreMap.getCameraPosition()` returning `CameraPosition` (gljs_verified: n/a; android verified from maplibre.org Kotlin API docs). gl-js has no aggregate — it is `getCenter/getZoom/getBearing/getPitch/getPadding`. Our own platform contract already calls it `getCamera()` (packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:25). | RENAME to `camera.getCamera()` (or a `camera.position` getter typed `CameraPosition`) — pick one vocabulary. Right now the method is named after Android's `CameraPosition` while returning a type named after Apple's `MLNMapCamera`, and the layer directly beneath it uses the third name. Cheapest fix: `getPosition()` → `getCamera()`, matching the platform interface and `MLNMapCamera`. |
| `MapLibreLayersController.addPoints(id, points, {cluster, radius, color, clusterColor, clusterRadiusPx, clusterRadius, clusterMaxZoom, clusterTextFont, beforeId})` / `setPoints(id, points)` / `removePoints(id)` (packages/maplibre_flutter/lib/src/map_layers_controller.dart:258, 365, 369). It invents an undocumented id scheme — `<id>`, `<id>-clusters`, `<id>-count`, `<id>-points` (map_layers_controller.dart:256-257, 370) — that only `removePoints` knows how to undo. | NOTHING in gl-js and nothing in the style spec: the canonical shape is the documented recipe `addSource(id, {type:'geojson', cluster:true, clusterRadius, clusterMaxZoom})` followed by three `addLayer` calls (gljs_verified: true). Android SDK has the closest named analogue — `org.maplibre.android.annotations.CircleManager` / `SymbolManager` / `LineManager` / `FillManager` with `create(CircleOptions)` / `update` / `delete` (android_verified: true, maplibre.org Kotlin API index + maplibre-plugins-android). Apple has `MLNShapeSource` + `MLNCircleStyleLayer` and nothing higher-level. | KEEP the convenience, but move it OUT of the spec-named namespace and rename so it reads as a recipe. `layers.*` should be a 1:1 mirror of gl-js `Map` style methods; `addPoints` sitting next to `addLayer` implies it is spec API when it is a three-layer macro with a private id convention. Two acceptable landings: (a) `MapLibreLayersController.addCircleLayerFromPoints(...)` returning a small handle that owns its generated ids, or (b) follow the Android plugin and give it its own manager namespace, `controller.annotations.circles.add(...)`, so the composite-id scheme is that object's business. Either way `setPoints` should be spelled `setData`/`setSourceData` (see next row). |
| `setGeoJsonData(String sourceId, String geoJson)` (packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:36, forwarded at packages/maplibre_flutter/lib/src/map_layers_controller.dart:114, C ABI `mbl_map_set_geojson_data`, packages/maplibre_flutter_core/src/maplibre_flutter_core.h:193). | gl-js: `(map.getSource(id) as GeoJSONSource).setData(data)` — the verb is `setData` and it hangs off a source handle, not off the map (gljs_verified: true). Apple: assign `MLNShapeSource.shape` or `.URL` (MLNShapeSource.h:354, :362). | RENAME to `setSourceData(id, data)` now, and plan a `layers.getSource(id)` handle later so it can become `getSource(id).setData(...)` exactly as gl-js. `setGeoJsonData` bakes the format into the verb, which will read wrong the moment an image source or a computed source needs an equivalent (Apple's `MLNComputedShapeSource`, MLNComputedShapeSource.h). |
| `MapLibreModel` (id, assetPath, point, scale, headingDegrees, spinDegreesPerSecond, elevationMetres) + `MapLibreModelHost` (addModel/updateModel/removeModel/modelPartCount/renderedFrameCount) (packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:13-134). | MapLibre has NO model layer — the vendored spec's layer types are exactly fill, line, symbol, circle, heatmap, fill-extrusion, raster, hillshade, color-relief, background (third_party/maplibre-native/scripts/style-spec-reference/v8.json, `layer.type.values`), and the root has no `models` key. The portable engine hook we actually draw through is mbgl `CustomDrawableLayer`, surfaced on Apple as `MLNCustomDrawableStyleLayer` (MLNCustomDrawableStyleLayer.h:9). The only shipped vocabulary for this concept anywhere is **Mapbox** GL JS v3's `model` layer + root `models`, with `model-rotation` / `model-scale` / `model-translation` / `model-opacity` (not MapLibre, and not verifiable from local sources — gljs_verified: false). | KEEP the capability (upstream genuinely has no name for it — FEATURE_MATRIX.md:636 says so correctly), but BORROW Mapbox's `model-*` vocabulary for the fields so a future MapLibre `model` layer type drops straight into the generated typed style API: `scale` → `modelScale`, `headingDegrees` → `modelRotation` (a 3-vector or at least document it as the z component), `elevationMetres` → the z of `modelTranslation`. Two further shape fixes: (1) `assetPath` must be a real filesystem path (model_host.dart:29-31), which is unlike every other MapLibre resource — accept a URI (`file://`, `asset://`, `http(s)://`) and resolve it, matching how mbgl addresses sprites/glyphs/tiles; (2) `spinDegreesPerSecond` (model_host.dart:61) has no analogue anywhere and welds an animation clock into a value type — drop it from the model and let apps drive `updateModel`, or keep it behind `@experimental` and out of any spec-shaped serialisation. Also reconsider the *entry point*: since we already draw via `CustomDrawableLayer`, exposing this as a `ModelLayer` under `controller.layers` would be more upstream-shaped than a bespoke `models:` widget prop. |
| `MapLibreMarker(point, child, alignment, draggable, onDragStart/onDragUpdate/onDragEnd, key, repaintBoundary)` (packages/maplibre_flutter/lib/src/marker.dart:16-74), driven by `MapLibreMap.markers` (packages/maplibre_flutter/lib/src/maplibre_map.dart:51). | gl-js `Marker` / `MarkerOptions`: `element`, `anchor`, `offset`, `draggable`, `rotation`, `rotationAlignment`, `pitchAlignment`, `className`, `color`, `scale`, `clickTolerance`, `opacity`, `subpixelPositioning`; methods `addTo/remove/setLngLat/getLngLat/setPopup/setDraggable/setOffset/setRotation`; events `dragstart` / `drag` / `dragend` / `click` (gljs_verified: true). Apple: `MLNPointAnnotation.coordinate` (MLNPointAnnotation.h:50) + `MLNAnnotationView`, with `MLNAnnotation.title`/`subtitle` (MLNAnnotation.h:46,53) and callouts. | KEEP the class and the widget-prop shape (see good divergences) but ALIGN the field names and close the gaps: our `alignment` is gl-js's `anchor` (keep `Alignment` — it is strictly better than nine magic strings — but say so in the dartdoc); our `onDragStart/onDragUpdate/onDragEnd` are gl-js's `dragstart`/`drag`/`dragend` ✔; MISSING and cheap: `offset` (gl-js `MarkerOptions.offset`, a pixel nudge distinct from `anchor`), `rotation` + `rotationAlignment` + `pitchAlignment` (map-locked vs viewport-locked markers — a real feature, not a nicety, once pitch/rotate gestures exist as of 2026-07-31), `opacity`/`opacityWhenCovered`, and a per-marker `onTap` (gl-js `click`). Do NOT rename `point` to `lngLat`: our coordinate type is `LatLng(lat, lng)` and importing gl-js's axis-order name would re-open the #1 bug class this repo has (CLAUDE.md §11). Also: FEATURE_MATRIX.md:423 claims widget markers are "Our own tier, no MapLibre equivalent" and rows 430-440 mark every gl-js `Marker` capability as ➖ web_only — that framing is wrong and hides real backlog; gl-js `Marker` is the same concept and its option list is our to-do list. |
| `controller.layers` (`MapLibreLayersController`) holding sources, layers, images, style transitions AND `queryRenderedFeatures` (packages/maplibre_flutter/lib/src/map_layers_controller.dart:55-238). | Apple puts source/layer/image/transition on the STYLE object: `MLNStyle.sources` (MLNStyle.h:92), `-addSource:` (:130), `.layers` (:157), `-addLayer:` (:183), `-insertLayer:belowLayer:` (:218), `-setImage:forName:` (:270), `.transition` (:98), `.performsPlacementTransitions` (:105) — and puts queries on the MAP: `-visibleFeaturesInRect:` (MLNMapView.h:2176). gl-js flattens both onto `Map` (gljs_verified: true). | RENAME the namespace to `controller.style` and move the query off it. `layers` is a misnomer for an object that owns sources, images and the style-wide transition, and it will keep accreting non-layer members (`getSource`, `hasImage`, `listImages`, `setGlobalStateProperty`). `controller.style` does NOT violate CLAUDE.md's "no public `controller.setStyle`" rule — that rule is about the style *document* being a widget prop, and a namespace is not a setter. Then put `queryRenderedFeatures` / `querySourceFeatures` / `project` / `unproject` on the controller root or a `controller.query` namespace, matching both upstreams which agree that queries belong to the map, not the style. Do this before 1.0; after 1.0 it is a breaking rename in every app. |
| `onReady` — one `Future<void>` documented as "the native map exists and has finished loading its initial style" (packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:17-22; app-facing packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:87-91). On macOS it is actually completed by polling for the FIRST RENDERED FRAME (packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:141). | Four separate signals, everywhere. mbgl `MapObserver`: `onDidFinishLoadingMap()` (include/mbgl/map/map_observer.hpp:58), `onDidFinishLoadingStyle()` (:64), `onDidBecomeIdle()` (:66), `onDidFinishRenderingFrame(RenderFrameStatus)` (:61). Apple: `-mapViewDidFinishLoadingMap:` (MLNMapViewDelegate.h:206), `-mapView:didFinishLoadingStyle:` (:321), `-mapViewDidBecomeIdle:` (:299), `-mapViewDidFinishRenderingFrame:fullyRendered:` (:252). gl-js: `load`, `styledata`, `idle`, `render` (gljs_verified: true). | KEEP `onReady` (a one-shot Future is the right Flutter idiom — `webview_flutter` and `video_player` both do this, and it is the ergonomic 90% case), but STOP letting it stand in for the other three, and pin down which upstream event it IS: it should mean `load`, and the macOS first-frame implementation is `render`, which is a real cross-tier semantic drift to fix. Then add, as separate members: `onStyleLoaded` (fires on EVERY style load, not once — without it `MapLibreMap.style` and `controller.layers` are broken together, because mbgl drops every custom layer on style load per CLAUDE.md §11), `onIdle`, and `onError`. FEATURE_MATRIX.md:484-489 already lists `load`/`idle`/`styledata` as ❌ across the board. |
| `MapOptions` with exactly one field, `initialCamera` (packages/maplibre_flutter_platform_interface/lib/src/map_options.dart:13-20). | All three upstreams use the name `MapOptions`, and all three scope it differently. mbgl `MapOptions`: mapMode, constrainMode, viewportMode, crossSourceCollisions, northOrientation, size, pixelRatio (include/mbgl/map/map_options.hpp:32-134) — note that camera LIMITS are deliberately elsewhere, in `BoundOptions` (bounds, maxZoom, minZoom, maxPitch, minPitch — include/mbgl/map/bound_options.hpp:43-55), applied with the mutable `Map::setBounds()` (map.hpp:98-101). Apple `MLNMapOptions` is deliberately tiny: styleURL, styleJSON (MLNMapOptions.h:19,28). gl-js `MapOptions` is the maximalist one (~60 fields incl. minZoom/maxZoom/maxBounds/interactive/scrollZoom/dragRotate/fadeDuration/crossSourceCollisions/pixelRatio/transformRequest). | KEEP the name (unanimous upstream) and grow it along mbgl's split, which is also the three-bucket rule: init-only ENGINE config (`crossSourceCollisions`, `pixelRatio`, `northOrientation`, `constrainMode`) goes in `MapOptions`; the camera LIMITS (`minZoom`/`maxZoom`/`minPitch`/`maxPitch`/`maxBounds`) must NOT go in `MapOptions` even though gl-js puts them there — mbgl models them as mutable `setBounds(BoundOptions)`, so they belong on the controller as gl-js's own `setMinZoom`/`setMaxZoom`/`setMaxBounds`/`getMaxBounds`. Decide this explicitly now; it is the kind of contract churn CLAUDE.md §3 warns is most expensive. |
| `MapLibreMap.rotateGesturesEnabled` / `.tiltGesturesEnabled` (packages/maplibre_flutter/lib/src/maplibre_map.dart:82, 88). | gl-js names these `dragRotate`, `touchPitch`, `touchZoomRotate`, `scrollZoom`, `doubleClickZoom`, `keyboard`, `boxZoom`, `dragPan` (MapOptions flags, gljs_verified: true). Android SDK `UiSettings` names them `setRotateGesturesEnabled` / `setTiltGesturesEnabled` / `setScrollGesturesEnabled` / `setZoomGesturesEnabled` (android_verified: true, `MapLibreMap.uiSettings`). | KEEP — but state the choice and then finish it consistently. These are Android `UiSettings` names, not gl-js names, and that is the right call for a Flutter plugin (gl-js's names are DOM-input-flavoured: `scrollZoom`, `boxZoom` and `dragRotate` mean nothing on a phone). So commit to the Android vocabulary and add the rest of the set with the SAME prefix scheme — `scrollGesturesEnabled` (pan), `zoomGesturesEnabled`, `doubleTapZoomEnabled`, `quickZoomEnabled` — rather than mixing in a gl-js name later. Given the whole gesture layer is ours in Dart (packages/maplibre_flutter/lib/src/maplibre_map.dart:553-990), these are pure widget-side booleans with zero native cost. |

## Divergences that should stay

- **Widget-owned declarative state (`MapLibreMap.style`, `.markers`, `.models` — maplibre_map.dart:44, 51, 67) with NO public `controller.setStyle` (it is `@internal`, maplibre_map_controller.dart:268-269), against gl-js's imperative `map.setStyle()` / `marker.addTo(map)` / `marker.remove()` and Apple's `mapView.styleURL` / `-addAnnotation:`.** — This is the whole reason a Flutter binding exists rather than a thin FFI wrapper. `setState(() => _markers = next)` + `didUpdateWidget` diffing (maplibre_map.dart:138-169 for models) gives hot reload, correct rebuild semantics and no manual add/remove bookkeeping — the imperative shape leaks lifecycle bugs into every app. It also matches the two Flutter plugins users already know (`webview_flutter`, `video_player`). Do not import gl-js's imperative marker lifecycle just because it is upstream.
- **Optional capabilities as separate `abstract interface class`es feature-detected with `is` — `MapLibreGestureHandler` (gesture_handler.dart:11), `MapLibreRotateHandler` (rotate_handler.dart:23), `MapLibreMapProjector` (projector.dart:24), `MapLibreStyleLayers` (style_layers.dart:24), `MapLibreModelHost` (model_host.dart:105), `MapLibreResizeMaskHint` (maplibre_map_controller.dart:77) — instead of one fat `MLNMapView`-sized contract.** — Upstream has no equivalent because upstream has one implementation per platform; we have eight tiers with genuinely different ceilings (web-WASM has no projector, no layers, no models today — FEATURE_MATRIX.md:110-113). rotate_handler.dart:8-22 documents the exact cost of getting this wrong: Dart's `implements` forces every member to be redeclared, so one added method is a hard compile break in five packages plus the test fakes. This is the mechanism that lets the binding grow at all. Keep it — and expose it to apps (see missing foundations).
- **`MapLibreMapProjector.project(List<LatLng> points, List<Offset> out, {List<bool>? visible})` — a batched, allocation-free, generation-returning projection (projector.dart:34), backed by `mbl_map_pixels_for_lat_lngs` + `mbl_map_presented_generation` (maplibre_flutter_core.h:147, :260).** — gl-js `project(lngLat)` and Apple `-convertCoordinate:toPointToView:` (MLNMapView.h:1712) are strictly one point per call, because in those runtimes the projection is on the same thread as the renderer. Ours is not: camera commands are applied ahead of the presented frame, so a naive per-point projection makes every marker swim (documented in maplibre_flutter_core.h:120-135 and CLAUDE.md §11). Batching plus projecting against the PRESENTED generation is a correctness fix, not a micro-optimisation, and one FFI call per frame for N markers is what makes the overlay viable at all. Keep — but do also expose the scalar `project`/`unproject` under the upstream names for ergonomics.
- **`controller.onCameraChanged` exposed as a `Listenable` (maplibre_map_controller.dart:75-82) fed by the `MapLibreCameraTickNotifier` mixin (projector.dart:50-66), instead of gl-js's `map.on('move', fn)` / `movestart` / `moveend`.** — ADAPTED DELIBERATELY, and say so in the docs: `Listenable` is the Flutter idiom, so it drops straight into `AnimatedBuilder` / `ListenableBuilder` / `Flow(repaint:)` — which is exactly how the marker overlay consumes it (marker_overlay.dart:137-143, 188). A `Stream<MapMoveEvent>` would force every consumer into a `StreamBuilder` rebuild per camera tick, which is the wrong cost at 60-120 Hz. Keep the `Listenable` for the continuous signal — but it is NOT a substitute for discrete `movestart`/`moveend`, which are still missing (FEATURE_MATRIX.md:509 correctly marks that row 🟡).
- **Flutter value types at every boundary instead of the upstream primitives: `Duration` rather than millisecond numbers (style_layers.dart:64, map_layers_controller.dart:172), `Color` rather than CSS strings (encoded once in style_encoding.dart:42-50), `Rect` for the query box (map_layers_controller.dart:197), `Alignment` for the marker anchor (marker.dart:37), `Offset` for screen space, `Size`+`devicePixelRatio` for resize (maplibre_map_controller.dart:39).** — Every one of these is a type Flutter developers already own and that `dart analyze` can check; the string/number forms upstream uses are artefacts of JS and ObjC. `Rect` in particular matches Apple exactly (`-visibleFeaturesInRect:`, MLNMapView.h:2176), and the colour encoding is centralised in one function so the `#rrggbb` vs `rgba()` spec subtlety is solved once.
- **The typed style API generated from the vendored spec — 10 layer types, 6 source types, 33 enums, 84 expression builders (packages/maplibre_flutter/lib/src/style/generated/*.g.dart, from tool/generate_style_api.dart), with `Expression extends StyleValue<Never>` so covariance lets one parameter accept a constant or an expression (style_value.dart:83).** — This is the one place we are MORE upstream-faithful than the native SDKs: Apple hand-writes `MLNCircleStyleLayer`/`NSExpression` wrappers that drift from the spec, we regenerate from the same v8.json mbgl generates its C++ from. Coverage is discovered, never allowlisted, so a core bump surfaces as a CI regen-diff. The `StyleValue<Never>` covariance trick has no upstream analogue and is what keeps typed properties from degrading to `Object?`.
- **`addWidgetIcon(id, Widget, size:, pixelRatio:, sdf:)` and the public `rasterizeWidget` (map_layers_controller.dart:387, 428) — paint a Flutter widget off-screen and register the bytes as a style image.** — No upstream analogue exists or could: gl-js `addImage` takes ImageData/HTMLImageElement, Apple `-setImage:forName:` takes an `MLNImage` (MLNStyle.h:270). This is the bridge between the two annotation tiers — author once as a widget, let the engine draw it 100k times — and it is a genuine differentiator. The underlying `addImage(id, rgba, w, h, pixelRatio:, sdf:)` already matches gl-js/`MLNStyle` naming, so the ergonomic wrapper sits on top of an upstream-shaped primitive, which is the right layering.
- **`MapLibreResizeMaskHint` (maplibre_map_controller.dart:45-77) and the presented-generation plumbing.** — Pure Flutter-texture-pipeline concerns with no upstream counterpart, and correctly modelled as an opt-in marker interface rather than a base-contract member so it never ripples. This is the pattern to reuse for future tier-specific quirks.
- **`MapLibreMarker.repaintBoundary` defaulting to FALSE with a dartdoc explaining that the intuitive win does not materialise under `Flow` (marker.dart:60-74).** — Keep — it is an honest, measured escape hatch. NOTE A DOC DRIFT to fix while you are here: FEATURE_MATRIX.md:425 claims "`repaintBoundary` (default on)", which contradicts marker.dart:26 (`this.repaintBoundary = false`) and its own dartdoc. Determine matrix rows from code.

## Domains

### Map creation, options, resources & lifecycle

#### Engine ceiling

Hard stops for the five native tiers **and** web-WASM (all of them run this same `mbgl::Map`):

- **No runtime pixel-ratio change.** `MapOptions::withPixelRatio` (map_options.hpp:127) is consumed at construction and `mbgl::Map` exposes no setter (map.hpp has `setSize` at :109, nothing for ratio). The frontend is the same: `HeadlessFrontend(Size, float pixelRatio_, …)` (platform/default/include/mbgl/gfx/headless_frontend.hpp:30) stores `float pixelRatio;` privately (:67) with only `setSize(Size)` (:45) public. So **a DPR change (window dragged to a second monitor, accessibility scale change) cannot be honoured without destroying and recreating the map** — or an upstream patch adding `HeadlessFrontend::setPixelRatio` + `Map::setPixelRatio`. Our web shim *pretends* to support it (`WebMap::resize(w,h,pixelRatio)` reassigns `pixelRatio_`, src/web/maplibre_flutter_core_web.cpp:270) but only uses it to size the canvas backing store — mbgl never sees the new ratio. This is the single most important ceiling in this domain.
- **`renderWorldCopies` does not exist.** gl-js's option has no mbgl analogue; mbgl always draws world copies horizontally and controls wrapping via `ConstrainMode` (mode.hpp:24), which is a different thing. Reject the gl-js name rather than fake it.
- **`maxTileCacheSize` / `maxTileCacheZoomLevels` do not exist** as numbers. mbgl offers only `Renderer::setTileCacheEnabled(bool)` (renderer.hpp:111) plus `reduceMemoryUse()` (:113) / `clearData()` (:114). Apple exposes the same Boolean (`tileCacheEnabled`, MLNMapView.h:489). A numeric cap is not bindable.
- **`refreshExpiredTiles` and `validateStyle` are not options.** mbgl always honours cache expiry, and `convertJSON<T>` always validates (that is exactly why our `addLayerJson` can throw synchronously). Reject.
- **No roll axis.** `CameraOptions` has center/zoom/bearing/pitch only; gl-js 5.x `roll` / `setRoll` / `rollEnabled` / `elevation` / `centerClampedToGround` are engine features MapLibre Native does not have. Reject for all six of our platforms (the matrix already marks these `web_only`, and that is correct).
- **Pitch is hard-clamped to 60°** (`util::DEFAULT_PITCH_MAX`, already documented in our own header at maplibre_flutter_core.h:103). `maxPitch` above 60 is silently ignored; `minPitch` cannot go below 0.
- **No inline-JSON style path is currently reachable through our shim** — this one is *our* limit, not mbgl's: `Style::loadJSON(const std::string&)` exists (style/style.hpp:29) and we simply never call it (`mbl_map_set_style` → `loadURL` at maplibre_flutter_core.cpp:1033; both render-thread mains do the same at :650 and :929).
- **The snapshotter is not in `include/mbgl`.** `mbgl::MapSnapshotter` lives at platform/default/include/mbgl/map/map_snapshotter.hpp:37 and our CMake compiles `map_snapshotter.cpp` **only on the Apple arm** (src/CMakeLists.txt:160 — the Android/Linux/Windows arms at :243/:376/:496 omit it). So a snapshotter binding is a build-system change on four of five native tiers, not just a C ABI change. `offline_database.cpp` *is* compiled on all four (:171, :302, :418, :546), so offline/ambient-cache work has no such blocker.
- **Log severity cannot be filtered numerically.** `Log::setObserver(std::unique_ptr<Observer>)` (util/logging.hpp:28) hands you every record and you return true to consume it; there is no `setLevel`. Apple's `MLNLoggingConfiguration.loggingLevel` (MLNLoggingConfiguration.h:89) is implemented as exactly that — an observer that drops below-threshold records. So we must do the same, in Dart.
- **`Map::getStyle().getJSON()` (style.hpp:32) is a serialisation of the *loaded* style**, not the document you handed in; gl-js's `map.getStyle()` has the same caveat. Fine, but do not document it as a round-trip.
- **Not a ceiling, worth stating:** everything else in this domain *is* reachable — `BoundOptions` (bound_options.hpp:13), `ResourceOptions` (resource_options.hpp:13), `ClientOptions` (client_options.hpp:11), `TileServerOptions` (tile_server_options.hpp:15), `ResourceTransform` (resource_transform.hpp:10), `NetworkStatus` (network_status.hpp:13), `ActionJournalOptions` (util/action_journal_options.hpp:12), the whole `MapObserver` event set (map_observer.hpp:28-94) and `DatabaseFileSource`'s ambient-cache surface (database_file_source.hpp:76-125). The gap is entirely our C ABI, which exposes 4 of these 0 and observes 1 of ~25 MapObserver callbacks.

#### Naming decisions

**Where upstream disagrees, and what I picked.**

1. **Where do resource/auth options live — per-map or process-global?** gl-js puts `transformRequest` on per-map `MapOptions`; Apple puts the api key on a class property (`MLNSettings.apiKey`, MLNSettings.h:53) and the session config on a singleton (`MLNNetworkConfiguration.sharedManager`, MLNNetworkConfiguration.h:51); Android puts it on a process singleton (`MapLibre.getInstance(context, apiKey, WellKnownTileServer)`). **I chose the Apple/Android global shape**, and the deciding evidence is mbgl, not taste: `FileSourceManager::getFileSource(type, ResourceOptions, ClientOptions)` (file_source_manager.hpp:33) *caches file sources by the (type, options) tuple*, and `ResourceTransform` is installed on the **FileSource** (`FileSource::setResourceTransform`, file_source.hpp:89), not on the Map. Per-map api keys/cache paths would silently mint a second OnlineFileSource + a second ambient-cache DB per map; per-map transforms would fight over one shared source. Our own shim already relies on this — `capDesktopRequestConcurrency()` (maplibre_flutter_core.cpp:616-631) reaches the render thread's file source *by re-requesting it with the same `ResourceOptions::Default()`*. So: `MapLibreSettings.configure(...)` (a static, apply-before-first-map surface) for apiKey / tileServerOptions / cachePath / maximumCacheSize / assetPath / transformRequest / logging / maxConcurrentRequests. gl-js naming is kept for the *members* (`transformRequest`, `apiKey`), Apple/Android shape for the *container*.

2. **Zoom/pitch/bounds limits: `setMinZoom` (gl-js) vs `minZoomPreference` (Android) vs `minimumZoomLevel` (Apple).** Chose **gl-js** (`minZoom`/`maxZoom`/`minPitch`/`maxPitch`/`maxBounds`), per the stated policy — they are style-spec-adjacent and shortest. mbgl's own carrier is `BoundOptions` (bound_options.hpp:13) with exactly those five fields, so gl-js is also closest to the engine. Init-only copies land on `MapOptions`; the mutable setters go on `controller.camera` (the namespace already exists) rather than a new `controller.limits`, matching `map.setMinZoom` living on the map object in gl-js.

3. **Tile prefetching: the SDKs genuinely disagree.** Apple exposes only a Boolean (`prefetchesTiles`, MLNMapView.h:478); Android exposes both `setPrefetchesTiles(Boolean)` and `setPrefetchZoomDelta(Int)`; mbgl's real knob is `setPrefetchZoomDelta(uint8_t)` (map.hpp:143) where 0 means off. gl-js has no equivalent at all. **Chose Android/mbgl** — one `int? prefetchZoomDelta` (null = engine default 4, 0 = off) expresses Apple's Boolean without losing the delta. Cheaper than shipping two properties that contradict each other.

4. **Events: gl-js `map.on('load'|'idle'|'error'|'styledata')` is un-Dartlike — I adapted it.** Low-frequency, one-per-map signals become **widget callbacks** (`MapLibreMap(onStyleLoaded:, onMapLoadFailed:, onIdle:)`), matching `webview_flutter`'s `NavigationDelegate` shape and the three-bucket rule; the general firehose becomes `controller.events` → `Stream<MapLibreMapEvent>` with a sealed event type, so `styledata`/`sourcedata`/`render` do not each need a widget parameter. The *names inside* stay gl-js (`MapStyleLoaded`, `MapIdle`, `MapError`); the delivery mechanism is Flutter's. Apple's delegate names (`mapViewDidBecomeIdle:`) are the same events under ObjC naming, so nothing is lost.

5. **Render mode.** mbgl calls it `MapMode::{Continuous,Static,Tile}` (mode.hpp:16); nobody else names it, because gl-js is always continuous and the SDKs never expose Static outside the snapshotter. Kept **mbgl's** name (`MapRenderMode.continuous/.static`) since it is the only vocabulary that exists, and it is already the word used in our own C ABI (`maplibre_flutter_core.h:52`).

6. **Content inset / padding.** gl-js calls it `padding` (a `PaddingOptions` on camera options); Apple calls it `contentInset` (MLNMapView.h:1610) and separately `cameraEdgeInsets` (:1623). Chose gl-js **`padding`** as a `MapCamera` field / camera-namespace concern, but note Apple's split is the better model for the *persistent* case (a bottom sheet covering the map permanently) — proposed `MapOptions.contentInset` for the persistent inset and `padding` on camera ops for the transient one, which is exactly Apple's design under gl-js's word for the transient half.

7. **Flutter-idiom adaptations made:** `map.remove()` → `controller.dispose()` (already so — Dart's disposal convention wins over gl-js's `remove`); `map.resize()` → driven by the widget's layout, never called by app code (`resize` is `@internal`, maplibre_map_controller.dart:274); `container` → the widget itself; `hash`/`trackResize`/`interactive` are browser-DOM concerns adapted or rejected outright. Sizes are **logical points** everywhere in our API (Flutter's unit), never CSS pixels or device pixels.

8. **Android SDK column caveat:** the Android SDK is not vendored here. `MapLibreMapOptions` builder names, `MapLibreMap.setMinZoomPreference/setPrefetchZoomDelta/setLatLngBoundsForCameraTarget`, `MapLibre.getInstance/setConnected/apiKey`, and the `MapView.addOnDid*Listener` family were verified against the published 11.x dokka pages; anything else in that column is from memory and is called out per-row.

#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | API key / access token | none | — (gl-js has no key concept; keys go in the style URL or transformRequest) | MLNSettings.apiKey (class property, MLNSettings.h:53); doc recommends the Info.plist key `MLNApiKey` | mbgl::ResourceOptions::withApiKey(std::string) (storage/resource_options.hpp:34); the parameter name comes from TileServerOptions::withApiKeyParameterName (util/tile_server_options.hpp:237) | widget-init | yes |
| P0 | Initial camera (center / zoom / bearing / pitch) | present | MapOptions.center, .zoom, .bearing, .pitch | MLNMapView.camera (MLNMapView.h:1317), .centerCoordinate (:934), .zoomLevel (:1026), .direction (:1081) | mbgl::Map::jumpTo(const CameraOptions&) (map/map.hpp:73) | widget-init | no |
| P0 | Initial style document (URL) | present | MapOptions.style | MLNMapOptions.styleURL (MLNMapOptions.h:19); MLNMapView.styleURL (MLNMapView.h:278) | mbgl::style::Style::loadURL (style/style.hpp:30) | widget-prop | no |
| P0 | Map creation entry point | present | new maplibregl.Map(options) | -[MLNMapView initWithFrame:options:] (MLNMapView.h:232); also initWithFrame:styleURL: (:210), initWithFrame:styleJSON: (:222) | mbgl::Map::Map(RendererFrontend&, MapObserver&, const MapOptions&, const ResourceOptions&, const ClientOptions&, const ActionJournalOptions&) (map/map.hpp:41) | widget-init | no |
| P0 | Map load FAILURE event | none | map.on('error', e => …) | -mapViewDidFailLoadingMap:withError: (MLNMapViewDelegate.h:219) | MapObserver::onDidFailLoadingMap(MapLoadError, const std::string&) (map/map_observer.hpp:59); MapLoadError enum at :21 {StyleParseError, StyleLoadError, NotFoundError, UnknownError} | widget-callback | yes |
| P0 | Resize contract | present | map.resize() | — (UIView layout) | mbgl::Map::setSize(Size) (map/map.hpp:109); mbgl::MapOptions::withSize (map/map_options.hpp:112) | controller | no |
| P0 | Style as inline JSON | none | MapOptions.style accepts a StyleSpecification object; map.setStyle(styleObject) | MLNMapOptions.styleJSON (MLNMapOptions.h:28); MLNMapView.styleJSON (MLNMapView.h:292) — throws NSInvalidArgumentException on invalid JSON | mbgl::style::Style::loadJSON(const std::string&) (style/style.hpp:29) | widget-prop | yes |
| P0 | dispose / teardown | present | map.remove() | — (ARC / view teardown) | ~Map (map/map.hpp:47); our mbl_map_destroy (maplibre_flutter_core.h:468, impl at maplibre_flutter_core.cpp:2038-2059) | controller | no |
| P0 | pixelRatio at runtime / DPR honoured on resize | partial | map.setPixelRatio(pixelRatio); map.getPixelRatio() | — (the view follows its window's screen automatically) | NOT IN CORE — no setter on Map (map/map.hpp) and pixelRatio is a private member of HeadlessFrontend (platform/default/include/mbgl/gfx/headless_frontend.hpp:67), settable only through the constructor at :30 | controller | yes |
| P0 | transformRequest (URL rewrite + custom headers + credentials) | none | MapOptions.transformRequest: (url, resourceType) => RequestParameters {url, headers, method, body, type, credentials, collectResourceTiming, cache}; also map.setTransformRequest(fn) | -[MLNNetworkConfigurationDelegate willSendRequest:] (MLNNetworkConfiguration.h:29) and sessionForNetworkConfiguration: (:27); also MLNNetworkConfiguration.sessionConfiguration (:69) for default headers | mbgl::ResourceTransform (storage/resource_transform.hpp:10) with TransformCallback = void(Resource::Kind, const std::string& url, FinishedCallback) (:13); installed via FileSource::setResourceTransform (storage/file_source.hpp:89); Resource::Kind values at storage/resource.hpp:14 {Unknown, Style, Source, Tile, Glyphs, SpriteImage, SpriteJSON, Image} | widget-init | yes |
| P1 | Ambient cache path (offline DB location) | none | — (browser cache) | MLNOfflineStorage.databasePath (readonly, MLNOfflineStorage.h:226) / databaseURL (:234); the location is set by the -[MLNOfflineStorageDelegate offlineStorage:URLForResourceOfType:] hook (:544) | mbgl::ResourceOptions::withCachePath(std::string) (storage/resource_options.hpp:64); runtime move via DatabaseFileSource::setDatabasePath (storage/database_file_source.hpp:32) | widget-init | yes |
| P1 | App lifecycle (pause / resume / background) | none | — (page visibility handled internally) | — (handled internally by MLNMapView) | FileSource::pause() / resume() (storage/file_source.hpp:73-74); Renderer::reduceMemoryUse (renderer/renderer.hpp:113) | widget-init | yes |
| P1 | Attribution display (legal requirement) | none | MapOptions.attributionControl (default {compact: true, customAttribution: 'MapLibre…'}) | MLNMapView.showsAttributionButton (MLNMapView.h:416), attributionButton (:431), attributionButtonPosition (:437), attributionButtonMargins (:442), -showAttribution: (:451); MLNAttributionInfo.h parses it from the style | mbgl::style::Source::getAttribution() (style/source.hpp:77) — the engine gives you the strings; drawing the UI is the SDK's job | widget-prop | yes |
| P1 | Idle event | none | map.on('idle') | -mapViewDidBecomeIdle: (MLNMapViewDelegate.h:299) | MapObserver::onDidBecomeIdle() (map/map_observer.hpp:66) | widget-callback | yes |
| P1 | Initial camera from bounds (`bounds` + `fitBoundsOptions`) | none | MapOptions.bounds, MapOptions.fitBoundsOptions | -[MLNMapView setVisibleCoordinateBounds:edgePadding:animated:] (MLNMapView.h:1180); -[MLNMapView cameraThatFitsCoordinateBounds:edgePadding:] (:1502) | mbgl::Map::cameraForLatLngBounds(const LatLngBounds&, const EdgeInsets&, bearing, pitch) (map/map.hpp:80) | widget-init | yes |
| P1 | LatLngBounds value type | none | LngLatBounds (sw/ne; LngLatBoundsLike accepts arrays) *(unverified)* | MLNCoordinateBounds struct (MLNGeometry.h) with MLNCoordinateBoundsMake(sw, ne) | mbgl::LatLngBounds (util/geo.hpp) | value-type | no |
| P1 | Memory pressure: reduceMemoryUse / clearData | none | — (nearest is clearPrewarmedResources()) | — (handled internally via UIApplicationDidReceiveMemoryWarning) | mbgl::Renderer::reduceMemoryUse() (renderer/renderer.hpp:113), clearData() (:114); reachable from our shim via HeadlessFrontend::getRenderer() (platform/default/include/mbgl/gfx/headless_frontend.hpp:47) | controller | yes |
| P1 | Persistent content inset / camera padding | none | CameraOptions.padding (PaddingOptions) *(unverified)* | MLNMapView.contentInset (MLNMapView.h:1610), cameraEdgeInsets readonly (:1623), -setContentInset:animated:completionHandler: (:1678), automaticallyAdjustsContentInset (:315) | mbgl::EdgeInsets on CameraOptions; Map::getCameraOptions(const std::optional<EdgeInsets>&) (map/map.hpp:72); also Map::setFrustumOffset(const EdgeInsets&) (:110) | widget-init | yes |
| P1 | Style from a Flutter asset | none | — | MLNMapView.styleURL accepts "a path to a local file relative to the application’s resource path" (MLNMapView.h:200-202) | mbgl::ResourceOptions::withAssetPath (storage/resource_options.hpp:80) — "the root directory from where the asset:// scheme gets resolved in a style" | widget-prop | yes |
| P1 | Style-loaded event | internal-only | map.on('styledata'); map.isStyleLoaded() | -mapView:didFinishLoadingStyle: (MLNMapViewDelegate.h:321) | MapObserver::onDidFinishLoadingStyle() (map/map_observer.hpp:64) | widget-callback | yes |
| P1 | Tile server options / well-known tile server | none | — | MLNSettings.tileServerOptions (MLNSettings.h:38); +[MLNSettings useWellKnownTileServer:] (:58) with MLNWellKnownTileServer {MLNMapTiler, MLNMapLibre, MLNMapbox} (:11); the option object is MLNTileServerOptions (MLNTileServerOptions.h:12: baseURL :17, uriSchemeAlias :22, sourceTemplate :27, styleTemplate :42, spritesTemplate :57, glyphsTemplate :72, tileTemplate :87, apiKeyParameterName :102, defaultStyles :107) | mbgl::TileServerOptions (util/tile_server_options.hpp:15) with DefaultConfiguration() :284, MapLibreConfiguration() :289, MapboxConfiguration() :294, MapTilerConfiguration() :299; attached via ResourceOptions::withTileServerOptions (storage/resource_options.hpp:49) | widget-init | yes |
| P1 | maxBounds (pan constraint) | none | MapOptions.maxBounds; map.setMaxBounds(bounds\|null) / getMaxBounds() | MLNMapView.maximumScreenBounds (MLNMapView.h:1069) | mbgl::BoundOptions::withLatLngBounds (map/bound_options.hpp:16, field at :43) — "constrain the CENTER of the camera to be within these bounds. If ConstrainMode is Screen these bounds describe what can be shown on screen" | widget-init | yes |
| P1 | maxZoom | none | MapOptions.maxZoom (default 22); map.setMaxZoom(n) / getMaxZoom() | MLNMapView.maximumZoomLevel (MLNMapView.h:1064) — "default 22, upper bound 25.5" | mbgl::BoundOptions::withMaxZoom (map/bound_options.hpp:26, field at :46) | widget-init | yes |
| P1 | minZoom | none | MapOptions.minZoom (default 0); map.setMinZoom(n) / map.getMinZoom() | MLNMapView.minimumZoomLevel (MLNMapView.h:1053) | mbgl::BoundOptions::withMinZoom (map/bound_options.hpp:21, field at :49); applied via Map::setBounds (map/map.hpp:98), read via Map::getBounds (:101) | widget-init | yes |
| P1 | onReady (map ready signal) | present | map.on('load'); map.loaded() | -mapViewDidFinishLoadingMap: (MLNMapViewDelegate.h:206) | MapObserver::onDidFinishLoadingMap() (map/map_observer.hpp:58) | controller | no |
| P2 | Ambient cache management (clear / invalidate / reset / pack) | none | — | -invalidateAmbientCacheWithCompletionHandler: (MLNOfflineStorage.h:433), -clearAmbientCacheWithCompletionHandler: (:444), -resetDatabaseWithCompletionHandler: (:454), -preloadData:forURL:modificationDate:expirationDate:eTag:mustRevalidate: (:480), -putResourceWithUrl:... (:488) | mbgl::DatabaseFileSource::clearAmbientCache (storage/database_file_source.hpp:103), invalidateAmbientCache (:90), resetDatabase (:41), packDatabase (:53), runPackDatabaseAutomatically (:63), put (:76) | controller-namespace | yes |
| P2 | Asset path (asset:// root) | none | — | — (implicit: the app bundle) | mbgl::ResourceOptions::withAssetPath(std::string) (storage/resource_options.hpp:80) | widget-init | yes |
| P2 | Custom protocol / scheme handler | none | addProtocol(customProtocol: string, loadFn: AddProtocolAction) / removeProtocol(customProtocol) | — (nearest is the MLNNetworkConfiguration session delegate) | mbgl::FileSourceManager::registerFileSourceFactory(FileSourceType, FileSourceFactory) (storage/file_source_manager.hpp:39); FileSourceType includes Asset/Database/FileSystem/Network/Mbtiles/ResourceLoader (storage/file_source.hpp:20-29) | widget-init | yes |
| P2 | Debug mask / tile boundaries / collision boxes / overdraw | none | map.showTileBoundaries, map.showCollisionBoxes, map.showPadding, map.showOverdrawInspector, map.repaint (properties) | MLNMapView.debugMask (MLNMapView.h:2267), type MLNMapDebugMaskOptions (MLNTypes.h) | mbgl::Map::setDebug(MapDebugOptions) / getDebug() (map/map.hpp:147-148); flags at map/mode.hpp:43 {TileBorders, ParseStatus, Timestamps, Collision, Overdraw, StencilClip, DepthBuffer} | controller | yes |
| P2 | Frame-rendered event + rendering stats | internal-only | map.on('render') | -mapViewDidFinishRenderingFrame:fullyRendered: (MLNMapViewDelegate.h:252) and the renderingStats overloads (:267, :284); stats object MLNRenderingStats.h:7 (encodingTime :10, renderingTime :12, numDrawCalls :18, memTextures :67, …) | MapObserver::onDidFinishRenderingFrame(const RenderFrameStatus&) (map/map_observer.hpp:61); RenderFrameStatus {mode, needsRepaint, placementChanged, renderingStats} at :47-52; RenderMode {Partial, Full} at :42 | controller | yes |
| P2 | Initial render-surface size | internal-only | implicit (the container element's size) | -[MLNMapView initWithFrame:] (MLNMapView.h:193) | mbgl::MapOptions::withSize(Size) (map/map_options.hpp:112); mbl_map_create(width, height, …) (maplibre_flutter_core.h:52) | widget-init | no |
| P2 | Logging: level + custom handler | none | — (console) | MLNLoggingConfiguration.sharedConfiguration (MLNLoggingConfiguration.h:94), .loggingLevel (:89, default None), .handler (:80); MLNLoggingLevel enum at :17; MLNLoggingBlockHandler typedef at :62 | mbgl::Log::setObserver(std::unique_ptr<Observer>) (util/logging.hpp:28) with Observer::onRecord(EventSeverity, Event, int64_t code, const std::string&) (:21); Log::useLogThread(bool, severity) (:45) | widget-init | yes |
| P2 | Logo ornament | none | MapOptions.maplibreLogo, MapOptions.logoPosition (default 'bottom-left') | MLNMapView.showsLogoView (MLNMapView.h:391), logoView (:397), logoViewPosition (:403), logoViewMargins (:408) | — (SDK-level chrome, not an engine feature) | widget-prop | no |
| P2 | Maximum cache size | none | — | -[MLNOfflineStorage setMaximumAmbientCacheSize:withCompletionHandler:] (MLNOfflineStorage.h:417) | mbgl::ResourceOptions::withMaximumCacheSize(uint64_t) (storage/resource_options.hpp:95); runtime form DatabaseFileSource::setMaximumAmbientCacheSize (storage/database_file_source.hpp:125) | widget-init | yes |
| P2 | Maximum concurrent network requests | internal-only | setMaxParallelImageRequests(n) / getMaxParallelImageRequests() | — (NSURLSessionConfiguration.HTTPMaximumConnectionsPerHost via MLNNetworkConfiguration.sessionConfiguration, MLNNetworkConfiguration.h:69) | FileSource::setProperty(MAX_CONCURRENT_REQUESTS_KEY, n) (storage/file_source.hpp:84) | widget-init | yes |
| P2 | Maximum render-surface size clamp | none | MapOptions.maxCanvasSize (default [4096, 4096]) | — | — (nothing in mbgl clamps it; Size is whatever you pass to withSize/setSize) | widget-init | no |
| P2 | Network reachability override (online/offline) | none | — (the browser decides) | — (internal reachability monitoring) | mbgl::NetworkStatus::Set(Status) / Get() / Reachable() (storage/network_status.hpp:20-23, enum at :15) | controller | yes |
| P2 | Preferred / maximum frame rate | none | — | MLNMapView.preferredFramesPerSecond (MLNMapView.h:466); typedef at :122 with constants Default/LowPower/Maximum at :128/:132/:136 | — (mbgl renders on invalidation; frame pacing is the embedder's job — see our own note at maplibre_flutter_core.h:457-460) | widget-init | yes |
| P2 | Render mode (continuous vs static) | internal-only | — (always continuous) | — (MLNMapView is always continuous; static rendering is MLNMapSnapshotter, MLNMapSnapshotter.h:245) | mbgl::MapMode::{Continuous,Static,Tile} (map/mode.hpp:16); mbgl::MapOptions::withMapMode (map/map_options.hpp:32) | widget-init | no |
| P2 | Rendered-frame counter (fps diagnostic) | partial | — | MLNRenderingStats.numFrames (MLNRenderingStats.h:15); -[MLNMapView enableRenderingStatsView:] (MLNMapView.h:2277) | gfx::RenderingStats via MapObserver::RenderFrameStatus (map/map_observer.hpp:51); Map::enableRenderingStatsView (map/map.hpp:151), isRenderingStatsViewEnabled (:150) | capability-interface | no |
| P2 | Renderer error / context lost | none | map.on('webglcontextlost') / ('webglcontextrestored') | -mapViewRendererDidError: (MLNMapViewDelegate.h:515) | MapObserver::onRenderError(std::exception_ptr) (map/map_observer.hpp:94); recovery primitive Renderer::markContextLost() (renderer/renderer.hpp:50) | controller | yes |
| P2 | Tile prefetching (prefetchZoomDelta) | none | — | MLNMapView.prefetchesTiles (MLNMapView.h:478) — BOOLEAN ONLY, default YES | mbgl::Map::setPrefetchZoomDelta(uint8_t) / getPrefetchZoomDelta() (map/map.hpp:143-144) — "the default delta is 4" | widget-init | yes |
| P2 | constrainMode | none | — (nearest analogue is renderWorldCopies, which is not the same thing) | — (implied by maximumScreenBounds, MLNMapView.h:1069) | mbgl::MapOptions::withConstrainMode(ConstrainMode) (map/map_options.hpp:48); enum at map/mode.hpp:24 {None, HeightOnly, WidthAndHeight, Screen}; runtime setter Map::setConstrainMode (map/map.hpp:107) | widget-init | yes |
| P2 | crossSourceCollisions | none | MapOptions.crossSourceCollisions (default true) | — (not exposed on MLNMapView) | mbgl::MapOptions::withCrossSourceCollisions(bool) (map/map_options.hpp:80) | widget-init | yes |
| P2 | getStyle / style name / style default camera | none | map.getStyle(): StyleSpecification | MLNMapView.style (MLNMapView.h:261) → MLNStyle with .name; -reloadStyle: (:304) | Style::getJSON() (style/style.hpp:32), getURL() (:33), getName() (:36), getDefaultCamera() (:37) | controller | yes |
| P2 | isFullyLoaded / areTilesLoaded | none | map.loaded(); map.areTilesLoaded() | — (implied by mapViewDidBecomeIdle:) | mbgl::Map::isFullyLoaded() (map/map.hpp:153) | controller | yes |
| P2 | localIdeographFontFamily | none | MapOptions.localIdeographFontFamily (default 'sans-serif') | — (Apple renders CJK locally via CoreText unconditionally) | HeadlessFrontend(Size, pixelRatio, swap, mode, const std::optional<std::string>& localFontFamily, …) (platform/default/include/mbgl/gfx/headless_frontend.hpp:34); forwarded to Renderer(…, localFontFamily) (renderer/renderer.hpp:45-47) | widget-init | yes |
| P2 | maxPitch | none | MapOptions.maxPitch (default 60); map.setMaxPitch(n) / getMaxPitch() | MLNMapView.maximumPitch (MLNMapView.h:1118) — "may not exceed 60 degrees regardless" | mbgl::BoundOptions::withMaxPitch (map/bound_options.hpp:36, field at :52); hard-clamped to util::DEFAULT_PITCH_MAX = 60 | widget-init | yes |
| P2 | maxTileCacheSize / maxTileCacheZoomLevels | none | MapOptions.maxTileCacheSize (default null), MapOptions.maxTileCacheZoomLevels (default 5) | MLNMapView.tileCacheEnabled (MLNMapView.h:489) — Boolean only | only mbgl::Renderer::setTileCacheEnabled(bool) / getTileCacheEnabled() (renderer/renderer.hpp:111-112) — no numeric cap | widget-init | yes |
| P2 | minPitch | none | MapOptions.minPitch (default 0); map.setMinPitch(n) / getMinPitch() | MLNMapView.minimumPitch (MLNMapView.h:1107) | mbgl::BoundOptions::withMinPitch (map/bound_options.hpp:31, field at :55) | widget-init | yes |
| P2 | pixelRatio at creation | internal-only | MapOptions.pixelRatio (default devicePixelRatio) | implicit (UIScreen scale) | mbgl::MapOptions::withPixelRatio(float) (map/map_options.hpp:127); HeadlessFrontend(Size, float pixelRatio_, …) (platform/default/include/mbgl/gfx/headless_frontend.hpp:30) | widget-init | no |
| P2 | styleimagemissing | none | map.on('styleimagemissing', e => map.addImage(e.id, …)) | -mapView:didFailToLoadImage: (MLNMapViewDelegate.h:339) — returns a UIImage, so the SDK can supply it synchronously | MapObserver::onStyleImageMissing(const std::string&) (map/map_observer.hpp:67); companion onCanRemoveUnusedStyleImage (:70) | widget-callback | yes |
| P2 | triggerRepaint | internal-only | map.triggerRepaint(); map.redraw() | -[MLNMapView triggerRepaint] (MLNMapView.h:2318) | mbgl::Map::triggerRepaint() (map/map.hpp:56) | controller | no |
| P3 | Action journal (diagnostic event log) | none | — | MLNMapOptions.actionJournalOptions (MLNMapOptions.h:33); MLNActionJournalOptions.{enabled,path,logFileSize,logFileCount,renderingStatsReportInterval} (MLNActionJournalOptions.h:16,21,26,31,36); readers -[MLNMapView getActionJournalLog] (MLNMapView.h:2306), getActionJournalLogFiles (:2284), clearActionJournalLog (:2311) | mbgl::util::ActionJournalOptions (util/action_journal_options.hpp:12, enable at :23, withPath :41, withLogFileSize :60, withLogFileCount :79); passed as the 6th Map ctor arg (map/map.hpp:46); reader Map::getActionJournal (map/map.hpp:210) | widget-init | yes |
| P3 | Camera-change reason (why did the camera move) | none | — (event.originalEvent / e.type) *(unverified)* | MLNCameraChangeReason (MLNCameraChangeReason.h); -mapView:regionIsChangingWithReason: (MLNMapViewDelegate.h:152), -mapView:regionDidChangeWithReason:animated: (:182) | MapObserver::onCameraWillChange(CameraChangeMode) / onCameraDidChange(CameraChangeMode) (map/map_observer.hpp:54, :56); CameraChangeMode {Immediate, Animated} at :37 — NOTE mbgl only distinguishes immediate vs animated, NOT gesture vs programmatic. The richer reason enum is synthesised by each SDK. | controller | yes |
| P3 | Client name / version (analytics + User-Agent) | none | — | — (set internally by the SDK) | mbgl::ClientOptions::withName / withVersion (util/client_options.hpp:31, :46); 5th Map ctor arg (map/map.hpp:45); read back via Map::getClientOptions (map/map.hpp:208) | widget-init | yes |
| P3 | Compass / scale-bar ornaments | none | NavigationControl / ScaleControl (separate control classes) *(unverified)* | showsCompassView (MLNMapView.h:366), compassViewPosition (:378), showsScale (:331), scaleBar (:337), scaleBarUsesMetricSystem (:347), scaleBarPosition (:353) | — (SDK chrome) | widget-prop | no |
| P3 | Frame dump to PNG (verification) | internal-only | map.getCanvas().toDataURL() *(unverified)* | MLNMapSnapshotter (MLNMapSnapshotter.h:245) | Map::renderStill(StillImageCallback) (map/map.hpp:52); ours is mbl_map_write_png (maplibre_flutter_core.h:465) | controller | no |
| P3 | Map snapshotter (offscreen static image) | none | — (no equivalent) | MLNMapSnapshotter (MLNMapSnapshotter.h:245), -initWithOptions: (:256), -startWithCompletionHandler: (:293), -cancel (:328); options MLNMapSnapshotOptions (:70) with showsLogo (:90), showsAttribution (:95), camera (:118), coordinateBounds (:126), size (:134), scale (:141) | mbgl::MapSnapshotter (platform/default/include/mbgl/map/map_snapshotter.hpp:37), ctor :39/:46, setStyleURL :50, setSize :56, setCameraOptions :59, setRegion :62, snapshot(Callback) :78 | controller-namespace | yes |
| P3 | Offline pack management | none | — (no equivalent) | MLNOfflineStorage.packs (MLNOfflineStorage.h:287), -addPackForRegion:withContext:completionHandler: (:310), -removePack:withCompletionHandler: (:339), -invalidatePack: (:356), -reloadPacks (:371), -setMaximumAllowedMapboxTiles: (:384), countOfBytesCompleted (:392) | mbgl::DatabaseFileSource::listOfflineRegions (storage/database_file_source.hpp:137), createOfflineRegion (:162), setOfflineRegionDownloadState (:180); region definitions at storage/offline.hpp:31 (OfflineTilePyramidRegionDefinition) and :52 (OfflineGeometryRegionDefinition) | controller-namespace | yes |
| P3 | Tile level-of-detail controls | none | — | tileLodMinRadius (MLNMapView.h:502), tileLodScale (:512), tileLodPitchThreshold (:520), tileLodZoomShift (:533) | Map::setTileLodMinRadius/Scale/PitchThreshold/ZoomShift/Mode (map/map.hpp:197-206), documented at :166-196; TileLodMode enum at map/mode.hpp:38 | widget-init | yes |
| P3 | Zero-copy presentation toggle | internal-only | — | — | not an mbgl concept — our own present path: mbl_map_set_zero_copy (maplibre_flutter_core.h:299) | widget-init | no |
| P3 | canvasContextAttributes / antialias | none | MapOptions.canvasContextAttributes (default {antialias: false, powerPreference: 'high-performance'}) | — | NOT IN CORE — backend/context creation is ours per platform | reject | no |
| P3 | detach / re-attach (controller reuse) | present | — (no equivalent) | — | — | controller | no |
| P3 | fadeDuration / symbol placement transitions | partial | MapOptions.fadeDuration (default 300) | MLNStyle.transition (MLNStyle.h) | style::TransitionOptions via Style::setTransitionOptions (style/style.hpp:41) | widget-init | no |
| P3 | hash (sync camera to URL) | none | MapOptions.hash (default false) | — | NOT IN CORE | reject | no |
| P3 | northOrientation | none | — | — (not exposed on iOS MLNMapView) | mbgl::MapOptions::withNorthOrientation(NorthOrientation) (map/map_options.hpp:97); mbgl::Map::setNorthOrientation (map/map.hpp:106) | widget-init | yes |
| P3 | refreshExpiredTiles | none | MapOptions.refreshExpiredTiles (default true) | — | NOT IN CORE as an option (expiry is honoured by the file source unconditionally; Resource carries its own expiry metadata) | reject | no |
| P3 | renderWorldCopies | none | MapOptions.renderWorldCopies (default true); map.setRenderWorldCopies() / getRenderWorldCopies() | — | NOT IN CORE | reject | no |
| P3 | sourcedata / source-changed event | none | map.on('sourcedata') | -mapView:sourceDidChange: (MLNMapViewDelegate.h:329) | MapObserver::onSourceChanged(style::Source&) (map/map_observer.hpp:65) | controller | yes |
| P3 | trackResize | internal-only | MapOptions.trackResize (default true) | — (implicit in UIView layout) | — (embedder concern) | reject | no |
| P3 | validateStyle | none | MapOptions.validateStyle (default true) | — (invalid styleJSON throws, MLNMapView.h:290) | NOT IN CORE as a toggle — conversion always validates via convertJSON<T> | reject | no |
| P3 | viewportMode (FlippedY) | none | — | — | mbgl::MapOptions::withViewportMode(ViewportMode) (map/map_options.hpp:64); enum at map/mode.hpp:33 | reject | no |

#### Proposed signatures

**API key / access token** — P0, `widget-init`, evidence: impossible today — every map is constructed with mbgl::ResourceOptions::Default() (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:642 and :921); the example app dodges it with two key-free styles (packages/maplibre_flutter/example/lib/main.dart:189)
```dart
MapLibreSettings.configure({String? apiKey})  // must be called before the first MapLibreMap mounts
```
> p0 AND a headline finding: MapTiler, Stadia, Jawg, Amazon Location — most commercial tile providers require a key, and this plugin cannot supply one except by concatenating it into the style URL by hand, which leaks the key into logs and does not reach sprite/glyph/tile sub-requests that the engine derives from a canonical maptiler:// URL. Both native SDKs treat this as day-one global config; we have nothing. Bind ResourceOptions::withApiKey + the well-known-tile-server row below and the whole commercial-provider story works.

**Initial camera (center / zoom / bearing / pitch)** — P0, `widget-init`, evidence: packages/maplibre_flutter_platform_interface/lib/src/map_options.dart:20; applied at packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:120-126 (and the four sibling controllers)
```dart
MapOptions({MapCamera initialCamera = const MapCamera(center: LatLng(0, 0))})  // unchanged
```
> The one field we have, and it is correctly placed.

**Initial style document (URL)** — P0, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:40 (widget prop); pushed via didUpdateWidget at :192-194
```dart
MapLibreMap({required String style})  // unchanged
```
> Correct per the three-bucket rule and deliberately has no controller.setStyle. Keep.

**Map creation entry point** — P0, `widget-init`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_flutter_platform.dart:48
```dart
Future<MapLibreMapPlatformController> createMap({required String style, required MapOptions options}) // unchanged shape; MapOptions grows
```
> The shape is right and matches all four upstreams (style separate from options, because style is mutable and options are not). The problem is that MapOptions carries ONE field. Every row below that says widget-init lands here.

**Map load FAILURE event** — P0, `widget-callback`, evidence: structurally impossible today: the Static path passes MapObserver::nullObserver() (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:637) and the Continuous path's FrameObserver (:872-903) overrides only onDidFinishRenderingFrame and onDidFinishLoadingStyle — onDidFailLoadingMap is not overridden anywhere
```dart
MapLibreMap({void Function(MapLibreMapError error)? onMapLoadFailed}) with sealed MapLibreMapError { styleParse, styleLoad, notFound, unknown } + message
```
> p0 and the second headline finding. Right now a wrong style URL, an expired api key, a captive-portal redirect and a 500 from the tile server all produce THE SAME observable behaviour: a blank map, onReady completing normally, and a log line the app cannot see. There is no way for an app to show "couldn't load the map, retry". Every upstream ships this. It is also the prerequisite for making the api-key and transformRequest work debuggable — bind those without this and every misconfiguration is a silent blank map. Implementation: one MblObserverCallbacks struct on the C ABI carrying function pointers, populated for BOTH render modes (the Static path has no observer at all today, which is its own bug).

**Resize contract** — P0, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:39; driven from layout at packages/maplibre_flutter/lib/src/maplibre_map.dart:351-372; C ABI at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:71
```dart
@internal Future<void> resize(Size size)  // drop the ignored devicePixelRatio, or honour it (see the DPR row)
```
> The mechanism is good — layout-driven, debounced only where the texture lags (MapLibreResizeMaskHint, platform_interface/lib/src/maplibre_map_controller.dart:60), which is a genuinely nice design. The only defect is the unused DPR argument; see that row. Keeping this correctly @internal (apps never call resize in Flutter) is the right adaptation of gl-js's public map.resize().

**Style as inline JSON** — P0, `widget-prop`, evidence: CLAIMED at packages/maplibre_flutter/lib/src/maplibre_map.dart:40 ("a URL, asset path, or inline JSON") and packages/maplibre_flutter_core/src/maplibre_flutter_core.h:52; NOT IMPLEMENTED — mbl_map_set_style calls loadURL unconditionally (maplibre_flutter_core.cpp:1033), as do both render-thread mains (:650, :929) and the web shim (src/web/maplibre_flutter_core_web.cpp:195, :209)
```dart
MapLibreMap({required MapLibreStyle style}) with sealed MapLibreStyle: MapLibreStyle.uri(String), .json(String), .asset(String)  // or keep String and sniff a leading '{'
```
> DOC/BEHAVIOUR DEFECT, not merely a gap: three public doc comments promise inline JSON and none of the three tiers implements it. A style string starting with '{' is today handed to loadURL and fails as a malformed URL, silently (no observer is attached — see the map-load-failure row). Cheapest honest fix: mbl_map_set_style dispatches loadJSON when the string starts with '{'; Apple's SDK proves the ergonomics (separate styleURL/styleJSON properties) if you prefer an explicit sealed type.

**dispose / teardown** — P0, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:96-104; ownership rule at maplibre_map.dart:204-212 (the widget disposes only a controller it created)
```dart
Future<void> dispose()  // unchanged
```
> Correct, and the ownership split (widget disposes only what it created; a user-provided controller is detach()ed and disposed by its owner) matches webview_flutter and is well tested. The C++ side is careful in the ways that matter — GPU resources released ON the render thread with the context still current (maplibre_flutter_core.cpp:944-957), which is the bug class that used to SIGABRT on exit. No change proposed.

**pixelRatio at runtime / DPR honoured on resize** — P0, `controller`, evidence: MapLibreMapPlatformController.resize(Size, double devicePixelRatio) takes a DPR (packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:39) and every native impl DISCARDS it — see the comment at packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:218-220 "devicePixelRatio is unused here" (same at linux:262, windows:267, ios:234, android:259). The C ABI cannot accept it anyway: mbl_map_resize(map, width, height) (maplibre_flutter_core.h:71). Web pretends to accept it (core_web_controller.dart:204-210 → src/web/maplibre_flutter_core_web.cpp:270) but only resizes the canvas backing store; mbgl never sees the new ratio.
```dart
none public — but the interface should stop lying: either honour the DPR (recreate the frontend) or narrow the contract to `resize(Size size)` and document that DPR is fixed at creation
```
> THE defect of this domain. Drag a window from a Retina display to a 1x monitor (or change accessibility scaling) and the map keeps rendering at the old ratio forever: on macOS/iOS/Windows/Linux it stays crisp-but-mis-sized or blurry, and labels/lines are laid out on the wrong pixel grid. The interface takes a parameter it cannot use, which is worse than not taking it — a future implementer will assume it works. Fix is genuinely expensive (mbgl has no setter; you must tear down and rebuild the HeadlessFrontend + Map on the render thread, or patch upstream). Decide deliberately: honour it, or delete the parameter and document the limitation. Do not leave it as-is.

**transformRequest (URL rewrite + custom headers + credentials)** — P0, `widget-init`, evidence: no hook exists — grep for Authorization/header/ResourceTransform across packages/maplibre_flutter_core/src returns nothing but incidental comments
```dart
MapLibreSettings.configure({String Function(MapLibreResourceKind kind, String url)? transformRequest, Map<String,String>? headers})
```
> THE answer to the maintainer's own question ("how does a consumer add an API key or Authorization header today?"): they cannot. Not through the style URL either — an Authorization header has nowhere to go. This blocks every enterprise deployment behind an auth proxy, which is a large share of paying users. Two-tier proposal, and I would ship them in this order: (1) a static Map<String,String> headers — trivial, covers Bearer tokens, no callback marshalling, no isolate hazard; (2) the full gl-js-shaped callback. Note mbgl's callback is URL-rewrite-only (it hands back a string, resource_transform.hpp:12-13) so HEADERS ARE NOT EXPRESSIBLE THROUGH ResourceTransform — headers require touching the platform HTTP source (curl on Linux/Windows, NSURLSession on Apple, our OkHttp bridge on Android at maplibre_flutter_core_android.h:26-33). Budget accordingly: the URL half is easy, the header half is four platform edits. Also: the transform runs on the file-source thread, so a Dart callback needs NativeCallable.listener + an async FinishedCallback, or a snapshot of the rules taken on the Dart side and evaluated in C++.

**Ambient cache path (offline DB location)** — P1, `widget-init`, evidence: ResourceOptions::Default() (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:642, :921) — so the DB goes wherever mbgl's default puts it, which on desktop is the process CWD
```dart
MapLibreSettings.configure({String? cachePath})
```
> p1 rather than p2 because the DEFAULT is wrong for a Flutter app on every platform: mbgl's default cache path is relative to the working directory, not path_provider's application-support directory, so on iOS/Android it can land somewhere the OS will purge or refuse to write. Anyone shipping this plugin will need to point it at getApplicationSupportDirectory(). Cheap to bind (one string on the ResourceOptions we already build), and it also unblocks the offline-pack work in §10, which needs a stable DB location.

**App lifecycle (pause / resume / background)** — P1, `widget-init`, evidence: no AppLifecycleState handling in any controller or in packages/maplibre_flutter/lib/src/maplibre_map.dart
```dart
internal: WidgetsBindingObserver in _MapLibreMapState → pause the render loop and the file source on AppLifecycleState.paused, resume on .resumed
```
> p1 for battery and data. A backgrounded map today keeps its render thread and can keep fetching tiles; Continuous mode is update-driven so it will usually be quiet, but any animated model or in-flight camera animation keeps it hot, and the file source never pauses. Android's SDK makes this the CALLER's job, which is exactly the kind of footgun a Flutter plugin should absorb — do it automatically in the widget, with no public API. Pairs with the memory-pressure row: same observer, same PR.

**Attribution display (legal requirement)** — P1, `widget-prop`, evidence: no attribution anywhere in app-facing code — grep across packages/maplibre_flutter/lib and the platform interface finds `attribution` ONLY as a generated source-spec field (packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart:76)
```dart
MapLibreMap({MapLibreAttribution attribution = const MapLibreAttribution.compact()}) + controller.getAttributions() → List<MapLibreAttributionInfo>
```
> COMPLIANCE ROW, and the most embarrassing gap in this domain. Every shipped MapLibre SDK — gl-js, Apple, Android — displays attribution BY DEFAULT because tile providers' terms of use require it; OpenStreetMap-derived tiles (our own example uses demotiles and OpenFreeMap Liberty) require attributing OSM. We display nothing, on any platform, and offer the app no way to display it. This is the one row here that could get a downstream user in legal trouble. The Flutter-idiomatic version is easy — a small widget in the map's Stack, fed by a new mbl_map_get_attributions() over Style::getSources() + Source::getAttribution() — and the widget bucket is the right place (declarative, low-frequency). Also fix the two ➖ cells in the matrix.

**Idle event** — P1, `widget-callback`, evidence: not overridden in FrameObserver (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903)
```dart
MapLibreMap({VoidCallback? onIdle})
```
> The standard signal for "the map is fully drawn now" — what integration tests await before a screenshot, what apps use to trigger a queryRenderedFeatures pass, and what a golden test needs to be deterministic. Given CLAUDE.md §7's rule that "a frame came back" does not prove the map is visible, an idle event is worth more to this project than to most: it is the assertion primitive the Windows blank-map class of bug needed. Comes free with the observer bridge.

**Initial camera from bounds (`bounds` + `fitBoundsOptions`)** — P1, `widget-init`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/map_options.dart
```dart
MapOptions({LatLngBounds? initialBounds, EdgeInsets initialBoundsPadding = EdgeInsets.zero})  // wins over initialCamera when set, exactly as gl-js `bounds` overrides `center`/`zoom`
```
> Shares the runtime `fitBounds` implementation with the camera domain — build cameraForLatLngBounds into the C ABI once and both rows land. Note the matrix calls cameraForLatLngs native_only, which is right, but `cameraForBounds` is NOT web_only-vs-native: mbgl has it, so the ❌ is accurate.

**LatLngBounds value type** — P1, `value-type`, evidence: only LatLng exists — packages/maplibre_flutter_platform_interface/lib/src/lat_lng.dart:5
```dart
@immutable class LatLngBounds { const LatLngBounds({required LatLng southwest, required LatLng northeast}); factory LatLngBounds.fromPoints(Iterable<LatLng>); bool contains(LatLng); LatLng get center; }
```
> PREREQUISITE for maxBounds, initialBounds, fitBounds, getBounds and cameraForBounds — five rows across two domains blocked on one 40-line value type. Build it first. Use southwest/northeast (all three upstreams agree on that pair; only the ORDER of the constructor args differs) and remember LatLng(lat,lng) vs GeoJSON [lng,lat] at the serialisation boundary.

**Memory pressure: reduceMemoryUse / clearData** — P1, `controller`, evidence: nothing responds to memory pressure — no didHaveMemoryPressure handler in any controller; the render thread just keeps its caches (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:905-941)
```dart
controller.reduceMemoryUse()  // plus an automatic hook on WidgetsBindingObserver.didHaveMemoryPressure
```
> p1 for mobile. Flutter surfaces memory pressure as WidgetsBindingObserver.didHaveMemoryPressure and today we ignore it, so a backgrounded map holds its full tile cache and raises the app's OOM-kill probability on Android. Both native SDKs wire onLowMemory internally, so our behaviour is a regression versus the SDK path users would otherwise have. The right shape is BOTH: an automatic hook in the widget (no API to learn) and a public method for apps with their own memory policy.

**Persistent content inset / camera padding** — P1, `widget-init`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/map_options.dart (persistent) and camera.dart (transient)
```dart
MapOptions({EdgeInsets contentInset = EdgeInsets.zero}) for the persistent case; padding on camera ops for the transient case
```
> Overlaps the camera domain — coordinate before implementing. Included here because Apple's split is the design decision to copy: a PERSISTENT inset (a bottom sheet permanently covering 40% of the map, which should shift the map's effective centre and every projection) is genuinely init/widget state, while a per-animation edgePadding is a camera argument. gl-js has only the latter, which is why gl-js apps constantly re-pass padding. Note the knock-on: contentInset must feed the projector too, or markers and the visible centre disagree.

**Style from a Flutter asset** — P1, `widget-prop`, evidence: nothing resolves assets: the shim constructs ResourceOptions::Default() (maplibre_flutter_core.cpp:642, :921) so assetPath is unset, and no Dart tier rewrites an asset key to a path (grep of the five controllers finds asset handling only for .glb models)
```dart
MapLibreStyle.asset('assets/style.json')  // widget resolves via rootBundle → temp file, or set assetPath once via MapLibreSettings.configure(assetPath: …)
```
> Ships-blocking for offline/bundled-style apps, which is a common Flutter case. Two possible mechanisms: (a) MapLibreSettings.configure(assetPath:) → ResourceOptions::withAssetPath so 'asset://foo.json' works engine-side (matches Android exactly), or (b) Dart-side: read from rootBundle and hand over inline JSON (depends on the row above). (a) is better because it also fixes asset:// sprite/glyph/tile URLs inside the style document, which (b) does not.

**Style-loaded event** — P1, `widget-callback`, evidence: observed but never surfaced: FrameObserver::onDidFinishLoadingStyle at packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:890-899 uses it to re-apply transition options and re-add model layers, and stops there. Continuous mode only — the Static path has no observer (:637).
```dart
MapLibreMap({VoidCallback? onStyleLoaded}) + Future<void> get controller.styleLoaded
```
> The callback is ALREADY BEING DELIVERED into our C++ — this is purely a matter of forwarding it. High value because it is the correct moment to add app layers/sources: today an app must await onReady (first frame) and hope the style is up, and after a runtime style change it gets no signal at all, so its own layers silently vanish (mbgl drops every custom layer on style load — our own header documents this at maplibre_flutter_core.cpp:886-888). Without this event, `MapLibreMap.style` being a declarative prop is a trap: change the style and your layers are gone with no notification.

**Tile server options / well-known tile server** — P1, `widget-init`, evidence: ResourceOptions::Default() at packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:642, :921
```dart
MapLibreSettings.useWellKnownTileServer(MapLibreWellKnownTileServer.mapTiler) and MapLibreSettings.configure({MapLibreTileServerOptions? tileServerOptions})
```
> This is what makes `maptiler://maps/streets` resolve, and what tells the engine WHERE to append the api key (apiKeyParameterName). Bind the three static presets first (one enum + one C call, trivial) and the full 12-field custom object later — Apple ships both and 95% of users only need the preset. Depends on the api-key row; ship together.

**maxBounds (pan constraint)** — P1, `widget-init`, evidence: packages/maplibre_flutter_platform_interface/lib/src/map_options.dart
```dart
MapOptions({LatLngBounds? maxBounds}) + controller.camera.setMaxBounds(LatLngBounds?) / getMaxBounds()
```
> NAME DISAGREEMENT worth flagging in dartdoc: gl-js's maxBounds constrains what is VISIBLE, mbgl's default constrains the CENTRE (bound_options.hpp:42), and Apple's name (maximumScreenBounds) matches the gl-js meaning. Under ConstrainMode::Screen mbgl matches gl-js. So if you adopt the gl-js name — and you should, it is the one everyone knows — you must also set ConstrainMode::Screen or apps will get subtly different behaviour on web-gljs versus native. That single decision is exactly the kind of thing this spec exists to prevent someone rediscovering.

**maxZoom** — P1, `widget-init`, evidence: packages/maplibre_flutter_platform_interface/lib/src/map_options.dart
```dart
MapOptions({double? maxZoom}) + controller.camera.setMaxZoom(double) / getMaxZoom()
```
> See minZoom — same C ABI call. Document Apple's 25.5 hard ceiling.

**minZoom** — P1, `widget-init`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/map_options.dart + camera.dart
```dart
MapOptions({double? minZoom}) + controller.camera.setMinZoom(double) / getMinZoom()
```
> gl-js naming per policy (Android's ...Preference suffix and Apple's minimumZoomLevel both lose). One C ABI call — mbl_map_set_bounds(minZoom, maxZoom, minPitch, maxPitch, bounds…) with sentinels for 'unset' — covers this row and the next four; do them as one change, not five.

**onReady (map ready signal)** — P1, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:91 → packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:22; but the native implementation polls for a FRAME, not a load: packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:143-153 (_pollReady → _coreMap.awaitFrame)
```dart
Future<void> get onReady  // keep, but document precisely: completes on FIRST FRAME, not style-load, and never completes if the style fails
```
> SEMANTIC DRIFT the matrix hides by calling it "load-equivalent". gl-js `load` fires when the style and all its first-view resources are loaded; ours fires when any frame — including an empty one — has been rendered. On the native tiers they differ by hundreds of ms and, worse, in FAILURE: a 404 style still produces frames, so onReady completes happily on a blank map. The doc comment at platform_interface:19-21 also promises "has finished loading its initial style", which is not what the code does. Either implement it on MapObserver::onDidFinishLoadingMap (cheap once an observer bridge exists — see the next three rows) or fix the docs. Do not leave the contract saying one thing and the code doing another.

**Ambient cache management (clear / invalidate / reset / pack)** — P2, `controller-namespace`, evidence: no DatabaseFileSource is ever obtained; only the Network file source is touched (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:625-628)
```dart
MapLibreSettings.cache.clear() / .invalidate() / .reset() / .pack()
```
> All four are async with an exception_ptr callback, so the Dart side is Future<void> with a thrown MapLibreException. Buildable today on every native tier — offline_database.cpp is compiled on all four arms (src/CMakeLists.txt:171, :302, :418, :546), unlike the snapshotter. Sequence after cachePath: clearing a cache whose location you do not control is not much use.

**Asset path (asset:// root)** — P2, `widget-init`, evidence: ResourceOptions::Default() (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:642, :921)
```dart
MapLibreSettings.configure({String? assetPath})
```
> Same C ABI change as cachePath/maxCacheSize. Together with the style-from-asset row this is the whole bundled-style story; point it at the Flutter asset bundle's on-disk root per platform (which differs — flutter_assets under the app dir on desktop, the APK on Android, so on Android this needs the AAssetManager path or a copy-out).

**Custom protocol / scheme handler** — P2, `widget-init`, evidence: would need a new C ABI + a Dart callback registry in packages/maplibre_flutter_core
```dart
MapLibreSettings.addProtocol(String scheme, Future<Uint8List> Function(String url) handler)
```
> gl-js naming (the only upstream with a first-class API for it). This is how the web ecosystem does PMTiles and COG — pmtiles:// is registered exactly this way — so it is the unlock for a whole class of serverless-tiles apps. On native the mechanism is registerFileSourceFactory, which is heavier than gl-js's loadFn but expressible. Same threading caveat as transformRequest. Also note mbgl already has an `Mbtiles` FileSourceType built in, which may cover the common case without any of this.

**Debug mask / tile boundaries / collision boxes / overdraw** — P2, `controller`, evidence: never called
```dart
controller.setDebugOptions(Set<MapLibreDebugOption>)  // gl-js's individual booleans map onto mbgl's bit flags
```
> Cheap (one int) and disproportionately useful to THIS project specifically: CLAUDE.md §11 records that GDI capture cannot photograph our Windows texture and that the Android emulator cannot composite our buffer, so on-map debug overlays drawn BY THE ENGINE are one of the few verification tools that survive both traps. TileBorders alone would have shortened several documented debugging sessions. gl-js's per-flag booleans read better in Dart than a bitmask — expose a Set<enum>.

**Frame-rendered event + rendering stats** — P2, `controller`, evidence: FrameObserver::onDidFinishRenderingFrame at packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:875-877 calls publishCurrentFrame and discards the status entirely — mode/needsRepaint/placementChanged/stats are all dropped
```dart
controller.events → Stream<MapLibreMapEvent> including MapFrameRendered(fullyRendered: bool, stats: MapLibreRenderingStats?)
```
> We are already inside this callback on every frame and throwing away the whole status struct. `fullyRendered` (RenderMode::Full) is the cheap high-value bit — it is what "the map is done" means in Continuous mode and the natural implementation of onReady's real contract. Stats are p3 but essentially free once the struct crosses. Deliver as a Stream, not a widget callback: per-frame frequency.

**Initial render-surface size** — P2, `widget-init`, evidence: hardcoded 512x512 in every native controller: packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:73-74 (and linux:72, windows:76, ios:83, android:92)
```dart
no public API — the widget should pass its first laid-out size, or the map should be created lazily on first layout
```
> Every map renders its first frames at a 512x512 square regardless of the widget box, then resizes. Visible as a brief wrong-aspect frame and a wasted style/tile load at the wrong zoom-for-viewport. Fix in the Dart tier (defer create until the first LayoutBuilder pass, or pass an initial size through MapOptions), no C ABI change needed. Not a public API row — a defect row.

**Logging: level + custom handler** — P2, `widget-init`, evidence: no observer installed — mbgl logs go to each platform's default sink (stderr / logcat / OSLog) with no level control
```dart
MapLibreSettings.configure({MapLibreLogLevel logLevel = MapLibreLogLevel.warning, void Function(MapLibreLogRecord)? onLog})
```
> Apple's shape (level + handler on a shared configuration), because mbgl has no level filter of its own — Log::Observer sees everything and returns true to consume, so the LEVEL must be implemented on our side exactly as Apple does. Practical value beyond tidiness: today a style that 404s logs to stderr where a Flutter app never sees it, which is half of why the map-load-failure row below is p0. Threading note: onRecord fires from mbgl's log thread (useLogThread defaults to async for everything but Error), so a Dart handler needs NativeCallable.listener.

**Logo ornament** — P2, `widget-prop`, evidence: would live in packages/maplibre_flutter/lib/src/maplibre_map.dart
```dart
MapLibreMap({bool showLogo = false, MapLibreOrnamentPosition logoPosition = MapLibreOrnamentPosition.bottomLeft})
```
> Optional in MapLibre's case (unlike Mapbox, where the logo is mandatory), so p2 not p1. Ship it with the attribution widget — same Stack, same position enum (copy Apple's MLNOrnamentPosition, MLNMapView.h:63, which Android mirrors as gravity).

**Maximum cache size** — P2, `widget-init`, evidence: ResourceOptions::Default() (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:642, :921)
```dart
MapLibreSettings.configure({int? maximumCacheSizeBytes})
```
> Ship with cachePath — same ResourceOptions, one C ABI change for both. Note mbgl offers it BOTH init-time (ResourceOptions) and at runtime (DatabaseFileSource, with a completion callback); prefer the init-time form, which needs no async plumbing.

**Maximum concurrent network requests** — P2, `widget-init`, evidence: an env var, not an API: capDesktopRequestConcurrency() defaults to 6 and reads MAPLIBRE_MAX_CONCURRENT_REQUESTS (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:616-631); the web tier hardcodes a bounded pool (src/web/emscripten_http_file_source.cpp:63)
```dart
MapLibreSettings.configure({int? maxConcurrentRequests})
```
> gl-js naming adapted (drop 'Image' — mbgl's knob covers all resource kinds). Already implemented, just not reachable from Dart, and the default of 6 exists for a documented reason (HTTP/2 ENHANCE_YOUR_CALM from community tile servers). Worth exposing because the right value is server-dependent: 6 for demotiles, 20+ for a private CDN.

**Maximum render-surface size clamp** — P2, `widget-init`, evidence: unbounded — packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:216-226 passes the widget's logical size straight through, and the core multiplies by pixelRatio
```dart
MapOptions({Size? maxSurfaceSize})  // logical points; the widget cover-fits the clamped texture
```
> gl-js is the only upstream that guards this, and it guards it for a reason: a 6K display at DPR 2 asks for a ~12000px-wide framebuffer, which exceeds GL_MAX_TEXTURE_SIZE on plenty of GPUs and simply fails to allocate. We have no clamp on any tier. Pure-Dart fix in the resize path; no C ABI change.

**Network reachability override (online/offline)** — P2, `controller`, evidence: never called — grep for NetworkStatus across packages/maplibre_flutter_core/src returns nothing
```dart
MapLibreSettings.connected = false;  // null restores automatic detection, matching Android's nullable Boolean
```
> Android's shape, because Android is the only upstream that exposes it and it maps 1:1 onto NetworkStatus::Set. The use case is real for a Flutter app: connectivity_plus says we are offline, so tell the engine to stop retrying and serve the ambient cache instead of stalling every tile request. Static/global (NetworkStatus is a process singleton), so it belongs on MapLibreSettings, not the controller — I have marked the bucket 'controller' only because the enum has no 'global' member; see naming notes.

**Preferred / maximum frame rate** — P2, `widget-init`, evidence: no pacing control; the render thread renders whenever invalidated (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:905-941)
```dart
MapOptions({int? maxFramesPerSecond})  // null = uncapped
```
> Battery/thermal knob that Apple considers important enough to ship three named constants for. Implementable purely in our render loop (throttle publishCurrentFrame), no mbgl change. Pairs with the renderedFrameCount diagnostic below — you want to cap the rate and then measure it.

**Render mode (continuous vs static)** — P2, `widget-init`, evidence: a --dart-define, not an API: packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:109-112 `bool.fromEnvironment('MAPLIBRE_CONTINUOUS', defaultValue: true)` (identically in the other four native controllers and at packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:39). Plumbed to mbl_map_create's `continuous` flag (maplibre_flutter_core.h:52).
```dart
MapOptions({MapRenderMode renderMode = MapRenderMode.continuous}) with enum MapRenderMode { continuous, static }
```
> Already plumbed end-to-end; only the public knob is missing. Worth exposing because Static mode is the right choice for a non-interactive thumbnail map (renders one complete frame, no render loop, no battery drain) — that is a real app use case, not just a test harness switch. Note the documented consequence: mbgl ignores TransitionOptions in Static (our own header says so at maplibre_flutter_core.h:225-226), so `layers.setTransitionOptions` becomes a no-op — document that on the enum value.

**Rendered-frame counter (fps diagnostic)** — P2, `capability-interface`, evidence: exists but is MISPLACED: renderedFrameCount hangs off the MapLibreModelHost capability (packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:130), surfaced at packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:239-244; C ABI at maplibre_flutter_core.h:428
```dart
move to a MapLibreRenderDiagnostics capability interface: int? get renderedFrameCount; MapLibreRenderingStats? get renderingStats;
```
> An API-shape defect rather than a gap: a render-thread frame counter has nothing to do with 3D models, and an app that wants fps must currently feature-detect MapLibreModelHost to get it. Both native SDKs put frame stats on the map/renderer, not on any drawing feature. Split it into its own capability interface before anyone depends on the current location — this is exactly the contract churn CLAUDE.md §3 says to avoid paying twice. Also add enableRenderingStatsView while you are there (both SDKs ship it; mbgl implements the overlay for you at map.hpp:151).

**Renderer error / context lost** — P2, `controller`, evidence: not overridden (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903)
```dart
controller.events → MapRenderError(message)
```
> Matters most on Android (GPU driver resets on app resume) and Windows (device-removed on driver update or GPU switch) — both platforms where our texture-composited present path would otherwise show a permanently frozen or blank map with no diagnosis. Given that a blank Windows map already cost this project a debugging session, having the engine SAY it lost its context is worth the small binding cost.

**Tile prefetching (prefetchZoomDelta)** — P2, `widget-init`, evidence: never called; would live in packages/maplibre_flutter_platform_interface/lib/src/map_options.dart
```dart
MapOptions({int? prefetchZoomDelta})  // null = engine default (4), 0 = disabled
```
> UPSTREAM DISAGREEMENT — Apple ships a Boolean, Android ships both, mbgl's truth is an int where 0 means off. Chose the int (Android/mbgl): it is strictly more expressive and collapses to Apple's Boolean. Worth having because prefetch is a bandwidth/perceived-latency trade an app should be able to tune — a metered-connection app wants it off, a fast-panning app wants delta 5.

**constrainMode** — P2, `widget-init`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/map_options.dart
```dart
MapOptions({MapConstrainMode constrainMode = MapConstrainMode.heightOnly})
```
> Coupled to maxBounds: bound_options.hpp:42 says that when ConstrainMode is Screen the bounds describe what can be shown on SCREEN rather than what the CENTRE may reach. So if you bind maxBounds (p1 below) you must bind this too, or the semantics of maxBounds are undefined for anyone expecting the gl-js meaning. Ship them together.

**crossSourceCollisions** — P2, `widget-init`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/map_options.dart
```dart
MapOptions({bool crossSourceCollisions = true})
```
> Init-only in mbgl (MapOptions has no runtime setter), so it belongs on MapOptions and nowhere else. Matters as soon as an app adds its own symbol layer on top of a basemap and wants its labels to win — which is the primary use of our layers API. gl-js and Android agree on the name; Apple simply omits it.

**getStyle / style name / style default camera** — P2, `controller`, evidence: the widget owns the style string it passed in, but nothing can read back the LOADED style
```dart
controller.getStyleJson() → Future<String>; controller.getStyleName(); controller.getStyleDefaultCamera() → Future<MapCamera>
```
> getDefaultCamera is the sleeper here: it is how you honour a style document's own center/zoom instead of forcing LatLng(0,0) — which is what MapOptions defaults to today (map_options.dart:15), so out of the box we ignore the style author's intended view. Apple's -resetPosition (MLNMapView.h:1131) is built on exactly this. getJSON is the debugging tool ("what did the engine actually load").

**isFullyLoaded / areTilesLoaded** — P2, `controller`, evidence: would need a new C ABI getter next to mbl_map_frame_count (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:428)
```dart
Future<bool> get controller.isFullyLoaded
```
> Trivial to bind (one bool getter, no observer needed) and it is the pull-based twin of the idle event — useful in tests that would rather poll than subscribe. The matrix's ➖ is the clearest example in this domain of the drift the maintainer suspected: someone read gl-js's method list, saw no native equivalent, and marked it impossible without checking map.hpp.

**localIdeographFontFamily** — P2, `widget-init`, evidence: the frontend is constructed without it at packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:636 and :912
```dart
MapOptions({String? localIdeographFontFamily})
```
> Real consequence, not cosmetic: without it a CJK basemap downloads megabytes of glyph PBFs per view. gl-js and Android both default it ON ('sans-serif'); we currently default it OFF by omission, so our CJK behaviour is worse than either. Init-only — the parameter is on the frontend/Renderer constructor. Cheap C ABI addition (one more const char* on mbl_map_create).

**maxPitch** — P2, `widget-init`, evidence: packages/maplibre_flutter_platform_interface/lib/src/map_options.dart
```dart
MapOptions({double? maxPitch}) + controller.camera.setMaxPitch(double) / getMaxPitch()
```
> Note the ceiling in the dartdoc: values above 60 are silently ignored by the engine on the five native tiers, but gl-js honours up to 85 on web-gljs. That is a genuine cross-engine behaviour split worth documenting rather than papering over.

**maxTileCacheSize / maxTileCacheZoomLevels** — P2, `widget-init`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/map_options.dart
```dart
MapOptions({bool tileCacheEnabled = true})  // Apple's shape, because that is all the engine has
```
> UPSTREAM DISAGREEMENT, resolved by the ceiling: gl-js's numeric knobs are unbindable, Apple's Boolean is exactly mbgl's Boolean. Take Apple's. Worth binding on memory-constrained Android alongside reduceMemoryUse (see the onLowMemory row) — Apple's doc at :483 is explicit that YES costs memory for smoother zoom.

**minPitch** — P2, `widget-init`, evidence: packages/maplibre_flutter_platform_interface/lib/src/map_options.dart
```dart
MapOptions({double? minPitch}) + controller.camera.setMinPitch(double) / getMinPitch()
```
> Same C ABI call as the zoom limits.

**pixelRatio at creation** — P2, `widget-init`, evidence: packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:99-104 reads ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0 (identically at linux:100, windows:104, ios:113, android:124; web at packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:83)
```dart
MapOptions({double? pixelRatio})  // null = follow the view's devicePixelRatio (today's behaviour)
```
> An explicit override is what low-end-device apps and golden tests want (gl-js and Android both expose it). Cheap: the value already flows to mbl_map_create. Two latent bugs worth fixing at the same time: `implicitView` is the wrong view in a multi-window app, and it is read BEFORE the widget has a BuildContext, so MediaQuery.devicePixelRatioOf is never consulted.

**styleimagemissing** — P2, `widget-callback`, evidence: not overridden in FrameObserver (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903)
```dart
MapLibreMap({void Function(String imageId)? onStyleImageMissing})  // app responds with controller.layers.addImage / addWidgetIcon
```
> Pairs beautifully with our existing addWidgetIcon: the engine asks for an icon by id and the app rasterises a Flutter widget on demand, which is a genuinely nicer story than any upstream has. Note Apple's variant is synchronous (return the image) while gl-js's is async (call addImage later); mbgl's callback is a plain notification, so take the gl-js shape. Duplicate matrix rows at :495 and :559 should be reconciled.

**triggerRepaint** — P2, `controller`, evidence: C ABI has it (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:461) and the Dart core wrapper exposes it (packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:386), but it is not on the platform interface or the app-facing controller — the only caller is the internal model-animation ticker
```dart
controller.triggerRepaint()
```
> Zero-cost to expose — it exists at every layer except the public one. Needed by anyone driving a custom animated layer, and CLAUDE.md §11 already warns that Continuous mode is update-driven, not vsync-driven, so an app WILL hit the case where nothing repaints. All three upstreams expose it.

**Action journal (diagnostic event log)** — P3, `widget-init`, evidence: the Map is constructed with 4 args at packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:637-642 and :916-921, so the ActionJournalOptions default (disabled) applies
```dart
MapOptions({MapLibreActionJournal? actionJournal}) + controller.diagnostics.readActionJournal()
```
> Long tail, but it is the SDK-blessed way to answer "why is this user's map blank" in the field — a JSON event stream of tile requests, style loads and failures. Cheap to bind (all-scalar options). Both Apple and Android expose it in 2026, which suggests it is the direction upstream is going for observability. Revisit after the error/lifecycle events below, which cover 80% of the same need.

**Camera-change reason (why did the camera move)** — P3, `controller`, evidence: controller.onCameraChanged is a bare Listenable with no payload (packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:75-82)
```dart
— (camera/events domain owns this; noted for the lifecycle-event bridge)
```
> Cross-domain, listed because it rides the SAME observer bridge as the p0 error event — build that bridge once with room for the camera callbacks and this row becomes nearly free later. The important finding for whoever designs it: mbgl gives you only Immediate-vs-Animated, so "the user did this" versus "my code did this" must be synthesised in our Dart gesture layer, exactly as Apple and Android do it. Do not promise gesture attribution from the engine.

**Client name / version (analytics + User-Agent)** — P3, `widget-init`, evidence: defaulted — the Map is constructed with 4 args (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:637-642, :916-921), and capDesktopRequestConcurrency also passes a default ClientOptions() (:627)
```dart
MapLibreSettings.configure({String? clientName, String? clientVersion})
```
> Matters for tile-server operators who rate-limit or bill by client, and for us: identifying as 'maplibre_flutter/x.y.z' would let MapTiler/OpenFreeMap see this plugin's traffic. Note the file-source cache key includes ClientOptions, so this must be set once, before the first map, exactly like apiKey — reinforcing the global-settings choice.

**Compass / scale-bar ornaments** — P3, `widget-prop`, evidence: the example app hand-rolls rotate/tilt buttons instead (packages/maplibre_flutter/example/lib/main.dart)
```dart
— (out of this domain; cross-reference §6)
```
> Listed only so the ornament family is complete in one place; the controls domain owns the design. Note they should all share one MapLibreOrnamentPosition enum with the logo and attribution rows above.

**Frame dump to PNG (verification)** — P3, `controller`, evidence: C ABI at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:465 and Dart core wrapper at packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:855, but not on the platform interface or the app-facing controller
```dart
@visibleForTesting controller.captureFrame() → Future<Uint8List>  // PNG bytes
```
> Exists at every layer but the public one. Worth surfacing at least under @visibleForTesting: CLAUDE.md §7 mandates asserting real pixels rather than "a frame came back", and integration tests currently have no supported way to get those pixels. Distinct from a real snapshotter (next row) — this captures the LIVE map, which is what a test wants.

**Map snapshotter (offscreen static image)** — P3, `controller-namespace`, evidence: n/a
```dart
MapLibreSnapshotter(options).snapshot() → Future<Uint8List>
```
> BUILD-SYSTEM CAVEAT the matrix does not mention: map_snapshotter.cpp is compiled ONLY on the Apple arm of our core (packages/maplibre_flutter_core/src/CMakeLists.txt:160); the Android, Linux and Windows arms (:243, :376, :496) omit it. So "❌ on all five native" understates the cost on four of them — it is a CMake change plus a C ABI, not just a C ABI. Cheap alternative that covers most snapshot use cases: create a Static-mode map offscreen and call the existing mbl_map_write_png, which needs no new engine code at all. Recommend that first.

**Offline pack management** — P3, `controller-namespace`, evidence: n/a
```dart
— (out of this domain; see FEATURE_MATRIX §10)
```
> Cross-referenced only, so the resource story is complete in one place. Two prerequisites from THIS domain must land first or the offline work is built on sand: cachePath (you must control where packs live) and the map-load-failure event (offline downloads fail constantly and silently today). Also fix the DefaultFileSource reference in the matrix.

**Tile level-of-detail controls** — P3, `widget-init`, evidence: never called
```dart
MapOptions({MapLibreTileLod? tileLod})  // a small value-type carrying the five knobs
```
> Long tail, but a *cheap* long tail (five doubles + one enum, all init-time-safe) and the single biggest performance lever for pitched 3D views, which is exactly where our texture-composited desktop tiers hurt most. Apple's own doc at :531 says to configure pixelRatio before touching TileLodZoomShift — relevant given our pixelRatio row. Group as one value type rather than five MapOptions fields.

**Zero-copy presentation toggle** — P3, `widget-init`, evidence: packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:117-119 `bool.fromEnvironment('MAPLIBRE_ZEROCOPY', defaultValue: true)`
```dart
MapOptions({bool zeroCopyPresent = true})  // or leave as a dart-define
```
> Arguably should NOT become public API — it is a platform-implementation detail and the fallback is automatic. Listed for completeness and because a support-diagnosis knob ("try turning it off") is easier to give users as an option than as a rebuild flag. Recommend: keep it a dart-define, document it in the README's troubleshooting section.

**canvasContextAttributes / antialias** — P3, `reject`, evidence: n/a
```dart
— (do not bind)
```
> Reject: WebGL-context-creation specifics with no cross-platform meaning. If MSAA is ever wanted it is a per-backend decision in our own present path, not a public option.

**detach / re-attach (controller reuse)** — P3, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:149-155 (detach) and :114-143 (attach, with the disposed-while-in-flight guard at :134-137)
```dart
@internal attach/detach  // unchanged
```
> No upstream analogue — this is a Flutter-specific concern (widget remount, hot reload, a controller hoisted above a PageView). Correctly @internal. Noted so the lifecycle picture is complete; nothing to do.

**fadeDuration / symbol placement transitions** — P3, `widget-init`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:63-67 setTransitionOptions({duration, delay, placementTransitions}); C ABI at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:227
```dart
MapOptions({Duration? fadeDuration})  // init-time seed for the existing controller.layers.setTransitionOptions
```
> Already covered imperatively and better than gl-js (we also expose the placement-fade kill switch). The only gap is that gl-js lets you set it at construction, before the first style loads. Low value; our sticky re-apply after style load (maplibre_flutter_core.cpp:890-891) already covers the practical case.

**hash (sync camera to URL)** — P3, `reject`, evidence: n/a
```dart
— (do not bind)
```
> Browser-URL feature. A Flutter app that wants this composes it from controller.onCameraChanged + go_router in ten lines. Reject.

**northOrientation** — P3, `widget-init`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/map_options.dart
```dart
MapOptions({MapNorthOrientation northOrientation = MapNorthOrientation.upwards})
```
> Long tail. Both init-only and runtime-settable in mbgl; expose the init form only until someone asks. The matrix row is correctly ❌ (mbgl can do it, nothing bound).

**refreshExpiredTiles** — P3, `reject`, evidence: n/a
```dart
— (do not bind)
```
> Reject; record as ➖ in the matrix.

**renderWorldCopies** — P3, `reject`, evidence: n/a
```dart
— (do not bind)
```
> No mbgl equivalent; mbgl always renders world copies and controls wrapping through ConstrainMode instead. Should be added to FEATURE_MATRIX as ➖ on the five native columns and ❌ on web-gljs so the absence is documented rather than rediscovered.

**sourcedata / source-changed event** — P3, `controller`, evidence: not overridden in FrameObserver (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903)
```dart
controller.events → MapSourceChanged(sourceId)
```
> Long tail; comes free with the observer bridge. Chief use is knowing when a setGeoJsonData actually took effect.

**trackResize** — P3, `reject`, evidence: always on: the widget drives resize from layout (packages/maplibre_flutter/lib/src/maplibre_map.dart:351-372) and the web tier from a ResizeObserver (packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:128-147)
```dart
— (do not bind)
```
> Reject. In Flutter, not tracking the widget box is never the right behaviour; gl-js needs the escape hatch only because DOM resize observation is expensive there.

**validateStyle** — P3, `reject`, evidence: n/a; our own validation story is the synchronous-parse contract documented at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:174-179
```dart
— (do not bind)
```
> Reject. gl-js exposes it because its validator is a measurable startup cost in JS; mbgl's is not optional and not expensive.

**viewportMode (FlippedY)** — P3, `reject`, evidence: n/a — recommend never binding it
```dart
— (do not bind)
```
> RECOMMEND REJECTING, and I would change the matrix's ❌ to ➖ here. This flips the vertical orientation of the whole viewport, which would silently invert every screen-space convention this codebase has fought over — gesture anchors, latLngToScreenCoordinate's bottom-left y and the shim's compensating flip (maplibre_flutter_core.h:107-124), and the present-path blits. It is an embedder-integration escape hatch for platforms whose surface is upside down; we already handle that per-platform in the present path. Exposing it is a foot-gun with no user story.


### Camera, bounds & projection

#### Engine ceiling

Hard stops for the five native tiers and web-WASM — things no amount of binding work reaches, verified in the vendored headers:

- **Pitch is hard-clamped to 60°.** `util::DEFAULT_PITCH_MAX = M_PI / 3` (constants.hpp:35) and `Transform` clamps to it. `camera.setMaxPitch(85)` — legal in gl-js — cannot be honoured; the ceiling is 60. (`PITCH_MAX = M_PI` exists at constants.hpp:36 but is not the applied limit.) Our own C shim documents this at maplibre_flutter_core.h:103.
- **Zoom is clamped to `[0, 25.5]`** (`util::MIN_ZOOM`/`MAX_ZOOM`, constants.hpp:42-43); `DEFAULT_MAX_ZOOM = 22` (constants.hpp:46).
- **No globe / vertical-perspective projection, and no `setProjection`/`getProjection`.** `map.hpp` offers only `setProjectionMode(ProjectionMode)` (map.hpp:115), and `ProjectionMode` (projection_mode.hpp:12-39) is *axonometric skew*, an unrelated thing. Web Mercator is the only projection.
- **No `curve`, `screenSpeed` or `maxDuration` on a flight.** `AnimationOptions` (camera.hpp:102-135) has exactly `duration`, `velocity`, `minZoom`, `easing`, `transitionFrameFn`, `transitionFinishFn`. gl-js's `curve` (default 1.42), `screenSpeed` and `maxDuration` have no mbgl analogue; the van-Wijk parameters are baked in. `speed` maps to `velocity` and `minZoom` maps to `minZoom`, so those two are NOT ceilings (contra FEATURE_MATRIX.md:326/328).
- **No camera-change *reason* from the engine.** `MapObserver` gives `onCameraWillChange(CameraChangeMode)` / `onCameraIsChanging()` / `onCameraDidChange(CameraChangeMode)` (map_observer.hpp:54-56) and `CameraChangeMode` has only `Immediate` / `Animated` (map_observer.hpp:37-40). There is no equivalent of `MLNCameraChangeReason` (MLNCameraChangeReason.h:30). **Mitigation, not a ceiling for us:** our gesture layer is Dart (`gesture_handler.dart`, `rotate_handler.dart`), so we can synthesise the reason at the call site more accurately than the Apple SDK does.
- **No terrain elevation query.** `queryTerrainElevation` / `getCameraTargetElevation` have no counterpart anywhere in `include/mbgl/map/map.hpp`. Setting is possible (`CameraOptions::centerAltitude`, camera.hpp:61) but reading terrain height under a coordinate is not exposed.
- **No `setCenterClampedToGround`** — no such concept in `CameraOptions` or `Transform`.
- **No `fitScreenCoordinates` primitive** — but this is composable (unproject the two corners, then `cameraForLatLngs`, map.hpp:84), so it is *not* a ceiling, contra FEATURE_MATRIX.md:309.
- **`freezeElevation` during a flight** — no analogue.
- **Roll and fov exist in `CameraOptions` (camera.hpp:83/86) but are not in our cached camera struct**, and `Transform`'s honouring of them across every backend is unverified — treat as "expressible, needs a device check", not as proven.
- Conversely, several things FEATURE_MATRIX calls web-only ARE in core and are *not* ceilings: `anchor` (camera.hpp:69), `centerAltitude` (camera.hpp:61), `fov` (camera.hpp:86), `isRotating`/`isScaling`/`isPanning` (map.hpp:67-69), `cancelTransitions` (map.hpp:64), `latLngBoundsForCamera` (map.hpp:92), `getFreeCameraOptions` (map.hpp:164), `Style::getDefaultCamera()` (style.hpp:37).

#### Naming decisions

**Policy applied: gl-js verbs, mbgl/Android nouns, Apple's structural ideas where gl-js has none.**

Where the three canonical APIs disagree in this domain, and the call made:

1. **`bearing` vs `direction`/`heading`.** gl-js `getBearing/setBearing`, Android `CameraPosition.bearing`, mbgl `CameraOptions::bearing` (camera.hpp:76) — Apple alone says `direction` (MLNMapView.h:1081) / `heading` (MLNMapCamera.h:27). → **`bearing`**. Three-to-one, and our `MapCamera.bearing` (camera.dart:26) already says it.
2. **`pitch` vs `tilt`.** gl-js/Apple/mbgl all say `pitch`; Android alone says `tilt` (`CameraUpdateFactory.tiltTo`). → **`pitch`**.
3. **`zoom` vs `zoomLevel`.** Apple says `zoomLevel` (MLNMapView.h:1026) and models the camera by **altitude** (`MLNMapCamera.altitude`, MLNMapCamera.h:49). gl-js and mbgl are zoom-based. → **`zoom`**; altitude is a derived convenience at most (Apple ships `MLNAltitudeForZoomLevel` / `MLNZoomLevelForAltitude`, MLNGeometry.h:235/247, precisely because the two models differ).
4. **`center` vs `centerCoordinate` vs `target`.** → **`center`** (gl-js + mbgl); we already use it.
5. **`LatLngBounds` vs `LngLatBounds` vs `MLNCoordinateBounds`.** gl-js says `LngLatBounds`; mbgl (geo.hpp:82) and Android say `LatLngBounds`. → **`LatLngBounds`**, deliberately *against* gl-js, because our point type is already `LatLng(lat, lng)` and CLAUDE.md §11 names lat/lng order the #1 source of web bugs. Constructor takes named `southwest:`/`northeast:` — mbgl's accessors (`southwest()`, `northeast()`, geo.hpp:124-125) and Apple's `MLNCoordinateBoundsMake(sw, ne)` (MLNGeometry.h:100) agree on that corner pair; gl-js's `[[w,s],[e,n]]` array form is not copied.
6. **`padding` vs `contentInset`/`edgePadding` vs `contentPadding`.** gl-js has ONE padding (`setPadding(PaddingOptions)`); Apple has **two** and the split is genuinely useful: persistent `contentInset` (MLNMapView.h:1610), transient per-call `edgePadding:` (MLNMapView.h:1394/1468/1203), and a read-only accumulation `cameraEdgeInsets` (MLNMapView.h:1623). → **Adopt Apple's split**, with gl-js's word: persistent becomes the widget prop `MapLibreMap.padding` (bucket 2 — mutable, declarative, low-frequency), transient becomes the `padding:` argument on `CameraOptions`/`fitBounds`, and `camera.getPadding()` returns the accumulation. mbgl backs both: `CameraOptions::padding` (camera.hpp:65) and `TransformState::setEdgeInsets`.
7. **`anchor` vs `around`.** gl-js calls the zoom/rotate pivot `around`; mbgl calls it `anchor` (camera.hpp:69) and **so does every line of our existing code** (`MapLibreGestureHandler.scaleBy(…, anchorX, anchorY)`, `mbl_map_rotate_by(…, anchor_x, anchor_y)`, and the long anchor-convention comment at maplibre_flutter_core.h:85-91). → **`anchor`**, against gl-js, for internal consistency. This is a rename to document loudly in the dartdoc.
8. **`maxBounds` — same word, DIFFERENT semantics.** gl-js `setMaxBounds` constrains what is *visible*. mbgl's `BoundOptions::bounds` constrains the camera **centre** unless `ConstrainMode::Screen` is set (bound_options.hpp:41-43, mode.hpp:24-29) — which is Android's `setLatLngBoundsForCameraTarget` semantics. Apple exposes the screen flavour as `maximumScreenBounds` (MLNMapView.h:1069). → Keep the gl-js **name** `maxBounds` and the gl-js **semantics**, implemented as `setBounds(BoundOptions().withLatLngBounds(b))` **plus** `setConstrainMode(ConstrainMode::Screen)`. Getting this wrong silently ships Android semantics under a gl-js name.
9. **`flyTo` apex zoom.** gl-js calls it `minZoom` (FlyToOptions), mbgl calls it `AnimationOptions::minZoom` (camera.hpp:115), Apple calls it `peakAltitude:` (MLNMapView.h:1446). → **renamed `apexZoom`**, against all three, because `minZoom` already means a hard constraint in the same Dart namespace (`camera.setMinZoom`) and the collision would be a permanent footgun. Documented as "gl-js `flyTo({minZoom})`".
10. **Camera-change notification.** gl-js fires 12+ discrete DOM-ish events (`movestart`/`move`/`moveend`, `zoom*`, `rotate*`, `pitch*`, `drag*`, `idle`); Apple has three delegate methods carrying an `MLNCameraChangeReason` bitmask (MLNMapViewDelegate.h:111/152/183, MLNCameraChangeReason.h:30); Android has three listeners plus `REASON_*` ints. → **Flutter-idiom adaptation, stated explicitly**: one `Stream<MapCameraEvent>` on `controller.camera`, where `MapCameraEvent` carries `phase` (`start`/`changing`/`end`/`idle`), `reason` (a Dart enum modelled on `MLNCameraChangeReason`), and the `MapCamera`. `on('moveend')` becomes `events.where((e) => e.phase == CameraPhase.end)`. The existing `controller.onCameraChanged` `Listenable` stays exactly as it is — it is the cheap per-frame overlay hook and must not become a Stream.
11. **Completion callbacks.** Apple passes `completionHandler:` blocks, Android passes `CancelableCallback`, gl-js gives you `moveend`. → **Flutter idiom: the returned `Future<void>` completes when the transition finishes or is superseded.** Backed by `AnimationOptions::transitionFinishFn` (camera.hpp:127), which is a real mbgl facility we are not using.
12. **`project`/`unproject` placement.** gl-js puts them flat on `Map`; Android groups them on `MapLibreMap.getProjection()`; Apple has both (`-convertCoordinate:toPointToView:`, MLNMapView.h:1712) and a standalone `MLNMapProjection` (MLNMapProjection.h:12). → gl-js **names** (`project`/`unproject`), Android/Apple **shape**: a `controller.projection` namespace, because the surface is 6+ members (project, unproject, batch, metersPerPixelAtLatitude, visibleRegion, bounds↔rect) and CLAUDE.md §3 says group a large surface into a namespace.
13. **Value types reused from Flutter, not reinvented**: gl-js `PaddingOptions` → **`EdgeInsets`**; gl-js `Point` / Apple `CGPoint` / Android `PointF` → **`Offset`**; gl-js `easing` function / Apple `CAMediaTimingFunction` / mbgl `UnitBezier` (camera.hpp:118) → **`Curve`** (a `Cubic` maps 1:1 onto `UnitBezier`); Android `durationMs` / Apple `NSTimeInterval` → **`Duration`**. Stated because a `PaddingOptions` class would be un-Dartlike and would not compose with `MediaQuery.padding`.
14. **`isEasing()` is NOT proposed.** The maintainer's brief lists it, but the maplibre-gl-js Map docs do not define it (that is a Mapbox GL JS method). No row invented for it.

#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | CameraOptions — a PARTIAL camera (every field nullable) | none | `CameraOptions {center?, zoom?, bearing?, pitch?, roll?, around?, padding?, elevation?}` consumed by `jumpTo/easeTo/flyTo` | `MLNMapCamera` (MLNMapCamera.h:21) — NOT partial; Apple instead ships per-property setters (`setZoomLevel:animated:`, MLNMapView.h:1039) | `mbgl::CameraOptions` — all `std::optional` (map/camera.hpp:19-87) | value-type | yes |
| P0 | LatLngBounds value type | none | `new LngLatBounds(sw, ne)`, `map.getBounds(): LngLatBounds` | `MLNCoordinateBounds {sw, ne}` (MLNGeometry.h:72) + `MLNCoordinateBoundsMake` (MLNGeometry.h:100) | `mbgl::LatLngBounds` (util/geo.hpp:82), with `world()` :85, `hull()` :91, `extend()` :135, `contains()` :150, `crossesAntimeridian()` :147 | value-type | no |
| P0 | `easeTo` (constant-zoom eased transition) | partial | `map.easeTo(options: EaseToOptions, eventData?)` | `-setCamera:withDuration:animationTimingFunction:completionHandler:` (MLNMapView.h:1369) | `Map::easeTo(const CameraOptions&, const AnimationOptions&)` (map.hpp:74) | controller | yes |
| P0 | `fitBounds` | none | `map.fitBounds(bounds: LngLatBoundsLike, options?: FitBoundsOptions, eventData?)`; `FitBoundsOptions {linear?: boolean = false, maxZoom?: number, offset?: PointLike = [0,0]}` extending FlyToOptions | `-setVisibleCoordinateBounds:edgePadding:animated:completionHandler:` (MLNMapView.h:1202); property form `visibleCoordinateBounds` (MLNMapView.h:1145) | `Map::cameraForLatLngBounds(const LatLngBounds&, const EdgeInsets&, bearing?, pitch?)` (map.hpp:80) then `easeTo`/`flyTo` | controller | yes |
| P0 | `flyTo` (van-Wijk flight) | partial | `map.flyTo(options: FlyToOptions, eventData?)` | `-flyToCamera:withDuration:peakAltitude:completionHandler:` (MLNMapView.h:1446); `-flyToCamera:edgePadding:withDuration:completionHandler:` (MLNMapView.h:1467) | `Map::flyTo(const CameraOptions&, const AnimationOptions&)` (map.hpp:75) | controller | yes |
| P0 | `project` (LatLng → screen point), app-facing | internal-only | `map.project(lngLat: LngLatLike): Point` | `-convertCoordinate:toPointToView:` (MLNMapView.h:1712); also `MLNMapProjection.convertCoordinate:` (MLNMapProjection.h:66) | `Map::pixelForLatLng(const LatLng&)` (map.hpp:119); our shim `mbl_map_pixel_for_lat_lng` (core.h:136) | controller-namespace | no |
| P0 | `unproject` (screen point → LatLng), app-facing | internal-only | `map.unproject(point: PointLike): LngLat` | `-convertPoint:toCoordinateFromView:` (MLNMapView.h:1695); `MLNMapProjection.convertPoint:` (MLNMapProjection.h:57) | `Map::latLngForPixel(const ScreenCoordinate&)` (map.hpp:120); shim `mbl_map_lat_lng_for_pixel` (core.h:157) | controller-namespace | no |
| P1 | Animation completion / cancellation callback | partial | — (you listen for `moveend`) | `completionHandler:` blocks on `-setCamera:…:completionHandler:` (MLNMapView.h:1372), `-flyToCamera:…completionHandler:` (:1449), `-setVisibleCoordinateBounds:…completionHandler:` (:1205) | `AnimationOptions::transitionFinishFn` and `transitionFrameFn` (map/camera.hpp:120-127) | controller | yes |
| P1 | Camera change events with phase + reason | partial | `map.on('movestart'\|'move'\|'moveend'\|'zoomstart'\|'zoom'\|'zoomend'\|'rotatestart'\|'rotate'\|'rotateend'\|'pitchstart'\|'pitch'\|'pitchend'\|'dragstart'\|'drag'\|'dragend', handler)` | `-mapView:regionWillChangeWithReason:animated:` (MLNMapViewDelegate.h:111), `-mapView:regionIsChangingWithReason:` (:152), `-mapView:regionDidChangeWithReason:animated:` (:183), reasons in MLNCameraChangeReason.h:30-65 | `MapObserver::onCameraWillChange(CameraChangeMode)` / `onCameraIsChanging()` / `onCameraDidChange(CameraChangeMode)` (map/map_observer.hpp:54-56) | controller | yes |
| P1 | Camera constraints as a declarative widget property | none | gl-js `MapOptions {minZoom, maxZoom, minPitch, maxPitch, maxBounds}` at construction, plus runtime setters *(unverified)* | mutable properties on `MLNMapView` (MLNMapView.h:1053/1064/1107/1118/1069) | `Map::setBounds(const BoundOptions&)` (map.hpp:98) | widget-prop | yes |
| P1 | DEFECT — `getCamera()` reports the REQUESTED camera, not the applied one | partial | `map.getZoom()` always returns the clamped value | `zoomLevel` (MLNMapView.h:1026) reflects the applied, clamped value | `Map::getCameraOptions()` (map.hpp:72) is the truth; the clamp lives in `Transform` (MIN/MAX_ZOOM constants.hpp:42-43, DEFAULT_PITCH_MAX :35) | capability-interface | no |
| P1 | MapCameraConstraints value type (min/max zoom, min/max pitch, maxBounds) | none | five independent setter/getter pairs: `setMinZoom/getMinZoom`, `setMaxZoom/getMaxZoom`, `setMinPitch/getMinPitch`, `setMaxPitch/getMaxPitch`, `setMaxBounds/getMaxBounds` | five independent properties: `minimumZoomLevel` (MLNMapView.h:1053), `maximumZoomLevel` (:1064), `minimumPitch` (:1107), `maximumPitch` (:1118), `maximumScreenBounds` (:1069) | ONE struct: `mbgl::BoundOptions {bounds, maxZoom, minZoom, maxPitch, minPitch}` (map/bound_options.hpp:13-56), applied by `Map::setBounds` (map.hpp:98) and read by `Map::getBounds()` (map.hpp:101) | value-type | yes |
| P1 | Persistent viewport padding (Apple `contentInset`) | none | `map.setPadding(padding: PaddingOptions)` / `map.getPadding(): PaddingOptions` | `@property UIEdgeInsets contentInset` (MLNMapView.h:1610), `-setContentInset:animated:completionHandler:` (MLNMapView.h:1678), `automaticallyAdjustsContentInset` (MLNMapView.h:315) | `CameraOptions::padding` (map/camera.hpp:65); `TransformState::setEdgeInsets` (src/mbgl/map/transform_state.hpp:161) | widget-prop | yes |
| P1 | Transient per-call padding on camera moves (`edgePadding:`) | none | `padding` on `CameraOptions`/`FitBoundsOptions`, i.e. on every camera method | `-setCamera:withDuration:animationTimingFunction:edgePadding:completionHandler:` (MLNMapView.h:1391), `-flyToCamera:edgePadding:withDuration:completionHandler:` (MLNMapView.h:1467), `-setVisibleCoordinateBounds:edgePadding:animated:completionHandler:` (MLNMapView.h:1202); accumulation exposed read-only as `cameraEdgeInsets` (MLNMapView.h:1623) | `CameraOptions::padding` (map/camera.hpp:65); `Map::cameraForLatLngBounds(bounds, EdgeInsets, ...)` (map.hpp:80) | value-type | yes |
| P1 | `MapLibreCameraCommands` — the platform-interface capability that carries all of the above | none | — (no federated split) | — (n/a) | the whole camera section of map.hpp:71-102 | capability-interface | yes |
| P1 | `cameraForBounds` (compute without moving) | none | `map.cameraForBounds(bounds: LngLatBoundsLike, options?: CameraForBoundsOptions): CenterZoomBearing` | `-cameraThatFitsCoordinateBounds:edgePadding:` (MLNMapView.h:1502); also `-camera:fittingCoordinateBounds:edgePadding:` (MLNMapView.h:1524), which preserves an existing camera's pitch/direction | `Map::cameraForLatLngBounds` (map.hpp:80) | controller | yes |
| P1 | `getBearing` / `setBearing` | partial | `map.getBearing(): number` / `map.setBearing(bearing: number, eventData?)` | `@property CLLocationDirection direction` (MLNMapView.h:1081), `-setDirection:animated:` (MLNMapView.h:1095) | `CameraOptions::bearing` — "measured in degrees from true north. Wrapped to [0, 360)" (map/camera.hpp:76) | controller | yes |
| P1 | `getBounds` — the currently visible bounds | none | `map.getBounds(): LngLatBounds` | `@property MLNCoordinateBounds visibleCoordinateBounds` (MLNMapView.h:1145); `-convertRect:toCoordinateBoundsFromView:` (MLNMapView.h:1727) | `Map::latLngBoundsForCamera(const CameraOptions&)` (map.hpp:92) and `latLngBoundsForCameraUnwrapped` (map.hpp:93) | controller | yes |
| P1 | `getPitch` / `setPitch` | partial | `map.getPitch(): number` / `map.setPitch(pitch: number, eventData?)` | `MLNMapCamera.pitch` (MLNMapCamera.h:36) | `CameraOptions::pitch` (map/camera.hpp:80); clamped to `DEFAULT_PITCH_MAX` = 60° (util/constants.hpp:35) | controller | yes |
| P1 | `getZoom` / `setZoom` | partial | `map.getZoom(): number` / `map.setZoom(zoom: number, eventData?)` | `@property double zoomLevel` (MLNMapView.h:1026), `-setZoomLevel:animated:` (MLNMapView.h:1039) | `CameraOptions::zoom` (map/camera.hpp:73) | controller | yes |
| P1 | `jumpTo` (instant, partial camera) | partial | `map.jumpTo(options: JumpToOptions, eventData?)` | `-setCamera:animated:` with `NO` (MLNMapView.h:1332) | `Map::jumpTo(const CameraOptions&)` (map.hpp:73) | controller | yes |
| P1 | `panBy` (pan by a screen-space offset) | internal-only | `map.panBy(offset: PointLike, options?: AnimationOptions, eventData?)` | — (no public pan-by-pixels) | `Map::moveBy(const ScreenCoordinate&, const AnimationOptions& = {})` (map.hpp:76) | controller | no |
| P1 | `setCenter` | partial | `map.setCenter(lngLat: LngLatLike)` | `-setCenterCoordinate:animated:` (MLNMapView.h:951); also `-setCenterCoordinate:zoomLevel:direction:animated:completionHandler:` (MLNMapView.h:1009) | `Map::jumpTo(CameraOptions().withCenter(...))` (map.hpp:73) | controller | yes |
| P1 | `setMaxBounds` (constrain panning) | none | `map.setMaxBounds(bounds: LngLatBoundsLike \| null)` | `@property MLNCoordinateBounds maximumScreenBounds` (MLNMapView.h:1069) — "maximum bounds of the map that can be shown on screen" | `Map::setBounds(BoundOptions().withLatLngBounds(b))` (map.hpp:98); `BoundOptions::bounds` (bound_options.hpp:43) + `Map::setConstrainMode(ConstrainMode::Screen)` (map.hpp:107, mode.hpp:24-29) | widget-prop | yes |
| P1 | `setMaxZoom` / `getMaxZoom` | none | `map.setMaxZoom(maxZoom: number)` / `map.getMaxZoom(): number` | `@property double maximumZoomLevel` (MLNMapView.h:1064) — default 22, upper bound 25.5 | `BoundOptions::maxZoom` (map/bound_options.hpp:46); ceiling `util::MAX_ZOOM = 25.5`, `DEFAULT_MAX_ZOOM = 22` (constants.hpp:43,46) | widget-prop | yes |
| P1 | `setMinZoom` / `getMinZoom` | none | `map.setMinZoom(minZoom: number)` / `map.getMinZoom(): number` | `@property double minimumZoomLevel` (MLNMapView.h:1053) — default 0 | `BoundOptions::minZoom` (map/bound_options.hpp:49); floor `util::MIN_ZOOM = 0.0` (constants.hpp:42) | widget-prop | yes |
| P1 | `stop()` — cancel a running camera transition | none | `map.stop(): this` | — (issuing a new `-setCamera:` cancels; no explicit stop) | `Map::cancelTransitions()` (map.hpp:64) | controller | yes |
| P1 | `zoomIn` / `zoomOut` | none | `map.zoomIn(options?, eventData?)` / `map.zoomOut(options?, eventData?)` (± 1 zoom level) | — (no method; the double-tap gesture does it) | `Map::scaleBy(2.0, anchor)` / `scaleBy(0.5, anchor)` (map.hpp:77) | controller | no |
| P2 | Batch project / unproject | internal-only | — (no batch API) | — | `Map::pixelsForLatLngs(const std::vector<LatLng>&)` (map.hpp:121), `latLngsForPixels` (map.hpp:122) | controller-namespace | no |
| P2 | Caller-supplied easing curve | partial | `easing?: (t: number) => number` on `AnimationOptions` | `animationTimingFunction:(CAMediaTimingFunction *)` (MLNMapView.h:1351/1371/1393) | `AnimationOptions::easing` — `std::optional<mbgl::util::UnitBezier>` (map/camera.hpp:118) | controller | yes |
| P2 | Visible region as a quad (pitched view) | none | — (gl-js gives only the bbox from `getBounds`) | — (`-convertRect:toCoordinateBoundsFromView:` gives a bbox, MLNMapView.h:1727) | composable from four `latLngForPixel` calls (map.hpp:120) on the existing transform snapshot | controller-namespace | no |
| P2 | `MapCamera` gains `padding`, `roll` | partial | `getRoll()` / `setRoll(roll)`; `getPadding()` | `MLNMapCamera.roll` (MLNMapCamera.h:30) | `CameraOptions::roll` (map/camera.hpp:83), `CameraOptions::padding` (:65) | value-type | yes |
| P2 | `camera.getPosition()` — read the camera | present | — (gl-js has no aggregate getter; you call getCenter/getZoom/getBearing/getPitch) | `@property (copy) MLNMapCamera *camera` (MLNMapView.h:1317) | `Map::getCameraOptions(const std::optional<EdgeInsets>&)` (map.hpp:72) | controller | no |
| P2 | `camera.move(MapCamera, {Duration?})` — the current entry point | present | — (no single equivalent; it is jumpTo-or-flyTo depending on the duration) | `-setCamera:animated:` (MLNMapView.h:1332) | `Map::jumpTo` (map.hpp:73) via `mbl_map_set_camera` (core.h:60) | controller | no |
| P2 | `cameraForLatLngs` / fit a set of points | none | — (you build a LngLatBounds yourself) | `-setVisibleCoordinates:count:edgePadding:animated:` (MLNMapView.h:1224); with direction/duration/timing at MLNMapView.h:1250 | `Map::cameraForLatLngs(const std::vector<LatLng>&, const EdgeInsets&, bearing?, pitch?)` (map.hpp:84) | controller | yes |
| P2 | `getCenter` | partial | `map.getCenter(): LngLat` | `@property CLLocationCoordinate2D centerCoordinate` (MLNMapView.h:934) | `Map::getCameraOptions().center` (map.hpp:72) | controller | no |
| P2 | `getMaxBounds` | none | `map.getMaxBounds(): LngLatBounds` | `maximumScreenBounds` getter (MLNMapView.h:1069) | `Map::getBounds(): BoundOptions` — "All optional fields in BoundOptions are set" (map.hpp:101) | controller | yes |
| P2 | `idle` event / did-become-idle | none | `map.on('idle', handler)` | `-mapViewDidBecomeIdle:` (MLNMapViewDelegate.h:299) | `MapObserver::onDidBecomeIdle()` (map/map_observer.hpp:66) | controller | yes |
| P2 | `isMoving` / `isZooming` / `isRotating` | none | `map.isMoving(): boolean`, `map.isZooming(): boolean`, `map.isRotating(): boolean` | — (inferred from `regionWillChange`/`regionDidChange` delegate pairs, MLNMapViewDelegate.h:95/165) | `Map::isRotating()`, `Map::isScaling()`, `Map::isPanning()`, `Map::isGestureInProgress()` (map.hpp:66-69) | controller | yes |
| P2 | `metersPerPixelAtLatitude` / scale bar support | none | — (no direct equivalent) | `-metersPerPointAtLatitude:` (MLNMapView.h:1758); `MLNMapProjection.metersPerPoint` (MLNMapProjection.h:71); a whole `MLNScaleBar` (MLNMapView.h:337) | `Projection::getMetersPerPixelAtLatitude(lat, zoom)` — a pure static (util/projection.hpp:47-53) | controller-namespace | no |
| P2 | `panTo` (animate the centre to a point) | none | `map.panTo(lngLat: LngLatLike, options?: AnimationOptions, eventData?)` | `-setCenterCoordinate:animated:` (MLNMapView.h:951) | `Map::easeTo(CameraOptions().withCenter(...), AnimationOptions(d))` (map.hpp:74) | controller | no |
| P2 | `resetNorth` | none | `map.resetNorth(options?: AnimationOptions, eventData?)` | `- (IBAction)resetNorth;` (MLNMapView.h:1123) | `Map::easeTo(CameraOptions().withBearing(0), …)` (map.hpp:74) | controller | no |
| P2 | `rotateTo` (animate to an absolute bearing) | none | `map.rotateTo(bearing: number, options?: AnimationOptions, eventData?)` | `-setDirection:animated:` (MLNMapView.h:1095) | `Map::easeTo(CameraOptions().withBearing(b).withAnchor(a), …)` (map.hpp:74) | controller | no |
| P2 | `setConstrainMode` | none | — (implicit in `maxBounds`) | — (implied by `maximumScreenBounds`, MLNMapView.h:1069) | `Map::setConstrainMode(ConstrainMode)` (map.hpp:107); `enum class ConstrainMode {None, HeightOnly, WidthAndHeight, Screen}` (map/mode.hpp:24-29) | reject | yes |
| P2 | `setGestureInProgress` — bracket a gesture for the engine | none | — (gl-js owns its own handlers) | — (internal to `MLNMapView`'s gesture recognizers) | `Map::setGestureInProgress(bool)` / `Map::isGestureInProgress()` (map.hpp:65-66) | capability-interface | yes |
| P2 | `setMaxPitch` / `getMaxPitch` | none | `map.setMaxPitch(maxPitch: number)` / `map.getMaxPitch(): number` (gl-js allows up to 85°) | `@property CGFloat maximumPitch` (MLNMapView.h:1118) — "may not exceed 60 degrees regardless of this property" | `BoundOptions::maxPitch` (map/bound_options.hpp:52); hard ceiling `util::DEFAULT_PITCH_MAX = M_PI/3` = 60° (constants.hpp:35) | widget-prop | yes |
| P2 | `setMinPitch` / `getMinPitch` | none | `map.setMinPitch(minPitch: number)` / `map.getMinPitch(): number` | `@property CGFloat minimumPitch` (MLNMapView.h:1107) — default 0 | `BoundOptions::minPitch` (map/bound_options.hpp:55) | widget-prop | yes |
| P2 | `zoomBy` / `scaleBy` (relative zoom about an anchor) | internal-only | — (no `zoomBy`; gl-js expresses it as `zoomTo(getZoom()+d, {around})`) | — (gesture-internal) | `Map::scaleBy(double scale, const std::optional<ScreenCoordinate>& anchor, …)` (map.hpp:77) | controller | no |
| P2 | `zoomTo` (animate to an absolute zoom) | none | `map.zoomTo(zoom: number, options?: AnimationOptions, eventData?)` | `-setZoomLevel:animated:` (MLNMapView.h:1039) | `Map::easeTo(CameraOptions().withZoom(z).withAnchor(a), …)` (map.hpp:74) | controller | no |
| P3 | Bounds ⇄ screen rect conversion | none | — | `-convertRect:toCoordinateBoundsFromView:` (MLNMapView.h:1727); `-convertCoordinateBounds:toRectToView:` (MLNMapView.h:1744) | composable from `pixelForLatLng` / `latLngForPixel` (map.hpp:119-120) | controller-namespace | no |
| P3 | Off-map projection object (project against a hypothetical camera) | none | — | `MLNMapProjection` (MLNMapProjection.h:12) — `-initWithMapView:`, `-setCamera:withEdgeInsets:` (:37), `-setVisibleCoordinateBounds:edgePadding:` (:48), `-convertPoint:` (:57), `-convertCoordinate:` (:66) | `mbgl::MapProjection` (map/map_projection.hpp:12-28) — `setCamera`, `getCamera`, `setVisibleCoordinates(points, EdgeInsets)`, `pixelForLatLng`, `latLngForPixel` | value-type | yes |
| P3 | Tile LOD tuning (pitch-driven detail falloff) | none | — | `tileLodMinRadius` (MLNMapView.h:502), `tileLodScale` (:512), `tileLodPitchThreshold` (:520), `tileLodZoomShift` (:533) | `Map::setTileLodMinRadius/Scale/PitchThreshold/ZoomShift/Mode` (map.hpp:197-206); `TileLodMode` (map/mode.hpp:38-41) | widget-prop | yes |
| P3 | `FreeCameraOptions` (direct 3D camera control) | none | — (maplibre-gl-js's Map does not expose getFreeCameraOptions/setFreeCameraOptions; that is Mapbox GL JS) | — | `Map::setFreeCameraOptions(const FreeCameraOptions&)` / `getFreeCameraOptions()` (map.hpp:163-164); `FreeCameraOptions {position, orientation, setLocation, getLocation, lookAtPoint, setRollPitchBearing}` (map/camera.hpp:141-178) | controller | yes |
| P3 | `MLNMapCamera` altitude / viewingDistance model | none | — (zoom-based) | `MLNMapCamera.altitude` (MLNMapCamera.h:49), `.viewingDistance` (:57); conversions `MLNAltitudeForZoomLevel` (MLNGeometry.h:235) / `MLNZoomLevelForAltitude` (:247) | zoom-based; the conversion is `Projection::getMetersPerPixelAtLatitude` (util/projection.hpp:47) plus trigonometry | reject | no |
| P3 | `MapCamera` gains `centerAltitude` / camera elevation | none | `getCenterElevation(): number` / `setCenterElevation(elevation: number)` | `MLNMapCamera.altitude` (MLNMapCamera.h:49) — a different quantity (eye altitude, not centre elevation) | `CameraOptions::centerAltitude` — "Altitude of the center of the map, in meters above sea level" (map/camera.hpp:61) | value-type | yes |
| P3 | `MapOptions.initialCamera` | present | gl-js `MapOptions {center, zoom, bearing, pitch}` at construction *(unverified)* | `-initWithFrame:options:` + `MLNMapOptions` (MLNMapView.h:232, MLNMapOptions.h:12) — note Apple's `MLNMapOptions` carries only style/journal/plugins, NOT a camera | applied as the first `jumpTo` (map.hpp:73) | widget-init | no |
| P3 | `anchorRotateOrZoomGesturesToCenterCoordinate` | none | `around: 'center'` on the touchZoomRotate/scrollZoom handler options *(unverified)* | `@property BOOL anchorRotateOrZoomGesturesToCenterCoordinate` (MLNMapView.h:896) | the anchor argument itself — `Map::scaleBy(scale, anchor)` (map.hpp:77) | widget-prop | no |
| P3 | `animate` / `essential` flags (reduced motion) | none | `animate?: boolean`, `essential?: boolean` on `AnimationOptions` | — (`animated:` BOOL is the same idea, MLNMapView.h:1332) | expressible: pass `AnimationOptions{}` with no duration, i.e. `jumpTo` | controller | no |
| P3 | `cameraForGeometry` / fit a shape | none | — | `-camera:fittingShape:edgePadding:` (MLNMapView.h:1545); `-cameraThatFitsShape:direction:edgePadding:` (MLNMapView.h:1566) | `Map::cameraForGeometry(const Geometry<double>&, const EdgeInsets&, bearing?, pitch?)` (map.hpp:88) | controller | yes |
| P3 | `fitScreenCoordinates` | none | `map.fitScreenCoordinates(p0: PointLike, p1: PointLike, bearing: number, options?: FitBoundsOptions, eventData?)` | — | no direct primitive, but composable: `latLngForPixel` ×2 (map.hpp:120) → `cameraForLatLngs` (map.hpp:84) | controller | no |
| P3 | `getRoll` / `setRoll` | none | `map.getRoll(): number` / `map.setRoll(roll: number, eventData?)` | `MLNMapCamera.roll` (MLNMapCamera.h:30) | `CameraOptions::roll` (map/camera.hpp:83), `FreeCameraOptions::setRollPitchBearing` (map/camera.hpp:177) | controller | yes |
| P3 | `queryTerrainElevation` | none | `map.queryTerrainElevation(lngLat: LngLatLike): number` | — | NOT IN CORE — no elevation query anywhere in `include/mbgl/map/map.hpp` | reject | no |
| P3 | `resetNorthPitch` | none | `map.resetNorthPitch(options?: AnimationOptions, eventData?)` | — (Apple has `-resetPosition` (MLNMapView.h:1131), which is a different thing: reset to the STYLE's default viewport) | `Map::easeTo(CameraOptions().withBearing(0).withPitch(0), …)` (map.hpp:74) | controller | no |
| P3 | `resetPosition` — return to the style's default camera | none | — (gl-js applies the style default at load if no camera was given, but exposes no reset) | `- (IBAction)resetPosition;` (MLNMapView.h:1131) — "Resets the map to the current style's default viewport" | `style::Style::getDefaultCamera(): CameraOptions` (style/style.hpp:37) | controller | yes |
| P3 | `setCenterClampedToGround` / `getCenterClampedToGround` | none | `map.setCenterClampedToGround(clamped: boolean)` / `map.getCenterClampedToGround(): boolean` | — | NOT IN CORE | reject | no |
| P3 | `setNorthOrientation` | none | — | — (not on iOS `MLNMapView`) | `Map::setNorthOrientation(NorthOrientation)` (map.hpp:106); `enum class NorthOrientation {Upwards, Rightwards, Downwards, Leftwards}` (util/geo.hpp:175-180) | widget-prop | yes |
| P3 | `setProjectionMode` / `getProjectionMode` (axonometric) | none | — (gl-js `setProjection` is about globe/mercator, a DIFFERENT thing) | — | `Map::setProjectionMode(const ProjectionMode&)` / `getProjectionMode()` (map.hpp:115-116); `ProjectionMode {axonometric, xSkew, ySkew}` (map/projection_mode.hpp:12-40) | controller | yes |
| P3 | `setVerticalFieldOfView` / `getVerticalFieldOfView` | none | `map.getVerticalFieldOfView(): number` / `map.setVerticalFieldOfView(fov: number)` | — | `CameraOptions::fov` — "Camera vertical field of view, measured in degrees" (map/camera.hpp:86), with a `withFov` builder (:52) | controller | yes |
| P3 | `setViewportMode` (FlippedY) | none | — | — | `Map::setViewportMode(ViewportMode)` (map.hpp:108); `enum class ViewportMode {Default, FlippedY}` (map/mode.hpp:33-36) | reject | no |
| P3 | `shouldChangeFromCamera` — veto a camera change | none | — | `-mapView:shouldChangeFromCamera:toCamera:` (MLNMapViewDelegate.h:52) and `…toCamera:reason:` (:82) | not in core — but implementable in Dart, since our gesture layer owns every camera command | widget-callback | no |
| P3 | `snapToNorth` (snap bearing to 0 within a tolerance) | none | `map.snapToNorth(options?: AnimationOptions, eventData?)`; the threshold is the `bearingSnap` map option | `@property CGFloat toleranceForSnappingToNorth` (MLNMapView.h:875) — Apple exposes the TOLERANCE, applied automatically by the rotate gesture, not a method | pure Dart over `setBearing(0)` | controller | no |
| P3 | flyTo `curve` / `screenSpeed` / `maxDuration` | none | `curve?: number` (default 1.42), `screenSpeed?: number`, `maxDuration?: number` on `FlyToOptions` | — | NOT IN CORE — `AnimationOptions` (map/camera.hpp:102-135) has only duration/velocity/minZoom/easing/transitionFrameFn/transitionFinishFn | reject | no |
| P3 | flyTo `speed` (velocity in screenfuls/second) | none | `speed?: number` on `FlyToOptions`, default 1.2 | — (duration only, MLNMapView.h:1424) | `AnimationOptions::velocity` — "Average velocity of a flyTo() transition, measured in screenfuls per second" (map/camera.hpp:106-111) | controller | yes |
| P3 | flyTo apex zoom (gl-js `minZoom`, Apple `peakAltitude`) | partial | `minZoom?: number` on `FlyToOptions` — "zoom level at the peak of the flight path" | `-flyToCamera:withDuration:peakAltitude:completionHandler:` (MLNMapView.h:1446) | `AnimationOptions::minZoom` — "Zero-based zoom level at the peak of the flyTo() transition's flight path" (map/camera.hpp:113-115) | controller | yes |
| P3 | gl-js `calculateCameraOptionsFromTo` / `…FromCameraLngLatAltRotation` | none | `map.calculateCameraOptionsFromTo(from: LngLat, altitudeFrom: number, to: LngLat, altitudeTo?: number): CameraOptions`; `map.calculateCameraOptionsFromCameraLngLatAltRotation(cameraLngLat, cameraAlt, bearing, pitch, roll?): CameraOptions` | `+[MLNMapCamera cameraLookingAtCenterCoordinate:fromEyeCoordinate:eyeAltitude:]` (MLNMapCamera.h:74) — the same idea | `FreeCameraOptions::lookAtPoint(location, upVector)` + `getLocation()` (map/camera.hpp:168-173) | value-type | yes |

#### Proposed signatures

**CameraOptions — a PARTIAL camera (every field nullable)** — P0, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/camera.dart:10 — `MapCamera` requires `center` and defaults zoom/bearing/pitch to 0, so there is no way to express "change only the zoom"
```dart
`@immutable class CameraOptions { const CameraOptions({this.center, this.zoom, this.bearing, this.pitch, this.roll, this.padding, this.anchor}); final LatLng? center; final double? zoom, bearing, pitch, roll; final EdgeInsets? padding; final Offset? anchor; }`
```
> Structural blocker: every gl-js camera verb below is a one-liner over this, and none of them can be written without it. Note the mbgl trap our own shim already documents (maplibre_flutter_core.cpp:1376-1379): `transform.cpp` reads `anchor = camera.center ? nullopt : camera.anchor`, so **setting `center` silently discards `anchor`** — the Dart type must document that, and `mbl_map_set_camera` (core.h:60) cannot be reused because it always sends centre. Needs a new `mbl_map_camera(map, flags, lat, lng, zoom, bearing, pitch, roll, pad_t/l/b/r, anchor_x, anchor_y, mode, duration_ms, ...)`-shaped entry point with a presence bitmask.

**LatLngBounds value type** — P0, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/lat_lng_bounds.dart (does not exist; lat_lng.dart:5 is the only geo type)
```dart
`@immutable class LatLngBounds { const LatLngBounds({required LatLng southwest, required LatLng northeast}); factory LatLngBounds.fromPoints(Iterable<LatLng> points); static const LatLngBounds world; LatLng get center; LatLng get southeast; LatLng get northwest; double get south, west, north, east; bool get isEmpty; bool get crossesAntimeridian; bool contains(LatLng p); bool intersects(LatLngBounds o); LatLngBounds extend(LatLng p); LatLngBounds extendBounds(LatLngBounds o); }`
```
> The single highest-leverage missing item in this domain: fitBounds, cameraForBounds, getBounds, setMaxBounds, getMaxBounds, cameraForLatLngs, visibleRegion and convertRect all need it and none can be written first. Pure Dart — no C ABI. Mirror mbgl's helper set (geo.hpp:85-153) rather than gl-js's array constructors; keep `LatLng` ordering and do NOT accept `[w,s,e,n]` arrays. Antimeridian: Apple's docs (MLNMapView.h:1140-1143) require longitudes outside ±180 to be preserved, so do NOT wrap in the constructor.

**`easeTo` (constant-zoom eased transition)** — P0, `controller`, evidence: packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:173-193 — steps `flyCameraAt` (fly_animation.dart:14) on a 33 ms `Future.delayed` loop
```dart
`Future<void> camera.easeTo(CameraOptions camera, {required Duration duration, Curve curve = Curves.easeInOut})`
```
> Real defect, not just a gap. `moveCamera(duration:)` is documented as an ease and implemented as `flyCameraAt` (fly_animation.dart:14-40), which deliberately dips the zoom toward a fit level. It is also driven from the UI isolate by `await Future.delayed(33ms)` — not vsync-aligned, not frame-paced, and it fights the frame budget. Fix by calling `Map::easeTo` with `AnimationOptions{duration, easing}`; `Curve` → `UnitBezier` (camera.hpp:118) is exact for any `Cubic`.

**`fitBounds`** — P0, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:311-313 (listed in the TODO); no LatLngBounds type exists to pass
```dart
`Future<void> camera.fitBounds(LatLngBounds bounds, {EdgeInsets padding = EdgeInsets.zero, double? maxZoom, double? bearing, double? pitch, Offset offset = Offset.zero, bool linear = false, Duration? duration, Curve curve = Curves.easeInOut})`
```
> Table stakes — "show me all my markers" is the second thing every map app does. gl-js's `linear` flag (easeTo vs flyTo) is worth copying verbatim; it is the only knob that decides which transition runs. Needs `mbl_map_camera_for_bounds(...)` + a camera-with-animation entry point.

**`flyTo` (van-Wijk flight)** — P0, `controller`, evidence: same Dart arc as easeTo — fly_animation.dart:14; macos_controller.dart:180-192
```dart
`Future<void> camera.flyTo(CameraOptions camera, {Duration? duration, double? speed, double? apexZoom, Curve? curve})`
```
> Same defect class as easeTo: a hand-rolled smoothstep arc with an approximate `_fitZoom` heuristic (fly_animation.dart:55-60) replaces mbgl's real flight-path math. `speed` → `AnimationOptions::velocity` (camera.hpp:111), `apexZoom` → `AnimationOptions::minZoom` (camera.hpp:115). `curve` / `screenSpeed` / `maxDuration` are NOT in mbgl — see the ceiling note.

**`project` (LatLng → screen point), app-facing** — P0, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/projector.dart:34 `project(...)`; the only way in is `MapLibreMapController.projector`, which is `@internal` (maplibre_flutter/lib/src/maplibre_map_controller.dart:193-194), and `MapLibreMapProjector` is NOT in the `maplibre_flutter` export list (maplibre_flutter/lib/maplibre_flutter.dart:7)
```dart
`Offset? controller.projection.project(LatLng point)` — synchronous, null before the first frame
```
> **Matrix drift:** FEATURE_MATRIX.md:524 ✅ macOS / 🧪 elsewhere — **DISAGREES with the code**. The capability exists and the marker overlay uses it, but there is no public app-facing API: the getter is `@internal` and the type is not exported. Should be 🟡 at best.

**`unproject` (screen point → LatLng), app-facing** — P0, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/projector.dart:39 `unproject(Offset)`; used by the widget's `onTap` (maplibre_map.dart:288) but not exposed to app code
```dart
`LatLng? controller.projection.unproject(Offset screenPoint)`
```
> **Matrix drift:** FEATURE_MATRIX.md:525 ✅ macOS / 🧪 elsewhere — same disagreement as `project`

**Animation completion / cancellation callback** — P1, `controller`, evidence: packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:173-193 — the returned `Future` completes when the Dart stepping loop ends, and completes silently when superseded by `_animToken`
```dart
every animated method returns `Future<void>` that completes when the transition finishes; supersession completes normally (not an error), and the `end` event carries `CameraChangeReason.transitionCancelled`
```
> Once the transition moves into mbgl, the Dart Future must be driven by `AnimationOptions::transitionFinishFn` (camera.hpp:127) or it will complete at the wrong time — today it completes because OUR loop ended, which happens to coincide. Do not throw on cancel: Android distinguishes onCancel/onFinish, but a throwing Future here would force try/catch around every camera call.

**Camera change events with phase + reason** — P1, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:75-82 `onCameraChanged` (a `Listenable`, ticked by `MapLibreCameraTickNotifier.notifyCameraChanged`, projector.dart:50-66) — no start/end, no reason, no camera payload
```dart
`Stream<MapCameraEvent> get camera.events;` with `class MapCameraEvent { final CameraPhase phase; /* start, changing, end, idle */ final Set<CameraChangeReason> reason; final MapCamera camera; }`
```
> **Flutter-idiom adaptation, deliberate:** one stream replaces gl-js's 15 string-keyed events, Apple's 3 delegate methods and Android's 4 listeners. `on('moveend')` becomes a `.where`. Keep `onCameraChanged` untouched — it is the per-frame overlay hook and must stay a cheap `Listenable`. The `reason` set is modelled on `MLNCameraChangeReason` (MLNCameraChangeReason.h:30) and must be synthesised in Dart at the gesture call sites, because mbgl only reports Immediate-vs-Animated (map_observer.hpp:37-40).

**Camera constraints as a declarative widget property** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:28-37 (constructor takes no constraints)
```dart
`MapLibreMap(constraints: MapCameraConstraints(minZoom: 4, maxBounds: bounds))` — pushed via `didUpdateWidget` to `MapLibreCameraCommands.setCameraConstraints(MapCameraConstraints)`
```
> Three-bucket rule places this squarely in bucket 2: mutable, declarative, low-frequency. Not `MapOptions` (init-only) because all three upstream SDKs allow runtime change. Reading stays imperative (`camera.getMinZoom()` etc., separate rows) because a read is a command, and because after clamping the ENGINE owns the value.

**DEFECT — `getCamera()` reports the REQUESTED camera, not the applied one** — P1, `capability-interface`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1267-1270 — `mbl_map_set_camera` writes `m->camera` on the CALLING thread before mbgl has clamped anything
```dart
no signature change; `mbl_map_get_camera` must serve the value read back from `Map::getCameraOptions()` after the jump lands, not the value that was posted
```
> Latent today (nothing clamps except mbgl's built-in limits), becomes a visible lie the moment `setMinZoom`/`setMaxZoom`/`maxBounds` land: `setZoom(30)` then `getZoom()` would return 30 while the map sits at 25.5. Fix before the constraints work, not after. Note the ordering constraint: the cache is deliberately written synchronously so `getCamera` right after `setCamera` is not stale — the fix is to write the POSTED value optimistically and overwrite from `getCameraOptions()` in `updateCameraCache`, which already runs on the render thread (maplibre_flutter_core.cpp:1277).

**MapCameraConstraints value type (min/max zoom, min/max pitch, maxBounds)** — P1, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/camera.dart (would live beside MapCamera)
```dart
`@immutable class MapCameraConstraints { const MapCameraConstraints({this.minZoom, this.maxZoom, this.minPitch, this.maxPitch, this.maxBounds}); final double? minZoom, maxZoom, minPitch, maxPitch; final LatLngBounds? maxBounds; }`
```
> Field NAMES from gl-js; the BUNDLE from mbgl, because `BoundOptions` is literally these five fields and one `mbl_map_set_bounds(...)` covers all of them. This is the value type behind the widget prop below. Deliberate divergence from gl-js's five setters: they would be five C ABI calls that all end at the same `Map::setBounds`.

**Persistent viewport padding (Apple `contentInset`)** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:28-37; `MapCamera` (camera.dart:10) has no padding field either
```dart
`MapLibreMap(padding: EdgeInsets.only(bottom: 240))` — pushed via `didUpdateWidget`
```
> The bottom-sheet / side-panel case: without it, `center` means the geometric centre of the texture, so a map half-covered by a sheet centres behind the sheet. Use Flutter's `EdgeInsets`, not a `PaddingOptions` class — it then composes with `MediaQuery.of(context).padding` for free, which is the whole point of Apple's `automaticallyAdjustsContentInset`. Widget prop (bucket 2), matching `style`/`markers`.

**Transient per-call padding on camera moves (`edgePadding:`)** — P1, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:28 (`moveCamera(MapCamera, {Duration?})` — no padding parameter)
```dart
`CameraOptions(padding: EdgeInsets)` and `camera.fitBounds(bounds, padding: EdgeInsets.all(48))`
```
> Apple's two-level model is the right one and gl-js has no equivalent: a `fitBounds` wants 48pt of breathing room for THAT call without permanently shifting the map centre. Keep `camera.getPadding()` returning the accumulated value (Apple's `cameraEdgeInsets`), not the widget prop.

**`MapLibreCameraCommands` — the platform-interface capability that carries all of the above** — P1, `capability-interface`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:13-43 — the base contract has only getCamera/moveCamera/setStyle/resize/dispose
```dart
`abstract interface class MapLibreCameraCommands { Future<void> setCamera(CameraOptions camera, {CameraTransition transition}); Future<void> stop(); Future<CameraOptions> cameraForBounds(LatLngBounds bounds, {EdgeInsets padding, double? bearing, double? pitch, double? maxZoom, Offset offset}); LatLngBounds? getBounds({bool unwrapped = false}); Future<void> setCameraConstraints(MapCameraConstraints constraints); Future<MapCameraConstraints> getCameraConstraints(); Stream<MapCameraEvent> get cameraEvents; }`
```
> **The one structural decision this domain needs.** Follow the `MapLibreRotateHandler` precedent (rotate_handler.dart:8-22): Dart's `implements` forces every member to be redeclared, so adding to the base `MapLibreMapPlatformController` is a hard compile break across six platform packages plus the widget test fakes. A feature-detected capability lands it incrementally, lets `maplibre_flutter_web_gljs` and the two opt-in SDK packages abstain, and matches how `MapLibreStyleLayers`/`MapLibreModelHost`/`MapLibreResizeMaskHint` already work. Note the counter-argument honestly: camera is not really optional, so a controller that abstains is a degraded map — mitigate by keeping `moveCamera` on the base and having `MapLibreCameraController` fall back to it when the capability is absent. ONE `setCamera(CameraOptions, {CameraTransition})` primitive (transition = jump | ease(duration, curve) | fly(duration, speed, apexZoom)) is enough to back every gl-js verb above, so the capability stays small and the app-facing namespace does the sugar — no interface churn per verb.

**`cameraForBounds` (compute without moving)** — P1, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:291-314
```dart
`Future<CameraOptions> camera.cameraForBounds(LatLngBounds bounds, {EdgeInsets padding = EdgeInsets.zero, double? bearing, double? pitch, double? maxZoom, Offset offset = Offset.zero})`
```
> Needed independently of fitBounds: apps compute the target to decide whether the move is worth making, or to blend it with their own camera. Apple's `-camera:fittingCoordinateBounds:` variant (honour an existing camera's pitch/bearing) is a good default — take bearing/pitch from the current camera when the arguments are null.

**`getBearing` / `setBearing`** — P1, `controller`, evidence: via getPosition/move — maplibre_flutter/lib/src/maplibre_map_controller.dart:297,308
```dart
`Future<double> camera.getBearing()` / `Future<void> camera.setBearing(double bearing, {Offset? anchor})`
```
> gl-js name, against Apple's `direction`. Sign warning to carry into the dartdoc: `bearing` is the compass direction that is UP, so it DECREASES as content turns clockwise — the opposite of `MapLibreRotateHandler.rotateBy` (rotate_handler.dart:28-34). That asymmetry already bit this codebase once; state it on both members.

**`getBounds` — the currently visible bounds** — P1, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:291-314; `MapLibreMapProjector` (projector.dart:24) can unproject corners but nothing composes them
```dart
`LatLngBounds? camera.getBounds()` — SYNCHRONOUS, computed from the same transform snapshot the projector uses; plus `LatLngBounds? camera.getBoundsUnwrapped()`
```
> Fetch-data-for-the-visible-area is the single most common reason apps hold a map controller. Make it synchronous like `project`/`unproject`: our shim already keeps a `mbgl::TransformState` snapshot under a light lock (maplibre_flutter_core.cpp:145, 588-593), so bounds can be derived without a render-thread round trip — the same trick that keeps markers glued. Expose BOTH the wrapped and unwrapped forms; mbgl distinguishes them (map.hpp:92/93) and the antimeridian case needs the unwrapped one.

**`getPitch` / `setPitch`** — P1, `controller`, evidence: via getPosition/move — maplibre_flutter/lib/src/maplibre_map_controller.dart:297,308
```dart
`Future<double> camera.getPitch()` / `Future<void> camera.setPitch(double pitch)`
```
> `pitch` beats Android's `tilt` 3-to-1. Dartdoc must state the 60° engine clamp (already stated at maplibre_flutter_core.h:103) so callers do not chase a silent clamp.

**`getZoom` / `setZoom`** — P1, `controller`, evidence: via getPosition/move — maplibre_flutter/lib/src/maplibre_map_controller.dart:297,308
```dart
`Future<double> camera.getZoom()` / `Future<void> camera.setZoom(double zoom, {Offset? anchor})`
```
> `anchor` added beyond gl-js's `setZoom` because mbgl supports it (camera.hpp:69) and zooming about a point is the common UI need. Remember the mbgl trap: setting `center` alongside `anchor` discards the anchor (documented at maplibre_flutter_core.cpp:1377) — `setZoom` must send zoom+anchor only.

**`jumpTo` (instant, partial camera)** — P1, `controller`, evidence: `camera.move(target)` with no duration — maplibre_flutter/lib/src/maplibre_map_controller.dart:308 → macos_controller.dart:176-179 → core.h:60 `mbl_map_set_camera` → `Map::jumpTo` (maplibre_flutter_core.cpp:1272)
```dart
`Future<void> camera.jumpTo(CameraOptions camera)`
```
> Rename/alias of today's `move(target)` once `CameraOptions` exists. Keep `move(MapCamera, {duration})` as a deprecated forwarder for one release rather than breaking apps.

**`panBy` (pan by a screen-space offset)** — P1, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/gesture_handler.dart:13 `moveBy(double dx, double dy)`; reachable only via `MapLibreMapController.gestureHandler`, which is `@internal` (maplibre_flutter/lib/src/maplibre_map_controller.dart:164-165)
```dart
`Future<void> camera.panBy(Offset offset, {Duration? duration, Curve curve = Curves.easeInOut})`
```
> C ABI already exists (`mbl_map_move_by`, core.h:76) — this is pure app-facing plumbing, the cheapest win in the domain. gl-js `PointLike` → Flutter `Offset`. Note the direction convention: gl-js `panBy` moves the MAP by the offset; make sure the sign matches `moveBy`'s (which pans content with the finger).

**`setCenter`** — P1, `controller`, evidence: only as `camera.move(current.copyWith(center: x))` after an await — maplibre_flutter/lib/src/maplibre_map_controller.dart:308
```dart
`Future<void> camera.setCenter(LatLng center)`
```
> gl-js semantics: an instant jump, no animation. Depends on the partial `CameraOptions` row — today sending a partial is impossible because `mbl_map_set_camera` (core.h:60) demands all five values.

**`setMaxBounds` (constrain panning)** — P1, `widget-prop`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart (no bounds member anywhere)
```dart
`MapLibreMap(constraints: MapCameraConstraints(maxBounds: b))`; clear with `maxBounds: null`
```
> **The semantic trap in this domain.** mbgl's `BoundOptions::bounds` constrains the camera CENTRE by default (bound_options.hpp:41-43) = Android's semantics; gl-js's `maxBounds` constrains what is VISIBLE = Apple's `maximumScreenBounds`. Shipping the former under the latter's name means users see grey beyond the edges. Choose gl-js semantics and set `ConstrainMode::Screen` alongside. Clearing is `LatLngBounds()`'s unbounded form (geo.hpp:109-112), not `world()` — mbgl documents the difference.

**`setMaxZoom` / `getMaxZoom`** — P1, `widget-prop`, evidence: —
```dart
set: `MapLibreMap(constraints: MapCameraConstraints(maxZoom: …))`; get: `Future<double> camera.getMaxZoom()`
```
> Document the 25.5 hard ceiling (constants.hpp:43) — Apple does, in the header, and users hit it with raster overlays.

**`setMinZoom` / `getMinZoom`** — P1, `widget-prop`, evidence: —
```dart
set: `MapLibreMap(constraints: MapCameraConstraints(minZoom: …))`; get: `Future<double> camera.getMinZoom()`
```
> Apple documents the aspect-ratio caveat (MLNMapView.h:1044-1046): the map may refuse to reach minZoom to avoid repeating the world in the viewport. Carry that into the dartdoc — it is a real "why did my setting not take" report waiting to happen.

**`stop()` — cancel a running camera transition** — P1, `controller`, evidence: packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:174 — `_animToken` supersession exists internally but nothing public cancels
```dart
`Future<void> camera.stop()`
```
> The "user grabbed the map mid-flyTo" case. Once `easeTo`/`flyTo` move into mbgl, `_animToken` no longer covers it — the engine owns the transition and only `cancelTransitions()` stops it. Must also fire the `end` camera event with a cancelled reason (Apple models this as `MLNCameraChangeReasonTransitionCancelled`, MLNCameraChangeReason.h:64).

**`zoomIn` / `zoomOut`** — P1, `controller`, evidence: the example app open-codes read-then-increment; nothing in maplibre_flutter/lib/src/maplibre_map_controller.dart:291-314
```dart
`Future<void> camera.zoomIn({Offset? anchor, Duration? duration})` / `Future<void> camera.zoomOut({Offset? anchor, Duration? duration})`
```
> Every +/- button in every map app. Implement over `scaleBy` (core.h:80, already there) rather than read-modify-write — the read path is async and races the gesture layer, which is exactly why the example's version is fragile.

**Batch project / unproject** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/projector.dart:34 takes `List<LatLng>` + out-params; core wrapper `projectBatch` (maplibre_flutter_core.dart:666); C ABI `mbl_map_pixels_for_lat_lngs` (core.h:147)
```dart
`int controller.projection.projectAll(List<LatLng> points, List<Offset> out, {List<bool>? visible})`
```
> Already built and already fast (one FFI call and one lock acquisition for the whole batch); it just needs a public door. This is what makes an app-drawn custom overlay of 500 points viable without 500 FFI calls per frame — a differentiator no competing Flutter plugin has.

**Caller-supplied easing curve** — P2, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/fly_animation.dart:16 — a hardcoded smoothstep `t*t*(3-2*t)`
```dart
`Curve curve = Curves.easeInOut` on `easeTo`/`flyTo`/`panTo`/`zoomTo`/`fitBounds`
```
> `Cubic` → `UnitBezier` is an exact 1:1 mapping (both are cubic Bézier timing curves with the same control-point parameterisation), so a `Curves.easeInOutCubic` crosses the ABI as four doubles. Non-`Cubic` curves (`Curves.elasticOut`) cannot cross — either reject them or sample them in Dart; say which in the dartdoc.

**Visible region as a quad (pitched view)** — P2, `controller-namespace`, evidence: —
```dart
`VisibleRegion? controller.projection.getVisibleRegion()` with `class VisibleRegion { final LatLng farLeft, farRight, nearLeft, nearRight; final LatLngBounds bounds; }`
```
> Android's shape, adopted because it is the only one that is honest about a pitched camera: the visible area is a trapezoid, and an axis-aligned `getBounds` over-reports badly at pitch 60. Free over the existing batch unproject.

**`MapCamera` gains `padding`, `roll`** — P2, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/camera.dart:10-56 — center/zoom/bearing/pitch only
```dart
`MapCamera({required LatLng center, double zoom, double bearing, double pitch, double roll = 0, EdgeInsets padding = EdgeInsets.zero})` + `copyWith`
```
> **Matrix drift:** FEATURE_MATRIX.md:314 `setRoll` ➖ web_only — **DISAGREES with the headers**: `CameraOptions::roll` is in mbgl and `MLNMapCamera.roll` is in the Apple SDK. Not web-only.

**`camera.getPosition()` — read the camera** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:297; platform_interface/lib/src/maplibre_map_controller.dart:25; core.h:65 `mbl_map_get_camera`
```dart
keep `Future<MapCamera> camera.getPosition()`; ALSO expose `MapCamera? get camera.position` (synchronous, from the same cached snapshot the projector uses)
```
> Name kept from Android (`CameraPosition`) even though gl-js has no aggregate getter — it predates this spec and renaming it buys nothing. The synchronous getter is worth adding: `mbl_map_get_camera` is a lock-and-copy of a cached struct (maplibre_flutter_core.cpp:1288-1293), so the `Future` is pure ceremony and forces `await` inside build/paint paths where markers already project synchronously.

**`camera.move(MapCamera, {Duration?})` — the current entry point** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:308; platform_interface/lib/src/maplibre_map_controller.dart:28
```dart
keep as `@Deprecated('Use camera.jumpTo / easeTo / flyTo') Future<void> move(MapCamera target, {Duration? duration})` for one minor release
```
> It is the whole camera API today, so it cannot simply be removed. But it conflates three distinct upstream operations behind a nullable Duration, and the animated branch silently runs a fly arc (see the easeTo row). Deprecate rather than redefine — redefining it to mean `easeTo` would silently change the motion of every existing caller.

**`cameraForLatLngs` / fit a set of points** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:291-314
```dart
`Future<void> camera.fitPoints(Iterable<LatLng> points, {EdgeInsets padding = EdgeInsets.zero, double? bearing, double? pitch, Duration? duration})`
```
> Not identical to `fitBounds(LatLngBounds.fromPoints(...))` on a pitched or rotated view — mbgl fits the actual point set to the rotated frustum, whereas an axis-aligned bbox over-zooms out. Worth binding separately for that reason, and `LatLngBounds.fromPoints` should NOT be presented as an equivalent.

**`getCenter`** — P2, `controller`, evidence: reachable only as `(await camera.getPosition()).center` — maplibre_flutter/lib/src/maplibre_map_controller.dart:297
```dart
`Future<LatLng> camera.getCenter()`
```
> Pure forwarder over the existing cache. Cheap, and it is the name every gl-js user reaches for first.

**`getMaxBounds`** — P2, `controller`, evidence: —
```dart
`Future<MapCameraConstraints> camera.getConstraints()` (returns all five, including `maxBounds`)
```
> One call, because `Map::getBounds()` returns the whole `BoundOptions` with every field populated. Five separate gl-js getters over one struct would be five round trips for the same bytes.

**`idle` event / did-become-idle** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:87-91 has `onReady` only
```dart
`Future<void> camera.onIdle` / the `CameraPhase.idle` event on `camera.events`
```
> The correct trigger for "the camera settled, now fetch data for the new viewport" — much better than debouncing `onCameraChanged`, and it also waits for tiles, which a camera tick does not. `mbl_map_set_idle_callback` mirrors the existing `mbl_map_set_frame_callback` (core.h:268) shape.

**`isMoving` / `isZooming` / `isRotating`** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:75-82 exposes only `onCameraChanged` (a bare `Listenable`, no state)
```dart
`bool get camera.isMoving`, `bool get camera.isZooming`, `bool get camera.isRotating` (synchronous, from a cached flag refreshed with the camera cache)
```
> gl-js `isMoving` = any of pan/scale/rotate/gesture, so map it to `isPanning() || isScaling() || isRotating() || isGestureInProgress()`; `isZooming` → `isScaling()`. Useful to gate expensive work (a `queryRenderedFeatures` during a fling is wasted). Another matrix ➖-that-should-be-❌.

**`metersPerPixelAtLatitude` / scale bar support** — P2, `controller-namespace`, evidence: nothing in packages/maplibre_flutter/lib/src/ or the platform interface
```dart
`double controller.projection.metersPerPixelAtLatitude(double latitude)` — and a pure-Dart static `MapLibreProjection.metersPerPixelAtLatitude(lat, zoom)`
```
> **Zero native work**: `util/projection.hpp:47` is 5 lines of pure math with no map dependency, so it can be reimplemented in Dart exactly (`cos(deg2rad(clamp(lat,±85.051128779806604))) * 2π * EARTH_RADIUS_M / (2^clamp(zoom,0,25.5) * 512)`). Prerequisite for a scale bar, which both native SDKs ship and we do not.

**`panTo` (animate the centre to a point)** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:311-313 (the TODO comment listing exactly these)
```dart
`Future<void> camera.panTo(LatLng center, {Duration? duration, Curve curve = Curves.easeInOut})`
```
> Sugar over `easeTo(CameraOptions(center: …))`; add it because gl-js users type it by reflex.

**`resetNorth`** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:291-314
```dart
`Future<void> camera.resetNorth({Duration duration = const Duration(milliseconds: 500)})`
```
> The compass-button action. This mislabelling matters: ➖ tells a future contributor the feature is impossible here, when in fact both native SDKs ship it and it is three lines over `easeTo`.

**`rotateTo` (animate to an absolute bearing)** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:291-314
```dart
`Future<void> camera.rotateTo(double bearing, {Offset? anchor, Duration? duration, Curve curve = Curves.easeInOut})`
```
> Must take the shortest path around the circle; `fly_animation.dart:46` already has the `_shortestDelta` helper for exactly this and it should be reused, not re-derived.

**`setConstrainMode`** — P2, `reject`, evidence: —
```dart
not a public API; set internally to `ConstrainMode.screen` when `maxBounds` is non-null (see the `setMaxBounds` row)
```
> Reject as a public knob, adopt as an implementation detail. Exposing four modes with no cross-platform meaning would be API surface nobody can use portably; but the `Screen` mode is load-bearing for `maxBounds` and must be wired.

**`setGestureInProgress` — bracket a gesture for the engine** — P2, `capability-interface`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart (the Dart gesture layer) never signals gesture start/end to the core; core.h has no entry point
```dart
`@internal void MapLibreGestureHandler.setGestureInProgress(bool)` — called by the widget's recognizers, not by app code
```
> Not app-facing, but it feeds `isMoving`, it lets mbgl suppress work mid-gesture, and it is the correct source for the camera-change *reason* (gesture vs programmatic) that mbgl otherwise cannot tell us. Our gesture layer is in Dart, so we are the only ones who can supply it — nobody else will.

**`setMaxPitch` / `getMaxPitch`** — P2, `widget-prop`, evidence: —
```dart
set: `MapLibreMap(constraints: MapCameraConstraints(maxPitch: …))`; get: `Future<double> camera.getMaxPitch()`
```
> **A genuine engine divergence to document, not paper over.** gl-js goes to 85°, mbgl clamps to 60° (constants.hpp:35, and Apple says so in its own header at MLNMapView.h:1113). A cross-platform app that asks for 75° gets 75 on gl-js-web and 60 on the five native tiers plus WASM. Clamp in Dart and say so, rather than silently accepting the value.

**`setMinPitch` / `getMinPitch`** — P2, `widget-prop`, evidence: —
```dart
set: `MapLibreMap(constraints: MapCameraConstraints(minPitch: …))`; get: `Future<double> camera.getMinPitch()`
```
> Rarely used except to force a permanently-tilted 3D view.

**`zoomBy` / `scaleBy` (relative zoom about an anchor)** — P2, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/gesture_handler.dart:16 `scaleBy(double scale, double anchorX, double anchorY)`; reached only through the `@internal` gestureHandler
```dart
`Future<void> camera.zoomBy(double delta, {Offset? anchor, Duration? duration})` — delta in ZOOM LEVELS (Android's unit), not a scale factor
```
> Deliberate unit change: the C ABI takes a multiplicative `scale` (core.h:80) but Android's public `zoomBy` takes zoom LEVELS, which is what callers reason in. Convert in Dart (`scale = pow(2, delta)`), do not leak the multiplier.

**`zoomTo` (animate to an absolute zoom)** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:311-313
```dart
`Future<void> camera.zoomTo(double zoom, {Offset? anchor, Duration? duration, Curve curve = Curves.easeInOut})`
```
> `anchor` is mbgl's `CameraOptions::anchor`; gl-js spells the same idea `around`. See the naming note.

**Bounds ⇄ screen rect conversion** — P3, `controller-namespace`, evidence: —
```dart
`LatLngBounds? controller.projection.boundsForRect(Rect rect)` / `Rect? controller.projection.rectForBounds(LatLngBounds bounds)`
```
> Apple-only among the three, and pure Dart over the projector. Useful for hit-testing an app-drawn region and for driving `queryRenderedFeatures(rect)` from a geographic area rather than a screen box.

**Off-map projection object (project against a hypothetical camera)** — P3, `value-type`, evidence: —
```dart
`MapProjectionSnapshot controller.projection.snapshot({CameraOptions? camera})` — an immutable projector for a hypothetical camera
```
> Apple and mbgl both ship this and gl-js does not. It answers "where would these markers land if I flew there?" without moving the map — a nice-to-have for pre-computing an animation, and it is `mbgl::MapProjection` (map_projection.hpp:24) which is already public. Not urgent, but worth recording so it is not reinvented.

**Tile LOD tuning (pitch-driven detail falloff)** — P3, `widget-prop`, evidence: —
```dart
`MapLibreMap(tileLod: MapTileLodOptions(minRadius: 3, scale: 1, pitchThresholdRadians: 0, zoomShift: 0, mode: TileLodMode.default_))`
```
> Arguably the rendering domain, but it is camera-driven (the heuristic keys off pitch and distance-to-viewpoint, map.hpp:170-196) and Apple puts it on `MLNMapView`, so record it here. It is the lever for making a heavily-pitched 3D view affordable on mobile — worth having on the backlog even at p3, and completely absent from the matrix.

**`FreeCameraOptions` (direct 3D camera control)** — P3, `controller`, evidence: —
```dart
`Future<void> camera.setFreeCamera(FreeCameraOptions options)` with `FreeCameraOptions.lookAt({required LatLng from, required double altitude, required LatLng at})`
```
> The drone/flythrough case, and the natural companion to the 3D model work already landed. mbgl's own helpers (`lookAtPoint`, camera.hpp:173; `setRollPitchBearing`, :177) are the ergonomic surface to bind — do not expose raw quaternions to Dart.

**`MLNMapCamera` altitude / viewingDistance model** — P3, `reject`, evidence: —
```dart
— as a camera model, reject; optionally add pure-Dart statics `MapLibreCamera.altitudeForZoom(zoom, pitch, latitude, size)` / `zoomForAltitude(...)`
```
> Apple is the outlier here: its camera is altitude-first with zoom derived. Copying that would fight both gl-js and mbgl. Ship the two conversion statics for anyone porting Apple-SDK code and leave the camera zoom-based.

**`MapCamera` gains `centerAltitude` / camera elevation** — P3, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/camera.dart:10
```dart
`MapCamera(centerAltitude: 120)` + `camera.setCenterElevation(double metres)` / `camera.getCenterElevation()`
```
> Only meaningful with terrain, which we do not run yet — hence p3 despite being expressible. Flag the matrix correction regardless: a ➖ tells a future reader never to attempt it.

**`MapOptions.initialCamera`** — P3, `widget-init`, evidence: packages/maplibre_flutter_platform_interface/lib/src/map_options.dart:15-20; consumed at macos_controller.dart:120
```dart
unchanged: `MapLibreMap(options: MapOptions(initialCamera: MapCamera(center: …)))`
```
> Correctly bucketed already (init-only → `MapOptions`). One gap worth noting: there is no way to say "start where the style says", which is what `Style::getDefaultCamera()` (style.hpp:37) would give — see the `resetPosition` row. Consider making `initialCamera` nullable so null means "use the style's default".

**`anchorRotateOrZoomGesturesToCenterCoordinate`** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:28-37 (no such prop); the gesture layer always anchors on the pinch centroid
```dart
`MapLibreMap(gestureAnchor: MapGestureAnchor.gesture)` — `gesture` (default) or `center`
```
> Sits on the camera/gesture boundary; flagged here because the anchor is a camera concept and because it corrects two more ➖-should-be-❌ cells. Pure Dart: the gesture layer just passes the viewport centre as the anchor. The "locked zoom" mode navigation apps want.

**`animate` / `essential` flags (reduced motion)** — P3, `controller`, evidence: —
```dart
`duration: null` already means "do not animate"; for reduced motion, honour `MediaQuery.of(context).disableAnimations` in the widget and add `bool essential = false` to skip that check
```
> Flutter-idiom adaptation: gl-js's `essential` exists because it checks `prefers-reduced-motion`; Flutter's equivalent is `MediaQueryData.disableAnimations`. Honouring it is an accessibility win no competing plugin does.

**`cameraForGeometry` / fit a shape** — P3, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:291-314
```dart
`Future<CameraOptions> camera.cameraForGeoJson(Map<String, Object?> geometry, {EdgeInsets padding = EdgeInsets.zero, double? bearing, double? pitch})`
```
> Takes GeoJSON geometry as a Dart map, matching the existing JSON-in style/data path (`addSourceJson`, core.h:181) rather than inventing a Dart geometry hierarchy. Low priority until there is a reason beyond "frame this route", which `fitPoints` already covers.

**`fitScreenCoordinates`** — P3, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:291-314
```dart
`Future<void> camera.fitScreenCoordinates(Offset p0, Offset p1, {double? bearing, EdgeInsets padding = EdgeInsets.zero, Duration? duration})`
```
> This is what a box-zoom (shift-drag) gesture calls. Implementable entirely in Dart today over the existing projector's `unproject` + a future `cameraForBounds`. The ➖ in the matrix would stop someone from even trying.

**`getRoll` / `setRoll`** — P3, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/camera.dart:10 (no roll field)
```dart
`Future<double> camera.getRoll()` / `Future<void> camera.setRoll(double roll)`
```
> Expressible, unproven. Ship only after checking that `Transform` and each backend's projection matrix honour it — `CameraOptions::roll` being in the struct is not evidence that the Metal/GL/Vulkan paths respect it.

**`queryTerrainElevation`** — P3, `reject`, evidence: —
```dart
— (do not add)
```
> Hard stop. Note the matrix has this backwards relative to its neighbours: it marks ❌ (bindable) where the truth is closer to ➖, while marking ➖ on half a dozen rows above that ARE bindable.

**`resetNorthPitch`** — P3, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:291-314
```dart
`Future<void> camera.resetNorthPitch({Duration duration = const Duration(milliseconds: 500)})`
```
> Trivial once easeTo takes a partial camera. Include for gl-js familiarity.

**`resetPosition` — return to the style's default camera** — P3, `controller`, evidence: nothing reads the style document's `center`/`zoom`/`bearing`/`pitch`; MapOptions.initialCamera (map_options.dart:20) is the only default
```dart
`Future<void> camera.resetPosition({Duration? duration})` and `Future<CameraOptions> camera.getStyleDefaultCamera()`
```
> Also fixes a real usability wart: today a style that declares its own `center`/`zoom` is overridden by `MapOptions.initialCamera` with no way to ask what the style wanted. Exposing `getDefaultCamera()` lets an app opt into style-declared framing.

**`setCenterClampedToGround` / `getCenterClampedToGround`** — P3, `reject`, evidence: —
```dart
— (do not add)
```
> Ties to terrain, which core does not query. Genuine ➖.

**`setNorthOrientation`** — P3, `widget-prop`, evidence: —
```dart
`MapLibreMap(northOrientation: MapNorthOrientation.upwards)`
```
> Long tail. One real use: a rotated kiosk display. Cheap to bind (one enum, one call) but nothing needs it — record and defer.

**`setProjectionMode` / `getProjectionMode` (axonometric)** — P3, `controller`, evidence: —
```dart
`Future<void> camera.setAxonometric({bool enabled = true, double xSkew = 0, double ySkew = 1})`
```
> Isometric/SimCity-style rendering of fill-extrusions. Genuinely native-only and genuinely useful for a niche; keep the mbgl field names so the mapping is obvious.

**`setVerticalFieldOfView` / `getVerticalFieldOfView`** — P3, `controller`, evidence: —
```dart
`Future<void> camera.setVerticalFieldOfView(double degrees)` / `Future<double> camera.getVerticalFieldOfView()`
```
> Same correction pattern as roll/centerAltitude/anchor: the matrix's ➖ on this row is contradicted by `camera.hpp`. Verify `Transform` honours it before promising anything.

**`setViewportMode` (FlippedY)** — P3, `reject`, evidence: —
```dart
— (do not expose)
```
> An embedder-integration knob, not an app API, and dangerous here: our present paths already own the y-orientation story (the flip lives in the shim, core.h:115-118, and CLAUDE.md §11 records that getting it wrong mirrored every marker). Exposing a second y-flip lever invites exactly the bug class this repo has already paid for twice.

**`shouldChangeFromCamera` — veto a camera change** — P3, `widget-callback`, evidence: —
```dart
`MapLibreMap(onCameraWillChange: bool Function(MapCamera from, MapCamera to, Set<CameraChangeReason> reason)?)`
```
> Apple-only, and the sanctioned way to do "restrict panning to this region" with custom logic that `maxBounds` cannot express (e.g. a non-rectangular service area). We can do it BETTER than the native SDKs because the gesture layer is Dart — the veto is a plain function call, not a delegate round trip.

**`snapToNorth` (snap bearing to 0 within a tolerance)** — P3, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:291-314
```dart
`Future<void> camera.snapToNorth({double bearingSnap = 7, Duration? duration})` plus a widget prop `MapLibreMap.bearingSnap` consumed by the rotate recognizer
```
> Two halves: the method (gl-js) and the automatic gesture snap (Apple/gl-js `bearingSnap`). The gesture half belongs with `rotate_handler.dart` and the 8° twist deadzone that already exists there.

**flyTo `curve` / `screenSpeed` / `maxDuration`** — P3, `reject`, evidence: —
```dart
— (do not add; document the divergence in `flyTo`'s dartdoc)
```
> A genuine engine ceiling. gl-js's van-Wijk ρ parameter is not exposed by mbgl. Rejecting is better than emulating in Dart, which is what we do today and what produces the arc mismatch.

**flyTo `speed` (velocity in screenfuls/second)** — P3, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/fly_animation.dart (fixed pacing)
```dart
`double? speed` on `camera.flyTo(...)`
```
> Comes free with `AnimationOptions`; listed separately because the matrix declares it impossible on native and it is not.

**flyTo apex zoom (gl-js `minZoom`, Apple `peakAltitude`)** — P3, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/fly_animation.dart:29-32 — a hand-rolled `_fitZoom` dip, not caller-controllable
```dart
`double? apexZoom` on `camera.flyTo(...)`
```
> Renamed from gl-js's `minZoom` to avoid colliding with the constraint `minZoom` in the same namespace — see naming note 9. Our `_fitZoom` heuristic (fly_animation.dart:55) was written to approximate exactly this; it can be deleted once the engine does it.

**gl-js `calculateCameraOptionsFromTo` / `…FromCameraLngLatAltRotation`** — P3, `value-type`, evidence: —
```dart
`CameraOptions MapLibreCamera.lookingAt({required LatLng eye, required double eyeAltitudeMetres, required LatLng target})` — a pure factory, no map needed
```
> Three engines converge on this one (gl-js method, Apple class factory, mbgl FreeCameraOptions helper), which is a good sign it is the right shape. Apple's naming (`cameraLookingAtCenterCoordinate:fromEyeCoordinate:eyeAltitude:`) is the clearest of the three; adapt it to a Dart factory.


### Sources

#### Engine ceiling

Hard stops for the five native tiers **and** web-WASM (they are the same C++), verified by reading the vendored core at `packages/maplibre_flutter_core/third_party/maplibre-native` (pinned `core-fa8a9c8e3261ce64940127aecc1d52f540c21c57`):

**A. Spec fields mbgl silently ignores.** The style-spec→`Source` converter is `src/mbgl/style/conversion/source.cpp` (dispatch at `:207-240`), `geojson_options.cpp` and `source_options.cpp`. Reading them end to end, **none of these are ever parsed**:
- `promoteId` (vector + geojson). Zero hits for `promoteId` in `src/` and `include/`; the only occurrences in the whole submodule are five render-test fixtures, and all five are on the permanent ignore list (`metrics/ignores/platform-all.json:127-131`, pointing at mapbox-gl-js#9202). **Feature state therefore only works on features whose own GeoJSON/MVT `id` is set.**
- `generateId` (geojson). Zero hits anywhere.
- `filter` (geojson). `Converter<GeoJSONOptions>` (`geojson_options.cpp:11-178`) reads minzoom/maxzoom/buffer/tolerance/cluster/clusterMaxZoom/clusterRadius/clusterMinPoints/lineMetrics/synchronousUpdate/clusterProperties — **and nothing else**.
- `volatile` (all tile sources). `Source::setVolatile` exists as a C++ setter (`include/mbgl/style/source.hpp:81`) but no converter calls it, so setting it in the source JSON is a no-op. Reachable only via a new C ABI on the live `Source*`.
- `redFactor` / `blueFactor` / `greenFactor` / `baseShift` and `encoding: "custom"` (raster-dem). `Converter<SourceOptions>` (`source_options.cpp:9-28`) accepts exactly `"mapbox" | "terrarium" | "mvt" | "mlt"` and **errors** on anything else — so `encoding: "custom"` does not merely no-op, it makes the whole `addSourceJson` call fail with `invalid encoding`.

This is the single most important finding in this domain: our generated typed API exposes all six of these as first-class fields (`style_sources.g.dart:84, 89, 274, 280-298, 378, 451, 457`) because coverage is discovered from the spec, and five of the six compile, serialise, and do nothing.

**B. Source types mbgl does not have.** `source.cpp:226-238` accepts exactly `raster | raster-dem | vector | geojson | image` and returns `error.message = "invalid source type"` otherwise. So **`video` is a hard stop** (and our generated `VideoSource`, `style_sources.g.dart:487`, is dead code on every tier we ship). `canvas` is not in the vendored spec at all (`v8.json` `source` = the six above minus canvas), so we do not even generate it.

**C. Runtime mutations mbgl does NOT offer:**
- `RasterSource::setTiles` / `setUrl` — **absent**. `raster_source.hpp` declares only the ctor and `supportsLayerType`; `TileSource` (`tile_source.hpp:13-35`) exposes `getURLOrTileset`/`getURL`/`getTileSize` and no setter. Only `VectorSource::setTiles` exists (`vector_source.hpp:30`). Changing a raster source's tiles means remove + re-add.
- `GeoJSONSource` cluster options are **immutable after construction** — `getOptions()` at `geojson_source.hpp:71` is const and there is no setter, so gl-js's `setClusterOptions` cannot be implemented; remove + re-add is the only route.
- **No incremental `updateData`.** `GeoJSONSource` offers `setURL` / `setGeoJSON` / `setGeoJSONData` (`geojson_source.hpp:66-68`) — whole-document replacement only. gl-js's `GeoJSONSourceDiff` (`{removeAll, remove, add, update}`) has no core counterpart.
- **No `getData`.** Nothing reads the current GeoJSON back out of a `GeoJSONSource`.
- **No per-source `getBounds`.** gl-js computes it in its worker. A tile source's declared `bounds` is readable via `Tileset::bounds` (`util/tileset.hpp:36`) but that is the TileJSON declaration, not the data extent.
- `Style::removeSource` **cannot fail loudly**: it logs `"Source 'x' is in use, cannot remove"` and returns `nullptr` (`src/mbgl/style/style_impl.cpp:178-194`). Apple's `-[MLNStyle removeSource:error:]` (`MLNStyle.h:149`) can only be emulated by checking layer sources ourselves first.

**D. What mbgl CAN do that we have not bound — the real backlog.** All of these are already reachable: the shim holds `m->frontend->getRenderer()` (used at `maplibre_flutter_core.cpp:1738`) and a `MapObserver` subclass (`FrameObserver`, `:872`).
- `Renderer::querySourceFeatures(sourceID, SourceQueryOptions{sourceLayers, filter})` — `include/mbgl/renderer/renderer.hpp:61`, options at `renderer/query.hpp:30-41`.
- `Renderer::queryFeatureExtensions(sourceID, feature, "supercluster", "children"|"leaves"|"expansion-zoom", args)` — `renderer.hpp:67`; the three getters and the `{"limit","offset"}` arg names are at `src/mbgl/renderer/sources/render_geojson_source.cpp:29-63`. **All three gl-js cluster helpers are one C ABI call away.**
- `Renderer::setFeatureState / getFeatureState / removeFeatureState` — `renderer.hpp:74-87`. The `feature-state` expression is implemented (`src/mbgl/style/expression/compound_expression.cpp:734,1070`), so the whole hover/select story works *provided the feature carries its own id* (see A).
- `ImageSource::setURL / setImage(PremultipliedImage&&) / setCoordinates(std::array<LatLng,4>)` — `image_source.hpp:21-26`. Both gl-js `updateImage` variants are available, including raw pixels, which pairs with our existing `mbl_map_add_image` byte path.
- `Source::getAttribution()` `:77`, `isVolatile/setVolatile` `:80-81`, `setPrefetchZoomDelta` `:93`, `setMinimumTileUpdateInterval` `:102`, `setMaxOverscaleFactorForParentTiles` `:117`, and the public `bool loaded` field `:123` (⇒ `isSourceLoaded`).
- `Style::getSources()` `style.hpp:55` and `Style::getJSON()` `:32` ⇒ `getSource` / `getStyle().sources` in one call.
- `Map::isFullyLoaded()` `map/map.hpp:153` ⇒ gl-js `areTilesLoaded`.
- `MapObserver::onSourceChanged(Source&)` `map/map_observer.hpp:65`, `onDidBecomeIdle()` `:66`, `onTileAction(TileOperation, OverscaledTileID, sourceID)` `:86` with the 9-value `TileOperation` enum (`tile/tile_operation.hpp`) ⇒ `sourcedata`, `idle`, and a tile-level signal *richer* than gl-js's.
- `CustomGeometrySource` **is a public mbgl header** (`style/sources/custom_geometry_source.hpp:24-62`) with `setTileData`, `invalidateTile`, `invalidateRegion` and a `fetchTileFunction` callback. It is the direct backing for Apple's `MLNComputedShapeSource` and Android's `CustomGeometrySource`, and it has no gl-js equivalent.
- `VectorEncoding::MLT` is **real and wired** — `VectorSource` ctor takes it (`vector_source.hpp:20`), the converter parses `"mlt"` (`source.cpp:118-125`), and `RenderVectorSource` dispatches to `VectorMLTTile` (`src/mbgl/renderer/sources/render_vector_source.cpp:39-44`). No build gate found.

**E. Cross-tier behavioural divergence that is not an mbgl limit but ours.** The native shim catches `Style::addSource`'s duplicate-id `std::runtime_error` (thrown at `style_impl.cpp:165-169`) and only `fprintf(stderr, ...)`s it (`maplibre_flutter_core.cpp:1562-1564`), because the add is posted to the render thread. The **web-WASM** path applies inline and returns the message, which `core_web_controller.dart:269` turns into a thrown `ArgumentError`. Same public call, same engine, two different contracts. Same for `setGeoJsonData` on a missing/wrong-typed source id (native: `fprintf` at `:1619-1627`; web: throws, `core_web_controller.dart:285`).

#### Naming decisions

**Policy applied: gl-js names, Apple/Android shapes where gl-js has none, flattened at the platform interface and re-assembled into a handle app-side.**

1. **Where all three upstreams AGREE, copy it verbatim.** `addSource(id, spec)` / `removeSource(id)` / `getSource(id)` then per-source ops (`setData`, `setTiles`, `setUrl`, `updateImage`, `setCoordinates`, `getClusterExpansionZoom` / `getClusterChildren` / `getClusterLeaves`) is the shape of gl-js (`map.getSource(id).setData(...)`), the Apple SDK (`style.source(withIdentifier:) as? MLNShapeSource` then `.shape = …`, `MLNShapeSource.h:354`) **and** the Android SDK (`style.getSourceAs<GeoJsonSource>(id)!!.setGeoJson(...)`). Three-for-three. So the app-facing API should be `controller.sources.getSource<MapLibreGeoJsonSource>('pts')?.setData(...)`, **not** more flat `layers.setXOnSource(id, …)` methods. The "handle" is only `(id, back-reference)` — no native pointer, so there is no lifetime problem and no staleness beyond "the id may be gone", which every call already has to tolerate.

2. **Flat at the platform interface, handle-shaped app-side.** House rule §3 says the namespace is a pure app-facing wrapper forwarding to the flat platform controller. So `MapLibreStyleLayers` (or a new `MapLibreSources` capability) keeps flat `setGeoJsonData(sourceId, json)`, `setSourceTiles(sourceId, tiles)`, `getClusterExpansionZoom(sourceId, clusterId)` … and `MapLibreGeoJsonSource` in `maplibre_flutter` is 40 lines of forwarding. Zero contract churn per new source type.

3. **New namespace `controller.sources`, splitting off `controller.layers`.** Today sources live on `controller.layers` (`map_layers_controller.dart:97,106,114,119`), which was fine at four methods and is wrong at forty. gl-js and both SDKs treat sources and layers as separate collections (`MLNStyle.sources` at `MLNStyle.h:92` vs `MLNStyle.layers` at `:157`; `mbgl::style::Style::getSources()` vs `getLayers()`, `style.hpp:55/65`). Keep the four existing methods on `layers` as `@Deprecated` forwards so nothing breaks.

4. **Where the SDKs and gl-js DISAGREE:**
   - **Cluster helpers.** gl-js takes a raw `clusterId: number` (`getClusterExpansionZoom(clusterId)`); Apple takes the *feature object* (`-[MLNShapeSource zoomLevelForExpandingCluster:]`, `MLNShapeSource.h:437`) as does Android (`getClusterExpansionZoom(cluster: Feature)`). **I pick gl-js (the int id).** Reason: mbgl's own entry point is `Renderer::queryFeatureExtensions(sourceID, feature, "supercluster", "expansion-zoom")` and it only ever reads `feature.properties["cluster_id"]` — the SDKs' feature-shaped argument is a wrapper that immediately unwraps to the int, and passing a whole feature over an FFI boundary means re-serialising GeoJSON for nothing. `MapLibreQueriedFeature` already surfaces `cluster_id` in `properties`. I do add a convenience overload taking `MapLibreFeature` so the ergonomic call site matches the SDKs.
   - **Zoom-level type.** Apple returns `double` (`zoomLevelForExpandingCluster:` → `double`), Android returns `Int`, gl-js `Promise<number>`, mbgl returns `uint8_t`. **I pick `double`** (Apple/gl-js) so it composes with `MapCamera.zoom`.
   - **Feature state placement.** gl-js puts it on `Map` (`map.setFeatureState(feature, state)`); Android 11 puts it on the *source* (`GeoJsonSource.setFeatureState(featureId, state)`, `VectorSource.setFeatureState(sourceLayerId, featureId, state)`); Apple **has none at all** (grep for `eatureState` across all 164 headers → zero hits). **I pick gl-js's `FeatureIdentifier` shape** (`{source, sourceLayer?, id}`) because it is one method for both source kinds, matches mbgl's own `Renderer::setFeatureState(sourceID, sourceLayerID, featureID, state)` argument-for-argument, and Android's split is just its lack of a `FeatureIdentifier` type. Android's `resetFeatureStates()` maps onto gl-js `removeFeatureState({source}, undefined)`, so no extra method.
   - **`setData` argument.** gl-js `setData(string | GeoJSON)` overloads URL and inline on one method; Apple splits them into two properties (`shape` at `:354`, `URL` at `:362`); Android splits into `setGeoJson` vs `setUri`. **I pick gl-js's single method**, using our existing sealed-ish `GeoJsonData` type (`geojson_data.dart:12`) which already has `.url()` and `.inline()` constructors — Dart named constructors give us the SDK clarity with the gl-js arity.
   - **Tile-source encoding names.** Apple invents `MLNVectorTileSourceEncoding{Mapbox,MLT}` (`MLNVectorTileSource.h:21-32`) and `MLNDEMEncoding{Mapbox,Terrarium}` (`MLNRasterDEMSource.h:22-35`); the spec strings are `"mvt"/"mlt"` and `"mapbox"/"terrarium"`. **Spec strings win** — the generated `VectorEncoding.mvt/.mlt` (`style_enums.g.dart:719`) and `RasterDemEncoding` (`:360`) are already right.
   - **`scheme`.** Apple calls it `MLNTileCoordinateSystem{XYZ,TMS}` (`MLNTileSource.h:124`); spec/gl-js call it `scheme: "xyz"|"tms"`. Spec wins (already generated).

5. **Flutter-idiom adaptations, named explicitly:**
   - `map.on('sourcedata', cb)` → **`Stream<MapLibreSourceDataEvent> get onSourceData`** on a new `MapLibreSourceEvents` capability. gl-js's string-keyed `on()` is un-Dartlike; a typed stream is the Flutter equivalent and preserves the payload (`sourceId`, `sourceDataType`, `isSourceLoaded`). Not a `Listenable` like `onCameraChanged`, because the payload matters here.
   - Every round-trip to the render thread (`getSource`, `isSourceLoaded`, cluster helpers, `querySourceFeatures`, `getFeatureState`) is **`Future`-returning**. The existing `queryRenderedFeaturesJson` is synchronous and blocks the UI isolate up to `timeout_ms` (`maplibre_flutter_core.h:246`, waits on a condvar at `maplibre_flutter_core.cpp:1769`) — that is exactly the pattern CLAUDE.md §5a warns about. Do **not** repeat it for the ~8 new query entry points.
   - gl-js returns `this` for chaining; Dart returns `void`/`Future<void>`. No cascade sugar needed — Dart has `..`.
   - `NSPredicate` / `Expression` filters (Apple `featuresMatchingPredicate:` `:392`, Android `querySourceFeatures(filter)`) → our generated `Expression` from `style_expressions.g.dart`, serialised to the spec filter array. No new type.

6. **Sources stay on the controller, not the widget.** Under the three-bucket rule a source is "mutable + imperative/command", and a declarative `MapLibreMap.sources` prop would fight `MapLibreMap.style` (the style document already declares sources, and loading a style replaces them all — `docs`/CLAUDE.md §11). Only `MapLibreMap.style` stays declarative.

#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | `MapLibreFeature` value type — queried features lose geometry and id | partial | MapGeoJSONFeature — a full GeoJSON Feature with id, geometry, properties, plus source/sourceLayer/state | id<MLNFeature> (MLNFeature.h:40) with identifier + attributes; concrete MLNPointFeature (:171), MLNPolylineFeature (:200), MLNPolygonFeature (:208), MLNMultiPolygonFeature (:243), MLNShapeCollectionFeature (:266), and MLNPointFeatureCluster (:185) conforming to MLNCluster (MLNCluster.h:43-49: clusterIdentifier, clusterPointCount) | mbgl::Feature (util/feature.hpp) with id + geometry + properties; already serialised whole via mapbox::geojson::stringify (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1750-1753) | value-type | no |
| P0 | `addSource` — duplicate-id / invalid-document error reporting | partial | map.addSource throws on a duplicate id | raises MLNRedundantSourceException / MLNRedundantSourceIdentifierException (MLNStyle.h:20-21), documented at :118-122 | style::Style::Impl::addSource throws std::runtime_error('Source X already exists') (src/mbgl/style/style_impl.cpp:165-169) | controller-namespace | yes |
| P1 | Blocking query calls on the UI isolate | partial | every source query is Promise-returning | synchronous, but on the main thread with an in-process renderer — not comparable | the renderer is thread-affine (see the comment at maplibre_flutter_core.cpp:1723-1725) | controller-namespace | yes |
| P1 | Cluster expansion zoom — `getClusterExpansionZoom` | none | geoJsonSource.getClusterExpansionZoom(clusterId: number): Promise<number> | -[MLNShapeSource zoomLevelForExpandingCluster:] → double (MLNShapeSource.h:437); 'any negative return value should be considered an error' | Renderer::queryFeatureExtensions(sourceID, feature, "supercluster", "expansion-zoom") (include/mbgl/renderer/renderer.hpp:67); getter registered at src/mbgl/renderer/sources/render_geojson_source.cpp:56-63; underlying GeoJSONData::getClusterExpansionZoom (style/sources/geojson_source.hpp:57) | controller-namespace | yes |
| P1 | Feature state — `setFeatureState` | none | map.setFeatureState(feature: FeatureIdentifier, state: any): this — FeatureIdentifier = {source: string, sourceLayer?: string, id?: string\|number} | — **none**: zero hits for 'eatureState' across all 164 public Apple headers | Renderer::setFeatureState(sourceID, optional<sourceLayerID>, featureID, FeatureState) (include/mbgl/renderer/renderer.hpp:74-77); FeatureState = mapbox::base::ValueObject (util/feature.hpp:16); the ['feature-state'] expression is implemented (src/mbgl/style/expression/compound_expression.cpp:734,1070) | controller-namespace | yes |
| P1 | GeoJSON `setData` — with a URL | none | setData accepts `string` (a URL) as well as a GeoJSON object — one method | MLNShapeSource.URL, settable (MLNShapeSource.h:362); the header's own 'Add live data' example is exactly 'update the URL property' | style::GeoJSONSource::setURL(const std::string&) (geojson_source.hpp:66) — present, just not bound | controller-namespace | yes |
| P1 | GeoJSON — `generateId` | internal-only | source spec `generateId: boolean` — assigns feature.id from array index *(unverified)* | — | NOT IN CORE — zero hits for `generateId` in src/ or include/ | controller-namespace | no |
| P1 | GeoJSON — `promoteId` | internal-only | source spec `promoteId` *(unverified)* | — | NOT IN CORE (see vector promoteId row) | controller-namespace | no |
| P1 | List the style's sources / `getStyle().sources` | none | map.getStyle(): StyleSpecification — `.sources` is a map of id → spec | MLNStyle.sources (NSSet<MLNSource*>, MLNStyle.h:92); whole document via MLNStyle.styleJSON (:85) | style::Style::getSources() (include/mbgl/style/style.hpp:55-56) and Style::getJSON() (:32) | controller-namespace | yes |
| P1 | Source attribution accessor (read-back) | none | source.attribution (a property on the Source object) | MLNTileSource.attributionInfos (MLNTileSource.h:186) and .attributionHTMLString (:195); MLNAttributionInfo models clickable buttons | style::Source::getAttribution() → optional<string> (include/mbgl/style/source.hpp:77) | controller-namespace | yes |
| P1 | Vector source — `promoteId` | internal-only | source spec `promoteId: string \| {<sourceLayer>: string}` *(unverified)* | — (no MLNSource surface; Apple has no feature state at all) | NOT IN CORE — zero hits for `promoteId` in src/ and include/; the five render-test fixtures are permanently ignored (metrics/ignores/platform-all.json:127-131) | controller-namespace | no |
| P1 | Web tier: source support exists but the matrix says it does not | present | n/a (this is the WASM core tier, not gl-js) *(unverified)* | — | same C++ as the native tiers, compiled to WASM | controller-namespace | no |
| P1 | `LatLngBounds` value type (source `bounds`, fit-to-data) | none | LngLatBounds; source spec `bounds: [swLng, swLat, neLng, neLat]` | MLNCoordinateBounds {sw, ne} (MLNGeometry.h:71-76) + MLNCoordinateBoundsMake (:99) | mbgl::LatLngBounds — used for Tileset::bounds (util/tileset.hpp:36) and CustomGeometrySource::invalidateRegion (custom_geometry_source.hpp:47) | value-type | no |
| P1 | `areTilesLoaded` / fully-loaded | none | map.areTilesLoaded(): boolean; also map.loaded() | — (mapViewDidBecomeIdle: on MLNMapViewDelegate is the practical stand-in) | Map::isFullyLoaded() (include/mbgl/map/map.hpp:153) — style + all tiles + sprites + glyphs | controller | yes |
| P1 | `getSource` | none | map.getSource(id: string): Source \| undefined | -[MLNStyle sourceWithIdentifier:] (MLNStyle.h:113), returning a concrete MLNSource subclass or nil | style::Style::getSource(const std::string&) (include/mbgl/style/style.hpp:58); type via Source::getType() (source.hpp:75), id via getID() (:76) | controller-namespace | yes |
| P1 | `removeSource` — silent failure while a layer still uses it | partial | throws if the source is in use *(unverified)* | -[MLNStyle removeSource:error:] (MLNStyle.h:149) — 'YES if source was removed successfully. If NO, outError contains an NSError describing the problem' | Style::Impl::removeSource logs Warning "Source 'x' is in use, cannot remove" and returns nullptr — src/mbgl/style/style_impl.cpp:178-194. It does NOT throw. | controller-namespace | yes |
| P2 | Cluster children — `getClusterChildren` | none | geoJsonSource.getClusterChildren(clusterId: number): Promise<Feature[]> | -[MLNShapeSource childrenOfCluster:] (MLNShapeSource.h:426); note at :422-424 that the result may contain the cluster itself | queryFeatureExtensions(..., "supercluster", "children") — getter at src/mbgl/renderer/sources/render_geojson_source.cpp:29-34; GeoJSONData::getChildren (geojson_source.hpp:55) | controller-namespace | yes |
| P2 | Cluster leaves — `getClusterLeaves` (paginated) | none | geoJsonSource.getClusterLeaves(clusterId: number, limit: number, offset: number): Promise<Feature[]> | -[MLNShapeSource leavesOfCluster:offset:limit:] (MLNShapeSource.h:408) — note Apple's argument ORDER is offset-then-limit, the reverse of gl-js | queryFeatureExtensions(..., "supercluster", "leaves", {"limit", "offset"}) — src/mbgl/renderer/sources/render_geojson_source.cpp:36-52; defaults to limit=10, offset=0 when args are absent; GeoJSONData::getLeaves (geojson_source.hpp:56) | controller-namespace | yes |
| P2 | CustomGeometrySource (computed / on-demand tiles) | none | — (no equivalent; gl-js's nearest is addProtocol/custom source, different model) *(unverified)* | MLNComputedShapeSource (MLNComputedShapeSource.h:90) with MLNComputedShapeSourceDataSource (:43): featuresInTileAtX:y:zoomLevel: (:53) or featuresInCoordinateBounds:zoomLevel: (:63), plus invalidateBounds: (:141), invalidateTileAtX:y:zoomLevel: (:150), setFeatures:inTileAtX:y:zoomLevel: (:161), requestQueue (:175) | style::CustomGeometrySource (include/mbgl/style/sources/custom_geometry_source.hpp:24-62): Options{fetchTileFunction, cancelTileFunction, zoomRange, TileOptions{tolerance,tileSize,buffer,clip,wrap}} (:26-39), setTileData (:45), invalidateTile (:46), invalidateRegion (:47) | capability-interface | yes |
| P2 | Feature state — `getFeatureState` | none | map.getFeatureState(feature: FeatureIdentifier): any | — none | Renderer::getFeatureState(FeatureState& out, sourceID, optional<sourceLayerID>, featureID) (include/mbgl/renderer/renderer.hpp:79-82) | controller-namespace | yes |
| P2 | Feature state — `removeFeatureState` (and Android's `resetFeatureStates`) | none | map.removeFeatureState(feature: FeatureIdentifier, key?: string): this | — none | Renderer::removeFeatureState(sourceID, optional<sourceLayerID>, optional<featureID>, optional<stateKey>) (include/mbgl/renderer/renderer.hpp:84-87) — BOTH trailing args optional, so 'clear one key', 'clear one feature', and 'clear the whole source' are one call | controller-namespace | yes |
| P2 | GeoJSON `getBounds` | none | geoJsonSource.getBounds(): Promise<LngLatBounds> | — | NOT IN CORE for geojson. Tile sources carry a declared Tileset::bounds (util/tileset.hpp:36) but that is TileJSON metadata, not a data extent | reject | no |
| P2 | GeoJSON `setData` — inline data | present | geoJsonSource.setData(data: string \| GeoJSON): Promise<void> | MLNShapeSource.shape property, settable (MLNShapeSource.h:354) — 'Actions must be performed on the application's main thread' | style::GeoJSONSource::setGeoJSON(const GeoJSON&) (include/mbgl/style/sources/geojson_source.hpp:67) | controller-namespace | no |
| P2 | GeoJSON clustering — `clusterProperties` | present | source spec `clusterProperties: {name: [operator, mapExpression]}` *(unverified)* | MLNShapeSourceOptionClusterProperties (MLNShapeSource.h:88) — a dict of two NSExpressions | geojson_options.cpp:111-176 — the richest converter in the file; supports both the [operator, mapExpr] short form and a full reduce expression referencing ['accumulated'] | controller-namespace | no |
| P2 | GeoJSON clustering — `cluster` | present | source spec `cluster: boolean` *(unverified)* | MLNShapeSourceOptionClustered (MLNShapeSource.h:35) | geojson_options.cpp:53-61 → GeoJSONOptions::cluster (geojson_source.hpp:29) | controller-namespace | no |
| P2 | GeoJSON source — add with a `data` URL | present | map.addSource(id, {type:'geojson', data: 'https://…/x.geojson'}) | -[MLNShapeSource initWithIdentifier:URL:options:] (MLNShapeSource.h:241); URL property at :362 | source.cpp:170-171 string branch → GeoJSONSource::setURL (geojson_source.hpp:66) | controller-namespace | no |
| P2 | GeoJSON source — add with inline data | present | map.addSource(id, {type:'geojson', data: {...}}) | -[MLNShapeSource initWithIdentifier:shape:options:] (MLNShapeSource.h:277) / …features:options: (:307) / …shapes:options: (:337) | convertGeoJSONSource (src/mbgl/style/conversion/source.cpp:148-176), object branch at :164-169 → GeoJSONSource::setGeoJSON (style/sources/geojson_source.hpp:67) | controller-namespace | no |
| P2 | GeoJSON — `filter` (pre-tiling filter) | internal-only | source spec `filter` (an expression, applied before tiling) *(unverified)* | — (no MLNShapeSourceOption for it) | NOT IN CORE — Converter<GeoJSONOptions> (geojson_options.cpp:11-178) never reads `filter` | controller-namespace | no |
| P2 | GeoJSON — `lineMetrics` (required for `line-gradient`) | present | source spec `lineMetrics: boolean` *(unverified)* | MLNShapeSourceOptionLineDistanceMetrics (MLNShapeSource.h:164) — explicitly documented as the prerequisite for MLNLineStyleLayer.lineGradient | geojson_options.cpp:91-99 → GeoJSONOptions::lineMetrics (geojson_source.hpp:26) | controller-namespace | no |
| P2 | Image source `setCoordinates` | none | imageSource.setCoordinates(coordinates: Coordinates): this | MLNImageSource.coordinates property (MLNImageSource.h:108) plus explicit -setCoordinates: (:115) | style::ImageSource::setCoordinates(const std::array<LatLng,4>&) (include/mbgl/style/sources/image_source.hpp:25); read back getCoordinates() (:26) | controller-namespace | yes |
| P2 | Image source `updateImage` — by URL | none | imageSource.updateImage(options: UpdateImageOptions): this — {url?, image?, coordinates?}, exactly one of url/image | MLNImageSource.URL property (MLNImageSource.h:88) and -setURL: (:95) | style::ImageSource::setURL(const std::string&) (image_source.hpp:21) | controller-namespace | yes |
| P2 | Image source `updateImage` — by raw pixels | none | updateImage({image}) where image is ImageBitmap/HTMLImageElement/ImageData | MLNImageSource.image property, an MLNImage (MLNImageSource.h:103); -initWithIdentifier:coordinateQuad:image: (:76) | style::ImageSource::setImage(PremultipliedImage&&) (image_source.hpp:23) | controller-namespace | yes |
| P2 | Image source — add (`url` + `coordinates`) | present | map.addSource(id, {type:'image', url, coordinates}) | -[MLNImageSource initWithIdentifier:coordinateQuad:URL:] (MLNImageSource.h:63); MLNCoordinateQuad at MLNGeometry.h:85-94 | convertImageSource (src/mbgl/style/conversion/source.cpp:178-203) → style::ImageSource(id, std::array<LatLng,4>) (style/sources/image_source.hpp:17) | controller-namespace | no |
| P2 | Raster source — add (url / tiles) | present | map.addSource(id, {type:'raster', tiles\|url, tileSize}) | -[MLNRasterTileSource initWithIdentifier:configurationURL:] (MLNRasterTileSource.h:89), …configurationURL:tileSize: (:112), …tileURLTemplates:options: (:136) | convertRasterSource (src/mbgl/style/conversion/source.cpp:39-58) → style::RasterSource (style/sources/raster_source.hpp:12) | controller-namespace | no |
| P2 | Raster-DEM source — add | present | map.addSource(id, {type:'raster-dem', …}) *(unverified)* | MLNRasterDEMSource : MLNRasterTileSource (MLNRasterDEMSource.h:70) — inherits all the raster initialisers | convertRasterDEMSource (src/mbgl/style/conversion/source.cpp:60-84) → style::RasterDEMSource (style/sources/raster_dem_source.hpp:18) | controller-namespace | no |
| P2 | Raster-DEM — `encoding` mapbox / terrarium | present | source spec `encoding: 'terrarium'\|'mapbox'\|'custom'` *(unverified)* | MLNTileSourceOptionDEMEncoding (MLNRasterDEMSource.h:16) with MLNDEMEncoding{Mapbox=0, Terrarium=1} (:22-35) | Converter<SourceOptions> (src/mbgl/style/conversion/source_options.cpp:9-28) → Tileset::RasterEncoding (util/tileset.hpp:21-24) | controller-namespace | no |
| P2 | Raster-DEM — custom encoding factors (`redFactor`/`blueFactor`/`greenFactor`/`baseShift`) | internal-only | source spec redFactor/blueFactor/greenFactor/baseShift *(unverified)* | — (MLNDEMEncoding has only Mapbox and Terrarium) | NOT IN CORE — Converter<SourceOptions> (source_options.cpp:9-28) reads only `encoding`; zero hits for redFactor/baseShift in the submodule | reject | no |
| P2 | Vector / Raster / Raster-DEM source — `volatile` | internal-only | source spec `volatile: boolean` *(unverified)* | — (not exposed on MLNSource/MLNTileSource) | style::Source::isVolatile()/setVolatile() (include/mbgl/style/source.hpp:80-81) — but NO converter calls it; not parsed from source JSON | controller-namespace | yes |
| P2 | Vector source `setTiles` at runtime | none | vectorTileSource.setTiles(tiles: string[]): this | — (MLNVectorTileSource is init-only) | style::VectorSource::setTiles(const std::vector<std::string>&) (include/mbgl/style/sources/vector_source.hpp:30); read back with getTiles() (:26) | controller-namespace | yes |
| P2 | Vector source — `attribution` | present | source spec `attribution`; readable as `source.attribution` | MLNTileSourceOptionAttributionHTMLString (MLNTileSource.h:72/95) and MLNTileSourceOptionAttributionInfos (:81/104) | tileset.cpp:70-78 → Tileset::attribution; readback via style::Source::getAttribution() (include/mbgl/style/source.hpp:77) | controller-namespace | no |
| P2 | Vector source — `encoding` (mvt / mlt) | present | source spec `encoding: 'mvt'\|'mlt'` *(unverified)* | MLNVectorTileSourceOptionEncoding (MLNVectorTileSource.h:15) with MLNVectorTileSourceEncoding{Mapbox=0, MLT=1} (:21-32) | convertVectorSource parses 'mvt'/'mlt' (src/mbgl/style/conversion/source.cpp:114-125) → Tileset::VectorEncoding (util/tileset.hpp:25-28); dispatched to VectorMLTTile at src/mbgl/renderer/sources/render_vector_source.cpp:39-44 | controller-namespace | no |
| P2 | Vector source — `tiles` URL templates | present | map.addSource(id, {type:'vector', tiles:[…]}) | -[MLNVectorTileSource initWithIdentifier:tileURLTemplates:options:] (MLNVectorTileSource.h:158) | Converter<Tileset> reads `tiles` (src/mbgl/style/conversion/tileset.cpp:14-32); mbgl::Tileset::tiles (util/tileset.hpp:30) | controller-namespace | no |
| P2 | Vector source — add by TileJSON `url` | present | map.addSource(id, {type:'vector', url}) | -[MLNVectorTileSource initWithIdentifier:configurationURL:] (MLNVectorTileSource.h:111); also …configurationURLString: (:135) for pmtiles:// URLs NSURL mis-parses | style::VectorSource(id, variant<string,Tileset>, …) (style/sources/vector_source.hpp:16); URL branch at src/mbgl/style/conversion/source.cpp:22-37 | controller-namespace | no |
| P2 | `LatLngQuad` value type (image-source corners) | none | Coordinates = [[lng,lat],[lng,lat],[lng,lat],[lng,lat]] — TL, TR, BR, BL | MLNCoordinateQuad struct {topLeft, bottomLeft, bottomRight, topRight} (MLNGeometry.h:85-94) + MLNCoordinateQuadMake (:112) + MLNCoordinateQuadFromCoordinateBounds (:129) | std::array<LatLng,4> in spec order (include/mbgl/style/sources/image_source.hpp:17,25) | value-type | no |
| P2 | `addSource` — the operation | present | map.addSource(id: string, source: SourceSpecification): this | -[MLNStyle addSource:] (MLNStyle.h:130) | style::Style::addSource(std::unique_ptr<Source>) (include/mbgl/style/style.hpp:61) | controller-namespace | no |
| P2 | `isSourceLoaded` | none | map.isSourceLoaded(id: string): boolean; also source.loaded() | — (no direct API; inferred from mapView:sourceDidChange: + MLNMapViewDelegate) | style::Source::loaded — a public bool field (include/mbgl/style/source.hpp:123) | controller-namespace | yes |
| P2 | `querySourceFeatures` | none | map.querySourceFeatures(sourceId: string, options?: QuerySourceFeatureOptions) — {sourceLayer?: string, filter?: FilterSpecification, validate?: boolean} | -[MLNShapeSource featuresMatchingPredicate:] (MLNShapeSource.h:392) and -[MLNVectorTileSource featuresInSourceLayersWithIdentifiers:predicate:] (MLNVectorTileSource.h:200) | Renderer::querySourceFeatures(sourceID, SourceQueryOptions{sourceLayers, filter}) (include/mbgl/renderer/renderer.hpp:61); options at include/mbgl/renderer/query.hpp:30-41 — sourceLayers 'required for VectorSource, ignored for GeoJSONSource' | controller-namespace | yes |
| P2 | `removeSource` | present | map.removeSource(id: string): this | -[MLNStyle removeSource:] (MLNStyle.h:137) and -[MLNStyle removeSource:error:] (:149) returning BOOL + NSError | style::Style::removeSource(const std::string&) (style.hpp:62) | controller-namespace | no |
| P2 | `sourcedata` event (source loaded / data changed) | none | map.on('sourcedata', e) → MapSourceDataEvent {sourceId, sourceDataType: 'metadata'\|'content'\|'visibility'\|'idle', isSourceLoaded, source, tile, coord} | -[MLNMapViewDelegate mapView:sourceDidChange:] (MLNMapViewDelegate.h:329) | MapObserver::onSourceChanged(style::Source&) (include/mbgl/map/map_observer.hpp:65); also onDidBecomeIdle() (:66) | capability-interface | yes |
| P3 | Canvas source | none | map.addSource(id, {type:'canvas', canvas, coordinates, animate}); CanvasSource.play/pause/getCanvas *(unverified)* | — | NOT IN CORE | reject | no |
| P3 | Duplicate scheme enums (`VectorScheme` vs `RasterScheme`) | partial | one `scheme` value in the spec, no per-source type *(unverified)* | ONE enum, MLNTileCoordinateSystem, shared by every tile source (MLNTileSource.h:124-143) | ONE enum, Tileset::Scheme (include/mbgl/util/tileset.hpp:17-20) | value-type | no |
| P3 | GeoJSON `getClusterOptions` / `setClusterOptions` | none | getClusterOptions(): GetClusterOptions {cluster, clusterMaxZoom, clusterRadius}; setClusterOptions(options): Promise<void> | — (options are init-only on MLNShapeSource, MLNShapeSource.h:241/277) | READ only: GeoJSONSource::getOptions() returns a const ref (geojson_source.hpp:71). NO setter — options are Immutable<GeoJSONOptions> fixed at construction (:63) | reject | yes |
| P3 | GeoJSON `getData` | none | geoJsonSource.getData(): Promise<GeoJSON> | MLNShapeSource.shape is readable (MLNShapeSource.h:354) — Apple DOES have this | NOT IN CORE — no reader on GeoJSONSource; only getURL() (geojson_source.hpp:70) and getOptions() (:71) | reject | no |
| P3 | GeoJSON `updateData` (incremental diff) | none | geoJsonSource.updateData(diff: GeoJSONSourceDiff): Promise<void>; GeoJSONSourceDiff = {removeAll?: boolean, remove?: GeoJSONFeatureId[], add?: Feature[], update?: GeoJSONFeatureDiff[]}, applied in order remove→add→update | — (MLNShapeSource has whole-shape replacement only) | NOT IN CORE — GeoJSONSource offers only setURL/setGeoJSON/setGeoJSONData (geojson_source.hpp:66-68); no diff path | reject | no |
| P3 | GeoJSON clustering — `clusterRadius` / `clusterMaxZoom` / `clusterMinPoints` | present | source spec clusterRadius / clusterMaxZoom / clusterMinPoints *(unverified)* | MLNShapeSourceOptionClusterRadius (:45), …MaximumZoomLevelForClustering (:103), …ClusterMinPoints (:54) | geojson_options.cpp:63-89 → GeoJSONOptions::{clusterRadius, clusterMaxZoom, clusterMinPoints} (geojson_source.hpp:30-32) | controller-namespace | no |
| P3 | GeoJSON — `attribution` | present | source spec `attribution` *(unverified)* | — (MLNShapeSource is not an MLNTileSource, so it has no attribution option) | Source::getAttribution() (include/mbgl/style/source.hpp:77). Whether the geojson converter stores it: not set by convertGeoJSONSource (source.cpp:148-176) — the attribution lives on Source::Impl only for tile sources | controller-namespace | no |
| P3 | GeoJSON — `buffer` | present | source spec `buffer` (default 128) *(unverified)* | MLNShapeSourceOptionBuffer (MLNShapeSource.h:139) | geojson_options.cpp:33-41 → GeoJSONOptions::buffer (geojson_source.hpp:23) | controller-namespace | no |
| P3 | GeoJSON — `maxzoom` | present | source spec `maxzoom` (default 18) *(unverified)* | MLNShapeSourceOptionMaximumZoomLevel (MLNShapeSource.h:127) | geojson_options.cpp:24-31 → GeoJSONOptions::maxzoom (style/sources/geojson_source.hpp:22) | controller-namespace | no |
| P3 | GeoJSON — `minzoom` (mbgl + Apple only, NOT in the spec) | none | — | MLNShapeSourceOptionMinimumZoomLevel (MLNShapeSource.h:115) — documented as spec-backed, but the spec does not have it for geojson | Converter<GeoJSONOptions> DOES read `minzoom` (src/mbgl/style/conversion/geojson_options.cpp:13-21) → GeoJSONOptions::minzoom (geojson_source.hpp:21) | controller-namespace | no |
| P3 | GeoJSON — `synchronousUpdate` (mbgl + Apple only, NOT in the spec) | none | — | MLNShapeSourceOptionSynchronousUpdate (MLNShapeSource.h:170) | Converter<GeoJSONOptions> reads it (src/mbgl/style/conversion/geojson_options.cpp:101-109) → GeoJSONOptions::synchronousUpdate (style/sources/geojson_source.hpp:39); queryable via GeoJSONSource::isUpdateSynchronous() (:82) | controller-namespace | no |
| P3 | GeoJSON — `tolerance` | present | source spec `tolerance` (default 0.375) *(unverified)* | MLNShapeSourceOptionSimplificationTolerance (MLNShapeSource.h:151) | geojson_options.cpp:43-51 → GeoJSONOptions::tolerance (geojson_source.hpp:24) | controller-namespace | no |
| P3 | Raster source `setTiles` / any source `setUrl` at runtime | none | rasterTileSource.setTiles(tiles) / setUrl(url); vectorTileSource.setUrl(url) | — (init-only) | NOT IN CORE — raster_source.hpp declares only the ctor; TileSource (tile_source.hpp:13-35) has getURLOrTileset/getURL/getTileSize and no setter. VectorSource has setTiles but no setUrl. | reject | no |
| P3 | Raster source — `tileSize` | present | source spec `tileSize` (default 512) *(unverified)* | MLNTileSourceOptionTileSize (MLNRasterTileSource.h:23) | src/mbgl/style/conversion/source.cpp:45-56 → RasterSource ctor uint16_t tileSize | controller-namespace | no |
| P3 | Source runtime tuning — `setMaxOverscaleFactorForParentTiles` | none | — | — | style::Source::setMaxOverscaleFactorForParentTiles(optional<uint8_t>) / get… (include/mbgl/style/source.hpp:117-118), documented at :105-116 | controller-namespace | yes |
| P3 | Source runtime tuning — `setMinimumTileUpdateInterval` | none | — | — | style::Source::setMinimumTileUpdateInterval(Duration) / get… (include/mbgl/style/source.hpp:102-103); default Duration::zero() | controller-namespace | yes |
| P3 | Source runtime tuning — `setPrefetchZoomDelta` | none | — | — (not on MLNSource; MLNSource.h is 56 lines and exposes only `identifier`) | style::Source::setPrefetchZoomDelta(optional<uint8_t>) / getPrefetchZoomDelta() (include/mbgl/style/source.hpp:93-94); map-wide variant Map::setPrefetchZoomDelta (map/map.hpp:143) | controller-namespace | yes |
| P3 | Source tile lifecycle events (`onTileAction`) | none | — (gl-js's dataloading/sourcedataabort are coarser and differently shaped; not equivalent, so left blank rather than mis-mapped) | -[MLNMapViewDelegate mapView:tileDidTriggerAction:x:y:z:wrap:overscaledZ:sourceID:] (MLNMapViewDelegate.h:469) with MLNTileOperation (MLNTileOperation.h:3-13, 9 cases incl. RequestedFromCache, LoadFromNetwork, StartParse, Error, Cancelled) | MapObserver::onTileAction(TileOperation, const OverscaledTileID&, const std::string& sourceID) (include/mbgl/map/map_observer.hpp:86); enum at include/mbgl/tile/tile_operation.hpp | capability-interface | yes |
| P3 | Vector source — `bounds` | present | source spec `bounds: [sw.lng, sw.lat, ne.lng, ne.lat]` *(unverified)* | MLNTileSourceOptionCoordinateBounds (MLNTileSource.h:56), an MLNCoordinateBounds boxed in NSValue | Converter<Tileset> bounds branch (src/mbgl/style/conversion/tileset.cpp:80-118) → Tileset::bounds (util/tileset.hpp:36) | controller-namespace | no |
| P3 | Vector source — `minzoom` / `maxzoom` | present | source spec `minzoom` / `maxzoom` *(unverified)* | MLNTileSourceOptionMinimumZoomLevel / …MaximumZoomLevel (MLNTileSource.h:28, :42) | convertVectorSource reads both and passes them as ctor args (src/mbgl/style/conversion/source.cpp:96-113); Tileset::zoomRange (util/tileset.hpp:31) | controller-namespace | no |
| P3 | Vector source — `scheme` (xyz/tms) | present | source spec `scheme: 'xyz'\|'tms'` *(unverified)* | MLNTileSourceOptionTileCoordinateSystem (MLNTileSource.h:118) with MLNTileCoordinateSystem{XYZ,TMS} (:124-143) | tileset.cpp:34-40 → Tileset::Scheme (util/tileset.hpp:17-20) | controller-namespace | no |
| P3 | Video source | internal-only | map.addSource(id, {type:'video', urls, coordinates}) *(unverified)* | — | NOT IN CORE — src/mbgl/style/conversion/source.cpp:226-238 accepts only raster/raster-dem/vector/geojson/image and returns error 'invalid source type' | reject | no |

#### Proposed signatures

**`MapLibreFeature` value type — queried features lose geometry and id** — P0, `value-type`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:15 MapLibreQueriedFeature carries only (point, properties); the decoder at :215 does `if (geometry['type'] != 'Point') continue;` and never reads feature['id']
```dart
class MapLibreFeature { final Object? id; final MapLibreGeometry geometry; final Map<String, Object?> properties; bool get isCluster; int? get clusterId; int get pointCount; }
```
> **p0 defect, pure Dart, no C ABI.** The native side already hands over a complete FeatureCollection with every geometry type and every feature id — the Dart decoder throws it away. Consequences: (1) querying a line or fill layer returns an EMPTY list, silently; (2) `feature.id` is unreachable, which makes setFeatureState unusable even once bound; (3) the same decoder is what querySourceFeatures and the cluster helpers will reuse, so every new query API inherits the bug. Apple's class hierarchy is the model, and its MLNCluster protocol (clusterIdentifier/clusterPointCount) is exactly the isCluster/clusterId/pointCount convenience our MapLibreQueriedFeature already half-implements at :27-30. Keep MapLibreQueriedFeature as a deprecated alias.

**`addSource` — duplicate-id / invalid-document error reporting** — P0, `controller-namespace`, evidence: native: maplibre_flutter_core.cpp:1558-1565 catches the runtime_error and only fprintf(stderr). web: maplibre_flutter_core_web.cpp:419-423 returns it, core_web_controller.dart:269 throws ArgumentError
```dart
Future<void> addSource(String id, StyleSource source);  // completes with an error, uniformly on all six tiers
```
> **p0: the same call has two different contracts on tiers that share an engine.** Native swallows a duplicate id into stderr; web throws. Every upstream reports it. Fix shape: make the C ABI post-and-report — either (a) an optional completion callback carrying the render-thread error, or (b) do the duplicate check synchronously against a shim-side id set before posting (cheap, catches the overwhelmingly common case). (b) is a small change and closes the divergence without a round trip. Note the current sync `int` return only covers PARSE errors (.cpp:1552-1555), which is why the shape reads as if errors were handled.

**Blocking query calls on the UI isolate** — P1, `controller-namespace`, evidence: mbl_map_query_rendered_features waits on a condvar for timeout_ms (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1769-1772), and the Dart side is synchronous all the way up (style_layers.dart:78, map_layers_controller.dart:196)
```dart
Future<…> for every new query: querySourceFeatures, getCluster*, getFeatureState, isSourceLoaded, getSource
```
> Not a source feature, but a design decision this backlog forces: the domain adds ~8 render-thread round trips. CLAUDE.md §5a already says long-running calls belong off the UI isolate, and the existing sync query is the counter-example (a busy render thread costs a stalled frame, up to timeout_ms). Decide now, before eight more entry points copy the pattern. The SDKs look synchronous only because they have no thread boundary; gl-js — which does — is async, and that is the right precedent for us.

**Cluster expansion zoom — `getClusterExpansionZoom`** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart; cluster_id is already surfaced to Dart via MapLibreQueriedFeature.properties (map_layers_controller.dart:23)
```dart
Future<double?> getClusterExpansionZoom(String sourceId, int clusterId)  // + convenience on MapLibreGeoJsonSource
```
> **p1: we ship clustering but not the one interaction every clustered map has** — tap a bubble, zoom to where it breaks apart. Users can already get `cluster_id` out of queryRenderedFeatures, so this is the missing last step. All three upstreams have it; mbgl has it; one C ABI call. Return type double per Apple/gl-js (mbgl gives uint8_t, widen it). Make it a Future — do NOT copy the blocking pattern of mbl_map_query_rendered_features (maplibre_flutter_core.h:246).

**Feature state — `setFeatureState`** — P1, `controller-namespace`, evidence: nothing anywhere; would live in style_layers.dart + a new C ABI
```dart
Future<void> setFeatureState({required String source, String? sourceLayer, required Object id, required Map<String, Object?> state})
```
> **p1 — hover and selection highlighting is the single most requested interactive-map behaviour and this is the only way to do it without re-uploading the whole source.** Fully backed by mbgl. gl-js's FeatureIdentifier shape wins over Android's split because it maps 1:1 onto mbgl's argument list. **Caveat that MUST be in the dartdoc:** because promoteId and generateId are unimplemented in core (see those rows), the feature's own `id` must already be an integer or an integer-castable string — otherwise nothing matches and nothing highlights. That interaction is exactly why those two rows are p1 too.

**GeoJSON `setData` — with a URL** — P1, `controller-namespace`, evidence: maplibre_flutter_core.cpp:1607-1613 runs convertJSON<mbgl::GeoJSON>(geojson) which cannot parse a bare URL string; same on web (maplibre_flutter_core_web.cpp:448-451)
```dart
geoJsonSource.setData(GeoJsonData.url('https://…/live.geojson'))  // same method, URL variant
```
> p1: polling a server-rendered GeoJSON endpoint is THE canonical live-data pattern and all three upstreams document it as the primary use of the source. The C ABI addition is trivial — `mbl_map_set_geojson_url(map, source_id, url)` calling setURL — but it must be a separate entry point because the existing one parses eagerly. Alternatively give the existing one a `bool is_url` flag.

**GeoJSON — `generateId`** — P1, `controller-namespace`, evidence: style_sources.g.dart:451, serialised :477
```dart
@Deprecated('Not implemented by mbgl-core; assign a numeric `id` on each GeoJSON Feature yourself.') final bool? generateId;
```
> p1 for the same reason as promoteId: it is the *easy* way to make feature state work, and it is a no-op here. The workable substitute is cheap and we should ship it: `GeoJsonData.points(pts, generateIds: true)` writing a numeric `id` on each Feature in Dart (geojson_data.dart:39-53 already builds the features). That is a pure-Dart fix with no C ABI. Neither Apple nor Android has this option either, so it is a genuine gl-js-only convenience.

**GeoJSON — `promoteId`** — P1, `controller-namespace`, evidence: style_sources.g.dart:457, serialised :478
```dart
@Deprecated('Not implemented by mbgl-core.') final Object? promoteId;
```
> Same annotation. Together with generateId this means: on our engine, feature state requires the data to carry a numeric/castable `id` already.

**List the style's sources / `getStyle().sources`** — P1, `controller-namespace`, evidence: no style-readback entry point exists — grep FFI_PLUGIN_EXPORT in packages/maplibre_flutter_core/src/maplibre_flutter_core.h shows no getter for style JSON or source ids
```dart
Future<List<String>> get sourceIds;  // plus Future<String> getStyleJson() as the full-document hatch
```
> Cheapest high-value entry point in the whole domain: `Style::getJSON()` is one call and yields `getStyle()` for the layers domain too. Without it there is no way to discover what a loaded basemap declares — so no 'insert my layer under the labels', no attribution UI, no debugging. Both SDKs expose the collection; gl-js exposes the whole document. Bind BOTH: ids for the common case, JSON for the hatch.

**Source attribution accessor (read-back)** — P1, `controller-namespace`, evidence: settable via the generated `attribution` field (style_sources.g.dart:76/181/269) but never readable; no attribution UI anywhere in packages/maplibre_flutter/lib/src/
```dart
Future<List<String>> get attributions;  // every source's attribution, deduped — on controller.sources
```
> **p1 for a non-technical reason: attribution is a licence obligation** for OSM-derived tiles, and we currently give an app no way to read what the loaded style requires. Both SDKs consider it important enough to model richly (Apple parses the HTML into tappable buttons). Falls out of getSource/getStyleJson almost for free. The attribution *widget* belongs to the controls domain, but the data must come from here.

**Vector source — `promoteId`** — P1, `controller-namespace`, evidence: style_sources.g.dart:84 — the field exists and serialises (:107) but mbgl never reads it
```dart
@Deprecated('Not implemented by mbgl-core; feature ids must come from the feature\'s own `id`.') final Object? promoteId;
```
> p1 because it fails SILENTLY and takes feature-state down with it: a user sets promoteId:'name', calls setFeatureState with id 'Paris', and nothing ever highlights. Fix: teach tool/generate_style_api.dart a small `coreUnsupported` set that injects a doc/@Deprecated line — it does NOT reintroduce an allowlist for coverage (the field is still generated), it annotates. Then correct FEATURE_MATRIX.md:133 to ➖.

**Web tier: source support exists but the matrix says it does not** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:44-49 implements MapLibreStyleLayers; addSourceJson :265, addLayerJson :273, setGeoJsonData :281, removeSource :295, addImage :301, queryRenderedFeaturesJson :335. Backed by packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:412, :448, :472 and the embind table at :1016-1020
```dart
— (no new API; correct the matrix)
```
> **The single largest staleness in FEATURE_MATRIX for this domain, and it errs in our favour** — it under-reports what we ship, which means the backlog is being planned against a false picture of the biggest 'gap'. Web should read 🧪 (wired, unrun in a browser) for every row the native tiers read 🧪. Do the same audit for sections 2 and 7 before trusting any Web column.

**`LatLngBounds` value type (source `bounds`, fit-to-data)** — P1, `value-type`, evidence: absent from packages/maplibre_flutter_platform_interface/lib/src/lat_lng.dart
```dart
class LatLngBounds { const LatLngBounds({required LatLng southwest, required LatLng northeast}); factory LatLngBounds.ofPoints(Iterable<LatLng>); List<double> toSpecBounds(); }
```
> Shared prerequisite for this domain (source `bounds`, CustomGeometrySource.invalidateRegion, the getBounds substitute) AND the camera domain (fitBounds). All three upstreams model it as sw/ne named corners; only the spec's serialised form is a flat 4-array, so keep the flattening inside toSpecBounds() and never expose the array. Coordinate every choice here with the camera domain's spec — this type must be defined once.

**`areTilesLoaded` / fully-loaded** — P1, `controller`, evidence: no entry point; nearest is mbl_map_await_frame (maplibre_flutter_core.h:275) which only proves A frame arrived
```dart
Future<bool> get isFullyLoaded;  // on the controller, not the sources namespace — it is map-wide
```
> Directly serves CLAUDE.md §7's own rule: "'a frame came back' does not prove the map is visible". This is the assertion integration tests on Windows/Linux/Android actually want before screenshotting. Bind it and use it in the harnesses. mbgl's name (isFullyLoaded) is broader than gl-js's areTilesLoaded — keep mbgl's, it is more accurate and matches gl-js's `map.loaded()` semantics.

**`getSource`** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart (flat) + a MapLibreSource handle in packages/maplibre_flutter/lib/src/
```dart
Future<MapLibreSource?> getSource(String id);  // MapLibreSource sealed: MapLibreGeoJsonSource | MapLibreVectorSource | MapLibreRasterSource | MapLibreRasterDemSource | MapLibreImageSource
```
> **The keystone row.** Every per-source mutation below hangs off this in all three upstreams, and a Dart `sealed` class over `Source::getType()` gives exhaustive switch for free. The handle needs only (id, type, back-reference) — no native pointer, so no lifetime hazard. Underneath, one flat call `Future<String?> getSourceJson(String id)` returning `{id, type, attribution, volatile, loaded}` is enough to construct it.

**`removeSource` — silent failure while a layer still uses it** — P1, `controller-namespace`, evidence: maplibre_flutter_core.cpp:1644-1651 — posts and returns void; nothing can report the refusal. removePoints (map_layers_controller.dart:369-374) works only because it deletes layers first
```dart
Future<bool> removeSource(String id)  // Apple's shape: false when a layer still references it
```
> The classic teardown bug: remove the source, keep a layer, get a silently-still-there source and a stale-data leak. Apple is the only upstream that models it honestly (BOOL + NSError) and mbgl's nullptr return is exactly that signal — we throw the return value away. Copy Apple. A cheap alternative that needs no round trip: `removeSourceAndLayers(id)` that enumerates layers with that source first, mirroring what removePoints does by hand.

**Cluster children — `getClusterChildren`** — P2, `controller-namespace`, evidence: as above
```dart
Future<List<MapLibreFeature>> getClusterChildren(String sourceId, int clusterId)
```
> Returns a GeoJSON FeatureCollection string over the ABI, decoded with the same mapbox::geojson::stringify path already used at maplibre_flutter_core.cpp:1750-1753 — so the native side is near-free once the extension call is written. Apple's caveat (the cluster can be its own child) is a real behaviour worth carrying into our dartdoc.

**Cluster leaves — `getClusterLeaves` (paginated)** — P2, `controller-namespace`, evidence: as above
```dart
Future<List<MapLibreFeature>> getClusterLeaves(String sourceId, int clusterId, {int limit = 10, int offset = 0})
```
> Upstreams disagree on argument order (gl-js/Android limit-then-offset; Apple offset-then-limit). Dart named parameters make the disagreement vanish — take both as named, and use mbgl's own defaults (limit 10, offset 0, render_geojson_source.cpp:51) so an argument-less call behaves like the engine. This is the 'expand the cluster into a list' interaction.

**CustomGeometrySource (computed / on-demand tiles)** — P2, `capability-interface`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart (or a new custom_source.dart capability) + a new C ABI callback pair
```dart
abstract interface class MapLibreComputedSource { void addComputedSource(String id, {required int minZoom, int maxZoom, ...}); void setTileData(String id, int z, int x, int y, String geoJson); void invalidateTile(String id, int z, int x, int y); void invalidateRegion(String id, LatLngBounds bounds); } // + a Dart tile-request callback
```
> The only source type where a Dart app can serve its own data lazily — the answer for datasets too big to ship as one GeoJSON blob (a local database, a custom binary format). Non-trivial: needs a native→Dart callback delivered off the render thread, so a `NativeCallable.listener` on a helper isolate, matching the pattern in CLAUDE.md §5e. Both SDKs run it on a dedicated queue (Apple's `requestQueue`, :175) for the same reason. Correct the matrix row first — a ➖ there tells future-us not to bother.

**Feature state — `getFeatureState`** — P2, `controller-namespace`, evidence: n/a
```dart
Future<Map<String, Object?>> getFeatureState({required String source, String? sourceLayer, required Object id})
```
> Out-param in C++, Future-of-map in Dart. Returns the JSON object over the ABI like every other query here.

**Feature state — `removeFeatureState` (and Android's `resetFeatureStates`)** — P2, `controller-namespace`, evidence: n/a
```dart
Future<void> removeFeatureState({required String source, String? sourceLayer, Object? id, String? key})
```
> mbgl's all-optional signature is strictly more expressive than Android's three named methods, and matches gl-js's optional `key`. Taking `id` as nullable subsumes Android's `resetFeatureStates()` — omit id to clear the source. One method, no extra names.

**GeoJSON `getBounds`** — P2, `reject`, evidence: n/a; no LatLngBounds type exists either (packages/maplibre_flutter_platform_interface/lib/src/lat_lng.dart:5 has only LatLng)
```dart
— on the source. Instead: LatLngBounds.ofPoints(Iterable<LatLng>) as a pure-Dart value-type helper
```
> Reject on the source, but the USE CASE (fit the camera to the data I just added) is table stakes and every competing plugin has it. Compute it in Dart from the GeoJSON the app already holds, and pair with camera.fitBounds. That makes LatLngBounds a prerequisite value type shared with the camera domain.

**GeoJSON `setData` — inline data** — P2, `controller-namespace`, evidence: map_layers_controller.dart:114 setGeoJsonData → style_layers.dart:36 → maplibre_flutter_core.dart:469 → mbl_map_set_geojson_data (maplibre_flutter_core.h:193, .cpp:1601); convenience setPoints at map_layers_controller.dart:365
```dart
geoJsonSource.setData(GeoJsonData data)  // via controller.sources.getSource<MapLibreGeoJsonSource>(id)
```
> Works and is the cheap live-data path. Rename to gl-js's `setData` at the app-facing layer; keep `setGeoJsonData` on the platform interface (it names the geojson-only constraint the shim enforces at .cpp:1623-1628).

**GeoJSON clustering — `clusterProperties`** — P2, `controller-namespace`, evidence: style_sources.g.dart:438 (typed as `Object?`)
```dart
GeoJsonSource(clusterProperties: {'total': ClusterProperty.sum(Expr.get('magnitude'))})  // typed, replacing the bare Object?
```
> Works via raw JSON, but `Object?` throws away everything the typed API is for, and mbgl's shape is strict (each member must be a 2-element array — geojson_options.cpp:126-132, error otherwise). A tiny hand-written `ClusterProperty` value type over the existing `Expression` would make this safe: `.sum(expr)`, `.max(expr)`, `.reduce(Expression, Expression)`. Android's three-arg builder is the right shape to copy.

**GeoJSON clustering — `cluster`** — P2, `controller-namespace`, evidence: style_sources.g.dart:401; convenience wrapper map_layers_controller.dart:258 addPoints(cluster: true)
```dart
GeoJsonSource(cluster: true)
```
> Best-verified row in the domain. Apple's header notes clustering is ignored on MLNComputedShapeSource (:27-29) — same for mbgl's CustomGeometrySource.

**GeoJSON source — add with a `data` URL** — P2, `controller-namespace`, evidence: GeoJsonData.url at style/geojson_data.dart:16
```dart
controller.sources.addSource(id, GeoJsonSource(data: GeoJsonData.url('https://…')))
```
> Works at ADD time. It is the UPDATE path (setData with a URL) that is broken — separate row below.

**GeoJSON source — add with inline data** — P2, `controller-namespace`, evidence: style_sources.g.dart:329 GeoJsonSource, :354 data; GeoJsonData.inline/points/lineThrough at style/geojson_data.dart:19,28,59; addSource at map_layers_controller.dart:97
```dart
controller.sources.addSource(id, GeoJsonSource(data: GeoJsonData.points(pts)))
```
> The best-covered row in the domain. Apple's three-way split (shape / features / shapes) exists because MLNFeature attributes are lost through the `shapes:` variant (MLNShapeSource.h:323-327); GeoJSON has no such trap, so one `data` parameter is correct.

**GeoJSON — `filter` (pre-tiling filter)** — P2, `controller-namespace`, evidence: style_sources.g.dart:378 — generated as `final Object? filter`, serialised at :466, never read
```dart
@Deprecated('Not read by mbgl-core; filter on the LAYER instead.') final Object? filter;
```
> Harmless in outcome (you get more features than you asked for) but it is a performance promise that is not kept, and the obvious workaround — filter on the layer — is not obvious to a reader who set it on the source. Same generator annotation. Android exposing withFilter while Apple does not is itself a hint it is not core-backed on the Android side either; worth a probe if we ever ship the SDK tier.

**GeoJSON — `lineMetrics` (required for `line-gradient`)** — P2, `controller-namespace`, evidence: style_sources.g.dart:444
```dart
GeoJsonSource(lineMetrics: true)
```
> Works. Worth an example: `line-gradient` is a marquee feature and silently renders nothing without this flag. Apple's header is the only upstream that says so at the point of use.

**Image source `setCoordinates`** — P2, `controller-namespace`, evidence: would live in style_layers.dart; no LatLngQuad value type exists
```dart
Future<void> setCoordinates(String sourceId, LatLngQuad coordinates)
```
> The animated-radar-overlay use case: reposition a georeferenced image without re-adding the source. All three upstreams have it and mbgl backs it. Blocked on the LatLngQuad value type (see its own row).

**Image source `updateImage` — by URL** — P2, `controller-namespace`, evidence: n/a
```dart
Future<void> updateImage(String sourceId, {String? url, MapLibreRgbaImage? image, LatLngQuad? coordinates})
```
> Copy gl-js's single `updateImage` (which folds coordinates in) rather than the SDKs' separate URL and coordinates setters — one method means one atomic frame when both change, which is what an animated overlay needs.

**Image source `updateImage` — by raw pixels** — P2, `controller-namespace`, evidence: n/a; the RGBA marshalling already exists for style images (mbl_map_add_image, maplibre_flutter_core.h:207, .cpp:1653-1664)
```dart
Future<void> updateImage(String sourceId, {MapLibreRgbaImage? image, LatLngQuad? coordinates})  // MapLibreRgbaImage(Uint8List rgba, int width, int height)
```
> This is the Flutter-native win: a widget rasterised with the EXISTING MapLibreLayersController.rasterizeWidget (map_layers_controller.dart:428) becomes a georeferenced, map-anchored, rotating overlay — a live chart or floorplan pinned to the ground plane. The RGBA copy path is already proven by mbl_map_add_image; this is the same marshalling pointed at ImageSource::setImage.

**Image source — add (`url` + `coordinates`)** — P2, `controller-namespace`, evidence: style_sources.g.dart:517 ImageSource, :527 url, :532 coordinates
```dart
controller.sources.addSource(id, ImageSource(url: '…', coordinates: LatLngQuad(topLeft:…, topRight:…, bottomRight:…, bottomLeft:…)))
```
> Corner ORDER is the trap and the three upstreams state it differently. Spec/gl-js: 'top left, top right, bottom right, bottom left' (clockwise from TL). Apple's MLNCoordinateQuad struct field order is topLeft, bottomLeft, bottomRight, topRight and its doc says 'counter clockwise order from top left' (MLNGeometry.h:81-94). mbgl just takes std::array<LatLng,4> in spec order. Our generated `List<List<double>>` (:532) is raw [lng,lat] pairs in spec order — correct but exactly the kind of positional convention CLAUDE.md §11 says to pin with an asymmetric fixture. **Introduce a named LatLngQuad value type** and let it serialise; never let a user hand-order this.

**Raster source — add (url / tiles)** — P2, `controller-namespace`, evidence: style_sources.g.dart:118 (RasterSource), :139 url, :144 tiles
```dart
controller.sources.addSource(id, RasterSource(tiles: [...], tileSize: 256))
```
> Works. Note Apple defaults tileSize to 256 for Mapbox-canonical URLs and 512 otherwise (MLNRasterTileSource.h:77-81); mbgl always defaults to util::tileSize_I (512) — so an Apple-SDK app and ours will differ on a Mapbox URL. Ours matches gl-js and the spec.

**Raster-DEM source — add** — P2, `controller-namespace`, evidence: style_sources.g.dart:208
```dart
controller.sources.addSource(id, RasterDemSource(url: 'https://…/terrain.json'))
```
> Backs both hillshade and color-relief layers (MLNRasterDEMSource.h:44-47). No blocker.

**Raster-DEM — `encoding` mapbox / terrarium** — P2, `controller-namespace`, evidence: style_sources.g.dart:274; enum RasterDemEncoding at style_enums.g.dart:360
```dart
RasterDemSource(encoding: RasterDemEncoding.terrarium)
```
> mapbox and terrarium work. `RasterDemEncoding.custom` (style_enums.g.dart:372) makes mbgl ERROR OUT — source_options.cpp:22-25 returns nullopt with 'invalid encoding', so the whole addSource fails, not just the field. That is a loud failure, unlike promoteId — but it is a generated enum value that can never be used on 6 of 6 tiers.

**Raster-DEM — custom encoding factors (`redFactor`/`blueFactor`/`greenFactor`/`baseShift`)** — P2, `reject`, evidence: style_sources.g.dart:280, :286, :292, :298 — generated, serialised at :316-319, never read by the engine
```dart
@Deprecated('mbgl-core supports only mapbox/terrarium DEM encoding; these factors are ignored.') final double? redFactor; // …
```
> Reject as a feature; annotate as generated-but-dead. Same generator mechanism as promoteId. Correct FEATURE_MATRIX.md:141 to ➖ for the five native columns.

**Vector / Raster / Raster-DEM source — `volatile`** — P2, `controller-namespace`, evidence: style_sources.g.dart:89 (vector), :186 (raster), :303 (raster-dem) — all serialise, none are read
```dart
Future<void> setVolatile(String sourceId, bool volatile);  // on controller.sources, Android-shaped
```
> The Android SDK is the only upstream that got this right: it is a runtime property, not a style-spec field, because that is what mbgl exposes. Follow Android. Keep the generated `volatile` field but annotate it as ignored, exactly like promoteId.

**Vector source `setTiles` at runtime** — P2, `controller-namespace`, evidence: no entry point
```dart
Future<void> setTiles(String sourceId, List<String> tiles)  // vector only; throws/logs on other source types
```
> Real use cases: switching tile CDN, adding a signed token, A/B-ing a tileserver — without tearing down every layer. gl-js's name is the only one on offer. The row must be SPLIT in the matrix: vector 🧪, raster ➖.

**Vector source — `attribution`** — P2, `controller-namespace`, evidence: style_sources.g.dart:76
```dart
VectorSource(attribution: '© OpenStreetMap contributors')
```
> Settable today. READING it back (for an attribution control) is a separate row — see 'Source attribution accessor'. Apple's richer MLNAttributionInfo model (clickable buttons parsed out of the HTML) has no mbgl counterpart; mbgl stores a plain string.

**Vector source — `encoding` (mvt / mlt)** — P2, `controller-namespace`, evidence: style_sources.g.dart:95; enum VectorEncoding at style_enums.g.dart:719
```dart
VectorSource(tiles: […], encoding: VectorEncoding.mlt)
```
> Works today on all six tiers. This is the single most misleading cell in FEATURE_MATRIX section 1 — it tells a reader the native tiers *cannot* do something they can. Fix the row to 🧪 (unverified, but wired).

**Vector source — `tiles` URL templates** — P2, `controller-namespace`, evidence: style_sources.g.dart:45
```dart
controller.sources.addSource(id, VectorSource(tiles: ['https://…/{z}/{x}/{y}.pbf']))
```
> Apple documents that only the FIRST template is used and the rest ignored (MLNVectorTileSource.h:151-152); mbgl actually keeps the whole vector. Our List<String> matches mbgl/gl-js, which is the better contract.

**Vector source — add by TileJSON `url`** — P2, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart:18 (VectorSource), :40 (url); serialised via map_layers_controller.dart:97
```dart
controller.sources.addSource(String id, VectorSource(url: 'https://…/tiles.json'))
```
> **Matrix drift:** line 127 — 🧪 on all five native, ❌ web. Agrees for native; DISAGREES on web (the WASM tier implements MapLibreStyleLayers, core_web_controller.dart:46-49,265).

**`LatLngQuad` value type (image-source corners)** — P2, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/lat_lng.dart:5 has only LatLng; ImageSource.coordinates is a raw List<List<double>> (style_sources.g.dart:532)
```dart
class LatLngQuad { const LatLngQuad({required LatLng topLeft, required LatLng topRight, required LatLng bottomRight, required LatLng bottomLeft}); factory LatLngQuad.fromBounds(LatLngBounds b); }
```
> **Named parameters, always** — this is a textbook CLAUDE.md §11 trap: the three upstreams state the winding differently (Apple's field order is TL,BL,BR,TR and its doc says 'counter clockwise from top left'; gl-js/spec say clockwise from TL; Android's ctor is TL,TR,BR,BL), and every ordering renders SOMETHING, so a positional list will be wrong in a way only an asymmetric fixture catches. Also add `.fromBounds`, which Apple found worth an inline helper.

**`addSource` — the operation** — P2, `controller-namespace`, evidence: map_layers_controller.dart:97 (typed) / :106 (json) → style_layers.dart:27 → maplibre_flutter_core.dart:431 → mbl_map_add_source_json (maplibre_flutter_core.h:181, impl .cpp:1543)
```dart
void addSource(String id, StyleSource source)  // move from controller.layers to controller.sources
```
> gl-js takes (id, spec) exactly as we do — the SDKs put the id inside the source object instead (MLNSource.identifier, MLNSource.h:52). gl-js's split is better here because the spec models `sources` as a map, which is also what our StyleSource base class documents (style_layer.dart:27-28). Keep it.

**`isSourceLoaded`** — P2, `controller-namespace`, evidence: would live in style_layers.dart alongside queryRenderedFeaturesJson (packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78)
```dart
Future<bool> isSourceLoaded(String id)
```
> gl-js name; there is no SDK name to conflict with. Pairs with the sourcedata event below — gl-js's own idiom is `map.on('sourcedata', e => { if (e.isSourceLoaded) … })`, so bind both or the event is half-useful.

**`querySourceFeatures`** — P2, `controller-namespace`, evidence: only queryRenderedFeatures exists — style_layers.dart:78, map_layers_controller.dart:196, mbl_map_query_rendered_features (maplibre_flutter_core.h:246)
```dart
Future<List<MapLibreFeature>> querySourceFeatures(String sourceId, {List<String>? sourceLayers, Expression? filter})
```
> Distinct from queryRenderedFeatures: returns what the source LOADED, whether or not a layer draws it — so it works before/without styling, and it is the tool for 'what's in this tile'. gl-js's flat map-level form beats the SDKs' per-source split because our sourceLayers/filter arguments are identical for both source kinds, exactly as mbgl models it. Both SDK headers carry the same warning worth copying into dartdoc: geometries are clipped at tile boundaries and features appear duplicated across tiles (MLNVectorTileSource.h:175-181).

**`removeSource`** — P2, `controller-namespace`, evidence: map_layers_controller.dart:119 → style_layers.dart:40 → maplibre_flutter_core.dart:490 → mbl_map_remove_source (maplibre_flutter_core.h:199, .cpp:1644)
```dart
void removeSource(String id)
```
> Works. See the next row for the failure mode.

**`sourcedata` event (source loaded / data changed)** — P2, `capability-interface`, evidence: the shim already has a MapObserver subclass to hang this on — FrameObserver at packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872, with onDidFinishLoadingStyle already overridden at :890
```dart
abstract interface class MapLibreSourceEvents { Stream<MapLibreSourceDataEvent> get onSourceData; }  // MapLibreSourceDataEvent(sourceId, isLoaded)
```
> Flutter-idiom adaptation, stated: gl-js's `on('sourcedata', cb)` string-keyed subscription becomes a typed Dart Stream. A separate capability interface rather than a base-contract addition, per §3. Payload is thinner than gl-js's (mbgl hands us the Source, not a sourceDataType) — expose `sourceId` + `isLoaded` (from Source::loaded, source.hpp:123) and do not invent the rest. Note this is the correct signal to drive 'my data finished loading', which today has no answer at all.

**Canvas source** — P3, `reject`, evidence: not generated — `canvas` is absent from v8.json's `source` list (verified: source = [vector, raster, raster-dem, geojson, video, image])
```dart
— (do not bind)
```
> A DOM `<canvas>` cannot exist behind a WASM-core `<canvas>`; genuinely irreducible. Only reachable through the opt-in maplibre_flutter_web_gljs package, which binds nothing beyond camera+style today.

**Duplicate scheme enums (`VectorScheme` vs `RasterScheme`)** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_enums.g.dart:404 RasterScheme{xyz,tms} and :738 VectorScheme{xyz,tms} — identical members, non-interchangeable types
```dart
enum TileScheme { xyz, tms }  // one type, used by both VectorSource and RasterSource
```
> Generator artefact: one enum minted per source-type occurrence. Both native SDKs and mbgl model it once. Fix in tool/generate_style_api.dart by keying enum identity on (member set + spec doc) rather than on the owning schema — worth doing because the same duplication will recur for every shared spec enum as coverage grows, and it forces users into meaningless casts when writing generic code over sources.

**GeoJSON `getClusterOptions` / `setClusterOptions`** — P3, `reject`, evidence: n/a
```dart
— for the setter. Optionally: the getter falls out of `getSource` returning the source's spec JSON.
```
> Both SDKs agree with mbgl that clustering is init-only, so gl-js is the outlier. Document 'remove + re-add to change clustering' rather than faking a setter — a fake would silently re-tile the whole source and lose cluster ids, which breaks any expansion-zoom the app is mid-way through.

**GeoJSON `getData`** — P3, `reject`, evidence: n/a
```dart
— (do not bind; the app already owns the data it set)
```
> The Dart-side alternative is free: keep what you passed to setData. `querySourceFeatures` (below) covers the 'what did the engine actually make of it' question, which is the useful half.

**GeoJSON `updateData` (incremental diff)** — P3, `reject`, evidence: n/a
```dart
— (do not bind)
```
> True ceiling. The mitigation to document instead: `synchronousUpdate: true` plus a whole-collection setData is fast enough for the sizes people actually animate, and `GeoJSONSource::setGeoJSONData(shared_ptr<GeoJSONData>)` (:68) is the escape hatch if we ever want a custom in-C++ provider.

**GeoJSON clustering — `clusterRadius` / `clusterMaxZoom` / `clusterMinPoints`** — P3, `controller-namespace`, evidence: style_sources.g.dart:407, :415, :421
```dart
GeoJsonSource(clusterRadius: 50, clusterMaxZoom: 14, clusterMinPoints: 2)
```
> Apple renames clusterMaxZoom to 'MaximumZoomLevelForClustering' and documents the default as maxzoom-1 (:90-104); mbgl hardcodes 17 (geojson_source.hpp:31). Our doc (style_sources.g.dart:409-412) repeats the spec's 'one zoom less than maxzoom' which is NOT what the pinned core does. Minor doc drift worth a note.

**GeoJSON — `attribution`** — P3, `controller-namespace`, evidence: style_sources.g.dart:365
```dart
GeoJsonSource(attribution: '© Someone')
```
> Probable silent no-op on geojson: convertGeoJSONSource does not touch attribution and Converter<Tileset> (which does) is not run for geojson. Apple agrees by omission — it exposes attribution options only on MLNTileSource (:72/81). Verify before trusting; if confirmed, annotate like the others.

**GeoJSON — `buffer`** — P3, `controller-namespace`, evidence: style_sources.g.dart:372
```dart
GeoJsonSource(buffer: 128)
```
> Fine.

**GeoJSON — `maxzoom`** — P3, `controller-namespace`, evidence: style_sources.g.dart:360
```dart
GeoJsonSource(maxZoom: 18)
```
> Fine.

**GeoJSON — `minzoom` (mbgl + Apple only, NOT in the spec)** — P3, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart — GeoJsonSource ctor at :331 has maxZoom but no minZoom, because v8.json `source_geojson` has no `minzoom` key
```dart
GeoJsonSource(minZoom: 4)  // hand-written extension, not generated
```
> A spec-driven generator structurally cannot emit this. This is the clean argument for a small hand-written `GeoJsonSourceExtras` mixin (or `extraOptions: {'minzoom': 4}` passthrough) for the mbgl-only geojson options — see also `synchronousUpdate`. Both Apple and Android expose it, so it is not exotic.

**GeoJSON — `synchronousUpdate` (mbgl + Apple only, NOT in the spec)** — P3, `controller-namespace`, evidence: absent from style_sources.g.dart:331 — v8.json `source_geojson` has no such key, so the generator cannot emit it
```dart
GeoJsonSource(synchronousUpdate: true)  // hand-written extension alongside minZoom
```
> Makes setData take effect on the very next frame instead of after an async re-tile — the right switch for a marker being dragged. Only Apple exposes it, and only because Apple binds mbgl directly. Same hand-written-extras mechanism as `minzoom`.

**GeoJSON — `tolerance`** — P3, `controller-namespace`, evidence: style_sources.g.dart:384
```dart
GeoJsonSource(tolerance: 0.375)
```
> Fine. Apple renames it 'SimplificationTolerance'; spec name wins.

**Raster source `setTiles` / any source `setUrl` at runtime** — P3, `reject`, evidence: n/a
```dart
— (document remove + re-add)
```
> Both native SDKs agree with the ceiling by exposing nothing, which is good corroboration. Document the workaround explicitly: remove the layers, remove the source, re-add — the same dance removePoints already performs (map_layers_controller.dart:369).

**Raster source — `tileSize`** — P3, `controller-namespace`, evidence: style_sources.g.dart:170
```dart
RasterSource(tileSize: 256)
```
> Interesting asymmetry the spec bakes in: `tileSize` lives on the SOURCE for raster, but Apple hangs it off MLNTileSourceOption which it then documents as ignored for vector (MLNRasterTileSource.h:20-21). Our generated split (present on RasterSource/RasterDemSource, absent on VectorSource) is the correct one.

**Source runtime tuning — `setMaxOverscaleFactorForParentTiles`** — P3, `controller-namespace`, evidence: n/a
```dart
Future<void> setMaxOverscaleFactorForParentTiles(String sourceId, int? factor)
```
> Stops a heavily-overscaled parent raster tile being stretched into a blurry mess while the real tile loads. mbgl's own comment (source.hpp:108-111) explains it better than either SDK; copy that into dartdoc. Same Android-only-upstream pattern.

**Source runtime tuning — `setMinimumTileUpdateInterval`** — P3, `controller-namespace`, evidence: n/a
```dart
Future<void> setMinimumTileUpdateInterval(String sourceId, Duration interval)
```
> Throttles re-requests for a frequently-updating tile source (live weather/traffic). Dart's Duration maps directly onto mbgl's; Android's raw Long is the weaker shape and we should not copy it.

**Source runtime tuning — `setPrefetchZoomDelta`** — P3, `controller-namespace`, evidence: n/a
```dart
Future<void> setPrefetchZoomDelta(String sourceId, int? delta)
```
> Loads a coarser parent tile first so a zoom-in shows something immediately instead of blank. A real perceived-performance lever on slow links, and Android is the only upstream that exposes it — which is the pattern for this whole group: Apple binds mbgl but chose not to surface source tuning, Android did. Follow Android's names verbatim (they ARE mbgl's names).

**Source tile lifecycle events (`onTileAction`)** — P3, `capability-interface`, evidence: n/a
```dart
Stream<MapLibreTileEvent> get onTileAction;  // (sourceId, z, x, y, MapLibreTileOperation)
```
> Diagnostics-grade, not app-grade — but it is the honest answer to 'is my tileserver being hit / are tiles erroring', which is otherwise invisible. Apple's header warns 'This method is not thread-safe' (MLNMapViewDelegate.h:470); our Dart side would need to marshal off the render thread anyway. p3 because it is a debugging tool, but worth correcting the three ➖ cells.

**Vector source — `bounds`** — P3, `controller-namespace`, evidence: style_sources.g.dart:53
```dart
VectorSource(bounds: [swLng, swLat, neLng, neLat])  // keep spec order; add LatLngBounds convenience ctor
```
> Spec order is [lng,lat,lng,lat]; a raw List<double> is a lng/lat footgun (CLAUDE.md §11). Once LatLngBounds exists, add `VectorSource.bounded(LatLngBounds)` so callers never hand-order it. mbgl clamps lat to ±90 and errors if bottom>top or left>right (tileset.cpp:100-116) — those errors DO surface through addSourceJson.

**Vector source — `minzoom` / `maxzoom`** — P3, `controller-namespace`, evidence: style_sources.g.dart:64, :71
```dart
VectorSource(minZoom: 0, maxZoom: 14)
```
> Vector is the one source type where minzoom/maxzoom are read TWICE by mbgl — once into the ctor overrides and once into the Tileset — which is why they work with both the `url` and `tiles` forms.

**Vector source — `scheme` (xyz/tms)** — P3, `controller-namespace`, evidence: style_sources.g.dart:59 (VectorScheme); enum at style_enums.g.dart:738
```dart
VectorSource(scheme: VectorScheme.tms)
```
> Apple renames this to 'TileCoordinateSystem'; spec name wins. mbgl only checks for the literal 'tms' and silently defaults to XYZ for any other string (tileset.cpp:36-39) — a typo is not an error.

**Video source** — P3, `reject`, evidence: style_sources.g.dart:487 VideoSource — fully generated (urls, coordinates) and will always fail
```dart
@Deprecated('No video source in MapLibre Native; not available on any tier this package ships.') final class VideoSource extends StyleSource
```
> Reject the feature, but the generated CLASS is a public API promise we cannot keep on 6 of 6 tiers (web is WASM core too, not gl-js). Either annotate it or teach the generator to skip source types the core rejects. Annotating is more honest — it documents the ceiling instead of hiding it.


### Layers, style mutation & introspection

#### Engine ceiling

**Hard stops — mbgl cannot do these, so all five native tiers *and* web-WASM are permanently ➖, not ❌:**

- **`setSky`/`getSky`** — no sky/atmosphere anywhere in `include/mbgl` (grepped the whole tree; `style/layers/` has no `sky_layer.hpp`, and `LayerManager` cannot create a type that has no factory). gl-js-only.
- **`setTerrain`/`getTerrain`, `queryTerrainElevation`, `getCameraTargetElevation`** — no terrain type in `include/mbgl`. The `raster-dem` **source** and the `hillshade` **layer** exist (style/sources/raster_dem_source.hpp, style/layers/hillshade_layer.hpp) but 3D terrain does not.
- **`setProjection`/`getProjection` (globe, vertical-perspective)** — no globe. `Map::setProjectionMode` (map.hpp:115) is a *different, unrelated* thing (axonometric/xSkew/ySkew), and the matrix already correctly separates them.
- **`setGlobalStateProperty` / `getGlobalState` / the `global-state` expression** — not in mbgl's expression set.
- **`setGlyphs`/`getGlyphs`, `addSprite`/`setSprite`/`removeSprite`/`getSprite`** — `mbgl::style::Sprite` (style/sprite.hpp:8) is a two-string struct the style parser fills in; `Style` exposes **no** sprite or glyph mutation API at all (style.hpp has only `getImage`/`addImage`/`removeImage`, lines 50-52). Runtime sprite/glyph swapping is gl-js-only.
- **`listImages()`** — `Style` has `getImage(name)` (style.hpp:50) but no way to enumerate the image set. `hasImage` is derivable from `getImage`; a full listing is not.
- **`Source` serialization.** `Layer::serialize()` exists per layer type (layer.hpp:146, e.g. `circle_layer.cpp:506`), but there is **no `Source::serialize()`** anywhere in `include/mbgl/style/` (grepped). So a true gl-js `getStyle()` — the *live* spec document including runtime-added sources — cannot be assembled from core.
- **`Style::getJSON()` is not `getStyle()`.** It returns the original loaded document verbatim (`src/mbgl/style/style_impl.cpp:149-151` is literally `return json;`), so it does **not** reflect runtime `addLayer`/`setPaintProperty`/`removeSource`. Anyone binding it as "getStyle" ships a lie. Live layer state must be assembled from `getLayers()` + `Layer::serialize()`.
- **A queried feature does not know which style layer drew it.** `mbgl::Feature` (util/feature.hpp:20-24) carries `source`, `sourceLayer` and `state` but **no layer id**, so gl-js's `MapGeoJSONFeature.layer` cannot be reproduced. The best we can offer is running one query per `layerIds` set.
- **`GeoJSONSource.updateData` (incremental diff), `getData`, `getBounds`, runtime `setClusterOptions`** — `GeoJSONSource` (style/sources/geojson_source.hpp:61-94) has `setURL`/`setGeoJSON`/`setGeoJSONData` and `getOptions()` only; options are `Immutable<GeoJSONOptions>` fixed at construction.
- **Raster `setTiles`/`setUrl` at runtime** — `VectorSource::setTiles` exists (vector_source.hpp:30) but `RasterSource`/`RasterDEMSource` have no equivalent; `TileSource` exposes only `getURLOrTileset()` (tile_source.hpp:18). So vector-only, contradicting the matrix which calls both web-only.
- **Raw `CustomLayer`** — `style/layers/custom_layer.hpp` exists but its factory is `#ifdef`-gated to OpenGL (already recorded in CLAUDE.md §11). `CustomDrawableLayer` is the portable route, and is what our model host uses. A public "bring your own draw call" API is therefore GL-only and should stay unbound.
- **Named `slot` insertion points** — not in the vendored v8 spec, not in `Layer`.

**Things the matrix calls impossible that mbgl CAN actually do** (i.e. these are ❌-binding-work, not ➖):
`getLayersOrder` (style.hpp:65 returns the ordered vector), `updateImage` (style.hpp:51 `addImage` overwrites by id), `hasImage`/`getImage` (style.hpp:50), stretchable images + `content` + **text-fit** (style/image.hpp:41-45 and 84-87 — the matrix marks text-fit `web_only`, which is wrong), vector `setTiles` (vector_source.hpp:30), image-source `setCoordinates`/`setImage` (image_source.hpp:23-26), cluster expansion-zoom/children/leaves (renderer.hpp:67 `queryFeatureExtensions`, backed by geojson_source.hpp:55-57), and the whole feature-state trio (renderer.hpp:74-87).

#### Naming decisions

**Policy applied: gl-js names win for everything in this domain.** Every operation here (addLayer/removeLayer/moveLayer/getLayer/getLayersOrder, set|getPaintProperty, set|getLayoutProperty, set|getFilter, setLayerZoomRange, addSource/removeSource/getSource, addImage/removeImage/hasImage, setLight/getLight, queryRenderedFeatures/querySourceFeatures, set|get|removeFeatureState) exists verbatim in gl-js and is what the style spec's own vocabulary implies, and our generated typed style API already mirrors gl-js/spec property names (`circleColor` <- `circle-color`). Apple and Android are *typed-accessor* SDKs here (`layer.circleColor = NSExpression…`, `layer.setProperties(PropertyFactory.circleColor(…))`) with no string-keyed setter at all, so there is no Apple/Android name to copy for the single most-requested missing API. Android's `Style` is the closer of the two (`addLayerBelow/Above/At`, `getLayers()`, `getSource`, `setTransition`), but it still has no `moveLayer`, no `getPaintProperty` and no `getFilter` on the base class.

**Where they disagree, and what I chose:**

1. **Layer insertion.** gl-js: `addLayer(layer, beforeId)` + `moveLayer(id, beforeId)`. Apple: `insertLayer:atIndex:` / `belowLayer:` / `aboveLayer:` (MLNStyle.h:202/218/234), no move. Android: `addLayerAt/Below/Above`. mbgl underneath has **only** `addLayer(layer, beforeLayerID)` (style.hpp:71). **Chose gl-js**: `beforeId` everywhere, plus `moveLayer(id, {beforeId})` implemented as `removeLayer`+`addLayer(before)` on the render thread. Index- and above-based insertion are p3 and expressible from `getLayersOrder()`.

2. **Paint vs layout split.** gl-js has two setters; mbgl has **one** (`Layer::setProperty(name, value)`, layer.hpp:143) that dispatches on the property name and also accepts `visibility`, `minzoom`, `maxzoom`, `filter`, `source`, `source-layer` (verified in `src/mbgl/style/layer.cpp`). **Chose gl-js's two names** anyway — they are what users type and what the spec document structure implies — and both compile to *one* C ABI entry point. Getting is asymmetric: `Layer::getProperty` only knows paint+layout names, so `getFilter`/`getVisibility`/zoom-range read through the dedicated getters. That asymmetry is invisible in Dart.

3. **Filters.** gl-js `setFilter(layerId, filter)`. Apple calls it `predicate` and uses `NSPredicate` (MLNVectorStyleLayer.h:54) — an Apple-only idiom with a documented lossy mapping to spec filters. **Chose gl-js `setFilter` + our own `Expression`**, which is already generated from the spec.

4. **Transitions.** gl-js `Map` has **no** public `setTransition`/`getTransition` (verified against the 5.x method index — it is a root property of the style document only, and the Style class's setter is internal). Apple has `MLNStyle.transition` + `performsPlacementTransitions` (MLNStyle.h:98/105); Android has `Style.setTransition/getTransition`. **Chose the Apple/Android shape**, which is what we already ship as `layers.setTransitionOptions(duration:, delay:, placementTransitions:)`. Keeping it on `layers` rather than moving it under a new `style` namespace: moving it is pure contract churn for zero user benefit.

5. **"Is the style ready?"** gl-js `isStyleLoaded()` = style parsed. mbgl `Map::isFullyLoaded()` (map.hpp:153) = style **and** all viewport tiles — i.e. gl-js's `isStyleLoaded() && areTilesLoaded()`. **Split into two rows** rather than mapping one onto the other, because silently redefining "loaded" is exactly the class of bug §7 of CLAUDE.md warns about.

6. **Style source of truth.** gl-js `setStyle(style, {diff, transformStyle})`. Apple has both `styleURL` and `styleJSON` as settable properties (MLNMapView.h:278/292). Our house rule says the style is a **widget prop with no public `controller.setStyle`**, so I keep `MapLibreMap.style` as the single source of truth and express "inline JSON vs URL vs asset" as a **sealed value type** on that one prop rather than adding methods.

**Flutter-idiom adaptations, stated explicitly:**
- gl-js `map.on('styledata' | 'styleimagemissing' | 'error' | 'sourcedata')` -> **widget callbacks** `MapLibreMap.onStyleLoaded / onStyleImageMissing / onStyleError`, matching the existing `onTap` prop and Apple's delegate shape (`MLNMapViewDelegate.h:321/353/219/329`). No `Stream`, no `on(String)` — a stringly-typed subscription API is un-Dartlike and untypeable.
- gl-js `setStyle(string | StyleSpecification)` -> **`sealed class MapLibreStyle`** with `MapLibreStyle.uri` / `.asset` / `.json` / `.document(StyleDocument)`. A bare `String` that sometimes means a URL and sometimes a whole JSON document is the kind of overload Dart has sum types for. `MapLibreMap.style` accepts `Object` (String kept for source compat) or we do a breaking widen — flagged in the rows.
- gl-js's `transformStyle` callback (a synchronous style rewriter) -> `MapLibreMap.onStyleLoaded` re-application callback, because our engine cannot intercept the parsed document before it is applied (mbgl `Style::loadURL` is fire-and-forget).
- gl-js getters return values synchronously off an in-process style object; ours must cross to the render thread. **New reads return `Future`** (matching the existing `getCamera()`), with the one deliberate exception that `queryRenderedFeatures` stays synchronous because it is called from the camera-tick overlay path where an `await` costs a frame. That asymmetry is intentional and must be documented on both.
- gl-js `MapGeoJSONFeature` -> `MapLibreQueriedFeature`, widened to carry `id`, `source`, `sourceLayer`, `state` and full `geometry` (all present in `mbgl::Feature`, util/feature.hpp:20-24) instead of today's point-only, properties-only shape.

#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | A style load DROPS app-added layers, sources and images | partial | map.setStyle(style, {diff: true}) diffs instead of replacing; {transformStyle: (prev, next) => …} carries layers/sources over | documented contract, not API: MLNStyle.h:32-36 and MLNStyle.h:123-127 tell you to (re)add in mapView:didFinishLoadingStyle: | style::Style::loadURL/loadJSON replace the whole layer+source+image set (style.hpp:29-30); no diff, no retain | widget-callback | no |
| P0 | Load style from INLINE JSON | none | map.setStyle(styleSpecificationObject) | `MLNMapView.styleJSON` (MLNMapView.h:292); `MLNStyle.styleJSON` (MLNStyle.h:85); `-[MLNMapView initWithFrame:styleJSON:]` (MLNMapView.h:222) | style::Style::loadJSON (include/mbgl/style/style.hpp:29) | widget-prop | yes |
| P0 | Load style from a Flutter asset | none | — | `MLNMapView.styleURL` accepts a file: or asset URL (MLNMapView.h:200-210 doc block) | style::Style::loadURL (style.hpp:30) resolves asset:// only when the platform registers an asset FileSource — we register none | widget-prop | yes |
| P0 | Style-loaded event (`styledata` / didFinishLoadingStyle) | none | map.on('styledata', cb) / map.on('style.load', cb) | `-[MLNMapViewDelegate mapView:didFinishLoadingStyle:]` (MLNMapViewDelegate.h:321) | MapObserver::onDidFinishLoadingStyle (include/mbgl/map/map_observer.hpp:64) | widget-callback | yes |
| P0 | `setPaintProperty` | none | map.setPaintProperty(layerId, name, value, options?: StyleSetterOptions) | no string-keyed setter — typed NSExpression properties, e.g. `MLNBackgroundStyleLayer.backgroundColor` (MLNBackgroundStyleLayer.h:85) | style::Layer::setProperty(name, Convertible) (include/mbgl/style/layer.hpp:143) — ONE setter for paint AND layout, dispatched by name | controller-namespace | yes |
| P1 | GeoJSON `setData` | present | map.getSource(id).setData(geojson) | `MLNShapeSource.shape` (MLNShapeSource.h:354) | style::GeoJSONSource::setGeoJSON (include/mbgl/style/sources/geojson_source.hpp:67) | controller-namespace | no |
| P1 | Layer visibility set/get (`layout.visibility`) | partial | map.setLayoutProperty(layerId, 'visibility', 'visible' \| 'none') | `MLNStyleLayer.visible` (getter isVisible) (MLNStyleLayer.h:52) | style::Layer::setVisibility / getVisibility with VisibilityType (include/mbgl/style/layer.hpp:133-134; style/types.hpp:21-24) | controller-namespace | no |
| P1 | Load style from a URL (http/https/mapbox/file) | present | map.setStyle(style: StyleSpecification \| string, options?: StyleSwapOptions) | `MLNMapView.styleURL` (MLNMapView.h:278); `-[MLNMapView initWithFrame:styleURL:]` (MLNMapView.h:210) | style::Style::loadURL (include/mbgl/style/style.hpp:30) | widget-prop | no |
| P1 | Queried-feature value type: id, geometry, source, sourceLayer, state | partial | MapGeoJSONFeature { id, geometry, properties, layer, source, sourceLayer, state } | `id<MLNFeature>` with identifier + attributes + the concrete geometry class (MLNFeature.h) | mbgl::Feature (include/mbgl/util/feature.hpp:20-24) carries source, sourceLayer, state, plus the GeoJSONFeature identifier — our shim SLICES all of it away by copying into a feature_collection<double> | value-type | yes |
| P1 | Style error event (`error` / didFailLoadingMap) | none | map.on('error', e => …) | `-[MLNMapViewDelegate mapViewDidFailLoadingMap:withError:]` (MLNMapViewDelegate.h:219) | MapObserver::onDidFailLoadingMap (include/mbgl/map/map_observer.hpp:59) with MapLoadError {StyleParseError, StyleLoadError, NotFoundError, UnknownError} (map_observer.hpp:21-26) | widget-callback | yes |
| P1 | `addImage` (raw RGBA) | present | map.addImage(id, image: StyleImageSource, options?: Partial<StyleImageMetadata>) | `-[MLNStyle setImage:forName:]` (MLNStyle.h:270) | style::Style::addImage (include/mbgl/style/style.hpp:51) | controller-namespace | no |
| P1 | `addLayer` — raw style-spec JSON escape hatch | present | map.addLayer({id, type, source, paint, layout, filter}, beforeId) | — (Apple has no JSON layer path; typed subclasses only) | conversion::Converter<std::unique_ptr<Layer>> (include/mbgl/style/conversion/layer.hpp:14) | controller-namespace | no |
| P1 | `addLayer` — typed, from the generated style API | present | map.addLayer(layer: AddLayerObject, beforeId?: string) | `-[MLNStyle addLayer:]` (MLNStyle.h:183) with typed MLNStyleLayer subclasses | style::Style::addLayer (include/mbgl/style/style.hpp:71) via conversion::Converter<unique_ptr<Layer>> (style/conversion/layer.hpp:14) | controller-namespace | no |
| P1 | `addSource` — typed and raw JSON | present | map.addSource(id, source: SourceSpecification) | `-[MLNStyle addSource:]` (MLNStyle.h:130) | style::Style::addSource (include/mbgl/style/style.hpp:61) | controller-namespace | no |
| P1 | `getLayer` — read a layer back as spec JSON | none | map.getLayer(id: string): StyleLayer | `-[MLNStyle layerWithIdentifier:]` (MLNStyle.h:166) | style::Style::getLayer (include/mbgl/style/style.hpp:68) + Layer::serialize (style/layer.hpp:146) | controller-namespace | yes |
| P1 | `getLayersOrder` | none | map.getLayersOrder(): string[] | `MLNStyle.layers` — "arranged according to their back-to-front ordering on the screen" (MLNStyle.h:154-157) | style::Style::getLayers (include/mbgl/style/style.hpp:65) returns the ordered vector | controller-namespace | yes |
| P1 | `getLayoutProperty` | none | map.getLayoutProperty(layerId, name) | typed getters | style::Layer::getProperty (include/mbgl/style/layer.hpp:145) | controller-namespace | no |
| P1 | `getPaintProperty` | none | map.getPaintProperty(layerId, name) | typed property getters on the MLNStyleLayer subclass | style::Layer::getProperty(name) -> StyleProperty (include/mbgl/style/layer.hpp:145; style/style_property.hpp:11) | controller-namespace | yes |
| P1 | `isStyleLoaded` | none | map.isStyleLoaded(): boolean | `MLNMapView.style` is nil until loaded (MLNMapView.h:261) | no style-only flag; Map::isFullyLoaded (include/mbgl/map/map.hpp:153) means style AND viewport tiles | controller-namespace | yes |
| P1 | `moveLayer` | none | map.moveLayer(id: string, beforeId?: string) | no move; `-[MLNStyle insertLayer:belowLayer:]` (MLNStyle.h:218) / `aboveLayer:` (MLNStyle.h:234) / `atIndex:` (MLNStyle.h:202) after a removeLayer: | NOT DIRECT — compose Style::removeLayer (style.hpp:72, returns unique_ptr) then Style::addLayer(std::move(l), beforeId) (style.hpp:71) on the render thread | controller-namespace | yes |
| P1 | `queryRenderedFeatures` — point overload | none | map.queryRenderedFeatures(point) — a single PointLike | `-[MLNMapView visibleFeaturesAtPoint:inStyleLayersWithIdentifiers:predicate:]` (MLNMapView.h:2157) | Renderer::queryRenderedFeatures(const ScreenCoordinate&, …) (include/mbgl/renderer/renderer.hpp:58) — a distinct overload with its own hit-tolerance semantics | controller-namespace | yes |
| P1 | `queryRenderedFeatures` — rect | present | map.queryRenderedFeatures(geometry?: PointLike \| [PointLike, PointLike], options?: {layers, filter, validate}) | `-[MLNMapView visibleFeaturesInRect:inStyleLayersWithIdentifiers:predicate:]` (MLNMapView.h:2253) | Renderer::queryRenderedFeatures(const ScreenBox&, RenderedQueryOptions) (include/mbgl/renderer/renderer.hpp:60) | controller-namespace | no |
| P1 | `removeLayer` | present | map.removeLayer(id: string) | `-[MLNStyle removeLayer:]` (MLNStyle.h:242) | style::Style::removeLayer (include/mbgl/style/style.hpp:72) | controller-namespace | no |
| P1 | `removeSource` | present | map.removeSource(id) | `-[MLNStyle removeSource:]` (MLNStyle.h:137) and `removeSource:error:` (MLNStyle.h:149) | style::Style::removeSource (include/mbgl/style/style.hpp:62) | controller-namespace | no |
| P1 | `setFilter` | none | map.setFilter(layerId, filter?: FilterSpecification, options?: StyleSetterOptions) | `MLNVectorStyleLayer.predicate` (NSPredicate) (MLNVectorStyleLayer.h:54) | style::Layer::setFilter (include/mbgl/style/layer.hpp:130); also reachable via setProperty("filter", …) (src/mbgl/style/layer.cpp) | controller-namespace | no |
| P1 | `setLayerZoomRange` | none | map.setLayerZoomRange(layerId, minzoom, maxzoom) | `MLNStyleLayer.minimumZoomLevel` / `.maximumZoomLevel` (MLNStyleLayer.h:64 / 58) | style::Layer::setMinZoom / setMaxZoom (include/mbgl/style/layer.hpp:139-140); also via setProperty("minzoom"/"maxzoom") (src/mbgl/style/layer.cpp) | controller-namespace | no |
| P1 | `setLayoutProperty` | none | map.setLayoutProperty(layerId, name, value, options?: StyleSetterOptions) | typed properties (e.g. MLNSymbolStyleLayer.textField) | style::Layer::setProperty (include/mbgl/style/layer.hpp:143) — same entry point as paint | controller-namespace | no |
| P2 | Bulk property set (one call, many properties) | none | — (gl-js is one property per call) | — (property-at-a-time) | conversion::setPaintProperties(Layer&, Convertible) (include/mbgl/style/conversion/layer.hpp:19), plus repeated Layer::setProperty | controller-namespace | yes |
| P2 | Cluster expansion zoom / children / leaves | none | map.getSource(id).getClusterExpansionZoom(clusterId, cb) / getClusterChildren / getClusterLeaves *(unverified)* | `-[MLNShapeSource zoomLevelForExpandingCluster:]` (MLNShapeSource.h:437), `childrenOfCluster:` (:426), `leavesOfCluster:offset:limit:` (:408) | Renderer::queryFeatureExtensions (include/mbgl/renderer/renderer.hpp:67) over GeoJSONData::getClusterExpansionZoom/getChildren/getLeaves (style/sources/geojson_source.hpp:55-57) | controller-namespace | yes |
| P2 | Error reporting from style mutations | partial | map.on('error') for style errors; setters throw synchronously on a bad value | MLNRedundantLayerIdentifierException / MLNRedundantSourceIdentifierException (MLNStyle.h:19/21); `-[MLNStyle removeSource:error:]` (MLNStyle.h:149) | conversion::Error out-params on Layer::setProperty (include/mbgl/style/layer.hpp:143) and the conversion Converters; duplicate-id is detected only inside Style on the render thread | controller-namespace | yes |
| P2 | GeoJSON `setUrl` at runtime | none | map.getSource(id).setUrl?  — not a documented gl-js Map method; gl-js does it by setData(url) *(unverified)* | `MLNShapeSource.URL` (MLNShapeSource.h:362) | style::GeoJSONSource::setURL (include/mbgl/style/sources/geojson_source.hpp:66) | controller-namespace | yes |
| P2 | Image source `setCoordinates` | none | map.getSource(id).setCoordinates(coordinates) *(unverified)* | `-[MLNImageSource setCoordinates:]` (MLNImageSource.h:115); `MLNImageSource.coordinates` (MLNImageSource.h:108) | style::ImageSource::setCoordinates(std::array<LatLng,4>) (include/mbgl/style/sources/image_source.hpp:25) | controller-namespace | yes |
| P2 | Image source `setImage` / `updateImage` | none | map.getSource(id).updateImage({url, coordinates}) *(unverified)* | `MLNImageSource.image` (MLNImageSource.h:103) | style::ImageSource::setImage(PremultipliedImage&&) (include/mbgl/style/sources/image_source.hpp:23) | controller-namespace | yes |
| P2 | Layer exists / hasLayer | none | map.getLayer(id) === undefined | `-[MLNStyle layerWithIdentifier:]` returns nil (MLNStyle.h:166) | style::Style::getLayer (include/mbgl/style/style.hpp:68) returns nullptr | controller-namespace | no |
| P2 | List sources / `isSourceLoaded` | none | map.isSourceLoaded(id): boolean; (no listSources — use getStyle().sources) | `MLNStyle.sources` (NSSet) (MLNStyle.h:92) | style::Style::getSources (include/mbgl/style/style.hpp:55); `Source::loaded` public flag (style/source.hpp:123) | controller-namespace | yes |
| P2 | Per-property transition (`*-transition`) at runtime | partial | map.setPaintProperty(layerId, 'circle-color-transition', {duration, delay}) *(unverified)* | `MLNBackgroundStyleLayer.backgroundColorTransition` (MLNBackgroundStyleLayer.h:93) — MLNTransition struct per property | the '-transition' names are in each layer's property table (verified in src/mbgl/style/layers/circle_layer.cpp:441), so Layer::setProperty (layer.hpp:143) accepts them | controller-namespace | no |
| P2 | Stretchable images (`stretchX`/`stretchY`), `content` box, text-fit | none | map.addImage(id, image, {stretchX, stretchY, content, textFitWidth, textFitHeight, pixelRatio, sdf}) | — (no stretch metadata on setImage:forName:) | style::Image ctor takes stretchX, stretchY, content, textFitWidth, textFitHeight (include/mbgl/style/image.hpp:41-45); getters at image.hpp:76-87; TextFit enum at image.hpp:17-21 | controller-namespace | yes |
| P2 | Style-wide transition options (duration / delay / placement fade) | present | — (no public Map.setTransition; the style document's root `transition` only) | `MLNStyle.transition` (MLNStyle.h:98) + `MLNStyle.performsPlacementTransitions` (MLNStyle.h:105) | style::Style::setTransitionOptions (include/mbgl/style/style.hpp:41); TransitionOptions {duration, delay, enablePlacementTransitions} (style/transition_options.hpp:12-23) | controller-namespace | no |
| P2 | Vector source `setTiles` | none | map.getSource(id).setTiles(tiles: string[]) *(unverified)* | — (MLNTileSource.configurationURL is read-only, MLNTileSource.h:174) | style::VectorSource::setTiles(const std::vector<std::string>&) (include/mbgl/style/sources/vector_source.hpp:30) — VECTOR ONLY; RasterSource/RasterDEMSource have no equivalent | controller-namespace | yes |
| P2 | `addWidgetIcon` — rasterize a Flutter widget into a style image | present | — (no equivalent; gl-js takes an HTMLImageElement/ImageBitmap) | — (callers build a UIImage themselves) | style::Style::addImage (include/mbgl/style/style.hpp:51) | controller-namespace | no |
| P2 | `areTilesLoaded` / fully-loaded | none | map.areTilesLoaded(): boolean | — | Map::isFullyLoaded (include/mbgl/map/map.hpp:153) | controller-namespace | yes |
| P2 | `getFeatureState` / `removeFeatureState` | none | map.getFeatureState(feature) / map.removeFeatureState(feature, key?) | — | Renderer::getFeatureState (renderer.hpp:79-82) / removeFeatureState (renderer.hpp:84-87) | controller-namespace | yes |
| P2 | `getFilter` | none | map.getFilter(layerId): void \| FilterSpecification | `MLNVectorStyleLayer.predicate` getter (MLNVectorStyleLayer.h:54) | style::Layer::getFilter (include/mbgl/style/layer.hpp:129); Filter::serialize (style/filter.hpp:46) | controller-namespace | yes |
| P2 | `getLayer` — read a layer back as a TYPED StyleLayer | none | map.getLayer(id) returns a typed StyleLayer | `-[MLNStyle layerWithIdentifier:]` returns the concrete subclass (MLNStyle.h:166) | Layer::serialize (style/layer.hpp:146); typing is ours to add in Dart | controller-namespace | no |
| P2 | `getSource` — read a source back | none | map.getSource(id): Source | `-[MLNStyle sourceWithIdentifier:]` (MLNStyle.h:113) | style::Style::getSource (include/mbgl/style/style.hpp:58) — but Source has NO serialize(), only getType/getID/getAttribution/isVolatile (style/source.hpp:75-80) | value-type | yes |
| P2 | `getStyle` — serialize the live style document | none | map.getStyle(): StyleSpecification | `MLNStyle.styleJSON` getter (MLNStyle.h:85) | PARTIAL — Style::getJSON (style.hpp:32) returns the ORIGINAL loaded document, not live state (src/mbgl/style/style_impl.cpp:149); live layers only via getLayers()+Layer::serialize() (layer.hpp:146); no Source::serialize exists | controller-namespace | yes |
| P2 | `hasImage` / `getImage` | none | map.hasImage(id): boolean; map.getImage(id): StyleImage | `-[MLNStyle imageForName:]` (MLNStyle.h:253) | style::Style::getImage (include/mbgl/style/style.hpp:50) returns std::optional<Image> | controller-namespace | yes |
| P2 | `queryRenderedFeatures` — filter argument | none | queryRenderedFeatures(geometry, {filter: FilterSpecification}) | the `predicate:` argument (MLNMapView.h:2160 / 2256) | RenderedQueryOptions::filter (include/mbgl/renderer/query.hpp:24) | controller-namespace | yes |
| P2 | `querySourceFeatures` | none | map.querySourceFeatures(sourceId, options?: {sourceLayer, filter, validate}) | `-[MLNShapeSource featuresMatchingPredicate:]` (MLNShapeSource.h:392) | Renderer::querySourceFeatures (include/mbgl/renderer/renderer.hpp:61) with SourceQueryOptions {sourceLayers, filter} (renderer/query.hpp:30-41) | controller-namespace | yes |
| P2 | `setFeatureState` | none | map.setFeatureState(feature: FeatureIdentifier, state: any)  // FeatureIdentifier = {source, sourceLayer?, id} | — (no feature-state API in the Apple SDK 6.27 headers) | Renderer::setFeatureState (include/mbgl/renderer/renderer.hpp:74-77) | controller-namespace | yes |
| P2 | `setLight` / `getLight` | none | map.setLight(light: LightSpecification, options?: StyleSetterOptions); map.getLight(): LightSpecification | `MLNStyle.light` (MLNStyle.h:284); `MLNLight` with anchor/position/color/intensity + per-property transitions (MLNLight.h:74, 103, 139, 193, 225) | style::Style::setLight / getLight (include/mbgl/style/style.hpp:44-47); style::Light with setProperty(name, value) (style/light.hpp:25) and typed anchor/color/intensity/position setters (light.hpp:29-50) | controller-namespace | yes |
| P2 | `styleimagemissing` event | none | map.on('styleimagemissing', e => map.addImage(e.id, …)) | `-[MLNMapViewDelegate mapView:didFailToLoadImage:]` (MLNMapViewDelegate.h:339) | MapObserver::onStyleImageMissing (include/mbgl/map/map_observer.hpp:67) | widget-callback | yes |
| P3 | Change a layer's `source-layer` / `source` at runtime | none | — (gl-js has no runtime source/source-layer setter) | `MLNVectorStyleLayer.sourceLayerIdentifier` (MLNVectorStyleLayer.h:27); `MLNForegroundStyleLayer.sourceIdentifier` is READ-ONLY (MLNForegroundStyleLayer.h:33) | style::Layer::setSourceLayer / setSourceID (include/mbgl/style/layer.hpp:125-126) | controller-namespace | no |
| P3 | Custom layer (app-supplied draw calls) | internal-only | map.addLayer(customLayerInterface) with render(gl, matrix) | `MLNCustomStyleLayer` (MLNCustomStyleLayer.h:51) with drawInMapView:withContext: (:142); `MLNCustomDrawableStyleLayer` (MLNCustomDrawableStyleLayer.h:9); `MLNPluginLayer` (MLNPluginLayer.h:89) | style::CustomLayer (include/mbgl/style/layers/custom_layer.hpp) — factory is #ifdef-gated to OpenGL; style::CustomDrawableLayer (custom_drawable_layer.hpp) is the portable one | reject | no |
| P3 | Insert a layer at an index / above another layer | none | — (gl-js is beforeId-only) | `-[MLNStyle insertLayer:atIndex:]` (MLNStyle.h:202), `insertLayer:aboveLayer:` (MLNStyle.h:234) | NOT IN CORE — Style::addLayer takes only beforeLayerID (include/mbgl/style/style.hpp:71) | reject | no |
| P3 | Map-wide tile prefetch (`setPrefetchZoomDelta`) | none | — | `MLNMapView.prefetchesTiles` (MLNMapView.h:478) | Map::setPrefetchZoomDelta / getPrefetchZoomDelta (include/mbgl/map/map.hpp:143-144) | widget-init | yes |
| P3 | Named `slot` insertion points | none | — (not in maplibre-gl-js 5.x; this is a Mapbox GL JS v3 concept) | — | NOT IN CORE — no `slot` in style/layer.hpp and none in the vendored v8.json | reject | no |
| P3 | Predefined / default styles list | none | — | `+[MLNStyle predefinedStyles]` (MLNStyle.h:46), `+defaultStyle` (:51), `+defaultStyleURL` (:56), `+predefinedStyle:` (:62), `MLNDefaultStyle` {url, name, version} (MLNDefaultStyle.h:11-26) | NOT IN CORE — driven by MLNSettings / MLNTileServerOptions, an SDK-level concern | reject | no |
| P3 | Source tuning: volatile, prefetch delta, min tile update interval, max overscale | none | — (no gl-js equivalent) | — | Source::setVolatile (style/source.hpp:81), setPrefetchZoomDelta (:93), setMinimumTileUpdateInterval (:102), setMaxOverscaleFactorForParentTiles (:117) | controller-namespace | yes |
| P3 | Style name | none | map.getStyle().name | `MLNStyle.name` (MLNStyle.h:71) | style::Style::getName (include/mbgl/style/style.hpp:36) | controller-namespace | yes |
| P3 | Style's default camera (`center`/`zoom`/`bearing`/`pitch` root props) | none | implicit — Map honours the style's center/zoom when no camera is given *(unverified)* | implicit in MLNMapView when no camera set | style::Style::getDefaultCamera (include/mbgl/style/style.hpp:37) | controller-namespace | yes |
| P3 | Unused-style-image removal veto | none | — | `-[MLNMapViewDelegate mapView:shouldRemoveStyleImage:]` (MLNMapViewDelegate.h:353) | MapObserver::onCanRemoveUnusedStyleImage (include/mbgl/map/map_observer.hpp:70) | reject | yes |
| P3 | `getTransition` | none | — | `MLNStyle.transition` is readwrite (MLNStyle.h:98) | style::Style::getTransitionOptions (include/mbgl/style/style.hpp:40) | controller-namespace | yes |
| P3 | `listImages` | none | map.listImages(): string[] | — | NOT IN CORE — Style exposes getImage/addImage/removeImage only (include/mbgl/style/style.hpp:50-52); there is no image enumeration | reject | no |
| P3 | `localizeLabels` (rewrite text-field to a locale) | none | — (plugin / expression-rewrite pattern) | `-[MLNStyle localizeLabelsIntoLocale:]` (MLNStyle.h:302) | NOT IN CORE — Apple implements it in the SDK by walking layers and rewriting text-field expressions; there is no mbgl entry point | controller-namespace | no |
| P3 | `setGlobalStateProperty` / `getGlobalState` | none | map.setGlobalStateProperty(key, value); map.getGlobalState() | — | NOT IN CORE — no global-state expression in include/mbgl/style/expression/ | reject | no |
| P3 | `setGlyphs` / `getGlyphs`, sprite runtime API | none | map.setSprite / addSprite / removeSprite / getSprite / setGlyphs / getGlyphs | — | NOT IN CORE — style::Sprite (include/mbgl/style/sprite.hpp:8) is a parsed value with no Style-level mutator; style.hpp exposes only per-image add/remove/get (lines 50-52) | reject | no |
| P3 | `setProjection` / `getProjection` (globe) | none | map.setProjection(projection: ProjectionSpecification \| string); map.getProjection() | — | NOT IN CORE for globe. Map::setProjectionMode (include/mbgl/map/map.hpp:115) is unrelated (axonometric/skew) | reject | no |
| P3 | `setSky` / `getSky` | none | map.setSky(sky: SkySpecification, options?); map.getSky() | — | NOT IN CORE — no sky layer type anywhere in include/mbgl/style/layers/ | reject | no |
| P3 | `setTerrain` / `getTerrain` | none | map.setTerrain(terrain: TerrainSpecification \| null, options?); map.getTerrain() | — | NOT IN CORE | reject | no |
| P3 | `sourcedata` / source-changed event | none | map.on('sourcedata', e => …) | `-[MLNMapViewDelegate mapView:sourceDidChange:]` (MLNMapViewDelegate.h:329) | MapObserver::onSourceChanged (include/mbgl/map/map_observer.hpp:65) | widget-callback | yes |
| P3 | `updateImage` | present | map.updateImage(id, image: StyleImageSource) | `setImage:forName:` overwrites (MLNStyle.h:256 doc: "Adds or overrides an image") | style::Style::addImage (style.hpp:51) replaces an existing id | controller-namespace | no |

#### Proposed signatures

**A style load DROPS app-added layers, sources and images** — P0, `widget-callback`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:890-899 — onDidFinishLoadingStyle re-applies transition options and re-adds MODELS only; nothing re-adds app sources/layers/images
```dart
MapLibreMap(onStyleLoaded: …) is the contract; optionally MapLibreMap(transformStyle: StyleDocument Function(StyleDocument? previous, StyleDocument next))
```
> Ranked p0 as a DEFECT, not a feature: today an app that calls layers.addPoints and then flips MapLibreMap.style loses its data with no signal and no way to know. The precedent is already in our own shim — models survive a style load because the shim retains and re-adds them. Either extend that retain-and-replay to app sources/layers/images (a superset of what gl-js's diff buys, and cheap since we already hold the JSON), or ship onStyleLoaded and document the contract. Recommend: onStyleLoaded first (p0), retain-and-replay as an opt-in `MapLibreMap.retainRuntimeStyle` later.

**Load style from INLINE JSON** — P0, `widget-prop`, evidence: would live in packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1027 and packages/maplibre_flutter_core/src/maplibre_flutter_core.h:57
```dart
MapLibreMap(style: MapLibreStyle.json(String styleJson))  // and MapLibreStyle.document(StyleDocument)
```
> P0 BECAUSE THE DOC ALREADY CLAIMS IT. packages/maplibre_flutter/lib/src/maplibre_map.dart:40 says the style prop takes 'a URL, asset path, or inline JSON'; the shim calls loadURL unconditionally, so passing JSON silently produces a blank map. Either bind loadJSON or fix the doc — the former, since all three canonical SDKs offer it. New C entry: mbl_map_set_style_json(map, json, err, err_len), plus the same discrimination in mbl_map_create.

**Load style from a Flutter asset** — P0, `widget-prop`, evidence: no `asset` handling anywhere in packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp (grepped for asset://, AssetFileSource); would live at cpp:1027
```dart
MapLibreMap(style: MapLibreStyle.asset('assets/style.json'))
```
> Same p0 reason: the widget doc promises 'asset path'. Cheapest correct implementation is Dart-side: rootBundle.loadString -> MapLibreStyle.json, which makes this fall out of the loadJSON work above and needs no per-platform asset FileSource. Do that; do not chase asset:// through mbgl.

**Style-loaded event (`styledata` / didFinishLoadingStyle)** — P0, `widget-callback`, evidence: observer hook exists natively at packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:890 (onDidFinishLoadingStyle) but is never surfaced; nothing in packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart exposes it (only `onReady`, line 22)
```dart
MapLibreMap(onStyleLoaded: (MapLibreMapController c) { … })  // fires on first load AND after every style swap
```
> This is the load-bearing gap of the whole domain. Both Apple and Android document that you MUST add sources/layers/images from this callback and re-add after every style change — we give apps no such callback, so there is literally no correct time to call layers.addLayer after a style swap. Needs a new mbl_map_set_style_callback(map, cb, user) plus a MapLibreStyleDocument capability interface (see naming notes) so it is feature-detected with `is`, not bolted onto the base contract.

**`setPaintProperty`** — P0, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:31 (next to addLayerJson) and core.h:187
```dart
void setPaintProperty(String layerId, String name, Object? value)  // value: a spec constant, an Expression, or a StyleValue
```
> THE headline gap. Today the only way to change a colour is to remove and re-add the layer, which drops its fade state and costs a re-layout. One new C entry — mbl_map_set_layer_property(map, layer_id, name, value_json, err, err_len) — backs setPaintProperty, setLayoutProperty, setFilter, setLayerZoomRange, setVisibility and setLayerSourceLayer, because mbgl's Layer::setProperty already handles all of those names (verified in src/mbgl/style/layer.cpp). Parse the JSON synchronously on the calling thread and post only the mutation, exactly as add_layer_json does (core.h:174-179).

**GeoJSON `setData`** — P1, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:114 (+ typed sugar setPoints :365) -> style_layers.dart:36 -> core.h:193 -> core.cpp:1617
```dart
void setGeoJsonData(String sourceId, String geoJson)  // unchanged
```
> Our name is source-first because we address by id rather than by returning a Source handle; that is the right call given getSource can only return a value type (see above). Keep.

**Layer visibility set/get (`layout.visibility`)** — P1, `controller-namespace`, evidence: settable only at construction — `visibility` field on every generated layer, e.g. packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:1268 and its toJson at :1443; no runtime mutation anywhere
```dart
void setVisibility(String layerId, bool visible)  +  Future<bool> getVisibility(String layerId)
```
> MATRIX DRIFT (of the misleading-🧪 kind): 🧪 for a *mutation* row implies runtime toggling exists. Adapted to Flutter idiom: a `bool`, not the spec's 'visible'/'none' string, mirroring Apple's BOOL `visible`. The raw string remains reachable through setLayoutProperty. 'Show/hide this layer' is the single most common runtime style operation and it is currently impossible without a layer rebuild.

**Load style from a URL (http/https/mapbox/file)** — P1, `widget-prop`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1027 (mbl_map_set_style -> loadURL); header src/maplibre_flutter_core.h:57; Dart lib/maplibre_flutter_core.dart:199; widget prop packages/maplibre_flutter/lib/src/maplibre_map.dart:44
```dart
MapLibreMap(style: MapLibreStyle.uri('https://…/style.json'))
```
> Works today, but only via a bare String. Keep the String overload for source compatibility and add the sealed MapLibreStyle so the other three loading modes below have somewhere to live.

**Queried-feature value type: id, geometry, source, sourceLayer, state** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:14-35 (MapLibreQueriedFeature carries only point+properties) and :213 `if (geometry['type'] != 'Point') continue;` — every non-point feature is silently dropped; the shim's own output is full GeoJSON (core.cpp, mapbox::geojson::stringify of the FeatureCollection)
```dart
class MapLibreQueriedFeature { Object? id; MapLibreGeometry geometry; Map<String,Object?> properties; String source; String? sourceLayer; Map<String,Object?> state; LatLng? get point; bool get isCluster; int get pointCount; }
```
> TWO REAL DEFECTS in one row. (1) Querying a fill or line layer returns an EMPTY list today — the Point-only guard at map_layers_controller.dart:213 drops everything else, so 'which polygon did I tap' silently fails. (2) The feature `id` is never surfaced, which makes setFeatureState below unusable even once it is bound (feature state is keyed by id). Both are fixable in Dart except source/sourceLayer/state, which need the shim to stop slicing mbgl::Feature. gl-js's `layer` field is NOT reproducible — see the ceiling notes.

**Style error event (`error` / didFailLoadingMap)** — P1, `widget-callback`, evidence: would live alongside the style callback in packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:890
```dart
MapLibreMap(onStyleError: (MapLibreStyleError e) { … })  // e.kind: parse | load | notFound | unknown
```
> A mistyped style URL is today a silent blank map on every tier. mbgl already classifies the failure into four kinds — bind the enum, do not flatten it to a String.

**`addImage` (raw RGBA)** — P1, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:123 -> style_layers.dart:47 -> core.h:207 -> core.cpp:1669
```dart
void addImage(String id, Uint8List rgba, int width, int height, {double pixelRatio = 1.0, bool sdf = false})  // unchanged
```
> Note our ordering is (id, image) matching gl-js, not Apple's (image, forName:) — right call, gl-js and Android agree with us.

**`addLayer` — raw style-spec JSON escape hatch** — P1, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:110 -> platform_interface/lib/src/style_layers.dart:31 -> core.h:187 -> core.cpp:1569
```dart
void addLayerJson(String json, {String? beforeId})  // unchanged
```
> Keep public forever. This is the only one of the four canonical bindings that accepts a whole layer document, and it is what makes 'expressible via addLayerJson' true for every 🧪 row in §2.

**`addLayer` — typed, from the generated style API** — P1, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:93; generated layer classes packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:22,220,510,1258,1503,1659,1879,2083,2287,2404 (all 10 spec types)
```dart
void addLayer(StyleLayer layer, {String? beforeId})  // unchanged
```
> MATRIX DRIFT (Web): packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:44-49 declares `implements … MapLibreStyleLayers`, and packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:428/1017 exports addLayerJson through embind. The whole Web column of §1 and §2 is stale — web-WASM has the layer surface.

**`addSource` — typed and raw JSON** — P1, `controller-namespace`, evidence: typed packages/maplibre_flutter/lib/src/map_layers_controller.dart:97 with generated sources style_sources.g.dart:18,118,208,329,487,517; raw :106 -> style_layers.dart:27 -> core.h:181 -> core.cpp:1543
```dart
void addSource(String id, StyleSource source)  /  void addSourceJson(String id, String json)  // unchanged
```
> Both signatures already match gl-js exactly (id-then-spec, mirroring the spec's `sources` map). No change wanted.

**`getLayer` — read a layer back as spec JSON** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart and core.h next to mbl_map_query_rendered_features (h:246)
```dart
Future<Map<String, Object?>?> getLayerJson(String id)
```
> Layer::serialize is implemented per layer type (e.g. src/mbgl/style/layers/circle_layer.cpp:506) and the base adds id/type/source/source-layer/filter/minzoom/maxzoom/visibility (src/mbgl/style/layer.cpp Layer::serialize). So this is a faithful round-trip of what addLayerJson took. Returns null when no such layer, matching gl-js's undefined.

**`getLayersOrder`** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
Future<List<String>> getLayersOrder()
```
> MATRIX DRIFT, and a consequential one: the matrix says this is impossible off gl-js, but every canonical binding has it and mbgl returns the ordered vector directly. It is also the prerequisite for the p3 index/above-based insertion rows below and for 'insert my layer under the first symbol layer', the single most common style-integration recipe.

**`getLayoutProperty`** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
Future<Object?> getLayoutProperty(String layerId, String name)
```
> Shares the C read entry point with getPaintProperty.

**`getPaintProperty`** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
Future<Object?> getPaintProperty(String layerId, String name)
```
> StyleProperty carries a Kind {Undefined, Constant, Expression, Transition} (style_property.hpp:13-18). Return the decoded JSON value and let Undefined map to null — that matches gl-js, which also returns undefined for an unset property. Do NOT surface Kind in v1; note it as available if a typed getter is wanted later. CAVEAT: getProperty knows paint+layout names only (verified: getLayerProperty in src/mbgl/style/layers/circle_layer.cpp:496 returns {} for anything not in its property table), so visibility/minzoom/filter must read through their own getters.

**`isStyleLoaded`** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart (new MapLibreStyleDocument capability)
```dart
bool get isStyleLoaded  // on controller.style
```
> Track it in the shim off onDidFinishLoadingStyle (map_observer.hpp:64) rather than mapping it to isFullyLoaded — conflating the two is precisely the silent-redefinition failure mode CLAUDE.md §7 warns about.

**`moveLayer`** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:38 (next to removeLayer) and core.h:198
```dart
void moveLayer(String id, {String? beforeId})  // null beforeId = move to top
```
> gl-js name, gl-js semantics. Implementable losslessly because mbgl hands back the layer object; do the remove+add inside one render-thread post so no frame ever sees the layer missing. New entry: mbl_map_move_layer(map, id, before_id).

**`queryRenderedFeatures` — point overload** — P1, `controller-namespace`, evidence: style_layers.dart:78 takes minX/minY/maxX/maxY only; callers must synthesise a box
```dart
List<MapLibreQueriedFeature> queryRenderedFeaturesAt(Offset point, {List<String>? layerIds, Expression? filter})
```
> Not the same as a 1x1 rect: mbgl's point overload applies the layer's own hit tolerance (a line's stroke width, a circle's radius), which a degenerate box does not. Tapping a feature is THE reason people query, and our onTap (maplibre_map.dart:70) gives only a LatLng — this is what turns it into 'which road did I tap'. Renamed with an `At` suffix rather than overloading, because Dart has no overloads and `Object geometry` would be untypeable.

**`queryRenderedFeatures` — rect** — P1, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:196 -> style_layers.dart:78 -> core.h:246 -> core.cpp (mbl_map_query_rendered_features)
```dart
List<MapLibreQueriedFeature> queryRenderedFeatures(Rect rect, {List<String>? layerIds, Expression? filter})  // stays SYNCHRONOUS
```
> Keep the synchronous signature — it is called from the camera-tick overlay path and an await would cost a frame. Document that asymmetry against the new Future-returning getters. See the three follow-on rows: point overload, filter, and the feature value type.

**`removeLayer`** — P1, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:117 -> style_layers.dart:38 -> core.h:198 -> core.cpp:1639
```dart
void removeLayer(String id)  // unchanged
```
> Fine as-is. Note mbgl returns the removed unique_ptr<Layer> — that is what makes moveLayer implementable below.

**`removeSource`** — P1, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:119 -> style_layers.dart:40 -> core.h:199 -> core.cpp:1648
```dart
void removeSource(String id)  // unchanged
```
> Apple's error-returning variant exists because removing a source still referenced by a layer fails. Our shim logs and drops (core.cpp:1648). Worth surfacing eventually via the same err-buffer convention as add_source_json (core.h:176-179) — folded into the p2 'errors from style mutations' row below.

**`setFilter`** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart; the Expression type already exists at packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart
```dart
void setFilter(String layerId, Expression? filter)  // null clears the filter
```
> gl-js name and gl-js nullability. Apple's NSPredicate is an Apple-only idiom with a documented lossy mapping — do not copy it. This is the API that makes a filter-driven UI (a legend with toggles, a time slider) possible without re-adding layers; today the only route is remove+add, which re-runs layout on every toggle.

**`setLayerZoomRange`** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart; minZoom/maxZoom are construction-only today (style_layers.g.dart:1266-1267 for CircleLayer)
```dart
void setLayerZoomRange(String layerId, double minZoom, double maxZoom)
```
> gl-js name (Apple/Android split it into two properties; one call is better and matches the spec pair). Rides the setPaintProperty C entry point via the "minzoom"/"maxzoom" names.

**`setLayoutProperty`** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
void setLayoutProperty(String layerId, String name, Object? value)
```
> Shares the C entry point with setPaintProperty; the Dart split exists purely because gl-js and the spec document split them and users think in those terms. Zero extra native cost.

**Bulk property set (one call, many properties)** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
void setLayerProperties(String layerId, Map<String, Object?> properties)
```
> Chose the Android shape here because gl-js has no equivalent and the cost model demands it: every single-property call is a render-thread post, so animating three properties per frame is three posts. One call, one post. Also the natural implementation of 'apply this whole typed layer's paint block'.

**Cluster expansion zoom / children / leaves** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78 (next to queryRenderedFeaturesJson); cluster metadata is surfaced today only as point_count on a queried feature (map_layers_controller.dart:27-30)
```dart
Future<double> getClusterExpansionZoom(String sourceId, int clusterId)  /  Future<List<MapLibreQueriedFeature>> getClusterChildren(String sourceId, int clusterId)  /  getClusterLeaves(sourceId, clusterId, {int limit = 10, int offset = 0})
```
> gl-js names (the SDKs agree modulo casing). This is the missing half of a feature we already advertise: our own docs (style_layers.dart:14-16, map_layers_controller.dart:186-195) sell in-engine clustering, and 'tap a cluster to zoom to where it splits' is the canonical interaction — currently impossible without reimplementing supercluster in Dart. Runs through queryFeatureExtensions with extension "supercluster" and fields "expansion-zoom"/"children"/"leaves".

**Error reporting from style mutations** — P2, `controller-namespace`, evidence: the C ABI already returns 1/0 + an err buffer for the three JSON entry points (core.h:181/187/193) and the shim documents that render-thread-only errors are LOGGED not returned (core.h:177-179); Dart maps them to ArgumentError at packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:576 (_styleCall) — but removeLayer/removeSource/addImage return nothing at all
```dart
— (widen the existing err-buffer convention to the new mutators; keep throwing ArgumentError)
```
> Design note for whoever implements setPaintProperty et al.: follow the EXISTING split at core.h:174-179 — parse and validate synchronously on the calling thread so a bad value throws immediately, and post only the mutation. Do not invent a second error channel. The gap worth closing is duplicate-id and missing-id, which mbgl can only detect on the render thread; the honest answer there is the onStyleError callback, not a return code.

**GeoJSON `setUrl` at runtime** — P2, `controller-namespace`, evidence: would live next to setGeoJsonData in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:36
```dart
void setGeoJsonUrl(String sourceId, String url)
```
> MATRIX GAP: no row exists. Apple/Android both expose it and mbgl has it directly. gl-js reaches it by passing a URL string to setData, which is a shape we could copy instead — but a separate method is clearer and matches the two native SDKs. Left `gljs` unverified rather than inventing a signature.

**Image source `setCoordinates`** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
void setImageSourceCoordinates(String sourceId, List<LatLng> corners)  // exactly 4, TL/TR/BR/BL
```
> LatLng(lat,lng) vs GeoJSON [lng,lat] applies at this boundary too — the corner order is a spec convention (top-left, top-right, bottom-right, bottom-left) and must be asserted with an ASYMMETRIC fixture per CLAUDE.md §11, not a round-trip. Assert an ArgumentError on length != 4 rather than silently truncating.

**Image source `setImage` / `updateImage`** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:47 (next to addImage)
```dart
void setImageSourceImage(String sourceId, Uint8List rgba, int width, int height)
```
> Same premultiplied-RGBA contract as our existing addImage (core.h:201-210), so the marshalling is already proven. This is how you put a live video frame or a weather radar sweep on the map without a raster tile server.

**Layer exists / hasLayer** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
Future<bool> hasLayer(String id)  // sugar over getLayersOrder/getLayerJson
```
> Pure Dart sugar once getLayersOrder lands. Worth having because addLayer on a duplicate id throws in Apple (MLNRedundantLayerIdentifierException, MLNStyle.h:19) and is logged-and-dropped in our shim — callers currently have no way to check first.

**List sources / `isSourceLoaded`** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
Future<List<String>> getSourceIds()  +  Future<bool> isSourceLoaded(String id)
```
> Both are trivial C entry points. Note Apple returns an unordered NSSet while layers are an ordered NSArray — source order is meaningless, so a List<String> of ids is fine and matches the spec's `sources` map.

**Per-property transition (`*-transition`) at runtime** — P2, `controller-namespace`, evidence: construction-only — StyleTransition on every transitionable property, e.g. style_layers.g.dart:1272 circleRadiusTransition, generated/style_transition.g.dart:16
```dart
void setPaintProperty(layerId, 'circle-color-transition', {'duration': 300, 'delay': 0})  // falls out of setPaintProperty
```
> Free once setPaintProperty exists — no new API needed, just a documented recipe. Worth a doc example because it is the per-layer alternative to the style-wide setTransitionOptions, and the style-wide one is the sharp edge already documented at map_layers_controller.dart:141-171.

**Stretchable images (`stretchX`/`stretchY`), `content` box, text-fit** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.h:207 — mbl_map_add_image takes only rgba/width/height/pixel_ratio/sdf; core.cpp:1669 constructs style::Image with the short ctor
```dart
void addImage(String id, Uint8List rgba, int width, int height, {double pixelRatio = 1.0, bool sdf = false, List<(double,double)>? stretchX, List<(double,double)>? stretchY, Rect? content, TextFit? textFitWidth, TextFit? textFitHeight})
```
> MATRIX DRIFT: text-fit marked web_only although mbgl::style::Image takes it (image.hpp:44-45, 84-87). This is the nine-patch story — the ONLY way to draw a label chip that grows with its text (`icon-text-fit: both` + a stretchable background). Right now every such marker has to be a fixed-size widget icon. Extend the existing mbl_map_add_image rather than adding a second entry point; the trailing params are all defaultable.

**Style-wide transition options (duration / delay / placement fade)** — P2, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:172 -> style_layers.dart:63 -> core.h:227 -> core.cpp:858; re-applied after every style load at core.cpp:891
```dart
void setTransitionOptions({Duration? duration, Duration? delay, bool placementTransitions = true})  // unchanged, stays on controller.layers
```
> Apple/Android shape adopted deliberately because gl-js has no Map-level equivalent. Keep it on `layers` rather than migrating it to a new `controller.style` namespace — two names for one operation is worse than a slightly odd home, and the contract churn buys nothing. The stickiness across style loads (core.cpp:891) matches Apple's behaviour and should stay.

**Vector source `setTiles`** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
void setVectorSourceTiles(String sourceId, List<String> tileUrlTemplates)
```
> MATRIX DRIFT: marked ➖ web_only for both vector and raster; it exists in mbgl for VECTOR. The correct matrix cell is ❌ for vector and ➖ for raster — the row conflates two source types that genuinely differ. The use case is swapping an API key or a tile host without rebuilding the style.

**`addWidgetIcon` — rasterize a Flutter widget into a style image** — P2, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:387, with the reusable rasterizer at :428
```dart
Future<void> addWidgetIcon(String id, Widget widget, {required Size size, double pixelRatio = 3.0, bool sdf = false})  // unchanged
```
> MATRIX GAP: this is a genuine differentiator over all four canonical bindings and it is not in the parity matrix at all — the matrix only tracks what MapLibre has, so anything we add beyond it is invisible. Worth an 'extensions' section alongside the 3D model rows in §9. Also: the doc-comment note that `size` is a MAXIMUM (map_layers_controller.dart:422-427) is subtle and should be surfaced in the README, not just the dartdoc.

**`areTilesLoaded` / fully-loaded** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_core/src/maplibre_flutter_core.h alongside mbl_map_presented_generation (h:260)
```dart
bool get areTilesLoaded  // on controller.style
```
> MATRIX DRIFT: marked ➖ web_only, but it is a one-line C ABI over an existing mbgl getter. Useful for tests and for 'wait until the map is settled before screenshotting'.

**`getFeatureState` / `removeFeatureState`** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
Future<Map<String,Object?>> getFeatureState({required String source, String? sourceLayer, required Object id})  /  void removeFeatureState({required String source, String? sourceLayer, Object? id, String? stateKey})
```
> mbgl's remove takes optional id AND optional key (renderer.hpp:84-87), i.e. it can clear a whole source — richer than gl-js's (feature, key?). Copy mbgl's nullability, keep gl-js's name; note the widening in the dartdoc.

**`getFilter`** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
Future<Object?> getFilterJson(String layerId)  // and Future<Expression?> getFilter(String layerId) once Expression.fromJson exists
```
> Filter::serialize (filter.hpp:46-50) round-trips to spec JSON, so the raw form is free. The typed form needs an Expression.fromJson in the generator — same work item as the typed getLayer row.

**`getLayer` — read a layer back as a TYPED StyleLayer** — P2, `controller-namespace`, evidence: needs a generator change in packages/maplibre_flutter/tool/generate_style_api.dart (emit `factory XLayer.fromJson`) plus a StyleLayer.fromJson dispatcher in packages/maplibre_flutter/lib/src/style/style_layer.dart:11
```dart
Future<StyleLayer?> getLayer(String id)  // typed, decoded via generated fromJson
```
> The generated layers are currently write-only (toJson at style_layers.g.dart:1440 for CircleLayer, no fromJson). Adding fromJson is a generator change, so it must THROW on an unmapped type exactly like the existing generator does (CLAUDE.md §5d), and it will show up in the CI regen-diff. Ships on top of getLayerJson, no extra transport.

**`getSource` — read a source back** — P2, `value-type`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
Future<MapLibreSourceInfo?> getSource(String id)  // {id, type, attribution, isVolatile, url?, tiles?, coordinates?}
```
> CEILING CAVEAT: unlike a layer, a source cannot be serialized back to its spec document (no Source::serialize anywhere in include/mbgl/style/). Bind the attributes mbgl does expose plus the per-subtype getters (GeoJSONSource::getURL geojson_source.hpp:70, TileSource::getURL tile_source.hpp:19, VectorSource::getTiles vector_source.hpp:26, ImageSource::getCoordinates image_source.hpp:26) as a value type. Do NOT pretend to return a SourceSpecification.

**`getStyle` — serialize the live style document** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp near mbl_map_query_rendered_features (cpp:~1770)
```dart
Future<Map<String, Object?>?> getStyle()  // on controller.style
```
> Bind the honest version: assemble {version, name, sources: <from the loaded doc>, layers: [Layer::serialize()…]} and DOCUMENT that runtime-added sources are not reflected, because mbgl cannot serialize a Source. Do not bind Style::getJSON as `getStyle` — it silently returns a stale document.

**`hasImage` / `getImage`** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:47
```dart
Future<bool> hasImage(String id)
```
> MATRIX DRIFT ON BOTH ROWS. Bind hasImage (cheap, and the natural partner of the styleimagemissing callback). Skip getImage returning pixels — copying a bitmap back across the C ABI to hand an app data it just supplied is not worth the entry point; if it is ever wanted it is a separate p3.

**`queryRenderedFeatures` — filter argument** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78 exposes layerIds only; core.h:246 likewise
```dart
…, {List<String>? layerIds, Expression? filter}  // on both query overloads
```
> All four canonical bindings have it and mbgl takes it in the options struct we already construct (core.cpp passes RenderedQueryOptions(layers) with the filter defaulted). Filtering inside the engine avoids marshalling thousands of features across the C ABI just to drop them in Dart.

**`querySourceFeatures`** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78
```dart
Future<List<MapLibreQueriedFeature>> querySourceFeatures(String sourceId, {List<String>? sourceLayers, Expression? filter})
```
> Differs from queryRenderedFeatures in that it ignores the viewport and returns everything loaded, filtered — the right tool for 'how many of X are in this tile set'. Reuses the exact render-thread post + timeout machinery already written for mbl_map_query_rendered_features (core.cpp), so it is cheap.

**`setFeatureState`** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
void setFeatureState({required String source, String? sourceLayer, required Object id, required Map<String, Object?> state})
```
> gl-js is the ONLY canonical binding with this, but mbgl has it in full — so we can be ahead of the two native SDKs here. This is the correct mechanism for hover/selection highlighting: it re-paints without re-tiling, unlike setFilter or a data reload. Depends on the feature-id row above (you cannot address a feature you were never given the id of). Named parameters rather than gl-js's positional {source,id} object literal.

**`setLight` / `getLight`** — P2, `controller-namespace`, evidence: would live in a new controller.style namespace in packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:60 (next to `layers`)
```dart
void setLight(StyleLight light)  +  Future<StyleLight?> getLight()  // StyleLight generated from the spec `light` schema
```
> The root `light` object is the missing piece of fill-extrusion styling — §9 lists fill-extrusion as 🧪 while its lighting is unbindable, which is only half a feature. mbgl's Light has the same setProperty(name, Convertible) shape as Layer (light.hpp:25), so ONE more C entry point (mbl_map_set_light_json) covers the whole object. StyleLight should be GENERATED from the spec's `light` schema by tool/generate_style_api.dart, not hand-written — the generator already reads that file.

**`styleimagemissing` event** — P2, `widget-callback`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
MapLibreMap(onStyleImageMissing: (String id) async { … controller.layers.addImage(id, …); })
```
> MATRIX SELF-CONTRADICTION (line 495 vs 559). Genuinely cross-platform in mbgl. This is the lazy-icon-loading pattern: name an icon in a data-driven `icon-image` expression and supply the bitmap on demand instead of pre-registering thousands.

**Change a layer's `source-layer` / `source` at runtime** — P3, `controller-namespace`, evidence: construction-only (`sourceLayer` field, style_layers.g.dart:1310); would live in style_layers.dart
```dart
void setLayerSourceLayer(String layerId, String sourceLayer)
```
> Rides the same C entry point ('source-layer'). Apple deliberately makes `sourceIdentifier` read-only while `sourceLayerIdentifier` is writable — copy that: expose source-layer, do NOT expose setLayerSource, because mbgl warns-and-ignores it for layer types whose LayerTypeInfo::source is NotRequired (src/mbgl/style/layer.cpp).

**Custom layer (app-supplied draw calls)** — P3, `reject`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1055 constructs an mbgl::style::CustomDrawableLayer for the 3D model host; there is no public Dart API and MapLibreModelHost (platform_interface/lib/src/model_host.dart) is the only consumer
```dart
— (reject as a general API; keep MapLibreModelHost as the one curated consumer)
```
> MATRIX DRIFT (severity: misleading): ❌ suggests this is on the backlog. It is not bindable — a Dart callback cannot issue draw calls into mbgl's render thread, and CLAUDE.md §11 already records that raw CustomLayer is a dead end off OpenGL. The right framing is: we expose CURATED CustomDrawableLayer users (today: 3D models), not a generic hook. Recommend changing the cell to ➖ with that note.

**Insert a layer at an index / above another layer** — P3, `reject`, evidence: only beforeId exists (packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:31)
```dart
— (reject; compose from getLayersOrder + beforeId)
```
> REJECT as API, DOCUMENT as a recipe. Two of four canonical bindings have it, but mbgl does not, so we would be reimplementing index arithmetic in Dart over getLayersOrder — which the caller can do in three lines, visibly, with the ordering they can inspect. Following gl-js here also keeps one insertion concept instead of three.

**Map-wide tile prefetch (`setPrefetchZoomDelta`)** — P3, `widget-init`, evidence: would live in packages/maplibre_flutter_core/src/maplibre_flutter_core.h
```dart
MapOptions(prefetchZoomDelta: 4)  // init-only; 0 disables
```
> Init-only by the three-bucket rule — it is a load-strategy choice, not something an app flips per frame. Apple reduces it to a BOOL; keep mbgl's int (a delta of 4 is the default) and let 0 mean off, which covers Apple's NO.

**Named `slot` insertion points** — P3, `reject`, evidence: n/a
```dart
— (reject)
```
> MATRIX DRIFT (severity: cosmetic): listed as ❌ ('engine can do it, we haven't bound it'), which by the matrix's own ❌-vs-➖ rule at line 52 is wrong — nothing in MapLibre has slots. Should be ➖, or dropped.

**Predefined / default styles list** — P3, `reject`, evidence: n/a — the example hardcodes style URLs (packages/maplibre_flutter/example/lib/main.dart:1205)
```dart
— (reject for this domain)
```
> REJECT HERE, not globally: this belongs with tile-server/auth options (MLNTileServerOptions.h, MLNSettings.h), which is another domain's row. Flagging it so it is not lost — Apple's `predefinedStyles` is the API a style-picker UI wants.

**Source tuning: volatile, prefetch delta, min tile update interval, max overscale** — P3, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
void setSourceTileOptions(String sourceId, {bool? volatile, int? prefetchZoomDelta, Duration? minimumTileUpdateInterval, int? maxOverscaleFactorForParentTiles})
```
> mbgl-only knobs with no counterpart in any of the four canonical bindings — genuine native_only. Real value for a mobile app on a metered connection. One method with named optionals rather than four setters, because they are always tuned together.

**Style name** — P3, `controller-namespace`, evidence: would live in packages/maplibre_flutter_core/src/maplibre_flutter_core.h
```dart
Future<String?> getStyleName()  // on controller.style
```
> Trivial once the style-document capability exists; useful for a style picker UI.

**Style's default camera (`center`/`zoom`/`bearing`/`pitch` root props)** — P3, `controller-namespace`, evidence: would live in packages/maplibre_flutter_core/src/maplibre_flutter_core.h; MapOptions.initialCamera (platform_interface/lib/src/map_options.dart:19) always wins today
```dart
Future<MapCamera?> getStyleDefaultCamera()  // on controller.style; plus MapOptions(useStyleCamera: true)
```
> Today MapOptions.initialCamera defaults to LatLng(0,0)/zoom 0, so a style that specifies a sensible default view is ignored. Every other binding honours it.

**Unused-style-image removal veto** — P3, `reject`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
— (reject)
```
> REJECT: a synchronous bool callback from the render thread into Dart is the one shape we cannot do safely (no method channels on the data path, and a Dart callback cannot block mbgl's render loop). Default behaviour (remove unused) is correct for us because addWidgetIcon-registered images are cheap to re-register.

**`getTransition`** — P3, `controller-namespace`, evidence: write-only today (packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:63)
```dart
Future<({Duration? duration, Duration? delay, bool placementTransitions})> getTransitionOptions()
```
> Only interesting because the setter's nulls mean 'keep the style document's value' — without a getter an app cannot discover what that value actually is. Low priority.

**`listImages`** — P3, `reject`, evidence: n/a
```dart
— (reject)
```
> Genuine ceiling. The app knows which ids it registered; the style's own sprite ids are not enumerable through the public API.

**`localizeLabels` (rewrite text-field to a locale)** — P3, `controller-namespace`, evidence: would live in a controller.style namespace
```dart
Future<void> localizeLabels(Locale? locale)  // pure Dart over getLayersOrder + getLayoutProperty + setLayoutProperty
```
> CEILING NUANCE: mbgl cannot do it, but WE can — it is an expression rewrite, and once getLayoutProperty/setLayoutProperty exist it is ~40 lines of Dart shared by all six tiers. Apple's version is hardcoded to Mapbox Streets field names (MLNStyle.h:288-296); ours should key off the style's own `name:xx` convention and be documented as best-effort. Blocked on the property get/set rows.

**`setGlobalStateProperty` / `getGlobalState`** — P3, `reject`, evidence: n/a
```dart
— (reject for now)
```
> Hard stop TODAY, but the matrix's own note says there is an open upstream tracking issue — so this is the one ➖ in this domain likely to become a ❌. Worth a watch item rather than a permanent rejection.

**`setGlyphs` / `getGlyphs`, sprite runtime API** — P3, `reject`, evidence: n/a
```dart
— (reject)
```
> MATRIX DRIFT: lines 560-563 and 568 mark the sprite/glyph ROOT properties ❌ (bindable, unbound) when there is no runtime API in mbgl at all — the only way to change them is to load a different style document, which we already support. Those cells should be ➖ or folded into the style-loading rows.

**`setProjection` / `getProjection` (globe)** — P3, `reject`, evidence: n/a
```dart
— (reject)
```
> Hard stop, and the matrix already keeps the two projection concepts separate (line 343 vs line 345) — that distinction is correct and should be preserved.

**`setSky` / `getSky`** — P3, `reject`, evidence: n/a
```dart
— (reject)
```
> Hard stop for all six of our tiers, including web — our web tier is the WASM core, not gl-js, so 'web_only' in the matrix means 'reachable only via the opt-in maplibre_flutter_web_gljs package'. Worth restating in the matrix header because it reads as if our web column could have it.

**`setTerrain` / `getTerrain`** — P3, `reject`, evidence: n/a
```dart
— (reject)
```
> Hard stop. The raster-dem SOURCE and the hillshade LAYER do exist in mbgl and are already 🧪 — do not let the terrain ➖ get confused with those.

**`sourcedata` / source-changed event** — P3, `widget-callback`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
MapLibreMap(onSourceChanged: (String sourceId) { … })
```
> Low value on its own; bundle it with the onStyleLoaded/onStyleError callback plumbing since it is the same observer and the same C entry point shape.

**`updateImage`** — P3, `controller-namespace`, evidence: implicitly — mbl_map_add_image overwrites by id (core.cpp:1669 constructs a new style::Image under the same id); no distinct API and no doc saying so
```dart
— (document that addImage overwrites; do not add a second name)
```
> MATRIX DRIFT: marked ➖ web_only when it already works. Fix is a doc line on addImage, not code. Following Apple's own wording ("Adds or overrides") rather than gl-js's two-method split, because a second Dart method that does exactly what the first one does is worse API.


### Expressions, filters, feature-state & transitions

#### Engine ceiling

Hard stops for the five native tiers **and** web-WASM (one engine), each verified in the vendored submodule at `core-fa8a9c8e3261ce64940127aecc1d52f540c21c57`:

1. **`promoteId` is not implemented at all.** `grep -rni promoteid src/ include/ platform/` over the whole submodule returns zero hits. `src/mbgl/style/conversion/geojson_options.cpp:14-175` reads exactly `minzoom, maxzoom, buffer, tolerance, cluster, clusterMaxZoom, clusterRadius, clusterMinPoints, lineMetrics, synchronousUpdate, clusterProperties`; `src/mbgl/style/conversion/source.cpp:22-215` never reads it for vector sources either. The key is silently discarded. **Consequence for this whole domain:** feature state can only be keyed on a real top-level GeoJSON/MVT `id`.

2. **`generateId` is not implemented either.** Same grep, same file (`geojson_options.cpp:14-175`). So the gl-js escape hatch for id-less data does not exist. Combined with (1), an app whose GeoJSON has no ids cannot use feature state at all.

3. **Source-level `filter` on a geojson source is not implemented** (spec key `source_geojson.filter`; absent from `geojson_options.cpp`). Our generated `GeoJsonSource` will serialize it and mbgl will drop it.

4. **Feature state only affects data-driven PAINT properties.** `src/mbgl/renderer/paint_property_binder.hpp:338` re-evaluates with `EvaluationContext(&feature).withFeatureState(&state)` and writes one vertex attribute; nothing re-runs layout. So layout properties, filters and symbol placement are untouched by a state change — matching the spec's own note but worth binding-level documentation.

5. **Feature state only works on tile sources.** `RenderTileSource` implements set/get/remove (`src/mbgl/renderer/sources/render_tile_source.cpp:543-560`); the `RenderSource` base is an empty no-op (`src/mbgl/renderer/render_source.hpp:98-104`). Image, video and raster sources silently accept and ignore state.

6. **Feature ids are strings at the mbgl boundary.** `Renderer::setFeatureState(..., const std::string& featureID, ...)` — `include/mbgl/renderer/renderer.hpp:76`. gl-js's `string | number` union collapses, so integer id `42` and string id `"42"` address the same feature. Not a blocker; must be documented.

7. **Query results carry no source/layer/state attribution.** `RenderOrchestrator::queryRenderedFeatures` builds `resultsByLayer` keyed by layer id and then flattens it into a bare `std::vector<Feature>` (`src/mbgl/renderer/render_orchestrator.cpp:668-674`); the public `mbgl::Feature` type has no such fields. gl-js's `MapGeoJSONFeature.source/.sourceLayer/.layer/.state` are unreproducible. The Apple SDK has the same flattening (`MLNMapView.h:2253`). Workaround: one query per layer id.

8. **`moveLayer` does not exist as an atomic operation.** `include/mbgl/style/style.hpp:71-72` offers only `addLayer(layer, beforeLayerID)` and `removeLayer(id)`. A move must be remove-then-reinsert; it is lossless (removeLayer returns the owning `unique_ptr`) but must happen inside one render-thread post.

9. **`global-state` / `setGlobalStateProperty`, and `split` / `join`, do not exist in the pinned core** — absent from `src/mbgl/style/expression/parsing_context.cpp:107-144`, from `src/mbgl/style/expression/compound_expression.cpp:1019-1099`, and from the vendored `scripts/style-spec-reference/v8.json` (which lists exactly 84 `expression_name` values). The *live* MapLibre spec docs list all three, so this is submodule lag, not a permanent ceiling.

10. **Terrain-driven `elevation` is unreachable.** `elevationCompoundExpression` has two paths (`compound_expression.cpp:372-390`): `colorRampParameter` (color-relief) and `params.elevation` (3D terrain). mbgl's style parser has no `terrain` key at all (`grep terrain src/mbgl/style/parser.cpp` → nothing), so only the color-relief path is live. **This is NOT the same as "elevation is not in mbgl-core", which is what FEATURE_MATRIX.md:271 claims** — the operator is registered (`compound_expression.cpp:1030`), the `color-relief` layer ships (`include/mbgl/style/layers/color_relief_layer.hpp`, factory at `src/mbgl/layermanager/color_relief_layer_factory.cpp:9`), and we already generate both the builder and the layer.

11. **No "skip validation" path** for style setters — `Layer::setProperty` (`src/mbgl/style/layer.cpp:166`) always converts. gl-js's `StyleSetterOptions.validate` has nothing to bind to.

Everything else in this domain is reachable: `Renderer::setFeatureState/getFeatureState/removeFeatureState` (`include/mbgl/renderer/renderer.hpp:74-87`), `Renderer::queryFeatureExtensions` for cluster children/leaves/expansion-zoom (`:67`), `RenderedQueryOptions::filter` and `SourceQueryOptions` (`include/mbgl/renderer/query.hpp:16-39`), `Layer::setFilter/getFilter/setProperty/getProperty/serialize` (`include/mbgl/style/layer.hpp:126-141`), per-property `*-transition` by spec name (`src/mbgl/style/layers/circle_layer.cpp:432`), and `Style::getJSON/getLayers` (`include/mbgl/style/style.hpp:32,65`). The shim already has mbgl's private `src/` on its include path (`packages/maplibre_flutter_core/src/CMakeLists.txt:655`), so `conversion/stringify.hpp` and `rapidjson_conversion.hpp` are available for the getters.

#### Naming decisions

**Policy applied: gl-js verbs win for style/data operations; Apple/Android shapes win where gl-js has no equivalent; Flutter idiom only where a gl-js name would be un-Dartlike.** Every adaptation is listed below.

**1. Where gl-js and the SDKs genuinely disagree — feature-state.** gl-js has `map.setFeatureState / getFeatureState / removeFeatureState`. **Neither the Apple SDK nor the Android SDK exposes feature state at all** — I grepped all 164 Apple headers (`grep -rn "eatureState" …/MapLibre.framework/Headers` → zero hits) and the vendored Android sources (`platform/android/…/style/expressions/Expression.java` has `properties()`, `geometryType()`, `id()`, `accumulated()`, `heatmapDensity()`, `lineProgress()`, `zoom()` and **no** `featureState()`). The only in-tree consumers of `Renderer::setFeatureState` are `platform/node/src/node_map.cpp:1262` and `platform/glfw/glfw_view.cpp:1140`. **I chose gl-js**, because (a) the engine capability is fully plumbed (`Renderer` → `RenderOrchestrator` → `RenderTileSource` → `GeometryTile` → `bucket->update`), (b) the SDKs' silence is an SDK gap, not an engine ceiling, and (c) `feature-state` is in the spec our typed API is generated from, so `Expr.featureState` already exists in our public API and is currently a dead builder. Copying "nothing" would leave a generated API that lies.

**2. Adaptation: `FeatureIdentifier` → `MapLibreFeatureRef`.** gl-js passes an anonymous object `{source, sourceLayer?, id?}`. Dart has no anonymous records in a public API worth shipping, so this becomes a small value type with the *same three field names*. gl-js makes `id` optional so that `removeFeatureState({source})` can clear a whole source; making `id` nullable in Dart would make `set`/`get` unsound, so I split it: `id` is **required** on the ref, and clearing a whole source/source-layer is a separate `clear(source, {sourceLayer})`. Same capability, no nullable-id landmine.

**3. Adaptation: namespace absorbs the noun.** `controller.featureState.set/get/remove/clear` rather than `controller.setFeatureState(...)`. The house rule already says group a large imperative surface into a namespace (`controller.camera`, `controller.layers`); `controller.featureState.setFeatureState(...)` stutters. The verbs are kept verbatim so the gl-js docs remain greppable. This is the same move `controller.layers.addLayer` already makes against gl-js's `map.addLayer`.

**4. Filters: gl-js `setFilter`/`getFilter`, not Apple's `predicate`.** Apple models filters as `NSPredicate` (`MLNVectorStyleLayer.h:54`) and property values as `NSExpression` (`MLNCircleStyleLayer.h:175`), with `MLNStyleValue` explicitly deprecated in favour of `NSExpression` (`MLNStyleValue.h:31`). That is a Cocoa-native re-skin with no Dart analogue — and Apple itself provides the JSON bridge `+[NSExpression expressionWithMLNJSONObject:]` / `-mgl_jsonExpressionObject` (`NSExpression+MLNAdditions.h:228,243`) and `+[NSPredicate predicateWithMLNJSONObject:]` (`NSPredicate+MLNAdditions.h:25`) as the escape hatch. **Our `Expression`/`Expr` IS that JSON bridge, promoted to the primary API** — which is exactly what Android does too (`CircleLayer.setFilter(Expression)`, `Expression.toArray()`). So: gl-js names, Android's typed-expression shape, Apple's JSON bridge as the underlying transport. No `NSPredicate` analogue is proposed.

**5. Transitions: Apple/Android shape for the style-wide setter, gl-js for the per-property one.** gl-js has **no runtime style-wide transition setter** — its `fadeDuration` is an init-only `MapOptions` field and `transition` is a style-document key. Apple has `MLNStyle.transition` (`MLNStyle.h:98`) + `MLNStyle.performsPlacementTransitions` (`MLNStyle.h:105`); Android has `Style.setTransition(TransitionOptions)` (`Style.java:659`) where `TransitionOptions` carries `duration/delay/enablePlacementTransitions` (`TransitionOptions.java:37`). We already shipped the Apple/Android shape (`layers.setTransitionOptions(duration:, delay:, placementTransitions:)`), which is correct — keep it. For **per-property** transitions the SDKs use typed accessors (`circleColorTransition`, `MLNCircleStyleLayer.h:201`; `CircleLayer.setCircleColorTransition`, `CircleLayer.java:236`), but mbgl's own generic path is the spec-named `"circle-color-transition"` property (`circle_layer.cpp:432`), which is byte-identical to gl-js's `setPaintProperty(layer, 'circle-color-transition', {...})`. **gl-js wins**: one generic `setPaintProperty` covers all ~180 transitionable properties instead of 180 generated setters, and the typed layer classes already carry `StyleTransition` fields for the construction-time case.

**6. Adaptation: `StyleSetterOptions.validate` is dropped.** gl-js's setters take `{validate?: boolean}`. mbgl validates unconditionally inside `convertJSON<T>` / `Layer::setProperty` and there is no "skip validation" path in the C++ API, so the flag has nothing to bind to. Rejected rather than faked.

**7. Adaptation: `Duration` for transitions, not milliseconds.** Apple uses `NSTimeInterval` seconds (`MLNTypes.h:94-104`), Android `long` millis, gl-js `number` millis, the spec millis. We already use `Duration` at the Dart boundary and convert at the C ABI. Keep. `StyleTransition` (generated, `style_transition.g.dart:16`) uses `double?` millis because it is generated straight from the spec schema — that asymmetry is deliberate and should stay, since regenerating would clobber a hand-edit.

**8. `MapLibreQueriedFeature` gains `id`, `state` and `layerId` — but only `id` is honest.** gl-js's `MapGeoJSONFeature` carries `id`, `source`, `sourceLayer`, `layer`, `state`. mbgl's public query returns a bare `std::vector<Feature>` (`renderer.hpp:57-60`) and `RenderOrchestrator::queryRenderedFeatures` explicitly **flattens** its internal `resultsByLayer` map into one vector (`render_orchestrator.cpp:668-674`), so source/layer attribution is destroyed inside the engine. The Apple SDK returns the same flattened `NSArray<id<MLNFeature>>`. So we bind `id` (which mbgl does keep, and `mapbox::geojson::stringify` does emit — `geojson_impl.hpp:463`) and document per-layer querying as the only way to get attribution. Do **not** invent a `layer` field.

#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | Feature `id` surfaced from queryRenderedFeatures | partial | queryRenderedFeatures(...)[i].id — MapGeoJSONFeature carries id, source, sourceLayer, layer, state | `MLNFeature.identifier` (id<NSObject>) — MLNFeature.h; cluster id via `MLNCluster.clusterIdentifier` (MLNCluster.h:46) | mbgl::Feature == mapbox::feature::feature<double>, whose `id` IS serialized by mapbox::geojson::stringify — vendor/maplibre-native-base/deps/geojson.hpp/include/mapbox/geojson_impl.hpp:463 | value-type | no |
| P0 | WEB COLUMN of FEATURE_MATRIX §3 (all rows) | present | n/a — this is our WASM tier, not gl-js *(unverified)* | n/a | same mbgl-core compiled to WASM; the web query goes through the same renderer->queryRenderedFeatures at maplibre_flutter_core_web.cpp:542 | reject | no |
| P1 | Cluster expansion / children / leaves (queryFeatureExtensions) | none | GeoJSONSource.getClusterExpansionZoom(clusterId): Promise<number>; getClusterChildren(clusterId): Promise<Feature[]>; getClusterLeaves(clusterId, limit, offset): Promise<Feature[]> | -[MLNShapeSource zoomLevelForExpandingCluster:] (MLNShapeSource.h:437); -childrenOfCluster: (MLNShapeSource.h:426); -leavesOfCluster:offset:limit: (MLNShapeSource.h:408); MLNCluster protocol at MLNCluster.h:43-49 | mbgl::Renderer::queryFeatureExtensions(sourceID, feature, extension, extensionField, args) — include/mbgl/renderer/renderer.hpp:67; implemented for geojson at src/mbgl/renderer/sources/render_geojson_source.cpp:119; underlying data at include/mbgl/style/sources/geojson_source.hpp:52-54 (getChildren/getLeaves/getClusterExpansionZoom) | controller | yes |
| P1 | MapLibreFeatureRef — the gl-js FeatureIdentifier value type | none | type FeatureIdentifier = {id?: string \| number; source: string; sourceLayer?: string} | — (no equivalent; MLNFeature has `identifier` but there is no ref type) | the three params of Renderer::setFeatureState — include/mbgl/renderer/renderer.hpp:74-77 (featureID is std::string, NOT a variant) | value-type | no |
| P1 | Runtime `setFilter` on an existing layer | none | map.setFilter(layerId: string, filter?: FilterSpecification \| null, options?: StyleSetterOptions): this | `MLNVectorStyleLayer.predicate` (NSPredicate, readwrite) — MLNVectorStyleLayer.h:54; JSON bridge via +[NSPredicate predicateWithMLNJSONObject:] (NSPredicate+MLNAdditions.h:25) | mbgl::style::Layer::setFilter(const Filter&) — include/mbgl/style/layer.hpp:127; also reachable generically via Layer::setProperty("filter", …) — src/mbgl/style/layer.cpp:181-186 | controller | yes |
| P1 | Runtime layer visibility toggle | partial | map.setLayoutProperty(layerId, 'visibility', 'none' \| 'visible') | MLNStyleLayer.visible (BOOL, getter=isVisible) — MLNStyleLayer.h:52 | Layer::setVisibility(VisibilityType) — include/mbgl/style/layer.hpp:131; via setProperty("visibility") — src/mbgl/style/layer.cpp:170 | controller | no |
| P1 | Runtime setLayoutProperty | none | map.setLayoutProperty(layerId, name, value, options?): this | typed NSExpression properties (e.g. MLNSymbolStyleLayer.textField) | Layer::setProperty — include/mbgl/style/layer.hpp:138 | controller | no |
| P1 | Runtime setPaintProperty | none | map.setPaintProperty(layerId, name, value, options?: StyleSetterOptions): this | typed NSExpression properties, e.g. `MLNCircleStyleLayer.circleColor` (MLNCircleStyleLayer.h:175); MLNStyleValue is deprecated in favour of NSExpression (MLNStyleValue.h:31-32) | mbgl::style::Layer::setProperty(name, Convertible) — include/mbgl/style/layer.hpp:138, dispatcher at src/mbgl/style/layer.cpp:165 | controller | yes |
| P1 | `feature-state` expression — reachability of the generated Expr.featureState builder | internal-only | ["feature-state", key] — fully supported | — (no $featureState variable; NSExpression+MLNAdditions.h:63-111 exposes zoomLevel, heatmapDensity, lineProgress, geometryType, featureIdentifier, featureAccumulated, featureAttributes — and NOTHING for feature state) | featureStateCompoundExpression — src/mbgl/style/expression/compound_expression.cpp:732-747, registered at :1070; feature-dependent per is_constant.cpp:19 | capability-interface | yes |
| P1 | `promoteId` on a source (feature ids from an arbitrary property) | present | source spec key `promoteId`, honoured by gl-js | — (no MLNShapeSourceOption for promoteId; MLNShapeSource.h:35-170 lists clustered, clusterRadius, clusterMinPoints, clusterProperties, min/max zoom, buffer, tolerance, lineDistanceMetrics, synchronousUpdate — and nothing else) | **NOT IN CORE.** `grep -rni promoteid src/ include/ platform/` returns zero hits. src/mbgl/style/conversion/geojson_options.cpp:14-175 reads exactly minzoom, maxzoom, buffer, tolerance, cluster, clusterMaxZoom, clusterRadius, clusterMinPoints, lineMetrics, synchronousUpdate, clusterProperties. src/mbgl/style/conversion/source.cpp:22-215 never looks at it either. | reject | no |
| P1 | removeFeatureState (one key on one feature) | none | map.removeFeatureState(feature: FeatureIdentifier, key?: string): this | — | mbgl::Renderer::removeFeatureState(sourceID, sourceLayerID, featureID, stateKey) — include/mbgl/renderer/renderer.hpp:84 (all three trailing params are std::optional) | controller-namespace | yes |
| P1 | setFeatureState | none | map.setFeatureState(feature: FeatureIdentifier, state: any): this | — (no feature-state API anywhere in the 164 public headers; grep -rn "eatureState" MapLibre.framework/Headers returns nothing) | mbgl::Renderer::setFeatureState(sourceID, sourceLayerID, featureID, state) — include/mbgl/renderer/renderer.hpp:74; plumbed through render_orchestrator.cpp:725, render_tile_source.cpp:543, geometry_tile.cpp:582 | controller-namespace | yes |
| P2 | Expr arity — every builder takes up to 10 positional args | partial | true varargs | NSArray-based, unbounded | Varargs<T> — unbounded (compound_expression.cpp signatures) | value-type | no |
| P2 | Expr.accumulated + clusterProperties — reachability | partial | clusterProperties: {sum: ['+', ['get', 'scalerank']]} *(unverified)* | MLNShapeSourceOptionClusterProperties — MLNShapeSource.h:88; NSExpression.featureAccumulatedVariableExpression ($featureAccumulated) — NSExpression+MLNAdditions.h:101 | GeoJSONOptions::clusterProperties (ClusterProperties = map<string, pair<Expression,Expression>>) — include/mbgl/style/sources/geojson_source.hpp:32-36; parsed at src/mbgl/style/conversion/geojson_options.cpp:114-175; consumed at src/mbgl/style/sources/geojson_source_impl.cpp:112 | value-type | no |
| P2 | Expr.elevation — reachability | present | ["elevation"] in color-relief-color *(unverified)* | MLNColorReliefStyleLayer.h exists in the 6.27.0 headers, so Apple ships the consuming layer | elevationCompoundExpression — src/mbgl/style/expression/compound_expression.cpp:372-390, registered at :1030; consumer layer at include/mbgl/style/layers/color_relief_layer.hpp; factory compiled in CORE_ONLY (src/mbgl/layermanager/color_relief_layer_factory.cpp:9) | value-type | no |
| P2 | Runtime `getFilter` | none | map.getFilter(layerId: string): void \| FilterSpecification | `MLNVectorStyleLayer.predicate` getter (MLNVectorStyleLayer.h:54) + -mgl_jsonExpressionObject (NSPredicate+MLNAdditions.h:40) | mbgl::style::Layer::getFilter() — include/mbgl/style/layer.hpp:126; Filter::serialize() → mbgl::Value at include/mbgl/style/filter.hpp:45 | controller | yes |
| P2 | Runtime getPaintProperty / getLayoutProperty | none | map.getPaintProperty(layerId, name) / map.getLayoutProperty(layerId, name) | the same typed NSExpression properties, read (MLNCircleStyleLayer.h:175) | virtual StyleProperty Layer::getProperty(const std::string&) const — include/mbgl/style/layer.hpp:140; StyleProperty carries a Value + a Kind{Undefined,Constant,Expression,Transition} at include/mbgl/style/style_property.hpp:11-30 | controller | yes |
| P2 | Runtime per-property transition (set) | none | map.setPaintProperty(layerId, 'circle-color-transition', {duration, delay}) *(unverified)* | layer.circleColorTransition = MLNTransitionMake(0.3, 0) — MLNCircleStyleLayer.h:201 + MLNTypes.h:121 | Layer::setProperty("circle-color-transition", …) — the name is in the per-layer property table (src/mbgl/style/layers/circle_layer.cpp:432) and routes through setPropertyInternal | controller | no |
| P2 | `generateId` on a geojson source (auto-assign feature ids) | present | source spec key `generateId`, honoured by gl-js | — | **NOT IN CORE.** `grep -rn 'generateId' src/mbgl` returns nothing; geojson_options.cpp:14-175 never reads it. | reject | no |
| P2 | getFeatureState | none | map.getFeatureState(feature: FeatureIdentifier): any | — | mbgl::Renderer::getFeatureState(FeatureState& out, sourceID, sourceLayerID, featureID) const — include/mbgl/renderer/renderer.hpp:79 | controller-namespace | yes |
| P2 | getLayer / layer exists / getLayersOrder | none | map.getLayer(id: string): StyleLayer; map.getLayersOrder(): string[] | -[MLNStyle layerWithIdentifier:] (MLNStyle.h:166); MLNStyle.layers (NSArray, ordered) at MLNStyle.h:157 | Style::getLayer(const std::string&) — include/mbgl/style/style.hpp:68; Style::getLayers() returns the ORDERED std::vector<Layer*> — include/mbgl/style/style.hpp:65; Layer::serialize() → Value at include/mbgl/style/layer.hpp:141 | controller | yes |
| P2 | moveLayer | none | map.moveLayer(id: string, beforeId?: string): this | -[MLNStyle insertLayer:belowLayer:] (MLNStyle.h:218) / -insertLayer:aboveLayer: (:234) / -insertLayer:atIndex: (:202) after -removeLayer: (:242) | **NOT IN CORE as a single operation.** mbgl::style::Style exposes only addLayer(layer, beforeLayerID) and removeLayer(id) — include/mbgl/style/style.hpp:71-72. A move is remove-then-reinsert, and removeLayer returns the unique_ptr so nothing is lost. | controller | yes |
| P2 | queryRenderedFeatures — `filter` option | none | queryRenderedFeatures(geometry?, {layers?, filter?, availableImages?, validate?}) | -[MLNMapView visibleFeaturesInRect:inStyleLayersWithIdentifiers:predicate:] (MLNMapView.h:2253) and …AtPoint:…predicate: (MLNMapView.h:2157) | mbgl::RenderedQueryOptions{layerIDs, filter} — include/mbgl/renderer/query.hpp:16-24. The filter field EXISTS and we pass std::nullopt. | controller | yes |
| P2 | queryRenderedFeatures — point and geometry overloads | none | queryRenderedFeatures(pointOrBox?, options?) — PointLike, or [PointLike, PointLike] | -[MLNMapView visibleFeaturesAtPoint:inStyleLayersWithIdentifiers:predicate:] — MLNMapView.h:2157 | three overloads: ScreenCoordinate (point), ScreenLineString (polyline/polygon), ScreenBox — include/mbgl/renderer/renderer.hpp:57-60. Only ScreenBox is bound. | controller | no |
| P2 | querySourceFeatures | none | map.querySourceFeatures(sourceId: string, options?: {sourceLayer?, filter?, validate?}): GeoJSONFeature[] | -[MLNShapeSource featuresMatchingPredicate:] (MLNShapeSource.h:392); -[MLNVectorTileSource featuresInSourceLayersWithIdentifiers:predicate:] (MLNVectorTileSource.h:200) | mbgl::Renderer::querySourceFeatures(sourceID, SourceQueryOptions{sourceLayers, filter}) — include/mbgl/renderer/renderer.hpp:61, options at include/mbgl/renderer/query.hpp:30-39 | controller | yes |
| P2 | removeFeatureState (whole source / source-layer) | none | map.removeFeatureState({source, sourceLayer}) — same method, id omitted | — | include/mbgl/renderer/renderer.hpp:84 — featureID is std::optional<std::string>, so std::nullopt clears the whole source | controller-namespace | no |
| P2 | setLayerZoomRange (minzoom / maxzoom) | partial | map.setLayerZoomRange(layerId: string, minzoom: number, maxzoom: number): this | MLNStyleLayer.minimumZoomLevel / .maximumZoomLevel (float, readwrite) — MLNStyleLayer.h:58,64 | Layer::setMinZoom(float) / setMaxZoom(float) — include/mbgl/style/layer.hpp:134-135; also via setProperty("minzoom"/"maxzoom") — src/mbgl/style/layer.cpp:172-180 | controller | no |
| P3 | Construction-time layer `filter` | present | the `filter` key of an AddLayerObject passed to map.addLayer({...}) | set `predicate` before -[MLNStyle addLayer:] (MLNStyle.h:183) | convertJSON<std::unique_ptr<Layer>> handles `filter` — used at packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1576 | widget-prop | no |
| P3 | Expr builder coverage vs the spec (all 84 operators) | present | the same 84 operators (plus newer ones gl-js has and our pinned spec does not — see the global-state/split/join rows) | NSExpression bridge: +expressionWithMLNJSONObject: (NSExpression+MLNAdditions.h:228) plus convenience constructors mgl_expressionForConditional/Stepping/Interpolating/Matching (:124,:145,:165,:180) | parser registry at src/mbgl/style/expression/parsing_context.cpp:107-144 (36 structural ops) + compound registry at src/mbgl/style/expression/compound_expression.cpp:1019-1099 | value-type | no |
| P3 | Expr naming adaptations for Dart reserved words / collisions | present | the raw spec operator strings | NSExpression's own function names (a total re-skin: 'mgl_stepWithMinimum:stops:') | n/a | value-type | no |
| P3 | Expr.collator / Expr.resolvedLocale / Expr.numberFormat / Expr.isSupportedScript — reachability | present | same operators | NSExpression bridge; -mgl_expressionLocalizedIntoLocale: — NSExpression+MLNAdditions.h:261 | CollatorExpression::parse (parsing_context.cpp:122), NumberFormat::parse (:132), resolvedLocaleCompoundExpression (compound_expression.cpp:720), isSupportedScriptCompoundExpression (registry :1065) | value-type | no |
| P3 | Expr.heatmapDensity — reachability | present | ["heatmap-density"] in heatmap-color *(unverified)* | NSExpression.heatmapDensityVariableExpression — NSExpression+MLNAdditions.h:71 | heatmapDensityCompoundExpression — compound_expression.cpp:359-368 | value-type | no |
| P3 | Expr.image — reachability | present | ["image", "icon-id"] *(unverified)* | MLNAttributedExpression (MLNAttributedExpression.h:35) for the format/image family | ImageExpression::parse — parsing_context.cpp:125 | value-type | no |
| P3 | Expr.lineProgress — reachability | present | ["line-progress"] in line-gradient *(unverified)* | NSExpression.lineProgressVariableExpression ($lineProgress) — NSExpression+MLNAdditions.h:79 | lineProgressCompoundExpression — compound_expression.cpp:393-401; errors out unless params.colorRampParameter is set (i.e. unless evaluated as a colour ramp) | value-type | no |
| P3 | Expr.within / Expr.distance — reachability | present | ["within", geojson] / ["distance", geojson] | NSPredicate/NSExpression via the JSON bridge | Within::parse (parsing_context.cpp:142, impl src/mbgl/style/expression/within.cpp), Distance::parse (:123, impl src/mbgl/style/expression/distance.cpp) | value-type | no |
| P3 | Legacy (deprecated) filter syntax — ["!in", k, …], ["!has", k], ["none", …] | partial | legacy filter arrays accepted by setFilter/addLayer *(unverified)* | NSPredicate covers both forms transparently | src/mbgl/style/conversion/filter.cpp:56-72 and :227-242 convert `has`, `!has`, `in`, `!in`, `none`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `any`, `all`, `within`; the legacy ops become filter-* compound expressions registered at compound_expression.cpp:1072-1099 | reject | no |
| P3 | Legacy zoom / property / zoom-and-property functions ({stops: [...]}) | none | the legacy `{property, stops, base, type}` function form, still accepted *(unverified)* | MLNStyleFunction / MLNCameraStyleFunction / MLNSourceStyleFunction — all marked __attribute__((unavailable("Use NSExpression instead."))) at MLNStyleValue.h:41-62 | include/mbgl/style/conversion/function.hpp — mbgl still converts them | reject | no |
| P3 | Per-property transition at layer construction (`*-transition`) | present | the `paint` object's `"circle-color-transition": {duration, delay}` key in an AddLayerObject *(unverified)* | MLNCircleStyleLayer.circleColorTransition (MLNTransition) — MLNCircleStyleLayer.h:201, one per transitionable paint property | CircleLayer::setCircleColorTransition(const TransitionOptions&) — src/mbgl/style/layers/circle_layer.cpp:129; the generic name mapping 'circle-color-transition' → Property::CircleColorTransition at circle_layer.cpp:432 | widget-prop | no |
| P3 | Runtime per-property transition (get) | none | map.getPaintProperty(layerId, 'circle-color-transition') *(unverified)* | the same MLNTransition property, read — MLNCircleStyleLayer.h:201 | Layer::getProperty("circle-color-transition") returns StyleProperty with Kind::Transition — include/mbgl/style/style_property.hpp:17 | controller | no |
| P3 | Source/layer attribution on a queried feature (`feature.source`, `.sourceLayer`, `.layer`, `.state`) | none | MapGeoJSONFeature carries source, sourceLayer, layer and state | — (visibleFeaturesInRect: returns a flat NSArray<id<MLNFeature>> with no attribution — MLNMapView.h:2253) | **NOT IN CORE.** RenderOrchestrator builds `resultsByLayer` keyed by layer id and then explicitly flattens it into one std::vector<Feature> — src/mbgl/renderer/render_orchestrator.cpp:668-674. The public mbgl::Feature type has no source/layer field. | reject | no |
| P3 | Style-wide transition options (duration / delay / placement fade) | present | — (no runtime setter; `transition` is a style-document key and `fadeDuration` is an init-only MapOptions field) | MLNStyle.transition (MLNTransition) — MLNStyle.h:98; MLNStyle.performsPlacementTransitions (BOOL) — MLNStyle.h:105; MLNTransition struct at MLNTypes.h:94-104, MLNTransitionMake at :121 | Style::setTransitionOptions(const TransitionOptions&) — include/mbgl/style/style.hpp:41; struct at include/mbgl/style/transition_options.hpp:12-23 | controller | no |
| P3 | `feature-state` inside a layer `filter` | none | — (gl-js rejects feature-state in filters at validation time) *(unverified)* | — | no explicit rejection in src/mbgl/style/conversion/filter.cpp; the Filter evaluation context (include/mbgl/style/filter.hpp:33 operator()) is built without a FeatureState, so it evaluates to null rather than erroring | reject | no |
| P3 | `global-state` expression + setGlobalStateProperty | none | map.setGlobalStateProperty(key: string, value: any): this; map.getGlobalState(): Record<string, any>; ["global-state", key] | — | **NOT IN CORE.** Absent from both registries (parsing_context.cpp:107-144, compound_expression.cpp:1019-1099) and from the pinned scripts/style-spec-reference/v8.json (84 names, no global-state). The LIVE style-spec docs DO list it, so this is our pinned submodule (core-fa8a9c8e, 2026-06-11) being behind the spec. | reject | no |
| P3 | `sky-radial-progress`, `measure-light`, `distance-from-center`, `config`, `pitch` expressions | none | — (I could not confirm any of these five in the MapLibre gl-js/style-spec docs; `measure-light`, `distance-from-center`, `config` and `pitch` are Mapbox GL JS v3 operators, not MapLibre) | — | NOT IN CORE (absent from both registries) | reject | no |
| P3 | `split` / `join` string expressions | none | ["split", input, separator] / ["join", array, separator] | — | **NOT IN CORE.** Absent from the pinned v8.json and from both mbgl registries. Present in the live MapLibre style-spec docs. | reject | no |
| P3 | getStyle (whole style document as JSON) | none | map.getStyle(): StyleSpecification | MLNStyle.styleJSON (NSString, readwrite) — MLNStyle.h:85 | mbgl::style::Style::getJSON() const — include/mbgl/style/style.hpp:32 | controller | yes |
| P3 | gl-js StyleSetterOptions.validate on setters | none | setFilter/setPaintProperty/setLayoutProperty all take options?: StyleSetterOptions with a `validate` boolean | — (no analogue) | **NOT IN CORE.** Validation is unconditional inside convertJSON<T> and Layer::setProperty (src/mbgl/style/layer.cpp:166); there is no skip path. | reject | no |
| P3 | gl-js `fadeDuration` map option | none | new Map({fadeDuration: 300}) — init-only MapOptions field *(unverified)* | — (Apple exposes it only as the mutable MLNStyle.transition, MLNStyle.h:98) | TransitionOptions is style-scoped, settable at any time — include/mbgl/style/style.hpp:41 | reject | no |

#### Proposed signatures

**Feature `id` surfaced from queryRenderedFeatures** — P0, `value-type`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:15-35 (MapLibreQueriedFeature has only `point` and `properties`) and :210-231 (the parser reads `geometry` and `properties`, and DROPS the top-level `id`)
```dart
final Object? id; // on MapLibreQueriedFeature, alongside point/properties
```
> **Matrix drift:** `queryRenderedFeatures` — 🧪/macOS ✅, note says 'Rect only (no point/geometry overload), no filter argument' (FEATURE_MATRIX.md:520). The matrix does NOT mention that the id is dropped. DISAGREEMENT: the matrix reads as a complete ✅ for the feature it covers; it is not.

**WEB COLUMN of FEATURE_MATRIX §3 (all rows)** — P0, `reject`, evidence: packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:49 (`implements … MapLibreStyleLayers`) with real implementations at :264 (addSourceJson), :273 (addLayerJson), :279 (setGeoJsonData), :286/:292 (removeLayer/removeSource), :298 (addImage), :313 (removeImage), :317 (setTransitionOptions), :332 (queryRenderedFeaturesJson); embind surface at packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:1016-1024
```dart
— (no API change; this is a matrix correction)
```
> **Flagged p0 because it is the largest single trust problem with the matrix**, and the maintainer explicitly asked how much to trust it. Everything in this domain that is 🧪 on the five native tiers is equally wired on web-WASM, because it is one engine behind one Dart contract — which is the matrix's own stated reading rule (FEATURE_MATRIX.md:20-22), just not applied to the web column. The honest markings would be 🧪 for the expression/filter/transition rows and ❌ for the genuinely-unbound ones (feature-state, runtime setters), identical to the native columns. Whoever fixes §3 should re-run the same check on §1, §2 and §7, where the same 'web has nothing' assumption looks to be baked in.

**Cluster expansion / children / leaves (queryFeatureExtensions)** — P1, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:196-238 (queryRenderedFeatures surfaces `point_count` and `cluster_id` in properties, but there is no way to act on cluster_id)
```dart
Future<double> MapLibreLayersController.getClusterExpansionZoom(String sourceId, int clusterId); Future<List<MapLibreQueriedFeature>> getClusterChildren(String sourceId, int clusterId); Future<List<MapLibreQueriedFeature>> getClusterLeaves(String sourceId, int clusterId, {int limit = 10, int offset = 0})
```
> Belongs in this domain because it is the only way to consume the `cluster_id` that our own queryRenderedFeatures already hands back, and the pairing with `accumulated`/clusterProperties is what makes cluster-property expressions useful. 'Tap a cluster → zoom to where it splits' is the single most-requested clustering interaction and today it is unimplementable. One C entry point with an `extension`/`extensionField` pair mirrors mbgl exactly: `char* mbl_map_query_feature_extensions(MblMap*, const char* source_id, const char* feature_json, const char* extension, const char* field, const char* args_json, uint32_t timeout_ms)`. gl-js's param order (clusterId, limit, offset) vs Apple's (offset, limit) disagree — **I took gl-js's names as Dart named params so order stops mattering.**

**MapLibreFeatureRef — the gl-js FeatureIdentifier value type** — P1, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/lat_lng.dart:1 (sibling value type; new file feature_state.dart)
```dart
final class MapLibreFeatureRef { const MapLibreFeatureRef({required String source, required Object id, String? sourceLayer}); }
```
> `id` is `Object` (int or String) to mirror gl-js, but the C ABI takes a `const char*` because mbgl's featureID is a std::string (renderer.hpp:76) — so the Dart layer must stringify with `id.toString()`, and an int id 42 and a String id '42' address the SAME feature. Document that. `sourceLayer` is required in practice for vector sources and must be null for geojson (gl-js documents the same conditional requirement).

**Runtime `setFilter` on an existing layer** — P1, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:100-119 (only addLayerJson / removeLayer / removeSource; no per-layer mutation exists)
```dart
void MapLibreLayersController.setFilter(String layerId, Expression? filter)
```
> Table stakes — every competing plugin has it, and today the only way to change a filter is removeLayer + addLayer, which drops symbol placement state and re-triggers the 300 ms fade. `null` clears the filter, matching gl-js. Implementable with ONE generic C entry point that also covers setPaintProperty/setLayoutProperty/setLayerZoomRange/visibility, because mbgl's Layer::setProperty already dispatches on the name (layer.cpp:165-200 handles 'filter', 'visibility', 'minzoom', 'maxzoom', 'source-layer', 'source' after delegating to the derived setPropertyInternal). See the setPaintProperty row for the proposed shim.

**Runtime layer visibility toggle** — P1, `controller`, evidence: construction-time `visibility` is a generated layout field (packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart); no runtime toggle
```dart
void MapLibreLayersController.setLayerVisible(String layerId, bool visible)
```
> gl-js has no dedicated name for this, both SDKs do (Apple's `visible` BOOL, Android's PropertyFactory.visibility). **I took the SDK shape** — a bool is far more Dartlike than the magic strings 'none'/'visible', and it is the single most common runtime style mutation in real apps (layer toggles in a legend). Sugar over setLayoutProperty, which stays public for anyone who wants the spec spelling.

**Runtime setLayoutProperty** — P1, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:100-119
```dart
void MapLibreLayersController.setLayoutProperty(String layerId, String name, Object? value)
```
> Same shim entry point as setPaintProperty — mbgl does not distinguish, and neither does Android. **Kept as two Dart methods anyway** because gl-js does and because it documents intent (a layout change re-runs layout and is expensive; a paint change does not). Note the sharp edge worth a dartdoc line: `feature-state` is legal only in paint properties, so `setLayoutProperty(id, 'text-field', Expr.featureState('label'))` will be rejected by mbgl's is_constant check (is_constant.cpp:19).

**Runtime setPaintProperty** — P1, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:100-119 (add/remove only); C ABI has no per-layer property setter — packages/maplibre_flutter_core/src/maplibre_flutter_core.h:181-229
```dart
void MapLibreLayersController.setPaintProperty(String layerId, String name, Object? value)
```
> **One C entry point should back this, setLayoutProperty, setFilter, setLayerZoomRange, layer visibility AND per-property transitions**, because mbgl's Layer::setProperty already routes all of them by name (layer.cpp:165-200). Proposal: `int mbl_map_set_layer_property(MblMap*, const char* layer_id, const char* name, const char* value_json, char* err, uint32_t err_len)`. Implementation note that matters: Convertible holds a pointer INTO the rapidjson document, so the shim must parse into a `std::shared_ptr<JSDocument>` captured by the posted lambda and build `Convertible(&*doc)` on the render thread (rapidjson_conversion.hpp) — it cannot use convertJSON<T>, which owns its document on the stack. Unlike addLayerJson, the conversion error is only discoverable on the render thread (the layer must exist), so it gets LOGGED, which is the convention the header already documents at maplibre_flutter_core.h:177-179. `Object? value` accepts a Dart literal, a StyleValue, or an Expression — encoded through the existing encodeStyleJson.

**`feature-state` expression — reachability of the generated Expr.featureState builder** — P1, `capability-interface`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:882 (Expr.featureState is generated and public; nothing in the runtime can ever populate the state it reads)
```dart
Expr.featureState('hover') — already exists; unblocked by MapLibreFeatureStateController.set
```
> This is the answer to the brief's 'determine exactly which generated builders are unreachable today': **Expr.featureState is the single builder that is structurally dead.** It parses fine in mbgl and evaluates to null forever, because params.featureState is always nullptr with no setFeatureState binding (expression.hpp:95). Two further ceilings worth documenting on the builder: (1) it only affects **data-driven PAINT** properties — paint_property_binder.hpp:338 `updateVertexVector` re-evaluates and re-uploads a vertex attribute, it does not re-run layout, so layout properties and filters are untouched; (2) it works only on **tile sources** (vector + geojson): RenderTileSource implements it (render_tile_source.cpp:543) while the RenderSource base is an empty no-op (render_source.hpp:98), so image/video/raster sources silently ignore it.

**`promoteId` on a source (feature ids from an arbitrary property)** — P1, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart:84 (VectorSource.promoteId) and :457 (GeoJsonSource.promoteId) — both serialized at :107 and :474ff
```dart
@Deprecated-style doc warning on GeoJsonSource.promoteId / VectorSource.promoteId — no signature change
```
> The typed API is generated from the SPEC, and the spec is ahead of the engine here. Because the generator is spec-driven and must never be hand-edited, the fix is either (a) a curated 'unsupported by the pinned core' set in tool/generate_style_api.dart that emits a dartdoc `⚠ ignored by mbgl-core` banner, or (b) a doc table in docs/typed-style-api.md. I'd take (a) — it survives regeneration and it is exactly the class of silent-lie the CLAUDE.md §11 'verify the convention, don't infer it' rule exists to catch. Practical consequence for this domain: **feature-state on a geojson source only works if your GeoJSON features carry a real top-level integer `id`** — there is no promoteId fallback.

**removeFeatureState (one key on one feature)** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:24 (new feature_state.dart)
```dart
void MapLibreFeatureStateController.remove(MapLibreFeatureRef feature, {String? key})
```
> Ships with `set` — a hover effect that can only add state is useless. One C entry point covers both this and `clear` below because mbgl's optionals do: `void mbl_map_remove_feature_state(MblMap*, const char* source_id, const char* source_layer /*nullable*/, const char* feature_id /*nullable*/, const char* state_key /*nullable*/)`. NULL feature_id = clear the whole source/source-layer; NULL state_key = clear all keys on that feature.

**setFeatureState** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:24 (would live in a new sibling capability interface, feature_state.dart)
```dart
void MapLibreFeatureStateController.set(MapLibreFeatureRef feature, Map<String, Object?> state)
```
> The single highest-value binding in this domain: it is the ONLY way to make Expr.featureState (already public, already generated) do anything, and hover/selection effects are the canonical demo. New entry point: `int mbl_map_set_feature_state(MblMap*, const char* source_id, const char* source_layer /*nullable*/, const char* feature_id, const char* state_json, char* err, uint32_t err_len)`. Follow the mbl_map_add_layer_json pattern (maplibre_flutter_core.cpp:1569): parse the state JSON synchronously on the calling thread so malformed JSON returns 0 with a message, then post the mutation. Renderer lives on the frontend (`m->frontend->getRenderer()`, already used at maplibre_flutter_core.cpp:1738), so it must be posted to the render thread. FeatureState is mapbox::base::ValueObject (include/mbgl/util/feature.hpp:16) — a flat string→primitive map, so `Map<String, Object?>` is the exact Dart shape.

**Expr arity — every builder takes up to 10 positional args** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:20-23 (the doc admits it) and the a0..a9 pattern on every builder; sentinel `_unset` at :1771, truncation at :1777
```dart
static Expression step(Object input, Object output0, [List<Object?> stops = const []]) — or keep a0..a9 and add Expr.rawOp(String op, List<Object?> args)
```
> **A real usability cliff hiding behind a 🧪.** A `step` with six stops or a `match` with a dozen cases exceeds 10 args and silently forces the caller to Expr.raw, losing every bit of typing. Our own addPoints helper already sits at 6 args (map_layers_controller.dart:299-306) — one more tier and it breaks. Options, in preference order: (1) generator emits `[List<Object?> more = const []]` as an 11th spread parameter for the varargs operators the spec marks as such; (2) add `Expr.op(String name, List<Object?> args)` next to Expr.raw so the operator name is at least not hand-typed. Either is a generator change, not a hand edit.

**Expr.accumulated + clusterProperties — reachability** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:1013 (Expr.accumulated); packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart:438 (GeoJsonSource.clusterProperties, typed as `Object?`)
```dart
final Map<String, Object?>? clusterProperties; // instead of Object? — plus a MapLibreLayersController.addPoints(clusterProperties:) passthrough
```
> Fully reachable in the engine — this is the ONE mbgl-supported route to aggregate values across a cluster, and it is the only consumer of Expr.accumulated. Two ergonomic gaps: (1) `clusterProperties` is typed `Object?` because the spec types it `*`, so there is no help constructing the `{name: [operator, mapExpression]}` shape — a generator special-case or a hand-written `ClusterProperty` value type in the non-generated style/ directory would pay for itself; (2) our own addPoints convenience (map_layers_controller.dart:258) does not forward clusterProperties, so the built-in clustering path cannot aggregate anything. Both are pure Dart.

**Expr.elevation — reachability** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:976 (builder exists); ColorReliefLayer with colorReliefColor at packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:2287,2367 — so the layer that consumes it is generated too
```dart
— (Expr.elevation already works; needs a raster-dem source + ColorReliefLayer to be reachable)
```
> **The single worst piece of matrix drift in this domain** — it tells the maintainer an engine capability is impossible when it is already generated and only needs a demo. Reachability preconditions to document: a `raster-dem` source (generated as RasterDemSource) and a ColorReliefLayer whose `color-relief-color` is an interpolate over Expr.elevation(). The second path in mbgl (params.elevation for 3D terrain, compound_expression.cpp:380-383) is NOT reachable — mbgl's style parser has no `terrain` key (`grep terrain src/mbgl/style/parser.cpp` → nothing), so terrain-driven elevation is a genuine ➖.

**Runtime `getFilter`** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:100-119
```dart
Future<Expression?> MapLibreLayersController.getFilter(String layerId)
```
> Async for the same thread-affinity reason as getFeatureState. Serialize with src/mbgl/style/conversion/stringify.hpp (reachable — the shim already has MLN_ROOT/src on its include path, src/CMakeLists.txt:655), return a JSON string, decode to `Expression(jsonDecode(s) as List)` in Dart. Lower priority than setFilter: apps that set filters generally hold the Dart Expression they set.

**Runtime getPaintProperty / getLayoutProperty** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:100-119
```dart
Future<Object?> MapLibreLayersController.getPaintProperty(String layerId, String name); Future<Object?> getLayoutProperty(String layerId, String name)
```
> `char* mbl_map_get_layer_property(MblMap*, const char* layer_id, const char* name, uint32_t timeout_ms)` returning JSON, freed by mbl_string_free. StyleProperty::Kind is genuinely useful and no other binding surfaces it — consider returning `{"kind":"expression","value":[…]}` so Dart can distinguish a constant from an expression from an unset property, which gl-js cannot do.

**Runtime per-property transition (set)** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:172-180 (only the style-wide setter exists)
```dart
void MapLibreLayersController.setPaintPropertyTransition(String layerId, String property, StyleTransition transition)
```
> **Matrix drift:** folded into 'Property transitions … 🧪' (FEATURE_MATRIX.md:279). **DISAGREEMENT**: the 🧪 covers only construction-time; the runtime setter does not exist and the matrix does not say so.

**`generateId` on a geojson source (auto-assign feature ids)** — P2, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart:451 (GeoJsonSource.generateId), serialized at :477
```dart
doc warning on GeoJsonSource.generateId — no signature change
```
> The second half of the feature-state prerequisite gap. gl-js users reach for `generateId: true` when their data has no ids; that escape hatch does not exist on our engine. Combined with the promoteId gap, the ONLY way to key feature state on the native/WASM tiers is a real integer `id` member on each GeoJSON feature — which our own GeoJsonData.points() helper does not emit either (packages/maplibre_flutter/lib/src/style/geojson_data.dart). If setFeatureState lands, GeoJsonData will need an id-carrying constructor.

**getFeatureState** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:24 (new feature_state.dart)
```dart
Future<Map<String, Object?>> MapLibreFeatureStateController.get(MapLibreFeatureRef feature)
```
> Must be async in Dart even though gl-js is sync: mbgl's Renderer is thread-affine, so this needs the post-and-wait-with-deadline pattern already used by mbl_map_query_rendered_features (maplibre_flutter_core.cpp:1735-1775). Signature: `char* mbl_map_get_feature_state(MblMap*, const char* source_id, const char* source_layer, const char* feature_id, uint32_t timeout_ms)` returning a JSON object string freed with mbl_string_free. Lower priority than set/remove — apps overwhelmingly write state and read it back from their own Dart model.

**getLayer / layer exists / getLayersOrder** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:100-119
```dart
Future<List<String>> MapLibreLayersController.getLayersOrder(); Future<Map<String, Object?>?> getLayer(String id)
```
> In this domain because it is the prerequisite for safely using setPaintProperty/setFilter against a basemap you did not author — you have to know the layer ids the style actually shipped. Layer::serialize() gives the whole layer document including its filter, so `getLayer` subsumes `getFilter` if the payload is decoded in Dart. Consider binding getLayer as `Layer::serialize()` and building getFilter/getPaintProperty on top of a Dart-side decode rather than three C entry points.

**moveLayer** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:110 (addLayerJson takes beforeId at insert time only)
```dart
void MapLibreLayersController.moveLayer(String id, {String? beforeId})
```
> gl-js name, native implementation. Worth a C entry point rather than Dart-side remove+re-add, because the remove and the add must land in the SAME render-thread post or a frame can render with the layer missing. `void mbl_map_move_layer(MblMap*, const char* id, const char* before_id /*nullable*/)`. Ceiling note: mbgl's Layer keeps its paint/layout state across remove+add (removeLayer hands back the owning unique_ptr), so unlike a naive Dart workaround this is genuinely lossless — including symbol placement, which is why doing it in the engine matters.

**queryRenderedFeatures — `filter` option** — P2, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78-84 (queryRenderedFeaturesJson takes only a rect + layerIds); C ABI at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:246-248; call site passes `mbgl::RenderedQueryOptions(layers)` with no filter at maplibre_flutter_core.cpp:1748
```dart
List<MapLibreQueriedFeature> MapLibreLayersController.queryRenderedFeatures(Rect rect, {List<String>? layerIds, Expression? filter})
```
> All three canonical APIs take a filter; we are the outlier. Cheap: add `const char* filter_json` to mbl_map_query_rendered_features, parse it with convertJSON<Filter> synchronously (so a bad filter reports immediately, matching the header's documented convention at maplibre_flutter_core.h:174-179), and pass RenderedQueryOptions(layers, filter). Note the existing `layer_ids` transport is comma-joined in Dart (packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:770) — a layer id containing a comma silently splits into two. Worth fixing in the same change (length-prefixed array or NUL-separated).

**queryRenderedFeatures — point and geometry overloads** — P2, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78 (rect only)
```dart
List<MapLibreQueriedFeature> MapLibreLayersController.queryRenderedFeaturesAt(Offset point, {double tolerance = 4, List<String>? layerIds, Expression? filter})
```
> Deliberately NOT a new C entry point: a point query is a rect query inflated by a tap tolerance, which is what every touch UI wants anyway (mbgl's ScreenCoordinate overload does no tolerance inflation of its own, so a bare point misses on a finger tap). Pure Dart sugar over the existing rect call — hence needs_c_abi false and cheap. The ScreenLineString overload (arbitrary polygon) has no gl-js parallel worth chasing; leave it.

**querySourceFeatures** — P2, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78 (only the rendered query exists)
```dart
Future<List<MapLibreQueriedFeature>> MapLibreLayersController.querySourceFeatures(String sourceId, {String? sourceLayer, Expression? filter})
```
> All four canonical APIs have it and we have none. Distinct from the rendered query: it returns loaded-but-not-necessarily-drawn features, which is what you want for 'select all restaurants in the loaded tiles'. Same post-and-wait shim shape as queryRenderedFeatures, same GeoJSON FeatureCollection transport, so the Dart parser is shared.

**removeFeatureState (whole source / source-layer)** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:24 (new feature_state.dart)
```dart
void MapLibreFeatureStateController.clear(String source, {String? sourceLayer})
```
> Reuses the mbl_map_remove_feature_state entry point above with a NULL feature_id, so no extra C ABI. Split out from `remove` deliberately (see naming note 2): gl-js gets away with an optional `id` because JS is untyped; in Dart a nullable id would poison `set`/`get`.

**setLayerZoomRange (minzoom / maxzoom)** — P2, `controller`, evidence: construction-time only: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart (minzoom/maxzoom are generated fields); no runtime setter in packages/maplibre_flutter/lib/src/map_layers_controller.dart
```dart
void MapLibreLayersController.setLayerZoomRange(String layerId, double minZoom, double maxZoom)
```
> Free once mbl_map_set_layer_property exists — two setProperty calls. Kept as its own gl-js-named method because the paired semantics matter (setting only one leaves an inconsistent range).

**Construction-time layer `filter`** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:31/91/207 (filter is `Expression?` on every vector layer type and serializes into the layer document); used in anger at packages/maplibre_flutter/lib/src/map_layers_controller.dart:296 (`Expr.has('point_count')`) and :337 (`Expr.not(Expr.has('point_count'))`)
```dart
— (already correct; no change)
```
> Verified working on macOS via the clustering demo. This is the row that makes the whole domain look healthier than it is: constructing a filter works, mutating one does not.

**Expr builder coverage vs the spec (all 84 operators)** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart — 84 builders (verified: `grep -c 'static Expression '` matches the 84 names in scripts/style-spec-reference/v8.json `expression_name.values`), plus Expr.raw at :27
```dart
— (already correct; coverage is spec-discovered, per CLAUDE.md §5d)
```
> Cross-check done operator-by-operator: every one of the spec's 84 names resolves in mbgl's parser or compound registry. mbgl additionally accepts `to-padding` (parsing_context.cpp:138) and `error` (compound_expression.cpp:1068) which are NOT in `expression_name`, so we generate no builder for them — correct, and Expr.raw covers them.

**Expr naming adaptations for Dart reserved words / collisions** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:55 (`var` → Expr.variable), :191 (`case` → Expr.caseOf), :129 (`in` → Expr.isIn), :419 (`typeof` → Expr.typeof), :649 (`to-string` → Expr.toStringOp), :1431 (`==` → Expr.equals), :1455 (`!=` → Expr.notEquals), :1610 (`!` → Expr.not), :1031 (`+` → Expr.sum), :1047 (`*` → Expr.product)
```dart
— (already correct; keep, and keep the generator throwing on new collisions)
```
> Documented here so the divergence from gl-js spelling is a recorded decision rather than an accident. **Android renames too** (`switchCase`, `eq`, `neq`), so 'copy upstream naming' has no single answer for operators that are Dart/Java keywords. Our names differ from Android's in three places (caseOf vs switchCase, equals vs eq, notEquals vs neq); I'd keep ours — `equals`/`notEquals` read better in Dart and match Dart's own `==` conventions — but the dartdoc should name the spec operator (it already does: 'The `case` expression').

**Expr.collator / Expr.resolvedLocale / Expr.numberFormat / Expr.isSupportedScript — reachability** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:516 (collator), :1748 (resolvedLocale), :618 (numberFormat), :1656 (isSupportedScript)
```dart
— (already works)
```
> Verified reachable on EVERY arm, which is not obvious: these need ICU. Apple uses NSLocale-backed .mm implementations (src/CMakeLists.txt:131-138); Linux/Windows/Android use platform/default/src/mbgl/i18n/{collator,number_format}.cpp with system ICU or the vendored builtin (src/CMakeLists.txt:273-274, 381-382, 437-444); the WASM arm force-defines MBGL_USE_BUILTIN_ICU (web/CMakeLists.txt:110). No stubs anywhere, so no builder in this family is dead.

**Expr.heatmapDensity — reachability** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:956; consumer `heatmapColor` is a generated HeatmapLayer field
```dart
— (already works)
```
> Reachable, only inside heatmap-color; mbgl returns an EvaluationError elsewhere (compound_expression.cpp:362-366). No binding needed.

**Expr.image — reachability** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:594; images registered via packages/maplibre_flutter/lib/src/map_layers_controller.dart:123 (addImage) and :387 (addWidgetIcon)
```dart
— (already works)
```
> Genuinely reachable end-to-end, and one of the nicer stories we have: addWidgetIcon rasterises a Flutter widget into a style image which Expr.image can then reference from a text-field. Worth a demo, not a binding.

**Expr.lineProgress — reachability** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:994; consumer `lineGradient` is a generated LineLayer field
```dart
— (already works)
```
> Reachable, with two preconditions the dartdoc should name: (1) usable ONLY in `line-gradient`, (2) the geojson source must set `lineMetrics: true` — which our GeoJsonSource does expose (style_sources.g.dart, `lineMetrics`) and which mbgl DOES honour (geojson_options.cpp:94), unlike promoteId/generateId. So this one is genuinely end-to-end.

**Expr.within / Expr.distance — reachability** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:1636 (within), :1397 (distance)
```dart
— (already works; the GeoJSON argument goes through Expr.raw-style literal encoding)
```
> Reachable. One usability note: both take a GeoJSON OBJECT, not an expression, and our builders take `Object?` positionals, so a caller passes a raw Dart Map. Our GeoJsonData helper (packages/maplibre_flutter/lib/src/style/geojson_data.dart) could gain a `.toJson()`-compatible polygon constructor so `Expr.within(GeoJsonData.polygon(ring))` reads properly.

**Legacy (deprecated) filter syntax — ["!in", k, …], ["!has", k], ["none", …]** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:27 (Expr.raw is the only route; the 84 generated builders come from spec `expression_name.values`, which contains no legacy operator)
```dart
— (Expr.raw(['!in', 'class', 'street']) is the documented route; no new builders)
```
> Do NOT generate builders for legacy operators: they are not in `expression_name` in the spec, so a hand-added builder would be a hand-edit of generated output (forbidden), and the generator would need an allowlist — exactly the 'discovered from the spec, never allowlisted' property CLAUDE.md §5d protects. Expr.raw is the right answer; just make sure the dartdoc names the legacy ops so they are greppable.

**Legacy zoom / property / zoom-and-property functions ({stops: [...]})** — P3, `reject`, evidence: the typed API models only expressions — packages/maplibre_flutter/lib/src/style/style_value.dart:37-45 (StyleValue is constant-or-Expression, with no function variant); reachable only by hand-writing the JSON through addLayerJson
```dart
— (rejected; use Expr.interpolate / Expr.step)
```
> **Recommend flipping these three matrix rows from ❌ to ➖-by-policy.** They are deprecated in every canonical implementation — Apple has literally marked the classes `unavailable` — and mbgl only keeps the converter for old style documents, which still load fine through addLayerJson/setStyle. Binding them would add three legacy shapes to a typed API whose entire selling point is that it is generated from the current spec. Leaving them as ❌ makes the parity backlog look 3 items worse than it is.

**Per-property transition at layer construction (`*-transition`)** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:1273 (CircleLayer.circleColorTransition), serialized to 'circle-color-transition' at :1450; type at packages/maplibre_flutter/lib/src/style/generated/style_transition.g.dart:16-36
```dart
— (already correct)
```
> Generated from the spec, so coverage is automatically complete across all ~180 transitionable properties. StyleTransition uses `double?` milliseconds (generated from the spec schema) while the hand-written setTransitionOptions uses `Duration` — an intentional asymmetry, since the generated file must not be hand-edited. Worth one dartdoc sentence so it does not read as an oversight.

**Runtime per-property transition (get)** — P3, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:172
```dart
Future<StyleTransition?> MapLibreLayersController.getPaintPropertyTransition(String layerId, String property)
```
> Free once getPaintProperty lands. StyleProperty::Kind::Transition is exactly the discriminator needed to decode it correctly, which is another argument for surfacing Kind in the getter's JSON payload.

**Source/layer attribution on a queried feature (`feature.source`, `.sourceLayer`, `.layer`, `.state`)** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:15-35
```dart
— (rejected; document 'query one layer at a time to know which layer matched')
```
> **Hard mbgl ceiling and a genuine gl-js-vs-native divergence.** gl-js can do it, both native SDKs cannot, and the loss happens inside mbgl's orchestrator, not at the binding. Do not fake a `layer` field. The documented workaround (issue one query per layer id) is exactly what the Apple SDK's own docs imply. Directly limits how ergonomic MapLibreFeatureRef construction from a hit-test can be: the caller must know which source they queried.

**Style-wide transition options (duration / delay / placement fade)** — P3, `controller`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:172-180; platform contract at packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:63-67; C ABI at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:227-229, impl at maplibre_flutter_core.cpp:1675, re-applied after every style load via onDidFinishLoadingStyle (maplibre_flutter_core.cpp:849, 890)
```dart
— (already correct; keep the Apple/Android shape)
```
> One of the few places we are AHEAD of gl-js. Two additions worth considering: (1) a `getTransitionOptions()` read to match Android's getTransition() (Style.java:681) — needs C ABI; (2) the sticky-across-style-load behaviour we implement is an invention of ours (neither SDK does it) and is genuinely better, but should be called out in the dartdoc as a deliberate divergence so nobody 'fixes' it. Also note mbgl ignores transition options in Static mode entirely — already documented at maplibre_flutter_core.h:225-226.

**`feature-state` inside a layer `filter`** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:91 (filter is Expression?, so Expr.featureState is type-assignable and will serialize)
```dart
— (documentation only, on Expr.featureState and on the generated `filter` field)
```
> Our type system cannot prevent it (Expression is assignable to `filter` by construction), and mbgl fails soft rather than loud, so a filter using feature-state silently matches nothing. Worth one sentence in the Expr.featureState dartdoc. Not worth API machinery.

**`global-state` expression + setGlobalStateProperty** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart — no builder emitted (correct: `global-state` is absent from the pinned spec's expression_name list)
```dart
— (rejected until the pinned core implements it)
```
> Hard stop for all five native tiers AND web-WASM (same engine). Note the second-order effect: because our generator is spec-driven and the spec is vendored inside the submodule, `global-state` will appear as a generated builder automatically the moment the submodule is bumped past the mbgl implementation — and the regen-diff CI check (currently disabled, CLAUDE.md §2) is what would surface it. Another argument for turning those triggers on.

**`sky-radial-progress`, `measure-light`, `distance-from-center`, `config`, `pitch` expressions** — P3, `reject`, evidence: not generated (absent from the pinned spec)
```dart
— (rejected)
```
> Listed so the backlog explicitly closes them out rather than leaving 'what about measure-light?' open. Four of the five are Mapbox GL JS v3, not MapLibre, and should never appear in a MapLibre parity matrix at all.

**`split` / `join` string expressions** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart — no builders (absent from the pinned spec)
```dart
— (rejected)
```
> Same pinned-spec-lag class as global-state. ➖ is the right marking today but the reason should read 'newer than the pinned core' rather than 'never', since it will self-resolve on a submodule bump.

**getStyle (whole style document as JSON)** — P3, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:32 (setStyle only, one direction)
```dart
Future<String> MapLibreMapController.getStyleJson()
```
> Included because it is the universal escape hatch for this whole domain: with no getFilter/getPaintProperty, getStyleJson lets an app read anything once. All four canonical implementations have it. Deliberately NOT the mirror of the widget's declarative `style` prop — the house rule says there is no public controller.setStyle, and this is a read, so it does not violate that.

**gl-js StyleSetterOptions.validate on setters** — P3, `reject`, evidence: n/a
```dart
— (rejected)
```
> gl-js exposes it because its JS validator is a measurable cost; mbgl's conversion IS the parse, so there is nothing to skip. Do not add a no-op parameter to three methods.

**gl-js `fadeDuration` map option** — P3, `reject`, evidence: packages/maplibre_flutter_platform_interface/lib/src/map_options.dart:1-28 (MapOptions has no transition/fade field)
```dart
— (rejected)
```
> Do NOT add an init-only MapOptions field. gl-js makes it init-only for its own reasons; the engine makes it mutable, both SDKs expose it as mutable, and we already have the mutable form. Adding an init-only twin would create two sources of truth for one engine value — precisely what the three-bucket rule is meant to prevent.


### Gestures & user interaction

#### Engine ceiling

**mbgl-core has no gesture layer at all — none of this domain is an engine limit, all of it is ours to write.** `mbgl::Map` exposes exactly four relative-camera primitives (`moveBy`, `scaleBy`, `pitchBy`, `rotateBy` — include/mbgl/map/map.hpp:76-79), the absolute setters (`jumpTo`/`easeTo`/`flyTo`, map.hpp:73-75), `cancelTransitions()` (map.hpp:64), the gesture flag `setGestureInProgress`/`isGestureInProgress`/`isRotating`/`isScaling`/`isPanning` (map.hpp:65-69), and `setBounds(BoundOptions)` (map.hpp:98) for min/max zoom, min/max pitch and a pan-constraining `LatLngBounds` (include/mbgl/map/bound_options.hpp:13-56). Recognition, thresholds, inertia, keyboard and cooperative gestures do not exist in the engine — the Apple SDK builds them from `UIGestureRecognizer`s and gl-js from DOM events. So there is **no mbgl ceiling on this domain**; the ceiling is our own Dart gesture layer.

**Genuine hard stops / traps that do bite:**

1. **No camera-change reason in the engine.** `MapObserver::onCameraWillChange(CameraChangeMode)` / `onCameraIsChanging()` / `onCameraDidChange(CameraChangeMode)` (include/mbgl/map/map_observer.hpp:54-56) carry only `Immediate` vs `Animated` (map_observer.hpp:37-40). The Apple bitmask is synthesised entirely in `MLNMapView.mm` from its own recognizers. **Consequence for us: the reason must be produced in the Dart gesture layer and must NOT be plumbed through the C ABI** — the C ABI physically cannot know it. This is a happy accident: our gesture layer is in Dart on all five native tiers, so we can produce a *more* faithful reason than the Apple SDK does, with zero ffigen churn. It also means the web-WASM tier, whose gestures live in C++ (`packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:199-205`), is the one tier that *does* need a new embind field to report it.

2. **Pitch is clamped to 60°** — `util::DEFAULT_PITCH_MAX = M_PI/3` (include/mbgl/util/constants.hpp:35). A `maxPitch` above 60 is silently ignored, so `MapGestureSettings`/`MapCameraConstraints` must document the clamp rather than pretend to honour it. (`PITCH_MAX = M_PI` exists at constants.hpp:36 but is not the default bound.)

3. **`Map::rotateBy` and `Map::pitchBy` are broken upstream and must never be used.** `Transform::rotateBy` computes a bogus `pow(2,x)+pow(2,y)`, and `Map::pitchBy` *subtracts* its argument. Our shim already routes both through `jumpTo` + `CameraOptions` instead (`packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1359-1420`). Any new gesture built on rotation/pitch must go through `mbl_map_rotate_by` / `mbl_map_pitch_by`, not a fresh binding to the mbgl methods.

4. **`Map::scaleBy` accepts an `AnimationOptions` (map.hpp:77) but our C ABI drops it** (`mbl_map_scale_by`, packages/maplibre_flutter_core/src/maplibre_flutter_core.h:80). Animated zoom-about-an-anchor — which is what double-tap zoom and quick-zoom-release need to feel right — therefore needs a C ABI change, not just Dart work. This is the single biggest ffigen-regen item in the domain.

5. **Roll is NOT a web-only feature.** `CameraOptions::roll` / `withRoll` exist in the engine (include/mbgl/map/camera.hpp:48-51, 83), and `Transform::easeTo` reads it (src/mbgl/map/transform.cpp:130). FEATURE_MATRIX.md:396 marks `rollEnabled` ➖ **web_only** on all five native columns — that is wrong at the engine level. It is unbound, not unavailable.

6. **`setGestureInProgress` is never called by our shim** (no hit anywhere in `maplibre_flutter_core.cpp`). mbgl uses it in two places: `Transform::easeTo` skips the flyTo re-route and changes longitude-wrap handling when a gesture is live (src/mbgl/map/transform.cpp:113, 141), and `TransformState::isChanging()` (src/mbgl/map/transform_state.cpp:732) selects the texture-filtering path for icons/text (src/mbgl/gfx/drawable_atlases_tweaker.cpp:42-43) and raster resampling (src/mbgl/renderer/layers/raster_layer_tweaker.cpp:104). Because every one of our gesture steps is a `jumpTo`, the transform half is inert today, but the filtering half means symbols may shimmer during a pinch in a way the native SDKs do not.

#### Naming decisions

**Where the three upstreams disagree, and what I picked.**

1. **Toggle naming — all three disagree.** gl-js: imperative handler objects (`map.scrollZoom.disable()`) plus declarative `MapOptions` keys (`scrollZoom: false`). Apple: flat booleans on the view (`zoomEnabled`, `scrollEnabled`, `rotateEnabled`, `pitchEnabled` — MLNMapView.h:817/839/866/890). Android: `UiSettings.setZoomGesturesEnabled` / `setScrollGesturesEnabled` / `setRotateGesturesEnabled` / `setTiltGesturesEnabled` (verified against the 11.x KDoc).
   > **SUPERSEDED 2026-08-01 — this paragraph contradicted `:52` and `:241` of this same document,
   > and stage 0 settled it the other way.** The settled policy is **Android `UiSettings` names**
   > (`rotateGesturesEnabled`, `tiltGesturesEnabled`, `scrollGesturesEnabled`,
   > `zoomGesturesEnabled`, …), recorded in CLAUDE.md §9 and `docs/decision-log.md`. The
   > *granularity* argument below survives and is folded into the policy: where Android's toggle is
   > coarser than the gestures we actually recognise, **split it with the same `…Enabled` suffix**
   > (`doubleTapZoomEnabled`, `quickZoomEnabled`) rather than importing a gl-js handler name. The
   > *naming* argument does not survive: gl-js's names are DOM-input-flavoured, we already ship two
   > Android-named toggles, and `google_maps_flutter` and `maplibre_gl` have both converged on
   > `…GesturesEnabled`. Read the rest of this item as the rejected alternative, kept for its
   > reasoning; the container shape (one immutable widget prop, bucket 2) is unaffected and stands.
   >
   > Item **5** below (`rotateGesturesEnabled`/`tiltGesturesEnabled` becoming `@Deprecated`
   > pass-throughs onto gl-js-named fields) falls with it — those two names are now the spine, not
   > the legacy.

   **Rejected alternative: gl-js's `MapOptions` key names, as fields of one immutable `MapGestureSettings` widget prop.** Reasons given: (a) gl-js's *decomposition* is strictly finer than Apple's and Android's — Apple/Android `zoomEnabled` lumps pinch + double-tap + quick-zoom + wheel into one boolean, which we would immediately have to split anyway; (b) `MapOptions` is already a declarative-init/update shape, which is exactly bucket 2, whereas gl-js's `enable()/disable()` handler objects are imperative and would violate the three-bucket rule for state that is mutable + declarative + low-frequency; (c) the field type is a plain `bool`, which is what a Flutter widget prop wants. So: `dragPan`, `dragRotate`, `scrollZoom`, `boxZoom`, `doubleClickZoom`, `touchZoomRotate`, `touchPitch`, `keyboard`, `interactive`, `cooperativeGestures`, `pitchWithRotate`, `bearingSnap`, `clickTolerance`, `rotateSpeed`, `pitchSpeed`.

2. **Where gl-js has no name, Apple/Android names are adopted verbatim**: `quickZoom` (Apple one-finger zoom / Android `setQuickZoomGesturesEnabled`), `panScrollingMode` (Apple `MLNPanScrollingMode`, MLNMapView.h:112-118/853), `flingVelocityAnimation` / `scaleVelocityAnimation` / `rotateVelocityAnimation` (Android UiSettings), `increaseRotateThresholdWhenScaling` / `disableRotateWhenScaling` / `increaseScaleThresholdWhenRotating` (Android), `quickZoomReversed` and `hapticFeedback` (Apple, MLNMapView.h:826/909), `focalPoint` (Android `UiSettings.setFocalPoint`, which subsumes gl-js `around:'center'` and Apple `anchorRotateOrZoomGesturesToCenterCoordinate`).

3. **Camera-change reason: Apple's shape wins outright.** gl-js has nothing equivalent — it only lets you sniff `e.originalEvent` on a `movestart`. Apple's `MLNCameraChangeReason` (MLNCameraChangeReason.h:30-66) is a 10-value bitmask that names each gesture; Android's is three ints (`REASON_API_GESTURE=1`, `REASON_DEVELOPER_ANIMATION=2`, `REASON_API_ANIMATION=3`). Apple's is strictly more informative and its extra values cost nothing, so: **a Dart `MapCameraChangeReason` bitfield mirroring Apple 1:1**, with a `MapCameraChangeReason.gesture` convenience getter that reproduces Android's coarse `REASON_API_GESTURE` for the common "did the user do this?" test.

4. **Flutter-idiom adaptations I made, and to what.**
   - `map.on('moveend', cb)` → **`MapLibreMap.onCameraIdle` / `.onCameraMoveStarted` / `.onCameraMove` widget callbacks** (Android's listener names, which are already the callback-shaped ones). String-keyed `on()` is not Dartlike and defeats static checking; a general event bus is deferred to the events domain.
   - gl-js `dragstart`/`drag`/`dragend` + `zoomstart`/… + `rotatestart`/… + `pitchstart`/… → **one `onCameraMoveStarted(MapCameraChangeReason)` + `onCameraIdle(MapCameraChangeReason)` pair**, because the reason bitmask already carries "which gesture", so twelve callbacks would be redundant in a language with bitfields. Apps that want only zoom filter on `reason & MapCameraChangeReason.anyZoom`.
   - gl-js handler `enable()/disable()/isEnabled()` → declarative `bool` fields (see 1). `isActive()` → **`controller.gestures.activeGestures`**, a read-only `Set<MapGestureKind>` on the controller (bucket 3, high-frequency introspection).
   - `MLNMapView.decelerationRate` (a `CGFloat` with `Normal`/`Fast`/`Immediate` sentinel constants, MLNMapView.h:35-41/920) → **`MapGestureSettings.panDeceleration`, a plain `double` with named `MapPanDeceleration.normal/fast/immediate` constants**, so the sentinel-constant idiom survives without an ObjC typed-extensible-enum.
   - `AndroidView.gestureRecognizers` → adopted verbatim from `google_maps_flutter`/`webview_flutter`, because it is the Flutter-native answer to "map inside a scrollable" and both our tiers (texture *and* platform-view) need it.
   - `cooperativeGestures`' DOM help-text overlay → a Flutter overlay widget with a `cooperativeGesturesBuilder`, since there is no DOM to inject into.

5. **One place where I deliberately keep OUR name.** The existing `MapLibreMap.rotateGesturesEnabled` / `.tiltGesturesEnabled` are Android-derived and each currently controls *two* gl-js handlers at once (twist **and** secondary-drag). They should become `@Deprecated` pass-throughs onto `gestures.touchRotate && gestures.dragRotate` / `gestures.touchPitch && gestures.dragRotate` rather than being deleted, because they ship today and the mapping is lossy in one direction only.

#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | Double-click / double-tap zoom-in gesture | none | `map.doubleClickZoom` (DoubleClickZoomHandler); `MapOptions.doubleClickZoom: boolean` default true | folded into `zoomEnabled` (MLNMapView.h:817, doc: "by pinching two fingers or by double tapping"); reported as `MLNCameraChangeReasonGestureZoomIn` (MLNCameraChangeReason.h:51) | `Map::scaleBy(2.0, anchor, AnimationOptions{duration})` (include/mbgl/map/map.hpp:77) — the engine can do it; our C ABI drops the AnimationOptions (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:80) | widget-prop | yes |
| P0 | Gesture settings container | none | `new Map({dragPan, dragRotate, scrollZoom, boxZoom, doubleClickZoom, touchZoomRotate, touchPitch, keyboard, ...})` (MapOptions) | No container — flat properties on the view: `zoomEnabled`/`scrollEnabled`/`rotateEnabled`/`pitchEnabled` (MLNMapView.h:817, 839, 866, 890) | NOT IN CORE — gesture recognition is a platform-layer concern; mbgl offers only Map::moveBy/scaleBy/pitchBy/rotateBy (include/mbgl/map/map.hpp:76-79) | value-type | no |
| P0 | Global interactive toggle / disable all gestures | none | `interactive: boolean` (MapOptions, default true) | no single flag — set zoomEnabled/scrollEnabled/rotateEnabled/pitchEnabled = NO (MLNMapView.h:817, 839, 866, 890) | NOT IN CORE | widget-prop | no |
| P0 | MapLibreMap.gestures widget prop | partial | the gesture keys of `MapOptions`, plus `map.<handler>.enable()/disable()` at runtime | individual `@property` setters on MLNMapView (MLNMapView.h:817-920) | NOT IN CORE | widget-prop | no |
| P0 | Web-WASM tier: touch gestures entirely absent | none | full touch stack (TwoFingersTouchZoomRotateHandler, TwoFingersTouchPitchHandler, tap/double-tap) — this is what the opt-in maplibre_flutter_web_gljs package would give instead | n/a | n/a — a platform-layer gap, not an engine one | reject | yes |
| P1 | Animated scaleBy about an anchor (C ABI) | none | `map.zoomIn({duration})` / `easeTo({zoom, around, duration})` | `-setZoomLevel:animated:` (MLNMapView.h:1039); the double-tap gesture animates internally | `Map::scaleBy(double, optional<ScreenCoordinate>, const AnimationOptions&)` (include/mbgl/map/map.hpp:77) — the third parameter is exactly what we drop | capability-interface | yes |
| P1 | Camera-change reason bitmask | none | — (no reason type; the nearest thing is sniffing `e.originalEvent` on a MapMovementEvent) | `typedef NS_OPTIONS(NSUInteger, MLNCameraChangeReason)` — None/Programmatic/ResetNorth/GesturePan/GesturePinch/GestureRotate/GestureZoomIn/GestureZoomOut/GestureOneFingerZoom/GestureTilt/TransitionCancelled (MLNCameraChangeReason.h:30-66) | NOT IN CORE — MapObserver::onCameraWillChange/DidChange carry only CameraChangeMode{Immediate, Animated} (include/mbgl/map/map_observer.hpp:37-40, 54-56). Apple synthesises the bitmask in MLNMapView.mm. | value-type | no |
| P1 | Double-click zoom enable/disable toggle | none | `map.doubleClickZoom.enable()/.disable()/.isEnabled()` | `zoomEnabled` (MLNMapView.h:817) | NOT IN CORE | widget-prop | no |
| P1 | Drag-pan enable/disable toggle | none | `map.dragPan.enable(options?)` / `.disable()` / `.isEnabled()`; `MapOptions.dragPan: boolean \| DragPanOptions` | `@property (getter=isScrollEnabled) BOOL scrollEnabled` (MLNMapView.h:839) | NOT IN CORE | widget-prop | no |
| P1 | Drag-rotate enable/disable toggle | partial | `map.dragRotate.enable()` / `.disable()` / `.isEnabled()` / `.isActive()` | — | NOT IN CORE | widget-prop | no |
| P1 | Gesture constraints: min/max zoom, min/max pitch, maxBounds | none | `map.setMinZoom(n)` / `setMaxZoom(n)` / `setMinPitch(n)` / `setMaxPitch(n)` / `setMaxBounds(bounds \| null)` and the matching getters; MapOptions defaults minZoom 0, maxZoom 22, minPitch 0, maxPitch 60 | `minimumZoomLevel` (MLNMapView.h:1053), `maximumZoomLevel` (:1064, "default 22, upper bound 25.5"), `maximumScreenBounds` (:1069), `minimumPitch` (:1107), `maximumPitch` (:1118, "may not exceed 60 degrees regardless") | `Map::setBounds(BoundOptions)` / `getBounds()` (include/mbgl/map/map.hpp:98-101) with withLatLngBounds/withMinZoom/withMaxZoom/withMinPitch/withMaxPitch (include/mbgl/map/bound_options.hpp:16-39) — fully supported, entirely unbound | controller | yes |
| P1 | Layer-scoped tap (hit-test a tap against style layers) | none | `map.on('click', layerId, cb)` — the 3-arg overload; the handler receives MapMouseEvent with `features` populated | the documented pattern is a tap recognizer + `-visibleFeaturesAtPoint:inStyleLayersWithIdentifiers:` on MLNMapView | queryRenderedFeatures, already bound as mbl_map_query_rendered_features (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:246) — but rect-only, no point overload | widget-callback | no |
| P1 | Pan inertia / fling enable + deceleration | internal-only | `MapOptions.dragPan: DragPanOptions` / `map.dragPan.enable({linearity, easing, maxSpeed, deceleration})` — e.g. `{maxSpeed: 1400, deceleration: 2500}` | `@property CGFloat decelerationRate` (MLNMapView.h:911-920) with `MLNMapViewDecelerationRateNormal` / `…Fast` / `…Immediate` (MLNMapView.h:35, 38, 41) | NOT IN CORE — inertia is integrated in the platform layer over repeated `Map::moveBy` (include/mbgl/map/map.hpp:76) | widget-prop | yes |
| P1 | Quick zoom (one-finger double-tap-hold-drag) | none | documented on TwoFingersTouchZoomRotateHandler as single-finger zoom via "double tapping and dragging" on the second tap | gated by `zoomEnabled`; reported as `MLNCameraChangeReasonGestureOneFingerZoom` (MLNCameraChangeReason.h:56-58); direction invertible via `quickZoomReversed` (MLNMapView.h:826) | `Map::scaleBy(scale, anchor)` (include/mbgl/map/map.hpp:77) — continuous, no animation needed while dragging | widget-prop | no |
| P1 | Scroll-zoom enable/disable toggle | none | `map.scrollZoom.enable(options?: boolean \| AroundCenterOptions)` / `.disable()` / `.isEnabled()` / `.isActive()` | `zoomEnabled` (MLNMapView.h:817) | NOT IN CORE | widget-prop | no |
| P1 | Scroll/pinch zoom rate tuning | internal-only | `map.scrollZoom.setZoomRate(rate)` (default 1/100, trackpad) and `.setWheelZoomRate(rate)` (default 1/450, mouse wheel); `map.touchZoomRotate.setZoomRate(rate?)` | — (no API; the recognizer's scale is used directly) | NOT IN CORE (mbgl takes the final scale factor, not a rate) | widget-prop | yes |
| P1 | Stop / cancel in-flight camera animation and inertia | none | `map.stop(): this` — "stops any animated transition underway" | — (setting a camera cancels; `MLNCameraChangeReasonTransitionCancelled` reports it, MLNCameraChangeReason.h:64) | `Map::cancelTransitions()` (include/mbgl/map/map.hpp:64) — UNBOUND in our C ABI (no symbol in packages/maplibre_flutter_core/src/maplibre_flutter_core.h) | controller | yes |
| P1 | gestureRecognizers escape hatch (map inside a scrollable) | none | n/a (the DOM has no gesture arena; `cooperativeGestures` is the analogous answer) | MLNMapView.h:164-175 documents `require(toFail:)` for exactly this conflict class | NOT IN CORE | widget-prop | no |
| P1 | onCameraIdle(reason) callback | none | `map.on('moveend', cb)` (also dragend/zoomend/rotateend/pitchend) | `-mapView:regionDidChangeWithReason:animated:` (MLNMapViewDelegate.h:182-184); `-mapViewDidBecomeIdle:` (MLNMapViewDelegate.h:299) | `MapObserver::onCameraDidChange(CameraChangeMode)` (include/mbgl/map/map_observer.hpp:56) and `onDidBecomeIdle()` (:66) | widget-callback | no |
| P1 | onCameraMove callback with payload | partial | `map.on('move', cb)` → MapMovementEvent | `-mapView:regionIsChangingWithReason:` (MLNMapViewDelegate.h:152); reasonless variant `-mapViewRegionIsChanging:` (:132) | `MapObserver::onCameraIsChanging()` (include/mbgl/map/map_observer.hpp:55) | widget-callback | no |
| P1 | onCameraMoveStarted(reason) callback | none | `map.on('movestart', cb)` → MapMovementEvent (also dragstart/zoomstart/rotatestart/pitchstart) | `-mapView:regionWillChangeWithReason:animated:` (MLNMapViewDelegate.h:110-112); the reasonless `-mapView:regionWillChangeAnimated:` (MLNMapViewDelegate.h:95) is suppressed when the reason variant is implemented | `MapObserver::onCameraWillChange(CameraChangeMode)` (include/mbgl/map/map_observer.hpp:54) — fires, but carries no reason | widget-callback | no |
| P1 | onLongPress / contextmenu callback | none | `map.on('contextmenu', cb)` → MapMouseEvent (right-click) | no delegate hook — apps add a UILongPressGestureRecognizer | NOT IN CORE (projection only) | widget-callback | no |
| P1 | onTap payload (screen point alongside LatLng) | partial | `map.on('click', cb)` → MapMouseEvent with `lngLat`, `point`, `originalEvent`, `features` | no delegate tap callback — the app adds its own UITapGestureRecognizer (MLNMapView.h:164-175 documents the pattern) and calls `-convertPoint:toCoordinateFromView:` (MLNMapView.h:1695) | projection via `Map::latLngForPixel` (include/mbgl/map/map.hpp:120), bound as mbl_map_lat_lng_for_pixel (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:157) | widget-callback | no |
| P2 | Cooperative gestures | none | `MapOptions.cooperativeGestures: GestureOptions \| boolean` (default false) + `map.cooperativeGestures` handler; requires ctrl (Windows/Linux) or cmd (Mac) + scroll to zoom, two fingers to pan; emits `cooperativegestureprevented` | — | NOT IN CORE | widget-prop | no |
| P2 | Drag-pan gesture (one-finger / mouse drag) | present | `map.dragPan` (DragPanHandler) | `scrollEnabled` (MLNMapView.h:839) | `mbgl::Map::moveBy(ScreenCoordinate, AnimationOptions)` (include/mbgl/map/map.hpp:76) via mbl_map_move_by (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:76) | widget-prop | no |
| P2 | Drag-rotate gesture (secondary button / ctrl+drag) | present | `map.dragRotate` (DragRotateHandler): right mouse button or ctrl+drag; horizontal→bearing, vertical→pitch | — (no mouse; iOS has no equivalent) | mbl_map_rotate_by / mbl_map_pitch_by (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:97, 105) | widget-prop | no |
| P2 | Gesture focal point / around-center anchoring | none | `AroundCenterOptions` — `map.scrollZoom.enable({around: 'center'})`, same for touchZoomRotate and touchPitch | `@property BOOL anchorRotateOrZoomGesturesToCenterCoordinate` (MLNMapView.h:893-896) and the subclass hook `-anchorPointForGesture:` (MLNMapView.h:1587) | the anchor argument of `Map::scaleBy` (include/mbgl/map/map.hpp:77) — already plumbed as mbl_map_scale_by's anchor_x/anchor_y (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:80) | widget-prop | no |
| P2 | Gesture state introspection (isMoving / isZooming / isRotating) | none | `map.isMoving(): boolean`, `map.isZooming(): boolean`, `map.isRotating(): boolean`; per-handler `isActive()` | — (no public equivalent; inferred from the delegate's will/did pair) | `Map::isGestureInProgress()`, `isRotating()`, `isScaling()`, `isPanning()` (include/mbgl/map/map.hpp:66-69) — present but UNBOUND in our C ABI | controller | no |
| P2 | Keyboard pan / zoom / rotate handler | none | `map.keyboard` (KeyboardHandler): `enable()`, `disable()`, `isEnabled()`, `isActive()`, `enableRotation()`, `disableRotation()`. Bindings: arrows pan 100 px; `=`/`+` zoom in 1 (shift: 2); `-` zoom out 1 (shift: 2); shift+left/right rotate ±15°; shift+up/down pitch ±10° | — (macOS SDK only) | NOT IN CORE — composed from Map::moveBy/scaleBy + mbl_map_rotate_by/pitch_by | widget-prop | no |
| P2 | Map::setGestureInProgress plumbing | none | — (internal to gl-js's Handler manager) | MLNMapView.mm calls it around each recognizer (not visible in the public headers) | `Map::setGestureInProgress(bool)` (include/mbgl/map/map.hpp:65) → TransformState::gestureInProgress, read by Transform::easeTo (src/mbgl/map/transform.cpp:113, 141) and TransformState::isChanging() (src/mbgl/map/transform_state.cpp:732), which selects icon/text texture filtering (src/mbgl/gfx/drawable_atlases_tweaker.cpp:42-43) and raster resampling (src/mbgl/renderer/layers/raster_layer_tweaker.cpp:104) | capability-interface | yes |
| P2 | Pinch rotation sub-toggle (zoom without rotate) | present | `map.touchZoomRotate.disableRotation()` / `.enableRotation()` | `rotateEnabled` (MLNMapView.h:866) | NOT IN CORE | widget-prop | no |
| P2 | Pinch-release zoom inertia (scale velocity animation) | none | handled inside TwoFingersTouchZoomRotateHandler's inertia (no separate public option) | folded into `decelerationRate` (MLNMapView.h:920) | NOT IN CORE — repeated `Map::scaleBy` (include/mbgl/map/map.hpp:77) | widget-prop | no |
| P2 | Reduce-motion / accessibility respect | none | gl-js honours `prefers-reduced-motion` for non-`essential` camera animations (the `essential` flag on camera options is the opt-out) *(unverified)* | — (UIKit apps read UIAccessibilityIsReduceMotionEnabled themselves) | NOT IN CORE | widget-prop | no |
| P2 | Scroll-wheel zoom gesture | present | `map.scrollZoom` (ScrollZoomHandler) | macOS only in the Apple SDK; on iOS `zoomEnabled` covers pinch/double-tap (MLNMapView.h:817) | `mbgl::Map::scaleBy(double, optional<ScreenCoordinate>, AnimationOptions)` (include/mbgl/map/map.hpp:77) via mbl_map_scale_by (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:80) | widget-prop | no |
| P2 | Touch pinch zoom-rotate gesture | present | `map.touchZoomRotate` (TwoFingersTouchZoomRotateHandler) | `zoomEnabled` + `rotateEnabled` (MLNMapView.h:817, 866) | `Map::scaleBy` (map.hpp:77) + our mbl_map_rotate_by (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:97) — NOT mbgl's own broken Map::rotateBy (map.hpp:79) | widget-prop | no |
| P2 | Two-finger pitch (shove) gesture | present | `map.touchPitch` (TwoFingersTouchPitchHandler) | `pitchEnabled` (MLNMapView.h:890) | our mbl_map_pitch_by (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:105) — NOT mbgl's Map::pitchBy (map.hpp:78), which subtracts its argument | widget-prop | no |
| P2 | Two-finger single-tap zoom-out gesture | none | — (gl-js has no two-finger-tap zoom out; verified absent from the handler list) | reported as `MLNCameraChangeReasonGestureZoomOut` — "The user zoomed the map out (two finger single tap)" (MLNCameraChangeReason.h:53-54); gated by `zoomEnabled` (MLNMapView.h:817) | `Map::scaleBy(0.5, anchor, AnimationOptions)` (include/mbgl/map/map.hpp:77) | widget-prop | yes |
| P2 | bearingSnap / snap-to-north tolerance | none | `MapOptions.bearingSnap: number` (default 7) — on rotate-end, snap to 0 if within this many degrees | `@property CGFloat toleranceForSnappingToNorth` — "The default value of this property is 7" (MLNMapView.h:869-875); `-resetNorth` (MLNMapView.h:1123); haptic feedback fires at 0° (MLNMapView.h:909) | NOT IN CORE — implement over mbl_map_rotate_by / set_camera | widget-prop | no |
| P2 | onDoubleTap callback | none | `map.on('dblclick', cb)` → MapMouseEvent | — (consumed by the zoom gesture) | NOT IN CORE | widget-callback | no |
| P2 | pitchSpeed (drag-pitch sensitivity) | internal-only | `MapOptions.pitchSpeed: number` (default -0.5) | — | NOT IN CORE; the result is clamped to 0..60 by mbgl (include/mbgl/util/constants.hpp:35) | widget-prop | yes |
| P2 | pitchWithRotate option | none | `MapOptions.pitchWithRotate: boolean` (default true) — when false, dragRotate changes bearing only | — | NOT IN CORE | widget-prop | no |
| P2 | rotateSpeed (drag-rotate sensitivity) | internal-only | `MapOptions.rotateSpeed: number` (default 0.8) | — | NOT IN CORE | widget-prop | yes |
| P3 | Box zoom gesture (shift + drag a rectangle) | none | `map.boxZoom` (BoxZoomHandler): shift+drag; `MapOptions.boxZoom: boolean \| BoxZoomHandlerOptions` default true | — | `Map::cameraForLatLngBounds(LatLngBounds, EdgeInsets, bearing?, pitch?)` (include/mbgl/map/map.hpp:80-83) — fully supported, but NOT bound in our C ABI (no such symbol in packages/maplibre_flutter_core/src/maplibre_flutter_core.h) | widget-prop | yes |
| P3 | Box-zoom events (boxzoomstart / boxzoomend / boxzoomcancel) | none | `'boxzoomstart' \| 'boxzoomend' \| 'boxzoomcancel'` → MapBoxZoomEvent | — | NOT IN CORE | reject | no |
| P3 | Fling / OnFlingListener notification | none | — (subsumed by moveend) | — | NOT IN CORE | reject | no |
| P3 | Haptic feedback on north snap | none | — | `@property (getter=isHapticFeedbackEnabled) BOOL hapticFeedbackEnabled` — "a UIImpactFeedbackStyleLight haptic feedback event [is] played when the user rotates the map to due north (0°)" (MLNMapView.h:898-909), default YES | NOT IN CORE | widget-prop | no |
| P3 | Hover / cursor feedback over features | none | `map.on('mouseenter'\|'mouseleave'\|'mousemove', layerId, cb)`; apps set `map.getCanvas().style.cursor` | — | queryRenderedFeatures (bound, rect-only) | widget-callback | no |
| P3 | Pan scrolling mode (horizontal- / vertical-only pan) | none | — | `@property MLNPanScrollingMode panScrollingMode` (MLNMapView.h:853) with `MLNPanScrollingModeHorizontal \| Vertical \| Default` (MLNMapView.h:112-118) | NOT IN CORE (just zero one component of the ScreenCoordinate passed to Map::moveBy, include/mbgl/map/map.hpp:76) | widget-prop | no |
| P3 | Per-gesture detail listeners (OnMove / OnRotate / OnScale / OnShove) | none | the twelve dragstart/zoomstart/rotatestart/pitchstart-family events | — (only the region will/is/did trio) | NOT IN CORE | reject | no |
| P3 | Raw pointer/wheel/touch event forwarding | none | `map.on('mousedown'\|'mouseup'\|'mousemove'\|'touchstart'\|'touchend'\|'touchcancel'\|'wheel', cb)` | apps add their own UIGestureRecognizer (MLNMapView.h:164-175) | NOT IN CORE | reject | no |
| P3 | Rotate-release inertia (rotate velocity animation) | none | handled inside the touch handler's inertia (no separate public option) | folded into `decelerationRate` (MLNMapView.h:920) | NOT IN CORE | widget-prop | no |
| P3 | Rotate/scale threshold cross-suppression | internal-only | `map.touchZoomRotate.setZoomThreshold(zoomThreshold?)` and `setZoomRate(zoomRate?)` | — (no public thresholds) | NOT IN CORE | widget-prop | no |
| P3 | anchorPointForGesture: subclass hook | none | — (`around: 'center'` is the declarative equivalent) | `-(CGPoint)anchorPointForGesture:(UIGestureRecognizer *)gesture` — "Subclasses may override this method to provide specialized behavior — for example, anchoring on the map's center point" (MLNMapView.h:1568-1587) | the anchor argument of Map::scaleBy (include/mbgl/map/map.hpp:77) | reject | no |
| P3 | clickTolerance | none | `MapOptions.clickTolerance: number` (default 3) — max movement in px before a click stops counting as a click | — (UIKit's own recognizer slop) | NOT IN CORE | widget-prop | no |
| P3 | cooperativegestureprevented notification | none | `'cooperativegestureprevented'` → MapLibreEvent with a `gestureType` property | — | NOT IN CORE | widget-callback | no |
| P3 | quickZoomReversed option | none | — | `@property (getter=isQuickZoomReversed) BOOL quickZoomReversed` — "reverses the direction of the quick zoom gesture ... aligning with the behavior in Apple Maps. The default value is NO" (MLNMapView.h:820-826) | NOT IN CORE | widget-prop | no |
| P3 | rollEnabled option | none | `MapOptions.rollEnabled: boolean` (default false); `'rollstart' \| 'roll' \| 'rollend'` events | — (MLNMapCamera has no roll) | `CameraOptions::roll` / `withRoll` (include/mbgl/map/camera.hpp:48-51, 83), read by Transform::easeTo (src/mbgl/map/transform.cpp:130) — **the engine supports it** | widget-prop | yes |
| P3 | shouldChangeFromCamera:toCamera:reason: veto hook | none | — (no equivalent; apps clamp via setMaxBounds / min-max zoom) | `-mapView:shouldChangeFromCamera:toCamera:reason:` → BOOL (MLNMapViewDelegate.h:81-84) | NOT IN CORE — mbgl's own constraint mechanism is BoundOptions (include/mbgl/map/bound_options.hpp:13) | reject | no |

#### Proposed signatures

**Double-click / double-tap zoom-in gesture** — P0, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1251-1257 — the GestureDetector wires only onScaleStart/Update/End; no onDoubleTap anywhere in the file
```dart
final bool doubleClickZoom; // MapGestureSettings, default true — gesture itself implemented in _DesktopMapGestures + the WASM glue
```
> **p0: a straight regression that every map on earth has.** Android and iOS had it from the SDK before the core-primary inversion and lost it. Implementation: a `DoubleTapGestureRecognizer` alongside the scale recognizer (they can coexist in the arena; the scale recognizer must not claim a second tap that hasn't moved), zooming by +1 about the tap point over ~300 ms. Needs the C ABI because an instant `scaleBy(2)` reads as a jarring snap — every upstream animates it; add `mbl_map_scale_by_animated(map, scale, ax, ay, duration_ms)` or a duration parameter on the existing entry point. The same entry point unblocks quick-zoom release and two-finger-tap zoom-out.

**Gesture settings container** — P0, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/map_options.dart:13 (would NOT live here — MapOptions is init-only; this is a widget prop in packages/maplibre_flutter/lib/src/maplibre_map.dart)
```dart
@immutable class MapGestureSettings { const MapGestureSettings({this.interactive = true, this.dragPan = true, this.dragRotate = true, this.scrollZoom = true, this.boxZoom = false, this.doubleClickZoom = true, this.touchZoomRotate = true, this.touchRotate = true, this.touchPitch = true, this.quickZoom = true, this.keyboard = true, this.cooperativeGestures = false, this.pitchWithRotate = true, this.rollEnabled = false, this.panScrollingMode = MapPanScrollingMode.free, this.bearingSnap = 7.0, this.clickTolerance = 3.0, this.rotateSpeed = 0.8, this.pitchSpeed = -0.5, this.zoomRate = 1/100, this.wheelZoomRate = 1/450, this.focalPoint, this.panDeceleration = MapPanDeceleration.normal, this.flingVelocityAnimation = true, this.scaleVelocityAnimation = true, this.rotateVelocityAnimation = false, this.respectReduceMotion = true, this.hapticFeedback = true, this.quickZoomReversed = false}); ... }
```
> One immutable value class is what makes the other 25 rows cheap: they become fields, not 25 widget props. Defaults are copied from gl-js MapOptions where it has one (bearingSnap 7, clickTolerance 3, rotateSpeed 0.8, pitchSpeed -0.5, minPitch 0/maxPitch 60), from ScrollZoomHandler for zoomRate 1/100 and wheelZoomRate 1/450, and from Apple for the rest. `boxZoom` defaults false rather than gl-js's true because shift-drag has no meaning on a touch-first platform. Must have value equality so didUpdateWidget can diff cheaply.

**Global interactive toggle / disable all gestures** — P0, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:407-417 — the gesture layer is attached unconditionally whenever the controller is a MapLibreGestureHandler
```dart
final bool interactive; // MapGestureSettings.interactive — false skips the whole Dart gesture layer
```
> p0 because a non-interactive map is an ordinary requirement (a static locator map in a form, a map thumbnail in a list) and today it is literally unbuildable — there is no way to stop the widget from panning. Implementation is one `if` around the `_DesktopMapGestures` wrap at maplibre_map.dart:407, plus not registering the global pointer route at :720.

**MapLibreMap.gestures widget prop** — P0, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:36-37 (only rotateGesturesEnabled + tiltGesturesEnabled exist), threaded at :228-229, :262-263, :413-414
```dart
final MapGestureSettings gestures; // on MapLibreMap; pushed via didUpdateWidget
```
> Bucket 2 by the three-bucket rule: mutable, declarative, low-frequency. Deliberately NOT MapOptions — MapOptions goes to createMap and never reaches the gesture layer, which lives entirely in the widget (the existing doc comment at maplibre_map.dart:76-79 already argues this). Keep `rotateGesturesEnabled`/`tiltGesturesEnabled` as @Deprecated pass-throughs for one minor release; each maps to TWO gl-js handlers (twist + secondary-drag), so the migration note must say so.

**Web-WASM tier: touch gestures entirely absent** — P0, `reject`, evidence: packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:199-205 registers exactly four callbacks — mousedown, mousemove, mouseup, wheel. No emscripten_set_touchstart/move/end anywhere in the file; teardown at :601-604 confirms the set.
```dart
(no new public API — the fix is emscripten touch callbacks in the WASM glue, behind the same MapGestureSettings)
```
> **The most serious finding in this domain.** Bucketed `reject` because it creates no new Dart API — it is pure implementation debt — but it is p0: mobile web is a first-class target and the map is effectively unusable there. Register emscripten_set_touchstart/touchmove/touchend/touchcancel on the canvas and port the pinch/twist/shove recognition. Better still, consider hoisting the whole web gesture layer into Dart to match the other five tiers, which would delete maplibre_flutter_core_web.cpp:799-885 and remove the wheel-rate and inertia-model divergences with it — but note the web controller deliberately does NOT implement MapLibreGestureHandler today (packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:13-16), so that is a contract decision, not a refactor.

**Animated scaleBy about an anchor (C ABI)** — P1, `capability-interface`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.h:80 `mbl_map_scale_by(map, scale, anchor_x, anchor_y)` — no duration; packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1352 calls Map::scaleBy with the default (empty) AnimationOptions
```dart
// platform interface, on MapLibreGestureHandler (or a new MapLibreAnimatedGestureHandler):
void scaleBy(double scale, double anchorX, double anchorY, {Duration? duration});
```
> The enabling change for three p0/p1 gestures at once: double-tap zoom-in, two-finger-tap zoom-out, and quick-zoom release. Without it those gestures snap instantly, which reads as broken next to any native map. Prefer adding an optional `duration_ms` to the existing mbl_map_scale_by over a new symbol, so the ffigen diff stays small — but note that adding a parameter to `MapLibreGestureHandler.scaleBy` is a hard compile break across five packages plus the test fakes (packages/maplibre_flutter_core/lib/testing.dart:257), for the reason spelled out at packages/maplibre_flutter_platform_interface/lib/src/rotate_handler.dart:8-22. Either use a default parameter value or put the animated form on a new feature-detected interface.

**Camera-change reason bitmask** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:75-82 — onCameraChanged is a bare Listenable with no payload at all; packages/maplibre_flutter_platform_interface/lib/src/projector.dart:60-62 — notifyCameraChanged() takes no arguments
```dart
extension type const MapCameraChangeReason(int bits) {
  static const none = MapCameraChangeReason(0);
  static const programmatic = MapCameraChangeReason(1 << 0);
  static const resetNorth = MapCameraChangeReason(1 << 1);
  static const gesturePan = MapCameraChangeReason(1 << 2);
  static const gesturePinch = MapCameraChangeReason(1 << 3);
  static const gestureRotate = MapCameraChangeReason(1 << 4);
  static const gestureZoomIn = MapCameraChangeReason(1 << 5);
  static const gestureZoomOut = MapCameraChangeReason(1 << 6);
  static const gestureOneFingerZoom = MapCameraChangeReason(1 << 7);
  static const gestureTilt = MapCameraChangeReason(1 << 8);
  static const transitionCancelled = MapCameraChangeReason(1 << 16);
  static const anyGesture = MapCameraChangeReason(0b1_1111_1100);
  bool contains(MapCameraChangeReason other) => bits & other.bits != 0;
}
```
> **Copy Apple's bit values EXACTLY, including the 1<<16 gap for TransitionCancelled** — an app porting from iOS should be able to move its masks over unchanged. Two additions beyond Apple: `boxZoom` and `keyboard` bits (gestures Apple does not have), at 1<<9 and 1<<10 so the Apple bits stay put. **needs_c_abi is FALSE and that is the key insight of this domain**: the reason cannot come from the engine (mbgl does not know), and it does not have to, because our gesture recognisers are in Dart on all five native tiers — the widget already knows which recogniser fired at maplibre_map.dart:840-952. The only tier that needs plumbing is web-WASM, whose gestures are in C++ (maplibre_flutter_core_web.cpp:799-885). Without this, a 'follow my location, break on user pan' mode is unbuildable, which is the standard navigation-app pattern.

**Double-click zoom enable/disable toggle** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:522-534
```dart
final bool doubleClickZoom; // MapGestureSettings
```
> Ships with the gesture. Apps that put a double-tap action on the map (e.g. drop a pin) need to turn it off.

**Drag-pan enable/disable toggle** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:522-534 — _DesktopMapGestures takes rotateEnabled/tiltEnabled only
```dart
final bool dragPan; // MapGestureSettings
```
> Table stakes — maplibre_gl, google_maps_flutter and flutter_map all have it. Guard the moveBy call at maplibre_map.dart:910 and the blocked-route pan at :1091.

**Drag-rotate enable/disable toggle** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1189-1194 — gated by `rotateEnabled || tiltEnabled`, i.e. it shares the twist toggles rather than having its own
```dart
final bool dragRotate; // MapGestureSettings — independent of touchRotate
```
> Matters because the two gestures serve different input devices: an app may well want mouse rotate on desktop but no touch twist on a tablet. Also gates `pitchWithRotate`.

**Gesture constraints: min/max zoom, min/max pitch, maxBounds** — P1, `controller`, evidence: no mbl_map_set_bounds symbol in packages/maplibre_flutter_core/src/maplibre_flutter_core.h; packages/maplibre_flutter/lib/src/maplibre_map.dart:928-951 applies any scale the gesture produces
```dart
// on MapLibreCameraController (camera domain owns the symbol; gestures obey it):
Future<void> setMinZoom(double? minZoom);
Future<void> setMaxZoom(double? maxZoom);
Future<void> setMinPitch(double? minPitch);
Future<void> setMaxPitch(double? maxPitch);
Future<void> setMaxBounds(LatLngBounds? bounds);
```
> **Cross-domain — the camera agent should own the symbol; listed here because it is the primary way apps constrain interaction** ("users may not zoom out past z10", "the map may not leave this city"). Bind it once as `mbl_map_set_bounds(map, has_bounds, sw_lat, sw_lng, ne_lat, ne_lng, has_min_zoom, min_zoom, …)`. Two engine facts to document in the dartdoc: maxPitch above 60 is silently clamped (include/mbgl/util/constants.hpp:35) and maxZoom above 25.5 likewise (constants.hpp:43). Constraining in the engine rather than in the gesture layer is important — it keeps the constraint honoured by programmatic moves and inertia too.

**Layer-scoped tap (hit-test a tap against style layers)** — P1, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart provides queryRenderedFeatures(rect) but nothing binds it to a tap; packages/maplibre_flutter/lib/src/maplibre_map.dart:285-293 does not query
```dart
final void Function(MapTapEvent event, List<MapFeature> features)? onFeatureTap;
final List<String>? tapLayerIds; // null = all layers; mirrors gl-js's per-layer subscription
```
> This is what makes engine-drawn annotations (the clustering path we already ship) actually interactive — without it a cluster bubble cannot be tapped. Implementable today on top of the existing rect query by inflating the tap point by `clickTolerance`, so no C ABI change; a proper point overload with a filter belongs to the queries domain. gl-js's 3-arg `on('click', layerId, cb)` is the upstream shape; `tapLayerIds` is the Flutter-idiom flattening of it, since a widget cannot take N subscriptions.

**Pan inertia / fling enable + deceleration** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:602-635 (constants) and :955-1010 (model); web has a DIFFERENT model at packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:772-795, :924-926
```dart
final bool flingVelocityAnimation;   // MapGestureSettings, default true (Android name)
final double panDeceleration;        // MapPanDeceleration.normal | .fast | .immediate, or any double (Apple shape)
```
> p1 for two reasons. (1) **The two tiers use different physics**: Dart uses the Android SDK's fling model (duration = v/10.5 + 150 ms, glide = v·t·0.28, easeOutCubic — maplibre_map.dart:618-630), while web-WASM uses exponential decay with tau = 0.3 s (maplibre_flutter_core_web.cpp:788, 924). Same product, two feels, no test pinning either. (2) An app cannot turn inertia off, which accessibility and kiosk/embedded uses both need. Adopting Apple's `decelerationRate` as a single scalar with three named constants is the cheapest cross-tier knob; needs_c_abi so the WASM tier can read it. Fold reduce-motion into `respectReduceMotion` (separate row).

**Quick zoom (one-finger double-tap-hold-drag)** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:764-953 — no tap-then-drag state machine
```dart
final bool quickZoom; // MapGestureSettings, default true
```
> p1 because it is THE one-handed zoom on mobile and every native map has it; losing it is part of the same inversion regression as double-tap. State machine: tap-up within the double-tap window, second pointer-down without release, then map vertical drag to a scale factor about the first tap point. Purely additive in Dart.

**Scroll-zoom enable/disable toggle** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1139 — _onPointerSignal is unconditional
```dart
final bool scrollZoom; // MapGestureSettings
```
> Also the precondition for cooperativeGestures, which works by disabling scrollZoom unless a modifier is held.

**Scroll/pinch zoom rate tuning** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1134 and :1143 hardcode `pow(2, -scrollDelta.dy/120)`; packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:880 hardcodes `pow(2, -deltaY/120 * 0.5)`
```dart
final double zoomRate;      // trackpad / pinch, default 1/100
final double wheelZoomRate; // discrete mouse wheel, default 1/450
```
> **Matrix drift:** "Scroll-zoom rate tuning ❌ everywhere" (FEATURE_MATRIX.md:382) — agrees that it is unbound, but does NOT record that the two tiers currently disagree by a factor of 2

**Stop / cancel in-flight camera animation and inertia** — P1, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:760-762 `_stopInertia()` is private and only called from _onScaleStart (:765), _onPointerSignal (:1141) and _onPointerDown (:1202); nothing public cancels a fly-to
```dart
Future<void> stop(); // on MapLibreCameraController — cancels fly-to, ease and any gesture inertia
```
> p1 because it is the standard escape hatch: a long flyTo must be interruptible when the user taps something, and today nothing but a new gesture stops the fling. gl-js's `stop()` is the right name (Android's `cancelTransitions` is more verbose and Apple has none). needs_c_abi for the web-WASM tier, whose animation lives in C++ (`animating_` at maplibre_flutter_core_web.cpp:794) and for parity with mbgl's own cancelTransitions when we eventually move easing into the engine. Must also fire onCameraIdle with `transitionCancelled` set, mirroring Apple.

**gestureRecognizers escape hatch (map inside a scrollable)** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:474 — `gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{}` is hardcoded empty for the Android platform view; the texture tier's GestureDetector at :1251 competes in the arena with no way for the app to bias it
```dart
final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers; // on MapLibreMap, default const {}
```
> Copied verbatim from `google_maps_flutter` and `webview_flutter` — the established Flutter answer, and the one an app author will already know (pass an `EagerGestureRecognizer` factory to make the map win vertical drags inside a ListView). Applies to BOTH branches: forwarded to AndroidViewSurface at maplibre_map.dart:474 (where the empty set is currently a silent policy decision) and used to bias the arena on the texture tier. p1 because putting a map inside a scrolling page is an ordinary layout, and today it produces a map that cannot be panned vertically with no way out.

**onCameraIdle(reason) callback** — P1, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:75-82
```dart
final void Function(MapCameraChangeReason reason)? onCameraIdle; // on MapLibreMap
```
> The single most-requested map callback in practice: it is when you refetch data for the new viewport. Must fire AFTER inertia settles, not at pointer-up — that distinction is exactly why it needs to be built in the gesture layer (which owns the fling ticker at maplibre_map.dart:995-1010) rather than derived from the camera tick.

**onCameraMove callback with payload** — P1, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:75-82 — `Listenable? get onCameraChanged`, no camera, no reason; fed by MapLibreCameraTickNotifier.notifyCameraChanged() (packages/maplibre_flutter_platform_interface/lib/src/projector.dart:60-62)
```dart
final void Function(MapCamera camera, MapCameraChangeReason reason)? onCameraMove; // on MapLibreMap
```
> Keep the existing `controller.onCameraChanged` Listenable — it is the right primitive for the marker overlay's per-frame reprojection and must stay allocation-free. Add the payload-carrying callback ALONGSIDE it, not instead: a Listenable cannot carry a reason, and a per-frame callback that allocates a MapCamera is a different cost profile. Document which to use when.

**onCameraMoveStarted(reason) callback** — P1, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:75-82 — only a continuous Listenable; no start/end edges
```dart
final void Function(MapCameraChangeReason reason)? onCameraMoveStarted; // on MapLibreMap
```
> Android's name, because it is already callback-shaped and carries the reason in the same position. Adapted from gl-js's twelve string-keyed events (movestart/dragstart/zoomstart/rotatestart/pitchstart × start/end) to ONE callback whose reason bitmask says which — a bitfield makes the fan-out redundant. Edge detection lives in the widget's gesture layer (gesture start / animation start), so no interface churn.

**onLongPress / contextmenu callback** — P1, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:286-292 — the tap GestureDetector wires onTapUp only
```dart
final ValueChanged<MapTapEvent>? onLongPress;    // touch long-press AND desktop right-click
final ValueChanged<MapTapEvent>? onSecondaryTap; // desktop-only, if the two must be distinguished
```
> Adaptation, stated: gl-js's `contextmenu` and Android's `onMapLongClick` are the same user intent on different input devices, and Flutter's GestureDetector already unifies them (`onLongPress` fires for touch, `onSecondaryTap` for right-click). Bind BOTH to `onLongPress` by default so an app gets 'the user asked for a context action here' once, and offer `onSecondaryTap` for the desktop-only case. p1 because 'long-press to drop a pin' is the single most common map interaction after tap. Careful: the secondary button is already consumed by drag-rotate (maplibre_map.dart:1192), so a secondary tap must be distinguished from a secondary DRAG by movement threshold.

**onTap payload (screen point alongside LatLng)** — P1, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:71 `final ValueChanged<LatLng>? onTap;` and :285-293 — reports only the unprojected LatLng, and only when a projector exists (:279-280)
```dart
final ValueChanged<MapTapEvent>? onTap;
@immutable class MapTapEvent { final LatLng latLng; final Offset point; final MapPointerKind kind; }
```
> gl-js's MapMouseEvent shape is right and we have half of it. The screen `point` is what an app needs to position a popup or run a queryRenderedFeatures box, and today the caller has to re-project the LatLng to get it back. Breaking change to onTap's signature — do it before a stable tag. `kind` (touch/mouse/stylus) is a Flutter addition, cheap from PointerEvent.kind, and lets an app size its hit-target. Note the tap only fires where a projector exists, so it never fires on the opt-in Android/iOS SDK tiers (neither implements MapLibreMapProjector) — a divergence worth documenting.

**Cooperative gestures** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1139-1152 — a scroll over the map always zooms it, with no modifier requirement and no escape for a surrounding scroll view
```dart
final bool cooperativeGestures; // MapGestureSettings, default false
final Widget Function(BuildContext, MapCooperativeGestureHint)? cooperativeGesturesBuilder; // on MapLibreMap
```
> Flutter-idiom adaptation: gl-js injects a DOM overlay with localized help text (`GestureOptions.windowsHelpText` etc.); we cannot, so the overlay becomes a builder the app supplies (defaulting to a translucent scrim + `Text`). The hint enum tells the builder which rule was violated (scroll-without-modifier vs one-finger-pan). Pairs directly with the `gestureRecognizers` row — they are the two halves of "a map inside a scrollable".

**Drag-pan gesture (one-finger / mouse drag)** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:900-926 (_onScaleUpdate pure-pan branch) → MapLibreGestureHandler.moveBy
```dart
(no new API — governed by MapGestureSettings.dragPan)
```
> Works. The only gap is that it cannot be turned off (see the dragPan row). Note the Linux trackpad pan gain of 0.25 at maplibre_map.dart:730 is a platform correction, not a tunable — it must NOT be folded into the public `panSpeed` if one is ever added.

**Drag-rotate gesture (secondary button / ctrl+drag)** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1189-1228 (_isRotateDrag, _onPointerMove) — on the raw Listener, not the GestureDetector
```dart
(no new API — governed by MapGestureSettings.dragRotate + .pitchWithRotate)
```
> Correctly ported from gl-js, including the sign (drag right turns content clockwise). The two tiers even share the constants 0.8 and 0.5 — which are gl-js's `rotateSpeed` and `|pitchSpeed|` defaults, confirming the port. Expose them under those names.

**Gesture focal point / around-center anchoring** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:946-949 — the zoom anchor is always the cursor or the frozen focal; there is no way to force the viewport centre
```dart
final Offset? focalPoint; // MapGestureSettings — null = anchor on the gesture; Offset.zero-relative logical px, or MapGestureSettings.centerFocalPoint for the viewport centre
```
> Android's `setFocalPoint(PointF)` is the most general shape — it subsumes gl-js's `around:'center'` (pass the centre) and Apple's boolean — so adopt it, with a `centerFocalPoint` sentinel for the common case. The real driver is the location-follow mode: when the camera is locked to the user's position, zooming about the cursor fights the lock, which is exactly why Apple added its flag. One `if` at maplibre_map.dart:946.

**Gesture state introspection (isMoving / isZooming / isRotating)** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:39-283 — no state getters; packages/maplibre_flutter/lib/src/maplibre_map.dart:554 keeps _mode privately in the gesture State
```dart
// on MapLibreMapController:
bool get isMoving;
bool get isZooming;
bool get isRotating;
Set<MapGestureKind> get activeGestures; // the Dartlike form of gl-js's per-handler isActive()
```
> Answer from the DART gesture state (maplibre_map.dart:554, :646, :651), not from mbgl — the Dart layer knows sooner and more precisely, and mbgl's flags would be stale by a render-thread hop. `activeGestures` is the Flutter-idiom collapse of gl-js's nine separate `isActive()` calls into one set, which is also extensible when we add quickZoom/boxZoom. Needs the gesture state hoisted out of the private State into something the controller can read — the one piece of plumbing here.

**Keyboard pan / zoom / rotate handler** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1242 — the map is not focusable and has no Focus/Shortcuts wrapper; HardwareKeyboard is read only for the ctrl modifier at :1194
```dart
final bool keyboard;        // MapGestureSettings, default true
final bool keyboardRotate;  // the declarative form of KeyboardHandler.disableRotation()
```
> Copy gl-js's key bindings and step sizes verbatim (100 px pan, ±1/±2 zoom, ±15° bearing, ±10° pitch) — they are the de-facto standard and a user switching from a web map will expect them. Implementation: wrap the map in `Focus` + `Shortcuts`/`CallbackAction`. This is also the only keyboard-accessible way to move the map, which matters for a11y review before a stable tag.

**Map::setGestureInProgress plumbing** — P2, `capability-interface`, evidence: no occurrence of setGestureInProgress anywhere in packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp (grepped); mbl_map_move_by (:1334) / scale_by (:1346) / rotate_by (:1384) / pitch_by (:1409) each jumpTo without ever flagging a gesture
```dart
// platform interface, on MapLibreGestureHandler:
void setGestureInProgress(bool inProgress);
```
> A real conformance gap with mbgl's contract that no test would catch. Because every one of our gesture steps is a jumpTo, the Transform half is inert today, but `isChanging()` staying false through a pinch means symbols and rasters are filtered with the static-view path — the plausible cause of any icon shimmer during gestures that shows up in the native-feel A/B. Needs `mbl_map_set_gesture_in_progress(MblMap*, int)`, hence an ffigen regen; call it from the widget's gesture start/end (maplibre_map.dart:764, :955) and from the fling ticker's start/stop. Adding a method to MapLibreGestureHandler is a hard compile break in five packages (see the rationale at packages/maplibre_flutter_platform_interface/lib/src/rotate_handler.dart:8-22) — so either land it in one coordinated change or put it on a new opt-in interface.

**Pinch rotation sub-toggle (zoom without rotate)** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:844-846 — `widget.rotateEnabled` gates the rotate latch; :878-890 test covers it
```dart
final bool touchRotate; // MapGestureSettings — the declarative form of disableRotation()
```
> Only rename/regroup work. Today `rotateGesturesEnabled` also gates the secondary-drag rotate (maplibre_map.dart:1191), which gl-js keeps separate as `dragRotate`; splitting them is the point of the new field.

**Pinch-release zoom inertia (scale velocity animation)** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:940-945 — an explicit TODO: "smooth / springy pinch-to-zoom is not implemented yet ... no interpolation toward the target and no release momentum"; :961 returns early from _onScaleEnd for any gesture that scaled
```dart
final bool scaleVelocityAnimation; // MapGestureSettings, default true
```
> The code's own TODO is the spec: interpolate toward the target scale during the pinch and carry momentum on release. This is the single most-felt difference from the native SDKs in an A/B. Note the ticker constraint at maplibre_map.dart:987-992 — _DesktopMapGesturesState is a SingleTickerProviderStateMixin and reuses one ticker; adding a second animation means moving to TickerProviderStateMixin, which the rotate-inertia note in FEATURE_MATRIX.md:365-367 already flags as load-bearing. Do that refactor once, for both.

**Reduce-motion / accessibility respect** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:990-1010 — the fling ticker runs regardless of platform accessibility settings
```dart
final bool respectReduceMotion; // MapGestureSettings, default true — when set, MediaQuery.disableAnimationsOf(context) suppresses fling/ease
```
> gljs_verified false — I did not fetch a page that names the option, and gl-js's exact mechanism (an `essential` flag on camera options vs a global switch) is not something I will assert. The Flutter-idiom adaptation is unambiguous though: read `MediaQuery.disableAnimationsOf(context)` (fed by the OS reduce-motion setting on every platform we ship) and skip inertia. Cheap, and the kind of thing a stable-tag review asks for.

**Scroll-wheel zoom gesture** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1139-1152 (_onPointerSignal) and the overlay-blocked fallback at :1128-1136
```dart
(no new API — governed by MapGestureSettings.scrollZoom)
```
> Works on all six tiers, but at two DIFFERENT rates — see the wheelZoomRate row, which is a real defect.

**Touch pinch zoom-rotate gesture** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:890-952 (zoom) and :872-882 (twist), anchored per maplibre_map.dart:592-600 and :675-694
```dart
(no new API — governed by MapGestureSettings.touchZoomRotate / .touchRotate)
```
> **Matrix drift:** "Touch zoom-rotate (pinch) gesture ✅ all six" (FEATURE_MATRIX.md:387). **Disagrees for Web:** the WASM tier registers only mousedown/mousemove/mouseup/wheel (maplibre_flutter_core_web.cpp:199-205) — there is no touch handler at all, so pinch does not exist on web.

**Two-finger pitch (shove) gesture** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:779-819 (_isShove, from raw pointer positions) and :854-870 (apply)
```dart
(no new API — governed by MapGestureSettings.touchPitch)
```
> **Matrix drift:** "Touch-pitch gesture ✅ all six" (FEATURE_MATRIX.md:391). **Disagrees for Web** for the same reason as pinch — no touch handlers in the WASM glue.

**Two-finger single-tap zoom-out gesture** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1251-1257 — no multi-tap recognizer
```dart
(no separate field — ships with MapGestureSettings.doubleClickZoom, matching Apple, which gates both under zoomEnabled)
```
> The counterpart to double-tap zoom-in on every native map, and the reason `MLNCameraChangeReasonGestureZoomOut` exists. gl-js has no equivalent because a two-finger tap has no desktop meaning — this is a case where copying Apple, not gl-js, is right. Shares the animated-scaleBy C entry point.

**bearingSnap / snap-to-north tolerance** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:872-882 — the bearing is applied raw; there is no snap and no compass affordance
```dart
final double bearingSnap; // MapGestureSettings, default 7.0
```
> gl-js and Apple agree on both the concept and the default (7°), which is the strongest signal in this whole domain — take it verbatim. Without it a twisted map almost never returns to exactly north, which users read as "I can't get it straight again". Applied on rotate-end, so it composes with rotate inertia later.

**onDoubleTap callback** — P2, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1251-1257
```dart
final ValueChanged<MapTapEvent>? onDoubleTap;
```
> Only meaningful once the double-tap recognizer exists (see the double-click-zoom row) — it is the same recognizer, forked. If the app sets `doubleClickZoom: false` and supplies `onDoubleTap`, the app owns the gesture; if both, the map zooms AND reports, matching gl-js, where `dblclick` fires regardless of the handler.

**pitchSpeed (drag-pitch sensitivity)** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:753 `_kDragPitchDegreesPerPixel = 0.5` (applied negated at :1225); web copy at packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:930
```dart
final double pitchSpeed;       // MapGestureSettings, default -0.5 (gl-js sign convention)
final double touchPitchSpeed;  // two-finger shove, default 0.1 deg/px (the SDK's factor)
```
> Note the sign: gl-js's default is NEGATIVE (-0.5) because dragging up increases pitch; our code stores +0.5 and negates at the call site. Adopt gl-js's signed convention so the number in the docs matches the number in the field, and delete the negation. Two separate constants are genuinely needed (mouse drag vs two-finger shove) — gl-js only names the first.

**pitchWithRotate option** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1223-1226 — the vertical component of a rotate-drag always pitches
```dart
final bool pitchWithRotate; // MapGestureSettings, default true
```
> Three lines of work. Commonly used by apps that want a rotatable but strictly top-down map.

**rotateSpeed (drag-rotate sensitivity)** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:752 `_kDragRotateDegreesPerPixel = 0.8`; mirrored in C++ at packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:929
```dart
final double rotateSpeed; // MapGestureSettings, default 0.8
```
> Our hardcoded 0.8 IS gl-js's default — the port is already faithful, so exposing it costs a field and gains the name. needs_c_abi only for the web tier, whose copy of the constant is compiled in.

**Box zoom gesture (shift + drag a rectangle)** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1242-1257 — no modifier-gated drag box
```dart
final bool boxZoom;                                  // MapGestureSettings, default false
final Widget Function(BuildContext, Rect)? boxZoomOverlayBuilder; // draws the rubber band
```
> Desktop-only in practice, hence p3, but it is the natural power-user gesture on Windows/Linux/macOS where we own the whole input stack. Needs `mbl_map_camera_for_lat_lng_bounds` (shared with fitBounds in the camera domain — coordinate with that agent so the entry point lands once). The rubber-band rectangle is a Flutter overlay, which is why a builder is exposed rather than a hardcoded look.

**Box-zoom events (boxzoomstart / boxzoomend / boxzoomcancel)** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart (no box zoom)
```dart
(folded into onCameraMoveStarted/onCameraIdle with MapCameraChangeReason.boxZoom)
```
> Rejected as separate callbacks: the reason bitmask already distinguishes it, and three more widget callbacks for a p3 desktop gesture is a bad trade. Add `MapCameraChangeReason.boxZoom` (an extension beyond Apple's bitmask, which has no box zoom) rather than three events.

**Fling / OnFlingListener notification** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:955-993 — the fling is applied but never reported
```dart
(no separate callback — onCameraMoveStarted fires with MapCameraChangeReason.gesturePan and onCameraIdle fires when the glide settles)
```
> Rejected: Android exposes it because its camera callbacks are coarse; ours will carry a reason and a correct idle edge, which covers every use I can find for OnFlingListener. Recording the decision so it does not get re-litigated from the matrix row.

**Haptic feedback on north snap** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart (no HapticFeedback import or call)
```dart
final bool hapticFeedback; // MapGestureSettings, default true → HapticFeedback.lightImpact() on north snap
```
> Ships with bearingSnap; `HapticFeedback.lightImpact()` from services.dart is the exact analogue of UIImpactFeedbackStyleLight. Pure polish, but it is the tactile confirmation that the snap happened, and Apple defaults it ON.

**Hover / cursor feedback over features** — P3, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1176-1179 — _onPointerHover tracks the cursor for the zoom anchor only; no MouseRegion, no cursor change
```dart
final void Function(MapTapEvent event, List<MapFeature> features)? onFeatureHover;
final MouseCursor Function(List<MapFeature> features)? featureCursor;
```
> Desktop polish (a pointing-hand cursor over a clickable feature is what makes a web map feel clickable), and a per-frame query is expensive — so p3, and it must be throttled and opt-in. Flutter's `MouseRegion` + `MouseCursor` is the idiom; there is no cross-platform 'set the canvas cursor' to copy.

**Pan scrolling mode (horizontal- / vertical-only pan)** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:909-911 — both axes are always applied
```dart
final MapPanScrollingMode panScrollingMode; // free | horizontalOnly | verticalOnly, default free
```
> Apple's tri-state enum is the better shape than Android's single boolean (which can only express one of the two restrictions), so copy `MLNPanScrollingMode`. Two lines in _onScaleUpdate. Real use case: a strip map / timeline along one axis.

**Per-gesture detail listeners (OnMove / OnRotate / OnScale / OnShove)** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:764-1010 — all recogniser detail stays private to _DesktopMapGesturesState
```dart
(no separate callbacks — onCameraMoveStarted/onCameraMove/onCameraIdle carry MapCameraChangeReason, which names the gesture)
```
> Rejected deliberately, and this is the single biggest API-surface saving in the domain: Android's four listener interfaces × three methods and gl-js's twelve string events collapse to three callbacks plus a bitmask. If a concrete need appears for a gesture's raw delta (not the resulting camera), revisit — but do not build twelve callbacks speculatively. Recorded here because the matrix's six rows make it look like six missing features.

**Raw pointer/wheel/touch event forwarding** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:1242-1250 — the Listener consumes events internally and forwards nothing to the app
```dart
(none — apps wrap MapLibreMap in their own Listener / GestureDetector)
```
> Rejected: gl-js needs these because a DOM canvas is opaque to the page, whereas in Flutter an app can simply wrap `MapLibreMap` in its own `Listener` and receive every pointer event before or after the map, depending on hit-test order. Re-exporting them would duplicate the framework. Worth documenting in the widget's dartdoc so nobody thinks it is missing — with the caveat that the map's own recognizers compete in the arena, which is what the `gestureRecognizers` row exists to resolve.

**Rotate-release inertia (rotate velocity animation)** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:955-961 — _onScaleEnd only ever flings a pan; a rotate is never continued
```dart
final bool rotateVelocityAnimation; // MapGestureSettings, default false
```
> Explicitly deferred today for a documented reason (the single-ticker constraint). Default false so we do not promise a feel we have not tuned. Unblocked by the same TickerProviderStateMixin change as pinch inertia.

**Rotate/scale threshold cross-suppression** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:520 (_GestureMode), :840-852 (the latch) and :736 (8° deadzone) — a hardcoded latch that is stricter than any upstream and not configurable
```dart
final bool disableRotateWhenScaling;
final bool increaseRotateThresholdWhenScaling;
final double rotateThresholdDegrees; // default 8 (ours today; the Android SDK uses 3 + a speed gate)
```
> Our latch already implements a coarse version of `disableRotateWhenScaling` in the shove branch (maplibre_map.dart:868-869) and a fixed 8° threshold where the Android SDK uses 3° plus a speed-adaptive second gate we did not port (see the comment at :732-736). Exposing the threshold lets the eventual native-feel A/B be done by an app author rather than a recompile. Android's three flag names are the only vocabulary anyone has for this — copy them.

**anchorPointForGesture: subclass hook** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:946-949 — the anchor policy is fixed in the widget
```dart
(none — MapGestureSettings.focalPoint covers it declaratively)
```
> Rejected: it is an ObjC subclassing idiom with no Flutter analogue (our widget is final and composition-based), and both other SDKs express the same capability declaratively. Recorded so the header is not mistaken for a missing binding.

**clickTolerance** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:285-293 — onTapUp fires from a bare GestureDetector with Flutter's default slop
```dart
final double clickTolerance; // MapGestureSettings, default kTouchSlop (18) — NOT gl-js's 3
```
> Adaptation, stated: keep the gl-js NAME but change the DEFAULT to Flutter's `kTouchSlop`, because a 3-px tolerance on a touchscreen would reject most real taps — gl-js's 3 is a mouse-first number. Document the divergence in the dartdoc so nobody 'fixes' it back.

**cooperativegestureprevented notification** — P3, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart (no cooperative gestures)
```dart
final ValueChanged<MapCooperativeGestureHint>? onCooperativeGesturePrevented;
```
> Only needed by apps that want custom feedback (a toast, haptics) instead of the default overlay. Ships with cooperativeGestures.

**quickZoomReversed option** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart (no quick zoom at all)
```dart
final bool quickZoomReversed; // MapGestureSettings, default false
```
> Long tail, but free once quick zoom exists, and it is the kind of platform-convention detail iOS reviewers notice. Copy Apple's name and default verbatim.

**rollEnabled option** — P3, `widget-prop`, evidence: packages/maplibre_flutter_platform_interface/lib/src/camera.dart:10-28 — MapCamera has center/zoom/bearing/pitch and no roll, so there is nothing for a roll gesture to drive
```dart
final bool rollEnabled; // MapGestureSettings, default false — blocked on MapCamera.roll
```
> Flagged mainly to correct the matrix. Genuinely p3 (roll is a niche aviation/AR camera), but the ➖ is misinformation that could stop someone from building it. Blocked on the camera domain adding `MapCamera.roll` and the shim passing it through mbl_map_set_camera.

**shouldChangeFromCamera:toCamera:reason: veto hook** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:39-283 — no interception point
```dart
(none — use setMaxBounds / setMinZoom / setMaxZoom / setMinPitch / setMaxPitch)
```
> Rejected: a synchronous per-frame veto callback into Dart on the gesture path is a performance and re-entrancy hazard (it would run inside the gesture update, mid-frame), and mbgl already offers the declarative constraint that covers 95% of the use — which is why gl-js and Android never added one. Reconsider only if a concrete non-rectangular constraint (e.g. 'stay within this polygon') shows up.


### Events & queries

#### Engine ceiling

Four hard stops for the native + WASM tiers in this domain, all verified in the vendored headers/sources.

**1. Layer identity on rendered-feature queries — genuinely lost inside mbgl.** `RenderOrchestrator::queryRenderedFeatures` builds `std::unordered_map<std::string, std::vector<Feature>> resultsByLayer`, then flattens it into a `std::vector<Feature>` and throws the key away (`src/mbgl/renderer/render_orchestrator.cpp:646-676`, specifically the merge loop at :667-674). `mbgl::Feature` (`include/mbgl/util/feature.hpp:20-35`) carries `source`, `sourceLayer` and `state` but has no layer field. The public `Renderer::queryRenderedFeatures` overloads (`include/mbgl/renderer/renderer.hpp:57-60`) all return the flattened vector. So gl-js's `feature.layer.id` cannot be produced from mbgl's public API. Workaround inside our shim: one query per requested layer id, tagging each batch. The Apple SDK hits the identical wall — `-visibleFeaturesAtPoint:inStyleLayersWithIdentifiers:` (MLNMapView.h:2094) returns `NSArray<id<MLNFeature>>` and `MLNFeature` has no layer property (MLNFeature.h:40-153).

**2. Terrain, and therefore `queryTerrainElevation` / `getCameraTargetElevation` — absent from mbgl-core entirely.** A recursive grep of `include/mbgl` for terrain matches only `shaders/{gl,mtl,vulkan}/color_relief.hpp`. There is no terrain source type, no `Map::queryTerrainElevation`, and no elevation term in the camera or transform. This is gl-js-only and will stay so until upstream lands terrain in native. FEATURE_MATRIX.md:522 marks it ❌ ("the engine CAN do it"); by the matrix's own legend (:50-67) it must be ➖.

**3. gl-js's `data` / `dataloading` / `dataabort` / `sourcedataloading` / `sourcedataabort` family has no mbgl counterpart.** mbgl offers `onSourceChanged(style::Source&)` (`include/mbgl/map/map_observer.hpp:65`) — one coarse notification with no `dataType` ('metadata' vs 'content'), no tile reference, and no abort signal — plus the per-tile `onTileAction` (`:86`). The aggregate pipeline gl-js models is a property of its worker architecture, not of the engine. Bind `sourceData` with the narrower mbgl payload; do not fabricate the missing fields.

**4. Camera-change *reason* is not in mbgl.** `MapObserver::CameraChangeMode` is `{Immediate, Animated}` (`include/mbgl/map/map_observer.hpp:37-40`) and nothing richer crosses the observer. Apple's 11-value `MLNCameraChangeReason` (MLNCameraChangeReason.h:30-66) is synthesized above the engine, in the platform's own gesture code. Not a blocker for us — our five native tiers already recognize every gesture in Dart — but it means the reason can never come *from* the C ABI, and any design that expects it to is wrong.

Two near-ceilings worth flagging, both surmountable:
- **`onCanRemoveUnusedStyleImage` (`include/mbgl/map/map_observer.hpp:70`) is the only observer method whose return value the engine waits on.** Answering it from Dart means blocking the render thread on an isolate hop — the same re-entrancy/deadlock shape CLAUDE.md §11 records for `FileSource::Callback`. Treat as unbindable as a callback; express as declarative policy in C++ if ever needed.
- **`Renderer::getPlacedSymbolsData()` is gated to `MapMode::Tile`** (`include/mbgl/renderer/renderer.hpp:92-108`), and we run Continuous or Static (`packages/maplibre_flutter_core/src/maplibre_flutter_core.h:47-51`). Collision-box introspection is therefore off the table without a second map instance in Tile mode.

Everything else in this domain is *binding work, not an engine limit* — and notably three things the matrix declares impossible are sitting in the public engine headers: `Map::isGestureInProgress/isRotating/isScaling/isPanning` (`include/mbgl/map/map.hpp:66-69`, matrix says ➖ web_only at FEATURE_MATRIX.md:517), `style::Source::loaded` (`include/mbgl/style/source.hpp:123`), and `Map::isFullyLoaded()` (`include/mbgl/map/map.hpp:153`).

#### Naming decisions

**Policy applied.** Style/data *queries* take gl-js names verbatim (`queryRenderedFeatures`, `querySourceFeatures`, `isSourceLoaded`, `areTilesLoaded`, `getBounds`, and the option names `layers` / `filter`), because those words come from the style spec and the generated typed style API already speaks them. The Apple SDK calls the same operation `-visibleFeaturesAtPoint:inStyleLayersWithIdentifiers:predicate:` (MLNMapView.h:2074/2094/2157) and `-visibleFeaturesInRect:...` (MLNMapView.h:2176/2195/2253); that is an Apple-idiom rename of the same mbgl entry point (`Renderer::queryRenderedFeatures`, include/mbgl/renderer/renderer.hpp:57-60) and loses to gl-js. Things gl-js has no equivalent of take the Apple shape: **camera-change reason** is Apple's `MLNCameraChangeReason` bitmask (MLNCameraChangeReason.h:30-66), not Android's coarser 3-value `OnCameraMoveStartedListener.REASON_*`, because Apple's is strictly richer and is what mbgl's own SDK ships.

**Four upstream disagreements, and the calls made.**

1. **Layer identity on query results.** gl-js results carry `feature.layer.id`. mbgl **cannot**: `RenderOrchestrator::queryRenderedFeatures` builds `resultsByLayer` and then flattens it into a `std::vector<Feature>`, discarding the key (src/mbgl/renderer/render_orchestrator.cpp:667-674), and `mbgl::Feature` (include/mbgl/util/feature.hpp:20-35) has `source`/`sourceLayer`/`state` but no layer field. The Apple SDK inherits that gap. **Chose gl-js's shape** (`MapLibreFeature.layerId`) and fill it in the shim by looping one `RenderedQueryOptions({oneLayer})` query per requested layer id and tagging each batch — exact when `layers:` is given, `null` for an unrestricted query. Stated as a ceiling below.

2. **Map click.** gl-js has `map.on('click', …)`; Android has `addOnMapClickListener`. The **Apple SDK has no map-click delegate method at all** — `MLNMapViewDelegate` (read in full, MLNMapViewDelegate.h:22-1019) offers only `didSelectAnnotation:` (:800), and MLNMapView.h:167-175 documents adding your *own* `UITapGestureRecognizer`. **Chose gl-js/Android**, which is also what we already ship as `MapLibreMap.onTap`.

3. **Query geometry argument.** gl-js takes one method with `PointLike | [PointLike, PointLike] | options`; Apple splits into `…AtPoint:` and `…InRect:`. **Chose Apple's split, gl-js's name stem** — `queryRenderedFeatures({Rect? area, …})` (null = whole viewport, gl-js's no-arg form) plus `queryRenderedFeaturesAt(Offset point, …)`. A Dart `Object?` union parameter would be un-Dartlike and unanalyzable.

4. **Filters.** Apple filters with `NSPredicate`; gl-js with a `FilterSpecification` expression. **Chose gl-js/spec** — our generated `Expression` already models all 84 operators, and `RenderedQueryOptions.filter` is a `style::Filter` (include/mbgl/renderer/query.hpp:24), i.e. an expression, so `NSPredicate` is a pure Apple-side translation layer we should not import.

**Flutter-idiom adaptations, and what they are.**

- **`map.on('moveend', fn)` is not Dartlike.** Split two ways. (a) *Pointer and camera-lifecycle* events become **widget callbacks** — `MapLibreMap.onTap`, `.onLongPress`, `.onCameraIdle` — matching what we already ship and what `google_maps_flutter` does. (b) *Engine and diagnostic* events (style/source/tile/sprite/glyph/shader/error/frame — roughly twenty) become **broadcast `Stream`s under a new `controller.events` namespace**, because one widget prop each would bloat the widget past readability. Event **names keep the gl-js word** where one exists (`styleLoaded`, `idle`, `sourceData`, `styleImageMissing`, `errors`); where only mbgl/Apple has it, the mbgl `MapObserver` name is kept (`tileActions`, `spriteEvents`, `glyphEvents`, `renderFrames`).
- **`on`/`off`/`once`/`listens` are replaced by `Stream`**: `listen`/`cancel` is `on`/`off`, `.first` is `once`, `hasListener` is `listens`. Adapted, not bound.
- **Async by default.** gl-js's `queryRenderedFeatures` is synchronous; ours is synchronous *and* blocks the UI isolate on a render-thread round trip with a 200 ms deadline (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1769-1774). Public shape becomes `Future<List<MapLibreFeature>>` per CLAUDE.md §5a ("long-running calls belong on a helper isolate"), with `queryRenderedFeaturesSync` retained as the escape hatch for the existing camera-tick overlay use.
- **`tolerance:` on the point query is ours, not upstream's.** Neither gl-js nor Apple has it; a finger is not a pixel, so a hit-test slop in logical points is a Flutter necessity.
- **`LngLatBounds` → `LatLngBounds`.** gl-js says LngLat; we already committed to `LatLng(lat, lng)` (CLAUDE.md §11), so the bounds type follows our order. Deliberate deviation from the gl-js spelling for internal consistency.
- **Reason enum is synthesized in Dart, not in the engine.** mbgl's `MapObserver::CameraChangeMode` (include/mbgl/map/map_observer.hpp:37-40) is only `Immediate|Animated`. Since every gesture on the five native tiers is already recognized in our Dart layer, the reason is known there and needs no C ABI.

#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | Feature `id` in query results | none | `MapGeoJSONFeature.id` | `MLNFeature.identifier` (MLNFeature.h:72) — documented as the vector-tile feature id, NSNumber or NSString | `GeoJSONFeature::id` (`mapbox::feature::identifier`) via include/mbgl/util/feature.hpp:15 | value-type | no |
| P0 | LatLngBounds value type | none | `LngLatBounds` class; `map.getBounds(): LngLatBounds` | `MLNCoordinateBounds` struct (MLNGeometry.h:72) + `MLNCoordinateBoundsMake(sw, ne)` (MLNGeometry.h:100), `MLNCoordinateBoundsIntersectsCoordinateBounds` (MLNGeometry.h:147) | `mbgl::LatLngBounds` (include/mbgl/util/geo.hpp:82; `southwest()` :124, `northeast()` :125, `constrain()` :133, `contains()` :150) | value-type | no |
| P0 | MapGeometry — sealed GeoJSON geometry type | none | GeoJSON `Geometry` union from the geojson types package | `MLNPointFeature` / `MLNPolylineFeature` / `MLNPolygonFeature` / `MLNPointCollectionFeature` / `MLNMultiPolylineFeature` / `MLNMultiPolygonFeature` / `MLNShapeCollectionFeature` (MLNFeature.h:171/200/208/220/235/243/266) | `mapbox::geometry::geometry<double>` via `Feature::GeometryType` (include/mbgl/util/feature.hpp:26) | value-type | no |
| P0 | MapLibreError + error severity/kind | none | `ErrorEvent` on `map.on('error', …)`; `{ error: Error, sourceId?, source?, tile? }` | `-mapViewDidFailLoadingMap:withError:` (MLNMapViewDelegate.h:219); `-mapViewRendererDidError:` (MLNMapViewDelegate.h:515) | `MapObserver::onDidFailLoadingMap(MapLoadError, const std::string&)` (include/mbgl/map/map_observer.hpp:59) with `enum class MapLoadError {StyleParseError, StyleLoadError, NotFoundError, UnknownError}` (:21-26); `MapObserver::onRenderError(std::exception_ptr)` (:94); and the global `Log::Observer::onRecord(EventSeverity, Event, int64_t code, const std::string&)` (include/mbgl/util/logging.hpp:15-29) | value-type | yes |
| P0 | MapLibreFeature — the query result type | partial | `MapGeoJSONFeature` = GeoJSONFeature + `layer` (LayerSpecification with `source`), `source: string`, `sourceLayer?: string`, `state: {[k]: any}` | `@protocol MLNFeature` — `identifier` (MLNFeature.h:72), `attributes` (MLNFeature.h:132), `-attributeForKey:` (MLNFeature.h:140), `-geoJSONDictionary` (MLNFeature.h:151); no layer/source/state | `mbgl::Feature` (include/mbgl/util/feature.hpp:20-35) — GeoJSONFeature (id/geometry/properties) plus `source`, `sourceLayer`, `state` | value-type | yes |
| P0 | MapLibreMapEvent hierarchy + tap/pointer event payload | none | `MapMouseEvent` { type, target, originalEvent, point: Point, lngLat: LngLat, preventDefault(), defaultPrevented }; `MapLayerMouseEvent` adds `features` | — (no pointer event object; the SDK expects your own UIGestureRecognizer, MLNMapView.h:167-175) | NOT IN CORE — mbgl has no input layer at all; hit-testing is `Renderer::queryRenderedFeatures` (include/mbgl/renderer/renderer.hpp:57-60) | value-type | no |
| P0 | MapLibreMapObserver — the capability interface that carries every event | none | `map.on(type, listener)` / `off` / `once` / `listens` | `@protocol MLNMapViewDelegate` in full (MLNMapViewDelegate.h:22-1019) — one optional method per event | `class MapObserver` (include/mbgl/map/map_observer.hpp:28-95) — 25 virtuals; we currently subclass it with exactly two overrides | capability-interface | yes |
| P0 | Non-Point geometry in query results | none | full GeoJSON geometry on every result | the concrete MLNFeature subclass per geometry type (MLNFeature.h:171-266) | `Feature::geometry` — `mapbox::geometry::geometry<double>` (include/mbgl/util/feature.hpp:26) | value-type | no |
| P0 | `click` — map tap reports the screen point | partial | `map.on('click', (e: MapMouseEvent) => { e.lngLat; e.point; })` | — (no delegate method; MLNMapView.h:167-175 tells you to add your own UITapGestureRecognizer) | NOT IN CORE (no input layer) | widget-callback | no |
| P0 | `error` event / diagnostic channel | none | `map.on('error', (e) => …)` — the default handler console.errors | `-mapViewDidFailLoadingMap:withError:` (MLNMapViewDelegate.h:219); `-mapViewRendererDidError:` (MLNMapViewDelegate.h:515) | `MapObserver::onDidFailLoadingMap(MapLoadError, const std::string&)` (include/mbgl/map/map_observer.hpp:59); `onRenderError(std::exception_ptr)` (:94); `Log::setObserver(std::unique_ptr<Observer>)` (include/mbgl/util/logging.hpp:28) | controller-namespace | yes |
| P0 | `queryRenderedFeatures` — point form | none | `queryRenderedFeatures(point: PointLike, options?)` | `-visibleFeaturesAtPoint:inStyleLayersWithIdentifiers:predicate:` (MLNMapView.h:2157) | `Renderer::queryRenderedFeatures(const ScreenCoordinate&, const RenderedQueryOptions&)` (include/mbgl/renderer/renderer.hpp:58) — **already exists, we just do not call it** | controller-namespace | yes |
| P0 | `style.load` / `styledata` — style finished loading | internal-only | `map.on('style.load', …)` / `map.on('styledata', …)`; `map.isStyleLoaded(): boolean` | `-mapView:didFinishLoadingStyle:` (MLNMapViewDelegate.h:321) — documented as "the earliest opportunity to modify the layout or appearance of the current style" | `MapObserver::onDidFinishLoadingStyle()` (include/mbgl/map/map_observer.hpp:64) | controller-namespace | yes |
| P0 | controller.events namespace | none | `map.on('…')` (flat) | delegate protocol (flat) | `MapObserver` (include/mbgl/map/map_observer.hpp:28) | controller-namespace | no |
| P1 | Cluster expansion — `getClusterExpansionZoom` / `getClusterChildren` / `getClusterLeaves` | none | `GeoJSONSource.getClusterExpansionZoom(clusterId: number): Promise<number>`; `.getClusterChildren(clusterId): Promise<Feature[]>`; `.getClusterLeaves(clusterId, limit, offset): Promise<Feature[]>` | `-[MLNShapeSource zoomLevelForExpandingCluster:]` (MLNShapeSource.h:437), `-childrenOfCluster:` (MLNShapeSource.h:426), `-leavesOfCluster:offset:count:` (MLNShapeSource.h:408); cluster identity via `MLNCluster.clusterIdentifier` / `.clusterPointCount` (MLNCluster.h:46-49) | `Renderer::queryFeatureExtensions(sourceID, feature, extension, extensionField, args)` (include/mbgl/renderer/renderer.hpp:67) with extension `"supercluster"` and fields `"children"` / `"leaves"` / `"expansion-zoom"` (src/mbgl/renderer/sources/render_geojson_source.cpp:63, :124) | controller-namespace | yes |
| P1 | Layer identity (`feature.layer.id`) on query results | none | `MapGeoJSONFeature.layer` (a LayerSpecification, so `feature.layer.id` and `feature.layer.type`) | — (`NSArray<id<MLNFeature>>` from `-visibleFeaturesAtPoint:…`; MLNFeature has no layer property, MLNFeature.h:40-153) | **NOT IN CORE** — `RenderOrchestrator::queryRenderedFeatures` builds `std::unordered_map<std::string, std::vector<Feature>> resultsByLayer` and then flattens it, discarding the key (src/mbgl/renderer/render_orchestrator.cpp:667-674). `mbgl::Feature` (include/mbgl/util/feature.hpp:20-35) has source/sourceLayer/state but no layer id. | value-type | yes |
| P1 | Layer-scoped click — `map.on('click', layerId, fn)` | none | `map.on('click', layerId: string \| string[], listener: (e: MapLayerMouseEvent) => void)` — `e.features` is pre-populated | — (compose `-visibleFeaturesAtPoint:inStyleLayersWithIdentifiers:` (MLNMapView.h:2094) with your own recognizer) | `Renderer::queryRenderedFeatures(const ScreenCoordinate&, RenderedQueryOptions)` (include/mbgl/renderer/renderer.hpp:58) | widget-prop | yes |
| P1 | MapLibreCameraChangeReason | none | — | `MLNCameraChangeReason` NS_OPTIONS (MLNCameraChangeReason.h:30-66): None/Programmatic/ResetNorth/GesturePan/GesturePinch/GestureRotate/GestureZoomIn/GestureZoomOut/GestureOneFingerZoom/GestureTilt/TransitionCancelled | NOT IN CORE as a reason — `MapObserver::CameraChangeMode` is only `{Immediate, Animated}` (include/mbgl/map/map_observer.hpp:37-40) | value-type | no |
| P1 | Native long-press (`OnMapLongClickListener`) | none | — (approximated by `contextmenu`) | — | NOT IN CORE | widget-callback | no |
| P1 | Query off the UI isolate | none | — (single-threaded, no isolate concept) | — (synchronous on the main thread) | the query MUST run on the render thread (`Renderer` is thread-affine), which is why the shim posts and waits | controller-namespace | no |
| P1 | Query timeout is dropped by the platform interface | internal-only | — (synchronous, no timeout) | — (synchronous) | no timeout in core; ours is a shim-level deadline (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:243-245, .cpp:1769-1774) | capability-interface | no |
| P1 | `areTilesLoaded` / `loaded()` / `isFullyLoaded` | none | `map.areTilesLoaded(): boolean`; `map.loaded(): boolean` | — (no boolean; `-mapViewDidBecomeIdle:` is the event form, MLNMapViewDelegate.h:299) | `Map::isFullyLoaded() const` (include/mbgl/map/map.hpp:153) | controller | yes |
| P1 | `contextmenu` / secondary tap | none | `map.on('contextmenu', (e: MapMouseEvent) => …)` | — (long-press via your own UILongPressGestureRecognizer) | NOT IN CORE | widget-callback | no |
| P1 | `getBounds` — visible coordinate bounds | none | `map.getBounds(): LngLatBounds` | `MLNMapView.visibleCoordinateBounds` (MLNMapView.h:1145); `-convertRect:toCoordinateBoundsFromView:` (MLNMapView.h:1727); `MLNMapView.maximumScreenBounds` (MLNMapView.h:1069) | `Map::latLngBoundsForCamera(const CameraOptions&) const` (include/mbgl/map/map.hpp:92) and `latLngBoundsForCameraUnwrapped` (:93) | controller-namespace | yes |
| P1 | `getFeatureState` (and the set/remove pair) | none | `getFeatureState(feature: FeatureIdentifier): any`; `setFeatureState(feature, state): Map`; `removeFeatureState(feature, key?): Map` | — (not exposed by the Apple SDK at all) | `Renderer::getFeatureState(FeatureState&, sourceID, sourceLayerID, featureID)` (include/mbgl/renderer/renderer.hpp:79), `setFeatureState` (:74), `removeFeatureState` (:84); types at include/mbgl/util/feature.hpp:16-18 | controller-namespace | yes |
| P1 | `idle` — no more drawing until something changes | none | `map.on('idle', …)` | `-mapViewDidBecomeIdle:` (MLNMapViewDelegate.h:299) — documented as "no camera transitions in progress, all requested tiles loaded, all fade/transition animations complete" | `MapObserver::onDidBecomeIdle()` (include/mbgl/map/map_observer.hpp:66) | controller-namespace | yes |
| P1 | `isSourceLoaded` | none | `map.isSourceLoaded(id: string): boolean` | — (not exposed on MLNSource/MLNStyle) | `style::Source::loaded` — a public bool field (include/mbgl/style/source.hpp:123), reachable via `Style::getSource(id)` (include/mbgl/style/style.hpp:58) | controller-namespace | yes |
| P1 | `isStyleLoaded` | none | `map.isStyleLoaded(): boolean` | `MLNMapView.style` is nil until loaded (MLNMapView.h:261) — a nullable property is the idiom | derivable from `MapObserver::onDidFinishLoadingStyle` (include/mbgl/map/map_observer.hpp:64); no direct getter on Style | controller | yes |
| P1 | `mousemove` / hover + per-layer `mouseenter` / `mouseleave` / `mouseover` / `mouseout` | none | `map.on('mousemove'\|'mouseenter'\|'mouseleave'\|'mouseover'\|'mouseout', layerId?, listener)` — the enter/leave pair is layer-scoped only | — (no pointer on iOS; macOS AppKit has NSTrackingArea, not in the SDK) | NOT IN CORE (hit-testing via `Renderer::queryRenderedFeatures`, include/mbgl/renderer/renderer.hpp:58) | widget-prop | yes |
| P1 | `movestart` / `move` / `moveend` | partial | `map.on('movestart'\|'move'\|'moveend', …)` → `MapMovementEvent` | `-mapView:regionWillChangeAnimated:` (MLNMapViewDelegate.h:95) / `-mapViewRegionIsChanging:` (:132) / `-mapView:regionDidChangeAnimated:` (:165), plus the `…WithReason:` variants (:110, :152, :182) | `MapObserver::onCameraWillChange(CameraChangeMode)` (include/mbgl/map/map_observer.hpp:54), `onCameraIsChanging()` (:55), `onCameraDidChange(CameraChangeMode)` (:56) | widget-callback | no |
| P1 | `on` / `off` / `once` / `listens` — the subscription API itself | none | `map.on(type, listener)` / `on(type, layerId, listener)`; `off`; `once`; `listens(type): boolean` | delegate assignment (`MLNMapView.delegate`, MLNMapView.h:244) | `MapObserver` passed to the `Map` constructor (include/mbgl/map/map.hpp:41-46) — one observer per map, not a registry | controller-namespace | no |
| P1 | `queryRenderedFeatures` — `filter` option | none | `QueryRenderedFeaturesOptions.filter?: FilterSpecification` | `predicate:(nullable NSPredicate *)` (MLNMapView.h:2160, :2256) | `RenderedQueryOptions.filter` — `std::optional<style::Filter>` (include/mbgl/renderer/query.hpp:24) | controller-namespace | yes |
| P1 | `queryRenderedFeatures` — bbox form | partial | `queryRenderedFeatures(geometryOrOptions?: PointLike \| [PointLike, PointLike] \| QueryRenderedFeaturesOptions, options?): MapGeoJSONFeature[]` | `-visibleFeaturesInRect:inStyleLayersWithIdentifiers:predicate:` (MLNMapView.h:2253) | `Renderer::queryRenderedFeatures(const ScreenBox&, const RenderedQueryOptions&)` (include/mbgl/renderer/renderer.hpp:60) | controller-namespace | no |
| P1 | `querySourceFeatures` | none | `querySourceFeatures(sourceId: string, options?: QuerySourceFeatureOptions): GeoJSONFeature[]` | `-[MLNShapeSource featuresMatchingPredicate:]` (MLNShapeSource.h:392) and `-[MLNVectorTileSource featuresInSourceLayersWithIdentifiers:predicate:]` (MLNVectorTileSource.h:200) | `Renderer::querySourceFeatures(const std::string& sourceID, const SourceQueryOptions&)` (include/mbgl/renderer/renderer.hpp:61); `SourceQueryOptions {sourceLayers, filter}` (include/mbgl/renderer/query.hpp:30-41) | controller-namespace | yes |
| P1 | `source` / `sourceLayer` / `state` on query results | none | `MapGeoJSONFeature.source`, `.sourceLayer`, `.state` | — (MLNFeature exposes neither source nor state) | `mbgl::Feature::source`, `::sourceLayer`, `::state` (include/mbgl/util/feature.hpp:22-24) — **present in core, discarded by our shim** | value-type | yes |
| P1 | `sourcedata` / source changed | none | `map.on('sourcedata', …)` → `MapSourceDataEvent` (sourceId, isSourceLoaded, sourceDataType, tile) | `-mapView:sourceDidChange:` (MLNMapViewDelegate.h:329) | `MapObserver::onSourceChanged(style::Source&)` (include/mbgl/map/map_observer.hpp:65) — carries only the source, NOT gl-js's dataType/tile detail | controller-namespace | yes |
| P1 | `styleimagemissing` | none | `map.on('styleimagemissing', (e) => { e.id })` — the documented hook for lazily registering an icon | `-mapView:didFailToLoadImage:` returning a `UIImage` (MLNMapViewDelegate.h:339) — Apple makes it a SYNCHRONOUS provider, not a notification | `MapObserver::onStyleImageMissing(const std::string&)` (include/mbgl/map/map_observer.hpp:67) | controller-namespace | yes |
| P2 | Rect ⇄ bounds conversion, and metres-per-pixel | none | — (compose two unproject calls; no rect helper) | `-convertRect:toCoordinateBoundsFromView:` (MLNMapView.h:1727); `-convertCoordinateBounds:toRectToView:` (MLNMapView.h:1744); `-metersPerPointAtLatitude:` (MLNMapView.h:1758); `MLNMapProjection.metersPerPoint` (MLNMapProjection.h:71) | derivable from `pixelsForLatLngs`/`latLngsForPixels` (include/mbgl/map/map.hpp:121-122) + `Projection::getMetersPerPixelAtLatitude` in mbgl/util | capability-interface | no |
| P2 | Renderer error (`onRenderError`) | none | folded into `map.on('error')` | `-mapViewRendererDidError:` (MLNMapViewDelegate.h:515) — note it passes NO error object, only the map view | `MapObserver::onRenderError(std::exception_ptr)` (include/mbgl/map/map_observer.hpp:94) | controller-namespace | yes |
| P2 | Tile-load events (`onTileAction`) | none | — (partially covered by `sourcedata`/`dataloading` with a `tile` field) | `-mapView:tileDidTriggerAction:x:y:z:wrap:overscaledZ:sourceID:` (MLNMapViewDelegate.h:462) with `MLNTileOperation` (MLNTileOperation.h:3-13) | `MapObserver::onTileAction(TileOperation, const OverscaledTileID&, const std::string&)` (include/mbgl/map/map_observer.hpp:86); `enum class TileOperation` (include/mbgl/tile/tile_operation.hpp:5-15): RequestedFromCache/RequestedFromNetwork/LoadFromNetwork/LoadFromCache/StartParse/EndParse/Error/Cancelled/NullOp | controller-namespace | yes |
| P2 | `dblclick` / double-tap | none | `map.on('dblclick', (e: MapMouseEvent) => …)` | — (gesture only: `MLNCameraChangeReasonGestureZoomIn`, MLNCameraChangeReason.h:51) | NOT IN CORE | widget-callback | no |
| P2 | `dragstart` / `drag` / `dragend` | none | `map.on('dragstart'\|'drag'\|'dragend', …)` → `MapMovementEvent` | `MLNCameraChangeReasonGesturePan` (MLNCameraChangeReason.h:42) | `Map::isPanning()` (include/mbgl/map/map.hpp:69) | widget-callback | no |
| P2 | `isMoving` / `isZooming` / `isRotating` | none | `map.isMoving(): boolean`, `map.isZooming(): boolean`, `map.isRotating(): boolean` | not exposed as booleans (inferred from the region-change delegate pair) | `Map::isGestureInProgress()` (include/mbgl/map/map.hpp:66), `Map::isRotating()` (:67), `Map::isScaling()` (:68), `Map::isPanning()` (:69) — **all four already public in core** | controller | yes |
| P2 | `load` / map-ready signal | present | `map.on('load', …)`; `map.loaded(): boolean` | `-mapViewDidFinishLoadingMap:` (MLNMapViewDelegate.h:206) | `MapObserver::onDidFinishLoadingMap()` (include/mbgl/map/map_observer.hpp:58) | controller | no |
| P2 | `pitchstart` / `pitch` / `pitchend` | none | `map.on('pitchstart'\|'pitch'\|'pitchend', …)` | `MLNCameraChangeReasonGestureTilt` (MLNCameraChangeReason.h:61) | no `isPitching()`; pitch changes flow through the same camera observer (include/mbgl/map/map_observer.hpp:54-56) | widget-callback | no |
| P2 | `render` — a frame was drawn (+ fullyRendered) | internal-only | `map.on('render', …)` | `-mapViewWillStartRenderingFrame:` (MLNMapViewDelegate.h:238), `-mapViewDidFinishRenderingFrame:fullyRendered:` (:252), `…frameEncodingTime:frameRenderingTime:` (:267), `…renderingStats:` (:284) | `MapObserver::onWillStartRenderingFrame()` (include/mbgl/map/map_observer.hpp:60); `onDidFinishRenderingFrame(const RenderFrameStatus&)` (:61) with `RenderFrameStatus {RenderMode mode; bool needsRepaint; bool placementChanged; gfx::RenderingStats renderingStats;}` (:47-52) | controller-namespace | yes |
| P2 | `renderedFrameCount` is filed under the wrong capability | present | — (no frame counter) | `MLNRenderingStats.numFrames` (MLNRenderingStats.h:15) | `gfx::RenderingStats` via `MapObserver::onDidFinishRenderingFrame` (include/mbgl/map/map_observer.hpp:51); our shim exposes `mbl_map_frame_count` (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:428) | controller | no |
| P2 | `rotatestart` / `rotate` / `rotateend` | none | `map.on('rotatestart'\|'rotate'\|'rotateend', …)` | `MLNCameraChangeReasonGestureRotate` (MLNCameraChangeReason.h:48) on the regionIsChangingWithReason: family | `Map::isRotating()` (include/mbgl/map/map.hpp:67) | widget-callback | no |
| P2 | `styledataloading` / will-start-loading-map | none | `map.on('styledataloading', …)` | `-mapViewWillStartLoadingMap:` (MLNMapViewDelegate.h:196) | `MapObserver::onWillStartLoadingMap()` (include/mbgl/map/map_observer.hpp:57) | controller-namespace | yes |
| P2 | `triggerRepaint` | internal-only | `map.triggerRepaint(): void`; `map.redraw(): this` | `-[MLNMapView triggerRepaint]` (MLNMapView.h:2318) | `Map::triggerRepaint()` (include/mbgl/map/map.hpp:56) | controller | no |
| P2 | `zoomstart` / `zoom` / `zoomend` | none | `map.on('zoomstart'\|'zoom'\|'zoomend', …)` | — (folded into regionIsChangingWithReason: + MLNCameraChangeReasonGesturePinch, MLNCameraChangeReason.h:45) | `Map::isScaling()` (include/mbgl/map/map.hpp:68); no discrete event | widget-callback | no |
| P3 | Action journal — persistent rolling event log | none | — | `-getActionJournalLogFiles` (MLNMapView.h:2284), `-getActionJournalLog` (MLNMapView.h:2306), `-clearActionJournalLog` (MLNMapView.h:2311); configured by `MLNActionJournalOptions.h` | `util::ActionJournal` (include/mbgl/util/action_journal.hpp:34-65 — `getLogDirectory`, `getLogFiles`, `getLog`, `clearLog`) with `ActionJournalOptions` (include/mbgl/util/action_journal_options.hpp); wired through the `Map` constructor (include/mbgl/map/map.hpp:46) and `Map::getActionJournal()` (:210) | controller-namespace | yes |
| P3 | Debug overlays — `setDebug` / `debugMask` / rendering-stats view | none | `map.showTileBoundaries`, `.showCollisionBoxes`, `.showPadding` (properties, not methods) *(unverified)* | `MLNMapView.debugMask` (`MLNMapDebugMaskOptions`) (MLNMapView.h:2267); `-isRenderingStatsViewEnabled` (:2272) / `-enableRenderingStatsView:` (:2277) | `Map::setDebug(MapDebugOptions)` / `getDebug()` (include/mbgl/map/map.hpp:147-148); `isRenderingStatsViewEnabled()` / `enableRenderingStatsView(bool)` (:150-151) | widget-prop | yes |
| P3 | Glyph request events (loaded / error / requested) | none | — | `-mapView:glyphsWillLoad:range:` (MLNMapViewDelegate.h:413), `glyphsDidLoad:range:` (:426), `glyphsDidError:range:` (:439) | `MapObserver::onGlyphsLoaded/onGlyphsError/onGlyphsRequested(const FontStack&, const GlyphRange&, …)` (include/mbgl/map/map_observer.hpp:81-83) | controller-namespace | yes |
| P3 | Native fling (`OnFlingListener`) and gesture-detail listeners (Rotate/Scale/Shove begin/·/end) | none | — | — (`-anchorPointForGesture:` (MLNMapView.h:1587) is the only gesture hook) | NOT IN CORE | widget-callback | no |
| P3 | Shader compilation events | none | — | `-mapView:shaderWillCompile:backend:defines:` (MLNMapViewDelegate.h:367), `shaderDidCompile:…` (:382), `shaderDidFailCompile:…` (:397) — all flagged "not thread-safe" | `MapObserver::onPreCompileShader/onPostCompileShader/onShaderCompileFailed(shaders::BuiltIn, gfx::Backend::Type, const std::string&)` (include/mbgl/map/map_observer.hpp:76-78) | controller-namespace | yes |
| P3 | Sprite request events (loaded / error / requested) | none | — (folded into `data`/`error`) | `-mapView:spriteWillLoad:url:` (MLNMapViewDelegate.h:482), `spriteDidLoad:url:` (:493), `spriteDidError:url:` (:504) | `MapObserver::onSpriteLoaded/onSpriteError/onSpriteRequested(const std::optional<style::Sprite>&, …)` (include/mbgl/map/map_observer.hpp:89-91) | controller-namespace | yes |
| P3 | `data` / `dataloading` / `dataabort` / `sourcedataloading` / `sourcedataabort` | none | `map.on('data'\|'dataloading'\|'dataabort'\|'sourcedataloading'\|'sourcedataabort', …)` | — | NOT IN CORE — the closest is `MapObserver::onTileAction(TileOperation, OverscaledTileID, sourceID)` (include/mbgl/map/map_observer.hpp:86), which is per-TILE, not the aggregate data pipeline gl-js models | reject | no |
| P3 | `getPlacedSymbolsData` — label placement/collision introspection | none | — | — | `Renderer::collectPlacedSymbolData(bool)` (include/mbgl/renderer/renderer.hpp:98) and `getPlacedSymbolsData()` (:108) returning `std::vector<PlacedSymbolData>` (:24-41) with text/icon collision boxes and placed flags — **Tile map mode only** | controller-namespace | yes |
| P3 | `mapViewWillStartRenderingMap` / `mapViewDidFinishRenderingMap:fullyRendered:` | none | — (gl-js has no map-scoped render pair; `load` + `idle` cover it) | `-mapViewWillStartRenderingMap:` (MLNMapViewDelegate.h:222), `-mapViewDidFinishRenderingMap:fullyRendered:` (MLNMapViewDelegate.h:225) | `MapObserver::onWillStartRenderingMap()` (include/mbgl/map/map_observer.hpp:62), `onDidFinishRenderingMap(RenderMode)` (:63) | controller-namespace | yes |
| P3 | `mousedown` / `mouseup` / `wheel` / `touchstart` / `touchmove` / `touchend` / `touchcancel` | none | `map.on('mousedown'\|'mouseup'\|'wheel'\|'touchstart'\|'touchmove'\|'touchend'\|'touchcancel', …)` | — | NOT IN CORE | reject | no |
| P3 | `onCanRemoveUnusedStyleImage` / `shouldRemoveStyleImage:` | none | — | `-mapView:shouldRemoveStyleImage:` (MLNMapViewDelegate.h:353) | `MapObserver::onCanRemoveUnusedStyleImage(const std::string&) -> bool` (include/mbgl/map/map_observer.hpp:70) | reject | yes |
| P3 | `project` / `unproject` | present | `map.project(lngLat: LngLatLike): Point`; `map.unproject(point: PointLike): LngLat` | `-convertCoordinate:toPointToView:` (MLNMapView.h:1712); `-convertPoint:toCoordinateFromView:` (MLNMapView.h:1695); also the snapshot-style `MLNMapProjection` (MLNMapProjection.h:57, :66) | `Map::pixelForLatLng` / `latLngForPixel` / `pixelsForLatLngs` / `latLngsForPixels` (include/mbgl/map/map.hpp:119-122) | capability-interface | no |
| P3 | `projectiontransition`, `roll`/`rollstart`/`rollend`, `cooperativegestureprevented`, `boxzoom*` | none | `map.on('projectiontransition'\|'roll'\|'rollstart'\|'rollend'\|'cooperativegestureprevented'\|'boxzoomstart'\|'boxzoomend'\|'boxzoomcancel', …)` | — | NOT IN CORE — no globe/mercator transition, no camera roll axis (`CameraOptions` is centre/zoom/bearing/pitch only, include/mbgl/map/camera.hpp), no cooperative-gesture or box-zoom handler (mbgl has no input layer) | reject | no |
| P3 | `remove` — map destroyed | none | `map.on('remove', …)` | — | NOT IN CORE (destruction is synchronous; `mbl_map_destroy` at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:468) | reject | no |
| P3 | `resize` | none | `map.on('resize', …)` | — (UIView layout) | NOT IN CORE as an event (`Map::setSize`, include/mbgl/map/map.hpp:109) | reject | no |
| P3 | `shouldChangeFromCamera:toCamera:reason:` (veto a gesture) | none | — (nearest is `MapMouseEvent.preventDefault()`) | `-mapView:shouldChangeFromCamera:toCamera:` (MLNMapViewDelegate.h:51) and `…reason:` (MLNMapViewDelegate.h:81) — the documented way to restrict panning to a region | `Map::setBounds(BoundOptions)` (include/mbgl/map/map.hpp:98) / `getBounds()` (:101) — the DECLARATIVE form of the same restriction | widget-prop | yes |
| P3 | `terrain` event / `queryTerrainElevation` / `getCameraTargetElevation` | none | `map.on('terrain', …)`; `map.queryTerrainElevation(lngLat: LngLatLike): number \| null` | — | NOT IN CORE — a full grep of include/mbgl for terrain finds only `shaders/{gl,mtl,vulkan}/color_relief.hpp`; there is no terrain source, no `Map::queryTerrainElevation`, no elevation in TransformState | reject | no |
| P3 | `validate` / `availableImages` query options | none | `QueryRenderedFeaturesOptions.validate?: boolean`, `.availableImages?: string[]` | — | NOT IN CORE — `RenderedQueryOptions` has exactly two fields, layerIDs and filter (include/mbgl/renderer/query.hpp:14-25) | reject | no |
| P3 | `webglcontextlost` / `webglcontextrestored` | none | `map.on('webglcontextlost'\|'webglcontextrestored', …)` | — | `Renderer::markContextLost()` (include/mbgl/renderer/renderer.hpp:50) — a COMMAND in, no observer out | controller-namespace | yes |

#### Proposed signatures

**Feature `id` in query results** — P0, `value-type`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:218-231 — the parser reads `geometry` and `properties` and never looks at `feature['id']`, even though the shim DOES emit it (vendor/maplibre-native-base/deps/geojson.hpp/include/mapbox/geojson_impl.hpp:463 writes "id" when non-null)
```dart
final Object? id; // int or String, per the vector-tile spec
```
> **Pure Dart-side loss — the data is already in the JSON string we parse and throw away.** Cheapest p0 in this document (about five lines in map_layers_controller.dart). Without it there is no stable feature identity, so setFeatureState/hover-highlight/selection are all impossible on top of our query.

**LatLngBounds value type** — P0, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/lat_lng.dart (only LatLng exists; this is where it would live)
```dart
@immutable class LatLngBounds { const LatLngBounds({required LatLng southwest, required LatLng northeast}); factory LatLngBounds.fromPoints(Iterable<LatLng> points); final LatLng southwest; final LatLng northeast; LatLng get center; bool contains(LatLng point); LatLngBounds extend(LatLng point); bool get isEmpty; }
```
> Blocking prerequisite for getBounds, fitBounds, cameraForBounds, setMaxBounds and the bbox query overload — four domains are stuck behind this one 40-line type. Spelled LatLng-first to match our LatLng(lat,lng), deliberately unlike gl-js's LngLatBounds.

**MapGeometry — sealed GeoJSON geometry type** — P0, `value-type`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:215 — `if (geometry['type'] != 'Point') continue;` silently discards every LineString, Polygon, Multi* and GeometryCollection
```dart
sealed class MapGeometry { const MapGeometry(); factory MapGeometry.fromJson(Map<String, Object?> json); Map<String, Object?> toJson(); } final class PointGeometry extends MapGeometry { final LatLng coordinates; } final class LineStringGeometry extends MapGeometry { final List<LatLng> coordinates; } final class PolygonGeometry extends MapGeometry { final List<List<LatLng>> coordinates; } // + MultiPoint/MultiLineString/MultiPolygon/GeometryCollection
```
> This is a real defect, not just a gap: querying a fill or line layer today returns an EMPTY list with no error. Sealed so `switch` is exhaustive. Every constructor flips [lng,lat] → LatLng(lat,lng) at the boundary (CLAUDE.md §11) and that flip must be tested against an asymmetric fixture, not a round trip.

**MapLibreError + error severity/kind** — P0, `value-type`, evidence: no error channel exists anywhere — grep for onError/MapLibreError across packages/*/lib finds only script-tag loader handlers (maplibre_gl_loader.dart:48, core_wasm_loader.dart:86). The shim swallows query failures to stderr (maplibre_flutter_core.cpp:1756-1760)
```dart
@immutable class MapLibreError { const MapLibreError({required this.kind, required this.message, this.severity = MapLibreErrorSeverity.error, this.sourceId, this.url}); final MapLibreErrorKind kind; /* styleParse, styleLoad, notFound, network, render, unknown */ final String message; final MapLibreErrorSeverity severity; final String? sourceId; final String? url; }
```
> The single largest usability hole in the package: a bad style URL, a 404 tile server or a glyph 404 storm is TODAY completely invisible to Dart — the map just stays blank. mbgl gives two feeds: the per-map MapObserver, and the process-global Log::Observer, which is where 404s and parse warnings actually surface. Bind both; route Log::Observer records through the same type with a `severity`.

**MapLibreFeature — the query result type** — P0, `value-type`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:15-35 (`MapLibreQueriedFeature` carries only `point` + `properties`)
```dart
@immutable class MapLibreFeature { const MapLibreFeature({this.id, required this.geometry, this.properties = const {}, this.layerId, this.source, this.sourceLayer, this.state = const {}}); final Object? id; final MapGeometry geometry; final Map<String, Object?> properties; final String? layerId; final String? source; final String? sourceLayer; final Map<String, Object?> state; bool get isCluster; int get pointCount; int? get clusterId; }
```
> Replaces MapLibreQueriedFeature (keep the old name as a deprecated typedef exposing `point` = geometry-as-point for one release). `properties` is the GeoJSON/gl-js word, not Apple's `attributes`. `state` and `source`/`sourceLayer` need shim work: the shim builds a `feature_collection<double>` from `std::vector<Feature>`, which SLICES those three fields off before `mapbox::geojson::stringify` (maplibre_flutter_core.cpp:1751-1754).

**MapLibreMapEvent hierarchy + tap/pointer event payload** — P0, `value-type`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:71 — `final ValueChanged<LatLng>? onTap;` (a bare LatLng, no wrapper)
```dart
@immutable class MapLibreTapEvent { const MapLibreTapEvent({required this.point, required this.position, this.features = const []}); final LatLng point; final Offset position; /* logical px, top-left, same space as MapLibreMapProjector */ final List<MapLibreFeature> features; }
```
> gl-js's MapMouseEvent shape, minus the DOM bits. `position` is the field the current API throws away — without it a caller cannot place a popup, run its own hit-test, or call queryRenderedFeaturesAt. `features` is populated only for the layer-scoped callbacks (see the layer-scoped click row); leaving it empty for the plain map tap avoids a query on every tap.

**MapLibreMapObserver — the capability interface that carries every event** — P0, `capability-interface`, evidence: packages/maplibre_flutter_platform_interface/lib/src/ — there is no observer file; the exports list (maplibre_flutter_platform_interface.dart:4-15) has camera/fly/gesture/latlng/platform/controller/options/model_host/projector/render_handle/rotate/style_layers and nothing else
```dart
// packages/maplibre_flutter_platform_interface/lib/src/map_observer.dart
abstract interface class MapLibreMapObserver { Stream<MapLibreMapEvent> get mapEvents; }
// sealed event hierarchy: MapStyleLoadedEvent, MapIdleEvent, MapSourceDataEvent, MapStyleImageMissingEvent, MapErrorEvent, MapRenderFrameEvent, MapTileEvent, MapSpriteEvent, MapGlyphEvent, MapShaderEvent, MapRemovedEvent
```
> ONE capability, ONE C ABI callback, ONE sealed event type — not 25 interface members and not 25 native callbacks. Feature-detected with `is`, exactly like MapLibreStyleLayers/MapLibreModelHost, so the gl-js opt-in tier and any future SDK tier can skip it. The app-facing `controller.events` namespace (next row) is a pure Dart wrapper that filters this one stream into typed streams, so it does not ripple into the five impls. C ABI: `mbl_map_set_event_callback(map, MblEventCallback, void* user)` delivering `(kind, json)`; must be marshalled to Dart via a NativeCallable.listener + SendPort, NOT called on the UI isolate from the render thread.

**Non-Point geometry in query results** — P0, `value-type`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:215 — `if (geometry == null || geometry['type'] != 'Point') continue;`
```dart
final MapGeometry geometry; // sealed; see the MapGeometry row
```
> **Silent wrong-answer bug, not a gap.** Query a fill or line layer today and you get `[]` with no error and no log — indistinguishable from 'nothing there'. Whoever fixes this should add a test with a Polygon fixture; a Point-only fixture will keep passing forever.

**`click` — map tap reports the screen point** — P0, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:71 (`ValueChanged<LatLng>? onTap`) and :285-292 — `onTapUp: (details) { final point = projector.unproject(details.localPosition); if (point != null) onTap(point); }`: `details.localPosition` is computed and then **discarded**
```dart
final void Function(MapLibreTapEvent event)? onTap; // was ValueChanged<LatLng>
```
> A one-line fix with an outsized payoff: without `position` a caller cannot anchor a popup at the tap, cannot run their own queryRenderedFeaturesAt, and cannot implement selection. This is a BREAKING signature change — do it now, pre-1.0, not after. gl-js's event object is the model; Android's bare-LatLng shape is the mistake we currently copy.

**`error` event / diagnostic channel** — P0, `controller-namespace`, evidence: no public error surface anywhere; the shim prints query failures to stderr (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1756-1760) and logs style-application errors on the render thread rather than returning them (documented at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:177-179)
```dart
Stream<MapLibreError> get errors; // controller.events.errors
```
> Bind BOTH feeds. `onDidFailLoadingMap` catches the fatal case (bad style URL, 404 style, parse error) and maps 1:1 onto MapLibreErrorKind via mbgl's MapLoadError enum. `Log::Observer` catches the sub-resource case — 404 glyph ranges, tile server 403s, sprite failures — which is where real deployments actually break and which no other hook reports. Log::Observer is PROCESS-GLOBAL (a static), so the shim must own exactly one and fan out to live maps; installing it per-map will fight itself.

**`queryRenderedFeatures` — point form** — P0, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78-84 takes only minX/minY/maxX/maxY; callers fake a point with a tiny Rect
```dart
Future<List<MapLibreFeature>> queryRenderedFeaturesAt(Offset point, {List<String>? layers, Expression? filter, double tolerance = 8, Duration timeout = const Duration(milliseconds: 200)});
```
> p0 because it is the prerequisite for the layer-scoped tap callback, i.e. the whole 'click a feature' story. mbgl's point overload has different (tighter) semantics than a 1px box, so call the real one rather than synthesizing a Rect. `tolerance` (expand the point to a box of 2×tolerance) is OUR addition for finger-sized targets — neither gl-js nor Apple has it; flag it in the dartdoc as a Flutter affordance.

**`style.load` / `styledata` — style finished loading** — P0, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:890-899 — `FrameObserver::onDidFinishLoadingStyle()` exists and is used to re-apply transitions and re-add models, but nothing is surfaced to Dart
```dart
Stream<void> get styleLoaded; // controller.events.styleLoaded
bool get isStyleLoaded;      // controller.isStyleLoaded, gl-js name
```
> p0 because CLAUDE.md §11 already states the rule this event exists to serve: "Loading a style overwrites style-level state … Re-apply from onDidFinishLoadingStyle." Right now the ENGINE obeys that rule and app code cannot: an app that calls `layers.addLayer` and then changes `MapLibreMap.style` silently loses every layer with no signal that it happened. The observer is one override away — FrameObserver already implements it.

**controller.events namespace** — P0, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:54-60 — only `camera` and `layers` namespaces exist
```dart
class MapLibreEventsController { bool get isSupported; Stream<void> get styleLoaded; Stream<void> get idle; Stream<MapLibreError> get errors; Stream<MapSourceDataEvent> get sourceData; Stream<String> get styleImageMissing; Stream<MapRenderFrameEvent> get renderFrames; Stream<MapTileEvent> get tileActions; Stream<MapSpriteEvent> get spriteEvents; Stream<MapGlyphEvent> get glyphEvents; }
// reached as `controller.events`
```
> Third bucket (imperative/subscription, large surface) → namespace, matching `camera` and `layers`. Broadcast streams so multiple widgets can listen; every stream must be closed in MapLibreMapController.dispose (packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:96-104). The GC pitfall in CLAUDE.md §5e applies to the NativeCallable behind this — hold a field reference, clear on dispose, and TEST it.

**Cluster expansion — `getClusterExpansionZoom` / `getClusterChildren` / `getClusterLeaves`** — P1, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:27-30 exposes `isCluster`/`pointCount` but nothing can expand a cluster; the example just re-renders (example/lib/main.dart:1514)
```dart
Future<double> getClusterExpansionZoom(String sourceId, int clusterId);
Future<List<MapLibreFeature>> getClusterChildren(String sourceId, int clusterId);
Future<List<MapLibreFeature>> getClusterLeaves(String sourceId, int clusterId, {int limit = 10, int offset = 0});
```
> This is the missing half of the clustering story we already sell: `layers.addPoints(cluster: true)` draws clusters, `queryRenderedFeatures` finds them, and then there is no way to answer the one thing a user does next — tap a cluster to zoom to where it splits. All three take gl-js's names (Apple's `zoomLevelForExpandingCluster:` is the same call, worse named). Note upstream issue maplibre-native#3519: these throw from native when the cluster id is unknown, so the shim must validate rather than propagate a C++ exception across `extern "C"` (UB, per CLAUDE.md §11).

**Layer identity (`feature.layer.id`) on query results** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:218-231 builds MapLibreQueriedFeature from geometry+properties only; nothing upstream carries a layer id either
```dart
final String? layerId; // on MapLibreFeature; non-null only when the query restricted `layers:`
```
> **Documented ceiling with a documented workaround.** gl-js can do this; mbgl and both native SDKs cannot. Workaround inside the shim: when `layers:` is supplied, run one query per layer id and tag each batch, then concatenate in the layer order given (which also preserves gl-js's z-order-ish contract loosely). Cost is N render-thread round trips, so keep it to the restricted case and leave `layerId` null for an unrestricted query rather than lying. Alternative (better, slower to land): an upstream mbgl PR adding a `queryRenderedFeaturesByLayer` overload that returns the map it already built.

**Layer-scoped click — `map.on('click', layerId, fn)`** — P1, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:285-292 — one global tap handler, no layer awareness. An app must call `layers.queryRenderedFeatures(Rect.fromCenter(...))` itself (as example/lib/main.dart:696 does).
```dart
final Map<String, void Function(MapLibreTapEvent)>? onLayerTap; // keys are layer ids; event.features is pre-filled and layer-restricted
```
> gl-js's layer-scoped `on` is the single most-used pattern in every MapLibre tutorial ("click a marker, show a popup"), and it is the reason our current tap API feels unfinished. Depends on the point-query (`queryRenderedFeaturesAt`) row. A `Map<layerId, callback>` widget prop is the Dart-idiom adaptation of gl-js's overloaded `on`; alternative is `onLayerTap: (layerId, event)` with a `tapLayers: List<String>` prop — pick one and state it, do not ship both.

**MapLibreCameraChangeReason** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:75-82 (`onCameraChanged` is a bare Listenable — no payload at all)
```dart
enum MapLibreCameraChangeReason { programmatic, resetNorth, gesturePan, gesturePinch, gestureRotate, gestureZoomIn, gestureZoomOut, gestureOneFingerZoom, gestureTilt, transitionCancelled } // carried as Set<MapLibreCameraChangeReason> — pinch+rotate co-occur, exactly as MLNCameraChangeReason.h:13-15 warns
```
> Apple's bitmask wins over Android's 3 constants because it is strictly richer and is the SDK built on the engine we ship. Needs NO C ABI: every gesture on the five native tiers is recognized in our own Dart layer (maplibre_map.dart), so the reason is already known there. Dart Set instead of a bitfield int — a Dart-idiom adaptation of an NS_OPTIONS.

**Native long-press (`OnMapLongClickListener`)** — P1, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:285-292
```dart
final void Function(MapLibreTapEvent event)? onLongPress; // same callback as the contextmenu row
```
> The single most-requested missing map callback in every Flutter map plugin's issue tracker ("long-press to drop a pin"). Purely widget-side; no C ABI, no interface change. Should be an early win.

**Query off the UI isolate** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:758-787 is synchronous and blocks the calling isolate on a condition_variable wait (maplibre_flutter_core.cpp:1769-1774)
```dart
Future<List<MapLibreFeature>> queryRenderedFeatures(...); // helper isolate, per CLAUDE.md §5a
```
> CLAUDE.md §5a is explicit: "Long-running calls belong on a helper isolate, not the UI isolate, or they drop frames." A 200 ms worst-case blocking call on the UI isolate is 12 dropped frames. The JSON parse is also non-trivial for a large result and should move with it. Keep the sync variant for the existing per-tick overlay path, but stop making the blocking form the default one people reach for.

**Query timeout is dropped by the platform interface** — P1, `capability-interface`, evidence: packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:758-765 has `Duration timeout = const Duration(milliseconds: 200)`; packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78-84 has no timeout parameter, and every controller (e.g. packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:351-365) calls the core with the default
```dart
String? queryRenderedFeaturesJson(..., {List<String>? layers, String? filterJson, Duration timeout}); // add the parameter to MapLibreStyleLayers
```
> A caller running a big query while tiles stream in gets a silent `null` (→ empty list, map_layers_controller.dart:207) after 200 ms with no way to ask for more time and no way to distinguish 'timed out' from 'nothing found'. Widen the interface AND make the timeout distinguishable — return a sentinel or throw a TimeoutException rather than an empty list, because 'no features' and 'we gave up' lead to opposite app behaviour.

**`areTilesLoaded` / `loaded()` / `isFullyLoaded`** — P1, `controller`, evidence: the nearest thing is `awaitFrame` in the core wrapper (packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:605), which is not on the platform interface
```dart
Future<bool> get isFullyLoaded; // mbgl's name; document that it is gl-js's loaded() + areTilesLoaded() combined
```
> Kept mbgl's name rather than gl-js's `loaded()`, which is too vague in Dart next to `onReady` and `isStyleLoaded`. This is the boolean form of `idle`; ship both, because tests want the boolean (poll-and-assert) and apps want the event. Directly serves CLAUDE.md §7's rule that 'a frame came back' does not prove the map is visible.

**`contextmenu` / secondary tap** — P1, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:285-292; the secondary button is currently consumed by the drag-rotate recognizer (FEATURE_MATRIX.md:377)
```dart
final void Function(MapLibreTapEvent event)? onSecondaryTap; // desktop right-click
final void Function(MapLibreTapEvent event)? onLongPress;    // touch long-press
```
> Two callbacks, not one, because they are genuinely different inputs and Flutter runs on both kinds of device. Care needed: the secondary button already drives drag-rotate on the desktop tier, so onSecondaryTap must lose the arena to a drag that actually moves — test that, it is exactly the kind of gesture-arena interaction that escapes review.

**`getBounds` — visible coordinate bounds** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:25 offers only `getCamera()`; packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:297-304 wraps it
```dart
Future<LatLngBounds> getBounds(); // controller.camera.getBounds()
```
> Table stakes — 'load the data for what the user is looking at' is the most common map app loop and is impossible today without hand-unprojecting the four corners. Note mbgl has BOTH wrapped and unwrapped forms; expose `unwrapped: false` as a named parameter rather than picking one silently, because the difference bites exactly at the antimeridian, which is where nobody tests. Depends on the LatLngBounds value type.

**`getFeatureState` (and the set/remove pair)** — P1, `controller-namespace`, evidence: no feature-state anywhere in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
Future<Map<String, Object?>> getFeatureState({required String source, String? sourceLayer, required String featureId});
```
> Listed here because it is a READ query and because it is the other half of the hover story (mouseenter → setFeatureState({hover:true}) → `['feature-state','hover']` in paint). The set/remove half belongs to the data-driven-styling domain — flagging the overlap so it does not get specced twice or, worse, zero times. Another gl-js-is-right case: mbgl backs all three and NEITHER native SDK exposes them.

**`idle` — no more drawing until something changes** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903
```dart
Stream<void> get idle; // controller.events.idle
```
> Table stakes: this is the signal integration tests and screenshot/snapshot code need ("the map has settled, now assert"), and the one every competing plugin exposes. It is also the correct trigger for re-running queryRenderedFeatures instead of the current camera-tick polling in the example (example/lib/main.dart:696).

**`isSourceLoaded`** — P1, `controller-namespace`, evidence: no equivalent in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
Future<bool> isSourceLoaded(String sourceId); // controller.layers.isSourceLoaded
```
> gl-js's name; the engine field is right there and neither native SDK bothered to expose it, so this is a case where gl-js is simply the better API and mbgl can back it. Pairs with `sourceData` to answer 'has my setGeoJsonData landed yet'.

**`isStyleLoaded`** — P1, `controller`, evidence: no equivalent; `onReady` (packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:22) is a first-frame future, not a style flag
```dart
bool get isStyleLoaded; // synchronous; latched by the observer, cleared on setStyle
```
> Synchronous (a latched bool, not a Future) so it can be read from build(). Latch on onDidFinishLoadingStyle and clear in the setStyle path — that also gives the widget a correct answer across a declarative style change, which is precisely when app code most needs it.

**`mousemove` / hover + per-layer `mouseenter` / `mouseleave` / `mouseover` / `mouseout`** — P1, `widget-prop`, evidence: no MouseRegion anywhere in packages/maplibre_flutter/lib/src/maplibre_map.dart
```dart
final void Function(MapLibreTapEvent event)? onHover;
final Map<String, MapLibreLayerHoverCallbacks>? onLayerHover; // {onEnter, onLeave} per layer id
```
> The classic MapLibre hover-highlight recipe is `mouseenter` + `setFeatureState({hover: true})`; both halves are missing (feature-state is domain 3). Implementation: MouseRegion → throttled queryRenderedFeaturesAt → diff the feature-id set against the previous frame to synthesize enter/leave. Throttling is mandatory — a query per mouse-move pixel is a render-thread round trip per pixel.

**`movestart` / `move` / `moveend`** — P1, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:75-82 (`onCameraChanged` — a bare `Listenable` with no payload and no start/end distinction), fed by `MapLibreCameraTickNotifier` (packages/maplibre_flutter_platform_interface/lib/src/projector.dart:50-66)
```dart
// MapLibreMap widget props (bucket 2), mirroring google_maps_flutter and our existing onTap:
final void Function(Set<MapLibreCameraChangeReason> reason)? onCameraMoveStarted;
final void Function(MapCamera camera)? onCameraMove;
final VoidCallback? onCameraIdle;
```
> Deliberately NOT a C ABI change: gestures and animations are already driven in Dart on all five native tiers (CLAUDE.md §3), so start/end boundaries are known in the widget's own gesture layer. That also gives the reason for free. `onCameraIdle` here is the CAMERA-settled signal (Android's naming); `controller.events.idle` is the ENGINE-settled signal (mbgl onDidBecomeIdle) — they are different and both should exist, so name them apart and document the difference.

**`on` / `off` / `once` / `listens` — the subscription API itself** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_web_gljs/lib/src/maplibre_gl_interop.dart:49 (`on`) and :52 (`off`) exist as JS interop and are used internally at maplibre_flutter_web_controller.dart:73 and :156 only
```dart
// adapted, not bound: Stream subscription IS the API.
// on   -> stream.listen(...)
// off  -> subscription.cancel()
// once -> await stream.first
// listens -> stream.hasListener (broadcast streams)
```
> State this mapping explicitly in the dartdoc of `controller.events` so someone porting gl-js code finds it. Do NOT ship a literal `on(String type, Function fn)` — a stringly-typed event API in Dart throws away the exhaustiveness checking that makes the sealed event hierarchy worth having, and it is the single easiest place to accidentally import JS idiom wholesale.

**`queryRenderedFeatures` — `filter` option** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1749 constructs `mbgl::RenderedQueryOptions(layers)` with the filter left `std::nullopt`
```dart
// `Expression? filter` parameter on both query methods above; serialised to spec JSON and parsed by the shim with convertJSON<style::Filter>
```
> Take gl-js/Android's expression filter, not Apple's NSPredicate — we already generate all 84 spec operators as `Expr`, and mbgl's field is literally a `style::Filter`. Parse the JSON SYNCHRONOUSLY on the calling thread and return an error, per the rule already established for addLayerJson (maplibre_flutter_core.h:174-179); a bad filter must not vanish into a log.

**`queryRenderedFeatures` — bbox form** — P1, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:196-238 (public), packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78-84 (interface), packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:758-787 (core wrapper), packages/maplibre_flutter_core/src/maplibre_flutter_core.h:246-248 + .cpp:1702-1780 (shim)
```dart
Future<List<MapLibreFeature>> queryRenderedFeatures({Rect? area, List<String>? layers, Expression? filter, Duration timeout = const Duration(milliseconds: 200)});
List<MapLibreFeature> queryRenderedFeaturesSync({Rect? area, List<String>? layers, Expression? filter, Duration timeout});
```
> `area: null` = whole viewport, which gl-js supports and we currently cannot express. Renames `layerIds:` → `layers:` to match gl-js's option name. The sync variant stays for the camera-tick overlay path that exists today (example/lib/main.dart:696) but stops being the default. Also fix the stale Web cell.

**`querySourceFeatures`** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart (no such member); would live alongside queryRenderedFeaturesJson at :78
```dart
Future<List<MapLibreFeature>> querySourceFeatures(String sourceId, {List<String>? sourceLayers, Expression? filter, Duration timeout});
```
> Semantically different from queryRenderedFeatures in a way worth documenting on the method: it returns LOADED features, visible or not, so a source with no layer drawing it still answers — which is exactly why it exists (Apple's headers spell this out at MLNShapeSource.h:379-386). `sourceLayers` is required for vector sources and ignored for geojson (query.hpp:37). Small C ABI addition; reuses the whole result pipeline.

**`source` / `sourceLayer` / `state` on query results** — P1, `value-type`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1751-1754 — `feature_collection<double>(features.begin(), features.end())` **slices** mbgl::Feature down to GeoJSONFeature before stringify, dropping all three
```dart
final String? source; final String? sourceLayer; final Map<String, Object?> state;
```
> gl-js is right and both native SDKs are impoverished here — and mbgl agrees with gl-js, so this is a shim bug, not a ceiling. Fix: stop relying on `mapbox::geojson::stringify` of a sliced collection; serialise each Feature by hand, adding `source`/`sourceLayer`/`state` next to `properties`. `state` is what makes hover-highlight round-trip.

**`sourcedata` / source changed** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903
```dart
Stream<MapSourceDataEvent> get sourceData; // {String sourceId, bool isSourceLoaded}
```
> mbgl is COARSER than gl-js here: `onSourceChanged` gives you a source, and `Source::loaded` (include/mbgl/style/source.hpp:123) gives you the boolean — there is no `sourceDataType` ('metadata'|'content') and no per-tile detail. Ship the narrower payload rather than faking gl-js's; do not invent fields the engine cannot fill.

**`styleimagemissing`** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903; the icon path is one-way (`addImage`, style_layers.dart:47-55)
```dart
Stream<String> get styleImageMissing; // controller.events.styleImageMissing — respond with layers.addImage / layers.addWidgetIcon
```
> Real gap given we already ship `addWidgetIcon` (map_layers_controller.dart:387): this is the event that makes data-driven `icon-image` from Flutter widgets work — register icons on demand instead of pre-registering every possible one. Apple's sync-provider shape is NOT portable across an async FFI boundary; take gl-js's notification shape and let the app call addImage, which is what mbgl's C++ signature (void, not a return) supports anyway.

**Rect ⇄ bounds conversion, and metres-per-pixel** — P2, `capability-interface`, evidence: packages/maplibre_flutter_platform_interface/lib/src/projector.dart:24-40 (points only)
```dart
LatLngBounds? unprojectRect(Rect rect); Rect? projectBounds(LatLngBounds bounds); double metersPerPixel({double? latitude});
```
> Apple has all three and both gl-js and we have none; take Apple's shapes with Dart types (Rect for CGRect). `metersPerPixel` is what a scale bar needs and is the reason it is worth binding rather than leaving to callers. Pure Dart on top of the existing projector for the rect pair; `metersPerPixel` needs the current zoom/latitude, which the camera snapshot already has.

**Renderer error (`onRenderError`)** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903
```dart
// folded into controller.events.errors with kind: MapLibreErrorKind.render
```
> mbgl gives an exception_ptr (rethrow-and-catch in the shim to get `.what()`), which is strictly more than Apple's zero-payload delegate. Take mbgl's. Fold into the single `errors` stream rather than adding a second — gl-js's one-error-channel design is right.

**Tile-load events (`onTileAction`)** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903
```dart
Stream<MapTileEvent> get tileActions; // {MapTileOperation operation, int x, y, z, wrap, overscaledZ, String sourceId}
```
> Apple's argument list translates 1:1 and should be copied verbatim including `wrap` and `overscaledZ`. High-volume — make it opt-in (`MapOptions.observeTileActions`) so the C ABI does not marshal thousands of events nobody listens to. This plus `errors` is what makes a tile-server misconfiguration diagnosable instead of a blank map.

**`dblclick` / double-tap** — P2, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:285-292 (only onTapUp)
```dart
final void Function(MapLibreTapEvent event)? onDoubleTap;
```
> Land it together with the double-tap-to-zoom gesture the inversion regressed (FEATURE_MATRIX.md:371) — one GestureDetector recognizer serves both, and shipping the event without the gesture would be odd. Flutter's onDoubleTap must be arena-coordinated with onTap or the single tap fires first.

**`dragstart` / `drag` / `dragend`** — P2, `widget-callback`, evidence: pan is `MapLibreGestureHandler.moveBy` (packages/maplibre_flutter_platform_interface/lib/src/gesture_handler.dart:13), driven from the widget's own gesture layer
```dart
// covered by onCameraMoveStarted(reason: {gesturePan}) + onCameraMove
```
> Third ➖-should-be-❌ in the camera-event block. Taken together (rows :512, :514, :517) the matrix systematically marks "gl-js has a named event, the native SDKs fold it into a reason bitmask" as ➖ N/A, when it is really "expressible with a different shape". Worth a legend clarification.

**`isMoving` / `isZooming` / `isRotating`** — P2, `controller`, evidence: no equivalent on MapLibreMapPlatformController (packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:13-43)
```dart
bool get isMoving;   // isGestureInProgress || any transition
bool get isZooming;  // Map::isScaling
bool get isRotating; // Map::isRotating
bool get isPanning;  // Map::isPanning — mbgl has it, gl-js does not; keep mbgl's name
```
> The single most clearly-incorrect cell in §7 and a good calibration point for how far to trust the matrix: it declares a feature impossible on five platforms while the engine header declares it public four lines apart. Adds `isPanning` beyond the gl-js trio because mbgl offers it and it costs nothing.

**`load` / map-ready signal** — P2, `controller`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:22 (`Future<void> get onReady`); fed on macOS by polling `awaitFrame` (packages/maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:141-146)
```dart
Future<void> get onReady; // unchanged, but re-document as "first frame published", and add `controller.events.styleLoaded` for the real load semantic
```
> Keep as-is — the widget needs a first-frame signal and this is it. But the DOC is wrong and the matrix repeats the error. Do not retrofit onReady onto onDidFinishLoadingMap; add the real event separately.

**`pitchstart` / `pitch` / `pitchend`** — P2, `widget-callback`, evidence: packages/maplibre_flutter_platform_interface/lib/src/rotate_handler.dart (pitchBy); no event
```dart
// covered by onCameraMoveStarted(reason: {gestureTilt}) + onCameraMove
```
> Note the vocabulary split: gl-js and Apple say "pitch"/"tilt", Android says "shove" for the gesture. Our widget already says `tiltGesturesEnabled` (maplibre_map.dart:87) and `MapCamera.pitch` — keep BOTH words in their existing places rather than unifying, and say so in the dartdoc.

**`render` — a frame was drawn (+ fullyRendered)** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:875-877 (`onDidFinishRenderingFrame` publishes the frame); frame COUNT reaches Dart only through `MapLibreModelHost.renderedFrameCount` (packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:130, surfaced at packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:239-244)
```dart
Stream<MapRenderFrameEvent> get renderFrames; // {bool fullyRendered, bool needsRepaint, bool placementChanged, MapRenderingStats? stats}
```
> Throttle or make opt-in — this fires at frame rate and a Dart Stream event per frame is a real cost. `fullyRendered` (RenderMode::Full) is the useful bit: it is the honest "the map is done" signal that CLAUDE.md §7 warns a green integration test does not prove.

**`renderedFrameCount` is filed under the wrong capability** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:239-244 — `renderedFrameCount` is read via `platform is MapLibreModelHost`
```dart
int? get renderedFrameCount; // move off MapLibreModelHost onto the new MapLibreMapObserver capability (or a MapLibreDiagnostics capability)
```
> A real design defect, not cosmetic: `renderedFrameCount` and `modelPartCount` sit on `MapLibreModelHost` because that is the capability that happened to exist when they landed. A renderer that can report frames but cannot draw glTF models cannot expose it. Move it while the API is still pre-1.0; it costs one interface member in five packages.

**`rotatestart` / `rotate` / `rotateend`** — P2, `widget-callback`, evidence: packages/maplibre_flutter_platform_interface/lib/src/rotate_handler.dart:23-45 — rotation is driven from Dart via `rotateBy`, so the boundaries are known and simply not reported
```dart
// covered by onCameraMoveStarted(reason: {gestureRotate}) + onCameraMove
```
> Flagged because the ➖ actively misleads: it says "never possible here", when the gesture is recognized in OUR OWN Dart code as of 2026-07-31. Same correction applies to the `dragstart/drag/dragend` row at :512.

**`styledataloading` / will-start-loading-map** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903 (FrameObserver overrides only 2 of 25 virtuals)
```dart
Stream<void> get styleLoading; // controller.events.styleLoading
```
> Free once the observer capability lands — one more case in the event switch. Drives a loading spinner over a style swap.

**`triggerRepaint`** — P2, `controller`, evidence: packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:386 (`void triggerRepaint()`), backed by packages/maplibre_flutter_core/src/maplibre_flutter_core.h:461; NOT on MapLibreMapPlatformController nor on MapLibreMapController
```dart
void triggerRepaint(); // on MapLibreMapController
```
> All three upstreams expose it and we hide it. It matters here more than upstream: CLAUDE.md §11 records that 'Continuous mode is update-driven, not vsync-driven — a change that never touches mbgl needs an explicit Map::triggerRepaint()', which is exactly the situation an app with a custom animated layer or a model hits. Reachable today only by importing the core package directly, which app code must not do.

**`zoomstart` / `zoom` / `zoomend`** — P2, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:75-82 (only the undifferentiated tick)
```dart
// no separate callbacks — onCameraMoveStarted carries `reason: {gesturePinch}` and onCameraMove carries the camera. Document the gl-js mapping.
```
> Upstream disagrees on granularity: gl-js has 12 axis-specific events (move/zoom/rotate/pitch × start/·/end); both native SDKs have ONE camera-change event plus a reason bitmask. Chose the native shape — 12 widget props is not a defensible Flutter API, and the reason set is strictly more expressive (it tells you pinch AND rotate happened together, which gl-js's separate events also do but at 4× the surface).

**Action journal — persistent rolling event log** — P3, `controller-namespace`, evidence: n/a — `mbl_map_create` (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:52) passes no ActionJournalOptions; the shim constructs `mbgl::Map` without one (maplibre_flutter_core.cpp:918-923)
```dart
// MapOptions.actionJournal: ActionJournalOptions? (init-only, bucket 1)
Future<List<String>> getActionJournalLog(); Future<void> clearActionJournalLog(); // controller.diagnostics
```
> A field-diagnostics feature nobody has to design — mbgl already serialises every observer event to rolling JSON files (the header shows an onTileAction record verbatim, action_journal.hpp:18-32) and the Apple SDK just exposes three getters. Init-only (bucket 1) because it is a Map-constructor option. Good candidate for 'support asked me why the map is blank on this user's device'.

**Debug overlays — `setDebug` / `debugMask` / rendering-stats view** — P3, `widget-prop`, evidence: the only debug hook is `mbl_map_write_png` (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:465), not on the platform interface
```dart
final Set<MapLibreDebugOverlay> debugOverlays; // {tileBorders, parseStatus, timestamps, collision, overdraw, stencilClip, depthBuffer} — MapLibreMap widget prop
```
> gl-js splits it into three booleans, Apple/mbgl into one option set; take mbgl's set (it is the superset and it is our engine). A widget prop, not a controller call, per bucket 2 — it is declarative and low-frequency. `showCollisionBoxes` in particular is how the text-centring patch should be demoed. Marked gljs_verified:false — I did not fetch the gl-js property docs for this row.

**Glyph request events (loaded / error / requested)** — P3, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903
```dart
Stream<MapGlyphEvent> get glyphEvents; // {MapResourceState state, List<String> fontStack, int rangeStart, int rangeEnd}
```
> Directly diagnoses a failure mode this repo has already documented and worked around by hand: naming a font the style does not serve makes mbgl 404 a glyph range on every tile (map_layers_controller.dart:249-257, which defends against it by omitting the label layer entirely). `glyphsDidError` turns that from a mysterious missing label into a message.

**Native fling (`OnFlingListener`) and gesture-detail listeners (Rotate/Scale/Shove begin/·/end)** — P3, `widget-callback`, evidence: inertia/fling is implemented in our Dart tier (FEATURE_MATRIX.md:369) but emits no callback
```dart
// covered by onCameraMoveStarted(reason:) granularity; add discrete callbacks only if an app asks
```
> Android's four listener families exist because its gesture engine is native and otherwise opaque. Ours is in Dart, so an app that needs this granularity can already wrap the widget. Low value; keep on the long tail.

**Shader compilation events** — P3, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903
```dart
Stream<MapShaderEvent> get shaderEvents; // {MapShaderState state, int id, int backend, String defines}
```
> Genuinely useful to THIS project specifically: the 3D-model work patches shaders per backend, and `shaderDidFailCompile` is the signal that a GL/Vulkan/WebGPU shader-patch edit is broken — which is exactly the class of "unverified code, not working code" CLAUDE.md §2 flags. Bind it behind a debug flag; the Apple header warns these are not thread-safe, so marshal, never call back.

**Sprite request events (loaded / error / requested)** — P3, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903
```dart
Stream<MapSpriteEvent> get spriteEvents; // {MapResourceState state, String id, String url}
```
> Same rationale as glyphs: a failed sprite means every icon in the style silently vanishes. Cheap once the observer capability exists.

**`data` / `dataloading` / `dataabort` / `sourcedataloading` / `sourcedataabort`** — P3, `reject`, evidence: n/a — no engine equivalent
```dart
// rejected — no cross-platform equivalent; use `styleLoaded` + `sourceData` + `tileActions` instead
```
> The one row in this section where the matrix's ➖ is right. gl-js's `data` family is a JS-runtime abstraction over its own worker pipeline; mbgl has no counterpart, so binding it on web-gljs only would create exactly the per-platform divergence CLAUDE.md §3 forbids.

**`getPlacedSymbolsData` — label placement/collision introspection** — P3, `controller-namespace`, evidence: n/a
```dart
// deferred — mbgl restricts it to MapMode::Tile, which our Continuous/Static tiers do not use
```
> Worth knowing exists, not worth binding: mbgl gates it on Tile mode (renderer.hpp:93-98) and we run Continuous or Static (maplibre_flutter_core.h:47-51). Would be the honest way to test the text-centring patch in docs/upstream-text-centring/ against real collision boxes rather than pixels — the one use case that might justify it.

**`mapViewWillStartRenderingMap` / `mapViewDidFinishRenderingMap:fullyRendered:`** — P3, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903
```dart
Stream<bool> get mapRendered; // payload: fullyRendered
```
> Largely subsumed by `idle` + `renderFrames(fullyRendered:)`. Bind it for delegate-parity with the Apple/Android SDKs, not because apps need it. Note the Apple header itself marks these two `// TODO` with no doc comment.

**`mousedown` / `mouseup` / `wheel` / `touchstart` / `touchmove` / `touchend` / `touchcancel`** — P3, `reject`, evidence: raw pointers are consumed by the gesture layer (packages/maplibre_flutter/lib/src/maplibre_map.dart, `Listener` + recognizers); nothing is forwarded
```dart
// rejected — wrap MapLibreMap in a Listener/GestureDetector; Flutter's raw pointer stream is strictly richer than gl-js's DOM re-emission
```
> Correct not to bind, but change the matrix note from "web_only" to "Flutter-native": a reader scanning ➖ cells learns the wrong thing about what the package can do. The one caveat worth documenting is that the map's own gesture recognizers compete in the arena, so a wrapping Listener sees pointers the map may also claim.

**`onCanRemoveUnusedStyleImage` / `shouldRemoveStyleImage:`** — P3, `reject`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872-903
```dart
// rejected for now — a synchronous bool from Dart on the render thread is not safely bindable
```
> The only mbgl observer method that RETURNS a value the engine waits on. Answering it from Dart means blocking the render thread on an isolate round trip — exactly the deadlock shape CLAUDE.md §11 warns about with FileSource callbacks. If it is ever needed, model it as a declarative policy (`MapOptions.keepStyleImages: Set<String>`) evaluated in C++, never as a Dart callback.

**`project` / `unproject`** — P3, `capability-interface`, evidence: packages/maplibre_flutter_platform_interface/lib/src/projector.dart:24-40 (`project` batched, returns the generation; `unproject`); backed by packages/maplibre_flutter_core/src/maplibre_flutter_core.h:136-160
```dart
// keep as-is; consider aliasing on the app-facing controller so users see gl-js's names:
Offset? project(LatLng point); LatLng? unproject(Offset position);
```
> Genuinely done, and better than upstream: batched, lock-light, and projected against the PRESENTED generation so overlays do not swim. Two follow-ups only: fix the stale Web cells, and consider surfacing single-point `project`/`unproject` on `MapLibreMapController` under the gl-js names — today they are reachable only via the capability interface, which app code is not supposed to touch.

**`projectiontransition`, `roll`/`rollstart`/`rollend`, `cooperativegestureprevented`, `boxzoom*`** — P3, `reject`, evidence: n/a
```dart
// rejected — gl-js-only features with no engine or handler behind them
```
> Add `roll*` and `projectiontransition` rows to §7 as ➖ so a future reader does not assume they were forgotten. If a box-zoom gesture is ever added to our Dart tier, the events become ours to synthesize, not the engine's — reconsider then.

**`remove` — map destroyed** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:96-104 (`dispose` returns a Future; no notification)
```dart
// rejected — `await controller.dispose()` already IS this signal in Dart
```
> A JS-idiom event with a Dart-idiom answer. Do not bind.

**`resize`** — P3, `reject`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:39 (`resize` is a command in, not an event out)
```dart
// rejected — use LayoutBuilder / NotificationListener<SizeChangedLayoutNotification> around MapLibreMap
```
> Correct to not bind, but the matrix's justification ("web_only") is the wrong reason and misleads. Change the note to "Flutter-native".

**`shouldChangeFromCamera:toCamera:reason:` (veto a gesture)** — P3, `widget-prop`, evidence: n/a
```dart
// prefer the declarative engine-side form over a per-gesture Dart veto:
final LatLngBounds? maxBounds;  // MapLibreMap widget prop -> Map::setBounds
final double? minZoom, maxZoom; // same BoundOptions
```
> Apple's synchronous per-frame veto callback is the wrong shape across an FFI boundary (the gesture would have to block on Dart). mbgl already offers the intent declaratively via BoundOptions, which is also bucket-2 shaped. Bind setBounds, not the veto. Belongs primarily to the camera domain; noted here because the matrix files the veto under events.

**`terrain` event / `queryTerrainElevation` / `getCameraTargetElevation`** — P3, `reject`, evidence: n/a
```dart
// rejected — hard mbgl ceiling, see mbgl_ceiling_notes
```
> The clearest false-❌ in §7. Per the matrix's own ❌-vs-➖ rule (FEATURE_MATRIX.md:50-67), ❌ means "the engine CAN do it"; here it cannot. Fix the cell, otherwise it sits on the backlog forever as apparently-tractable work.

**`validate` / `availableImages` query options** — P3, `reject`, evidence: n/a
```dart
// rejected — gl-js-internal knobs with no mbgl counterpart
```
> `validate` toggles gl-js's runtime style-spec validator, which mbgl does not have as an option (it validates on convert). `availableImages` is a gl-js worker-protocol detail. Binding either would be inventing API.

**`webglcontextlost` / `webglcontextrestored`** — P3, `controller-namespace`, evidence: no context-loss handling in packages/maplibre_flutter_web/lib/src/core_web/
```dart
Stream<bool> get contextLost; // web/WASM tier only; true = lost, false = restored
```
> Not cross-platform, but the web-WASM tier is the DEFAULT web renderer and a lost WebGL2 context there is a permanently blank canvas with no recovery path today. Track it under the web productionization work in docs/experimental-web-core-wasm.md rather than as a general event.


### Annotations, markers & controls

#### Engine ceiling

**mbgl-core has no view layer at all — this whole domain's UI half is a hard stop, and that is fine because it belongs in Flutter anyway.**

1. **No ornaments exist in core.** There is no compass, scale bar, logo, attribution view or navigation control anywhere under `include/mbgl` — `map/map.hpp` (218 lines) is engine operations only, and `grep -ri "attribution"` over the entire public header tree returns exactly two hits: `style/source.hpp:77` (`std::optional<std::string> getAttribution() const`) and `util/tileset.hpp:32` (`std::string attribution`). Every ornament must be a Flutter widget. This is a ceiling on *how* we build them, not on *whether*: the underlying **data** is all reachable —
   - attribution text: `style::Style::getSources()` (style/style.hpp:55) → `style::Source::getAttribution()` (style/source.hpp:77);
   - scale bar: `mbgl::Projection::getMetersPerPixelAtLatitude(lat, zoom)` (util/projection.hpp:47) — a `static` pure function, portable to Dart verbatim, **no C ABI needed**;
   - compass: bearing from `Map::getCameraOptions()` (map/map.hpp:72), already plumbed.

2. **No geolocation of any kind.** `grep -rl "LocationManager\|Geolocation" include/mbgl` returns nothing. The user-location puck cannot get a position from the engine; the position must come from Dart. Apple's `MLNLocationManager` is an SDK-level protocol layered *above* core, and Android's `LocationComponent` likewise. So `MapLibreLocationSource` is not a design choice we could avoid — it is forced by the engine.

3. **No globe projection ⇒ `GlobeControl` is impossible on all six tiers.** `map/projection_mode.hpp` (40 lines) covers axonometric rendering and X/Y skew only. gl-js 5.x's globe has no counterpart in MapLibre Native. This is a genuine `➖`, not a backlog item.

4. **No terrain ⇒ gl-js's `opacityWhenCovered` / marker occlusion is unimplementable.** The only "terrain" hits under `include/mbgl` are the `color_relief` shader headers and constants; there is no 3D terrain, so a marker can never be *covered* by it. `Marker.setOpacity(opacity, opacityWhenCovered)`'s second argument has no meaning for us. (Depth occlusion against 3D *buildings* is a different thing and only applies to engine-drawn models, not widget markers.)

5. **The legacy annotation API DOES exist in core, and is strictly weaker than what we already ship.** `map/map.hpp:127-134` exposes `addAnnotationImage`, `removeAnnotationImage`, `getTopOffsetPixelsForAnnotationImage`, `addAnnotation`, `updateAnnotation`, `removeAnnotation`, over `annotation/annotation.hpp:64` `using Annotation = variant<SymbolAnnotation, LineAnnotation, FillAnnotation>`. A `SymbolAnnotation` (annotation.hpp:17-25) is a point plus an icon *name* — no rotation, no offset, no alignment, no callout, no drag, no per-annotation styling beyond flat opacity/width/colour on the shape variants. So binding it would give us **less** than the widget-marker overlay and less than the style-layer path we already have. It is a ceiling worth recording precisely because it looks like a shortcut and is not.

6. **Cluster drill-down is in core but not reachable from the public `Source` API.** `style/sources/geojson_source.hpp:55-57` declares `getChildren(uint32_t)`, `getLeaves(uint32_t, limit, offset)` and `getClusterExpansionZoom(uint32_t)` — but on `GeoJSONData`, reachable only via `GeoJSONSource::impl()` (geojson_source.hpp:73-74). Bindable, but it needs a C shim function that reaches through the impl, not a one-liner.

7. **Fitting the camera to a set of points is in core**, so "zoom to all markers" needs no new math: `Map::cameraForLatLngs(const std::vector<LatLng>&, const EdgeInsets&, bearing, pitch)` (map/map.hpp:84) and `MapProjection::setVisibleCoordinates(const std::vector<LatLng>&, const EdgeInsets&)` (map/map_projection.hpp:24). These back Apple's `-showAnnotations:edgePadding:animated:completionHandler:` (MLNMapView.h:1309).


#### Naming decisions

**Where I took gl-js, where I took the SDKs, and what I adapted.**

**1. Marker field names: gl-js wins.** `MapLibreMarker` gets `offset`, `rotation`, `rotationAlignment`, `pitchAlignment`, `opacity`, `draggable` — the exact `MarkerOptions` field names (verified at https://maplibre.org/maplibre-gl-js/docs/API/type-aliases/MarkerOptions/). Apple's equivalents are UIKit-shaped and differently factored (`centerOffset` is a `CGVector` doing double duty as offset+anchor, MLNAnnotationView.h:159; `rotatesToMatchCamera` MLNAnnotationView.h:193 is a two-state boolean where gl-js has a three-state `Alignment`). gl-js's factoring is finer-grained and matches the style spec's own `icon-rotation-alignment` / `icon-pitch-alignment` vocabulary, which our generated typed style API already emits — so one vocabulary covers both marker tiers.

**2. Marker anchor → `alignment`: ADAPTED to Flutter idiom (already done, keeping it).** gl-js `anchor: PositionAnchor` is nine discrete strings (`'center'`,`'top'`,…,`'bottom-right'`; default `'center'`). Our existing `MapLibreMarker.alignment` is a Flutter `Alignment`, a *continuous superset* — every gl-js value maps to a Flutter constant (`'bottom'` ⇒ `Alignment.bottomCenter`), and the semantics are identical (the named point of the marker box lands on the geographic point). This is the right adaptation and I am not proposing we revert it; the docs should state the mapping table so someone porting gl-js code knows what to type.

**3. Marker events → Flutter callbacks: ADAPTED (already done).** gl-js `marker.on('dragstart'|'drag'|'dragend'|'click')`. Ours is `onDragStart`/`onDragUpdate`/`onDragEnd` (marker.dart:46-54) — `drag` renamed `onDragUpdate` to match `GestureDetector`'s vocabulary. I propose adding `onTap` for gl-js's `click`, again as a callback field, not a stream.

**4. Marker lifecycle: DELIBERATE DIVERGENCE.** gl-js is imperative (`marker.addTo(map)` / `marker.remove()` / `setLngLat()`), Apple is imperative (`-addAnnotation:` MLNMapView.h:1793). Ours is declarative (`MapLibreMap.markers`), which is the three-bucket rule's answer for "mutable + declarative + low-frequency" and is what every mature Flutter map plugin does. Keep it; do **not** add `controller.addMarker`.

**5. Ornaments (attribution / compass / scale / logo): SDK shape, gl-js option names.** The two upstreams genuinely disagree in *shape*:
- gl-js: controls are separate DOM classes registered imperatively — `map.addControl(new AttributionControl({compact:true}), 'bottom-right')`, with an `IControl` interface (`onAdd`/`onRemove`/`getDefaultPosition`) and `ControlPosition = 'top-left'|'top-right'|'bottom-left'|'bottom-right'`.
- Apple/Android: ornaments are *properties of the map view* — a boolean, a position enum, a margin (`showsAttributionButton` MLNMapView.h:416, `attributionButtonPosition` :437, `attributionButtonMargins` :442; Android `uiSettings.setAttributionEnabled/…Gravity/…Margins`).

**I picked the SDK shape** (`MapLibreMap(attribution: …, compass: …, scaleBar: …, logo: …)`) for three reasons: (a) attribution must be **on by default**, and a default only exists if the widget owns it — an `addControl` model means a forgetful app ships with no attribution and a licence violation; (b) the position enum is identical in both worlds anyway (Apple's `MLNOrnamentPosition` MLNMapView.h:63 has exactly gl-js's four corner values), so nothing is lost; (c) `IControl` has no meaning in Flutter — a custom control is just a widget in a `Stack`. **I took gl-js's option NAMES inside those configs** (`compact`, `customAttribution`, `maxWidth`, `unit`, `showCompass`, `showZoom`, `visualizePitch`) so gl-js users find what they expect.

**`map.addControl` is therefore ADAPTED, not bound**: `MapLibreMap.controls: List<Widget>` positioned by a `MapLibreOrnament` wrapper. No `IControl`, no `removeControl`, no `hasControl` — a widget list is add/remove/query by construction.

**6. Ornament visibility: Apple wins.** `MLNOrnamentVisibility {adaptive, hidden, visible}` (MLNTypes.h:132) subsumes gl-js's boolean *and* Android's `setCompassFadeFacingNorth(bool)` — "adaptive" is precisely "hide when facing north / hide when the scale is meaningless". One three-state enum, `MapLibreOrnamentVisibility`, replaces a boolean plus a fade flag.

**7. Attribution content model: Apple wins, gl-js loses.** gl-js's `AttributionControl` injects the style's `attribution` string as **raw HTML** into the DOM. Flutter cannot do that without an HTML-rendering dependency, and this package takes none. Apple parses each source's attribution into structured `MLNAttributionInfo` objects (`title` + `URL` + `isFeedbackLink`, MLNAttributionInfo.h:33-77) and renders them itself. **Adopt Apple's structured model** — `MapLibreAttribution(text, url, isFeedbackLink)` — and do the HTML→(text,link) parse in Dart. gl-js's *option* names (`compact`, `customAttribution`) still apply to the widget config.

**8. User location: SDK split, not gl-js's conflated control.** gl-js's `GeolocateControl` is simultaneously a button, a position provider and a puck, because the browser's Geolocation API is ambient. On Flutter there is no ambient provider and this package must not depend on `geolocator`. So follow Apple/Android and split it: `MapLibreUserLocation` (the puck config, a widget prop) + `MapLibreUserTrackingMode` (Apple's four values verbatim — `none`, `follow`, `followWithHeading`, `followWithCourse`, MLNMapView.h:82-108) + a `MapLibreLocationSource` the app implements (mirrors Apple's `MLNLocationManager` protocol). A `MapLibreGeolocateButton` widget is the optional gl-js-flavoured sugar on top.

**9. Popup: gl-js wins over Apple's callout.** `MapLibrePopup` with `anchor`(→`alignment`), `offset`, `closeButton`, `closeOnClick`, `closeOnMove`, `maxWidth`. Apple's `MLNCalloutView` (MLNCalloutView.h:20) is a UIKit protocol with `leftAccessoryView`/`rightAccessoryView` and a delegate — untranslatable and unnecessary when the popup body is an arbitrary Flutter widget. **Binding is adapted**: gl-js `marker.setPopup(p)` + `togglePopup()` becomes `MapLibreMarker.popup` + `MapLibreMarker.popupOpen` (declarative, matching our marker model).

**10. Shape annotations: neither SDK's annotation API — the style-layer path.** Apple `MLNPolyline`/`MLNPolygon` (MLNPolyline.h:60, MLNPolygon.h:53) and mbgl's own `LineAnnotation`/`FillAnnotation` (annotation/annotation.hpp:30,47) are the legacy tier that upstream itself steers away from. gl-js never had them — it has GeoJSON sources + `line`/`fill` layers, which is what we already generate. So the proposal is convenience factories in gl-js's own vocabulary (`layers.addPolyline`, `layers.addPolygon`, `GeoJsonData.polygon`) rather than an annotation API. Stated as an explicit reject row so the decision is on the record.


#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | Attribution HTML → text + links | none | — (injects the raw HTML into the DOM; no parsing step exists) | MLNAttributionInfo parses source HTML into title/URL/feedbackLink (MLNAttributionInfo.h:42-65) and offers -titleWithStyle: with short/medium/long forms (MLNAttributionInfoStyle, MLNAttributionInfo.h:13-26, method at :77) | NOT IN CORE — the attribution string is passed through verbatim (style/source.hpp:77) | value-type | no |
| P0 | Attribution data from the style (source attribution strings) | none | internal to AttributionControl (reads style.sources[*].attribution) | MLNTileSource.attributionInfos (MLNTileSource.h:186) and .attributionHTMLString (MLNTileSource.h:195); MLNAttributionInfo (title/URL/isFeedbackLink, MLNAttributionInfo.h:33-77) | style::Style::getSources() (style/style.hpp:55) + style::Source::getAttribution() (style/source.hpp:77) — present, thread-confined to the map thread like every other style read | capability-interface | yes |
| P0 | Attribution — rendered on the map (LEGAL OBLIGATION) | none | new AttributionControl({compact, customAttribution}); MapOptions.attributionControl: false \| AttributionControlOptions, DEFAULT `{compact: true, customAttribution: 'MapLibre …'}` — i.e. ON BY DEFAULT | MLNMapView.showsAttributionButton DEFAULT YES (MLNMapView.h:416); attributionButton (:431); attributionButtonPosition default bottom-right (:437); attributionButtonMargins (:442); -showAttribution: (:451). The header carries an explicit legal note at :421-429: "Attribution is often required … do not hide this view or remove any notices from it." | DATA ONLY: style::Style::getSources() (style/style.hpp:55) → style::Source::getAttribution() (style/source.hpp:77); raw value at util/tileset.hpp:32. No view — see the ceiling notes. | widget-prop | yes |
| P1 | Attribution compact mode | none | AttributionControlOptions.compact: boolean (default false on the control; the Map option defaults it to true) | the ⓘ button IS the compact form (MLNMapView.h:431) and expands to an action sheet via -showAttribution: (:451) | NOT IN CORE | widget-prop | no |
| P1 | Compass ornament | none | NavigationControlOptions.showCompass: boolean (+ visualizePitch, visualizeRoll); clicking resets bearing to 0 | MLNMapView.showsCompassView DEFAULT YES (MLNMapView.h:366); compassView → MLNCompassButton (:372); compassViewPosition default top-right (:378); compassViewMargins (:383); MLNCompassButton.compassVisibility (MLNCompassButton.h:19) | DATA ONLY: bearing via mbgl::Map::getCameraOptions (map/map.hpp:72). No view. | widget-prop | no |
| P1 | Custom / additional attribution text | none | AttributionControlOptions.customAttribution: string \| string[] | — (you construct extra MLNAttributionInfo objects, MLNAttributionInfo.h:42; MLNTileSourceOptionAttributionInfos MLNTileSource.h:81 for source-level) | NOT IN CORE | widget-prop | no |
| P1 | Marker pixel offset | none | MarkerOptions.offset: PointLike; marker.setOffset(offset) / marker.getOffset() | MLNAnnotationView.centerOffset (CGVector) (MLNAnnotationView.h:159) | NOT IN CORE (widget tier); style-spec analogue `icon-offset` | widget-prop | no |
| P1 | Marker tap / click callback | partial | marker.on('click', handler) | -[MLNMapViewDelegate mapView:didSelectAnnotation:] (MLNMapViewDelegate.h:800) / didSelectAnnotationView: (MLNMapViewDelegate.h:830) | NOT IN CORE | widget-callback | no |
| P1 | Ornament position (four corners) | none | type ControlPosition = 'top-left' \| 'top-right' \| 'bottom-left' \| 'bottom-right'; used as map.addControl(control, position) | MLNOrnamentPosition {TopLeft, TopRight, BottomLeft, BottomRight} (MLNMapView.h:63-80), used by scaleBarPosition/compassViewPosition/logoViewPosition/attributionButtonPosition | NOT IN CORE | value-type | no |
| P1 | Popup / callout attached to a marker | none | new Popup(options).setLngLat(...).setHTML(...); marker.setPopup(popup) / getPopup() / togglePopup(); popup.addTo/remove/isOpen | MLNCalloutView protocol (MLNCalloutView.h:20), -[MLNMapViewDelegate mapView:annotationCanShowCallout:] (MLNMapViewDelegate.h:880), calloutViewForAnnotation: (:901) | NOT IN CORE | value-type | no |
| P1 | Scale bar ornament | none | new ScaleControl({maxWidth, unit: 'imperial'\|'metric'\|'nautical'}); scaleControl.setUnit(unit) | MLNMapView.showsScale default NO (MLNMapView.h:331); scaleBar → MLNScaleBar (:337); scaleBarShouldShowDarkStyles (:342); scaleBarUsesMetricSystem (:347); scaleBarPosition default top-left (:353); scaleBarMargins (:358). MLNScaleBar itself: metersPerPoint (MLNScaleBar.h:10), shouldShowDarkStyles (:13), usesMetricSystem (:16), primaryColor (:19), secondaryColor (:22) | mbgl::Projection::getMetersPerPixelAtLatitude(double lat, double zoom) (util/projection.hpp:47) — a static pure function; NO C ABI NEEDED, port it to Dart | widget-prop | no |
| P1 | User-location puck | none | new GeolocateControl({positionOptions, fitBoundsOptions, trackUserLocation, showAccuracyCircle, showUserLocation, showUserHeading}); control.trigger() | MLNMapView.showsUserLocation (MLNMapView.h:590); userLocationVisible (:618); userLocation → MLNUserLocation (:623, MLNUserLocation.h:20 with location/heading/updating); MLNUserLocationAnnotationView (MLNUserLocationAnnotationView.h:14); MLNUserLocationAnnotationViewStyle puckFillColor/haloFillColor/… (MLNUserLocationAnnotationViewStyle.h:16-53) | NOT IN CORE — no location manager anywhere under include/mbgl (see ceiling notes) | widget-prop | no |
| P2 | Accuracy circle | none | GeolocateControlOptions.showAccuracyCircle: boolean | MLNUserLocationAnnotationViewStyle.haloFillColor (MLNUserLocationAnnotationViewStyle.h:34), approximateHaloFillColor/BorderColor/BorderWidth/Opacity (:38-53) | NOT IN CORE for the widget path; the ENGINE path is a circle layer with a metre-radius expression (style spec `circle-radius` + `circle-pitch-scale`) | widget-prop | no |
| P2 | Cluster expansion zoom / children / leaves | none | GeoJSONSource.getClusterExpansionZoom(clusterId), getClusterChildren(clusterId), getClusterLeaves(clusterId, limit, offset) | — (Apple exposes the cluster feature but no drill-down helpers) | GeoJSONData::getClusterExpansionZoom(uint32_t), getChildren(uint32_t), getLeaves(uint32_t, limit, offset) (style/sources/geojson_source.hpp:55-57) — present, but only on GeoJSONData, reached via GeoJSONSource::impl() (:73-74) | capability-interface | yes |
| P2 | Cluster feature access (id, point count) | partial | features from map.queryRenderedFeatures carry cluster / cluster_id / point_count / point_count_abbreviated | MLNCluster protocol: clusterIdentifier (MLNCluster.h:46), clusterPointCount (:49); MLNClusterIdentifierInvalid (:11) | supercluster inside GeoJSONData (style/sources/geojson_source.hpp:43-58); our shim reads it back via mbl_map_query_rendered_features (maplibre_flutter_core/src/maplibre_flutter_core.h:246) | value-type | no |
| P2 | Custom controls / addControl | none | map.addControl(control: IControl, position?: ControlPosition) : this; map.removeControl(control) : this; map.hasControl(control) : boolean; interface IControl { onAdd(map): HTMLElement; onRemove(): void; getDefaultPosition(): ControlPosition } | — (ornaments are fixed properties; a custom control is just a subview you add yourself) | NOT IN CORE | widget-prop | no |
| P2 | Default marker visual (pin) | none | MarkerOptions.color (default '#3FB1CE') and scale (default 1) — with no `element`, gl-js draws a built-in droplet SVG | default red pin via MLNAnnotationImage when the delegate returns nothing (MLNAnnotationImage.h:31) | NOT IN CORE | widget-prop | no |
| P2 | Engine-drawn polygon helper + GeoJsonData.polygon | none | — (GeoJSON source + FillLayer, by hand) | MLNPolygon (MLNPolygon.h:53), +polygonWithCoordinates:count:interiorPolygons: (:90), interiorPolygons (:64), MLNMultiPolygon (:114); fill styling via mapView:fillColorForPolygonAnnotation: (MLNMapViewDelegate.h:705) | mbgl::FillAnnotation (annotation/annotation.hpp:47-62) — legacy path, not used; style-layer path via mbl_map_add_layer_json (maplibre_flutter_core/src/maplibre_flutter_core.h:187) | controller-namespace | no |
| P2 | Engine-drawn polyline helper | partial | — (GeoJSON source + LineLayer, by hand) | MLNPolyline (MLNPolyline.h:60) / +polylineWithCoordinates:count: (:71); MLNMultiPolyline (:96); -[MLNMapView addOverlay:] (MLNMapView.h:2024); styling via mapView:lineWidthForPolylineAnnotation: (MLNMapViewDelegate.h:721) and strokeColorForShapeAnnotation: (:686) | mbgl::LineAnnotation (annotation/annotation.hpp:30-45) — legacy path, deliberately not used; the style-layer path goes through our existing mbl_map_add_layer_json (maplibre_flutter_core/src/maplibre_flutter_core.h:187) | controller-namespace | no |
| P2 | Fit the camera to a set of markers / coordinates | none | map.fitBounds(bounds, options) — options include padding, maxZoom, linear, offset | -[MLNMapView showAnnotations:animated:] (MLNMapView.h:1270); -showAnnotations:edgePadding:animated:completionHandler: (MLNMapView.h:1309); -setVisibleCoordinateBounds:edgePadding:animated: (MLNMapView.h ~:912) | mbgl::Map::cameraForLatLngs(const std::vector<LatLng>&, const EdgeInsets&, bearing, pitch) (map/map.hpp:84); mbgl::MapProjection::setVisibleCoordinates (map/map_projection.hpp:24) | controller | yes |
| P2 | Geolocate button (recentre on me) | none | GeolocateControl's button; control.trigger() : boolean; events geolocate / error / outofmaxbounds | — (no built-in button; apps drive userTrackingMode from their own UI) | NOT IN CORE | widget-prop | no |
| P2 | Heading / course indicator | none | GeolocateControlOptions.showUserHeading: boolean | MLNMapView.showsUserHeadingIndicator (MLNMapView.h:726); MLNUserLocation.heading (MLNUserLocation.h:44); MLNUserLocationAnnotationViewStyle.puckArrowFillColor (:30) | NOT IN CORE | widget-prop | no |
| P2 | Map tap → LatLng (the annotation-adjacent hit test) | present | map.on('click', e => e.lngLat) | gesture recognisers + -[MLNMapView convertPoint:toCoordinateFromView:] | mbgl::Map::latLngForPixel (map/map.hpp:120) → mbl_map_lat_lng_for_pixel (maplibre_flutter_core/src/maplibre_flutter_core.h:157) | widget-callback | no |
| P2 | MapLibre logo ornament | none | LogoControl; MapOptions.maplibreLogo (boolean) and MapOptions.logoPosition (ControlPosition, default 'bottom-left') | MLNMapView.showsLogoView DEFAULT YES (MLNMapView.h:391); logoView (:397); logoViewPosition default bottom-left (:403); logoViewMargins (:408). Header note at :393: "You are not required to display this, but some vector-sources may require attribution." | NOT IN CORE | widget-prop | no |
| P2 | Marker opacity | none | MarkerOptions.opacity (default 1); marker.setOpacity(opacity, opacityWhenCovered) | -[MLNMapViewDelegate mapView:alphaForShapeAnnotation:] (MLNMapViewDelegate.h:667) for shapes; annotation views use UIView.alpha | NOT IN CORE | widget-prop | no |
| P2 | Marker rotation | none | MarkerOptions.rotation: number (default 0); marker.setRotation(r) / getRotation() | no direct rotation; MLNAnnotationView.rotatesToMatchCamera (MLNAnnotationView.h:193) only couples the view to the camera bearing | NOT IN CORE (widget tier); style-spec analogue `icon-rotate` | widget-prop | no |
| P2 | Marker rotationAlignment | none | MarkerOptions.rotationAlignment: Alignment ('map'\|'viewport'\|'auto'), default 'auto'; setRotationAlignment/getRotationAlignment | MLNAnnotationView.rotatesToMatchCamera (MLNAnnotationView.h:193) — the two-state version of the same idea | NOT IN CORE for widgets; style-spec `icon-rotation-alignment` is generated into our typed API | value-type | no |
| P2 | Ornament visibility (adaptive / visible / hidden) | none | — (booleans only: showCompass, showZoom, …) | MLNOrnamentVisibility {Adaptive, Hidden, Visible} (MLNTypes.h:132-139); MLNCompassButton.compassVisibility (MLNCompassButton.h:19) | NOT IN CORE | value-type | no |
| P2 | User tracking mode (camera follows the user) | none | GeolocateControlOptions.trackUserLocation: boolean + events trackuserlocationstart / trackuserlocationend / userlocationfocus / userlocationlostfocus | MLNMapView.userTrackingMode (MLNMapView.h:637), -setUserTrackingMode:animated:completionHandler: (:668), MLNUserTrackingMode {None, Follow, FollowWithHeading, FollowWithCourse} (MLNMapView.h:82-108), userLocationVerticalAlignment (:680), MLNAnnotationVerticalAlignment (:47) | NOT IN CORE (camera moves are, the tracking policy is not) | value-type | no |
| P2 | Zoom in / out buttons | none | NavigationControlOptions.showZoom: boolean (part of NavigationControl) | — (iOS has no zoom buttons) | mbgl::Map::scaleBy(double, anchor, animation) (map/map.hpp:77) — already bound as mbl_map_scale_by (maplibre_flutter_core/src/maplibre_flutter_core.h:80) | controller | no |
| P3 | 3D model annotations (our own tier) | present | — (no equivalent; gl-js needs a custom layer with three.js) | — (no equivalent) | CustomDrawableLayer (the portable escape hatch per CLAUDE.md §11); driven by mbl_map_add_model / mbl_map_set_model_transform / mbl_map_remove_model (maplibre_flutter_core/src/maplibre_flutter_core.h:395,411,438) | widget-prop | no |
| P3 | Apple callout accessory views and callout tap | none | — | MLNCalloutView.leftAccessoryView (MLNCalloutView.h:32) / rightAccessoryView (:38) / delegate (:44); -[MLNMapViewDelegate mapView:leftCalloutAccessoryViewForAnnotation:] (MLNMapViewDelegate.h:932) / rightCalloutAccessoryViewForAnnotation: (:963) / tapOnCalloutForAnnotation: (:1017) / annotationCanShowCallout: (:880) | NOT IN CORE | reject | no |
| P3 | Engine-drawn point layer helper (bulk markers + clustering) | present | — (no helper; you write the GeoJSON source + circle layers yourself) | — (MLNShapeSource + MLNCircleStyleLayer, assembled by hand) | style::GeoJSONOptions cluster/clusterRadius/clusterMaxZoom/clusterMinPoints (style/sources/geojson_source.hpp:29-32), reached through our mbl_map_add_source_json (maplibre_flutter_core/src/maplibre_flutter_core.h:181) | controller-namespace | no |
| P3 | Flutter widget → engine icon (icon-image) | present | map.addImage(id, image, options) | -[MLNStyle setImage:forName:]; MLNAnnotationImage +annotationImageWithImage:reuseIdentifier: (MLNAnnotationImage.h:31) | mbgl::style::Style::addImage (style/style.hpp:51); annotation variant mbgl::Map::addAnnotationImage (map/map.hpp:128) | controller-namespace | no |
| P3 | Fullscreen control | none | new FullscreenControl({container}); events fullscreenstart / fullscreenend | — | NOT IN CORE | reject | no |
| P3 | Globe control | none | GlobeControl (gl-js 5.x) | — | NOT IN CORE — map/projection_mode.hpp:12-39 is axonometric + skew only; there is no globe projection | reject | no |
| P3 | Imperative marker add / remove / move | none | marker.addTo(map) / marker.remove() / marker.setLngLat(lnglat) | -[MLNMapView addAnnotation:] :1793, addAnnotations: :1808, removeAnnotation: :1820, removeAnnotations: :1833, annotations :1775 | mbgl::Map::addAnnotation / updateAnnotation / removeAnnotation (map/map.hpp:132-134) | reject | no |
| P3 | Marker anchor / alignment | present | MarkerOptions.anchor: PositionAnchor ('center'\|'top'\|'bottom'\|'left'\|'right'\|'top-left'\|'top-right'\|'bottom-left'\|'bottom-right'), default 'center' | MLNAnnotationView.centerOffset (CGVector) (MLNAnnotationView.h:159) — Apple has no discrete anchor, only an offset | NOT IN CORE for widget markers; the style-spec equivalent is `icon-anchor` (scripts/style-spec-reference/v8.json) | widget-prop | no |
| P3 | Marker className / CSS class management | none | MarkerOptions.className; marker.addClassName / removeClassName / toggleClassName | — | NOT IN CORE | reject | no |
| P3 | Marker custom content (arbitrary widget) | present | MarkerOptions.element (HTMLElement); marker.getElement() | -[MLNMapViewDelegate mapView:viewForAnnotation:] → MLNAnnotationView (MLNMapViewDelegate.h:753, MLNAnnotationView.h:56) | NOT IN CORE (view layer) | widget-prop | no |
| P3 | Marker drag lifecycle callbacks | present | marker.on('dragstart'\|'drag'\|'dragend', handler) | -[MLNAnnotationView setDragState:animated:] (MLNAnnotationView.h:279) + mapView:annotationView:didChangeDragState:fromOldState: (MLNMapViewDelegate.h:767) | NOT IN CORE | widget-callback | no |
| P3 | Marker draggable | present | MarkerOptions.draggable (default false); marker.setDraggable(bool) / marker.isDraggable() | MLNAnnotationView.draggable (MLNAnnotationView.h:261), dragState (MLNAnnotationView.h:270), MLNAnnotationViewDragState enum (MLNAnnotationView.h:10) | NOT IN CORE | widget-prop | no |
| P3 | Marker occlusion behind a pitched camera | present | — (implicit) | — (implicit) | mbgl::Map::pixelsForLatLngs (map/map.hpp:121) + our shim's behind-camera test (maplibre_flutter_core/src/maplibre_flutter_core.h:147 mbl_map_pixels_for_lat_lngs) | capability-interface | no |
| P3 | Marker pitchAlignment | none | MarkerOptions.pitchAlignment: Alignment ('map'\|'viewport'\|'auto'), default 'auto'; setPitchAlignment/getPitchAlignment | no equivalent (MLNAnnotationView.scalesWithViewingDistance MLNAnnotationView.h:180 is a different axis) | mbgl::Map::getTransfromState() (map/map.hpp:125) returns the TransformState the full matrix would come from; nothing simpler is public | widget-prop | yes |
| P3 | Marker repaintBoundary escape hatch | present | — | — (MLNAnnotationImage.h is the analogous 'rasterise once' idea) | NOT IN CORE | widget-prop | no |
| P3 | Marker scalesWithViewingDistance (perspective scaling) | none | — | MLNAnnotationView.scalesWithViewingDistance (MLNAnnotationView.h:180) | NOT IN CORE | widget-prop | no |
| P3 | Marker selection / selected state | none | — (gl-js has no selection concept) | -[MLNMapView selectAnnotation:animated:completionHandler:] (MLNMapView.h:1946), deselectAnnotation:animated: (:2004), selectedAnnotations (:1918), didSelectAnnotation: (MLNMapViewDelegate.h:800), didDeselectAnnotation: (:814) | NOT IN CORE | reject | no |
| P3 | Marker subpixel positioning | present | MarkerOptions.subpixelPositioning (default false); marker.setSubpixelPositioning(bool) | — | NOT IN CORE | reject | no |
| P3 | Marker viewport culling | present | — (browser handles offscreen DOM) | -[MLNMapView visibleAnnotations] (MLNMapView.h:1890) / visibleAnnotationsInRect: (MLNMapView.h:1901) | NOT IN CORE (view tier) | controller | no |
| P3 | Marker z-order / paint order | internal-only | — (DOM order; gl-js has no marker z-index API) | — (no annotation z-order API) | style-spec `symbol-sort-key` for the engine tier; NOT IN CORE for widgets | widget-prop | no |
| P3 | Popup close button | none | PopupOptions.closeButton: boolean | — (callout dismisses on deselect; MLNCalloutView.dismissesAutomatically MLNCalloutView.h:106) | NOT IN CORE | reject | no |
| P3 | Popup trackPointer | none | popup.trackPointer() | — | NOT IN CORE | reject | no |
| P3 | Standalone popup (not bound to a marker) | none | new Popup().setLngLat(lnglat).setHTML(html).addTo(map) | — (callouts are always annotation-bound) | NOT IN CORE | reject | no |
| P3 | Terrain control | none | new TerrainControl(options: TerrainSpecification) | — | NOT IN CORE — no 3D terrain under include/mbgl (only color-relief shaders) | reject | no |
| P3 | Widget marker anchored to a LatLng | present | new Marker(options).setLngLat(lnglat).addTo(map) / marker.getLngLat() | -[MLNMapView addAnnotation:] (MLNMapView.h:1793), MLNPointAnnotation.coordinate (MLNPointAnnotation.h:50) | NOT USED BY US — mbgl::Map::addAnnotation (map/map.hpp:132) exists but ours is a Flutter overlay over MapLibreMapProjector (projector.dart:24) | widget-prop | no |
| P3 | mbgl legacy annotation API (SymbolAnnotation / LineAnnotation / FillAnnotation) | none | — (never existed in gl-js) | the whole MLNAnnotation family sits on top of it: MLNAnnotation (MLNAnnotation.h:25), MLNPointAnnotation (MLNPointAnnotation.h:44), MLNAnnotationImage (MLNAnnotationImage.h:17), -addAnnotation: (MLNMapView.h:1793) | mbgl::Map::addAnnotation / updateAnnotation / removeAnnotation (map/map.hpp:132-134); addAnnotationImage / removeAnnotationImage / getTopOffsetPixelsForAnnotationImage (:128-130); types at annotation/annotation.hpp:17-64 | reject | no |

#### Proposed signatures

**Attribution HTML → text + links** — P0, `value-type`, evidence: would live beside the proposed ornaments/attribution.dart
```dart
@immutable class MapLibreAttribution { const MapLibreAttribution(this.text, {this.url, this.isFeedbackLink = false}); final String text; final Uri? url; final bool isFeedbackLink; static List<MapLibreAttribution> parseHtml(String html); }
```
> UPSTREAMS DISAGREE and Apple must win: the style spec's `attribution` field is an HTML fragment (`<a href="https://openstreetmap.org">© OpenStreetMap</a>`), gl-js just sets innerHTML, and we cannot without an HTML dependency. Apple's structured MLNAttributionInfo is the model, including the `isFeedbackLink` flag (a link that is a feedback tool, not a credit). Keep parseHtml narrow — anchors and text only, entity-decoded, everything else stripped — and TEST it against the real strings from OpenFreeMap, MapTiler, Stadia and the MapLibre demotiles; a parser that silently drops a required credit is worse than showing raw markup.

**Attribution data from the style (source attribution strings)** — P0, `capability-interface`, evidence: no shim entry point — packages/maplibre_flutter_core/src/maplibre_flutter_core.h has no attribution function (see the mbl_* index: create/set_style/camera/resize/gestures/projection/source+layer json/images/transition/query/frames/models/destroy). Would live in maplibre_flutter_core.h beside mbl_map_query_rendered_features (:246) and be surfaced through a new capability interface in packages/maplibre_flutter_platform_interface/lib/src/.
```dart
abstract interface class MapLibreAttributionSource { List<MapLibreAttribution> get attributions; } — feature-detected with `is`, implemented by the five native controllers and the WASM web controller. New C entry point: `FFI_PLUGIN_EXPORT char *mbl_map_style_attributions(MblMap *map);` returning a JSON array `[{"sourceId":…,"html":…}]`, freed with mbl_string_free.
```
> Blocks the row above. Must also re-read on style load: CLAUDE.md §11 — 'loading a style overwrites style-level state', so the attribution list has to be refreshed from the didFinishLoadingStyle path, not cached at attach. Follow the existing mbl_map_query_rendered_features pattern (char* + mbl_string_free, maplibre_flutter_core.h:246,252) so no new ownership convention is introduced. Requires an ffigen regen on macOS.

**Attribution — rendered on the map (LEGAL OBLIGATION)** — P0, `widget-prop`, evidence: NOTHING ANYWHERE. `grep -rn attribution packages/ --include=*.dart` outside third_party returns only generated style-source fields (packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart:76,181,269,365 — the source's own `attribution` key) and one comment in example/lib/main.dart:236 about a 3D model asset. Would live in a new packages/maplibre_flutter/lib/src/ornaments/attribution.dart, rendered from maplibre_map.dart:295 (the Stack that currently only appears when markers exist).
```dart
on MapLibreMap: `final MapLibreAttributionOptions? attribution;` defaulting to `const MapLibreAttributionOptions()` (ON), with `null` meaning off. `@immutable class MapLibreAttributionOptions { const MapLibreAttributionOptions({bool compact = true, List<MapLibreAttribution> customAttribution = const [], MapLibreOrnamentPosition position = MapLibreOrnamentPosition.bottomRight, EdgeInsets margins = const EdgeInsets.all(4), TextStyle? textStyle, ValueChanged<Uri>? onTapLink}); }`
```
> THE headline gap of this domain. Both upstreams default it ON and Apple's header says in so many words not to remove it; we ship it OFF because we ship it not at all. Default ON, `null` to disable, and document that disabling may violate the tile provider's terms. `onTapLink` rather than a url_launcher dependency (the app decides how to open a URL) — but ship an example that wires it. Needs the C ABI row below.

**Attribution compact mode** — P1, `widget-prop`, evidence: would live in the proposed MapLibreAttributionOptions
```dart
final bool compact; // in MapLibreAttributionOptions, default true — an ⓘ affordance that expands to a sheet listing every MapLibreAttribution
```
> Both upstreams converge here in practice (Apple is compact-only, gl-js defaults compact on the Map option), so default `true`. The expanded sheet should be a plain showModalBottomSheet-shaped widget the app can override, not baked-in Material chrome — this package should not force a design system.

**Compass ornament** — P1, `widget-prop`, evidence: would live in packages/maplibre_flutter/lib/src/ornaments/compass.dart; data is already available — bearing from MapCamera.bearing (packages/maplibre_flutter_platform_interface/lib/src/camera.dart:26) ticked by MapLibreMapController.onCameraChanged (maplibre_map_controller.dart:75)
```dart
on MapLibreMap: `final MapLibreCompassOptions? compass;` default `const MapLibreCompassOptions()`. `class MapLibreCompassOptions { const MapLibreCompassOptions({MapLibreOrnamentVisibility visibility = MapLibreOrnamentVisibility.adaptive, MapLibreOrnamentPosition position = MapLibreOrnamentPosition.topRight, EdgeInsets margins = const EdgeInsets.all(8), bool visualizePitch = false, VoidCallback? onTap /* default: animate bearing→0 */, WidgetBuilder? builder}); }`
```
> Real defect adjacent: we shipped rotate + tilt gestures on all five native tiers this branch, so users can now leave the map at an arbitrary bearing with no affordance to recover — which is exactly why Apple defaults showsCompassView to YES. Zero engine work: bearing already ticks through onCameraChanged, and reset is `camera.move(current.copyWith(bearing: 0), duration: …)`. Take Apple's default position (top-right) and adaptive visibility; take gl-js's `visualizePitch` name.

**Custom / additional attribution text** — P1, `widget-prop`, evidence: would live in the proposed MapLibreAttributionOptions
```dart
final List<MapLibreAttribution> customAttribution; // gl-js's name, our structured element type
```
> Take gl-js's field name verbatim (`customAttribution`) but the element type is MapLibreAttribution, not String, so an app can attach a link. Needed by anyone mixing their own data layers into someone else's basemap — which is most apps that reach for the layers API.

**Marker pixel offset** — P1, `widget-prop`, evidence: would live in packages/maplibre_flutter/lib/src/marker.dart (field) + packages/maplibre_flutter/lib/src/marker_overlay.dart:231-234 (applied to dx/dy)
```dart
final Offset offset; // default Offset.zero — added to MapLibreMarker, applied after alignment: dx = pos.dx - anchorX + offset.dx
```
> The single most-missed marker feature. Every real app needs it: a callout tail, a pin shadow, or nudging co-located markers apart. Three lines in _MarkerFlowDelegate.paintChildren. Note the ORDER: alignment first (which point of the box), then offset (how far to push it) — gl-js composes them the same way.

**Marker tap / click callback** — P1, `widget-callback`, evidence: no field on MapLibreMarker (marker.dart has only drag callbacks); an app must wrap `child` in its own GestureDetector — example/lib/main.dart:1131-1148 does exactly that. Hit-testing works because Flow hit-tests painted children (marker_overlay.dart:13-15).
```dart
final VoidCallback? onTap; // wraps child in a GestureDetector when non-null, mirroring how `draggable` is handled at marker_overlay.dart:158
```
> Cheap (≈5 lines in _MarkerOverlayState._wrap) and it removes the single most common piece of boilerplate. Also fixes a subtle trap: a marker with BOTH a user GestureDetector and `draggable: true` currently nests two detectors and the tap/pan arena resolution is left to the app.

**Ornament position (four corners)** — P1, `value-type`, evidence: no ornaments exist, so no positioning type; would live in a new packages/maplibre_flutter/lib/src/ornaments/ornament.dart
```dart
enum MapLibreOrnamentPosition { topLeft, topRight, bottomLeft, bottomRight }
```
> The rare case where gl-js and Apple AGREE exactly on the value set, so there is nothing to choose — only spelling. Use Apple's type NAME (`Ornament`, which reads correctly for a native map) with Dart camelCase values that map 1:1 onto gl-js's hyphenated strings. Reject Android's Gravity ints (platform-specific, 20+ values, meaningless on desktop). This type is a prerequisite for the attribution, compass, scale-bar and logo rows.

**Popup / callout attached to a marker** — P1, `value-type`, evidence: would live in a new packages/maplibre_flutter/lib/src/popup.dart + a field on marker.dart; rendering in marker_overlay.dart
```dart
@immutable class MapLibrePopup { const MapLibrePopup({required Widget child, Alignment alignment = Alignment.bottomCenter, Offset offset = Offset.zero, bool closeOnMapTap = true, bool closeOnCameraMove = false, double? maxWidth, VoidCallback? onClose}); } ; and on MapLibreMarker: `final MapLibrePopup? popup; final bool popupOpen;`
```
> Table stakes — every competing Flutter map plugin has this and it is the second thing a user asks for after markers. gl-js naming for the type and its options; ADAPTED binding: gl-js's `setPopup` + `togglePopup()` becomes declarative `popup` + `popupOpen`, matching how markers themselves work. gl-js's `closeOnClick`/`closeOnMove` renamed `closeOnMapTap`/`closeOnCameraMove` because 'click' and 'move' are ambiguous in Flutter (a tap on WHAT, a move of WHAT) — note the rename in the dartdoc. Implementation is another Flow child anchored to the same point with a different alignment, so it inherits culling and swim-free anchoring for free.

**Scale bar ornament** — P1, `widget-prop`, evidence: would live in packages/maplibre_flutter/lib/src/ornaments/scale_bar.dart
```dart
on MapLibreMap: `final MapLibreScaleBarOptions? scaleBar;` default null (OFF, matching Apple's showsScale=NO). `class MapLibreScaleBarOptions { const MapLibreScaleBarOptions({MapLibreScaleUnit unit = MapLibreScaleUnit.metric, double maxWidth = 100, MapLibreOrnamentPosition position = MapLibreOrnamentPosition.bottomLeft, EdgeInsets margins = const EdgeInsets.all(8), Color? primaryColor, Color? secondaryColor}); }` + `enum MapLibreScaleUnit { metric, imperial, nautical }`
```
> Take gl-js's `unit` vocabulary (three values incl. nautical — Apple only has a metric boolean, MLNMapView.h:347) and gl-js's `maxWidth`; take Apple's colour knobs (MLNScaleBar.h:19-22) and its adaptive-visibility behaviour. Default OFF, matching Apple. Implementation is pure Dart: metresPerPixel = 156543.03392 * cos(lat*pi/180) / 2^zoom (the exact expression at util/projection.hpp:47-53), then snap to a 1/2/5×10ⁿ round number. VERIFICATION TRAP (CLAUDE.md §7): test at several latitudes AND against a known distance, not just self-consistency — a cos(lat) that is dropped or applied twice still produces a plausible-looking bar at the equator.

**User-location puck** — P1, `widget-prop`, evidence: nothing; would live in packages/maplibre_flutter/lib/src/ornaments/user_location.dart (drawn as a marker-like overlay child) plus a source interface in the platform interface package
```dart
on MapLibreMap: `final MapLibreUserLocationOptions? userLocation;` default null. `class MapLibreUserLocationOptions { const MapLibreUserLocationOptions({required MapLibreLocationSource source, MapLibreUserTrackingMode trackingMode = MapLibreUserTrackingMode.none, bool showAccuracyCircle = true, bool showUserHeading = false, Widget? puck}); }` + `abstract interface class MapLibreLocationSource { Stream<MapLibreUserLocation> get positions; }`
```
> Table stakes — every competing Flutter map plugin shows a puck, and it is the most common single reason to reach for a different package. THE DESIGN CALL: do not take a geolocation dependency. gl-js's GeolocateControl works only because the browser has an ambient Geolocation API; Apple/Android bake in CoreLocation/FusedLocation. We follow the SDKs' SPLIT (position source ≠ puck ≠ button) and make the source an interface the app implements over geolocator/location, with an example showing it. Everything else is Dart: the puck is a widget at a projected point, exactly like a marker.

**Accuracy circle** — P2, `widget-prop`, evidence: would live beside the proposed user_location.dart
```dart
final bool showAccuracyCircle; // in MapLibreUserLocationOptions, default true
```
> Take gl-js's field name. Implementation subtlety worth recording: the circle's radius is in METRES, so as a widget it must be re-sized per camera tick from metresPerPixel (the same util/projection.hpp:47 maths as the scale bar). The alternative — a real circle layer via layers.addSource/addLayer with `circle-pitch-alignment: map` — scales correctly for free and also tilts with the ground. Prefer the layer; keep the puck itself a widget.

**Cluster expansion zoom / children / leaves** — P2, `capability-interface`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart (interface) + maplibre_flutter_core/src/maplibre_flutter_core.h (shim) + map_layers_controller.dart (app-facing)
```dart
on MapLibreStyleLayers: `double? clusterExpansionZoom(String sourceId, int clusterId); String? clusterLeavesJson(String sourceId, int clusterId, {int limit = 10, int offset = 0});` surfaced as `layers.getClusterExpansionZoom(...)` / `layers.getClusterLeaves(...)` (gl-js names)
```
> The missing half of clustering: tapping a cluster should zoom to exactly the level where it splits, and that number lives in supercluster — it cannot be guessed. gl-js and Android both expose it, Apple does not; take gl-js's three method names since they are also Android's. Needs shim functions reaching through GeoJSONSource::impl(), so plan an ffigen regen on macOS. Pair it with a cluster-tap example — this is what turns addPoints(cluster: true) from a demo into a usable feature.

**Cluster feature access (id, point count)** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:15 MapLibreQueriedFeature with isCluster (:27) and pointCount (:30); `cluster_id` reachable only as a raw map entry via `.properties['cluster_id']`
```dart
on MapLibreQueriedFeature: `int? get clusterId => (properties['cluster_id'] as num?)?.toInt();`
```
> One getter, and it is the prerequisite for the next row — you cannot expand a cluster without its id. Adopt Apple's semantics (a missing id is 'not a cluster') but not its sentinel constant MLNClusterIdentifierInvalid; Dart has `null`.

**Custom controls / addControl** — P2, `widget-prop`, evidence: the widget's Stack is private (maplibre_map.dart:295-303) and only appears when markers is non-empty, so today an app must build its own outer Stack
```dart
on MapLibreMap: `final List<Widget> controls;` (default const []) rendered in the map's Stack, with `class MapLibreOrnament extends StatelessWidget { const MapLibreOrnament({required MapLibreOrnamentPosition position, EdgeInsets margins, required Widget child}); }` as the positioner
```
> EXPLICITLY ADAPTED, and worth writing down: gl-js's IControl/addControl/removeControl/hasControl trio is imperative registration of DOM nodes; a Flutter widget list is add/remove/query by construction, so binding the trio would be pure ceremony. The one thing `controls` buys over the app's own outer Stack is that ornaments live INSIDE the map's clip and share its coordinate space with the built-in ones — worth having, but it is sugar, not capability. On the web tier note CLAUDE.md §11: pointer_interceptor is needed for overlays drawn over a gl-js map, though not over our WASM canvas.

**Default marker visual (pin)** — P2, `widget-prop`, evidence: no default: MapLibreMarker.child is `required` (marker.dart:19). Every example builds its own (example/lib/main.dart:1131-1176).
```dart
class MapLibrePin extends StatelessWidget { const MapLibrePin({Color color = const Color(0xFF3FB1CE), double scale = 1}); } — so `MapLibreMarker(point: p, child: const MapLibrePin())` is the one-liner
```
> Adopt gl-js's exact default colour #3FB1CE and scale semantics so screenshots match the canonical docs. This is a documentation/adoption feature more than a capability one: 'draw a marker' should be one line in the README, and today it is fifteen. Keep `child` required (no magic default) — MapLibrePin is opt-in and the pin's anchor should be Alignment.bottomCenter.

**Engine-drawn polygon helper + GeoJsonData.polygon** — P2, `controller-namespace`, evidence: GeoJsonData has url/inline/points/lineThrough only (packages/maplibre_flutter/lib/src/style/geojson_data.dart:16,19,28,59) — no polygon factory; FillLayer is generated but unhelped
```dart
factory GeoJsonData.polygon(List<LatLng> exterior, {List<List<LatLng>> holes = const [], Map<String, Object?>? properties}); void layers.addPolygon(String id, List<LatLng> exterior, {List<List<LatLng>> holes, Color fillColor, Color? outlineColor, String? beforeId});
```
> The `holes` parameter is the part people get wrong by hand: GeoJSON requires the exterior ring counter-clockwise and interior rings clockwise, and rings must be explicitly closed (first point repeated). Encode that once in the factory with a test, exactly as Apple's interiorPolygons (MLNPolygon.h:64) does. Same [lng,lat] flip discipline as the existing factories.

**Engine-drawn polyline helper** — P2, `controller-namespace`, evidence: GeoJsonData.lineThrough exists (packages/maplibre_flutter/lib/src/style/geojson_data.dart:59) and LineLayer is generated, but there is no `layers.addPolyline` counterpart to addPoints (map_layers_controller.dart:258)
```dart
void layers.addPolyline(String id, List<LatLng> points, {Color color, double width, List<double>? dashArray, String? beforeId}); void layers.setPolyline(String id, List<LatLng> points); void layers.removePolyline(String id);
```
> Symmetry with addPoints, and it closes the 'draw a route' use case that every navigation-flavoured app hits on day one. Pure Dart over the existing JSON path — GeoJsonData.lineThrough already does the [lng,lat] flip (geojson_data.dart:57-58). Naming: NOT `addPolylineAnnotation` — the annotation vocabulary belongs to the legacy tier we are declining.

**Fit the camera to a set of markers / coordinates** — P2, `controller`, evidence: would live in packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:311 (the explicit TODO comment listing fitBounds among the camera methods to add)
```dart
Future<void> camera.fitBounds(LatLngBounds bounds, {EdgeInsets padding = EdgeInsets.zero, double? maxZoom, Duration? duration}); plus Future<void> camera.fitMarkers(Iterable<LatLng> points, {EdgeInsets padding, Duration? duration})
```
> Overlaps the camera domain — flagged here because Apple files it as an ANNOTATION operation (`showAnnotations:`) and it is the #1 thing apps do after adding markers. Take gl-js's name `fitBounds` for the primitive and add `fitMarkers` as the annotation-flavoured sugar. Needs a C entry point over Map::cameraForLatLngs; note LatLngBounds does not exist in our Dart yet (would go in maplibre_flutter_platform_interface/lib/src/lat_lng.dart).

**Geolocate button (recentre on me)** — P2, `widget-prop`, evidence: would live in packages/maplibre_flutter/lib/src/ornaments/geolocate.dart
```dart
class MapLibreGeolocateButton extends StatelessWidget { const MapLibreGeolocateButton({required MapLibreMapController controller, ...}); } — with `trigger()` on its state, gl-js's name
```
> gl-js is the only upstream with a built-in button, so this row is gl-js-shaped by default. Ship it as an opt-in widget in `controls`, not a default ornament, and keep the tri-state visual gl-js established (inactive / active / active-lock) because users recognise it.

**Heading / course indicator** — P2, `widget-prop`, evidence: would live beside the proposed user_location.dart
```dart
final bool showUserHeading; // in MapLibreUserLocationOptions, default false
```
> gl-js's name; Apple's default (off). Note the distinction both SDKs make and gl-js blurs: HEADING is where the device points (magnetometer) and COURSE is where it is travelling (GPS track) — Apple encodes it in the tracking mode (followWithHeading vs followWithCourse) and draws a fan for heading, an arrow for course. Our MapLibreUserLocation value type should carry both fields so a puck can render either.

**Map tap → LatLng (the annotation-adjacent hit test)** — P2, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:69 (onTap), :285-292 (unprojects via the projector; marker hits win by hit-test order)
```dart
— unchanged; consider `final ValueChanged<LatLng>? onLongPress;` to match Android's OnMapLongClickListener (the usual 'drop a pin here' gesture)
```
> Included in this domain because 'long-press to add a marker' is the canonical annotation interaction and we have no long-press at all (§7 line 509 `Native long-press` ❌ everywhere). The tap half is done and correct — a marker consumes its own tap because the overlay sits above the detector in the Stack (maplibre_map.dart:296-302).

**MapLibre logo ornament** — P2, `widget-prop`, evidence: would live in packages/maplibre_flutter/lib/src/ornaments/logo.dart (asset would need bundling in the maplibre_flutter package)
```dart
on MapLibreMap: `final MapLibreLogoOptions? logo;` default null (OFF). `class MapLibreLogoOptions { const MapLibreLogoOptions({MapLibreOrnamentPosition position = MapLibreOrnamentPosition.bottomLeft, EdgeInsets margins = const EdgeInsets.all(4), Widget? logo}); }`
```
> DIVERGE from both upstreams on the DEFAULT: Apple and gl-js default the logo ON, we should default it OFF. Reason: their logo is the vendor's own mark shown by the vendor's own SDK; ours would be a third-party plugin injecting a brand into someone's app unasked. Attribution (the legal part) is a separate, on-by-default row. Note the asset licensing question before bundling the MapLibre wordmark — that is a decision for the maintainer, not an implementation detail.

**Marker opacity** — P2, `widget-prop`, evidence: would live in packages/maplibre_flutter/lib/src/marker.dart (app can already wrap `child` in Opacity — but then it costs a save-layer per marker, which is exactly what the overlay's design avoids)
```dart
final double opacity; // 0..1, default 1 — applied via context.paintChild(i, opacity: …) which FlowPaintingContext supports natively
```
> Flow's paintChild already takes an `opacity` argument, so this is free and avoids the save-layer an app-level Opacity widget would cost. Do NOT add `opacityWhenCovered`: it means 'occluded by terrain or the globe', and neither exists in mbgl.

**Marker rotation** — P2, `widget-prop`, evidence: would live in packages/maplibre_flutter/lib/src/marker.dart + marker_overlay.dart:248 (compose into the Matrix4 passed to paintChild)
```dart
final double rotation; // degrees clockwise, default 0
```
> Implement by composing Matrix4.rotationZ about the alignment anchor into the existing translation at marker_overlay.dart:248 — no relayout, still one transform per child. Watch the house rule on handedness: gl-js `rotation` is clockwise on screen; do NOT reuse the model-matrix reasoning from CLAUDE.md §11 (that is left-handed map space and a different axis).

**Marker rotationAlignment** — P2, `value-type`, evidence: would live in packages/maplibre_flutter/lib/src/marker.dart + marker_overlay.dart (needs the camera bearing, available via controller.camera.getPosition() / the projector tick)
```dart
enum MapLibreAlignment { map, viewport, auto } ; final MapLibreAlignment rotationAlignment; // default MapLibreAlignment.auto
```
> gl-js naming wins over Apple's boolean because the enum is the same vocabulary the style spec (and therefore our generated typed API) already uses for icon-rotation-alignment — one word means one thing across both marker tiers. 'map' needs the presented bearing, which the projector's camera tick already implies; expose bearing on MapLibreMapProjector rather than round-tripping getCamera() per frame.

**Ornament visibility (adaptive / visible / hidden)** — P2, `value-type`, evidence: would live in the proposed ornaments/ornament.dart
```dart
enum MapLibreOrnamentVisibility { adaptive, visible, hidden }
```
> UPSTREAMS DISAGREE: gl-js boolean, Android boolean-plus-fade-flag, Apple three-state. Apple wins because its three states subsume the other two exactly — `adaptive` IS 'fade when facing north' for the compass and 'hide when the scale is meaningless' for the scale bar (Apple documents that at MLNMapView.h:320-327: the scale bar only appears below ~800 km visible width).

**User tracking mode (camera follows the user)** — P2, `value-type`, evidence: would live beside the proposed user_location.dart, driving controller.camera.move
```dart
enum MapLibreUserTrackingMode { none, follow, followWithHeading, followWithCourse }
```
> Take Apple's four-value enum verbatim (MLNMapView.h:82-108) — it is strictly richer than gl-js's boolean and than Android's three CameraModes, and the names are self-describing. Copy Apple's fallback semantics too, documented in that header: a user pan drops to `none`, a user rotate drops FollowWithHeading to Follow, a user zoom does NOT break tracking. Those rules are the whole feature; getting them wrong makes the map fight the user.

**Zoom in / out buttons** — P2, `controller`, evidence: would live in packages/maplibre_flutter/lib/src/ornaments/navigation.dart; the camera primitive it needs (`camera.zoomIn/zoomOut`) is also missing — maplibre_map_controller.dart:311 lists zoomBy/zoomTo as TODO
```dart
class MapLibreZoomControl extends StatelessWidget { const MapLibreZoomControl({required MapLibreMapController controller, ...}); } — plus `camera.zoomIn({Duration? duration})` / `camera.zoomOut({...})` / `camera.zoomBy(double delta, {Offset? anchor, Duration? duration})`
```
> UPSTREAMS DISAGREE and the split is by input device: gl-js has zoom buttons because a mouse-only user needs them, both mobile SDKs dropped them because pinch is universal. We span BOTH — desktop (Windows/Linux/macOS) is exactly gl-js's situation. So ship it as an opt-in widget (default off), not a default ornament, and add the camera.zoomIn/zoomOut primitives regardless since they are useful without any UI.

**3D model annotations (our own tier)** — P3, `widget-prop`, evidence: MapLibreMap.models (maplibre_map.dart:66), MapLibreModel (packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:13), MapLibreModelHost (:105); implemented by ALL FIVE native controllers — android:44-46, ios:45-47, macos:35-37, linux:37-39, windows:41-43
```dart
— unchanged (already declarative via MapLibreMap.models, with controller.updateModel as the per-frame escape hatch)
```
> Listed here because the matrix files it under §6 Annotations. It is also the template the marker API should follow for anything imperative: declarative list + a controller method for the per-frame case, documented as such (maplibre_map.dart:60-65). No upstream has this at all.

**Apple callout accessory views and callout tap** — P3, `reject`, evidence: n/a
```dart
— (rejected; MapLibrePopup.child is an arbitrary widget, so accessories are just children with their own onTap)
```
> A UIKit-shaped API that exists because a UIKit callout has fixed slots. With an arbitrary Flutter child there are no slots to fill. Recording it keeps the reject explicit rather than looking like an oversight when someone diffs our surface against MLNMapViewDelegate.

**Engine-drawn point layer helper (bulk markers + clustering)** — P3, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:258-341 (addPoints), :365 (setPoints), :369 (removePoints)
```dart
— unchanged; this is ahead of all three upstreams
```
> Worth calling out as a differentiator in the README: no upstream has a one-call clustered-points helper, and ours refuses to guess a font (map_layers_controller.dart:248-257), which is the exact trap that makes hand-written cluster layers 404 their glyphs.

**Flutter widget → engine icon (icon-image)** — P3, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:387 (addWidgetIcon), :428 (rasterizeWidget), :123 (addImage) → platform interface style_layers.dart:47 → shim mbl_map_add_image (maplibre_flutter_core/src/maplibre_flutter_core.h:207)
```dart
— unchanged
```
> This is our answer to MLNAnnotationImage and it is a better one: the icon is authored as a Flutter widget rather than a bitmap asset. The two-pass loose/tight layout (map_layers_controller.dart:428-451) is subtle and load-bearing — do not 'simplify' it. Remember the rasterizer test rule (CLAUDE.md §11): toImage() needs tester.runAsync.

**Fullscreen control** — P3, `reject`, evidence: n/a
```dart
— (rejected)
```
> An app-window concern, not a map concern: on desktop it is window management, on mobile it is Navigator/SystemChrome, on web it is the Fullscreen API. Nothing the map can implement portably, and an app can put its own button in `controls`. Genuine ➖.

**Globe control** — P3, `reject`, evidence: n/a
```dart
— (rejected: no globe projection in the engine)
```
> The clearest hard stop in the domain and worth stating in the README's comparison table: an app that needs a globe needs gl-js, therefore the opt-in maplibre_flutter_web_gljs package — and cannot have it on the five native tiers at all.

**Imperative marker add / remove / move** — P3, `reject`, evidence: deliberately absent — MapLibreMap.markers (maplibre_map.dart:51) is the source of truth; diffing happens in the widget
```dart
— (rejected; use MapLibreMap.markers and rebuild)
```
> Explicit reject so the decision is on the record: all three upstreams are imperative here and we are not, by CLAUDE.md §3's three-bucket rule (mutable + declarative + low-frequency ⇒ widget prop). The one legitimate escape hatch — per-frame movement — is already covered by the models precedent (controller.updateModel, maplibre_map_controller.dart:226). If profiling ever shows a marker moving every frame is too slow declaratively, revisit with the SAME shape as models, not with addMarker/removeMarker.

**Marker anchor / alignment** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/marker.dart:37 (Alignment alignment = Alignment.center); applied at marker_overlay.dart:228-231
```dart
final Alignment alignment; — unchanged, plus a documented mapping table from gl-js PositionAnchor values (e.g. 'bottom' ⇒ Alignment.bottomCenter)
```
> ADAPTED naming, deliberately: Flutter Alignment is a continuous superset of PositionAnchor. Default matches gl-js ('center'). Only gap is documentation of the mapping.

**Marker className / CSS class management** — P3, `reject`, evidence: n/a
```dart
— (rejected)
```
> Pure DOM styling. The Flutter equivalent is 'build a different widget'. Genuine ➖ on all six columns including Web, since our web tier is WASM + Flutter widgets, not gl-js DOM markers.

**Marker custom content (arbitrary widget)** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/marker.dart:33 (final Widget child)
```dart
final Widget child; — unchanged
```
> Strictly better than all three upstreams: gl-js gets a DOM node, Apple gets a UIView, we get a live Flutter subtree with gestures and animation (example/lib/main.dart:1595 _PulsingMarker proves it).

**Marker drag lifecycle callbacks** — P3, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/marker.dart:46,50,54 (onDragStart / onDragUpdate / onDragEnd)
```dart
final ValueChanged<LatLng>? onDragStart, onDragUpdate, onDragEnd; — unchanged
```
> ADAPTED: gl-js's `drag` event is `onDragUpdate` here, to match Flutter's GestureDetector vocabulary (onPanUpdate). Say so in the dartdoc so gl-js porters find it.

**Marker draggable** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/marker.dart:43 (bool draggable); marker_overlay.dart:158-167 (GestureDetector), :112-131 (drag state machine)
```dart
final bool draggable; — unchanged
```
> Ours is arguably better engineered than gl-js's: the dragged marker is positioned from the LIVE POINTER in overlay space (marker_overlay.dart:39-40,121-125) rather than from its declarative point, so it cannot double-move when the app also updates `point` from the callback.

**Marker occlusion behind a pitched camera** — P3, `capability-interface`, evidence: projector.dart:34 `project(..., {List<bool>? visible})`; consumed at marker_overlay.dart:214,224
```dart
— unchanged
```
> Already correct and better than a naive port would be: skipping the child entirely rather than parking it offscreen also removes the phantom hit target (marker_overlay.dart:220-224). Worth a matrix row of its own so it does not get regressed.

**Marker pitchAlignment** — P3, `widget-prop`, evidence: would live in packages/maplibre_flutter/lib/src/marker.dart; needs more than MapLibreMapProjector.project (projector.dart:34) can give
```dart
final MapLibreAlignment pitchAlignment; // default MapLibreAlignment.auto
```
> The only marker row that genuinely costs a C ABI addition: laying a widget flat on the pitched ground plane needs the projection matrix, not a projected point. Proposed shim: `mbl_map_projection_matrix(MblMap*, double out[16])` reading the presented generation, so it composes with the existing swim-free anchoring (CLAUDE.md §11). Low priority — 'auto'/'viewport' (billboard, what we do today) is what almost every app wants.

**Marker repaintBoundary escape hatch** — P3, `widget-prop`, evidence: marker.dart:26 `this.repaintBoundary = false` — DEFAULT IS FALSE; applied at marker_overlay.dart:157
```dart
— unchanged
```
> Concrete, checkable matrix drift: the matrix advertises a default that is the opposite of the code, on a performance-sensitive flag. This is the kind of error that makes a reader distrust the whole document.

**Marker scalesWithViewingDistance (perspective scaling)** — P3, `widget-prop`, evidence: would live in packages/maplibre_flutter/lib/src/marker.dart
```dart
final bool scalesWithViewingDistance; // default false
```
> Apple-only concept; gl-js deliberately has no equivalent (its markers are always constant-size). Include for completeness but it is genuinely long tail — and it fights readability on a pitched map. Needs the same distance term as pitchAlignment, so schedule it with that row or not at all.

**Marker selection / selected state** — P3, `reject`, evidence: n/a — app state today
```dart
— (rejected; app holds selection in its own state and rebuilds the marker's child)
```
> UPSTREAMS DISAGREE and gl-js's silence is the tell: selection exists in Apple's API only because a callout has to be attached to something. With declarative widget markers the app already owns selection, and adding a parallel selection model inside the plugin would fight it. The one piece worth keeping from Apple is the callout trigger, covered by the `popupOpen` row below.

**Marker subpixel positioning** — P3, `reject`, evidence: marker_overlay.dart:248 Matrix4.translationValues(dx, dy, 0) with double dx/dy — we are ALWAYS subpixel
```dart
— (no API; document that positioning is always subpixel). If pixel-snapping is ever wanted: `final bool snapToPixel;`
```
> gl-js needs the flag because DOM transforms default to whole pixels for text crispness. Flutter composites in device pixels with anti-aliasing, so the flag has no analogue. Reject, and put a line in the matrix note so nobody 'implements' it later.

**Marker viewport culling** — P3, `controller`, evidence: marker_overlay.dart:240-246 (box entirely outside the overlay ⇒ no transform, no paint)
```dart
— internal; optionally expose `MapLibreMapController.visibleMarkers` mirroring Apple's visibleAnnotations
```
> Apple exposes the visible set; we compute it and throw it away. Low value in Flutter (the app owns the marker list and the projector is public, so it can recompute), but it is a one-line getter if someone asks.

**Marker z-order / paint order** — P3, `widget-prop`, evidence: implicit: marker_overlay.dart:217 iterates `markers` in list order and Flow paints in that order — so list order IS z-order, but nothing documents it and there is no per-marker control
```dart
final int zIndex; // default 0; overlay sorts by (zIndex, list index) before painting
```
> Neither gl-js nor Apple offers this, so we would be ahead of upstream — but the real-world need is concrete (pins nearer the viewer must overlap pins further away, i.e. sort by latitude). Minimum viable action is to DOCUMENT that list order is paint order; the field is optional sugar. If added, keep the sort stable or markers will flicker between frames.

**Popup close button** — P3, `reject`, evidence: would live in the proposed popup.dart
```dart
— (rejected: the popup's `child` draws its own close affordance and calls `onClose`)
```
> gl-js needs it because its popup chrome is library-drawn; ours is entirely app-drawn. Providing a plugin-drawn close button would force plugin-drawn chrome, which is the opposite of the design. `onClose` (proposed on MapLibrePopup) is the whole contract.

**Popup trackPointer** — P3, `reject`, evidence: would live in the proposed popup.dart
```dart
— (rejected for now; a hover-following tooltip is a plain Flutter MouseRegion over the map)
```
> Desktop/web-only interaction (needs a hover pointer). Achievable today with MouseRegion + controller.projector.unproject, so the plugin adds nothing. Revisit only if a desktop demo wants it.

**Standalone popup (not bound to a marker)** — P3, `reject`, evidence: would live in packages/maplibre_flutter/lib/src/maplibre_map.dart (a `popups` prop) — or not at all
```dart
— (rejected: express as `MapLibreMarker(point: p, child: popupBody)`)
```
> UPSTREAMS DISAGREE (gl-js yes, Apple no) and here Apple's model is the better fit: our marker IS an arbitrary widget at a point, so a standalone popup is a marker with a bubble child. Adding a second list of anchored widgets would duplicate the whole overlay for no capability. Say this in the docs — it is the answer to an FAQ, not a gap.

**Terrain control** — P3, `reject`, evidence: n/a
```dart
— (rejected: no terrain in the engine)
```
> Hard stop below the binding: a control toggling a feature the engine does not have. Revisit only if MapLibre Native ships terrain (the matrix's own rule 6 says re-check these flags when a feature graduates across engines).

**Widget marker anchored to a LatLng** — P3, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/marker.dart:16 (MapLibreMarker), packages/maplibre_flutter/lib/src/maplibre_map.dart:51 (MapLibreMap.markers), packages/maplibre_flutter/lib/src/marker_overlay.dart:21
```dart
const MapLibreMarker({required LatLng point, required Widget child, ...}) — unchanged
```
> **Matrix drift:** §6 line 423 `**maplibre_flutter widget markers**` — Android🧪 iOS🧪 macOS✅ Windows🧪 Linux🧪 **Web❌**. DISAGREES on Web: packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:44-49 implements MapLibreMapProjector, and maplibre_map.dart:295-303 renders the overlay whenever a projector exists — Web should be 🧪, not ❌.

**mbgl legacy annotation API (SymbolAnnotation / LineAnnotation / FillAnnotation)** — P3, `reject`, evidence: no shim entry point — packages/maplibre_flutter_core/src/maplibre_flutter_core.h exposes no mbl_map_add_annotation
```dart
— (rejected; use MapLibreMap.markers for interactive points and layers.* for bulk data)
```
> RECORD THE DECISION so nobody 'discovers' this API later and thinks it is a shortcut. It IS in core and it IS bindable, and it is still the wrong move: a SymbolAnnotation is a point plus an icon name (annotation.hpp:17-25) with no rotation, offset, alignment, drag or callout, so binding it would give strictly LESS than the widget overlay we already ship and less than the style-layer path. Upstream is migrating away from it too (Android's version is deprecated, the annotation plugin moved to a separate repo). Ten matrix rows currently imply a gap that we are choosing not to have.


### Images, sprites, glyphs & localization

#### Engine ceiling

**Hard stops — things mbgl-core genuinely cannot do, so the five native tiers and web-WASM cannot either.**

1. **Runtime sprite mutation: `setSprite` / `addSprite` / `removeSprite` are NOT IN CORE.** `include/mbgl/style/style.hpp` (the entire public style API) has no sprite accessor. Sprites are modelled as `mbgl::style::Sprite {id, spriteURL}` (`include/mbgl/style/sprite.hpp:8-15`) but are constructed only inside `Style::Impl::parse()` and owned by a private `SpriteLoader` (`src/mbgl/style/style_impl.hpp:115`, `spritesLoadingStatus` at `:124`). The only escape is read the style JSON → patch `$root.sprite` → `loadJSON` — a full style reload.

2. **Runtime glyph-URL mutation: `setGlyphs` is NOT IN CORE.** `Style::Impl::getGlyphURL()` exists (`src/mbgl/style/style_impl.hpp:92`, member at `:117`) but there is **no setter anywhere** — `glyphURL` is written only during `parse()`. Same style-reload escape hatch. Note the asymmetry: `getGlyphs` **is** implementable (the getter is right there), only `setGlyphs` is blocked; the FEATURE_MATRIX conflates them into one ➖ row (line 570-571).

3. **Animated / dynamic style images are NOT IN CORE.** `mbgl::style::Image` holds a `PremultipliedImage` behind `Immutable<Impl>` (`include/mbgl/style/image.hpp:90`) — there is no `render()` callback, no `onAdd`/`onRemove`, and no way to mutate pixels in place. gl-js's `StyleImageInterface` has no engine counterpart. The only substitute is a Dart timer calling `updateImage`, which does a full pixel upload each tick.

4. **`listImages` is not in the *public* headers** — `Style` exposes `getImage`/`addImage`/`removeImage` (`include/mbgl/style/style.hpp:49-51`) but no enumeration. It is reachable through `Style::Impl::getImageImpls()` (`src/mbgl/style/style_impl.hpp:96`), a private header. That is not a stop (we already include private mbgl headers deliberately — `mbgl/map/transform_state.hpp` at `maplibre_flutter_core.cpp:27`, the `style/conversion/*` family at `:36-39`), but it is the one row in this domain whose implementation can break on an `MBGL_CORE_VERSION` bump. Guard it with a native harness test.

5. **`localizeLabels` is NOT IN CORE.** There is no localization entry point in `include/mbgl/style/style.hpp`. Apple implements it entirely above the engine, in ObjC, by rewriting each symbol layer's `text-field` expression (`MLNStyle.h:302` → `NSExpression+MLNAdditions.h:261`). For us that means it is Dart-level work — and it is **blocked on a read/write layer-property API we do not have** (no `getLayer`, no `getLayoutProperty`, no `setLayoutProperty` anywhere in `packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart`, which has only `addLayerJson`/`removeLayer`).

6. **Local glyph rasterization is a per-platform hole in OUR build, not an mbgl one.** `mbgl::Renderer` takes `localFontFamily` (`include/mbgl/renderer/renderer.hpp:47`) and we already pass `std::nullopt` into `HeadlessFrontend`'s corresponding parameter (`src/mbgl/gfx/headless_frontend.hpp:34`, call site `maplibre_flutter_core.cpp:913`). But only the Apple arm links the real rasterizer (`platform/darwin/core/local_glyph_rasterizer.mm`, `src/CMakeLists.txt:134`). Android, Linux, Windows and web all get `platform/default/src/mbgl/text/local_glyph_rasterizer.cpp`, whose `canRasterizeGlyph` returns **false** unconditionally (lines 11-13). So `localIdeographFontFamily` will be silently inert on four of six tiers unless someone writes a FreeType-backed default — which is nearer than it sounds, because FreeType is already linked (next point).

7. **Not a ceiling — a capability we have and did not know about: HarfBuzz complex-text shaping is compiled in on every arm.** `MLN_TEXT_SHAPING_HARFBUZZ` defaults `ON` (`third_party/maplibre-native/CMakeLists.txt:21`) and the HarfBuzz/FreeType block at `CMakeLists.txt:1012-1040` runs **before** the `MLN_WITH_CORE_ONLY` early return at `:1266`; we never set the option off. Combined with the `font-faces` root property in the vendored spec (`scripts/style-spec-reference/v8.json`, `$root['font-faces']`) and `FontFace{type,name,url,ranges}` (`include/mbgl/text/glyph.hpp:165-188`), Devanagari/Khmer/Arabic shaping works today, declaratively, on all six tiers — with no equivalent in maplibre-gl-js. It is absent from FEATURE_MATRIX §8 entirely.

8. **Also not a ceiling: image decoding is already in core.** `mbgl::decodeImage(const std::string&) → PremultipliedImage` (`include/mbgl/util/image.hpp:179`) handles PNG/JPEG/WebP on every arm we build. An `addImageEncoded(id, pngBytes)` entry point therefore needs no Dart-side decode and no new dependency — relevant to the `loadImage` and `ImageProvider` rows.

9. **The observer surface is far richer than we use.** `mbgl::MapObserver` already declares `onStyleImageMissing` (`include/mbgl/map/map_observer.hpp:67`), `onCanRemoveUnusedStyleImage` (`:70`), `onGlyphsLoaded/Error/Requested` (`:81-83`) and `onSpriteLoaded/Error/Requested` (`:89-91`). Our `FrameObserver` (`packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872`) overrides exactly two of them. Every "event" row in this domain is an override plus a callback marshal, not new engine work. Two constraints that must be respected: the renderer-side `onStyleImageMissing` hands you a `done` continuation that **must** be invoked (`include/mbgl/renderer/renderer_observer.hpp:66-67`, fired from `src/mbgl/renderer/image_manager.cpp:276`), and `onCanRemoveUnusedStyleImage` returns a `bool` **synchronously on the render thread** — so it cannot be a Dart round-trip and must be a shim-side policy.

10. **A real defect that the ceiling explains:** `Style::Impl::parse()` does `images = makeMutable<ImageImpls>()` (`src/mbgl/style/style_impl.cpp:104`), wiping every runtime image on any style load. Our `FrameObserver::onDidFinishLoadingStyle` (`maplibre_flutter_core.cpp:890`) replays transition options and model layers but **not** images — so every `addImage`/`addWidgetIcon` silently disappears when `MapLibreMap.style` changes. This is the p0 row.

#### Naming decisions

**Where gl-js and the SDKs disagree, and what I picked.**

1. **Image CRUD verb set — gl-js wins outright.** gl-js has the widest and most orthogonal surface (`addImage`/`updateImage`/`hasImage`/`getImage`/`removeImage`/`listImages`/`loadImage`); Apple has only three verbs (`setImage:forName:`/`imageForName:`/`removeImageForName:`) and no list; Android has the three plus batch (`addImages`) and async variants. I take **gl-js names verbatim** and add Android's `addImages` as a batch overload, because a batch call is a real perf win over our C ABI (one `post()` instead of N). I explicitly **reject Apple's `setImage:forName:` argument order** — id-first (`addImage(id, …)`) matches gl-js, the style spec, and our existing `addImage`.

2. **Image metadata — gl-js `StyleImageMetadata` is the canonical bundle** (`pixelRatio`, `sdf`, `stretchX`, `stretchY`, `content`, `textFitWidth`, `textFitHeight`), and it maps 1:1 onto `mbgl::style::Image`'s constructor (style/image.hpp:37-45). Android exposes the same fields as positional `List<ImageStretches>`/`ImageContent` params; Apple exposes them only implicitly (it derives `sdf` from `UIImage.isTemplate` and stretch from `capInsets`, which is an Apple-idiom translation with no cross-platform meaning). **Adapted to Flutter idiom:** gl-js passes an options *object*; Dart gets **named optional parameters** on `addImage`, which keeps the existing call sites source-compatible (pure addition, zero contract churn) while covering the whole metadata set. `ImageContent`/`TextFit`/`ImageStretch` become small value types named after the mbgl/spec terms, not after `UIEdgeInsets`.

3. **Namespace placement.** All of this currently lives on `controller.layers` (`MapLibreLayersController`), whose doc comment is about *engine-drawn datasets*, not style resources. I propose an app-facing **`controller.images`** namespace (`MapLibreImagesController`) forwarding to the **same** `MapLibreStyleLayers` platform capability — exactly the sanctioned pattern in CLAUDE.md §3 ("the namespace is a pure app-facing wrapper forwarding to the flat platform controller, so it does not ripple into the interface"). No new capability interface, no impl churn: `MapLibreStyleLayers` gains methods, five controllers gain forwards. `layers.addImage`/`layers.removeImage` stay as aliases (deprecate no earlier than the next major). This mirrors Apple, where images hang off `MLNStyle`, not off a layer object.

4. **Localization — Apple's shape wins, because gl-js has none.** I verified the gl-js `Map` docs: there is **no** `setLanguage`; language switching on web is a plugin (`@maplibre/maplibre-gl-language`), so there is nothing upstream to copy. Apple ships `-[MLNStyle localizeLabelsIntoLocale:]` (MLNStyle.h:302) plus the expression-level primitive `-[NSExpression mgl_expressionLocalizedIntoLocale:]` (NSExpression+MLNAdditions.h:261). I take Apple's name, **adapted to Flutter idiom**: `Locale?` instead of `NSLocale*`, and `localizeLabels({Locale? locale})` rather than the ObjC `…IntoLocale:` suffix. Semantics preserved: `null` = system preferred language, `Locale('mul')` = local/native language, as documented at MLNStyle.h:298-301.

5. **RTL text plugin — rejected, and the matrix agrees.** `setRTLTextPlugin`/`getRTLTextPluginStatus` exist only because gl-js cannot bundle ICU. Our engine compiles ICU + bidi into `mbgl-core` on **every** arm (`src/CMakeLists.txt:131,160,186,273,291,381,400,497,516`; `web/CMakeLists.txt:80-85,105-116`), so RTL shaping is unconditional. Binding a plugin loader would be binding a no-op. I do propose one row: a read-only `MapLibreTextCapabilities` probe so an app can *assert* RTL/complex-text support rather than guess.

6. **Events — adapted from gl-js `on('styleimagemissing')` to Flutter idiom.** We have no event bus and no `on`/`off`; the house pattern is a widget callback (`MapLibreMap.onTap`) or an optional capability. gl-js 5.x has moved past the event anyway: `map.setMissingStyleImageResolver(resolver)` is the modern, *awaitable* form and matches Apple's synchronous `-mapView:didFailToLoadImage:` (MLNMapViewDelegate.h:339) far better than an event does. So: **`MapLibreMap.onStyleImageMissing`**, an async resolver returning image bytes — gl-js's resolver semantics, Apple's delegate ergonomics, Flutter's callback-prop bucket.

7. **Sprite / glyph runtime setters — named after gl-js, but they are style-document edits.** `setSprite`/`addSprite`/`setGlyphs` have no mbgl equivalent (see the ceiling notes); implementing them means read style JSON → patch the root property → `loadJSON`. I keep the gl-js names because that is what users will look for, but every one of them is gated behind a `getStyleJson` C ABI entry point we do not have. That dependency is itself a row.

8. **`text-font` stays `List<String>`** — that matches the style spec, gl-js, Apple's `NSArray<NSString*>` fontStack, and mbgl's `FontStack = std::vector<std::string>`. The gotcha is not the type, it is the *semantics*: mbgl comma-joins the whole list into **one** `{fontstack}` request (`util/font_stack.cpp:11-13` → `storage/resource.cpp:76`), so it is a server-side composite request, **not** a client-side fallback chain. That is a doc fix, not an API change, and it is the single most common cause of blank labels in this repo (`map_layers_controller.dart:248-254` already works around it for cluster counts).

#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | Runtime images survive a style reload (re-register on onDidFinishLoadingStyle) | none | — (gl-js `setStyle` has a `diff` mode that preserves runtime images; no explicit API) *(unverified)* | — (same defect exists on Apple; the SDK does not re-register either) | mbgl::style::Style::Impl::parse() → `images = makeMutable<ImageImpls>()` (src/mbgl/style/style_impl.cpp:104) wipes every runtime image | controller-namespace | no |
| P1 | addImage (runtime style image, raw premultiplied RGBA) | present | map.addImage(id: string, image: StyleImageSource, options?: Partial<StyleImageMetadata>): this | -[MLNStyle setImage:forName:] (MLNStyle.h:270) | mbgl::style::Style::addImage(std::unique_ptr<Image>) (include/mbgl/style/style.hpp:50) | controller-namespace | yes |
| P1 | addImage from a Flutter ImageProvider / ui.Image (assets, network, memory) | partial | map.addImage(id, image) accepts HTMLImageElement \| ImageBitmap \| ImageData — i.e. the platform's native image types | -[MLNStyle setImage:forName:] takes MLNImage (= UIImage/NSImage, MLNTypes.h:10,13) — i.e. the platform's native image type | mbgl::decodeImage (include/mbgl/util/image.hpp:179) already decodes PNG/JPEG/WebP inside core, on every arm we build | controller-namespace | no |
| P1 | hasImage | none | map.hasImage(id: string): boolean | — (no direct equivalent; `imageForName:` returning nil is the idiom, MLNStyle.h:253) | mbgl::style::Style::getImage(const std::string&) → std::optional<Image> (include/mbgl/style/style.hpp:49). Also directly: mbgl::HeadlessFrontend::hasImage(const std::string&) (src/mbgl/gfx/headless_frontend.hpp:51) — literally the same name. | controller-namespace | yes |
| P1 | removeImage | present | map.removeImage(id: string): this | -[MLNStyle removeImageForName:] (MLNStyle.h:277) | mbgl::style::Style::removeImage(const std::string&) (include/mbgl/style/style.hpp:51) | controller-namespace | no |
| P1 | styleimagemissing — supply an image on demand when the style asks for one it does not have | none | map.on('styleimagemissing', (e: MapStyleImageMissingEvent) => …)  — and the modern form map.setMissingStyleImageResolver(resolver: MissingStyleImageResolver): this | -[MLNMapViewDelegate mapView:didFailToLoadImage:] → nullable UIImage (MLNMapViewDelegate.h:339). Doc at :332-334: 'The image should be added synchronously with MLNStyle/setImage:forName: … When loading icons asynchronously, you can load a placeholder image and replace it when your image has loaded.' | mbgl::MapObserver::onStyleImageMissing(const std::string&) (include/mbgl/map/map_observer.hpp:67). The renderer-side form carries a completion: RendererObserver::onStyleImageMissing(const std::string&, const StyleImageMissingCallback& done) (include/mbgl/renderer/renderer_observer.hpp:66-67); wired through RenderOrchestrator (src/mbgl/renderer/render_orchestrator.cpp:1070) from ImageManager (src/mbgl/renderer/image_manager.cpp:276). | widget-callback | yes |
| P1 | text-font / font stack — comma-join semantics, NOT a fallback chain | present | layout property `text-font: string[]` (identical) *(unverified)* | MLNSymbolStyleLayer textFontNames (NSExpression evaluating to an NSString array); MLNFontNamesAttribute for per-section fonts (MLNAttributedExpression.h:9) | mbgl::FontStack = std::vector<std::string> (include/mbgl/util/font_stack.hpp:13); **fontStackToString joins with ',' via boost::algorithm::join** (src/mbgl/util/font_stack.cpp:11-13), and that single joined string is percent-encoded into one {fontstack} request (src/mbgl/storage/resource.cpp:76) | value-type | no |
| P2 | Content box (`content`) — the text-safe rect inside a stretchable image | none | StyleImageMetadata.content?: [number, number, number, number] | — (no equivalent) | mbgl::style::ImageContent {left, top, right, bottom} (include/mbgl/style/image.hpp:23-33); Image ctor param (:43); getContent() (:81) | value-type | yes |
| P2 | Glyph load / error / requested notifications | none | — (no dedicated glyph event; verified on the MapEventType page) | -[MLNMapViewDelegate mapView:glyphsWillLoad:range:] (MLNMapViewDelegate.h:414), mapView:glyphsDidLoad:range: (:427), mapView:glyphsDidError:range: (:440). All three carry `NSArray<NSString*> *fontStack` and `NSRange range`, and all are documented '> Warning: This method is not thread-safe.' | mbgl::MapObserver::onGlyphsLoaded(const FontStack&, const GlyphRange&), onGlyphsError(const FontStack&, const GlyphRange&, std::exception_ptr), onGlyphsRequested(const FontStack&, const GlyphRange&) (include/mbgl/map/map_observer.hpp:81-83) | widget-callback | yes |
| P2 | Image source — setImage (push raw pixels into a georeferenced image source) | none | map.getSource(id).updateImage({url, coordinates}) *(unverified)* | @property (nonatomic, retain, nullable) MLNImage *image (MLNImageSource.h:103); -[MLNImageSource initWithIdentifier:coordinateQuad:image:] (MLNImageSource.h:77-78) | mbgl::style::ImageSource::setImage(PremultipliedImage&&) (include/mbgl/style/sources/image_source.hpp:23) | controller-namespace | yes |
| P2 | Stretchable images — stretchX / stretchY (nine-patch for icon-text-fit) | none | StyleImageMetadata.stretchX?: [number, number][]  /  stretchY?: [number, number][] | — (no header-level API; the SDK derives stretch from UIImage.capInsets) | mbgl::style::ImageStretches = std::vector<std::pair<float,float>>; Image ctor params stretchX/stretchY (include/mbgl/style/image.hpp:14-15, 41-42); getters at :76,:78 | controller-namespace | yes |
| P2 | addImages (batch registration) | none | — (no batch API) | — (no batch API) | mbgl::style::Style::addImage called N times (include/mbgl/style/style.hpp:50) | controller-namespace | yes |
| P2 | getImage (read back a registered image's pixels + metadata) | none | map.getImage(id: string): StyleImage | -[MLNStyle imageForName:] → nullable MLNImage* (MLNStyle.h:253) | mbgl::style::Style::getImage(const std::string&) → std::optional<Image> (include/mbgl/style/style.hpp:49); pixels via Image::getImage() (include/mbgl/style/image.hpp:67), metadata via getPixelRatio/isSdf/getStretchX/getStretchY/getContent (:70-87) | controller-namespace | yes |
| P2 | getStyleJson — read the live style document (enabler for every sprite/glyph runtime setter) | none | map.getStyle(): StyleSpecification *(unverified)* | — (MLNStyle exposes typed accessors rather than the document) | mbgl::style::Style::getJSON() const (include/mbgl/style/style.hpp:32) and getURL() (:33) — both public, both trivially bindable | controller-namespace | yes |
| P2 | listImages | none | map.listImages(): string[] | — (no equivalent) | NOT IN THE PUBLIC HEADER — but reachable: mbgl::style::Style::Impl::getImageImpls() → Immutable<std::vector<Immutable<Image::Impl>>> (src/mbgl/style/style_impl.hpp:96). Private header, already on our shim's include path (we include mbgl/map/transform_state.hpp and mbgl/style/conversion/* the same way, maplibre_flutter_core.cpp:27,36-39). | controller-namespace | yes |
| P2 | loadImage (fetch an image from a URL and register it) | none | map.loadImage(url: string, callback?): AbortController / Promise<{data: StyleImageSource}> | — (app fetches with URLSession and calls setImage:forName:) | Decoding is in core: mbgl::decodeImage(const std::string&) → PremultipliedImage (include/mbgl/util/image.hpp:179) handles PNG/JPEG/WebP. Fetching would use mbgl::FileSource, but there is no public 'load this URL as a style image' entry point. | controller-namespace | no |
| P2 | localIdeographFontFamily — render CJK glyphs from a local system font instead of downloading them | none | MapOptions.localIdeographFontFamily?: string \| false (default 'sans-serif') — 'Overrides font generation for Chinese, Japanese and Korean characters locally, ignoring map style font settings except for font-weight keywords' | — (no public setter; the Apple SDK hardwires the CoreText rasterizer) | mbgl::Renderer ctor param `const std::optional<std::string>& localFontFamily` (include/mbgl/renderer/renderer.hpp:47) → GlyphManager/LocalGlyphRasterizer (src/mbgl/renderer/render_orchestrator.cpp:119). Reachable for us via mbgl::HeadlessFrontend's 5th ctor parameter (src/mbgl/gfx/headless_frontend.hpp:34). | widget-init | yes |
| P2 | localizeLabels — rewrite the style's text-field expressions into a locale | none | — (no equivalent in core gl-js; verified. Web solves it with the @maplibre/maplibre-gl-language plugin.) | -[MLNStyle localizeLabelsIntoLocale:] (MLNStyle.h:302). Doc at :289-301: 'automatically modifies the text property of any symbol style layer … To use the system's preferred language, specify nil. To use the local language, specify a locale with the identifier `mul`.' | NOT IN CORE. There is no localization entry point in include/mbgl/style/style.hpp; Apple implements it entirely in Swift/ObjC by rewriting each symbol layer's text expression (NSExpression+MLNAdditions.h:261, `-mgl_expressionLocalizedIntoLocale:`). | controller-namespace | no |
| P2 | updateImage (replace pixels of an existing id, keeping metadata) | partial | map.updateImage(id: string, image: StyleImageSource): this | -[MLNStyle setImage:forName:] doubles as update — 'Adds **or overrides** an image used by the style's layers' (MLNStyle.h:256-257) | mbgl::style::Style::addImage — src/mbgl/style/style_impl.cpp:305-317 does an in-place replace when the id already exists | controller-namespace | no |
| P3 | Animated / dynamic style images (per-frame repaint of a registered image) | none | map.addImage(id, image: StyleImageInterface) where the object supplies `render()`, `onAdd`, `onRemove` and a mutable `data` buffer *(unverified)* | — (no equivalent) | NOT IN CORE. mbgl::style::Image holds an immutable PremultipliedImage behind `Immutable<Impl>` (include/mbgl/style/image.hpp:90) — there is no render callback and no way to mutate pixels in place. | reject | no |
| P3 | Expression-level localization — resolved-locale, collator, number-format | present | same expression operators (style-spec, identical) *(unverified)* | NSExpression+MLNAdditions `-mgl_expressionLocalizedIntoLocale:` (:261) is built on the same primitives; MLNAttributedExpression exposes the `format` sections (MLNAttributedExpression.h:9-16) | include/mbgl/style/expression/collator.hpp, collator_expression.hpp, number_format.hpp; ICU-backed via include/mbgl/i18n/collator.hpp and i18n/number_format.hpp. Compiled on every arm (src/CMakeLists.txt:131,138,273-274,381-382,497-498; web/CMakeLists.txt:80-81). | controller-namespace | no |
| P3 | Glyph range loading (256-codepoint PBF ranges) | none | — (internal) | — (internal; only observable via the glyph delegate methods, MLNMapViewDelegate.h:414-441) | mbgl::GlyphRange (include/mbgl/text/glyph_range.hpp), getGlyphRange (include/mbgl/text/glyph.hpp:58); requests at src/mbgl/storage/resource.cpp:70-83 substituting {fontstack} and {range} | reject | no |
| P3 | Glyphs root property — the {fontstack}/{range}.pbf URL template | present | — (declarative) | — (declarative) | mbgl::style::Style::Impl::getGlyphURL() (src/mbgl/style/style_impl.hpp:92; member at :117) — **getter only, no setter**. Requests built by mbgl::Resource::glyphs (src/mbgl/storage/resource.cpp:70-83). | widget-prop | no |
| P3 | High-DPI @2x sprite selection | present | — (automatic from devicePixelRatio) *(unverified)* | — (automatic from UIScreen.scale) | mbgl::Resource::spriteJSON / spriteImage append '@2x' when pixelRatio > 1 (src/mbgl/storage/resource.cpp:65-67) | widget-init | no |
| P3 | Image source — setUrl / setCoordinates | none | map.getSource(id).updateImage({url, coordinates}) / setCoordinates(coordinates) *(unverified)* | -[MLNImageSource setURL:] (MLNImageSource.h:95); @property URL (MLNImageSource.h:88); coordinateQuad on the initialiser (MLNImageSource.h:64) | mbgl::style::ImageSource::setURL(const std::string&) (include/mbgl/style/sources/image_source.hpp:21); setCoordinates(const std::array<LatLng,4>&) (:25); getCoordinates() (:26) | controller-namespace | yes |
| P3 | Multiple sprite sources (array of {id, url}, referenced as `my-sprite:icon`) | present | — (declarative; runtime form is addSprite/removeSprite) | — (declarative) | mbgl::style::Sprite {id, spriteURL} (include/mbgl/style/sprite.hpp:8-15); per-sprite load status at src/mbgl/style/style_impl.hpp:124. Spec doc: '$root.sprite … An array of {id: my-sprite, url: …} objects … used as a prefix when referencing images from that sprite (i.e. my-sprite:image). If the id field is equal to default, the prefix is omitted.' | widget-prop | no |
| P3 | Native annotation images (MLNAnnotationImage) | none | — (no equivalent) | +[MLNAnnotationImage annotationImageWithImage:reuseIdentifier:] (MLNAnnotationImage.h:31); @property image (:37), reuseIdentifier (:50), enabled (:58); vended from -[MLNMapViewDelegate mapView:imageForAnnotation:] (MLNMapViewDelegate.h:649-650) | NOT IN CORE as such — mbgl's annotation subsystem (include/mbgl/annotation/) is a thin layer the SDKs build on; our tiers do not use it | reject | no |
| P3 | RTL text plugin (setRTLTextPlugin) | none | setRTLTextPlugin(pluginURL: string, lazy: boolean): Promise<void> | — (none; the Apple SDK bundles ICU) | Not applicable as an API. Bidi is in-core: platform/default/src/mbgl/text/bidi.cpp, compiled on every arm we build (src/CMakeLists.txt:160,291,400,516; web/CMakeLists.txt:84). | reject | no |
| P3 | SDF icons (signed-distance-field, style-recolourable) | present | StyleImageMetadata.sdf: boolean | — (no explicit parameter; the SDK infers it from UIImage.renderingMode == alwaysTemplate, which is not visible in the headers) | mbgl::style::Image ctor `bool sdf` (include/mbgl/style/image.hpp:40); read back via isSdf() (:73) | controller-namespace | no |
| P3 | Sprite load / error / requested notifications | none | — (folded into the generic `styledata` / `dataloading` events; no dedicated sprite event, verified on the MapEventType page) | -[MLNMapViewDelegate mapView:spriteWillLoad:url:] (MLNMapViewDelegate.h:482), mapView:spriteDidLoad:url: (:493), mapView:spriteDidError:url: (:504) | mbgl::MapObserver::onSpriteLoaded / onSpriteError / onSpriteRequested, all taking std::optional<style::Sprite> (include/mbgl/map/map_observer.hpp:89-91) | widget-callback | yes |
| P3 | Sprite root property — single sprite URL in the style document | present | — (declarative; the runtime equivalent is setSprite, below) | — (declarative) | Parsed by mbgl::style::Style::Impl::parse → SpriteLoader (src/mbgl/style/style_impl.hpp:115); style spec `$root.sprite` (scripts/style-spec-reference/v8.json) | widget-prop | no |
| P3 | Text-fit constraints — textFitWidth / textFitHeight | none | StyleImageMetadata.textFitWidth?: TextFit  /  textFitHeight?: TextFit | — (no equivalent for the image side; MLNSymbolStyleLayer.iconTextFit at MLNSymbolStyleLayer.h:831 is the layer-side property) | enum class mbgl::style::TextFit { stretchOrShrink, stretchOnly, proportional } (include/mbgl/style/image.hpp:17-21); Image ctor params (:44-45); getters (:84,:87) | value-type | yes |
| P3 | Text-shaping capability probe (is RTL / complex-script / local-glyph rasterization available) | none | — (getRTLTextPluginStatus is the nearest analogue) | — (no equivalent) | Compile-time facts: MLN_TEXT_SHAPING_HARFBUZZ (third_party/maplibre-native/CMakeLists.txt:21), ICU linkage, and LocalGlyphRasterizer::canRasterizeGlyph (src/mbgl/text/local_glyph_rasterizer.hpp:39) — the last differs per platform in OUR build | value-type | yes |
| P3 | addSprite / removeSprite (add or drop one sprite source at runtime) | none | map.addSprite(id: string, url: string, options?: StyleSetterOptions): this  /  map.removeSprite(id: string, options?: StyleSetterOptions): this | — (no equivalent) | NOT IN CORE — same as setSprite; the sprite collection is built only in Style::Impl::parse() | controller-namespace | yes |
| P3 | addWidgetIcon — rasterise a Flutter widget into a style image | present | — (no equivalent) | — (no equivalent; closest is MLNAnnotationImage, a different subsystem) | n/a — pure Dart on top of Style::addImage | controller-namespace | no |
| P3 | areSpritesLoaded — has the style's sprite finished loading | none | — (map.isStyleLoaded() covers it implicitly) *(unverified)* | — (no equivalent) | mbgl::style::Style::Impl::areSpritesLoaded() (src/mbgl/style/style_impl.hpp:101) — private header, reachable like getImageImpls | controller-namespace | yes |
| P3 | font-faces root property — HarfBuzz complex-text shaping (Devanagari, Khmer, Arabic …) | present | — (no equivalent; this is a maplibre-native extension to the spec) | — (no runtime API) | struct mbgl::FontFace {type, name, url, ranges} / using FontFaces = std::vector<FontFace> (include/mbgl/text/glyph.hpp:165-188); Style::Impl::getFontFaces() (src/mbgl/style/style_impl.hpp:93) → GlyphManager::setFontFaces (src/mbgl/text/glyph_manager.hpp:68). Style spec `$root.font-faces` (scripts/style-spec-reference/v8.json — 'Font faces contain information needed to render complex texts such as Devanagari, Khmer among many others'; supports a CSS-like `unicode-range`). | widget-prop | no |
| P3 | getRTLTextPluginStatus | none | getRTLTextPluginStatus(): string — one of 'unavailable' \| 'loading' \| 'loaded' \| 'error' | — (none) | NOT IN CORE (no plugin concept exists) | reject | no |
| P3 | onCanRemoveUnusedStyleImage — veto eviction of a cached style image | none | — (no equivalent) | -[MLNMapViewDelegate mapView:shouldRemoveStyleImage:] → BOOL (MLNMapViewDelegate.h:353). Doc at :343-347: 'called in two scenarios: when the cumulative size of unused images exceeds the cache size or when the last tile that includes the image is removed from the map'. | mbgl::MapObserver::onCanRemoveUnusedStyleImage(const std::string&) → bool, default true (include/mbgl/map/map_observer.hpp:70). Cache size at include/mbgl/util/constants.hpp:55. | widget-callback | yes |
| P3 | pixelRatio (high-DPI style images) | present | StyleImageMetadata.pixelRatio: number | — (derived from UIImage.scale) | mbgl::style::Image ctor `float pixelRatio` (include/mbgl/style/image.hpp:39); getPixelRatio() (:70) | controller-namespace | no |
| P3 | setGlyphs / getGlyphs (replace or read the glyph URL template at runtime) | none | map.setGlyphs(glyphs: string \| null, options?: StyleSetterOptions): this  /  map.getGlyphs(): string | — (no equivalent) | `getGlyphURL()` exists (src/mbgl/style/style_impl.hpp:92) but there is **NO setter** — glyphURL is written only in Style::Impl::parse(). Setting it at runtime is NOT IN CORE. | controller-namespace | yes |
| P3 | setLanguage / language switching | none | — (verified absent from the gl-js Map API; language switching on web is the @maplibre/maplibre-gl-language plugin, which rewrites text-field expressions) | — (Apple's answer is localizeLabelsIntoLocale:, MLNStyle.h:302) | NOT IN CORE | reject | no |
| P3 | setSprite / getSprite (replace or read the style's sprite at runtime) | none | map.setSprite(sprite: string \| null, options?: StyleSetterOptions): this  /  map.getSprite(): string \| null | — (no equivalent) | NOT IN CORE as a setter. mbgl::style::Style (include/mbgl/style/style.hpp) has no sprite accessor at all; the URL lives in the private SpriteLoader (src/mbgl/style/style_impl.hpp:115) and is only set during parse(). `areSpritesLoaded()` (style_impl.hpp:101) is the sole introspection point. | controller-namespace | yes |

#### Proposed signatures

**Runtime images survive a style reload (re-register on onDidFinishLoadingStyle)** — P0, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:890 — FrameObserver::onDidFinishLoadingStyle re-applies transition options and re-adds every model layer, but does NOT re-add runtime images. Same hole on web: src/web/maplibre_flutter_core_web.cpp:92.
```dart
(no new public API — the shim must retain registered images and re-add them from onDidFinishLoadingStyle, exactly as it already does for models)
```
> **Real defect, not a gap.** `MapLibreMap.style` is a declarative widget prop, so switching styles is a first-class, expected user action — and it silently drops every `addImage`/`addWidgetIcon` the app registered, leaving symbol layers with missing icons. CLAUDE.md §11 already records 'Loading a style overwrites style-level state … every custom layer is dropped. Re-apply from onDidFinishLoadingStyle' — the models path obeys it, the images path does not. Fix is ~15 lines in the shim (keep `std::unordered_map<std::string, ImageEntry>` beside `m->models` and replay it), mirrored in the WASM shim.

**addImage (runtime style image, raw premultiplied RGBA)** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:47; packages/maplibre_flutter/lib/src/map_layers_controller.dart:123; packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:535; packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1653
```dart
void addImage(String id, Uint8List rgba, int width, int height, {double pixelRatio = 1.0, bool sdf = false, List<ImageStretch>? stretchX, List<ImageStretch>? stretchY, ImageContent? content, TextFit? textFitWidth, TextFit? textFitHeight})
```
> **Matrix drift:** line 544 `addImage` (runtime): Android 🧪 / iOS 🧪 / macOS ✅ / Win 🧪 / Linux 🧪 / **Web ❌**. **DISAGREES**: web-core-WASM implements it (packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:301 → src/web/maplibre_flutter_core_web.cpp:478, embind at :1021), and it is unit-tested at packages/maplibre_flutter_web/test/core_web_capabilities_test.dart:151. Web should be 🧪, not ❌.

**addImage from a Flutter ImageProvider / ui.Image (assets, network, memory)** — P1, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:387 `addWidgetIcon` covers the widget case only; there is no asset/ui.Image path — callers must do `toByteData(format: rawRgba)` by hand
```dart
Future<void> addImageProvider(String id, ImageProvider provider, {double pixelRatio = 1.0, bool sdf = false})
```
> **The single biggest ergonomic gap in this domain.** Every upstream SDK takes its platform's *native* image type; we take a raw premultiplied RGBA byte buffer, which no Flutter app has lying around. `addWidgetIcon` proves we already own the rasterise-and-register plumbing (map_layers_controller.dart:387-414); this is the same three lines against an `ImageProvider` instead of a `Widget`. Pure Dart, no C ABI. Optionally add `addImageEncoded(id, Uint8List pngBytes)` backed by `mbgl::decodeImage` to skip a Dart-side decode for sprite atlases.

**hasImage** — P1, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart (next to addImage:47)
```dart
bool hasImage(String id)
```
> **Matrix drift:** line 549: `hasImage` — ➖ on all five native columns, ❌ on Web, marked **web_only (gl-js)**. **DISAGREES, hard.** It is not web-only: `Style::getImage` is public mbgl API and `HeadlessFrontend::hasImage` — the exact frontend type our shim already holds (`m->frontend`) — has the method by that name. Every native column should be ❌ (bindable), not ➖.

**removeImage** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:56; packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1689; web: packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:313
```dart
void removeImage(String id)
```
> **Matrix drift:** line 548: Android 🧪 / iOS 🧪 / macOS ✅ / Win 🧪 / Linux 🧪 / **Web ❌**. **DISAGREES** — web-core implements it (core_web_controller.dart:313, embind maplibre_flutter_core_web.cpp:1022). Also the Notes cell on line 548 is a copy-paste of line 544's and describes `addImage`, not `removeImage`.

**styleimagemissing — supply an image on demand when the style asks for one it does not have** — P1, `widget-callback`, evidence: would need a new callback on MapLibreMap (packages/maplibre_flutter/lib/src/maplibre_map.dart:35, beside onTap) + a C ABI callback registration beside mbl_map_set_frame_callback (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:268)
```dart
final Future<MapLibreStyleImage?> Function(String id)? onStyleImageMissing;  // on MapLibreMap
```
> **Matrix drift:** line 559: `styleimagemissing` event — ➖ on all five native, ❌ Web, **web_only (event form); native is in §7**. And line 495 (§7) says `styleimagemissing` event ❌ across the board. **DISAGREES**: it is a first-class mbgl MapObserver hook and an Apple delegate method — the ➖s are wrong on every native column. Also note the row is duplicated across §7 and §8 with different symbols.

**text-font / font stack — comma-join semantics, NOT a fallback chain** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:807 `StyleValue<List<String>>? textFont` → serialised to 'text-font' at :1164
```dart
(type unchanged: StyleValue<List<String>>) — plus dartdoc stating the join semantics, and a `MapLibreFontStack` doc-only helper listing the known-good stacks for the styles the example ships
```
> **Documentation defect, not an API defect.** The `List<String>` type invites the reading 'try these fonts in order' — the actual behaviour is 'request the single composite font named `A,B,C` from the tile server', which 404s unless the server publishes exactly that composite. This has already cost this repo one workaround (`clusterTextFont` defaulting to null and dropping the whole label layer, map_layers_controller.dart:248-254). Fix: say it plainly in the generated dartdoc for `textFont`, and pair it with the glyph-error callback above so the failure is visible.

**Content box (`content`) — the text-safe rect inside a stretchable image** — P2, `value-type`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:47
```dart
ImageContent? content  (`class ImageContent { final double left, top, right, bottom; }`)
```
> Ships with stretchX/stretchY — the two are useless apart. Name the fields after mbgl's struct (left/top/right/bottom) rather than gl-js's positional 4-tuple, which is unreadable in Dart. gl-js's order IS [left, top, right, bottom], so a `.toList()` interop is trivial.

**Glyph load / error / requested notifications** — P2, `widget-callback`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872 — FrameObserver could override these and does not
```dart
final void Function(List<String> fontStack, Object? error)? onGlyphsLoaded;  // on MapLibreMap
```
> **Higher value than it looks, for this repo specifically.** The 404-glyph failure mode is already a documented trap here — `addPoints` refuses to add a label layer at all unless the caller names a font (`map_layers_controller.dart:248-254`, 'naming one it does not have makes mbgl request glyphs that 404 on every tile'). A glyph-error callback turns that from a silent invisible-label bug into a diagnosable one. Take Apple's shape (fontStack + range), collapse the three phases into one callback with a nullable error, and heed Apple's thread-safety warning: marshal to the Dart isolate, never call back into mbgl from inside it.

**Image source — setImage (push raw pixels into a georeferenced image source)** — P2, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart:522 has the typed `image` source (creation-only, via addSourceJson); no mutation path exists
```dart
void setImageSourceImage(String sourceId, Uint8List rgba, int width, int height)
```
> This is the live-radar / live-overlay use case, and it is the one image API that mutates a *source* rather than the style's image registry — keep it on `controller.sources`-ish naming, not `controller.images`, to avoid confusion with `addImage`. Core support is a single public method; the whole cost is one C entry point.

**Stretchable images — stretchX / stretchY (nine-patch for icon-text-fit)** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:47 (new named params on addImage)
```dart
List<ImageStretch>? stretchX, List<ImageStretch>? stretchY  (on addImage; `class ImageStretch { final double start, end; }`)
```
> This is what makes a *label bubble* possible — an icon that grows horizontally around variable-length text via `icon-text-fit`. Without it, every text-in-a-pill marker has to be a full widget rasterisation per distinct label, which is exactly the scaling wall `addWidgetIcon` exists to avoid. Core support is complete; only our C ABI is narrow. Take gl-js's field names (`stretchX`/`stretchY`) and mbgl's pair semantics; do **not** copy Apple's capInsets translation.

**addImages (batch registration)** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
void addImages(Map<String, MapLibreStyleImage> images)
```
> **Matrix drift:** line 545: `addImages` (batch) — Android ❌, everything else ➖, **native_only (Android Style.addImages)**. **DISAGREES on the ➖s**: our five native tiers are one engine, so if Android can batch, so can macOS/iOS/Windows/Linux — this is a shim-side loop, not an Android SDK feature. All six should be ❌.

**getImage (read back a registered image's pixels + metadata)** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
MapLibreStyleImage? getImage(String id)
```
> **Matrix drift:** line 550: `getImage` / `imageForName` — ❌ on all five native, ➖ on Web, marked **native_only**. **DISAGREES**: gl-js 5.x *does* have `getImage(id)` (verified on the Map docs page), so the native_only tag is wrong; Web should be ❌.

**getStyleJson — read the live style document (enabler for every sprite/glyph runtime setter)** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.h has mbl_map_set_style (line 57) but no getter; packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:32 is write-only
```dart
Future<String> getStyleJson()
```
> **Listed here because four rows in this domain are blocked on it** — setSprite, addSprite/removeSprite, setGlyphs, and any font-faces mutation all reduce to 'read the document, patch a root key, reload'. It is one allocating C call over an existing public mbgl method (`getJSON`), pairs with the existing `mbl_string_free`, and unblocks more of this domain than any other single entry point. Caveat to document: `getJSON()` returns the document as loaded, so runtime `addLayer`/`addImage` mutations are not reflected — patch-and-reload therefore loses runtime state until the p0 re-registration fix lands.

**listImages** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
List<String> listImages()
```
> **Matrix drift:** line 552: `listImages` — ➖ on all five native, ❌ Web, **web_only (gl-js)**. **DISAGREES**: implementable on native via Style::Impl, exactly like our existing private-header uses. Should be ❌ everywhere, not ➖.

**loadImage (fetch an image from a URL and register it)** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter/lib/src/map_layers_controller.dart (pure Dart, alongside addWidgetIcon:387)
```dart
Future<void> loadImage(String id, Uri url, {double pixelRatio = 1.0, bool sdf = false, HttpClient? client})
```
> **Matrix drift:** line 551: `loadImage` (from URL) — ➖ native, ❌ Web, **web_only (gl-js)**. **DISAGREES**: nothing about this is web-only. It is Dart-level work (`package:http` or `NetworkImage`) plus our existing `addImage`.

**localIdeographFontFamily — render CJK glyphs from a local system font instead of downloading them** — P2, `widget-init`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:913 — we construct HeadlessFrontend passing `std::nullopt` for exactly this parameter; would surface on packages/maplibre_flutter_platform_interface/lib/src/map_options.dart:14 (MapOptions has only initialCamera today)
```dart
MapOptions({..., String? localIdeographFontFamily})   // init-only
```
> **Init-only by construction** — it is a `Renderer` constructor argument, so it belongs in `MapOptions`, never on the controller. Plumbing is small (one field → `mbl_map_create` → the HeadlessFrontend ctor we already call). **But it only does anything on iOS and macOS.** Our CMake gives Apple the real CoreText rasterizer (`platform/darwin/core/local_glyph_rasterizer.mm`, src/CMakeLists.txt:134); Android, Linux, Windows and web all get `platform/default/src/mbgl/text/local_glyph_rasterizer.cpp` (src/CMakeLists.txt:292,401,517; web/CMakeLists.txt:85), whose `canRasterizeGlyph` returns **false** unconditionally (local_glyph_rasterizer.cpp:11-13). Note that mbgl's Android SDK *does* ship a JNI rasterizer we deliberately do not use, because it needs the Java layer. So: bind it, document it as Apple-only today, and file 'write a FreeType-backed default rasterizer' as separate work — HarfBuzz+FreeType are already linked in (see the font-faces row), so it is closer than it sounds.

**localizeLabels — rewrite the style's text-field expressions into a locale** — P2, `controller-namespace`, evidence: would live in packages/maplibre_flutter/lib/src/map_layers_controller.dart (pure Dart). Blocked: there is no getLayer / getLayoutProperty / setLayoutProperty anywhere — packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart has only addLayerJson/removeLayer.
```dart
Future<void> localizeLabels({Locale? locale})   // null = system preferred; Locale('mul') = local/native names
```
> **Matrix drift:** line 575: `localizeLabels` — ❌ on all five native, ➖ Web, **native_only**. **PARTLY DISAGREES**: the ➖ on Web is wrong — it is a Dart-level expression rewrite, so if it works on native it works on web-WASM identically (nothing platform-specific is involved). Should be ❌ on all six.

**updateImage (replace pixels of an existing id, keeping metadata)** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1669 — `addImage` on an existing id overwrites it (mbgl style_impl.cpp:305-317 replaces in place), so the behaviour exists but is undocumented and has no distinct name
```dart
void updateImage(String id, Uint8List rgba, int width, int height)
```
> **Matrix drift:** line 547: `updateImage` — ➖ on all five native, ❌ Web, **web_only (gl-js)**. **DISAGREES**: the *capability* is present on every tier today via overwrite-on-add; only the distinct verb is missing. Should be 🟡 (partial) natively.

**Animated / dynamic style images (per-frame repaint of a registered image)** — P3, `reject`, evidence: n/a — not implementable; would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
— (reject; document the workaround: drive a timer in Dart and call updateImage, which is what mbgl's own consumers do)
```
> Hard stop for the five native tiers and web-WASM. The honest substitute is a Dart `Ticker` calling `updateImage` at 10-15 Hz for a pulsing marker — cheap for one icon, unusable for many. Say so in the docs rather than leaving users to discover it.

**Expression-level localization — resolved-locale, collator, number-format** — P3, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:1748 `Expr.resolvedLocale`, :516 `Expr.collator`, :618 `Expr.numberFormat`, :569 `Expr.format`, :605 `Expr.image`
```dart
(unchanged — generated; keep `Expr.resolvedLocale`, `Expr.collator`, `Expr.numberFormat`)
```
> **Matrix drift:** line 257: 'String expressions (concat/upcase/downcase/resolved-locale)' — 🧪 on all five native, ❌ Web, note 'Buildable from Dart via the generated Expr builders'. **DISAGREES on Web**: the generated Expr builders are pure Dart serialised into `addLayerJson`, which web-WASM implements (core_web_controller.dart:264), and the ICU sources are compiled into the WASM build (web/CMakeLists.txt:80-81,105-116). Should be 🧪.

**Glyph range loading (256-codepoint PBF ranges)** — P3, `reject`, evidence: n/a — engine-internal, no API surface anywhere
```dart
— (reject as an API; expose only via the glyph load/error callbacks)
```
> Nothing to bind. Kept as a row so the backlog does not later re-litigate it.

**Glyphs root property — the {fontstack}/{range}.pbf URL template** — P3, `widget-prop`, evidence: inherited from the style document via setStyle (packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:32); labels render on every tier today
```dart
(no API — declarative via MapLibreMap.style)
```
> **Matrix drift:** line 568: Glyphs root property — ❌ on all six, note 'Loaded via style JSON.' **DISAGREES**: the note contradicts the symbol; it works today on every tier (every label you see proves it). Should be 🧪/✅.

**High-DPI @2x sprite selection** — P3, `widget-init`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.h:52 — mbl_map_create takes `pixel_ratio`, which mbgl uses to pick the @2x sprite
```dart
(no API — automatic from the widget's devicePixelRatio)
```
> **Matrix drift:** line 563: High-DPI @2x sprites — ❌ on all six. **DISAGREES**: automatic, and already correct on our tiers because we pass the real device pixel ratio into mbl_map_create. Should be 🧪/✅.

**Image source — setUrl / setCoordinates** — P3, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart:522 (creation-only)
```dart
void setImageSourceUrl(String sourceId, Uri url); void setImageSourceCoordinates(String sourceId, List<LatLng> quad)  // TL, TR, BR, BL
```
> Ships with setImage. **LatLng ⇄ [lng,lat] flip applies** — Apple's `MLNCoordinateQuad` and mbgl's `std::array<LatLng,4>` are both lat/lng ordered, but the style-spec JSON `coordinates` are [lng,lat], so a caller who round-trips through addSourceJson and this method must not see two conventions. Assert the quad order (top-left, top-right, bottom-right, bottom-left) in the doc, matching MLNImageSource.h:57-58.

**Multiple sprite sources (array of {id, url}, referenced as `my-sprite:icon`)** — P3, `widget-prop`, evidence: same as the single-sprite row — inherited from mbgl's parser via setStyle (maplibre_map_controller.dart:32)
```dart
(no API — declarative via MapLibreMap.style)
```
> **Matrix drift:** line 561: Multiple sprite sources — ❌ on all six, no note. **DISAGREES**: mbgl models sprites as a keyed collection (`spritesLoadingStatus`, `Sprite{id,url}`) and parses the array form from the document. Declaratively supported today.

**Native annotation images (MLNAnnotationImage)** — P3, `reject`, evidence: n/a — we do not bind the Apple annotation subsystem at all (no MLN* usage in packages/maplibre_flutter_ios/lib/src/maplibre_flutter_ios_core_controller.dart, which is the mbgl-core tier)
```dart
— (reject for the core tiers; `MapLibreMap.markers` + `addWidgetIcon` are our answer)
```
> Explicit non-goal, recorded so it is not re-proposed. Our two annotation tiers (widget markers for the interactive few, engine symbol layers with `addWidgetIcon` for bulk) cover the same ground with one API on six platforms; binding the Apple annotation stack would apply to one opt-in package only and would fork the marker story.

**RTL text plugin (setRTLTextPlugin)** — P3, `reject`, evidence: n/a — nothing to bind; ICU is linked into mbgl-core on every arm (src/CMakeLists.txt:186,212,337,439-454,567; web/CMakeLists.txt:105-116)
```dart
— (reject)
```
> **Deliberate non-binding, and it is a selling point worth stating in the README:** because every tier is one C++ engine with ICU compiled in, Arabic and Hebrew shape correctly out of the box on web too — no plugin URL, no lazy-load, no `getRTLTextPluginStatus` race. gl-js users must configure this; our users must not. That asymmetry is exactly the kind of thing the parity matrix should record as ➖-with-a-reason rather than a gap.

**SDF icons (signed-distance-field, style-recolourable)** — P3, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:53 (`bool sdf`); C ABI packages/maplibre_flutter_core/src/maplibre_flutter_core.h:210; tested at packages/maplibre_flutter/test/core_controller_conformance_test.dart:354
```dart
(unchanged) `bool sdf = false` named parameter on addImage
```
> **Matrix drift:** line 553: Android 🧪 / iOS 🧪 / macOS ✅ / Win 🧪 / Linux 🧪 / **Web ❌**. **DISAGREES on Web** — it is a parameter of the WASM `addImage` (src/web/maplibre_flutter_core_web.cpp:483,496).

**Sprite load / error / requested notifications** — P3, `widget-callback`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:872 FrameObserver overrides only onDidFinishRenderingFrame and onDidFinishLoadingStyle — the sprite hooks are available and unused
```dart
final void Function(String spriteId, Object? error)? onSpriteLoaded;  // on MapLibreMap
```
> Apple exposes all three phases; gl-js has none. Take **Apple's shape** since it is the only upstream that models it, but collapse three delegate methods into one Flutter callback with a nullable error — three separate props for a diagnostic hook is not worth the widget surface. Diagnostic value only: 'why are my icons missing' is currently unanswerable from Dart.

**Sprite root property — single sprite URL in the style document** — P3, `widget-prop`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:32 (setStyle takes a URL, file path or inline JSON; C ABI maplibre_flutter_core.h:56) — the sprite loads because it is part of the style document
```dart
(no API — declarative via MapLibreMap.style)
```
> **Matrix drift:** line 560: Sprite root property (single source) — ❌ on all six, note 'Loaded via style JSON; no runtime sprite API.' **DISAGREES**: the note contradicts the symbol. It IS loaded via style JSON on every tier today — every demo style we render has a sprite and the icons draw. Should be 🧪/✅, not ❌.

**Text-fit constraints — textFitWidth / textFitHeight** — P3, `value-type`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:47
```dart
TextFit? textFitWidth, TextFit? textFitHeight  (`enum TextFit { stretchOrShrink, stretchOnly, proportional }`)
```
> **Matrix drift:** line 556: ➖ on all five native, ❌ Web, **web_only (gl-js metadata)**. **DISAGREES**: `TextFit` is an mbgl core enum with a constructor parameter — it is not a gl-js-only concept. All six should be ❌.

**Text-shaping capability probe (is RTL / complex-script / local-glyph rasterization available)** — P3, `value-type`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart or as a new small capability in the barrel (packages/maplibre_flutter_platform_interface/lib/maplibre_flutter_platform_interface.dart)
```dart
class MapLibreTextCapabilities { final bool rtl; final bool complexScriptShaping; final bool localGlyphRasterization; }  →  MapLibreTextCapabilities get textCapabilities
```
> **Ours, no upstream precedent — proposed because our build genuinely diverges.** `localIdeographFontFamily` is honoured on Apple and silently ignored on Android/Linux/Windows/web (see that row), which is exactly the kind of invisible divergence CLAUDE.md's 'feature-detect with `is`' rule exists to prevent. A three-bool struct read from compile-time defines makes it explicit and testable, and it is what an app needs to decide whether to ship its own CJK-capable font stack.

**addSprite / removeSprite (add or drop one sprite source at runtime)** — P3, `controller-namespace`, evidence: would need a new C ABI; nothing exists
```dart
Future<void> addSprite(String id, Uri url)  /  Future<void> removeSprite(String id)  — style-document patch
```
> Same style-reload caveat. Genuinely lower value than the rest of this domain: `addImages` covers the same need (register a batch of icons) without a style reload, and is strictly cheaper. Recommend documenting `addImages` as the answer and leaving these unbound unless a user asks.

**addWidgetIcon — rasterise a Flutter widget into a style image** — P3, `controller-namespace`, evidence: packages/maplibre_flutter/lib/src/map_layers_controller.dart:387 (+ rasterizeWidget:428); tested at packages/maplibre_flutter/test/map_layers_controller_test.dart:295,319
```dart
(keep) Future<void> addWidgetIcon(String id, Widget widget, {required Size size, double pixelRatio, bool sdf})  + new: Future<void> addWidgetIcons(Map<String, Widget> widgets, {required Size size, double pixelRatio})
```
> **Ours, with no upstream equivalent — keep the name, it is a differentiator.** It is the bridge between the widget-marker tier and the engine tier and nothing in gl-js/Apple/Android does it. Two follow-ups: a plural form riding `addImages` (one render-thread hop for a whole icon set), and re-registration after a style swap (see the p0 row) — a rasterised widget icon is exactly the kind of image that silently vanishes today.

**areSpritesLoaded — has the style's sprite finished loading** — P3, `controller-namespace`, evidence: would live in packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
bool get spritesLoaded
```
> Long tail. Only worth binding as part of a general 'is the style fully ready' predicate, because on its own it answers a question users do not ask. Mentioned for completeness of the mbgl surface.

**font-faces root property — HarfBuzz complex-text shaping (Devanagari, Khmer, Arabic …)** — P3, `widget-prop`, evidence: reachable declaratively today via setStyle (packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart:32); engine support is compiled in on every arm
```dart
(no runtime API — declarative via MapLibreMap.style; add `font-faces` to the generated typed style-document model if/when we model the style root)
```
> **Missing from the matrix entirely, and it is a genuine capability we already ship.** `MLN_TEXT_SHAPING_HARFBUZZ` defaults ON (third_party/maplibre-native/CMakeLists.txt:21) and the HarfBuzz+FreeType block at CMakeLists.txt:1012-1040 runs **before** the `MLN_WITH_CORE_ONLY` early return at :1266 — so every arm we build (we never set the option OFF) links `mbgl-harfbuzz` and `mbgl-freetype`. That means complex-script rendering via `font-faces` works today on all five native tiers and web, with no binding work. Worth an example-app style and a matrix row: it is a differentiator over gl-js, which has no equivalent.

**getRTLTextPluginStatus** — P3, `reject`, evidence: n/a
```dart
— (reject; if anything, expose the affirmative capability probe below)
```
> Purely a consequence of gl-js's plugin architecture. Nothing to bind.

**onCanRemoveUnusedStyleImage — veto eviction of a cached style image** — P3, `widget-callback`, evidence: would live beside onStyleImageMissing on MapLibreMap (packages/maplibre_flutter/lib/src/maplibre_map.dart)
```dart
final bool Function(String id)? onCanRemoveUnusedStyleImage;  // on MapLibreMap
```
> Only meaningful once `onStyleImageMissing` exists — the pair is how an app runs a bounded on-demand icon cache. Must be answered **synchronously** on the render thread (mbgl reads the bool return), so this cannot be a Dart round-trip: bind it as a shim-side policy (an id allowlist pushed down from Dart) rather than a live callback. Say that explicitly or someone will try the naive wiring and deadlock the render loop.

**pixelRatio (high-DPI style images)** — P3, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:52; default 1.0 at map_layers_controller.dart:128; addWidgetIcon defaults to 3.0 (map_layers_controller.dart:391)
```dart
(unchanged) `double pixelRatio = 1.0`
```
> **Matrix drift:** line 557: Android 🧪 / iOS 🧪 / macOS ✅ / Win 🧪 / Linux 🧪 / **Web ❌**. **DISAGREES on Web** (src/web/maplibre_flutter_core_web.cpp:482).

**setGlyphs / getGlyphs (replace or read the glyph URL template at runtime)** — P3, `controller-namespace`, evidence: would need a new C ABI pair; nothing exists
```dart
String? getGlyphs()   // bindable now, via Style::Impl::getGlyphURL
Future<void> setGlyphs(String? urlTemplate)   // style-document patch only
```
> **Matrix drift:** lines 570-571: `setGlyphs` / `getGlyphs` — ➖ native, ❌ Web, **web_only (gl-js)**. **PARTLY DISAGREES**: `getGlyphs` is directly implementable (the getter exists); only `setGlyphs` is a true core gap. The row conflates them.

**setLanguage / language switching** — P3, `reject`, evidence: n/a — no equivalent anywhere in packages/maplibre_flutter/lib/src/
```dart
— (do not add a separate name; `localizeLabels({Locale? locale})` IS this feature)
```
> **Matrix drift:** line 576: Language switching (setLanguage pattern) — ➖ native, ❌ Web, **web_only: expression-rewrite / plugin pattern**. **DISAGREES**: it is not a gl-js API at all — gl-js has no `setLanguage`. Labelling it web_only implies upstream-web has something we lack; it does not. All six should read ❌, satisfied by the same `localizeLabels` work.

**setSprite / getSprite (replace or read the style's sprite at runtime)** — P3, `controller-namespace`, evidence: would need a new C ABI pair; nothing in packages/maplibre_flutter_core/src/maplibre_flutter_core.h touches sprites
```dart
Future<void> setSprite(String? spriteUrl)  /  String? getSprite()   — both implemented as a style-document patch
```
> **Hard-ish stop.** The only route is: read the current style JSON → patch `$root.sprite` → `loadJSON`. That is a full style reload (drops runtime images and custom layers, per the p0 row) and is therefore a poor API to offer casually. **Gated on the `getStyleJson` row below.** Recommendation: bind `getSprite` (cheap, read-only) and defer `setSprite` until the style-reload state-preservation is fixed, then document it as 'reloads the style'.


### 3D, terrain, atmosphere & models

#### Engine ceiling

**Four hard stops, verified in the vendored source at pin `core-fa8a9c8e3261ce64940127aecc1d52f540c21c57`. These bound all five native tiers AND web-WASM, because web-WASM is the same mbgl.**

1. **No 3D terrain. At all.** There is no `terrain.hpp` anywhere under `include/mbgl/` — `ls include/mbgl/style/layers/` yields background, circle, color_relief, custom_drawable, custom, fill_extrusion, fill, heatmap, hillshade, line, location_indicator, raster, symbol and nothing else. Decisively: **the style parser never reads the `terrain` root key**. `src/mbgl/style/parser.cpp` reads `version`(43), `name`(54), `center`(61), `centerAltitude`(72), `zoom`(79), `bearing`(86), `pitch`(93), `roll`(100), `transition`(107), `light`(111), `sources`(115), `layers`(119) — and stops. A style document containing `"terrain": {...}` is loaded **silently, with the terrain clause discarded**. The style spec itself concedes this: `v8.json`'s `terrain.source.sdk-support` lists `js: 2.2.0` and, for ios/android, a link to `maplibre-native` issue **#252** instead of a version. The only DEM machinery in core is 2D: `src/mbgl/geometry/dem_data.cpp` feeding hillshade and color-relief. Consequence: **no `setTerrain`, no `getTerrain`, no `queryTerrainElevation`, no terrain-draped models or markers, no terrain-occluded symbols, no terrain fog.**

2. **No sky, no fog, no atmosphere.** `grep -ril "sky" include/mbgl/` returns **zero files**; `grep -ril "atmosphere\|fog" include/mbgl/` likewise returns zero. There is no `SkyLayer`, no sky root object in the parser (see above), and no sky factory in `include/mbgl/layermanager/` (which lists exactly 13 factories: background, circle, color_relief, custom_drawable, custom, fill_extrusion, fill, heatmap, hillshade, line, location_indicator, raster, symbol). The spec's own `sky` entry is annotated *"this definition is still experimental and is under development in maplibre-gl-js."* All seven sky properties (`sky-color`, `horizon-color`, `fog-color`, `fog-ground-blend`, `horizon-fog-blend`, `sky-horizon-blend`, `atmosphere-blend`) are unreachable.

3. **No globe / vertical-perspective projection.** `grep -ril "globe" include/mbgl/` hits only `map_options.hpp` (in prose about wrapping) and `shaders/mtl/widevector.hpp`. There is no `projection` root-key parse, no `ProjectionSpecification`, no `projectionDefinition` type. mbgl **is Web Mercator only**. What mbgl *does* have under the name "projection" is unrelated: `mbgl::ProjectionMode` (`include/mbgl/map/projection_mode.hpp:12`) is **axonometric skew** — `withAxonometric(bool)`, `withXSkew(double)`, `withYSkew(double)` — driven by `Map::setProjectionMode` / `getProjectionMode` (`include/mbgl/map/map.hpp:115-116`). That is a genuine native-only 3D feature gl-js has no equivalent of, and it is bindable.

4. **The 3D-model shader ceiling.** Our model path is `mbgl::style::CustomDrawableLayer` (`include/mbgl/style/layers/custom_drawable_layer.hpp:20`), whose `Interface::addGeometry(vertices, indices, is3D)` (:189) accepts only `GeometryVertex {position[3], texcoords[2], normal[3]}` (:66) with `GeometryOptions {matrix, color, texture, light[4]}` (:74). The `normal` and `light` fields **are ours** — added by `patches/custom-geometry-lighting.patch`; upstream's vertex is position+uv only. Even patched, the ceiling is one directional light + an ambient floor, one base-colour texture, one tint. Therefore: **no PBR, no metallic/roughness/normal maps, no shadows, no skinned or morph animation, no glTF animation channels** — rigid-body only. Two further hard limits: `gfx::IndexVector` is `uint16`, so **65 536 vertices per drawable** (we split per material and re-index to survive it); and raw `mbgl::style::CustomLayer` — the escape hatch that would let us run our own shaders — is unusable off OpenGL, because `CustomLayerFactory` registration in `platform/default/src/mbgl/layermanager/layer_manager.cpp:81-85` is `#ifdef MLN_RENDER_BACKEND_OPENGL`-gated while `CustomDrawableLayerFactory` (:89-91) is unconditional.

**What mbgl DOES have that we have not bound (i.e. NOT a ceiling — just a gap):**
- **`Light` is fully present**: `include/mbgl/style/light.hpp:17`, with `setAnchor`/`setColor`/`setIntensity`/`setPosition` plus every `…Transition` (:31-49), `setProperty(name, Convertible)` (:28), reachable via `Style::getLight()`/`setLight()` (`include/mbgl/style/style.hpp:44-47`), parsed from the root (`parser.cpp:111`, `:236`), and there is a ready-made `Converter<Light>` at `include/mbgl/style/conversion/light.hpp:13` — so a JSON-shaped C ABI is a ~20-line shim addition, no per-property ABI churn.
- **The `elevation` expression exists** — `src/mbgl/style/expression/compound_expression.cpp:374` and its registry entry at `:1030`, plus `parsing_context.cpp:48` listing it alongside `zoom`/`heatmap-density`. (`expression.hpp:220` even reserves `Elevation = 1 << 7 // Elevation from DEM`.)
- **Camera 3D fields**: `CameraOptions.fov` (`include/mbgl/map/camera.hpp:86`), `.roll` (:83), `.centerAltitude` (:60, genuinely wired — `src/mbgl/map/transform.cpp:130` and `:230`); pitch bounds via `BoundOptions::withMinPitch`/`withMaxPitch` (`include/mbgl/map/bound_options.hpp:31/:36`); `FreeCameraOptions` with `setLocation`/`lookAtPoint`/`setRollPitchBearing` (`camera.hpp:141-177`) driven by `Map::setFreeCameraOptions` (`map.hpp:163`). Pitch is clamped to `DEFAULT_PITCH_MAX = M_PI/3` = 60° (`include/mbgl/util/constants.hpp:35`); default fov is `0.6435011` rad ≈ 36.87° (:41).
- **`hillshade-method` and multidirectional hillshading** are in core (`hillshade_layer.hpp:60-64`), as are vector-valued illumination direction/altitude/shadow/highlight (:36-58).
- **`RasterDEMSource` with an encoding option** (`include/mbgl/style/sources/raster_dem_source.hpp:16`, `SourceOptions::rasterEncoding` at :11).
- **Rendering stats**: `include/mbgl/gfx/rendering_stats.hpp:17` with `numFrames` (:26), `numDrawCalls` (:28); `Map::enableRenderingStatsView` (`map.hpp:151`).
- **Tile-LOD controls** that exist specifically to make high pitch affordable: `setTileLodMinRadius`/`setTileLodScale`/`setTileLodPitchThreshold`/`setTileLodZoomShift`/`setTileLodMode` (`map.hpp:197-206`).
- **`LayerManager::addLayerTypeCoreOnly`** (`include/mbgl/layermanager/layer_manager.hpp:77`) — the registration hook a real `model` layer type would use. Note there is **no plugin-layer factory at our pin**: `include/mbgl/layermanager/` has no `plugin_layer_factory.hpp`, so the Apple SDK 6.27's `MLNPluginLayer` / `-[MLNMapView addPluginLayerType:]` (MLNMapView.h:2323) mechanism postdates `fa8a9c8e3261` and is not available to us without a submodule bump.

**Corroboration from the Apple SDK.** The 164 public headers of MapLibre Apple 6.27.0 contain **no terrain API, no sky API, no globe/projection API** — `grep -rn "globe\|Globe"` over the whole Headers directory returns nothing, and the only "terrain" hits are doc prose in `MLNRasterDEMSource.h:65` and `MLNHillshadeStyleLayer.h:113`. A mature, shipped native SDK on the same engine offers exactly what mbgl offers: raster-DEM + hillshade + color-relief + fill-extrusion + `MLNLight`. That is independent confirmation that these are engine ceilings, not binding gaps.

#### Naming decisions

**Policy applied.** For everything the style spec owns (light, terrain, sky, projection, fill-extrusion/hillshade/color-relief properties, raster-dem) I take **gl-js / style-spec names verbatim** — `setLight`/`getLight`, `setTerrain`/`getTerrain`, `setSky`/`getSky`, `setProjection`/`getProjection`, `queryTerrainElevation` — because our typed style API is already generated from `v8.json` and every property name in it is the spec name. For things gl-js has no equivalent of I take the **Apple SDK shape**.

**Where upstream disagrees, and what I chose:**

1. **fill-extrusion property names.** The Apple SDK *renamed* two spec properties: `fill-extrusion-vertical-gradient` → `fillExtrusionHasVerticalGradient` (MLNFillExtrusionStyleLayer.h:183, with `fillExtrusionVerticalGradient` marked `unavailable` at :185) and `fill-extrusion-translate`/`-translate-anchor` → `fillExtrusionTranslation`/`fillExtrusionTranslationAnchor` (:288/:354, old names `unavailable` at :324/:356). gl-js and the spec keep the original names. **I chose the spec/gl-js names** (`fillExtrusionVerticalGradient`, `fillExtrusionTranslate`, `fillExtrusionTranslateAnchor`) — which is what our generator already emits, since it reads `v8.json`. Apple's rename is an Objective-C ergonomics choice, not a spec change; following it would silently desync us from the generator and from every style JSON on the internet.

2. **Light value shape.** gl-js `LightSpecification.position` is a bare 3-array `[r, a, p]`. Apple models it as a struct with named fields, `MLNSphericalPosition {radial, azimuthal, polar}` (MLNLight.h:30-39). Android takes a `Position` object (`org.maplibre.android.style.light.Position`). **I chose Apple's named-field shape** — `StyleLightPosition({radial, azimuthalDegrees, polarDegrees})` — because a `List<double>` of length 3 with positional meaning is exactly the kind of API that produces the coordinate bugs CLAUDE.md §11 warns about, and Dart has no tuple literal that reads better. `toJson()` still emits `[r, a, p]`, so the wire format stays spec-exact. **This is a Flutter-idiom adaptation and I am flagging it as such.**

3. **Light anchor type.** gl-js accepts a bare string; Apple uses `NSExpression` over `MLNLightAnchor` (MLNLight.h:14, :103); Android uses a `String` with `@LightAnchor` annotation. **I chose our generated-enum convention** (`StyleLightAnchor.map` / `.viewport`, `implements StyleEnum`), matching every other enum in `style_enums.g.dart`. Because the whole `light` object is generatable from `spec['light']`, the enum, the transitions and the `StyleValue<T>`/`Expression` covariance all fall out of the existing generator for free — this should be **generated, not hand-written**.

4. **Where `setLight` lives.** Three-bucket tension, stated openly. Light is style-document state, mutable, low-frequency and declarative — which reads like a widget prop (`MapLibreMap.light`). But it is *style-wide state that a style reload overwrites* (CLAUDE.md §11, mbgl behaviour), which is the exact same category as `setTransitionOptions`, and that already sits imperatively on `MapLibreStyleLayers` (`style_layers.dart:63`). **I chose the controller path — `controller.layers.setLight(...)` / `getLight()` — for precedent and to avoid re-inventing the re-apply-on-style-load machinery for a property most apps set once.** If a second style-global ever lands, rename the namespace `controller.style`; do not add a third home.

5. **`queryTerrainElevation` naming.** gl-js name kept verbatim even though the method is unbindable today — it is listed as `reject` so the name is reserved and nobody invents `getElevationAt`.

6. **Model API — we are genuinely soloing this, and it should be said out loud.** `MapLibreModel` / `MapLibreModelHost` has **no upstream equivalent anywhere**: no `model` layer type in `v8.json`, no model API in gl-js, none in the Apple SDK, none in Android. The closest analogues are all *lower level* and all hand you a GPU context rather than a mesh: gl-js `CustomLayerInterface` (`{id, type:'custom', renderingMode:'2d'|'3d', onAdd, prerender, render, onRemove}`), Apple `MLNCustomStyleLayer` (`-drawInMapView:withContext:`, MLNCustomStyleLayer.h:142) and the newer `MLNPluginLayer` (`+layerCapabilities`, `-onRenderLayer:renderEncoder:`, MLNPluginLayer.h:93/:97), and the community three.js/deck.gl patterns that sit on top of the gl-js one. The one upstream idea worth *stealing* is **`MLNPluginLayerCapabilities.layerProperties`** (MLNPluginLayer.h:59) — Apple drives a custom layer from **declared, style-JSON-addressable properties** rather than a bespoke value type. That is the shape our model API should converge on long-term (a `model` layer whose paint properties are spec-shaped and expression-driven), and it is why I propose `MapLibreModelSource` / per-model visibility+opacity+zoom-range now rather than growing more positional constructor args. Until then, **`MapLibreModel` stays `@experimental`.**

7. **Camera-domain overlap, flagged for dedupe.** `fieldOfView`, `centerElevation`, `roll` and min/max pitch are 3D camera controls that another agent's "camera" domain may also claim. I include them here because they are the 3D half of the camera and because **three of them are matrix errors** (see below), but the parent should keep one copy.

8. **Terminology I did NOT adopt.** gl-js `map.on('terrain')` / event-name strings — un-Dartlike; our analogue would be a `Listenable`, but the feature is rejected anyway so no name is coined.

#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | Model asset source — .glb must be a real FILE PATH, not a Flutter asset key | partial | — | — | n/a — our own loader, packages/maplibre_flutter_core/src/maplibre_flutter_core_gltf.hpp:34 (GLB only; no external .bin or images) | value-type | yes |
| P0 | Model mesh cache is never evicted — unbounded process-lifetime growth | present | — | — | n/a — our cache, not mbgl's | capability-interface | no |
| P1 | Color-relief layer (elevation → colour ramp) | present | map.addLayer({id, type:'color-relief', source, paint:{'color-relief-color': […]}}) *(unverified)* | MLNColorReliefStyleLayer (MLNColorReliefStyleLayer.h:25) | mbgl::style::ColorReliefLayer — include/mbgl/style/layers/color_relief_layer.hpp:18 | value-type | no |
| P1 | Fill-extrusion layer (3D buildings — the 3D that actually works) | present | map.addLayer({id, type:'fill-extrusion', source, 'source-layer', paint:{…}}) *(unverified)* | MLNFillExtrusionStyleLayer (MLNFillExtrusionStyleLayer.h:54) | mbgl::style::FillExtrusionLayer — include/mbgl/style/layers/fill_extrusion_layer.hpp:17 | value-type | no |
| P1 | Hillshade layer (2D relief — the terrain substitute that DOES work) | present | map.addLayer({id, type:'hillshade', source, paint:{…}}) *(unverified)* | MLNHillshadeStyleLayer (MLNHillshadeStyleLayer.h:92) | mbgl::style::HillshadeLayer — include/mbgl/style/layers/hillshade_layer.hpp:17 | value-type | no |
| P1 | MapLibreModel — the geo-anchored 3D model value type (OUR EXTENSION, no upstream equivalent) | present | — NONE. There is no `model` layer type in the style spec, no model API in gl-js. The nearest thing is CustomLayerInterface {id, type:'custom', renderingMode:'2d'\|'3d', onAdd?, prerender?, render, onRemove?} — which hands you a raw WebGL context, not a mesh. | — NONE. Nearest: MLNCustomStyleLayer (MLNCustomStyleLayer.h:51) with -drawInMapView:withContext: (:142) and MLNStyleLayerDrawingContext (:20); MLNCustomDrawableStyleLayer (MLNCustomDrawableStyleLayer.h:9, an empty marker class); MLNPluginLayer (MLNPluginLayer.h:89). | NO MODEL LAYER. Built on mbgl::style::CustomDrawableLayer — include/mbgl/style/layers/custom_drawable_layer.hpp:20 (host), :34 (Interface), :189 (addGeometry(vertices, indices, is3D)) | value-type | no |
| P1 | Model depth occlusion against fill-extrusion — carried by a Metal-ONLY patch | partial | — | — (MLNPluginLayerCapabilities.requiresPass3D, MLNPluginLayer.h:56, is the upstream knob for the same problem: declaring that a custom layer needs the 3D pass) | CustomDrawableLayer's LayerTypeInfo.pass3d is NotRequired, so it renders in the Translucent pass rather than the 3D pass fill-extrusion uses — that mismatch is what the patch works around (docs/3d-models-research.md §5) | capability-interface | no |
| P1 | Model lighting is HARDCODED and ignores the style's `light` | internal-only | — | — | Our patched GeometryOptions.light[4] — include/mbgl/style/layers/custom_drawable_layer.hpp:83 (default {0,0,1,0.85}), added by patches/custom-geometry-lighting.patch; the vertex NORMAL at :71 is ours too | capability-interface | no |
| P1 | Model load-failure reporting to the app | partial | — (gl-js's analogue is map.on('error')) *(unverified)* | -[MLNMapViewDelegate mapViewDidFailLoadingMap:withError:] (MLNMapViewDelegate.h) is the shape-analogue | n/a — our loader's error text, surfaced through mbl_map_add_model's out_error (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:395-400) | widget-callback | no |
| P1 | Model visibility / opacity / zoom range | none | — (the spec-shaped equivalents would be layout.visibility, a paint opacity, and minzoom/maxzoom on any layer) | MLNStyleLayer.visible / minimumZoomLevel / maximumZoomLevel (MLNStyleLayer.h) — every real layer type has these | Layer::setVisibility / setMinZoom / setMaxZoom — include/mbgl/style/layer.hpp; our host bypasses all of it by building drawables directly | value-type | yes |
| P1 | Re-applying `light` after a style load (style-level state is overwritten) | none | — (gl-js re-applies from the new style document; same hazard exists there) *(unverified)* | — (MLNStyle.light is re-read per style, same hazard) | style::Style::setLight — include/mbgl/style/style.hpp:47; the parser replaces the whole light on load (src/mbgl/style/parser.cpp:111, :236) | capability-interface | no |
| P1 | StyleLight value type — GENERATED from spec['light'], not hand-written | none | LightSpecification { anchor?, position?, color?, intensity?, plus *-transition keys } | MLNLight (MLNLight.h:74) with NSExpression anchor :103, position :139 + positionTransition :146, color :170/:193 + colorTransition :201, intensity :225 + intensityTransition :232 | include/mbgl/style/light.hpp:31-49 — every property with a matching PropertyValue<T> getter/setter AND a TransitionOptions pair | value-type | no |
| P1 | Warn when a style document contains unsupported `terrain` / `sky` / `projection` root keys | none | — (n/a, gl-js supports them) *(unverified)* | — (Apple has the same silent-drop behaviour) | src/mbgl/style/parser.cpp:43-119 — the parser reads 12 root keys and silently ignores everything else | capability-interface | no |
| P1 | light.anchor (map \| viewport) | none | light.anchor: 'map' \| 'viewport' (default 'viewport') | MLNLightAnchor {MLNLightAnchorMap, MLNLightAnchorViewport} (MLNLight.h:14-24); property :103 | LightAnchorType — include/mbgl/style/light.hpp:31-35 | value-type | no |
| P1 | light.color | none | light.color (default '#ffffff') | MLNLight.h:170 (UIColor, iOS) / :193 (NSColor, macOS) + colorTransition :201 | PropertyValue<Color> — include/mbgl/style/light.hpp:36-40 | value-type | no |
| P1 | light.intensity | none | light.intensity (0..1, default 0.5) | MLNLight.h:225 + intensityTransition :232 | PropertyValue<float> — include/mbgl/style/light.hpp:41-45 | value-type | no |
| P1 | light.position (radial / azimuthal / polar) | none | light.position: [r, a, p] (default [1.15, 210, 30]) | MLNSphericalPosition {CGFloat radial; CLLocationDirection azimuthal; CLLocationDirection polar} (MLNLight.h:30-39), + MLNSphericalPositionMake (:50); property :139 | PropertyValue<Position> — include/mbgl/style/light.hpp:46-50; the type at include/mbgl/style/position.hpp, converter at include/mbgl/style/conversion/position.hpp | value-type | no |
| P1 | modelPartCount(assetPath) — keyed by PATH against a process-global cache | present | — | — (nearest: MLNRenderingStats.numDrawCalls, MLNRenderingStats.h:18) | n/a | capability-interface | yes |
| P1 | raster-dem source (type='raster-dem') | present | map.addSource(id, {type:'raster-dem', url\|tiles, tileSize, encoding, redFactor, greenFactor, blueFactor, baseShift, bounds, minzoom, maxzoom, attribution, volatile}) *(unverified)* | MLNRasterDEMSource (MLNRasterDEMSource.h:70), + MLNTileSourceOptionDEMEncoding (:16) | mbgl::style::RasterDEMSource — include/mbgl/style/sources/raster_dem_source.hpp:16 | value-type | no |
| P1 | renderedFrameCount — mis-homed on the MODEL capability | present | — | MLNRenderingStats (MLNRenderingStats.h:7) with numFrames :15, numDrawCalls :18, totalDrawCalls :20, renderingTime :12, encodingTime :10, plus memory counters :67-75; toggled by -[MLNMapView enableRenderingStatsView:] (MLNMapView.h:2277) and read via -isRenderingStatsViewEnabled (:2272) | mbgl::gfx::RenderingStats — include/mbgl/gfx/rendering_stats.hpp:17, numFrames :26, numDrawCalls :28, numActiveTextures :35; Map::enableRenderingStatsView / isRenderingStatsViewEnabled — include/mbgl/map/map.hpp:150-151 | capability-interface | no |
| P1 | setLight — the root `light` object (lights fill-extrusion geometry) | none | map.setLight(light: LightSpecification, options?: StyleSetterOptions): this  /  map.getLight(): LightSpecification | @property (nonatomic, strong) MLNLight *light  (MLNStyle.h:284); the object itself is MLNLight (MLNLight.h:74) | style::Style::getLight() / setLight(std::unique_ptr<Light>) — include/mbgl/style/style.hpp:44-47; the class at include/mbgl/style/light.hpp:17; a ready-made Converter<Light> at include/mbgl/style/conversion/light.hpp:13; the parser already uses it (src/mbgl/style/parser.cpp:111, :236) | controller-namespace | yes |
| P2 | 3D on the Web tier (WASM core) — the whole domain is absent there | none | n/a — this is our WASM tier, not gl-js | — | Same mbgl compiled to WASM, so the same ceiling AND the same capabilities — the custom_geometry shaders exist for gl and webgpu (include/mbgl/shaders/webgpu/, include/mbgl/shaders/gl/) | capability-interface | no |
| P2 | Center elevation (camera target altitude above sea level) | none | map.setCenterElevation(elevation: number, options?: AnimationOptions): this  /  map.getCenterElevation(): number  /  map.getCameraTargetElevation(): number | MLNMapCamera.altitude (MLNMapCamera.h:49) — but that is EYE altitude, not target elevation; the two are different quantities. MLNMapCamera.viewingDistance (:57) is a third. | CameraOptions::centerAltitude — include/mbgl/map/camera.hpp:60-61, genuinely wired: src/mbgl/map/transform.cpp:130 and :230. The style root key `centerAltitude` is parsed too (src/mbgl/style/parser.cpp:72). | value-type | yes |
| P2 | Light transitions (position / color / intensity) | none | `position-transition` / `color-transition` / `intensity-transition` keys inside LightSpecification *(unverified)* | MLNTransition positionTransition (MLNLight.h:146), colorTransition (:201), intensityTransition (:232) | setAnchorTransition/setPositionTransition/setColorTransition/setIntensityTransition — include/mbgl/style/light.hpp:33/:38/:43/:48 | value-type | no |
| P2 | MapLibreMap.models — declarative widget prop with add/update/remove diffing | present | — | — | n/a | widget-prop | no |
| P2 | MapLibreModelHost — the optional model capability | present | — | — (nearest registration analogue: -[MLNMapView addPluginLayerType:] MLNMapView.h:2323) | custom_drawable_layer.hpp:20 CustomDrawableLayerHost | capability-interface | no |
| P2 | Min / max pitch limits | none | map.setMinPitch(minPitch: number): this / map.getMinPitch(): number / map.setMaxPitch(maxPitch: number): this / map.getMaxPitch(): number | @property CGFloat minimumPitch (MLNMapView.h:1107) / maximumPitch (:1118) — property form, not setter form. Header notes pitch 'may not exceed 60 degrees' (:1113). | BoundOptions::withMinPitch / withMaxPitch — include/mbgl/map/bound_options.hpp:31, :36 (fields :52, :55); applied via Map::setBounds (include/mbgl/map/map.hpp:98). Hard ceiling: DEFAULT_PITCH_MAX = M_PI/3 = 60° (include/mbgl/util/constants.hpp:35), PITCH_MAX = M_PI (:36). | controller-namespace | yes |
| P2 | Model draw order / beforeId (where the model sits in the layer stack) | none | map.addLayer(layer, beforeId?) *(unverified)* | -[MLNStyle insertLayer:belowLayer:] (MLNStyle.h:218) / insertLayer:aboveLayer: (:234) | Style::addLayer(std::unique_ptr<Layer>, const std::optional<std::string>& beforeLayerID) — include/mbgl/style/style.hpp:71 | capability-interface | yes |
| P2 | Model hit-testing / tap | none | — (a custom layer is invisible to queryRenderedFeatures in gl-js too — same limitation) *(unverified)* | — (MLNCustomStyleLayer is likewise not queryable) | NOT IN CORE for custom drawables. queryRenderedFeatures walks RenderSource tiles; a CustomDrawableLayer has no source and no feature index. | widget-callback | yes |
| P2 | Model instancing — many copies of one mesh | partial | — | — | No instanced-draw API on CustomDrawableLayerHost::Interface (include/mbgl/style/layers/custom_drawable_layer.hpp:94-199 is the full surface) | value-type | no |
| P2 | Model pitch / roll (only yaw is expressible) | partial | — | — | No constraint — GeometryOptions.matrix is a full mat4 (include/mbgl/style/layers/custom_drawable_layer.hpp:75), so any orientation is already expressible | value-type | yes |
| P2 | Pitch on the camera + tilt gesture (the 3D entry point that DOES work) | present | map.getPitch(): number; map.setPitch(pitch) / easeTo({pitch}) | MLNMapCamera.pitch (MLNMapCamera.h:36); -[MLNMapView isPitchEnabled] (MLNMapView.h:890) | CameraOptions::pitch — include/mbgl/map/camera.hpp:44-47, :80; Map::pitchBy — include/mbgl/map/map.hpp:78 | controller-namespace | no |
| P2 | Vertical field of view (camera FOV — the other half of the 3D look) | none | map.setVerticalFieldOfView(verticalFieldOfView: number): this  /  map.getVerticalFieldOfView(): number | MLNStyleLayerDrawingContext.fieldOfView is READ-ONLY context (MLNCustomStyleLayer.h:31); no public setter on MLNMapView | CameraOptions::fov / withFov — include/mbgl/map/camera.hpp:52-55, :86. Default DEFAULT_FOV = 0.6435011087932844 rad ≈ 36.87° (include/mbgl/util/constants.hpp:41) | value-type | yes |
| P2 | `elevation` expression (reads DEM height inside a color-relief ramp) | present | ['elevation'] expression *(unverified)* | — (NSExpression bridging; no dedicated symbol) | elevationCompoundExpression — src/mbgl/style/expression/compound_expression.cpp:374, registered at :1030; listed as a valid parameter in src/mbgl/style/expression/parsing_context.cpp:48; EvaluationContext::elevation at include/mbgl/style/expression/expression.hpp:92 and the `Elevation = 1 << 7` dependency at :220 | value-type | no |
| P2 | color-relief-color (ColorRampPropertyValue) and color-relief-opacity | present | paint['color-relief-color'] (a colour ramp over the `elevation` expression), paint['color-relief-opacity'] *(unverified)* | MLNColorReliefStyleLayer.h:60/:77 (colorReliefColor), :97 (opacity), transition :104 | ColorRampPropertyValue getColorReliefColor — include/mbgl/style/layers/color_relief_layer.hpp:25-29; opacity :31-35 | value-type | no |
| P2 | controller.addModel / updateModel / removeModel — imperative per-frame path | present | — | — | custom_drawable_layer.hpp:189 addGeometry; the per-frame matrix is applied through a GeometryTweakerCallback (:149) | controller | no |
| P2 | fill-extrusion-color (shaded by the root `light`) | present | paint['fill-extrusion-color'] (default #000000) *(unverified)* | MLNFillExtrusionStyleLayer.h:126 (iOS) / :150 (macOS), transition :158 | include/mbgl/style/layers/fill_extrusion_layer.hpp:30-34 | value-type | no |
| P2 | fill-extrusion-height | present | paint['fill-extrusion-height'] (metres, default 0, data-driven) *(unverified)* | MLNFillExtrusionStyleLayer.h:204, transition :211 | include/mbgl/style/layers/fill_extrusion_layer.hpp:36-40 | value-type | no |
| P2 | hillshade-exaggeration | present | paint['hillshade-exaggeration'] (default 0.5) *(unverified)* | -[MLNHillshadeStyleLayer hillshadeExaggeration] (MLNHillshadeStyleLayer.h:179), transition :186 | HillshadeLayer::setHillshadeExaggeration — include/mbgl/style/layers/hillshade_layer.hpp:30-34 | value-type | no |
| P2 | hillshade-illumination-direction (multidirectional: List<double>) | present | paint['hillshade-illumination-direction'] (default 335) *(unverified)* | -[MLNHillshadeStyleLayer hillshadeIlluminationDirection] (MLNHillshadeStyleLayer.h:308) | PropertyValue<std::vector<float>> — include/mbgl/style/layers/hillshade_layer.hpp:54-58 | value-type | no |
| P2 | hillshade-method (standard \| basic \| combined \| igor \| multidirectional) | present | paint['hillshade-method'] *(unverified)* | MLNHillshadeMethod enum (MLNHillshadeStyleLayer.h:35); property :342 | HillshadeMethodType — include/mbgl/style/layers/hillshade_layer.hpp:60-64 | value-type | no |
| P2 | raster-dem encoding enum (mapbox \| terrarium \| custom) | present | encoding?: 'terrarium' \| 'mapbox' \| 'custom' (default 'mapbox') *(unverified)* | MLNDEMEncoding {MLNDEMEncodingMapbox=0, MLNDEMEncodingTerrarium=1} (MLNRasterDEMSource.h:22-35) — note Apple has NO 'custom' case | Tileset::RasterEncoding via SourceOptions::rasterEncoding — include/mbgl/style/sources/raster_dem_source.hpp:11 | value-type | no |
| P3 | Axonometric projection mode (native-only 3D skew — mbgl HAS this, gl-js does not) | none | — (no gl-js equivalent) | — (not surfaced in the public Apple headers) | Map::setProjectionMode(const ProjectionMode&) / getProjectionMode() — include/mbgl/map/map.hpp:115-116; the struct at include/mbgl/map/projection_mode.hpp:12 with withAxonometric(bool) :13, withXSkew(double) :17, withYSkew(double) :21 | capability-interface | yes |
| P3 | Built-in test model (spinning four-colour pyramid) | internal-only | — | — | n/a | reject | no |
| P3 | Camera roll (bank angle) | none | map.setRoll / map.getRoll — v8.json root `roll` lists js: 5.0.0, so gl-js 5.x has it; I did NOT fetch the Map method page for the exact signature, so it is left unquoted rather than guessed *(unverified)* | — (no roll on MLNMapCamera) | CameraOptions::roll / withRoll — include/mbgl/map/camera.hpp:48-51, :83; FreeCameraOptions::setRollPitchBearing — :177; the style root `roll` key is parsed at src/mbgl/style/parser.cpp:100 | value-type | yes |
| P3 | Generic CustomDrawableLayer escape hatch (polylines / fills / symbols beyond models) | none | CustomLayerInterface {id, type:'custom', renderingMode:'2d'\|'3d', onAdd?, prerender?, render, onRemove?} — a raw GL context, no drawing helpers | MLNCustomDrawableStyleLayer (MLNCustomDrawableStyleLayer.h:9 — an empty marker class, no public drawing API); MLNCustomStyleLayer's -drawInMapView:withContext: (MLNCustomStyleLayer.h:142) with MLNStyleLayerDrawingContext {size, centerCoordinate, zoomLevel, direction, pitch, fieldOfView, projectionMatrix} (:20-35) | CustomDrawableLayerHost::Interface — addPolyline(GeometryCoordinates\|LineString, LineShaderType) at include/mbgl/style/layers/custom_drawable_layer.hpp:158/:168, addFill(GeometryCollection) :177, addSymbol(GeometryCoordinate, texCoords) :186, addGeometry(...) :189, plus per-type option structs at :41 (LineOptions), :52 (FillOptions), :57 (SymbolOptions) and tweaker callbacks at :146-149 | capability-interface | yes |
| P3 | Model animation — glTF animation channels, skins, morph targets | none | — (three.js on a custom layer can skin; that is a separate engine, not MapLibre) | — | Shader ceiling. GeometryVertex is position+uv+normal only (include/mbgl/style/layers/custom_drawable_layer.hpp:66-72); no joint/weight attributes, no bone matrix array. | reject | no |
| P3 | Model per-instance tint / colour | none | — | — | GeometryOptions.color — include/mbgl/style/layers/custom_drawable_layer.hpp:76 (already a per-drawable tint, already plumbed) | value-type | yes |
| P3 | Model shadows | none | — (the official gl-js 'shadow' example fakes it with a transparent three.js ShadowMaterial plane) *(unverified)* | — | NOT IN CORE. No shadow pass, no light-space depth buffer. docs/3d-models-research.md:32: 'MapLibre has no equivalent to Mapbox v3's `lights`.' | reject | no |
| P3 | Terrain-draped markers / models (anchored content that follows ground height) | none | — (gl-js does this implicitly once setTerrain is active) *(unverified)* | — | NOT IN CORE — follows from stop #1 | reject | no |
| P3 | Tile-LOD tuning (the perf lever that makes high pitch affordable) | none | — (no gl-js equivalent) | @property double tileLodPitchThreshold (MLNMapView.h:520, documented as 'Pitch angle in radians above which LOD calculation is performed') | Map::setTileLodMinRadius / setTileLodScale / setTileLodPitchThreshold / setTileLodZoomShift / setTileLodMode — include/mbgl/map/map.hpp:197-206, with the full heuristic documented at :166-196 | widget-init | yes |
| P3 | atmosphere-blend | none | sky['atmosphere-blend'] (0..1, default 0.8) | — | NOT IN CORE | reject | no |
| P3 | fill-extrusion-base | present | paint['fill-extrusion-base'] (default 0) *(unverified)* | MLNFillExtrusionStyleLayer.h:94, transition :101 | include/mbgl/style/layers/fill_extrusion_layer.hpp:24-28 | value-type | no |
| P3 | fill-extrusion-opacity | present | paint['fill-extrusion-opacity'] (default 1, per-layer not per-feature) *(unverified)* | MLNFillExtrusionStyleLayer.h:231, transition :238 | include/mbgl/style/layers/fill_extrusion_layer.hpp:42-46 | value-type | no |
| P3 | fill-extrusion-pattern | present | paint['fill-extrusion-pattern'] (an image name) *(unverified)* | MLNFillExtrusionStyleLayer.h:254, transition :261 | PropertyValue<expression::Image> — include/mbgl/style/layers/fill_extrusion_layer.hpp:48-52 | value-type | no |
| P3 | fill-extrusion-translate / -translate-anchor | present | paint['fill-extrusion-translate'] / ['fill-extrusion-translate-anchor'] *(unverified)* | **RENAMED by Apple**: fillExtrusionTranslation (MLNFillExtrusionStyleLayer.h:288 iOS / :314 macOS) and fillExtrusionTranslationAnchor (:354); the spec-named fillExtrusionTranslate / fillExtrusionTranslateAnchor are marked `unavailable` at :324 / :356 | include/mbgl/style/layers/fill_extrusion_layer.hpp:54-58 (translate), :60-64 (translate-anchor) | value-type | no |
| P3 | fill-extrusion-vertical-gradient | present | paint['fill-extrusion-vertical-gradient'] (default true) *(unverified)* | **RENAMED by Apple**: fillExtrusionHasVerticalGradient (MLNFillExtrusionStyleLayer.h:183); the spec name is `unavailable` at :185 | include/mbgl/style/layers/fill_extrusion_layer.hpp:66-70 | value-type | no |
| P3 | fog-color | none | sky['fog-color'] (default #ffffff) | — | NOT IN CORE | reject | no |
| P3 | fog-ground-blend | none | sky['fog-ground-blend'] (0..1, default 0.5) | — | NOT IN CORE | reject | no |
| P3 | getSky | none | map.getSky(): SkySpecification \| null | — | NOT IN CORE | reject | no |
| P3 | getTerrain | none | map.getTerrain(): TerrainSpecification \| null | — | NOT IN CORE (src/mbgl/style/parser.cpp:43-119) | reject | no |
| P3 | hillshade-illumination-altitude | present | paint['hillshade-illumination-altitude'] (default 45) *(unverified)* | MLNHillshadeStyleLayer.h:260 | include/mbgl/style/layers/hillshade_layer.hpp:42-46 | value-type | no |
| P3 | hillshade-illumination-anchor (map \| viewport) | present | paint['hillshade-illumination-anchor'] (default 'viewport') *(unverified)* | MLNHillshadeIlluminationAnchor enum (MLNHillshadeStyleLayer.h:15); property :284 | HillshadeIlluminationAnchorType — include/mbgl/style/layers/hillshade_layer.hpp:48-52 | value-type | no |
| P3 | hillshade-shadow-color / -highlight-color / -accent-color | present | paint['hillshade-shadow-color'] / ['hillshade-highlight-color'] / ['hillshade-accent-color'] *(unverified)* | MLNHillshadeStyleLayer.h:365/:387 (shadow), :209/:231 (highlight), :131/:152 (accent), + transitions :395/:239/:160 | include/mbgl/style/layers/hillshade_layer.hpp:66-70 (shadow), :36-40 (highlight), :24-28 (accent) | value-type | no |
| P3 | horizon-color | none | sky['horizon-color'] (default #ffffff) | — | NOT IN CORE | reject | no |
| P3 | horizon-fog-blend | none | sky['horizon-fog-blend'] (0..1, default 0.8) | — | NOT IN CORE | reject | no |
| P3 | queryTerrainElevation — elevation of a LngLat under the loaded DEM | none | map.queryTerrainElevation(lngLat: LngLatLike): number \| null | — | NOT IN CORE. DEM tiles are decoded (src/mbgl/geometry/dem_data.cpp) but only as a hillshade/color-relief input — there is no public sampling entry point on Map or Source. | reject | yes |
| P3 | raster-dem custom encoding factors (redFactor / greenFactor / blueFactor / baseShift) | present | redFactor/greenFactor/blueFactor/baseShift on the raster-dem source spec *(unverified)* | — (no Apple equivalent) | Tileset custom encoding — include/mbgl/util/tileset.hpp via SourceOptions (raster_dem_source.hpp:10-13) | value-type | no |
| P3 | setProjection / getProjection (mercator \| globe \| vertical-perspective) | none | map.setProjection(projection: ProjectionSpecification): this  /  map.getProjection(): ProjectionSpecification | — (grep for 'globe' over all 164 headers: zero hits. MLNMapProjection.h is a COORDINATE-CONVERSION helper — camera :26, convertPoint: :57, convertCoordinate: :66, metersPerPoint :71 — not a map projection selector. Do not confuse the two names.) | NOT IN CORE. No `projection` root key in src/mbgl/style/parser.cpp:43-119; no projectionDefinition type; grep -ril 'globe' include/mbgl/ hits only map_options.hpp prose and shaders/mtl/widevector.hpp | reject | no |
| P3 | setSky — sky/atmosphere/fog root object | none | map.setSky(sky: SkySpecification \| null, options?: StyleSetterOptions): this | — (grep -ril 'sky' over all 164 headers: zero hits) | NOT IN CORE. `grep -ril "sky" include/mbgl/` returns ZERO files. No sky factory in include/mbgl/layermanager/ (13 factories, none of them sky). No `sky` root key in src/mbgl/style/parser.cpp:43-119. | reject | no |
| P3 | setTerrain — enable 3D terrain from a raster-dem source | none | map.setTerrain(terrain: TerrainSpecification \| null, options?: StyleSetterOptions): this | —  (no terrain API in any of the 164 headers; grep over Headers/ finds only doc prose at MLNRasterDEMSource.h:65) | NOT IN CORE. No terrain.hpp under include/mbgl/; the style parser never reads the `terrain` root key (src/mbgl/style/parser.cpp:43-119 enumerates every key it reads) | reject | no |
| P3 | sky-color | none | sky['sky-color'] (default #88C6FC, interpolatable by zoom, transitionable) | — | NOT IN CORE | reject | no |
| P3 | sky-horizon-blend | none | sky['sky-horizon-blend'] (0..1, default 0.8) | — | NOT IN CORE | reject | no |
| P3 | terrain.source + terrain.exaggeration (the TerrainSpecification value type) | none | TerrainSpecification { source: string (required); exaggeration?: number (min 0, default 1) } | — | NOT IN CORE | reject | no |

#### Proposed signatures

**Model asset source — .glb must be a real FILE PATH, not a Flutter asset key** — P0, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:31 (assetPath) with the doc at :27-30: 'Must be a real file path, not a Flutter asset key — the engine reads it natively. Copy bundled assets out to a temp file first.' The example app carries a whole shim for this: packages/maplibre_flutter/example/lib/model_asset_io.dart + model_asset_web.dart.
```dart
sealed class MapLibreModelSource {
  const factory MapLibreModelSource.asset(String assetKey) = _AssetModelSource;
  const factory MapLibreModelSource.file(String path)      = _FileModelSource;
  const factory MapLibreModelSource.bytes(Uint8List glb)   = _BytesModelSource;
}
// MapLibreModel({required MapLibreModelSource source, …})
```
> **p0: a blocker for ordinary apps.** Every Flutter app ships models as bundle assets; today every single one must reimplement the same rootBundle→temp-file dance, and our OWN EXAMPLE APP had to write it twice (io + web). That is the definition of a missing binding. `.bytes` additionally removes the temp file entirely and is the only path that can work on web. Needs a `mbl_map_add_model_bytes(MblMap*, const char* layer_id, const uint8_t* glb, size_t len, …)` alongside the path form, hence an ffigen regen. Keep the path form — it is right for large models you do not want in memory twice.

**Model mesh cache is never evicted — unbounded process-lifetime growth** — P0, `capability-interface`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1105 `std::unordered_map<std::string, std::shared_ptr<const MblMeshData>> meshCache;` — inserted at :1156, read at :1142 and :1209, and **there is no erase() anywhere in the file** (grep for meshCache returns exactly lines 1104, 1105, 1141, 1142, 1143, 1155, 1156, 1208, 1209, 1210)
```dart
// no public API change; the fix is refcount-on-removeModel plus an opt-in cap:
// void removeModel(String id)  →  drops the mesh when the last user goes
```
> **p0 — a real defect, not a missing feature.** `removeModel` tears down the layer but the parsed CPU mesh stays resident for the life of the process. An app that cycles models (a route replay, a model picker, hot reload during development) grows without bound; the header itself notes a real Sketchfab car was 509k vertices across 149 primitives, so this is tens of MB per distinct .glb. The cache was added for a good reason (re-adding after a style reload must not re-read the file — maplibre_flutter_core_model.hpp:79-81), so the fix is refcounting, not deletion: keep the entry while any host or the retained-model registry holds it, drop it when the last reference goes. Pure C++; no ABI change, no regen.

**Color-relief layer (elevation → colour ramp)** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:2287 (ColorReliefLayer)
```dart
controller.layers.addLayer(ColorReliefLayer(id: 'relief', source: 'dem', colorReliefColor: Expression.interpolate(…, Expression.elevation(), …)))  // already exists
```
> p1 for the same reason as hillshade: this is what you demo when someone asks for terrain. Together with hillshade it gives shaded, coloured relief with zero terrain support.

**Fill-extrusion layer (3D buildings — the 3D that actually works)** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:1659 (FillExtrusionLayer); added via packages/maplibre_flutter/lib/src/map_layers_controller.dart:93
```dart
controller.layers.addLayer(FillExtrusionLayer(id: 'buildings', source: 'openmaptiles', sourceLayer: 'building', fillExtrusionHeight: Expression.get('render_height'), fillExtrusionColor: Value(Colors.grey)))  // already exists
```
> **p1 is a verification gap, not a binding gap.** Grep of packages/maplibre_flutter/example/lib/main.dart for 'extrusion' returns nothing — there is no 3D-buildings scenario in the example app, so this has never been rendered on ANY tier. Given the whole 3D-model feature exists to depth-occlude against extruded buildings (model_host.dart:5-7 says exactly that), and the depth fix needed a Metal-only mbgl patch, shipping a fill-extrusion scenario is also the regression test for the model depth work.

**Hillshade layer (2D relief — the terrain substitute that DOES work)** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:2083 (HillshadeLayer)
```dart
controller.layers.addLayer(HillshadeLayer(id: 'hills', source: 'dem', hillshadeExaggeration: Value(0.6)))  // already exists
```
> **This is the row to promote in docs.** When a user asks for terrain and the answer is 'mbgl can't', hillshade + color-relief over a raster-dem source is the honest, working substitute and it is fully bound today. p1 = build the example-app scenario and get all five native tiers off 🧪.

**MapLibreModel — the geo-anchored 3D model value type (OUR EXTENSION, no upstream equivalent)** — P1, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:13 (class), fields :27-61, isSamePlacementSourceAs :69
```dart
// keep, but tighten (see the rows below):
class MapLibreModel {
  const MapLibreModel({required String id, required MapLibreModelSource source,
    required LatLng point, double scale, double headingDegrees,
    double spinDegreesPerSecond, double elevationMetres,
    bool visible, double opacity, double? minZoom, double? maxZoom});
}
```
> **THIS IS WHERE WE ARE SOLOING, and the spec should say so loudly.** There is no upstream naming to copy — not in the spec, not in gl-js, not in Apple, not in Android — so every decision here is ours to defend. Two consequences: (a) keep it `@experimental` until the shape settles, which the code already does; (b) the one upstream idea worth stealing is MLNPluginLayerCapabilities.layerProperties (MLNPluginLayer.h:59), where a custom layer declares STYLE-JSON-ADDRESSABLE properties rather than exposing a bespoke Dart class. Converging on a spec-shaped `model` layer is the long-term exit from soloing.

**Model depth occlusion against fill-extrusion — carried by a Metal-ONLY patch** — P1, `capability-interface`, evidence: packages/maplibre_flutter_core/patches/metal-custom-drawable-3d-depth.patch (1.8 KB) and packages/maplibre_flutter_core/patches/metal-custom-geometry-sampler-repeat.patch (1.7 KB) — both Metal-only; the cross-backend lighting work is packages/maplibre_flutter_core/patches/custom-geometry-lighting.patch (18.6 KB). Applied idempotently by packages/maplibre_flutter_core/hook/build.dart.
```dart
// no API change; a platform-support note on MapLibreModel:
// 'Depth occlusion against 3D buildings is verified on Metal (macOS/iOS).
//  GL and Vulkan carry the same fix unverified.'
```
> **p1 because it is a documentation/verification debt with a shipping-risk edge.** The whole selling point of engine-drawn models over a widget overlay is depth occlusion (model_host.dart:5-7 says so), and that property is verified on exactly one backend. Two consequences to write down: (a) users on Windows/Linux/Android may see models float over buildings, and today nothing tells them; (b) `requiresPass3D` in Apple 6.27 suggests upstream solved this properly AFTER our pin — worth checking whether a submodule bump lets us drop a carried patch, which CLAUDE.md §9 flags as a real cost (patch order matters, patches must be regenerated against a pristine submodule).

**Model lighting is HARDCODED and ignores the style's `light`** — P1, `capability-interface`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core_model.cpp:159-164 — `constexpr double kLx = -0.4, kLy = -0.45, kLz = 0.8;` with a fixed 0.55 ambient, rotated by the model's own yaw. No Dart or C ABI control; mbl_map_add_model (maplibre_flutter_core.h:395) has no light parameters.
```dart
// once StyleLight lands, drive the model shader FROM it rather than adding a
// second, parallel light control:
//   model light direction := StyleLight.position (converted r/a/p → xyz)
//   model ambient         := 1 - StyleLight.intensity
```
> **Coherence problem worth naming.** Buildings are lit by the style's root `light`; our models are lit by two hardcoded constants in a .cpp file. Whatever the app sets on the style, models will disagree. This is the strongest argument for prioritising setLight: bind the light once and drive BOTH from it, rather than shipping a second bespoke model-light API we would then have to keep in sync. If setLight lands first, this row is ~30 lines in the shim and no new public API at all.

**Model load-failure reporting to the app** — P1, `widget-callback`, evidence: Throws ArgumentError from packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:279; the widget catches it and routes to FlutterError.reportError (packages/maplibre_flutter/lib/src/maplibre_map.dart:156-167). So it is never silent — but there is no programmatic hook.
```dart
MapLibreMap(onModelError: (String modelId, Object error) { … })
```
> The C ABI already produces a good error string and the widget already catches — the only gap is that the app cannot react (show a placeholder, retry, fall back to a marker). FlutterError.reportError is a debug channel, not an app-facing one. Pure Dart, no ABI change.

**Model visibility / opacity / zoom range** — P1, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:14-22 — the constructor has no visible/opacity/minZoom/maxZoom
```dart
MapLibreModel(…, bool visible = true, double opacity = 1, double? minZoom, double? maxZoom)
```
> **Every other layer in the system has these three and our model layer has none of them.** Hiding a model today means removing it, which drops the mesh; showing it again re-parses. Zoom range matters especially: a few-metre object is sub-pixel below ~z18 and is pure cost. `visible` and the zoom range are cheap (skip the drawable in the tweaker); `opacity` needs a shader uniform — the tint already exists in GeometryOptions.color (custom_drawable_layer.hpp:76), so alpha may come almost free.

**Re-applying `light` after a style load (style-level state is overwritten)** — P1, `capability-interface`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp — the style-load observer that already re-adds retained models (see packages/maplibre_flutter/lib/src/maplibre_map.dart:197-198, 'the core re-adds retained models itself')
```dart
// internal: the core retains the last-set StyleLight and re-applies it from
// onDidFinishLoadingStyle, exactly as it already does for retained models.
```
> **Ship this WITH setLight or the feature is broken by design.** CLAUDE.md §11: 'Loading a style overwrites style-level state.' We already have the machinery and the precedent — models survive a style change because the core retains and re-adds them. Light must do the same, or `MapLibreMap.style` changes silently reset it. Same argument applies to `setTransitionOptions`, which may already have this bug (worth checking as a side quest).

**StyleLight value type — GENERATED from spec['light'], not hand-written** — P1, `value-type`, evidence: packages/maplibre_flutter/tool/generate_style_api.dart — it reads spec['layer'] (:212), spec['layout_*']/spec['paint_*'] (:237-238), spec['source_*'] (:505), spec['transition'] (:623) and spec['expression_name'] (:665). It does NOT read spec['light']. Output would be packages/maplibre_flutter/lib/src/style/generated/style_light.g.dart
```dart
// generated:
final class StyleLight {
  const StyleLight({this.anchor, this.position, this.positionTransition,
                    this.color, this.colorTransition,
                    this.intensity, this.intensityTransition});
  final StyleValue<StyleLightAnchor>? anchor;
  final StyleValue<StyleLightPosition>? position;
  final StyleTransition? positionTransition;
  final StyleValue<Color>? color;
  final StyleTransition? colorTransition;
  final StyleValue<double>? intensity;
  final StyleTransition? intensityTransition;
  Map<String, Object?> toJson();
}
```
> **Extend the generator rather than hand-writing this.** spec['light'] is a flat property map, structurally identical to spec['transition'] which the generator already handles (:623) — so the enum, the transitions, and the `StyleValue<T>` / `Expression` covariance all come for free, and CI's regen-diff keeps it honest. CLAUDE.md §9: generated files are committed, never hand-edited. Do the same for spec['terrain'], spec['sky'] and spec['projection'] behind a flag the day mbgl supports them.

**Warn when a style document contains unsupported `terrain` / `sky` / `projection` root keys** — P1, `capability-interface`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp (in the set-style path, beside mbl_map_set_style — maplibre_flutter_core.h:57)
```dart
// no public API; a one-line mbgl::Log::Warning on style load:
// "style declares `terrain`, which MapLibre Native does not implement — ignored"
```
> **Cheapest high-value item in the whole domain.** Many popular styles (MapTiler Outdoor, Winter, 3D variants) carry a `terrain` clause. Today they load, render flat, and the user has no signal at all — they will file it as our bug. A warning at parse time converts a support burden into a documented limitation. Costs about ten lines in the shim and no ABI change.

**light.anchor (map | viewport)** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_enums.g.dart (would be generated here, alongside HillshadeIlluminationAnchor at :97)
```dart
enum StyleLightAnchor implements StyleEnum { map('map'), viewport('viewport'); … }
```
> Naming disagreement resolved: Android is stringly-typed, Apple wraps an NS_ENUM in an NSExpression. We take the generated-enum form to match every other enum we ship. Semantics are identical to HillshadeIlluminationAnchor, which is a useful docs cross-reference.

**light.color** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_light.g.dart (would be generated)
```dart
StyleLight(color: Value(const Color(0xFFFFF3E0)), colorTransition: StyleTransition(duration: Duration(seconds: 1)))
```
> Our generator already maps spec `color` → `StyleValue<Color>` (see fillExtrusionColor at style_layers.g.dart:1756), so this needs no new type mapping.

**light.intensity** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_light.g.dart (would be generated)
```dart
StyleLight(intensity: Value(0.5), intensityTransition: StyleTransition(duration: …))
```
> Spec range is 0..1; the generator does not emit range assertions today, so document it in the dartdoc.

**light.position (radial / azimuthal / polar)** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_light.g.dart (would be generated)
```dart
final class StyleLightPosition {
  const StyleLightPosition({this.radial = 1.15, this.azimuthalDegrees = 210, this.polarDegrees = 30});
  final double radial, azimuthalDegrees, polarDegrees;
  List<double> toJson() => [radial, azimuthalDegrees, polarDegrees];
}
```
> **Flutter-idiom adaptation, deliberate.** gl-js's bare `[r, a, p]` is exactly the positional-array shape CLAUDE.md §11 blames for this project's recurring coordinate bugs; Apple and Android both name the fields, so named fields are also the SDK-majority choice. `toJson()` still emits `[r, a, p]`. Document the convention explicitly: azimuthal 0° = top of viewport when anchor=viewport, due north when anchor=map, proceeding CLOCKWISE; polar 0° = directly above, 180° = directly below (MLNLight.h:33-38). Verify with an asymmetric fixture, not a round-trip.

**modelPartCount(assetPath) — keyed by PATH against a process-global cache** — P1, `capability-interface`, evidence: packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:121; packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:249; C ABI packages/maplibre_flutter_core/src/maplibre_flutter_core.h:434 — `uint32_t mbl_model_part_count(const char* glb_path)`, note it takes NO MblMap*; impl at packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:1204-1210 reading the file-scope `meshCache` declared at :1105
```dart
int? modelPartCount(String modelId);   // key by MODEL ID, not asset path
```
> Two real problems. (1) **It is process-global, not per-map** — the C entry point takes no map handle and reads a static cache, so two MapLibreMap widgets share it and a query can report a mesh the asking map never loaded. (2) **It is keyed on the asset path**, which stops working the moment MapLibreModelSource.bytes exists (no path to key on). Re-key on the model id and route it through the map handle. Do this in the same change as the source row so the ffigen regen is paid once.

**raster-dem source (type='raster-dem')** — P1, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart:208 (RasterDemSource); reachable via packages/maplibre_flutter/lib/src/map_layers_controller.dart:97 addSource / :106 addSourceJson
```dart
controller.layers.addSource('dem', RasterDemSource(url: 'https://…/terrain-rgb.json', tileSize: 256))  // already exists
```
> Generated, complete, and NEVER EXERCISED — there is no hillshade/DEM scenario in packages/maplibre_flutter/example/lib/main.dart (grep for Hillshade/RasterDem returns nothing). p1 is a TEST gap, not a binding gap.

**renderedFrameCount — mis-homed on the MODEL capability** — P1, `capability-interface`, evidence: packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:130 (`int? get renderedFrameCount` — declared on MapLibreModelHost); packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:239; C ABI `mbl_map_frame_count` at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:428
```dart
// move to its own capability, named after mbgl/Apple rather than after models:
abstract interface class MapLibreRenderingStats {
  int? get numFrames;       // mbgl RenderingStats::numFrames / MLNRenderingStats.numFrames
  int? get numDrawCalls;
}
// app-facing: controller.renderingStats
```
> **A contract-shape defect, and contract churn is the expensive kind (CLAUDE.md §3) — so fix it before more tiers depend on the current shape.** The map's frame rate has nothing to do with 3D models; today a tier that wants to report fps must claim to host models, and an app must go through `controller.modelPartCount`'s neighbour to get it. Both upstream SDKs already give this its own home and its own name (`numFrames`), and mbgl exposes a whole RenderingStats struct we are reading one field of. Pure Dart + one shim getter; the C ABI (mbl_map_frame_count) is already correct and map-scoped, unlike mbl_model_part_count.

**setLight — the root `light` object (lights fill-extrusion geometry)** — P1, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart (should sit beside setTransitionOptions at :63); app-facing in packages/maplibre_flutter/lib/src/map_layers_controller.dart (beside setTransitionOptions at :172)
```dart
// platform interface, on MapLibreStyleLayers:
void setLightJson(String json);
String? getLightJson();

// app-facing, on MapLibreLayersController:
void setLight(StyleLight light);
StyleLight? getLight();
```
> **The headline actionable item in this domain.** Everything needed is already in core, including the JSON converter, so the C ABI is a straight mirror of the existing `mbl_map_add_layer_json` pattern: `int mbl_map_set_light_json(MblMap*, const char* json, char* out_error, size_t cap)` + `char* mbl_map_get_light_json(MblMap*)` (freed by the existing `mbl_string_free`, maplibre_flutter_core.h:252). JSON rather than per-property entry points, for exactly the reason the layer path is JSON: it buys the whole spec (expressions, transitions) through `convertJSON<Light>` with no future ABI churn. Parse synchronously on the calling thread so bad JSON throws immediately (CLAUDE.md §11). Requires an ffigen regen on macOS.

**3D on the Web tier (WASM core) — the whole domain is absent there** — P2, `capability-interface`, evidence: packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:20 — documents that MapLibreModelHost is 'absent by necessity, not oversight'; the web controller implements neither MapLibreModelHost nor MapLibreStyleLayers
```dart
// no new API — the web tier should implement the EXISTING MapLibreStyleLayers
// so fill-extrusion / hillshade / color-relief work there too.
```
> The single highest-leverage web item in this domain is not a 3D feature at all — it is wiring MapLibreStyleLayers into the web controller, which brings fill-extrusion, hillshade and color-relief along for free since they are just layer documents. Models on web are a bigger lift (asset delivery + the glFlush-after-blit rule, CLAUDE.md §11) and should wait.

**Center elevation (camera target altitude above sea level)** — P2, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/camera.dart:10 — no elevation field
```dart
// on MapCamera:
final double? centerElevationMetres;
// on MapLibreCameraController (gl-js names):
Future<void> setCenterElevation(double metres, {Duration? duration});
Future<double> getCenterElevation();
```
> Camera-domain overlap; flagged for dedupe. **Name carefully** — Apple's `altitude` (eye), Apple's `viewingDistance` (eye-to-target), and gl-js's `centerElevation` (target above sea level) are three different numbers with confusable names. Take the gl-js name per policy, spell out 'metres above sea level, of the point the camera looks at' in the dartdoc.

**Light transitions (position / color / intensity)** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_transition.g.dart (StyleTransition already exists and would be reused)
```dart
StyleLight(positionTransition: StyleTransition(duration: Duration(seconds: 2), delay: Duration.zero), …)
```
> This is the payoff for choosing the JSON C ABI: transitions ride along in the light document with zero extra ABI. Note mbgl declares an anchor transition too (light.hpp:33) even though the spec says anchor is `transition: false` — follow the spec, not the header.

**MapLibreMap.models — declarative widget prop with add/update/remove diffing** — P2, `widget-prop`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:34 (ctor), :67 (field), diff at :138-169, pushed from didUpdateWidget :196-200
```dart
MapLibreMap(models: [MapLibreModel(id: 'car', source: …, point: …)])  // already exists
```
> Correct three-bucket placement, and the diff is smart: isSamePlacementSourceAs (model_host.dart:69) distinguishes 'moved' from 'reloaded' so a placement change never re-parses the .glb. **But controller.addModel's own dartdoc is now stale** — packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:203-206 still says 'The eventual API is a declarative MapLibreMap(models: ...)… this exists so the renderer can be exercised before that lands.' That prop shipped. Fix the doc to say what it actually is: the per-frame escape hatch.

**MapLibreModelHost — the optional model capability** — P2, `capability-interface`, evidence: packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:105; implemented by all five native tiers (macos:37, ios:47, android:46, linux:39, windows:43); deliberately absent on web (packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:20 documents why)
```dart
abstract interface class MapLibreModelHost {
  void addModel(MapLibreModel model);
  void updateModel(MapLibreModel model);
  void removeModel(String id);
  int? modelPartCount(String assetPath);   // → see the defect rows below
  int? get renderedFrameCount;             // → MIS-HOMED, see below
}
```
> Correctly built as an optional `is`-detected capability per CLAUDE.md §3. The interface is sound; the two problems are its MEMBERSHIP (renderedFrameCount does not belong) and the model value type's expressiveness — both filed separately.

**Min / max pitch limits** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/map_options.dart:13 — MapOptions carries only initialCamera (:20); no pitch bounds anywhere
```dart
// on MapLibreCameraController (gl-js names):
Future<void> setMinPitch(double degrees);
Future<void> setMaxPitch(double degrees);
Future<double> getMinPitch();
Future<double> getMaxPitch();
```
> Camera-domain overlap; flagged for dedupe. **Naming disagreement**: gl-js uses setters, Apple uses properties, Android puts them on init-only options. I take the gl-js setter form (policy) but note the three-bucket argument for ALSO seeding them from MapOptions. Document the 60° ceiling (constants.hpp:35) or users will set 85 and quietly get 60 — CLAUDE.md §11 already flags this clamp.

**Model draw order / beforeId (where the model sits in the layer stack)** — P2, `capability-interface`, evidence: packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:111 — addModel takes no beforeId, unlike MapLibreStyleLayers.addLayerJson (style_layers.dart:31) which does
```dart
void addModel(MapLibreModel model, {String? beforeId});
```
> Inconsistent with our own layers API, which already supports beforeId. Matters in practice: a model should usually sit above the basemap fills but below symbol labels, and today it lands wherever addLayer puts it. mbgl already takes the parameter (style.hpp:71) — the shim just does not pass it through.

**Model hit-testing / tap** — P2, `widget-callback`, evidence: packages/maplibre_flutter/lib/src/maplibre_map.dart:71 (onTap gives a LatLng only); queryRenderedFeatures (packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:78) queries ENGINE layers and cannot see a CustomDrawableLayer
```dart
MapLibreMap(onModelTap: (String modelId) { … })
// or: List<String> controller.queryRenderedModels(Offset point);
```
> Upstream has the same hole, so this is a genuine design decision rather than a port. Cheapest honest implementation is a Dart-side screen-space bounds test using the existing projector (projector.dart) plus the model's known bounding box — approximate, no depth, but adequate for 'tap the vehicle'. Do NOT promise pixel-accurate picking; say what it is.

**Model instancing — many copies of one mesh** — P2, `value-type`, evidence: Meshes and GPU textures ARE shared across instances (packages/maplibre_flutter_core/src/maplibre_flutter_core_model.hpp:58-69 MblMeshGpu, with the rationale at :60-63 — '24 instances x 10 images x 1024^2 RGBA is about a gigabyte'), but each instance is still its OWN CustomDrawableLayer with its own draw calls.
```dart
// keep the current model — one MapLibreModel per instance — but document the
// cost honestly: draw calls scale with (instances x parts), memory does not.
```
> The memory win is real and already banked. The draw-call ceiling is the real limit and mbgl offers no instancing hook, so the honest move is to DOCUMENT the ceiling on MapLibreModel (with the number the stress scenario measures) rather than imply models scale like engine-drawn points do.

**Model pitch / roll (only yaw is expressible)** — P2, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:48 (headingDegrees) — yaw only; the shim builds M = T * Rz * S with a single rotate_z (packages/maplibre_flutter_core/src/maplibre_flutter_core_model.cpp:146-150)
```dart
MapLibreModel(…, double headingDegrees = 0, double pitchDegrees = 0, double rollDegrees = 0)
```
> Needed for anything that banks or climbs — aircraft, drones, a vehicle on a slope. The engine already takes a full mat4, so this is two extra rotates in the shim plus two ABI parameters. **CLAUDE.md §11 trap applies directly**: map model space is LEFT-HANDED (X east, Y south, Z up), so rotate_z is already clockwise from above and negating it runs headings backwards — the existing code has this right (a bug already paid for once); adding pitch/roll must be verified with the asymmetric pyramid fixture (maplibre_flutter_core_model.hpp:87-95), not a round-trip.

**Pitch on the camera + tilt gesture (the 3D entry point that DOES work)** — P2, `controller-namespace`, evidence: packages/maplibre_flutter_platform_interface/lib/src/camera.dart:15 (MapCamera.pitch), :28 (doc); gesture at packages/maplibre_flutter/lib/src/maplibre_map.dart:37 (tiltGesturesEnabled); C ABI mbl_map_pitch_by at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:105
```dart
controller.camera.move(cam.copyWith(pitch: 60));  // already exists
MapLibreMap(tiltGesturesEnabled: true)             // already exists
```
> Included for completeness — pitch is the precondition for every other row in this domain being visible at all. Note the matrix's own warning at :303: our mbl_map_pitch_by is NOT mbgl's Map::pitchBy, which SUBTRACTS its argument. Worth keeping that comment alive (it is also in maplibre_flutter_core.h:100-105).

**Vertical field of view (camera FOV — the other half of the 3D look)** — P2, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/camera.dart:10 — MapCamera carries center/zoom/bearing/pitch only (:19-28); no fov field
```dart
// on MapCamera (gl-js name, Dart-cased):
final double? verticalFieldOfViewDegrees;
// on MapLibreCameraController:
Future<void> setVerticalFieldOfView(double degrees);
Future<double> getVerticalFieldOfView();
```
> Camera-domain overlap; flagged for dedupe. Included here because FOV is what makes a pitched 3D view read as dramatic or flat, and because mbgl works in RADIANS while gl-js and every user expectation are in DEGREES — convert at the shim boundary and say so, or this becomes another units bug. Requires widening mbl_map_set_camera/get_camera (maplibre_flutter_core.h:60/:65), hence an ffigen regen.

**`elevation` expression (reads DEM height inside a color-relief ramp)** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_expressions.g.dart:976 — `static Expression elevation([...])`
```dart
Expression.elevation()  // already exists
```
> The generator discovers expressions from spec['expression_name'].values, which contains 'elevation' — so it landed automatically. Concrete proof of CLAUDE.md §5d's 'coverage is discovered from the spec, never allowlisted' paying off, and equally concrete proof that the matrix is hand-maintained and drifting.

**color-relief-color (ColorRampPropertyValue) and color-relief-opacity** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:2357 (opacity), :2300 (colorReliefColor ctor arg)
```dart
ColorReliefLayer(…, colorReliefColor: <ramp expression>, colorReliefOpacity: Value(0.8))  // already exists
```
> The ramp is a `ColorRampPropertyValue` in mbgl, i.e. an interpolate expression over `elevation` — which is exactly why the `elevation` expression row below matters.

**controller.addModel / updateModel / removeModel — imperative per-frame path** — P2, `controller`, evidence: packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:215 (addModel), :226 (updateModel), :258 (removeModel); C ABI at packages/maplibre_flutter_core/src/maplibre_flutter_core.h:395, :411, :438; Dart wrapper at packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:249, :295
```dart
controller.addModel(model); controller.updateModel(model.copyWith(point: next)); controller.removeModel('car');  // already exists
```
> Correct split under the three-bucket rule: the declarative prop for structure, the imperative call for the 60 Hz path. Two API nits worth fixing while touching this: these are flat on MapLibreMapController while `camera` and `layers` are namespaced — a `controller.models` namespace would match the house style; and `MapLibreModel` has no `copyWith`, which the per-frame path needs (the example app hand-rolls placement mutation).

**fill-extrusion-color (shaded by the root `light`)** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:1756, transition :1760
```dart
FillExtrusionLayer(…, fillExtrusionColor: Value(const Color(0xFFBDBDBD)))  // already exists
```
> **The direct dependency on setLight.** Our own generated dartdoc for this field (style_layers.g.dart:1748-1752) says the surfaces 'will be shaded differently based on this color in combination with the root `light` settings' — and we expose no way to touch the root light. Also note the generated doc at :1755 emits a broken 'Requires .' fragment, a small generator bug (an empty requires-clause is not suppressed).

**fill-extrusion-height** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:1679 (ctor arg), transition :1680
```dart
FillExtrusionLayer(…, fillExtrusionHeight: Expression.get('render_height'))  // already exists
```
> Data-driven (a feature property), which is where `Expression extends StyleValue<Never>` earns its keep (CLAUDE.md §5d).

**hillshade-exaggeration** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:2183 (+ transition at :2187)
```dart
HillshadeLayer(…, hillshadeExaggeration: Value(0.5), hillshadeExaggerationTransition: StyleTransition(duration: …))  // already exists
```
> Not the same thing as terrain exaggeration — this darkens/lightens shading, it does not displace geometry. Worth saying in the dartdoc so nobody mistakes it for `terrain.exaggeration`.

**hillshade-illumination-direction (multidirectional: List<double>)** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:2166 — StyleValue<List<double>>?
```dart
HillshadeLayer(…, hillshadeIlluminationDirection: Value([335, 65]))  // already exists
```
> Both mbgl and our generated type are VECTOR-valued (multi-light), which only takes effect when hillshade-method is `multidirectional`. Apple/Android still expose it as a scalar Float — we are ahead, again because we generate from the spec.

**hillshade-method (standard | basic | combined | igor | multidirectional)** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_enums.g.dart:114 (HillshadeMethod); field at style_layers.g.dart (HillshadeLayer ctor arg `hillshadeMethod`, :2105)
```dart
HillshadeLayer(…, hillshadeMethod: Value(HillshadeMethod.multidirectional))  // already exists
```
> One of the clearest examples of the matrix being stale in a way that UNDERSELLS us — we ship this and the matrix says the engine cannot do it.

**raster-dem encoding enum (mapbox | terrarium | custom)** — P2, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_enums.g.dart:360 (RasterDemEncoding); field at style_sources.g.dart:274
```dart
RasterDemSource(url: …, encoding: RasterDemEncoding.terrarium)  // already exists
```
> Also note we are AHEAD of Apple here: the spec's `custom` encoding (with redFactor/greenFactor/blueFactor/baseShift) has no MLNDEMEncoding case, but our generated enum has all three because it comes from the spec. Good example of why generating beats hand-porting an SDK.

**Axonometric projection mode (native-only 3D skew — mbgl HAS this, gl-js does not)** — P3, `capability-interface`, evidence: packages/maplibre_flutter_platform_interface/lib/src/maplibre_map_controller.dart (would be a new optional capability, not a base-contract member)
```dart
abstract interface class MapLibreAxonometricView {
  void setAxonometric({required bool enabled, double xSkew = 0, double ySkew = 0});
  ({bool enabled, double xSkew, double ySkew}) getAxonometric();
}
// app-facing: controller.camera.setAxonometric(...)
```
> A rare case where mbgl is AHEAD of gl-js. Gives the isometric/'SimCity' look for 3D buildings without a perspective camera. p3 — genuinely niche, but it belongs in the backlog because it is free capability we are throwing away, and because 'mbgl has no projection support' is otherwise a half-truth. Feature-detected with `is`, per CLAUDE.md §3.

**Built-in test model (spinning four-colour pyramid)** — P3, `reject`, evidence: C ABI packages/maplibre_flutter_core/src/maplibre_flutter_core.h:451 (mbl_map_add_test_model) and the mesh at packages/maplibre_flutter_core/src/maplibre_flutter_core_model.hpp:95 (mblMakeTestPyramid); not exposed in the platform interface or the app-facing API
```dart
// keep internal. Optionally expose to package tests only, via
// package:maplibre_flutter_core/testing.dart.
```
> Correctly internal, and worth preserving verbatim: it is the domain's best regression asset. Deliberately asymmetric and per-face coloured so that top-down it must read as red north / green east / blue south / yellow west (maplibre_flutter_core_model.hpp:87-95) — which catches anchor mirroring, a flipped up-axis, inverted winding, and depth silently degraded to painter's order. That is exactly the asymmetric-fixture discipline CLAUDE.md §11 demands. Do not delete it when the model API is productionised.

**Camera roll (bank angle)** — P3, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/camera.dart:10 — no roll field
```dart
// on MapCamera:
final double roll; // degrees, counter-clockwise about the camera boresight
```
> Camera-domain overlap; flagged for dedupe. p3 because roll is genuinely rare in map UIs — but the matrix asserting the engine cannot do it is exactly the kind of drift that makes a backlog untrustworthy. gl-js signature deliberately left unverified rather than invented.

**Generic CustomDrawableLayer escape hatch (polylines / fills / symbols beyond models)** — P3, `capability-interface`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core_model.cpp uses only addGeometry; addPolyline / addFill / addSymbol are unused anywhere in packages/maplibre_flutter_core/src/
```dart
// not yet — but if a second custom-drawable use case appears, generalise
// MapLibreModelHost into MapLibreCustomDrawableHost rather than adding a
// parallel capability.
```
> Listed for completeness: our model host uses one of five available primitives. WideVector polylines (LineShaderType::WideVector, :36-39) in particular are a capability nothing in our API reaches. p3 — do not build it speculatively; CLAUDE.md §3 says do not build a platform feature before the interface can express it. Recorded so the next person knows the headroom exists.

**Model animation — glTF animation channels, skins, morph targets** — P3, `reject`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core_gltf.hpp:28-29 ('No skins/animations. mbgl's shader cannot skin. Animate with the model matrix instead.'); the Dart doc repeats it at packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:11-12
```dart
// DO NOT IMPLEMENT. Rigid-body only:
// MapLibreModel(headingDegrees:, spinDegreesPerSecond:, point:, elevationMetres:)
```
> HARD STOP at our pin. Escaping it means raw mbgl::style::CustomLayer + our own shaders per backend — and CustomLayerFactory is #ifdef MLN_RENDER_BACKEND_OPENGL-gated (platform/default/src/mbgl/layermanager/layer_manager.cpp:81-85), so it is unavailable on Metal and Vulkan, i.e. on four of our six tiers. docs/3d-models-research.md ranks that path 3rd for exactly this reason. Say 'rigid-body only' in the public docs and stop there.

**Model per-instance tint / colour** — P3, `value-type`, evidence: packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:14-22 — no colour field; the tint comes only from the glTF's own baseColorFactor (packages/maplibre_flutter_core/src/maplibre_flutter_core_gltf.hpp:70)
```dart
MapLibreModel(…, Color? tint)  // multiplies the material base colour
```
> Near-free: the tint uniform already exists and is already set per part. Unlocks the common case of one mesh reused as a fleet in different liveries without shipping N .glb files. Pairs naturally with the opacity row (same uniform's alpha).

**Model shadows** — P3, `reject`, evidence: packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:9-11 (bake lighting into the texture)
```dart
// DO NOT IMPLEMENT.
```
> Fill-extrusion buildings get no shadows either, so a shadowed model would look MORE wrong, not less. Documented fake if anyone insists: a translucent dark ellipse drawn as a flat model part at ground level.

**Terrain-draped markers / models (anchored content that follows ground height)** — P3, `reject`, evidence: packages/maplibre_flutter_platform_interface/lib/src/projector.dart; packages/maplibre_flutter_platform_interface/lib/src/model_host.dart:55 (elevationMetres is a flat offset, not ground-relative)
```dart
// DO NOT IMPLEMENT. Would be: MapLibreModel(elevationMode: ElevationMode.aboveGround)
```
> Worth documenting on MapLibreModel.elevationMetres: it is metres above the MERCATOR PLANE, not above ground. On a mountain the model floats or sinks. That doc line is free and prevents a bug report.

**Tile-LOD tuning (the perf lever that makes high pitch affordable)** — P3, `widget-init`, evidence: packages/maplibre_flutter_platform_interface/lib/src/map_options.dart:13 (init-only bucket) — nothing today
```dart
// MapOptions (init-only, per the three-bucket rule):
const MapOptions({..., this.tileLodPitchThresholdDegrees, this.tileLodScale, this.tileLodMinRadius, this.tileLodZoomShift})
```
> Belongs in the 3D domain because it exists specifically for pitched views — mbgl's own comment (map.hpp:170) says 'This can improve performance, particularly when the camera pitch is high.' Relevant to us twice over: the CPU-readback present tiers (Windows, Android) pay per frame, and the 3D-model research already flagged per-frame triggerRepaint cost as an open question on exactly those tiers. Note Apple exposes the threshold in RADIANS; convert at the boundary.

**atmosphere-blend** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/
```dart
// DO NOT IMPLEMENT. Reserved: StyleValue<double>? atmosphereBlend
```
> Spec doc says 'best to interpolate this when using globe projection' — doubly unreachable for us, since globe is also absent.

**fill-extrusion-base** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:1681, transition :1682
```dart
FillExtrusionLayer(…, fillExtrusionBase: Expression.get('render_min_height'))  // already exists
```

**fill-extrusion-opacity** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:1742, transition :1746
```dart
FillExtrusionLayer(…, fillExtrusionOpacity: Value(0.85))  // already exists
```
> Layer-wide only, no data-driven styling — the generated dartdoc already says so (:1737-1739).

**fill-extrusion-pattern** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:1677, transition :1678
```dart
FillExtrusionLayer(…, fillExtrusionPattern: Value('brick'))  // already exists
```
> Pairs with the existing addImage on MapLibreStyleLayers (style_layers.dart:47) — a Flutter-widget-derived texture on a 3D building is a genuinely nice demo and needs no new binding.

**fill-extrusion-translate / -translate-anchor** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:1674 (translate) and :1676 (translate-anchor); the enum at style_enums.g.dart:63 (FillExtrusionTranslateAnchor)
```dart
FillExtrusionLayer(…, fillExtrusionTranslate: Value([0, -2]), fillExtrusionTranslateAnchor: Value(FillExtrusionTranslateAnchor.viewport))  // already exists
```
> **Naming disagreement, resolved in favour of the spec.** Apple renamed; gl-js, Android, mbgl and the spec did not. We keep the spec name (which our generator produces automatically). Documented in naming_policy_notes.

**fill-extrusion-vertical-gradient** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:1683 (ctor arg fillExtrusionVerticalGradient)
```dart
FillExtrusionLayer(…, fillExtrusionVerticalGradient: Value(true))  // already exists
```
> Second instance of the Apple rename. Same resolution: keep the spec name.

**fog-color** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/
```dart
// DO NOT IMPLEMENT. Reserved: StyleValue<Color>? fogColor
```
> Spec: 'Requires 3D terrain.' So this is blocked twice over — it needs both the sky object AND terrain, neither of which mbgl has.

**fog-ground-blend** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/
```dart
// DO NOT IMPLEMENT. Reserved: StyleValue<double>? fogGroundBlend
```

**getSky** — P3, `reject`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
// DO NOT IMPLEMENT. Reserved: MapLibreSky? getSky()
```
> Would always return null.

**getTerrain** — P3, `reject`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart
```dart
// DO NOT IMPLEMENT. Reserved: MapLibreTerrain? getTerrain()
```
> **Matrix drift:** `getTerrain` FEATURE_MATRIX.md:594 — ➖/❌. Same Web-cell disagreement as the row above.

**hillshade-illumination-altitude** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:2173
```dart
HillshadeLayer(…, hillshadeIlluminationAltitude: Value([45]))  // already exists
```
> 0 = sunset, 90 = noon.

**hillshade-illumination-anchor (map | viewport)** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_enums.g.dart:97 (HillshadeIlluminationAnchor); field at style_layers.g.dart:2178
```dart
HillshadeLayer(…, hillshadeIlluminationAnchor: Value(HillshadeIlluminationAnchor.map))  // already exists
```
> Same map/viewport semantics as light.anchor — a good consistency check once StyleLight lands.

**hillshade-shadow-color / -highlight-color / -accent-color** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_layers.g.dart:2194 (shadow, StyleValue<List<Color>>), :2200 (highlight), and the accent field + transitions at :2103-2104
```dart
HillshadeLayer(…, hillshadeShadowColor: Value([Colors.black]), hillshadeHighlightColor: Value([Colors.white]), hillshadeAccentColor: Value([Colors.black]))  // already exists
```
> Vector-of-Color in mbgl and in our generated type (one colour per light source when method=multidirectional); scalar in the Apple/Android SDKs.

**horizon-color** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/
```dart
// DO NOT IMPLEMENT. Reserved: StyleValue<Color>? horizonColor
```

**horizon-fog-blend** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/
```dart
// DO NOT IMPLEMENT. Reserved: StyleValue<double>? horizonFogBlend
```

**queryTerrainElevation — elevation of a LngLat under the loaded DEM** — P3, `reject`, evidence: packages/maplibre_flutter_platform_interface/lib/src/projector.dart (the natural home — it is a projection query)
```dart
// DO NOT IMPLEMENT. Reserved: double? queryTerrainElevation(LatLng point)
```
> Note the asymmetry worth stating to users: the `elevation` EXPRESSION can read DEM height inside a color-relief layer (compound_expression.cpp:374) but there is no way to get that number back out to Dart. Binding it would mean adding DEM sampling to core, i.e. an upstream contribution, not a shim function.

**raster-dem custom encoding factors (redFactor / greenFactor / blueFactor / baseShift)** — P3, `value-type`, evidence: packages/maplibre_flutter/lib/src/style/generated/style_sources.g.dart:280, :286, :292, :298
```dart
RasterDemSource(url: …, encoding: RasterDemEncoding.custom, redFactor: 256, greenFactor: 1, blueFactor: 1/256, baseShift: -32768)  // already exists
```
> Unverified end-to-end. A cheap high-value test: a custom-encoded DEM whose factors are deliberately wrong should produce a visibly different hillshade than the right ones — an asymmetric fixture, per CLAUDE.md §11.

**setProjection / getProjection (mercator | globe | vertical-perspective)** — P3, `reject`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart (would live here)
```dart
// DO NOT IMPLEMENT. Reserved: void setProjection(MapLibreProjection p)
```
> HARD STOP — mbgl is Web-Mercator-only. **Naming hazard worth writing down**: Apple ships a class literally called `MLNMapProjection` that has nothing to do with this. Our own `MapLibreMapProjector` capability (projector.dart) is the same kind of thing — coordinate conversion. If we ever add projection selection, do not reuse either name.

**setSky — sky/atmosphere/fog root object** — P3, `reject`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart (would live here)
```dart
// DO NOT IMPLEMENT. Reserved: void setSky(MapLibreSky? sky) on controller.layers
```
> HARD STOP. The spec itself annotates the sky object 'still experimental and under development in maplibre-gl-js'. **Working substitute worth documenting**: a `background` layer with a zoom/pitch-interpolated colour gives a usable horizon wash on a pitched map. Not sky, but it is what users actually want most of the time.

**setTerrain — enable 3D terrain from a raster-dem source** — P3, `reject`, evidence: packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart (would live here, as a MapLibreStyleLayers member)
```dart
// DO NOT IMPLEMENT. Reserved name only:
// void setTerrain(MapLibreTerrain? terrain) — on controller.layers
```
> **Matrix drift:** `3D terrain (setTerrain)` FEATURE_MATRIX.md:593 — ➖ on all five native, ❌ on Web. **DISAGREE on the Web cell**: the matrix's own preamble (line 22) says the Web column means the WASM core, which is the same mbgl, so Web must be ➖ too. ❌ implies bindable; it is not.

**sky-color** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/ (would be generated from spec['sky'])
```dart
// DO NOT IMPLEMENT. Reserved field: StyleValue<Color>? skyColor
```
> Listed individually so the backlog matches the matrix row-for-row and nobody re-derives the sky property list later.

**sky-horizon-blend** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/
```dart
// DO NOT IMPLEMENT. Reserved: StyleValue<double>? skyHorizonBlend
```

**terrain.source + terrain.exaggeration (the TerrainSpecification value type)** — P3, `reject`, evidence: packages/maplibre_flutter/lib/src/style/generated/ (would be generated from spec['terrain'])
```dart
// DO NOT IMPLEMENT. Shape if it ever lands:
// final class MapLibreTerrain { const MapLibreTerrain({required String source, double exaggeration = 1}); }
```
> **Matrix drift:** `terrain source` :595 and `terrain exaggeration` :596 — ➖/❌. Same Web-cell disagreement.


### Offline, caching, location & snapshotter

#### Engine ceiling

Six genuine hard stops in this domain — things that are impossible on the native+wasm tiers no matter how much binding work we do — plus two that look like ceilings and are not.

**Real ceilings**

1. **Custom HTTP headers on tile/style requests.** `mbgl::ResourceTransform`'s callback signature is `void(Resource::Kind kind, const std::string& url, FinishedCallback)` (include/mbgl/storage/resource_transform.hpp:13) — it takes a URL and returns a URL. `mbgl::Resource` (include/mbgl/storage/resource.hpp:13–90) carries no header map, and `FileSource` (include/mbgl/storage/file_source.hpp:36) has no header surface; the only tunables are the four setProperty keys at file_source.hpp:105–119 (api key, base URL, max concurrent requests, read-only mode). Headers exist only *inside* each platform's `HTTPFileSource`, which is why the Apple SDK can offer `MLNNetworkConfiguration.sessionConfiguration` (MLNNetworkConfiguration.h:69) and gl-js can return `{headers}` from `transformRequest`, and we cannot. Escape hatches: per-arm plumbing (our Android arm already owns its HTTPFileSource at src/maplibre_flutter_core_android_http.cpp:98, so Android is cheap; Apple/Linux/Windows/web each need their own), or an upstream PR widening ResourceTransform — the same category of contribution as the text-centring patch we already carry. Until then, signed query parameters via transformRequest are the supported workaround.

2. **Location: position, permissions, heading.** There is no location, permission or sensor API anywhere under `include/mbgl` — no `mbgl/location`, nothing on `Map`. mbgl only *draws*, via `style::LocationIndicatorLayer` (include/mbgl/style/layers/location_indicator_layer.hpp:18). The Apple SDK fills the gap with `MLNLocationManager` (MLNLocationManager.h:19) and Android with `LocationComponent`/`LocationEngine`, both of which are SDK-layer, not engine. For us this is a hard stop by construction and, as argued in the rows, also the right place to stop.

3. **Maximum ambient cache AGE.** `DatabaseFileSource` (include/mbgl/storage/database_file_source.hpp:65–125) offers exactly four ambient-cache operations — `put`, `invalidateAmbientCache`, `clearAmbientCache`, `setMaximumAmbientCacheSize`. There is no age/TTL knob, and neither the Apple nor the Android SDK has one either. **FEATURE_MATRIX.md:671 lists "Set maximum ambient cache age" as ❌ on all five native tiers**, i.e. as bindable backlog. It is not; it is a Mapbox-SDK-only concept that never existed in MapLibre. That row should be ➖ or deleted.

4. **Byte-accurate offline download progress.** `OfflineRegionStatus` (include/mbgl/storage/offline.hpp:114–166) states outright at lines 110–112 that "the total required size in bytes is not currently available." You get `completedResourceSize`/`completedTileSize` for what has landed, and only *counts* for what is required — and even `requiredResourceCount` is a lower bound until `requiredResourceCountIsPrecise` flips (offline.hpp:154–163). Apple papers over this with `maximumResourcesExpected = UINT64_MAX` (MLNOfflinePack.h:96). Any "247 MB of 512 MB" UI is therefore a lie on every MapLibre binding; design the progress UI around resource counts.

5. **Snapshotter logo / attribution chrome.** `mbgl::MapSnapshotter::Callback` returns a `PremultipliedImage` plus an `Attributions` string vector (platform/default/include/mbgl/map/map_snapshotter.hpp:76–77) and draws no chrome at all. `MLNMapSnapshotOptions.showsLogo`/`.showsAttribution` (MLNMapSnapshotter.h:90,95) and Android's `withLogo` are SDK-side compositing. **FEATURE_MATRIX.md:687 marks this ❌ on all five native tiers** — it will never become ✅ by binding; it becomes ✅ by drawing attribution in Flutter. That row should be ➖ with a note, and we must expose the attribution strings or every snapshot ships out of compliance.

6. **`location-indicator` is not in the style spec.** The layer is real and registered (platform/default/src/mbgl/layermanager/layer_manager.cpp:88; type string at src/mbgl/style/layers/location_indicator_layer.cpp:24) but it is absent from `scripts/style-spec-reference/v8.json`, which is the sole input to `tool/generate_style_api.dart`. So the generated typed style API structurally cannot cover it, today or ever, and the puck needs a hand-written typed layer sitting beside the generated ones. Do **not** solve this by injecting a fake spec entry — the generator's value is that coverage is discovered from the spec and a spec change surfaces in CI (CLAUDE.md §5d).

**Two things that look like ceilings and are not — both currently mis-marked ➖ in the matrix**

- **The location puck on desktop.** FEATURE_MATRIX.md:675–683 marks the location component ➖ (engine cannot) on macOS, Windows and Linux. mbgl has `LocationIndicatorLayer` with a raw-GL render path (`#if MLN_RENDER_BACKEND_OPENGL`, src/mbgl/renderer/layers/render_location_indicator_layer.cpp:33) **and** a drawable path for the non-GL backends (`MLN_DRAWABLE_LOCATION_INDICATOR`, defined at render_location_indicator_layer.hpp:8–10), with Metal and Vulkan shaders shipped (include/mbgl/shaders/mtl/location_indicator.hpp, include/mbgl/shaders/vulkan/location_indicator.hpp). Every backend we ship can draw it. Ten cells to correct.

- **Offline on web.** Every offline row (FEATURE_MATRIX.md:655–674) marks Web ➖. Our WASM build compiles `database_file_source.cpp`, `offline_database.cpp` and `sqlite3.cpp` (packages/maplibre_flutter_core/web/CMakeLists.txt:53,61,65) against the same engine. The gap is Emscripten filesystem glue (IDBFS + FS.syncfs), not capability. Roughly twenty cells to correct.

**Not a ceiling but a build gap worth stating plainly:** `mbgl::MapSnapshotter` lives at platform/default/include/mbgl/map/map_snapshotter.hpp, i.e. in the default platform rather than in core, and our CMake attaches `map_snapshotter.cpp` **only on the Apple arm** (packages/maplibre_flutter_core/src/CMakeLists.txt:160). Android, Linux, Windows and web do not compile it. So "snapshotter on Linux" is one line of CMake plus a binding, and any estimate that treats all five native tiers as identical here will be wrong.

#### Naming decisions

**Policy applied.** The house rule is "gl-js naming for style/data ops, Apple/Android shapes where gl-js has no peer." This domain is almost entirely the second case — maplibre-gl-js has no offline manager, no ambient cache, no snapshotter and no location component — so the shapes below come from the Apple SDK and the Android SDK, cross-checked against the mbgl headers we actually bind. The three places gl-js DOES have a peer, and what I picked:

1. **`transformRequest`** — gl-js `MapOptions.transformRequest: RequestTransformFunction` + `map.setTransformRequest()` (both verified in the 5.x docs) vs Apple `-[MLNOfflineStorageDelegate offlineStorage:URLForResourceOfKind:withURL:]` (MLNOfflineStorage.h:544) vs mbgl `ResourceTransform` (storage/resource_transform.hpp:13). **gl-js name wins** (`transformRequest`), because it is the lingua franca and the callback shape is identical. The resource-kind enum is taken from Apple/mbgl, which agree member-for-member (`MLNResourceKind` MLNOfflineStorage.h:159 == `mbgl::Resource::Kind` storage/resource.hpp:15: unknown/style/source/tile/glyphs/spriteImage/spriteJSON/image), so there is no conflict to resolve.
2. **Snapshot of the *live* map** — Android `MapLibreMap.snapshot(SnapshotReadyCallback)` vs gl-js `map.getCanvas().toDataURL()` (needs `canvasContextAttributes.preserveDrawingBuffer`). **Android name wins** (`controller.snapshot()`); gl-js's is a DOM idiom, not an API.
3. **Geolocation** — gl-js's only offering is `GeolocateControl`, a DOM control with `{positionOptions, trackUserLocation, showUserLocation, showUserHeading, showAccuracyCircle, fitBoundsOptions}` and a `trigger()` method. **Rejected as a shape**: it is a control widget, and we have no control system. Apple's `userTrackingMode` wins.

**Where Apple and Android/mbgl disagree, and my calls:**

- **The offline handle.** Apple splits it into `MLNOfflinePack` (the download handle, MLNOfflinePack.h:122) + `id<MLNOfflineRegion>` (the definition, MLNOfflineRegion.h:9). Android and mbgl instead call the *handle* `OfflineRegion` and the *definition* `OfflineRegionDefinition` (mbgl: storage/offline.hpp:216 and :74). → **Take mbgl/Android**: `MapLibreOfflineRegion` (handle) + `sealed MapLibreOfflineRegionDefinition` (value). Two of three agree, and it is the engine's own vocabulary — a shim that says "pack" over an `mbgl::OfflineRegion` invites exactly the confusion we do not need.
- **The opaque blob.** Apple `MLNOfflinePack.context` (NSData, MLNOfflinePack.h:152); Android `metadata` (ByteArray); mbgl `OfflineRegionMetadata` (offline.hpp:90). → **`metadata`**. Two of three, and `context` collides head-on with Flutter's `BuildContext`.
- **The manager.** Apple `MLNOfflineStorage.sharedOfflineStorage` (MLNOfflineStorage.h:203); Android `OfflineManager.getInstance(context)`; mbgl `DatabaseFileSource`. → **`MapLibreOfflineManager.instance`**. "Storage" reads as the ambient cache (which is a *sibling* concern in the same class on Apple, and that is precisely what makes `MLNOfflineStorage` confusing); `DatabaseFileSource` is an implementation name. Ecosystem weight also sits with `OfflineManager` — the incumbent Flutter plugins (`maplibre_gl`/`mapbox_gl`) expose `OfflineRegion`/`OfflineRegionDefinition`/`downloadOfflineRegion`, so migrators recognise it.
- **Tracking modes.** Apple `MLNUserTrackingMode` is 4 values (MLNMapView.h:82: none/follow/followWithHeading/followWithCourse). Android splits into `CameraMode` (7 values) × `RenderMode` (3). → **Apple's 4-value enum**, as `MapLibreUserTrackingMode`. Android's cross-product is 21 nominal states, most unreachable, and the four Apple values cover every case apps actually ship.
- **Mapbox branding in the tile limit.** Apple `-setMaximumAllowedMapboxTiles:` (MLNOfflineStorage.h:384), Android `setOfflineMapboxTileCountLimit(limit)`, mbgl `setOfflineMapboxTileCountLimit` (database_file_source.hpp:248). All three still carry "Mapbox". → **Deliberate deviation**: `setTileCountLimit(int)`. It is a MapLibre plugin; the Mapbox-hosted-tiles constraint is meaningless here and only survives upstream for database compatibility. Documented as a rename, not a new concept.
- **The puck.** Apple owns the GPS (`MLNMapView.showsUserLocation` :590, `locationManager` :568, `MLNUserLocation` :20); Android owns it too (`LocationComponent.activateLocationComponent(...)`). mbgl owns only the *drawing*, via the `location-indicator` style layer (style/layers/location_indicator_layer.hpp:18). → **Deliberate divergence from both SDKs**: we bind the drawing and NOT the provider. `MapLibreMap.locationPuck` is a declarative widget prop the app feeds from `geolocator` (or anything). Rationale: shipping a location provider means owning iOS background modes, `NSLocationWhenInUseUsageDescription`, Android runtime permissions and a foreground service — a permanent maintenance surface that duplicates a mature pub package, on a plugin whose pitch is quality. Say so in the README so the omission reads as a decision, not a gap.

**Flutter-idiom adaptations (each is a deviation I am choosing, not an oversight):**

- **Completion handlers → `Future`.** Every `withCompletionHandler:` / `FileSourceCallback` becomes an `async` method that completes or throws `MapLibreOfflineException`.
- **`NSNotification` + KVO / `OfflineRegion.setObserver` → `Stream`.** Apple posts `MLNOfflinePackProgressChangedNotification` (MLNOfflineStorage.h:34), `…ErrorNotification` (:47) and `…MaximumMapboxTilesReachedNotification` (:61); Android registers an `OfflineRegionObserver`; mbgl uses `OfflineRegionObserver` (offline.hpp:172). All three become one broadcast `Stream<MapLibreOfflineRegionStatus> get statusChanges` plus `Stream<MapLibreOfflineError> get errors` on the region handle. Three notification names collapse into two streams because `mapboxTileCountLimitExceeded` is just an error kind.
- **`UIImage`/`Bitmap` → `Uint8List` (PNG) with a lazy `Future<ui.Image>`.** `mbgl::MapSnapshotter::Callback` hands back a `PremultipliedImage` (map_snapshotter.hpp:77); Flutter has no cross-platform bitmap type, and the plugin already encodes PNG through mbgl (`mbl_map_write_png`).
- **Global singletons drop `BuildContext`.** `OfflineManager.getInstance(context)` needs a Context only to find the app data dir. `MapLibreOfflineManager.instance` takes nothing; the default cache path is resolved **natively**, in each platform package's existing plugin class, rather than by adding `path_provider` to the critical path of every map. (Recommendation, flagged: a new pub dependency on the first-frame path is worse than five short native calls we are already positioned to make.)
- **`LatLng` order trap, live in this domain.** The `location-indicator` layer's `location` paint property is `std::array<double,3>` and mbgl reads it as `LatLng{pos[0], pos[1]}` (src/mbgl/renderer/layers/render_location_indicator_layer.cpp:970) — i.e. **[lat, lng, altitudeMetres]**, the *opposite* of the GeoJSON `[lng, lat]` used by every other layer document we serialise. Whatever serialises `MapLibreLocationPuck` must not go through the generic GeoJSON coordinate helper. This is exactly the class of bug CLAUDE.md §11 warns about; it needs an asymmetric fixture test (puck at 60°N 25°E, assert it is not drawn at 25°N 60°E).

#### Bindings

| P | Feature | Ours | gl-js | Apple SDK | mbgl | Bucket | C ABI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | Persistent tile/resource cache (cache database path) | none | — | MLNOfflineStorage.databasePath (MLNOfflineStorage.h:226) / .databaseURL (:234); overridden by the MLNOfflineStorageDatabasePath Info.plist key | mbgl::ResourceOptions::withCachePath(std::string) (include/mbgl/storage/resource_options.hpp:64); default is ":memory:" (src/mbgl/storage/resource_options.cpp:11) | widget-init | yes |
| P1 | API key / access token | none | — (gl-js has no global token; keys go in the style/tile URL or via transformRequest) | MLNSettings.apiKey (class property, MLNSettings.h:53); also readable from the MLNApiKey Info.plist key | mbgl::ResourceOptions::withApiKey(std::string) (include/mbgl/storage/resource_options.hpp:34); also settable at runtime via FileSource::setProperty(API_KEY_KEY, …) — API_KEY_KEY = "api-tkey" (include/mbgl/storage/file_source.hpp:105) | widget-init | yes |
| P1 | Asset path (root for the asset:// scheme in a style) | none | — | — (the Apple SDK resolves bundle-relative style URLs itself in MLNMapView/MLNStyle) | mbgl::ResourceOptions::withAssetPath(std::string) (include/mbgl/storage/resource_options.hpp:80); consumed by platform/default/src/mbgl/storage/asset_file_source.cpp, which is compiled on every arm (src/CMakeLists.txt:162,293,408,536; web/CMakeLists.txt:52) | widget-init | yes |
| P1 | Clear ambient cache | none | — | -[MLNOfflineStorage clearAmbientCacheWithCompletionHandler:] (MLNOfflineStorage.h:444) | mbgl::DatabaseFileSource::clearAmbientCache(std::function<void(std::exception_ptr)>) (include/mbgl/storage/database_file_source.hpp:103) | capability-interface | yes |
| P1 | Create an offline region (start a download) | none | — | -[MLNOfflineStorage addPackForRegion:withContext:completionHandler:] (MLNOfflineStorage.h:310) | mbgl::DatabaseFileSource::createOfflineRegion(const OfflineRegionDefinition&, const OfflineRegionMetadata&, callback) (include/mbgl/storage/database_file_source.hpp:162) | capability-interface | yes |
| P1 | Delete an offline region | none | — | -[MLNOfflineStorage removePack:withCompletionHandler:] (MLNOfflineStorage.h:339) | mbgl::DatabaseFileSource::deleteOfflineRegion(const OfflineRegion&, std::function<void(std::exception_ptr)>) (include/mbgl/storage/database_file_source.hpp:234) | value-type | yes |
| P1 | Force offline / network status toggle | none | — | — (the Apple SDK derives reachability itself) | mbgl::NetworkStatus::Set(NetworkStatus::Status::Offline\|Online) and ::Get() (include/mbgl/storage/network_status.hpp:20–21); also ::Reachable() (:23) to kick retries | widget-init | yes |
| P1 | List offline regions | none | — | MLNOfflineStorage.packs (MLNOfflineStorage.h:287, nil until loaded, KVO-observable) + -reloadPacks (:371) | mbgl::DatabaseFileSource::listOfflineRegions(std::function<void(expected<OfflineRegions, std::exception_ptr>)>) (include/mbgl/storage/database_file_source.hpp:137) | capability-interface | yes |
| P1 | Local tile archives — mbtiles:// and pmtiles:// sources | present | — (gl-js needs the third-party pmtiles protocol plugin via maplibregl.addProtocol) | — (same core file sources, undocumented at SDK level) | FileSourceType::Mbtiles / FileSourceType::Pmtiles (include/mbgl/storage/file_source.hpp:27–28); implementations in platform/default/src/mbgl/storage/{mbtiles,pmtiles}_file_source.cpp | controller-namespace | no |
| P1 | Location provider (permissions, GPS stream, compass) | none | navigator.geolocation via GeolocateControl({positionOptions}) | MLNMapView.locationManager (MLNMapView.h:568) + the MLNLocationManager protocol (MLNLocationManager.h:19): requestWhenInUseAuthorization (:133), requestAlwaysAuthorization (:127), startUpdatingLocation (:140), startUpdatingHeading (:157), authorizationStatus (:122), desiredAccuracy (:52), distanceFilter (:34); delegate callbacks at MLNLocationManagerDelegate (:178) | NOT IN CORE. There is no location, permission or sensor API anywhere under include/mbgl — mbgl draws a puck and knows nothing about where the device is. | reject | no |
| P1 | Location puck (engine-drawn user-location indicator) | none | — (GeolocateControl draws a DOM marker; no engine layer) | MLNMapView.showsUserLocation (MLNMapView.h:590), .userLocation (:623) → MLNUserLocation (MLNUserLocation.h:20), .userLocationVisible (:618) | mbgl::style::LocationIndicatorLayer (include/mbgl/style/layers/location_indicator_layer.hpp:18); type string "location-indicator" (src/mbgl/style/layers/location_indicator_layer.cpp:24) | widget-prop | no |
| P1 | Maximum cache database size | none | maplibregl.Map options `maxTileCacheSize: number \| null` (RAM tile cache, not a disk DB — not the same thing) | -[MLNOfflineStorage setMaximumAmbientCacheSize:withCompletionHandler:] (MLNOfflineStorage.h:417) | mbgl::ResourceOptions::withMaximumCacheSize(uint64_t) (include/mbgl/storage/resource_options.hpp:95); default mbgl::util::DEFAULT_MAX_CACHE_SIZE = 50 MiB (include/mbgl/util/constants.hpp:53) | widget-init | yes |
| P1 | Offline manager entry point | none | — (no offline concept in gl-js at all) | MLNOfflineStorage.sharedOfflineStorage (MLNOfflineStorage.h:203) | mbgl::FileSourceManager::get()->getFileSource(FileSourceType::Database, resourceOptions, clientOptions) → mbgl::DatabaseFileSource (include/mbgl/storage/file_source_manager.hpp:33; include/mbgl/storage/database_file_source.hpp:13) | capability-interface | yes |
| P1 | Offline region definition — tile pyramid (bounds + zoom range) | none | — | MLNTilePyramidOfflineRegion (MLNTilePyramidOfflineRegion.h:32), -initWithStyleURL:bounds:fromZoomLevel:toZoomLevel: (:83); properties bounds (:38), minimumZoomLevel (:45), maximumZoomLevel (:52) | mbgl::OfflineTilePyramidRegionDefinition(std::string, LatLngBounds, double, double, float, bool) (include/mbgl/storage/offline.hpp:29–40) | value-type | yes |
| P1 | Puck position, bearing, accuracy radius | none | — | MLNUserLocation.location → CLLocation (MLNUserLocation.h:29), .heading → CLHeading (:44), .updating (:35) | LocationIndicatorLayer::setLocation(PropertyValue<std::array<double,3>>) (include/mbgl/style/layers/location_indicator_layer.hpp:77), setBearing(PropertyValue<Rotation>) (:59), setAccuracyRadius(PropertyValue<float>) (:41) | value-type | yes |
| P1 | Region download state (resume / suspend) | none | — | -[MLNOfflinePack resume] (MLNOfflinePack.h:206) / -suspend (:220) | mbgl::DatabaseFileSource::setOfflineRegionDownloadState(const OfflineRegion&, OfflineRegionDownloadState) (include/mbgl/storage/database_file_source.hpp:180); enum OfflineRegionDownloadState { Inactive, Active } (offline.hpp:101) | value-type | yes |
| P1 | Region metadata (read and update the opaque blob) | none | — | MLNOfflinePack.context (MLNOfflinePack.h:152) + -setContext:completionHandler: (:166) | mbgl::OfflineRegion::getMetadata() (include/mbgl/storage/offline.hpp:223); mbgl::DatabaseFileSource::updateOfflineMetadata(int64_t, const OfflineRegionMetadata&, callback) (database_file_source.hpp:168); OfflineRegionMetadata = std::vector<uint8_t> (offline.hpp:90) | value-type | yes |
| P1 | Region status / download progress snapshot | none | — | MLNOfflinePack.progress (MLNOfflinePack.h:194) returning struct MLNOfflinePackProgress (:60–97); -requestProgress (:232) to force a refresh | mbgl::DatabaseFileSource::getOfflineRegionStatus(const OfflineRegion&, callback) (include/mbgl/storage/database_file_source.hpp:188); class OfflineRegionStatus (offline.hpp:114–166) with complete() at :165 | value-type | yes |
| P1 | Region status change stream (progress observer) | none | — | MLNOfflinePackProgressChangedNotification (MLNOfflineStorage.h:34) with userInfo keys MLNOfflinePackUserInfoKeyState (:75) / …KeyProgress (:84); or KVO on the pack's `progress` key path | mbgl::OfflineRegionObserver::statusChanged(OfflineRegionStatus) (include/mbgl/storage/offline.hpp:185), installed via DatabaseFileSource::setOfflineRegionObserver (database_file_source.hpp:175) | value-type | yes |
| P1 | Resource URL transform (transformRequest) | none | MapOptions.transformRequest: RequestTransformFunction \| null (default null); map.setTransformRequest(fn) | -[MLNOfflineStorageDelegate offlineStorage:URLForResourceOfKind:withURL:] (MLNOfflineStorage.h:544), set via MLNOfflineStorage.delegate (:215); MLNResourceKind enum at :159 | mbgl::ResourceTransform (include/mbgl/storage/resource_transform.hpp:10) installed via FileSource::setResourceTransform (OnlineFileSource overrides it, include/mbgl/storage/online_file_source.hpp:28) | widget-init | yes |
| P1 | Set maximum ambient cache size at runtime | none | — | -[MLNOfflineStorage setMaximumAmbientCacheSize:withCompletionHandler:] (MLNOfflineStorage.h:417) | mbgl::DatabaseFileSource::setMaximumAmbientCacheSize(uint64_t, std::function<void(std::exception_ptr)>) (include/mbgl/storage/database_file_source.hpp:125) | capability-interface | yes |
| P1 | Snapshot the LIVE map (screenshot the widget's map) | internal-only | map.getCanvas().toDataURL() (requires canvasContextAttributes.preserveDrawingBuffer: true) | — (MLNMapView has no snapshot method; you use MLNMapSnapshotter or UIGraphics on the view) | already covered — our shim encodes with mbgl's PNG encoder; the raw path is mbl_map_copy_frame (maplibre_flutter_core.h:287) | controller | no |
| P2 | Cancel an in-flight snapshot | none | — | -[MLNMapSnapshotter cancel] (MLNMapSnapshotter.h:328); .loading (:338) reports whether one is in flight | mbgl::MapSnapshotter::cancel() (platform/default/include/mbgl/map/map_snapshotter.hpp:79) | capability-interface | yes |
| P2 | Change the cache/offline database path at runtime | none | — | MLNOfflineStorage.databasePath is READ-ONLY (MLNOfflineStorage.h:226); Apple only lets you set it via Info.plist | mbgl::DatabaseFileSource::setDatabasePath(const std::string&, std::function<void()> callback) (include/mbgl/storage/database_file_source.hpp:32) | capability-interface | yes |
| P2 | Custom HTTP headers on tile/style requests (auth headers) | none | MapOptions.transformRequest returns { url, headers, credentials } — gl-js CAN set headers | MLNNetworkConfiguration.sessionConfiguration (MLNNetworkConfiguration.h:69) + -willSendRequest: on MLNNetworkConfigurationDelegate (:29) — Apple CAN set headers | NOT IN CORE. mbgl::ResourceTransform rewrites only the URL string (include/mbgl/storage/resource_transform.hpp:13: TransformCallback(Resource::Kind, const std::string& url, FinishedCallback)); mbgl::Resource (include/mbgl/storage/resource.hpp:13) carries no header map. | reject | no |
| P2 | In-memory (RAM) tile cache control and memory pressure release | none | MapOptions.maxTileCacheSize: number \| null (default null = dynamic); maxTileCacheZoomLevels: number (default 5) | MLNMapView.tileCacheEnabled (MLNMapView.h:489) | mbgl::Renderer::setTileCacheEnabled(bool) / getTileCacheEnabled() (include/mbgl/renderer/renderer.hpp:111–112), ::reduceMemoryUse() (:113), ::clearData() (:114) | controller | yes |
| P2 | Invalidate ambient cache (force revalidation) | none | — | -[MLNOfflineStorage invalidateAmbientCacheWithCompletionHandler:] (MLNOfflineStorage.h:433) | mbgl::DatabaseFileSource::invalidateAmbientCache(std::function<void(std::exception_ptr)>) (include/mbgl/storage/database_file_source.hpp:90) | capability-interface | yes |
| P2 | Invalidate an offline region (revalidate its tiles) | none | — | -[MLNOfflineStorage invalidatePack:withCompletionHandler:] (MLNOfflineStorage.h:356) | mbgl::DatabaseFileSource::invalidateOfflineRegion(const OfflineRegion&, std::function<void(std::exception_ptr)>) (include/mbgl/storage/database_file_source.hpp:242) | value-type | yes |
| P2 | Logging level and log observer | none | — | MLNLoggingConfiguration.sharedConfiguration (MLNLoggingConfiguration.h:94), .loggingLevel (:89) with MLNLoggingLevel { None, Fault, Error, Warning, Info, Debug } (:17), .handler (:80) taking MLNLoggingBlockHandler (:62) | mbgl::Log::setObserver(std::unique_ptr<Observer>) / removeObserver() (include/mbgl/util/logging.hpp:28–29); Observer::onRecord(EventSeverity, Event, int64_t code, const std::string&) (:21), returning true to consume; Log::useLogThread(bool, optional<EventSeverity>) (:45) | widget-init | yes |
| P2 | Maximum concurrent HTTP requests | internal-only | maplibregl.setMaxParallelImageRequests(n) / getMaxParallelImageRequests() | — (NSURLSession manages this; reachable indirectly via MLNNetworkConfiguration.sessionConfiguration, MLNNetworkConfiguration.h:69) | FileSource::setProperty(MAX_CONCURRENT_REQUESTS_KEY, unsigned) — MAX_CONCURRENT_REQUESTS_KEY = "max-concurrent-requests" (include/mbgl/storage/file_source.hpp:113) | widget-init | yes |
| P2 | Merge a secondary offline database (ship prebuilt packs) | none | — | -[MLNOfflineStorage addContentsOfFile:withCompletionHandler:] (MLNOfflineStorage.h:251) and -addContentsOfURL:withCompletionHandler: (:269), both returning MLNBatchedOfflinePackAdditionCompletionHandler (:144) | mbgl::DatabaseFileSource::mergeOfflineRegions(const std::string& sideDatabasePath, callback) (include/mbgl/storage/database_file_source.hpp:211) | capability-interface | yes |
| P2 | Offline region definition — shape / geometry (GeoJSON) | none | — | MLNShapeOfflineRegion (MLNShapeOfflineRegion.h:31), -initWithStyleURL:shape:fromZoomLevel:toZoomLevel: (:82); property shape (:37) | mbgl::OfflineGeometryRegionDefinition(styleURL, Geometry<double>, minZoom, maxZoom, pixelRatio, includeIdeographs) (include/mbgl/storage/offline.hpp:53–69) | value-type | yes |
| P2 | Prefetch zoom delta (load a coarse tile first) | none | — | MLNMapView.prefetchesTiles (BOOL) — MLNMapView.h:478 | mbgl::Map::setPrefetchZoomDelta(uint8_t) / getPrefetchZoomDelta() (include/mbgl/map/map.hpp:143–144); default delta is 4 | controller | yes |
| P2 | Preload / put a resource into the ambient cache | none | — | -[MLNOfflineStorage preloadData:forURL:modificationDate:expirationDate:eTag:mustRevalidate:completionHandler:] (MLNOfflineStorage.h:519); the older -putResourceWithUrl:… (:488) is deprecated | mbgl::DatabaseFileSource::put(const Resource&, const Response&) (include/mbgl/storage/database_file_source.hpp:76) | capability-interface | yes |
| P2 | Puck imagery (top / bearing / shadow images and their sizes) | none | — | MLNUserLocationAnnotationViewStyle (MLNUserLocationAnnotationViewStyle.h:11): puckFillColor (:16), puckShadowColor (:20), puckShadowOpacity (:26), puckArrowFillColor (:30), haloFillColor (:34), approximateHaloFillColor (:38); or a fully custom MLNUserLocationAnnotationView (MLNUserLocationAnnotationView.h:14) | setTopImage / setBearingImage / setShadowImage (include/mbgl/style/layers/location_indicator_layer.hpp:35,27,31) and their *Size counterparts (:95,:65,:89); setAccuracyRadiusColor (:53), setAccuracyRadiusBorderColor (:47), setPerspectiveCompensation (:83), setImageTiltDisplacement (:71) | value-type | no |
| P2 | Region error stream (download errors, tile-limit exceeded) | none | — | MLNOfflinePackErrorNotification (MLNOfflineStorage.h:47, userInfo key …KeyError :92) and MLNOfflinePackMaximumMapboxTilesReachedNotification (:61, key …KeyMaximumCount :102) | mbgl::OfflineRegionObserver::responseError(Response::Error) (include/mbgl/storage/offline.hpp:198) and ::mapboxTileCountLimitExceeded(uint64_t) (:213) | value-type | yes |
| P2 | Reset (delete and reinitialise) the database | none | — | -[MLNOfflineStorage resetDatabaseWithCompletionHandler:] (MLNOfflineStorage.h:454) | mbgl::DatabaseFileSource::resetDatabase(std::function<void(std::exception_ptr)>) (include/mbgl/storage/database_file_source.hpp:41) | capability-interface | yes |
| P2 | Retrieve one offline region by id | none | — | — (filter MLNOfflineStorage.packs on MLNOfflinePack.regionId, MLNOfflinePack.h:134) | mbgl::DatabaseFileSource::getOfflineRegion(int64_t regionID, callback) (include/mbgl/storage/database_file_source.hpp:147) | capability-interface | yes |
| P2 | Snapshot attributions | none | — (AttributionControl handles it in the DOM) *(unverified)* | — (folded into MLNMapSnapshotOptions.showsAttribution, MLNMapSnapshotter.h:95, which draws it for you) | mbgl::MapSnapshotter::Attributions = std::vector<std::string>, delivered in the Callback (platform/default/include/mbgl/map/map_snapshotter.hpp:76–77) | value-type | yes |
| P2 | Snapshot coordinate projection (point ⇄ LatLng on the static image) | none | — | -[MLNMapSnapshot pointForCoordinate:] (MLNMapSnapshotter.h:156) / -coordinateForPoint: (:161) | the Callback hands back PointForFn and LatLngForFn closures (platform/default/include/mbgl/map/map_snapshotter.hpp:74–75, :77) | value-type | yes |
| P2 | Snapshot result image | none | map.getCanvas().toDataURL() with canvasContextAttributes.preserveDrawingBuffer: true | MLNMapSnapshot.image → UIImage (MLNMapSnapshotter.h:166) / NSImage on macOS (:182) | mbgl::MapSnapshotter::Callback delivers a PremultipliedImage (platform/default/include/mbgl/map/map_snapshotter.hpp:77) | value-type | yes |
| P2 | Snapshotter options (size, pixel ratio, style, camera, region, padding) | none | — | MLNMapSnapshotOptions (MLNMapSnapshotter.h:70): -initWithStyleURL:camera:size: (:81), .styleURL (:100), .zoomLevel (:109), .camera (:118), .coordinateBounds (:126), .size (:134), .scale (:141) | setSize/getSize (map_snapshotter.hpp:56–57), setCameraOptions (:59), setRegion (:62), setPadding (:65), setStyleURL (:50), setStyleJSON (:53); ctor takes Size, pixelRatio, ResourceOptions, ClientOptions, observer, localFontFamily (:39–44) | value-type | yes |
| P2 | Standalone map snapshotter (render a static image with no widget) | none | — (no snapshotter; the closest is rendering a hidden Map and reading map.getCanvas().toDataURL()) | MLNMapSnapshotter (MLNMapSnapshotter.h:245), -initWithOptions: (:256), -startWithCompletionHandler: (:293), -startWithQueue:completionHandler: (:304), -cancel (:328), .loading (:338) | mbgl::MapSnapshotter (platform/default/include/mbgl/map/map_snapshotter.hpp:37); snapshot(Callback) at :78, cancel() at :79 | capability-interface | yes |
| P2 | Tile server options / well-known tile server preset | none | — | MLNSettings.tileServerOptions (MLNSettings.h:38) + `+[MLNSettings useWellKnownTileServer:]` (:58) with MLNWellKnownTileServer { MLNMapTiler, MLNMapLibre, MLNMapbox } (:11); MLNTileServerOptions has 20 fields (MLNTileServerOptions.h:12–112) | mbgl::TileServerOptions (include/mbgl/util/tile_server_options.hpp:15) with withBaseURL/withUriSchemeAlias/withSourceTemplate/withStyleTemplate/withSpritesTemplate/withGlyphsTemplate/withTileTemplate/withApiKeyParameterName; wired via ResourceOptions::withTileServerOptions (resource_options.hpp:49) | widget-init | yes |
| P2 | Total bytes stored on disk | none | — | MLNOfflineStorage.countOfBytesCompleted (MLNOfflineStorage.h:392) | No single getter. Sum OfflineRegionStatus::completedResourceSize (include/mbgl/storage/offline.hpp:128) across regions, or stat the DB file — Apple's property is SDK-side bookkeeping over the same data. | capability-interface | yes |
| P2 | Tracking-mode-changed callback | none | GeolocateControl 'trackuserlocationstart' / 'trackuserlocationend' / 'userlocationfocus' / 'userlocationlostfocus' events | -[MLNMapViewDelegate mapView:didChangeUserTrackingMode:animated:] (MLNMapViewDelegate.h:590) | NOT IN CORE — emitted by our own Dart tracking implementation. | widget-callback | no |
| P2 | User tracking / camera follow modes | none | GeolocateControl({trackUserLocation: true, showUserHeading: true}) — a DOM control, not a map API | MLNMapView.userTrackingMode (MLNMapView.h:637) with MLNUserTrackingMode { None, Follow, FollowWithHeading, FollowWithCourse } (:82); -setUserTrackingMode:animated:completionHandler: (:668); the :652 two-arg form is deprecated | NOT IN CORE as a mode — but fully implementable in Dart over the existing camera API (MapLibreCameraController.move, packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:308), exactly like the Dart fly arc and the Dart gesture tier already are. | widget-prop | no |
| P2 | Web/WASM offline persistence (IDBFS) | partial | — (gl-js relies on the browser HTTP cache and has no offline manager) | n/a | No ceiling — sqlite compiles to WASM and mbgl is unaware of the FS backend. The gap is purely Emscripten glue: FS.mkdir + FS.mount(IDBFS) + FS.syncfs, none of which exists in packages/maplibre_flutter_core/src/web/. | widget-init | yes |
| P2 | includeIdeographs flag on a region | none | — | MLNOfflineRegion.includesIdeographicGlyphs (MLNOfflineRegion.h:32) | the trailing bool of both definition constructors (include/mbgl/storage/offline.hpp:31, :60) | value-type | yes |
| P3 | Action journal (rolling on-disk event log) | none | — | MLNMapOptions.actionJournalOptions (MLNMapOptions.h:33) → MLNActionJournalOptions (MLNActionJournalOptions.h:11): enabled (:16), path (:21), logFileSize (:26), logFileCount (:31), renderingStatsReportInterval (:36) | mbgl::util::ActionJournalOptions (include/mbgl/util/action_journal_options.hpp:12) — enable (:23), withPath (:41), withLogFileSize (:60), withLogFileCount (:79), withRenderingStatsReportInterval (:96); passed to the Map ctor (include/mbgl/map/map.hpp:46) and read back via Map::getActionJournal (:210) | widget-init | yes |
| P3 | Automatic packing after delete/clear | none | — | — | mbgl::DatabaseFileSource::runPackDatabaseAutomatically(bool) (include/mbgl/storage/database_file_source.hpp:63); enabled by default | capability-interface | yes |
| P3 | Client name / version (User-Agent identification) | none | — | — (the Apple SDK sets its own User-Agent internally) | mbgl::ClientOptions::withName / withVersion (include/mbgl/util/client_options.hpp:31,46) | widget-init | yes |
| P3 | Offline tile count limit | none | — | -[MLNOfflineStorage setMaximumAllowedMapboxTiles:] (MLNOfflineStorage.h:384) | mbgl::DatabaseFileSource::setOfflineMapboxTileCountLimit(uint64_t) const (include/mbgl/storage/database_file_source.hpp:248) | capability-interface | yes |
| P3 | Pack (VACUUM) the database | none | — | — (not exposed on MLNOfflineStorage) | mbgl::DatabaseFileSource::packDatabase(std::function<void(std::exception_ptr)>) (include/mbgl/storage/database_file_source.hpp:53) | capability-interface | yes |
| P3 | Platform context (Android AssetManager) for asset:// inside the APK | none | — | — (bundle resources resolve through the filesystem on Apple) | mbgl::ResourceOptions::withPlatformContext(void*) / platformContext() (include/mbgl/storage/resource_options.hpp:111,118) | reject | yes |
| P3 | Platform network configuration (URLSession / OkHttp) | none | — (fetch options are not exposed; transformRequest carries credentials only) | MLNNetworkConfiguration.sharedManager (MLNNetworkConfiguration.h:51), .sessionConfiguration (:69), .delegate (:46) with -sessionForNetworkConfiguration: (:27), -willSendRequest: (:29), -didReceiveResponse: (:31) | NOT IN CORE. FileSource has no timeout, proxy or TLS surface; everything network-shaped in mbgl's public API is ResourceOptions (api key, base URL) plus the setProperty keys at include/mbgl/storage/file_source.hpp:105–119. | reject | no |
| P3 | Puck tap / long-press callback | none | — | — (the user-location annotation participates in normal annotation selection) | NOT IN CORE. queryRenderedFeatures does not return location-indicator hits (it is not a feature-backed layer), so hit-testing must be done in Dart against the known puck position. | widget-callback | no |
| P3 | Read-only database mode | none | — | — | FileSource::setProperty(READ_ONLY_MODE_KEY, true) — READ_ONLY_MODE_KEY = "read-only-mode" (include/mbgl/storage/file_source.hpp:119) | widget-init | yes |
| P3 | Rendering statistics | partial | — | MLNRenderingStats (MLNRenderingStats.h:7) with 30+ readonly counters: encodingTime (:10), renderingTime (:12), numFrames (:15), numDrawCalls (:18), numCreatedTextures (:23), memTextures (:67), stencilClears (:78) … | mbgl::gfx::RenderingStats (include/mbgl/gfx/rendering_stats.hpp); also Map::isRenderingStatsViewEnabled / enableRenderingStatsView (include/mbgl/map/map.hpp:150–151) | controller | yes |
| P3 | Snapshotter annotations and style images | none | — | -[MLNMapSnapshotter addAnnotation:] (MLNMapSnapshotter.h:270), -addAnnotations: (:285), -startWithOverlayHandler:completionHandler: (:319) with MLNMapSnapshotOverlay (:23) exposing a CGContextRef; MLNMapSnapshotter conforms to MLNStylable and exposes .style (:366) | mbgl::MapSnapshotter::addAnnotationImage(std::unique_ptr<style::Image>) and ::addAnnotation(const Annotation&) (platform/default/include/mbgl/map/map_snapshotter.hpp:68–69); ::getStyle() (:71) | reject | yes |
| P3 | Snapshotter local ideograph font family | none | MapOptions.localIdeographFontFamily: string \| false (default 'sans-serif') | — (not on MLNMapSnapshotOptions) | the trailing std::optional<std::string> localFontFamily on the MapSnapshotter ctor (platform/default/include/mbgl/map/map_snapshotter.hpp:44) | value-type | yes |
| P3 | Snapshotter logo / attribution chrome | none | — | MLNMapSnapshotOptions.showsLogo (MLNMapSnapshotter.h:90) and .showsAttribution (:95) | NOT IN CORE. mbgl returns a PremultipliedImage plus an Attributions string vector (map_snapshotter.hpp:76–77) and draws no chrome whatsoever. | reject | no |
| P3 | Snapshotter observer (style loaded / style failed / image missing) | none | — | MLNMapSnapshotterDelegate (MLNMapSnapshotter.h:374): -mapSnapshotterDidFail:withError: (:388), -mapSnapshotter:didFinishLoadingStyle: (:401), -mapSnapshotter:didFailLoadingImageNamed: (:403) | mbgl::MapSnapshotterObserver (platform/default/include/mbgl/map/map_snapshotter.hpp:27): onDidFailLoadingStyle (:32), onDidFinishLoadingStyle (:33), onStyleImageMissing (:34) | capability-interface | yes |
| P3 | Zoom / tilt / padding while tracking | none | GeolocateControl({fitBoundsOptions}) | — (Apple adjusts the camera directly while tracking) | NOT IN CORE — Dart-side, over the existing camera. | controller-namespace | no |

#### Proposed signatures

**Persistent tile/resource cache (cache database path)** — P0, `widget-init`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:642 (Static arm) and :921 (Continuous arm) — both construct mbgl::Map with mbgl::ResourceOptions::Default(); src/web/maplibre_flutter_core_web.cpp:178,186 likewise. mbl_map_create takes no cache path (src/maplibre_flutter_core.h:52). Would live in src/maplibre_flutter_core.h + a new MapLibreSettings in packages/maplibre_flutter/lib/src/
```dart
static Future<void> MapLibreSettings.configure({String? cachePath, String? assetPath, String? apiKey, String? baseUrl, int maximumCacheSize = 50 * 1024 * 1024, MapLibreClientInfo? client})
```
> CONFIRMED — this is a real defect, not a gap. Every native tier and web-WASM run with cachePath ":memory:", so the offline database is a RAM sqlite that evaporates on process exit. Consequences: every app launch re-downloads the whole style, sprite, glyph set and every tile; panning back over ground you just covered re-fetches (the RAM DB is at least shared across maps in the process, since FileSourceManager keys file sources by (type, baseURL|apiKey|cachePath|ctx) — see the comment at maplibre_flutter_core.cpp:612); community tile servers see the traffic (which is why maplibre_flutter_core.cpp:625 already has to throttle concurrency to keep demotiles/OpenFreeMap from returning ENHANCE_YOUR_CALM); and there is no offline resilience whatsoever. Fix shape: add a global `mbl_configure_resources(cache_path, asset_path, api_key, base_url, maximum_cache_size, err, err_len)` that stores a ResourceOptions, have both renderThreadMain arms use it instead of ResourceOptions::Default(), and default cachePath to the platform app-support directory resolved in each platform package's native plugin class. Because FileSourceManager caches by ResourceOptions identity, this MUST be set before the first mbl_map_create — hence widget-init/process-init, not a controller call. Web caveat: sqlite3.cpp and offline_database.cpp ARE compiled for WASM (web/CMakeLists.txt:61,65) but Emscripten's default MEMFS is RAM-only per page load, so web needs an IDBFS mount + FS.syncfs before a path means anything.

**API key / access token** — P1, `widget-init`, evidence: Never set. Users must inline `?key=…` into the style URL passed to MapLibreMap.style. Would live in the same MapLibreSettings.configure as the cache path.
```dart
MapLibreSettings.configure(apiKey: 'xxx')
```
> Survivable today (put the key in the URL), which is why this is p1 and not p0 — but it is table stakes: MapTiler, Stadia and Mapbox styles all want one, and the key participates in the FileSourceManager cache identity, so setting it late silently creates a *second* OnlineFileSource. Set it in the same one-shot configure() as the cache path. Note the upstream typo: the property key literal is "api-tkey", not "api-key" — copy it verbatim.

**Asset path (root for the asset:// scheme in a style)** — P1, `widget-init`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:642 — ResourceOptions::Default() leaves assetPath as "." (src/mbgl/storage/resource_options.cpp:12), i.e. the process CWD
```dart
MapLibreSettings.configure(assetPath: '/path/to/flutter_assets')
```
> The AssetFileSource is compiled in on all six tiers, so `asset://sprite.png` in a style *would* work — it just resolves against the process working directory, which is meaningless on iOS/Android and fragile on desktop. Bundling a style with its sprite/glyph assets is a normal thing to want and is silently broken today. On Android there is a second half: mbgl's default AssetFileSource reads the filesystem, not the APK; the upstream Android SDK instead hands an AssetManager through ResourceOptions::withPlatformContext (resource_options.hpp:111). Our Android arm supplies a custom HTTPFileSource (src/maplibre_flutter_core_android_http.cpp) but no asset bridge, so on Android the honest fix is to point assetPath at the extracted flutter_assets directory rather than plumb the AssetManager.

**Clear ambient cache** — P1, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
Future<void> MapLibreOfflineManager.clearAmbientCache()
```
> Every app with a 'clear cache' settings row needs this. Unanimous naming across all three engines, so no decision to make. Documented not to touch resources shared with offline packs — mirror that in the dartdoc, since users assume it wipes everything. Pairs with a `cacheSizeOnDisk` getter so the settings row can show a number.

**Create an offline region (start a download)** — P1, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
Future<MapLibreOfflineRegion> MapLibreOfflineManager.createRegion(MapLibreOfflineRegionDefinition definition, {Uint8List? metadata})
```
> The naming fork resolved in the policy notes lands here: Apple says addPack…withContext, Android/mbgl say createOfflineRegion…metadata. Taking Android/mbgl. Behaviour to mirror in the dartdoc, because all three engines share it and it surprises everyone: **the region is created Inactive and downloads nothing until you resume it.** Make that impossible to miss — either name it `createRegion` and document loudly, or offer a `download()` convenience that creates + resumes + returns the status stream, which is what an app actually wants.

**Delete an offline region** — P1, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_region.dart
```dart
Future<void> MapLibreOfflineRegion.delete()
```
> Naming disagreement: Apple puts `removePack:` on the manager; Android puts `delete()` on the region; mbgl puts `deleteOfflineRegion` on the file source and documents that it **takes ownership** — the handle is dead afterwards (offline.hpp / database_file_source.hpp:222–224). Take Android's shape (method on the region) because it matches mbgl's ownership semantics: the object consumes itself. Apple raises an exception on any subsequent message to a removed pack; Dart should throw StateError. Also mirror the note that deletion only frees resources not required by *other* regions.

**Force offline / network status toggle** — P1, `widget-init`, evidence: No binding. Would live alongside MapLibreSettings in packages/maplibre_flutter/lib/src/
```dart
static set MapLibreSettings.connected(bool value); static bool get MapLibreSettings.connected;
```
> Directly paired with the cache work and useless without it — but once a disk cache exists, 'render only from what I already have' is the single most-requested offline behaviour and it is three lines of C. Android names it `setConnected`, and that is the only SDK with a name, so take it. Also expose `NetworkStatus::Reachable()` as `MapLibreSettings.notifyReachable()` so an app using connectivity_plus can prod mbgl to retry immediately instead of waiting out its backoff.

**List offline regions** — P1, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
Future<List<MapLibreOfflineRegion>> MapLibreOfflineManager.listRegions()
```
> Apple models it as an observable *property* that is nil until loaded, plus an explicit reloadPacks; Android and mbgl model it as an async *call*. Take the async call — a Future is the Dart-idiomatic answer to 'nil until loaded', and it removes Apple's whole KVO ceremony. Apple's `reloadPacks` then has no counterpart and is dropped (calling listRegions again is the same thing); state that. Region handles are non-copyable in mbgl (OfflineRegion's ctor is private, offline.hpp:228), so the C ABI must hand back opaque pointers with explicit release, not values.

**Local tile archives — mbtiles:// and pmtiles:// sources** — P1, `controller-namespace`, evidence: Compiled on every arm: packages/maplibre_flutter_core/src/CMakeLists.txt:163,299,415,543 (mbtiles_file_source.cpp) and :174,305,421,549 (pmtiles_file_source.cpp); web/CMakeLists.txt:58,64. Reachable today through MapLibreStyleLayers.addSourceJson (packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:27).
```dart
No new API — document it. `controller.layers.addSourceJson('local', '{"type":"vector","url":"mbtiles:///abs/path/tiles.mbtiles"}')`
```
> **Best news in this domain: this already works and nobody knows.** A pre-built .mbtiles or .pmtiles shipped in the app bundle (or downloaded by the app's own code) gives complete offline maps with zero new API and zero offline-download machinery — for many apps this is a better answer than offline packs, because the archive is a single file the backend can version. gl-js needs a plugin for PMTiles; mbgl has it in-core on all six tiers. Action: prove it with an example-app scenario + a native test, then document it prominently. It is p1 as *documentation and a test*, not as binding work. Caveat: the path resolution goes through LocalFileSource, so it interacts with the assetPath row above.

**Location provider (permissions, GPS stream, compass)** — P1, `reject`, evidence: n/a — deliberately out of scope. The widget prop MapLibreMap.locationPuck (see that row) is the seam.
```dart
REJECT. Document the geolocator/location recipe in the example app and README instead: `Geolocator.getPositionStream().listen((p) => setState(() => _puck = MapLibreLocationPuck(position: LatLng(p.latitude, p.longitude), bearing: p.heading, accuracyRadiusMeters: p.accuracy)))`
```
> **Matrix drift:** "Force location update / location engine" (FEATURE_MATRIX.md:680) and "Compass / bearing engine" (:681), both ❌ Android / ➖ elsewhere. Treating these as ❌ (a binding backlog item) is the disagreement: they should be ➖ everywhere with a note saying we deliberately do not ship a provider.

**Location puck (engine-drawn user-location indicator)** — P1, `widget-prop`, evidence: No binding, but the engine path is fully compiled: mbgl registers LocationIndicatorLayerFactory in the default layer manager (third_party/maplibre-native/platform/default/src/mbgl/layermanager/layer_manager.cpp:88) and we compile layer_manager.cpp on every arm (packages/maplibre_flutter_core/src/CMakeLists.txt:159,291,406,534; web/CMakeLists.txt:82). New files: packages/maplibre_flutter_platform_interface/lib/src/location_puck.dart + a widget prop in packages/maplibre_flutter/lib/src/maplibre_map.dart
```dart
MapLibreMap(locationPuck: MapLibreLocationPuck?)
final class MapLibreLocationPuck { const MapLibreLocationPuck({required LatLng position, double? bearing, double accuracyRadiusMeters = 0, double elevationMeters = 0, MapLibreLocationPuckStyle style = const MapLibreLocationPuckStyle()}); }
```
> **A puck is buildable TODAY with zero new C ABI**: `controller.layers.addLayerJson('{"id":"puck","type":"location-indicator", "paint":{...}}')` already goes through LayerManager::createLayer (src/mbgl/style/conversion/layer.cpp:66), which knows this type. Two caveats that turn it from a demo into a feature: (1) `location-indicator` is NOT in scripts/style-spec-reference/v8.json, so the generated typed style API will never emit it — this needs a hand-written (non-generated) typed layer, and the generator must not be taught to fake a spec entry; (2) moving the puck per GPS fix needs `setPaintProperty`, which we do not have (FEATURE_MATRIX.md:232, ❌ everywhere) — re-adding the layer per fix works but churns GPU resources at 1 Hz. So this row's real dependency is the runtime-property C ABI from the layers domain, or a dedicated `mbl_map_set_location_puck(lat, lng, bearing, accuracy_m, elevation_m)` shortcut. **Coordinate trap**: mbgl reads the `location` property as `LatLng{pos[0], pos[1]}` (src/mbgl/renderer/layers/render_location_indicator_layer.cpp:970), i.e. [lat, lng, altitude] — the opposite of the GeoJSON order used by every other document we serialise. Test it with an asymmetric fixture.

**Maximum cache database size** — P1, `widget-init`, evidence: Never set; mbgl's default applies. packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:642
```dart
MapLibreSettings.configure(maximumCacheSize: 50 * 1024 * 1024)
```
> Two distinct entry points with the same units: ResourceOptions::withMaximumCacheSize at construction, and DatabaseFileSource::setMaximumAmbientCacheSize at runtime (see the separate row). Set the init one; expose the runtime one for apps that want to trim. Apple documents 'call before the map and style have loaded', which matches mbgl's own warning that the call is expensive because it trims.

**Offline manager entry point** — P1, `capability-interface`, evidence: Nothing offline exists anywhere in Dart — verified by grepping packages/*/lib for offline|ambient|cachePath|apiKey|NetworkStatus: zero hits. New file: packages/maplibre_flutter/lib/src/offline/offline_manager.dart + packages/maplibre_flutter_platform_interface/lib/src/offline_store.dart
```dart
abstract interface class MapLibreOfflineStore { … } // platform interface, feature-detected with `is`
class MapLibreOfflineManager { static MapLibreOfflineManager get instance; static bool get isSupported; }
```
> **Matrix drift:** "OfflineManager (offline storage manager)" — FEATURE_MATRIX.md:655, ❌ on all five native, ➖ web. **Disagrees on web**: the matrix says ➖ (engine cannot), but web/CMakeLists.txt:61,65 compiles offline_database.cpp and sqlite3.cpp into the WASM build, so the engine CAN — what is missing is Emscripten persistence (IDBFS + FS.syncfs). That cell should be ❌ with a note, not ➖.

**Offline region definition — tile pyramid (bounds + zoom range)** — P1, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_region.dart
```dart
final class MapLibreTilePyramidRegionDefinition extends MapLibreOfflineRegionDefinition { const MapLibreTilePyramidRegionDefinition({required String styleUrl, required LatLngBounds bounds, required double minZoom, required double maxZoom, double pixelRatio = 1.0, bool includeIdeographs = false}); }
```
> All three engines agree on the concept and near-agree on the name (Apple prefixes MLN, Android prefixes Offline). Two things the Dart type must carry that the Apple initializer hides: `pixelRatio` (mbgl requires it; the pack is only valid for maps at that ratio, which is a real gotcha on mixed-DPI fleets) and `includeIdeographs`. **Blocker: we have no LatLngBounds type at all** — packages/maplibre_flutter_platform_interface/lib/src/lat_lng.dart is 20 lines and holds only LatLng. `LatLngBounds` is needed by this row, by fitBounds and by getBounds in the camera domain, so it should land as a shared value type first.

**Puck position, bearing, accuracy radius** — P1, `value-type`, evidence: No binding. packages/maplibre_flutter_platform_interface/lib/src/location_puck.dart
```dart
Fields of MapLibreLocationPuck: LatLng position; double? bearing; double accuracyRadiusMeters; double elevationMeters;
```
> mbgl gives all three as transitionable paint properties, which is better than either SDK: setting a transition duration makes the puck glide between GPS fixes for free instead of teleporting, using the same StyleTransition machinery our generated layers already have. `accuracyRadius` is in metres and drives the translucent halo. `location`'s third component is altitude in metres — our 3D-model work already learned that mbgl mixes world-pixel XY with metre Z (CLAUDE.md §11), and this is the same convention. Because these change at 1 Hz, they are the strongest argument for the setPaintProperty C ABI.

**Region download state (resume / suspend)** — P1, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_region.dart
```dart
Future<void> MapLibreOfflineRegion.resume(); Future<void> MapLibreOfflineRegion.suspend(); MapLibreOfflineDownloadState get downloadState; // { inactive, active }
```
> Naming disagreement worth calling: Apple's verb pair `resume`/`suspend` vs Android's untyped `setDownloadState(Int)` vs mbgl's typed enum setter. **Take Apple's verbs** and back them with mbgl's enum — `resume()`/`suspend()` read far better than `setDownloadState(MapLibreOfflineDownloadState.active)`, and Android's raw Int is exactly the kind of thing Dart should not copy. Expose the enum as a read-only getter for symmetry.

**Region metadata (read and update the opaque blob)** — P1, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_region.dart
```dart
Uint8List get MapLibreOfflineRegion.metadata; Future<void> MapLibreOfflineRegion.setMetadata(Uint8List metadata);
```
> This is how an app names its regions — mbgl deliberately stores an opaque BLOB and, per the header comment at offline.hpp:83–89, tells bindings NOT to impose a format so the DB stays portable. **Resist the temptation to type it.** Ship `Uint8List` as the contract and offer a documented `utf8.encode(jsonEncode(...))` convenience in the example app, not in the API. Name: `metadata` (Android + mbgl beat Apple's `context`, which also collides with BuildContext).

**Region status / download progress snapshot** — P1, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_region.dart
```dart
Future<MapLibreOfflineRegionStatus> MapLibreOfflineRegion.getStatus();
final class MapLibreOfflineRegionStatus { final MapLibreOfflineDownloadState downloadState; final int completedResourceCount, completedResourceSize, completedTileCount, completedTileSize, requiredResourceCount, requiredTileCount; final bool requiredResourceCountIsPrecise; bool get isComplete; }
```
> Field-for-field the same on all three engines, so copy mbgl's names verbatim. **The one thing to document honestly**: mbgl states outright (offline.hpp:110–112) that the required total *size in bytes* is unavailable — only counts are. So a byte-accurate progress bar is impossible; the only correct progress fraction is completedResourceCount / requiredResourceCount, and `requiredResourceCountIsPrecise` is false early in a download (offline.hpp:154–163), so even that jumps. Apple's struct adds `maximumResourcesExpected` = UINT64_MAX until known, which is the same caveat wearing a different hat. Build the example's progress UI around this reality or it will look broken.

**Region status change stream (progress observer)** — P1, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_region.dart
```dart
Stream<MapLibreOfflineRegionStatus> get MapLibreOfflineRegion.statusChanges
```
> **Adapted to Flutter idiom**: three engines, three different push mechanisms (NSNotification+KVO / a Java observer object / a C++ virtual), all collapsing to one broadcast Stream. Say so in the dartdoc so nobody looks for `setObserver`. Threading is the trap — mbgl documents that statusChanged fires on the **database thread** and that it is the binding's job to re-execute on the main thread (offline.hpp:181–183). The C ABI must therefore post to a Dart SendPort, and the Dart side must keep a field reference to the registered NativeCallable or the GC will collect it and progress will silently stop (CLAUDE.md §5e — this is exactly the pitfall that deserves the test).

**Resource URL transform (transformRequest)** — P1, `widget-init`, evidence: No binding. Would live as a capability on the platform interface, e.g. packages/maplibre_flutter_platform_interface/lib/src/resource_transform.dart
```dart
typedef MapLibreRequestTransform = String Function(String url, MapLibreResourceKind kind);
MapLibreSettings.configure(transformRequest: MapLibreRequestTransform?)
```
> Table stakes: signed-URL CDNs, per-tenant tile hosts, and rewriting a style's absolute URLs to a local mirror all need it. The three engines agree on the *shape* (kind + url in, url out) and only disagree on the name — take gl-js's `transformRequest` per policy. Threading is the interesting part: mbgl's TransformCallback is invoked on the OnlineFileSource's worker thread and hands back a FinishedCallback, so the C ABI must marshal to a Dart isolate and back **without holding a lock across the callback** (CLAUDE.md §11: never hold a lock across an mbgl FileSource::Callback). Simplest safe design: register a Dart NativeCallable.isolateLocal on a helper isolate and block the mbgl worker on a future — never the UI isolate. Note that mbgl's transform is a URL-only rewrite; see the headers row for what it cannot do.

**Set maximum ambient cache size at runtime** — P1, `capability-interface`, evidence: No binding. Would live in a new packages/maplibre_flutter/lib/src/offline/offline_manager.dart backed by a new capability interface.
```dart
Future<void> MapLibreOfflineManager.setMaximumAmbientCacheSize(int bytes)
```
> All three engines agree on name and units (bytes). Apple documents that setting it to 0 disables ambient caching entirely while leaving offline packs alone — worth mirroring in the dartdoc, because it is the supported way to run 'packs only, no opportunistic caching'. The call is expensive (it trims), so it belongs on the offline manager and not on a hot path.

**Snapshot the LIVE map (screenshot the widget's map)** — P1, `controller`, evidence: C ABI exists: mbl_map_write_png (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:465). Dart wrapper exists: MapLibreCoreMap.writePng (packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart:855) and a fake at lib/testing.dart:399. Used ONLY by the core package's own tests (test/maplibre_flutter_core_test.dart:71,113,479,517,707). Reachable from no platform controller and no public API — packages/maplibre_flutter/lib/src/maplibre_map_controller.dart has nothing.
```dart
Future<Uint8List?> controller.snapshot({MapLibreImageFormat format = MapLibreImageFormat.png}); Future<bool> controller.snapshotToFile(String path);
```
> **The cheapest win in this entire domain, and the maintainer already spotted it.** The C ABI, the Dart wrapper and the tests all exist; the only missing pieces are a capability interface on the platform controller, five one-line forwards in the five native controllers, and a controller method. No ffigen regen. Design points: (1) prefer returning bytes over writing a path — a Flutter app wants Uint8List for share_plus or a widget, and a file path forces a temp-dir dance; keep writePng as the debug/harness path it already is; (2) Android's `snapshot()` is the only SDK precedent for the name, so take it; (3) it returns null before the first frame, matching mbl_map_write_png returning 0 with no frame; (4) worth a raw-RGBA variant, since mbl_map_copy_frame already exposes width/height/stride and PNG encoding is the expensive part; (5) it must NOT be a widget prop — it is a command, so bucket 3. Add a matrix row for it while you are there.

**Cancel an in-flight snapshot** — P2, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/snapshotter.dart
```dart
void MapLibreSnapshotter.cancel()
```
> Unanimous naming; trivial once the snapshotter exists. Matters because snapshots are commonly kicked off from a scrolling list, where most of them must be abandoned. Dart shape: `start()` returns a Future that completes with an error (a dedicated MapLibreSnapshotCancelled) when cancel() runs, rather than never completing — never-completing futures are how a list view leaks.

**Change the cache/offline database path at runtime** — P2, `capability-interface`, evidence: No binding. Would live in packages/maplibre_flutter_core/src/maplibre_flutter_core.h alongside a new offline C ABI block.
```dart
Future<void> MapLibreOfflineManager.setDatabasePath(String path)
```
> mbgl exposes this as a runtime call; Apple deliberately does not. Bind mbgl's version, because relocating a downloaded pack DB (e.g. from internal storage to an SD card) is a real Android use case and the API is trivially available. Caveat: changing it after maps exist leaves the already-resolved FileSource pointing at the old DB — document that it must be called before the first map, exactly like cachePath.

**Custom HTTP headers on tile/style requests (auth headers)** — P2, `reject`, evidence: No binding anywhere; the C ABI has no header surface (packages/maplibre_flutter_core/src/maplibre_flutter_core.h)
```dart
REJECT at the core layer. Nearest supportable: MapLibreSettings.configure(transformRequest: (url, kind) => …) which can only rewrite the URL (e.g. append a signed query token).
```
> **Hard mbgl ceiling, and the most likely surprise for an enterprise adopter.** Both native SDKs and gl-js can attach headers; mbgl's cross-platform layer cannot, because headers only exist inside each platform's HTTPFileSource. Options if this is ever needed: (a) per-arm plumbing — we already own the Android one outright (src/maplibre_flutter_core_android_http.cpp:98 HTTPFileSource::request), so Android is cheap; Apple would need our own NSURLSession source; curl and Emscripten sources would each need work; or (b) an upstream PR adding a header map to ResourceTransform, which is the right long-term move and is the same shape as the text-centring patch we already carry. Document the limitation rather than half-shipping it.

**In-memory (RAM) tile cache control and memory pressure release** — P2, `controller`, evidence: No binding. Would be a controller method in packages/maplibre_flutter/lib/src/maplibre_map_controller.dart backed by the render thread's Renderer
```dart
controller.setTileCacheEnabled(bool enabled); Future<void> controller.reduceMemoryUse(); Future<void> controller.clearRenderData();
```
> Distinct from the disk cache — this is the retained-tile RAM cache inside the renderer. Two reasons it belongs in the backlog: (1) Flutter apps get `didReceiveMemoryWarning` / `onTrimMemory` and have nothing to forward it to, so a backgrounded map holds full tile RAM; (2) `clearData()` is the correct thing to call when a style is swapped for an unrelated one. Our render thread owns the HeadlessFrontend, so reaching the Renderer means posting to that thread — same pattern as queryRenderedFeatures. gl-js exposes it as a size, the natives as a bool; take the natives' bool because that is what mbgl offers.

**Invalidate ambient cache (force revalidation)** — P2, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
Future<void> MapLibreOfflineManager.invalidateAmbientCache()
```
> The polite alternative to clearing: forces an if-none-match round trip per resource instead of a re-download, so unchanged tiles cost a 304. Apple's docs explicitly recommend it over clearAmbientCache. Unanimous naming.

**Invalidate an offline region (revalidate its tiles)** — P2, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_region.dart
```dart
Future<void> MapLibreOfflineRegion.invalidate()
```
> The efficient 'refresh my offline map' path: revalidates against the server so unchanged tiles cost a 304 instead of a re-download. Unanimous naming across all three engines. Pair it in the docs with the ambient-cache invalidate row so the two are not confused — this one only touches the region's tiles.

**Logging level and log observer** — P2, `widget-init`, evidence: No binding; mbgl logs go to the platform log with no Dart control. Would live in MapLibreSettings (packages/maplibre_flutter/lib/src/).
```dart
static set MapLibreSettings.logLevel(MapLibreLogLevel level); static set MapLibreSettings.onLog(void Function(MapLibreLogLevel level, String message)?);
```
> Diagnostics rather than a map feature, but it earns p2 because **this is how a user reports a bug to us**. Today a failing style load, a 403 from a tile server or a missing glyph range is written somewhere the Flutter developer never sees; routing mbgl's log into `debugPrint` or the app's own logger turns unreproducible reports into actionable ones. mbgl's Observer returns bool to consume the message, which maps cleanly to a nullable Dart handler. Two gotchas: onRecord fires on arbitrary mbgl threads (marshal to an isolate), and Log::useLogThread means Error-level records are synchronous while others are async — so during a crash the async ones are lost, which is worth knowing before trusting the tail of a log.

**Maximum concurrent HTTP requests** — P2, `widget-init`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:608–633 (capDesktopRequestConcurrency) — hardcoded to 6, overridable only by the MAPLIBRE_MAX_CONCURRENT_REQUESTS env var, and skipped entirely on Apple (#if !defined(__APPLE__))
```dart
MapLibreSettings.configure(maxConcurrentRequests: 6)
```
> We already exercise this native path — it is the only knob in this domain that is wired at all, and it is wired as an env var, which no shipped Flutter app can set. Promoting it to a real configure() field is nearly free. Note the existing asymmetry: Apple is deliberately excluded because it uses the NSURLSession HTTP source; that comment (maplibre_flutter_core.cpp:620) should stay true after the change. Also note mbgl reuses this same key for offline downloads (platform/default/src/mbgl/storage/offline_download.cpp:409), so raising it speeds pack downloads too.

**Merge a secondary offline database (ship prebuilt packs)** — P2, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
Future<List<MapLibreOfflineRegion>> MapLibreOfflineManager.mergeDatabase(String path)
```
> Naming disagreement: Apple calls it `addContentsOfFile:` (framing it as importing packs); Android and mbgl call it `mergeOfflineRegions`. Take the Android/mbgl framing but shorten to `mergeDatabase` since 'offline regions' is already implied by the manager. This is the practical way to ship a preloaded map in the app bundle without making the user download it — pair it in the docs with the mbtiles/pmtiles row, which solves the same problem without any of this machinery. Two caveats to surface, both from the mbgl header: the side database **must be writable** (schema upgrades happen in place, so copy it out of the bundle first), and the merge can fail with a tile-count-limit error.

**Offline region definition — shape / geometry (GeoJSON)** — P2, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_region.dart
```dart
final class MapLibreShapeRegionDefinition extends MapLibreOfflineRegionDefinition { const MapLibreShapeRegionDefinition({required String styleUrl, required String geoJson, required double minZoom, required double maxZoom, double pixelRatio = 1.0, bool includeIdeographs = false}); }
```
> Naming disagreement: Apple says **Shape**, Android and mbgl say **Geometry**. Two-of-three says Geometry, but I pick **Shape** here against the count, because 'geometry' already means something else in every layer document we serialise and because the Dart-facing payload is a GeoJSON string, which reads as a shape. Flag it as a conscious deviation. p2 rather than p1 because a bounding box covers most apps and the polygon path costs materially more tiles to compute; ship the pyramid first. Payload: pass GeoJSON text over the C ABI and let mbgl's own converter build the Geometry<double>, exactly as addSourceJson already does.

**Prefetch zoom delta (load a coarse tile first)** — P2, `controller`, evidence: No binding; mbgl's default of 4 applies. Would be a controller method in packages/maplibre_flutter/lib/src/maplibre_map_controller.dart
```dart
controller.setPrefetchZoomDelta(int delta) / int get prefetchZoomDelta
```
> Squarely a caching/bandwidth knob: prefetching costs extra requests to fill the screen faster. Apple degraded it to a bool; Android and mbgl keep the integer. Take the integer (Android/mbgl agree, and `0` reproduces Apple's NO). It matters more once a disk cache exists, because prefetched coarse tiles then persist. Cheap: one C entry point, one controller method.

**Preload / put a resource into the ambient cache** — P2, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
Future<void> MapLibreOfflineManager.preloadData(Uint8List data, {required String url, DateTime? modified, DateTime? expires, String? eTag, bool mustRevalidate = false})
```
> Naming disagreement: Apple *deprecated* `putResourceWithUrl:` in favour of `preloadData:forURL:…`; Android still ships `putResourceWithUrl`. Take Apple's newer `preloadData` — Apple deliberately moved away from the Android name, so following Android here would adopt a name its own author retired. Real use: warming the cache from an app-controlled CDN bundle, or seeding a style + sprite at first launch so the first map is instant. Requires a `Response`-shaped struct across the C ABI (bytes + modified/expires/etag/mustRevalidate), which is the fiddliest part of this row.

**Puck imagery (top / bearing / shadow images and their sizes)** — P2, `value-type`, evidence: No binding, but the image-registration half already exists: MapLibreStyleLayers.addImage (packages/maplibre_flutter_platform_interface/lib/src/style_layers.dart:47) and the widget rasteriser addWidgetIcon (packages/maplibre_flutter/lib/src/map_layers_controller.dart)
```dart
final class MapLibreLocationPuckStyle { const MapLibreLocationPuckStyle({Widget? topImage, Widget? bearingImage, Widget? shadowImage, double topImageSize = 1, double bearingImageSize = 1, double shadowImageSize = 1, Color accuracyRadiusColor, Color accuracyRadiusBorderColor, double perspectiveCompensation = 0, double imageTiltDisplacement = 0}); }
```
> **This is where our architecture beats both SDKs.** Apple gives you a fixed style struct or a whole custom UIView; Android gives you an XML style. mbgl takes three *style images*, and we already have `addWidgetIcon` — a Flutter widget rasterised into a style image. So the puck can be an arbitrary Flutter widget while still being drawn by the engine (correct depth, correct tilt, no swimming). That is a genuinely differentiating story worth building the example around. `perspectiveCompensation` and `imageTiltDisplacement` are the two properties that make a puck look right on a pitched map and have no SDK-level equivalent at all.

**Region error stream (download errors, tile-limit exceeded)** — P2, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_region.dart
```dart
Stream<MapLibreOfflineError> get MapLibreOfflineRegion.errors;
sealed class MapLibreOfflineError { } // MapLibreOfflineResponseError(reason, message) | MapLibreOfflineTileCountLimitExceeded(limit)
```
> Two of Apple's three notifications and two of mbgl's three observer callbacks are errors, so one sealed error type + one stream covers both. Important semantics to surface: these errors are usually **recoverable** — mbgl retries with exponential backoff and on network restoration (offline.hpp:188–192) — so the UI must not treat the first error as a failed download. A sealed class is the right Dart shape because the tile-limit case carries a different payload and needs different handling.

**Reset (delete and reinitialise) the database** — P2, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
Future<void> MapLibreOfflineManager.resetDatabase()
```
> Nuclear option: destroys ambient cache AND every offline pack, then reinitialises. Unanimous naming. Worth binding mainly as the recovery path for a corrupted DB, which is the failure mode users actually hit. Apple's 'you typically do not need to call this' belongs in the dartdoc verbatim.

**Retrieve one offline region by id** — P2, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
Future<MapLibreOfflineRegion?> MapLibreOfflineManager.getRegion(int id)
```
> Apple has no direct getter (you filter `packs`); Android and mbgl do. Take the getter — it is the natural partner to persisting a region id in the app's own database, which is what apps do. Returns null rather than throwing when the id is gone, matching mbgl's optional<OfflineRegion>.

**Snapshot attributions** — P2, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/snapshotter.dart
```dart
List<String> get MapLibreSnapshot.attributions
```
> **Legally load-bearing and easy to drop.** Both SDKs hide this by compositing attribution onto the image; mbgl hands you the strings and expects you to draw them. Since we return raw pixels, the app MUST be given the strings or every snapshot ships without required attribution. Expose the list, and make the example app draw it — that is the honest answer to the next row.

**Snapshot coordinate projection (point ⇄ LatLng on the static image)** — P2, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/snapshotter.dart
```dart
Offset MapLibreSnapshot.pixelForLatLng(LatLng position); LatLng MapLibreSnapshot.latLngForPixel(Offset point);
```
> This is what makes a snapshot useful: draw your own pins/routes on top in Flutter at the right pixels. Naming disagreement: Apple says pointForCoordinate/coordinateForPoint; Android says pixelForLatLng/latLngForPixel. **Take Android's**, because it matches the vocabulary our existing MapLibreMapProjector already uses (packages/maplibre_flutter_platform_interface/lib/src/projector.dart) — internal consistency beats Apple here. **Y-origin trap**: mbgl's LatLngForFn/PointForFn go through the same TransformState as latLngToScreenCoordinate, which returns a bottom-left-origin y (documented at maplibre_flutter_core.h:114–118, where our shim already flips). The snapshot C ABI must apply the identical flip, and the test must assert north-is-up against an asymmetric fixture — a round trip will pass either way (CLAUDE.md §11).

**Snapshot result image** — P2, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/snapshotter.dart
```dart
final class MapLibreSnapshot { Uint8List get pngBytes; Future<ui.Image> toImage(); }
```
> **Adapted**: UIImage/Bitmap have no Flutter equivalent, so the contract is PNG bytes (encoded by mbgl's own encoder, the same path mbl_map_write_png already uses) plus a lazy `toImage()` for callers who want to draw it. Two things worth getting right: the bytes are **premultiplied** RGBA before encoding (matching the note in maplibre_flutter_core.h:203 for addImage), and returning a raw RGBA buffer + stride as an alternative avoids a PNG round trip for anyone compositing in Flutter — consider offering both, as the copyFrame path already does.

**Snapshotter options (size, pixel ratio, style, camera, region, padding)** — P2, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/snapshotter.dart
```dart
final class MapLibreSnapshotterOptions { const MapLibreSnapshotterOptions({required Size size, required String style, double pixelRatio = 1.0, MapCamera? camera, LatLngBounds? region, EdgeInsets padding = EdgeInsets.zero, String? localFontFamily}); }
```
> All three engines agree on the option set; the only divergence is `scale` (Apple, MLNMapSnapshotter.h:141) vs `pixelRatio` (mbgl ctor). Take **pixelRatio**, which is what the rest of our API already says (MapLibreMapPlatformController.resize takes devicePixelRatio). `camera` and `region` are mutually exclusive in practice — region wins if both are set, matching mbgl's setRegion overriding the camera; encode that as an assert rather than letting it be discovered. Note mbgl also has setPadding (:65) which Apple omits; keep it, since fitting a bounds with insets is the common case. Style takes a URL *or* inline JSON in mbgl and Android but only a URL in Apple — take the two-way version, matching our existing MapLibreMap.style which already accepts both.

**Standalone map snapshotter (render a static image with no widget)** — P2, `capability-interface`, evidence: No binding. mbgl's snapshotter is compiled ONLY on the Apple arm: packages/maplibre_flutter_core/src/CMakeLists.txt:160 (map_snapshotter.cpp); it is absent from the Android (:251+), Linux (:375+), Windows (:496+) and web (web/CMakeLists.txt) source lists. New files: packages/maplibre_flutter_core/src/maplibre_flutter_core.h + packages/maplibre_flutter/lib/src/snapshotter.dart
```dart
final class MapLibreSnapshotter { MapLibreSnapshotter(MapLibreSnapshotterOptions options); Future<MapLibreSnapshot> start(); void cancel(); void dispose(); }
```
> Real uses that a live map cannot serve: a map thumbnail in a list, a share-sheet image of a route, a print/PDF export, a server-ish batch render. Note the header lives under platform/default/include, not include/mbgl — it is a default-platform class, not core, which is why our CORE_ONLY arms drop it. Work order: (1) add map_snapshotter.cpp to the other four arms' target_sources and confirm nothing else is missing, (2) C ABI, (3) Dart. The snapshotter owns its own thread/RunLoop, so it must NOT be created on our render thread. Also: mbgl::MapSnapshotter's ctor takes ResourceOptions, so it inherits the same cachePath defect as the map — fix that row first or every snapshot re-downloads everything.

**Tile server options / well-known tile server preset** — P2, `widget-init`, evidence: Never set; ResourceOptions::Default() carries a default TileServerOptions. packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:642
```dart
MapLibreSettings.configure(tileServer: MapLibreTileServer.mapTiler) // enum { mapLibre, mapTiler, mapbox } — or tileServerOptions: MapLibreTileServerOptions(baseURL: …, uriSchemeAlias: 'maptiler', …)
```
> This is what makes `maptiler://maps/streets` and `mapbox://styles/…` short URLs resolve. p2 because a full https:// style URL always works. Bind the enum first (three presets covers ~everything) and the 20-field struct only if someone asks — Apple exposes both and the struct is almost never used directly.

**Total bytes stored on disk** — P2, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
Future<int> get MapLibreOfflineManager.cacheSizeOnDisk
```
> Every 'clear cache' settings row wants a number next to the button. Apple has a property; mbgl does not, so honest options are (a) stat the sqlite file, which includes ambient + packs + free pages, or (b) sum per-region completedResourceSize, which excludes the ambient cache. Recommend (a) plus a per-region breakdown from (b), and document that (a) overstates after deletes until packDatabase runs.

**Tracking-mode-changed callback** — P2, `widget-callback`, evidence: No binding. packages/maplibre_flutter/lib/src/maplibre_map.dart
```dart
MapLibreMap(onUserTrackingModeChanged: void Function(MapLibreUserTrackingMode mode)?)
```
> Needed precisely because the mode self-cancels on user pan — without this callback an app's 'recenter' button cannot know to light up again. It is a widget callback (bucket 1/3 boundary: the mode itself is a widget prop, so its change notification is a widget callback, matching MapLibreMap.onTap). gl-js splits it into four events; Apple and Android use one; take the one, since our enum already carries the distinction.

**User tracking / camera follow modes** — P2, `widget-prop`, evidence: No binding. Would live as a widget prop plus camera-namespace support: packages/maplibre_flutter/lib/src/maplibre_map.dart and .../maplibre_map_controller.dart:291 (MapLibreCameraController)
```dart
MapLibreMap(userTrackingMode: MapLibreUserTrackingMode.follow, onUserTrackingModeChanged: (mode) {})
enum MapLibreUserTrackingMode { none, follow, followWithHeading, followWithCourse }
```
> Naming resolved in the policy notes: **Apple's 4-value enum**, because Android's CameraMode × RenderMode cross-product is 21 nominal states of which apps use four. Implement it in Dart, in the same place the fly arc lives — no C ABI, and it then works on all six tiers including web, which is a rare thing in this matrix. Behaviour to copy from Apple: the mode auto-resets to `none` when the user pans (MLNMapView.h:86), which is the interaction users expect and the single most-forgotten detail. `followWithCourse` additionally wants `targetCoordinate` (MLNMapView.h:752) to keep a destination in frame — treat that as a later refinement.

**Web/WASM offline persistence (IDBFS)** — P2, `widget-init`, evidence: sqlite3 and the offline database ARE compiled into the WASM build (packages/maplibre_flutter_core/web/CMakeLists.txt:61 offline_database.cpp, :65 sqlite3.cpp, :53 database_file_source.cpp, :104/:115 vendor sqlite), and the map is built with ResourceOptions::Default() (src/web/maplibre_flutter_core_web.cpp:178,186) — so the machinery exists but writes to ":memory:" inside a MEMFS that dies with the page.
```dart
Same API as native — MapLibreSettings.configure(cachePath: …) — with the web platform package mounting IDBFS at that path and calling FS.syncfs on idle.
```
> Worth its own row because it changes the shape of the web story: the matrix currently tells a reader that offline is impossible on web, which would be a permanent architectural limit, when in fact it is a page of Emscripten glue. IDBFS is async and needs an explicit FS.syncfs to flush, so the honest first step is the *ambient cache* (dramatically fewer refetches across reloads) with full offline packs later. This should be tracked in docs/experimental-web-core-wasm.md alongside the COOP/COEP and single-thread-fallback work, since it is the same productionization pass.

**includeIdeographs flag on a region** — P2, `value-type`, evidence: No binding; would be a field on both definition value types (packages/maplibre_flutter/lib/src/offline/offline_region.dart)
```dart
MapLibreOfflineRegionDefinition(..., bool includeIdeographs = false)
```
> Small field, large consequences: CJK glyph ranges are enormous, so a region covering East Asia is a completely different download with this on. Apple's spelling is `includesIdeographicGlyphs`; mbgl's parameter is `includeIdeographs`. Take mbgl's shorter form for the Dart field, since it is the engine's own name and Apple's is a mouthful. Interacts with the local-ideograph-font-family option (§8 of the matrix, line 572) — if we ever wire local glyph rendering, this should default differently.

**Action journal (rolling on-disk event log)** — P3, `widget-init`, evidence: No binding; mbgl::Map is constructed without ActionJournalOptions (packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:638, :917 — the ctor's trailing options parameter is omitted, so the default disabled state applies)
```dart
MapLibreSettings.configure(actionJournal: MapLibreActionJournalOptions(enabled: true, path: …, logFileSize: 1 << 20, logFileCount: 5, renderingStatsReportInterval: Duration(seconds: 60)))
```
> Newish upstream feature, exposed identically by mbgl and the Apple SDK (field for field — Apple's class is a direct transliteration). It is a rolling on-disk journal of map events plus periodic rendering stats, intended for post-hoc field diagnosis. p3, but note it defaults its path to "/tmp/" (action_journal_options.hpp:110), which is wrong on iOS and Android — so if it is ever enabled, the path must be set, and the same platform app-dir resolution the cache path needs will already be there. Genuinely useful for the 'quality is the pitch' goal: it is how you debug a customer's map without a repro.

**Automatic packing after delete/clear** — P3, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
void MapLibreOfflineManager.setPackDatabaseAutomatically(bool enabled)
```
> Only reason to bind it: batch deletes. With autopack on (the default), deleting N regions VACUUMs N times. Android's name is `runPackDatabaseAutomatically`; I renamed to `setPackDatabaseAutomatically` for Dart's setter convention — a small, stated deviation. Explicitly not a widget prop: it is process-global state on the file source.

**Client name / version (User-Agent identification)** — P3, `widget-init`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:627 passes a default-constructed mbgl::ClientOptions()
```dart
MapLibreSettings.configure(client: MapLibreClientInfo(name: 'my_app', version: '1.2.3'))
```
> Long tail, but cheap and it matters for anyone self-hosting tiles: without it every maplibre_flutter app is anonymous in the tile server's logs. ClientOptions is already threaded through every FileSource getter we call, so this is one extra pair of strings on the configure() call. Also worth defaulting to 'maplibre_flutter/<pubspec version>' so the ecosystem is measurable.

**Offline tile count limit** — P3, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
void MapLibreOfflineManager.setTileCountLimit(int limit)
```
> **Deliberate rename**, stated in the naming notes: all three engines still say 'Mapbox' (and mbgl's header even carries the Mapbox Terms-of-Service warning at :245–247), which is meaningless in a MapLibre plugin. Ship it as `setTileCountLimit` and explain in the dartdoc that it caps the region tile store and that exceeding it surfaces as MapLibreOfflineTileCountLimitExceeded on the region error stream. p3 — most self-hosted deployments never touch it, but it is one line once the manager exists.

**Pack (VACUUM) the database** — P3, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/offline/offline_manager.dart
```dart
Future<void> MapLibreOfflineManager.packDatabase()
```
> Apple omits it; Android and mbgl have it. Take Android/mbgl. It is a sqlite VACUUM, so it is slow and moves pages — pair it with runPackDatabaseAutomatically(false) for apps that would rather control when the stall happens (e.g. delete twenty regions, then pack once).

**Platform context (Android AssetManager) for asset:// inside the APK** — P3, `reject`, evidence: packages/maplibre_flutter_core/src/maplibre_flutter_core.cpp:642 — ResourceOptions::Default() leaves platformContext null; our Android arm supplies only a custom HTTPFileSource (src/maplibre_flutter_core_android_http.cpp)
```dart
No Dart API — internal. The Android platform package would pass its AssetManager down at MapLibreSettings.configure time.
```
> Listed for completeness and then rejected: Flutter already extracts assets to a real directory reachable from native code, so pointing `assetPath` at flutter_assets (see that row) solves the same problem without a JNI AssetManager bridge and without diverging our Android arm further from the other four. Revisit only if someone needs to read straight out of a compressed APK.

**Platform network configuration (URLSession / OkHttp)** — P3, `reject`, evidence: Our Android arm owns an HTTPFileSource outright (packages/maplibre_flutter_core/src/maplibre_flutter_core_android_http.cpp:92–149) and the web arm owns an Emscripten one (src/web/emscripten_http_file_source.cpp:189); neither is configurable from Dart. Apple/Linux/Windows use mbgl's own NSURLSession/curl sources.
```dart
REJECT as a cross-platform API. Cover the portable subset with transformRequest + maxConcurrentRequests (separate rows); leave timeouts/TLS pinning/proxies to the platform.
```
> Rejected because a cross-platform API here would be five different half-implementations — NSURLSessionConfiguration, OkHttp, curl, WinHTTP-via-curl and fetch have almost nothing in common, and CLAUDE.md §3's rule is to extend the interface deliberately rather than per-platform. What IS worth doing, and is cheap because we already own the file: our Android HTTPFileSource (maplibre_flutter_core_android_http.cpp) is the one place a header/auth hook could land without touching mbgl, which makes Android the natural pilot if the headers row ever becomes urgent. Document the limitation next to the headers row rather than pretending it is backlog.

**Puck tap / long-press callback** — P3, `widget-callback`, evidence: No binding. MapLibreMap already has onTap (packages/maplibre_flutter/lib/src/maplibre_map.dart) which unprojects a tap.
```dart
MapLibreMap(onLocationPuckTap: VoidCallback?) — or compose: onTap + a distance check against the puck position.
```
> Genuinely trivial in our architecture and worth noting as such: we know the puck's LatLng (the app gave it to us) and we have a projector, so a tap within N logical points of the projected position is the whole implementation — no engine involvement. Ships as a convenience over onTap; do not add a capability interface for it.

**Read-only database mode** — P3, `widget-init`, evidence: No binding; would go in the same C ABI options block (packages/maplibre_flutter_core/src/maplibre_flutter_core.h)
```dart
MapLibreSettings.configure(readOnlyCache: true)
```
> Long tail, but it is the correct way to ship a **read-only prebuilt offline pack inside the app bundle** — open the bundled .db read-only rather than copying it out to writable storage first. Neither SDK exposes it; mbgl does. Worth binding once the offline block exists because it is one setProperty call.

**Rendering statistics** — P3, `controller`, evidence: Only a frame counter: mbl_map_frame_count (packages/maplibre_flutter_core/src/maplibre_flutter_core.h:428), surfaced as MapLibreMapController.renderedFrameCount (packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:239) — and awkwardly, only via the MapLibreModelHost capability, so it is unavailable on a tier that has no model support.
```dart
MapLibreRenderingStats? get controller.renderingStats — move renderedFrameCount here off MapLibreModelHost
```
> Two separable points. (1) **A latent design smell to fix regardless of priority**: `renderedFrameCount` lives on MapLibreModelHost (packages/maplibre_flutter_platform_interface/lib/src/model_host.dart) because that is where it happened to land, but frame count has nothing to do with 3D models — a tier could reasonably implement one and not the other. Move it to its own capability or the base contract. (2) The full stats struct is p3 but is the honest way to answer 'is the map keeping up', which the existing comment at maplibre_flutter_core.h:420–427 correctly argues a Flutter Ticker cannot. Apple exposes the whole struct; mirror it as a plain value type when someone needs it. `enableRenderingStatsView` draws an in-engine overlay and would be a nice debug widget flag.

**Snapshotter annotations and style images** — P3, `reject`, evidence: No binding. packages/maplibre_flutter/lib/src/snapshotter.dart
```dart
Deprioritise. Prefer composing in Flutter over MapLibreSnapshot.pixelForLatLng. If ever needed: MapLibreSnapshotterOptions(layers: List<MapLibreStyleLayer>) reusing the typed style API.
```
> Rejected on design grounds rather than capability grounds: mbgl's annotation API is the legacy pre-style-layer path (include/mbgl/annotation/annotation.hpp) which we have deliberately not bound anywhere, and drawing pins in Flutter over pixelForLatLng is strictly more capable. The one piece worth keeping in mind is getStyle() — it means a snapshot can carry the same typed style layers as a live map, which is the right escape hatch if someone needs engine-drawn content in a snapshot. Correct the matrix regardless.

**Snapshotter local ideograph font family** — P3, `value-type`, evidence: No binding. packages/maplibre_flutter/lib/src/snapshotter.dart
```dart
MapLibreSnapshotterOptions(localFontFamily: 'PingFang SC')
```
> Long tail, but note the asymmetry: mbgl offers localFontFamily on the **snapshotter ctor** and the live map takes it elsewhere, while our MapOptions (packages/maplibre_flutter_platform_interface/lib/src/map_options.dart, all 28 lines of it) has neither. If CJK is ever a target, this and the includeIdeographs row are the two levers, and skipping them means downloading enormous glyph ranges. Mentioned here so the snapshotter's ctor is designed with the slot rather than retrofitted.

**Snapshotter logo / attribution chrome** — P3, `reject`, evidence: n/a — not bindable from mbgl. Would have to be drawn in Flutter, e.g. a MapLibreSnapshotAttribution widget in packages/maplibre_flutter/lib/src/
```dart
REJECT at the core layer. Provide instead: `Widget MapLibreAttribution(List<String> attributions)` for the app to composite.
```
> **Matrix drift:** "Snapshotter logo / attribution toggle" — FEATURE_MATRIX.md:687, ❌ on all five native, ➖ web. **Disagrees**: ❌ claims 'the engine can do it, we just have not bound it'. mbgl cannot — this is SDK-level compositing, so those cells should be ➖ with a note, per the matrix's own rule at line 707.

**Snapshotter observer (style loaded / style failed / image missing)** — P3, `capability-interface`, evidence: No binding. packages/maplibre_flutter/lib/src/snapshotter.dart
```dart
Fold into the start() Future: it completes with MapLibreStyleLoadException on failure. Optionally Stream<String> get MapLibreSnapshotter.missingImages.
```
> Both SDKs expose a delegate/observer; in Dart most of it collapses into the Future's error channel, which is the right adaptation. The one callback that does not collapse is onStyleImageMissing — it fires per missing icon and is the only way to diagnose a snapshot that renders without its symbols. Worth a stream, but p3. Note the same observer shape exists on the live map (mbgl::MapObserver) and is likewise unbound; whoever wires the events domain should do both at once.

**Zoom / tilt / padding while tracking** — P3, `controller-namespace`, evidence: No binding. packages/maplibre_flutter/lib/src/maplibre_map_controller.dart (camera namespace)
```dart
Future<void> controller.camera.setTrackingZoom(double zoom, {Duration? duration}); Future<void> controller.camera.setTrackingTilt(double tilt, {Duration? duration}); Future<void> controller.camera.setTrackingPadding(EdgeInsets padding, {Duration? duration});
```
> Android-only concept and honestly a slightly awkward one — it exists because setting the camera directly fights the tracking loop. Once our tracking loop is Dart, the same problem appears and the same solution applies: the loop must own zoom/tilt/padding and take them from here rather than from camera.move. p3, but design the tracking loop so these slots exist from day one; retrofitting them means rewriting the loop. Note **padding is unbound generally** (FEATURE_MATRIX.md:318, ❌ everywhere), so this row depends on that landing first.


## FEATURE_MATRIX.md staleness audit

The matrix cannot be trusted as the parity backlog today: 24 of 55 sampled cells (~44%) are wrong, and — importantly — they are wrong in only one direction. Every ✅ and 🧪 I sampled held up against the code (macOS ✅ cells are backed by real example-app demos in `packages/maplibre_flutter/example/lib/main.dart`; the 🧪 cells rest on all five native controllers genuinely declaring `MapLibreStyleLayers`/`MapLibreModelHost`/`MapLibreRotateHandler`), so there are no dangerous false positives. What the matrix does instead is systematically *under*-report shipped work: 15 wrong cells are the entire Web column, which gained `MapLibreMapProjector`, `MapLibreCameraTickNotifier` and `MapLibreStyleLayers` in cbfa220 (2026-08-01 03:06) after the last matrix edit (81eaa95, 2026-07-31 22:43), and another 6 are the 3D-model rows in §6/§9, which landed on Linux/Android (de30016, 21:46) and Windows (0a4650e, 21:50) *before* that same edit — whose commit message even reads "models on all five tiers", but which only touched the prose at line 118 and never the tables. The maintainer's own cited example of drift (§5's "no rotate, pitch, double-tap or quick-zoom gesture") is itself out of date: that sentence was corrected in 81eaa95 and §5 is now one of the most accurate sections. Net effect: as a backlog the matrix will make you re-do or de-prioritise work that already exists (especially on web), and it contradicts itself in three places about what is done.

Sampled 55 cells; 24 were wrong.

### Causes

Structural, along three clean seams — not scattered noise.

(1) THE WEB COLUMN, one commit behind. `cbfa220 feat(web): projector, camera tick and style layers on the WASM core tier` (2026-08-01 03:06) landed after the last matrix edit (81eaa95, 2026-07-31 22:43). It flipped the web tier from "camera + style only" to "projector + camera tick + full `MapLibreStyleLayers`", which invalidates every Web ❌ in §1, §2, §3, §6, §7 and §8 in one stroke — 15 of my 24 wrong cells. The prose at lines 105-108 ("**None** of the annotation, layer, query, projection or model surface is bound on web — no projector, no `MapLibreStyleLayers`, no model host") is now the single most wrong sentence in the file. Only the model-host half of it survives.

(2) THE 3D-MODEL ROWS, a half-applied edit. Models landed on Linux/Android (de30016, 21:46) and Windows (0a4650e, 21:50) *before* 81eaa95 at 22:43, whose commit subject is "update the feature matrix for models on all five tiers and the new gestures". Its diff shows it rewrote the §4 rotate/pitch rows and the whole of §5, and updated the summary bullet at line 118 — but never touched §6 line 429 or the six §9 rows. So the failure mode is not "the doc is old", it is "the doc was edited by hand and the edit missed two sections". That is exactly the failure hand-fixing reproduces. It also left the document self-contradicting: line 99 says models are "**macOS/Metal only**" and line 118 says they are "wired on all five native tiers".

(3) PRE-INVERSION RESIDUE IN §4. §5 got a "**Corrected for the core-primary inversion**" header; §4 never did. Its `flyTo` note still says "iOS uses `MLNMapView.fly` … Android animates via `animateCamera`", and `panBy`/`scaleBy` still mark Android and iOS ❌ while marking the desktop trio ✅/🟡 — an Android/iOS-are-SDK-tiers assumption that the 2026-06-21 inversion deleted. This is drift measured in months, not hours.

Underneath all three is a design problem: the grid asks a per-platform question that the architecture no longer has a per-platform answer to. Since the inversion the five native columns are one Dart class shape — I verified that by reading five `implements` clauses that differ only in `MapLibreResizeMaskHint` — so 5/6 of every row is mechanically determined by which capability interfaces one controller declares. The matrix's own rule 4 admits this ("keep all five native columns in lockstep"), and the ~60 rows in §1/§2 that repeat one identical note verbatim ("Expressible: `addSourceJson` takes the whole spec document") are that redundancy made visible: those rows cannot rot independently, and they cannot inform independently either. Meanwhile the one axis that genuinely varies per platform — has anyone actually RUN this here — is encoded in an emoji rather than in a dated record of who ran what on which device, which is why ✅ vs 🧪 is applied inconsistently between §5 (gestures ✅ on unrun hardware) and §2 (layers 🧪 on the same hardware, on the same class of evidence).

### Drift found

| Row | Matrix says | Reality | Direction |
| --- | --- | --- | --- |
| §1 Vector source (`type='vector'`) — Web (:126) | ❌ on Web (and the same ❌ on every other `addSourceJson`-backed source row) | `MapLibreCoreWebController` implements `MapLibreStyleLayers.addSourceJson` (packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:265) forwarding to the embind `WebMap::addSourceJson` (packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:412, exported at :1016). Any spec source document can be sent on web today. | matrix_underclaims |
| §1 GeoJSON source (`type='geojson'`) — Web (:143) | ❌ on Web; ✅ macOS | macOS ✅ is correct (example demos `layers.addPoints` + `GeoJsonSource`). Web is wired: `addSourceJson` + `setGeoJsonData` both exist on the WASM tier. | matrix_underclaims |
| §1 Add source at runtime — `addSource` — Web (:169) | ❌ on Web | Wired (core_web_controller.dart:265) and reachable through `controller.layers.addSource` because `MapLibreLayersController.attachTo` feature-detects `MapLibreStyleLayers` with no platform branch (map_layers_controller.dart:67). | matrix_underclaims |
| §1 GeoJSON `setData` — Web (:174) | ❌ on Web | `setGeoJsonData` implemented at core_web_controller.dart:281. | matrix_underclaims |
| §2 Line layer / Line paint / Line layout — Web (:202) | ❌ on Web | `addLayerJson` implemented on the WASM tier (core_web_controller.dart:273 → maplibre_flutter_core_web.cpp:428), so every layer type the typed API emits is sendable on web exactly as on the native tiers. | matrix_underclaims |
| §2 `addLayer` (+ beforeId) / `removeLayer` — Web (:226) | ❌ on Web | Both wired on web, `beforeId` included (core_web_controller.dart:273, :289). | matrix_underclaims |
| §2 Layer visibility (`layout.visibility`) (:225) | 🧪 on all five native tiers, with the blanket note "Expressible: addLayerJson takes the whole spec document" | Visibility is settable only at layer-creation time. There is no `setLayoutProperty`/`setPaintProperty`/`setVisibility` anywhere in the plugin or in the C ABI (grep returns nothing across `maplibre_flutter/lib`, the platform interface and `maplibre_flutter_core.h`). Toggling a layer means removing and re-adding it. Reading the row alone, a consumer concludes runtime visibility control exists; the honest state is ❌ or 🟡. Same objection applies to "Symbol placement and collision" (L208) and "Universal layer properties" (L224). | matrix_misleading |
| §3 Transition object (duration, delay) — Web (:280) | ❌ on Web; ✅ macOS | `setTransitionOptions` implemented on the WASM tier (core_web_controller.dart:320), including the same "negative means leave the style's value" convention as the C ABI. | matrix_underclaims |
| §4 `easeTo` (eased camera transition) (:294) | 🟡 everywhere — "Native/macOS animate via duration; Web easeTo declared but unused (uses flyTo)" | There is no `easeTo` and no `flyTo` in the public API at all (grep for those names across `maplibre_flutter/lib` and the platform interface returns nothing). The only camera call is `controller.camera.move(target, {duration})`, and a non-null duration steps `flyCameraAt()` — the van-Wijk-ish arc with a mid-flight zoom dip (maplibre_flutter_macos/lib/src/maplibre_flutter_macos_controller.dart:173-193). So easeTo and flyTo are not two features with two statuses; they are one call, and the linear ease the row implies does not exist. | matrix_misleading |
| §4 `flyTo` (flight-curve transition) (:295) | 🟡 Android, ✅ iOS/macOS/Windows/Linux/Web, note: "iOS uses `MLNMapView.fly`; macOS uses a Dart eased arc; Android animates via `animateCamera`" | Pre-inversion prose that survived into a post-inversion table. iOS and Android default to the core tiers (`MapLibreFlutterIosCoreController`, `MapLibreFlutterAndroidCoreController`), which run the identical shared `flyCameraAt` stepping — `MLNMapView.fly` and `animateCamera` are only reachable via the opt-in `_sdk` packages. Android's 🟡 vs the others' ✅ encodes an engine split that no longer exists. | matrix_misleading |
| §4 `panBy` (pan by pixel offset) — Android, iOS (:296) | ❌ Android, ❌ iOS, 🟡 macOS/Windows/Linux | All five native controllers declare `MapLibreGestureHandler` (moveBy/scaleBy) — verified in the class headers of maplibre_flutter_android_core_controller.dart:39, maplibre_flutter_ios_core_controller.dart:40, and the macOS/Windows/Linux equivalents. Android and iOS have exactly the same `moveBy` primitive; the row also violates the matrix's own rule 4 (never leave a shared binding ❌ on unrun platforms). | matrix_underclaims |
| §4 `scaleBy` (relative zoom around anchor) — Android, iOS (:304) | ❌ Android, ❌ iOS, ✅ macOS/Windows/Linux | Same as panBy: `MapLibreGestureHandler.scaleBy` is implemented by all five core controllers, and §5's own "Scroll-zoom gesture" row marks Android and iOS ✅ on the strength of it. The two rows contradict each other. | matrix_underclaims |
| §5 Drag-pan gesture — Windows, Linux (:375) | ✅ Android/iOS/macOS, 🧪 Windows, 🧪 Linux | Inconsistent with the document's own line 102 ("Linux and Windows … have only been run for camera / style / gestures") and with the very next-but-one row, Scroll-zoom (L379), which marks Windows and Linux ✅. If gestures were run on that hardware, drag-pan is ✅; if not, scroll-zoom is 🧪. One of the two is wrong. | matrix_misleading |
| §5 Touch zoom-rotate / Touch-pitch / Drag-rotate — Windows, Linux, Android (:387) | ✅ on all five native platforms, with the note "Unrun on hardware for all but macOS/iOS" | The symbol contradicts its own note and rule 4 ("Mark the platform you actually ran ✅ and the rest 🧪"). Backing evidence is device-free widget tests in packages/maplibre_flutter/test/maplibre_map_test.dart — the same class of evidence that leaves layer rows at 🧪. Not factually false (rule 1 accepts a test), but the ✅/🧪 boundary is being applied two different ways in two sections, which is what makes the grid unreadable as a backlog. | matrix_misleading |
| §6 `maplibre_flutter` widget markers (`MapLibreMap.markers`) — Web (:423) | ❌ on Web | The marker overlay is gated on one thing only — `controller.projector != null` (packages/maplibre_flutter/lib/src/maplibre_map.dart:279-304) — and that branch runs for `ElementViewHandle` alongside texture and platform-view handles. `MapLibreCoreWebController` now implements `MapLibreMapProjector` with a real `projectBatch`/`unproject` (core_web_controller.dart:228, :252 → maplibre_flutter_core_web.cpp:362). Widget markers are wired on web. | matrix_underclaims |
| §6 Map tap → LatLng (`MapLibreMap(onTap:)`) — Web (:426) | ❌ on Web | Same gate (maplibre_map.dart:285-293); works on web now that the projector exists. | matrix_underclaims |
| §6 Flutter widget → style image (`layers.addWidgetIcon`) — Web (:428) | ❌ on Web | `addWidgetIcon` rasterises in pure Dart and calls `addImage`, which the web controller implements (core_web_controller.dart:301). No native-only step remains. | matrix_underclaims |
| §6 3D `.glb` model (`controller.addModel`, `MapLibreMap(models:)`) (:429) | ❌ Android, ❌ iOS, ✅ macOS, ❌ Windows, ❌ Linux — "macOS/Metal only" | All five native controllers declare `MapLibreModelHost` (android:39-45, ios:40-46, macos:30-36, windows:35-42, linux:31-38). Linux/Android landed in de30016 and Windows in 0a4650e, both ~an hour BEFORE the matrix's own last edit — whose commit message is literally "update the feature matrix for models on all five tiers". The prose at line 118 was updated; the table was not. | matrix_underclaims |
| §7 `queryRenderedFeatures` — Web (:520) | ❌ on Web | Implemented on the WASM tier (core_web_controller.dart:335 → maplibre_flutter_core_web.cpp:518, exported :1024), including the `layerIds` filter. | matrix_underclaims |
| §7 `project` / `unproject` — Web (:524) | ❌ on Web | Both implemented (core_web_controller.dart:228 and :252), with a documented rationale for why web needs no presented-vs-newest generation split. | matrix_underclaims |
| §7 `movestart` / `move` / `moveend` events — Web (:511) | ❌ on Web; 🟡 on native via `onCameraChanged` | `MapLibreCoreWebController` mixes in `MapLibreCameraTickNotifier` (core_web_controller.dart:45), so `controller.onCameraChanged` is non-null on web too — the same 🟡 the native columns get. | matrix_underclaims |
| §7 `click` event — Web (:501) | ❌ on Web; 🟡 on native | `onTap` works wherever a projector exists, which now includes web (maplibre_map.dart:279-293). | matrix_underclaims |
| §8 `addImage` / `removeImage` / SDF icons / pixelRatio — Web (:544) | ❌ on Web (four separate rows: 544, 548, 553, 557) | `addImage(id, rgba, w, h, pixelRatio, sdf)` and `removeImage` are implemented on the WASM tier (core_web_controller.dart:301, :314) with the same signature as the C ABI (`mbl_map_add_image`, maplibre_flutter_core.h:207). | matrix_underclaims |
| §9 3D model rows (model layer, placement, occlusion, mesh splitting, lighting, texture wrap) (:636) | ❌ Android, ❌ iOS, ✅ macOS, ❌ Windows, ❌ Linux across all six rows; per-row notes say "Metal-only patch" and "only the Metal edits have been run — GL/Vulkan are unverified mirrors" | Doubly stale. (a) All five tiers implement `MapLibreModelHost`, as of commits that predate the last matrix edit. (b) Since then, ff45251 verified 3D models on GL under Mesa/llvmpipe and 613e207 verified the Vulkan backend under lavapipe (recorded in 51f2536), so "only the Metal edits have been run" is no longer true either. This whole block reads as the single most out-of-date section. | matrix_underclaims |

### Recommendation

Replace it — split along the axis that actually varies, then generate one half and shrink the other. Do not hand-fix: the file was hand-fixed five hours before HEAD and was already wrong in 24/55 sampled cells at the moment of that fix, because a human edit updated the prose and missed two tables.

Concretely, three artefacts instead of one:

1. **A generated capability table (`tool/generate_feature_matrix.dart`, output committed, regen-diffed in CI like ffigen and the typed style API).** Almost everything I checked is derivable without judgement:
   - which capability interfaces each platform controller declares — parse the `implements` clause of the six controllers (`MapLibreGestureHandler`, `MapLibreRotateHandler`, `MapLibreMapProjector`, `MapLibreStyleLayers`, `MapLibreModelHost`, `MapLibreResizeMaskHint`, `MapLibreCameraTickNotifier`);
   - which operations exist at all — the members of `MapLibreMapPlatformController` plus each capability interface, cross-checked against the `FFI_PLUGIN_EXPORT` list in `maplibre_flutter_core.h` and the `EMSCRIPTEN_BINDINGS` `.function(...)` list in `src/web/maplibre_flutter_core_web.cpp` (the web/native asymmetry then falls out of the code instead of being asserted);
   - style-spec coverage — read `v8.json`, exactly as `generate_style_api.dart` already does, and emit the layer/source/expression rows with the generated class names, so §1/§2/§3 stop being 200 hand-typed rows carrying one copy-pasted sentence.
   This alone would have caught 21 of my 24 drift findings on the commit that introduced them.

2. **A short hand-written verification ledger** — the ✅-vs-🧪 axis, which no tool can infer. Not per-row emoji: a table of `platform | date | device | commit | what was exercised`, maybe 20 lines, e.g. "macOS, 2026-07-30, M-series, example app: markers, addPoints+clustering, queryRenderedFeatures, transitions, .glb model". The generated table then says "wired", the ledger says "run here, on this date", and the two cannot contradict each other because they answer different questions. This also fixes the §5-vs-§2 inconsistency in what ✅ means, and removes the temptation to mark unrun hardware ✅.

3. **A genuinely hand-maintained gap list** — the ~40 rows that are real binding work with no code to read: `moveLayer`, `getLayer`, `setPaintProperty`/`setLayoutProperty`, `setFilter`/`getFilter`, `setFeatureState` family, `fitBounds`/`cameraForBounds`, `setMin/MaxZoom`/`Pitch`/`MaxBounds`, `getBounds`, `querySourceFeatures`, offline, snapshotter, location component, `setLight`, sprite/glyph runtime APIs, stretchable images. Every one of these I sampled was accurate — this is the part of the matrix that works, and it is also the part the binding-spec exercise actually needs. Keep it, and let it be prose with upstream names rather than a grid.

If a full replacement is too much right now, the minimum viable repair before anyone plans work off this file, in priority order: (a) delete or rewrite lines 105-108 (the "web has none of it" paragraph) — it is the item most likely to cause wasted or duplicated effort; (b) flip §6 L429 and §9 L636-641 to five-tier and drop the "Metal-only" language now that GL and Vulkan are verified under llvmpipe/lavapipe; (c) reconcile line 99 with line 118; (d) re-read §4 for pre-inversion notes, starting with `flyTo`, `panBy` and `scaleBy`. And regardless of which route you take, mark in §4 that `easeTo`/`flyTo`/`jumpTo`/`panTo`/`zoomTo` do not exist as named APIs — there is only `camera.move(target, {duration})` — because the binding spec is about to propose gl-js names for exactly those, and the matrix currently implies four of them are already ✅.

