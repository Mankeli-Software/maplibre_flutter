# maplibre_flutter_platform_interface

The common platform interface for the `maplibre_flutter` plugin. Platform
implementations extend `MaplibreFlutterPlatform`; app code depends on
`maplibre_flutter`, not this package.

This contract is render-agnostic (CLAUDE.md §3): mobile returns a platform-view
handle, desktop returns a texture handle, web returns an element-view handle.
