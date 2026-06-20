import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_ios_controller.dart';
import 'src/maplibre_flutter_ios_core_controller.dart';

/// The ios implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. By default
/// [createMap] returns a [PlatformViewHandle]; the native `MaplibreFlutterIosPlugin`
/// (registered via `pluginClass`) provides the `UiKitView` factory that renders
/// the map with the MapLibre Apple SDK's `MLNMapView` (CLAUDE.md §3, §8 step 2).
///
/// EXPERIMENTAL: with `--dart-define=MAPLIBRE_EXPERIMENTAL_CORE=true`, [createMap]
/// instead returns a [MapLibreFlutterIosCoreController] (a [TextureHandle]) that
/// renders `mbgl-core` into a Flutter `Texture` like the desktop tier — the
/// sanctioned core-on-mobile A/B escape hatch (CLAUDE.md §3, 2026-06-19 decision).
/// The flag gates only this Dart selection; the native mbgl-core build is
/// unconditional (a dart-define is invisible to the build hook).
class MapLibreFlutterIos extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterIos();
  }

  /// Whether to render with the experimental mbgl-core path instead of the
  /// MapLibre Apple SDK. Compile-time, opt-in (mirrors the desktop tier's
  /// `const bool.fromEnvironment` flags).
  static const bool _experimentalCore = bool.fromEnvironment(
    'MAPLIBRE_EXPERIMENTAL_CORE',
    defaultValue: false,
  );

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) {
    if (_experimentalCore) {
      return MapLibreFlutterIosCoreController.create(style, options);
    }
    return Future.value(MapLibreFlutterIosController(style, options));
  }
}
