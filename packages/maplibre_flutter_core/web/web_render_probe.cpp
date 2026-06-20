// Render probe: instantiate an mbgl Map in WASM and render one still frame to a
// WebGL2 canvas, reporting whether the frame has content. This is the milestone-2
// proof that the engine RUNS (not just compiles) in the browser. Not shipped.
//
// Static mode + emscripten_set_main_loop: the browser event loop cannot be blocked,
// so we kick an async renderStill() and tick RunLoop::runOnce() each frame; the
// fetch HTTP source delivers tiles between ticks, and renderStill's callback fires
// once the still frame is complete.

#include <mbgl/gfx/headless_frontend.hpp>
#include <mbgl/map/camera.hpp>
#include <mbgl/map/map.hpp>
#include <mbgl/map/map_observer.hpp>
#include <mbgl/map/map_options.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/style/style.hpp>
#include <mbgl/util/geo.hpp>
#include <mbgl/util/image.hpp>
#include <mbgl/util/run_loop.hpp>

#include <emscripten.h>
#include <emscripten/html5.h>

#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>

namespace mbgl {
namespace webgl {
void setCanvasSelector(std::string);
}
} // namespace mbgl

namespace {

std::unique_ptr<mbgl::util::RunLoop> g_loop;
std::unique_ptr<mbgl::HeadlessFrontend> g_frontend;
std::unique_ptr<mbgl::Map> g_map;

void onStill(std::exception_ptr e) {
    if (e) {
        std::fprintf(stderr, "PROBE: renderStill error\n");
        std::fflush(stderr);
        return;
    }
    mbgl::PremultipliedImage img = g_frontend->readStillImage();
    std::size_t nonZero = 0;
    const std::size_t n = img.bytes();
    for (std::size_t i = 0; i < n; ++i) {
        if (img.data[i] != 0) ++nonZero;
    }
    std::fprintf(stderr, "PROBE: FRAME READY %ux%u nonzero=%zu/%zu\n", img.size.width, img.size.height, nonZero, n);
    std::fflush(stderr);
}

void tick() {
    if (g_loop) {
        g_loop->runOnce();
    }
    static int n = 0;
    if (++n % 120 == 0) {
        std::fprintf(stderr, "PROBE: heartbeat tick=%d\n", n);
        std::fflush(stderr);
    }
}

} // namespace

int main() {
    g_loop = std::make_unique<mbgl::util::RunLoop>();
    mbgl::webgl::setCanvasSelector("#canvas");

    const mbgl::Size size{512, 512};
    g_frontend = std::make_unique<mbgl::HeadlessFrontend>(size, 1.0f);
    g_map = std::make_unique<mbgl::Map>(
        *g_frontend,
        mbgl::MapObserver::nullObserver(),
        mbgl::MapOptions().withMapMode(mbgl::MapMode::Static).withSize(size).withPixelRatio(1.0f),
        mbgl::ResourceOptions::Default());

    g_map->getStyle().loadURL("https://demotiles.maplibre.org/style.json");
    g_map->jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{30.0, 10.0}).withZoom(2.0));

    std::fprintf(stderr, "PROBE: start\n");
    std::fflush(stderr);
    g_map->renderStill(onStill);

    emscripten_set_main_loop(tick, 0, 0);
    return 0;
}
