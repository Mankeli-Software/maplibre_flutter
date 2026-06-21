import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_android_core_controller.dart';

/// The default Android implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. [createMap]
/// returns a [TextureHandle]: Android renders with the shared `mbgl-core` engine
/// (OpenGL ES + a Flutter `Texture`), the same engine as every other platform, so
/// feature parity is maintained in one place (CLAUDE.md §3). The native
/// `MaplibreFlutterAndroidPlugin` (registered via `pluginClass`) wires the core
/// map's frames into the texture registrar.
///
/// To render with the MapLibre Android SDK instead (native `MapView`/`AndroidView`,
/// e.g. for A/B testing), add the `maplibre_flutter_android_sdk` package to your
/// app: as a direct dependency it overrides this endorsed default.
class MapLibreFlutterAndroid extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterAndroid();
  }

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) => MapLibreFlutterAndroidCoreController.create(style, options);
}
