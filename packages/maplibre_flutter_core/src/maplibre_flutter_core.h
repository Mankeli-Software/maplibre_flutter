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
FFI_PLUGIN_EXPORT char *mbl_map_query_rendered_features(
    MblMap *map, double min_x, double min_y, double max_x, double max_y,
    const char *layer_ids, uint32_t timeout_ms);

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
// Call after the style has loaded — a subsequent mbl_map_set_style REPLACES the
// style and drops the layer.
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

// Remove a model layer added by mbl_map_add_model. A no-op if `layer_id` names
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
// Asynchronous — the layer is added on the render thread.
FFI_PLUGIN_EXPORT void mbl_map_add_test_model(MblMap *map, double lat,
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
