# maplibre_flutter_android

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

The default Android implementation of [`maplibre_flutter`](../maplibre_flutter). Don't depend on
this package directly — depend on `maplibre_flutter`, which endorses it for Android.

## How it works

Android renders with the shared **mbgl-core** C++ engine (OpenGL ES3 + EGL) — the *same* engine
that powers macOS, Windows, Linux, and the experimental iOS path — rather than the MapLibre Android
SDK. mbgl-core draws off-screen and its frames are presented into a Flutter `Texture`. Because the
renderer is the shared core, `createMap` returns a `TextureHandle`, and the shared desktop Dart
gesture + fly-to tier drives pan, zoom, and animated camera moves (there are no SDK-native gestures).

### Rendering — mbgl-core into a Flutter `Texture`

The engine itself is `libmaplibre_flutter_core.so`, produced by the
[`maplibre_flutter_core`](../maplibre_flutter_core) package's build hook. A small JNI bridge library,
`libmaplibre_flutter_android_jni.so` (built by Gradle's `externalNativeBuild`), copies the core's
rendered frames into the `Surface` of a Flutter `SurfaceProducer` using the NDK `ANativeWindow` API.
The plugin class (`MaplibreFlutterAndroidPlugin`) only registers a texture-registrar `MethodChannel`
— registration only; the per-frame path runs entirely in native code and over FFI, with no method
channel on the data path.

### HTTP — OkHttp over JNI

mbgl-core's tile, style, and glyph requests are served by a Kotlin **OkHttp**-over-JNI bridge, which
gives requests the system TLS stack and trust store. curl is not used.

### Present — zero-copy by default, CPU fallback

The default present path is **zero-copy**: an EGL window surface backed by the `SurfaceProducer`,
with no GPU→CPU readback. On renderers that can't composite a foreign-EGL buffer through a
`SurfaceProducer` — notably the Android emulator and software GL, which would otherwise show a white
map — it automatically falls back to a CPU `ANativeWindow` blit. Force the CPU path with
`--dart-define=MAPLIBRE_ZEROCOPY=false`.

## Toolchain

Built for **AGP 9+**: a `namespace` declared in Gradle, **built-in Kotlin** (the `kotlin-android`
plugin is deliberately *not* applied — AGP 9 fails the build if it is), and Java 17. It stays
back-compatible with the older AGP versions current Flutter still supports. `minSdk` is **26**,
because mbgl-core references `pthread_getname_np`, which was added to bionic in API 26.

## Optional: native Android SDK renderer

To render with the MapLibre Android SDK instead — a native `MapView` embedded via `AndroidView`,
useful for A/B testing or for the SDK's native gesture, annotation, and location stack — add the
`maplibre_flutter_android_sdk` package to your app. As a direct dependency it overrides this
endorsed default.
