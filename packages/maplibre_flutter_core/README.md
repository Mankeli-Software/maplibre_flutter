# maplibre_flutter_core

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

The shared desktop engine for [`maplibre_flutter`](../maplibre_flutter): a thin **C ABI shim**
over MapLibre Native (`mbgl-core`) plus the committed **ffigen** bindings used by the macOS,
Windows, and Linux implementation packages. There is no Flutter widget code here — this package
is the engine and its Dart FFI surface; the platform packages own the per-OS texture present.

## How it works

Dart FFI cannot bind C++ directly, so `mbgl-core`'s C++ API is wrapped in a thin **C ABI** shim
(`src/maplibre_flutter_core.{h,cpp}`) that `ffigen` turns into Dart bindings
(`lib/src/maplibre_flutter_core_bindings_generated.dart`). The shim owns a dedicated **render
thread** that drives `mbgl-core` headlessly: create a map, load a style, move the camera, and
render frames into an off-screen surface that the platform package presents through a Flutter
texture. Long-running calls run off the platform thread so the UI never stalls.

Two render modes are selectable per map:

- **Static** — synchronous, one complete frame per request. The default for headless tests.
- **Continuous** — an `mbgl` run loop publishes each frame as tiles stream in (partial → refines).
  This is what makes fly-to over uncached tiles smooth.

### Per-OS rendering backend

The same engine and C ABI compile against a different GPU backend on each desktop OS — the CMake
build (`src/CMakeLists.txt`) selects exactly one:

| OS | mbgl backend | Default present | Zero-copy (opt-in) |
| -- | ------------ | --------------- | ------------------ |
| macOS | Metal | IOSurface-backed `CVPixelBuffer` | GPU compute blit into an IOSurface (`maplibre_flutter_core_metal.mm`) |
| Windows | Vulkan | CPU pixel buffer (`mbl_map_copy_frame`) | D3D11 shared texture via `VK_KHR_external_memory_win32` (`maplibre_flutter_core_vk.cpp`) |
| Linux | OpenGL ES 3 / EGL | CPU pixel buffer | dmabuf-exported texture ring (`maplibre_flutter_core_gl.cpp`) |

Each platform package presents the default CPU path for correctness and flips on its zero-copy
GPU path with `--dart-define=MAPLIBRE_ZEROCOPY=true` (with `MAPLIBRE_CONTINUOUS` toggling the
render mode). The Metal-specific code is guarded behind `__APPLE__`; on the other OSes those
entry points are no-ops and the pixel-format-aware CPU copy (BGRA/RGBA) is used.

## Building from source

`mbgl-core` is vendored as a git **submodule** under `third_party/` and built with CMake via the
build hook (`hook/build.dart`, using `native_toolchain_cmake`). Vendor it once:

```sh
git submodule update --init --recursive
```

The engine is pinned to a specific revision (`MBGL_CORE_VERSION`). A couple of platform fixes that
can't live upstream in a pinned submodule ship as patches under `patches/` and are applied
**idempotently by the build hook** (a marker check, then `git apply`) — currently a Windows
DNS-resolution fix and the Windows Vulkan external-memory extension enablement. On Windows the hook
also drives [vcpkg](https://vcpkg.io) to install the native dependencies and links them statically
into the core DLL.

Regenerate the bindings after changing the shim header (needs libclang):

```sh
dart run tool/ffigen.dart
```

## Distribution

`mbgl-core` is large and slow to compile, so the build hook resolves the native library two ways:

- **App consumers** (no submodule, as published on pub.dev) — the hook downloads a prebuilt
  per-`(os, arch)` binary from the GitHub release matching the package version
  (`maplibre_flutter_core-v<version>`). No C++ toolchain or multi-minute first build required.
- **Developers / CI** (this repo, submodule vendored) — the hook builds from the pinned source.
  Set `MAPLIBRE_FLUTTER_BUILD_FROM_SOURCE=1` to force this path even without a submodule.

`third_party/` is `.pubignore`d, so the published archive stays small; the prebuilt download fills
the gap for consumers. Both paths resolve to the same ffigen asset id, so the Dart side is
identical either way.
