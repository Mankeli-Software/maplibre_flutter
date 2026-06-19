// Implementation of the GL zero-copy presenter (see maplibre_flutter_core_gl.h).
//
// Cross-DISPLAY sharing via dmabuf: mbgl's render context and Flutter's raster
// context live on different EGLDisplays, so an EGLImageKHR handle (display-scoped)
// cannot cross between them. A Linux dmabuf (a kernel buffer fd) can. So per ring
// slot we: blit mbgl's frame into our RGBA8 texture, wrap it in an EGLImage, and
// EXPORT that image to a dmabuf fd (+ DRM fourcc/stride/offset/modifier) once at
// allocation. The plugin imports that fd into Flutter's context via
// EGL_LINUX_DMA_BUF_EXT (eglCreateImageKHR), so the present is GPU-only, no readback.
//
// Correctness notes (fatal pitfalls an adversarial review caught):
//  * mbgl's gl::Context caches every GL binding in write-through State<> wrappers
//    and skips redundant glBind* calls; any raw GL state we change behind its back
//    desyncs the cache and the NEXT mbgl render targets the wrong FBO. Every public
//    function brackets its GL work with save/restore of the framebuffer +
//    active-texture bindings (when idle mbgl keeps cache == actual, so restoring the
//    saved values keeps the cache truthful).
//  * The source FBO is NOT guessed: the shim binds mbgl's renderable right before
//    present(), so GL_DRAW_FRAMEBUFFER_BINDING is reliably mbgl's color FBO.
//  * A dmabuf fd is owned by us (closed in destroySlot). EGL dups it on import, so
//    the plugin must not close it. resize retires the old ring and frees it only
//    after a full ring cycle of presents — never under an in-flight raster import.
#include "maplibre_flutter_core_gl.h"

#if defined(_WIN32)
// Windows present is CPU pixel-buffer only for now (CLAUDE.md §8): GPU zero-copy on
// Windows would use a D3D11 shared texture and is a later step. The dmabuf presenter
// below is Linux-kernel-specific (EGL_MESA_image_dma_buf_export, <unistd.h>), so on
// Windows we compile no-op presenter stubs instead. mbl_gl_presenter_create()
// returning NULL keeps the shared non-Apple shim on the CPU mbl_map_copy_frame path;
// the other entry points exist only so the shim links — they are never reached at
// runtime (the shim guards every presenter call on a non-null presenter).
extern "C" {
MblGlPresenter *mbl_gl_presenter_create(void) { return nullptr; }
int mbl_gl_presenter_resize(MblGlPresenter *, uint32_t, uint32_t) { return 0; }
int mbl_gl_presenter_present(MblGlPresenter *, MblGlDmabufFrame *) { return 0; }
void mbl_gl_presenter_destroy(MblGlPresenter *) {}
} // extern "C"
#else

#include <EGL/egl.h>
#include <EGL/eglext.h>
// GLES3 core (glBlitFramebuffer, glTexStorage2D) first — it defines GL_APIENTRY and
// the GL types the extension header needs.
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include <unistd.h> // close()

#include <cstdio>
#include <cstring>
#include <vector>

namespace {

constexpr uint32_t kRingSize = 3;
// Free a retired ring only after this many presents, i.e. once the producer has
// cycled past every slot the raster thread could still be sampling.
constexpr uint64_t kRetireAfterPresents = kRingSize;

struct Slot {
  GLuint tex = 0;
  GLuint fbo = 0;
  EGLImageKHR image = EGL_NO_IMAGE_KHR;
  // Exported dmabuf (persistent per slot; the blit updates its contents).
  int fd = -1;
  uint32_t fourcc = 0;
  uint32_t stride = 0;
  uint32_t offset = 0;
  uint64_t modifier = 0;
};

struct RetiredRing {
  Slot slots[kRingSize];
  uint64_t destroyAfter = 0; // free once presentCount reaches this
};

// Saves and restores the GL bindings this helper touches, so mbgl's State<> cache
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

bool hasExtension(const char *list, const char *ext) {
  return list != nullptr && std::strstr(list, ext) != nullptr;
}

} // namespace

struct MblGlPresenter {
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  PFNEGLCREATEIMAGEKHRPROC createImage = nullptr;
  PFNEGLDESTROYIMAGEKHRPROC destroyImage = nullptr;
  PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC exportQuery = nullptr;
  PFNEGLEXPORTDMABUFIMAGEMESAPROC exportImage = nullptr;

  uint32_t width = 0;
  uint32_t height = 0;
  uint64_t generation = 0;
  uint64_t presentCount = 0;
  uint32_t nextSlot = 0;
  Slot ring[kRingSize];
  std::vector<RetiredRing> retired;

  void destroySlot(Slot &s) {
    if (s.fd >= 0) {
      close(s.fd);
      s.fd = -1;
    }
    if (s.image != EGL_NO_IMAGE_KHR) {
      destroyImage(display, s.image);
      s.image = EGL_NO_IMAGE_KHR;
    }
    if (s.fbo != 0) {
      glDeleteFramebuffers(1, &s.fbo);
      s.fbo = 0;
    }
    if (s.tex != 0) {
      glDeleteTextures(1, &s.tex);
      s.tex = 0;
    }
  }
};

namespace {

// Allocates one ring slot: an RGBA8 texture + FBO + EGLImage, then exports the
// image to a dmabuf fd. Caller holds a GlStateGuard. Returns false on failure.
bool buildSlot(MblGlPresenter *p, Slot &s, uint32_t w, uint32_t h) {
  glGenTextures(1, &s.tex);
  glBindTexture(GL_TEXTURE_2D, s.tex);
  // Immutable, complete level-0 storage is required before eglCreateImageKHR.
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, static_cast<GLsizei>(w),
                 static_cast<GLsizei>(h));

  const EGLint attribs[] = {EGL_GL_TEXTURE_LEVEL_KHR, 0, EGL_NONE};
  s.image = p->createImage(
      p->display, p->context, EGL_GL_TEXTURE_2D_KHR,
      reinterpret_cast<EGLClientBuffer>(static_cast<uintptr_t>(s.tex)), attribs);
  if (s.image == EGL_NO_IMAGE_KHR) {
    return false;
  }

  // Export the image's storage as a dmabuf (single-plane RGBA8).
  int fourcc = 0, numPlanes = 0;
  EGLuint64KHR modifiers[4] = {0, 0, 0, 0};
  if (!p->exportQuery(p->display, s.image, &fourcc, &numPlanes, modifiers) ||
      numPlanes != 1) {
    return false;
  }
  int fds[4] = {-1, -1, -1, -1};
  EGLint strides[4] = {0, 0, 0, 0};
  EGLint offsets[4] = {0, 0, 0, 0};
  if (!p->exportImage(p->display, s.image, fds, strides, offsets) ||
      fds[0] < 0) {
    return false;
  }
  s.fd = fds[0];
  s.fourcc = static_cast<uint32_t>(fourcc);
  s.stride = static_cast<uint32_t>(strides[0]);
  s.offset = static_cast<uint32_t>(offsets[0]);
  s.modifier = static_cast<uint64_t>(modifiers[0]);

  glGenFramebuffers(1, &s.fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, s.fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         s.tex, 0);
  return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}

// Frees retired rings whose hold-down window has elapsed.
void reapRetired(MblGlPresenter *p) {
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

MblGlPresenter *mbl_gl_presenter_create(void) {
  EGLDisplay display = eglGetCurrentDisplay();
  EGLContext context = eglGetCurrentContext();
  if (display == EGL_NO_DISPLAY || context == EGL_NO_CONTEXT) {
    fprintf(stderr, "maplibre_flutter_core: no current EGL display/context for "
                    "zero-copy; using CPU readback.\n");
    return nullptr;
  }

  const char *eglExts = eglQueryString(display, EGL_EXTENSIONS);
  if (!hasExtension(eglExts, "EGL_KHR_image_base") ||
      !hasExtension(eglExts, "EGL_KHR_gl_texture_2D_image") ||
      !hasExtension(eglExts, "EGL_MESA_image_dma_buf_export")) {
    fprintf(stderr, "maplibre_flutter_core: required EGL dmabuf-export extensions "
                    "absent; using CPU readback.\n");
    return nullptr;
  }

  auto createImage = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
      eglGetProcAddress("eglCreateImageKHR"));
  auto destroyImage = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
      eglGetProcAddress("eglDestroyImageKHR"));
  auto exportQuery = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC>(
      eglGetProcAddress("eglExportDMABUFImageQueryMESA"));
  auto exportImage = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEMESAPROC>(
      eglGetProcAddress("eglExportDMABUFImageMESA"));
  if (createImage == nullptr || destroyImage == nullptr ||
      exportQuery == nullptr || exportImage == nullptr) {
    fprintf(stderr, "maplibre_flutter_core: EGL dmabuf entry points unresolved; "
                    "using CPU readback.\n");
    return nullptr;
  }

  auto *p = new MblGlPresenter();
  p->display = display;
  p->context = context;
  p->createImage = createImage;
  p->destroyImage = destroyImage;
  p->exportQuery = exportQuery;
  p->exportImage = exportImage;
  return p;
}

int mbl_gl_presenter_resize(MblGlPresenter *p, uint32_t width, uint32_t height) {
  if (p == nullptr || width == 0 || height == 0) {
    return 0;
  }
  if (width == p->width && height == p->height && p->ring[0].tex != 0) {
    return 1; // unchanged
  }

  GlStateGuard guard;

  // Retire the current ring (if any) rather than freeing it now — the raster
  // thread may still be importing one of its dmabufs. Free after a ring cycle.
  if (p->ring[0].tex != 0) {
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

int mbl_gl_presenter_present(MblGlPresenter *p, MblGlDmabufFrame *out) {
  if (p == nullptr || out == nullptr || p->ring[0].tex == 0) {
    return 0;
  }

  GlStateGuard guard;

  // The shim bound mbgl's color renderable immediately before this call, so the
  // current draw framebuffer is reliably mbgl's color FBO.
  GLint srcFbo = 0;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &srcFbo);
  if (srcFbo == 0) {
    return 0; // not mbgl's FBO; fall back to CPU readback rather than blit garbage
  }

  Slot &slot = p->ring[p->nextSlot];
  glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(srcFbo));
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, slot.fbo);
  // Flip vertically (dst y inverted) to match the CPU path's top-down image.
  glBlitFramebuffer(0, 0, static_cast<GLint>(p->width),
                    static_cast<GLint>(p->height), 0,
                    static_cast<GLint>(p->height), static_cast<GLint>(p->width),
                    0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  if (glGetError() != GL_NO_ERROR) {
    return 0;
  }
  // v2 sync: submit the blit without stalling the render thread (glFlush, not the
  // v1 glFinish) and rely on the dmabuf's IMPLICIT fence — on Linux/Mesa the
  // producer's write attaches a fence to the buffer's reservation object, and the
  // consumer's sample (Flutter's raster context, a different EGLDisplay) waits on
  // it automatically. This is cross-display-safe (a fence handle, like an EGLImage,
  // is display-scoped and could NOT be shared; the kernel dma_resv fence can).
  // glFinish would also be correct but stalls the render thread every frame; the
  // explicit alternative if a driver lacks implicit dma-buf sync is an
  // EGL_ANDROID_native_fence_sync fd passed alongside the dmabuf fd.
  glFlush();

  out->fd = slot.fd;
  out->fourcc = slot.fourcc;
  out->stride = slot.stride;
  out->offset = slot.offset;
  out->modifier = slot.modifier;
  out->generation = p->generation;
  out->ring_index = p->nextSlot;
  out->width = p->width;
  out->height = p->height;

  p->nextSlot = (p->nextSlot + 1) % kRingSize;
  ++p->presentCount;
  reapRetired(p);
  return 1;
}

void mbl_gl_presenter_destroy(MblGlPresenter *p) {
  if (p == nullptr) {
    return;
  }
  GlStateGuard guard;
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

#endif // !_WIN32
