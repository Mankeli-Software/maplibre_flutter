import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'maplibre_map_controller.dart';
import 'map_options.dart';

/// The interface every platform implementation of `maplibre_flutter` extends.
///
/// Implementations register themselves by setting [instance] from their
/// `registerWith` entrypoint. App code never touches this class directly — it
/// uses the `maplibre_flutter` package, which talks to [instance].
///
/// We extend [PlatformInterface] (not just `implements`) so a private token
/// guards against implementations that forget to call `super`, per Flutter's
/// federated-plugin guidance (CLAUDE.md §7 layer 1).
abstract class MapLibreFlutterPlatform extends PlatformInterface {
  MapLibreFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static MapLibreFlutterPlatform? _instance;

  /// The registered implementation.
  ///
  /// Throws [UnimplementedError] until a platform package registers one; there
  /// is deliberately no default `MethodChannel` implementation (CLAUDE.md §10:
  /// no method channels on the data path).
  static MapLibreFlutterPlatform get instance {
    final i = _instance;
    if (i == null) {
      throw UnimplementedError(
        'No MapLibreFlutterPlatform registered. Did the platform package run '
        'its registerWith()?',
      );
    }
    return i;
  }

  static set instance(MapLibreFlutterPlatform value) {
    PlatformInterface.verify(value, _token);
    _instance = value;
  }

  /// Create a map and return a controller bound to its render handle.
  Future<MapLibreMapController> createMap(MapOptions options) {
    throw UnimplementedError('createMap() has not been implemented.');
  }
}
