import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_ios_core_controller.dart';

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
}
