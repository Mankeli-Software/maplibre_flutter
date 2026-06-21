import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/core_web/core_web_controller.dart';

/// The default web implementation of `maplibre_flutter`.
///
/// Registered via `pluginClass` in pubspec.yaml; the web registrant passes a
/// [Registrar] (unused — there is no message channel on the data path). Web
/// renders with the native MapLibre engine (`mbgl-core`) compiled to WebAssembly
/// ([MapLibreCoreWebController]) into a `<canvas>` inside an `HtmlElementView` —
/// the **same engine as every other platform**, so feature parity is maintained
/// in one place. See `docs/experimental-web-core-wasm.md` for the WASM artifact +
/// hosting (`COOP`/`COEP`) requirements.
///
/// To render with maplibre-gl-js instead (mature reference renderer, CDN-loaded,
/// no special hosting headers — e.g. for A/B testing or maximum browser
/// coverage), add the `maplibre_flutter_web_gljs` package to your app: as a
/// direct dependency it overrides this endorsed default.
class MapLibreFlutterWeb extends MapLibreFlutterPlatform {
  /// Called by the Flutter web plugin registrant to install this implementation.
  static void registerWith(Registrar registrar) {
    MapLibreFlutterPlatform.instance = MapLibreFlutterWeb();
  }

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) => MapLibreCoreWebController.create(style, options);
}
