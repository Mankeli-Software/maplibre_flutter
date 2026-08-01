import 'package:flutter/foundation.dart';

/// Something the map could not do.
///
/// Mirrors gl-js's `map.on('error', …)` — adapted to a `sealed` type and a
/// `Stream` rather than a string-keyed listener, so a handler can `switch` over
/// the cases exhaustively and the compiler checks it. That adaptation is
/// recorded in CLAUDE.md §9.
///
/// Almost everything mbgl does is asynchronous, so almost every failure arrives
/// here rather than as a thrown exception: a style URL that 404s, a glyph range
/// the tile server does not serve, a sprite that will not parse. Before this
/// channel existed each of them was a blank map and no signal at all.
@immutable
sealed class MapLibreError {
  const MapLibreError(this.message);

  /// What the engine said. Not localised, and shaped for a log rather than for
  /// a user.
  final String message;

  @override
  String toString() => '$runtimeType($message)';
}

/// The style document could not be loaded or parsed.
///
/// The map is blank when this arrives, and stays blank. mbgl
/// `MapObserver::onDidFailLoadingMap`; gl-js reports the same thing on
/// `'error'`.
final class MapStyleError extends MapLibreError {
  const MapStyleError(super.message);
}

/// A font's glyph range could not be fetched.
///
/// Worth surfacing loudly: mbgl does not merely drop the text, it stops the
/// whole source that referenced the font from rendering — so a style naming one
/// font the tile server does not serve can make an entire dataset vanish.
final class MapGlyphsError extends MapLibreError {
  const MapGlyphsError(super.message);
}

/// A sprite sheet could not be loaded, so icons are missing.
final class MapSpriteError extends MapLibreError {
  const MapSpriteError(super.message);
}

/// The renderer raised while drawing a frame.
final class MapRenderError extends MapLibreError {
  const MapRenderError(super.message);
}

/// A command was accepted but could not be applied — removing a layer that is
/// not there, removing a source a layer still references, or issuing anything
/// before the render thread is up.
///
/// Every mutating style call returns `void` because it is applied on the render
/// thread, so this is the only way those failures can reach an app.
final class MapCommandError extends MapLibreError {
  const MapCommandError(super.message);
}

/// Anything else the engine logged at warning level or above.
///
/// The catch-all, and deliberately not empty: several real failures reach
/// mbgl's log and no observer callback — a glyph 404 is the notorious one.
final class MapEngineError extends MapLibreError {
  const MapEngineError(super.message);
}

/// Asynchronous events from the engine — the diagnostics channel.
///
/// An **optional capability**: feature-detect it with `is`, like the others
/// (CLAUDE.md §3). The five `mbgl-core` tiers implement it; the two web tiers
/// do not yet.
///
/// This is the capability the 2026-07-31 decision-log entry called
/// `MapLibreStyleEvents`. Renamed because it carries errors as well as style
/// events, and a name that says "style" would have to be worked around the
/// first time an app wanted [onError].
abstract interface class MapLibreMapEvents {
  /// Everything the map could not do. Broadcast, so late listeners are fine —
  /// but events emitted before the first listener attaches are not replayed.
  Stream<MapLibreError> get onError;

  /// Fires each time a style finishes loading — **every** time, not just the
  /// first.
  ///
  /// It has to repeat, because mbgl replaces the whole layer list on a style
  /// load: every source, layer and image an app added is dropped. Since
  /// `MapLibreMap.style` is a declarative widget property that can change on any
  /// rebuild, this is the only correct moment to re-apply them, and before this
  /// existed the workaround was a hardcoded delay.
  ///
  /// mbgl `MapObserver::onDidFinishLoadingStyle`; gl-js `styledata`; Apple
  /// `-mapView:didFinishLoadingStyle:`.
  Stream<void> get onStyleLoaded;

  /// The id of an image a layer asked for and the style does not have.
  ///
  /// Respond by registering it — `controller.layers.addImage` or
  /// `addWidgetIcon` — and the engine will pick it up. gl-js
  /// `styleimagemissing`.
  Stream<String> get onStyleImageMissing;
}
