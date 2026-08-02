# Offline downloads abort the process under the default tile server — upstream MapLibre defect

**Status: patched locally, NOT yet reported upstream.** See
[Opening the upstream PR](#opening-the-upstream-pr) — that is the outstanding work.

Found 2026-08-01, the second time offline regions were attempted here. The first
attempt (2026-08-01, backed out — see `docs/offline-design.md`) hit it, could not
explain it, and shipped nothing rather than ship a call that kills the host process.

Severity is the unusual part: this is not a rendering artifact. `createOfflineRegion`
followed by `setOfflineRegionDownloadState(Active)` — the two calls that ARE the
offline feature — terminate the process, on the **default** `TileServerOptions`, for
**any** style served from the configured base URL. There is no error to catch and no
defensive posture available to a caller, because it is raised on mbgl's own
file-source thread:

```
libc++abi: terminating due to uncaught exception of type std::__1::regex_error
Abort trap: 6
```

---

## The defect

`util::mapbox::createTokenMap` builds a `std::regex` out of a `TileServerOptions` URL
template, replacing the five tokens it knows with a capture group and leaving
everything else as-is:

```cpp
// src/mbgl/util/mapbox.cpp:79 (before the patch)
std::regex tokenPattern(R"(\{domain\}|\{path\}|\{directory\}|\{filename\}|\{extension\})");
std::string templatePattern = std::regex_replace(
    urlTemplate, tokenPattern, "(.+)", std::regex_constants::match_any);
std::regex r2(templatePattern);   // <- the template's literal text, as a PATTERN
```

The template's remaining characters are literal text, and are not escaped. In the
ECMAScript grammar an unescaped `{` opens a quantifier — so a template containing a
brace that is **not** one of those five names is a syntax error, not a brace.

Two of the three built-in configurations have one, and one of those two is the
default (`TileServerOptions::DefaultConfiguration()` returns
`MapLibreConfiguration()`, `src/mbgl/util/tile_server_options.cpp:213`):

| Configuration | Template | Pattern built | Result |
| --- | --- | --- | --- |
| **MapLibre** glyphs | `/font/{fontstack}/{start}-{end}.pbf` | `/font/{fontstack}/{start}-{end}.pbf` | `regex_error(error_badbrace)` |
| **MapLibre** sprites | `/{path}/sprite{scale}.{format}` | `/(.+)/sprite{scale}.{format}` | `regex_error(error_badbrace)` |
| MapLibre source | `/tiles/{domain}.json` | `/tiles/(.+).json` | ok |
| Mapbox, MapTiler | (only the five known tokens) | — | ok |

Nothing catches it. `createTokenMap`'s only callers are
`canonicalize{Source,Glyph,Sprite}URL`, and their only caller is
`OfflineDownload::activateDownload` — on the database/online file-source thread:

```cpp
// platform/default/src/mbgl/storage/offline_download.cpp:258
parser.glyphURL = util::mapbox::canonicalizeGlyphURL(tileServerOptions, parser.glyphURL);
```

`parser.glyphURL` for the demo style is
`https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf` — under the base URL,
so the gate below lets it through — and the process is gone.

### The second half, which is silent rather than fatal

Escaping alone would have converted the abort into a wrong answer.
`isNormalizedSourceURL` is the gate that decides whether `createTokenMap` runs at all,
and it recognised a **different** token set from the one `createTokenMap` can extract:

```cpp
// src/mbgl/util/mapbox.cpp:107 (before the patch)
std::regex tokenPattern(R"(\{.+\})");            // ANY braces, greedy
std::string urlPattern = std::regex_replace(urlTemplate, tokenPattern, "(.+)", …) + "(.*)";
std::string pattern(baseURL + urlPattern);       // baseURL unescaped too
```

Greedy `\{.+\}` collapses `{fontstack}/{start}-{end}` to one group, so the MapLibre
glyphs template matched — and `createTokenMap`, which only knows the five names, would
have come back with an **empty map**. `canonicalizeGlyphURL` then rebuilds the URL out
of that nothing:

```
https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf   ->   maplibre://fonts
```

Every glyph range in the style collapses to one meaningless URL. That is a crash
replaced by a download that appears to run and produces an unusable region, which is
worse.

`baseURL` is also concatenated into the pattern unescaped, so its `.` characters match
any character — `https://api.maptiler.com` also matches `https://apizmaptilerxcom`.
Not exploitable in practice (the surrounding literals still have to match) but wrong.

## The fix

`patches/offline-url-template-regex.patch`, marker `MBL_URL_TEMPLATE_ESCAPE`. One new
helper compiles a template to a pattern — the five known tokens become capture groups,
**everything else is escaped** — and both functions now use it, so the gate accepts
exactly what the extractor can read.

Two more guards, because "the gate agrees with the extractor" needed saying twice:

- **`isNormalizedSourceURL` refuses a template with no recognised token.** Escaping alone
  still lets one through: the pattern is then a pure literal, a URL identical to the template
  matches it, and `createTokenMap` returns an empty map because it recognises none of those
  names — landing on `maplibre://fonts` after all, just from a rarer input.
- **Each `canonicalize*URL` returns the URL unchanged when the map comes back empty.** The
  gate `regex_match`es the whole URL while `createTokenMap` `regex_search`es only the *path*,
  so a template whose last token sits at the end can have that group satisfied by
  `?access_token=…` in the gate and by nothing in the extractor. Mapbox's sprites template
  does exactly this; the probe pins both the query and the no-query form.

Consequences for the MapLibre default configuration, all of them correct:

- glyphs and sprites no longer match, so their URLs pass through unchanged. That is
  the right answer and not merely a safe one: MapLibre's glyphs template says
  `{start}-{end}` while the demo style says `{range}`, so the two do not correspond
  and there is no canonical form to rewrite into. Passing through is what leaves the
  glyph ranges fetchable.
- `/tiles/{domain}.json` still canonicalises, and round-trips:
  `https://demotiles.maplibre.org/tiles/tiles.json` -> `maplibre://tiles` ->
  `https://demotiles.maplibre.org/tiles/tiles.json`.

One adjacent bug is fixed in passing, because the escaping change exposes it: the
extraction loop read `m[1]` from each successive **match** rather than each capture
**group** of one match, so a template with more than one token left every token after
the first empty. Mapbox's sprites template has three
(`/styles/v1{directory}{filename}/sprite{extension}`), and its canonical URL was
losing the filename and the extension.

## Evidence

`packages/maplibre_flutter_core/src/offline_url_probe.cpp` — ctest label `hermetic`,
no GPU, no network, ~0.2 s. It asserts the two crashing cases **and** the MapTiler
expectations lifted from mbgl's own `test/util/mapbox.test.cpp` that the patch must
not change.

Without the patch (`git -C third_party/maplibre-native checkout -- src/mbgl/util/mapbox.cpp`,
rebuild, run):

```
--- MapLibre (the DEFAULT configuration) -------------------------
glyphs: demotiles (the abort)                  FAIL
       got <threw std::regex_error(code 8): The expression contained an invalid range in a {} expression.>
      want https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf
sprites: base-URL-hosted sprite                FAIL
       got <threw std::regex_error(code 8): …>
source: demotiles tiles.json                   ok
…13 MapTiler cases…                            ok
offline_url_probe: FAIL
```

With it, all 17 cases pass. The end-to-end proof is in the Dart native suite:
`offline regions > a download runs to completion — the case that used to abort the
process` creates a region over London at z0–1 against `demotiles`, activates it, and
waits for `completedResourceCount >= requiredResourceCount` with
`requiredResourceCountIsPrecise`. Reaching that is two claims at once — the path no
longer aborts, **and** the URLs it produces are ones the server answers. A crash-only
fix hangs there instead, because a wrongly canonicalised glyph URL 404s forever.

## Two more process-aborts in the same download path

Found while fixing the one above, by asking what ELSE on that thread is unchecked. Both are
the same shape — a value dereferenced without the test every other consumer performs, on a
thread where an app has nothing to catch — and both ship as
`patches/offline-download-null-guards.patch`, marker `MBL_OFFLINE_NULL_GUARDS`.

1. **`parser.parse(*styleResponse.data)` on a no-content response.**
   `OfflineDownload::activateDownload` (`offline_download.cpp:255`) and `getStatus` (`:153`)
   dereference `Response::data` without checking it. It is documented as present only for
   non-error, non-notModified responses, and is left null for an HTTP 204
   (`http_file_source.cpp`) and for a stored resource whose blob is NULL
   (`offline_database.cpp`). Every other consumer of a style response in mbgl tests
   `noContent` first — `style_impl.cpp`, `tile_source.cpp`, `sprite_loader.cpp`,
   `geojson_source.cpp`. `offline_download.cpp` is the only one that does not. A proxy
   answering 204 for a style URL therefore SIGSEGVs the process instead of failing the region.

2. **`queueTiles` indexes `tileset.tiles[0]` with `operator[]`** (`:455`). A TileJSON with
   `"tiles": []` converts successfully — `conversion/tileset.cpp` only rejects a missing or
   non-array member and the fill loop simply does not run — so the vector can be empty. The
   render path reads the same field with `at()` (`tile_loader_impl.hpp:24`), which at least
   throws; this is the one place that reads past the end.

Both fixes are early returns. A region that cannot be enumerated stops with
`requiredResourceCountIsPrecise` still false, which is already how a caller learns the pyramid
is not known.

## Opening the upstream PR

**TODO — not done yet.** One issue, one PR.

1. **Issue** on `maplibre/maplibre-native`. Lead with the blast radius, because it is
   easy to under-read as a URL-parsing nit: offline downloads abort the host process
   on the **default** configuration, which means every consumer of
   `DatabaseFileSource::createOfflineRegion` that has not overridden
   `TileServerOptions`. Note that the Android and iOS SDKs ship
   `MapLibreConfiguration` as their default too, so this is not desktop-specific — it
   only looks that way because most SDK users configure MapTiler or a self-hosted
   server, whose templates happen to use only the five known tokens.
2. **PR on `maplibre/maplibre-native`** — the patch, plus the probe's cases rewritten
   as gtest in `test/util/mapbox.test.cpp`. **This is the one of the three patches we
   carry that arrives with its test**, so lead with that; the existing MapTiler cases
   there already pass before and after, which is the argument that the fix is not a
   behaviour change for anyone currently working.

   Expect two maintainer questions. *"Why change `isNormalizedSourceURL` as well —
   isn't escaping `createTokenMap` enough?"*: no, and the "second half" section above
   is the answer — the gate and the extractor disagreeing about what a token is is
   the actual bug, and escaping alone turns the abort into `maplibre://fonts`.
   *"Should the MapLibre glyphs template be fixed to `{range}` instead?"*: that is a
   separate, arguably correct change, but it fixes one configuration and leaves the
   crash live for anyone whose own template has a non-token brace.

3. **A second, separate PR for the two null/bounds guards.** They are unrelated to the regex
   defect and much easier to land on their own — each is a one-line early return, and the
   argument for each is "every other consumer in this repo already does this", which is a
   one-line diff to point at.

There is **no gl-js mirror** for any of it: maplibre-gl-js has no offline download path and no
`TileServerOptions` templating, so nothing there is analogous.
