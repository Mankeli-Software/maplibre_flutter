## 0.0.3

 - **REFACTOR**(windows): drop resize-mask polling — widget-owned freeze + cover-fit. ([cc046ade](https://github.com/Mankeli-Software/maplibre_flutter/commit/cc046ade38c908224c7553dade33f710fa4cc39d))
 - **PERF**: share GPU textures between models, merge parts by material, add a HUD. ([42be7969](https://github.com/Mankeli-Software/maplibre_flutter/commit/42be7969eab660c2273b5a3b83157e89603bc8e1))
 - **PERF**(markers): cull off-screen markers and cache rich children in layers. ([1a9d7340](https://github.com/Mankeli-Software/maplibre_flutter/commit/1a9d7340ae4b7a72384e17104c79f0b78844de14))
 - **FIX**(example): the fps counter measured Flutter's vsync, not the map. ([a16f0b4f](https://github.com/Mankeli-Software/maplibre_flutter/commit/a16f0b4fe33012d7eef50ff5950a0cf4fa1d14ee))
 - **FIX**(windows): mask resize stretch — coalesce + freeze + cover-fit (exploratory). ([ec857fb6](https://github.com/Mankeli-Software/maplibre_flutter/commit/ec857fb6a277bdb25eda5c9c16c089b359ca6d9b))
 - **FEAT**(core): expose the style's transition options. ([201de598](https://github.com/Mankeli-Software/maplibre_flutter/commit/201de59858a25e831808899854e3f7cac6165303))
 - **FEAT**: declarative MapLibreMap(models:) prop. ([ca593364](https://github.com/Mankeli-Software/maplibre_flutter/commit/ca5933646fddebad9b61bb81baad1d90db01c444))
 - **FEAT**: drive models along a path, lift them off the ground, rotate the camera. ([73776545](https://github.com/Mankeli-Software/maplibre_flutter/commit/73776545052ab62bb6710644a8f72f5fe1d72c86))
 - **FEAT**(markers): queryRenderedFeatures, and animated widgets over engine clusters. ([74350233](https://github.com/Mankeli-Software/maplibre_flutter/commit/7435023333b055c4d0d2ab8212073fc6cf17ecea))
 - **FEAT**: expose 3D models through the app-facing API and example. ([f495cc3b](https://github.com/Mankeli-Software/maplibre_flutter/commit/f495cc3b70b2fa1e72664ca5af1b40ce1a5209e4))
 - **FEAT**(markers): app-facing engine-drawn annotations for very large datasets. ([5f2b2a9a](https://github.com/Mankeli-Software/maplibre_flutter/commit/5f2b2a9a5a7248a58afaf654e27af6335a1322a9))
 - **FEAT**(markers): glue interactive Flutter widgets to map points (macOS-first). ([532d3c3a](https://github.com/Mankeli-Software/maplibre_flutter/commit/532d3c3a516f2c12ab5fc52a8193ab9a7d7614fe))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([dd625919](https://github.com/Mankeli-Software/maplibre_flutter/commit/dd62591995b93b66ebdf8189ba222af200b94a13))
 - **FEAT**(linux): GTK plugin + shared fly-to + RGBA pixel-format flag. ([1ad69b85](https://github.com/Mankeli-Software/maplibre_flutter/commit/1ad69b85cc99a4f33a9ee2ed10fed91824f66acd))
 - **FEAT**: desktop map gestures — pan, pinch- and scroll-zoom. ([64f8ceb4](https://github.com/Mankeli-Software/maplibre_flutter/commit/64f8ceb4fabfe0dd0323ffd334c3a8329c2b24a8))
 - **FEAT**: size the desktop map to the widget + gate readiness on first frame. ([a83a284e](https://github.com/Mankeli-Software/maplibre_flutter/commit/a83a284e224337af3b84e44523037531a36a06a0))
 - **FEAT**: Android Hybrid Composition + map-ready signal; mobile-tier hardening. ([dba5974d](https://github.com/Mankeli-Software/maplibre_flutter/commit/dba5974d346dda471750d756d1058c5b487c883c))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([12823cf8](https://github.com/Mankeli-Software/maplibre_flutter/commit/12823cf817fd5298356ea357b568b9847797892d))
 - **FEAT**(android): render MapLibre map and drive it from Dart over jnigen. ([3293efc0](https://github.com/Mankeli-Software/maplibre_flutter/commit/3293efc042021ca76fd59d89224a32f00da8c14f))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([1157517f](https://github.com/Mankeli-Software/maplibre_flutter/commit/1157517f68e8786f97fdb5738e64517626c128aa))

## 0.0.2

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

## 0.0.1

* Initial scaffold.
