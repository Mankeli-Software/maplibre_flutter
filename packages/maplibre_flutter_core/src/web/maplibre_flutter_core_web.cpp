// Web shim + embind module for maplibre_flutter_core.
//
// Exposes the `MaplibreFlutterCore` JS API that the Dart web controller drives
// (see packages/maplibre_flutter_web/lib/src/core_web/core_wasm_interop.dart):
//   const m = await MaplibreFlutterCore();          // MODULARIZE factory
//   const map = m.createMap({canvas, styleUri, lat, lng, zoom, ..., continuous});
//   map.setCamera(...); map.setStyle(...); map.getCamera(); map.resize(...);
//   map.moveBy(...); map.scaleBy(...); map.onReady(cb); map.destroy();
//
// All maps share one main-thread RunLoop, ticked once per animation frame by
// emscripten_set_main_loop. Rendering defaults to Continuous mode (like the
// desktop tier): every camera/style change and each tile that streams in
// invalidates mbgl, the HeadlessFrontend's asyncInvalidate renders a frame off
// the RunLoop (driven by the per-frame runOnce), and a MapObserver presents each
// finished frame — partial frames show immediately and refine as tiles arrive,
// so pan/zoom stay smooth instead of stalling on a full renderStill. A Static
// path (one complete frame on demand) is kept behind continuous=false. Each
// finished frame is presented by blitting mbgl's color FBO to the canvas's
// default framebuffer (the same technique as the desktop GL presenter).
// Background tile work runs on the core's std::thread scheduler (Emscripten
// pthreads).

#include <emscripten/bind.h>
#include <emscripten/emscripten.h>
#include <emscripten/em_asm.h>
#include <emscripten/html5.h>

#include <mbgl/gfx/backend_scope.hpp>
#include <mbgl/gfx/headless_backend.hpp>
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
#include <cmath>
#include <cstdint>
#include <memory>
#include <optional>
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

// Observes a Continuous-mode map: each finished frame (partial → refined as tiles
// stream in) is presented to the canvas. Mirrors the desktop FrameObserver. The
// out-of-line method body (after WebMap) calls back into the owning map.
class WebFrameObserver final : public mbgl::MapObserver {
public:
    explicit WebFrameObserver(WebMap* map) : map_(map) {}
    void onDidFinishRenderingFrame(const RenderFrameStatus&) override;

private:
    WebMap* map_;
};

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
           double pixelRatio,
           bool continuous)
        : canvas_(canvas), pixelRatio_(static_cast<float>(pixelRatio)), continuous_(continuous) {
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

        if (continuous_) {
            // Continuous mode: mbgl renders partial frames immediately and refines
            // them as tiles stream in. invalidateOnUpdate drives renderFrame off the
            // RunLoop on every map mutation / tile load; the observer presents each
            // finished frame. NoFlush: the present blit is same-context and ordered
            // after the render, so no per-frame glFinish stall is needed.
            observer_ = std::make_unique<WebFrameObserver>(this);
            frontend_ = std::make_unique<mbgl::HeadlessFrontend>(
                size_, pixelRatio_, mbgl::gfx::HeadlessBackend::SwapBehaviour::NoFlush,
                mbgl::gfx::ContextMode::Unique, std::nullopt, /*invalidateOnUpdate=*/true);
            map_ = std::make_unique<mbgl::Map>(
                *frontend_, *observer_,
                mbgl::MapOptions().withMapMode(mbgl::MapMode::Continuous).withSize(size_).withPixelRatio(pixelRatio_),
                mbgl::ResourceOptions::Default());
        } else {
            // Static mode (fallback): one complete frame per renderStill, driven on
            // demand by tick() when the map is dirty.
            frontend_ = std::make_unique<mbgl::HeadlessFrontend>(size_, pixelRatio_);
            map_ = std::make_unique<mbgl::Map>(
                *frontend_, mbgl::MapObserver::nullObserver(),
                mbgl::MapOptions().withMapMode(mbgl::MapMode::Static).withSize(size_).withPixelRatio(pixelRatio_),
                mbgl::ResourceOptions::Default());
        }

        map_->jumpTo(mbgl::CameraOptions()
                         .withCenter(mbgl::LatLng{lat, lng})
                         .withZoom(zoom)
                         .withBearing(bearing)
                         .withPitch(pitch));
        if (!style.empty()) {
            map_->getStyle().loadURL(style);
        }
        dirty_ = true;

        // Canvas pointer gestures: drag pans, wheel zooms. mbgl-core has no gesture
        // recognition, so we drive moveBy/scaleBy from raw events (as gl-js does
        // internally). Registered on the canvas; a drag that leaves it ends.
        emscripten_set_mousedown_callback(target_.c_str(), this, EM_FALSE, &WebMap::onMouseDown);
        emscripten_set_mousemove_callback(target_.c_str(), this, EM_FALSE, &WebMap::onMouseMove);
        emscripten_set_mouseup_callback(target_.c_str(), this, EM_FALSE, &WebMap::onMouseUp);
        emscripten_set_wheel_callback(target_.c_str(), this, EM_FALSE, &WebMap::onWheel);
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

    // Eased camera transition over [durationMs] (the fly-to path). Stepped in tick().
    void animateTo(double lat, double lng, double zoom, double bearing, double pitch, double durationMs) {
        const mbgl::CameraOptions cam = map_->getCameraOptions();
        fromLat_ = cam.center ? cam.center->latitude() : lat;
        fromLng_ = cam.center ? cam.center->longitude() : lng;
        fromZoom_ = cam.zoom.value_or(zoom);
        fromBearing_ = cam.bearing.value_or(bearing);
        fromPitch_ = cam.pitch.value_or(pitch);
        toLat_ = lat;
        toLng_ = lng;
        toZoom_ = zoom;
        toBearing_ = bearing;
        toPitch_ = pitch;

        // Fly-to zoom-out arc ("zoom back"): for long flights, dip the zoom toward a
        // level that fits both endpoints at the time-midpoint, then zoom back in —
        // matching gl-js / the desktop tier. Only engage when fitting the two centers
        // actually needs a lower zoom than both endpoints, so +/- buttons and short
        // hops just lerp with no overshoot (mirrors the macOS fly-to dip fix).
        double dLng = std::fabs(toLng_ - fromLng_);
        if (dLng > 180.0) dLng = 360.0 - dLng; // shortest way around the globe
        const double dLat = std::fabs(toLat_ - fromLat_);
        const double span = std::max(std::max(dLng, dLat), 1e-6);
        const double cssWidth = size_.width / (pixelRatio_ > 0.0f ? pixelRatio_ : 1.0f);
        // Zoom at which `span` degrees fits the viewport (whole world = 512px·2^z = 360°).
        const double fitZoom = std::log2(360.0 * cssWidth / (512.0 * span));
        peakZoom_ = fitZoom < 0.0 ? 0.0 : fitZoom;
        useDip_ = cssWidth >= 1.0 && peakZoom_ < std::min(fromZoom_, toZoom_) - 0.25;

        animStartMs_ = emscripten_get_now();
        animDurMs_ = durationMs > 1.0 ? durationMs : 1.0;
        animating_ = true;
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
        // NB: we do NOT resize the canvas backing store here. Setting canvas.width/
        // height clears the WebGL drawing buffer to transparent; if we did it now, the
        // browser would composite the cleared canvas before the next frame renders —
        // a white blink on resize. Instead present() resizes the backing store right
        // before the blit, so the clear and the blit are in the same turn (no blink).
        frontend_->setSize(size_);
        map_->setSize(size_);
        dirty_ = true;
    }

    // Like resize(), but renders the new-size frame synchronously in this call. Called
    // from the Dart canvas ResizeObserver, which fires after layout and before paint,
    // so the correctly-sized frame is composited in the SAME paint — no 1-frame stretch
    // (the per-tick syncSize polling notices a CSS-box change a frame late, which is
    // what caused the stretch). The first call also hands sizing authority to the
    // observer: it disables syncSize's polling so the two don't both drive sizing.
    void resizeSync(double width, double height, double pixelRatio) {
        autoSize_ = false;
        resize(width, height, pixelRatio);
        // map_->setSize() synchronously invalidates the frontend (Map::onUpdate →
        // frontend.update → asyncInvalidate), so one runOnce() renders the new size now
        // → the observer presents it. Not re-entrant: the ResizeObserver callback runs
        // outside the rAF tick (after layout), not nested in globalTick.
        if (continuous_ && g_loop != nullptr) {
            g_loop->runOnce();
        }
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

    // Continuous mode: the observer calls this after mbgl finishes each frame.
    // Present it to the canvas and complete onReady on the first frame.
    void onFrameRendered() {
        present();
        signalReady();
    }

    // Called each animation frame by globalTick.
    void tick() {
        syncSize();
        stepAnimation();
        if (continuous_) {
            // Continuous mode renders itself: camera/size mutations and tile loads
            // invalidate the frontend, which renders off the RunLoop (driven by
            // globalTick's runOnce); the observer presents. Nothing to do here.
            return;
        }
        // Static mode: render one complete frame on demand when dirty.
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
            signalReady();
        });
    }

    ~WebMap() {
        emscripten_set_mousedown_callback(target_.c_str(), nullptr, EM_FALSE, nullptr);
        emscripten_set_mousemove_callback(target_.c_str(), nullptr, EM_FALSE, nullptr);
        emscripten_set_mouseup_callback(target_.c_str(), nullptr, EM_FALSE, nullptr);
        emscripten_set_wheel_callback(target_.c_str(), nullptr, EM_FALSE, nullptr);
        // Destroy the map before the frontend and observer it references.
        map_.reset();
        frontend_.reset();
        observer_.reset();
        EM_ASM({ delete specialHTMLTargets[UTF8ToString($0)]; }, target_.c_str());
    }

private:
    void signalReady() {
        if (!ready_) {
            ready_ = true;
            if (!readyCb_.isUndefined()) {
                readyCb_();
            }
        }
    }

    // Copy mbgl's offscreen color FBO into the canvas default framebuffer (0).
    //
    // ORIENTATION — copy straight, do NOT flip. mbgl's GL HeadlessBackend renders
    // into an offscreen renderbuffer FBO, producing the same pixel layout it would
    // draw straight into the default framebuffer (which the browser composits
    // right-side-up). So a 1:1 blit (src rect == dst rect) keeps the map upright.
    // A vertical flip here renders the map upside down — that was the orientation
    // half of the "map flips 180° on resize" report.
    //
    // CACHE — keep mbgl's GL state truthful. mbgl's gl::Context caches the framebuffer
    // binding in a write-through State<> wrapper and skips redundant glBindFramebuffer
    // calls. If we leave a different framebuffer bound when we return, the cache
    // desyncs and mbgl's NEXT render targets whatever is actually bound — FBO 0 —
    // instead of its offscreen color FBO. That desync was the other half of the resize
    // bug: in steady state the desync made mbgl render straight into FBO 0 (upright,
    // and this blit early-returned), but a resize allocates a fresh offscreen FBO id,
    // forcing one real render into the offscreen FBO — which this blit then flipped
    // → one upside-down frame, until the next mutation desynced the cache back to
    // FBO 0. We fix both halves: blit without a flip, and re-bind mbgl's color FBO
    // before returning so its cache stays truthful (the desktop GL presenter's
    // GlStateGuard discipline). Now every frame deterministically renders into the
    // offscreen FBO and blits 1:1 to the canvas.
    void present() {
        mbgl::gfx::BackendScope guard{*frontend_->getBackend()};
        // Bind mbgl's color renderable so the draw binding is reliably its color FBO
        // (and so mbgl's State<> cache is set to that FBO), then read it back as the
        // blit source.
        frontend_->getBackend()->getDefaultRenderable().getResource<mbgl::gfx::RenderableResource>().bind();

        GLint srcFbo = 0;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &srcFbo);
        if (srcFbo == 0) {
            // mbgl already rendered into FBO 0; the frame is on screen. Blitting 0->0
            // would be a GL feedback-loop error, so leave it as-is.
            return;
        }
        // Sync the canvas backing store to the render size here — immediately before
        // the blit — so the clear it triggers and the blit happen in one turn (no
        // resize white blink; see resize()). Guarded so we only touch it on a change.
        if (canvasW_ != size_.width || canvasH_ != size_.height) {
            canvas_.set("width", static_cast<int>(size_.width));
            canvas_.set("height", static_cast<int>(size_.height));
            canvasW_ = size_.width;
            canvasH_ = size_.height;
        }
        const auto w = static_cast<GLint>(size_.width);
        const auto h = static_cast<GLint>(size_.height);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(srcFbo));
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        // Re-bind mbgl's color FBO (read+draw) so its State<> cache stays truthful —
        // see the cache note above. This is the line that fixes the resize flip.
        glBindFramebuffer(GL_FRAMEBUFFER, static_cast<GLuint>(srcFbo));
    }

    // Auto-size the render surface to the canvas's CSS size (× DPR) so the map is
    // crisp and correctly proportioned, following layout/resize without a Dart hop.
    void syncSize() {
        // Once the Dart ResizeObserver has driven a resize (resizeSync), it owns sizing
        // — it's timely (fires before paint) whereas this per-tick poll is a frame late
        // (the stretch). Until then this is the fallback (initial size / no observer).
        if (!autoSize_) {
            return;
        }
        double cssW = 0;
        double cssH = 0;
        if (emscripten_get_element_css_size(target_.c_str(), &cssW, &cssH) != EMSCRIPTEN_RESULT_SUCCESS) {
            return;
        }
        if (cssW < 1.0 || cssH < 1.0) {
            return;
        }
        const auto w = static_cast<uint32_t>(cssW * pixelRatio_);
        const auto h = static_cast<uint32_t>(cssH * pixelRatio_);
        if (w == size_.width && h == size_.height) {
            return;
        }
        resize(static_cast<double>(w), static_cast<double>(h), pixelRatio_);
    }

    void stepAnimation() {
        if (!animating_) {
            return;
        }
        double t = (emscripten_get_now() - animStartMs_) / animDurMs_;
        if (t >= 1.0) {
            t = 1.0;
            animating_ = false;
        }
        // easeInOutCubic
        const double e = t < 0.5 ? 4.0 * t * t * t : 1.0 - std::pow(-2.0 * t + 2.0, 3.0) / 2.0;
        double zoom = lerp(fromZoom_, toZoom_, e);
        if (useDip_) {
            // Symmetric dip toward the fit zoom, peaking at the time-midpoint
            // (sin(pi*t) is 0 at both ends, 1 at t=0.5). Uses linear t (not eased) so
            // the zoom-out is centered in time.
            constexpr double kPi = 3.14159265358979323846;
            const double dipAmount = std::min(fromZoom_, toZoom_) - peakZoom_;
            zoom -= dipAmount * std::sin(kPi * t);
        }
        map_->jumpTo(mbgl::CameraOptions()
                         .withCenter(mbgl::LatLng{lerp(fromLat_, toLat_, e), lerp(fromLng_, toLng_, e)})
                         .withZoom(zoom)
                         .withBearing(lerp(fromBearing_, toBearing_, e))
                         .withPitch(lerp(fromPitch_, toPitch_, e)));
        dirty_ = true;
    }

    static double lerp(double a, double b, double t) { return a + (b - a) * t; }

    static EM_BOOL onMouseDown(int, const EmscriptenMouseEvent* e, void* ud) {
        auto* m = static_cast<WebMap*>(ud);
        m->dragging_ = true;
        m->lastX_ = e->targetX;
        m->lastY_ = e->targetY;
        m->animating_ = false; // a press cancels any in-flight fly-to
        return EM_TRUE;
    }
    static EM_BOOL onMouseMove(int, const EmscriptenMouseEvent* e, void* ud) {
        auto* m = static_cast<WebMap*>(ud);
        if (!m->dragging_) {
            return EM_FALSE;
        }
        const double dx = (e->targetX - m->lastX_) * m->pixelRatio_;
        const double dy = (e->targetY - m->lastY_) * m->pixelRatio_;
        m->lastX_ = e->targetX;
        m->lastY_ = e->targetY;
        m->map_->moveBy(mbgl::ScreenCoordinate{dx, dy});
        m->dirty_ = true;
        return EM_TRUE;
    }
    static EM_BOOL onMouseUp(int, const EmscriptenMouseEvent*, void* ud) {
        static_cast<WebMap*>(ud)->dragging_ = false;
        return EM_FALSE;
    }
    static EM_BOOL onWheel(int, const EmscriptenWheelEvent* e, void* ud) {
        auto* m = static_cast<WebMap*>(ud);
        const double factor = std::pow(2.0, -e->deltaY / 120.0 * 0.5);
        m->map_->scaleBy(factor,
                         mbgl::ScreenCoordinate{e->mouse.targetX * m->pixelRatio_,
                                                e->mouse.targetY * m->pixelRatio_});
        m->dirty_ = true;
        return EM_TRUE;
    }

    val canvas_;
    std::string target_;
    float pixelRatio_ = 1.0f;
    mbgl::Size size_{1, 1};
    // Backing-store size currently applied to the canvas (synced lazily in present()
    // to avoid the resize white blink — see resize()). 0 = not yet applied.
    uint32_t canvasW_ = 0;
    uint32_t canvasH_ = 0;
    // True until the Dart ResizeObserver drives a resize; then syncSize stops polling
    // (the observer is the timely, before-paint sizer). See resizeSync()/syncSize().
    bool autoSize_ = true;
    bool continuous_ = true;
    // Continuous-mode frame observer; the Map holds a reference to it, so it is
    // declared before (destroyed after) map_. nullptr in Static mode.
    std::unique_ptr<WebFrameObserver> observer_;
    std::unique_ptr<mbgl::HeadlessFrontend> frontend_;
    std::unique_ptr<mbgl::Map> map_;
    bool dirty_ = false;
    bool rendering_ = false; // Static path only
    bool ready_ = false;
    val readyCb_ = val::undefined();

    // Gesture state.
    bool dragging_ = false;
    double lastX_ = 0;
    double lastY_ = 0;

    // Fly-to animation state.
    bool animating_ = false;
    double animStartMs_ = 0;
    double animDurMs_ = 1;
    double fromLat_ = 0, fromLng_ = 0, fromZoom_ = 0, fromBearing_ = 0, fromPitch_ = 0;
    double toLat_ = 0, toLng_ = 0, toZoom_ = 0, toBearing_ = 0, toPitch_ = 0;
    // Fly-to zoom-out arc: when useDip_, the eased step dips zoom toward peakZoom_
    // (the level that fits both endpoints) at the time-midpoint.
    bool useDip_ = false;
    double peakZoom_ = 0;
};

void WebFrameObserver::onDidFinishRenderingFrame(const mbgl::MapObserver::RenderFrameStatus&) {
    map_->onFrameRendered();
}

void globalTick() {
    if (g_loop != nullptr) {
        g_loop->runOnce();
    }
    // Copy raw pointers first: a tick (renderStill callback / observer) could
    // destroy a map.
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
        opts["pixelRatio"].as<double>(),
        opts["continuous"].isUndefined() ? true : opts["continuous"].as<bool>());
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
        .function("resizeSync", &WebMap::resizeSync)
        .function("moveBy", &WebMap::moveBy)
        .function("scaleBy", &WebMap::scaleBy)
        .function("animateTo", &WebMap::animateTo)
        .function("onReady", &WebMap::onReady)
        .function("destroy", &WebMap::destroy);

    emscripten::function("createMap", &createMap, emscripten::allow_raw_pointers());
}
