import 'camera.dart';
import 'render_handle.dart';

/// Handle to one live map instance.
///
/// Returned by [MapLibreFlutterPlatform.createMap]. The contract is identical
/// on every platform; only [renderHandle] reveals how the map is embedded.
abstract class MapLibreMapController {
  /// How the app-facing widget should embed this map (view vs texture vs DOM).
  MapLibreRenderHandle get renderHandle;

  /// Current camera as last reported by the native side.
  Future<MapCamera> getCamera();

  /// Move the camera. Implementations animate when [duration] is non-null.
  Future<void> moveCamera(MapCamera camera, {Duration? duration});

  /// Replace the active style (URL, asset path, or inline JSON).
  Future<void> setStyle(String styleUri);

  /// Release native resources, callbacks, and the texture/view registration.
  Future<void> dispose();
}
