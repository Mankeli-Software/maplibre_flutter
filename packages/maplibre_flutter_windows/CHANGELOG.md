## 0.0.3

 - **REFACTOR**(windows): drop resize-mask polling — widget-owned freeze + cover-fit. ([053f9ed0](https://github.com/Mankeli-Software/maplibre_flutter/commit/053f9ed0741f452f7b01f811df2bcfb874e6fc67))
 - **FIX**(windows): revert pinch-zoom anchor Y-flip that mirrored the zoom point. ([430e3d95](https://github.com/Mankeli-Software/maplibre_flutter/commit/430e3d95360ca5379ab77179a9f221f01de1e5b4))
 - **FIX**(linux): desktop gesture fixes — resize stretch, 2x trackpad pan, pinch anchor. ([026132a5](https://github.com/Mankeli-Software/maplibre_flutter/commit/026132a5aa4155efd715610b15cda4bac92b549d))
 - **FIX**(windows): mask resize stretch — coalesce + freeze + cover-fit (exploratory). ([379e4f9a](https://github.com/Mankeli-Software/maplibre_flutter/commit/379e4f9a005e7b40e6a47f8ccd92b6d69283ba66))
 - **FIX**(desktop): render the core at the device pixel ratio (macOS/Linux/Windows). ([6e3f2ec4](https://github.com/Mankeli-Software/maplibre_flutter/commit/6e3f2ec44430e7c37e693275ed8b3f8c20b19f9a))
 - **FEAT**(core): expose the style's transition options. ([7931c39a](https://github.com/Mankeli-Software/maplibre_flutter/commit/7931c39ab57407f113c9fd71a8a367c59d58546b))
 - **FEAT**(markers): markers, layers and queries on Linux, Windows, iOS-core, Android-core. ([acf0137c](https://github.com/Mankeli-Software/maplibre_flutter/commit/acf0137ca9ba57a463c6e23688a15b5558ed4e73))
 - **FEAT**(desktop): zero-copy present on by default for Linux + Windows. ([9f619179](https://github.com/Mankeli-Software/maplibre_flutter/commit/9f61917943978412538d0659db70df778bcf637e))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([b15fa1fd](https://github.com/Mankeli-Software/maplibre_flutter/commit/b15fa1fd23040f7e3a0ff690533f5d9f6affebe4))
 - **FEAT**(windows): Vulkan backend — fixes the fly-to crash (replaces ANGLE/OpenGL-ES). ([890f99ad](https://github.com/Mankeli-Software/maplibre_flutter/commit/890f99ad962a2d99e0298705e6642a396d584aa1))
 - **FEAT**(windows): native map — DNS fix (OS resolver) + D3D11 zero-copy present. ([b18d4e82](https://github.com/Mankeli-Software/maplibre_flutter/commit/b18d4e82eb1552ed580cfb99da455a01929c8810))
 - **FEAT**(windows): build + render mbgl-core on real Windows hardware (ANGLE/EGL). ([dacf9a86](https://github.com/Mankeli-Software/maplibre_flutter/commit/dacf9a86c8ded12754a2ae1ca08c149982147f47))
 - **FEAT**(windows): scaffold the Windows desktop tier (ANGLE/EGL, CPU pixel-buffer). ([f985506c](https://github.com/Mankeli-Software/maplibre_flutter/commit/f985506cc7d732c77944bd4e40bc48196f283972))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([05b45ffd](https://github.com/Mankeli-Software/maplibre_flutter/commit/05b45ffdd2922a12b54ac4aede0265114cfb42b3))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([ea27815a](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea27815a4e855634723c9c3ae98b123a0d8dcdb2))

## 0.0.2

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

## 0.0.1

* Initial scaffold.
