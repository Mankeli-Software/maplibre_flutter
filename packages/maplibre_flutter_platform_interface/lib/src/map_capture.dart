import 'snapshot.dart';

/// Optional capability: a platform controller that can hand back the pixels of
/// the map **currently on screen**.
///
/// Feature-detected with `is`, like the other capabilities (CLAUDE.md §3). The
/// five `mbgl-core` tiers implement it — they already own the frame — and the
/// web tiers do not, because the map there is a DOM canvas that Flutter never
/// sees the pixels of.
///
/// Distinct from `MapLibreSnapshotter`, and the difference is the whole point:
/// the snapshotter renders a NEW off-screen map from a style and a camera, so it
/// costs a full load and can be pointed anywhere. This returns the frame the
/// user is looking at — the current camera, the current style, whatever tiles
/// have actually arrived — which is what a "share this view" button means, and
/// which no amount of re-rendering can reproduce exactly.
///
/// Both produce a [MapSnapshot], so a caller can treat the two the same way.
abstract interface class MapLibreMapCapture {
  /// The latest rendered frame, or null if none exists yet.
  ///
  /// Null rather than an exception, and rather than waiting: before the first
  /// frame there is genuinely nothing, and a capture call that blocks until one
  /// arrives would hang for as long as the network does. Await
  /// `controller.onReady` — or `onIdle`, if the point is a fully-loaded view —
  /// and call again.
  ///
  /// The frame is whatever the renderer last published, so on a Continuous-mode
  /// map (which every shipped tier is) it can be mid-load: tiles still
  /// streaming, labels not yet placed. That is what is on screen, which is the
  /// contract — but it is why a screenshot taken immediately after a camera move
  /// looks unfinished, and why `onIdle` is the signal to wait for.
  Future<MapSnapshot?> captureFrame();
}
