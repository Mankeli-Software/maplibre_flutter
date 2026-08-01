import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart'
    show ChangeNotifier, Listenable, VoidCallback;

import 'lat_lng.dart';

/// Optional capability: a platform controller that can project between geographic
/// coordinates and the widget's screen space, and notify on every camera change.
///
/// Controllers whose renderer supports anchored widget overlays ("markers")
/// implement this — the default `mbgl-core` tiers (desktop + core-on-mobile) and
/// the web tiers. The `MapLibreMap` widget feature-detects it with `is` (exactly
/// like [MapLibreGestureHandler]); a controller that does not implement it simply
/// renders no overlay (graceful degradation), so this never ripples into every
/// platform implementation.
///
/// As a [Listenable], it fires its listeners on **every** camera change — each
/// gesture step, fly-to animation frame, inertia tick, and imperative move — so a
/// `Flow`-based overlay can reproject and stay glued to its map point without a
/// per-frame native round trip. Screen positions are in **logical pixels**,
/// top-left origin (the same space as [MapLibreGestureHandler] deltas/anchors and
/// the widget's own gesture coordinates).
abstract interface class MapLibreMapProjector implements Listenable {
  /// Projects each of [points] to a screen position, writing results into [out]
  /// (which must have the same length as [points]). When [visible] is supplied
  /// (same length), each entry is set to `false` for points behind the camera on
  /// a pitched view and `true` otherwise.
  ///
  /// Synchronous and cheap (pure math on a transform snapshot). Returns the
  /// camera generation used — a value that increases on every camera change —
  /// for optional frame correlation; before the first frame it returns 0 and
  /// leaves [out] unchanged.
  int project(List<LatLng> points, List<Offset> out, {List<bool>? visible});

  /// The geographic point under a screen position (logical pixels, top-left
  /// origin), for hit-testing a tap or dragging a marker. Null before the first
  /// frame (no transform yet).
  LatLng? unproject(Offset point);
}

/// Supplies the [Listenable] half of [MapLibreMapProjector] for controllers.
///
/// Mix this into a core controller and call [notifyCameraChanged] at every
/// camera choke point (move/scale/animation step). It owns a private
/// [ChangeNotifier] rather than the controller mixing in [ChangeNotifier]
/// directly, because the controllers' `dispose()` is `async` (returns
/// `Future<void>`) and would clash with [ChangeNotifier.dispose]'s `void`.
/// Remember to call [disposeCameraTick] from the controller's `dispose()`.
mixin MapLibreCameraTickNotifier implements Listenable {
  final _CameraTick _cameraTick = _CameraTick();

  @override
  void addListener(VoidCallback listener) => _cameraTick.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _cameraTick.removeListener(listener);

  /// Notifies overlay listeners that the camera changed (reproject now). Call
  /// after applying any camera move/scale/animation step.
  ///
  /// A no-op once [disposeCameraTick] has run. Controllers already guard their
  /// own `_disposed`, but an in-flight animation resolves through this from a
  /// microtask the controller no longer controls — and a `ChangeNotifier` used
  /// after disposal asserts.
  void notifyCameraChanged() {
    if (_cameraTickDisposed) return;
    _cameraTick.tick();
  }

  /// Wraps an **engine-driven** camera animation so the camera keeps ticking for
  /// its whole duration, and returns [animation] unchanged.
  ///
  /// Needed because `easeTo`/`flyTo`/`fitBounds` hand the transition to the
  /// engine, which runs it on its render thread and calls back only when it
  /// ENDS. Between the call and that callback the camera changes every frame
  /// with nothing on the Dart side to notice — so anchored widget overlays,
  /// which project against the presented frame, froze at the camera the flight
  /// started from and snapped into place when it landed. The Dart-stepped
  /// `moveCamera(duration:)` path never had this: it ticks at every step it
  /// applies. Engine-native markers were unaffected throughout, which is what
  /// made it look like an overlay bug rather than a missing notification.
  ///
  /// Ticking is reference-counted, so a flight superseded by another (each
  /// bumping the animation token) leaves the ticker running until the last one
  /// reports back rather than stopping it under its successor.
  Future<T> tickWhileAnimating<T>(Future<T> animation) {
    _animationsInFlight++;
    // Roughly a frame. Consumers that need per-frame accuracy re-project on
    // their own vsync ticker and use this only to know movement is in flight;
    // this rate is what everything else — a ListenableBuilder on the camera —
    // actually redraws at.
    _animationTicker ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => notifyCameraChanged(),
    );
    return animation.whenComplete(() {
      if (--_animationsInFlight > 0) return;
      _animationTicker?.cancel();
      _animationTicker = null;
      // One final tick: the last periodic fire lands before the transition's
      // own last frame, so without this the overlay can settle a frame stale.
      notifyCameraChanged();
    });
  }

  Timer? _animationTicker;
  int _animationsInFlight = 0;
  bool _cameraTickDisposed = false;

  /// Releases the camera-tick notifier. Call from the controller's `dispose()`.
  void disposeCameraTick() {
    if (_cameraTickDisposed) return;
    _cameraTickDisposed = true;
    _animationTicker?.cancel();
    _animationTicker = null;
    _animationsInFlight = 0;
    _cameraTick.dispose();
  }
}

/// Exposes [ChangeNotifier.notifyListeners] (which is `@protected`) as a public
/// [tick] for [MapLibreCameraTickNotifier].
class _CameraTick extends ChangeNotifier {
  void tick() => notifyListeners();
}
