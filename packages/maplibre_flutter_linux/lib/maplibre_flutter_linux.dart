import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:maplibre_flutter_core/maplibre_flutter_core.dart';

import 'src/maplibre_flutter_linux_controller.dart';

/// The controller is exported so the shared core-controller conformance suite
/// (packages/maplibre_flutter/test/core_controller_conformance_test.dart) can
/// drive it against a recording fake. One suite covering all five tiers beats
/// five near-identical copies, and only `maplibre_flutter` depends on every
/// platform package, so the suite has to live there and the type has to be
/// reachable without an implementation import.
export 'src/maplibre_flutter_linux_controller.dart';

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
