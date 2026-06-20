/// `dart:js_interop` contract for the **experimental** native-core web renderer.
///
/// This describes the JavaScript surface that an Emscripten/WASM build of
/// `maplibre_flutter_core` (MapLibre Native, `mbgl-core`) must expose. It is the
/// web analogue of the C ABI in
/// `packages/maplibre_flutter_core/src/maplibre_flutter_core.h` — the same engine,
/// the same operations, surfaced to JS instead of to Dart FFI.
///
/// Nothing here runs until the `MAPLIBRE_WEB_CORE` build flag selects this path
/// AND the WASM artifact is built and served (see
/// `docs/experimental-web-core-wasm.md`). The default web renderer remains
/// maplibre-gl-js (`maplibre_gl_interop.dart`).
///
/// **Coordinate order:** unlike maplibre-gl-js, this surface takes `lat, lng`
/// directly (matching our `LatLng` and the C ABI `mbl_map_set_camera`), so there
/// is no `[lng, lat]` flip on this boundary.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The Emscripten module factory, exposed on `window` by a `MODULARIZE=1`,
/// `EXPORT_NAME=MaplibreFlutterCore` build. Calling it instantiates the WASM
/// module and resolves once the runtime is ready.
///
/// Emscripten locates the sibling `.wasm` relative to the `.js` glue by default;
/// override with a `locateFile` module arg only if they are served apart (see the
/// design doc).
@JS('MaplibreFlutterCore')
external JSPromise<CoreModule> instantiateCoreModule(CoreModuleArg arg);

/// Partial Emscripten Module config passed to the factory. We set
/// [mainScriptUrlOrBlob] because the loader injects the glue `<script>` dynamically
/// — `document.currentScript` is then null, so without this Emscripten cannot
/// resolve its own pthread-worker / `.wasm` URLs and startup hangs at
/// `library_fetch_init`.
extension type CoreModuleArg._(JSObject _) implements JSObject {
  external factory CoreModuleArg({String mainScriptUrlOrBlob});
}

/// A ready Emscripten module instance. Factory for maps; one module instance can
/// host one rendering context, so each map gets its own module (see the design
/// doc's "multiple maps" note).
extension type CoreModule._(JSObject _) implements JSObject {
  /// Builds a map that renders into [CoreMapOptions.canvas]. Mirrors
  /// `mbl_map_create`.
  external CoreMap createMap(CoreMapOptions options);
}

/// Object literal for [CoreModule.createMap]. Named-only parameters emit a JS
/// `{...}` literal, omitting anything left unset.
extension type CoreMapOptions._(JSObject _) implements JSObject {
  external factory CoreMapOptions({
    /// The visible canvas the WebGPU/WebGL2 context renders into.
    web.HTMLCanvasElement canvas,

    /// Style URL, asset path, or inline style JSON.
    String styleUri,

    /// Initial camera (lat, lng — not flipped).
    double lat,
    double lng,
    double zoom,
    double bearing,
    double pitch,

    /// CSS-to-device pixel ratio for the backing store (`window.devicePixelRatio`).
    double pixelRatio,

    /// Continuous (true) vs Static (false) render mode — see the C ABI
    /// `mbl_map_create` `continuous` flag.
    bool continuous,
  });
}

/// A live map. Operations mirror the C ABI one-for-one; the WASM glue forwards
/// them onto the engine's render loop.
extension type CoreMap._(JSObject _) implements JSObject {
  /// `mbl_map_set_style`.
  external void setStyle(String styleUri);

  /// `mbl_map_set_camera` (lat, lng — not flipped).
  external void setCamera(
    double lat,
    double lng,
    double zoom,
    double bearing,
    double pitch,
  );

  /// `mbl_map_get_camera` (returns cached state).
  external CoreCamera getCamera();

  /// `mbl_map_resize`. [width]/[height] are device pixels.
  external void resize(double width, double height, double pixelRatio);

  /// `mbl_map_move_by` — shared-desktop-tier pan primitive (logical pixels).
  external void moveBy(double dx, double dy);

  /// `mbl_map_scale_by` — shared-desktop-tier zoom primitive (logical pixels).
  external void scaleBy(double scale, double anchorX, double anchorY);

  /// Eased camera transition over [durationMs] (the fly-to path), stepped by the
  /// module's render loop.
  external void animateTo(
    double lat,
    double lng,
    double zoom,
    double bearing,
    double pitch,
    double durationMs,
  );

  /// Registers a one-shot [callback] fired once the initial style has loaded and
  /// the first frame is on screen — the web analogue of `mbl_map_await_frame` /
  /// the frame callback, used to complete the controller's `onReady`.
  external void onReady(JSFunction callback);

  /// `mbl_map_destroy` — stop the render loop and release the context.
  external void destroy();
}

/// Camera snapshot returned by [CoreMap.getCamera] (lat, lng — not flipped).
extension type CoreCamera._(JSObject _) implements JSObject {
  external double get lat;
  external double get lng;
  external double get zoom;
  external double get bearing;
  external double get pitch;
}
