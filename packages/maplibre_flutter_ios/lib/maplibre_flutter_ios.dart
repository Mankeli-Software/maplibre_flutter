import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:maplibre_flutter_core/maplibre_flutter_core.dart';

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
}
