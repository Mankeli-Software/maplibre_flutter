// Verifies patches/offline-url-template-regex.patch against mbgl's URL
// canonicalisation directly, with no map, no GPU and no network.
//
//   cmake -B <build> -DMAPLIBRE_FLUTTER_BUILD_HARNESS=ON && ninja offline_url_probe
//   ./offline_url_probe
//
// mbgl builds a std::regex out of a TileServerOptions URL template without
// escaping the template's literal text. In the ECMAScript grammar an unescaped
// `{` opens a quantifier, so a template containing a brace that is NOT one of
// the five recognised tokens is a syntax error. Two of the three built-in
// configurations have one — and one of those is the DEFAULT:
//
//   MapLibre glyphs   /font/{fontstack}/{start}-{end}.pbf
//   MapLibre sprites  /{path}/sprite{scale}.{format}
//
// std::regex then throws regex_error(error_badbrace). The only callers of
// createTokenMap are canonicalize{Source,Glyph,Sprite}URL, and the only caller
// of those is OfflineDownload::activateDownload — on mbgl's file-source thread,
// where nothing catches it. Starting a download therefore aborted the process.
//
// The second half of the bug is silent rather than fatal: isNormalizedSourceURL
// gated createTokenMap on a DIFFERENT token set (any `{...}`) from the one
// createTokenMap can read (the five). A template with an unrecognised token
// passed the gate and came back with an empty map, so the canonical URL was
// rebuilt out of nothing — every glyph range in the style collapsing to
// "maplibre://fonts". Escaping alone would have turned the abort into that.
//
// The MapTiler cases below are lifted from mbgl's own suite
// (test/util/mapbox.test.cpp, TEST(MapTiler, …)) and are the ones that exercise
// the two patched functions. They are here so the patch is shown to preserve
// upstream behaviour, not just to stop the crash.

#include <mbgl/util/mapbox.hpp>
#include <mbgl/util/tile_server_options.hpp>

#include <cstdio>
#include <functional>
#include <regex>
#include <string>

using namespace mbgl;

namespace {

int failures = 0;

void check(const std::string& what, const std::string& got, const std::string& want) {
    const bool ok = got == want;
    std::printf("%-46s %s\n%*s got %s\n", what.c_str(), ok ? "ok" : "FAIL", 46, "", got.c_str());
    if (!ok) {
        std::printf("%*swant %s\n", 47, "", want.c_str());
        ++failures;
    }
}

// Every canonicalise call goes through here: before the patch the MapLibre ones
// do not return at all, and a probe that let the exception escape would abort
// exactly like the download did instead of reporting which case failed. The
// exception is reported as the "value", so one failing case prints one line.
std::string guarded(const std::function<std::string()>& call) {
    try {
        return call();
    } catch (const std::regex_error& e) {
        return "<threw std::regex_error(code " + std::to_string(static_cast<int>(e.code())) + "): " + e.what() + ">";
    }
}

void checkGlyphs(const TileServerOptions& options, const std::string& what, const std::string& url,
                 const std::string& want) {
    check(what, guarded([&] { return util::mapbox::canonicalizeGlyphURL(options, url); }), want);
}

void checkSprites(const TileServerOptions& options, const std::string& what, const std::string& url,
                  const std::string& want) {
    check(what, guarded([&] { return util::mapbox::canonicalizeSpriteURL(options, url); }), want);
}

void checkSource(const TileServerOptions& options, const std::string& what, const std::string& url,
                 const std::string& want) {
    check(what, guarded([&] { return util::mapbox::canonicalizeSourceURL(options, url); }), want);
}

} // namespace

int main() {
    const auto maplibre = TileServerOptions::MapLibreConfiguration();
    const auto maptiler = TileServerOptions::MapTilerConfiguration();
    const auto mapbox = TileServerOptions::MapboxConfiguration();

    std::printf("--- MapLibre (the DEFAULT configuration) -------------------------\n");

    // The reproduction. demotiles' style.json carries exactly this glyphs URL,
    // and OfflineDownload::activateDownload canonicalises it first of all.
    //
    // Unchanged is the right answer, not merely a safe one: MapLibre's glyphs
    // template says {start}-{end} while the style says {range}, so the two do
    // not correspond and there is no canonical form to rewrite it into. Passing
    // the URL through is what leaves the glyph ranges fetchable.
    checkGlyphs(maplibre,
                "glyphs: demotiles (the abort)",
                "https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf",
                "https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf");

    // The same defect one template over. demotiles has no sprite, so this is
    // the shape any other style served from the base URL would hit.
    checkSprites(maplibre,
                 "sprites: base-URL-hosted sprite",
                 "https://demotiles.maplibre.org/styles/osm-bright-gl-style/sprite",
                 "https://demotiles.maplibre.org/styles/osm-bright-gl-style/sprite");

    // The same glyphs template, against a URL that IS the template verbatim.
    //
    // This is the case escaping alone does not fix and the crash hides: the
    // pattern matches, so the gate would pass, and createTokenMap can extract
    // nothing (the template has none of the five names it knows) — leaving
    // canonicalizeGlyphURL to rebuild the URL from the domain alone as
    // "maplibre://fonts", losing every glyph range. The gate refuses a template
    // with no recognised token for exactly this reason.
    checkGlyphs(maplibre,
                "glyphs: URL identical to the template",
                "https://demotiles.maplibre.org/font/{fontstack}/{start}-{end}.pbf",
                "https://demotiles.maplibre.org/font/{fontstack}/{start}-{end}.pbf");

    // The one MapLibre template that has only recognised tokens, so it
    // canonicalises for real — and must survive the patch. This is the source
    // the demotiles style actually declares.
    checkSource(maplibre,
                "source: demotiles tiles.json",
                "https://demotiles.maplibre.org/tiles/tiles.json",
                "maplibre://tiles");

    // ...and back, since a canonical URL that does not normalise to the URL it
    // came from is a 404 rather than a cache hit.
    check("source: round-trips through normalize",
          util::mapbox::normalizeSourceURL(maplibre, "maplibre://tiles", ""),
          "https://demotiles.maplibre.org/tiles/tiles.json");

    std::printf("\n--- MapTiler (mbgl's own expectations, test/util/mapbox.test.cpp) -\n");

    checkSource(maptiler,
                "TEST(MapTiler, SourceURL) v3",
                "https://api.maptiler.com/tiles/v3/tiles.json?key=abcdef",
                "maptiler://sources/v3");
    checkSource(maptiler,
                "TEST(MapTiler, SourceURL) outdoor",
                "https://api.maptiler.com/tiles/outdoor/tiles.json?key=abcdef",
                "maptiler://sources/outdoor");
    checkSource(maptiler,
                "TEST(MapTiler, SourceURL) uuid",
                "https://api.maptiler.com/tiles/7ac429c7-c96e-46dd-8c3e-13d48988986a/tiles.json?key=abcdef",
                "maptiler://sources/7ac429c7-c96e-46dd-8c3e-13d48988986a");

    checkGlyphs(maptiler,
                "TEST(MapTiler, GlyphsURL)",
                "https://api.maptiler.com/fonts/{fontstack}/{range}.pbf",
                "maptiler://fonts/{fontstack}/{range}.pbf");
    checkGlyphs(maptiler,
                "TEST(MapTiler, GlyphsURL) with key",
                "https://api.maptiler.com/fonts/{fontstack}/{range}.pbf?key=abcdef",
                "maptiler://fonts/{fontstack}/{range}.pbf");

    checkSprites(maptiler,
                 "TEST(MapTiler, Sprites)",
                 "https://api.maptiler.com/maps/streets/sprite",
                 "maptiler://sprites/streets/sprite");

    // The pass-through halves of the same tests: a URL that is not the tile
    // server's must come back untouched. These are what a too-loose pattern
    // breaks — note `api.tileserver.com` differs from `api.maptiler.com` only
    // in characters an unescaped `.` would have matched.
    checkSource(maptiler, "TEST(MapTiler, SourceURLPassThrough) dummy", "http://dummy", "http://dummy");
    checkSource(maptiler,
                "TEST(MapTiler, SourceURLPassThrough) other host",
                "https://api.tileserver.com/map?key=1234",
                "https://api.tileserver.com/map?key=1234");
    checkSource(maptiler, "TEST(MapTiler, SourceURLPassThrough) empty", "", "");
    checkGlyphs(maptiler, "TEST(MapTiler, GlyphsURLPassThrough) dummy", "http://dummy", "http://dummy");
    checkGlyphs(maptiler,
                "TEST(MapTiler, GlyphsURLPassThrough) other host",
                "https://api.tileserver.com/map?key=1234",
                "https://api.tileserver.com/map?key=1234");
    checkGlyphs(maptiler, "TEST(MapTiler, GlyphsURLPassThrough) empty", "", "");
    checkSprites(maptiler, "TEST(MapTiler, SpritesURLPassThrough) dummy", "http://dummy", "http://dummy");
    checkSprites(maptiler,
                 "TEST(MapTiler, SpritesURLPassThrough) other host",
                 "https://api.tileserver.com/map?key=1234",
                 "https://api.tileserver.com/map?key=1234");
    checkSprites(maptiler, "TEST(MapTiler, SpritesURLPassThrough) empty", "", "");

    std::printf("\n--- Mapbox: the gate and the extractor see different strings -------\n");

    // isNormalizedSourceURL matches the whole URL; createTokenMap matches only
    // the PATH. A template whose last token sits at the end can have that group
    // satisfied by "?access_token=…" in the gate and by nothing in the
    // extractor, so the gate passes and extraction comes back empty. Without a
    // guard on the empty map the caller emits "mapbox://sprites" and throws the
    // path away — the same defect as the glyphs case, reached a different way.
    checkSprites(mapbox,
                 "sprites: gate satisfied by the query only",
                 "https://api.mapbox.com/styles/v1/mapbox/streets-v10/sprite?access_token=key",
                 "https://api.mapbox.com/styles/v1/mapbox/streets-v10/sprite?access_token=key");
    checkSprites(mapbox,
                 "sprites: the same URL without a query",
                 "https://api.mapbox.com/styles/v1/mapbox/streets-v10/sprite.png",
                 "mapbox://sprites/mapbox/streets-v10.png");

    std::printf("\n%s\n", failures == 0 ? "offline_url_probe: PASS" : "offline_url_probe: FAIL");
    return failures == 0 ? 0 : 1;
}
