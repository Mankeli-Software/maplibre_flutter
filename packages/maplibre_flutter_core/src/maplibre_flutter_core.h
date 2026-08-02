// C ABI shim over MapLibre Native (mbgl-core). Dart FFI cannot bind C++, so this
// header exposes a plain-C surface (opaque handle + functions) that ffigen binds
// (CLAUDE.md §5c). It must stay free of any mbgl/C++ includes so ffigen parses it
// against the bare toolchain. The implementation lives in maplibre_flutter_core.cpp.
//
// Threading: each MblMap owns a dedicated render thread that exclusively creates
// and drives the mbgl Map/RunLoop/HeadlessFrontend (mbgl is single-thread-affine).
// Commands are marshaled onto that thread; rendered frames are published to an
// internal buffer and announced via a frame-ready callback. Getters read cached
// state. All functions below are safe to call from any thread.
//
// Generated bindings: lib/src/maplibre_flutter_core_bindings_generated.dart
// (committed, regenerated with `dart run tool/ffigen.dart`, never hand-edited).
#ifndef MAPLIBRE_FLUTTER_CORE_H
#define MAPLIBRE_FLUTTER_CORE_H

#include <stddef.h>
#include <stdint.h>

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to one off-screen MapLibre map (owns an mbgl::Map + headless
// Metal backend + RunLoop on its own render thread). Created/destroyed from Dart.
typedef struct MblMap MblMap;

// Frame-ready callback, invoked on the render thread after a new frame has been
// rendered into the internal buffer. `user` is the pointer passed to
// mbl_map_set_frame_callback. Must be cheap and thread-safe: the macOS plugin
// uses it to call FlutterTextureRegistry.textureFrameAvailable. Do NOT call back
// into the map from here.
typedef void (*MblFrameCallback)(void *user);

// --- Diagnostics -------------------------------------------------------------
//
// Everything mbgl does asynchronously can fail silently: a style URL that 404s,
// a glyph range the tile server does not serve, a bad sprite. Each of those
// produces a blank or half-drawn map and NOTHING else — the only synchronous
// error paths in this ABI are the two JSON parses. This is the channel out.

// What a diagnostic event is about. Values are part of the ABI: Dart switches
// on them.
typedef enum {
  // mbgl MapObserver::onDidFinishLoadingStyle. Fires on EVERY style load, not
  // just the first — and a style load drops every app-added source and layer,
  // so this is the signal to re-apply them.
  MBL_DIAG_STYLE_LOADED = 0,
  // onDidFinishLoadingMap: the style and all of its initial resources are in.
  MBL_DIAG_MAP_LOADED = 1,
  // onDidFailLoadingMap. The message is mbgl's, prefixed with which of
  // MapLoadError it was.
  MBL_DIAG_MAP_LOAD_FAILED = 2,
  // onDidBecomeIdle: nothing left to draw or fetch.
  MBL_DIAG_IDLE = 3,
  // onStyleImageMissing. The message is the image id a layer asked for.
  MBL_DIAG_STYLE_IMAGE_MISSING = 4,
  // onGlyphsError. The message names the font stack and glyph range.
  MBL_DIAG_GLYPHS_ERROR = 5,
  // onSpriteError.
  MBL_DIAG_SPRITE_ERROR = 6,
  // onRenderError.
  MBL_DIAG_RENDER_ERROR = 7,
  // An mbgl::Log record. This is the one that actually catches a glyph 404 —
  // mbgl logs it rather than routing it to MapObserver::onGlyphsError.
  MBL_DIAG_LOG = 8,
  // A command this ABI accepted could not be applied. Every mutating call here
  // is posted to the render thread and returns void, so without this the caller
  // cannot tell "removed" from "there was nothing by that name". The message
  // names the call and the reason.
  MBL_DIAG_COMMAND_FAILED = 9,
} MblDiagnosticKind;

// Mirrors mbgl::EventSeverity. Observer events that are not log records report
// MBL_SEVERITY_ERROR, except the informational ones, which report
// MBL_SEVERITY_INFO.
typedef enum {
  MBL_SEVERITY_DEBUG = 0,
  MBL_SEVERITY_INFO = 1,
  MBL_SEVERITY_WARNING = 2,
  MBL_SEVERITY_ERROR = 3,
} MblDiagnosticSeverity;

// A diagnostic event.
//
// `message` is a heap string **transferred to the callee**: release it with
// mbl_string_free exactly once. Never NULL — an event with nothing to say
// passes "". Ownership transfer is what makes this safe to marshal to another
// thread, which is the point: the callback fires on the RENDER thread (or, for
// MBL_DIAG_LOG, on whichever thread logged), so a Dart handler is necessarily a
// NativeCallable.listener and will read the string after this call returns.
//
// Do NOT call back into the map from here.
typedef void (*MblDiagnosticCallback)(void *user, int32_t kind,
                                      int32_t severity, char *message);

// Register (or clear, with NULL) the diagnostic callback. Installing one on any
// map also installs the process-wide mbgl log observer, once; it forwards to
// stderr as well, so nothing that used to be printed stops being printed.
//
// If a style has ALREADY finished loading when a callback is registered, one
// MBL_DIAG_STYLE_LOADED is delivered immediately. Registration cannot precede
// creation — the caller needs the handle first — and a style often loads within
// ~200 ms of it, so a strictly live stream would routinely drop the one event a
// caller most needs: the initial load that says the map is usable.
FFI_PLUGIN_EXPORT void mbl_map_set_diagnostic_callback(
    MblMap *map, MblDiagnosticCallback callback, void *user);

// --- Process-wide configuration ----------------------------------------------
//
// Tile cache, API key and tile-server URLs, set ONCE before the first map.
//
// **Why process-wide and not per-map.** mbgl caches file sources by
// `(type, ResourceOptions)` — `FileSourceManager::getFileSource` returns the
// same instance for equal options — so a per-map cache path or API key mints a
// SECOND cache database and a second connection pool per distinct value. Apple
// reached the same conclusion and shipped `MLNSettings` as a static
// configure-before-first-map surface; this mirrors it.

// Configure resources. Returns 1 on success, 0 if it is too late — a map
// already exists, or an mbl_offline_* call has already built the offline
// database. Both bake the current options into a file source that is then
// shared for the process lifetime, so a later change would apply to nothing
// while looking like it had worked.
//
// `cache_path`: the SQLite cache database. mbgl's own default is `:memory:`,
// which means every restart re-downloads every tile — so passing a real path
// here is not an optimisation, it is the difference between having a tile cache
// and not. Parent directories are created. NULL leaves it unchanged.
//
// `max_cache_bytes`: 0 keeps mbgl's default (50 MB).
//
// `api_key`: substituted for `{key}` in tile URLs by mbgl's URL resolver, which
// is how MapTiler, Stadia and friends authenticate. NULL leaves it unchanged.
FFI_PLUGIN_EXPORT int mbl_configure(const char *cache_path,
                                    uint64_t max_cache_bytes,
                                    const char *api_key);

// The cache path in force, as a heap string (mbl_string_free), so a caller can
// report what it actually got rather than what it asked for.
FFI_PLUGIN_EXPORT char *mbl_get_cache_path(void);

// --- Authenticating to a tile provider ----------------------------------------
//
// Three mechanisms, because providers use three: a key in the query string, a
// header, and a signed URL. They are here together because they are one
// question — "how does this request prove who it is" — and because the first of
// them does not work without mbl_configure_tile_server.

// The tile servers mbgl knows the URL shapes of.
typedef enum {
  MBL_TILE_SERVER_MAPLIBRE = 0,
  MBL_TILE_SERVER_MAPTILER = 1,
  MBL_TILE_SERVER_MAPBOX = 2,
} MblTileServer;

// Select the tile server whose URL conventions apply. Returns 1, or 0 if it is
// too late (see mbl_configure — same rule, same reason).
//
// **Without this the API key passed to mbl_configure does nothing at all**, and
// that is not an overstatement of a subtle case. mbgl reaches the key through
// exactly one path — rewriting a CANONICAL URL, one under the configured
// scheme, e.g. `maptiler://maps/streets` — and three separate gates close it by
// default: an ordinary `https://…` URL is not canonical so it is returned
// untouched; the default configuration (MapLibre) declares
// `requiresApiKey=false`; and its api-key parameter name is the empty string.
// There is also no `{key}` token substitution anywhere in mbgl. So a key set
// without this call is stored and never read.
//
// What selecting a server buys, precisely:
//   * `maptiler://maps/streets` and `mapbox://styles/…` resolve at all;
//   * the key is appended to every URL derived from one of those — the style,
//     and the sprite, glyph and tile sub-requests it names, which is the half
//     an app cannot do by hand because it never sees those URLs;
//   * offline regions canonicalise against the right templates
//     (see docs/upstream-offline-url-regex/ for why that path is delicate).
//
// An app whose style URL is a plain `https://…` with the key already in the
// query string needs none of this — that path never consults these options.
FFI_PLUGIN_EXPORT int mbl_configure_tile_server(int32_t server);

// Per-request HTTP headers, as a JSON array of rules:
//
//   [{"urlPrefix":"https://tiles.example.com/",
//     "headers":{"Authorization":"Bearer …"}}, …]
//
// REPLACE-ALL, and that is the whole update protocol: rotating an expiring
// token is one more call with the new value, and there is no partial update to
// race. Pass NULL or `[]` to clear.
//
// **Callable at any time**, unlike mbl_configure — deliberately. Headers are
// not part of ResourceOptions and nothing caches them, so they are read fresh
// when each request is built. A bearer token that expires in an hour is the
// normal case, and an API that could only be set before the first map would be
// useless for it.
//
// **`urlPrefix` is required on every rule, and that is a deliberate divergence
// from upstream.** Apple applies its headers to a whole NSURLSession and
// Android to the whole OkHttp client, so both send your Authorization header to
// every host a style names — and a style routinely names hosts you do not own,
// for sprites, glyphs or a basemap from another vendor. Scoping by prefix is
// how a credential stops leaking to them. An app that genuinely wants every
// host can pass `"https://"`, which is explicit, greppable, and its own choice.
//
// Matching is a plain case-sensitive prefix over the full URL, evaluated in
// array order; every matching rule contributes, and a later rule wins a header
// name a earlier one also set. Returns 1, or 0 if the JSON is malformed — in
// which case NOTHING changed, because a half-applied auth rule is worse than a
// rejected one.
FFI_PLUGIN_EXPORT int mbl_set_http_headers(const char *rules_json);

// The kind of resource being requested. Mirrors `mbgl::Resource::Kind`.
typedef enum {
  MBL_RESOURCE_UNKNOWN = 0,
  MBL_RESOURCE_STYLE = 1,
  MBL_RESOURCE_SOURCE = 2,
  MBL_RESOURCE_TILE = 3,
  MBL_RESOURCE_GLYPHS = 4,
  MBL_RESOURCE_SPRITE_IMAGE = 5,
  MBL_RESOURCE_SPRITE_JSON = 6,
  MBL_RESOURCE_IMAGE = 7,
} MblResourceKind;

// Asks the app to rewrite a URL — gl-js `transformRequest`, for signed URLs and
// per-tenant hosts.
//
// `url` is a heap string TRANSFERRED to the callee (mbl_string_free). Fires on
// mbgl's file-source thread, so a Dart handler must be a
// `NativeCallable.listener`.
//
// **The reply is asynchronous and MUST arrive**, exactly once, via
// mbl_transform_reply with the same `request_id`. Replying from another thread
// is safe, replying later is safe, and replying after the request has been
// cancelled is safe — mbgl routes it through an actor mailbox that drops late
// messages. Never replying stalls that ONE resource forever, which for a style
// is a blank map.
typedef void (*MblRequestTransformCallback)(void *user, uint64_t request_id,
                                            int32_t kind, char *url);

// Install (or, with NULL, remove) the URL rewriter. Returns 1, or 0 if the
// online file source could not be reached.
//
// Only mbgl's NETWORK file source honours a resource transform; the one a map
// actually talks to (the resource loader) inherits an empty implementation and
// would drop it silently, which is the trap this function exists to hide.
FFI_PLUGIN_EXPORT int mbl_set_request_transform(
    MblRequestTransformCallback callback, void *user);

// Deliver the rewritten URL for `request_id`. Passing the URL unchanged is the
// correct way to decline. A `request_id` that has already been answered, or
// that belongs to a cancelled request, is ignored.
FFI_PLUGIN_EXPORT void mbl_transform_reply(uint64_t request_id, const char *url);

// --- Offline regions ----------------------------------------------------------
//
// Download a style and everything it needs for a bounding box and zoom range,
// into the SAME database mbl_configure named, and keep it there until deleted.
// Apple's shapes (MLNOfflineStorage / MLNOfflinePack /
// MLNTilePyramidOfflineRegion), because gl-js has no offline vocabulary at all.
//
// **Process-wide, not per-map**, for the same reason mbl_configure is: a region
// is rows in the cache database, so it exists independently of any map, and
// downloading one benefits every map afterwards. There is no map handle in this
// section by design.
//
// **A region is identified by its int64 id everywhere.** mbgl's mutators take an
// `OfflineRegion` object with a private constructor, which cannot cross a C ABI,
// so the shim keeps the objects mbgl handed it in a table and maps ids back.
//
// **Everything here is asynchronous and every callback fires on mbgl's DATABASE
// thread**, so a Dart handler must be a `NativeCallable.listener`.
//
// **A region download needs a real cache path.** With mbgl's default `:memory:`
// the region is written to a database that dies with the process, which looks
// exactly like a download that did nothing. Call mbl_configure first.

// Matches `mbgl::OfflineRegionDownloadState`.
typedef enum {
  MBL_OFFLINE_INACTIVE = 0,
  MBL_OFFLINE_ACTIVE = 1,
} MblOfflineDownloadState;

// `required_is_precise` when the status could not be read at all — see
// mbl_offline_get_region_status. Never sent to an observer.
#define MBL_OFFLINE_STATUS_UNAVAILABLE (-1)

// A region's progress. `state` is an MblOfflineDownloadState.
//
// `required_is_precise` is 0 until mbgl has enumerated the whole tile pyramid,
// and it is the reason this field exists rather than being hidden: before it
// turns 1, `required_resources` is a LOWER BOUND that grows as sources are
// discovered, so `completed / required` runs backwards and a progress bar built
// on it jumps. Show a spinner until it is 1. It is
// MBL_OFFLINE_STATUS_UNAVAILABLE (-1) only in the one case documented on
// mbl_offline_get_region_status, and every other field is then 0.
typedef void (*MblOfflineProgressCallback)(void *user, int64_t region_id,
                                           int32_t state,
                                           uint64_t completed_resources,
                                           uint64_t required_resources,
                                           int required_is_precise,
                                           uint64_t completed_bytes,
                                           uint64_t completed_tiles,
                                           uint64_t required_tiles,
                                           uint64_t completed_tile_bytes);

// Why a download is not finishing. `message` is a heap string TRANSFERRED to the
// callee (mbl_string_free), never NULL.
//
// `is_tile_limit` distinguishes the one error that is not transient: mbgl caps
// the number of tiles ONE DATABASE may hold across all regions whose URLs
// canonicalise under the configured tile server's scheme (6000 by default, see
// mbl_offline_set_tile_count_limit) and stops storing tiles at the cap. Every
// other error here is a network failure mbgl retries on its own backoff, so a
// caller should surface but not act on those.
typedef void (*MblOfflineErrorCallback)(void *user, int64_t region_id,
                                        int is_tile_limit, char *message);

// Delivers a one-shot result. `error` is NULL on success, otherwise a heap
// string (mbl_string_free) and `region_id` is meaningless.
typedef void (*MblOfflineRegionCallback)(void *user, int64_t region_id,
                                         char *error);

// Delivers the region list as a heap JSON array (mbl_string_free), or NULL if
// the query failed. Each element is
//   {"id":N,"kind":"tilePyramid"|"geometry","styleUrl":"…",
//    "north":…,"south":…,"east":…,"west":…,
//    "minZoom":…,"maxZoom":…|null,"pixelRatio":…,"includeIdeographs":bool,
//    "metadataBase64":"…","state":0|1,"completedResources":N,
//    "requiredResources":N,"requiredResourceCountIsPrecise":bool,
//    "completedBytes":N,"completedTiles":N,"requiredTiles":N,
//    "completedTileBytes":N}
//
// `maxZoom` is **null** when the region was defined with an infinite one ("as
// deep as each source goes"): JSON has no infinity, and writing a stand-in
// number would silently redefine the region on the way back out.
//
// `kind` is `"geometry"` for a region another SDK wrote to the same database
// with mbgl's OfflineGeometryRegionDefinition — this ABI cannot create one, and
// such an element carries no bounds rather than a bounding box the region never
// had. It can still be listed, deleted and invalidated by id.
//
// Metadata is base64 because mbgl stores arbitrary BYTES and explicitly tells
// bindings not to impose a format on them (offline.hpp) — a raw string field
// cannot carry a NUL or invalid UTF-8, and quietly mangling an app's blob is
// worse than making it decode one line.
//
// The status fields come from a separate per-region query, so listing is not
// free — but a list without progress is useless to a UI that has just restarted,
// which is the only time anything lists.
typedef void (*MblOfflineListCallback)(void *user, char *json);

// Define a region and write it to the database. It starts INACTIVE: register a
// progress callback, then call mbl_offline_set_download_state to begin.
//
// The bounds are mbgl's `LatLngBounds(sw, ne)` in degrees. `max_zoom` may be
// INFINITY, meaning "as deep as each source goes". `pixel_ratio` should be the
// device's — a region downloaded at 1.0 and displayed at 2.0 re-fetches every
// raster tile.
//
// A box that crosses the antimeridian is expressed with an UNWRAPPED east —
// west 170, east 190 — not a wrapped one. `east < west` is rejected rather than
// normalised: mbgl would hull it into the complementary box, which is the whole
// rest of the world, and downloading that silently is worse than an error.
//
// `metadata`/`metadata_len` is opaque to the engine: mbgl stores the bytes and
// hands them back on listing, and Apple documents the same field
// (MLNOfflinePack.context) the same way. Pass a name, a JSON blob, or NULL/0.
//
// Invalid input (empty style URL, max_zoom < min_zoom, non-finite bounds)
// reports through `callback` with an error rather than throwing: mbgl's
// LatLngBounds constructor throws on a bad latitude and a throw across
// `extern "C"` is undefined behaviour.
FFI_PLUGIN_EXPORT void mbl_offline_create_region(
    const char *style_url, double north, double south, double east, double west,
    double min_zoom, double max_zoom, float pixel_ratio,
    int include_ideographs, const uint8_t *metadata, uint32_t metadata_len,
    MblOfflineRegionCallback callback, void *user);

// Replace a region's metadata blob. The new bytes are visible to the next
// mbl_offline_list_regions.
FFI_PLUGIN_EXPORT void mbl_offline_set_metadata(
    int64_t region_id, const uint8_t *metadata, uint32_t metadata_len,
    MblOfflineRegionCallback callback, void *user);

// Every region in the database, with its current progress. See
// MblOfflineListCallback for the JSON shape.
FFI_PLUGIN_EXPORT void mbl_offline_list_regions(MblOfflineListCallback callback,
                                                void *user);

// Start (MBL_OFFLINE_ACTIVE) or pause (MBL_OFFLINE_INACTIVE) downloading.
// A no-op for an id this process has not seen — the shim can only act on
// regions it holds an `OfflineRegion` for, so call mbl_offline_list_regions
// after a restart before touching a region created by a previous run.
FFI_PLUGIN_EXPORT void mbl_offline_set_download_state(int64_t region_id,
                                                      int32_t state);

// Read a region's progress once, without waiting for it to change. This is what
// a UI needs on startup: the observer only fires on a CHANGE, so a completed
// region that nobody is downloading never reports anything.
//
// Returns 1 if a callback is on its way, 0 if `region_id` is not one this
// process holds (see mbl_offline_set_download_state) — in which case NOTHING
// will be delivered. The return value is what lets a binding resolve its
// promise instead of waiting on a call that is never coming, and it must not be
// replaced by a timeout: freeing the callback while mbgl may still hold it is a
// use-after-free, and a timeout cannot tell "slow" from "never".
//
// Returning 1 is a PROMISE of exactly one delivery, including when the read
// fails — mbgl can refuse whenever the row has gone or SQLite is unhappy, which
// a caller cannot predict. That case arrives as `required_is_precise ==
// MBL_OFFLINE_STATUS_UNAVAILABLE` with every other field 0, rather than as
// silence, because silence is indistinguishable from a slow database and leaves
// the caller's callback allocated forever.
FFI_PLUGIN_EXPORT int mbl_offline_get_region_status(
    int64_t region_id, MblOfflineProgressCallback callback, void *user);

// Observe a region's progress and errors. Either callback may be NULL. Passing
// NULL for both removes the observer. Returns 1 if it was installed (or
// removed), 0 for an id this process does not hold.
//
// The observer is owned by mbgl and outlives this call, so the shim holds the
// (callback, user) pair in a table rather than in a capture — a lambda capturing
// them would be a dangling call the moment this function returned.
FFI_PLUGIN_EXPORT int mbl_offline_set_observer(
    int64_t region_id, MblOfflineProgressCallback on_progress,
    MblOfflineErrorCallback on_error, void *user);

// Delete a region and evict the resources no other region needs. The observer is
// cleared first, so no status callback can fire for a region that is gone.
FFI_PLUGIN_EXPORT void mbl_offline_delete_region(
    int64_t region_id, MblOfflineRegionCallback callback, void *user);

// Mark a region's tiles stale so the next map load revalidates them against the
// server instead of trusting the cache. Cheaper than delete-and-redownload: an
// unchanged tile costs one conditional request rather than its bytes.
FFI_PLUGIN_EXPORT void mbl_offline_invalidate_region(
    int64_t region_id, MblOfflineRegionCallback callback, void *user);

// Raise or lower the per-database tile cap (mbgl's default is 6000).
//
// It is easy to assume this is a Mapbox-only limit — mbgl calls it
// `setOfflineMapboxTileCountLimit` and its own comment cites the Mapbox terms of
// service. It is NOT: the counter is over tiles whose URL is canonical for the
// CONFIGURED tile server, and OfflineDownload canonicalises tile URLs before
// storing them, so a MapLibre-hosted region's tiles count too. Past the cap mbgl
// silently stops storing tiles and reports through MblOfflineErrorCallback with
// `is_tile_limit` set; a large region hits it long before it hits disk.
FFI_PLUGIN_EXPORT void mbl_offline_set_tile_count_limit(uint64_t limit);

// Compact the database file, releasing the space deleted regions freed. mbgl
// does this automatically after every delete, so this exists for the caller who
// turned that off or wants it at a chosen moment — it vacuums, which is slow and
// rewrites pages.
FFI_PLUGIN_EXPORT void mbl_offline_pack_database(
    MblOfflineRegionCallback callback, void *user);

// --- The ambient cache, in the same database ----------------------------------
//
// Offline regions and the ambient (opportunistic) tile cache share one SQLite
// file, which is why these live here and not next to mbl_configure: they are
// calls on the same DatabaseFileSource, and every one of them is the sibling an
// app's "storage" settings screen needs next to its region list.
//
// Neither of these touches resources an offline region requires — that is mbgl's
// guarantee, and it is the whole point of having both in one database.

// Erase the ambient cache. Regions survive.
FFI_PLUGIN_EXPORT void mbl_offline_clear_ambient_cache(
    MblOfflineRegionCallback callback, void *user);

// Cap the ambient cache at `bytes`. **0 disables ambient caching entirely**
// while leaving regions alone, which is the supported way to run
// "downloaded regions only, nothing opportunistic".
//
// Expensive: it trims to fit before returning. Note the cap is over the whole
// database, so regions eat into it — 40 MB of regions under a 50 MB cap leaves
// the ambient cache 10.
FFI_PLUGIN_EXPORT void mbl_offline_set_maximum_ambient_cache_size(
    uint64_t bytes, MblOfflineRegionCallback callback, void *user);

// Delete the database file and start again — regions, ambient cache, all of it.
// This is the "reset" behind an app's clear-all-data button, and it is the only
// call here that destroys downloaded regions.
FFI_PLUGIN_EXPORT void mbl_offline_reset_database(
    MblOfflineRegionCallback callback, void *user);

// Create an off-screen map of `width`x`height` device pixels at `pixel_ratio`,
// loading `style_uri` (URL, file path, or inline JSON). Spawns the render thread
// and starts loading the style. Returns NULL on failure. Does not block on the
// style load — use mbl_map_await_frame or the frame callback to know when a
// frame exists.
//
// `continuous`: 0 = Static mode (each camera/style change renders one complete
// frame, blocking until all its tiles load — simple, used by headless/tests);
// 1 = Continuous mode (render partial frames immediately and refine as tiles
// stream in, like the mobile SDK — smooth interaction over uncached/detailed
// tiles, no per-frame network stall). The public API is identical either way.
FFI_PLUGIN_EXPORT MblMap *mbl_map_create(uint32_t width, uint32_t height,
                                         float pixel_ratio,
                                         const char *style_uri, int continuous);

// Replace the active style (URL, file path, or inline JSON). Triggers a re-render.
FFI_PLUGIN_EXPORT void mbl_map_set_style(MblMap *map, const char *style_uri);

// Jump the camera and trigger a re-render (no animation in M2; M3 adds duration).
FFI_PLUGIN_EXPORT void mbl_map_set_camera(MblMap *map, double lat, double lng,
                                          double zoom, double bearing,
                                          double pitch);

// Read the last-set camera into the (nullable) out params. Cheap (cached).
FFI_PLUGIN_EXPORT void mbl_map_get_camera(MblMap *map, double *out_lat,
                                          double *out_lng, double *out_zoom,
                                          double *out_bearing,
                                          double *out_pitch);

// Resize the off-screen surface and trigger a re-render.
FFI_PLUGIN_EXPORT void mbl_map_resize(MblMap *map, uint32_t width,
                                      uint32_t height);

// Pan the map by a screen-space delta (device pixels) and re-render. For the
// shared desktop gesture layer.
FFI_PLUGIN_EXPORT void mbl_map_move_by(MblMap *map, double dx, double dy);

// Zoom by `scale` (>1 zooms in) about the anchor point (device pixels) and
// re-render.
FFI_PLUGIN_EXPORT void mbl_map_scale_by(MblMap *map, double scale,
                                        double anchor_x, double anchor_y);

// Turn the map CONTENT clockwise by `degrees` about the anchor, and re-render.
//
// The anchor is in the same space as mbl_map_scale_by: logical points,
// TOP-LEFT origin, passed to mbgl unflipped. That is the OPPOSITE of the
// projection functions below, which do flip — mbgl documents CameraOptions'
// anchor as top-left and converts it itself (transform.cpp does
// `anchor->y = height - anchor->y`), whereas latLngToScreenCoordinate hands back
// a bottom-left y. Two conventions coexist in this file deliberately; a
// briefly-shipped flip here mirrored the Windows pinch anchor.
//
// The sign lives HERE, once, so five controllers do not each re-derive it.
// mbgl's bearing is the compass direction that is UP, so turning the content
// clockwise LOWERS it; Flutter's ScaleUpdateDetails.rotation is positive for a
// clockwise on-screen twist, and this takes that convention.
FFI_PLUGIN_EXPORT void mbl_map_rotate_by(MblMap *map, double degrees,
                                         double anchor_x, double anchor_y);

// Tilt by `degrees` (positive tilts AWAY from straight down, toward the
// horizon) about the viewport centre, and re-render.
//
// mbgl clamps the result to [0, util::DEFAULT_PITCH_MAX] = [0, 60], so callers
// need no clamp of their own.
FFI_PLUGIN_EXPORT void mbl_map_pitch_by(MblMap *map, double degrees);

// --- Camera commands ---------------------------------------------------------
//
// mbgl has jumpTo / easeTo / flyTo natively (map.hpp:73-75). Binding them here
// retires the Dart-side flight arc, which no upstream shares.

// A PARTIAL camera: each field applies only when its `has_` flag is non-zero,
// mirroring `mbgl::CameraOptions`, whose fields are all std::optional. That
// partiality is the point — "zoom to 12 and leave everything else" must not
// require reading the camera first, which races the render thread.
typedef struct {
  int32_t has_center;
  double center_lat;
  double center_lng;
  int32_t has_zoom;
  double zoom;
  int32_t has_bearing;
  double bearing;
  int32_t has_pitch;
  double pitch;
  int32_t has_roll;
  double roll;
  int32_t has_padding;
  double padding_top;
  double padding_right;
  double padding_bottom;
  double padding_left;
  // The screen point that stays fixed while zoom/bearing change, in LOGICAL
  // POINTS from the TOP-LEFT — the same space as the gesture anchors.
  //
  // **mbgl discards this whenever a centre is set**: `Transform::startTransition`
  // reads `anchor = camera.center ? std::nullopt : camera.anchor`. So an
  // anchored move must NOT carry a centre, and a test that anchors on the map
  // centre cannot detect the difference, because the centre is a fixed point
  // either way.
  int32_t has_anchor;
  double anchor_x;
  double anchor_y;
} MblCameraOptions;

// How to animate, mirroring `mbgl::AnimationOptions`.
//
// Two gl-js flyTo options are deliberately absent because the engine cannot
// honour them: `curve` (the van Wijk rho) is hardcoded to 1.42 in
// Transform::flyTo and only varies indirectly from apex_zoom, and there is no
// maxDuration field at all.
typedef struct {
  int32_t has_duration;
  uint32_t duration_ms;
  // Cubic bezier control points, mbgl's UnitBezier. Only a cubic maps onto it,
  // which is why the Dart side types this as `Cubic` and not `Curve`.
  int32_t has_easing;
  double easing_x1;
  double easing_y1;
  double easing_x2;
  double easing_y2;
  // flyTo only. Average velocity in screenfuls per second; gl-js calls it
  // `speed`, mbgl calls it `velocity`. Engine default 1.2.
  int32_t has_speed;
  double speed;
  // flyTo only. The zoom at the apex of the flight arc — mbgl's
  // AnimationOptions::minZoom, renamed because `minZoom` already means a hard
  // constraint in the same Dart namespace.
  int32_t has_apex_zoom;
  double apex_zoom;
} MblAnimationOptions;

// Called on the render thread when an animated move finishes OR is superseded.
//
// `token` is whatever the caller passed to mbl_map_ease_to / mbl_map_fly_to.
// Superseding fires it too, and that is mbgl's own behaviour rather than a
// choice made here: `Transform::startTransition` invokes the PREVIOUS
// transitionFinishFn before installing the new one. So a Dart Future built on
// this completes rather than hanging when a gesture interrupts a flight.
typedef void (*MblCameraFinishCallback)(void *user, uint64_t token);

// Register (or clear, with NULL) the camera-finished callback.
FFI_PLUGIN_EXPORT void mbl_map_set_camera_finish_callback(
    MblMap *map, MblCameraFinishCallback callback, void *user);

// Apply `camera` instantly.
FFI_PLUGIN_EXPORT void mbl_map_jump_to(MblMap *map,
                                       const MblCameraOptions *camera);

// Transition to `camera` along a straight, eased path. `token` is reported to
// the finish callback; pass 0 for "do not report".
//
// **CONTINUOUS MODE ONLY.** mbgl advances transitions from its render loop, so
// in Static mode this creates a transition nothing ever steps and the camera
// never moves. Every real tier is continuous; the headless harness is not.
FFI_PLUGIN_EXPORT void mbl_map_ease_to(MblMap *map,
                                       const MblCameraOptions *camera,
                                       const MblAnimationOptions *animation,
                                       uint64_t token);

// Transition to `camera` along a van Wijk flight path (zoom out, pan, zoom in).
FFI_PLUGIN_EXPORT void mbl_map_fly_to(MblMap *map,
                                      const MblCameraOptions *camera,
                                      const MblAnimationOptions *animation,
                                      uint64_t token);

// Stop any transition in flight, leaving the camera where it got to.
// `Map::cancelTransitions` — the finish callback still fires.
FFI_PLUGIN_EXPORT void mbl_map_cancel_transitions(MblMap *map);

// --- Bounds ------------------------------------------------------------------

// A geographic box, south-west and north-east corners. Field order follows
// `mbgl::LatLngBounds`, which is latitude-first — never gl-js's LngLatBounds.
typedef struct {
  double sw_lat;
  double sw_lng;
  double ne_lat;
  double ne_lng;
} MblLatLngBounds;

// Compute the camera that frames `bounds` under `padding`, then apply it with
// the given animation, ALL ON THE RENDER THREAD.
//
// Fused deliberately rather than exposed as compute-then-move: the computation
// needs the live transform, so splitting it would mean a blocking round trip
// followed by a second command, with the camera free to change in between.
// `mode`: 0 = jump, 1 = ease, 2 = fly.
FFI_PLUGIN_EXPORT void mbl_map_fit_bounds(MblMap *map,
                                          const MblLatLngBounds *bounds,
                                          double pad_top, double pad_right,
                                          double pad_bottom, double pad_left,
                                          int32_t has_bearing, double bearing,
                                          int32_t has_pitch, double pitch,
                                          int32_t mode,
                                          const MblAnimationOptions *animation,
                                          uint64_t token);

// Compute the camera that would frame `bounds`, WITHOUT moving — gl-js
// `cameraForBounds`. Returns 1 on success, 0 on timeout.
//
// BLOCKS the caller for up to `timeout_ms`: the computation needs the live
// transform, which only the render thread may touch. One-shot by nature, so
// unlike the projection functions it is not worth a snapshot.
FFI_PLUGIN_EXPORT int mbl_map_camera_for_lat_lng_bounds(
    MblMap *map, const MblLatLngBounds *bounds, double pad_top,
    double pad_right, double pad_bottom, double pad_left, int32_t has_bearing,
    double bearing, int32_t has_pitch, double pitch, uint32_t timeout_ms,
    MblCameraOptions *out_camera);

// The geographic area a camera covers — gl-js `getBounds` when passed the
// current camera. Returns 1 on success, 0 on timeout. Blocks, as above.
FFI_PLUGIN_EXPORT int mbl_map_lat_lng_bounds_for_camera(
    MblMap *map, const MblCameraOptions *camera, uint32_t timeout_ms,
    MblLatLngBounds *out_bounds);

// The camera CONSTRAINTS, mirroring `mbgl::BoundOptions`.
//
// Note `bounds` here constrains the camera CENTRE unless the constrain mode is
// Screen — which is Android's `setLatLngBoundsForCameraTarget` semantics, NOT
// gl-js's `maxBounds`. See mbl_map_set_constrain_mode.
typedef struct {
  int32_t has_bounds;
  MblLatLngBounds bounds;
  int32_t has_min_zoom;
  double min_zoom;
  int32_t has_max_zoom;
  double max_zoom;
  int32_t has_min_pitch;
  double min_pitch;
  int32_t has_max_pitch;
  double max_pitch;
} MblBoundOptions;

// Apply camera constraints. Unset fields are left alone.
//
// mbgl clamps pitch to DEFAULT_PITCH_MAX = 60 degrees regardless of max_pitch.
FFI_PLUGIN_EXPORT void mbl_map_set_bounds(MblMap *map,
                                          const MblBoundOptions *bounds);

// Read the current constraints. Every field comes back set — mbgl's getBounds
// fills all of them. Returns 1 on success, 0 on timeout; blocks, as above.
FFI_PLUGIN_EXPORT int mbl_map_get_bounds(MblMap *map, uint32_t timeout_ms,
                                         MblBoundOptions *out_bounds);

// 0 = None, 1 = HeightOnly, 2 = WidthAndHeight, 3 = Screen (mbgl ConstrainMode,
// mode.hpp:24-29).
//
// Needed to give `maxBounds` gl-js's meaning: gl-js constrains what is VISIBLE,
// while mbgl's BoundOptions::bounds constrains the camera CENTRE until the mode
// is Screen. Same word, different semantics — Apple exposes the screen flavour
// separately as `maximumScreenBounds`.
FFI_PLUGIN_EXPORT void mbl_map_set_constrain_mode(MblMap *map, int32_t mode);

// --- Projection -------------------------------------------------------------
//
// Convert between geographic coordinates and screen positions, for anchoring
// Flutter widgets ("markers") to a LatLng. Screen positions are in the SAME
// screen space as mbl_map_move_by / mbl_map_scale_by anchors — mbgl `Size`
// units, top-left origin (the controllers configure that size in logical
// points, so these match Flutter's widget-box coordinates with no DPR scaling).
//
// NOTE: mbgl itself is not internally consistent here. Its gesture anchors
// (scaleBy/moveBy) are top-left origin, but TransformState::latLngToScreenCoordinate
// returns a BOTTOM-LEFT-origin y. The implementation flips y so everything this
// header exposes is genuinely top-left; do not remove that flip.
//
// These do NOT touch the live mbgl Map: every camera/size change snapshots a
// copy of mbgl's transform on the render thread, and the functions below run
// pure projection math on that snapshot under a lightweight lock. So they are
// cheap and safe to call from any thread (e.g. Flutter's UI thread inside a
// Flow paint), need no render-thread round trip, and are exact for bearing/pitch.

// Project one geographic point to a screen position. Writes *out_x/*out_y; the
// (nullable) *out_visible is 0 when the point is behind the camera (off the
// visible map on a pitched view) and 1 otherwise. Returns 1 on success, 0 if no
// camera/transform snapshot exists yet (in which case nothing is written).
//
// `generation` selects WHICH transform to project against: pass 0 for the newest
// one, or a generation from mbl_map_presented_generation() to project against the
// frame currently on screen (see that function — this is what keeps anchored
// widgets from swimming during movement). An unknown/evicted generation quietly
// falls back to the newest transform.
FFI_PLUGIN_EXPORT int mbl_map_pixel_for_lat_lng(MblMap *map, double lat,
                                                double lng, double *out_x,
                                                double *out_y, int *out_visible,
                                                uint64_t generation);

// Batch project `count` points in one call (one FFI call per frame for all
// markers). `in_lat_lng` is 2*count doubles [lat0,lng0,lat1,lng1,...]; writes
// 2*count doubles [x0,y0,x1,y1,...] to `out_xy` and, if non-null, `count` ints
// to `out_visible`. Returns the snapshot generation used (a value that bumps on
// every camera change; 0 means no snapshot yet, in which case nothing is
// written). Acquires the snapshot lock once for the whole batch.
FFI_PLUGIN_EXPORT uint64_t mbl_map_pixels_for_lat_lngs(MblMap *map,
                                                       const double *in_lat_lng,
                                                       uint32_t count,
                                                       double *out_xy,
                                                       int *out_visible,
                                                       uint64_t generation);

// Inverse projection: the geographic point under a screen position (for
// hit-testing a tap, or dragging a marker). Writes *out_lat/*out_lng. Returns 1
// on success, 0 if no camera/transform snapshot exists yet.
FFI_PLUGIN_EXPORT int mbl_map_lat_lng_for_pixel(MblMap *map, double x, double y,
                                                double *out_lat,
                                                double *out_lng,
                                                uint64_t generation);

// --- Style sources, layers and images ---------------------------------------
//
// For point datasets too large to be Flutter widgets (thousands and up): the
// ENGINE draws these, so they are glued to the map by construction — same
// transform, same frame, no lag — and scale far past what one-widget-per-point
// can. Clustering comes free: set `cluster: true` on a geojson source and mbgl
// runs supercluster internally, re-clustering per zoom.
//
// `json` is MapLibre Style Spec JSON, exactly what maplibre-gl-js takes in
// map.addSource(id, {...}) / map.addLayer({...}), so data-driven styling,
// expressions and filters all work with no extra API surface here.
//
// JSON parsing and conversion happen SYNCHRONOUSLY on the calling thread (they
// need no map), so a malformed document is reported immediately: these return 1
// on success, or 0 with a message written to `err` (pass NULL/0 to ignore).
// Applying the result to the style is then posted to the render thread, where
// mbgl lives. Errors only detectable there (a duplicate or unknown id) are
// logged rather than returned.

FFI_PLUGIN_EXPORT int mbl_map_add_source_json(MblMap *map, const char *id,
                                              const char *json, char *err,
                                              uint32_t err_len);

// `before_id` (nullable) inserts the layer beneath an existing one, for draw
// order; NULL appends on top.
FFI_PLUGIN_EXPORT int mbl_map_add_layer_json(MblMap *map, const char *json,
                                             const char *before_id, char *err,
                                             uint32_t err_len);

// Replaces the data of an existing geojson source — the cheap path for dynamic
// datasets (mbgl re-tiles and re-clusters internally; no layer rebuild).
FFI_PLUGIN_EXPORT int mbl_map_set_geojson_data(MblMap *map,
                                               const char *source_id,
                                               const char *geojson, char *err,
                                               uint32_t err_len);

FFI_PLUGIN_EXPORT void mbl_map_remove_layer(MblMap *map, const char *id);

// Set ONE style-spec property on an existing layer, by its spec name.
//
// `value_json` is a JSON fragment: `12`, `"#ff0000"`, `["get","population"]`,
// `"none"`. Returns 1 if the JSON parsed, 0 otherwise (message in `err`).
//
// **One entry point covers the lot.** `mbgl::style::Layer::setProperty`
// (include/mbgl/style/layer.hpp:144) dispatches to the generated paint/layout
// setters and then, on miss, handles `visibility`, `minzoom`, `maxzoom`,
// `filter` and `source-layer` itself (src/mbgl/style/layer.cpp:165-190). So
// this ABI needs none of gl-js's split into setPaintProperty /
// setLayoutProperty / setFilter / setLayerZoomRange — those are Dart-side
// names over this one call.
//
// The JSON is parsed on the CALLING thread (so bad JSON is reported here and
// now) and the mutation is posted. A property the layer does not have is
// therefore reported asynchronously, through the diagnostic channel as
// MBL_DIAG_COMMAND_FAILED.
// Whether the style has an image called `id` — gl-js `hasImage`.
// Returns 1 yes, 0 no, -1 if the read timed out (which is NOT "no").
FFI_PLUGIN_EXPORT int mbl_map_has_image(MblMap *map, const char *id,
                                        uint32_t timeout_ms);

// Every image id in the style, as a JSON array — gl-js `listImages`. Includes
// the style's own sprite images, not just ones this ABI added. Release with
// mbl_string_free; NULL on timeout.
FFI_PLUGIN_EXPORT char *mbl_map_get_image_ids(MblMap *map, uint32_t timeout_ms);

// One source as JSON: `{"id":…,"type":…,"attribution":…,"volatile":…}`, or
// NULL if absent or timed out. Release with mbl_string_free.
//
// NOT the source's full style-spec document: `mbgl::style::Source` has no
// serialize() the way Layer does, so this reports what the public API actually
// exposes rather than fabricating the rest.
//
// `attribution` is the string a tile provider requires be shown — see the
// attribution work in stage 8, which has no other route to it today.
FFI_PLUGIN_EXPORT char *mbl_map_get_source_json(MblMap *map,
                                                const char *source_id,
                                                uint32_t timeout_ms);

// The style's source ids, as a JSON array. Release with mbl_string_free.
//
// Like mbl_map_get_layer_ids, mbgl's own "org.maplibre.annotations" source is
// omitted — AnnotationManager injects it on every style load.
//
// NOTE for callers building a replay: mbl_map_get_source_json returns a
// DESCRIPTOR (id, type, attribution, volatile), not a style-spec document, and
// cannot return one — mbgl's Source has no serialize() the way Layer does. A
// source cannot be round-tripped through this ABI; keep the document you added.
FFI_PLUGIN_EXPORT char *mbl_map_get_source_ids(MblMap *map,
                                               uint32_t timeout_ms);

FFI_PLUGIN_EXPORT int mbl_map_set_layer_property(MblMap *map,
                                                 const char *layer_id,
                                                 const char *name,
                                                 const char *value_json,
                                                 char *err, uint32_t err_len);

// Move `layer_id` in the draw order: directly beneath `before_id`, or to the
// top when `before_id` is NULL/empty.
//
// Cheap by construction: `Style::removeLayer` hands back the owning unique_ptr
// and `addLayer` takes a `before`, so the Layer object survives the move — no
// re-parse, no re-upload. Reports through the diagnostic channel if the layer
// does not exist.
FFI_PLUGIN_EXPORT void mbl_map_move_layer(MblMap *map, const char *layer_id,
                                          const char *before_id);

// Read one property back as JSON — gl-js `getPaintProperty` /
// `getLayoutProperty` / `getFilter`, which are all `Layer::getProperty`.
//
// Returns a heap string the caller must release with mbl_string_free, or NULL
// if the layer or property does not exist, or the read timed out. BLOCKS up to
// `timeout_ms`: the style lives on the render thread.
FFI_PLUGIN_EXPORT char *mbl_map_get_layer_property(MblMap *map,
                                                   const char *layer_id,
                                                   const char *name,
                                                   uint32_t timeout_ms);

// The style's layer ids, top-most last, as a JSON array of strings — gl-js
// `getLayersOrder`. Release with mbl_string_free; NULL on timeout.
//
// mbgl's OWN annotation layers ("org.maplibre.annotations…") are omitted.
// AnnotationManager::updateStyle() injects them on every style load, whether or
// not anything uses them, so an unfiltered list reports a layer that is in no
// style document, has no gl-js counterpart, and cannot be driven through any
// API we expose. They are still reachable by id through
// mbl_map_get_layer_json — filtered out of the ENUMERATION, not hidden.
FFI_PLUGIN_EXPORT char *mbl_map_get_layer_ids(MblMap *map, uint32_t timeout_ms);

// One layer as its full style-spec JSON — gl-js `getLayer`.
//
// Uses `Layer::serialize()`, NOT `Style::getJSON()`: the latter returns the
// document AS LOADED and so would not reflect anything the app added or
// changed. Release with mbl_string_free; NULL if absent or timed out.
FFI_PLUGIN_EXPORT char *mbl_map_get_layer_json(MblMap *map,
                                               const char *layer_id,
                                               uint32_t timeout_ms);
FFI_PLUGIN_EXPORT void mbl_map_remove_source(MblMap *map, const char *id);

// Registers an icon usable as `icon-image` in a symbol layer, from raw
// premultiplied RGBA (`width * height * 4` bytes, copied here). This is what
// lets a Flutter widget become an engine-drawn marker: paint the widget to an
// image, hand the bytes over, and reference it by id. `pixel_ratio` is the
// image's scale (2 for a @2x bitmap); `sdf` makes it a signed-distance-field
// icon that can be recoloured/scaled by the style.
FFI_PLUGIN_EXPORT void mbl_map_add_image(MblMap *map, const char *id,
                                         const uint8_t *rgba, uint32_t width,
                                         uint32_t height, float pixel_ratio,
                                         int sdf);
FFI_PLUGIN_EXPORT void mbl_map_remove_image(MblMap *map, const char *id);

// Style-wide transition behaviour. `duration_ms` / `delay_ms` below zero leave
// the style document's own value (mbgl's default is 300 ms / 0).
//
// `placement_transitions` = 0 stops SYMBOL layers fading in and out. That fade
// is why a cluster's count label lingers ~300 ms after its circle has gone: a
// circle is a feature that simply stops being drawn, while a symbol ramps its
// opacity over the transition duration (mbgl `Placement::symbolFadeChange`).
// Turning it off makes the two disappear together — at the cost of the basemap's
// own labels popping rather than fading, since this is a property of the style,
// not of one layer.
//
// Sticky: re-applied automatically after every style load, which would
// otherwise reset it to the document's values. Only honoured in Continuous mode
// (mbgl ignores transition options in Static).
FFI_PLUGIN_EXPORT void mbl_map_set_transition_options(
    MblMap *map, int32_t duration_ms, int32_t delay_ms,
    int placement_transitions);

// Query the features the engine actually DREW inside a screen-space box
// (logical points, top-left origin — the same space as the projection
// functions and gesture anchors).
//
// This is how a caller finds out what is on screen without duplicating the
// engine's work: for a clustered geojson source it returns supercluster's
// cluster features, with their `point_count` and their real positions, which
// Dart could not compute itself. Pass a comma-separated `layer_ids` to restrict
// the query, or NULL for every layer.
//
// Returns a heap-allocated GeoJSON FeatureCollection string that the caller
// must release with mbl_string_free, or NULL on failure. Runs the query ON the
// render thread (mbgl's renderer is thread-affine) and waits up to
// `timeout_ms`, returning NULL if that elapses — so a busy render thread costs
// a dropped query, never a deadlock.
// `filter_json` is a style-spec filter EXPRESSION as JSON (e.g.
// `["==", ["get", "kind"], "city"]`), or NULL for none — mbgl
// `RenderedQueryOptions::filter` (renderer/query.hpp). It is evaluated inside
// the engine, so a filtered query costs less than fetching everything and
// filtering in Dart, and it can reach properties Dart never sees.
FFI_PLUGIN_EXPORT char *mbl_map_query_rendered_features(
    MblMap *map, double min_x, double min_y, double max_x, double max_y,
    const char *layer_ids, const char *filter_json, uint32_t timeout_ms);

// Delivers a query result. `json` is a heap string TRANSFERRED to the callee —
// release it with mbl_string_free — or NULL if the query failed. Fires on the
// RENDER thread, so a Dart handler must be a NativeCallable.listener.
typedef void (*MblQueryCallback)(void *user, char *json);

// Same query, without blocking the caller.
//
// The synchronous form waits on a condition variable with a deadline, which on
// the UI isolate means stalling frame production for however long the render
// thread takes to reach the request. That is tolerable for a one-off hit test
// and wrong for a query driven by the camera at 60-120 Hz, which is the usual
// reason to run one.
//
// There is no timeout: the callback fires when the render thread gets to it.
// A caller that needs a deadline can impose one on its own Future.
FFI_PLUGIN_EXPORT void mbl_map_query_rendered_features_async(
    MblMap *map, double min_x, double min_y, double max_x, double max_y,
    const char *layer_ids, const char *filter_json, MblQueryCallback callback,
    void *user);

// Query features in a SOURCE's loaded tiles, drawn or not — gl-js
// `querySourceFeatures`, mbgl `Renderer::querySourceFeatures`
// (renderer/query.hpp). Unlike the rendered query this ignores styling and
// visibility, so it answers "what data is loaded here", not "what is on
// screen": a feature hidden by a layer filter, or under another feature, or in
// a layer whose zoom range excludes the current zoom, still comes back.
//
// `source_layers` is a comma-separated list of source-layer names (required in
// practice for a vector source, ignored by a geojson one), or NULL for all.
// `filter_json` is as above.
//
// Two behaviours that surprise every caller once, both mbgl's and gl-js's:
//
//   * it only ever sees tiles ALREADY LOADED — there is no fetch — so the
//     result depends on where the camera has been;
//   * results are NOT deduplicated. The answer is assembled per tile, so one
//     feature in the overlap of several cached tiles comes back once per tile.
//     Dedupe by feature id if you need unique features.
FFI_PLUGIN_EXPORT char *mbl_map_query_source_features(
    MblMap *map, const char *source_id, const char *source_layers,
    const char *filter_json, uint32_t timeout_ms);

// --- Clusters ----------------------------------------------------------------
//
// The three supercluster questions, over mbgl's feature-extension mechanism
// (Renderer::queryFeatureExtensions, extension "supercluster") — gl-js
// getClusterExpansionZoom / getClusterChildren / getClusterLeaves, Apple
// MLNShapeSource.h:408-437.
//
// All three take the integer `cluster_id` that clustering put in a cluster
// feature's properties, which is gl-js's shape. mbgl actually wants a whole
// FEATURE (Apple hands it the cluster shape), but the only thing it reads off
// it is that property — render_geojson_source.cpp:133 — so a synthetic feature
// carrying just `cluster_id` is equivalent and spares every caller having to
// keep the cluster feature alive.
//
// Only a geojson source with `cluster: true` answers these; anything else
// returns NULL / -1.

// The zoom at which a cluster splits — point the camera here to expand it.
// Returns -1 if the source is not clustered or the call timed out.
//
// **A cluster id that does not exist is NOT detectable here.** supercluster
// derives the answer from the id's own low bits — `(cluster_id % 32) - 1`,
// vendor/supercluster/include/supercluster.hpp:236 — and only then walks the
// tree, so a made-up id returns a plausible-looking number rather than
// failing. 999999 answers 30. To check that a cluster exists, ask
// mbl_map_get_cluster_children: that one really does come back empty.
FFI_PLUGIN_EXPORT int32_t mbl_map_get_cluster_expansion_zoom(
    MblMap *map, const char *source_id, uint32_t cluster_id,
    uint32_t timeout_ms);

// The cluster's immediate children (clusters and/or points) at the next zoom
// level, as a GeoJSON FeatureCollection. Release with mbl_string_free; NULL on
// failure.
FFI_PLUGIN_EXPORT char *mbl_map_get_cluster_children(MblMap *map,
                                                     const char *source_id,
                                                     uint32_t cluster_id,
                                                     uint32_t timeout_ms);

// The original points under a cluster, however deep, as a GeoJSON
// FeatureCollection. `limit` caps how many come back and `offset` pages through
// them — a cluster can stand for a hundred thousand points, so there is no
// "all" form. Release with mbl_string_free; NULL on failure.
FFI_PLUGIN_EXPORT char *mbl_map_get_cluster_leaves(MblMap *map,
                                                   const char *source_id,
                                                   uint32_t cluster_id,
                                                   uint32_t limit,
                                                   uint32_t offset,
                                                   uint32_t timeout_ms);

// --- Feature state -----------------------------------------------------------
//
// Per-feature data held OUTSIDE the tile, readable from a style expression with
// ["feature-state", "<key>"] — gl-js setFeatureState, mbgl Renderer::
// setFeatureState (renderer/renderer.hpp:74-86). This is how hover and
// selection are done without re-uploading a source: set a key, and a paint
// property that reads it repaints just that feature.
//
// **IT ONLY WORKS ON FEATURES WITH THEIR OWN ID.** The style spec has
// `promoteId` (and `generateId`) for sources whose features carry their
// identity in a property instead, and mbgl implements NEITHER — grep the pinned
// submodule for "promoteId" and there are no hits outside the spec JSON. So a
// GeoJSON feature needs a top-level "id", and a vector feature needs an id in
// the MVT. Setting state for an id no feature has is silently a no-op: mbgl
// stores it against that id and nothing ever reads it.

// Attach state to one feature. `state_json` is a JSON OBJECT, merged into any
// state already there (gl-js semantics), so setting one key leaves the others.
// `source_layer` is required for a vector source and may be NULL for a geojson
// one. Asynchronous; a bad `state_json` reports on the diagnostic callback.
FFI_PLUGIN_EXPORT void mbl_map_set_feature_state(MblMap *map,
                                                 const char *source_id,
                                                 const char *source_layer,
                                                 const char *feature_id,
                                                 const char *state_json);

// One feature's state as a JSON object, `{}` when it has none. Release with
// mbl_string_free; NULL on timeout. BLOCKS up to `timeout_ms`.
FFI_PLUGIN_EXPORT char *mbl_map_get_feature_state(MblMap *map,
                                                  const char *source_id,
                                                  const char *source_layer,
                                                  const char *feature_id,
                                                  uint32_t timeout_ms);

// Remove state. NULL `state_key` clears the whole feature's state; NULL
// `feature_id` clears every feature's state in the source (or source layer) —
// the same widening gl-js `removeFeatureState` does with omitted arguments.
FFI_PLUGIN_EXPORT void mbl_map_remove_feature_state(MblMap *map,
                                                    const char *source_id,
                                                    const char *source_layer,
                                                    const char *feature_id,
                                                    const char *state_key);

// Frees a string returned by this library (e.g. from
// mbl_map_query_rendered_features).
FFI_PLUGIN_EXPORT void mbl_string_free(char *s);

// The projection generation of the frame most recently PUBLISHED (i.e. the one
// the compositor is showing). Camera commands are applied asynchronously on the
// render thread, so the newest transform usually runs ahead of the visible
// frame; projecting anchored widgets against this generation instead keeps them
// locked to the map through pan/zoom rather than lagging it. 0 before the first
// frame.
FFI_PLUGIN_EXPORT uint64_t mbl_map_presented_generation(MblMap *map);

// The current projection generation: a counter bumped on every camera/size
// change. Lets a caller cheaply detect whether a reprojection is needed. 0
// before the first snapshot.
FFI_PLUGIN_EXPORT uint64_t mbl_map_proj_generation(MblMap *map);

// Register (or clear, with NULL) the frame-ready callback. See MblFrameCallback.
FFI_PLUGIN_EXPORT void mbl_map_set_frame_callback(MblMap *map,
                                                  MblFrameCallback callback,
                                                  void *user);

// Block up to `timeout_ms` until at least one frame has been rendered. Returns 1
// if a frame is available, 0 on timeout. Intended for headless/test use and for
// an initial readiness wait — not for the per-frame present path.
FFI_PLUGIN_EXPORT int mbl_map_await_frame(MblMap *map, uint32_t timeout_ms);

// Copy the latest rendered frame as tightly-packed BGRA (premultiplied alpha)
// into `dst` (capacity `dst_capacity` bytes); non-blocking. BGRA matches the
// macOS CVPixelBuffer format so the texture bridge needs no swizzle. Writes the
// frame dimensions/row stride to the (nullable) out params. Returns 1 on success,
// 0 if no frame yet or the buffer is too small. Safe to call from the raster
// thread (the plugin calls it from copyPixelBuffer).
//
// A null `dst` is "query mode": it writes the current frame dimensions/stride
// and returns 1 (if a frame exists) without copying — lets the caller size a
// destination buffer first, so the texture can follow resizes automatically.
FFI_PLUGIN_EXPORT int mbl_map_copy_frame(MblMap *map, uint8_t *dst,
                                         size_t dst_capacity,
                                         uint32_t *out_width,
                                         uint32_t *out_height,
                                         uint32_t *out_stride);

// Enable (1) or disable (0) zero-copy presentation. When enabled, each render
// GPU-blits mbgl's rendered frame into a shared texture (no CPU readback): on macOS
// an IOSurface-backed BGRA texture (mbl_map_current_iosurface), on Linux/desktop GL
// an EGLImage-backed RGBA texture exposed via mbl_map_current_gl_image. A no-op
// (the CPU mbl_map_copy_frame path stays in use) if the platform helper can't
// initialise. Off by default. Call before or during use; takes effect next render.
FFI_PLUGIN_EXPORT void mbl_map_set_zero_copy(MblMap *map, int enabled);

// Select the byte order mbl_map_copy_frame writes: 1 = BGRA (default; matches the
// macOS CVPixelBuffer), 0 = RGBA (e.g. Linux FlPixelBufferTexture). mbgl renders
// RGBA, so BGRA costs a per-pixel swizzle and RGBA is a straight copy. Set once at
// setup; does not affect the zero-copy/IOSurface path (always BGRA).
FFI_PLUGIN_EXPORT void mbl_map_set_pixel_format_bgra(MblMap *map, int bgra);

// Return the IOSurface (as an opaque pointer; an IOSurfaceRef on macOS) backing
// the latest zero-copy frame, or NULL if zero-copy is off or no frame exists yet.
// The macOS plugin wraps it in a CVPixelBuffer for the texture with no copy. The
// surface is owned by the map and reused across frames (a small ring), so read it
// promptly from the present path. Safe to call from the raster thread.
FFI_PLUGIN_EXPORT void *mbl_map_current_iosurface(MblMap *map);

// A zero-copy GL frame published as a Linux dmabuf — a kernel buffer fd that is
// shareable ACROSS EGLDisplays/contexts (mbgl's render context and Flutter's raster
// context use different displays, so an EGLImage handle cannot cross between them; a
// dmabuf can). The plugin imports this into Flutter's context via
// EGL_LINUX_DMA_BUF_EXT. `fd` is process-wide and owned by the core (the plugin must
// NOT close it). `fd < 0` means "no frame".
typedef struct MblGlDmabufFrame {
  int32_t fd;          // dmabuf file descriptor (process-wide; core owns it)
  uint32_t fourcc;     // DRM FourCC pixel format
  uint32_t stride;     // plane-0 row pitch in bytes
  uint32_t offset;     // plane-0 byte offset
  uint64_t modifier;   // DRM format modifier (DRM_FORMAT_MOD_INVALID if none)
  uint64_t generation; // bumped on resize (the fd changes); for the plugin's cache
  uint32_t ring_index; // which ring slot (0..N-1)
  uint32_t width;
  uint32_t height;
} MblGlDmabufFrame;

// Latest zero-copy GL frame for the Linux FlTextureGL present (called by address
// from the plugin's populate callback on the raster thread). Fills *out with the
// current dmabuf descriptor and returns 1 if a zero-copy GL frame is available, 0
// otherwise (zero-copy off, no frame yet, tearing down, or non-Linux). Reads only
// mutex-guarded state — no GL/EGL calls — so it is safe on the raster thread.
FFI_PLUGIN_EXPORT int mbl_map_current_gl_image(MblMap *map,
                                               MblGlDmabufFrame *out);

// Non-zero (1) if the GL zero-copy presenter is live (its dmabuf exporter
// initialised), 0 otherwise. Lets the plugin/Dart confirm zero-copy actually
// activated before committing to the FlTextureGL path. 0 on non-Linux.
FFI_PLUGIN_EXPORT int mbl_map_gl_active(MblMap *map);

// Windows D3D11 zero-copy: the latest frame published as a DXGI shared handle (a
// legacy IDXGIResource::GetSharedHandle from a shared D3D11 texture). The Windows
// plugin hands it to a Flutter GpuSurfaceTexture (DxgiSharedHandle), which ANGLE
// re-opens on Flutter's device via EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE. Fills
// *out_handle and the (nullable) size out params and returns 1 if a zero-copy D3D
// frame is available, 0 otherwise (zero-copy off, no frame yet, tearing down, or
// non-Windows). Reads only mutex-guarded state — no D3D/GL/EGL calls — so it is
// safe on the raster thread.
FFI_PLUGIN_EXPORT int mbl_map_current_d3d_handle(MblMap *map, void **out_handle,
                                                 uint32_t *out_width,
                                                 uint32_t *out_height);

// Non-zero (1) if the D3D11 zero-copy presenter is live, 0 otherwise. Lets the
// plugin/Dart confirm zero-copy activated before committing to the
// GpuSurfaceTexture path. 0 on non-Windows.
FFI_PLUGIN_EXPORT int mbl_map_d3d_active(MblMap *map);

// --- 3D models (SPIKE — not a stable API) ------------------------------------
//
// EXPERIMENTAL. Draws an animated 3D mesh inside mbgl, anchored to a LatLng, via
// mbgl::style::CustomDrawableLayer. Present only to answer two questions that
// cannot be settled by reading source: whether a custom drawable renders at all
// under Metal + CORE_ONLY + our headless frontend, and whether it depth-occludes
// against fill-extrusion buildings. Expect this surface to be replaced by a real
// model API (mesh + texture supplied by the caller) before it ships.

// Load a binary glTF (.glb) from `glb_path` and draw it at `lat`/`lng` as a
// layer named `layer_id` (re-using an id replaces the previous model).
//
// `scale` multiplies the model's own units, so 1.0 renders a glTF authored in
// metres at life size; the model then keeps its ground footprint across zooms.
// `heading_deg` yaws it clockwise from north (a glTF's -Z "forward" faces north
// at 0); `spin_dps` adds a continuous yaw on top, in degrees per second (0 =
// static).
//
// Returns 1 on success, 0 on failure, writing a NUL-terminated reason into
// `out_error` (if non-NULL, truncated to `error_capacity`). The FILE IS PARSED
// SYNCHRONOUSLY on the calling thread — only the GPU upload is deferred to the
// render thread — which is what lets parse errors be reported here rather than
// vanishing into a log. Expect it to block for the duration of a file read.
//
// Supported subset (bounded by what mbgl's CustomGeometryShader can draw):
// triangles, POSITION + TEXCOORD_0, node transforms baked in, all primitives
// merged, the first base-colour texture and factor used. No skins/animations, no
// Draco/meshopt, no external buffers or images (GLB only), and at most 65535
// vertices because mbgl's indices are uint16. There is no lighting, so bake it
// into the texture. See docs/3d-models-research.md.
//
// Call after the style has loaded. A subsequent mbl_map_set_style replaces the
// style and drops every custom layer, but this shim retains the model and
// re-adds it, so a style change does not lose it.
//
// `layer_id` IS NOT the style-layer id. The layer is created as
// "mbl:model:<layer_id>", in a namespace of its own, so a model can never
// collide with a layer the app added by the same name — mbl_map_remove_model
// used to be able to delete an unrelated style layer, and mbl_map_remove_layer
// used to leave the model's retention behind so the next style load brought it
// back. Pass the plain id to every mbl_map_*_model call; the prefixed form is
// what mbl_map_get_layer_ids reports and what mbl_map_move_layer takes.
FFI_PLUGIN_EXPORT int mbl_map_add_model(MblMap *map, const char *layer_id,
                                        const char *glb_path, double lat,
                                        double lng, double scale,
                                        double heading_deg, double spin_dps,
                                        double elevation_m, char *out_error,
                                        size_t error_capacity);

// Move/re-orient an existing model WITHOUT touching its uploaded geometry.
//
// This is the only sane way to animate a model along a path: re-adding it would
// re-read and re-parse the whole .glb every frame (tens of megabytes for a real
// model). Asynchronous, and a no-op if `layer_id` names no model.
//
// `elevation_m` lifts the model off the ground. A model whose base sits exactly
// at z=0 is coplanar with the basemap's ground geometry and z-fights, so the map
// bleeds through the bodywork; a few centimetres resolves it.
FFI_PLUGIN_EXPORT void mbl_map_set_model_transform(MblMap *map,
                                                   const char *layer_id,
                                                   double lat, double lng,
                                                   double scale,
                                                   double heading_deg,
                                                   double elevation_m);

// Total frames the RENDER THREAD has published since creation.
//
// This is mbgl's actual frame production rate, which is the number that matters
// for "is the map keeping up". A Flutter Ticker measures FLUTTER's vsync instead,
// and because the map is composited as a Texture, Flutter's UI thread stays
// pinned at the display rate no matter how far behind the map falls — so a
// Ticker-based counter reads a flat 60 while the map visibly stutters.
//
// Sample it once a second and difference it to get map fps. Cheap and lock-free
// enough to poll; safe from any thread.
FFI_PLUGIN_EXPORT uint64_t mbl_map_frame_count(MblMap *map);

// How many drawables (draw calls) one instance of the model at `glb_path` costs,
// or 0 if it has not been loaded. Reads the parsed-mesh cache, so it is only
// meaningful after a successful mbl_map_add_model. Exists so a caller can report
// real draw-call counts instead of guessing from primitive counts.
FFI_PLUGIN_EXPORT uint32_t mbl_model_part_count(const char *glb_path);

// Remove a model layer added by mbl_map_add_model. Takes the PLAIN id (see
// mbl_map_add_model), and drops the retention even when the style layer is
// already gone. A no-op if `layer_id` names
// no layer. Asynchronous (applied on the render thread).
FFI_PLUGIN_EXPORT void mbl_map_remove_model(MblMap *map, const char *layer_id);

// Add the built-in test model — a spinning, per-face-coloured pyramid — at
// `lat`/`lng`. `metres_per_unit` sizes it in real-world metres (the mesh spans 2
// units in X, 1 in Y, 1.5 in Z, so 50 gives a 100m x 50m footprint 75m tall).
// `spin_dps` is the rotation rate in degrees per second (0 = static).
//
// Kept as a dependency-free regression: viewed top-down it must read as a
// four-colour pinwheel (red north, green east, blue south, yellow west), which
// catches anchor mirroring, a flipped up-axis, inverted winding, and depth that
// has silently degraded to painter's order.
//
// `layer_id` may be NULL, meaning "mbl-test-model". As with mbl_map_add_model
// it is the PLAIN id — the layer lands at "mbl:model:<layer_id>".
//
// Asynchronous — the layer is added on the render thread.
FFI_PLUGIN_EXPORT void mbl_map_add_test_model(MblMap *map, const char *layer_id,
                                              double lat,
                                              double lng,
                                              double metres_per_unit,
                                              double spin_dps,
                                              double elevation_m);

// Ask mbgl for one more frame. Continuous mode is update-driven, not
// vsync-driven: with nothing invalidating the map, an animated layer renders
// once and stops. Anything driving an animation must pump this (a Dart Ticker,
// or the harness loop). No-op in Static mode, which never animates.
FFI_PLUGIN_EXPORT void mbl_map_trigger_repaint(MblMap *map);

// Debug/verification: encode the latest frame to a PNG file at `path` using
// mbgl's own PNG encoder. Returns 1 on success, 0 if no frame or the write failed.
FFI_PLUGIN_EXPORT int mbl_map_write_png(MblMap *map, const char *path);

// Stop the render thread and free all resources. The handle is invalid after.
FFI_PLUGIN_EXPORT void mbl_map_destroy(MblMap *map);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // MAPLIBRE_FLUTTER_CORE_H
