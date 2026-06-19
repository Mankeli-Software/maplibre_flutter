# maplibre_flutter example

> ⚠️ **Work in progress — pre-release, not production-ready.** Every target platform
> (Android, iOS, macOS, Windows, Linux, Web) renders a real MapLibre map, but only a small
> slice of the API is wired so far — map creation, camera (get / move / jump / fly), style
> switching, gestures, resize, and lifecycle. Layers, sources, annotations, events, and
> queries are **not** exposed yet. The public API will change without notice; pin an exact
> version. ⭐ the [repository](https://github.com/Mankeli-Software/maplibre_flutter) to follow
> along.

The reference app for [`maplibre_flutter`](../) and the project's primary manual test harness.
It shows a full-screen `MapLibreMap` with floating controls that:

- **zoom in / out** — read the camera and animate to `zoom ± 1`,
- **fly to** — animate the camera through a few cities (London, Tokyo, New York),
- **toggle style** — swap between two keyless styles at runtime (MapLibre demotiles ↔
  OpenFreeMap Liberty).

The overlay controls are wrapped in `PointerInterceptor` so their taps don't leak through to the
map on web (where the map is a DOM element under the Flutter scene); it's a no-op on the other
platforms. See [`lib/main.dart`](lib/main.dart).

## Run it

```bash
flutter run -d <android|ios|macos|windows|linux|chrome>
```

Both demo styles are keyless, so no API token is required. For platform-specific setup (Apple
codesigning, the desktop native engine submodule, etc.) see the repository
[CONTRIBUTING.md](../../../CONTRIBUTING.md).
