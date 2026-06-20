import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show ValueListenable;

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

/// Optional capability for texture tiers whose produced frame can **lag** the
/// widget box during a resize (the slow CPU-readback desktop present, i.e.
/// Windows today). A controller that implements it exposes [textureSize] — the
/// size of the frame currently in the texture — so the `MapLibreMap` widget can
/// scale a still-old-size frame to the new box *uniformly* (`BoxFit.cover`)
/// instead of stretching it, turning the resize warp into a brief crop while the
/// render thread catches up.
///
/// Controllers that don't implement it (mobile/web own their surface; macOS
/// zero-copy catches up within a frame) make the widget render the bare texture,
/// so this stays an opt-in that doesn't ripple into the other implementations —
/// the same pattern as [MapLibreGestureHandler].
abstract interface class MapLibreTextureSizeProvider {
  /// The size (device pixels — only the aspect ratio is used) of the frame
  /// currently produced into the texture. Changes as the render thread catches
  /// up after a [MapLibreMapPlatformController.resize].
  ValueListenable<Size> get textureSize;
}
