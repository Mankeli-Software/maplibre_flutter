import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_linux_controller.dart';

/// The Linux implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. Linux is part
/// of the desktop tier (CLAUDE.md §3): it renders MapLibre Native (`mbgl-core`,
/// via `maplibre_flutter_core`'s OpenGL/EGL arm) off-screen and composites
/// through a Flutter `Texture`. The native half (`maplibre_flutter_linux_plugin`,
/// GTK) owns the texture registrar; [createMap] delegates to
/// [MapLibreFlutterLinuxController].
///
/// NOTE: not yet run on real Linux hardware — see CLAUDE.md §8.
class MapLibreFlutterLinux extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterLinux();
  }

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) => MapLibreFlutterLinuxController.create(style, options);
}
