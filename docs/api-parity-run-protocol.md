# API parity — run protocol

**How to execute one run of the API-parity effort.** The ledger
(`docs/api-parity-progress.md`) holds all state; this file holds the procedure. Between them, a
run is fully specified — the invoking prompt only needs to say "do a run".

This procedure is designed to be run **repeatedly**. Each run advances the goal and records what it
did. No run is expected to finish the goal — each is expected to leave the repo green and the ledger
honest.

**The goal.** Bring the public Dart API up to parity with the canonical MapLibre APIs
(maplibre-gl-js, the MapLibre Apple/Android SDKs), by **copying upstream naming and shape rather
than inventing our own**, so this plugin is credible as *the* stable MapLibre Flutter binding.

**Goal reached when** every P0 and P1 row in `docs/api-parity-binding-spec.md` is either implemented
or explicitly rejected with a recorded reason, and `docs/api-parity-progress.md` says so.

---

## Run protocol — follow this every time

1. **Read `docs/api-parity-progress.md`.** It is the ledger: stages, tasks, checkboxes, run log.
   Read the run log first; the previous run may have left something `[~]` half-done.
2. **Read `docs/api-parity-binding-spec.md`** — its **"Engine traps that constrain these
   signatures"** preamble first, then the rows covering the tasks you are about to do. It is the
   source of truth for *what to call things and what shape they take*, with header:line citations
   into gl-js, the Apple SDK and mbgl. Follow the citations; do not guess a signature. Note that the
   preamble flags its own camera rows as drafted **before** the `CameraOptions::anchor` /
   `Transform::rotateBy` / `Map::pitchBy` findings — those constrain how the camera verbs can be
   implemented at all.
3. **Read `CLAUDE.md`** — house rules. It overrides this document where they conflict; surface the
   conflict rather than diverging silently.
4. **Pick the work.** Finish any `[~]` task first. Otherwise take the next `[ ]` task in the
   lowest-numbered stage whose predecessor stages are all `[x]` or `[-]`. **Do not start a stage
   until every task above it is closed** — the order is a real dependency order, not a preference.
5. **Size the run.** Take as much as you can finish *and verify* in one sitting. A stage is usually
   too big; one to four tasks is usually right. Finishing three tasks cleanly beats starting eight.
6. **Do the work**, obeying the constraints below.
7. **Run the gates** (below). They must pass before you update the ledger.
8. **Update the ledger:** tick the tasks you completed, mark anything half-done `[~]` with a note on
   exactly what remains, and append a run-log entry using the template at the bottom of that file.
9. **Report** to the user: what landed, what you deferred and why, any spec row you found to be
   wrong, and what the next run should pick up.

If a task turns out to be blocked — it needs hardware you cannot reach, or an upstream mbgl change —
mark it `[-]`, record why in the run log, and move to the next task rather than stopping.

## Constraints that are not negotiable

- **Never hand-edit generated files** (`packages/maplibre_flutter/lib/src/style/generated/*.g.dart`,
  `maplibre_flutter_core_bindings_generated.dart`). Regenerate via the `tool/` scripts only. ffigen
  must be run on macOS.
- **Extend the platform interface deliberately, in one shot per stage — never per-platform.**
  `MapLibreStyleLayers` is an `abstract interface class`, so adding a method breaks all five native
  controllers plus the test doubles at compile time. That is intended; it must land atomically.
- **Optional capabilities are feature-detected with `is`**, as separate interfaces — never added to
  the base `MapLibreMapPlatformController` contract.
- **Three-bucket rule** for every new property: init-only → `MapOptions`; mutable + declarative →
  widget prop pushed via `didUpdateWidget`; mutable + imperative/high-frequency → controller
  namespace. There is deliberately no public `controller.setStyle`.
- **No method channels on the data path** — C ABI bindings only.
- Conventional Commits. Branch off the current branch; never commit to `main`.

## Traps that will bite — each cost this project a session

- **`LatLng(lat, lng)` ⇄ GeoJSON `[lng, lat]`** — flip at every boundary. CLAUDE.md names this the
  #1 recurring bug. **Test with asymmetric fixtures against absolute directions** (north is up, east
  is right), never round-trips: a symmetric Y flip survived every round-trip test the project had.
- **`GeoJsonFeature.toJson()` must NOT use `encodeStyleJson`.** That encoder rewrites `6.0` → `6`;
  `GeoJsonData.toJson()` deliberately opts out because those bytes are the one path into mbgl's
  GeoJSON parser (`docs/decision-log.md:1330-1333`). Test that `60.45` survives byte-identically.
- **`CameraOptions::anchor` is silently discarded whenever `center` is set.** So anchored zoom/rotate
  can never be get-camera-then-set-camera, and a centre-anchored test cannot detect the bug.
- **`Transform::rotateBy` and `Map::pitchBy` are broken upstream** — do not use either; build on
  `jumpTo(CameraOptions()...)` as `mbl_map_rotate_by`/`mbl_map_pitch_by` already do.
- **Never blind-port a controller change to a sibling platform citing the shared core.** That exact
  move flipped the Windows pinch anchor. Verify on that hardware or leave it.
- **Keep a Dart-side *field* reference to every registered native callback**, or the GC collects the
  proxy and callbacks silently stop.
- **Long-running calls belong on a helper isolate**, not the UI isolate.
- **"A frame came back" does not prove the map is visible** — assert real pixels.
- `FEATURE_MATRIX.md` is ~44% wrong in sampled cells, all under-reporting. **Determine current state
  by reading code, never from that file.** Stage 9 replaces it.

## Gates — all must pass before you update the ledger

```bash
dart run melos run analyze          # --fatal-infos; an unused import in a generated file is a break
dart run melos run test --no-select
dart run melos run format
```

Plus, per stage:

- **Stages 0, 1, 4** — `git diff` must show **no** change to any `*_generated.dart` or to
  `maplibre_flutter_core.{h,cpp}`. These stages are pure Dart; needing a C ABI change means you have
  left the scope. Stop and report instead.
- **Stages 2, 3, 5, 6, 8** — after any header change, regenerate ffigen **on macOS** and confirm the
  committed bindings are diff-clean. Add or extend the fake in
  `packages/maplibre_flutter_core/lib/testing.dart` so the new surface is testable on the VM without
  a dylib.
- **Stage 3 and anything touching gestures or the camera** — must be run on real hardware per tier
  before its ledger task is ticked. macOS is the reference tier; verify there first.
- **Stage 7** — flip a 🧪 to ✅ only on evidence from that platform, never by inference.

Every new public API needs dartdoc, and each signature's doc comment should name the upstream API it
mirrors (e.g. "mirrors gl-js `LngLatBounds`; field order follows `mbgl::LatLngBounds`").

## Judgement

The spec document was produced by analysis, not by compilation. If a citation is wrong when you open
the actual header, trust the header, fix the spec row, and note it in your report — one camera
citation was already found wrong this way (`TransformState::getCoordMatrix()` is private, not public).

Where the spec and the code disagree about current state, **trust the code**.

Where you think a proposed signature is wrong, say so before implementing it — but the default is to
copy upstream, because the whole point of this effort is to stop soloing the API design.

---

## Why this shape

- **Resumability lives in the ledger, not the prompt.** The invoking prompt is stateless;
  `docs/api-parity-progress.md` holds all state. Run it once or twenty times and it picks up where it
  left off. It also works under `/loop`.
- **The stage gates differ on purpose.** Stages 0/1/4 assert no generated-file diff — that is a
  tripwire, not a formality: if a run drifts into C ABI work during a pure-Dart stage, the gate
  catches it before the platform interface churns.
- **Half-done is recorded honestly.** `[~]` plus a note on exactly what remains beats racing to tick
  a box, which is the usual failure mode of a long checklist.
