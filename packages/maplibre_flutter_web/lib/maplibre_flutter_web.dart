import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'src/maplibre_flutter_web_controller.dart';

/// The web implementation of `maplibre_flutter`.
///
/// Registered via `pluginClass` in pubspec.yaml; the web registrant passes a
/// [Registrar] (unused — there is no message channel on the data path). Web is
/// part of the same tier model as mobile (CLAUDE.md §3): it renders with
/// maplibre-gl-js inside an `HtmlElementView` and delegates to
/// [MapLibreFlutterWebController].
class MapLibreFlutterWeb extends MapLibreFlutterPlatform {
  /// Called by the Flutter web plugin registrant to install this implementation.
  static void registerWith(Registrar registrar) {
    MapLibreFlutterPlatform.instance = MapLibreFlutterWeb();
  }

  @override
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) => MapLibreFlutterWebController.create(style, options);
}
