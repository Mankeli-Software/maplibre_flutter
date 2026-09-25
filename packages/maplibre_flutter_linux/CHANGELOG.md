## 0.0.3

 - **FIX**(linux): desktop gesture fixes — resize stretch, 2x trackpad pan, pinch anchor. ([026132a5](https://github.com/Mankeli-Software/maplibre_flutter/commit/026132a5aa4155efd715610b15cda4bac92b549d))
 - **FIX**(desktop): render the core at the device pixel ratio (macOS/Linux/Windows). ([6e3f2ec4](https://github.com/Mankeli-Software/maplibre_flutter/commit/6e3f2ec44430e7c37e693275ed8b3f8c20b19f9a))
 - **FIX**(linux): zero-copy white screen — do EGL setup on the raster thread. ([8f6da5ab](https://github.com/Mankeli-Software/maplibre_flutter/commit/8f6da5ab810919b281a8660d7f9490d08cb9226c))
 - **FEAT**(core): expose the style's transition options. ([7931c39a](https://github.com/Mankeli-Software/maplibre_flutter/commit/7931c39ab57407f113c9fd71a8a367c59d58546b))
 - **FEAT**(markers): markers, layers and queries on Linux, Windows, iOS-core, Android-core. ([acf0137c](https://github.com/Mankeli-Software/maplibre_flutter/commit/acf0137ca9ba57a463c6e23688a15b5558ed4e73))
 - **FEAT**(desktop): zero-copy present on by default for Linux + Windows. ([9f619179](https://github.com/Mankeli-Software/maplibre_flutter/commit/9f61917943978412538d0659db70df778bcf637e))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([b15fa1fd](https://github.com/Mankeli-Software/maplibre_flutter/commit/b15fa1fd23040f7e3a0ff690533f5d9f6affebe4))
 - **FEAT**(windows): Vulkan backend — fixes the fly-to crash (replaces ANGLE/OpenGL-ES). ([890f99ad](https://github.com/Mankeli-Software/maplibre_flutter/commit/890f99ad962a2d99e0298705e6642a396d584aa1))
 - **FEAT**(linux): zero-copy FlTextureGL present via dmabuf. ([bae4d76a](https://github.com/Mankeli-Software/maplibre_flutter/commit/bae4d76a59590b2190f6330fe55a4824372d6d88))
 - **FEAT**(linux): GTK plugin + shared fly-to + RGBA pixel-format flag. ([71d2b463](https://github.com/Mankeli-Software/maplibre_flutter/commit/71d2b463792f2a51a306f514d17283c7da865704))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([05b45ffd](https://github.com/Mankeli-Software/maplibre_flutter/commit/05b45ffdd2922a12b54ac4aede0265114cfb42b3))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([ea27815a](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea27815a4e855634723c9c3ae98b123a0d8dcdb2))

## 0.0.2

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

## 0.0.1

* Initial scaffold.
