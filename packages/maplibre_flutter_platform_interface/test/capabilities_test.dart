import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter/painting.dart' show EdgeInsets;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// A tier with nothing optional — the shape the web-WASM controller had when
/// this was written.
class _BareController implements MapLibreMapPlatformController {
  @override
  MapLibreRenderHandle get renderHandle => const TextureHandle(textureId: 1);
  @override
  Future<void> get onReady => Future<void>.value();
  @override
  Future<MapCamera> getCamera() async => const MapCamera(center: LatLng(0, 0));
  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {}
  @override
  Future<void> setStyle(String styleUri) async {}
  @override
  Future<void> resize(Size size, double devicePixelRatio) async {}
  @override
  Future<void> dispose() async {}
}

/// A tier with every optional capability, like the `mbgl-core` ones.
class _FullController extends _BareController
    with MapLibreCameraTickNotifier
    implements
        MapLibreMapProjector,
        MapLibreStyleLayers,
        MapLibreModelHost,
        MapLibreRotateHandler,
        MapLibreGestureHandler,
        MapLibreMapEvents,
        MapLibreCameraCommands {
  @override
  int project(List<LatLng> points, List<Offset> out, {List<bool>? visible}) =>
      1;
  @override
  LatLng? unproject(Offset point) => const LatLng(0, 0);

  @override
  void addSourceJson(String id, String json) {}
  @override
  void addLayerJson(String json, {String? beforeId}) {}
  @override
  void setSourceData(String sourceId, String data) {}
  @override
  String? getSourceJson(String sourceId) => null;
  @override
  List<String>? getSourceIds() => null;
  @override
  void setGeoJsonData(String sourceId, String geoJson) {}
  @override
  void removeLayer(String id) {}
  @override
  bool setLayerProperty(String layerId, String name, String valueJson) => true;
  @override
  void moveLayer(String layerId, {String? beforeId}) {}
  @override
  String? getLayerProperty(String layerId, String name) => null;
  @override
  List<String>? getLayerIds() => null;
  @override
  String? getLayerJson(String layerId) => null;

  @override
  void removeSource(String id) {}
  @override
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) {}
  @override
  bool? hasImage(String id) => null;
  @override
  List<String>? getImageIds() => null;
  @override
  void removeImage(String id) {}
  @override
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions = true,
  }) {}
  @override
  String? queryRenderedFeaturesJson(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
    String? filterJson,
  }) => null;

  @override
  Future<String?> queryRenderedFeaturesAsyncJson(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
    String? filterJson,
  }) async => queryRenderedFeaturesJson(
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

  /// What [querySourceFeaturesJson] returns.
  String? sourceQueryResult;

  @override
  String? querySourceFeaturesJson(
    String sourceId, {
    List<String>? sourceLayers,
    String? filterJson,
  }) {
    sourceQueries.add((
      sourceId: sourceId,
      sourceLayers: sourceLayers,
      filterJson: filterJson,
    ));
    return sourceQueryResult;
  }

  @override
  void setFeatureStateJson(
    String sourceId,
    String featureId,
    String stateJson, {
    String? sourceLayer,
  }) {}

  @override
  String? getFeatureStateJson(
    String sourceId,
    String featureId, {
    String? sourceLayer,
  }) => null;

  @override
  void removeFeatureState(
    String sourceId, {
    String? featureId,
    String? sourceLayer,
    String? stateKey,
  }) {}

  @override
  void addModel(MapLibreModel model) {}
  @override
  void updateModel(MapLibreModel model) {}
  @override
  void removeModel(String id) {}
  @override
  int? modelPartCount(String assetPath) => null;
  @override
  int get renderedFrameCount => 0;

  @override
  void rotateBy(double degrees, double anchorX, double anchorY) {}
  @override
  void pitchBy(double degrees) {}

  @override
  void moveBy(double dx, double dy) {}
  @override
  void scaleBy(double scale, double anchorX, double anchorY) {}

  @override
  Stream<MapLibreError> get onError => const Stream<MapLibreError>.empty();
  @override
  Stream<void> get onStyleLoaded => const Stream<void>.empty();
  @override
  Stream<String> get onStyleImageMissing => const Stream<String>.empty();

  @override
  Future<void> jumpTo(CameraOptions camera) async {}
  @override
  Future<void> easeTo(
    CameraOptions camera, {
    CameraAnimation? animation,
  }) async {}
  @override
  Future<void> flyTo(
    CameraOptions camera, {
    CameraAnimation? animation,
  }) async {}
  @override
  Future<void> fitBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    double? bearing,
    double? pitch,
    CameraTransition transition = CameraTransition.ease,
    CameraAnimation? animation,
  }) async {}
  @override
  Future<CameraOptions?> cameraForBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    double? bearing,
    double? pitch,
  }) async => null;
  @override
  Future<LatLngBounds?> getBounds() async => null;
  @override
  Future<void> setCameraConstraints(MapCameraConstraints constraints) async {}
  @override
  Future<MapCameraConstraints?> getCameraConstraints() async => null;
  @override
  Future<void> setConstrainToBounds({required bool wholeViewport}) async {}
  @override
  Future<void> stopCamera() async {}
}

void main() {
  test('nothing is available before a map is bound', () {
    const none = MapLibreCapabilities.none();
    expect(none.projection, isFalse);
    expect(none.styleLayers, isFalse);
    expect(none.models, isFalse);
    expect(none.rotateAndTilt, isFalse);
    expect(none.gestures, isFalse);
    expect(none.events, isFalse);
    expect(none.cameraCommands, isFalse);
    expect(MapLibreCapabilities.of(null), none);
    expect(MapLibreCapabilities.of('not a controller'), none);
  });

  test('a bare tier reports every optional capability as absent', () {
    expect(
      MapLibreCapabilities.of(_BareController()),
      const MapLibreCapabilities.none(),
    );
  });

  test('a full tier reports every one as present', () {
    final full = MapLibreCapabilities.of(_FullController());
    expect(full.projection, isTrue);
    expect(full.styleLayers, isTrue);
    expect(full.models, isTrue);
    expect(full.rotateAndTilt, isTrue);
    expect(full.gestures, isTrue);
    expect(full.events, isTrue);
    expect(full.cameraCommands, isTrue);
    expect(
      full,
      const MapLibreCapabilities(
        projection: true,
        styleLayers: true,
        models: true,
        rotateAndTilt: true,
        gestures: true,
        events: true,
        cameraCommands: true,
      ),
    );
  });

  test('the derivation agrees with a hand-written `is` check', () {
    // The point of the value object is that it cannot drift from the checks it
    // replaces, so assert the two together. Typed as Object so the analyser
    // cannot prove the `is` checks statically and elide them.
    final Object platform = _FullController();
    final capabilities = MapLibreCapabilities.of(platform);
    expect(capabilities.projection, platform is MapLibreMapProjector);
    expect(capabilities.models, platform is MapLibreModelHost);
    expect(capabilities.styleLayers, platform is MapLibreStyleLayers);
    expect(capabilities.rotateAndTilt, platform is MapLibreRotateHandler);
    expect(capabilities.gestures, platform is MapLibreGestureHandler);
    expect(capabilities.events, platform is MapLibreMapEvents);
    expect(capabilities.cameraCommands, platform is MapLibreCameraCommands);
  });

  group('MapCameraChangeReason', () {
    test('mirrors the ten Apple MLNCameraChangeReason values', () {
      // MLNCameraChangeReasonNone is the empty set, not an enum value.
      expect(MapCameraChangeReason.values, hasLength(10));
      expect(
        MapCameraChangeReason.values.map((r) => r.name),
        containsAll(<String>[
          'programmatic',
          'resetNorth',
          'gesturePan',
          'gesturePinch',
          'gestureRotate',
          'gestureZoomIn',
          'gestureZoomOut',
          'gestureOneFingerZoom',
          'gestureTilt',
          'transitionCancelled',
        ]),
      );
    });

    test('anyGesture is exactly the user-driven reasons', () {
      expect(MapCameraChangeReason.anyGesture, hasLength(7));
      expect(
        MapCameraChangeReason.anyGesture.contains(
          MapCameraChangeReason.programmatic,
        ),
        isFalse,
      );
      expect(MapCameraChangeReason.gesturePan.isGesture, isTrue);
      expect(MapCameraChangeReason.programmatic.isGesture, isFalse);
      expect(MapCameraChangeReason.transitionCancelled.isGesture, isFalse);
      // resetNorth is a compass tap, which Apple reports as programmatic.
      expect(MapCameraChangeReason.resetNorth.isGesture, isFalse);
    });

    test('the set extensions classify a reason set', () {
      const pinch = {MapCameraChangeReason.gesturePinch};
      expect(pinch.isGesture, isTrue);
      expect(pinch.isZoom, isTrue);
      expect(pinch.isProgrammatic, isFalse);
      expect(pinch.isRotation, isFalse);

      // A twisting pinch is both, which is why this is a set and not an enum.
      const twist = {
        MapCameraChangeReason.gesturePinch,
        MapCameraChangeReason.gestureRotate,
      };
      expect(twist.isZoom, isTrue);
      expect(twist.isRotation, isTrue);

      const flight = {MapCameraChangeReason.programmatic};
      expect(flight.isProgrammatic, isTrue);
      expect(flight.isGesture, isFalse);

      const compass = {MapCameraChangeReason.resetNorth};
      expect(compass.isRotation, isTrue);
      expect(compass.isProgrammatic, isTrue);

      const shove = {MapCameraChangeReason.gestureTilt};
      expect(shove.isTilt, isTrue);
      expect(shove.isZoom, isFalse);

      const cancelled = {MapCameraChangeReason.transitionCancelled};
      expect(cancelled.isCancelled, isTrue);
      expect(cancelled.isGesture, isFalse);

      const none = <MapCameraChangeReason>{};
      expect(none.isGesture, isFalse);
      expect(none.isProgrammatic, isFalse);
    });
  });
}
