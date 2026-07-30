# Continuing the annotation / style / 3D work on the other platforms

**Snapshot: 2026-07-30.** Everything described here is on `feat/glued-widget-markers`
(pushed, 49 commits ahead of `main`). It is all **verified on macOS only** unless a
row says otherwise — that is the whole point of this document: what is done, what is
merely *written*, and what has to happen per platform before any of it can be called
supported.

Read this with CLAUDE.md §12 (the decision log carries the *why* for each piece) and
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
| **3D `.glb` models** (`controller.addModel`, `MapLibreMap(models:)`) | `maplibre_flutter_core` (glTF loader, model host) + `MapLibreModelHost` | **No — Metal-only so far** | macOS / Metal |
| **Example scenarios + rotate/tilt controls** | `packages/maplibre_flutter/example` | Yes | macOS |

### Capability wiring as it stands

Measured from the source, not assumed:

| Capability | Android | iOS | macOS | Windows | Linux | Web (WASM) | Web (gl-js) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `MapLibreMapProjector` (markers) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| `MapLibreCameraTickNotifier` | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| `MapLibreStyleLayers` (+ typed API, transitions) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Projects against the **presented** frame | ✅ | ✅ | ✅ | ✅ | ✅ | ➖ | ➖ |
| `MapLibreModelHost` (3D) | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |

✅ here means **the forward is written**, not that it has been run on that platform.
Only the macOS column has been exercised on hardware.

---

## 2. Per-platform continuation

### Linux and Windows — code complete, unrun

Both already implement projector, camera tick and style layers, and both forward
`setTransitionOptions`. Nothing is known to be missing; **the work is verification**,
and these two are where a mistake is most likely, because their present paths flip the
pixel buffer while the anchor space stays top-left (see the 2026-06-21 pinch-anchor
regression in CLAUDE.md — the lesson being: do not "fix" an anchor convention on a
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
  (documented at length in CLAUDE.md 2026-06-20) — so zero-copy will read as white
  there and that is not a bug to chase.
- iOS: the marker overlay and gesture layer are the shared Dart tier, so the risk is
  DPR-related, not logic-related. Check label crispness and that pins track under a
  pinch (the pixelRatio class of bug from the iOS-core POC).

### Web — the real gap

Neither web package implements **any** of the capabilities: no projector, no camera
tick, no style layers, no models. So on web today: no widget markers, no engine
layers, no typed style API, no transitions.

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

### 3D models — the largest remaining piece

Only macOS has `MapLibreModelHost`. The engine-side work is **not** per-platform Dart
plumbing; it is the shader patches:

- `patches/custom-geometry-lighting.patch` touches all four backends (Metal, GL,
  Vulkan, WebGPU), but **only the Metal edits have been run**. The GL / Vulkan / WebGPU
  edits are mechanical mirrors — treat them as unverified code, not as working code.
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
  project churn (regenerated at build time, CLAUDE.md §5b).
