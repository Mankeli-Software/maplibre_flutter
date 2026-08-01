import 'lat_lng.dart';
import 'lat_lng_bounds.dart';
import 'camera.dart';

/// Init-only map configuration — the first bucket of CLAUDE.md §3's three-bucket
/// rule: set at construction, never changed afterwards.
///
/// Everything here has an imperative counterpart on `controller.camera`. Both
/// exist because they answer different questions: the constraints below apply
/// **before the first frame**, so a map that must never show the whole world
/// never does, whereas setting them after `onReady` means one frame at an
/// unconstrained camera. gl-js draws the same distinction (`minZoom` and
/// friends are both `MapOptions` fields and setters).
class MapOptions {
  const MapOptions({
    this.initialCamera = const MapCamera(center: LatLng(0, 0)),
    this.minZoom,
    this.maxZoom,
    this.minPitch,
    this.maxPitch,
    this.maxBounds,
  });

  /// Camera the map starts at before any user interaction. Use the controller's
  /// camera methods to move afterwards.
  final MapCamera initialCamera;

  /// The furthest out the map can zoom — gl-js `minZoom`. Null leaves mbgl's
  /// default (0).
  final double? minZoom;

  /// The closest the map can zoom — gl-js `maxZoom`. Null leaves mbgl's default
  /// (22).
  final double? maxZoom;

  /// The flattest pitch allowed — gl-js `minPitch`. Null leaves mbgl's default
  /// (0).
  final double? minPitch;

  /// The steepest pitch allowed — gl-js `maxPitch`.
  ///
  /// **mbgl clamps this to 60° regardless** (`DEFAULT_PITCH_MAX`), so a larger
  /// value is accepted and then ignored by the engine, not by us.
  final double? maxPitch;

  /// The region the map is held inside — gl-js `maxBounds`.
  ///
  /// gl-js semantics: the whole VIEWPORT is kept within these bounds, so you
  /// cannot pan until only a corner of the region is visible. mbgl's own
  /// `BoundOptions` constrains the camera CENTRE under the same word, which is
  /// a weaker promise; the controller sets the constrain mode to match gl-js
  /// rather than shipping Android semantics under a gl-js name.
  final LatLngBounds? maxBounds;

  /// Whether anything here constrains the camera — lets a tier skip the whole
  /// apply step, which is a render-thread round trip, on the common case.
  bool get hasConstraints =>
      minZoom != null ||
      maxZoom != null ||
      minPitch != null ||
      maxPitch != null ||
      maxBounds != null;

  @override
  bool operator ==(Object other) =>
      other is MapOptions &&
      other.initialCamera == initialCamera &&
      other.minZoom == minZoom &&
      other.maxZoom == maxZoom &&
      other.minPitch == minPitch &&
      other.maxPitch == maxPitch &&
      other.maxBounds == maxBounds;

  @override
  int get hashCode => Object.hash(
    initialCamera,
    minZoom,
    maxZoom,
    minPitch,
    maxPitch,
    maxBounds,
  );
}
