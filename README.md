# maplibre_flutter

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

A Flutter plugin that renders [MapLibre](https://maplibre.org) vector maps **natively on every
platform** — Android, iOS, macOS, Windows, Linux, and Web.

The differentiator versus existing packages (`maplibre_gl`, `maplibre`) is **true native
rendering on desktop**: on macOS, Windows, and Linux we drive the MapLibre Native C++ engine
(`mbgl-core`) directly and composite it through Flutter's texture pipeline — not a
`maplibre-gl-js` WebView. The goal is to become the *stable*, well-tested MapLibre binding for
Flutter.

## Why

- **One API, every platform.** The public Dart API (the `MapLibreMap` widget and its
  controller) is identical everywhere. All platform divergence stays behind a render-agnostic
  platform interface.
- **Real native desktop rendering.** Desktop runs the same battle-tested `mbgl-core` engine
  that powers the official mobile SDKs, drawn into a GPU texture — no embedded browser.
- **Native feel on mobile and web.** Android and iOS wrap the mature official MapLibre SDKs;
  web uses `maplibre-gl-js`. Each platform gets the most appropriate, best-supported renderer
  rather than one lowest-common-denominator engine.
- **Built to be trusted.** Quality and test coverage are the pitch — a serious, stable binding
  rather than a demo.

## Platforms

Every platform renders a map today. Only camera, style, gestures, resize, and lifecycle are
wired through the API so far (see [status](#status) and the
[feature matrix](https://github.com/Mankeli-Software/maplibre_flutter/blob/main/FEATURE_MATRIX.md)).

| Platform | Rendering engine | Flutter embedding | Verified |
| -------- | ---------------- | ----------------- | -------- |
| Android | MapLibre Android SDK 11.11.0 | `AndroidView` (Hybrid Composition) | On device |
| iOS | MapLibre Apple SDK 6.27.0 | `UiKitView` | Builds (SPM + CocoaPods); on-device frame pending |
| macOS | `mbgl-core` (Metal) | `Texture` (zero-copy IOSurface) | On device, smooth |
| Windows | `mbgl-core` (Vulkan) | `Texture` (CPU present; D3D11 zero-copy opt-in) | On device |
| Linux | `mbgl-core` (OpenGL ES / EGL) | `FlPixelBufferTexture` (CPU; dmabuf zero-copy opt-in) | On device |
| Web | maplibre-gl-js 5.24.0 | `HtmlElementView` | Builds + tests |

## Install

```yaml
dependencies:
  maplibre_flutter: any   # pre-release — pin an exact version once published
```

You depend only on `maplibre_flutter`. It endorses the per-platform implementations, which are
pulled in transitively; never depend on a platform package directly.

## Usage

Drive the map with a `MapLibreMapController` (camera + queries are imperative); the **style is
a declarative widget property** — change it and rebuild to switch styles at runtime.

```dart
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // You constructed the controller, so you own it: dispose it when done.
  final MapLibreMapController _controller = MapLibreMapController();
  String _style = 'https://demotiles.maplibre.org/style.json';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _zoomIn() async {
    await _controller.onReady; // the native map is ready a moment after build
    final camera = await _controller.camera.getPosition();
    await _controller.camera.move(
      camera.copyWith(zoom: camera.zoom + 2),
      duration: const Duration(milliseconds: 600),
    );
  }

  // Style is declarative — change the `style` prop and rebuild.
  void _useLiberty() =>
      setState(() => _style = 'https://tiles.openfreemap.org/styles/liberty');

  @override
  Widget build(BuildContext context) {
    return MapLibreMap(
      controller: _controller, // optional — omit it and the widget owns one
      style: _style,
      options: const MapOptions(
        initialCamera: MapCamera(center: LatLng(0, 0), zoom: 1),
      ),
    );
  }
}
```

Gestures (pan / zoom / rotate / pitch) work out of the box: natively via the SDK on
Android/iOS, natively via maplibre-gl-js on web, and through a shared Dart gesture tier on the
desktop platforms.

## Packages

This is a federated plugin. App code uses only the first package; the rest are implementation
details.

| Package | Role |
| ------- | ---- |
| [`maplibre_flutter`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter) | **The package you depend on** — public API + `MapLibreMap` widget; endorses the implementations. |
| [`maplibre_flutter_platform_interface`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_platform_interface) | The render-agnostic contract every implementation implements. |
| [`maplibre_flutter_core`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_core) | Shared desktop engine: a C ABI shim over `mbgl-core` + ffigen bindings (used by macOS/Windows/Linux). |
| [`maplibre_flutter_android`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_android) | Android — jnigen against the MapLibre Android SDK. |
| [`maplibre_flutter_ios`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_ios) | iOS — swiftgen against the MapLibre Apple SDK. |
| [`maplibre_flutter_macos`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_macos) | macOS — `mbgl-core` + Metal external texture. |
| [`maplibre_flutter_windows`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_windows) | Windows — `mbgl-core` + Vulkan + GPU/CPU texture. |
| [`maplibre_flutter_linux`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_linux) | Linux — `mbgl-core` + OpenGL + CPU/dmabuf texture. |
| [`maplibre_flutter_web`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_web) | Web — maplibre-gl-js via `dart:js_interop`. |

## Architecture

The plugin is organised in **two tiers** behind one identical public API:

- **Mobile tier (Android + iOS)** wraps the mature official native SDKs — best native feel,
  lowest risk. Gestures, annotations, and location come from the SDK.
- **Desktop tier (macOS + Windows + Linux)** shares one `mbgl-core` integration rendered into a
  GPU texture. Gestures and camera are implemented once in Dart over the engine. macOS lives
  here (not paired with iOS) so all three desktop platforms inherit the same hardened engine.

Web is its own thing — `maplibre-gl-js` in an `HtmlElementView`, which (like the mobile SDKs)
owns its own gestures.

Every native platform renders **off-screen and composites through Flutter's texture pipeline or
a platform view**. The platform interface is render-agnostic — mobile returns a native view to
embed, desktop returns a `textureId`, web returns an element-view handle — but the public Dart
API (camera, style, …) is the same everywhere. Each per-package README goes deep on how that
platform renders.

## Status

What works on every platform today: **map creation, camera (`getCamera` / `moveCamera` /
jump / fly), style switching (`setStyle`), gestures, `resize`, `onReady`, and `dispose`.**

Not yet wired: layers, sources, runtime styling/expressions, annotations & controls, events &
queries, images/sprites/glyphs, 3D/terrain, and offline. These are binding work, not engine
limitations — the underlying engines support them. The
[feature matrix](https://github.com/Mankeli-Software/maplibre_flutter/blob/main/FEATURE_MATRIX.md)
tracks the full parity backlog, feature by feature, per platform.

## Example

A runnable example app (map + zoom / fly-to / style-toggle controls) lives in
[`packages/maplibre_flutter/example`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter/example):

```bash
cd packages/maplibre_flutter/example
flutter run -d <android|ios|macos|windows|linux|chrome>
```

## Contributing

Issues, discussions, and PRs are welcome. See
[CONTRIBUTING.md](https://github.com/Mankeli-Software/maplibre_flutter/blob/main/CONTRIBUTING.md)
for repository layout, building, code generation, and the release flow.

## License

BSD-3-Clause. Each package carries its own `LICENSE`.
