/// Optional relative-camera control for the shared desktop gesture layer.
///
/// The desktop (texture) controllers also implement this so the `MapLibreMap`
/// widget can drive pan/zoom from Flutter gestures — the desktop tier handles
/// gestures in Dart (CLAUDE.md §3). The mobile platform-view controllers do not
/// implement it (their native views handle gestures), so the widget skips its
/// gesture layer for them. Deltas and anchors are in logical pixels.
abstract interface class MapLibreGestureHandler {
  /// Pans the map by a screen-space delta in logical pixels.
  void moveBy(double dx, double dy);

  /// Zooms by [scale] (> 1 zooms in) about the anchor point in logical pixels.
  void scaleBy(double scale, double anchorX, double anchorY);
}
