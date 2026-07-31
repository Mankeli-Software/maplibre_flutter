/// Optional capability: relative rotation and tilt, for the shared Dart gesture
/// layer.
///
/// Feature-detected with `is`, exactly like [MapLibreGestureHandler] — a
/// controller that does not implement it simply gets no rotate or tilt gesture,
/// and still pans and zooms.
///
/// **Why this is a separate interface rather than two more members on
/// [MapLibreGestureHandler].** Every core controller declares that one under
/// `implements`, and Dart's `implements` requires each member to be redeclared
/// even when the interface supplies a body — so adding a method there is a hard
/// compile break in five packages plus the widget test fakes, not a soft one. A
/// "default no-op body" does not rescue it. It would also force the deliberately
/// abstaining `maplibre_flutter_web_gljs` controller (maplibre-gl-js handles its
/// own gestures on the DOM element) into a decision it should not have to make.
/// Feature-detected capabilities are how this codebase adds abilities without
/// rippling through every implementation — see [MapLibreStyleLayers],
/// [MapLibreModelHost] and [MapLibreResizeMaskHint].
///
/// **Why rotate and tilt share one interface.** They land from one C ABI change
/// and one recognizer, and no renderer can plausibly offer one without the
/// other. Splitting them would be contract churn for nothing.
abstract interface class MapLibreRotateHandler {
  /// Turns the map CONTENT clockwise by [degrees] about the anchor.
  ///
  /// The anchor is in logical pixels, top-left origin — the same space as
  /// [MapLibreGestureHandler.scaleBy]'s anchor and the widget's own gesture
  /// coordinates, and it passes through to the engine unflipped.
  ///
  /// Positive is clockwise, matching Flutter's `ScaleUpdateDetails.rotation`.
  /// Note that this is the opposite direction to `MapCamera.bearing`, which is
  /// the compass direction pointing up and therefore DECREASES as the content
  /// turns clockwise; implementations must not re-derive that sign, because the
  /// engine shim already owns it.
  void rotateBy(double degrees, double anchorX, double anchorY);

  /// Tilts by [degrees] about the viewport centre — positive tilts away from a
  /// straight-down view, toward the horizon.
  ///
  /// The engine clamps the result to 0..60 degrees, so callers need no clamp of
  /// their own.
  void pitchBy(double degrees);
}
