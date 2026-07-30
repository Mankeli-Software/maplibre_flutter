# Animated 3D models on the map — research & implementation plan

_Researched 2026-07-29 against the pinned submodule `fa8a9c8e3261`. Not yet implemented; nothing in this doc has been built or run._

## 1. How 3D models work in MapLibre today

**There is no model layer. Anywhere.** Not in the style spec, not in gl-js, not in MapLibre Native, not on the roadmap. Every 3D model you have ever seen on a MapLibre map was drawn by third-party code through an escape hatch.

Verified directly, not from docs:

- **Style spec** (`maplibre-style-spec` `v8.json`, live): the complete `layer.type` enum is `fill, line, symbol, circle, heatmap, fill-extrusion, raster, hillshade, color-relief, background`. No `model`. No `models` root property. Mapbox GL JS v3 has both (`model` layer + `batched-model` source) — that implementation is proprietary post-v2 and cannot be copied, but the reason MapLibre lacks one is that nobody has contributed it, and maintainers have since chosen plugin/custom layers as the answer rather than a built-in layer.
- **This repo's pinned mbgl** (`third_party/maplibre-native` @ `fa8a9c8e3261`, 2026-06-11): `ls include/mbgl/style/layers/` yields no model layer; `grep -rn 'gltf' src/ include/` is empty. `fill_extrusion_layer` is the only built-in 3D geometry. MapLibre Native's roadmap lists Globe, Terrain3D, WebGPU, Plugin API — no models.
- **Upstream tracking**: maplibre-native #2806 "Rendering 3D Models" is **open and dormant** since 2024-09-06. #3096 "GLTF Model Support" was closed 2025-07-26 with *"Closing since this can now be done using plugins."* gl-js #3794 was closed 2026-03-27 in favour of a three.js 3D-tiles *example* plus "the plugin approach" — **not** because a layer shipped.

### The three real mechanisms (native)

| Mechanism | What you get | Portability | Verdict |
|---|---|---|---|
| **`CustomLayer` + `CustomLayerHost`** | Raw GPU callback inside mbgl's render pass. `initialize/render/contextLost/deinitialize`. | **GL + Metal only on our pin.** `include/mbgl/style/layers/` has only an `mtl/` subdir — there is no `vulkan::CustomLayerRenderParameters`, so on Vulkan the host receives camera scalars and **no command buffer**. | Full shader freedom (PBR, normals, skinning) but **dead on Windows** and 3× the renderer code. |
| **`CustomDrawableLayer` + `Host::Interface`** | You hand mbgl vertex/index buffers and a `mat4`; mbgl builds real drawables. `custom_geometry` shaders exist for **gl, mtl, vulkan and webgpu** (`include/mbgl/shaders/{gl,mtl,vulkan,webgpu}/custom_geometry.hpp`), and `custom_drawable_layer_factory.cpp` is compiled and registered **unconditionally**. | **All five native tiers + WASM.** | One implementation everywhere — but shader-locked (see below). |
| **`PluginLayer`** (`src/mbgl/plugin/`) | Runtime-registered style-JSON layer type; render callback gets the full internal `PaintParameters&`. This is what the one real glTF-on-Native project uses. | **iOS/Darwin + Metal only.** Android tracked by open issue #3593 ("Vulkan does not have a Kotlin API"), zero activity since 2025-06-30. Upstream PR #4382 lists *"Figure out the status of PluginLayer"* as a TODO while laying different C++ plugin foundations. | Unusable for a cross-platform Flutter binding, and possibly about to be deprecated. |

### What `CustomDrawableLayer` actually gives you — read this before getting excited

`Interface::addGeometry(vertices, indices, is3D)` takes `GeometryVertex { float position[3]; float texcoords[2]; }` and `GeometryOptions { mat4 matrix; Color color; gfx::Texture2DPtr texture; }`. The shader is, verbatim, `gl_Position = u_matrix * vec4(a_pos, 1.0)` and `fragColor = texture(u_image, frag_uv) * u_color`.

That means: **no normals, no lighting, no PBR, no multi-material, no skinning, one texture, one flat tint.** You cannot supply your own shader — `createBuilder`/`*ShaderDefault()` are `private` in the `Interface`. Rigid-body animation is free (rewrite the `mat4` per frame from a tweaker callback); **skeletal animation is not expressible.** It is a textured-triangle-soup API.

### Other gaps, stated bluntly

- **No lighting for models.** The style spec's root `light` affects fill-extrusion only. Your model will never match the basemap's shading unless you mirror `light.position`/`intensity` yourself.
- **No shadow system at all.** MapLibre has no equivalent to Mapbox v3's `lights`. The official gl-js "shadow" example fakes it with a transparent three.js `ShadowMaterial` plane; those shadows do not fall on terrain or buildings.
- **No repaint-on-demand hook.** There is no callback by which a layer says "render me again." `Map::triggerRepaint()` (`include/mbgl/map/map.hpp:56`) is the only driver — and it is **not in our C ABI** (I checked all 23 `mbl_*` exports in `packages/maplibre_flutter_core/src/maplibre_flutter_core.h`).
- **Custom layers die on `setStyle`.** They cannot be created from style JSON (`createLayer` does `assert(false)`) and are wiped by a style reload.
- **Depth occlusion against buildings was broken until 2026-07-09** (upstream #4301 → PR #4364, Darwin-only, **postdates our pin**).

### gl-js (web) is a separate world

gl-js has `{type: 'custom', renderingMode: '3d'}`, which is a genuine shared-depth-buffer hook — `renderingMode:'3d'` gets `DepthMode(LEQUAL, ReadWrite, depthRangeFor3D)`, the same range fill-extrusion uses. That is the ecosystem the three.js/deck.gl examples ride on. But: **none of MapLibre's five official three.js examples animate anything** (no `AnimationMixer`, no `THREE.Clock` in the sources), threebox is dead (npm 2022-06-03, zero "maplibre" references), and `map.triggerRepaint()` in `render()` repaints the *entire basemap* every frame — an idle MapLibre map renders zero frames, so one animated model flips the whole map to a continuous 60 fps render.

---

## 2. Options for this repo, ranked

### Rank 1 — (a-i) `CustomDrawableLayer` in the C shim

**How.** A `MblModelLayerHost : mbgl::style::CustomDrawableLayerHost` in a new `packages/maplibre_flutter_core/src/maplibre_flutter_core_model.cpp`. Its `update(Interface&)` uploads a triangle mesh once via `addGeometry(vertices, indices, /*is3D=*/true)`; its `setGeometryTweakerCallback` recomputes the model matrix **every frame** from `PaintParameters`. The upstream template is `platform/glfw/example_custom_drawable_style_layer.cpp:479-512` (a 3D OBJ sphere) and `:453-478` (a `frameCount++`-driven rotation) — literally an animated mesh through this API.

The matrix recipe, verbatim from that example (`:490-502`):

```cpp
const mbgl::Point<double> center =
    mbgl::Projection::project(latLng.wrapped(), params.state.getScale());  // projection.hpp:79
const float scale = itemScale * std::pow(2.f, params.state.getZoom()) * params.pixelsToGLUnits[0];
mbgl::mat4 m = mbgl::matrix::identity4();
mbgl::matrix::translate(m, m, center.x, center.y, 0.0);
mbgl::matrix::rotate_z(m, m, frameCount * 0.05f);          // <-- the animation
mbgl::matrix::scale(m, m, scale, scale, scale);
mbgl::matrix::multiply(currentOptions.matrix, params.transformParams.nearClippedProjMatrix, m);
```

**Tiers covered.** macOS, iOS-core, Android-core, Linux, Windows, web-WASM — all six. The `custom_geometry` shader exists per backend and the factory is registered unconditionally.

**What to build, concretely:**

1. `src/maplibre_flutter_core_model.cpp/.h` — the host + a minimal OBJ/glTF-mesh loader (`vendor/tinyobjloader.cmake` already exists in the submodule; or write a 60-line OBJ parser and skip the dep).
2. New C ABI in `src/maplibre_flutter_core.h`, house style (`FFI_PLUGIN_EXPORT`, `mbl_` prefix, opaque handle, int returns):
   - `typedef struct MblModel MblModel;`
   - `MblModel *mbl_map_add_model(MblMap*, const char *layer_id, const float *vertices, uint32_t vertex_count, const uint16_t *indices, uint32_t index_count, const char *before_layer_id);`
   - `void mbl_model_set_transform(MblModel*, double lat, double lng, double altitude_m, double scale, double rotation_deg);`
   - `void mbl_model_set_animation(MblModel*, double degrees_per_second);`
   - `void mbl_model_destroy(MblModel*);`
   - **`void mbl_map_trigger_repaint(MblMap*);`** — wraps `Map::triggerRepaint()`. *Does not exist today; mandatory (see failure modes).*
3. Every one of those posts through `m->post([...]{ ... m->renderRequested = true; })` (`src/maplibre_flutter_core.cpp:203`) — mbgl is render-thread-confined (`:87-89`). Same choke point `mbl_map_set_style` uses (`:815`).
4. `dart run tool/ffigen.dart` on macOS, commit the regenerated `lib/src/maplibre_flutter_core_bindings_generated.dart`, confirm byte-identical (CI §7 layer 6). **Do not hand-write bindings** — that has already cost two macOS cleanup passes.
5. No CMake include change needed: `src/CMakeLists.txt:648` already puts `${MLN_ROOT}/src` on the shim's path (added for the projector), which `custom_drawable_layer.hpp` requires — it includes `mbgl/map/transform_state.hpp`, `mbgl/renderer/update_parameters.hpp` and `mbgl/renderer/render_tree.hpp`, all private.
6. **No plugin, Swift, texture or present-path change on any tier.** Every present already reads mbgl's own framebuffer (`getMetalTexture()` `:307`, GL FBO blit `:369`, Vulkan `getAcquiredImage()` `_vk.cpp:380`, CPU `readStillImage` `:681`). A layer inside mbgl appears for free.

**Effort.** 3–5 person-days to an animated rigid mesh on macOS + a headless PNG assertion. +2–3 days per additional tier for build/verify. +5–8 days for a real glTF ingest (parse `.glb`, flatten node hierarchy, bake into position+uv triangles, PNG base-colour texture).

**Cannot do.** No lighting/PBR/normals. No skeletal or morph animation. One texture, one tint. Occlusion against fill-extrusion is **unverified — needs an experiment** (see §5).

**Failure modes.**
- **Idle freeze.** Continuous mode is *update-driven*, not vsync-driven: `HeadlessFrontend::update()` only invalidates when `invalidateOnUpdate` is set (our Continuous frontend, `maplibre_flutter_core.cpp:712`), and mbgl self-sustains only while `needsRepaint || transform.inTransition()`. A spinning model renders **once** and stops. Static mode uses `MapObserver::nullObserver()` (`:502`) and will not animate at all.
- **Style toggle wipes it.** `mbl_map_set_style` calls `getStyle().loadURL` (`:815`); the shim overrides only `onDidFinishRenderingFrame` (`:694`). Needs an `onDidFinishLoadingStyle` override + a retained model list.
- **Tweaker runs on the render thread** every frame, inside layer-group render. Anything it reads from Dart needs the same discipline as the existing `projMutex` snapshot.
- **Android**: JPEG/WebP decode is stubbed (`maplibre_flutter_core_android_image_stubs.cpp`) — model textures must be PNG or raw.

---

### Rank 2 — (b) Flutter-widget overlay on the existing projector

**How.** Reuse the 2026-06-29 marker machinery unchanged: `MapLibreMapProjector` (`packages/maplibre_flutter_platform_interface/lib/src/projector.dart:24`, `int project(List<LatLng> points, List<Offset> out, {List<bool>? visible})` at `:34`) + `MapLibreCameraTickNotifier` (`:50`) + the `Flow`-based `packages/maplibre_flutter/lib/src/marker_overlay.dart`, stacked over the map at `packages/maplibre_flutter/lib/src/maplibre_map.dart:195-201`. Put a 3D-rendering widget (or a pre-rendered sprite sheet / Rive / Lottie) in the marker's `child` and let the projector glue it to a LatLng.

**Tiers.** macOS today (only `maplibre_flutter_macos_controller.dart:28-33` implements the projector). ~10 lines per other core controller — the C ABI (`mbl_map_pixels_for_lat_lngs`, header `:111`) is already platform-neutral.

**Effort.** 1–2 person-days for a billboarded sprite/Rive "3D-ish" model. The 3D part is not solved by this option — it delegates to option (c) for actual mesh rendering.

**Cannot do — and this is disqualifying for real 3D:**
- **No depth occlusion, ever.** The overlay is a `Stack` sibling painted above the map texture. A model will float over buildings, terrain and other models with no z-sort.
- **No pitch fidelity.** The projector returns `Offset` only; `marker_overlay.dart:161-168` applies a pure `Matrix4.translationValues`. No scale-with-zoom, no rotation, no perspective. You would need to surface `TransformState::getProjMatrix` and `Projection::getMetersPerPixelAtLatitude` (`include/mbgl/util/projection.hpp:47`) across the C ABI — neither is exposed.
- **No altitude.** `LatLng` is 2D; `latLngToScreenCoordinate` takes no elevation.
- **Two frame clocks** → visible swim during fast pan/zoom (already flagged as a known follow-up).

**Verdict:** the right answer for *labels, badges, pins, and 2.5D billboards*. The wrong answer for "a 3D model on the map."

---

### Rank 3 — (a-ii) Raw `CustomLayer` + a per-backend glTF renderer

**How.** `mbgl::style::CustomLayer(id, std::make_unique<Host>())` where the host issues native draw calls inside mbgl's render pass. On Metal you get a live `MTLRenderCommandEncoder` via `style::mtl::CustomLayerRenderParameters` (`include/mbgl/style/layers/mtl/custom_layer_render_parameters.hpp`), and `vendor/metal-cpp` is already on the shim's include path (`src/CMakeLists.txt:655`). On GL you write GL ES3 against a globally-bound context; mbgl re-binds the default renderable and calls `setDirtyState()` after you return (`src/mbgl/gfx/drawable_custom_layer_host_tweaker.cpp:37-42`), so mbgl's `State<>` cache survives.

**This is the only route to PBR, normals, lighting and skinning.** It is also the only one that gets you into mbgl's true depth pass.

**Two hard blockers:**

1. **Windows is dead.** Vulkan has no `CustomLayerRenderParameters` subclass on our pin — the host gets camera scalars and nothing to record into. Upstream fixed this in **PR #4348, merged 2026-06-26, two weeks after our pin**, and it is a **source-breaking change** (`initialize()` → `initialize(const CustomLayerInitParameters&)`, host moved to a new `custom_layer_host.hpp`). Options: bump the submodule (re-validating the Windows Vulkan and macOS/iOS Metal arms), or backport as a third `patches/*.patch`. Do not re-add GL on Windows — Vulkan is there specifically because `gl::DrawableGL::draw` faults under ANGLE/D3D11 (`0xC0000005` on fly-to).
2. **The factory is not registered on Metal or Vulkan.** *(I verified this myself; the research contradicted itself here.)* `platform/default/src/mbgl/layermanager/layer_manager.cpp:81-85` wraps `addLayerType(std::make_unique<CustomLayerFactory>())` in `#ifdef MLN_RENDER_BACKEND_OPENGL`, while `CustomDrawableLayerFactory` (`:89-91`) is unconditional. Our shim links exactly that file on all four native arms. So on macOS/iOS/Windows, `Style::addLayer(CustomLayer)` reaches `getFactory()` → `assert(false); return nullptr` → `assert(factory)` in `createRenderLayer` (`src/mbgl/layermanager/layer_manager.cpp:53-57`) = **abort in debug, null deref in release.** Fixable without a patch — `custom_layer_factory.cpp` is compiled unconditionally (`CMakeLists.txt:835`) — with one startup call:
   ```cpp
   mbgl::LayerManager::get()->addLayerTypeCoreOnly(std::make_unique<mbgl::CustomLayerFactory>());
   // include/mbgl/layermanager/layer_manager.hpp:77 (public virtual)
   ```

**Effort.** 20–40+ person-days: a glTF loader, then three renderers (Metal via metal-cpp, GL ES3, Vulkan pipelines/descriptor sets), plus per-backend shader authoring, plus the submodule bump/patch.

**Cannot do.** Nothing technically — this is the ceiling. But it is a 3-renderer maintenance burden on a project whose pitch is stability.

---

### Rank 4 — (c) Separate 3D engine texture composited over the map

**flutter_scene** (bdero, 0.20.0, 2026-07-27) is architecturally the best fit: `Camera` is a **plain abstract class** (`getViewTransform(Size) => projection.getProjectionMatrix(aspect) * getViewMatrix()`), so you can inject an arbitrary map VP; and `Scene.render(camera, ui.Canvas)` draws into the ordinary Flutter canvas from a `CustomPainter`, clearing to transparent — meaning it composites in the **same Flutter frame** as the widget tree, killing the temporal-swim problem the Texture-over-Texture options have. It does runtime `.glb`, skinned + blended animation, PBR.

**Two blockers, both hard:**
- **Master channel only.** flutter_gpu is an explicit early preview: master-only, Impeller-required, "does not guarantee API stability."
- **Dependency conflict, already latent here.** `flutter_scene` → `data_assets ^0.20.0` → `hooks ^2.0.0`. `packages/maplibre_flutter_core/pubspec.yaml` pins `hooks ^1.0.0` / `code_assets ^1.0.0`, and a pub workspace shares **one** resolution. Same failure family as the documented melos/`cli_util` and `objective_c <9.4.1` pins.

**Thermion** (Filament 1.56.4, 0.4.1, repo pushed today) works on **stable**, has full `setProjectionMatrixWithCulling(Matrix4, near, far)` / `setModelMatrix(Matrix4)` control, and skinning + morph animation — but **no Linux support** (a hole in our verified desktop tier), 55/160 pub points, 19 likes, 947 downloads/30d, retracted 0.4.0 patches, single maintainer.

**three_js** (Knightro63, 0.3.0) works on stable via `flutter_angle` on all six platforms and exposes `Camera.projectionMatrix` / `matrixWorldInverse` as public mutable `Matrix4` fields — the exact custom-layer recipe. Lower fidelity/perf (a JS engine hand-ported to Dart).

**Effort.** 5–10 person-days to a macOS prototype (mostly matrix calibration).

**Cannot do.** **No depth occlusion** — each engine has its own depth buffer; the result composites as flat RGBA. No interaction with fill-extrusion, terrain, or map layer ordering. Texture-over-Texture variants (Thermion, three_js) also get **temporal swim** during pan/pinch/fly-to from two independent present cadences.

---

### Rank 5 — (d) Web-only, gl-js + three.js/deck.gl

**How.** `map.addLayer({id, type:'custom', renderingMode:'3d', onAdd(map, gl), render(gl, args)})` in `packages/maplibre_flutter_web_gljs/`, with three.js sharing the map's GL context (`new THREE.WebGLRenderer({canvas: map.getCanvas(), context: gl})`, `autoClear = false`, `resetState()` per frame). Position via `MercatorCoordinate.fromLngLat([lng,lat], altitudeMeters)` + `meterInMercatorCoordinateUnits()`, model matrix scaled `(scale, -scale, scale)` (mercator Y is down), then `camera.projectionMatrix = mainMatrix * modelMatrix`. Animate with your own `THREE.Clock` + `mixer.update(dt)` + `map.triggerRepaint()`.

**Effort.** 2–3 person-days.

**What it proves:** that our web *opt-in* package can host a real animated glTF with correct shared-depth 3D and full three.js PBR/skinning. Genuinely a good demo.

**What it does NOT prove:** anything about the five native tiers or the WASM-core web default. `maplibre_flutter_web_gljs` is opt-in since the 2026-06-21 inversion; the **default** web renderer is our WASM core, which has no gl-js custom-layer API. Zero code transfers.

**Caveats specific to us.** We pin `5.24.0` (`packages/maplibre_flutter_web_gljs/lib/src/maplibre_gl_loader.dart:10`), so the v5 render signature applies: `(gl: WebGLRenderingContext | WebGL2RenderingContext, options: CustomRenderMethodInput) => void` — **the union, not WebGL2-only**. deck.gl interleaved works on 5.x and is broken on v6. Do **not** bump to v6 casually: it is ESM-only (the UMD `dist/maplibre-gl.js` our loader injects as a classic `<script>` no longer exists) and it removed `map.transform`.

---

## 3. Recommended test this week

**Goal:** an animated 3D mesh, drawn by mbgl, glued to a LatLng, spinning on the macOS map — via `CustomDrawableLayer`. macOS because it is the dev machine, the historical reference tier, the only backend where *both* mechanisms work, and it has a headless PNG assertion loop.

**Punt deliberately:** glTF parsing (use a procedural cone/pyramid — asymmetric so orientation bugs are visible), textures, lighting, skeletal animation, all other tiers, and the public Dart API.

### Steps

1. **`packages/maplibre_flutter_core/src/maplibre_flutter_core_model.cpp` (new).**
   A `MblModelHost : mbgl::style::CustomDrawableLayerHost`. `update(Interface&)`: if `interface.getDrawableCount() == 0`, build a hardcoded ~20-triangle cone into `VertexVector<Interface::GeometryVertex>` / `IndexVector<gfx::Triangles>`, call `setGeometryOptions`, `setGeometryTweakerCallback(...)`, then `addGeometry(v, i, /*is3D=*/true)`. Tweaker body = the glfw recipe above with a mutable `frameCount++` driving `rotate_z`. Copy `platform/glfw/example_custom_drawable_style_layer.cpp:479-512` and its `project()` helper at `:37-41`.

2. **Add to `packages/maplibre_flutter_core/src/CMakeLists.txt`** in the shim's source list (no new include dirs — `:648` already provides `${MLN_ROOT}/src`).

3. **Two C entry points in `src/maplibre_flutter_core.h` + `.cpp`**, both `m->post(...)`-marshaled, following the `mbl_map_set_style` shape at `:815`:
   - `FFI_PLUGIN_EXPORT int mbl_map_add_test_model(MblMap *map, double lat, double lng);`
   - `FFI_PLUGIN_EXPORT void mbl_map_trigger_repaint(MblMap *map);` → `m->post([m]{ m->map->triggerRepaint(); m->renderRequested = true; });`

4. **Headless first — this is the cheap iteration loop.** Extend `packages/maplibre_flutter_core/src/render_harness.cpp` (`-DMAPLIBRE_FLUTTER_BUILD_HARNESS=ON`) to: create a map → set style → `mbl_map_add_test_model(37.76, -122.47)` → loop `{ mbl_map_trigger_repaint(); mbl_map_await_frame(); mbl_map_write_png("frame_N.png"); }` ×20. **Assert real content**, not "a frame came back" — diff frame 0 vs frame 10 and require the pixels around the model's projected position to change. This is the §7 rule the Windows blank-map bug produced.

5. **Then the GUI.** `dart run tool/ffigen.dart`, commit the regenerated bindings, add a temporary button in `packages/maplibre_flutter/example/lib/main.dart` calling through `packages/maplibre_flutter_core/lib/maplibre_flutter_core.dart` → `flutter run -d macos`. Drive the repaint with a Dart `Ticker` calling `mbl_map_trigger_repaint` while animating.

6. **The occlusion probe (the real experiment).** Place the model at the base of a tall OpenFreeMap Liberty building, pitch to ~60°, orbit the bearing 360°. Screenshot / PNG-assert whether the building correctly hides the model when it passes behind it.

### What this validates

- Whether `CustomDrawableLayer` renders at all under **Metal + CORE_ONLY + our headless frontend** (upstream only *tests* custom layers on GL; `test/api/custom_layer.test.cpp` is entirely inside `#if MLN_RENDER_BACKEND_OPENGL`).
- Whether `triggerRepaint` gives a usable animation clock through our Continuous frontend — the single biggest unknown.
- Whether the tweaker's `nearClippedProjMatrix` composition is geographically correct under bearing/pitch (the asymmetric cone catches handedness/Y-flip errors immediately).
- Whether zero-copy present survives a custom drawable (it should — the drawable path never touches the framebuffer binding, unlike a raw `CustomLayer`).
- **Whether 3D depth occlusion works**, which decides the entire production path.

---

## 4. Production path if the test succeeds

**Order matters — do not parallelize.**

1. **macOS → real geometry.** Replace the procedural cone with a `.glb` ingest: parse, flatten the node hierarchy, bake to position+uv triangles, upload the base-colour texture as `gfx::Texture2DPtr`. Decide here whether to vendor `vendor/tinyobjloader.cmake` (already in the submodule) or take a header-only glTF parser.

2. **macOS → correctness plumbing.** (a) `onDidFinishLoadingStyle` override on the Continuous `FrameObserver` (`maplibre_flutter_core.cpp:691`) + a retained model registry, so models survive a `MapLibreMap.style` change; (b) a repaint policy — only pump `triggerRepaint` while an animation is playing and the model is on-screen (`mbl_map_pixel_for_lat_lng`'s `visible` flag is free for this), never unconditionally.

3. **Public API, three-bucket rule.** Models are mutable + declarative → a widget prop: `MapLibreMap(models: List<MapLibreModel>)` in `packages/maplibre_flutter/lib/src/`, mirroring `markers`, pushed via `didUpdateWidget`. No `controller.setModels`. New optional platform-interface capability `MapLibreModelHost`, feature-detected with `is` exactly like `MapLibreMapProjector` — controllers without it silently render nothing.

4. **Linux (GL) second.** Cheapest verification: the existing headless Docker path (`packages/maplibre_flutter_core/docker/`) runs the GL arm under Mesa llvmpipe **on the Mac**, so the GL shader path is provable before touching hardware. Then a real-hardware run.

5. **Windows (Vulkan) third.** This is the risk tier — a completely different drawable path with a documented crash history. HW-verify, do not extrapolate from macOS. Per the 2026-06-21 lesson: if a matrix/winding convention is verified on one tier, **copy it verbatim** — do not "adapt" it.

6. **iOS-core and Android-core.** iOS is a near-free ride on the Apple arm. Android needs a **physical device** (emulator GL is untrustworthy for anything GPU-side) and PNG-only textures.

7. **Web last, both packages.** WASM-core: the same `CustomDrawableLayer` host compiles (the `webgpu`/`gl` custom_geometry shaders exist), plus an embind method — but remember the `glFlush()`-after-blit rule and the pre-allocated `PTHREAD_POOL_SIZE`. gl-js: the separate three.js custom-layer path from option (d), if we want it at all.

8. **Only then** consider the raw `CustomLayer` route for lighting/PBR/skinning — which means bumping the submodule past PR #4348 (Vulkan custom-layer params) and #4364, re-validating the Windows Vulkan and Apple Metal arms, and adding the `addLayerTypeCoreOnly` registration call.

---

## 5. Open questions and risks

### Corrected by the verification pass — do not act on the original claims

- **"Clean-room licensing is the blocker for a model layer."** Wrong scope (that quote is from *maplibre-gl-js* #3794, not Native), wrong causation (the maintainer labelled it "PR is more than welcomed" 19 seconds later — the blocker was contributor bandwidth), and two years stale (both issues closed as *completed*, resolved via plugin layers). Do not plan around a licensing thaw.
- **"No open RFC/design proposal for a model layer."** The narrow kernel holds (no `model` type in the spec, no RFC), but the search method could not support the negative and the enumeration was wrong. maplibre-native **#2806 "Rendering 3D Models" is open**, and style-spec **#1048** ("Dynamic 3D object and attribute support") and **#1565** are open 3D proposals a keyword search for "model" misses.
- **gl-js v6 `overrideNearFarZ`.** `map.transform` is gone, but `map._camera.transform` still exposes it and type-checks; the `IReadonlyTransform` barrier on `map.painter.transform` is compile-time only (same object reference, `src/ui/map.ts:4067`). The **actual** v6 blocker is `transform.getMatrixForModel` being **deleted outright** with no rename. Moot for us today — we pin 5.24.0.
- **gl-js custom-layer signature.** The quoted `(gl: WebGL2RenderingContext, options)` is the **v6** signature. On our pinned 5.24.0 it is `(gl: WebGLRenderingContext | WebGL2RenderingContext, options)` — writing to the WebGL2-only form is a hard `tsc` error against v5.

### Corrected by my own check of the source (the research contradicted itself)

- **`CustomLayerFactory` is NOT registered by the default layer manager on Metal or Vulkan.** One research area asserted "no `#ifdef` — no layer-manager change needed." `platform/default/src/mbgl/layermanager/layer_manager.cpp:81-85` shows the opposite: it is gated on `#ifdef MLN_RENDER_BACKEND_OPENGL`. `CustomDrawableLayerFactory` (`:89-91`) is unconditional. This is why option (a-i) is safe and (a-ii) needs `addLayerTypeCoreOnly` — and it would have been a debug abort / release null-deref on the first macOS run.

### Genuinely unknown — needs an experiment, not more reading

1. **Does a `CustomDrawableLayer` occlude correctly behind fill-extrusion buildings?** `addGeometry(..., is3D=true)` sets `setEnableDepth(true)` + `DepthMaskType::ReadWrite` + `setIs3D(true)` (`src/mbgl/style/layers/custom_drawable_layer.cpp:741-746`), **but** the layer's `LayerTypeInfo.pass3d` is `NotRequired`, so it renders in the **Translucent** pass, not the dedicated 3D pass that fill-extrusion uses. Upstream #4301 says custom 3D layers *did not* occlude correctly until PR #4364 (2026-07-09, Darwin-only, postdates our pin). **Experiment: step 6 of §3.** If occlusion fails, options (a-i), (b) and (c) all land in the same bucket — "model floats over buildings" — and the ranking changes materially.
2. **Does `triggerRepaint()` actually produce a steady animation clock through our Continuous `HeadlessFrontend`?** The invalidation chain (`triggerRepaint → impl->onUpdate() → update() → asyncInvalidate → renderFrame`) should work, but the shim has never driven repaints externally. **Experiment: step 4 headless loop** — count published frames over 5 s with no camera motion.
3. **What does per-frame `triggerRepaint` cost on the CPU-present tiers?** Windows Vulkan and Android core do a GPU→CPU readback per frame; forcing 60 fps for an animated model may be unacceptable. **Experiment: instrument `mbl_map_copy_frame` timing on Windows/Android with animation on vs. off.**
4. **Does `CustomDrawableLayer` render at all on Vulkan under CORE_ONLY?** The shaders exist and the factory is registered, but nobody in this repo has exercised a custom drawable on Vulkan, and the Windows arm has a history of backend-specific faults. **Experiment: the harness PNG check on Windows — never a GDI screenshot, which returns white for Flutter's external texture regardless.**
5. **Can the built-in `custom_geometry` shader produce an acceptable-looking model with no normals?** Flat-shaded, single-tint, one-texture geometry may simply look bad enough to invalidate option (a-i) for real use. **Experiment: render a real building/vehicle `.glb` through it and look at it** — a judgement call that cannot be made from the shader source.

### Standing risks

- **Submodule pin.** `fa8a9c8e3261` predates PR #4348 (Vulkan custom-layer params, **source-breaking**) and #4364. Any bump re-validates the Windows Vulkan and Apple Metal arms and must re-apply `patches/windows-dns-os-resolve.patch` and `patches/windows-vulkan-external-memory.patch` via `hook/build.dart`'s `_applySubmodulePatches`.
- **We are coding against mbgl internals.** `custom_drawable_layer.hpp` pulls three headers from `src/` (upstream tracks this as #2039). `PaintParameters`, `TransformState` and `transformParams.nearClippedProjMatrix` are all private API on a hard pin.
- **Convergence watch:** `maplibre/maplibre-native-ffi` (official experimental C API, pushed 2026-07-29) is very close in intent to our hand-rolled shim. Worth a look before investing further C++ effort here.
- **Do not use `maplibre.org/maplibre-native/docs/book/` for any of this** — it has no custom-layer, plugin-layer or 3D-model page and still describes OpenGL as the only backend. The headers, `platform/ios/MapLibre.docc/PluginLayers.md`, the roadmap pages and the issue tracker are the only authoritative sources.
---

# Spike results (2026-07-29, macOS/Metal, branch `feat/3d-model-spike`)

Built and **actually run** on macOS (Metal + CORE_ONLY + our headless frontend).
Everything below is measured, not reasoned. Harnesses:
`src/model_harness.cpp` (pixel assertions) and `src/proj_probe.cpp`
(projection sign checks), both behind `-DMAPLIBRE_FLUTTER_BUILD_HARNESS=ON`.

## What works

| Question | Answer |
|---|---|
| Does `CustomDrawableLayer` render under Metal + CORE_ONLY + `HeadlessFrontend`? | **Yes.** Upstream only *tests* custom layers under `MLN_RENDER_BACKEND_OPENGL`, so this was genuinely unknown. |
| Is it correctly geo-anchored? | **Yes** — projected anchor (281.2, 450.4) vs drawn model centroid (280.7, 449.9). |
| Does `triggerRepaint` drive animation through Continuous mode? | **Yes** — ~21k px change per spin step. This was the biggest unknown going in. |
| Is it real 3D with correct axes? | **Yes** — top-down with the base removed gives the exact expected pinwheel: red=north top, green=east right, blue=south bottom, yellow=west left. |

## Depth occlusion: was broken, now FIXED (Metal-only mbgl bug)

Initially the model had **no depth occlusion at all** — not against fill-extrusion
buildings, and not even against itself (the pyramid's base, drawn last and farther
away, painted over all four side faces).

**Root cause — and it is Metal-specific, not a design limit.** `mtl::Drawable`
deliberately skips setting its own depth/stencil state when `is3D`, with the comment
*"For 3D mode, stenciling is handled by the layer group"* (`mtl/drawable.cpp:244`).
But `mtl::TileLayerGroup` only computed `features3d` **inside**
`if (stencilTiles && !stencilTiles->empty())` (`mtl/tile_layer_group.cpp:59`). A layer
group with no stencil tiles — which is *every* `CustomDrawableLayer` — therefore left
`features3d` false and set **no depth state at all**, so 3D geometry silently fell back
to painter's order.

The GL (`drawable_gl.cpp:46`) and Vulkan (`drawable.cpp:274`) drawables set
`depthModeFor3D()` themselves, so **Linux, Android and Windows never had this bug.**

**Fix:** `patches/metal-custom-drawable-3d-depth.patch` (marker `MBL_CUSTOM_3D_DEPTH`,
applied idempotently by `hook/build.dart` alongside the two existing Windows patches).
It hoists the 3D scan out of the stencil-tiles guard; `stencil3d` stays gated on stencil
tiles, so tiled layers are unaffected.

**Verified after the fix:**

| Check | Before | After |
|---|---|---|
| 18 m model at the centre of the Empire State Building footprint | 844 px (drawn straight through the tower) | **0 px — fully hidden** |
| Same camera, no buildings (control) | 844 px | 844 px |
| Model partially behind a building edge | 3220 px | 3078 px (correctly clipped) |
| Self-occlusion: base vs side faces, top-down | base covered everything | correct four-face pinwheel |

### Correction to the earlier research

An earlier draft of this document claimed upstream PR **#4364** fixed custom-layer
occlusion and that our pin merely predated it. **That is wrong.** #4364
(`14d3c7529d29`) only adds a `nearClippedProjectionMatrix` field to
`CustomLayerRenderParameters` and exposes it on the ObjC `MLNCustomStyleLayer`; it
touches no depth or `pass3d` code. Upstream `main` as of `c8dad00be558` still has
`pass3d = NotRequired` and the same stencil-gated `features3d` scan — i.e. **the bug is
still present upstream and a submodule bump would not have fixed it.** Worth filing.

Note also that `pass3d = NotRequired` turned out to be a red herring: full depth testing
works through `depthModeFor3D()` without touching `pass3d` at all.

## Two bugs found on the way

**1. The projector had an inverted Y axis (fixed here).** `mbl_map_pixel_for_lat_lng`
returned north *below* centre and south *above* it. Root cause:
`TransformState::latLngToScreenCoordinate` returns a **bottom-left-origin** y
(`transform_state.cpp:775` does `size.height - y`), but mbgl's **gesture anchors are
top-left origin** — confirmed independently here by zooming about (0,0) and watching
the camera move north-west. The shim passed `sc.y` through while its header claimed
both spaces matched. Every widget marker would have been mirrored vertically about the
map centre. Fixed in all three projection entry points; `proj_probe` guards it.

This is the same class of error as the 2026-06-21 Windows anchor-flip incident, and it
survived because the marker/projector work (commit `532d3c3`) was written but **never
run** — its own decision-log entry says so.

**2. mbgl's model matrix uses different units per axis.** X/Y are **world pixels**, Z is
**metres** — `camera.cpp:104`: *"Height value (z) of renderables is in meters. Scale z
coordinate by pixelsPerMeter."* Upstream's example scales all three axes uniformly
(it only draws flat geometry, so it never notices). Doing the same squashes a model's
height by a factor of `metresPerPixel` — it renders as a flat decal. Also, upstream's
`itemScale * 2^zoom * pixelsToGLUnits[0]` is not physically meaningful; at z15 it drew
the mesh ~300x too large. Correct form: XY `metres / metresPerPixel`, Z `metres`.

## Verdict

**Viable.** Animated, geo-anchored, depth-occluding 3D models render inside mbgl on our
pinned core, on every backend we ship, with one four-line Metal patch that follows the
repo's existing patch convention. No submodule bump needed.

Remaining before this is a feature rather than a spike:
1. Real mesh ingest (`.glb`/`.obj` -> position+uv triangles + one PNG texture).
2. Verify on the other tiers — GL and Vulkan should need no patch, but that is reasoned,
   not measured; per the 2026-06-21 lesson, HW-verify rather than extrapolate.
3. Style-reload survival (`onDidFinishLoadingStyle` + a retained model registry).
4. A repaint policy: only pump `triggerRepaint` while an animation is on-screen.
5. Public API: `MapLibreMap(models: ...)` as a declarative widget prop, mirroring
   `markers` (three-bucket rule).
6. The unlit-shader ceiling still stands: no normals/lighting/PBR, one texture, and no
   skeletal animation. Bake lighting into the texture.

---

# .glb ingest (2026-07-30, macOS/Metal)

Real glTF models now load and render. `mbl_map_add_model(map, layer_id, glb_path,
lat, lng, scale, heading_deg, spin_dps, out_error, error_capacity)` →
`MapLibreCoreMap.addModel(...)` in Dart.

## No new dependency

The reader (`src/maplibre_flutter_core_gltf.{hpp,cpp}`) is hand-written against
mbgl's **already-vendored rapidjson** (linked PUBLIC into mbgl-core, so its headers
reach the shim) and mbgl's own `decodeImage`. So no cgltf/tinygltf vendoring, no
FetchContent, and no build-time network access on any of the six platform arms.
Scoping it to exactly what mbgl's `CustomGeometryShader` can draw is what makes a
hand-written reader reasonable rather than reckless.

## Supported subset

Triangles, POSITION + TEXCOORD_0, node transforms baked in (explicit `matrix` or
TRS), all primitives of all meshes merged into one buffer, first base-colour
texture + `baseColorFactor` as the tint, sampler wrap/filter honoured. Accessors
may be float or normalized u8/u16; indices u8/u16/u32; `byteStride` respected;
accessor/bufferView ranges bounds-checked against the BIN chunk so a truncated or
hostile file cannot walk off the buffer.

Rejected loudly (never silently degraded): text `.gltf`, external buffers/images,
sparse accessors, >65535 vertices, and files with no triangle geometry.

Coordinate conversion: glTF (Y-up, -Z forward, right-handed) → map model space
(X east, Y south, Z up) as `(x, y, z) -> (-x, z, y)`. Determinant +1, so winding
survives, and a model's glTF "forward" faces map north at heading 0.

## Verified

| Asset | Result |
|---|---|
| Khronos `Duck.glb` | 2399 verts / 4212 tris, 512x512 texture. Renders textured, upright, standing on the ground; spins; anchored |
| Khronos `BoxTextured.glb` | 24 verts / 12 tris, node rotation baked in, texture correct after the sampler fix |
| `AnimatedCube.gltf` (text) | correctly rejected: "not a binary glTF (.glb)" |
| Synthesized 70002-vertex GLB | correctly rejected: "model exceeds 65535 vertices (mbgl indices are uint16); decimate the mesh" |

Pyramid pinwheel, projector signs, and the Empire-State-Building occlusion test
(0 px) all still pass, so neither patch regressed the earlier work.

## Second Metal-only mbgl bug found and fixed

`BoxTextured.glb` rendered as a flat grey block. Its UVs legitimately span
**u=[0,6]** — a 6-wide atlas, one unit per cube face, relying on REPEAT wrapping
(glTF's default). It was being clamped, so every face sampled one edge column.

Two layers of cause:
1. **Mine.** The host hardcoded `TextureWrapType::Clamp` with a confident comment
   that "a model's UVs are authored inside [0,1]". Wrong: glTF defaults to REPEAT.
   Now read from the glTF sampler (`wrapS`/`wrapT`/`magFilter`).
2. **mbgl's, and Metal-only.** Fixing (1) changed nothing, because the Metal
   `CustomGeometryShader` declares its sampler INSIDE the shader —
   `constexpr sampler sampler2d(coord::normalized, filter::linear)` — and a Metal
   `constexpr sampler` defaults to `address::clamp_to_edge`, ignoring whatever
   `setSamplerConfiguration` puts on the Texture2D. The GL
   (`shaders/gl/custom_geometry.hpp`) and Vulkan
   (`shaders/vulkan/custom_geometry.hpp`) variants sample through a `sampler2D`
   whose wrap state mbgl does control, so **only Metal was affected** — the same
   pattern as the depth bug.

Fixed by `patches/metal-custom-geometry-sampler-repeat.patch` (marker
`MBL_CUSTOM_GEOMETRY_REPEAT`). Repeat is a safe default: UVs inside [0,1] never
sample outside the texture, so clamp and repeat are indistinguishable for them.
The residual limitation is that a model explicitly wanting CLAMP_TO_EDGE *and*
having UVs outside [0,1] will now tile — rare, and the opposite of the glTF
default.

**Both Metal patches are needed for correct 3D models on Apple platforms**, and
both are Metal-only: GL (Linux/Android) and Vulkan (Windows) handle depth and
sampler wrap correctly already — reasoned from source, not yet measured on those
tiers.

## Lesson

Two independent bugs in this session came from the same mistake — a hardcoded
graphics-state guess with a plausible comment (`Clamp` because "UVs are in
[0,1]"; and earlier, uniform XYZ scale because upstream's example did that). Both
looked right and rendered *something*. Take state from the source data or the
spec, not from intuition about what models "usually" do.
