import 'dart:typed_data';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:maplibre_flutter_core/maplibre_flutter_core.dart';

import 'src/core_offline_store.dart';
import 'src/maplibre_flutter_ios_core_controller.dart';

/// The controller is exported so the shared core-controller conformance suite
/// (packages/maplibre_flutter/test/core_controller_conformance_test.dart) can
/// drive it against a recording fake. One suite covering all five tiers beats
/// five near-identical copies, and only `maplibre_flutter` depends on every
/// platform package, so the suite has to live there and the type has to be
/// reachable without an implementation import.
export 'src/maplibre_flutter_ios_core_controller.dart';

/// The default iOS implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. [createMap]
/// returns a [TextureHandle]: iOS renders with the shared `mbgl-core` engine
/// (Metal → a Flutter `Texture`), the same engine as every other platform, so
/// feature parity is maintained in one place (CLAUDE.md §3). The native
/// `MaplibreFlutterIosPlugin` (registered via `pluginClass`) wires the core map's
/// frames into the texture registrar.
///
/// To render with the MapLibre Apple SDK instead (native `MLNMapView`/`UiKitView`,
/// e.g. for A/B testing), add the `maplibre_flutter_ios_sdk` package to your app:
/// as a direct dependency it overrides this endorsed default.
class MapLibreFlutterIos extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterIos();
  }

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) => MapLibreFlutterIosCoreController.create(style, options);

  // 8.1/8.2: process-wide, before the first map. mbgl caches file sources by
  // (type, ResourceOptions), so this cannot be per-map without minting a second
  // cache database per distinct value.
  @override
  bool configureResources({
    String? cachePath,
    int? maximumCacheBytes,
    String? apiKey,
  }) => MapLibreCoreSettings.configure(
    cachePath: cachePath,
    maximumCacheBytes: maximumCacheBytes,
    apiKey: apiKey,
  );

  @override
  String? get cachePath => MapLibreCoreSettings.cachePath;

  /// Offline regions live in the same database `cachePath` names, so the tier
  /// that has a cache is exactly the tier that can store regions.
  @override
  MapLibreOfflineStore? get offlineStore => const CoreOfflineStore();

  /// Renders off-screen in STATIC mode, which blocks until every tile for the
  /// frame has loaded — a Continuous map would hand back a half-loaded picture,
  /// and a snapshot that is missing its tiles is worse than none.
  @override
  Future<MapSnapshot?> takeSnapshot(MapSnapshotOptions options) async {
    final width = (options.size.width * options.pixelRatio).round();
    final height = (options.size.height * options.pixelRatio).round();
    if (width <= 0 || height <= 0) return null;

    final map = MapLibreCoreMap.create(
      width: width,
      height: height,
      pixelRatio: options.pixelRatio,
      styleUri: options.style,
    );
    try {
      map.setCamera(
        latitude: options.camera.center.latitude,
        longitude: options.camera.center.longitude,
        zoom: options.camera.zoom,
        bearing: options.camera.bearing,
        pitch: options.camera.pitch,
      );
      if (!map.awaitFrame(options.timeout)) return null;
      final frame = map.copyFrame();
      if (frame == null) return null;
      return MapSnapshot(
        pixels: _bgraToRgba(frame),
        width: width,
        height: height,
      );
    } finally {
      // ALWAYS: this map exists only for the render, and leaking a render
      // thread per snapshot would be invisible until an app took a few hundred.
      map.dispose();
    }
  }

  /// The engine hands back BGRA; Flutter's image APIs want RGBA.
  ///
  /// In place on a copy, swapping only the two channels — the alpha and green
  /// bytes are already where they belong.
  static Uint8List _bgraToRgba(Uint8List frame) {
    final out = Uint8List.fromList(frame);
    for (var i = 0; i + 3 < out.length; i += 4) {
      final b = out[i];
      out[i] = out[i + 2];
      out[i + 2] = b;
    }
    return out;
  }
}
