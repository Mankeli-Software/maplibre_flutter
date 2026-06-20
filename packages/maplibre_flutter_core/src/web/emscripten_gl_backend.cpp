// Emscripten WebGL2 context for mbgl's headless GL backend.
//
// Replaces platform/linux's headless_backend_egl.cpp: Emscripten's EGL does not
// support pbuffer surfaces, so instead of EGL we create a real WebGL2 context on a
// canvas via the emscripten_webgl_* API. mbgl still renders into its own offscreen
// framebuffer (the HeadlessFrontend's renderable); the web shim blits that to the
// canvas's default framebuffer to present.
//
// The target canvas is chosen by CSS selector. The web shim sets it (per map) via
// mbgl::webgl::setCanvasSelector() before constructing the HeadlessFrontend.

#include <mbgl/gl/headless_backend.hpp>
#include <mbgl/util/logging.hpp>

#include <emscripten/html5.h>
#include <emscripten/html5_webgl.h>

#include <cassert>
#include <stdexcept>
#include <string>

namespace mbgl {
namespace webgl {

// Selector of the canvas the next-created GL context binds to (e.g. "#mlbf-canvas-0").
std::string& canvasSelector() {
    static std::string selector = "#canvas";
    return selector;
}

void setCanvasSelector(std::string selector) {
    canvasSelector() = std::move(selector);
}

} // namespace webgl

namespace gl {

class EmscriptenGLBackend final : public HeadlessBackend::Impl {
public:
    EmscriptenGLBackend() {
        EmscriptenWebGLContextAttributes attrs;
        emscripten_webgl_init_context_attributes(&attrs);
        attrs.majorVersion = 2; // WebGL2 == OpenGL ES 3.0
        attrs.minorVersion = 0;
        attrs.alpha = true;
        attrs.depth = true;
        attrs.stencil = true;
        attrs.antialias = false;
        attrs.premultipliedAlpha = true;
        attrs.preserveDrawingBuffer = false;
        attrs.failIfMajorPerformanceCaveat = false;
        attrs.enableExtensionsByDefault = true;
        // Render on the thread that owns the context (the map / main thread).
        attrs.proxyContextToMainThread = EMSCRIPTEN_WEBGL_CONTEXT_PROXY_DISALLOW;

        const std::string& selector = webgl::canvasSelector();
        context = emscripten_webgl_create_context(selector.c_str(), &attrs);
        if (context <= 0) {
            throw std::runtime_error("emscripten_webgl_create_context failed for canvas '" + selector +
                                     "' (code " + std::to_string(context) + ")");
        }
        if (emscripten_webgl_make_context_current(context) != EMSCRIPTEN_RESULT_SUCCESS) {
            throw std::runtime_error("emscripten_webgl_make_context_current failed");
        }
    }

    ~EmscriptenGLBackend() final {
        emscripten_webgl_make_context_current(0);
        if (context > 0) {
            emscripten_webgl_destroy_context(context);
        }
    }

    gl::ProcAddress getExtensionFunctionPointer(const char* name) final {
        return reinterpret_cast<gl::ProcAddress>(emscripten_webgl_get_proc_address(name));
    }

    void activateContext() final {
        if (emscripten_webgl_make_context_current(context) != EMSCRIPTEN_RESULT_SUCCESS) {
            throw std::runtime_error("Switching WebGL context failed.");
        }
    }

    void deactivateContext() final { emscripten_webgl_make_context_current(0); }

    EMSCRIPTEN_WEBGL_CONTEXT_HANDLE handle() const { return context; }

private:
    EMSCRIPTEN_WEBGL_CONTEXT_HANDLE context = 0;
};

void HeadlessBackend::createImpl() {
    assert(!impl);
    impl = std::make_unique<EmscriptenGLBackend>();
}

} // namespace gl
} // namespace mbgl
