## 0.0.3

 - **REFACTOR**(windows): drop resize-mask polling — widget-owned freeze + cover-fit. ([053f9ed0](https://github.com/Mankeli-Software/maplibre_flutter/commit/053f9ed0741f452f7b01f811df2bcfb874e6fc67))
 - **PERF**: share GPU textures between models, merge parts by material, add a HUD. ([1c23a128](https://github.com/Mankeli-Software/maplibre_flutter/commit/1c23a128d0596a39c2c2773b0e88976618dd6b00))
 - **PERF**(markers): cull off-screen markers and cache rich children in layers. ([59c86515](https://github.com/Mankeli-Software/maplibre_flutter/commit/59c865153503fd5cb6868abc6ff569a529577892))
 - **FIX**(example): the fps counter measured Flutter's vsync, not the map. ([fb811d72](https://github.com/Mankeli-Software/maplibre_flutter/commit/fb811d72050b9af2e5fcf02b35de4c6b6345b221))
 - **FIX**(windows): mask resize stretch — coalesce + freeze + cover-fit (exploratory). ([379e4f9a](https://github.com/Mankeli-Software/maplibre_flutter/commit/379e4f9a005e7b40e6a47f8ccd92b6d69283ba66))
 - **FEAT**(core): expose the style's transition options. ([7931c39a](https://github.com/Mankeli-Software/maplibre_flutter/commit/7931c39ab57407f113c9fd71a8a367c59d58546b))
 - **FEAT**: declarative MapLibreMap(models:) prop. ([8e9a0959](https://github.com/Mankeli-Software/maplibre_flutter/commit/8e9a09593f760d326f96a58dca5eb2f259b8480b))
 - **FEAT**: drive models along a path, lift them off the ground, rotate the camera. ([ab062139](https://github.com/Mankeli-Software/maplibre_flutter/commit/ab062139d5f1ae6694daf789d49224d116e60e96))
 - **FEAT**(markers): queryRenderedFeatures, and animated widgets over engine clusters. ([9db82a28](https://github.com/Mankeli-Software/maplibre_flutter/commit/9db82a2874fb99ef7beb0ab28953a6cc63fb526e))
 - **FEAT**: expose 3D models through the app-facing API and example. ([57e2578a](https://github.com/Mankeli-Software/maplibre_flutter/commit/57e2578aec6d86ea1752a4bcc4db04d0214908e1))
 - **FEAT**(markers): app-facing engine-drawn annotations for very large datasets. ([f7538bb7](https://github.com/Mankeli-Software/maplibre_flutter/commit/f7538bb7772fc9f50188ef7b1e0bc2c84f0fc31e))
 - **FEAT**(markers): glue interactive Flutter widgets to map points (macOS-first). ([294452d7](https://github.com/Mankeli-Software/maplibre_flutter/commit/294452d74a3282dc6ce520c6b3eccbc56fed55ab))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([b15fa1fd](https://github.com/Mankeli-Software/maplibre_flutter/commit/b15fa1fd23040f7e3a0ff690533f5d9f6affebe4))
 - **FEAT**(linux): GTK plugin + shared fly-to + RGBA pixel-format flag. ([71d2b463](https://github.com/Mankeli-Software/maplibre_flutter/commit/71d2b463792f2a51a306f514d17283c7da865704))
 - **FEAT**: desktop map gestures — pan, pinch- and scroll-zoom. ([c1944e4c](https://github.com/Mankeli-Software/maplibre_flutter/commit/c1944e4c2ed9115943ca47e3ad5c11a6299ee033))
 - **FEAT**: size the desktop map to the widget + gate readiness on first frame. ([3cdb4931](https://github.com/Mankeli-Software/maplibre_flutter/commit/3cdb4931af732070fb1ca662e303de7a544e6bca))
 - **FEAT**: Android Hybrid Composition + map-ready signal; mobile-tier hardening. ([8e2a513d](https://github.com/Mankeli-Software/maplibre_flutter/commit/8e2a513da5514093bd94f21da624d2d6b43db23f))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([05b45ffd](https://github.com/Mankeli-Software/maplibre_flutter/commit/05b45ffdd2922a12b54ac4aede0265114cfb42b3))
 - **FEAT**(android): render MapLibre map and drive it from Dart over jnigen. ([eb4250a1](https://github.com/Mankeli-Software/maplibre_flutter/commit/eb4250a1a1cb09f1e9eafed57295fc5166c60b34))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([ea27815a](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea27815a4e855634723c9c3ae98b123a0d8dcdb2))

## 0.0.2

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

## 0.0.1

* Initial scaffold.
