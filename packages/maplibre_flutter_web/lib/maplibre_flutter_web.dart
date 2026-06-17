import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// The web implementation of `maplibre_flutter`.
///
/// Registered via `pluginClass` in pubspec.yaml; the web registrant passes a
/// [Registrar]. maplibre-gl-js rendering (HtmlElementView + pointer_interceptor)
/// is wired in the web build-order step (CLAUDE.md §8); for now [createMap]
/// throws so the wiring is unmistakable.
class MapLibreFlutterWeb extends MapLibreFlutterPlatform {
  /// Called by the Flutter web plugin registrant to install this implementation.
  static void registerWith(Registrar registrar) {
    MapLibreFlutterPlatform.instance = MapLibreFlutterWeb();
  }

  @override
  Future<MapLibreMapController> createMap(MapOptions options) {
    throw UnimplementedError(
      'maplibre_flutter_web createMap() is not implemented yet (see CLAUDE.md §8).',
    );
  }
}
