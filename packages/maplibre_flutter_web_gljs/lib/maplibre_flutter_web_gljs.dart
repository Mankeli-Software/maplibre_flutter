import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_web_controller.dart';

/// The **opt-in** maplibre-gl-js implementation of `maplibre_flutter` for web.
///
/// The default web renderer is `mbgl-core` compiled to WASM (the
/// `maplibre_flutter_web` package). Add this package to your app's `pubspec.yaml`
/// to render with **maplibre-gl-js** instead — the mature reference web renderer,
/// CDN-loaded, no special hosting headers — for A/B comparison or maximum browser
/// coverage. Because it `implements: maplibre_flutter` and is a *direct* app
/// dependency, it overrides the endorsed core default.
///
/// maplibre-gl-js owns pan/zoom/rotate gestures and inertia natively, so the
/// controller implements [MapLibreMapPlatformController] only (not
/// [MapLibreGestureHandler]); the app-facing widget skips its Dart gesture layer
/// for the resulting `ElementViewHandle`.
class MapLibreFlutterWebGljs extends MapLibreFlutterPlatform {
  /// Called by the Flutter web plugin registrant to install this implementation.
  static void registerWith(Registrar registrar) {
    MapLibreFlutterPlatform.instance = MapLibreFlutterWebGljs();
  }

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) => MapLibreFlutterWebController.create(style, options);
}
