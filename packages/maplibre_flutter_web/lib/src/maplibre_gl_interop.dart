/// `dart:js_interop` bindings to the parts of maplibre-gl-js (the global
/// `maplibregl` object) that the web controller drives.
///
/// These are extension types over `package:web`'s [JSObject] — zero-cost at
/// runtime and WASM-safe. We use only `dart:js_interop` (never the legacy
/// `dart:js`/`package:js`), per CLAUDE.md §5.
///
/// **Coordinate order:** maplibre-gl-js camera centers are `[lng, lat]` arrays —
/// the *reverse* of our `LatLng(lat, lng)`. Convert at every boundary crossing
/// (the controller does this in `_lngLat` / `getCamera`).
library;

import 'dart:js_interop';

/// A live `maplibregl.Map` instance (`new maplibregl.Map({...})`).
@JS('maplibregl.Map')
extension type MaplibreMap._(JSObject _) implements JSObject {
  /// Constructs the map on the element passed as [MaplibreMapOptions.container].
  external MaplibreMap(MaplibreMapOptions options);

  /// Replaces the active style. [style] is a URL string or a style-spec JSON
  /// object. Does not re-fire `'load'`; listen for `'styledata'` to detect the
  /// swap completing.
  external void setStyle(JSAny style);

  /// Jumps the camera instantly (no animation).
  external void jumpTo(CameraLiteral options);

  /// Animates the camera at a constant rate.
  external void easeTo(CameraLiteral options);

  /// Animates the camera along a flight curve (zoom dips mid-flight).
  external void flyTo(CameraLiteral options);

  /// Current center as a `{lng, lat}` object.
  external LngLat getCenter();
  external double getZoom();
  external double getBearing();
  external double getPitch();

  /// Recomputes the map size after its container element changed size.
  external void resize();

  /// Disposes the map: releases the WebGL context, web worker, DOM nodes and
  /// event bindings. The instance must not be used afterwards.
  external void remove();

  /// Subscribes [listener] to a map event (e.g. `'load'`, `'styledata'`).
  external void on(String type, JSFunction listener);

  /// Removes a listener previously added with [on].
  external void off(String type, JSFunction listener);
}

/// A geographic point as returned by [MaplibreMap.getCenter].
extension type LngLat._(JSObject _) implements JSObject {
  external double get lng;
  external double get lat;
}

/// Object literal for the `maplibregl.Map` constructor. Named-only parameters
/// emit a JS `{...}` literal, omitting any argument left unset.
extension type MaplibreMapOptions._(JSObject _) implements JSObject {
  external factory MaplibreMapOptions({
    /// The actual host `HTMLElement` (not an id string) — avoids DOM-id timing.
    JSObject container,

    /// Style URL string or style-spec JSON.
    JSAny style,

    /// Initial center as `[lng, lat]`.
    JSArray<JSNumber> center,
    double zoom,
    double bearing,
    double pitch,
  });
}

/// Object literal shared by [MaplibreMap.jumpTo], [MaplibreMap.easeTo] and
/// [MaplibreMap.flyTo]. Unset fields are omitted from the emitted JS literal, so
/// a plain `jumpTo` target carries no animation keys.
extension type CameraLiteral._(JSObject _) implements JSObject {
  external factory CameraLiteral({
    /// Target center as `[lng, lat]`.
    JSArray<JSNumber> center,
    double zoom,
    double bearing,
    double pitch,

    /// Animation length in milliseconds (easeTo defaults to 500; flyTo derives
    /// its length from speed/curve unless this is set).
    double duration,

    /// When true, the animation runs even if the OS requests reduced motion.
    bool essential,
  });
}
