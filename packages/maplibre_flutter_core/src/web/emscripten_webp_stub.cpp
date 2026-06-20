// WebP decode stub for the WASM build. Emscripten has no libwebp port, and base
// vector styles (demotiles / OpenFreeMap) don't use WebP, so we stub the decoder
// that platform/default/util/image.cpp dispatches to. PNG and JPEG come from the
// Emscripten libpng / libjpeg ports.
#include <mbgl/util/image.hpp>

#include <stdexcept>

namespace mbgl {

PremultipliedImage decodeWEBP(const uint8_t*, size_t) {
    throw std::runtime_error("WebP decoding is not available in the maplibre_flutter_core WASM build");
}

} // namespace mbgl
