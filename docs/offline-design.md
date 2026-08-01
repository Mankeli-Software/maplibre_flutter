# Offline regions — design, and the blocker that stopped it

**Status: designed and prototyped, NOT shipped.** A working C ABI and Dart
wrapper were written and compiled; creating a region aborted the process from
inside mbgl. The code was backed out rather than shipped, and this is the
record so the next attempt starts from the finding rather than from scratch.

Task 8.3 in `docs/api-parity-progress.md`.

---

## What mbgl gives us

`mbgl::DatabaseFileSource` (`include/mbgl/storage/database_file_source.hpp`):

| Call | Purpose |
| --- | --- |
| `createOfflineRegion(definition, metadata, callback)` | define a region |
| `listOfflineRegions(callback)` | enumerate |
| `setOfflineRegionDownloadState(region, Active/Inactive)` | start / pause |
| `deleteOfflineRegion(region, callback)` | delete it and its tiles |
| `setOfflineRegionObserver(region, observer)` | progress |

`OfflineTilePyramidRegionDefinition` is `(styleURL, LatLngBounds, minZoom,
maxZoom, pixelRatio, includeIdeographs)`. `OfflineRegionStatus` carries
`downloadState`, `completedResourceCount`, `requiredResourceCount`,
`requiredResourceCountIsPrecise` and `completedResourceSize`.

## The design that was built

A process-wide surface, **not** per-map — same reasoning as `mbl_configure`
(8.1): a region is rows in the cache database, so it is independent of any map,
and downloading one benefits every map afterwards.

```c
typedef void (*MblOfflineProgressCallback)(void *user, int64_t region_id,
    int32_t state, uint64_t completed_resources, uint64_t required_resources,
    int required_is_precise, uint64_t completed_bytes);
typedef void (*MblOfflineRegionCallback)(void *user, int64_t region_id, char *message);
typedef void (*MblOfflineListCallback)(void *user, char *json);

void  mbl_offline_create_region(const char *style_url, double north, double south,
      double east, double west, double min_zoom, double max_zoom,
      float pixel_ratio, MblOfflineRegionCallback cb, void *user);
void  mbl_offline_list_regions(MblOfflineListCallback cb, void *user);
void  mbl_offline_set_download_state(int64_t region_id, int32_t state);
void  mbl_offline_delete_region(int64_t region_id, MblOfflineRegionCallback cb, void *user);
void  mbl_offline_set_progress_callback(int64_t region_id,
      MblOfflineProgressCallback cb, void *user);
```

Decisions worth keeping:

- **Ids, not handles, across the ABI.** mbgl's mutators take an `OfflineRegion`
  rather than an id, so the shim keeps an `unordered_map<int64_t,
  shared_ptr<OfflineRegion>>` and maps back. That keeps the C surface plain
  integers, which is what a Dart binding wants.
- **The progress observer must live in a table, not a capture.** mbgl's
  `OfflineRegionObserver` is owned by the region and outlives any single call, so
  a lambda capturing the Dart callback would be a dangling call the moment the
  ABI function returned.
- **`setOfflineRegionObserver(region, nullptr)` BEFORE deleting**, or a status
  callback can fire for a region that no longer exists.
- **`requiredResourceCountIsPrecise` has to reach Dart.** It is false until mbgl
  has enumerated the whole pyramid, so a progress bar built on
  `completed/required` before then jumps around. Callers need to know to show a
  spinner until it turns true.
- **`OfflineRegionDefinition` is a `std::variant`, not mapbox's `variant`** — so
  `std::get_if`, not `.match()`. Both idioms are live in this codebase
  (`mbgl::Value` is mapbox's), and the first attempt used the wrong one.

## The blocker

Creating a region and letting the download start aborts the process:

```
libc++abi: terminating due to uncaught exception of type std::__1::regex_error
Abort trap: 6
```

What is known:

- It happens **after** `createOfflineRegion` succeeds and the region has been
  written — `create → list → delete` passed and round-tripped the definition
  (bounds, zooms, style URL) before the abort.
- It is **not** in our code: the shim contains no `std::regex`. It is raised on
  mbgl's database/download thread.
- Removing the progress-observer test did **not** avoid it, so it is reached
  from starting the download itself, not from observing it.
- `regex_error` (rather than a match failure) means a regex was **constructed**
  from a bad pattern, which points at pattern-building rather than input.

Where to look next, in order:

1. `std::regex` uses in the pinned submodule reachable from the offline download
   path — start with `mbgl/util/url.cpp`, `mbgl/util/mapbox.cpp` and the
   `OfflineDownload` translation unit.
2. Whether the demotiles style URL is the trigger, by trying a
   `file://` style and an inline document.
3. Whether it reproduces in mbgl's own offline tests on this platform and
   toolchain (Xcode 26 / libc++) — if it does, it is an upstream bug and belongs
   in `docs/upstream-*` like the other two we carry.

**Do not ship a `createRegion` that can abort the host process.** That is why
this was backed out with the tree green rather than landed behind a flag: a
crash in a background thread cannot be caught by the app, so there is no
defensive posture available to a caller.

## What did land from this work

- The test-fragility fix it exposed: `maplibre_flutter_core_test.dart` no longer
  deletes the temp directory holding the configured cache. The cache path is
  process-wide and `mbl_configure` refuses once a map exists, so deleting the
  directory left every later test pointing at a path that no longer existed
  (`unable to open database file`). That was a latent order-dependency, and the
  offline group is simply the first thing that ran late enough to notice.
