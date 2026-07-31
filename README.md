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

The differentiator versus existing packages (`maplibre_gl`, `maplibre`) is **one engine
everywhere**: every platform — Android, iOS, macOS, Windows, Linux, and Web — drives the
MapLibre Native C++ engine (`mbgl-core`) directly and composites it through Flutter's texture
pipeline (a `<canvas>` via WebAssembly on web), not a `maplibre-gl-js` WebView. The goal is to
become the *stable*, well-tested MapLibre binding for Flutter.

## Why

- **One API, every platform.** The public Dart API (the `MapLibreMap` widget and its
  controller) is identical everywhere. All platform divergence stays behind a render-agnostic
  platform interface.
- **One engine, every platform.** Android, iOS, and the three desktops all render the same
  battle-tested `mbgl-core` engine into a GPU texture; web compiles it to WebAssembly. Feature
  parity is maintained once, in the engine, instead of reconciling several renderers.
- **Native SDKs are opt-in, not the default.** The mature MapLibre Android/Apple SDKs and
  `maplibre-gl-js` are still available as **separate opt-in packages** for A/B comparison or to
  use a native SDK's gesture/annotation/location stack — but they are *not* in the default
  build, so they never bloat your app unless you ask for them.
- **Built to be trusted.** Quality and test coverage are the pitch — a serious, stable binding
  rather than a demo.

## Platforms

Every platform renders a map today. Only camera, style, gestures, resize, and lifecycle are
wired through the API so far (see [status](#status) and the
[feature matrix](https://github.com/Mankeli-Software/maplibre_flutter/blob/main/FEATURE_MATRIX.md)).

Every platform renders the same `mbgl-core` engine. Zero-copy GPU present is the default
everywhere it is supported (disable with `--dart-define=MAPLIBRE_ZEROCOPY=false`); each platform
falls back to a CPU present automatically when the GPU path is unavailable.

| Platform | Rendering engine | Flutter embedding | Verified |
| -------- | ---------------- | ----------------- | -------- |
| Android | `mbgl-core` (OpenGL ES) | `Texture` (SurfaceProducer; EGL zero-copy default) | On device |
| iOS | `mbgl-core` (Metal) | `Texture` (IOSurface zero-copy default) | On device |
| macOS | `mbgl-core` (Metal) | `Texture` (zero-copy IOSurface) | On device, smooth |
| Windows | `mbgl-core` (Vulkan) | `Texture` (D3D11 zero-copy default; CPU fallback) | On device |
| Linux | `mbgl-core` (OpenGL ES / EGL) | `Texture` (dmabuf zero-copy default; CPU fallback) | On device |
| Web | `mbgl-core` (WebAssembly / WebGL2) | `HtmlElementView` (`<canvas>`) | Builds + tests |

The mature native SDKs / maplibre-gl-js remain available as opt-in packages — see
[Renderers](#renderers).

## Install

> ⚠️ **You must build the native engine from source today — a plain pub.dev dependency will
> not give you a working map.** The MapLibre Native C++ engine (`mbgl-core`) is vendored as a
> multi-gigabyte git submodule and is deliberately excluded from the published archive.
> Prebuilt binaries are the intended fix and the build hook already knows how to fetch them,
> but **they are not published yet** — so with no submodule and no prebuilt, the native build
> is skipped and calls into the engine fail at runtime. A `git:` dependency does not help
> either, because pub clones without submodules.
>
> **→ [How to build from source](https://github.com/Mankeli-Software/maplibre_flutter/blob/main/docs/building-from-source.md)** — clone with
> `--recursive`, depend by path, build. Takes a C++ toolchain and a few minutes on the first
> build of each platform.
>
> Once prebuilt binaries ship, the snippet below works on its own with no submodule, no C++
> toolchain, and no long first build. Nothing about your Dart code changes — only where the
> compiled engine comes from.

```yaml
dependencies:
  maplibre_flutter: any   # pre-release — pin an exact version once published
```

You depend only on `maplibre_flutter`. It endorses the per-platform implementations, which are
pulled in transitively; never depend on a platform package directly.

Web is the exception: the opt-in [`maplibre_flutter_web_gljs`](#renderers) renderer uses
maplibre-gl-js and needs **no native build at all**.

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

Gestures work out of the box: a shared Dart gesture tier drives pan / zoom / fly-to over the
engine on every platform (the engine owns gestures itself on web). The opt-in native-SDK and
maplibre-gl-js renderers use their own native gestures instead.

## Packages

This is a federated plugin. App code uses only the first package; the rest are implementation
details.

| Package | Role |
| ------- | ---- |
| [`maplibre_flutter`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter) | **The package you depend on** — public API + `MapLibreMap` widget; endorses the implementations. |
| [`maplibre_flutter_platform_interface`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_platform_interface) | The render-agnostic contract every implementation implements. |
| [`maplibre_flutter_core`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_core) | The shared engine: a C ABI shim over `mbgl-core` + ffigen bindings (used by every native platform). |
| [`maplibre_flutter_android`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_android) | Android — `mbgl-core` (OpenGL ES) + Flutter `Texture`. |
| [`maplibre_flutter_ios`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_ios) | iOS — `mbgl-core` (Metal) + Flutter `Texture`. |
| [`maplibre_flutter_macos`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_macos) | macOS — `mbgl-core` + Metal external texture. |
| [`maplibre_flutter_windows`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_windows) | Windows — `mbgl-core` + Vulkan + GPU/CPU texture. |
| [`maplibre_flutter_linux`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_linux) | Linux — `mbgl-core` + OpenGL + CPU/dmabuf texture. |
| [`maplibre_flutter_web`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_web) | Web — `mbgl-core` compiled to WebAssembly, rendered into a `<canvas>`. |

Opt-in alternate renderers (add one to your app to override the default for that platform):

| Package | Role |
| ------- | ---- |
| [`maplibre_flutter_android_sdk`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_android_sdk) | Android — render with the native MapLibre Android SDK (jnigen, `AndroidView`) instead of the core. |
| [`maplibre_flutter_ios_sdk`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_ios_sdk) | iOS — render with the native MapLibre Apple SDK (swiftgen, `UiKitView`) instead of the core. |
| [`maplibre_flutter_web_gljs`](https://github.com/Mankeli-Software/maplibre_flutter/tree/main/packages/maplibre_flutter_web_gljs) | Web — render with maplibre-gl-js instead of the WASM core. |

## Renderers

By default every platform renders with `mbgl-core`. To use a native SDK or maplibre-gl-js on a
platform, add its **opt-in package** to your app — as a direct dependency it overrides the
endorsed core default for that platform, and the alternate renderer's native code only ships
when that package is present:

```yaml
dependencies:
  maplibre_flutter: any
  maplibre_flutter_ios_sdk: any      # iOS now renders with the MapLibre Apple SDK
  # maplibre_flutter_android_sdk / maplibre_flutter_web_gljs do the same per platform
```

> On iOS specifically, the core default and the SDK package both ultimately build on mbgl, so an
> A/B build that pulls *both* should exclude the core iOS package via `dependency_overrides` to
> avoid duplicate mbgl symbols. The published core default needs no override.

## Architecture

One engine, one public API. Every platform renders the same `mbgl-core` integration
**off-screen and composites it through Flutter's texture pipeline** (a `<canvas>` via WebAssembly
on web); gestures and camera are implemented once in Dart over the engine. The platform interface
is render-agnostic — desktop/mobile return a `textureId`, web returns an element-view handle, and
the opt-in native-SDK packages return a native view to embed — but the public Dart API (camera,
style, …) is identical everywhere. Each per-package README goes deep on how that platform renders.

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
