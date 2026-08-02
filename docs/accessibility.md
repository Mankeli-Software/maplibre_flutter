# Accessibility — research & design

_Researched 2026-08-01 against the pinned submodule, Flutter 3.44.2 stable (framework `c9a6c48423`,
engine `77e2e94772`) at `/Users/juhotorkkeli/development/flutter`, and maplibre-gl-js `74590c62`.
Every platform-lowering claim is read from engine source; **none has been observed in VoiceOver,
TalkBack, NVDA or Orca.** §9 lists what that leaves uncertain._

> **Build status, 2026-08-02** — on branch `feat/accessibility`. Phase 0 and the Phase 1 locale +
> formatters are **built and tested**; everything from the map node onwards is still design.
> Two things this document said that turned out to be wrong, both caught by a test rather than by
> reading:
>
> 1. **`scrollDown` moves the camera NORTH, so latitude increases** — §7 said it decreases. Flutter
>    documents `onScrollDown` as "a user moving their finger across the screen from top to bottom",
>    and `camera.panBy` takes a finger delta (`maplibre_map_controller.dart`, "does what dragging
>    100 px to the right does"). Both are finger conventions and they agree; the doc had reasoned
>    from viewport motion instead.
> 2. **Annotating an attribution link with `Semantics(link: true)` merges it into the enclosing
>    paragraph**, so a two-link credit became ONE node labelled with the whole line, carrying one
>    tap action — the second link unreachable, the first announcing the wrong URL. `container: true`
>    is required. §5's other in-paragraph annotations need the same treatment.
>
> Sections drafted but **not yet integrated** (kept in `.a11y-pending/`): user populations
> (switch / voice / braille / magnification), map load state, the settle-storm hardening, reduced
> motion for spinning models, colour and contrast, snapshotter/offline/model labels, developer
> experience, Phase 0 rephasing, and the upstream table — the last of which is already written up
> in full at `docs/upstream-apple-a11y-vendor-gate/`.

---

## 1. Why this document exists

**No Flutter map package ships accessible map content. Not one.**

- `google_maps_flutter` exposes no accessibility property at all. flutter/flutter#114895
  ("Setting custom semantic label for each map marker") is **open**, P2, `a: accessibility`,
  no assignee, no PR. On iOS its markers read as a bare "button"; on Android they do not exist.
- `maplibre_gl` and `flutter_map` ship no `Semantics` for map content.
- `googlemaps/android-maps-compose#305` — markers "do not support a custom modifier", so no custom
  screen readouts.
- `react-native-maps#3500` / `#3981` — the same for `<Marker/>` and `<Callout/>`.
- `mapbox/mapbox-gl-native#16128` ("[Android] TalkBack accessibility using markers") was filed,
  never fixed, and archived with the repo on 2023-08-08. **MapLibre Native forked from that repo,
  which is exactly why its Android tree has zero accessibility code today** (§2).

This is not a gap we are behind on. It is a gap nobody has closed, in any framework, on any
platform except one: Apple's `MLNMapView`, which built a real `UIAccessibilityContainer` eight
years ago and then gated the good half of it behind a Mapbox-only check that makes it dead on
every MapLibre style (§2).

Three structural facts make this cheap for us and expensive for everyone else:

1. **`Texture` contributes literally zero semantics.** `packages/flutter/lib/src/rendering/texture.dart`
   and `widgets/texture.dart` contain the string "semantic" exactly **zero** times (VERIFIED by
   `grep -c`). So on macOS, Windows, Linux, iOS-core and Android-core there is nothing to inherit,
   nothing to conflict with, and nothing to work around. We own the whole tree.
2. **Flutter's embedder *is* the accessibility provider.** `io.flutter.view.AccessibilityBridge
   extends AccessibilityNodeProvider`; on iOS it is `SemanticsObject`/`UIAccessibilityElement`; on
   desktop it is `flutter::AccessibilityBridge` over `ax::mojom`; on web it is `<flt-semantics>` +
   ARIA. **One Dart implementation lowers to five assistive-technology stacks.** Android's canonical
   mechanism for this — `ExploreByTouchHelper` over `AccessibilityNodeProvider` — is what MapLibre
   Android *should* have written and did not; we get it for free.
3. **Gestures and camera are already implemented once in Dart** (CLAUDE.md §3). Accessibility can
   be too, and it lands on all five core tiers simultaneously — exactly as `rotateGesturesEnabled`
   did.

Positioning: this project's pitch is that quality and test coverage make adoption credible
(CLAUDE.md §1). Accessible markers, a keyboard-operable map and WCAG-conformant gesture
alternatives are the most legible possible expression of that pitch, because they are *checkable*
by an auditor who has never read our source. And unlike the six-platform render story, this one has
no competitor to be second to.

---

## 2. The state of the art

### The comparison

| | Screen-reader label | Feature exploration | Keyboard | Reduced motion | Gesture alternatives | Localized a11y strings |
| --- | --- | --- | --- | --- | --- | --- |
| **maplibre-gl-js** | `role=region` + `aria-label="Map"` on the `<canvas>`; **default** markers get `aria-label` + `role=img`/`button` | **None** — zero `aria-live` anywhere | Full `KeyboardHandler` (arrows/±/Shift) | `prefers-reduced-motion` + `essential` opt-out | `cooperativeGestures`; **no pan/zoom buttons in `NavigationControl` beyond ±** | 25-key `defaultLocale` patch table |
| **MapLibre Apple SDK** | `MAP_A11Y_LABEL` + computed `accessibilityValue` | **Rich but vendor-gated** — per-place/road/annotation elements, dead outside Mapbox Streets | **None** | **None** | Adjustable zoom only; **no `accessibilityScroll` anywhere** | 18 keys × 24 locales + `.stringsdict` plurals |
| **MapLibre Android SDK** | One static `contentDescription` | **None** | D-pad pans (not a11y-routed) | **None** | **None** | ≤4 keys × 21 translations |
| **Google Maps (Android)** | `setContentDescription`, default `"Google Map"` | **None** (public API) | — | — | — | — |
| **Leaflet** | Container is a focusable `div`; markers are focusable `<a>` with `alt` | Marker-level only (DOM-backed) | Arrows/±/Home | None | Zoom buttons | `aria-label` on controls |
| **Esri ArcGIS JS** | Labelled map region, live "map moved" announcements | Popup-driven, not tab-order | Arrows/± + `Alt` modifiers | Honours `prefers-reduced-motion` | Zoom + compass widgets | Full i18n bundle |
| **Flutter map packages** | **Nothing** | **Nothing** | **Nothing** | **Nothing** | **Nothing** | **Nothing** |

Two rows deserve emphasis. **Every WebGL/native map in this table fails feature exploration** —
rendered map content lives in a GPU texture or a canvas and has no accessibility-tree
representation — except Apple's, which solved it and then made the solution unreachable. And the
Flutter row is empty across the board, which is the opportunity.

### maplibre-gl-js — narrow, precise, and honest about it

VERIFIED at commit `74590c62d98f825d6966dead9e7ae0abe9e74315`.

`_setupContainer()` gives the `<canvas>` exactly three attributes (`src/ui/map.ts:4032-4034`):
`tabindex` = `'0'` when interactive else `'-1'`, `aria-label` = `_getUIString('Map.Title')`
(default the literal `"Map"`), and `role` = `'region'`. Nothing else in the **container** tree gets a
role — the outer `div.maplibregl-map` and the control container are unlabelled divs. That is the
whole map-level story. Markers are the one exception, and they are not an oversight: a **default**
marker gets `aria-label` from `Marker.Title` (`src/ui/marker.ts:398-399`) plus `role=img`, or
`role=button` when it is draggable or carries a popup (`:887-906`). A **custom** marker element gets
nothing, deliberately — see the maintainers' boundary below.

`defaultLocale` (`src/ui/default_locale.ts`) is a flat **25**-entry `Record<string,string>` — a
27-*line* file, which is the easy miscount — and it is the
single source of every AT-visible string; `MapOptions.locale` patches it (`{...defaultLocale,
...resolvedOptions.locale}`) and `_getUIString` **throws** on a missing key — which is precisely
what stops a silently unlabelled control from shipping.

`KeyboardHandler` (`src/ui/handler/keyboard.ts`) is complete and worth copying verbatim:
`panStep: 100` px, `bearingStep: 15`°, `pitchStep: 10`°, `easeTo` over 300 ms with
`easeOut = t => t * (2 - t)`. Pan is expressed as a **negated pixel `offset` with the centre passed
through unchanged** — which is exactly why it stays correct under bearing and pitch. It bails out
entirely if `altKey || ctrlKey || metaKey`, and calls `preventDefault()` **only** on unshifted
arrows, letting OS and browser shortcuts through. Dispatch is on the deprecated `e.keyCode`, so it
is not layout-aware — on a keyboard where `+`/`-` sit elsewhere, zoom silently does not work
(INFERRED consequence; upstream does not discuss it).

Reduced motion is handled at three sites and all three matter:
- `camera.ts:762` — `easeTo` sets `duration = 0`, still firing the full event sequence.
- `camera.ts:1016-1021` — `flyTo` degrades to `jumpTo` carrying **only**
  `center, zoom, bearing, pitch, roll, elevation, padding`. Dropping `offset` is the correctness
  half: a `flyTo` that carried it through would land somewhere else.
- `handler_manager.ts:694-712` — drag inertia is suppressed, but `moveend` still fires and
  snap-to-north still runs.

`AnimationOptions.essential` is the per-call opt-out. `MapOptions.reduceMotion` is a global
override — and it writes a module-global `browser.prefersReducedMotion`, so **two maps on one page
cannot disagree**.

What is absent, VERIFIED by exhaustive grep over `src/`: **no `aria-live`, no `role="status"`, no
`role="alert"`.** Camera position, zoom, bearing, the scale bar, geolocation results and errors are
never announced. The 2021 W3C/Maps4HTML WCAG audit (issue #53) spawned issues #355–#364; **nine of
the ten were closed by a stale-bot rather than by fixes.** Only #359 (attribution disclosure) was
genuinely resolved, by switching to native `<details>/<summary>`. On #364 a commenter wrote "this
issue has been closed but not addressed although it is highly relevant" and the maintainer replied
"You are right, this wasn't addressed."

The maintainers' position is not that accessibility is out of scope but that it is unresourced:
*"I'd be happy to review and merge any PR related to improved accessibility"*, and on funding,
*"maplibre organization does not have a way to fund things"*. The one thing they have declared out
of scope, repeatedly, is the accessibility of **custom marker elements**: *"I don't think we should
handle the case of element that is passed, it's up to the user to handle it"* — codified in
`marker.ts` as *"Custom marker elements are left alone so applications own their a11y tree."*
**That boundary is right and we adopt it** (§5.3).

### MapLibre Apple SDK — the only real implementation, and its self-inflicted wound

This is the deepest prior art anywhere and the model for §5. All line numbers VERIFIED against the
vendored submodule at `packages/maplibre_flutter_core/third_party/maplibre-native/`.

**The map is a container, not a leaf.** `MLNMapView.mm:661-672`:

```objc
  // setup accessibility
  //  self.isAccessibilityElement = YES;      // ← commented out, deliberately
  …                                           // ← :663-668, [MLNNetworkConfiguration sharedManager]
  self.accessibilityLabel = NSLocalizedStringWithDefaultValue(@"MAP_A11Y_LABEL", nil, nil, @"Map", …);
  self.accessibilityTraits =
      UIAccessibilityTraitAllowsDirectInteraction | UIAccessibilityTraitAdjustable;
```

`AllowsDirectInteraction` is what lets a VoiceOver user pan and pinch with real touches.
**Flutter's `SemanticsProperties` has no equivalent member** (VERIFIED against the full member
list), which is why §5.4 must synthesize panning instead of passing touches through.

**The element hierarchy** (`MLNMapAccessibilityElement.h/.mm`) is six classes:
`MLNMapAccessibilityElement` (base; adds `UIAccessibilityTraitAdjustable` and forwards
`accessibilityIncrement`/`Decrement` to its container, so zoom stays reachable from any child) →
`MLNAnnotationAccessibilityElement` (+`TraitButton`, hint `ANNOTATION_A11Y_HINT` = "Shows more
info") · `MLNFeatureAccessibilityElement` (+`TraitStaticText`) → `MLNPlaceFeatureAccessibilityElement`
· `MLNRoadFeatureAccessibilityElement`; plus `MLNMapViewProxyAccessibilityElement`, which is
deliberately **not** a subclass (so it is not adjustable) and exists only while a callout is open.

**The spoken map value** (`MLNMapView.mm:3229-3286`) — VERIFIED verbatim, four facts joined by a
single space:

```objc
double zoomLevel = round(self.zoomLevel + 1);                     // ← note the +1
… @"Zoom %dx."
… @"%ld annotation(s) visible."
for (id<MLNFeature> placeFeature in placeFeatures.reverseObjectEnumerator) {
  NSString *name = [placeFeature attributeForKey:@"name"];        // ← RAW, not name_<lang>
  if (![placesSet containsObject:name]) { [placesArray addObject:name]; [placesSet addObject:name]; }
  if (placesArray.count >= 3) break;                              // ← the cap
}
… @"Places visible: %@."   … @"%ld road(s) visible."
```

Two defects visible in that excerpt. The `+1` makes the spoken zoom disagree with `zoomLevel`
itself. And the summary reads the **raw** `name` while element labels read the localized,
transliterated `name_<lang>` (`MLNMapAccessibilityElement.mm:52-64`) — so the same place is
announced under two different names.

**The road describer** (`MLNMapAccessibilityElement.mm:130-203`) is the single most portable piece,
VERIFIED verbatim: `ref` → `ROAD_REF_A11Y_FMT` = `@"Route %@"` (with a live
`// TODO: Decorate the route number with the network name based on the shield attribute.` — `shield`
is read nowhere); `oneway == @"true"` → `ROAD_ONEWAY_A11Y_VALUE` = `@"One way"`; an
`MLNMultiPolylineFeature` → `ROAD_DIVIDED_A11Y_VALUE` = `@"Divided road"`; then
`MLNDirectionBetweenCoordinates(coordinates[pointCount-1], coordinates[0])` and its reverse, each
formatted by `MLNCompassDirectionFormatter` at `NSFormattingUnitStyleLong`, into
`ROAD_DIRECTION_A11Y_FMT` = `@"%@ to %@"`. Its own test asserts two exact strings, on two different
fixtures: `"Route 42, One way, southwest to northeast"` (`MLNMapAccessibilityElementTests.m:69`, a
single `MLNPolylineFeature` carrying `ref` **and** `oneway`) and
`"Route 42, Divided road, southwest to northeast"` (`:85`, an `MLNMultiPolylineFeature` whose own
attributes are `ref` **only**). The facts append in order — ref → oneway → divided → direction — so
the two fixtures are not interchangeable (§7).

**The query-and-dedupe algorithm**, which §5.2 ports:

1. `visiblePlaceFeatures` / `visibleRoadFeatures` (`MLNMapView.mm:3288-3306`) lazily cache
   `[self visibleFeaturesInRect:self.bounds inStyleLayersWithIdentifiers:<set>]` — the **full
   viewport, with no cap of any kind.**
2. The layer set comes from `MLNStyle.placeStyleLayers` / `roadStyleLayers`
   (`MLNStyle.mm:615-644`), hardcoded to `{marine_label, country_label, state_label, place_label,
   water_label, poi_label, rail_station_label, mountain_peak_label, natural_label,
   transit_stop_label}` and `{road_label, road}`.
3. Element reuse (`MLNMapView.mm:3512-3612`) matches an existing element whose `feature.identifier`
   is non-nil, not `@0`, and equal — which is what keeps VoiceOver focus from jumping on every
   re-query.
4. Ordering (`MLNMapView.mm:3376-3396`) sorts each category by euclidean pixel distance from
   `contentCenter` (or `userLocationAnnotationViewCenter` when tracking):
   `hypot(pointA.x - centerPoint.x, pointA.y - centerPoint.y)`. **This full `std::sort` is re-run on
   every single `accessibilityElementAtIndex:` and `indexOfAccessibilityElement:` call** — O(n² log n)
   for one traversal, with an mbgl projection per comparison.
5. Cache invalidation happens in exactly one place (`MLNMapView.mm:6795-6832`), guarded by
   `if ((respondsToSelector || respondsToSelectorWithReason) && applicationState == Active)` — **so
   if the host app's delegate implements neither `mapView:regionDidChangeAnimated:` nor
   `mapView:regionDidChangeWithReason:animated:`, the caches are never cleared and stale elements
   survive an arbitrary pan.** A genuine upstream defect.

**And then the gate that kills it.** `MLNVectorTileSource.mm:191-199`, VERIFIED verbatim:

```objc
- (BOOL)isMapboxStreets {
  NSURL *url = self.configurationURL;
  if (![url.scheme isEqualToString:@"mapbox"]) { return NO; }
  NSArray *identifiers = [url.host componentsSeparatedByString:@","];
  return [identifiers containsObject:@"mapbox.mapbox-streets-v8"] ||
         [identifiers containsObject:@"mapbox.mapbox-streets-v7"];
}
```

`placeStyleLayers` first restricts to sources passing that test. **On MapLibre demotiles,
OpenMapTiles, Protomaps or any raster style, both arrays are empty, zero place/road elements are
produced, and `accessibilityValue` collapses to "Zoom Nx."** The most advertised part of this
implementation is dead on every style a MapLibre user actually loads. We do not port this gate; it
is the single strongest argument for app-supplied layer configuration (§5.2).

**Adjustable zoom** (`MLNMapView.mm:3750-3771`), VERIFIED:

```objc
- (void)accessibilityIncrement { [self accessibilityScaleBy:0.5]; }   // "Swipe up to zoom out."
- (void)accessibilityDecrement { [self accessibilityScaleBy:2]; }     // "Swipe down to zoom in."
- (void)accessibilityScaleBy:(double)scaleFactor {
  …                                            // ← :3761-3764, centerPoint = contentCenter, or the
                                               //   user-location centre while tracking
  double newZoom = round(self.zoomLevel) + log2(scaleFactor);
  self.mbglMap.jumpTo(mbgl::CameraOptions().withZoom(newZoom).withAnchor(…));
  …                                            // ← :3768, [self unrotateIfNeededForGesture]
  _accessibilityValueAnnouncementIsPending = YES;
}
```

Two details worth copying exactly: it snaps to an **integer** zoom, so repeated swipes land on clean
levels instead of drifting; and it sends `withAnchor` **without** `withCenter`, which is the only
reason it works at all — CLAUDE.md §11 records that `CameraOptions::anchor` is silently discarded
whenever `center` is set. One detail worth **not** copying: increment = zoom out (§5.1).

**The deferred announcement.** The pending flag is consumed in `cameraDidChangeAnimated:`, which
calls `announceAccessibilityValue` via `performSelector:withObject:afterDelay:0.1` — a deliberate
100 ms debounce so the query sees settled tiles — posting
`UIAccessibilityAnnouncementNotification` then `UIAccessibilityLayoutChangedNotification`.
Announcements fire **only** after an AT-driven zoom, never after a gesture pan. That restraint is
correct and §5.7 keeps it.

**Minimum element size** is `MLNAnnotationAccessibilityElementMinimumSize = CGSizeMake(10, 10)`
(`MLNMapView.mm:316`) — below every modern guideline. And at `:3535-3536` the place-feature path
passes `.width / 2` for **both** insets, so a non-square minimum would be applied wrong; harmless
today because it is square, latent otherwise.

**What Apple does not have**, VERIFIED by repo-wide grep returning zero matches:
`accessibilityScroll` (so VoiceOver three-finger pan is simply not implemented anywhere),
`accessibilityCustomActions`, `UIAccessibilityCustomRotor`, `accessibilityPerformEscape`,
`accessibilityPerformMagicTap`. Bearing and pitch have **no** accessibility affordance at all.
`MLNScaleBar` contains zero accessibility code and is absent from the container enumeration, as is
the logo view (whose label is still the string `"Mapbox"`). Automated coverage is one 88-line
XCTest exercising three formatter classes in isolation — nothing tests enumeration, ordering, the
adjustable zoom, the announcement path or cache invalidation.

**macOS has nothing.** A grep for `NSAccessibility` across all of `platform/macos/` returns **zero
matches**; the single accessibility line in the entire macOS SDK is one `accessibilityTitle` on the
logo view.

### MapLibre Android SDK — three strings

VERIFIED: a grep of the entire `platform/android` tree for `AccessibilityNodeProvider`,
`ExploreByTouchHelper`, `announceForAccessibility` and `AccessibilityNodeInfo` returns **zero
matches**. The only occurrence of the word "accessibility" in the Kotlin/Java sources is the comment
`// add accessibility support` above `MapView.java:141`.

What exists is three `setContentDescription` calls (`MapView.java:141`, `:206`, `:221`):
- the map — *"Showing a Map created with MapLibre. Scroll by dragging two fingers. Zoom by pinching
  two fingers."*, set once and **never recomputed** for zoom, centre or bearing;
- the compass — *"Map compass. Activate to reset the map rotation to North."* `CompassView.update(bearing)`
  calls `setRotation` but not `setContentDescription`, so TalkBack can never say which way the map faces;
- the attribution icon.

The logo `ImageView` gets no label and is not marked decorative;
`maplibre_logoContentDescription` is declared `<public>` in `res-public/values/public.xml:86` with
**no backing string resource anywhere**. `maplibre_myLocationViewContentDescription` is translated
into all 21 of the SDK's translation locales (`res/` holds 22 `values*` directories: the default plus
bg ca cs es fr gl he hu iw ko lt nl pl pt-rPT ru sv uk vi zh-rCN zh-rHK zh-rTW) and referenced from
nowhere — dead since the puck became mbgl style layers rather
than an Android `View`. Markers carry `title`/`snippet`, documented as "A String used in the marker
info window", wired to no accessibility API.

**This is our ceiling on the `maplibre_flutter_android_sdk` tier and it cannot be raised from
here.** Worse, `ExploreByTouchHelper` — the right mechanism — throws
`"Views cannot have both real and virtual children"`, and MapLibre's `MapView` is a `FrameLayout`
whose real children are the compass, attribution and logo views. Adopting it upstream would require
restructuring.

---

## 3. What the standards require

### The two a map fails by default

**WCAG 2.2 SC 2.5.1 Pointer Gestures (Level A)** — *"All functionality that uses multipoint or
path-based gestures for operation can be operated with a single pointer without a path-based
gesture, unless … essential."* The Understanding document names our case, verbatim: *"A website
includes a map view that supports the pinch/spread gesture to zoom into the map content. As a
single-pointer alternative, the map also includes plus/minus buttons to zoom in and out."*
**Pinch-zoom, two-finger rotate and two-finger shove are all multipoint.** Drag-pan is not (only net
displacement matters), so it is a 2.5.7 problem instead.

**WCAG 2.2 SC 2.5.7 Dragging Movements (Level AA)** — the Understanding document's example is
verbatim ours: *"A map allows users to drag the view of the map around, and the map has
up/down/left/right buttons to move the view as well."* The user-agent carve-out does **not** apply,
because we implement panning ourselves rather than letting a scroller do it.

**Neither is discharged by keyboard support or by semantics.** They are pointer criteria. The only
conforming answer is real, visible, single-pointer control widgets — which is why §5.5 defaults them
on, and why this is the one part of the design that no amount of `Semantics` can substitute for.

### The rest, and who owns each

| Criterion | Level | Package ships | App owns |
| --- | --- | --- | --- |
| 1.1.1 Non-text Content | A | Map label, control labels, puck label, decorative chrome excluded | Marker labels; a text alternative for its data |
| 1.3.1 Info and Relationships | A | One semantics container over map + controls + attribution + markers | Relating its own legend/list to the map |
| 1.4.1 Use of Color | A | No shipped chrome encodes state by colour alone | The style; category-by-colour convenience macros |
| 1.4.3 Contrast (Minimum) | AA | Chrome contrast (the attribution bar's translucent background is a current failure) | **Map label contrast — we cannot fix it** |
| 1.4.4 Resize Text | AA | Chrome honours `textScaler` | **Map labels do not scale — mbgl rasterises them** |
| 1.4.10 Reflow | AA | Collapsible controls + wrapping attribution fit 320 px | — |
| 1.4.11 Non-text Contrast | AA | Icons, focus ring, puck ≥3:1 | Style symbology |
| 2.1.1 Keyboard | A | Full gl-js binding table over `controller.camera` | Not swallowing keys around the map |
| 2.1.2 No Keyboard Trap | A | Tab/Shift-Tab/Escape always pass through | — |
| 2.1.4 Character Key Shortcuts | A | `+`/`-`/`=` are **focus-scoped**, never global — satisfies the active-on-focus-only exception | — |
| 2.4.7 Focus Visible | AA | Keyboard-only focus ring (gl-js ships none) | — |
| 2.4.11 Focus Not Obscured | AA | `showOnScreen` pans focused nodes clear of shipped chrome | Its own overlays |
| 2.5.1 Pointer Gestures | A | **Control cluster, default on** | Its own multipoint gestures |
| 2.5.2 Pointer Cancellation | A | Already compliant — `onTapUp` at `maplibre_map.dart:559` | — |
| 2.5.7 Dragging Movements | AA | **Pan pad; non-drag path for draggable markers** | Its own drags |
| 2.5.8 Target Size | AA | Controls ≥48 px; a11y nodes inflated to 44 px | — |
| 4.1.2 Name, Role, Value | A | The map node; control state | Anything it draws over the map |
| 4.1.3 Status Messages | AA | Not engaged by default (deliberate); opt-in announcements | Its own async status |

Two notes. **SC 2.5.8 explicitly exempts map pins**: *"in digital maps, the position of pins is
analogous to the position of places shown on the map … It is essential to show the pins at the
correct map location, therefore the Essential exception applies."* So we do not distort marker
geometry — but every *control* we ship is in scope. And **SC 2.5.4 Motion Actuation is not
applicable** (we bind no device-motion input), which is worth stating rather than leaving blank,
because a map is exactly where an auditor looks for tilt-to-pan.

### Legal drivers

- **EN 301 549** (clause 9 web, clause 11 software/mobile) is the harmonised standard behind both
  instruments below. Clause **11.7 User preferences** is what makes reduced motion a legal item
  rather than a nicety.
- **European Accessibility Act** — applies from **28 June 2025**.
- **ADA Title II final rule** (US) — WCAG 2.1 AA for state/local government web content **and mobile
  apps**, by **26 April 2027** (large entities) / **2028** (small).[^ada]

[^ada]: These are the dates **as amended by the DOJ interim final rule of April 2026**, which pushed
    each deadline out by a year. The original 2024 rule said 2026/2027, so a reader checking against
    a stale secondary source will find the earlier pair and "correct" these back. Do not.

The much-cited "maps exemption" in the Web Accessibility Directive is narrow: it exempts the map
surface only where *"essential information is provided in an accessible digital manner"* — i.e. it
requires the accessible-alternative pattern (§5.8), it does not excuse its absence. Ordnance
Survey's own election-maps statement declares its map a **2.1.1 keyboard failure** rather than
claiming the exemption.

### The independent evidence

The W3C/OGC Maps for the Web workshop evaluation of eleven web mapping tools
(`Malvoz/web-maps-wcag-evaluation`) found **universal 4.1.2 failure**, near-universal 1.3.1 failure,
**9 of 11 failing 1.4.3 on map label contrast** (consistently ocean and water labels — only the two
Mapbox GL entries passed), and **6 of 11 failing 2.1.1**. The workshop report concluded: *"none of
the evaluated Web mapping frameworks meet all the WCAG 2.1 success criteria."*

---

## 4. Where we stand today

**Nothing. Verified, not estimated.**

```
$ grep -rn "Semantics\|semanticLabel\|excludeFromSemantics\|SemanticsService\|ExcludeSemantics" \
    packages/*/lib packages/*/example/lib
(no output)
```

Zero matches across every package's library and the example app. No `Semantics`, no
`MergeSemantics`, no `ExcludeSemantics`, no `SemanticsService.announce`, no `semanticLabel`.

Keyboard: **one** reference in the entire tree —
`packages/maplibre_flutter/lib/src/maplibre_map.dart:1571`,
`HardwareKeyboard.instance.isControlPressed`, used solely to detect ctrl+drag as a rotate modifier.
No `Focus`, no `FocusNode`, no `Shortcuts`, no `Actions`, no `FocusableActionDetector`, no arrow-key
pan. **The map is unreachable by keyboard on all four desktop tiers and on web.**

Reduced motion: `grep -rn "disableAnimations" packages/*/lib` returns **zero** (unscoped, `packages/`
returns three hits, all of them inside the example's committed `build/web/main.dart.js`). The only
`MediaQuery` reads in library code are `devicePixelRatioOf` at `maplibre_map.dart:658` and a
synthetic `MediaQueryData` for widget rasterization at `map_style_controller.dart:1215`.

Localization: **zero `.arb` files, zero `intl`, zero `flutter_localizations`, no `l10n.yaml`.** Any
accessibility label would be this package's first user-facing translatable string.

Specific latent problems, with evidence:

- **Attribution links carry no link role.** `attribution_bar.dart:97-111` renders each as a bare
  `GestureDetector` inside a `WidgetSpan`. The node itself is already there and already tappable:
  `excludeFromSemantics` defaults `false` (`widgets/gesture_detector.dart:299`), so
  `RenderSemanticsGestureHandler` publishes `config.onTap` (`rendering/proxy_box.dart:4212-4213`),
  and `RenderParagraph.assembleSemanticsNode` really does walk `PlaceholderSpanIndexSemanticsTag`
  children (`rendering/paragraph.dart:1322-1335`) — so each link reaches the tree with
  `SemanticsAction.tap`, labelled by its inner `Text`. What is missing is the **role**: no
  `link: true`, no `linkUrl:`, both of which `SemanticsProperties` already has, so a screen reader
  announces a tappable run of text and never the word "link". The genuinely inert case is narrower:
  with no `onAttributionTap`, `_spansFor` returns a plain `TextSpan` (`:85-88`) and there is no node
  at all. Attribution reachability is a **licence** condition, and a texture-rendered map has no DOM,
  so this widget is the only copy that exists.
- **The user-location puck is silent.** `user_location_puck.dart:46-58` is `IgnorePointer` over a
  `CustomPaint`. `IgnorePointer` does not exclude semantics — there simply are none. Position,
  accuracy and heading are conveyed by colour and shape alone.
- **The `Flow` cull would become an a11y bug.** `marker_overlay.dart:242` and `:262-268` `continue`
  without calling `paintChild`, and `RenderFlow` does not override `visitChildrenForSemantics` while
  `applyPaintTransform` returns identity for an unpainted child. So the moment any marker child has
  semantics, **every culled marker reports a node at the overlay's layout origin** — a screen reader
  reading out a pile of off-screen markers stacked at (0,0). This is CLAUDE.md §11's
  `Flow`-reports-the-layout-origin trap, in the semantics tree.
- **No ornaments exist.** No compass, no scale bar, no zoom buttons.
  `docs/api-parity-binding-spec.md:355` classifies them P3, not implemented. The *action* is already
  wired: `camera.resetNorth()` (`maplibre_map_controller.dart:849`) already reports
  `MapCameraChangeReason.resetNorth` — "the one 'programmatic' move a USER asked for."

### Which tiers could inherit native accessibility

| Tier | Handle | Native a11y underneath | Verdict |
| --- | --- | --- | --- |
| macOS / Windows / Linux (core) | `TextureHandle` | **None** — `Texture` has zero semantics | We own it entirely |
| iOS / Android **core** (default) | `TextureHandle` | **None** | We own it entirely |
| Web **core-WASM** (default) | `ElementViewHandle` | **None** — bare `<canvas>`, no `tabindex`/`role`/`aria-label`; the C++ shim registers only mousedown/mousemove/mouseup/wheel, **no keydown** | We own it — and it is *mouse-only* today |
| Web **gl-js** (opt-in) | `ElementViewHandle` | **Yes** — canvas ARIA + `KeyboardHandler` | Defer to it |
| Android **SDK** (opt-in) | `PlatformViewHandle` | One `contentDescription` | Augment as siblings |
| iOS **SDK** (opt-in) | `PlatformViewHandle` | **Rich** `UIAccessibilityContainer` | Defer to it |

**The two `ElementViewHandle` tiers are opposite cases, and so are the two `PlatformViewHandle`
tiers.** Branching on the handle *type* is therefore wrong; §5 resolves this with a flag on the
handle itself.

`mbgl-core` has no notion of accessibility anywhere — every SDK implements it in the platform layer
we replaced with Dart. There is nothing to bind and no C ABI to add.

---

## 5. The design

**Guiding decision: this needs no new capability interface and no new C ABI.** Everything is built
on `controller.camera` (so it degrades by capability across all nine tiers rather than being
texture-only), `MapLibreMapProjector`, `MapLibreStyleLayers` and `MapLibreCameraCommands`. The
single platform-interface change is one defaulted field on the existing sealed render handle,
forwarded through all three of its subclass constructors (§5.11). CLAUDE.md §3: *churn in the
contract is the most expensive kind.*

### 5.0 The Android collision that constrains everything

**VERIFIED in `AccessibilityBridge.java`, and it invalidates the obvious design.**

Node construction, `:1089-1105`:

```java
if (semanticsNode.hasAction(Action.SCROLL_LEFT) || semanticsNode.hasAction(Action.SCROLL_UP)) {
  result.addAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD);
}
…
if (semanticsNode.hasAction(Action.INCREASE) || semanticsNode.hasAction(Action.DECREASE)) {
  result.setClassName("android.widget.SeekBar");
  if (semanticsNode.hasAction(Action.INCREASE)) {
    result.addAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD);   // ← the same action
  }
```

Dispatch, `:1326-1342`:

```java
case AccessibilityNodeInfo.ACTION_SCROLL_FORWARD:
  if (semanticsNode.hasAction(Action.SCROLL_UP))        → SCROLL_UP
  else if (semanticsNode.hasAction(Action.SCROLL_LEFT)) → SCROLL_LEFT
  else if (semanticsNode.hasAction(Action.INCREASE))    → INCREASE
```

Three actions collapse onto one Android action, and dispatch is a first-match chain. Consequences,
in order of severity:

1. **A node carrying both `onScrollUp` and `onIncrease` makes zoom unreachable on Android.**
   SCROLL_UP wins; INCREASE is never dispatched. The obvious design — one map node with adjustable
   zoom *and* four-way scroll panning — is **silently broken on Android**, and a widget test that
   asserts both actions are present would pass while the feature is dead on device. This is exactly
   the §7 "a frame came back" failure mode, in accessibility.
2. `onScrollLeft` and `onScrollUp` cannot coexist either. Flutter's own dartdoc on
   `SemanticsProperties.onScrollLeft` says so, typo and all: *"On Android, [onScrollUp] and
   [onScrollLeft] share the same gesture. Therefore, only on of them should be provided."*

**Resolution.** On Android the map node exposes `onIncrease`/`onDecrease` **only** — zoom is the more
valuable adjustable, and it is the one Apple chose. All panning on Android goes through
`CustomSemanticsAction`s, which TalkBack surfaces in its local context menu without collision. On
iOS, macOS, Windows, Linux and web the map node exposes all four scroll actions **and** increase /
decrease, because those platforms map them to distinct AX actions
(`shell/platform/common/accessibility_bridge.cc:395-412`: `kScrollLeft`/`kScrollRight`/`kScrollUp`/
`kScrollDown`/`kIncrement`/`kDecrement`). The custom actions are emitted **everywhere**, so the
platform branch changes only what is redundant, never what is reachable.

This is a `defaultTargetPlatform` branch inside the widget — the second one, not an exception:
`_PlatformView.build` already switches on it (`maplibre_map.dart:712-725`), and CLAUDE.md §3 does not
forbid the pattern. It belongs there because it is a **Flutter engine fact, not a renderer fact** —
it would be identical on a platform view — so it does not belong behind the platform interface.

### 5.1 The map node

```dart
@immutable
class MapLibreSemantics {
  const MapLibreSemantics({
    this.enabled = true,
    this.label,                       // defaults to locale['Map.Title'] == 'Map'
    this.hint,
    this.identifier = 'maplibre.map',
    this.value = const MapSemanticsValue.cameraSummary(),
    this.markers = MapMarkerSemantics.childOwned,
    this.features = const MapFeatureSemantics.none(),
    this.announcements = MapSemanticsAnnouncements.accessibilityActions,
    this.maxNodes = 32,
    this.minimumTargetSize = const Size(44, 44),
    this.scrollStep = 0.5,            // fraction of the viewport per AT scroll
    this.zoomStep = 1.0,
    this.settleDelay = const Duration(milliseconds: 100),
    this.chromeInsets,                // null ⇒ derived from the shipped controls
  });
  const MapLibreSemantics.excluded() : this(enabled: false);
}

enum MapMarkerSemantics { childOwned, synthesized, excluded }
enum MapSemanticsAnnouncements { never, accessibilityActions, always }

sealed class MapSemanticsValue {
  // A redirecting factory may not carry defaults, so they live on the target.
  const factory MapSemanticsValue.cameraSummary({
    bool zoom, bool center, bool bearing, bool pitch, bool markerCount,
  }) = MapCameraSummaryValue;
  const factory MapSemanticsValue.custom(MapSemanticsSummaryBuilder builder) = MapCustomValue;
  const factory MapSemanticsValue.none() = MapNoValue;
}

final class MapCameraSummaryValue extends MapSemanticsValue {
  const MapCameraSummaryValue({
    this.zoom = true, this.center = false, this.bearing = false,
    this.pitch = false, this.markerCount = true,
  });
  final bool zoom, center, bearing, pitch, markerCount;
}

typedef MapSemanticsSummaryBuilder =
    String Function(MapSemanticsSummary summary, MapLibreLocale locale);

@immutable
class MapSemanticsSummary {
  const MapSemanticsSummary({
    required this.camera, required this.viewport,
    required this.visibleMarkerCount, required this.features,
  });
  final MapCamera camera;
  final Size viewport;
  final int visibleMarkerCount;
  final List<MapSemanticFeature> features;
  String describe(MapLibreLocale locale);
}

// on MapLibreMap
final MapLibreSemantics semantics;   // default const MapLibreSemantics()
```

**Bucket: widget prop** — mutable, declarative, low-frequency (three-bucket rule). It cannot go in
`MapOptions`: that is init-only and handed to `createMap`, so it never reaches the widget layer
where every string is consumed. Same reason `rotateGesturesEnabled` is a widget prop
(`maplibre_map.dart:118-122`).

**Upstream:** `label`/`hint`/`identifier`/`value`/`excluded` from Flutter's own `SemanticsProperties`
(§9's rule: boundary value types come from Flutter). `describe` ports
`-[MLNMapView accessibilityValue]`. The container name has no upstream — no upstream ships an
accessibility options bundle.

Rendered as `Semantics(container: true, explicitChildNodes: true, label:, value:, hint:,
identifier:, increasedValue:, decreasedValue:, onIncrease:, onDecrease:, onScroll*:,
customSemanticsActions:, role: SemanticsRole.region)` wrapping the **outer** Stack — above both
existing Stacks, so controls, attribution and markers become children of one map region. That is
WCAG 1.3.1, and it is precisely gl-js issue #364 (closed stale, maintainer-confirmed unaddressed):
they put the attributes on the `<canvas>`, we have a container and can do it right on day one.

**`SemanticsRole.region` constrains `label`, and that is a rule, not a default.**
`_DebugSemanticsRoleChecks._semanticsRegion` (`semantics.dart:548-557`) errors on
`data.label.isEmpty` — *"A region role should include a label that describes the purpose of the
content."* So `label` must never *resolve* to empty: `null` falls back to `locale['Map.Title']`, and
an app passing `''` must fall back too rather than pass through, or the frame throws in debug. The
region role and a labelless map are mutually exclusive by construction.

**Three deliberate divergences from Apple, each with a reason:**

1. **Increase = zoom IN**, the opposite of `accessibilityIncrement → accessibilityScaleBy:0.5`.
   Flutter asserts `(value == '') == (increasedValue == '')` at `semantics.dart:3756`, so a spoken
   `value` of "Zoom 12" with `increasedValue` "Zoom 13" must mean zoom in, or the announced value
   contradicts the action. Apple's value is a magnification factor, ours is a zoom level.
2. **No `+1` on the spoken zoom.** Apple's `round(self.zoomLevel + 1)` makes the spoken number
   disagree with its own `zoomLevel` property; ours agrees with `getCamera().zoom`.
3. **Zoom snaps to an integer**, which Apple *does* do (`round(zoomLevel) + log2(scaleFactor)`) and
   which we copy — repeated swipes land on clean levels instead of drifting. Routed through
   `camera.zoomTo(z, around: centre)`, which never sets a centre, so CLAUDE.md §11's
   anchor-discard trap does not fire.

The `value` is recomputed on **camera settle**, never on the 60–120 Hz `onCameraChanged`
`Listenable` — which is why that signal is a `Listenable` and not a `Stream` in the first place
(§9 adaptation #1).

### 5.2 Virtual feature nodes

```dart
@immutable
class MapFeatureSemantics {
  const MapFeatureSemantics({
    required this.layerIds,
    this.labelProperties = const ['name:{lang}', 'name_{lang}', 'name'],
    this.describe,
    this.maxNodes = 32,
    this.onTap,
  });
  const MapFeatureSemantics.none() : this(layerIds: const <String>[]);
}

typedef MapFeatureDescriber =
    MapSemanticFeature? Function(QueriedFeature feature, String layerId);

@immutable
class MapSemanticFeature {
  const MapSemanticFeature({required this.label, this.value, this.hint, this.point});
}

// pure, exported, device-free testable:
MapSemanticFeature? describeMapLibreFeature(
  QueriedFeature feature, String layerId, MapLibreLocale locale,
  {List<String> labelProperties});
```

**Bucket: widget prop.** **Upstream:** `layers` / `accessibleLabelProperty` from mapbox's out-of-tree
`mapbox-gl-accessibility` plugin (the only documented pattern for making rendered features
reachable); the describer's fact lists port `MLNPlaceFeatureAccessibilityElement` and
`MLNRoadFeatureAccessibilityElement`. `labelProperty` → `labelProperties` because OpenMapTiles uses
`name:en` (colon) and Mapbox uses `name_en` (underscore) and one list covers both.

**`layerIds` is required and there is no default allowlist. This is the central decision of §5.2.**
Apple's allowlist is hardcoded to Mapbox Streets source-layer names *behind the `isMapboxStreets`
gate*, so shipping a default would either reproduce a feature that is dead on every MapLibre style,
or guess at a schema and announce wrong names. **A wrong announcement is worse than silence.**

Rejected alternative, for the record: automatic discovery by scanning for symbol layers with a
`text-field`. It works on any style, but it costs one `getLayer()` shim round trip per layer (200 on
a real style) on the UI isolate at exactly the moment the map becomes interactive, and it happily
picks up decorative and hidden layers. Also rejected: declaring the role in each layer's style-spec
`metadata` — elegant, needs no generator change, but depends on mbgl's `Layer::serialize()`
round-tripping unknown metadata keys, which is **unverified**. Both are recorded in §9 as future
options, not shipped.

**The pipeline**, ported from Apple with its two defects removed:

1. Triggered on `onCameraMoveEnd`/`onIdle`, debounced by `settleDelay` (Apple's exact 100 ms), and
   **gated on `SemanticsBinding.instance.semanticsEnabled`** — so it does nothing at all when no
   assistive technology is running.
2. One `queryRenderedFeaturesAsync` **per layer id**, because `QueriedFeature` carries no layer id —
   `RenderOrchestrator::queryRenderedFeatures` flattens per-layer results inside the engine
   (`platform_interface/lib/src/geojson/feature.dart:125-131`). Querying per layer is also what lets
   `describe` receive the layer id, which is what a schema switch actually needs.
3. Dedupe on `feature.id` when present and non-zero (Apple's rule verbatim), else on
   `(label, layerId)`. Among duplicates the segment nearest the viewport centre wins. Apple gets the
   id half accidentally via last-write-wins and has no fallback, which matters because OpenMapTiles
   road features frequently carry no id.
4. **Cap at `maxNodes` (32).** Apple caps nothing — `visibleFeaturesInRect:` is unbounded and a dense
   POI style yields hundreds of swipe targets, which in Flutter is hundreds of real semantics nodes.
5. Sort by euclidean distance from the viewport centre (Apple's `hypot`), computed **once per
   settle and cached** — not re-sorted per element access as Apple does.
6. Emitted from **one zero-paint `CustomPainter.semanticsBuilder`**, each node keyed
   `ValueKey(feature.id ?? '$layerId/$label')`. `RenderCustomPaint`'s reconciliation *moves* keyed
   nodes rather than recreating them, so a feature surviving a pan keeps its `SemanticsNode` and AT
   focus does not jump mid-read — the same guarantee Apple's `_featureAccessibilityElements` cache
   buys, and the one it loses whenever the host app omits a delegate method.
7. Rects inflated to `minimumTargetSize` (44×44, not Apple's 10×10).

**Feature nodes are opt-in.** Roads degrade: `SemanticsNode` exposes `rect` + `transform` and no
path, so Apple's stroked `accessibilityPath` becomes a single point sample. Explore-by-touch along a
motorway will not work. Documented, not hidden.

### 5.3 Markers

```dart
// added to MapLibreMarker
final String? semanticLabel;      // ← MLNAnnotation.title
final String? semanticValue;      // ← MLNAnnotation.subtitle
final String? semanticHint;       // ← ANNOTATION_A11Y_HINT, 'Shows more info'
final VoidCallback? onTap;
final double keyboardDragStep;      // 1 logical px
final double keyboardDragStepLarge; // 10 with Shift
```

**Bucket: widget prop.** **Upstream:** Apple's title/subtitle/hint split, under Flutter's universal
`semanticLabel` spelling (`Image.semanticLabel`, `Icon.semanticLabel`).

`MapMarkerSemantics.childOwned` is the default and means **we never wrap a user child in a labelling
`Semantics`.** That is gl-js's stated boundary — and note it is a boundary, not an absence: gl-js
labels the markers it draws itself (`marker.ts:398-399`, `:887-906`) and declines only the ones the
app supplies, *"Custom marker elements are left alone so applications own their a11y tree"*. Every
`MapLibreMarker` is app-supplied, so `childOwned` is that rule applied to a package where the custom
case is the only case — and it is stronger in Flutter than in the DOM: not-wrapping beats
not-clobbering. `.synthesized`, the analogue of gl-js's default-marker labelling, opts into a node
emitted from the shared `CustomPainter`; `.excluded` is for decorative pins.

**In both modes, culled markers are wrapped in `ExcludeSemantics`.** Without this the §4 `Flow`
layout-origin trap fires and off-screen markers pile up at (0,0). The visible set is computed on
settle and only `setState`s when the *set* changes, and only while semantics are enabled.

Marker keyboard/AT dragging is the WCAG 2.5.7 discharge: arrow keys move a focused draggable marker
1 px (10 with Shift), firing the same `onDragStart`/`onDragUpdate`/`onDragEnd` sequence as a pointer
drag, plus four "Move north/south/east/west" custom actions. The arrow must be consumed so it does
**not** also pan the map — gl-js issue #8046 documents exactly that double-action trap. This closes
gl-js's open #8020 (two competing PRs, #8045 and #8022, both unmerged as of 2026-08-01) before they
do.

### 5.4 Keyboard model

```dart
@immutable
class MapGestureSettings {
  const MapGestureSettings({
    this.interactive = true,
    this.scrollGesturesEnabled = true,
    this.zoomGesturesEnabled = true,
    this.rotateGesturesEnabled = true,
    this.tiltGesturesEnabled = true,
    this.keyboardEnabled = true,
    this.keyboardRotateEnabled = true,
    this.cooperativeGestures = MapCooperativeGestures.whenScrollable,
    this.respectReduceMotion = true,
    this.panStep = 100.0,       // gl-js KeyboardHandler defaultOptions
    this.bearingStep = 15.0,
    this.pitchStep = 10.0,
  });
}
enum MapCooperativeGestures { disabled, whenScrollable, enabled }

// on MapLibreMap
final MapGestureSettings gestures;
final FocusNode? focusNode;
final bool autofocus;

@Deprecated('Moved to MapGestureSettings.rotateGesturesEnabled.') final bool rotateGesturesEnabled;
@Deprecated('Moved to MapGestureSettings.tiltGesturesEnabled.')   final bool tiltGesturesEnabled;
```

**Bucket: widget prop.** **Upstream:** `interactive` / `keyboard` / `cooperativeGestures` /
`panStep` / `bearingStep` / `pitchStep` from gl-js; the `…GesturesEnabled` suffix from Android
`UiSettings` per §9 — including `keyboardEnabled` and `keyboardRotateEnabled`, which is §9's
explicit "where Android's toggle is coarser than the gestures we recognise, split it with the same
suffix, never a gl-js handler name" (gl-js spells these
`KeyboardHandler.disableRotation()`/`enableRotation()`).

`docs/api-parity-binding-spec.md:3040` already blessed a `MapGestureSettings` **container**, and the
container is what we keep. **Its field names we do not: this section supersedes them.** That row is
gl-js-flavoured end to end — `dragPan`, `dragRotate`, `scrollZoom`, `boxZoom`, `touchZoomRotate`,
`keyboard`, and `cooperativeGestures` as a `bool` defaulting `false` — and `keyboardRotate` is not
even on it (that is `:3233`). CLAUDE.md §9 settles the disagreement in advance and in favour of
Android `UiSettings`: the `…GesturesEnabled` suffix wins, and *"where Android's toggle is coarser
than the gestures we actually recognise, split it with the same `…Enabled` suffix; never mix in a
gl-js handler name."* So `dragPan` → `scrollGesturesEnabled`, `scrollZoom` → `zoomGesturesEnabled`,
`keyboard` → `keyboardEnabled`, `keyboardRotate` → `keyboardRotateEnabled`, and `cooperativeGestures`
becomes the tri-state `MapCooperativeGestures.whenScrollable` for the reason in §5.5. `panStep` /
`bearingStep` / `pitchStep` are new here — gl-js `KeyboardHandler` constants, with no Android
counterpart to collide with. **The spec row is the stale one and should be updated in the same
change**, or the names really do get invented twice. The two existing flat props land with
`@Deprecated` aliases for one release, per §9's rename discipline.

Bindings copied verbatim from gl-js: arrows pan 100 logical px as a **pixel offset** (so it stays
correct under bearing and pitch), `Shift`+left/right rotate ∓15°, `Shift`+up/down pitch ±10°,
`=`/`+`/numpadAdd zoom +1 (Shift +2), `-`/numpadSubtract zoom −1 (Shift −2), 300 ms with ease-out
`t*(2-t)` — a bespoke `Curve`, because `Curves.easeOut` is a different polynomial.

Three deliberate divergences:

1. **Dispatch on `LogicalKeyboardKey`, not key codes.** gl-js uses the deprecated `e.keyCode`, which
   is not layout-aware.
2. **Consume shifted arrows too.** gl-js `preventDefault()`s only unshifted arrows; in Flutter an
   unconsumed `Shift`+Arrow also fires `DirectionalFocusIntent` and would rotate the map *and* move
   focus out of it in one press.
3. **Respect `NavigationMode.directional`.** Under it, bare arrows are not consumed — they belong to
   directional traversal on TV/tvOS-style hosts.

Never consumed: `Tab`, `Shift`+`Tab`, and anything with alt/ctrl/meta (gl-js's first statement).
That is WCAG 2.1.2, and it is also what satisfies **SC 2.1.4**: `+`/`-`/`=` are single-character
shortcuts, made conformant by the *active-on-focus-only* exception — the handler lives on the map's
own `FocusNode` and is never installed via `HardwareKeyboard.addHandler`. A structural choice, not a
feature.

`FocusableActionDetector.onShowFocusHighlight` drives a focus ring drawn as a Flutter overlay (we
cannot draw into the texture), visible for keyboard navigation and not for mouse clicks. gl-js's
`.maplibregl-canvas` has **no** focus style at all, so this is a straight win. Focus loss or app
backgrounding calls `camera.stop()`, mirroring gl-js's window-`blur` handler — otherwise a held
arrow key survives an app switch.

### 5.5 Gesture alternatives — the compliance deliverable

```dart
@immutable
class MapControls {
  const MapControls({
    this.zoom = true,
    this.compass = MapCompassVisibility.whenRotated,
    this.pan = true,
    this.pitch = true,
    this.presentation = MapControlsPresentation.collapsible,
    this.alignment = Alignment.topRight,
    this.padding = const EdgeInsets.all(8),
    this.builder,
  });
  const MapControls.none()
      : this(zoom: false, compass: MapCompassVisibility.hidden, pan: false, pitch: false);
  const MapControls.expanded() : this(presentation: MapControlsPresentation.expanded);
}
enum MapCompassVisibility { hidden, whenRotated, always }
enum MapControlsPresentation { collapsible, expanded }

// on MapLibreMap
final MapControls controls;   // ← DEFAULT ON

// exported individually
class MapLibreNavigationControl extends StatelessWidget { … }
class MapLibreCompassButton extends StatelessWidget { … }
class MapLibreZoomButtons extends StatelessWidget { … }
class MapLibrePanPad extends StatelessWidget { … }
```

**Bucket: widget prop.** **Upstream:** gl-js `NavigationControl({showZoom, showCompass,
visualizePitch})`; Apple `MLNCompassButton` (`COMPASS_A11Y_LABEL`, `COMPASS_A11Y_HINT`, and its
"hide the element when bearing == 0" rule — but not its `accessibilityElementsHidden` leak). The
`pan` and `pitch` groups have **no** upstream and are justified directly by the 2.5.7 Understanding
document's map example.

**This defaults ON, and that is the most consequential decision in this document.** The precedent is
exact: `showAttribution` already defaults `true` (`maplibre_map.dart:42`) because displaying a credit
is a licence condition — the argument is written out at `:486-487`, on the stack order that keeps the
credit above the marker overlay. SC 2.5.1 is a Level A condition, created by gestures **this package
ships**. Shipping pinch-zoom, two-finger rotate and two-finger shove with no single-pointer
alternative hands every consumer a conformance failure they did not choose and probably cannot see.

`collapsible` is the default presentation — one 48×48 disclosure button expanding to the pad. WCAG
requires the alternative to be operable and programmatically discoverable, not permanently visible;
this is the same disclosure pattern gl-js uses for attribution (`<details>/<summary>`, the one WCAG
issue upstream actually closed). It is also the difference between a default a designer keeps and a
default a designer deletes.

Each group auto-suppresses when its gesture is disabled or its capability is absent, so a
`rotateGesturesEnabled: false` map does not grow a pointless rotate button and a tier without
`MapLibreRotateHandler` does not offer one. Targets are ≥48×48 (Android guideline, above WCAG's 24
and iOS's 44) — gl-js's 29×29 is its still-open issue #363 and we do not copy it. Zoom buttons take
`onPressed: null` at min/max zoom, which yields `disabled` + `aria-disabled` + `isEnabled` in one;
gl-js needs two explicit calls and it was its WCAG issue #361.

Because the controls drive `controller.camera`, **they are the one part of this design that reaches
all nine tiers**, including the platform-view and web tiers.

`MapControls.none()` is the opt-out, and its dartdoc names the criteria the app then owns.

**Cooperative gestures** (`MapCooperativeGestures`, default `whenScrollable`) is gl-js's
scroll-trapping mitigation. Tri-state rather than gl-js's bool, because gl-js itself disables it in
fullscreen — a full-screen map should never trap scroll and an embedded one always should, so
keying on `Scrollable.maybeOf(context) != null` is a better test than either upstream has, and it
changes nothing for a full-screen map. The mechanism is arena policy, not CSS `touch-action`: under
cooperative gestures the single-pointer drag recognizer does not enter the arena, so the ancestor
`Scrollable` wins uncontested. The hint overlay is `ExcludeSemantics` + `IgnorePointer` — gl-js sets
`aria-hidden="true"` on it and the reasoning transfers verbatim: *a screen-reader user cannot
perform the gesture the message describes.*

### 5.6 Reduced motion

```dart
// on MapLibreCameraController — added to easeTo, flyTo, fitBounds, panBy, panTo,
// zoomTo, rotateTo, resetNorth, resetPitch
Future<void> flyTo(CameraOptions camera, {
  Duration? duration, Cubic? easing, double? speed, double? apexZoom,
  bool essential = false,
});

@internal set reduceMotion(bool value);   // pushed in by the widget
```

**Bucket: controller** (imperative/command), with `essential` copied verbatim from gl-js
`AnimationOptions.essential` — the only way an app can say "this animation carries meaning."

**The detection must read two sources:**

```dart
final reduceMotion = widget.gestures.respectReduceMotion &&
    (MediaQuery.disableAnimationsOf(context) ||
     PlatformDispatcher.instance.accessibilityFeatures.reduceMotion);
```

VERIFIED: iOS's `AccessibilityFeatures.swift:46` only ever `flags.insert(.reduceMotion)` and never
inserts `.disableAnimations`; `MediaQueryData` has **zero** occurrences of `reduceMotion`
(`grep -c` over `media_query.dart`); and the macOS embedder calls `UpdateAccessibilityFeatures`
**nowhere at all**. So `MediaQuery.disableAnimationsOf` alone silently ignores "Reduce Motion" on
iOS — the platform where this project has a physical test device — and neither source works on
macOS, our reference tier (§9).

Behaviour, copied from gl-js's three honour sites: `easeTo` clamps to `Duration.zero`; `flyTo`
degrades to `jumpTo` carrying **only** `center, zoom, bearing, pitch, padding` (dropping `speed`,
`apexZoom` and any anchor — the correctness half); gesture fling inertia is suppressed at
`_onScaleEnd`; `_applyTracking()`'s 300 ms follow-ease becomes a jump. **`onCameraMoveStart` and
`onCameraMoveEnd` fire identically in both modes**, so an app's state machine cannot diverge between
reduced-motion and normal users.

The controller has no `BuildContext`, so the widget pushes the flag in — the same shape already used
for `retainRuntimeStyle`, which is a plain settable field on the style controller
(`map_style_controller.dart:95`) that the widget writes from `initState`, `didUpdateWidget` and
before every style push (`maplibre_map.dart:351`, `:428`, `:438`). This is what makes imperative
`controller.camera.flyTo(...)` calls from app code honour the setting too. Unlike gl-js, which
caches a `MediaQueryList` and writes a module-global singleton, ours is per-controller and picks up
a mid-session OS change through `didChangeAccessibilityFeatures`.

### 5.7 Announcements

```dart
abstract final class MapLibreSemanticsAnnouncer {
  static void announce(BuildContext context, String message,
      {Assertiveness assertiveness = Assertiveness.polite});
}
```

Default `MapSemanticsAnnouncements.accessibilityActions` reproduces Apple exactly: the pending flag
is armed **only** by an AT or keyboard action, never by a gesture, and fires 100 ms after settle.
Without it a user has no feedback that their swipe did anything; with it on every camera change,
TalkBack and VoiceOver are flooded and each announcement interrupts the last.

The platform split is encapsulated once so app authors never write it:

- `MediaQuery.supportsAnnounceOf(context)` true (iOS, web, desktop) →
  `SemanticsService.sendAnnouncement(View.of(context), …)`. Never the deprecated
  `SemanticsService.announce` (deprecated after v3.35.0-0.1.pre: *"This API is incompatible with
  multiple windows"*).
- False → mutate a hidden 0×0 `Semantics(liveRegion: true)` node's **label**.

**Android is permanently in the second branch**: `AccessibilityBridge.java:516` sets
`accessibilityFeatureFlags |= AccessibilityFeature.NO_ANNOUNCE.value` **unconditionally** (VERIFIED),
because Android 16 deprecated `announceForAccessibility`/`TYPE_ANNOUNCEMENT` outright — *"These can
create inconsistent user experiences for users of TalkBack … alternatives better serve a broader
range of user needs."* Its recommended replacement is exactly a live region, which Flutter lowers to
`TYPE_WINDOW_CONTENT_CHANGED` + `CONTENT_CHANGE_TYPE_SUBTREE`.

**Two traps that would make a naive implementation silently do nothing:** on both Android
(`AccessibilityBridge.java:2027-2029`) and web, a live region fires only on a changed **label** —
putting the summary in the map node's `value` and marking it a live region announces nothing. And
`role: SemanticsRole.status` together with `liveRegion: true` **throws** at frame time — in debug
only, which is the worse half: the check is `_DebugSemanticsRoleChecks._noLiveRegion`
(`semantics.dart:426-436`, reached from `SemanticsRole.status` at `:177`) and it is rethrown from
inside an `assert` in `_addToUpdate` (`:4032`), so a release build ships the contradiction in
silence.

### 5.8 The accessible-alternative list

```dart
class MapLibreFeatureList extends StatelessWidget {
  const MapLibreFeatureList({
    super.key, required this.controller, this.locale,
    this.itemBuilder, this.emptyBuilder,
    this.includeMarkers = true, this.onSelected, this.flyToOnSelect = true,
  });
}

// on MapLibreMapController
ValueListenable<MapSemanticsSummary> get semanticsSummary;
```

**Bucket: widget prop; the listenable is controller.** **Upstream: none in the MapLibre family** —
this is WCAG technique G92's long-description discharge and the pattern the Web Accessibility
Directive's map exemption actually requires. The closest prior art is `mapbox-gl-accessibility`,
which stamps *invisible* focusable buttons over queried features; we take its option vocabulary
(§5.2) and reject its invisible-overlay mechanism in favour of a real list.

Driven by the **same** `semanticsSummary` the map node reads, so the list and the spoken summary can
never disagree — which they do upstream, where Apple's summary reads raw `name` and its elements
read localized `name_<lang>`. Selecting an item flies to the feature, honouring reduced motion.

Exposed as a `ValueListenable`, not a `Stream`, per §9 adaptation #1 and the `onCameraChanged`
precedent.

It serves screen-reader, keyboard-only and cognitive-load users at once, and unlike the map surface
it is fully operable with zero custom semantics work.

### 5.9 Localization

```dart
class MapLibreLocale {
  const MapLibreLocale([this.overrides = const <String, String>{}]);
  static const Map<String, String> defaultLocale = <String, String>{
    // gl-js defaultLocale, verbatim, all 25 keys:
    'Map.Title': 'Map', 'Marker.Title': 'Map marker', 'Popup.Close': 'Close popup',
    'NavigationControl.ZoomIn': 'Zoom in', 'NavigationControl.ZoomOut': 'Zoom out',
    'NavigationControl.ResetBearing': 'Drag to rotate map, click to reset north',
    'AttributionControl.ToggleAttribution': 'Toggle attribution',
    'AttributionControl.MapFeedback': 'Map feedback',
    'LogoControl.Title': 'MapLibre logo',
    'ScaleControl.Feet': 'ft', 'ScaleControl.Meters': 'm', 'ScaleControl.Kilometers': 'km',
    'ScaleControl.Miles': 'mi', 'ScaleControl.NauticalMiles': 'nm',
    'FullscreenControl.Enter': 'Enter fullscreen', 'FullscreenControl.Exit': 'Exit fullscreen',
    'GeolocateControl.FindMyLocation': 'Find my location',
    'GeolocateControl.LocationNotAvailable': 'Location not available',
    'GlobeControl.Enable': 'Enable globe', 'GlobeControl.Disable': 'Disable globe',
    'TerrainControl.Enable': 'Enable terrain', 'TerrainControl.Disable': 'Disable terrain',
    'CooperativeGesturesHandler.WindowsHelpText': 'Use Ctrl + scroll to zoom the map',
    'CooperativeGesturesHandler.MacHelpText': 'Use ⌘ + scroll to zoom the map',
    'CooperativeGesturesHandler.MobileHelpText': 'Use two fingers to move the map',
    // Apple Localizable.strings, verbatim keys — kept ONLY where the semantics survive:
    'ANNOTATION_A11Y_HINT': 'Shows more info', 'CLOSE_CALLOUT_A11Y_HINT': 'Returns to the map',
    'COMPASS_A11Y_LABEL': 'Compass', 'COMPASS_A11Y_HINT': 'Rotates the map to face due north',
    'INFO_A11Y_LABEL': 'About this map',
    'INFO_A11Y_HINT': 'Shows credits, a feedback form, and more',
    'USER_DOT_TITLE': 'You Are Here', 'LIST_SEPARATOR': ', ',
    'ROAD_REF_A11Y_FMT': 'Route {ref}', 'ROAD_ONEWAY_A11Y_VALUE': 'One way',
    'ROAD_DIVIDED_A11Y_VALUE': 'Divided road', 'ROAD_DIRECTION_A11Y_FMT': '{from} to {to}',
    // ours — deliberately NOT under Apple's key, because the meaning diverged or the key
    // does not exist upstream:
    'Map.ValueZoom': 'Zoom {zoom}.',    // ≠ MAP_A11Y_VALUE_ZOOM = "Zoom %dx.", a magnification
                                        // factor; ours is a zoom level (§5.1 divergence #2)
    'Map.ValueMarkers.one': '{count} marker visible.',    // MAP_A11Y_VALUE_ANNOTATIONS is ONE
    'Map.ValueMarkers.other': '{count} markers visible.', // key; its plurals live in the
                                                          // en.lproj/Localizable.stringsdict
    'Action.PanNorth': 'Pan north', 'Action.PanSouth': 'Pan south',
    'Action.PanEast': 'Pan east', 'Action.PanWest': 'Pan west',
    'Action.RotateLeft': 'Rotate left', 'Action.RotateRight': 'Rotate right',
    'Action.ResetNorth': 'Reset north', 'Action.TiltUp': 'Tilt up',
    'Action.TiltDown': 'Tilt down', 'Action.ResetTilt': 'Reset tilt',
    'Controls.Expand': 'Show map controls', 'Controls.Collapse': 'Hide map controls',
  };
  String getUIString(String key, {Map<String, Object?> args = const {}});
  String plural(String key, int count, {Map<String, Object?> args = const {}});
}

// on MapLibreMap
final MapLibreLocale locale;   // default const MapLibreLocale()
```

**Bucket: widget prop.** **Upstream:** gl-js `defaultLocale` / `MapOptions.locale` / `_getUIString`;
Apple's `*_A11Y_*` key names.

**A flat patch map, not a `LocalizationsDelegate` + `.arb` set.** Three reasons. First, the identical
key names mean an app's existing gl-js translations drop straight in — all 25 gl-js strings are
placeholder-free, so that half really is 1:1 — and Apple's **24 shipped BSD-3 locales** carry over
with one mechanical rewrite, `%@`/`%d`/`%1$@` → the named placeholders (`Localizable.strings:62` is
`"%1$@ to %2$@"`). That is §9's "copy upstream naming" cashed out. It is also why the two diverged
strings above are **not** under Apple's keys: reusing a key whose meaning we changed imports 24
correct translations of the wrong sentence, which is worse than 24 missing ones. Second, adding
`flutter_localizations` and `intl` would break the package's standing posture of refusing avoidable
dependencies (it already refuses `url_launcher` for attribution links at `maplibre_map.dart:178-181`
and `geolocator` for the puck at `:186-191`). Third, it would add a third generated-code surface
needing a regen-diff check that CI — being `workflow_dispatch`-only — would never run.

`getUIString` copies gl-js's throw-on-missing as a debug `assert` (a silently unlabelled control is
what it prevents) and falls back to the default table in release. `{zoom}`-style named placeholders
replace printf `%@`/`%d` because Dart has no positional format and named placeholders survive
translator reordering. `LIST_SEPARATOR` is a **key, not a literal** — Apple localizes it and French
uses `;`.

Plurals use a `.one`/`.other` key convention mirroring Apple's `Localizable.stringsdict`. This is
honestly the design's weakest piece: it cannot express Slavic `few`/`many` and silently falls back to
`.other`. It is the difference between a product and "1 roads visible", but it is not `intl`. §9.

Two pure formatters land before anything else, because both are needed by two callers each and both
are trivially unit-testable:

```dart
String compassDirectionName(double bearing,
    {MapCompassStyle style = MapCompassStyle.long, MapLibreLocale locale});   // ← MLNCompassDirectionFormatter
String formatCoordinate(LatLng point, {double? zoom, MapLibreLocale locale}); // ← MLNCoordinateFormatter
```

`compassDirectionName` is the 32-point rose ("north", "north by east", "north-northeast",
"northeast by north"), keys copied verbatim (`COMPASS_N_LONG`, `COMPASS_NbE_LONG`, …) so Apple's
translations of the `Foundation` table can be reused. `formatCoordinate` gates precision on zoom
exactly as Apple does (`allowsMinutes = zoom > 8`, `allowsSeconds = zoom > 20`) — announcing seconds
at z3 is noise. It is also the only thing that tells a blind user *where* the map is when nothing on
screen is named.

**Both are where a sign flip would go unnoticed. §11 discipline applies: assert with asymmetric
fixtures — bearing 90 must be "east", latitude +60 must be "north" — never a round trip.**

### 5.10 App-facing customization

Three hooks, all in the wrap-the-default shape (`ScrollBehavior.buildScrollbar`,
`ErrorWidget.builder`), so an app overrides one decision without reimplementing the pipeline:

| Hook | Signature | Default |
| --- | --- | --- |
| Feature description | `MapFeatureDescriber` | `describeMapLibreFeature` (the Apple port) |
| Map value | `MapSemanticsSummaryBuilder` | `MapSemanticsSummary.describe` |
| Control layout | `MapControls.builder` | `MapLibreNavigationControl` |

`describe` returning `null` **drops** the feature — the right answer when the app knows a layer is
decorative. `properties` is a raw, untranslated, provider-controlled `Map<String, Object?>`, so any
default we ship is a guess and the app must be able to win. Apple has no override point at all,
which is exactly why its allowlist rotted.

### 5.11 The one platform-interface change

```dart
sealed class MapLibreRenderHandle {
  const MapLibreRenderHandle({this.providesOwnSemantics = false});

  /// Whether the embedded native view or DOM element publishes its own
  /// accessibility tree, so the widget must not synthesize a second one.
  final bool providesOwnSemantics;
}

final class PlatformViewHandle extends MapLibreRenderHandle {
  const PlatformViewHandle({
    required this.viewType, this.id, this.creationParams,
    super.providesOwnSemantics,                          // ← new, forwarded
  });
  …
}

final class TextureHandle extends MapLibreRenderHandle {
  const TextureHandle({required this.textureId, super.providesOwnSemantics});
  …
}

final class ElementViewHandle extends MapLibreRenderHandle {
  const ElementViewHandle({required this.viewType, super.providesOwnSemantics});
  …
}
```

**Call it what it is: a field on the base plus a forwarding parameter in every subclass
constructor — four constructors, not one.** Each of `PlatformViewHandle` / `TextureHandle` /
`ElementViewHandle` today declares its own `const` ctor with no super-arguments
(`render_handle.dart:11-13`, `:18-22`, `:41`, `:50`), so without the forwarding, the two packages
that need `true` could never set it. Callers are unaffected — the parameter is optional and defaults
`false` — but every member of the sealed hierarchy is touched.

Set `true` by `maplibre_flutter_ios_sdk` (rich `MLNMapView` container) and
`maplibre_flutter_web_gljs` (canvas ARIA + `KeyboardHandler`). Everything else keeps the default.

**Why a field on the handle and not a marker interface on the controller** (the obvious alternative,
in the shape of `MapLibreResizeMaskHint`): the widget already `switch`es on the sealed handle
(`maplibre_map.dart:524-547`), so this lands exactly where the decision is made, needs no `is` check
against a second object, and needs no `MapLibreCapabilities` row — it is renderer trivia, not an
app-facing ability.

**Why not branch on the handle *type*:** both web tiers share `ElementViewHandle` and only gl-js has
ARIA; both SDK tiers share `PlatformViewHandle` and only iOS has a rich tree. The type carries the
wrong information.

When `providesOwnSemantics` is true we emit **no** map surface node, no feature nodes and no keyboard
layer. We do **not** use `ExcludeSemantics`, and the reason is *not* the `platformViewId` assertion
(`semantics.dart:3698-3703`, *"SemanticsNodes with children must not specify a platformViewId"*) —
that fires on a platform-view node that has acquired Flutter children, which excluding a subtree
never produces. The real reason is simpler and worse: `ExcludeSemantics` drops everything below it,
**including the platform view's own node** — and the native tree is grafted *at* that node, so
excluding it takes the SDK's whole accessibility tree with it. Emitting nothing is not the same
operation as excluding something. Controls and the attribution bar remain as **Stack siblings**,
which is legal and is the shape used uniformly on every tier.

**This adds to the base contract, and CLAUDE.md §3 locks against exactly that** — *"optional
capabilities are feature-detected with `is`, not added to the base contract."* Everything above is
the argument for taking the exception (the handle is already where the widget branches; this is
renderer trivia, not an app-facing ability), but an argument is not an authorisation. §3's own rule
applies: this lands with a dated entry in `docs/decision-log.md`, or it does not land.

---

## 6. Per-platform matrix

| Capability | macOS | Windows | Linux | iOS core | Android core | Web WASM | iOS SDK | Android SDK | Web gl-js |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Map node: label + value | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | native | ⚠️ one string | native |
| Adjustable zoom (increase/decrease) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | native | ❌ | ❌ |
| 4-way AT scroll pan | ✅ | ✅ | ✅ | ✅ | **❌ §5.0** | ✅ | ❌ | ❌ | ❌ |
| Pan/rotate/tilt custom actions | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Marker semantics | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ no projector | ❌ no projector | ❌ no projector |
| Feature nodes (opt-in) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | native (Mapbox only) | ❌ | ❌ |
| Keyboard model | ✅ | ✅ | ✅ | ⌨️ | ⌨️ | ✅ | ❌ | ❌ | native |
| Focus ring | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Reduced motion detected | **❌** | **❌** | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ❌ |
| Reduced motion honoured | prop | prop | ✅ | ✅ | ✅ | prop | ✅ | ✅ | native |
| Announcements | ✅ | ✅ | ✅ | ✅ | live region | ✅ | native | ❌ | ❌ |
| Controls (2.5.1 / 2.5.7) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Accessible-alternative list | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Attribution link semantics | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

⌨️ = works with a hardware keyboard. "prop" = only via the explicit `respectReduceMotion`/app flag,
because the platform reports nothing. "native" = the embedded SDK's own tree — and on the gl-js tier
that extends to reduced motion, because every camera call we forward lands in gl-js's own `easeTo`
/ `flyTo` / inertia paths, all three of which already consult `browser.prefersReducedMotion` (§2).
That tier needs no prop; the browser is the source and the engine is the honourer.

**The last three rows are the payoff**: controls, the alternative list and attribution semantics are
pure Flutter widgets over `controller.camera`, so they reach **all nine tiers** — including the two
where we defer on semantics entirely.

### Blocked by the framework, not by us

| Blocker | Consequence | Evidence |
| --- | --- | --- |
| `SemanticsProperties` has no `allowsDirectInteraction` | VoiceOver cannot pass raw touches to our texture the way `MLNMapView` does; synthesized scroll actions are our only pan affordance | VERIFIED against the full member list |
| Android collapses SCROLL_LEFT/UP/INCREASE onto ACTION_SCROLL_FORWARD | No 4-way AT scroll on Android; zoom and scroll cannot coexist on one node | `AccessibilityBridge.java:1089-1105`, `:1326-1342` |
| `MediaQueryData` has no `reduceMotion`; the macOS embedder sets no features at all; Windows sets only high contrast; iOS never sets `disableAnimations` | Reduce motion undetectable on macOS and Windows — for two different reasons, so a name-grep misleads on Windows | `grep -c reduceMotion media_query.dart` → 0; iOS `AccessibilityFeatures.swift:46` inserts `.reduceMotion` and never `.disableAnimations`; macOS — no `UpdateAccessibilityFeatures` in `platform/darwin/macos/`; Windows **does** call it (`windows/flutter_windows.cc:117` → `flutter_windows_engine.cc:1021`) but `SendAccessibilityFeatures` (`:1032-1041`) sets only `kFlutterAccessibilityFeatureHighContrast`. Contrast Linux, which is the working case: `linux/fl_settings_handler.cc:49` ORs in `kFlutterAccessibilityFeatureDisableAnimations` and pushes it through `fl_engine_update_accessibility_features` (`linux/fl_engine.cc:1515`), asserted at `linux/fl_settings_handler_test.cc:227` |
| `SemanticsNode` exposes `rect` + `transform`, no path | A road degrades from Apple's stroked polyline to a point sample | — |
| Flutter web semantics are off until `ensureSemantics()` or the placeholder is activated | Web is documented host-app opt-in; a plugin must **not** call it (it forces a permanent semantics pipeline on the whole app) | docs.flutter.dev/ui/accessibility/web-accessibility |
| Safari does not support `aria-owns` | Platform-view traversal order is not established on Safari macOS/iOS | engine `semantics/platform_view.dart` source comment; WebKit 223798 |
| Flutter cannot z-order its semantics against a platform view's DOM semantics | Markers over a gl-js map cannot both be correctly ordered | flutter/flutter#101439, **open** |
| mbgl rasterises map labels inside the texture | Labels honour neither `textScaler` nor `boldText` nor `highContrast` | — |

That last one is worth stating plainly to consumers: **map label contrast (1.4.3) and map label
scaling (1.4.4) are the style author's obligation, not the binding's.** The documented workaround for
scaling is a `text-size` expression multiplied by `MediaQuery.textScalerOf(context).scale(1)` pushed
through `controller.style.setLayoutProperty`. We record 1.4.4 as *Partially Supports*, not as a pass.

---

## 7. Testing

Per §7's layering. The good news: `test/maplibre_map_test.dart:10-116` already defines a complete
dependency-free fake stack, and `_FakeGestureController` (`:54-73`) **already records every
`moveBy`/`scaleBy`/`rotateBy`/`pitchBy` call into lists** — which is precisely the assertion target a
semantic-action test needs. `marker_overlay_test.dart:12-53` adds a settable projector fake. No new
test infrastructure is required.

Note `testWidgets` enables semantics by **default** (`semanticsEnabled = true`), so `ensureSemantics()`
is redundant — and the zero-cost path can only be tested by passing `semanticsEnabled: false`
explicitly.

**Contract:**
- Map node shape with `matchesSemantics` — the **exact** matcher, so it also pins what we do *not*
  expose. Run once per `TargetPlatform` (override reset **inline in a `finally`**, per the existing
  convention at `maplibre_map_test.dart:169-171`) to lock the §5.0 Android branch: `hasIncreaseAction:
  true, hasScrollUpAction: false` on Android; all four scroll actions elsewhere.
- `performAction(…, SemanticsAction.increase)` at zoom 12.4 → exactly one recorded call reaching
  zoom **13**, not 13.4. Asserts the integer snap *and* that we never went via
  get-camera-then-set-camera.
- `SemanticsAction.customAction` round trip via `CustomSemanticsAction.getIdentifier` → the right
  `moveBy`. This is the Android east/west fallback path; if it breaks, Android loses panning
  entirely.

**Absolute directions, never round trips (§11):**
- `compassDirectionName(90) == 'east'`, `(270) == 'west'`, `(202.5) == 'south-southwest'`.
- `formatCoordinate(LatLng(60.17, 24.94))` contains 'north' and 'east'.
- After `SemanticsAction.scrollDown`, latitude **decreases**.
- A road running due east describes as "west to east" — an **asymmetric** fixture. Plus a verbatim
  port of **both** of Apple's `MLNMapAccessibilityElementTests.m` road assertions, with the fixtures
  kept separate as upstream has them: a LineString SW→NE carrying `{ref: '42', oneway: 'true'}` →
  `'Route 42, One way, southwest to northeast'` (`:63-69`); and a MultiLineString of two such
  polylines whose **own** attributes are `{ref: '42'}` only → `'Route 42, Divided road, southwest to
  northeast'` (`:80-85`). Merging the two fixtures is the trap: facts append ref → oneway → divided
  → direction (`MLNMapAccessibilityElement.mm:135-203`), so a MultiLineString that also carries
  `oneway` yields `'Route 42, One way, Divided road, southwest to northeast'` and an expectation
  copied from the wrong case fails for the right reason, late. That port alone gives us more
  accessibility test coverage than upstream has.

**The `Flow` trap:** two markers, one projected off-screen; `find.semantics.byLabel('B')` is
`findsNothing` — **not** a node at (0,0). Run in both `childOwned` and `synthesized` modes.

**Focus stability:** record a feature node's `SemanticsNode.id`, tick the camera so everything
reprojects, assert the id is **unchanged**. This is the keyed-reconciliation guarantee and the
difference between a usable and an unusable screen-reader experience.

**Zero cost:** with `semanticsEnabled: false`, 60 camera ticks produce **zero** `semanticsBuilder`
invocations, zero feature queries and zero settle timers.

**Reduced motion:** under `MediaQueryData(disableAnimations: true)`, `flyTo` reaches the fake as a
`jumpTo` with `speed`/`apexZoom` **dropped** and `center`/`zoom` kept; `easeTo` arrives with
`Duration.zero`; `essential: true` preserves both; and `onCameraMoveStart`/`onCameraMoveEnd` fire
identically with and without. Repeat with a faked `reduceMotion` feature bit to cover the iOS path,
which `MediaQuery` alone cannot exercise.

**Keyboard:** each binding to its recorded call; `Control`+Arrow does **nothing**; `Tab` is not
consumed and focus leaves the map (2.1.2); under `NavigationMode.directional` bare arrows are not
consumed.

**Guidelines:** `meetsGuideline(androidTapTargetGuideline)`, `iOSTapTargetGuideline` and
`labeledTapTargetGuideline` over the example app with controls mounted.

### Tests that would be theatre

- **`textContrastGuideline` over the map area.** It rasterises, so it must run inside
  `tester.runAsync` or it hangs to the 10-minute timeout (§11) — and it would read the blank test
  texture as the background, making every result over the map meaningless. **Scope it to chrome
  only.**
- **Asserting a semantics node exists and stopping there.** "A node came back" is this domain's
  version of "a frame came back" (§7). Assert the *content*: the exact label, the exact rect, the
  exact recorded camera call.
- **Round-tripping any projection or direction.** A symmetric Y flip survives every round trip we
  had; the map centre is symmetric too. Asymmetric fixtures or nothing.
- **Asserting both `hasIncreaseAction` and `hasScrollUpAction` on Android.** Both are present in the
  Flutter tree and the test passes — while zoom is unreachable on device (§5.0). The only honest
  test is the per-platform `matchesSemantics` above.
- **Any claim of AT behaviour from a widget test.** Widget tests prove the Flutter semantics tree.
  They prove nothing about what NVDA says. §9.

---

## 8. Phasing

Each milestone is independently shippable and independently valuable.

**Phase 1 — Name, role, value + reduced motion.** `MapLibreLocale`, the two pure formatters, the map
region container, the map surface node (label/value/hint/identifier), increase/decrease with the
integer snap, the scroll actions with the §5.0 Android branch, the ten custom actions, `essential`
on every camera verb, the `flyTo` whitelist, inertia suppression, `link: true` + `linkUrl:` on the
attribution links (the tappable node is already there, §4 — this is one property pair, not a
rewrite), the puck gets a label. **Delivers:** WCAG 4.1.2 / 1.1.1 / 1.3.1 on six tiers where
today there is literally nothing, plus the repo's already-specced `respectReduceMotion` item.
_~4–6 days. No platform-interface change, no native code, no new dependency, fully device-free
testable._

**Phase 2 — Controls and gesture alternatives.** `MapControls` default-on collapsible cluster,
`MapLibreNavigationControl` / `CompassButton` / `ZoomButtons` / `PanPad`, ≥48 px targets, disabled
state at min/max zoom. **Delivers:** SC 2.5.1 (A) and 2.5.7 (AA) — the two criteria a map fails by
default — and it is the only phase that lands on all nine tiers. _~3–4 days._

**Phase 3 — Keyboard and focus.** `MapGestureSettings` with the deprecated aliases,
`FocusableActionDetector`, gl-js's binding table, the Tab guarantee, `NavigationMode.directional`,
the focus ring, focus-loss stop. **Delivers:** SC 2.1.1 / 2.1.2 / 2.1.4 / 2.4.7 on four desktop tiers
and web, where the map is currently unreachable by keyboard entirely. Independently valuable to
sighted keyboard and switch-access users with no screen reader at all. _~3–4 days._

**Phase 4 — Markers.** The five marker fields, the `Flow` cull fix in both modes, `OrdinalSortKey` by
distance from centre, `MergeSemantics` so an app's existing in-child `GestureDetector` becomes the
labelled node's tap action, keyboard/AT marker nudging. **Delivers:** accessible markers — which
nobody in the Flutter or Android map ecosystem ships (§1). _~3–4 days._

**Phase 5 — Feature nodes and the alternative list.** `MapFeatureSemantics`, the settle-driven
per-layer query, dedupe/cap/sort, keyed `CustomPainterSemantics`, the Apple-derived describer,
`semanticsSummary`, `MapLibreFeatureList`, the announcement router. **Delivers:** a blind user can
explore what is on the map, on any style — the thing Apple built and gated, and gl-js never had.
_~5–8 days._

**Phase 6 — Per-tier truth and on-device verification.** `providesOwnSemantics` on the two SDK/gl-js
tiers; `tabindex`/`role`/`aria-label` + a keydown listener on the WASM tier's `<canvas>` (a ~20-line
change in `core_web_controller.dart` with no existing behaviour to regress, since that tier has never
been compiled); then the manual matrix — VoiceOver on macOS and a physical iPhone, TalkBack on a
**physical** Android device (the emulator is useless here), NVDA on Windows, Orca on Ubuntu,
NVDA+Chrome on web — recorded with dates and versions in this document. **This is the phase that
converts a code read into a claim.** Nothing before it should be described in the README as working.
_~4–6 days, mostly hardware time._

---

## 9. Open questions and unverified claims

**The whole design is a source read.** Not one platform-lowering claim has been observed in
VoiceOver, TalkBack, NVDA or Orca. §7's rule applies verbatim: "a frame came back" proves as little
as "the bridge exists". Phase 6 is not optional polish; it is where this could fall apart.

**Highest-risk unknowns:**

1. **macOS reports no accessibility features at all** (VERIFIED: no `UpdateAccessibilityFeatures`
   anywhere in `platform/darwin/macos/`). macOS is our reference tier, where everything is verified
   first — and it cannot tell us whether VoiceOver is running, and reduce motion is untestable there
   except through the explicit prop. **INFERRED and load-bearing:** that
   `SemanticsBinding.instance.semanticsEnabled` — which the entire zero-cost gate depends on — is
   driven correctly by the macOS `NSAccessibility` bridge. **Probe this before Phase 5.** If it is
   false, the gate never opens on our own dev machine.
2. **Does the iOS SDK tier's `UIAccessibilityContainer` survive the `UiKitView` boundary?**
   Structurally it should — `FlutterPlatformViewSemanticsContainer` is a `SemanticsObject` since
   flutter/engine#29531 — but flutter/flutter#135504 ("[iOS][a11y] VoiceOver on UIKitView seems to
   be broken") reports the view not appearing in the tree at all. **INFERRED. Untested.**
3. **Does TalkBack see the Android SDK tier's `contentDescription` through Hybrid Composition plus
   our attribution overlay?** flutter/flutter#113626 was exactly this shape ("fully transparent view
   overlays mask a11y elements that are underneath them"), fixed by flutter/flutter#168939 in May
   2025 and therefore inside 3.44.2 — but this repo triggers the same configuration. **INFERRED.**
   If TalkBack skips the map there, that is where to look, and the diagnostic is an Accessibility
   Scanner node dump, **never** a screenshot (§11's GDI-capture rule generalises).

**Also unverified:**

- **`SemanticsRole` lowering outside web.** Only the web engine's translation table was read. `role:
  SemanticsRole.region` may be a **no-op** on Android, iOS and desktop. INFERRED.
- **Feature-query cost per settle.** One `queryRenderedFeaturesAsync` per layer id, per settle, on a
  dense POI style, is a real render-thread round trip and it is **unmeasured**. A settle-storm could
  queue queries; a coalescing drop-oldest policy is probably needed, matching the existing "drain the
  queue and render once at the latest state" rule (§11).
- **`sourceLayer` is null for every GeoJSON source** (`feature.dart:169`), and `QueriedFeature`
  carries no layer id at all — so the per-layer query is not an optimisation choice, it is the only
  way to know what matched. (The web-WASM caveat belongs to `source`, not `sourceLayer`:
  `feature.dart:163` is the one that says *"Null on a tier that cannot report it (the web WASM tier
  today)"*. Whether that tier can report `sourceLayer` is not documented either way — unverified.)
- **Semantics rebuild cost at scale is measured only in a debug `flutter_tester` software build.**
  The scaling looked roughly linear in node count; the absolute figures are not representative of a
  release build on device. The 32-node cap is a **guess** — nobody knows how many swipe stops a real
  user tolerates before the map is worse than silence, and the answer probably differs between 32
  POIs and 32 markers.
- **`OrdinalSortKey` is sibling-scoped.** Ordering *within* markers and *within* features is exact;
  ordering *across* those groups rests on Stack position and paint order, which we cannot assert
  declaratively. Apple's compass → markers → places → roads sequence is only half-guaranteed.
- **The marker-visibility `setState` on settle is O(markers)** and rebuilds every marker child. For
  the large clusters the overlay is designed for, that is a per-gesture-end hitch **whenever an AT is
  running**. Gated on `semanticsEnabled`, which is exactly the reasoning that produces a jank report
  from the one user who has TalkBack on all day. A `visitChildrenForSemantics` override on a custom
  `RenderFlow` subclass would be strictly better and was rejected as fragile — that trade may be
  wrong at scale.
- **`SemanticsService.sendAnnouncement` coalescing/interruption semantics on iOS and web** were not
  traced. Only that the channel message is emitted.
- **`ChildSemanticsConfigurationsResult`** (the sibling-merge mechanism) was not examined; it may be
  the right tool for marker+callout pairs.
- **Keyboard focus on the two `ElementViewHandle` tiers is a design conflict, not just an unknown.**
  §5.4 wraps the map in `FocusableActionDetector`; §6 marks "Keyboard model: Web WASM ✅"; Phase 6
  proposes putting `tabindex` on the WASM `<canvas>`. **Those compete.** Once the canvas takes DOM
  focus the browser routes key events to the DOM and Flutter's `Focus` never sees them — the mirror
  image of CLAUDE.md §11's `pointer_interceptor` rule, and the same class of mistake. Exactly one
  owner: either the canvas owns keyboard the gl-js way (then `tabindex="0"` and a keydown listener,
  and Dart's bindings are dead on that tier), or Flutter owns it (then the canvas stays
  `tabindex="-1"` and Phase 6 adds `role`/`aria-label` only). **Decide before Phase 6, not during.**
  On the gl-js tier the answer is already forced — `providesOwnSemantics` is `true`, so the canvas
  owns it.
- **`IgnorePointer` does not hide semantics but it does block semantic *actions*.** §4's claim is
  right — `RenderIgnorePointer.visitChildrenForSemantics` skips only when the deprecated
  `_ignoringSemantics ?? false` — but `describeSemanticsConfiguration` sets
  `config.isBlockingUserActions = _ignoring && (_ignoringSemantics ?? true)`
  (`rendering/proxy_box.dart:3814`), which with `_ignoringSemantics` unset is **true**. So Phase 1's
  "the puck gets a label" is safe, and any future puck *action* — tap-to-recentre is the obvious one
  — is silently dead inside that `IgnorePointer` (`user_location_puck.dart:46-58`). Whoever adds the
  action must move the boundary, not just add a callback.

**Known gaps we are choosing, not missing:**

- **No transliteration.** Apple runs `mgl_stringByTransliteratingIntoScript:` so a VoiceOver user in
  an English locale hears "Cincinnati" for "Цинциннати". Dart core has no ICU transform without a
  dependency. Users of non-Latin basemaps get a materially worse experience than on iOS.
- **No CLDR plurals** (§5.9). `.one`/`.other` cannot express `few`/`many`.
- **Roads degrade to point samples** (§5.2). Explore-by-touch along a road will not find it.
- **Feature nodes are opt-in**, so the most differentiating part of this design reaches only apps
  that read the docs. Chosen because a wrong announcement is worse than silence — but the honest
  consequence is the same outcome Apple's vendor gate produces, by a different route.
- **WCAG 2.5.7 for marker dragging is only partly discharged.** Keyboard and AT paths exist; a
  single-pointer non-dragging *pointer* path does not, because the plugin does not own the marker's
  visual and cannot render nudge affordances over an app's widget. We document the obligation and
  provide the hooks. That is the best a binding can do; it is not conformance.

**One unrelated correction found while researching, worth landing**, and one near-miss worth
recording so it is not "corrected" a second time:

1. The web-WASM tier is **mouse-only**: `maplibre_flutter_core_web.cpp:202-205` registers exactly
   four Emscripten callbacks — mousedown, mousemove, mouseup, wheel. **No keydown, no touch, no
   pointer events.**
2. *Not* a correction: `maplibre_map.dart:729-737` attributes the virtual-display shunt to "the
   plain `AndroidView` (texture-layer) path", and that is right — `initAndroidView`'s own dartdoc
   says it "attempts to use the TLHC implementation when possible. In cases where that is not
   supported, it falls back to using Virtual Display" (`services/platform_views.dart:131-133`). The
   comment already names `initSurfaceAndroidView` + Hybrid Composition as our path. The only nuance
   it omits is the TLHC-first attempt on the path we do not take, which changes nothing it claims.

---

## 10. References

### This repository

- `CLAUDE.md` §3 (locked architecture, feature-detected capabilities), §7 (testing strategy),
  §9 (API naming policy), §11 (hard-won rules)
- `packages/maplibre_flutter/lib/src/maplibre_map.dart` — `:118-122` (why gesture toggles are widget
  props), `:486-497` (attribution Stack), `:524-547` (render-handle switch), `:551-552` (no projector
  ⇒ no overlay), `:559` (`onTapUp`), `:571-579` (marker Stack), `:658` (`devicePixelRatioOf`),
  `:716-720` (`UiKitView`), `:729-737` (the Hybrid Composition comment), `:1571` (the only keyboard
  reference in the tree)
- `packages/maplibre_flutter/lib/src/marker_overlay.dart` — `:133-150` (the `Flow`), `:152-172`
  (`_wrap`), `:242` and `:262-268` (the two cull paths)
- `packages/maplibre_flutter/lib/src/attribution_bar.dart:97-111` — links as bare `GestureDetector`
- `packages/maplibre_flutter/lib/src/user_location_puck.dart:46-58`
- `packages/maplibre_flutter/lib/src/maplibre_map_controller.dart:849` (`resetNorth` reporting),
  `:822-826` (`zoomTo` builds an anchor with no centre)
- `packages/maplibre_flutter/lib/src/map_style_controller.dart` — `:95` (the `retainRuntimeStyle`
  push-down shape, written from `maplibre_map.dart:351`/`:428`/`:438`), `:527`/`:573`/`:611`
  (queries), `:1215` (synthetic `MediaQuery`)
- `packages/maplibre_flutter_platform_interface/lib/src/geojson/feature.dart:125-131` — why
  `QueriedFeature` has no layer id; `:163` — `source` null on web; `:169` — `sourceLayer` null for
  every GeoJSON source
- `packages/maplibre_flutter_platform_interface/lib/src/{gesture_handler,rotate_handler,projector,capabilities}.dart`
- `packages/maplibre_flutter_web/lib/src/core_web/core_web_controller.dart:77-150` — the bare canvas
- `packages/maplibre_flutter_core/src/web/maplibre_flutter_core_web.cpp:202-205` — four mouse
  callbacks, no keydown
- `packages/maplibre_flutter/test/maplibre_map_test.dart:10-116` (fakes), `:169-171` (inline platform
  override reset); `test/marker_overlay_test.dart:12-53`
- `docs/api-parity-binding-spec.md:355` (ornaments P3), `:3040` (`MapGestureSettings` — the container
  we keep, the gl-js field names §5.4 supersedes), `:3233` (`keyboard`/`keyboardRotate`), `:3235`
  (keyboard before a stable tag), `:3256` (`respectReduceMotion`)

### MapLibre Apple SDK (vendored submodule)

- `platform/ios/src/MLNMapView.mm` — `:316` (minimum size), `:661-672` (label + traits, the
  commented-out `isAccessibilityElement`; `:663-668` is unrelated network setup, elided in §2),
  `:3229-3286` (`accessibilityValue`), `:3288-3306`
  (uncapped queries), `:3335-3347` (element count), `:3376-3396` (the distance sort),
  `:3512-3612` (element reuse), `:3535-3536` (the `.width/2` twice bug), `:3614-3740`
  (`indexOfAccessibilityElement:`), `:3750-3771` (`accessibilityScaleBy:`), `:6795-6837`
  (delegate-coupled cache invalidation, the deferred announcement)
- `platform/ios/src/MLNMapAccessibilityElement.{h,mm}` — `:13-27` (base), `:46-73` (feature label +
  transliteration), `:75-128` (place facts), `:130-203` (road facts), `:205-219` (proxy)
- `platform/darwin/src/MLNStyle.mm:608-644` — `placeStyleLayers` / `roadStyleLayers`
- `platform/darwin/src/MLNVectorTileSource.mm:191-199` — **`isMapboxStreets`, the gate**
- `platform/darwin/src/{MLNCompassDirectionFormatter,MLNCoordinateFormatter}.m`
- `platform/ios/src/MLNCompassButton.mm:46-53`, `:104-137`
- `platform/ios/resources/Base.lproj/Localizable.strings`; `en.lproj/Localizable.stringsdict`
- `platform/ios/test/MLNMapAccessibilityElementTests.m` — the entire automated a11y suite, 88 lines;
  the two road assertions are `:69` (one way) and `:85` (divided)
- `platform/android/.../maps/MapView.java:141`, `:206`, `:221`; `res/values/strings.xml`;
  `res-public/values/public.xml:86`
- Verified negatives: `grep -rn "accessibilityScroll" platform/` → none;
  `grep -rn "AccessibilityNodeProvider|ExploreByTouchHelper|announceForAccessibility" platform/android/` → none;
  `grep -rn "NSAccessibility" platform/macos/` → none

### Flutter (3.44.2 at `/Users/juhotorkkeli/development/flutter`)

- `packages/flutter/lib/src/semantics/semantics.dart` — `:177` (status → `_noLiveRegion`),
  `:426-436` (`_noLiveRegion`), `:548-557` (`_semanticsRegion`, the non-empty-label rule),
  `:2348-2356` (the `onScrollLeft` dartdoc, upstream typo and all), `:3698-3703` (the
  `platformViewId` assertion), `:3756-3763` (the increase/decrease value assertion), `:4032` (the
  debug-only rethrow in `_addToUpdate`)
- `packages/flutter/lib/src/rendering/texture.dart`, `widgets/texture.dart` — **zero** semantics
- `packages/flutter/lib/src/rendering/{custom_paint,platform_view}.dart`;
  `rendering/proxy_box.dart:3802-3806` (`RenderIgnorePointer.visitChildrenForSemantics`), `:3814`
  (`isBlockingUserActions`), `:4212-4213` (`RenderSemanticsGestureHandler.onTap`);
  `rendering/paragraph.dart:1322-1335` (`WidgetSpan` children reach the tree);
  `widgets/gesture_detector.dart:299` (`excludeFromSemantics` defaults `false`)
- `packages/flutter/lib/src/widgets/media_query.dart` — **zero** `reduceMotion`
- `packages/flutter/lib/src/services/platform_views.dart:131-133` (`initAndroidView`: TLHC, else
  Virtual Display), `:156-161` (`initSurfaceAndroidView`: TLHC, else Hybrid Composition)
- `bin/cache/pkg/sky_engine/lib/ui/window.dart:933`, `:965`, `:995`
- `engine/.../android/io/flutter/view/AccessibilityBridge.java` — **`:1089-1105` and `:1326-1342`
  (the scroll/increase collision)**, `:516` (`NO_ANNOUNCE`), `:2027-2029` (live region on label)
- `engine/.../darwin/ios/framework/Source/AccessibilityFeatures.swift:46` — `.reduceMotion` only
- `engine/.../darwin/macos/` — no `UpdateAccessibilityFeatures`
- `engine/.../windows/flutter_windows.cc:117`, `flutter_windows_engine.cc:1021`, `:1032-1041` —
  Windows calls it, but sends **high contrast only**
- `engine/.../linux/fl_settings_handler.cc:49`, `fl_engine.cc:1515`,
  `fl_settings_handler_test.cc:227` — Linux does send `kFlutterAccessibilityFeatureDisableAnimations`
- `engine/.../common/accessibility_bridge.cc:390-416` — desktop action mapping
- `engine/.../lib/web_ui/lib/src/engine/semantics/platform_view.dart` — `aria-owns` + the Safari
  comment

### Standards and law

- WCAG 2.2: [2.5.1 Pointer Gestures](https://www.w3.org/WAI/WCAG22/Understanding/pointer-gestures.html) ·
  [2.5.7 Dragging Movements](https://www.w3.org/WAI/WCAG22/Understanding/dragging-movements.html) ·
  [2.5.8 Target Size](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html) ·
  [4.1.2 Name, Role, Value](https://www.w3.org/WAI/WCAG22/Understanding/name-role-value.html) ·
  [full spec](https://www.w3.org/TR/WCAG22/)
- [W3C/OGC Maps for the Web workshop report](https://www.w3.org/2020/maps/report) ·
  [Malvoz/web-maps-wcag-evaluation](https://github.com/Malvoz/web-maps-wcag-evaluation)
- EN 301 549 clauses 9 and 11 · EAA (applies 28 June 2025) · ADA Title II final rule
  (April 2027/2028, as amended by the DOJ interim final rule of April 2026 — see the §3 footnote)

### maplibre-gl-js @ `74590c62`

`src/ui/map.ts:4020-4047`, `:296-303`, `:2684-2692` · `src/ui/default_locale.ts` ·
`src/ui/handler/keyboard.ts` · `src/ui/handler/cooperative_gestures.ts` ·
`src/ui/camera.ts:228-233`, `:762-764`, `:1016-1021` · `src/ui/handler_manager.ts:265-334`, `:694-712` ·
`src/ui/marker.ts:393-402` (`aria-label` at `:398-399`), `:518-556`, `:886-906`
(`_updateAccessibilityRole`, `role=img`/`button`, and the custom-element boundary comment at `:890`) ·
`src/ui/popup.ts` ·
`src/ui/control/{navigation,attribution,geolocate,fullscreen,scale}_control.ts` ·
`src/util/browser.ts:74-85` · `src/css/maplibre-gl.css`
Issues: [#53](https://github.com/maplibre/maplibre-gl-js/issues/53) (the audit) ·
[#357](https://github.com/maplibre/maplibre-gl-js/issues/357) ·
[#359](https://github.com/maplibre/maplibre-gl-js/issues/359) ·
[#360](https://github.com/maplibre/maplibre-gl-js/issues/360) ·
[#361](https://github.com/maplibre/maplibre-gl-js/issues/361) ·
[#362](https://github.com/maplibre/maplibre-gl-js/issues/362) ·
[#363](https://github.com/maplibre/maplibre-gl-js/issues/363) ·
[#364](https://github.com/maplibre/maplibre-gl-js/issues/364) ·
[#7082](https://github.com/maplibre/maplibre-gl-js/issues/7082) ·
[#8020](https://github.com/maplibre/maplibre-gl-js/issues/8020) ·
[#8046](https://github.com/maplibre/maplibre-gl-js/issues/8046)

### Ecosystem

[mapbox-gl-accessibility](https://github.com/mapbox/mapbox-gl-accessibility) ·
[mapbox-gl-native#16128](https://github.com/mapbox/mapbox-gl-native/issues/16128) ·
[flutter#114895](https://github.com/flutter/flutter/issues/114895) ·
[flutter#101439](https://github.com/flutter/flutter/issues/101439) ·
[flutter#113626](https://github.com/flutter/flutter/issues/113626) ·
[flutter#168939](https://github.com/flutter/flutter/pull/168939) ·
[flutter#135504](https://github.com/flutter/flutter/issues/135504) ·
[engine#29531](https://github.com/flutter/engine/pull/29531) ·
[android-maps-compose#305](https://github.com/googlemaps/android-maps-compose/issues/305) ·
[react-native-maps#3500](https://github.com/react-native-maps/react-native-maps/issues/3500) ·
[Android 16 announcement deprecation](https://developer.android.com/about/versions/16/behavior-changes-all) ·
[Flutter web accessibility](https://docs.flutter.dev/ui/accessibility/web-accessibility)
