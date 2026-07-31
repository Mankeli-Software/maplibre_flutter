## 0.0.3

 - **REFACTOR**(windows): drop resize-mask polling — widget-owned freeze + cover-fit. ([cc046ade](https://github.com/Mankeli-Software/maplibre_flutter/commit/cc046ade38c908224c7553dade33f710fa4cc39d))
 - **FIX**(windows): revert pinch-zoom anchor Y-flip that mirrored the zoom point. ([43d29926](https://github.com/Mankeli-Software/maplibre_flutter/commit/43d299262db2ad7f00cf0dbd5f746ee5b5c3fccd))
 - **FIX**(linux): desktop gesture fixes — resize stretch, 2x trackpad pan, pinch anchor. ([19633027](https://github.com/Mankeli-Software/maplibre_flutter/commit/19633027485acecb3756bf3acd7ce6cc839ce2da))
 - **FIX**(windows): mask resize stretch — coalesce + freeze + cover-fit (exploratory). ([ec857fb6](https://github.com/Mankeli-Software/maplibre_flutter/commit/ec857fb6a277bdb25eda5c9c16c089b359ca6d9b))
 - **FIX**(desktop): render the core at the device pixel ratio (macOS/Linux/Windows). ([e55fa4f5](https://github.com/Mankeli-Software/maplibre_flutter/commit/e55fa4f5e7e09e8fa3ca57752abf9a82e00fb6c5))
 - **FEAT**(core): expose the style's transition options. ([201de598](https://github.com/Mankeli-Software/maplibre_flutter/commit/201de59858a25e831808899854e3f7cac6165303))
 - **FEAT**(markers): markers, layers and queries on Linux, Windows, iOS-core, Android-core. ([9e052c7d](https://github.com/Mankeli-Software/maplibre_flutter/commit/9e052c7d6e4d84cbfbcf3f270c632fa316c63cdc))
 - **FEAT**(desktop): zero-copy present on by default for Linux + Windows. ([fd6977ee](https://github.com/Mankeli-Software/maplibre_flutter/commit/fd6977ee32ec677da23b80525c325bb0c2be9ac2))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([dd625919](https://github.com/Mankeli-Software/maplibre_flutter/commit/dd62591995b93b66ebdf8189ba222af200b94a13))
 - **FEAT**(windows): Vulkan backend — fixes the fly-to crash (replaces ANGLE/OpenGL-ES). ([b2f44ee2](https://github.com/Mankeli-Software/maplibre_flutter/commit/b2f44ee25daa5625316440a5520d255b90f72a94))
 - **FEAT**(windows): native map — DNS fix (OS resolver) + D3D11 zero-copy present. ([1a51d00a](https://github.com/Mankeli-Software/maplibre_flutter/commit/1a51d00a716103a3fbbd0b3f550935393af5e634))
 - **FEAT**(windows): build + render mbgl-core on real Windows hardware (ANGLE/EGL). ([c8513a05](https://github.com/Mankeli-Software/maplibre_flutter/commit/c8513a0507bca05a9cd0ffedbe40a517d4ab5173))
 - **FEAT**(windows): scaffold the Windows desktop tier (ANGLE/EGL, CPU pixel-buffer). ([907f910e](https://github.com/Mankeli-Software/maplibre_flutter/commit/907f910e6ff06165c7662bb3bc95a20288925209))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([12823cf8](https://github.com/Mankeli-Software/maplibre_flutter/commit/12823cf817fd5298356ea357b568b9847797892d))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([1157517f](https://github.com/Mankeli-Software/maplibre_flutter/commit/1157517f68e8786f97fdb5738e64517626c128aa))

## 0.0.2

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

## 0.0.1

* Initial scaffold.
