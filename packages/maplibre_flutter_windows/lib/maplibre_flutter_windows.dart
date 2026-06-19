import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_windows_controller.dart';

/// The Windows implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. Windows is
/// part of the desktop tier (CLAUDE.md §3): it renders MapLibre Native
/// (`mbgl-core`, via `maplibre_flutter_core`'s ANGLE/OpenGL-ES + EGL arm)
/// off-screen and composites through a Flutter `Texture`. The native half
/// (`MaplibreFlutterWindowsPlugin`) owns the texture registrar; [createMap]
/// delegates to [MapLibreFlutterWindowsController].
///
/// NOTE: not yet run on real Windows hardware — see CLAUDE.md §8.
class MapLibreFlutterWindows extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterWindows();
  }

  @override
  Future<MapLibreMapController> createMap(MapOptions options) =>
      MapLibreFlutterWindowsController.create(options);
}
