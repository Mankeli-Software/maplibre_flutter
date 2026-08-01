# MapLibre Feature Parity Matrix — `maplibre_flutter`

This document tracks, feature by feature, which parts of the MapLibre feature surface are wired
through the `maplibre_flutter` plugin API on each platform — Android, iOS, macOS, Windows, Linux,
and Web. The stated goal of the project is **full parity**: every platform should eventually support
every MapLibre feature the underlying engine can express. This matrix is the parity *backlog* —
it is deliberately exhaustive so the gap between "what the engine can do" and "what we have bound"
is always visible. Rows come from the canonical MapLibre feature surface (style-spec, gl-js, and the
native SDKs); cells reflect what is actually wired in this repo today.

_Last updated: 2026-07-31_ (cross-platform parity push: `MapLibreModelHost` on all five native
tiers, rotate/tilt gestures, iOS verified on a Simulator)._ Engines in play: **`mbgl-core`** (pinned by
`MBGL_CORE_VERSION`) is the default renderer on **every** platform since the 2026-06-21
core-primary inversion; the MapLibre Android SDK 11.11.0, Apple SDK 6.27.0 and
maplibre-gl-js 5.24.0 are **opt-in** packages (`maplibre_flutter_{android,ios}_sdk`,
`maplibre_flutter_web_gljs`).

Two consequences for reading this matrix:

- **All five native columns are one engine.** Android, iOS, macOS, Windows and Linux run the
  same `mbgl-core` through the same C ABI and the same Dart tier, so a feature wired on one is
  wired on all five. They differ only in what has been *run on hardware* — hence 🧪 below.
- **The Web column means the WASM core**, which is the default. Rows marked **web_only** are
  gl-js features: reachable today only by adding the opt-in `maplibre_flutter_web_gljs`
  package, and not implemented in our web binding either way.

For what landed most recently, what is verified where, and the ordered per-platform backlog,
see **`docs/cross-platform-continuation.md`**.
## Reading this alongside the generated file

The old ✅/🧪/❌/➖ legend is gone with the tables it described. It had drifted
into claiming things like "nothing else is plumbed through the platform
interface yet", written when the contract was camera-and-style and left standing
long after queries, feature state, clusters, the typed style API and 3D models
had landed. **A legend for symbols nobody emits any more is pure rot**, and it
was part of what made the tables trustworthy-looking and wrong.

Two distinctions did carry their weight, so they survive as prose:

- **Wired is not verified.** Five native tiers share one engine, one C ABI and
  one Dart tier, so a feature written for one is *present* on all five. That is
  a compile-level guarantee. Which tiers have actually been RUN is recorded in
  `docs/cross-platform-continuation.md`, and nowhere else — because it is
  evidence, not a property of the source, and the generator deliberately cannot
  invent it.
- **Missing is not impossible.** mbgl clamps pitch to 60°; globe and sky are
  gl-js features MapLibre Native does not have. Those are engine limits and no
  binding work changes them. Everything else absent is backlog. Keeping the two
  apart is the only reason a backlog count means anything.

## The per-feature tables are gone — read the generated one

Nine hand-maintained tables used to live here, 483 rows of ✅/🧪/❌/➖ across six
columns. **An audit found ~44% of sampled cells wrong, five hours after someone
had hand-fixed the file.** A table that says a feature is wired when it is not
is worse than no table: it gets consulted *instead of* the code, and it is
consulted precisely when someone is deciding whether to write something that
already exists.

Everything mechanically derivable now lives in **`FEATURE_MATRIX.generated.md`**,
produced by `packages/maplibre_flutter/tool/generate_feature_matrix.dart` from:

- each platform controller's `implements` clause — who has which capability;
- the `abstract interface class` declarations in the platform interface — what a
  capability actually contains;
- the `FFI_PLUGIN_EXPORT` list in `maplibre_flutter_core.h` — the whole engine
  surface the tiers can reach.

Regenerate with `dart run tool/generate_feature_matrix.dart` from
`packages/maplibre_flutter`. It is committed and regen-diffed in CI, exactly like
the ffigen bindings, so it cannot drift.

**What the generated file cannot tell you, and this one can:**

- **A tick means WIRED, not RUN.** Only macOS and iOS have been exercised on
  hardware. Android, Windows and Linux share one engine, one C ABI and one Dart
  tier with macOS, so their code is identical — which is a compile-level
  guarantee and nothing more.
- **Where the real gaps are**, in priority order:
  - **Web (WASM)** implements neither `MapLibreMapEvents` nor the camera
    commands, so no error stream, no style-loaded event, no engine transitions.
    It is also the only tier where a filtered query is *refused* rather than
    answered, deliberately: returning unfiltered features is the one failure a
    caller cannot see. Nothing in `src/web/` has been compiled anywhere.
  - **Offline packs** (`MLNOfflineStorage`) and the **location component**
    (`MLNUserLocation`) are unbuilt on every tier.
  - **Auth headers and `transformRequest`** are unbuilt; the API key is not.
    mbgl has no header hook on `ResourceOptions`, so it needs a custom
    `FileSource` and a Dart callback on the network path — a different order of
    risk from the rest of the surface.
- **What "the engine cannot" means.** Pitch is clamped to 60° by mbgl; globe and
  sky are gl-js features MapLibre Native does not have. Those are engine limits,
  not backlog, and no amount of binding work changes them.

For what landed most recently and the ordered per-platform backlog, see
**`docs/cross-platform-continuation.md`** and **`docs/api-parity-progress.md`**.

## How to keep this honest

1. **Do not re-add a hand-maintained table.** That is what was just removed, and
   it was removed because it was wrong. If a fact is derivable from the source,
   teach the generator; if it is not, it is judgement and belongs in prose above.
2. **Flip nothing to "verified" without a run.** The generated file deliberately
   does not carry a verified/unverified axis, because that is not derivable —
   record hardware runs in `docs/cross-platform-continuation.md`.
3. **Regenerate after any capability change.** Adding a member to a capability
   interface, or an `implements` clause to a tier, changes the generated file;
   CI diffs it like the ffigen bindings, so a stale one is a build break rather
   than a slow rot.
4. **Engine limits stay documented as limits.** Do not list mbgl's 60° pitch
   clamp or the absence of globe as backlog — a backlog nobody can clear is
   noise that hides the items someone could actually pick up.
