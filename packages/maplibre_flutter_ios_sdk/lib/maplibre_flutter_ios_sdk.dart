import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_ios_controller.dart';

/// The **opt-in** MapLibre Apple SDK implementation of `maplibre_flutter`.
///
/// The default iOS renderer is the shared `mbgl-core` engine (the
/// `maplibre_flutter_ios` package, endorsed automatically). Add this package to
/// your app's `pubspec.yaml` to render with the **MapLibre Apple SDK** instead —
/// native `MLNMapView` inside a `UiKitView`, driven over swiftgen — for A/B
/// comparison or to use the SDK's native gesture/annotation/location stack. As a
/// direct app dependency it overrides the endorsed core default.
///
/// [createMap] returns a [PlatformViewHandle]; the native
/// `MaplibreFlutterIosSdkPlugin` (registered via `pluginClass`) provides the
/// `UiKitView` factory.
class MapLibreFlutterIosSdk extends MapLibreFlutterPlatform {
  /// Called by the Flutter plugin registrant to install this implementation.
  static void registerWith() {
    MapLibreFlutterPlatform.instance = MapLibreFlutterIosSdk();
  }

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) => Future.value(MapLibreFlutterIosController(style, options));
}
