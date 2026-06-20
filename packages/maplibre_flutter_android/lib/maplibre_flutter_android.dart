import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_android_controller.dart';
import 'src/maplibre_flutter_android_core_controller.dart';

/// The android implementation of `maplibre_flutter`.
///
/// Registered automatically via `dartPluginClass` in pubspec.yaml. By default
/// [createMap] returns a [PlatformViewHandle]; the native
/// `MaplibreFlutterAndroidPlugin` (registered via `pluginClass`) provides the
/// `AndroidView` factory that renders the map with the MapLibre Android SDK
/// (CLAUDE.md §3, §8 step 1).
///
/// EXPERIMENTAL: with `--dart-define=MAPLIBRE_EXPERIMENTAL_CORE=true`, [createMap]
/// instead returns a [MapLibreFlutterAndroidCoreController] (a [TextureHandle])
/// that renders `mbgl-core` into a Flutter `Texture` like the desktop tier — the
/// sanctioned core-on-mobile A/B escape hatch (CLAUDE.md §3, 2026-06-19 decision).
/// The flag gates only this Dart selection; the native mbgl-core build is
/// unconditional (a dart-define is invisible to the build hook).
class MapLibreFlutterAndroid extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterAndroid();
  }

  /// Whether to render with the experimental mbgl-core path instead of the
  /// MapLibre Android SDK. Compile-time, opt-in (mirrors the desktop tier's
  /// `const bool.fromEnvironment` flags).
  static const bool _experimentalCore = bool.fromEnvironment(
    'MAPLIBRE_EXPERIMENTAL_CORE',
    defaultValue: false,
  );

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async {
    if (_experimentalCore) {
      return MapLibreFlutterAndroidCoreController.create(style, options);
    }
    return MapLibreFlutterAndroidController(style, options);
  }
}
