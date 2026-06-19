# maplibre_flutter_windows

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

The Windows implementation of [`maplibre_flutter`](../maplibre_flutter). Don't depend on this
package directly — depend on `maplibre_flutter`, which endorses it for Windows.

## How it works

Windows is part of the **desktop tier**: it drives the MapLibre Native C++ engine through
[`maplibre_flutter_core`](../maplibre_flutter_core) and composites into a Flutter `Texture`,
sharing the engine and the Dart control/gesture code with macOS and Linux.

### Rendering — Vulkan backend

The core renders on `mbgl`'s **Vulkan** backend. (Windows originally used an ANGLE / OpenGL-ES arm;
it was replaced after a `0xC0000005` access violation on fly-to and heavy movement, which traced to
a GL resource-lifetime issue in `mbgl`'s GL drawables under ANGLE's strict D3D11 validation. Vulkan
has no GL path, so the crash is gone — validated on device with sustained fly-to / zoom / style
churn.) `mbgl` loads the driver-supplied `vulkan-1.dll` at runtime, so there are no extra runtime
DLLs to bundle.

The hybrid C++ plugin presents through Flutter's `flutter::TextureRegistrar`:

- **Default — CPU pixel buffer.** A `flutter::PixelBufferTexture` presents the frame read back from
  the engine (`mbl_map_copy_frame`, RGBA). `MarkTextureFrameAvailable` is thread-safe, so the render
  thread marks frames directly. This is the validated default and the universal fallback.
- **Opt-in — D3D11 zero-copy** (`--dart-define=MAPLIBRE_ZEROCOPY=true`). The engine imports `mbgl`'s
  Vulkan image into a shared D3D11 BGRA texture (`VK_KHR_external_memory_win32`) and the plugin
  presents it as a `GpuSurfaceTexture` (DXGI shared handle) with no CPU readback. This needs a GPU
  whose driver can import the legacy shared handle Flutter's consumer requires; where it can't (e.g.
  some Intel iGPU drivers), the engine detects it and **falls back to CPU**.

### Control & gestures

The Dart controller mirrors the Linux/macOS controllers over FFI (`getCamera` / `moveCamera` /
`setStyle` / `resize`) and reuses the **shared desktop gesture + eased fly-to tier** in
`maplibre_flutter`, so behaviour matches the other desktop platforms.

## Building

The build hook (`hook/build.dart`) drives [vcpkg](https://vcpkg.io) to install `mbgl`'s native
dependencies and links them **statically** into `maplibre_flutter_core.dll`, then builds the core
with MSVC/Ninja. Building the example needs Visual Studio 2022 with "Desktop development with C++",
vcpkg (`VCPKG_ROOT` set), and — because Flutter plugins use symlinks and long paths — Windows
**Developer Mode** and long-path support enabled. A Windows-only `mbgl` patch that routes tile DNS
through the OS resolver (the fix for a blank map on this platform) is applied idempotently by the
build hook. See the repository [CONTRIBUTING.md](../../CONTRIBUTING.md) for the full setup.
