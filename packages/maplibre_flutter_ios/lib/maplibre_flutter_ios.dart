import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_ios_controller.dart';

/// The ios implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. [createMap]
/// returns a [PlatformViewHandle]; the native `MaplibreFlutterIosPlugin`
/// (registered via `pluginClass`) provides the `UiKitView` factory that renders
/// the map with `MLNMapView` (CLAUDE.md §3, §8 step 2).
class MapLibreFlutterIos extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterIos();
  }

  @override
  Future<MapLibreMapController> createMap(MapOptions options) async {
    return MapLibreFlutterIosController(options);
  }
}
