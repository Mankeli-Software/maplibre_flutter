// Implementation of the Windows D3D11 zero-copy presenter (see
// maplibre_flutter_core_d3d.h). Compiled only on Windows (CMakeLists adds it to the
// shim sources under WIN32 and links d3d11/dxgi).
//
// Per ring slot we create a shared D3D11 texture (D3D11_RESOURCE_MISC_SHARED on
// ANGLE's own ID3D11Device), wrap it as an ANGLE pbuffer
// (eglCreatePbufferFromClientBuffer + EGL_D3D_TEXTURE_ANGLE) so GL can render into
// it, and grab its legacy DXGI shared handle (IDXGIResource::GetSharedHandle). To
// present, we make the slot's pbuffer current, blit mbgl's color FBO into it
// (vertical flip to match the CPU path), glFinish() so the cross-device consumer
// never samples a half-drawn frame (no keyed mutex on a legacy shared handle), then
// restore mbgl's surface. The plugin hands the published handle to a Flutter
// GpuSurfaceTexture, which re-opens it on Flutter's device via
// EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE.
//
// Correctness notes (mirroring the Linux dmabuf presenter):
//  * mbgl's gl::Context caches GL bindings; we bracket all GL work in a
//    GlStateGuard (save/restore framebuffer + texture bindings) so mbgl's cache
//    stays truthful, and we restore mbgl's EGL surface after the blit.
//  * The source FBO is taken from GL_DRAW_FRAMEBUFFER_BINDING — the shim binds
//    mbgl's color renderable immediately before present(), so it is mbgl's color FBO.
//  * resize retires the old ring and frees it only after a full ring cycle of
//    presents, so a slot is never destroyed while the raster thread may still be
//    sampling it (the D3D texture / shared handle outlive the in-flight read).
#include "maplibre_flutter_core_d3d.h"

#if defined(_WIN32)

#include <EGL/egl.h>
#include <EGL/eglext.h>
// GLES3 core (glBlitFramebuffer) first — defines GL_APIENTRY + the GL types.
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include <d3d11.h>
#include <dxgi.h>

#include <cstdio>
#include <vector>

// ANGLE/EGL_EXT_device_query constants (avoid depending on eglext_angle.h being on
// the include path; these enum values are stable ABI).
#ifndef EGL_DEVICE_EXT
#define EGL_DEVICE_EXT 0x322C
#endif
#ifndef EGL_D3D11_DEVICE_ANGLE
#define EGL_D3D11_DEVICE_ANGLE 0x33A1
#endif
#ifndef EGL_D3D_TEXTURE_ANGLE
#define EGL_D3D_TEXTURE_ANGLE 0x33A3
#endif

namespace {

constexpr uint32_t kRingSize = 3;
// Free a retired ring only after this many presents — once the producer has cycled
// past every slot the raster thread could still be sampling.
constexpr uint64_t kRetireAfterPresents = kRingSize;

struct Slot {
  ID3D11Texture2D *tex = nullptr; // shared D3D11 texture (RGBA8)
  EGLSurface pbuffer = EGL_NO_SURFACE;
  HANDLE shared = nullptr; // legacy DXGI shared handle (owned by `tex`)
};

struct RetiredRing {
  Slot slots[kRingSize];
  uint64_t destroyAfter = 0;
};

// Saves/restores the GL bindings this helper touches, so mbgl's State<> cache
// (which assumes cache == actual whenever it isn't mid-render) stays truthful.
struct GlStateGuard {
  GLint drawFbo = 0, readFbo = 0, activeTex = 0, tex2d = 0;
  GlStateGuard() {
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFbo);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFbo);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTex);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex2d);
  }
  ~GlStateGuard() {
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, static_cast<GLuint>(drawFbo));
    glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(readFbo));
    glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(tex2d));
    glActiveTexture(static_cast<GLenum>(activeTex));
  }
};

} // namespace

struct MblD3dPresenter {
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  EGLConfig config = nullptr;
  ID3D11Device *device = nullptr; // ANGLE's device (borrowed, not ref-counted)

  uint32_t width = 0;
  uint32_t height = 0;
  uint64_t generation = 0;
  uint64_t presentCount = 0;
  uint32_t nextSlot = 0;
  Slot ring[kRingSize];
  std::vector<RetiredRing> retired;

  void destroySlot(Slot &s) {
    if (s.pbuffer != EGL_NO_SURFACE) {
      eglDestroySurface(display, s.pbuffer);
      s.pbuffer = EGL_NO_SURFACE;
    }
    if (s.tex != nullptr) {
      s.tex->Release();
      s.tex = nullptr;
    }
    s.shared = nullptr; // owned by tex; freed with it
  }
};

namespace {

// Allocates one ring slot: a shared D3D11 texture, its legacy DXGI shared handle,
// and an ANGLE pbuffer wrapping it. Returns false on failure.
bool buildSlot(MblD3dPresenter *p, Slot &s, uint32_t w, uint32_t h) {
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = w;
  desc.Height = h;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  // BGRA8, not RGBA8: ANGLE's EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE path (how
  // Flutter opens a DxgiSharedHandle) only accepts B8G8R8A8. mbgl renders RGBA,
  // but glBlitFramebuffer copies by logical channel (not memory order), so the
  // blit into this BGRA target keeps colours correct.
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.SampleDesc.Quality = 0;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.CPUAccessFlags = 0;
  // Legacy shared handle (GetSharedHandle) → consumed via
  // EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE on Flutter's device.
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

  if (FAILED(p->device->CreateTexture2D(&desc, nullptr, &s.tex)) ||
      s.tex == nullptr) {
    return false;
  }

  IDXGIResource *res = nullptr;
  if (FAILED(s.tex->QueryInterface(__uuidof(IDXGIResource),
                                   reinterpret_cast<void **>(&res))) ||
      res == nullptr) {
    return false;
  }
  HRESULT hr = res->GetSharedHandle(&s.shared);
  res->Release();
  if (FAILED(hr) || s.shared == nullptr) {
    return false;
  }

  // Wrap the D3D11 texture as an ANGLE pbuffer we can render into.
  const EGLint attribs[] = {EGL_NONE};
  s.pbuffer = eglCreatePbufferFromClientBuffer(
      p->display, EGL_D3D_TEXTURE_ANGLE,
      reinterpret_cast<EGLClientBuffer>(s.tex), p->config, attribs);
  return s.pbuffer != EGL_NO_SURFACE;
}

void reapRetired(MblD3dPresenter *p) {
  for (auto it = p->retired.begin(); it != p->retired.end();) {
    if (p->presentCount >= it->destroyAfter) {
      for (auto &s : it->slots) {
        p->destroySlot(s);
      }
      it = p->retired.erase(it);
    } else {
      ++it;
    }
  }
}

} // namespace

extern "C" {

MblD3dPresenter *mbl_d3d_presenter_create(void) {
  EGLDisplay display = eglGetCurrentDisplay();
  EGLContext context = eglGetCurrentContext();
  if (display == EGL_NO_DISPLAY || context == EGL_NO_CONTEXT) {
    fprintf(stderr, "maplibre_flutter_core: no current EGL display/context for "
                    "D3D zero-copy; using CPU readback.\n");
    return nullptr;
  }

  auto queryDisplay = reinterpret_cast<PFNEGLQUERYDISPLAYATTRIBEXTPROC>(
      eglGetProcAddress("eglQueryDisplayAttribEXT"));
  auto queryDevice = reinterpret_cast<PFNEGLQUERYDEVICEATTRIBEXTPROC>(
      eglGetProcAddress("eglQueryDeviceAttribEXT"));
  if (queryDisplay == nullptr || queryDevice == nullptr) {
    fprintf(stderr, "maplibre_flutter_core: EGL_EXT_device_query unavailable; "
                    "using CPU readback.\n");
    return nullptr;
  }

  EGLAttrib deviceAttr = 0;
  if (!queryDisplay(display, EGL_DEVICE_EXT, &deviceAttr)) {
    fprintf(stderr, "maplibre_flutter_core: eglQueryDisplayAttribEXT(DEVICE) "
                    "failed; using CPU readback.\n");
    return nullptr;
  }
  auto eglDevice = reinterpret_cast<EGLDeviceEXT>(deviceAttr);
  EGLAttrib d3dAttr = 0;
  if (!queryDevice(eglDevice, EGL_D3D11_DEVICE_ANGLE, &d3dAttr) || d3dAttr == 0) {
    fprintf(stderr, "maplibre_flutter_core: ANGLE backend is not D3D11; using CPU "
                    "readback.\n");
    return nullptr;
  }

  // Reuse mbgl's context config for the pbuffers so eglMakeCurrent matches.
  EGLint configId = 0;
  EGLConfig config = nullptr;
  EGLint numConfigs = 0;
  if (!eglQueryContext(display, context, EGL_CONFIG_ID, &configId)) {
    return nullptr;
  }
  const EGLint cfgAttribs[] = {EGL_CONFIG_ID, configId, EGL_NONE};
  if (!eglChooseConfig(display, cfgAttribs, &config, 1, &numConfigs) ||
      numConfigs < 1) {
    fprintf(stderr, "maplibre_flutter_core: could not resolve EGL config for D3D "
                    "zero-copy; using CPU readback.\n");
    return nullptr;
  }

  auto *p = new MblD3dPresenter();
  p->display = display;
  p->context = context;
  p->config = config;
  p->device = reinterpret_cast<ID3D11Device *>(d3dAttr);
  return p;
}

int mbl_d3d_presenter_resize(MblD3dPresenter *p, uint32_t width,
                             uint32_t height) {
  if (p == nullptr || width == 0 || height == 0) {
    return 0;
  }
  if (width == p->width && height == p->height && p->ring[0].tex != nullptr) {
    return 1; // unchanged
  }

  // Retire the current ring (the raster thread may still be sampling a slot).
  if (p->ring[0].tex != nullptr) {
    RetiredRing r;
    for (uint32_t i = 0; i < kRingSize; ++i) {
      r.slots[i] = p->ring[i];
      p->ring[i] = Slot{};
    }
    r.destroyAfter = p->presentCount + kRetireAfterPresents;
    p->retired.push_back(r);
  }

  bool ok = true;
  for (uint32_t i = 0; i < kRingSize && ok; ++i) {
    ok = buildSlot(p, p->ring[i], width, height);
  }
  if (!ok) {
    for (uint32_t i = 0; i < kRingSize; ++i) {
      p->destroySlot(p->ring[i]);
    }
    return 0;
  }

  p->width = width;
  p->height = height;
  p->nextSlot = 0;
  ++p->generation;
  return 1;
}

int mbl_d3d_presenter_present(MblD3dPresenter *p, void **out_handle) {
  if (p == nullptr || out_handle == nullptr || p->ring[0].tex == nullptr) {
    return 0;
  }

  GlStateGuard guard;

  // The shim bound mbgl's color renderable immediately before this call, so the
  // current draw framebuffer is reliably mbgl's color FBO.
  GLint srcFbo = 0;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &srcFbo);
  if (srcFbo == 0) {
    return 0; // not mbgl's FBO; fall back to CPU readback
  }

  // Save mbgl's EGL surfaces so we can restore them after rendering into the slot.
  EGLSurface savedDraw = eglGetCurrentSurface(EGL_DRAW);
  EGLSurface savedRead = eglGetCurrentSurface(EGL_READ);

  Slot &slot = p->ring[p->nextSlot];

  // Make the slot's pbuffer current so its color buffer (the D3D11 texture) is the
  // default framebuffer, then blit mbgl's FBO into it (flip Y to match the CPU
  // path's top-down image).
  if (!eglMakeCurrent(p->display, slot.pbuffer, slot.pbuffer, p->context)) {
    return 0;
  }
  glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(srcFbo));
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
  glBlitFramebuffer(0, 0, static_cast<GLint>(p->width),
                    static_cast<GLint>(p->height), 0,
                    static_cast<GLint>(p->height), static_cast<GLint>(p->width),
                    0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  const GLenum blitErr = glGetError();
  // Ensure the blit is GPU-complete before the cross-device consumer samples the
  // shared texture (a legacy DXGI shared handle has no keyed mutex to synchronise
  // on). glFinish stalls the render thread but still avoids the CPU readback +
  // re-upload of the pixel-buffer path. (Optimisation: a D3D11 fence / NT-handle
  // keyed mutex would let this be a non-blocking glFlush.)
  glFinish();

  // Restore mbgl's surface so the next render targets mbgl's own context state.
  eglMakeCurrent(p->display, savedDraw, savedRead, p->context);

  if (blitErr != GL_NO_ERROR) {
    return 0;
  }

  *out_handle = slot.shared;
  p->nextSlot = (p->nextSlot + 1) % kRingSize;
  ++p->presentCount;
  reapRetired(p);
  return 1;
}

void mbl_d3d_presenter_destroy(MblD3dPresenter *p) {
  if (p == nullptr) {
    return;
  }
  for (auto &r : p->retired) {
    for (auto &s : r.slots) {
      p->destroySlot(s);
    }
  }
  for (uint32_t i = 0; i < kRingSize; ++i) {
    p->destroySlot(p->ring[i]);
  }
  delete p;
}

} // extern "C"

#endif // _WIN32
