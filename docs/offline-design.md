# Offline regions — the design, and the upstream bug that took two attempts

**Status: SHIPPED** on all five `mbgl-core` tiers. Task 8.3 in
`docs/api-parity-progress.md`.

This document was written when the first attempt was backed out with a crash it
could not explain. It is kept because the *finding* is the valuable part: the
crash was an upstream MapLibre defect, not our code, and the reasoning that
eventually located it is worth having on record.

The upstream defect has its own write-up, with evidence and the TODO to report
it: **`docs/upstream-offline-url-regex/`**.

---

## What mbgl gives us

`mbgl::DatabaseFileSource` (`include/mbgl/storage/database_file_source.hpp`):

| Call | Purpose |
| --- | --- |
| `createOfflineRegion(definition, metadata, callback)` | define a region |
| `listOfflineRegions(callback)` | enumerate |
| `getOfflineRegionStatus(region, callback)` | read progress once |
| `setOfflineRegionDownloadState(region, Active/Inactive)` | start / pause |
| `setOfflineRegionObserver(region, observer)` | progress and errors |
| `updateOfflineMetadata(id, metadata, callback)` | rename |
| `deleteOfflineRegion(region, callback)` / `invalidateOfflineRegion(…)` | remove / restage |
| `packDatabase` / `resetDatabase` / `clearAmbientCache` / `setMaximumAmbientCacheSize` | the database itself |

`OfflineTilePyramidRegionDefinition` is `(styleURL, LatLngBounds, minZoom,
maxZoom, pixelRatio, includeIdeographs)`. `OfflineRegionStatus` carries
`downloadState`, `completedResourceCount`, `requiredResourceCount`,
`requiredResourceCountIsPrecise`, `completedResourceSize`, and the tile-only
subsets of those.

## The shape that shipped

A process-wide surface, **not** per-map — same reasoning as `mbl_configure`
(8.1): a region is rows in the cache database, so it is independent of any map,
and downloading one benefits every map afterwards.

Thirteen `mbl_offline_*` entry points; `MapLibreCoreOffline` in
`maplibre_flutter_core`; `MapLibreOfflineStore` as a feature-detected capability
on `MapLibreFlutterPlatform`; `MapLibreOfflineManager` + `MapLibreOfflineRegion`
app-facing. See `docs/api-parity-binding-spec.md` for why every name is the one
it is.

Decisions worth keeping:

- **Ids, not handles, across the ABI.** mbgl's mutators take an `OfflineRegion`
  whose constructor is private to `OfflineDatabase`, so an id cannot be turned
  back into one. The shim keeps every region mbgl has handed it in a table. The
  visible consequence, and it is in the public dartdoc: **a region created by a
  previous run must be listed before anything can resume, delete or observe it.**
- **The progress observer must live in a table, not a capture.** mbgl's
  `OfflineRegionObserver` is owned by the region and outlives any single call, so
  a lambda capturing the Dart callback would be a dangling call the moment the
  ABI function returned.
- **`setOfflineRegionObserver(region, nullptr)` BEFORE deleting**, or a status
  callback can fire for a region that no longer exists.
- **`requiredResourceCountIsPrecise` has to reach Dart.** It is false until mbgl
  has enumerated the whole pyramid, so a progress bar built on
  `completed/required` before then jumps. `MapLibreOfflineRegionStatus.progress`
  returns **null** while it is false rather than a number that runs backwards.
- **`OfflineRegionDefinition` is a `std::variant`, not mapbox's `variant`** — so
  `std::get_if`, not `.match()`. Both idioms are live in this codebase
  (`mbgl::Value` is mapbox's), and the first attempt used the wrong one.

Four more that the second attempt added:

- **Every global here is intentionally leaked.** A `DatabaseFileSource` owns a
  thread; letting a namespace-scope `shared_ptr` release the last reference at
  static-destruction time joins that thread while the runtime is tearing itself
  down. It surfaced as `system_error: mutex lock failed: Invalid argument` and a
  non-zero exit **after** all 89 tests had passed — a green suite that aborts.
  A function-local `new` that is never deleted is the fix.
- **The strong reference is not optional either.** `FileSourceManager` remembers
  file sources *weakly*, so without one the database thread dies the instant no
  map references it — a download that stops when the last map is disposed.
- **Metadata is bytes, and the ABI says so** (`const uint8_t *`, length). mbgl
  stores a BLOB and its header explicitly asks bindings not to impose a format,
  so the database stays portable. A `char *` would truncate at the first NUL; the
  listing carries it as base64 because JSON cannot hold arbitrary bytes.
- **`mbl_offline_get_region_status` and `mbl_offline_set_observer` return whether
  they dispatched.** For an id this process does not hold there is no region to
  ask about and no callback will ever fire, so a `void` version left the Dart
  Future hanging. A timeout is the wrong fix twice over: it cannot tell "slow"
  from "never", and freeing a callback mbgl might still hold is a use-after-free.

## What was NOT shipped, deliberately

Each is a separate row in `docs/api-parity-binding-spec.md`, not an oversight:

- **Shape (GeoJSON) regions.** mbgl has `OfflineGeometryRegionDefinition`; the
  ABI has no way to pass a geometry. One written by another SDK into the same
  database is listed as `MapLibreOtherRegionDefinition` — carrying no bounds
  rather than a bounding box it never had — and can still be deleted.
- **`mergeOfflineRegions`, `setDatabasePath`, ambient-cache *preload*
  (`put`), `invalidateAmbientCache`, `setConnected` / `NetworkStatus`,
  `transformRequest`.**
- The ambient-cache calls that DID ship (`clearAmbientCache`,
  `setMaximumAmbientCacheSize`, `resetDatabase`, `packDatabase`) are here because
  they are calls on the same `DatabaseFileSource` and are what a "storage"
  settings screen needs next to its region list.

## The blocker, and what it turned out to be

Creating a region and letting the download start aborted the process:

```
libc++abi: terminating due to uncaught exception of type std::__1::regex_error
Abort trap: 6
```

The first attempt's notes said: it happens after `createOfflineRegion` succeeds;
it is not in our code (the shim contains no `std::regex`); removing the
progress-observer test does not avoid it; and `regex_error` rather than a match
failure means a regex was **constructed** from a bad pattern.

**All four were correct, and the fourth is what found it.** `std::regex` uses in
the pinned submodule reachable from the offline download path come to two files,
and one of them — `src/mbgl/util/mapbox.cpp` — builds a pattern out of a
`TileServerOptions` URL template without escaping it. MapLibre's own glyphs
template is `/font/{fontstack}/{start}-{end}.pbf`, and in the ECMAScript grammar
an unescaped `{` is a quantifier. So the DEFAULT configuration cannot download
anything.

Full mechanism, evidence and the upstream TODO:
**`docs/upstream-offline-url-regex/`**. Carried as
`patches/offline-url-template-regex.patch`, with `offline_url_probe` (ctest label
`hermetic`) as the committed reproduction — the only one of the three patches we
carry that ships with its own test.

Two lessons that generalise past this bug:

- **"Not our code" is a location, not a dead end.** The first attempt stopped at
  correctly concluding the throw was inside mbgl. The distance from there to the
  answer was one `grep -rn regex src/` and reading the two hits.
- **A crash fix that is only a crash fix can be worse than the crash.** Escaping
  the template alone would have left the gate (`isNormalizedSourceURL`) and the
  extractor (`createTokenMap`) disagreeing about what a token is, and every glyph
  URL in the style would have canonicalised to the string `maplibre://fonts` — a
  download that runs, completes, and produces an unusable region.

## What the first attempt left behind

The test-fragility fix it exposed: `maplibre_flutter_core_test.dart` no longer
deletes the temp directory holding the configured cache. The cache path is
process-wide and `mbl_configure` refuses once a map exists, so deleting the
directory left every later test pointing at a path that no longer existed
(`unable to open database file`). That was a latent order-dependency, and the
offline group is simply the first thing that ran late enough to notice.

The offline group now also configures a cache path of its own if none is in
force, so `dart test --name "offline regions"` works on its own — running it that
way was how the ordering dependency became visible again.
