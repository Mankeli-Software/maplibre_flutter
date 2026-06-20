import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_macos_controller.dart';

/// The macOS implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. macOS is part
/// of the desktop tier (CLAUDE.md §3): it renders MapLibre Native (`mbgl-core`,
/// via `maplibre_flutter_core`) off-screen into a Metal texture and composites
/// through a Flutter `Texture`. The native half of this plugin
/// (`MaplibreFlutterMacosPlugin`) owns the texture registrar; [createMap]
/// delegates to [MapLibreFlutterMacosController].
class MapLibreFlutterMacos extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterMacos();
  }

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) => MapLibreFlutterMacosController.create(style, options);
}
