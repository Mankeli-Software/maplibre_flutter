# Continuing the annotation / style / 3D work on the other platforms

**Snapshot: 2026-07-31**, after the cross-platform parity push (branch
`feat/cross-platform-parity`). Read §1 for what is wired and where it has actually been
RUN — the distinction this document exists for.

Headline changes since the 2026-07-30 snapshot: all five `mbgl-core` tiers now implement
every capability macOS does (`MapLibreModelHost` was the only gap, and it is closed);
rotate and tilt gestures exist for the first time; iOS is verified end-to-end on a
Simulator; and the device-free floor that makes the rest reviewable — a 120-assertion
conformance suite over all five controllers, three asymmetric convention guards in the
core suite, working native harness probes, and per-platform compile gates in CI — now
exists where before there was none.

Read this with `docs/decision-log.md` (it carries the *why* for each piece) and
`FEATURE_MATRIX.md` (the exhaustive per-feature parity backlog, brought up to date on 2026-07-30
with everything below — it is the place to look up a single feature; this file is the place to look
up what to *do next*).

---

## 1. What landed, and where each piece actually runs

| Feature | Where the code lives | Platform-agnostic? | Verified on |
| --- | --- | --- | --- |
| **Widget markers** — Flutter widgets glued to a `LatLng` (`MapLibreMap.markers`) | `maplibre_flutter` (`marker_overlay.dart`) + `MapLibreMapProjector` in the interface | Overlay yes; needs the projector capability per platform | macOS (drag/zoom/pinch/fly/inertia) |
| **Engine layers / sources / images** (`controller.layers`) | C ABI in `maplibre_flutter_core`, `MapLibreStyleLayers` capability | Needs the capability per platform | macOS (incl. in-engine clustering, pixel-asserted native tests) |
| **`queryRenderedFeatures`** | same | same | macOS |
| **Typed style API** (`CircleLayer`, `SymbolLayer`, `GeoJsonSource`, `Expr`, …) | `maplibre_flutter/lib/src/style/` + `tool/generate_style_api.dart` | **Yes — pure Dart.** Serialises to `addLayerJson`, so it works wherever that does | macOS; 26 unit tests are platform-independent |
| **`layers.setTransitionOptions`** | new `mbl_map_set_transition_options` + all 5 core controllers | Needs the C ABI (present) | macOS |
| **3D `.glb` models** (`controller.addModel`, `MapLibreMap(models:)`) | `maplibre_flutter_core` (glTF loader, model host) + `MapLibreModelHost` | Yes on all five native tiers — the model and glTF sources are in `_shim_sources` for every arm | macOS / Metal, and iOS / Metal (Simulator) |
| **Rotate + tilt GESTURES** (twist, shove, drag) | `maplibre_flutter` (`maplibre_map.dart`) + `MapLibreRotateHandler`, over `mbl_map_rotate_by`/`mbl_map_pitch_by` | Yes — one recognizer over the shared capability | 11 device-free widget tests; feel unverified on hardware |
| **Example scenarios + rotate/tilt controls** | `packages/maplibre_flutter/example` | Yes | macOS |

### Capability wiring as it stands

Measured from the source, not assumed:

| Capability | Android | iOS | macOS | Windows | Linux | Web (WASM) | Web (gl-js) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `MapLibreMapProjector` (markers) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| `MapLibreCameraTickNotifier` | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| `MapLibreStyleLayers` (+ typed API, transitions) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Projects against the **presented** frame | ✅ | ✅ | ✅ | ✅ | ✅ | ➖ | ➖ |
| `MapLibreModelHost` (3D) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| `MapLibreRotateHandler` (rotate/tilt) | ✅ | ✅ | ✅ | ✅ | ✅ | ➖¹ | ➖² |

¹ Web-core has `rotateBy`/`pitchBy` in its embind module and a mouse drag-rotate, but it does not
use the Dart gesture layer, so the capability interface does not apply to it. It still has **no
touch handlers of any kind** — no pinch, no twist, no shove.
² gl-js handles its own gestures on the DOM element and already rotates and tilts.

✅ here means **the forward is written** — it does not mean it has been run on that platform.
What has actually been exercised:

- **macOS** — the reference tier, everything.
- **iOS** — verified on an Apple-Silicon Simulator (real host-GPU Metal): non-blank pixels, widget
  markers in the correct absolute directions, an engine circle layer found by `queryRenderedFeatures`
  with the mirrored box asserted to miss, and a `.glb` whose mesh parsed and whose spin keeps
  `renderedFrameCount` climbing. 5/5 in `example/integration_test/ios_core_map_test.dart`.
- **Android, Windows, Linux, Web** — NOT run. Their forwards are covered by the 120-assertion
  conformance suite (`packages/maplibre_flutter/test/core_controller_conformance_test.dart`) and,
  from this change on, by per-platform `flutter build` compile gates in CI. That is the difference
  between "unverified" and "unknown"; it is not the same as working.

---

## 2. Per-platform continuation

### Linux and Windows — capabilities complete, unrun

Both already implement projector, camera tick and style layers, and both forward
`setTransitionOptions`. Nothing is known to be missing; **the work is verification**,
and these two are where a mistake is most likely, because their present paths flip the
pixel buffer while the anchor space stays top-left (see the 2026-06-21 pinch-anchor
regression in `docs/decision-log.md` — the lesson being: do not "fix" an anchor convention on a
platform you have not run).

Verify, in this order:

1. `flutter run -d <linux|windows>` in `packages/maplibre_flutter/example`.
2. **Markers** scenario: pins must sit exactly on their points, including near the
   edges, and stay glued through pan / pinch / fly-to. A vertical mirroring means the
   projection Y flip is wrong for that present path.
3. **Engine clustering**: bubbles + counts, and cluster splitting on zoom.
4. **Typed style API** scenario: this is the cheapest end-to-end check that the
   generated documents are accepted by the engine on that platform.
5. `melos run test:native` on the box (the projection and layer tests carry pixel
   assertions).

Windows-specific: it runs the **Vulkan** backend, so nothing GL-shaped applies; the
zero-copy present falls back to CPU on Intel (documented).

### iOS-core and Android-core — same, plus device realities

Same capability set as above, all unrun. Additional per-platform items:

- Both need a **physical device** run, not just a simulator/emulator. The Android
  emulator specifically **cannot composite a GPU-produced `SurfaceProducer` buffer**
  (documented at length in `docs/decision-log.md`, 2026-06-20) — so zero-copy will read as white
  there and that is not a bug to chase.
- iOS: the marker overlay and gesture layer are the shared Dart tier, so the risk is
  DPR-related, not logic-related. Check label crispness and that pins track under a
  pinch (the pixelRatio class of bug from the iOS-core POC).

### Web — still the real gap

Neither web package implements any of the projector / camera-tick / style-layer
capabilities, so on web today there are still no widget markers, no engine layers, no
typed style API and no transitions. What DID change:

- The example builds for web again (an unconditional `dart:io` import had made it
  impossible, so the app that demonstrates the plugin could not demonstrate its default
  web renderer).
- The WASM shim's mbgl `Size` is now LOGICAL points. It was device pixels, which mbgl
  then multiplied by the pixel ratio a second time — at DPR 2 the framebuffer was 4x the
  canvas and only its bottom-left quadrant was blitted. Every capability stacked on this
  tier inherits its screen space, so this had to land first.
- `rotateBy`/`pitchBy` and a mouse drag-rotate exist in the embind module.
- The artifact is installable: the loader defaulted to an asset path a pure-Dart package
  can never serve.
- A `web-wasm` CI job now COMPILES the Emscripten module. Nothing did before, which is
  why its C++ was verified by nothing at all.

None of the web C++ above has been compiled locally (no emsdk on the authoring machine);
CI is what will check it.

Two different jobs, do not conflate them:

- **`maplibre_flutter_web_gljs`** (opt-in gl-js): the cheapest path. gl-js has
  `map.project` / `unproject`, `addSource` / `addLayer` (it takes the *same* style-spec
  JSON the typed API emits, so `addLayerJson` maps 1:1), `queryRenderedFeatures`, and
  `fadeDuration` for the transition question. Implementing the three capabilities here
  is mostly interop plumbing and would light up markers + the whole typed style API on
  web at once.
- **`maplibre_flutter_web`** (default, WASM core): needs the same C ABI surface exposed
  through embind in `packages/maplibre_flutter_core/src/web/`. Bigger job; see
  `experimental-web-core-wasm.md` for the state of that build.

### 3D models — wired everywhere, verified on Metal

All five native tiers now implement `MapLibreModelHost`. What remains is running it.

**The GL edits were not merely unverified — one was wrong.** `custom-geometry-lighting.patch`
ordered the GL attribute table `{a_pos, a_normal, a_uv}` while the shader declares
`location 1 = a_uv, 2 = a_normal`, and `ShaderProgramGL::create` indexes that table BY
LOCATION. Texcoords fed `a_normal` and normals fed `a_uv` on every GL model draw — Linux,
Android and the future web-WASM arm. Fixed; the patch was regenerated against a pristine
submodule. `model_harness` can now detect that class of defect (it sweeps a full rotation
and requires all four pinwheel faces, which a UV/normal swap collapses), proven in both
directions on Metal.

Still to run: the Mesa/llvmpipe GL loop via `docker/run-render-test.sh` (docker was not
available on the machine that did this work), and a Vulkan/lavapipe arm for Windows,
which has no off-target verification path at all.

- `patches/custom-geometry-lighting.patch` touches all four backends (Metal, GL,
  Vulkan, WebGPU). The Metal edits are verified; the GL edits are corrected but unrun;
  Vulkan reads as correct from source and is unrun; the WebGPU hunks are dead code
  (no arm enables that backend).
- `patches/metal-custom-drawable-3d-depth.patch` is Metal-only by nature: the GL
  (`drawable_gl.cpp`) and Vulkan (`drawable.cpp`) drawables already honour `is3D`, so
  Linux / Windows / Android should not need it.
- `patches/metal-custom-geometry-sampler-repeat.patch` is likewise Metal-only.

Order of attack: Linux (GL) first — the patch edits are smallest there and a desktop
box is easiest to iterate on — then Windows (Vulkan), then Android (GL ES). Each needs
`MapLibreModelHost` forwarded on its controller (the macOS controller is the template;
it is a thin pass-through to `MapLibreCoreMap`) plus a real run of the two 3D example
scenarios.

**Patch-ordering trap, already fixed but worth knowing:** `hook/build.dart` must apply
the lighting patch *before* the sampler-repeat patch, because the lighting patch was
generated from a tree that already had repeat applied and therefore carries that change
with it. In the other order neither patch applies to a pristine submodule and every
fresh source build fails. It was invisible on the machine that authored them, because
that submodule had been patched incrementally in the historical order and the hook's
idempotency markers made that permanent. **If you ever regenerate one of these patches,
regenerate it against a pristine submodule and re-check the order.**

---

## 3. Known-unverified and open items

- **TODO — open the upstream MapLibre PRs for the text-centring fix.** We carry
  `patches/text-centre-anchor-on-ink.patch`: both MapLibre engines centre text on a hardcoded
  baseline constant (`Shaping::yOffset = -17`, and the identical `SHAPING_DEFAULT_OFFSET` in
  maplibre-gl-js) instead of on font metrics, so centre-anchored text is not centred. Verified,
  measured and written up with evidence images in **`docs/upstream-text-centring/`**; the
  decision-log entry is 2026-07-31. Three things are outstanding:
  1. **Issue on `maplibre/maplibre-native`** — none exists today (org-wide search for
     `SHAPING_DEFAULT_OFFSET` returns zero). Cite mapbox/mapbox-gl-js#154 and #191, open since
     2013, as prior art; #154 proposes this exact approach.
  2. **PR on `maplibre/maplibre-native`** — the patch is complete (it moves `shaping.top` too, so
     the collision box follows the ink). Needs render tests. Lead with "yes, this moves labels for
     fonts whose metrics differ from the old assumption" — that is the maintainer's first question.
  3. **PR on `maplibre/maplibre-gl-js`** — the mirror patch exists
     (`carta-polaris/patches/maplibre-gl-js-text-centre-on-ink.patch`) but is **untested**; it needs
     the gl-js render-test suite run before it is proposable.
  Licence hazard: Mapbox's own fix (mapbox-gl-js#8781, 2021) is post-fork and proprietary. It was
  deliberately **not** consulted, and must not be — MapLibre's PR checklist requires confirming no
  Mapbox backports.
- **`"pinch zoom freezes its anchor and does not pan from focal drift"` fails** in
  `maplibre_flutter/test/maplibre_map_test.dart`, and fails on `main` too. Pre-existing,
  unrelated to any of today's work, still needs a look.
- **Cluster count labels outlive their bubbles by ~300 ms.** Diagnosed, not fixed:
  symbol layers fade and circle layers do not, and every lever mbgl offers is
  style-wide. Deliberately not worked around — see the decision log. The per-layer fix,
  if it ever matters, is to draw the bubble as an SDF symbol icon in the same layer as
  the count so the two are one symbol.
- **CI cannot verify the generated style API.** `.github/workflows/ci.yml` is still
  `workflow_dispatch`-only pending the cost review, so the "Generated typed style API is
  up to date" step (and the ffigen one) never actually run. Uncommenting the triggers is
  the single highest-value CI action available.
- **The typed style API's coverage is the whole spec, but only `circle`, `symbol`, `line`
  and `geojson` have been exercised** (via `addPoints` and the example). The other seven
  layer types and five source types are generated and unit-tested for serialisation
  only.
- **3D lighting on non-Metal backends is unverified code**, as above.

---

## 4. Repo state (for the merge to `main`)

Audited 2026-07-30:

- No stashes anywhere.
- Every local branch, every remote branch, and `main` are **fully contained** in
  `feat/glued-widget-markers` — nothing is stranded on another branch or machine.
- Two worktrees (`.` and `.claude/worktrees/3d-model-spike`), both clean apart from the
  vendored mbgl submodule showing *modified content* — that is the build hook's applied
  patches, not work.
- The submodule **pointer** is unchanged; only its working tree is patched.
- Not committed, on purpose: the Flutter-generated `example/ios` and `example/macos`
  project churn (regenerated at build time, CLAUDE.md §8).
