// Web shim + embind module for maplibre_flutter_core.
//
// Exposes the `MaplibreFlutterCore` JS API that the Dart web controller drives
// (see packages/maplibre_flutter_web/lib/src/core_web/core_wasm_interop.dart):
//   const m = await MaplibreFlutterCore();          // MODULARIZE factory
//   const map = m.createMap({canvas, styleUri, lat, lng, zoom, ...});
//   map.setCamera(...); map.setStyle(...); map.getCamera(); map.resize(...);
//   map.moveBy(...); map.scaleBy(...); map.onReady(cb); map.destroy();
//
// All maps share one main-thread RunLoop, ticked once per animation frame by
// emscripten_set_main_loop. Rendering is Static renderStill on demand (when a map
// is dirty); each completed frame is presented by blitting mbgl's color FBO to the
// canvas's default framebuffer (the same technique as the desktop GL presenter).
// Background tile work runs on the core's std::thread scheduler (Emscripten
// pthreads).

#include <emscripten/bind.h>
#include <emscripten/emscripten.h>
#include <emscripten/html5.h>

#include <mbgl/gfx/backend_scope.hpp>
#include <mbgl/gfx/renderable.hpp>
#include <mbgl/gfx/renderer_backend.hpp>
#include <mbgl/gfx/headless_frontend.hpp>
#include <mbgl/map/camera.hpp>
#include <mbgl/map/map.hpp>
#include <mbgl/map/map_observer.hpp>
#include <mbgl/map/map_options.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/style/style.hpp>
#include <mbgl/util/geo.hpp>
#include <mbgl/util/run_loop.hpp>

#include <GLES3/gl3.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mbgl {
namespace webgl {
void setCanvasSelector(std::string);
}
} // namespace mbgl

using emscripten::val;

namespace {

mbgl::util::RunLoop* g_loop = nullptr;
bool g_loopStarted = false;
int g_nextId = 0;

class WebMap;
// Owns the live maps. createMap appends; WebMap::destroy() erases (and frees).
std::vector<std::unique_ptr<WebMap>>& maps() {
    static std::vector<std::unique_ptr<WebMap>> m;
    return m;
}

void globalTick();

void ensureLoop() {
    if (g_loop == nullptr) {
        g_loop = new mbgl::util::RunLoop();
    }
    if (!g_loopStarted) {
        emscripten_set_main_loop(globalTick, 0, 0);
        g_loopStarted = true;
    }
}

mbgl::Size sizeFromCanvas(const val& canvas, mbgl::Size fallback) {
    const int w = canvas["width"].as<int>();
    const int h = canvas["height"].as<int>();
    return mbgl::Size{static_cast<uint32_t>(w > 0 ? w : static_cast<int>(fallback.width)),
                      static_cast<uint32_t>(h > 0 ? h : static_cast<int>(fallback.height))};
}

class WebMap {
public:
    WebMap(val canvas,
           const std::string& style,
           double lat,
           double lng,
           double zoom,
           double bearing,
           double pitch,
           double pixelRatio)
        : canvas_(canvas), pixelRatio_(static_cast<float>(pixelRatio)) {
        ensureLoop();

        // Register the canvas in Emscripten's module-scope specialHTMLTargets map so
        // emscripten_webgl_create_context can target it by key, independent of whether
        // it is attached to the DOM yet. (Under MODULARIZE there is no global Module,
        // so we reach the module-scope var via EM_ASM + Emval.)
        target_ = "!mlbf_canvas_" + std::to_string(g_nextId++);
        EM_ASM({ specialHTMLTargets[UTF8ToString($0)] = Emval.toValue($1); }, target_.c_str(),
               canvas_.as_handle());
        mbgl::webgl::setCanvasSelector(target_);

        size_ = sizeFromCanvas(canvas_, mbgl::Size{1, 1});

        frontend_ = std::make_unique<mbgl::HeadlessFrontend>(size_, pixelRatio_);
        map_ = std::make_unique<mbgl::Map>(
            *frontend_,
            mbgl::MapObserver::nullObserver(),
            mbgl::MapOptions().withMapMode(mbgl::MapMode::Static).withSize(size_).withPixelRatio(pixelRatio_),
            mbgl::ResourceOptions::Default());

        map_->jumpTo(mbgl::CameraOptions()
                         .withCenter(mbgl::LatLng{lat, lng})
                         .withZoom(zoom)
                         .withBearing(bearing)
                         .withPitch(pitch));
        if (!style.empty()) {
            map_->getStyle().loadURL(style);
        }
        dirty_ = true;
    }

    void setStyle(const std::string& uri) {
        map_->getStyle().loadURL(uri);
        dirty_ = true;
    }

    void setCamera(double lat, double lng, double zoom, double bearing, double pitch) {
        map_->jumpTo(mbgl::CameraOptions()
                         .withCenter(mbgl::LatLng{lat, lng})
                         .withZoom(zoom)
                         .withBearing(bearing)
                         .withPitch(pitch));
        dirty_ = true;
    }

    val getCamera() {
        const mbgl::CameraOptions cam = map_->getCameraOptions();
        val o = val::object();
        o.set("lat", cam.center ? cam.center->latitude() : 0.0);
        o.set("lng", cam.center ? cam.center->longitude() : 0.0);
        o.set("zoom", cam.zoom.value_or(0.0));
        o.set("bearing", cam.bearing.value_or(0.0));
        o.set("pitch", cam.pitch.value_or(0.0));
        return o;
    }

    void resize(double width, double height, double pixelRatio) {
        pixelRatio_ = static_cast<float>(pixelRatio);
        const auto w = static_cast<uint32_t>(width > 0 ? width : 1);
        const auto h = static_cast<uint32_t>(height > 0 ? height : 1);
        size_ = mbgl::Size{w, h};
        // Match the canvas backing store to the render size (blit target = canvas).
        canvas_.set("width", static_cast<int>(w));
        canvas_.set("height", static_cast<int>(h));
        frontend_->setSize(size_);
        map_->setSize(size_);
        dirty_ = true;
    }

    void moveBy(double dx, double dy) {
        map_->moveBy(mbgl::ScreenCoordinate{dx, dy});
        dirty_ = true;
    }

    void scaleBy(double scale, double anchorX, double anchorY) {
        map_->scaleBy(scale, mbgl::ScreenCoordinate{anchorX, anchorY});
        dirty_ = true;
    }

    void onReady(val cb) {
        readyCb_ = cb;
        if (ready_ && !readyCb_.isUndefined()) {
            readyCb_();
        }
    }

    // Remove from the registry (frees this WebMap). The JS handle must not be used
    // afterwards (the Dart controller nulls it on dispose).
    void destroy() {
        auto& all = maps();
        all.erase(std::remove_if(all.begin(), all.end(), [this](const std::unique_ptr<WebMap>& m) { return m.get() == this; }),
                  all.end());
    }

    // Called each animation frame by globalTick.
    void tick() {
        if (!dirty_ || rendering_) {
            return;
        }
        rendering_ = true;
        dirty_ = false;
        map_->renderStill([this](std::exception_ptr e) {
            rendering_ = false;
            if (e) {
                return;
            }
            present();
            if (!ready_) {
                ready_ = true;
                if (!readyCb_.isUndefined()) {
                    readyCb_();
                }
            }
        });
    }

    ~WebMap() {
        map_.reset();
        frontend_.reset();
        EM_ASM({ delete specialHTMLTargets[UTF8ToString($0)]; }, target_.c_str());
    }

private:
    // Blit mbgl's color FBO to the canvas default framebuffer (0), Y-flipped.
    void present() {
        mbgl::gfx::BackendScope guard{*frontend_->getBackend()};
        frontend_->getBackend()->getDefaultRenderable().getResource<mbgl::gfx::RenderableResource>().bind();

        GLint srcFbo = 0;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &srcFbo);

        const auto w = static_cast<GLint>(size_.width);
        const auto h = static_cast<GLint>(size_.height);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(srcFbo));
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glBlitFramebuffer(0, 0, w, h, 0, h, w, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

    val canvas_;
    std::string target_;
    float pixelRatio_ = 1.0f;
    mbgl::Size size_{1, 1};
    std::unique_ptr<mbgl::HeadlessFrontend> frontend_;
    std::unique_ptr<mbgl::Map> map_;
    bool dirty_ = false;
    bool rendering_ = false;
    bool ready_ = false;
    val readyCb_ = val::undefined();
};

void globalTick() {
    if (g_loop != nullptr) {
        g_loop->runOnce();
    }
    // Copy raw pointers first: a tick (renderStill callback) could destroy a map.
    std::vector<WebMap*> snapshot;
    snapshot.reserve(maps().size());
    for (const auto& m : maps()) {
        snapshot.push_back(m.get());
    }
    for (auto* m : snapshot) {
        m->tick();
    }
}

WebMap* createMap(val opts) {
    auto map = std::make_unique<WebMap>(
        opts["canvas"],
        opts["styleUri"].isUndefined() ? std::string{} : opts["styleUri"].as<std::string>(),
        opts["lat"].as<double>(),
        opts["lng"].as<double>(),
        opts["zoom"].as<double>(),
        opts["bearing"].as<double>(),
        opts["pitch"].as<double>(),
        opts["pixelRatio"].as<double>());
    WebMap* raw = map.get();
    maps().push_back(std::move(map));
    return raw;
}

} // namespace

EMSCRIPTEN_BINDINGS(maplibre_flutter_core) {
    emscripten::class_<WebMap>("CoreMap")
        .function("setStyle", &WebMap::setStyle)
        .function("setCamera", &WebMap::setCamera)
        .function("getCamera", &WebMap::getCamera)
        .function("resize", &WebMap::resize)
        .function("moveBy", &WebMap::moveBy)
        .function("scaleBy", &WebMap::scaleBy)
        .function("onReady", &WebMap::onReady)
        .function("destroy", &WebMap::destroy);

    emscripten::function("createMap", &createMap, emscripten::allow_raw_pointers());
}
