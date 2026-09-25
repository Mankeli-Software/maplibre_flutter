## 0.0.3

 - **PERF**: share GPU textures between models, merge parts by material, add a HUD. ([1c23a128](https://github.com/Mankeli-Software/maplibre_flutter/commit/1c23a128d0596a39c2c2773b0e88976618dd6b00))
 - **PERF**(macos): serve the texture from a reused IOSurface-backed buffer pool. ([a71c14b1](https://github.com/Mankeli-Software/maplibre_flutter/commit/a71c14b1f5d6d13cb67fef19a135fda800837e0a))
 - **FIX**(example): the fps counter measured Flutter's vsync, not the map. ([fb811d72](https://github.com/Mankeli-Software/maplibre_flutter/commit/fb811d72050b9af2e5fcf02b35de4c6b6345b221))
 - **FIX**(core): correct the projection Y axis and glue markers to the shown frame. ([2c8ce1c3](https://github.com/Mankeli-Software/maplibre_flutter/commit/2c8ce1c39a5b1c1a5c2a871cc288641c5379a8a8))
 - **FIX**(macos): harden window resize — IOSurface UAF crash, white blink, frame-lag squeeze. ([962951c5](https://github.com/Mankeli-Software/maplibre_flutter/commit/962951c556156f3926abe2cce9acbe1795399851))
 - **FIX**(desktop): render the core at the device pixel ratio (macOS/Linux/Windows). ([6e3f2ec4](https://github.com/Mankeli-Software/maplibre_flutter/commit/6e3f2ec44430e7c37e693275ed8b3f8c20b19f9a))
 - **FIX**(macos): only apply the fly-to zoom dip for real flights. ([01f3383a](https://github.com/Mankeli-Software/maplibre_flutter/commit/01f3383a33d832352b8a9a0f2f8a9324e61dedb1))
 - **FEAT**(core): expose the style's transition options. ([7931c39a](https://github.com/Mankeli-Software/maplibre_flutter/commit/7931c39ab57407f113c9fd71a8a367c59d58546b))
 - **FEAT**: drive models along a path, lift them off the ground, rotate the camera. ([ab062139](https://github.com/Mankeli-Software/maplibre_flutter/commit/ab062139d5f1ae6694daf789d49224d116e60e96))
 - **FEAT**(markers): queryRenderedFeatures, and animated widgets over engine clusters. ([9db82a28](https://github.com/Mankeli-Software/maplibre_flutter/commit/9db82a2874fb99ef7beb0ab28953a6cc63fb526e))
 - **FEAT**: expose 3D models through the app-facing API and example. ([57e2578a](https://github.com/Mankeli-Software/maplibre_flutter/commit/57e2578aec6d86ea1752a4bcc4db04d0214908e1))
 - **FEAT**(markers): app-facing engine-drawn annotations for very large datasets. ([f7538bb7](https://github.com/Mankeli-Software/maplibre_flutter/commit/f7538bb7772fc9f50188ef7b1e0bc2c84f0fc31e))
 - **FEAT**(markers): glue interactive Flutter widgets to map points (macOS-first). ([294452d7](https://github.com/Mankeli-Software/maplibre_flutter/commit/294452d74a3282dc6ce520c6b3eccbc56fed55ab))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([b15fa1fd](https://github.com/Mankeli-Software/maplibre_flutter/commit/b15fa1fd23040f7e3a0ff690533f5d9f6affebe4))
 - **FEAT**(linux): GTK plugin + shared fly-to + RGBA pixel-format flag. ([71d2b463](https://github.com/Mankeli-Software/maplibre_flutter/commit/71d2b463792f2a51a306f514d17283c7da865704))
 - **FEAT**(core): Continuous render mode for smooth fly-to over detailed tiles. ([10dc67ac](https://github.com/Mankeli-Software/maplibre_flutter/commit/10dc67ac94d2cf683544e3fe91437a2e4d0b73cf))
 - **FEAT**(macos): zero-copy present via GPU blit into an IOSurface. ([98b81c7f](https://github.com/Mankeli-Software/maplibre_flutter/commit/98b81c7f29d4cf0ed6be3c2feb35f9ccee0717dc))
 - **FEAT**(macos): animate moveCamera(duration) with an eased fly-to arc. ([b8482f8c](https://github.com/Mankeli-Software/maplibre_flutter/commit/b8482f8cf8750b5614b2ded09973ed0094cab9e0))
 - **FEAT**: desktop map gestures — pan, pinch- and scroll-zoom. ([c1944e4c](https://github.com/Mankeli-Software/maplibre_flutter/commit/c1944e4c2ed9115943ca47e3ad5c11a6299ee033))
 - **FEAT**: size the desktop map to the widget + gate readiness on first frame. ([3cdb4931](https://github.com/Mankeli-Software/maplibre_flutter/commit/3cdb4931af732070fb1ca662e303de7a544e6bca))
 - **FEAT**(macos): render mbgl-core into a Flutter Texture. ([ea7dfe59](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea7dfe59006e493cc0c21c638ba2185956479b0d))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([05b45ffd](https://github.com/Mankeli-Software/maplibre_flutter/commit/05b45ffdd2922a12b54ac4aede0265114cfb42b3))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([ea27815a](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea27815a4e855634723c9c3ae98b123a0d8dcdb2))
 - **DOCS**(macos): note true zero-copy as deferred follow-up. ([eec17246](https://github.com/Mankeli-Software/maplibre_flutter/commit/eec172460702b1152d8ba3dbfa12888ef9245c92))

## 0.0.2

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

## 0.0.1

* Initial scaffold.
