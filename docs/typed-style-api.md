# A typed Dart style API — design notes

**Status: not implemented.** Today `controller.layers` takes MapLibre Style Spec
JSON strings. This records why, what a typed API should look like, and how to
build it — so the decision is reversible with context rather than re-derived.

Tracked in code as `TODO(typed-style-api)` in
`maplibre_flutter/lib/src/map_layers_controller.dart` and
`maplibre_flutter_core/lib/maplibre_flutter_core.dart`.

---

## Where we are

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
(§5, §10 of CLAUDE.md). Reads the vendored `v8.json`, writes
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
- **Scope creep.** 10 layer types is a lot to land at once. Suggested order:
  `circle`, `symbol`, `line`, `fill` (which covers essentially all annotation
  work), then the rest.

## Definition of done

1. Generator reads the vendored spec and emits sources, layers, enums.
2. Generated output committed; CI regen-diff check wired in.
3. `addLayer(StyleLayer)` / `addSource(String, StyleSource)` alongside the
   existing JSON methods, which remain public.
4. `addPoints` reimplemented on top of the typed API — proof it can express what
   we already hand-roll.
5. Tests: generated JSON matches hand-written equivalents byte-for-byte, plus a
   native test that a generated layer actually renders.
