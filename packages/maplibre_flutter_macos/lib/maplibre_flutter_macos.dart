import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// The macos implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. Native
/// rendering is wired in this platform's build-order step (CLAUDE.md §8); for
/// now [createMap] throws so the wiring is unmistakable.
class MapLibreFlutterMacos extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterMacos();
  }

  @override
  Future<MapLibreMapController> createMap(MapOptions options) {
    throw UnimplementedError(
      'maplibre_flutter_macos createMap() is not implemented yet (see CLAUDE.md §8).',
    );
  }
}
