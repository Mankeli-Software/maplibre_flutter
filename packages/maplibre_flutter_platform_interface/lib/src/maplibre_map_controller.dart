import 'dart:ui' show Size;

import 'camera.dart';
import 'render_handle.dart';

/// Handle to one live native map instance, created by a platform implementation.
///
/// Returned by [MapLibreFlutterPlatform.createMap]. App code does **not** use
/// this directly — it uses the app-facing `MapLibreMapController` (in the
/// `maplibre_flutter` package), which wraps one of these. The contract is
/// identical on every platform; only [renderHandle] reveals how the map is
/// embedded.
abstract class MapLibreMapPlatformController {
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

  /// Replace the active style (URL, asset path, or inline JSON). Driven by the
  /// widget's declarative `style` property — app code changes that, not this.
  Future<void> setStyle(String styleUri);

  /// Reports the embedding view's logical [size] and [devicePixelRatio] so the
  /// platform can size its render surface to match. The platform-view tier
  /// (mobile) auto-sizes its native view and ignores this; the desktop texture
  /// tier resizes its off-screen surface so the map fills the widget crisply
  /// and at the correct aspect ratio. Default: no-op.
  Future<void> resize(Size size, double devicePixelRatio) async {}

  /// Release native resources, callbacks, and the texture/view registration.
  Future<void> dispose();
}

/// Marker capability for texture tiers whose produced frame **lags** the widget
/// box during a resize (the slow CPU-readback desktop present — Windows today,
/// where GPU zero-copy is unavailable).
///
/// When a controller implements it, the `MapLibreMap` widget **masks** resizes:
/// while the window is actively being dragged it holds the native surface at one
/// size and cover-fits that frozen frame to the moving box (a small uniform crop,
/// not a stretch), then pushes the real resize once the drag settles and lets the
/// texture catch up. Because the widget controls when it resizes, it always knows
/// the frozen frame's size — no produced-size feedback from the native side.
///
/// Controllers that don't implement it (mobile/web own their surface; macOS
/// zero-copy catches up within a frame) resize live, so this stays an opt-in that
/// doesn't ripple into the other implementations — the same pattern as
/// [MapLibreGestureHandler].
abstract interface class MapLibreResizeMaskHint {}
