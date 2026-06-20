// Implementation of the Android zero-copy present (see the header). Renders mbgl's
// offscreen FBO into an EGL window surface backed by the Flutter SurfaceProducer's
// ANativeWindow — no CPU readback (the fix for the stuttery default CPU present).
#include "maplibre_flutter_core_android_present.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <cctype>
#include <cstdio>
#include <string>

struct MblAndroidPresenter {
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT; // mbgl's context (shared, not owned)
  EGLSurface window = EGL_NO_SURFACE;  // our window surface (owned)
  // mbgl's own surfaces, restored after each present.
  EGLSurface mbglDraw = EGL_NO_SURFACE;
  EGLSurface mbglRead = EGL_NO_SURFACE;
};

extern "C" MblAndroidPresenter* mbl_android_presenter_create(void* native_window) {
  if (native_window == nullptr) return nullptr;

  EGLDisplay display = eglGetCurrentDisplay();
  EGLContext context = eglGetCurrentContext();
  EGLSurface mbglDraw = eglGetCurrentSurface(EGL_DRAW);
  EGLSurface mbglRead = eglGetCurrentSurface(EGL_READ);
  if (display == EGL_NO_DISPLAY || context == EGL_NO_CONTEXT) {
    return nullptr;
  }

  // Auto-fall-back to the CPU present on GL renderers that cannot import a
  // foreign-EGL-context's GL-rendered HardwareBuffer into a Flutter SurfaceProducer
  // texture (the buffer composites as white). This is a known limitation of the
  // Android emulator + software GL — confirmed across both emulator GPU modes and
  // every SurfaceProducer path. On real-device GPUs the producer-EGL-surface present
  // is the standard path and works, so zero-copy stays on there. (context is current
  // here — the shim calls this inside a BackendScope.)
  if (const char *r = reinterpret_cast<const char *>(glGetString(GL_RENDERER))) {
    std::string lower(r);
    for (char &c : lower) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (lower.find("emulator") != std::string::npos ||
        lower.find("swiftshader") != std::string::npos ||
        lower.find("llvmpipe") != std::string::npos ||
        lower.find("software") != std::string::npos) {
      fprintf(stderr,
              "maplibre_flutter_core: GL renderer '%s' can't composite foreign-EGL "
              "buffers in a Flutter SurfaceProducer; using the CPU present\n",
              r);
      return nullptr;
    }
  }

  // A window-capable ES3 RGBA8 config. It must be compatible with mbgl's context
  // (created from a pbuffer-only config) for eglMakeCurrent to accept it below — on
  // Android the RGBA8/ES3 configs generally are; if not, create()/present() fail and
  // the shim falls back to the CPU path.
  const EGLint attribs[] = {EGL_SURFACE_TYPE,
                            EGL_WINDOW_BIT,
                            EGL_RENDERABLE_TYPE,
                            EGL_OPENGL_ES3_BIT,
                            EGL_RED_SIZE,
                            8,
                            EGL_GREEN_SIZE,
                            8,
                            EGL_BLUE_SIZE,
                            8,
                            EGL_ALPHA_SIZE,
                            8,
                            EGL_NONE};
  EGLConfig config = nullptr;
  EGLint numConfigs = 0;
  if (!eglChooseConfig(display, attribs, &config, 1, &numConfigs) ||
      numConfigs != 1) {
    fprintf(stderr, "maplibre_flutter_core: no EGL window config\n");
    return nullptr;
  }

  EGLSurface window = eglCreateWindowSurface(
      display, config, static_cast<EGLNativeWindowType>(native_window), nullptr);
  if (window == EGL_NO_SURFACE) {
    fprintf(stderr,
            "maplibre_flutter_core: eglCreateWindowSurface failed 0x%x\n",
            eglGetError());
    return nullptr;
  }
  // Validate the config is usable with mbgl's context (catches EGL_BAD_MATCH now,
  // not mid-render), then restore mbgl's surfaces.
  if (!eglMakeCurrent(display, window, window, context)) {
    fprintf(stderr, "maplibre_flutter_core: window surface not context-compatible "
                    "(0x%x); using CPU present\n",
            eglGetError());
    eglMakeCurrent(display, mbglDraw, mbglRead, context);
    eglDestroySurface(display, window);
    return nullptr;
  }
  eglMakeCurrent(display, mbglDraw, mbglRead, context);

  auto* p = new MblAndroidPresenter();
  p->display = display;
  p->context = context;
  p->window = window;
  p->mbglDraw = mbglDraw;
  p->mbglRead = mbglRead;
  return p;
}

extern "C" int mbl_android_presenter_present(MblAndroidPresenter* p) {
  if (p == nullptr) return 0;
  // The shim bound mbgl's color renderable, so the current draw framebuffer is
  // mbgl's color FBO — our blit source. Save both bindings to restore after.
  GLint srcFbo = 0, prevRead = 0;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &srcFbo);
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);

  EGLint w = 0, h = 0;
  eglQuerySurface(p->display, p->window, EGL_WIDTH, &w);
  eglQuerySurface(p->display, p->window, EGL_HEIGHT, &h);
  if (w <= 0 || h <= 0) return 0;

  if (!eglMakeCurrent(p->display, p->window, p->window, p->context)) {
    return 0;
  }
  glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(srcFbo));
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0); // the window surface's default FB
  // Vertical flip (dst Y inverted) so the presented image matches the top-down CPU
  // readback path.
  glBlitFramebuffer(0, 0, w, h, 0, h, w, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  glFinish(); // ensure the blit completes before the buffer is queued to Flutter
  const EGLBoolean ok = eglSwapBuffers(p->display, p->window);

  // Restore mbgl's surfaces + FBO bindings so its GL state cache stays truthful.
  eglMakeCurrent(p->display, p->mbglDraw, p->mbglRead, p->context);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, static_cast<GLuint>(srcFbo));
  glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(prevRead));
  return ok ? 1 : 0;
}

extern "C" void mbl_android_presenter_destroy(MblAndroidPresenter* p) {
  if (p == nullptr) return;
  if (p->window != EGL_NO_SURFACE) {
    eglMakeCurrent(p->display, p->mbglDraw, p->mbglRead, p->context);
    eglDestroySurface(p->display, p->window);
  }
  delete p;
}
