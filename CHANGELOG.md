# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

## 2026-07-31

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`maplibre_flutter` - `v0.0.3`](#maplibre_flutter---v003)
 - [`maplibre_flutter_android` - `v0.0.3`](#maplibre_flutter_android---v003)
 - [`maplibre_flutter_android_sdk` - `v0.0.2+1`](#maplibre_flutter_android_sdk---v0021)
 - [`maplibre_flutter_core` - `v0.0.3`](#maplibre_flutter_core---v003)
 - [`maplibre_flutter_ios` - `v0.0.3`](#maplibre_flutter_ios---v003)
 - [`maplibre_flutter_ios_sdk` - `v0.0.2+1`](#maplibre_flutter_ios_sdk---v0021)
 - [`maplibre_flutter_linux` - `v0.0.3`](#maplibre_flutter_linux---v003)
 - [`maplibre_flutter_macos` - `v0.0.3`](#maplibre_flutter_macos---v003)
 - [`maplibre_flutter_platform_interface` - `v0.0.3`](#maplibre_flutter_platform_interface---v003)
 - [`maplibre_flutter_web` - `v0.0.3`](#maplibre_flutter_web---v003)
 - [`maplibre_flutter_web_gljs` - `v0.0.2+1`](#maplibre_flutter_web_gljs---v0021)
 - [`maplibre_flutter_windows` - `v0.0.3`](#maplibre_flutter_windows---v003)

---

#### `maplibre_flutter` - `v0.0.3`

 - **REFACTOR**(maplibre_flutter): extract embed helper methods into widget classes. ([cffc6c73](https://github.com/Mankeli-Software/maplibre_flutter/commit/cffc6c739a751d98cb32f9e2507fcf04b8b2361c))
 - **REFACTOR**(ios): mbgl-core is the default; split SDK into maplibre_flutter_ios_sdk. ([872b2282](https://github.com/Mankeli-Software/maplibre_flutter/commit/872b2282faeaca8188fc16367d2f0adc2ff6be6d))
 - **REFACTOR**(windows): drop resize-mask polling — widget-owned freeze + cover-fit. ([053f9ed0](https://github.com/Mankeli-Software/maplibre_flutter/commit/053f9ed0741f452f7b01f811df2bcfb874e6fc67))
 - **PERF**: share GPU textures between models, merge parts by material, add a HUD. ([1c23a128](https://github.com/Mankeli-Software/maplibre_flutter/commit/1c23a128d0596a39c2c2773b0e88976618dd6b00))
 - **PERF**(markers): cull off-screen markers and cache rich children in layers. ([59c86515](https://github.com/Mankeli-Software/maplibre_flutter/commit/59c865153503fd5cb6868abc6ff569a529577892))
 - **FIX**(example): the fps counter measured Flutter's vsync, not the map. ([fb811d72](https://github.com/Mankeli-Software/maplibre_flutter/commit/fb811d72050b9af2e5fcf02b35de4c6b6345b221))
 - **FIX**(gestures): reliable pan inertia — manual velocity, no zoom-fling, two-finger pan. ([2f100df7](https://github.com/Mankeli-Software/maplibre_flutter/commit/2f100df7ce9519832932a04858d5ae31155224d8))
 - **FIX**(core): model heading rotated the wrong way; circle the nearest marker. ([d318f19a](https://github.com/Mankeli-Software/maplibre_flutter/commit/d318f19ae28c9ff69c40d73618c8c0f32d7416e0))
 - **FIX**(example): un-clip the widget-derived icon; add an unclustered icon scenario. ([e64139a1](https://github.com/Mankeli-Software/maplibre_flutter/commit/e64139a1aea2e2493a1134f347d6e131e0655022))
 - **FIX**: four model bugs from the first hands-on run. ([4d38df20](https://github.com/Mankeli-Software/maplibre_flutter/commit/4d38df20a3cc9c85edc50379612836afb6fa94e9))
 - **FIX**(markers): a cluster count label with an unknown font killed the dataset. ([822717bc](https://github.com/Mankeli-Software/maplibre_flutter/commit/822717bc00181ff253c9375da26e9c74642af54d))
 - **FIX**(gestures): touch flick no longer spins the world at low zoom. ([a0693011](https://github.com/Mankeli-Software/maplibre_flutter/commit/a0693011c88f093ab8c984a77d43f1d0311c14b2))
 - **FIX**(desktop): pinch/scroll-zoom work when the cursor is over an overlay control. ([7f717e2a](https://github.com/Mankeli-Software/maplibre_flutter/commit/7f717e2a1c41e1e8cb8588c18597fdc062f585f9))
 - **FIX**(linux): desktop gesture fixes — resize stretch, 2x trackpad pan, pinch anchor. ([026132a5](https://github.com/Mankeli-Software/maplibre_flutter/commit/026132a5aa4155efd715610b15cda4bac92b549d))
 - **FIX**(gestures): trackpad pinch zoom drifts from the cursor on Windows/Linux. ([673c51f4](https://github.com/Mankeli-Software/maplibre_flutter/commit/673c51f499c50594e3c081f94c38d3ca5b916d34))
 - **FIX**(windows): mask resize stretch — coalesce + freeze + cover-fit (exploratory). ([379e4f9a](https://github.com/Mankeli-Software/maplibre_flutter/commit/379e4f9a005e7b40e6a47f8ccd92b6d69283ba66))
 - **FIX**(macos): harden window resize — IOSurface UAF crash, white blink, frame-lag squeeze. ([962951c5](https://github.com/Mankeli-Software/maplibre_flutter/commit/962951c556156f3926abe2cce9acbe1795399851))
 - **FIX**(gestures): reuse one Ticker for pan inertia (SingleTicker forbids per-fling tickers). ([6bcbb37b](https://github.com/Mankeli-Software/maplibre_flutter/commit/6bcbb37b885a0d6a1afb4a9e7d47f6137c5b2832))
 - **FEAT**(markers): queryRenderedFeatures, and animated widgets over engine clusters. ([9db82a28](https://github.com/Mankeli-Software/maplibre_flutter/commit/9db82a2874fb99ef7beb0ab28953a6cc63fb526e))
 - **FEAT**: multi-model stress mode, and share parsed meshes between models. ([177aaf07](https://github.com/Mankeli-Software/maplibre_flutter/commit/177aaf075468b69ba41bc2992017c4bd34e20b60))
 - **FEAT**(markers): app-facing engine-drawn annotations for very large datasets. ([f7538bb7](https://github.com/Mankeli-Software/maplibre_flutter/commit/f7538bb7772fc9f50188ef7b1e0bc2c84f0fc31e))
 - **FEAT**(example): swap between the car and the test box at runtime. ([40086167](https://github.com/Mankeli-Software/maplibre_flutter/commit/4008616710b099d41c7679e21a36aa033148eb42))
 - **FEAT**(markers): glue interactive Flutter widgets to map points (macOS-first). ([294452d7](https://github.com/Mankeli-Software/maplibre_flutter/commit/294452d74a3282dc6ce520c6b3eccbc56fed55ab))
 - **FEAT**(gestures): port the MapLibre Native SDK pan-fling model. ([f271e46b](https://github.com/Mankeli-Software/maplibre_flutter/commit/f271e46b4c6b43a4e276f915cf369b03a0382cb6))
 - **FEAT**(example): bundle the Alto K10 as the default model, with attribution. ([b8b120dd](https://github.com/Mankeli-Software/maplibre_flutter/commit/b8b120ddc67da1ab47b8d31888b6291ed5349894))
 - **FEAT**: declarative MapLibreMap(models:) prop. ([8e9a0959](https://github.com/Mankeli-Software/maplibre_flutter/commit/8e9a09593f760d326f96a58dca5eb2f259b8480b))
 - **FEAT**: Android Hybrid Composition + map-ready signal; mobile-tier hardening. ([8e2a513d](https://github.com/Mankeli-Software/maplibre_flutter/commit/8e2a513da5514093bd94f21da624d2d6b43db23f))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([05b45ffd](https://github.com/Mankeli-Software/maplibre_flutter/commit/05b45ffdd2922a12b54ac4aede0265114cfb42b3))
 - **FEAT**(example): bundle a demo vehicle so models need no setup to test. ([ac023665](https://github.com/Mankeli-Software/maplibre_flutter/commit/ac023665f7628e5688bcfd84e2ee1711a62d8f0b))
 - **FEAT**(markers): markers, layers and queries on Linux, Windows, iOS-core, Android-core. ([acf0137c](https://github.com/Mankeli-Software/maplibre_flutter/commit/acf0137ca9ba57a463c6e23688a15b5558ed4e73))
 - **FEAT**(core): expose the style's transition options. ([7931c39a](https://github.com/Mankeli-Software/maplibre_flutter/commit/7931c39ab57407f113c9fd71a8a367c59d58546b))
 - **FEAT**(example): add and remove cars incrementally while the field runs. ([bb472f39](https://github.com/Mankeli-Software/maplibre_flutter/commit/bb472f395fd41a9f50f13d6509411963e20e3ef0))
 - **FEAT**(style): typed style API generated from the MapLibre Style Spec. ([121a0ec2](https://github.com/Mankeli-Software/maplibre_flutter/commit/121a0ec20de80d04b1a1a706f49e2796f37deae8))
 - **FEAT**(android): render MapLibre map and drive it from Dart over jnigen. ([eb4250a1](https://github.com/Mankeli-Software/maplibre_flutter/commit/eb4250a1a1cb09f1e9eafed57295fc5166c60b34))
 - **FEAT**: drive models along a path, lift them off the ground, rotate the camera. ([ab062139](https://github.com/Mankeli-Software/maplibre_flutter/commit/ab062139d5f1ae6694daf789d49224d116e60e96))
 - **FEAT**(example): fold the 3D-model demo into the scenario list, and add map turning. ([9c975886](https://github.com/Mankeli-Software/maplibre_flutter/commit/9c975886a9ee2b30b845954f9e140bea6eadd6ae))
 - **FEAT**(gestures): pan inertia (fling) on the custom rendering engines. ([8591ab1d](https://github.com/Mankeli-Software/maplibre_flutter/commit/8591ab1db2b1a15c5513a03d9bf80115faa4879b))
 - **FEAT**(maplibre_flutter_android): experimental core-on-Android render (mbgl-core GL → Texture). ([0b57263b](https://github.com/Mankeli-Software/maplibre_flutter/commit/0b57263b561984da8b2fd69a05d35acf3020737e))
 - **FEAT**: expose 3D models through the app-facing API and example. ([57e2578a](https://github.com/Mankeli-Software/maplibre_flutter/commit/57e2578aec6d86ea1752a4bcc4db04d0214908e1))
 - **FEAT**(maplibre_flutter): namespace camera API under controller.camera. ([e898ae41](https://github.com/Mankeli-Software/maplibre_flutter/commit/e898ae41b17af0153781a9f5a8fea57a291ac568))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([b15fa1fd](https://github.com/Mankeli-Software/maplibre_flutter/commit/b15fa1fd23040f7e3a0ff690533f5d9f6affebe4))
 - **FEAT**(macos): render mbgl-core into a Flutter Texture. ([ea7dfe59](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea7dfe59006e493cc0c21c638ba2185956479b0d))
 - **FEAT**(windows): build + render mbgl-core on real Windows hardware (ANGLE/EGL). ([dacf9a86](https://github.com/Mankeli-Software/maplibre_flutter/commit/dacf9a86c8ded12754a2ae1ca08c149982147f47))
 - **FEAT**: size the desktop map to the widget + gate readiness on first frame. ([3cdb4931](https://github.com/Mankeli-Software/maplibre_flutter/commit/3cdb4931af732070fb1ca662e303de7a544e6bca))
 - **FEAT**: desktop map gestures — pan, pinch- and scroll-zoom. ([c1944e4c](https://github.com/Mankeli-Software/maplibre_flutter/commit/c1944e4c2ed9115943ca47e3ad5c11a6299ee033))
 - **FEAT**(macos): add Podfile and related configurations for macOS support. ([0c4f9139](https://github.com/Mankeli-Software/maplibre_flutter/commit/0c4f91390cbe10d14ecbad344043d09342d2a686))
 - **FEAT**(web): maplibre-gl-js rendering + control via HtmlElementView. ([51223efc](https://github.com/Mankeli-Software/maplibre_flutter/commit/51223efcf3a8b0bb1300d7061122139d228dc808))
 - **DOCS**: note smooth/springy pinch-to-zoom as an unimplemented feature. ([e52a3c15](https://github.com/Mankeli-Software/maplibre_flutter/commit/e52a3c15f98dd0cbfc740e9c8b606ab57e16c08a))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([ea27815a](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea27815a4e855634723c9c3ae98b123a0d8dcdb2))
 - **DOCS**: reframe for core-primary on every platform; record the inversion. ([3161a63d](https://github.com/Mankeli-Software/maplibre_flutter/commit/3161a63d5f48663bbffe70f74f36687e0873ee08))
 - **DOCS**: design notes for a generated, typed Dart style API. ([d6a1643b](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6a1643b0dac1fc8d95a6c3b346fe8599e5943e6))
 - **DOCS**(linux): mark desktop tier verified on real hardware. ([62eacbe0](https://github.com/Mankeli-Software/maplibre_flutter/commit/62eacbe0cc0898429b628ddd44d4ac5cb22ee633))

#### `maplibre_flutter_android` - `v0.0.3`

 - **REFACTOR**(android): mbgl-core is the default; split SDK into maplibre_flutter_android_sdk. ([21ac0494](https://github.com/Mankeli-Software/maplibre_flutter/commit/21ac0494c4432441b687735cc04a73b3441d107f))
 - **FEAT**(core): expose the style's transition options. ([7931c39a](https://github.com/Mankeli-Software/maplibre_flutter/commit/7931c39ab57407f113c9fd71a8a367c59d58546b))
 - **FEAT**(markers): markers, layers and queries on Linux, Windows, iOS-core, Android-core. ([acf0137c](https://github.com/Mankeli-Software/maplibre_flutter/commit/acf0137ca9ba57a463c6e23688a15b5558ed4e73))
 - **FEAT**(maplibre_flutter_android): adaptive zero-copy — on by default, auto-fallback to CPU. ([173d1641](https://github.com/Mankeli-Software/maplibre_flutter/commit/173d1641e91753183b9423c51919cf5070160361))
 - **FEAT**(maplibre_flutter_android): experimental core-on-Android render (mbgl-core GL → Texture). ([0b57263b](https://github.com/Mankeli-Software/maplibre_flutter/commit/0b57263b561984da8b2fd69a05d35acf3020737e))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([b15fa1fd](https://github.com/Mankeli-Software/maplibre_flutter/commit/b15fa1fd23040f7e3a0ff690533f5d9f6affebe4))
 - **FEAT**: size the desktop map to the widget + gate readiness on first frame. ([3cdb4931](https://github.com/Mankeli-Software/maplibre_flutter/commit/3cdb4931af732070fb1ca662e303de7a544e6bca))
 - **FEAT**: Android Hybrid Composition + map-ready signal; mobile-tier hardening. ([8e2a513d](https://github.com/Mankeli-Software/maplibre_flutter/commit/8e2a513da5514093bd94f21da624d2d6b43db23f))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([05b45ffd](https://github.com/Mankeli-Software/maplibre_flutter/commit/05b45ffdd2922a12b54ac4aede0265114cfb42b3))
 - **FEAT**(android): render MapLibre map and drive it from Dart over jnigen. ([eb4250a1](https://github.com/Mankeli-Software/maplibre_flutter/commit/eb4250a1a1cb09f1e9eafed57295fc5166c60b34))
 - **DOCS**: reframe for core-primary on every platform; record the inversion. ([3161a63d](https://github.com/Mankeli-Software/maplibre_flutter/commit/3161a63d5f48663bbffe70f74f36687e0873ee08))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([ea27815a](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea27815a4e855634723c9c3ae98b123a0d8dcdb2))

#### `maplibre_flutter_android_sdk` - `v0.0.2+1`

 - **REFACTOR**(android): mbgl-core is the default; split SDK into maplibre_flutter_android_sdk. ([21ac0494](https://github.com/Mankeli-Software/maplibre_flutter/commit/21ac0494c4432441b687735cc04a73b3441d107f))
 - **DOCS**: compact CLAUDE.md and archive the decision log. ([40bbfd06](https://github.com/Mankeli-Software/maplibre_flutter/commit/40bbfd06aa4f7dfb16b6a542c763673bdf69cdd5))

#### `maplibre_flutter_core` - `v0.0.3`

 - **REFACTOR**(windows): drop resize-mask polling — widget-owned freeze + cover-fit. ([053f9ed0](https://github.com/Mankeli-Software/maplibre_flutter/commit/053f9ed0741f452f7b01f811df2bcfb874e6fc67))
 - **PERF**(core): coalesce render requests on the render thread. ([9f5d9e0f](https://github.com/Mankeli-Software/maplibre_flutter/commit/9f5d9e0f762273c245b92b59aa3dac734e9517be))
 - **PERF**: share GPU textures between models, merge parts by material, add a HUD. ([1c23a128](https://github.com/Mankeli-Software/maplibre_flutter/commit/1c23a128d0596a39c2c2773b0e88976618dd6b00))
 - **PERF**(linux): v2 zero-copy sync — glFlush + implicit dmabuf fence. ([5d5bfbc4](https://github.com/Mankeli-Software/maplibre_flutter/commit/5d5bfbc499e93532016a40fc9c492623876008bd))
 - **FIX**(example): the fps counter measured Flutter's vsync, not the map. ([fb811d72](https://github.com/Mankeli-Software/maplibre_flutter/commit/fb811d72050b9af2e5fcf02b35de4c6b6345b221))
 - **FIX**(core): model heading rotated the wrong way; circle the nearest marker. ([d318f19a](https://github.com/Mankeli-Software/maplibre_flutter/commit/d318f19ae28c9ff69c40d73618c8c0f32d7416e0))
 - **FIX**: four model bugs from the first hands-on run. ([4d38df20](https://github.com/Mankeli-Software/maplibre_flutter/commit/4d38df20a3cc9c85edc50379612836afb6fa94e9))
 - **FIX**(markers): a cluster count label with an unknown font killed the dataset. ([822717bc](https://github.com/Mankeli-Software/maplibre_flutter/commit/822717bc00181ff253c9375da26e9c74642af54d))
 - **FIX**(core): make 3D custom-drawable geometry depth-test on Metal. ([e4841204](https://github.com/Mankeli-Software/maplibre_flutter/commit/e4841204d64a2318adffad1b1fb8108b6e7106dd))
 - **FIX**(core): correct the projection Y axis and glue markers to the shown frame. ([2c8ce1c3](https://github.com/Mankeli-Software/maplibre_flutter/commit/2c8ce1c39a5b1c1a5c2a871cc288641c5379a8a8))
 - **FIX**(windows): mask resize stretch — coalesce + freeze + cover-fit (exploratory). ([379e4f9a](https://github.com/Mankeli-Software/maplibre_flutter/commit/379e4f9a005e7b40e6a47f8ccd92b6d69283ba66))
 - **FIX**(macos): harden window resize — IOSurface UAF crash, white blink, frame-lag squeeze. ([962951c5](https://github.com/Mankeli-Software/maplibre_flutter/commit/962951c556156f3926abe2cce9acbe1795399851))
 - **FIX**(web): glFlush after present blit so the canvas isn't left stale (real-GPU "stuck"/blank). ([61640556](https://github.com/Mankeli-Software/maplibre_flutter/commit/616405566058c0e68b95d7dc88b72f4dc64e5525))
 - **FIX**(web): unstick the native-core map — async HTTP + drop the redundant blit. ([2896a272](https://github.com/Mankeli-Software/maplibre_flutter/commit/2896a2721e7382ee6075d79009eb3758d8316001))
 - **FIX**(core): cap desktop tile-request concurrency to avoid HTTP/2 throttling. ([7f7f2709](https://github.com/Mankeli-Software/maplibre_flutter/commit/7f7f27096c91c1ce86144b18071c9c14562f5668))
 - **FIX**(core): skip the build hook when code assets aren't requested. ([7bd81f7c](https://github.com/Mankeli-Software/maplibre_flutter/commit/7bd81f7c3dc34f6ae994ce67bcc7becd03c6ec62))
 - **FEAT**(markers): glue interactive Flutter widgets to map points (macOS-first). ([294452d7](https://github.com/Mankeli-Software/maplibre_flutter/commit/294452d74a3282dc6ce520c6b3eccbc56fed55ab))
 - **FEAT**(example): swap between the car and the test box at runtime. ([40086167](https://github.com/Mankeli-Software/maplibre_flutter/commit/4008616710b099d41c7679e21a36aa033148eb42))
 - **FEAT**(core): expose the style's transition options. ([7931c39a](https://github.com/Mankeli-Software/maplibre_flutter/commit/7931c39ab57407f113c9fd71a8a367c59d58546b))
 - **FEAT**: multi-model stress mode, and share parsed meshes between models. ([177aaf07](https://github.com/Mankeli-Software/maplibre_flutter/commit/177aaf075468b69ba41bc2992017c4bd34e20b60))
 - **FEAT**: drive models along a path, lift them off the ground, rotate the camera. ([ab062139](https://github.com/Mankeli-Software/maplibre_flutter/commit/ab062139d5f1ae6694daf789d49224d116e60e96))
 - **FEAT**(markers): queryRenderedFeatures, and animated widgets over engine clusters. ([9db82a28](https://github.com/Mankeli-Software/maplibre_flutter/commit/9db82a2874fb99ef7beb0ab28953a6cc63fb526e))
 - **FEAT**(gestures): pan inertia (fling) on the custom rendering engines. ([8591ab1d](https://github.com/Mankeli-Software/maplibre_flutter/commit/8591ab1db2b1a15c5513a03d9bf80115faa4879b))
 - **FEAT**: expose 3D models through the app-facing API and example. ([57e2578a](https://github.com/Mankeli-Software/maplibre_flutter/commit/57e2578aec6d86ea1752a4bcc4db04d0214908e1))
 - **FEAT**(maplibre_flutter_android): adaptive zero-copy — on by default, auto-fallback to CPU. ([173d1641](https://github.com/Mankeli-Software/maplibre_flutter/commit/173d1641e91753183b9423c51919cf5070160361))
 - **FEAT**(maplibre_flutter_android): experimental core-on-Android render (mbgl-core GL → Texture). ([0b57263b](https://github.com/Mankeli-Software/maplibre_flutter/commit/0b57263b561984da8b2fd69a05d35acf3020737e))
 - **FEAT**(web): smooth resize via ResizeObserver (fix the post-resize stretch). ([263a17dd](https://github.com/Mankeli-Software/maplibre_flutter/commit/263a17ddcf59b7f194d918f289dd0e10cf53e740))
 - **FEAT**(web): continuous rendering, resize fixes, bounded fetch pool, fly-to arc. ([3cb8697d](https://github.com/Mankeli-Software/maplibre_flutter/commit/3cb8697db763f1ca94a1095b8cd805165684bd0e))
 - **FEAT**(core): split .glb models into per-material parts; render a 509k-vertex car. ([fb80b1fe](https://github.com/Mankeli-Software/maplibre_flutter/commit/fb80b1fe0a2056c9c4f872e9384fb23feded49ce))
 - **FEAT**(web): native-core web map is interactive — gestures, auto-size, fly-to. ([bc5bfafd](https://github.com/Mankeli-Software/maplibre_flutter/commit/bc5bfafd4df39411c2df3563bf603de7155ba096))
 - **FEAT**(web): native-core map renders in the Flutter web example (verified). ([754b1336](https://github.com/Mankeli-Software/maplibre_flutter/commit/754b13362b0ce3b4b8c7ea8e6ed3b54a2020cc8f))
 - **FEAT**(web): embind module renders a map to the canvas (verified). ([1f589932](https://github.com/Mankeli-Software/maplibre_flutter/commit/1f5899321bcff869094ece0b9d9172b3680f843a))
 - **FEAT**(web): render mbgl-core in WebAssembly — full platform-layer port (verified). ([bf3f564e](https://github.com/Mankeli-Software/maplibre_flutter/commit/bf3f564e1cdd30b5babefb3cce2c297a2da9eb33))
 - **FEAT**(maplibre_flutter_core): run the iOS core renderer on the Simulator. ([b174e343](https://github.com/Mankeli-Software/maplibre_flutter/commit/b174e3431584a40304bf702b0886c43fa6048714))
 - **FEAT**(maplibre_flutter_ios): experimental core-on-iOS renderer (POC). ([dfb25a89](https://github.com/Mankeli-Software/maplibre_flutter/commit/dfb25a8980e8368e56d9e13d6cdad51195705c8d))
 - **FEAT**(web): prove mbgl-core compiles to WASM (Emscripten probe) + status. ([6b13856e](https://github.com/Mankeli-Software/maplibre_flutter/commit/6b13856e3f2e7948e9919f3cbc784d35b1c7030d))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([05b45ffd](https://github.com/Mankeli-Software/maplibre_flutter/commit/05b45ffdd2922a12b54ac4aede0265114cfb42b3))
 - **FEAT**(windows): Vulkan backend — fixes the fly-to crash (replaces ANGLE/OpenGL-ES). ([890f99ad](https://github.com/Mankeli-Software/maplibre_flutter/commit/890f99ad962a2d99e0298705e6642a396d584aa1))
 - **FEAT**(windows): native map — DNS fix (OS resolver) + D3D11 zero-copy present. ([b18d4e82](https://github.com/Mankeli-Software/maplibre_flutter/commit/b18d4e82eb1552ed580cfb99da455a01929c8810))
 - **FEAT**(windows): build + render mbgl-core on real Windows hardware (ANGLE/EGL). ([dacf9a86](https://github.com/Mankeli-Software/maplibre_flutter/commit/dacf9a86c8ded12754a2ae1ca08c149982147f47))
 - **FEAT**(windows): scaffold the Windows desktop tier (ANGLE/EGL, CPU pixel-buffer). ([f985506c](https://github.com/Mankeli-Software/maplibre_flutter/commit/f985506cc7d732c77944bd4e40bc48196f283972))
 - **FEAT**(core): directional lighting for 3D models. ([5316007b](https://github.com/Mankeli-Software/maplibre_flutter/commit/5316007bab7bfc5abd3cbb3349e5cb4a8597f2be))
 - **FEAT**(linux): zero-copy FlTextureGL present via dmabuf. ([bae4d76a](https://github.com/Mankeli-Software/maplibre_flutter/commit/bae4d76a59590b2190f6330fe55a4824372d6d88))
 - **FEAT**(core): load and render .glb models; fix Metal custom-geometry sampler wrap. ([3b3966ff](https://github.com/Mankeli-Software/maplibre_flutter/commit/3b3966ff8a0435df73c23aed1307f653f41ecc84))
 - **FEAT**(linux): GTK plugin + shared fly-to + RGBA pixel-format flag. ([71d2b463](https://github.com/Mankeli-Software/maplibre_flutter/commit/71d2b463792f2a51a306f514d17283c7da865704))
 - **FEAT**(core): engine-drawn sources, layers and images, with in-engine clustering. ([8efd1e14](https://github.com/Mankeli-Software/maplibre_flutter/commit/8efd1e14a857c5a29b7120296a299ff39aa5cfa5))
 - **FEAT**(core): prebuilt-artifact distribution + CI workflows. ([2e32080f](https://github.com/Mankeli-Software/maplibre_flutter/commit/2e32080fbb2a808af2f62484cbed8613e04a85d1))
 - **FEAT**(core): Continuous render mode for smooth fly-to over detailed tiles. ([10dc67ac](https://github.com/Mankeli-Software/maplibre_flutter/commit/10dc67ac94d2cf683544e3fe91437a2e4d0b73cf))
 - **FEAT**(macos): zero-copy present via GPU blit into an IOSurface. ([98b81c7f](https://github.com/Mankeli-Software/maplibre_flutter/commit/98b81c7f29d4cf0ed6be3c2feb35f9ccee0717dc))
 - **FEAT**(core): render MapLibre Native (mbgl-core) headless on desktop. ([cb5fec32](https://github.com/Mankeli-Software/maplibre_flutter/commit/cb5fec32709136236d29d2d96c1c1e744f71ed06))
 - **FEAT**: desktop map gestures — pan, pinch- and scroll-zoom. ([c1944e4c](https://github.com/Mankeli-Software/maplibre_flutter/commit/c1944e4c2ed9115943ca47e3ad5c11a6299ee033))
 - **FEAT**: size the desktop map to the widget + gate readiness on first frame. ([3cdb4931](https://github.com/Mankeli-Software/maplibre_flutter/commit/3cdb4931af732070fb1ca662e303de7a544e6bca))
 - **FEAT**(core): OpenGL/EGL arm for non-Apple desktop (Linux GL core). ([b52fad08](https://github.com/Mankeli-Software/maplibre_flutter/commit/b52fad08f2cf94136d8bc5a2aec7b0f9f22421be))
 - **DOCS**: design notes for a generated, typed Dart style API. ([d6a1643b](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6a1643b0dac1fc8d95a6c3b346fe8599e5943e6))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([ea27815a](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea27815a4e855634723c9c3ae98b123a0d8dcdb2))

#### `maplibre_flutter_ios` - `v0.0.3`

 - **REFACTOR**(ios): mbgl-core is the default; split SDK into maplibre_flutter_ios_sdk. ([872b2282](https://github.com/Mankeli-Software/maplibre_flutter/commit/872b2282faeaca8188fc16367d2f0adc2ff6be6d))
 - **FIX**(macos): harden window resize — IOSurface UAF crash, white blink, frame-lag squeeze. ([962951c5](https://github.com/Mankeli-Software/maplibre_flutter/commit/962951c556156f3926abe2cce9acbe1795399851))
 - **FIX**(maplibre_flutter_ios): render core at the device pixel ratio. ([e9ded4bc](https://github.com/Mankeli-Software/maplibre_flutter/commit/e9ded4bce1b25ba5044ed0bed1db59d6c0bbdf9d))
 - **FEAT**(core): expose the style's transition options. ([7931c39a](https://github.com/Mankeli-Software/maplibre_flutter/commit/7931c39ab57407f113c9fd71a8a367c59d58546b))
 - **FEAT**(markers): markers, layers and queries on Linux, Windows, iOS-core, Android-core. ([acf0137c](https://github.com/Mankeli-Software/maplibre_flutter/commit/acf0137ca9ba57a463c6e23688a15b5558ed4e73))
 - **FEAT**(maplibre_flutter_core): run the iOS core renderer on the Simulator. ([b174e343](https://github.com/Mankeli-Software/maplibre_flutter/commit/b174e3431584a40304bf702b0886c43fa6048714))
 - **FEAT**(maplibre_flutter_ios): experimental core-on-iOS renderer (POC). ([dfb25a89](https://github.com/Mankeli-Software/maplibre_flutter/commit/dfb25a8980e8368e56d9e13d6cdad51195705c8d))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([b15fa1fd](https://github.com/Mankeli-Software/maplibre_flutter/commit/b15fa1fd23040f7e3a0ff690533f5d9f6affebe4))
 - **FEAT**: size the desktop map to the widget + gate readiness on first frame. ([3cdb4931](https://github.com/Mankeli-Software/maplibre_flutter/commit/3cdb4931af732070fb1ca662e303de7a544e6bca))
 - **FEAT**: Android Hybrid Composition + map-ready signal; mobile-tier hardening. ([8e2a513d](https://github.com/Mankeli-Software/maplibre_flutter/commit/8e2a513da5514093bd94f21da624d2d6b43db23f))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([05b45ffd](https://github.com/Mankeli-Software/maplibre_flutter/commit/05b45ffdd2922a12b54ac4aede0265114cfb42b3))
 - **DOCS**: reframe for core-primary on every platform; record the inversion. ([3161a63d](https://github.com/Mankeli-Software/maplibre_flutter/commit/3161a63d5f48663bbffe70f74f36687e0873ee08))
 - **DOCS**(maplibre_flutter_ios): note the simulator-only tile seam (clean on device). ([74e2b8c3](https://github.com/Mankeli-Software/maplibre_flutter/commit/74e2b8c387ab7d71d7a6106e2d696fc7e0f2997e))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([ea27815a](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea27815a4e855634723c9c3ae98b123a0d8dcdb2))

#### `maplibre_flutter_ios_sdk` - `v0.0.2+1`

 - **REFACTOR**(ios): mbgl-core is the default; split SDK into maplibre_flutter_ios_sdk. ([872b2282](https://github.com/Mankeli-Software/maplibre_flutter/commit/872b2282faeaca8188fc16367d2f0adc2ff6be6d))
 - **DOCS**: compact CLAUDE.md and archive the decision log. ([40bbfd06](https://github.com/Mankeli-Software/maplibre_flutter/commit/40bbfd06aa4f7dfb16b6a542c763673bdf69cdd5))
 - **DOCS**: reframe for core-primary on every platform; record the inversion. ([3161a63d](https://github.com/Mankeli-Software/maplibre_flutter/commit/3161a63d5f48663bbffe70f74f36687e0873ee08))

#### `maplibre_flutter_linux` - `v0.0.3`

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

#### `maplibre_flutter_macos` - `v0.0.3`

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

#### `maplibre_flutter_platform_interface` - `v0.0.3`

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

#### `maplibre_flutter_web` - `v0.0.3`

 - **REFACTOR**(web): mbgl-core WASM is the default; split gl-js into maplibre_flutter_web_gljs. ([1544efe2](https://github.com/Mankeli-Software/maplibre_flutter/commit/1544efe27e3665b68147ad0062eb05783c363599))
 - **FEAT**(web): smooth resize via ResizeObserver (fix the post-resize stretch). ([263a17dd](https://github.com/Mankeli-Software/maplibre_flutter/commit/263a17ddcf59b7f194d918f289dd0e10cf53e740))
 - **FEAT**(web): native-core web map is interactive — gestures, auto-size, fly-to. ([bc5bfafd](https://github.com/Mankeli-Software/maplibre_flutter/commit/bc5bfafd4df39411c2df3563bf603de7155ba096))
 - **FEAT**(web): native-core map renders in the Flutter web example (verified). ([754b1336](https://github.com/Mankeli-Software/maplibre_flutter/commit/754b13362b0ce3b4b8c7ea8e6ed3b54a2020cc8f))
 - **FEAT**(web): scaffold experimental native-core (WASM) web renderer behind a build flag. ([ac5cd380](https://github.com/Mankeli-Software/maplibre_flutter/commit/ac5cd380241dfb2073e48fafa55bb435299da90b))
 - **FEAT**: Introduce MapLibreMapController for imperative map control. ([b15fa1fd](https://github.com/Mankeli-Software/maplibre_flutter/commit/b15fa1fd23040f7e3a0ff690533f5d9f6affebe4))
 - **FEAT**(web): maplibre-gl-js rendering + control via HtmlElementView. ([51223efc](https://github.com/Mankeli-Software/maplibre_flutter/commit/51223efcf3a8b0bb1300d7061122139d228dc808))
 - **FEAT**(ios): render MapLibre map and drive it from Dart over swiftgen. ([05b45ffd](https://github.com/Mankeli-Software/maplibre_flutter/commit/05b45ffdd2922a12b54ac4aede0265114cfb42b3))
 - **DOCS**: reframe for core-primary on every platform; record the inversion. ([3161a63d](https://github.com/Mankeli-Software/maplibre_flutter/commit/3161a63d5f48663bbffe70f74f36687e0873ee08))
 - **DOCS**(web): record the working native-core WASM PoC. ([fcd01123](https://github.com/Mankeli-Software/maplibre_flutter/commit/fcd01123f8116293b6a2a7cceb601d15cbbd05bc))
 - **DOCS**: rewrite READMEs + feature matrix for first pub.dev release. ([ea27815a](https://github.com/Mankeli-Software/maplibre_flutter/commit/ea27815a4e855634723c9c3ae98b123a0d8dcdb2))
 - **DOCS**(web): add maplibre_flutter_web implementation plan. ([c09efcd2](https://github.com/Mankeli-Software/maplibre_flutter/commit/c09efcd2e09b1029168320d741f2e75f45712ed4))

#### `maplibre_flutter_web_gljs` - `v0.0.2+1`

 - **REFACTOR**(web): mbgl-core WASM is the default; split gl-js into maplibre_flutter_web_gljs. ([1544efe2](https://github.com/Mankeli-Software/maplibre_flutter/commit/1544efe27e3665b68147ad0062eb05783c363599))

#### `maplibre_flutter_windows` - `v0.0.3`

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


## 2026-06-17

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`maplibre_flutter` - `v0.0.2`](#maplibre_flutter---v002)
 - [`maplibre_flutter_android` - `v0.0.2`](#maplibre_flutter_android---v002)
 - [`maplibre_flutter_core` - `v0.0.2`](#maplibre_flutter_core---v002)
 - [`maplibre_flutter_ios` - `v0.0.2`](#maplibre_flutter_ios---v002)
 - [`maplibre_flutter_linux` - `v0.0.2`](#maplibre_flutter_linux---v002)
 - [`maplibre_flutter_macos` - `v0.0.2`](#maplibre_flutter_macos---v002)
 - [`maplibre_flutter_platform_interface` - `v0.0.2`](#maplibre_flutter_platform_interface---v002)
 - [`maplibre_flutter_web` - `v0.0.2`](#maplibre_flutter_web---v002)
 - [`maplibre_flutter_windows` - `v0.0.2`](#maplibre_flutter_windows---v002)

---

#### `maplibre_flutter` - `v0.0.2`

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

#### `maplibre_flutter_android` - `v0.0.2`

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

#### `maplibre_flutter_core` - `v0.0.2`

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

#### `maplibre_flutter_ios` - `v0.0.2`

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

#### `maplibre_flutter_linux` - `v0.0.2`

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

#### `maplibre_flutter_macos` - `v0.0.2`

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

#### `maplibre_flutter_platform_interface` - `v0.0.2`

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

#### `maplibre_flutter_web` - `v0.0.2`

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

#### `maplibre_flutter_windows` - `v0.0.2`

 - **FEAT**: scaffold federated monorepo, publishable on pub.dev. ([d6fff80d](https://github.com/Mankeli-Software/maplibre_flutter/commit/d6fff80df09a8f74123a41fffadd207bde125e36))

