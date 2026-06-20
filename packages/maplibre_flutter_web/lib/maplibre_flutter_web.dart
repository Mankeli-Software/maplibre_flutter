import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/core_web/core_web_controller.dart';
import 'src/maplibre_flutter_web_controller.dart';

/// The web implementation of `maplibre_flutter`.
///
/// Registered via `pluginClass` in pubspec.yaml; the web registrant passes a
/// [Registrar] (unused — there is no message channel on the data path). Web is
/// part of the same tier model as mobile (CLAUDE.md §3): by default it renders
/// with maplibre-gl-js inside an `HtmlElementView` and delegates to
/// [MapLibreFlutterWebController].
///
/// **Experimental:** when built with `--dart-define=MAPLIBRE_WEB_CORE=true`, it
/// instead renders with the native MapLibre engine (`mbgl-core`) compiled to
/// WASM ([MapLibreCoreWebController]) — the same engine as the desktop tier, so
/// feature parity is maintained in one place with no separate web SDK. This is a
/// build-time-flagged spike; the default (maplibre-gl-js) is unaffected. See
/// `docs/experimental-web-core-wasm.md`.
class MapLibreFlutterWeb extends MapLibreFlutterPlatform {
  /// Selects the experimental native-core WASM renderer over maplibre-gl-js.
  /// Compile-time const, so the unused path tree-shakes away.
  static const bool useNativeCore = bool.fromEnvironment(
    'MAPLIBRE_WEB_CORE',
    defaultValue: false,
  );

  /// Called by the Flutter web plugin registrant to install this implementation.
  static void registerWith(Registrar registrar) {
    MapLibreFlutterPlatform.instance = MapLibreFlutterWeb();
  }

  @override
  Future<MapLibreMapController> createMap(MapOptions options) => useNativeCore
      ? MapLibreCoreWebController.create(options)
      : MapLibreFlutterWebController.create(options);
}
