# VoiceOver feature exploration is dead on every non-Mapbox style — upstream MapLibre defect

**Status: found, verified in the vendored submodule, NOT yet reported upstream.** We carry no
patch — this one is not in our path (we do not build the Apple SDK's accessibility layer; §5 of
`docs/accessibility.md` reimplements the model in Dart). It is filed here because it is the single
highest-leverage accessibility fix available in the MapLibre ecosystem, and because fixing it
upstream would restore the feature for **every** MapLibre Apple SDK consumer, not just us.

Found 2026-08-01 while researching prior art for `docs/accessibility.md`. The Apple SDK is the only
MapLibre platform with real map-content accessibility — and the good half of it cannot fire on a
MapLibre style.

---

## The defect

`MLNMapView` is a genuine `UIAccessibilityContainer`. Beyond the map element itself it exposes one
accessibility element per visible **place** and **road** feature, each with a composed label — the
road describer alone produces `"Route 42, Divided road, southwest to northeast"`. This is
substantially better than anything gl-js, the Android SDK or any Flutter map package has ever
shipped.

The element list is sourced from two style queries:

```objc
// platform/ios/src/MLNMapView.mm:3288
- (NSArray<id<MLNFeature>> *)visiblePlaceFeatures {
  if (!_visiblePlaceFeatures) {
    _visiblePlaceFeatures =
        [self visibleFeaturesInRect:self.bounds
        inStyleLayersWithIdentifiers:[NSSet setWithArray:self.style.placeStyleLayers…]];
```

`placeStyleLayers` filters the style's layers down to a hardcoded set of Mapbox Streets source-layer
names — **and first restricts to sources that pass a vendor test**:

```objc
// platform/darwin/src/MLNStyle.mm:615
- (NSArray<MLNStyleLayer *> *)placeStyleLayers {
  NSSet *streetsSourceIdentifiers = [self.mapboxStreetsSources valueForKey:@"identifier"];

  NSSet *placeSourceLayerIdentifiers =
      [NSSet setWithObjects:@"marine_label", @"country_label", @"state_label", @"place_label",
                            @"water_label", @"poi_label", @"rail_station_label",
                            @"mountain_peak_label", @"natural_label", @"transit_stop_label", nil];
  …
        return [layer isKindOfClass:[MLNVectorStyleLayer class]] &&
               [streetsSourceIdentifiers containsObject:layer.sourceIdentifier] &&
               [placeSourceLayerIdentifiers containsObject:layer.sourceLayerIdentifier];
```

`roadStyleLayers` (`:632`) does the same for `{road_label, road}`. And `mapboxStreetsSources` is:

```objc
// platform/darwin/src/MLNStyle.mm:608
- (NSSet<MLNVectorTileSource *> *)mapboxStreetsSources {
  return [self.sources objectsPassingTest:^BOOL(__kindof MLNVectorTileSource *source, BOOL *stop) {
    return [source isKindOfClass:[MLNVectorTileSource class]] && source.mapboxStreets;
  }];
}
```

which lands on the gate itself:

```objc
// platform/darwin/src/MLNVectorTileSource.mm:191
- (BOOL)isMapboxStreets {
  NSURL *url = self.configurationURL;
  if (![url.scheme isEqualToString:@"mapbox"]) {
    return NO;
  }
  NSArray *identifiers = [url.host componentsSeparatedByString:@","];
  return [identifiers containsObject:@"mapbox.mapbox-streets-v8"] ||
         [identifiers containsObject:@"mapbox.mapbox-streets-v7"];
}
```

**A source whose URL scheme is not `mapbox://` returns `NO` immediately.** MapLibre demotiles,
OpenMapTiles, Protomaps, Stadia, Esri, a self-hosted tileserver and every raster style all fail on
the first line. `mapboxStreetsSources` is empty, both predicates match nothing, both arrays are
empty, and **zero place and road accessibility elements are produced**.

The map element survives, so the failure is silent: VoiceOver still finds a map, and
`accessibilityValue` (`platform/ios/src/MLNMapView.mm:3229`) degrades from

> "Zoom 12x. 3 annotation(s) visible. Places visible: Helsinki, Espoo, Vantaa. 4 road(s) visible."

to just

> "Zoom 12x."

Nothing logs. Nothing throws. A developer testing on Mapbox Streets sees it work and ships.

## Why it is a defect and not a policy

This is inherited from mapbox-gl-native, where gating on Mapbox's own tileset was coherent: the
source-layer names above **are** the Mapbox Streets schema, and the code needs to know that
`poi_label` means "a place" and `road_label` means "a road". The vendor check was a cheap proxy for
"this style uses the schema I understand".

In MapLibre it is no longer a proxy for anything. The fork's entire purpose is to serve styles that
are not Mapbox's, and `mapbox://` URLs are the one scheme a MapLibre user is least likely to have.
So the check now excludes exactly the population the project exists for, while the schema knowledge
it was guarding — the ten place layer names and the two road layer names — is left hardcoded and
unreachable.

Note also that OpenMapTiles, the most common MapLibre vector schema, **uses several of the same
source-layer names** (`place`, `poi`, `water_name`, `transportation_name`). A fair fraction of the
existing hardcoded list would work unchanged if the vendor gate were simply lifted.

## The fix

Two independent changes, smallest first:

1. **Stop gating on the vendor.** Drop the `streetsSourceIdentifiers` term from both predicates in
   `MLNStyle.mm`, matching on source-layer identifier alone. One line in each method. Every style
   that happens to use Mapbox-Streets-compatible source-layer names — which includes OpenMapTiles
   for several of them — starts producing accessibility elements immediately, and no style gets
   *worse*, because today they all produce none.

2. **Make the schema configurable**, which is the real fix. Expose the two identifier sets as
   settable properties on `MLNStyle` (or as an accessibility options object on `MLNMapView`), so an
   app on OpenMapTiles or a bespoke schema can name its own place and road layers. Keep the current
   hardcoded sets as the default. This is the same conclusion `docs/accessibility.md` §5.2 reaches
   independently for our Dart implementation, where `layerIds` is **required** and has no default
   allowlist at all — a wrong announcement is worse than silence.

Change 1 is safe to land alone and is worth opening on its own.

## What a test would look like

CLAUDE.md §2 records that the one gap in our `upstream-simulator-stencil` submission is a committed
test, so: this defect *is* testable, unlike that one, and the test should ship with the PR.

`platform/ios/test/MLNMapAccessibilityElementTests.m` currently exercises only the three formatter
classes in isolation (88 lines — the entire automated accessibility suite for the SDK). Add a
`MLNStyle` test that builds a style with one `MLNVectorTileSource` on a **non-`mapbox://`** URL and
one `MLNSymbolStyleLayer` whose `sourceLayerIdentifier` is `poi_label`, then asserts
`style.placeStyleLayers` contains that layer. Against today's code it fails; against change 1 it
passes. That single assertion pins the whole defect.

## Related defects found in the same read

Filed together because they are in the same call paths and a maintainer looking at one should see
the others. None is as consequential as the gate.

| Defect | Where | Effect |
| --- | --- | --- |
| The spoken zoom is off by one | `MLNMapView.mm:3229`, `round(self.zoomLevel + 1)` | VoiceOver announces "Zoom 13x" at `zoomLevel == 12`, disagreeing with the SDK's own property |
| The summary reads the untranslated name | `MLNMapView.mm:3248`, raw `attributeForKey:@"name"` | The map value says "Цинциннати" while the element label says "Cincinnati" (`MLNMapAccessibilityElement.mm:46-73` transliterates) — the same place announced two ways |
| Cache invalidation is coupled to the host app's delegate | `MLNMapView.mm:6795-6832` | If the app implements neither `mapView:regionDidChangeAnimated:` nor `mapView:regionDidChangeWithReason:animated:`, the feature caches are never cleared and stale elements survive an arbitrary pan |
| A non-square minimum element size would be applied wrong | `MLNMapView.mm:3535-3536`, `.width / 2` passed for both insets | Latent only — the constant is `CGSizeMake(10, 10)` today. The 10×10 minimum is itself far below WCAG 2.5.8's 24×24 and Apple's own 44×44 HIG guidance |
| The element sort is re-run per element access | `MLNMapView.mm:3376-3396` | A full `std::sort` with an mbgl projection per comparison runs on **every** `accessibilityElementAtIndex:` and `indexOfAccessibilityElement:` — O(n² log n) for one VoiceOver traversal |
| MapLibre Android has no accessibility layer at all | `platform/android/`, zero matches for `AccessibilityNodeProvider` / `ExploreByTouchHelper` / `announceForAccessibility` | Not a regression to fix but a gap to state: the Android SDK's map is one static `contentDescription` set at `MapView.java:141` and never recomputed |

## Opening the upstream PR

Outstanding work, in order:

1. Open an issue on `maplibre/maplibre-native` titled for the user-visible symptom, not the
   mechanism — *"VoiceOver announces no places or roads on any non-Mapbox style"*. Lead with the
   `accessibilityValue` before/after, because that is reproducible in one line by anyone with an
   iPhone and demotiles.
2. PR change 1 plus the `MLNStyle` test above.
3. Raise change 2 in the issue as the follow-up, with our `layerIds`-is-required reasoning
   (`docs/accessibility.md` §5.2) as the argument for why a default allowlist is the wrong shape.
4. The five related defects: one issue, listed as a table. Only the `+1` and the raw-`name` items
   are worth a PR from us; the cache-invalidation one needs a maintainer's view on the delegate
   contract before anyone writes code.

**No gl-js mirror.** gl-js has no feature-exploration accessibility at all — no `aria-live`, no
per-feature elements — so there is nothing there to gate. That absence is its own upstream
opportunity and is tracked separately in `docs/accessibility.md` §2.

## Evidence

All line numbers verified against the vendored submodule at
`packages/maplibre_flutter_core/third_party/maplibre-native`, pinned by `MBGL_CORE_VERSION`.

- `platform/darwin/src/MLNVectorTileSource.mm:191-199` — the gate
- `platform/darwin/src/MLNStyle.mm:608-613` — `mapboxStreetsSources`
- `platform/darwin/src/MLNStyle.mm:615-630` — `placeStyleLayers`
- `platform/darwin/src/MLNStyle.mm:632-644` — `roadStyleLayers`
- `platform/ios/src/MLNMapView.mm:3229-3286` — `accessibilityValue`
- `platform/ios/src/MLNMapView.mm:3288-3306` — the two cached, uncapped queries
- `platform/ios/src/MLNMapAccessibilityElement.mm:46-73` — the transliterating feature label
- `platform/ios/test/MLNMapAccessibilityElementTests.m` — the whole automated suite
