# maplibre_flutter

Native [MapLibre](https://maplibre.org) vector maps for Flutter on every
platform — Android, iOS, macOS, Windows, Linux, and Web — with **true native
rendering on desktop** (the `mbgl-core` C++ engine, not a WebView).

This is the only package app code depends on; it endorses the per-platform
implementations. See [CLAUDE.md](../../CLAUDE.md) for architecture.

```dart
MaplibreMap(
  options: const MapOptions(
    styleUri: 'https://demotiles.maplibre.org/style.json',
    initialCamera: MapCamera(center: LatLng(0, 0), zoom: 1),
  ),
);
```
