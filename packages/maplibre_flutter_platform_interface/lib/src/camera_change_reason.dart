/// Why the camera moved.
///
/// Mirrors Apple's `MLNCameraChangeReason` (`MLNCameraChangeReason.h`) value for
/// value. That SDK is the reference here because the other two have nothing as
/// good: gl-js has no reason type at all — the nearest thing is sniffing
/// `e.originalEvent` on a `movestart` — and the Android SDK offers three coarse
/// ints (`REASON_API_GESTURE`, `REASON_DEVELOPER_ANIMATION`,
/// `REASON_API_ANIMATION`), which [MapCameraChangeReasons.isGesture] reproduces.
///
/// Apple ships this as an `NS_OPTIONS` bitmask; the Dart rendering is a
/// `Set<MapCameraChangeReason>`, so `MLNCameraChangeReasonNone` is simply the
/// empty set and testing a reason is `contains` rather than a mask.
///
/// **The engine cannot supply this.** mbgl's `MapObserver` carries only
/// `CameraChangeMode {Immediate, Animated}` (`include/mbgl/map/map_observer.hpp`),
/// so every SDK synthesises the richer reason in its own platform layer — and
/// ours is in Dart, which is the one place that knows a pan from a pinch from a
/// twist from a shove.
enum MapCameraChangeReason {
  /// A public API that moves the camera was called.
  ///
  /// Apple sets this for some gestures too, notably alongside [resetNorth].
  programmatic,

  /// The compass was tapped to put north back at the top.
  resetNorth,

  /// The user panned the map — a one-finger drag.
  gesturePan,

  /// The user pinched to zoom.
  gesturePinch,

  /// The user twisted two fingers to rotate.
  gestureRotate,

  /// The user zoomed in with a one-finger double tap.
  gestureZoomIn,

  /// The user zoomed out with a two-finger single tap.
  gestureZoomOut,

  /// The user quick-zoomed: tap, then press and drag up or down.
  gestureOneFingerZoom,

  /// The user tilted the map by dragging two fingers — a shove.
  gestureTilt,

  /// An in-flight transition was superseded or cancelled.
  transitionCancelled;

  /// Every gesture-driven reason. Android collapses exactly this group into its
  /// single `REASON_API_GESTURE`.
  static const Set<MapCameraChangeReason> anyGesture = {
    gesturePan,
    gesturePinch,
    gestureRotate,
    gestureZoomIn,
    gestureZoomOut,
    gestureOneFingerZoom,
    gestureTilt,
  };

  /// Every reason that changes the zoom level.
  static const Set<MapCameraChangeReason> anyZoom = {
    gesturePinch,
    gestureZoomIn,
    gestureZoomOut,
    gestureOneFingerZoom,
  };

  /// Every reason that changes the bearing — the set Apple's own header uses as
  /// its worked example of combining these.
  static const Set<MapCameraChangeReason> anyRotation = {
    resetNorth,
    gestureRotate,
  };

  /// Whether this reason came from the user rather than from app code.
  bool get isGesture => anyGesture.contains(this);
}

/// Reading a set of [MapCameraChangeReason]s without spelling out the groups.
extension MapCameraChangeReasons on Set<MapCameraChangeReason> {
  /// Whether the user caused this — Android's `REASON_API_GESTURE`.
  bool get isGesture => any(MapCameraChangeReason.anyGesture.contains);

  /// Whether app code caused this.
  bool get isProgrammatic =>
      contains(MapCameraChangeReason.programmatic) ||
      contains(MapCameraChangeReason.resetNorth);

  /// Whether the zoom level changed.
  bool get isZoom => any(MapCameraChangeReason.anyZoom.contains);

  /// Whether the bearing changed.
  bool get isRotation => any(MapCameraChangeReason.anyRotation.contains);

  /// Whether the pitch changed.
  bool get isTilt => contains(MapCameraChangeReason.gestureTilt);

  /// Whether a transition was superseded or cancelled.
  bool get isCancelled => contains(MapCameraChangeReason.transitionCancelled);
}
