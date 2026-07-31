# A typed Dart style API — design notes

**Status: built, covering the whole spec.** All 10 layer types, all 6 source
types, all 84 expression operators and every enum are generated from the vendored
spec — discovered from it, not allowlisted, so a layer type added by a future
spec generates itself and CI's regen diff makes that visible. The generator, its
committed output, the CI check, `addPoints`-on-the-typed-API and an example
scenario that uses it directly all landed together. What follows is the design as
built, with the original reasoning kept intact.

- Generator: `packages/maplibre_flutter/tool/generate_style_api.dart`
- Output (committed, never hand-edited):
  `packages/maplibre_flutter/lib/src/style/generated/*.g.dart` (~5.6k lines:
  10 layers, 6 sources, 33 enums, 84 expression builders)
- Worked example: the **Typed style API** scenario in
  `packages/maplibre_flutter/example/lib/main.dart` — a `GeoJsonSource` with
  per-point properties, a `CircleLayer` coloured by `Expr.match` and sized by
  `Expr.interpolate`, a `SymbolLayer`, and a dashed `LineLayer`, with no JSON
- Hand-written runtime it sits on: `lib/src/style/style_value.dart`
  (`StyleValue`, `Expression`), `style_layer.dart`, `geojson_data.dart`,
  `style_encoding.dart`
- CI: `.github/workflows/ci.yml` regenerates and `git diff --exit-code`s the
  output, exactly like ffigen

What it looks like:

```dart
controller.layers
  ..addSource(
    'pts',
    GeoJsonSource(
      data: GeoJsonData.points(points),
      cluster: true,
      clusterRadius: 50,
    ),
  )
  ..addLayer(
    CircleLayer(
      id: 'pts-clusters',
      source: 'pts',
      filter: Expr.has('point_count'),
      circleRadius: Expr.step(Expr.get('point_count'), 18, 100, 24, 750, 32),
      circleColor: const StyleValue(Color(0xFFF57C00)),
      circleStrokeWidth: const StyleValue(2),
    ),
  );
```

One `TODO(typed-style-api)` remains, in
`maplibre_flutter_core/lib/maplibre_flutter_core.dart`, pointing at this file
from the raw JSON C-ABI wrappers.

---

## Where we were (the original context, kept for the reasoning)

Typed already:

- `layers.addPoints(id, points, cluster:, radius:, color:, clusterTextFont:, …)`
- `setPoints`, `removePoints`, `addImage`, `addWidgetIcon`
- `queryRenderedFeatures(rect) -> List<MapLibreQueriedFeature>`
  (`isCluster`, `pointCount`, `point`)

Stringly-typed:

- `addSourceJson(id, json)`, `addLayerJson(json, beforeId:)`,
  `setGeoJsonData(sourceId, geoJson)`

So the common case (a clustered point layer) never touches JSON; anything beyond
it does. A malformed document is a runtime `ArgumentError` carrying mbgl's own
parse message — not a compile error.

**Why JSON first.** Seven C functions over `mbgl`'s `convertJSON<T>` buy the
entire spec — every layer type, expressions, filters, data-driven styling — for
a fraction of the API surface of typed accessors. It is also the same shape
maplibre-gl-js users already know. The typed layer is a *façade*: it can be
added later without touching the C ABI, because a typed layer's job is to
serialise to exactly the JSON we already accept.

---

## The size of the problem

Measured from the spec vendored in our own submodule
(`third_party/maplibre-native/scripts/style-spec-reference/v8.json`):

| | count |
|---|---|
| Layer types | 10 (`background`, `circle`, `color-relief`, `fill`, `fill-extrusion`, `heatmap`, `hillshade`, `line`, `raster`, `symbol`) |
| Paint + layout properties | 138 |
| Source types | 6 (`geojson`, `image`, `raster`, `raster-dem`, `vector`, `video`) |
| Expression operators | 84 |

138 properties and 84 operators is why this should be **generated, not
hand-written**. Hand-maintaining it means drifting from the spec on every mbgl
bump, silently.

---

## Precedent: mbgl already does this

Upstream generates its own C++ layer classes from that same file:

- `scripts/style-spec-reference/v8.json` — machine-readable spec
- `scripts/generate-style-code.mjs` — the generator
- `include/mbgl/style/layers/layer.hpp.ejs` — the template

So `CircleLayer::setCircleRadius(...)` in the C++ we link against is itself
generated from the spec we have vendored. Doing the same in Dart follows the
engine's own practice, uses the same source of truth, and stays in step with the
pinned `MBGL_CORE_VERSION` automatically.

---

## Proposed shape

### 1. Generated layers and sources

```dart
controller.layers.addLayer(
  CircleLayer(
    id: 'pts-clusters',
    source: 'pts',
    filter: Expr.has('point_count'),
    circleRadius: Expr.step(Expr.get('point_count'), 18, {100: 24, 750: 32}),
    circleColor: const Color(0xFFF57C00),
    circleStrokeWidth: 2,
    circleStrokeColor: const Color(0xFFFFFFFF),
  ),
);

controller.layers.addSource(
  'pts',
  GeoJsonSource(
    data: GeoJsonData.features(points),
    cluster: true,
    clusterRadius: 50,
    clusterMaxZoom: 14,
  ),
);
```

Every property is `T | Expression` — the spec marks which support
`property-function` / `zoom-function`, so the generator knows which may take an
expression and which are constants only. Encode that in the type
(`StyleValue<double>` with `.constant` / `.expression` constructors) rather than
accepting `Object?`.

### 2. Serialisation, not a new transport

`StyleLayer.toJson()` → the existing `addLayerJson`. **No C ABI change.** The
typed API is a pure Dart addition; the raw methods stay as the escape hatch for
anything the generator has not covered (and for users porting gl-js code).

### 3. Expressions

The hard part, and where most bindings give up. Options:

- **(a) Builder functions** — `Expr.get('x')`, `Expr.step(...)`,
  `Expr.interpolate(...)`. Catches arity and nesting mistakes, not types.
- **(b) Typed expressions** — `Expression<double>` etc. Genuinely type-safe,
  much more generator work, and awkward for heterogeneous operators like `case`
  and `match`.
- **(c) Builders + a raw hatch** — (a) plus `Expr.raw([...])`.

**Recommendation: (c).** 84 operators is too many to model perfectly at first;
generate builders for the common ones from `expression_name.values`, keep the
hatch, and tighten types later where it pays.

### 4. Where the generator lives

`packages/maplibre_flutter/tool/generate_style_api.dart`, following the repo
convention that codegen is a Dart script in `tool/` and **output is committed**
(§5, §9 of CLAUDE.md). Reads the vendored `v8.json`, writes
`lib/src/style/generated/*.g.dart`.

CI then verifies it is current the same way ffigen is: regenerate and
`git diff --exit-code`. That is what makes an mbgl bump that changes the spec a
visible failure instead of silent drift.

---

## Risks and open questions

- **Naming.** Spec properties are kebab-case (`circle-stroke-width`); Dart wants
  `circleStrokeWidth`. Mechanical, but `text-field`-style names with hyphens
  inside enum *values* need care.
- **Colours.** The spec's colour type accepts CSS strings; Dart wants
  `dart:ui Color`. Convert at the boundary and keep a string escape hatch for
  expression-valued colours.
- **Enums.** Many layout/paint values are string enums (`icon-anchor`,
  `line-cap`). Generate real Dart enums — a clear win over strings.
- **Transitions.** `*-transition` objects are a parallel property set the
  generator must not miss.
- **Spec drift.** Pinned to the submodule's spec, so a core bump can change
  generated output. The CI diff check turns that into a visible failure.
- **Scope creep.** Landed `circle` first, then widened to all 10 in one step
  once the mechanism was proven — the remaining types needed only new spec-type
  mappings (`padding`, `colorArray`, `numberArray`,
  `variableAnchorOffsetCollection`, arrays-of-enum, nested array schemas), not
  new per-property work. An allowlist was dropped deliberately: it would
  reintroduce exactly the drift this design exists to prevent.

## Definition of done

1. ✅ Generator reads the vendored spec and emits sources, layers, enums.
2. ✅ Generated output committed; CI regen-diff check wired in.
3. ✅ `addLayer(StyleLayer)` / `addSource(String, StyleSource)` alongside the
   existing JSON methods, which remain public.
4. ✅ `addPoints` reimplemented on top of the typed API — proof it can express
   what we already hand-roll.
5. ✅ Tests: generated JSON matches hand-written equivalents byte-for-byte
   (`test/style_api_test.dart`). The "native test that a generated layer
   renders" is **as close as the dependency graph allows**: the engine tests
   live in `maplibre_flutter_core`, which must not depend on the app-facing
   package, so instead a test pins the typed output equal to the exact documents
   `maplibre_flutter_core_test.dart` already adds to a real map and verifies by
   counting painted pixels.

---

## How it came out — decisions the build forced

- **Expressions are assignable to every property, with no wrapping.**
  `Expression extends StyleValue<Never>`, and Dart generics are covariant, so
  `StyleValue<Never> <: StyleValue<T>` for every `T`. That is what makes
  `circleRadius: Expr.step(...)` and `circleRadius: const StyleValue(6)` both
  type-check against one `StyleValue<double>?` parameter, without falling back
  to `Object?`. Recommendation (c) from §3, as planned: builders for all 84
  operators plus `Expr.raw`.
- **Constant-only properties get their plain type.** `property-type: constant`
  in the spec (e.g. `visibility`) generates `StyleVisibility?`, not a
  `StyleValue`, so an expression the engine would reject is not expressible.
- **The spec has no arity information for expressions**, so every generated
  builder is uniformly variadic to 10 arguments and drops the ones you omit
  (`identical`-checked sentinel, so an explicit `null` — meaningful in
  `["literal", null]` — survives). Longer arrays go through `Expr.raw`;
  overflowing is a compile error, not a silent truncation.
- **Name mapping needed a small curated table**, all of it in the generator:
  symbolic operators (`!` → `not`, `<=` → `lessThanOrEqual`), Dart reserved
  words (`case` → `caseOf`, `var` → `variable`, `in` → `isIn`), `to-string` →
  `toStringOp` (a static `toString` collides with `Object.toString`), and
  `visibility` → `StyleVisibility` (the bare name collides with the Flutter
  widget). Everything else is mechanical camelCase, and the generator *throws*
  on a collision or reserved word rather than emitting something broken.
- **Numbers serialise as ints when whole** (`6`, not `6.0`) and **opaque colours
  as `#rrggbb`**, so generated documents are byte-identical to hand-written
  style JSON. GeoJSON coordinates deliberately skip that rewriting and stay
  doubles.
- **Only the imports a file needs are emitted** — an unused import is an
  analyzer warning and `melos run analyze` runs `--fatal-infos`.
- **The generator runs `dart format` on its output**, so the committed files are
  byte-stable and the repo's format gate needs no manual step.
- **`promoteId` is the one spec type with no narrower Dart form** (`{"*":
  {"type": "string"}}` — a property name *or* a per-source-layer map), so it is
  `Object?`. Unknown spec types make the generator throw, by design: silent
  `Object` fallbacks are how a generated API rots.
