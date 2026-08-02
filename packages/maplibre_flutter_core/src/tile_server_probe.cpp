// Asserts what selecting a tile server actually buys, against mbgl's own URL
// normalisation — no map, no GPU, no network.
//
//   cmake -B <build> -DMAPLIBRE_FLUTTER_BUILD_HARNESS=ON && ninja tile_server_probe
//   ./tile_server_probe
//
// The claim being pinned is uncomfortable and worth stating plainly: **before
// `mbl_configure_tile_server` existed, the api key passed to `mbl_configure`
// reached nothing.** Not the sub-requests, not even the style URL. Three
// independent gates close it under the default configuration, and each one
// alone is sufficient:
//
//   1. `isCanonicalURL` — every `normalize*URL` returns immediately unless the
//      URL is under the configured scheme, and the default scheme is
//      `maplibre://`. An ordinary `https://api.maptiler.com/…` is handed
//      straight to curl.
//   2. `requiresApiKey` is false for MapLibreConfiguration.
//   3. `apiKeyParameterName` is the empty string for it.
//
// There is also no `{key}` token substitution anywhere in mbgl, so nothing else
// could have been picking the key up.
//
// The sub-request half is the part an app cannot work around by hand: it never
// sees the sprite, glyph and tile URLs — the style document does — so a key
// pasted into the style URL does not reach them.

#include <mbgl/util/mapbox.hpp>
#include <mbgl/util/tile_server_options.hpp>

#include <cstdio>
#include <string>

using namespace mbgl;

namespace {

int failures = 0;

void check(const std::string& what, const std::string& got, const std::string& want) {
    const bool ok = got == want;
    std::printf("%-52s %s\n%*s got %s\n", what.c_str(), ok ? "ok" : "FAIL", 52, "", got.c_str());
    if (!ok) {
        std::printf("%*swant %s\n", 53, "", want.c_str());
        ++failures;
    }
}

} // namespace

int main() {
    const auto maplibre = TileServerOptions::MapLibreConfiguration();
    const auto maptiler = TileServerOptions::MapTilerConfiguration();
    const std::string key = "SECRET";

    std::printf("--- the default configuration: the key reaches nothing ------------\n");

    // Gate 1: not canonical, so normalisation is a no-op and the key is never
    // consulted. This is what every real app passes.
    check("plain https style URL, unchanged",
          util::mapbox::normalizeStyleURL(maplibre, "https://api.maptiler.com/maps/streets/style.json", key),
          "https://api.maptiler.com/maps/streets/style.json");

    // Gates 2 and 3: even a genuinely canonical URL gets no key, because this
    // configuration declares it needs none and names no parameter.
    check("canonical maplibre:// style URL, still no key",
          util::mapbox::normalizeStyleURL(maplibre, "maplibre://maps/style", key),
          "https://demotiles.maplibre.org/style.json");

    // And the scheme an app would actually want is not this one, so it does not
    // resolve at all.
    check("maptiler:// under the DEFAULT configuration",
          util::mapbox::normalizeStyleURL(maplibre, "maptiler://maps/streets", key),
          "maptiler://maps/streets");

    std::printf("\n--- after selecting MapTiler: the key reaches everything ----------\n");

    check("style URL",
          util::mapbox::normalizeStyleURL(maptiler, "maptiler://maps/streets", key),
          "https://api.maptiler.com/maps/streets/style.json?key=SECRET");

    // The half an app cannot do by hand: these URLs come out of the style
    // document, so pasting a key into the style URL never reaches them.
    check("source sub-request",
          util::mapbox::normalizeSourceURL(maptiler, "maptiler://sources/v3", key),
          "https://api.maptiler.com/tiles/v3/tiles.json?key=SECRET");
    check("glyphs sub-request",
          util::mapbox::normalizeGlyphsURL(maptiler, "maptiler://fonts/{fontstack}/{range}.pbf", key),
          "https://api.maptiler.com/fonts/{fontstack}/{range}.pbf?key=SECRET");
    check("sprite sub-request",
          util::mapbox::normalizeSpriteURL(maptiler, "maptiler://sprites/streets/sprite", key),
          "https://api.maptiler.com/maps/streets/sprite?key=SECRET");
    check("tile sub-request",
          util::mapbox::normalizeTileURL(maptiler, "maptiler://tiles/tiles/v3/{z}/{x}/{y}.pbf", key),
          "https://api.maptiler.com/tiles/v3/{z}/{x}/{y}.pbf?key=SECRET");

    // A key is not invented when there is none to use.
    check("no key configured, no query string",
          util::mapbox::normalizeStyleURL(maptiler, "maptiler://maps/streets", ""),
          "https://api.maptiler.com/maps/streets/style.json");

    // Selecting a server does NOT hijack ordinary URLs — an app that already
    // has its key in the URL keeps working exactly as before.
    check("plain https URL is still left alone",
          util::mapbox::normalizeStyleURL(maptiler, "https://example.com/style.json?key=MINE", key),
          "https://example.com/style.json?key=MINE");

    std::printf("\n%s\n", failures == 0 ? "tile_server_probe: PASS" : "tile_server_probe: FAIL");
    return failures == 0 ? 0 : 1;
}
