/// Test doubles for [MapLibreCoreMap], so the platform controllers can be tested
/// without a native library, a GPU or a device.
///
/// CLAUDE.md §7 layer 2 ("each platform wrapper with its generated bindings
/// mocked") was written down and implemented zero times for zero platforms —
/// including macOS. Every fake in the repo implemented the *platform interface*,
/// one level above the FFI wrapper, so the ~400-line body of each core
/// controller (camera conversion, fly-to stepping, projector batching, style
/// pass-through, dispose ordering) was executed by no test anywhere.
///
/// This is the missing level. It matters most right now because the same
/// controller body is being ported to four platforms that cannot be run on
/// hardware, and a blind copy that drops one line — the first-frame camera tick,
/// say, or the presented generation — looks completely correct in review.
///
/// Import from a test only:
/// ```dart
/// import 'package:maplibre_flutter_core/testing.dart';
/// ```
library;

import 'dart:typed_data';

import 'maplibre_flutter_core.dart';

/// A [MapLibreCoreMap] that records every call instead of touching the engine.
///
/// `implements` rather than `extends`: [MapLibreCoreMap] carries no
/// `final`/`base`/`sealed` modifier, and its instance API is FFI-free in its
/// signatures (the `ffi.Pointer` members are private, and the function-address
/// getters are static, so neither participates in the interface).
///
/// Reads return configurable values so a controller can be driven through a
/// realistic lifecycle; writes append to public lists so a test can assert on
/// the exact arguments forwarded. Nothing here is thread-confined or async —
/// the point is that a controller test runs in milliseconds on the VM.
class RecordingCoreMap implements MapLibreCoreMap {
  RecordingCoreMap({
    this.width = 512,
    this.height = 512,
    this.camera = (latitude: 0, longitude: 0, zoom: 0, bearing: 0, pitch: 0),
  });

  /// Frame size in device pixels; [resize] updates both, so a test can assert a
  /// controller pushed LOGICAL points and not points x DPR.
  @override
  int width;

  @override
  int height;

  // --- reads a test can steer ------------------------------------------------

  /// What [getCamera] returns. Controllers convert this to a `MapCamera`.
  CoreCamera camera;

  /// What [awaitFrame] returns. Controllers poll it to complete `onReady`, so
  /// flipping it to true is how a test advances a controller past creation.
  bool frameReady = false;

  /// What [presentedGeneration] returns.
  ///
  /// Deliberately NOT equal to [projectionGeneration]: a controller must project
  /// against the PRESENTED frame, and if the two agreed here a controller that
  /// passed the wrong one — or passed the C ABI's `0` default, meaning "newest"
  /// — would be indistinguishable from a correct one.
  int presented = 7;

  /// What [projectionGeneration] returns.
  int projection = 9;

  /// Screen positions [projectBatch] writes, in order, one (x, y) pair per
  /// point. Short lists repeat the last entry; empty means (0, 0).
  List<({double x, double y})> projected = const [];

  /// Whether each projected point is reported visible. Short lists repeat the
  /// last entry; empty means visible.
  List<bool> projectedVisible = const [];

  /// What [projectBatch] returns — the generation it claims to have used. 0
  /// means "no snapshot yet", which controllers must surface as "not projected".
  int? projectBatchResult;

  /// What [queryRenderedFeaturesJson]'s core counterpart returns.
  String? queryResult;

  /// What [copyFrame] returns.
  Uint8List? frame;

  /// What [renderedFrameCount] returns.
  int frameCount = 0;

  // --- recorded writes -------------------------------------------------------

  final List<String> styles = <String>[];
  final List<CoreCamera> cameraSets = <CoreCamera>[];
  final List<({int width, int height})> resizes = <({int width, int height})>[];
  final List<({double dx, double dy})> moves = <({double dx, double dy})>[];
  final List<({double scale, double anchorX, double anchorY})> scales =
      <({double scale, double anchorX, double anchorY})>[];
  final List<({String id, String json})> sources =
      <({String id, String json})>[];
  final List<({String json, String? beforeId})> layers =
      <({String json, String? beforeId})>[];
  final List<({String sourceId, String geoJson})> geoJsonUpdates =
      <({String sourceId, String geoJson})>[];
  final List<String> removedLayers = <String>[];
  final List<String> removedSources = <String>[];
  final List<({String id, int width, int height, double pixelRatio, bool sdf})>
  images =
      <({String id, int width, int height, double pixelRatio, bool sdf})>[];
  final List<String> removedImages = <String>[];
  final List<({Duration? duration, Duration? delay, bool placement})>
  transitions = <({Duration? duration, Duration? delay, bool placement})>[];
  final List<
    ({
      double minX,
      double minY,
      double maxX,
      double maxY,
      List<String>? layerIds,
    })
  >
  queries =
      <
        ({
          double minX,
          double minY,
          double maxX,
          double maxY,
          List<String>? layerIds,
        })
      >[];
  final List<
    ({
      String layerId,
      String path,
      double latitude,
      double longitude,
      double scale,
      double headingDegrees,
      double spinDegreesPerSecond,
      double elevationMetres,
    })
  >
  addedModels =
      <
        ({
          String layerId,
          String path,
          double latitude,
          double longitude,
          double scale,
          double headingDegrees,
          double spinDegreesPerSecond,
          double elevationMetres,
        })
      >[];
  final List<
    ({
      String layerId,
      double latitude,
      double longitude,
      double scale,
      double headingDegrees,
      double elevationMetres,
    })
  >
  modelTransforms =
      <
        ({
          String layerId,
          double latitude,
          double longitude,
          double scale,
          double headingDegrees,
          double elevationMetres,
        })
      >[];
  final List<String> removedModels = <String>[];

  /// Generations passed to [projectBatch] / [project], so a test can assert a
  /// controller projects against the presented frame and not the "newest"
  /// default.
  final List<int> projectGenerations = <int>[];

  /// Generations passed to [unproject], for the same reason.
  final List<int> unprojectGenerations = <int>[];

  /// What [unproject] returns. Null means "no transform snapshot yet", which a
  /// controller must surface rather than substituting a plausible coordinate.
  ({double latitude, double longitude})? unprojected = (
    latitude: 12.5,
    longitude: -34.25,
  );

  int repaintCount = 0;
  int zeroCopyCalls = 0;
  bool disposed = false;

  // --- MapLibreCoreMap -------------------------------------------------------

  @override
  int get nativeAddress => 0xC0FFEE;

  @override
  void setZeroCopy(bool enabled) => zeroCopyCalls++;

  @override
  bool isZeroCopyActive() => false;

  @override
  void setPixelFormatBgra(bool bgra) {}

  @override
  void setStyle(String styleUri) => styles.add(styleUri);

  @override
  void setCamera({
    required double latitude,
    required double longitude,
    double zoom = 0,
    double bearing = 0,
    double pitch = 0,
  }) {
    final next = (
      latitude: latitude,
      longitude: longitude,
      zoom: zoom,
      bearing: bearing,
      pitch: pitch,
    );
    cameraSets.add(next);
    // The real core applies the camera, so a controller that reads back
    // immediately sees its own write; without this, fly-to stepping tests would
    // observe a frozen camera.
    camera = next;
  }

  @override
  CoreCamera getCamera() => camera;

  @override
  void resize(int width, int height) {
    this.width = width;
    this.height = height;
    resizes.add((width: width, height: height));
  }

  @override
  void moveBy(double dx, double dy) => moves.add((dx: dx, dy: dy));

  @override
  void scaleBy(double scale, double anchorX, double anchorY) =>
      scales.add((scale: scale, anchorX: anchorX, anchorY: anchorY));

  @override
  void addSourceJson(String id, String json) =>
      sources.add((id: id, json: json));

  @override
  void addLayerJson(String json, {String? beforeId}) =>
      layers.add((json: json, beforeId: beforeId));

  @override
  void setGeoJsonData(String sourceId, String geoJson) =>
      geoJsonUpdates.add((sourceId: sourceId, geoJson: geoJson));

  @override
  void removeLayer(String id) => removedLayers.add(id);

  @override
  void removeSource(String id) => removedSources.add(id);

  @override
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) => images.add((
    id: id,
    width: width,
    height: height,
    pixelRatio: pixelRatio,
    sdf: sdf,
  ));

  @override
  void removeImage(String id) => removedImages.add(id);

  @override
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions = true,
  }) => transitions.add((
    duration: duration,
    delay: delay,
    placement: placementTransitions,
  ));

  @override
  String? queryRenderedFeatures(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
    Duration timeout = const Duration(milliseconds: 200),
  }) {
    queries.add((
      minX: minX,
      minY: minY,
      maxX: maxX,
      maxY: maxY,
      layerIds: layerIds,
    ));
    return queryResult;
  }

  @override
  int projectBatch(
    int count,
    Float64List inLatLng,
    Float64List outXy, {
    Int32List? visible,
    int generation = 0,
  }) {
    projectGenerations.add(generation);
    final result = projectBatchResult ?? projection;
    if (result == 0) return 0;
    for (var i = 0; i < count; i++) {
      final p = projected.isEmpty
          ? (x: 0.0, y: 0.0)
          : projected[i < projected.length ? i : projected.length - 1];
      outXy[i * 2] = p.x;
      outXy[i * 2 + 1] = p.y;
      if (visible != null) {
        final v = projectedVisible.isEmpty
            ? true
            : projectedVisible[i < projectedVisible.length
                  ? i
                  : projectedVisible.length - 1];
        visible[i] = v ? 1 : 0;
      }
    }
    return result;
  }

  @override
  ({double x, double y, bool visible})? project(
    double latitude,
    double longitude, {
    int generation = 0,
  }) {
    projectGenerations.add(generation);
    if ((projectBatchResult ?? projection) == 0) return null;
    final p = projected.isEmpty ? (x: 0.0, y: 0.0) : projected.first;
    final visible = projectedVisible.isEmpty ? true : projectedVisible.first;
    return (x: p.x, y: p.y, visible: visible);
  }

  @override
  ({double latitude, double longitude})? unproject(
    double x,
    double y, {
    int generation = 0,
  }) {
    unprojectGenerations.add(generation);
    return unprojected;
  }

  @override
  int get presentedGeneration => presented;

  @override
  int get projectionGeneration => projection;

  @override
  bool awaitFrame(Duration timeout) => frameReady;

  @override
  Uint8List? copyFrame() => frame;

  @override
  bool writePng(String path) => true;

  @override
  void triggerRepaint() => repaintCount++;

  @override
  int get renderedFrameCount => frameCount;

  @override
  void addModel({
    required String layerId,
    required String path,
    required double latitude,
    required double longitude,
    double scale = 1,
    double headingDegrees = 0,
    double spinDegreesPerSecond = 0,
    double elevationMetres = 0,
  }) => addedModels.add((
    layerId: layerId,
    path: path,
    latitude: latitude,
    longitude: longitude,
    scale: scale,
    headingDegrees: headingDegrees,
    spinDegreesPerSecond: spinDegreesPerSecond,
    elevationMetres: elevationMetres,
  ));

  @override
  void setModelTransform({
    required String layerId,
    required double latitude,
    required double longitude,
    double scale = 1,
    double headingDegrees = 0,
    double elevationMetres = 0,
  }) => modelTransforms.add((
    layerId: layerId,
    latitude: latitude,
    longitude: longitude,
    scale: scale,
    headingDegrees: headingDegrees,
    elevationMetres: elevationMetres,
  ));

  @override
  void addTestModel({
    required double latitude,
    required double longitude,
    double metresPerUnit = 50,
    double spinDegreesPerSecond = 90,
    double elevationMetres = 0,
  }) {}

  @override
  void removeModel(String layerId) => removedModels.add(layerId);

  @override
  void dispose() => disposed = true;
}
