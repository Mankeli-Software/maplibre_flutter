import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/geojson.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:meta/meta.dart';

import 'style/style.dart';
import 'style/style_encoding.dart';

/// One feature the engine drew.
///
/// Renamed to [QueriedFeature], which mirrors gl-js's `MapGeoJSONFeature` and
/// carries the full [GeoJsonFeature.geometry] and [GeoJsonFeature.id] this type
/// never had.
///
/// One source-compatibility note: [QueriedFeature.point] is now `LatLng?`,
/// because a line or polygon feature has no single point — it used to be
/// non-null only because every non-point geometry was silently dropped.
@Deprecated(
  'Renamed to QueriedFeature (gl-js MapGeoJSONFeature). Note that .point is '
  'now nullable, since non-point geometries are no longer dropped. '
  'Will be removed in a future release.',
)
@Deprecated(
  'Renamed to QueriedFeature, after gl-js MapGeoJSONFeature. The MapLibre '
  'prefix belongs on types an app constructs, not on a value the engine hands '
  'back. Will be removed in a future release.',
)
typedef MapLibreQueriedFeature = QueriedFeature;

/// Engine-drawn map data: the scalable half of the annotation story.
///
/// Reach for this when there are more points than widgets can carry. The rule of
/// thumb from this repo's own measurements (macOS release):
///
/// * **Widget markers** (`MapLibreMap.markers`) — real Flutter widgets, so they
///   can animate, hold gestures and contain anything. Smooth to roughly a few
///   hundred rich children; each costs a render object painted every camera tick.
/// * **Engine layers** (this class) — drawn by mbgl with the map, so they are
///   glued to it by construction and scale to the hundreds of thousands, with
///   clustering built in. In exchange they are pictures: no child gestures, no
///   per-marker animation.
///
/// The two compose. The usual shape is bulk data here, and a handful of widget
/// markers for the things that must be live.
///
/// Reached from the app-facing controller as `controller.style`. Only available
/// on renderers that can do it (the `mbgl-core` tiers); [isSupported] tells you.
///
/// **Named for what it is.** This object owns sources, images and the
/// style-wide transition as well as layers — it is Apple's `MLNStyle`, whose
/// `sources` / `layers` / `-setImage:forName:` / `transition` it mirrors — so
/// `layers` was a misnomer that would only get worse as `getSource`, `hasImage`
/// and `listImages` land on it. `controller.style` does not conflict with the
/// rule against a public `controller.setStyle`: that rule is about the style
/// DOCUMENT being a widget property, and a namespace is not a setter.
class MapLibreStyleController {
  MapLibreStyleController();

  MapLibreStyleLayers? _layers;

  /// Sources this controller added, id -> the document to re-add.
  ///
  /// The DOCUMENT is kept, not just the id, because **mbgl sources cannot be
  /// serialised**: `Layer` has `serialize()` and `Source` has nothing, so
  /// `getSourceJson` can only report a descriptor (id, type, attribution,
  /// volatile) — enough for [getSource]'s handle, not enough to re-add. So a
  /// source is replayed from what the app passed, kept current by
  /// [setSourceData], which is the only mutation this API offers on one.
  ///
  /// That is why sources and layers are retained by different mechanisms: each
  /// uses the only faithful one available to it. It also means a retained
  /// GeoJSON source is held twice, here and in the engine — one reason
  /// [retainRuntimeStyle] is opt-in.
  final Map<String, String> _addedSources = <String, String>{};

  /// Layer ids this controller added, in the order it added them. Insertion
  /// order matters: layers are re-added in it, so the app's own draw order
  /// survives even though the snapshot cannot preserve `beforeId`.
  final List<String> _addedLayerIds = <String>[];

  /// Taken just before a style swap, replayed just after. Null when there is
  /// nothing in flight.
  ({List<(String, String)> sources, List<String> layers})? _snapshot;

  /// Whether to carry app-added sources and layers across a style change.
  ///
  /// Set from [MapLibreMap.retainRuntimeStyle]; see that property for what this
  /// costs you and when NOT to use it.
  @internal
  bool retainRuntimeStyle = false;

  /// Records a layer id, so [snapshotForRetain] can serialise it.
  void _trackLayer(String? id) {
    if (id == null || id.isEmpty || _addedLayerIds.contains(id)) return;
    _addedLayerIds.add(id);
  }

  /// Pulls the `id` out of a style-spec layer document.
  static String? _layerIdOf(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is Map<String, Object?> ? decoded['id'] as String? : null;
    } on FormatException {
      // addLayerJson itself reports the parse failure; nothing to track.
      return null;
    }
  }

  /// Serialises every app-added source and layer as it stands RIGHT NOW.
  ///
  /// Called by the controller immediately before it pushes a new style — which
  /// is the only moment this can work. The style-loaded event fires after
  /// `Style::Impl::parse()` has already dropped everything, so a snapshot taken
  /// then would find nothing; and replaying the JSON the app originally passed
  /// to [addLayerJson] would silently lose every [setPaintProperty],
  /// [setFilter] and [setLayerZoomRange] applied since. `Layer::serialize()`
  /// returns the LIVE state, which is what makes this faithful rather than
  /// approximate.
  @internal
  void snapshotForRetain() {
    if (!retainRuntimeStyle || _layers == null) return;
    // Sources come from what the app gave us (see [_addedSources]); only layers
    // can be read back out of the engine.
    final sources = [
      for (final entry in _addedSources.entries) (entry.key, entry.value),
    ];
    final layers = <String>[];
    for (final id in _addedLayerIds) {
      final json = _layers?.getLayerJson(id);
      if (json != null) layers.add(json);
    }
    _snapshot = (sources: sources, layers: layers);
  }

  /// Puts the snapshot back, once the new style has loaded.
  @internal
  void replayRetained() {
    final snapshot = _snapshot;
    _snapshot = null;
    if (snapshot == null || _layers == null) return;
    // Sources first: a layer referencing a source that is not there yet is
    // rejected outright, and reports on controller.onError.
    for (final (id, json) in snapshot.sources) {
      _layers?.addSourceJson(id, json);
    }
    // Layers on TOP of the new document, in their original relative order.
    // `beforeId` is deliberately not restored: it named a layer in the OUTGOING
    // document, which may not exist in the incoming one, and an unresolvable
    // beforeId is an error rather than a fallback. Sitting on top is the
    // predictable choice; an app that needs its layers interleaved with the new
    // basemap has to do that itself from onStyleLoaded, where it knows what the
    // new document contains.
    for (final json in snapshot.layers) {
      _layers?.addLayerJson(json);
    }
  }

  /// Whether the bound renderer can draw engine layers at all. False before the
  /// map attaches, and on renderers without the capability — every method below
  /// is a no-op in that case, so feature-detecting is optional.
  bool get isSupported => _layers != null;

  /// The projector, when the tier has one. Only [queryRenderedFeaturesIn] needs
  /// it — a geographic box has to become a screen box before the engine, whose
  /// query is screen-space, can answer it.
  MapLibreMapProjector? _projector;

  /// Binds the platform controller (called by the widget on attach).
  @internal
  void attachTo(Object? platform) {
    _layers = platform is MapLibreStyleLayers ? platform : null;
    _projector = platform is MapLibreMapProjector ? platform : null;
  }

  // --- Typed style-spec access ------------------------------------------------
  // Generated from the MapLibre Style Spec vendored in the mbgl-core submodule
  // (`tool/generate_style_api.dart`), so it tracks the pinned core version.
  // Serialises to the JSON methods below — there is no separate transport.
  //
  // Coverage is the whole spec: every layer type, every source type, every
  // expression operator, all discovered from the spec rather than listed by
  // hand. The JSON methods stay public as the hatch for anything the spec does
  // not describe.

  /// Adds a typed style [layer]; [beforeId] inserts beneath an existing layer.
  ///
  /// ```dart
  /// controller.layers.addLayer(
  ///   CircleLayer(
  ///     id: 'pts',
  ///     source: 'pts',
  ///     circleRadius: const StyleValue(6),
  ///     circleColor: Expr.get('color'),
  ///   ),
  /// );
  /// ```
  void addLayer(StyleLayer layer, {String? beforeId}) =>
      addLayerJson(jsonEncode(layer.toJson()), beforeId: beforeId);

  /// Adds a typed style [source] under [id].
  void addSource(String id, StyleSource source) =>
      addSourceJson(id, jsonEncode(source.toJson()));

  // --- Raw style-spec access --------------------------------------------------
  // MapLibre Style Spec JSON, the same documents maplibre-gl-js takes. This is
  // the full-power escape hatch, and stays public: every layer type, every
  // expression, anything the typed API above does not cover yet.

  /// Adds a style source under [id]. Throws [ArgumentError] on invalid JSON.
  void addSourceJson(String id, String json) {
    _addedSources[id] = json;
    _layers?.addSourceJson(id, json);
  }

  /// Adds a style layer; [beforeId] inserts beneath an existing layer.
  void addLayerJson(String json, {String? beforeId}) {
    _trackLayer(_layerIdOf(json));
    _layers?.addLayerJson(json, beforeId: beforeId);
  }

  /// Replaces a source's data — the cheap path for live datasets.
  ///
  /// gl-js spells this `getSource(id).setData(...)`, and [getSource] gives you
  /// that shape; this is the flat form underneath. Only a GeoJSON source can
  /// have its data replaced (mbgl has no setter on a vector or raster one), and
  /// asking for anything else reports on `controller.onError`.
  void setSourceData(String sourceId, Object data) {
    final encoded = data is String ? data : jsonEncode(encodeStyleJson(data));
    _rememberSourceData(sourceId, encoded);
    _layers?.setSourceData(sourceId, encoded);
  }

  /// Folds a data replacement into the retained document.
  ///
  /// Without this a replay restores the data the source was CREATED with, which
  /// on a live dataset means silently rewinding it — the worst kind of bug,
  /// because the map still draws.
  void _rememberSourceData(String sourceId, String data) {
    final retained = _addedSources[sourceId];
    if (retained == null) return;
    try {
      final decoded = jsonDecode(retained);
      if (decoded is! Map<String, Object?>) return;
      decoded['data'] = jsonDecode(data);
      _addedSources[sourceId] = jsonEncode(decoded);
    } on FormatException {
      // Either document is already invalid; the engine call reports that.
    }
  }

  /// Replaces a geojson source's data.
  @Deprecated(
    'Renamed to setSourceData: the verb should not bake in the format, which '
    'reads wrong the moment an image or computed source needs an equivalent. '
    'Will be removed in a future release.',
  )
  void setGeoJsonData(String sourceId, String geoJson) =>
      setSourceData(sourceId, geoJson);

  /// A handle to one source — gl-js `map.getSource(id)`.
  ///
  /// Null when the source does not exist. The handle is a thin view, not a
  /// snapshot: [MapLibreSource.setData] talks to the live map.
  MapLibreSource? getSource(String sourceId) {
    final json = _layers?.getSourceJson(sourceId);
    if (json == null) return null;
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) return null;
    return MapLibreSource._(
      this,
      id: sourceId,
      type: decoded['type'] as String? ?? 'unknown',
      attribution: decoded['attribution'] as String?,
      isVolatile: decoded['volatile'] as bool? ?? false,
    );
  }

  /// The style's source ids — the read side [getSource] iterates.
  List<String> getSourceIds() => _layers?.getSourceIds() ?? const [];

  void removeLayer(String id) {
    // Stop tracking FIRST, or a retained replay resurrects what the app removed.
    _addedLayerIds.remove(id);
    _layers?.removeLayer(id);
  }

  // --- Per-property mutation --------------------------------------------------
  //
  // gl-js splits this into setPaintProperty / setLayoutProperty / setFilter /
  // setLayerZoomRange, so those names are here — but they are ONE engine call.
  // `Layer::setProperty` dispatches to the generated paint/layout setters and
  // then handles visibility, minzoom, maxzoom and filter itself, so the C ABI
  // needed no split at all.
  //
  // Before this, changing one property meant removing the layer and adding it
  // back.

  /// Sets a paint property — gl-js `setPaintProperty`.
  ///
  /// ```dart
  /// controller.style.setPaintProperty('dots', 'circle-color', Colors.teal);
  /// controller.style.setPaintProperty(
  ///   'dots', 'circle-radius', Expr.get('magnitude'),
  /// );
  /// ```
  ///
  /// [value] is anything the typed style API accepts — a constant, a [Color],
  /// an [Expression] — encoded by the same serialiser the layer classes use, so
  /// there is no second encoder to drift.
  void setPaintProperty(String layerId, String name, Object? value) =>
      _setProperty(layerId, name, value);

  /// Sets a layout property — gl-js `setLayoutProperty`. Same call underneath
  /// as [setPaintProperty]; the split is gl-js's, not the engine's.
  void setLayoutProperty(String layerId, String name, Object? value) =>
      _setProperty(layerId, name, value);

  /// Shows or hides a layer — the `visibility` layout property.
  void setLayerVisible(String layerId, {required bool visible}) =>
      _setProperty(layerId, 'visibility', visible ? 'visible' : 'none');

  /// Replaces a layer's filter — gl-js `setFilter`. Pass null to clear it.
  void setFilter(String layerId, Expression? filter) =>
      _setProperty(layerId, 'filter', filter);

  /// The zoom range a layer draws in — gl-js `setLayerZoomRange`.
  void setLayerZoomRange(String layerId, {double? minZoom, double? maxZoom}) {
    if (minZoom != null) _setProperty(layerId, 'minzoom', minZoom);
    if (maxZoom != null) _setProperty(layerId, 'maxzoom', maxZoom);
  }

  /// Moves [layerId] beneath [beforeId], or to the top when [beforeId] is null
  /// — gl-js `moveLayer`.
  ///
  /// Cheap: the engine hands the layer object between positions rather than
  /// rebuilding it, so nothing is re-parsed or re-uploaded.
  void moveLayer(String layerId, {String? beforeId}) =>
      _layers?.moveLayer(layerId, beforeId: beforeId);

  void _setProperty(String layerId, String name, Object? value) => _layers
      ?.setLayerProperty(layerId, name, jsonEncode(encodeStyleJson(value)));

  // --- The read side ----------------------------------------------------------
  //
  // There was none at all before this: you could add a layer and never ask the
  // engine anything about it again.

  /// One paint property as decoded JSON, or null if the layer or property does
  /// not exist — gl-js `getPaintProperty`.
  ///
  /// **The engine's NORMALISED form comes back, not what you set.** A colour
  /// returns as `['rgba', r, g, b, a]` with doubles whatever notation set it,
  /// and numbers return as doubles. Round-tripping a read straight into a write
  /// is fine; comparing it to your input string is not.
  Object? getPaintProperty(String layerId, String name) =>
      _decodeProperty(layerId, name);

  /// One layout property — gl-js `getLayoutProperty`. Same call as
  /// [getPaintProperty]; see it for the normalisation caveat.
  Object? getLayoutProperty(String layerId, String name) =>
      _decodeProperty(layerId, name);

  /// A layer's filter as decoded JSON — gl-js `getFilter`.
  Object? getFilter(String layerId) => _decodeProperty(layerId, 'filter');

  /// The style's layer ids, bottom-most first — gl-js `getLayersOrder`.
  ///
  /// Includes the basemap's own layers, which is what makes it useful for
  /// picking a `beforeId`.
  List<String> getLayersOrder() => _layers?.getLayerIds() ?? const [];

  /// One layer's full style-spec document, decoded — gl-js `getLayer`.
  ///
  /// Read from the LIVE layer (`Layer::serialize()`), so it reflects everything
  /// set since it was added. `Style::getJSON()` would not: that returns the
  /// document as it was loaded.
  Map<String, Object?>? getLayer(String layerId) {
    final json = _layers?.getLayerJson(layerId);
    if (json == null) return null;
    final decoded = jsonDecode(json);
    return decoded is Map<String, Object?> ? decoded : null;
  }

  Object? _decodeProperty(String layerId, String name) {
    final json = _layers?.getLayerProperty(layerId, name);
    if (json == null) return null;
    try {
      return jsonDecode(json);
    } on FormatException {
      return null;
    }
  }

  void removeSource(String id) {
    _addedSources.remove(id);
    _layers?.removeSource(id);
  }

  /// Registers an icon (raw premultiplied RGBA) for `icon-image`. See
  /// [addWidgetIcon] to build one from a Flutter widget.
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) => _layers?.addImage(
    id,
    rgba,
    width,
    height,
    pixelRatio: pixelRatio,
    sdf: sdf,
  );

  void removeImage(String id) => _layers?.removeImage(id);

  /// Replaces an image already registered under [id] — gl-js `updateImage`.
  ///
  /// The same call as [addImage]: mbgl's own comment on `Style::Impl::addImage`
  /// is "We permit using addImage to update", so this is a name rather than a
  /// second code path. It exists because reaching for `addImage` to *change*
  /// something reads like a mistake.
  void updateImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) => addImage(id, rgba, width, height, pixelRatio: pixelRatio, sdf: sdf);

  /// Whether the style has an image called [id] — gl-js `hasImage`.
  ///
  /// Null when the engine could not answer in time, which is deliberately NOT
  /// false: code deciding whether to register an image needs "could not ask" to
  /// be distinguishable from "not there", or it will re-rasterise on every
  /// hiccup.
  bool? hasImage(String id) => _layers?.hasImage(id);

  /// Every image id in the style — gl-js `listImages`.
  ///
  /// Includes the style's OWN sprite images, not just ones this API added,
  /// which is what makes it useful for finding an icon name to reuse.
  List<String> listImages() => _layers?.getImageIds() ?? const [];

  /// Style-wide transition behaviour.
  ///
  /// The reason this is exposed: **symbol layers fade, circle layers do not.**
  /// When a clustered source re-clusters, a cluster's circle stops being drawn
  /// on the next frame while its count label ramps its opacity down over
  /// [duration] (300 ms by default), so the number appears to hang in the air
  /// for a few frames after its bubble has gone.
  ///
  /// Two ways to deal with that, and the gentler one is usually right:
  ///
  /// ```dart
  /// // Keeps every fade, shrinks the mismatch to a couple of frames.
  /// layers.setTransitionOptions(duration: const Duration(milliseconds: 80));
  ///
  /// // Removes it entirely — see the caveat below.
  /// layers.setTransitionOptions(placementTransitions: false);
  /// ```
  ///
  /// [placementTransitions] `false` makes symbols appear and disappear
  /// instantly, but it is a property of the **style**, not of one layer, so the
  /// basemap's own labels stop fading as well — they pop in and out while
  /// panning. Shortening [duration] avoids that, and only shortens the fade:
  /// mbgl clamps how often it recomputes placement at `max(300ms, duration)`.
  ///
  /// [duration] also governs paint-property transitions, and [delay] their
  /// start; null leaves the style document's own values. Both survive a style
  /// change (which would otherwise reset them), and apply to the continuous
  /// render mode only.
  ///
  /// Defaults are the engine's own behaviour, which is also what
  /// maplibre-gl-js does (its `fadeDuration`).
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions = true,
  }) => _layers?.setTransitionOptions(
    duration: duration,
    delay: delay,
    placementTransitions: placementTransitions,
  );

  // --- Queries ----------------------------------------------------------------

  /// The features the engine actually drew inside [rect] (logical pixels in the
  /// map widget's own coordinate space).
  ///
  /// This is how you find out what is on screen without duplicating the
  /// engine's work. On a clustered source it returns the **clusters**
  /// themselves — each with [QueriedFeature.pointCount] and the position mbgl
  /// placed it at — so cluster bubbles can be drawn as Flutter widgets over the
  /// top, or hit-tested for a tap, without reimplementing clustering in Dart.
  ///
  /// Every geometry type comes back, so a fill or line layer answers as well as
  /// a circle one; reach for [QueriedFeature.point] when you know it is a point
  /// and [GeoJsonFeature.geometry] otherwise.
  ///
  /// Empty when nothing matched, and when the renderer is unavailable or the
  /// query timed out — those cases are not distinguished today. Restrict to
  /// specific [layerIds] to keep results small; that is also the only way to
  /// learn which layer a feature came from, because mbgl flattens its
  /// per-layer results before returning them.
  ///
  /// Mirrors gl-js `map.queryRenderedFeatures(geometry?, options?)` and Apple's
  /// `-visibleFeaturesInRect:` (`MLNMapView.h`).
  ///
  /// [filter] is a style-spec expression evaluated INSIDE the engine, so it is
  /// cheaper than fetching everything and filtering in Dart, and it can reach
  /// feature properties that never cross the boundary.
  ///
  /// **Best-effort by design.** A failed or timed-out query returns `const []`,
  /// the same as "nothing there". That is deliberate: this runs on camera ticks
  /// and must not throw into a paint callback. When you need to tell the two
  /// apart, use [queryRenderedFeaturesAsync], which reports failure as an
  /// error on the Future.
  List<QueriedFeature> queryRenderedFeatures(
    Rect rect, {
    List<String>? layerIds,
    Expression? filter,
  }) {
    final json = _layers?.queryRenderedFeaturesJson(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
      layerIds: layerIds,
      filterJson: _filterJson(filter),
    );
    if (json == null || json.isEmpty) return const [];
    // Runs on camera ticks, so this must not throw into its caller — and that
    // promise only holds because every read below is checked. Unchecked casts
    // throw TypeError, which `on FormatException` would not have caught.
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map<String, Object?>) return const [];
    final features = decoded['features'];
    if (features is! List<Object?>) return const [];
    final out = <QueriedFeature>[];
    for (final f in features) {
      if (f is! Map<String, Object?>) continue;
      try {
        out.add(QueriedFeature.fromJson(f));
      } on FormatException {
        // One unreadable feature should not lose the rest of the frame's.
        continue;
      }
    }
    return out;
  }

  /// The features drawn at one screen POINT — gl-js
  /// `queryRenderedFeatures(point)`.
  ///
  /// [tolerance] grows the point into a box, in logical points. A literal
  /// zero-area query is technically valid and practically useless on touch:
  /// gl-js and both SDKs all pad a tap, and a 1 px box misses a 4 px circle the
  /// user was clearly aiming at.
  List<QueriedFeature> queryRenderedFeaturesAt(
    Offset point, {
    double tolerance = 8,
    List<String>? layerIds,
    Expression? filter,
  }) => queryRenderedFeatures(
    Rect.fromCircle(center: point, radius: tolerance),
    layerIds: layerIds,
    filter: filter,
  );

  /// The features drawn inside a geographic box.
  ///
  /// Needs a projector to turn the corners into screen space, so it returns
  /// `const []` on a tier without one. Note the box is the SCREEN-ALIGNED
  /// rectangle through the projected corners: under a bearing or a pitch that
  /// is a superset of the geographic bounds, never a subset, so nothing inside
  /// the bounds is missed.
  List<QueriedFeature> queryRenderedFeaturesIn(
    LatLngBounds bounds, {
    List<String>? layerIds,
    Expression? filter,
  }) {
    final rect = _projectBounds(bounds);
    if (rect == null) return const [];
    return queryRenderedFeatures(rect, layerIds: layerIds, filter: filter);
  }

  /// [queryRenderedFeatures] without blocking the UI isolate.
  ///
  /// The synchronous form waits on a render-thread round trip, which stalls
  /// frame production for as long as the render thread takes to get to it —
  /// fine for a one-off hit test, wrong for a query driven by the camera at
  /// frame rate, which is the usual reason to run one.
  ///
  /// **Throws [MapQueryException] when the query could not be answered**, which
  /// is the difference from the synchronous form: there, failure and "nothing
  /// found" are both `const []`.
  Future<List<QueriedFeature>> queryRenderedFeaturesAsync(
    Rect rect, {
    List<String>? layerIds,
    Expression? filter,
  }) async {
    final layers = _layers;
    if (layers == null) {
      throw const MapQueryException('this renderer cannot query features');
    }
    final json = await layers.queryRenderedFeaturesAsyncJson(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
      layerIds: layerIds,
      filterJson: _filterJson(filter),
    );
    if (json == null || json.isEmpty) {
      throw const MapQueryException(
        'the engine did not answer the query — it was busy, or the map is gone',
      );
    }
    return _parseFeatures(json);
  }

  /// Features in a source's LOADED TILES, drawn or not — gl-js
  /// `querySourceFeatures`.
  ///
  /// This answers "what data is loaded here", not "what is on screen": a
  /// feature excluded by a layer filter, hidden behind another, or outside a
  /// layer's zoom range still comes back.
  ///
  /// Two behaviours that surprise everyone once, and are mbgl's and gl-js's
  /// alike:
  ///
  /// * it only sees tiles **already fetched** — there is no request — so the
  ///   answer depends on where the camera has been;
  /// * results are **not deduplicated**. The answer is assembled per tile, so a
  ///   feature in the overlap of several cached tiles comes back once per tile.
  ///   Dedupe on [QueriedFeature.id] if you need unique features.
  ///
  /// [sourceLayers] is required in practice for a vector source and ignored by
  /// a GeoJSON one.
  List<QueriedFeature> querySourceFeatures(
    String sourceId, {
    List<String>? sourceLayers,
    Expression? filter,
  }) {
    final json = _layers?.querySourceFeaturesJson(
      sourceId,
      sourceLayers: sourceLayers,
      filterJson: _filterJson(filter),
    );
    if (json == null || json.isEmpty) return const [];
    return _parseFeatures(json);
  }

  /// Every attribution the current style's sources require.
  ///
  /// **Usually a legal obligation.** OpenStreetMap-derived tiles are ODbL,
  /// which requires visible credit, and most commercial providers say the same
  /// in their terms — so `MapLibreMap.showAttribution` defaults to true and
  /// this is what it renders. Reading the strings is not displaying them.
  ///
  /// Deduplicated: several sources in one style routinely carry the identical
  /// credit, and showing it three times is worse than showing it once.
  ///
  /// **Re-read it after every style load.** A style load replaces every source,
  /// so a list cached at attach goes stale the moment `MapLibreMap.style`
  /// changes — which is why the widget rebuilds this from `onStyleLoaded`
  /// rather than holding it.
  List<MapAttribution> getAttributions() {
    final seen = <String>{};
    final out = <MapAttribution>[];
    for (final id in getSourceIds()) {
      final html = getSource(id)?.attribution;
      if (html == null || html.trim().isEmpty) continue;
      if (!seen.add(html)) continue;
      out.add(MapAttribution.parse(html));
    }
    return out;
  }

  // --- Clusters ---------------------------------------------------------------
  //
  // The three supercluster questions. Every one takes the integer `cluster_id`
  // that clustering wrote into the cluster feature's properties — which
  // [QueriedFeature.clusterId] hands you straight from a query.

  /// The zoom at which a cluster splits into its children — gl-js
  /// `getClusterExpansionZoom`.
  ///
  /// The point of it is "tap a cluster, zoom to break it up":
  ///
  /// ```dart
  /// final zoom = controller.style.getClusterExpansionZoom('pts', id);
  /// if (zoom != null) {
  ///   await controller.camera.easeTo(CameraOptions(center: at, zoom: zoom));
  /// }
  /// ```
  ///
  /// Null when the source is not clustered or the read failed.
  ///
  /// **A cluster id that does not exist is not detectable here.** supercluster
  /// computes the answer from the id's own low bits before it ever looks the
  /// cluster up, so a made-up id returns a plausible-looking zoom instead of
  /// nothing. Pass an id you got from [QueriedFeature.clusterId], and use
  /// [getClusterChildren] if you need to know whether a cluster is real.
  double? getClusterExpansionZoom(String sourceId, int clusterId) =>
      _layers?.getClusterExpansionZoom(sourceId, clusterId)?.toDouble();

  /// A cluster's immediate children at the next zoom level — themselves
  /// clusters or individual points. gl-js `getClusterChildren`.
  List<QueriedFeature> getClusterChildren(String sourceId, int clusterId) {
    final json = _layers?.getClusterChildrenJson(sourceId, clusterId);
    return json == null ? const [] : _parseFeatures(json);
  }

  /// The original points under a cluster, however deep — gl-js
  /// `getClusterLeaves`.
  ///
  /// Paged deliberately: one cluster can stand for a hundred thousand points,
  /// so there is no "give me all of them". Page with [offset].
  List<QueriedFeature> getClusterLeaves(
    String sourceId,
    int clusterId, {
    int limit = 100,
    int offset = 0,
  }) {
    final json = _layers?.getClusterLeavesJson(
      sourceId,
      clusterId,
      limit: limit,
      offset: offset,
    );
    return json == null ? const [] : _parseFeatures(json);
  }

  // --- Feature state ----------------------------------------------------------

  /// Attaches state to one feature — gl-js `setFeatureState`.
  ///
  /// State lives OUTSIDE the tile and is readable from any style expression
  /// with `Expr.featureState('key')`, so hover and selection cost a repaint
  /// rather than re-uploading a source:
  ///
  /// ```dart
  /// controller.style.addLayer(CircleLayer(
  ///   id: 'dots',
  ///   source: 'pts',
  ///   circleColor: Expr.caseExpr(
  ///     Expr.featureState('selected'), const StyleValue(Color(0xFFFF0000)),
  ///     const StyleValue(Color(0xFF2196F3)),
  ///   ),
  /// ));
  /// controller.style.setFeatureState('pts', 7, {'selected': true});
  /// ```
  ///
  /// [state] is MERGED into whatever the feature already has, so setting one
  /// key leaves the others alone.
  ///
  /// **It only works on features that carry their own id.** The style spec has
  /// `promoteId` and `generateId` for sources that identify features by a
  /// property instead, and **mbgl implements neither** — so a GeoJSON feature
  /// needs a top-level `"id"` and a vector feature needs an id in the MVT.
  /// State set against an id no feature has is stored and never read: nothing
  /// throws, nothing repaints, and the only symptom is that your styling does
  /// not change.
  void setFeatureState(
    String sourceId,
    Object featureId,
    Map<String, Object?> state, {
    String? sourceLayer,
  }) => _layers?.setFeatureStateJson(
    sourceId,
    '$featureId',
    jsonEncode(encodeStyleJson(state)),
    sourceLayer: sourceLayer,
  );

  /// One feature's state, `{}` when it has none — gl-js `getFeatureState`.
  ///
  /// Returns null when the read failed, which is deliberately distinguishable
  /// from an empty map.
  Map<String, Object?>? getFeatureState(
    String sourceId,
    Object featureId, {
    String? sourceLayer,
  }) {
    final json = _layers?.getFeatureStateJson(
      sourceId,
      '$featureId',
      sourceLayer: sourceLayer,
    );
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// Removes feature state — gl-js `removeFeatureState`.
  ///
  /// Widens as arguments are omitted, exactly as gl-js does: no [stateKey]
  /// clears the feature's whole state, and no [featureId] clears every
  /// feature's state in the source.
  void removeFeatureState(
    String sourceId, {
    Object? featureId,
    String? sourceLayer,
    String? stateKey,
  }) => _layers?.removeFeatureState(
    sourceId,
    featureId: featureId == null ? null : '$featureId',
    sourceLayer: sourceLayer,
    stateKey: stateKey,
  );

  static String? _filterJson(Expression? filter) =>
      filter == null ? null : jsonEncode(encodeStyleJson(filter));

  /// The screen-space box through a geographic bounds' corners.
  ///
  /// All FOUR corners, not just the two the bounds names: under a bearing the
  /// south-west corner is not the left-most point on screen, so projecting two
  /// corners produces a box that clips the other two out of the query.
  Rect? _projectBounds(LatLngBounds bounds) {
    final projector = _projector;
    if (projector == null) return null;
    final corners = <LatLng>[
      LatLng(bounds.south, bounds.west),
      LatLng(bounds.south, bounds.east),
      LatLng(bounds.north, bounds.west),
      LatLng(bounds.north, bounds.east),
    ];
    final out = List<Offset>.filled(corners.length, Offset.zero);
    final visible = List<bool>.filled(corners.length, false);
    // Generation 0 means no frame has been presented, so `out` is untouched and
    // the box would be a point at the origin — which would query the wrong
    // place rather than nothing, so refuse instead.
    if (projector.project(corners, out, visible: visible) == 0) return null;

    // A corner BEHIND the camera on a pitched view projects to a meaningless
    // point, and including it would blow the box up to cover the screen. Drop
    // it; the remaining corners still bound everything that is actually
    // visible, which is all a rendered query can return anyway.
    final points = <Offset>[
      for (var i = 0; i < corners.length; i++)
        if (visible[i]) out[i],
    ];
    if (points.isEmpty) return null;
    var rect = Rect.fromPoints(points.first, points.first);
    for (final p in points.skip(1)) {
      rect = rect.expandToInclude(Rect.fromPoints(p, p));
    }
    return rect;
  }

  /// Parses a FeatureCollection into features, dropping only what it cannot
  /// read.
  static List<QueriedFeature> _parseFeatures(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map<String, Object?>) return const [];
    final features = decoded['features'];
    if (features is! List<Object?>) return const [];
    final out = <QueriedFeature>[];
    for (final f in features) {
      if (f is! Map<String, Object?>) continue;
      try {
        out.add(QueriedFeature.fromJson(f));
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  // --- Recipes ----------------------------------------------------------------
  //
  // NOT style-spec API. Everything above this line mirrors a gl-js `Map` method
  // one-for-one; everything below is a MACRO over several of them, with an id
  // scheme of its own invention. The split is deliberate and the naming carries
  // it: `addLayer` adds a layer, `addCircleLayersFromPoints` adds a source and
  // up to three layers whose ids you did not choose.

  /// Adds [points] as an engine-drawn circle layer, optionally clustered.
  ///
  /// The common case in one call: builds the GeoJSON, the source and the layers.
  /// With [cluster] on, mbgl runs supercluster internally and this adds cluster
  /// bubbles plus the leftover single points.
  ///
  /// **This is a recipe, not spec API.** gl-js has nothing like it — the
  /// canonical shape there is `addSource(id, {type: 'geojson', cluster: true})`
  /// followed by three `addLayer` calls, which is exactly what this does. The
  /// returned [MapLibrePointLayers] owns the ids it invented, so cleaning up no
  /// longer means knowing the scheme.
  ///
  /// **Cluster counts need a font you know the style has.** Pass
  /// [clusterTextFont] (e.g. `['Open Sans Regular']` for MapLibre demotiles,
  /// `['Noto Sans Regular']` for OpenFreeMap Liberty) to label each bubble with
  /// its point count. It is **null by default and the label layer is then
  /// omitted entirely**, because a library cannot know which fonts a given style
  /// serves: naming one it does not have makes mbgl request glyphs that 404 on
  /// every tile, which at best loses the text and at worst holds up the source.
  ///
  /// Ids are derived from [id] (`<id>`, `<id>-clusters`, `<id>-count`,
  /// `<id>-points`) — read them off the handle rather than rebuilding them.
  ///
  /// [properties] attaches one property map per point, parallel to [points],
  /// which is what data-driven styling reads (`Expr.get('…')`).
  MapLibrePointLayers addCircleLayersFromPoints(
    String id,
    List<LatLng> points, {
    List<Map<String, Object?>>? properties,
    bool cluster = false,
    double radius = 5,
    Color color = const Color(0xFF1565C0),
    Color clusterColor = const Color(0xFFF57C00),
    double clusterRadiusPx = 18,
    int clusterRadius = 50,
    int clusterMaxZoom = 14,
    List<String>? clusterTextFont,
    String? beforeId,
  }) {
    final handle = MapLibrePointLayers._(this, id, clustered: cluster);
    if (_layers == null) return handle;
    addSource(
      id,
      GeoJsonSource(
        data: GeoJsonData.points(points, properties: properties),
        cluster: cluster ? true : null,
        clusterRadius: cluster ? clusterRadius.toDouble() : null,
        clusterMaxZoom: cluster ? clusterMaxZoom.toDouble() : null,
      ),
    );

    // A single circle layer over the whole source when there is no clustering.
    if (!cluster) {
      addLayer(
        _circles(id: id, source: id, radius: radius, color: color),
        beforeId: beforeId,
      );
      return handle;
    }

    // `point_count` exists only on features supercluster created, so these two
    // filters partition the source into clusters and leftover single points.
    addLayer(
      CircleLayer(
        id: '$id-clusters',
        source: id,
        filter: Expr.has('point_count'),
        // Bubble grows with the number of points it stands for.
        circleRadius: Expr.step(
          Expr.get('point_count'),
          clusterRadiusPx,
          100,
          clusterRadiusPx * 1.35,
          750,
          clusterRadiusPx * 1.75,
        ),
        circleColor: StyleValue(clusterColor),
        circleStrokeWidth: const StyleValue(2),
        circleStrokeColor: const StyleValue(_white),
      ),
      beforeId: beforeId,
    );
    // Only when the caller has told us a font the style actually serves —
    // otherwise mbgl falls back to "Open Sans Regular,Arial Unicode MS Regular"
    // and 404s the glyph range on every tile.
    if (clusterTextFont != null) {
      addLayer(
        SymbolLayer(
          id: '$id-count',
          source: id,
          filter: Expr.has('point_count'),
          textField: Expr.get('point_count_abbreviated'),
          textFont: StyleValue(clusterTextFont),
          textSize: const StyleValue(12),
          textAllowOverlap: const StyleValue(true),
          textColor: const StyleValue(_white),
        ),
        beforeId: beforeId,
      );
    }
    addLayer(
      _circles(
        id: '$id-points',
        source: id,
        radius: radius,
        color: color,
        filter: Expr.not(Expr.has('point_count')),
      ),
      beforeId: beforeId,
    );
    handle._labelled = clusterTextFont != null;
    return handle;
  }

  /// The plain-points circle layer, shared by the clustered and unclustered
  /// paths so they cannot drift apart.
  static CircleLayer _circles({
    required String id,
    required String source,
    required double radius,
    required Color color,
    Expression? filter,
  }) => CircleLayer(
    id: id,
    source: source,
    filter: filter,
    circleRadius: StyleValue(radius),
    circleColor: StyleValue(color),
    circleStrokeWidth: const StyleValue(1),
    circleStrokeColor: const StyleValue(_white),
  );

  static const _white = Color(0xFFFFFFFF);

  /// Replaces the points of a layer added with [addCircleLayersFromPoints].
  ///
  /// [properties] attaches one property map per point, parallel to [points], so
  /// data-driven styling (`Expr.get('…')`) keeps working across an update.
  /// Omitting it clears the properties, exactly as passing new data does in
  /// gl-js `source.setData`.
  void setPointsData(
    String id,
    List<LatLng> points, {
    List<Map<String, Object?>>? properties,
  }) => setSourceData(
    id,
    jsonEncode(GeoJsonData.points(points, properties: properties).toJson()),
  );

  /// Removes everything [addCircleLayersFromPoints] created for [id].
  void removeCircleLayersFromPoints(String id) {
    for (final layer in ['$id-points', '$id-count', '$id-clusters', id]) {
      removeLayer(layer);
    }
    removeSource(id);
  }

  /// Adds [points] as an engine-drawn circle layer.
  @Deprecated(
    'Renamed to addCircleLayersFromPoints. The old name sat next to addLayer '
    'and read as style-spec API, when it is a macro that adds a source and up '
    'to three layers under ids it invents. Will be removed in a future release.',
  )
  void addPoints(
    String id,
    List<LatLng> points, {
    List<Map<String, Object?>>? properties,
    bool cluster = false,
    double radius = 5,
    Color color = const Color(0xFF1565C0),
    Color clusterColor = const Color(0xFFF57C00),
    double clusterRadiusPx = 18,
    int clusterRadius = 50,
    int clusterMaxZoom = 14,
    List<String>? clusterTextFont,
    String? beforeId,
  }) => addCircleLayersFromPoints(
    id,
    points,
    properties: properties,
    cluster: cluster,
    radius: radius,
    color: color,
    clusterColor: clusterColor,
    clusterRadiusPx: clusterRadiusPx,
    clusterRadius: clusterRadius,
    clusterMaxZoom: clusterMaxZoom,
    clusterTextFont: clusterTextFont,
    beforeId: beforeId,
  );

  /// Replaces the points of a recipe layer.
  @Deprecated(
    'Renamed to setPointsData, to stop reading as a sibling of setPaintProperty '
    'and to match setSourceData underneath. Will be removed in a future release.',
  )
  void setPoints(
    String id,
    List<LatLng> points, {
    List<Map<String, Object?>>? properties,
  }) => setPointsData(id, points, properties: properties);

  /// Removes everything the points recipe created for [id].
  @Deprecated(
    'Renamed to removeCircleLayersFromPoints, to pair with the recipe that '
    'created them. Will be removed in a future release.',
  )
  void removePoints(String id) => removeCircleLayersFromPoints(id);

  /// Paints [widget] off-screen and registers the result as an icon named [id],
  /// usable as `icon-image` in a symbol layer.
  ///
  /// This is the bridge between the two annotation styles: author the marker as
  /// a Flutter widget, then let the ENGINE draw it thousands of times. The icon
  /// is a snapshot — it will not animate and cannot hold gestures — so use it
  /// for bulk points and keep real widget markers for the interactive few.
  ///
  /// [size] is in logical pixels; [pixelRatio] should be the display's DPR so
  /// the bitmap is crisp (the icon is registered at that scale, so the engine
  /// draws it at the right size).
  Future<void> addWidgetIcon(
    String id,
    Widget widget, {
    required Size size,
    double pixelRatio = 3.0,
    bool sdf = false,
  }) async {
    if (_layers == null) return;
    final image = await rasterizeWidget(
      widget,
      size: size,
      pixelRatio: pixelRatio,
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return;
      addImage(
        id,
        data.buffer.asUint8List(),
        image.width,
        image.height,
        pixelRatio: pixelRatio,
        sdf: sdf,
      );
    } finally {
      image.dispose();
    }
  }

  /// Paints [widget] into an image without ever adding it to the visible tree.
  ///
  /// Builds a throwaway render tree around a [RenderRepaintBoundary] and pumps
  /// it through one layout/paint pass. Exposed because it is useful on its own
  /// (and testable); [addWidgetIcon] is the usual entry point.
  ///
  /// **[size] is a maximum, not a demand.** The widget is laid out under loose
  /// constraints and the image comes out at whatever size it chose, so a marker
  /// that wants more room than you guessed is not silently cropped (text
  /// clipped at an edge is the usual way that shows up). Widgets with no
  /// intrinsic size of their own — a bare [ColoredBox], say — would collapse to
  /// nothing under loose constraints, so those fall back to exactly [size].
  static Future<ui.Image> rasterizeWidget(
    Widget widget, {
    required Size size,
    double pixelRatio = 3.0,
  }) async {
    // First pass: let the widget pick its own size, bounded by `size`.
    final sized = await _paintOnce(
      widget,
      constraints: BoxConstraints.loose(size),
      pixelRatio: pixelRatio,
    );
    if (sized != null) return sized;

    // The widget has no intrinsic size (it collapsed to nothing under loose
    // constraints, as a bare ColoredBox does): give it the box instead.
    final forced = await _paintOnce(
      widget,
      constraints: BoxConstraints.tight(size),
      pixelRatio: pixelRatio,
      forceSize: size,
    );
    if (forced != null) return forced;
    throw StateError('rasterizeWidget produced no image for $widget');
  }

  /// Returns null when the widget laid out to an empty box — rasterizing that
  /// would assert, so the caller re-runs with an explicit size instead.
  static Future<ui.Image?> _paintOnce(
    Widget widget, {
    required BoxConstraints constraints,
    required double pixelRatio,
    Size? forceSize,
  }) async {
    final boundary = RenderRepaintBoundary();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final renderView = RenderView(
      view: view,
      child: RenderPositionedBox(child: boundary),
      configuration: ViewConfiguration(
        logicalConstraints: constraints,
        devicePixelRatio: pixelRatio,
      ),
    );
    final pipelineOwner = PipelineOwner()..rootNode = renderView;
    renderView.prepareInitialFrame();

    final buildOwner = BuildOwner(focusManager: FocusManager());
    final element = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(devicePixelRatio: pixelRatio),
          child: forceSize == null
              ? widget
              : SizedBox.fromSize(size: forceSize, child: widget),
        ),
      ),
    ).attachToRenderTree(buildOwner);

    buildOwner
      ..buildScope(element)
      ..finalizeTree();
    pipelineOwner
      ..flushLayout()
      ..flushCompositingBits()
      ..flushPaint();

    // Check BEFORE rasterizing: toImage on an empty boundary asserts.
    if (boundary.size.isEmpty) {
      pipelineOwner.rootNode = null;
      return null;
    }
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    // Detach the throwaway tree so its render objects are not left rooted.
    pipelineOwner.rootNode = null;
    return image;
  }
}

/// The style namespace.
@Deprecated(
  'Renamed to MapLibreStyleController: it owns sources, images and the '
  'style-wide transition as well as layers, which is Apple MLNStyle rather '
  'than a layer list. Will be removed in a future release.',
)
typedef MapLibreLayersController = MapLibreStyleController;

/// One source of the current style — gl-js `map.getSource(id)`'s return.
///
/// A thin view onto the live map rather than a snapshot: [setData] reaches the
/// engine. Obtained from [MapLibreStyleController.getSource].
/// What [MapLibreStyleController.addCircleLayersFromPoints] built.
///
/// The recipe invents ids — `<id>`, `<id>-clusters`, `<id>-count`,
/// `<id>-points` — and before this handle existed that scheme was undocumented
/// private knowledge that only `removePoints` knew how to undo. Now the object
/// that made them owns them: [setData] and [remove] need no ids at all, and
/// [layerIds] gives you the real ones for [MapLibreStyleController.moveLayer]
/// or a [MapLibreStyleController.queryRenderedFeatures] filter.
class MapLibrePointLayers {
  MapLibrePointLayers._(this._style, this.id, {required this.clustered});

  final MapLibreStyleController _style;

  /// The id passed to the recipe. Also the SOURCE id.
  final String id;

  /// Whether the engine is clustering this source.
  final bool clustered;

  /// False when no `clusterTextFont` was given, in which case the count-label
  /// layer was deliberately omitted rather than pointed at a font the style may
  /// not serve.
  bool _labelled = false;

  /// The source id — the same as [id], named so call sites read clearly.
  String get sourceId => id;

  /// Every layer this recipe created, bottom-most first.
  List<String> get layerIds => clustered
      ? ['$id-clusters', if (_labelled) '$id-count', '$id-points']
      : [id];

  /// Replaces the points, without rebuilding the layers — the engine re-tiles
  /// and re-clusters.
  void setData(List<LatLng> points, {List<Map<String, Object?>>? properties}) =>
      _style.setPointsData(id, points, properties: properties);

  /// Removes the source and every layer this recipe created.
  void remove() => _style.removeCircleLayersFromPoints(id);
}

class MapLibreSource {
  const MapLibreSource._(
    this._style, {
    required this.id,
    required this.type,
    required this.attribution,
    required this.isVolatile,
  });

  final MapLibreStyleController _style;

  /// The source's id in the style document.
  final String id;

  /// Its style-spec type: `geojson`, `vector`, `raster`, `raster-dem`, …
  final String type;

  /// The attribution string the tile provider requires be shown, if it declares
  /// one.
  ///
  /// **Reading it is not displaying it.** Nothing renders attribution today,
  /// which is a legal obligation for many providers — tracked as its own task.
  /// This at least makes the string reachable, which it was not before.
  final String? attribution;

  /// Whether mbgl keeps this source's data out of persistent storage.
  final bool isVolatile;

  /// Whether this source's data can be replaced with [setData].
  ///
  /// Only GeoJSON sources can: mbgl has no data setter on a vector or raster
  /// one, so this is an engine limit rather than a missing binding.
  bool get supportsSetData => type == 'geojson';

  /// Replaces this source's data — gl-js `source.setData(...)`.
  ///
  /// Takes a [GeoJsonData], a typed `GeoJsonFeatureCollection`, or a raw JSON
  /// string. Reports on `controller.onError` if this source cannot take it.
  void setData(Object data) => _style.setSourceData(id, data);

  @override
  String toString() => 'MapLibreSource($id, type: $type)';
}

/// Thrown when a query could not be ANSWERED, as opposed to answering
/// "nothing".
///
/// Only the asynchronous queries throw. The synchronous ones return `const []`
/// for both cases on purpose: they run on camera ticks and must not throw into
/// a paint callback, so they trade the distinction for safety. An async caller
/// can afford to handle it, and a Future is where a failure belongs in Dart.
class MapQueryException implements Exception {
  const MapQueryException(this.message);

  /// Why the query could not be answered.
  final String message;

  @override
  String toString() => 'MapQueryException: $message';
}
