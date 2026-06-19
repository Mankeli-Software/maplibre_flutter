# maplibre_flutter_macos

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

The macOS implementation of [`maplibre_flutter`](../maplibre_flutter). Don't depend on this
package directly — depend on `maplibre_flutter`, which endorses it for macOS.

## How it works

macOS is part of the **desktop tier**: it drives the MapLibre Native C++ engine through
[`maplibre_flutter_core`](../maplibre_flutter_core) (the shared C ABI shim + ffigen bindings) and
composites the result into a Flutter `Texture`. It is paired with Windows and Linux — *not* iOS —
so all three desktop platforms share one hardened engine. This package is the thin Swift glue that
turns the engine's rendered frames into a texture and wires up control.

### Rendering — Metal, zero-copy present

The core renders headlessly on a dedicated thread into a Metal texture. The hybrid Swift plugin
presents it with **true-enough zero-copy**: a GPU compute blit copies `mbgl`'s rendered texture
into an IOSurface-backed BGRA texture (the channel swizzle is implicit in the pixel-format
conversion), which is wrapped in a `CVPixelBuffer` and handed to Flutter's Metal `Texture` path —
**no CPU readback**. The blit runs on `mbgl`'s own command queue (GPU-ordered after the render,
before the next, so there's no race on its single internal texture) and completes **asynchronously**
(the completion handler publishes; no `waitUntilCompleted` stall). A small IOSurface ring + a
`CVPixelBuffer` cache avoid per-frame allocation.

Combined with the core's **Continuous** render mode — partial frames publish immediately and refine
as tiles stream in — this makes zoom and fly-to smooth even over uncached tiles. Both the zero-copy
present and Continuous mode default **on**; `--dart-define=MAPLIBRE_ZEROCOPY=false` /
`MAPLIBRE_CONTINUOUS=false` flip to the CPU-readback / Static fallbacks (the headless-test path).

### Control & gestures

The Dart controller mirrors the mobile controllers but talks to the engine over FFI: `getCamera`,
`moveCamera` (with a Dart-side eased fly arc), `setStyle`, and `resize`. Pan and zoom are handled by
the **shared desktop gesture tier** in `maplibre_flutter` (the controller implements
`MapLibreGestureHandler`'s `moveBy` / `scaleBy`), so gesture behaviour is identical across macOS,
Windows, and Linux.

Verified on device: solid rendering, smooth gestures / zoom / fly-to, stable when idle. The macOS
app sandbox needs `com.apple.security.network.client` to fetch tiles.
