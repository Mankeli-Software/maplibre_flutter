// JPEG/WebP decode stubs for the Android NDK core (experimental core-on-Android,
// CLAUDE.md §3). mbgl's image.cpp dispatches by magic bytes to decodePNG/decodeJPEG/
// decodeWEBP; we keep libpng (sprite sheets + glyph atlases use PNG) but stub JPEG and
// WebP, which are only needed for *raster* tile layers — the POC targets vector styles
// (demotiles, OpenFreeMap), so these are never exercised. Stubbing avoids vendoring
// libjpeg-turbo (which refuses add_subdirectory/FetchContent) and libwebp for the NDK.
// If a raster JPEG/WebP image is ever fetched, the throw is caught by mbgl's tile
// loader (that image is dropped, no crash) — make them real if raster support is added.
#include <mbgl/util/image.hpp>

#include <stdexcept>

namespace mbgl {

PremultipliedImage decodeJPEG(const uint8_t*, size_t) {
    throw std::runtime_error(
        "maplibre_flutter_core: JPEG decode is unsupported on the Android core POC");
}

PremultipliedImage decodeWEBP(const uint8_t*, size_t) {
    throw std::runtime_error(
        "maplibre_flutter_core: WebP decode is unsupported on the Android core POC");
}

} // namespace mbgl
