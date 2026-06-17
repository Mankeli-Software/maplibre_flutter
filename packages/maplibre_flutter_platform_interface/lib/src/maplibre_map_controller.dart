import 'camera.dart';
import 'render_handle.dart';

/// Handle to one live map instance.
///
/// Returned by [MapLibreFlutterPlatform.createMap]. The contract is identical
/// on every platform; only [renderHandle] reveals how the map is embedded.
abstract class MapLibreMapController {
  /// How the app-facing widget should embed this map (view vs texture vs DOM).
  MapLibreRenderHandle get renderHandle;

  /// Completes once the native map exists and has finished loading its initial
  /// style. Until then [getCamera] reports the initial camera and
  /// [moveCamera]/[setStyle] are best-effort no-ops, so callers should await
  /// this before driving the map. Does not complete if the map is disposed
  /// before it becomes ready.
  Future<void> get onReady;

  /// Current camera as last reported by the native side.
  Future<MapCamera> getCamera();

  /// Move the camera. Implementations animate when [duration] is non-null.
  Future<void> moveCamera(MapCamera camera, {Duration? duration});

  /// Replace the active style (URL, asset path, or inline JSON).
  Future<void> setStyle(String styleUri);

  /// Release native resources, callbacks, and the texture/view registration.
  Future<void> dispose();
}
