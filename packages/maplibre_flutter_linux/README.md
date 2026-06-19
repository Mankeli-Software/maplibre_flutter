# maplibre_flutter_linux

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

The Linux implementation of [`maplibre_flutter`](../maplibre_flutter). Don't depend on this
package directly — depend on `maplibre_flutter`, which endorses it for Linux.

## How it works

Linux is part of the **desktop tier**: it drives the MapLibre Native C++ engine through
[`maplibre_flutter_core`](../maplibre_flutter_core) and composites into a Flutter texture, sharing
the engine and the Dart control/gesture code with macOS and Windows.

### Rendering — OpenGL ES 3 / EGL

The core renders on `mbgl`'s **OpenGL ES 3** renderer through an **EGL** headless backend (a
pbuffer / surfaceless context), so it can run on a real GPU or, headless, under Mesa's software
renderer. The hybrid GTK plugin presents through one of two paths:

- **Default — CPU pixel buffer.** An `FlPixelBufferTexture` presents the RGBA frame copied out of
  the engine. This is the default and the fallback.
- **Opt-in — dmabuf zero-copy** (`--dart-define=MAPLIBRE_ZEROCOPY=true`). The engine blits `mbgl`'s
  color framebuffer into a ring of textures and exports each as a Linux **dmabuf**
  (`EGL_MESA_image_dma_buf_export`); the plugin imports it into an `FlTextureGL`
  (`EGL_LINUX_DMA_BUF_EXT`) with no CPU readback.

> **Why dmabuf, not an `EGLImage`.** `mbgl`'s render context and Flutter's GTK raster context use
> **different `EGLDisplay`s**, and an `EGLImageKHR` handle is display-scoped, so it can't cross
> between them (the first attempt rendered white). A dmabuf is a kernel buffer fd — not display
> scoped — so it crosses cleanly, and its implicit kernel fence provides cross-display sync without
> a stalling `glFinish`. On a unified-memory iGPU the CPU and zero-copy paths perform about the
> same; zero-copy's win shows on discrete GPUs.

A hard-won rule baked into this plugin: **never call EGL/GL on the platform thread** — it has no
current context. All EGL work happens on the raster thread (in the texture `populate` callback).

### Control & gestures

The Dart controller mirrors the macOS controller (minus IOSurface) over FFI and reuses the
**shared desktop gesture + eased fly-to tier** in `maplibre_flutter`. The core caps `mbgl`'s
concurrent tile requests on Linux to avoid HTTP/2 throttling (`ENHANCE_YOUR_CALM`) under
Continuous-mode bursts.

Verified on real hardware (Ubuntu, Intel iGPU): `flutter build linux` builds clean, the EGL backend
creates a context on the GPU, demotiles and OpenFreeMap Liberty both render, and the map is smooth
on GNOME/Wayland. See the repository [CONTRIBUTING.md](../../CONTRIBUTING.md) for the GTK/CMake build
prerequisites and the native engine submodule.
