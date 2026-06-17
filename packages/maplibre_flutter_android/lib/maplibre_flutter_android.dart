import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_android_controller.dart';

/// The android implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. [createMap]
/// returns a [PlatformViewHandle]; the native `MaplibreFlutterAndroidPlugin`
/// (registered via `pluginClass`) provides the `AndroidView` factory that
/// renders the map (CLAUDE.md §3, §8 step 1).
class MapLibreFlutterAndroid extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterAndroid();
  }

  @override
  Future<MapLibreMapController> createMap(MapOptions options) async {
    return MapLibreFlutterAndroidController(options);
  }
}
