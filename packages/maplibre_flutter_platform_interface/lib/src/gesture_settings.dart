import 'package:flutter/foundation.dart';

/// Which gestures the map responds to.
///
/// One immutable container rather than a widget property per toggle, so the set
/// can grow without `MapLibreMap`'s constructor growing with it, and so
/// `didUpdateWidget` can diff it with a single `==`.
///
/// **Named after the Android SDK's `UiSettings`**, per CLAUDE.md §9: gl-js
/// spells these `dragPan` / `scrollZoom` / `dragRotate`, which are descriptions
/// of *mouse* input and mean nothing on a phone — and `google_maps_flutter` and
/// `maplibre_gl` have both already converged on `…GesturesEnabled`.
///
/// **Only gestures that actually exist are listed here.** There is deliberately
/// no `quickZoomEnabled` (the one-finger double-tap-hold-drag): the gesture is
/// not implemented, and a toggle for a gesture that never fires is worse than
/// its absence — it reads as a feature and silently does nothing.
@immutable
class MapGestureSettings {
  const MapGestureSettings({
    this.interactive = true,
    this.scrollGesturesEnabled = true,
    this.zoomGesturesEnabled = true,
    this.rotateGesturesEnabled = true,
    this.tiltGesturesEnabled = true,
    this.doubleTapZoomEnabled = true,
  });

  /// Nothing at all: a map the user cannot pan, zoom, rotate or tilt.
  static const MapGestureSettings none = MapGestureSettings(interactive: false);

  /// The master switch. `false` detaches the whole gesture layer.
  ///
  /// **Taps still work.** `MapLibreMap.onTap` keeps firing, which is both what
  /// every upstream SDK does and the useful behaviour: the reason to build a
  /// non-interactive map — a locator in a form, a thumbnail in a list — is
  /// usually that tapping it should open a real one.
  ///
  /// Cheaper than setting the four toggles false, and not equivalent: this also
  /// removes the global pointer route the desktop gesture layer installs, so a
  /// non-interactive map costs nothing per pointer event anywhere on screen.
  final bool interactive;

  /// Whether the user can pan — a one-finger drag, or a trackpad two-finger
  /// pan.
  final bool scrollGesturesEnabled;

  /// Whether the user can zoom — a pinch, a trackpad pinch, or a mouse wheel.
  ///
  /// Covers all three deliberately: Android's single `zoomGesturesEnabled` is
  /// the name policy's baseline, and nothing has yet needed the wheel separated
  /// from the pinch. If something does, CLAUDE.md §9 says to split it with the
  /// same `…Enabled` suffix rather than importing gl-js's `scrollZoom`.
  ///
  /// To stop the wheel reaching a map inside a scrolling page, this is the
  /// wrong tool — wrap the overlay in `AbsorbPointerSignal` instead, which
  /// leaves pinch-zoom working.
  final bool zoomGesturesEnabled;

  /// Whether the user can turn the map — a two-finger twist, or a
  /// secondary-button / ctrl drag with a mouse.
  final bool rotateGesturesEnabled;

  /// Whether the user can tilt the map — a two-finger vertical "shove", or the
  /// vertical component of a secondary-button / ctrl drag.
  ///
  /// The engine clamps pitch to 0..60 degrees regardless.
  final bool tiltGesturesEnabled;

  /// Whether a double tap zooms in one level about the tapped point.
  ///
  /// Separate from [zoomGesturesEnabled], following Android, which gates the
  /// gesture on both. Apple has only the one toggle; the finer control is worth
  /// the divergence because a double tap is the gesture most likely to fight an
  /// app's own — a map inside a gallery where double tap means something else.
  final bool doubleTapZoomEnabled;

  MapGestureSettings copyWith({
    bool? interactive,
    bool? scrollGesturesEnabled,
    bool? zoomGesturesEnabled,
    bool? rotateGesturesEnabled,
    bool? tiltGesturesEnabled,
    bool? doubleTapZoomEnabled,
  }) => MapGestureSettings(
    interactive: interactive ?? this.interactive,
    scrollGesturesEnabled: scrollGesturesEnabled ?? this.scrollGesturesEnabled,
    zoomGesturesEnabled: zoomGesturesEnabled ?? this.zoomGesturesEnabled,
    rotateGesturesEnabled: rotateGesturesEnabled ?? this.rotateGesturesEnabled,
    tiltGesturesEnabled: tiltGesturesEnabled ?? this.tiltGesturesEnabled,
    doubleTapZoomEnabled: doubleTapZoomEnabled ?? this.doubleTapZoomEnabled,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MapGestureSettings &&
          other.interactive == interactive &&
          other.scrollGesturesEnabled == scrollGesturesEnabled &&
          other.zoomGesturesEnabled == zoomGesturesEnabled &&
          other.rotateGesturesEnabled == rotateGesturesEnabled &&
          other.tiltGesturesEnabled == tiltGesturesEnabled &&
          other.doubleTapZoomEnabled == doubleTapZoomEnabled;

  @override
  int get hashCode => Object.hash(
    interactive,
    scrollGesturesEnabled,
    zoomGesturesEnabled,
    rotateGesturesEnabled,
    tiltGesturesEnabled,
    doubleTapZoomEnabled,
  );

  @override
  String toString() =>
      'MapGestureSettings(interactive: $interactive, '
      'scroll: $scrollGesturesEnabled, zoom: $zoomGesturesEnabled, '
      'rotate: $rotateGesturesEnabled, tilt: $tiltGesturesEnabled, '
      'doubleTapZoom: $doubleTapZoomEnabled)';
}
