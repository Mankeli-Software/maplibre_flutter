import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_android_controller.dart';

/// The **opt-in** MapLibre Android SDK implementation of `maplibre_flutter`.
///
/// The default Android renderer is the shared `mbgl-core` engine (the
/// `maplibre_flutter_android` package, endorsed automatically). Add this package
/// to your app's `pubspec.yaml` to render with the **MapLibre Android SDK**
/// instead — native `MapView` inside an `AndroidView`, driven over jnigen — for
/// A/B comparison or to use the SDK's native gesture/annotation/location stack.
/// As a direct app dependency it overrides the endorsed core default.
///
/// [createMap] returns a [PlatformViewHandle]; the native
/// `MaplibreFlutterAndroidSdkPlugin` (registered via `pluginClass`) provides the
/// `AndroidView` factory.
class MapLibreFlutterAndroidSdk extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterAndroidSdk();
  }

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) async => MapLibreFlutterAndroidController(style, options);
}
