import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_windows_controller.dart';

/// The controller is exported so the shared core-controller conformance suite
/// (packages/maplibre_flutter/test/core_controller_conformance_test.dart) can
/// drive it against a recording fake. One suite covering all five tiers beats
/// five near-identical copies, and only `maplibre_flutter` depends on every
/// platform package, so the suite has to live there and the type has to be
/// reachable without an implementation import.
export 'src/maplibre_flutter_windows_controller.dart';

/// The Windows implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. Windows is
/// part of the desktop tier (CLAUDE.md §3): it renders MapLibre Native
/// (`mbgl-core`, via `maplibre_flutter_core`'s **Vulkan** arm) off-screen and
/// composites through a Flutter `Texture` — a D3D11 shared texture where the
/// driver allows it, a CPU pixel-buffer readback otherwise. The native half
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
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) => MapLibreFlutterWindowsController.create(style, options);
}
