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
  final List<({double degrees, double anchorX, double anchorY})> rotations =
      <({double degrees, double anchorX, double anchorY})>[];
  final List<double> pitches = <double>[];
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
      String? filterJson,
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
          String? filterJson,
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
  void setPixelFormatBgra(bool bgra) => pixelFormatIsBgra = bgra;

  @override
  bool pixelFormatIsBgra = true;

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
  void rotateBy(double degrees, double anchorX, double anchorY) =>
      rotations.add((degrees: degrees, anchorX: anchorX, anchorY: anchorY));

  @override
  void pitchBy(double degrees) => pitches.add(degrees);

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
    String? filterJson,
    Duration timeout = const Duration(milliseconds: 200),
  }) {
    queries.add((
      minX: minX,
      minY: minY,
      maxX: maxX,
      maxY: maxY,
      layerIds: layerIds,
      filterJson: filterJson,
    ));
    return queryResult;
  }

  @override
  Future<String?> queryRenderedFeaturesAsync(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
    String? filterJson,
  }) async => queryRenderedFeatures(
    minX,
    minY,
    maxX,
    maxY,
    layerIds: layerIds,
    filterJson: filterJson,
  );

  /// Recorded source queries.
  final List<
    ({String sourceId, List<String>? sourceLayers, String? filterJson})
  >
  sourceQueries =
      <({String sourceId, List<String>? sourceLayers, String? filterJson})>[];

  /// What [querySourceFeatures] returns; null simulates a failure.
  String? sourceQueryResult;

  @override
  String? querySourceFeatures(
    String sourceId, {
    List<String>? sourceLayers,
    String? filterJson,
    Duration timeout = const Duration(milliseconds: 200),
  }) {
    sourceQueries.add((
      sourceId: sourceId,
      sourceLayers: sourceLayers,
      filterJson: filterJson,
    ));
    return sourceQueryResult;
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

  /// Swaps like the real one, so a test can catch a tier that set the wrong
  /// format — returning [frame] unchanged here would make the channel order
  /// untestable, which is the bug this method exists to prevent.
  @override
  Uint8List? copyFrameRgba() {
    final source = frame;
    if (source == null || !pixelFormatIsBgra) return source;
    final out = Uint8List.fromList(source);
    for (var i = 0; i + 3 < out.length; i += 4) {
      final b = out[i];
      out[i] = out[i + 2];
      out[i + 2] = b;
    }
    return out;
  }

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
    String? layerId,
  }) {}

  // --- clusters --------------------------------------------------------------

  /// What the cluster helpers return.
  int? clusterExpansionZoomResult;
  String? clusterChildrenResult;
  String? clusterLeavesResult;

  /// Recorded cluster questions.
  final List<({String field, String sourceId, int clusterId})> clusterQueries =
      <({String field, String sourceId, int clusterId})>[];

  @override
  int? getClusterExpansionZoom(
    String sourceId,
    int clusterId, {
    Duration timeout = const Duration(milliseconds: 200),
  }) {
    clusterQueries.add((
      field: 'expansion-zoom',
      sourceId: sourceId,
      clusterId: clusterId,
    ));
    return clusterExpansionZoomResult;
  }

  @override
  String? getClusterChildren(
    String sourceId,
    int clusterId, {
    Duration timeout = const Duration(milliseconds: 200),
  }) {
    clusterQueries.add((
      field: 'children',
      sourceId: sourceId,
      clusterId: clusterId,
    ));
    return clusterChildrenResult;
  }

  @override
  String? getClusterLeaves(
    String sourceId,
    int clusterId, {
    int limit = 100,
    int offset = 0,
    Duration timeout = const Duration(milliseconds: 200),
  }) {
    clusterQueries.add((
      field: 'leaves',
      sourceId: sourceId,
      clusterId: clusterId,
    ));
    return clusterLeavesResult;
  }

  // --- feature state ---------------------------------------------------------

  /// Feature state by "sourceId/featureId", as the recording double sees it.
  final Map<String, String> featureStates = <String, String>{};

  /// What [getFeatureState] returns; null simulates a timeout.
  String? featureStateResult = '{}';

  @override
  void setFeatureState(
    String sourceId,
    String featureId,
    String stateJson, {
    String? sourceLayer,
  }) => featureStates['$sourceId/$featureId'] = stateJson;

  @override
  String? getFeatureState(
    String sourceId,
    String featureId, {
    String? sourceLayer,
    Duration timeout = const Duration(milliseconds: 200),
  }) => featureStateResult;

  @override
  void removeFeatureState(
    String sourceId, {
    String? featureId,
    String? sourceLayer,
    String? stateKey,
  }) {
    if (featureId == null) {
      featureStates.removeWhere((key, _) => key.startsWith('$sourceId/'));
      return;
    }
    featureStates.remove('$sourceId/$featureId');
  }

  @override
  void removeModel(String layerId) => removedModels.add(layerId);

  // --- images ----------------------------------------------------------------

  /// What [hasImage] returns; null simulates a timeout.
  bool? hasImageResult = false;

  /// What [getImageIds] returns; null simulates a timeout.
  List<String>? imageIds = const [];

  @override
  bool? hasImage(
    String id, {
    Duration timeout = const Duration(milliseconds: 250),
  }) => hasImageResult;

  @override
  List<String>? getImageIds({
    Duration timeout = const Duration(milliseconds: 250),
  }) => imageIds;

  // --- sources ---------------------------------------------------------------

  /// What [getSourceJson] returns; null simulates absent or timed out.
  String? sourceJson =
      '{"id":"p","type":"geojson","attribution":null,'
      '"volatile":false}';

  /// What [getSourceIds] returns; null simulates a timeout.
  List<String>? sourceIds = const ['p'];

  @override
  String? getSourceJson(
    String sourceId, {
    Duration timeout = const Duration(milliseconds: 250),
  }) => sourceJson;

  @override
  List<String>? getSourceIds({
    Duration timeout = const Duration(milliseconds: 250),
  }) => sourceIds;

  // --- layer properties ------------------------------------------------------

  /// Every setLayerProperty call, in order.
  final List<({String layerId, String name, String valueJson})>
  layerProperties = [];

  /// Every moveLayer call.
  final List<({String layerId, String? beforeId})> layerMoves = [];

  /// What [setLayerProperty] returns; false simulates malformed JSON.
  bool setLayerPropertyResult = true;

  /// What [getLayerProperty] returns; null simulates absent or timed out.
  String? layerPropertyResult = '12';

  /// What [getLayerIds] returns; null simulates a timeout.
  List<String>? layerIds = const ['background', 'dots'];

  /// What [getLayerJson] returns; null simulates absent or timed out.
  String? layerJson = '{"id":"dots","type":"circle"}';

  @override
  bool setLayerProperty(String layerId, String name, String valueJson) {
    layerProperties.add((layerId: layerId, name: name, valueJson: valueJson));
    return setLayerPropertyResult;
  }

  @override
  void moveLayer(String layerId, {String? beforeId}) =>
      layerMoves.add((layerId: layerId, beforeId: beforeId));

  @override
  String? getLayerProperty(
    String layerId,
    String name, {
    Duration timeout = const Duration(milliseconds: 250),
  }) => layerPropertyResult;

  @override
  List<String>? getLayerIds({
    Duration timeout = const Duration(milliseconds: 250),
  }) => layerIds;

  @override
  String? getLayerJson(
    String layerId, {
    Duration timeout = const Duration(milliseconds: 250),
  }) => layerJson;

  // --- camera commands -------------------------------------------------------

  /// Every partial camera the controller applied, in order, with how.
  final List<({CoreCameraOptions camera, CoreCameraTransition how, int token})>
  cameraMoves = [];

  /// Every fitBounds call.
  final List<CoreLatLngBounds> fittedBounds = [];

  /// Every constraint set applied.
  final List<CoreBoundOptions> boundsSet = [];

  /// How many times cancelTransitions was called.
  int cancelledTransitions = 0;

  /// What [cameraForBounds] returns; null simulates a timeout.
  CoreCameraOptions? cameraForBoundsResult = const CoreCameraOptions(zoom: 8);

  /// What [getVisibleBounds] returns; null simulates a timeout.
  CoreLatLngBounds? visibleBounds = (swLat: -1, swLng: -2, neLat: 3, neLng: 4);

  /// What [getBoundOptions] returns; null simulates a timeout.
  CoreBoundOptions? boundOptions = const CoreBoundOptions();

  /// The registered camera-finish listener, driven by [finishCameraMove].
  void Function(int token)? cameraFinishListener;

  @override
  void jumpTo(CoreCameraOptions camera) => cameraMoves.add((
    camera: camera,
    how: CoreCameraTransition.jump,
    token: 0,
  ));

  @override
  void easeTo(
    CoreCameraOptions camera,
    CoreAnimationOptions? animation, {
    int token = 0,
  }) => cameraMoves.add((
    camera: camera,
    how: CoreCameraTransition.ease,
    token: token,
  ));

  @override
  void flyTo(
    CoreCameraOptions camera,
    CoreAnimationOptions? animation, {
    int token = 0,
  }) => cameraMoves.add((
    camera: camera,
    how: CoreCameraTransition.fly,
    token: token,
  ));

  @override
  void cancelTransitions() => cancelledTransitions++;

  @override
  void fitBounds(
    CoreLatLngBounds bounds, {
    ({double top, double right, double bottom, double left}) padding = (
      top: 0,
      right: 0,
      bottom: 0,
      left: 0,
    ),
    double? bearing,
    double? pitch,
    CoreCameraTransition transition = CoreCameraTransition.jump,
    CoreAnimationOptions? animation,
    int token = 0,
  }) => fittedBounds.add(bounds);

  @override
  CoreCameraOptions? cameraForBounds(
    CoreLatLngBounds bounds, {
    ({double top, double right, double bottom, double left}) padding = (
      top: 0,
      right: 0,
      bottom: 0,
      left: 0,
    ),
    double? bearing,
    double? pitch,
    Duration timeout = const Duration(milliseconds: 250),
  }) => cameraForBoundsResult;

  @override
  CoreLatLngBounds? getVisibleBounds({
    CoreCameraOptions camera = const CoreCameraOptions(),
    Duration timeout = const Duration(milliseconds: 250),
  }) => visibleBounds;

  @override
  void setBounds(CoreBoundOptions options) => boundsSet.add(options);

  @override
  CoreBoundOptions? getBoundOptions({
    Duration timeout = const Duration(milliseconds: 250),
  }) => boundOptions;

  @override
  void setConstrainMode(CoreConstrainMode mode) => constrainMode = mode;

  /// The last constrain mode applied.
  CoreConstrainMode? constrainMode;

  @override
  void setCameraFinishCallback(void Function(int token)? onFinish) =>
      cameraFinishListener = onFinish;

  /// Completes an animated move as the engine would.
  void finishCameraMove(int token) => cameraFinishListener?.call(token);

  // --- diagnostics -----------------------------------------------------------

  /// The listener the controller registered, or null if it has none. A test
  /// drives it with [emitDiagnostic] to simulate the engine reporting.
  void Function(CoreDiagnostic)? diagnosticListener;

  /// How many times [setDiagnosticCallback] has been called, so a test can
  /// assert a controller registers exactly once and unregisters on dispose.
  int diagnosticRegistrations = 0;

  @override
  void setDiagnosticCallback(void Function(CoreDiagnostic)? onDiagnostic) {
    diagnosticRegistrations++;
    diagnosticListener = onDiagnostic;
  }

  /// Delivers one event as the engine would.
  void emitDiagnostic(
    CoreDiagnosticKind kind, {
    CoreDiagnosticSeverity severity = CoreDiagnosticSeverity.error,
    String message = '',
  }) => diagnosticListener?.call((
    kind: kind,
    severity: severity,
    message: message,
  ));

  @override
  void dispose() {
    disposed = true;
    // Mirrors the real handle, which unregisters natively before tearing down.
    setDiagnosticCallback(null);
  }
}
