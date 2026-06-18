# maplibre_flutter_web — implementation plan

Web tier (CLAUDE.md §3 Web row, §8 step 4). Branch: `feat/web-maplibre-gl-js` (off `main`,
independent of the in-flight Linux/Windows desktop-core work).

Web is the **only platform we can build + run end-to-end on this macOS dev machine**
(`flutter run -d chrome`), so it proceeds in parallel while Linux/Windows are taken on
real hardware elsewhere.

---

## 0. Architecture fit (what's already true)

The federated contract is render-agnostic and already supports web; nothing in the
platform-interface needs changing:

- `MapLibreRenderHandle` already has a `final class ElementViewHandle({viewType})`
  (`platform_interface/lib/src/render_handle.dart:49`).
- The app-facing widget already branches on it in `_embed`
  (`maplibre_flutter/lib/src/maplibre_map.dart:99`) — currently returns
  `_UnimplementedEmbed`. **This is the one app-facing change:** swap that for a real
  `HtmlElementView(viewType: viewType)`.
- `maplibre_flutter_web` already declares `pluginClass: MapLibreFlutterWeb` +
  `fileName: maplibre_flutter_web.dart` in pubspec (web uses a `flutter_web_plugins`
  `Registrar`, not `dartPluginClass`); `createMap()` is a deliberate `throw
  UnimplementedError`.

**Tier model:** web mirrors the **mobile tier**, not the desktop tier. maplibre-gl-js owns
gestures/inertia/zoom natively (like the Android/iOS SDKs own theirs), so the web controller
implements `MapLibreMapController` **only** — *not* `MapLibreGestureHandler`. The widget's
`_DesktopMapGestures` layer is correctly skipped for `ElementViewHandle` (it only attaches on
`TextureHandle` + a `MapLibreGestureHandler` controller). No Dart gesture code on web.

---

## 1. Locked dependency versions (live-verified 2026-06-18 — re-check pub.dev/npm at impl time per §10)

| Thing | Version | Notes |
| --- | --- | --- |
| maplibre-gl-js | **5.24.0** | latest stable 5.x. 6.0.0 is prerelease (`6.0.0-15`) — **do not** use. Pin exact `@5.24.0` in CDN URLs, not `@latest`/`^`. |
| `package:web` | **^1.1.1** | DOM bindings (`document`, `HTMLDivElement`, `HTMLScriptElement`, `HTMLLinkElement`). Replaces `dart:html`, WASM-safe. |
| `dart:js_interop` | SDK-bundled | **no pubspec entry** — core library, needs Dart 3.x (already have `sdk: ^3.12.2`). |
| `pointer_interceptor` | **^0.10.1+2** | example/consumer overlay dep only (see §6). NOT a dep of the app-facing widget. |
| `package:js` | — | **deprecated/discontinued — do not add.** |

CDN URLs (UMD, exposes global `maplibregl`):
- JS:  `https://unpkg.com/maplibre-gl@5.24.0/dist/maplibre-gl.js`
- CSS: `https://unpkg.com/maplibre-gl@5.24.0/dist/maplibre-gl.css` (**required** — markers/controls/popups break without it)
- jsdelivr mirror works identically (`https://cdn.jsdelivr.net/npm/maplibre-gl@5.24.0/dist/...`).

---

## 2. New files (all under `packages/maplibre_flutter_web/`)

```
lib/
  maplibre_flutter_web.dart                     # EXISTS — wire registerWith → controller
  src/
    maplibre_gl_interop.dart                    # NEW — dart:js_interop extension types over maplibre-gl-js
    maplibre_gl_loader.dart                     # NEW — inject <script>+<link>, await load, idempotent
    maplibre_flutter_web_controller.dart        # NEW — MapLibreMapController over the JS Map
test/
  maplibre_flutter_web_test.dart                # NEW — registerWith installs instance (VM-safe)
```

App-facing edit: `packages/maplibre_flutter/lib/src/maplibre_map.dart` — `ElementViewHandle`
branch.

Example edit: `packages/maplibre_flutter/example/lib/main.dart` + its `pubspec.yaml` —
wrap the FAB column in `PointerInterceptor`.

Integration test: `packages/maplibre_flutter/example/integration_test/web_map_test.dart`
(runs on chrome).

---

## 3. JS interop bindings — `src/maplibre_gl_interop.dart`

Modern `dart:js_interop` extension types over `package:web` `JSObject` (Dart ≥3.3; zero-cost,
WASM-safe). Bind only the surface the controller needs.

```dart
import 'dart:js_interop';

/// `new maplibregl.Map({...})`
@JS('maplibregl.Map')
extension type MaplibreMap._(JSObject _) implements JSObject {
  external MaplibreMap(MaplibreMapOptions options);

  external void setStyle(JSAny style);          // URL string or style JSON
  external void jumpTo(JSAny options);          // instant
  external void easeTo(JSAny options);          // {center,zoom,bearing,pitch,duration,essential}
  external void flyTo(JSAny options);           // {..., duration, essential}
  external LngLat getCenter();
  external double getZoom();
  external double getBearing();
  external double getPitch();
  external void resize();
  external void remove();                       // dispose: frees WebGL ctx + worker
  external void on(JSString type, JSFunction listener);
  external void off(JSString type, JSFunction listener);
}

extension type LngLat._(JSObject _) implements JSObject {
  external double get lng;
  external double get lat;
}

/// JS object literal — named-only params emit `{...}`, omitting absent keys.
extension type MaplibreMapOptions._(JSObject _) implements JSObject {
  external factory MaplibreMapOptions({
    JSAny container,        // pass the actual HTMLElement (not an id) — avoids id timing
    JSAny style,
    JSArray<JSNumber> center, // [lng, lat]  ← FLIP from LatLng(lat, lng)
    double zoom,
    double bearing,
    double pitch,
  });
}

/// Camera literal reused for jumpTo/easeTo/flyTo.
extension type CameraLiteral._(JSObject _) implements JSObject {
  external factory CameraLiteral({
    JSArray<JSNumber> center,
    double zoom,
    double bearing,
    double pitch,
    double duration,   // ms (easeTo default 500; pass to force flyTo length)
    bool essential,    // true → ignore prefers-reduced-motion (deterministic anim/test)
  });
}
```

**Gotchas baked in:**
- `center` is **`[lng, lat]`** — reverse of our `LatLng(lat, lng)`. Single most likely bug;
  convert at the boundary both ways (`getCenter().lng/.lat` → `LatLng(lat, lng)`).
- `getCenter()` returns a **LngLat object**, read `.lng`/`.lat` — never index `[0]/[1]`.
- All boundary values need explicit `.toJS` / `.toDart`; no implicit coercion. `[lng,lat]`
  → `<JSNumber>[lng.toJS, lat.toJS].toJS`.
- `@JS('maplibregl.Map')` resolves the namespaced global.

## 4. Script/CSS loader — `src/maplibre_gl_loader.dart`

Inject `<link rel=stylesheet>` + `<script>` into `document.head`, `await` script `onload`
before any `MaplibreMap(...)`. **Idempotent** (querySelector guard — survives hot reload /
multiple maps). Consumer escape hatch: if the script is already present (consumer added it to
`index.html`), detect + skip.

```dart
Future<void> ensureMaplibreLoaded() async {
  if (_loaded) return _loadFuture ??= _inject();   // memoise
  ...
}
```
- CSS appended first (non-blocking). Script: `HTMLScriptElement()..src=...`; wire
  `onload`/`onerror` as `.toJS` callbacks resolving a `Completer`. **Keep the callback
  closures referenced** until resolved (GC pitfall, §5d).
- **Decision: dynamic injection is the default** (zero-config DX), with index.html as a
  documented fallback for CSP-locked apps. Both major existing MapLibre Flutter web packages
  (`flutter-maplibre`, `maplibre_gl`) require manual index.html; we go one better with
  auto-injection + detect-and-skip, but README documents the manual path for CSP.

## 5. Controller — `src/maplibre_flutter_web_controller.dart`

`implements MapLibreMapController` (NOT `MapLibreGestureHandler`). Mirrors the macOS
controller's lifecycle (return early, gate real use on `onReady`), but the render handle is a
DOM view, not a texture.

**create(options):**
1. `await ensureMaplibreLoaded()`.
2. Mint a unique `viewType` (`maplibre_flutter/web/<id>`, monotonic counter — uniqueness is
   mandatory, collisions silently reuse a factory).
3. `ui_web.platformViewRegistry.registerViewFactory(viewType, (viewId) { ... return div; })`.
   Inside the factory (runs when the widget mounts the `HtmlElementView`, *after* createMap
   returns — like macOS returning before first frame):
   - create `HTMLDivElement()` with `style.width/height = '100%'`;
   - build `MaplibreMap(MaplibreMapOptions(container: div, style: styleUri.toJS,
     center: [lng,lat], zoom, bearing, pitch))`;
   - `map.on('load', ...)` → complete `_ready`; store map ref + keep the JS callback in a field.
4. Return controller immediately with `renderHandle = ElementViewHandle(viewType)`.

**methods** (all guard `_map == null` until the factory builds it — no-op/queue like the
other controllers' pre-ready window):
- `getCamera()` → read `getCenter().lng/.lat` + `getZoom/Bearing/Pitch`, flip to `LatLng(lat,lng)`.
- `moveCamera(c, {duration})` → `duration == null || <=0` ? `jumpTo` : `flyTo` with
  `duration: ms, essential: true`. (flyTo gives the nice arc; passing `duration` forces the
  length to match the other tiers' fixed-duration semantics. `essential:true` so it animates
  under prefers-reduced-motion.)
- `setStyle(uri)` → `map.setStyle(uri.toJS)`. Readiness of the *new* style is `'styledata'`/
  `'style.load'` (`'load'` does NOT re-fire) — only needed if we expose a style-ready future
  later; the button doesn't require it.
- `resize(size, dpr)` → `map.resize()` (the div is CSS-`100%`, maplibre reads container box +
  handles DPR itself; size args largely informational on web).
- `dispose()` → `map.remove()` (frees WebGL ctx — browsers cap ~16, leak = eventual render
  break), drop callback refs. Optionally unregister/clear the view.

**No `MaplibreMap` construction before the element exists** — that's why it lives in the
factory, not in `create()`.

## 6. App-facing widget — `maplibre_flutter/lib/src/maplibre_map.dart`

Replace the `ElementViewHandle` stub (`:99`):
```dart
case ElementViewHandle(:final viewType):
  return HtmlElementView(viewType: viewType);
```
`HtmlElementView` is in `package:flutter/widgets.dart` (compiles on all platforms; only
instantiated when a web controller returns an `ElementViewHandle`, i.e. on web). **No
`PointerInterceptor` here** — the map *is* the top DOM element and gets events natively. No
new dependency on the app-facing package.

**pointer_interceptor belongs on the OVERLAY widgets**, in the example/consumer code: the
FABs drawn over the map (`example/lib/main.dart`) would otherwise leak clicks through to the
map. Wrap the FAB `Column` in `PointerInterceptor(child: ...)` and add
`pointer_interceptor: ^0.10.1+2` to `example/pubspec.yaml` (no-op on non-web). Document this
in the web package README as the consumer requirement.

## 7. pubspec — `maplibre_flutter_web`

Add to `dependencies`: `web: ^1.1.1`. (`dart:js_interop`, `dart:ui_web` are SDK; `flutter`,
`flutter_web_plugins`, `maplibre_flutter_platform_interface` already present.) `pluginClass`/
`fileName` already correct.

---

## 8. Build order (milestones, mirror the per-platform A/B/C cadence)

- **A — visible map.** Loader + interop + minimal controller (create + factory + `MaplibreMap`
  + onReady) + widget `HtmlElementView` wiring + `web: ^1.1.1`. Goal: `flutter run -d chrome`
  shows the demotiles map filling the window. Camera/style methods may be no-ops.
- **B — control + overlays.** `getCamera`/`moveCamera`(fly)/`setStyle`/`resize`/`dispose`;
  example FABs wrapped in `PointerInterceptor`. Goal: zoom / fly-to / style-toggle buttons
  work on chrome exactly like the other tiers; no event leak.
- **C — tests + CI + docs.** §9 below; README setup; CLAUDE.md decision-log entry; melos
  `analyze`/`format`/`test` green.

## 9. Testing (CLAUDE.md §7)

- **Unit (VM-safe, layer 2):** `test/maplibre_flutter_web_test.dart` — `registerWith` installs
  the instance (mirrors macOS test). `createMap()` needs a browser (DOM + maplibregl global),
  so it is NOT unit-testable — exercised by the integration test.
- **Widget (layer 3):** assert the `ElementViewHandle` → `HtmlElementView` branch via a fake
  controller. Run under `flutter test --platform chrome` (HtmlElementView needs the web
  embedder); guard so the VM `test:` run doesn't try it.
- **Integration (layer 5):** `example/integration_test/web_map_test.dart` on chrome —
  pump `MapLibreMap`, await `onReady` (proves the JS map loaded a real style), drive
  `moveCamera`/`setStyle`, assert `getCamera` reflects the move. Run:
  `flutter test integration_test -d chrome` (headless via `chromedriver` for CI).
- **CI (layer 6):** add a web job to `.github/workflows/ci.yml` (currently triggers are
  DISABLED/commented per the core-distribution decision) — `flutter build web` + the chrome
  integration test. No native toolchain needed → cheapest CI lane.

## 10. Risks / gotchas (consolidated)

1. **`[lng, lat]` order** — flip both directions at the JS boundary. #1 bug source.
2. **CSS required** — inject `maplibre-gl.css` or controls/markers render broken.
3. **Script load race** — `await` `onload` before `new maplibregl.Map`; memoise + guard
   double-injection (hot reload, multiple maps).
4. **WebGL context leak** — always `map.remove()` on dispose (browser ~16-context cap).
5. **JS callback GC** — keep Dart-side field refs to `on('load'/'styledata')` + script
   onload closures for their lifetime (CLAUDE.md §5d).
6. **pointer_interceptor is for overlays, not the map** — wrap FABs/drawers/modals over the
   map, not the map widget itself. (Known #145837: misbehaves in web *release* mode — verify
   the example release build.)
7. **flyTo duration** — flyTo derives time from speed/curve unless you pass `duration`; pass
   it (+ `essential:true`) to match the fixed-duration behaviour of the other tiers and to
   animate under prefers-reduced-motion.
8. **viewType uniqueness** — per-map suffix; collisions silently reuse the factory.
9. **`setStyle` readiness** — `'load'` fires once; use `'styledata'`/`'style.load'` to detect
   a style swap completed.
10. **Pin the CDN version** — exact `@5.24.0`; an unpinned `@latest` could silently jump to
    6.x and break the interop surface.

## 11. CLAUDE.md updates on completion

- §2 status: move Web out of the "stubs" bullet to "done (A/B/C)".
- §8 step 4: mark Web done.
- §12 decision log: dated entry — web tier shipped; record the dynamic-injection-default
  decision, the "pointer_interceptor wraps overlays not the map" clarification, and the
  pinned versions.
