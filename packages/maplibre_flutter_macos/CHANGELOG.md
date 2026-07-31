## 0.0.3

 - **PERF**: share GPU textures between models, merge parts by material, add a HUD. ([42be7969](https://github.com/Mankeli-Software/maplibre_flutter/commit/42be7969eab660c2273b5a3b83157e89603bc8e1))
 - **PERF**(macos): serve the texture from a reused IOSurface-backed buffer pool. ([27181225](https://github.com/Mankeli-Software/maplibre_flutter/commit/27181225a09a64d66c9f635c19c5497d290d01e7))
 - **FIX**(example): the fps counter measured Flutter's vsync, not the map. ([a16f0b4f](https://github.com/Mankeli-Software/maplibre_flutter/commit/a16f0b4fe33012d7eef50ff5950a0cf4fa1d14ee))
 - **FIX**(core): correct the projection Y axis and glue markers to the shown frame. ([6eeb663f](https://github.com/Mankeli-Software/maplibre_flutter/commit/6eeb663f2291b2d05b86b247b3ba8266b51934f8))
 - **FIX**(macos): harden window resize — IOSurface UAF crash, white blink, frame-lag squeeze. ([96553165](https://github.com/Mankeli-Software/maplibre_flutter/commit/965531658dc4a8afc20171dbb9b4173731f622b3))
 - **FIX**(desktop): render the core at the device pixel ratio (macOS/Linux/Windows). ([e55fa4f5](https://github.com/Mankeli-Software/maplibre_flutter/commit/e55fa4f5e7e09e8fa3ca57752abf9a82e00fb6c5))
 - **FIX**(macos): only apply the fly-to zoom dip for real flights. ([bb299055](https://github.com/Mankeli-Software/maplibre_flutter/commit/bb29905516e9a407320f2b50e5d6df359f46e388))
 - **FEAT**(core): expose the style's transition options. ([201de598](https://github.com/Mankeli-Software/maplibre_flutter/commit/201de59858a25e831808899854e3f7cac6165303))
 - **FEAT**: drive models along a path, lift them off the ground, rotate the camera. ([73776545](https://github.com/Mankeli-Software/maplibre_flutter/commit/73776545052ab62bb6710644a8f72f5fe1d72c86))
 - **FEAT**(markers): queryRenderedFeatures, and animated widgets over engine clusters. ([74350233](https://github.com/Mankeli-Software/maplibre_flutter/commit/7435023333b055c4d0d2ab8212073fc6cf17ecea))
 - **FEAT**: expose 3D models through the app-facing API and example. ([f495cc3b](https://github.com/Mankeli-Software/maplibre_flutter/commit/f495cc3b70b2fa1e72664ca5af1b40ce1a5209e4))
 - **FEAT**(markers): app-facing engine-drawn annotations for very large datasets. ([5f2b2a9a](https://github.com/Mankeli-Software/maplibre_flutter/commit/5f2b2a9a5a7248a58afaf654e27af6335a1322a9))
 - **FEAT**(markers): glue interactive Flutter widgets to map points (macOS-first). ([532d3c3a](https://github.com/Mankeli-Software/maplibre_flutter/commit/532d3c3a516f2c12ab5fc52a8193ab9a7d7614fe))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([dd625919](https://github.com/Mankeli-Software/maplibre_flutter/commit/dd62591995b93b66ebdf8189ba222af200b94a13))
 - **FEAT**(linux): GTK plugin + shared fly-to + RGBA pixel-format flag. ([1ad69b85](https://github.com/Mankeli-Software/maplibre_flutter/commit/1ad69b85cc99a4f33a9ee2ed10fed91824f66acd))
 - **FEAT**(core): Continuous render mode for smooth fly-to over detailed tiles. ([fb5a5aaf](https://github.com/Mankeli-Software/maplibre_flutter/commit/fb5a5aaf91d038bd5cecef1ebb24cf5c52de654c))
 - **FEAT**(macos): zero-copy present via GPU blit into an IOSurface. ([5e2e5855](https://github.com/Mankeli-Software/maplibre_flutter/commit/5e2e5855e308f378dabe91536f1dfc48337eb49f))
 - **FEAT**(macos): animate moveCamera(duration) with an eased fly-to arc. ([4cbc37d1](https://github.com/Mankeli-Software/maplibre_flutter/commit/4cbc37d162ae8b70325a226640b47a62dc474ab5))
 - **FEAT**: desktop map gestures — pan, pinch- and scroll-zoom. ([64f8ceb4](https://github.com/Mankeli-Software/maplibre_flutter/commit/64f8ceb4fabfe0dd0323ffd334c3a8329c2b24a8))
 - **FEAT**: size the desktop map to the widget + gate readiness on first frame. ([a83a284e](https://github.com/Mankeli-Software/maplibre_flutter/commit/a83a284e224337af3b84e44523037531a36a06a0))
 - **FEAT**(macos): render mbgl-core into a Flutter Texture. ([2c771850](https://github.com/Mankeli-Software/maplibre_flutter/commit/2c77185053ee739e7abf9c47171b278c2aba99cb))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([12823cf8](https://github.com/Mankeli-Software/maplibre_flutter/commit/12823cf817fd5298356ea357b568b9847797892d))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([1157517f](https://github.com/Mankeli-Software/maplibre_flutter/commit/1157517f68e8786f97fdb5738e64517626c128aa))
 - **DOCS**(macos): note true zero-copy as deferred follow-up. ([8a617675](https://github.com/Mankeli-Software/maplibre_flutter/commit/8a6176757e589a890a69fc9c0cb0b0a544b55f96))

## 0.0.2

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

## 0.0.1

* Initial scaffold.
