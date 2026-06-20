// C ABI shim over mbgl-core (CLAUDE.md §5c). Compiled by hook/build.dart via
// CMake, linked against mbgl-core configured as a headless Metal desktop core.
//
// Each MblMap owns a dedicated render thread that exclusively constructs and
// drives the mbgl Map / HeadlessFrontend / RunLoop (mbgl is single-thread-affine,
// so all mbgl access — including destruction — happens on that thread). Commands
// from other threads are marshaled onto it through a queue. Rendering uses
// MapMode::Static: render() pumps the RunLoop until a complete frame is ready,
// so we render on demand (initial frame + after each camera/style change) rather
// than running a continuous loop. Frames are published to a mutex-guarded buffer
// and announced via a frame-ready callback; copy_frame is a non-blocking copy of
// the latest frame for the present path.
#include "maplibre_flutter_core.h"

#include <mbgl/gfx/backend_scope.hpp>
#include <mbgl/gfx/headless_frontend.hpp>
#include <mbgl/map/camera.hpp>
#include <mbgl/map/map.hpp>
#include <mbgl/map/map_observer.hpp>
#include <mbgl/map/map_options.hpp>
#include <mbgl/storage/file_source_manager.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/style/style.hpp>
#include <mbgl/util/client_options.hpp>
#include <mbgl/util/geo.hpp>
#include <mbgl/util/image.hpp>
#include <mbgl/util/run_loop.hpp>
#include <mbgl/util/size.hpp>

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

// Metal zero-copy present (macOS only). On other platforms the present path is
// the backend-agnostic CPU readback (mbl_map_copy_frame); the Metal symbols below
// are absent and the zero-copy entry points become no-ops.
#if defined(__APPLE__)
#include "maplibre_flutter_core_metal.h"
#include <mbgl/mtl/headless_backend.hpp>
#else
// GL/D3D zero-copy present (Linux/Windows). The shim binds mbgl's color renderable
// so the helper can blit from its FBO; that needs the gfx renderable/backend API.
#include <mbgl/gfx/renderable.hpp>
#include <mbgl/gfx/renderer_backend.hpp>
#if defined(_WIN32)
#include "maplibre_flutter_core_vk.h"
#elif defined(__ANDROID__)
// Android: the dmabuf GL presenter compiles as no-op stubs (so the shim links on the
// CPU path), and the real zero-copy present is an EGL window surface fed by the
// SurfaceProducer (maplibre_flutter_core_android_present.{h,cpp}).
#include "maplibre_flutter_core_android.h"
#include "maplibre_flutter_core_android_present.h"
#include "maplibre_flutter_core_gl.h"
#else
#include "maplibre_flutter_core_gl.h"
#endif
#endif

namespace {
struct CameraState {
  double lat = 0, lng = 0, zoom = 0, bearing = 0, pitch = 0;
};
} // namespace

struct MblMap {
  // Command queue → render thread.
  std::mutex queueMutex;
  std::condition_variable queueCv;
  std::deque<std::function<void()>> queue;
  bool stop = false;
  std::thread thread;

  // Owned by and only dereferenced on the render thread.
  mbgl::HeadlessFrontend *frontend = nullptr;
  mbgl::Map *map = nullptr;

  // Render-thread-only: set by commands that mutate the map (camera/style/size)
  // instead of rendering inline, so the loop can drain a burst of commands and
  // render once at the latest state. Coalescing means a fast camera animation
  // (or gesture stream) drops stale intermediate frames rather than rendering —
  // and falling behind on — every one.
  bool renderRequested = false;

  // Construction handshake (create() returns once the map is built).
  std::mutex startMutex;
  std::condition_variable startCv;
  bool started = false;

  // Latest rendered frame (RGBA premultiplied), guarded.
  std::mutex frameMutex;
  std::condition_variable frameCv;
  mbgl::PremultipliedImage frame;
  uint64_t frameCount = 0;

  // Byte order mbl_map_copy_frame emits: true = BGRA (macOS CVPixelBuffer),
  // false = RGBA (Linux FlPixelBufferTexture). Guarded by frameMutex.
  bool outputBgra = true;

  // Cached camera (set-through, read by the getter without touching the map).
  std::mutex cameraMutex;
  CameraState camera;

  // Frame-ready callback (called on the render thread).
  std::mutex cbMutex;
  MblFrameCallback frameCb = nullptr;
  void *frameCbUser = nullptr;

  // Zero-copy present. macOS blits mbgl's Metal texture into an IOSurface; the
  // non-Apple (GL) arm blits mbgl's color FBO into an EGLImage-backed texture ring.
  // `zeroCopy` is flipped via a posted command (so it changes on the render thread).
  bool zeroCopy = false;
#if defined(__APPLE__)
  // `blitter`/`currentSurface` are touched only on the render thread, except
  // `currentSurface` is also read under `frameMutex` by the IOSurface getter.
  MblMetalBlitter *blitter = nullptr;
  IOSurfaceRef currentSurface = nullptr;
#elif defined(_WIN32)
  // D3D11 presenter (render thread only). The latest shared handle below is
  // frameMutex-guarded and read by the GpuSurfaceTexture getter on the raster
  // thread, which never touches D3D/GL/EGL. `d3dActive` signals the presenter
  // initialised; `d3dTearingDown` makes the getter stop handing out the handle
  // while the render thread destroys the presenter. `currentD3dHandle == nullptr`
  // means "no frame".
  MblVkPresenter *vkPresenter = nullptr;
  void *currentD3dHandle = nullptr;
  uint32_t d3dWidth = 0;
  uint32_t d3dHeight = 0;
  bool d3dActive = false;
  bool d3dTearingDown = false;
#else
  // GL presenter (render thread only). The latest dmabuf frame below is
  // frameMutex-guarded and read by the FlTextureGL getter on the raster thread,
  // which never touches GL/EGL. `glActive` signals the presenter initialised (so
  // Dart can confirm zero-copy is live); `glTearingDown` makes the getter stop
  // handing out frames while the render thread destroys the presenter.
  // `currentGlFrame.fd < 0` means "no frame".
  MblGlPresenter *glPresenter = nullptr;
  MblGlDmabufFrame currentGlFrame{-1, 0, 0, 0, 0, 0, 0, 0, 0};
  bool glActive = false;
  bool glTearingDown = false;
#endif

#if defined(__ANDROID__)
  // Zero-copy present into a Flutter SurfaceProducer's EGL window surface (render
  // thread only). `androidZeroCopy` flips true once the presenter is created; the
  // plugin's CPU frame callback no-ops while it is true (the core swaps directly).
  MblAndroidPresenter *androidPresenter = nullptr;
  void *androidWindow = nullptr;
  bool androidZeroCopy = false;
#endif

  // Current render-target size in device pixels (render thread only), used to size
  // the GL presenter's ring to match each frame.
  uint32_t renderWidth = 0;
  uint32_t renderHeight = 0;

  // Resize coalescing. `pendingResize{W,H}` is the latest size requested by
  // mbl_map_resize (written from any thread under `resizeMutex`); `appliedResize{W,H}`
  // is the size last pushed to mbgl (render thread only). Each posted resize task
  // applies the LATEST pending size and skips when it is unchanged, so a fast
  // drag-resize collapses its burst of intermediate sizes into one setSize+render
  // per actually-new size — the texture tracks the live drag size ~1 render behind
  // instead of falling N CPU readbacks behind it (that growing backlog is what read
  // as resize "jitter", worst on the slow CPU-readback path with no zero-copy).
  std::mutex resizeMutex;
  uint32_t pendingResizeW = 0;
  uint32_t pendingResizeH = 0;
  uint32_t appliedResizeW = 0;
  uint32_t appliedResizeH = 0;

  // Continuous mode (vs the default Static). In Continuous mode the render
  // thread runs `renderLoop` (which drives renderFrame on invalidation + tile
  // loads), and commands are marshaled onto it via RunLoop::invoke instead of
  // the cv queue. `renderLoop` is set on the render thread and read cross-thread
  // by post()/destroy (RunLoop::invoke is thread-safe by design).
  bool continuous = false;
  mbgl::util::RunLoop *renderLoop = nullptr;

  void post(std::function<void()> fn) {
    if (continuous) {
      // Marshal onto the render thread's RunLoop (thread-safe). The command
      // mutates the map, which invalidates → renderFrame → frame published.
      if (renderLoop != nullptr) {
        renderLoop->invoke(std::move(fn));
      }
      return;
    }
    {
      std::lock_guard<std::mutex> lk(queueMutex);
      queue.push_back(std::move(fn));
    }
    queueCv.notify_one();
  }
};

namespace {

// Render thread. Notifies waiters and invokes the frame-ready callback after a
// new frame (CPU image or zero-copy IOSurface) has been published.
void announceFrame(MblMap *m) {
  m->frameCv.notify_all();
  MblFrameCallback cb = nullptr;
  void *user = nullptr;
  {
    std::lock_guard<std::mutex> lk(m->cbMutex);
    cb = m->frameCb;
    user = m->frameCbUser;
  }
  if (cb != nullptr) {
    cb(user);
  }
}

void publishFrame(MblMap *m, mbgl::PremultipliedImage img) {
  {
    std::lock_guard<std::mutex> lk(m->frameMutex);
    m->frame = std::move(img);
    ++m->frameCount;
  }
  announceFrame(m);
}

// Render thread only. CPU readback path: render and copy the frame back to a
// CPU image (the default, and the fallback when zero-copy is unavailable).
void renderCpu(MblMap *m) {
  auto result = m->frontend->render(*m->map);
  publishFrame(m, std::move(result.image));
}

#if defined(__APPLE__)
// Called (on a Metal-owned thread) when a zero-copy blit's GPU work completes:
// publish the IOSurface as the current frame and announce it. The map outlives
// any in-flight blit — destroy drains the blitter on the render thread before
// the map is freed.
void blitDone(void *user, IOSurfaceRef surface) {
  auto *m = static_cast<MblMap *>(user);
  {
    std::lock_guard<std::mutex> lk(m->frameMutex);
    // Hold our own ref on the published surface so it outlives the blitter's ring.
    // A window resize recreates (and CFReleases) the ring on the render thread,
    // but the raster thread may still be wrapping this surface in copyPixelBuffer.
    // This publish-ref plus the getter's per-read retain bridge that gap — without
    // them the ring free races the raster retain (EXC_BAD_ACCESS on resize).
    if (surface != nullptr) {
      CFRetain(surface);
    }
    if (m->currentSurface != nullptr) {
      CFRelease(m->currentSurface);
    }
    m->currentSurface = surface;
    ++m->frameCount;
  }
  announceFrame(m);
}

// Render thread only. Zero-copy path (macOS Metal): render into mbgl's offscreen
// Metal texture WITHOUT the GPU->CPU readback (mirrors HeadlessFrontend::render
// minus readStillImage — same renderStill, so frames stay complete), then GPU-
// blit that texture into an IOSurface on mbgl's own command queue. The blit is
// async (no CPU stall); blitDone publishes the frame on GPU completion. Returns
// false if the blit could not be committed, so the caller can fall back to CPU.
bool renderZeroCopyInner(MblMap *m) {
  {
    mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
    bool done = false;
    std::exception_ptr error;
    m->map->renderStill([&](const std::exception_ptr &e) {
      if (e) {
        error = e;
      } else {
        done = true;
      }
    });
    while (!done && !error) {
      mbgl::util::RunLoop::Get()->runOnce();
    }
    if (error) {
      std::rethrow_exception(error);
    }
  }
  // The concrete backend is the mtl HeadlessBackend; getMetalTexture() exposes
  // the texture renderStill just drew into, and getCommandQueue() its queue.
  auto *backend =
      static_cast<mbgl::mtl::RendererBackend *>(m->frontend->getBackend());
  auto *headless = static_cast<mbgl::mtl::HeadlessBackend *>(backend);
  return mbl_metal_blitter_blit(
             m->blitter, (void *)headless->getMetalTexture(),
             (void *)backend->getCommandQueue().get(), &blitDone, m) != 0;
}
#endif // __APPLE__

#if !defined(__APPLE__)
// Render thread, inside a BackendScope with mbgl's color renderable just bound.
// Blits mbgl's FBO into the platform present ring and publishes the result under
// frameMutex for the raster-thread getter. Returns false on failure (→ CPU).
bool presentZeroCopy(MblMap *m) {
#if defined(_WIN32)
  void *handle = nullptr;
  if (mbl_vk_presenter_present(m->vkPresenter, &handle) == 0) {
    return false;
  }
  {
    std::lock_guard<std::mutex> lk(m->frameMutex);
    m->currentD3dHandle = handle;
    m->d3dWidth = m->renderWidth;
    m->d3dHeight = m->renderHeight;
    ++m->frameCount;
  }
#else
  MblGlDmabufFrame frame;
  if (mbl_gl_presenter_present(m->glPresenter, &frame) == 0) {
    return false;
  }
  {
    std::lock_guard<std::mutex> lk(m->frameMutex);
    m->currentGlFrame = frame;
    ++m->frameCount;
  }
#endif
  announceFrame(m);
  return true;
}

// Render thread, inside its own BackendScope. Resizes the present ring to the
// current render size, then blits the already-rendered frame into the ring. Used by
// the Continuous path (the frame is drawn by the time the observer fires). Returns
// false to fall back to CPU readback.
bool presentZeroCopyAlreadyRendered(MblMap *m) {
  mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
#if defined(_WIN32)
  if (mbl_vk_presenter_resize(m->vkPresenter, m->renderWidth,
                               m->renderHeight) == 0) {
    return false;
  }
  // Vulkan: the present helper fetches mbgl's rendered image via the headless
  // renderable's getAcquiredImage() itself, so there is no GL FBO to bind here.
#else
  if (mbl_gl_presenter_resize(m->glPresenter, m->renderWidth, m->renderHeight) ==
      0) {
    return false;
  }
  // GL: bind mbgl's color renderable so GL_DRAW_FRAMEBUFFER_BINDING is reliably its
  // FBO (the dmabuf presenter blits from the currently-bound draw framebuffer) and
  // mbgl's GL state cache stays truthful.
  m->frontend->getBackend()
      ->getDefaultRenderable()
      .getResource<mbgl::gfx::RenderableResource>()
      .bind();
#endif
  return presentZeroCopy(m);
}

// Render thread only (Static path). Zero-copy: render a complete frame, then blit
// it into the ring. Returns false to fall back to CPU readback.
bool renderZeroCopy(MblMap *m) {
  {
    mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
    bool done = false;
    std::exception_ptr error;
    m->map->renderStill([&](const std::exception_ptr &e) {
      if (e) {
        error = e;
      } else {
        done = true;
      }
    });
    while (!done && !error) {
      mbgl::util::RunLoop::Get()->runOnce();
    }
    if (error) {
      std::rethrow_exception(error);
    }
  }
  return presentZeroCopyAlreadyRendered(m);
}
#endif // !__APPLE__

// Render thread only. Guards against mbgl throwing (e.g. a style/tile load
// failure surfaces as std::runtime_error during render) so it logs instead of
// terminating the host process.
void renderNow(MblMap *m) {
  if (m->map == nullptr || m->frontend == nullptr) {
    return;
  }
  try {
#if defined(__APPLE__)
    if (m->zeroCopy && m->blitter != nullptr) {
      if (renderZeroCopyInner(m)) {
        return;
      }
      fprintf(stderr, "maplibre_flutter_core: zero-copy blit failed; falling "
                      "back to CPU readback.\n");
      m->zeroCopy = false;
    }
#elif defined(_WIN32)
    if (m->zeroCopy && m->vkPresenter != nullptr) {
      if (renderZeroCopy(m)) {
        return;
      }
      fprintf(stderr, "maplibre_flutter_core: D3D zero-copy present failed; "
                      "falling back to CPU readback.\n");
      m->zeroCopy = false;
    }
#else
    if (m->zeroCopy && m->glPresenter != nullptr) {
      if (renderZeroCopy(m)) {
        return;
      }
      fprintf(stderr, "maplibre_flutter_core: GL zero-copy present failed; "
                      "falling back to CPU readback.\n");
      m->zeroCopy = false;
    }
#endif
    renderCpu(m);
  } catch (const std::exception &e) {
    fprintf(stderr, "maplibre_flutter_core: render failed: %s\n", e.what());
  } catch (...) {
    fprintf(stderr, "maplibre_flutter_core: render failed (unknown)\n");
  }
}

// Render thread only. Refreshes the cached camera from the map (after relative
// gesture ops, where we don't know the resulting camera up front).
void updateCameraCache(MblMap *m) {
  const auto cam = m->map->getCameraOptions();
  std::lock_guard<std::mutex> lk(m->cameraMutex);
  if (cam.center) {
    m->camera.lat = cam.center->latitude();
    m->camera.lng = cam.center->longitude();
  }
  if (cam.zoom) m->camera.zoom = *cam.zoom;
  if (cam.bearing) m->camera.bearing = *cam.bearing;
  if (cam.pitch) m->camera.pitch = *cam.pitch;
}

// Cap the desktop core's online tile-request concurrency. The non-Apple core uses
// the curl HTTP source, which multiplexes mbgl's default 20 concurrent requests
// onto one HTTP/2 connection; community tile servers (demotiles, OpenFreeMap)
// answer that burst with HTTP/2 ENHANCE_YOUR_CALM and drop tiles. A lower cap
// keeps tile loading well-behaved at a small cost to cold-load speed. The Network
// OnlineFileSource is shared by id (baseURL|apiKey|cachePath|ctx), so requesting
// it with the same ResourceOptions::Default() the render-thread Map uses returns
// that very instance. Tunable via MAPLIBRE_MAX_CONCURRENT_REQUESTS (default 6).
// Apple uses the NSURLSession HTTP source and doesn't hit this, so it's a no-op.
void capDesktopRequestConcurrency() {
#if !defined(__APPLE__)
  uint32_t maxRequests = 6;
  if (const char *env = std::getenv("MAPLIBRE_MAX_CONCURRENT_REQUESTS")) {
    const int parsed = std::atoi(env);
    if (parsed > 0) {
      maxRequests = static_cast<uint32_t>(parsed);
    }
  }
  if (auto fs = mbgl::FileSourceManager::get()->getFileSource(
          mbgl::FileSourceType::Network, mbgl::ResourceOptions::Default(),
          mbgl::ClientOptions())) {
    fs->setProperty(mbgl::MAX_CONCURRENT_REQUESTS_KEY, maxRequests);
  }
#endif
}

void renderThreadMain(MblMap *m, uint32_t width, uint32_t height,
                      float pixelRatio, std::string styleUri) {
  mbgl::util::RunLoop loop;
  mbgl::HeadlessFrontend frontend(mbgl::Size{width, height}, pixelRatio);
  mbgl::Map map(frontend, mbgl::MapObserver::nullObserver(),
                mbgl::MapOptions()
                    .withMapMode(mbgl::MapMode::Static)
                    .withSize(mbgl::Size{width, height})
                    .withPixelRatio(pixelRatio),
                mbgl::ResourceOptions::Default());

  m->frontend = &frontend;
  m->map = &map;
  capDesktopRequestConcurrency();
  m->renderWidth = width;
  m->renderHeight = height;
  if (!styleUri.empty()) {
    map.getStyle().loadURL(styleUri);
  }

  {
    std::lock_guard<std::mutex> lk(m->startMutex);
    m->started = true;
  }
  m->startCv.notify_all();

  renderNow(m); // initial frame

  for (;;) {
    {
      std::unique_lock<std::mutex> lk(m->queueMutex);
      m->queueCv.wait(lk, [m] { return m->stop || !m->queue.empty(); });
      if (m->stop && m->queue.empty()) {
        break;
      }
    }
    // Drain every command currently queued before rendering. A burst of camera
    // updates thus applies all the (cheap) jumpTo/scaleBy mutations and then
    // renders a single frame at the latest state — coalescing instead of
    // rendering each intermediate camera and falling behind.
    for (;;) {
      std::function<void()> cmd;
      {
        std::lock_guard<std::mutex> lk(m->queueMutex);
        if (m->queue.empty()) {
          break;
        }
        cmd = std::move(m->queue.front());
        m->queue.pop_front();
      }
      cmd();
    }
    if (m->renderRequested) {
      m->renderRequested = false;
      renderNow(m);
    }
  }

#if defined(_WIN32)
  if (m->vkPresenter != nullptr) {
    {
      std::lock_guard<std::mutex> lk(m->frameMutex);
      m->currentD3dHandle = nullptr;
      m->d3dActive = false;
      m->d3dTearingDown = true; // stop the raster getter handing out the handle
    }
    mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
    mbl_vk_presenter_destroy(m->vkPresenter);
    m->vkPresenter = nullptr;
  }
#elif !defined(__APPLE__)
  if (m->glPresenter != nullptr) {
    {
      std::lock_guard<std::mutex> lk(m->frameMutex);
      m->currentGlFrame.fd = -1;
      m->glActive = false;
      m->glTearingDown = true; // stop the raster getter handing out frames
    }
    mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
    mbl_gl_presenter_destroy(m->glPresenter);
    m->glPresenter = nullptr;
  }
#endif
  m->map = nullptr;
  m->frontend = nullptr;
#if defined(__APPLE__)
  if (m->blitter != nullptr) {
    mbl_metal_blitter_destroy(m->blitter);
    m->blitter = nullptr;
  }
  // The blitter is gone and the render thread has drained — no further blitDone can
  // fire, so drop the lingering publish-ref on the last surface (see blitDone).
  if (m->currentSurface != nullptr) {
    CFRelease(m->currentSurface);
    m->currentSurface = nullptr;
  }
#endif
  // map / frontend / loop are destroyed here, on the render thread.
}

// Render thread (Continuous). Publishes the frame already drawn into mbgl's
// texture (present + swap have completed by the time the frame observer fires,
// so the texture is final). Zero-copy blit when enabled, else a CPU readback.
#if defined(__ANDROID__)
// Render thread. Blits the already-rendered FBO into the SurfaceProducer's EGL window
// surface and swaps (zero-copy, no GPU->CPU readback — the fix for the stuttery CPU
// present). Bumps frameCount so awaitFrame()/onReady still fire even though no CPU
// image is published. Returns false on failure (→ CPU readback fallback).
bool presentAndroid(MblMap *m) {
  if (m->androidPresenter == nullptr) {
    return false;
  }
  {
    mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
    // Bind mbgl's color renderable so GL_DRAW_FRAMEBUFFER_BINDING is mbgl's color FBO
    // (the presenter blits from the bound draw framebuffer).
    m->frontend->getBackend()
        ->getDefaultRenderable()
        .getResource<mbgl::gfx::RenderableResource>()
        .bind();
    if (mbl_android_presenter_present(m->androidPresenter) == 0) {
      return false;
    }
  }
  {
    std::lock_guard<std::mutex> lk(m->frameMutex);
    ++m->frameCount;
  }
  announceFrame(m);
  return true;
}
#endif

void publishCurrentFrame(MblMap *m) {
  if (m->map == nullptr || m->frontend == nullptr) {
    return;
  }
  try {
#if defined(__ANDROID__)
    if (m->androidZeroCopy && m->androidPresenter != nullptr) {
      if (presentAndroid(m)) {
        return;
      }
      fprintf(stderr, "maplibre_flutter_core: Android zero-copy present failed; "
                      "falling back to CPU readback.\n");
      // The plugin's CPU frame callback checks the flag and resumes presenting.
      m->androidZeroCopy = false;
    }
#endif
#if defined(__APPLE__)
    if (m->zeroCopy && m->blitter != nullptr) {
      auto *backend =
          static_cast<mbgl::mtl::RendererBackend *>(m->frontend->getBackend());
      auto *headless = static_cast<mbgl::mtl::HeadlessBackend *>(backend);
      if (mbl_metal_blitter_blit(m->blitter, (void *)headless->getMetalTexture(),
                                 (void *)backend->getCommandQueue().get(),
                                 &blitDone, m) != 0) {
        return;
      }
      m->zeroCopy = false; // blitter unavailable; fall back to CPU readback
    }
#elif defined(_WIN32)
    if (m->zeroCopy && m->vkPresenter != nullptr) {
      // The frame is already drawn (the observer fired after present+swap).
      if (presentZeroCopyAlreadyRendered(m)) {
        return;
      }
      fprintf(stderr, "maplibre_flutter_core: D3D zero-copy present failed; "
                      "falling back to CPU readback.\n");
      m->zeroCopy = false;
    }
#else
    if (m->zeroCopy && m->glPresenter != nullptr) {
      // The frame is already drawn (the observer fired after present+swap).
      if (presentZeroCopyAlreadyRendered(m)) {
        return;
      }
      fprintf(stderr, "maplibre_flutter_core: GL zero-copy present failed; "
                      "falling back to CPU readback.\n");
      m->zeroCopy = false;
    }
#endif
    // Backend-agnostic CPU readback (the only path on GL; the fallback on Metal).
    publishFrame(m, m->frontend->readStillImage());
  } catch (const std::exception &e) {
    fprintf(stderr, "maplibre_flutter_core: publish failed: %s\n", e.what());
  } catch (...) {
    fprintf(stderr, "maplibre_flutter_core: publish failed (unknown)\n");
  }
}

// Observes the Continuous-mode map; each rendered frame (partial or full) is
// published, so the texture refines progressively as tiles stream in.
class FrameObserver final : public mbgl::MapObserver {
public:
  explicit FrameObserver(MblMap *map) : m(map) {}
  void onDidFinishRenderingFrame(const RenderFrameStatus &) override {
    publishCurrentFrame(m);
  }

private:
  MblMap *m;
};

void renderThreadMainContinuous(MblMap *m, uint32_t width, uint32_t height,
                                float pixelRatio, std::string styleUri) {
  mbgl::util::RunLoop loop;
  FrameObserver observer(m);
  // Continuous mode: render partial frames immediately and refine as tiles load
  // (invalidateOnUpdate drives renderFrame off the loop; Flush per the upstream
  // headless-continuous convention).
  mbgl::HeadlessFrontend frontend(
      mbgl::Size{width, height}, pixelRatio,
      mbgl::gfx::HeadlessBackend::SwapBehaviour::Flush,
      mbgl::gfx::ContextMode::Unique, std::nullopt, /*invalidateOnUpdate=*/true);
  mbgl::Map map(frontend, observer,
                mbgl::MapOptions()
                    .withMapMode(mbgl::MapMode::Continuous)
                    .withSize(mbgl::Size{width, height})
                    .withPixelRatio(pixelRatio),
                mbgl::ResourceOptions::Default());

  m->frontend = &frontend;
  m->map = &map;
  capDesktopRequestConcurrency();
  m->renderWidth = width;
  m->renderHeight = height;
  if (!styleUri.empty()) {
    map.getStyle().loadURL(styleUri);
  }
  m->renderLoop = &loop;

  {
    std::lock_guard<std::mutex> lk(m->startMutex);
    m->started = true;
  }
  m->startCv.notify_all();

  // Drives renderFrame (on invalidation), async tile loads, and posted commands
  // until destroy() stops the loop.
  loop.run();

  m->renderLoop = nullptr;
#if defined(_WIN32)
  if (m->vkPresenter != nullptr) {
    {
      std::lock_guard<std::mutex> lk(m->frameMutex);
      m->currentD3dHandle = nullptr;
      m->d3dActive = false;
      m->d3dTearingDown = true; // stop the raster getter handing out the handle
    }
    mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
    mbl_vk_presenter_destroy(m->vkPresenter);
    m->vkPresenter = nullptr;
  }
#elif !defined(__APPLE__)
  if (m->glPresenter != nullptr) {
    {
      std::lock_guard<std::mutex> lk(m->frameMutex);
      m->currentGlFrame.fd = -1;
      m->glActive = false;
      m->glTearingDown = true; // stop the raster getter handing out frames
    }
    mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
    mbl_gl_presenter_destroy(m->glPresenter);
    m->glPresenter = nullptr;
  }
#endif
#if defined(__ANDROID__)
  if (m->androidPresenter != nullptr) {
    m->androidZeroCopy = false;
    mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
    mbl_android_presenter_destroy(m->androidPresenter);
    m->androidPresenter = nullptr;
  }
#endif
  m->map = nullptr;
  m->frontend = nullptr;
#if defined(__APPLE__)
  if (m->blitter != nullptr) {
    mbl_metal_blitter_destroy(m->blitter);
    m->blitter = nullptr;
  }
  // The blitter is gone and the render thread has drained — no further blitDone can
  // fire, so drop the lingering publish-ref on the last surface (see blitDone).
  if (m->currentSurface != nullptr) {
    CFRelease(m->currentSurface);
    m->currentSurface = nullptr;
  }
#endif
}

} // namespace

MblMap *mbl_map_create(uint32_t width, uint32_t height, float pixel_ratio,
                       const char *style_uri, int continuous) {
  if (width == 0 || height == 0) {
    return nullptr;
  }
  auto *m = new MblMap();
  m->continuous = continuous != 0;
  const std::string style = style_uri != nullptr ? std::string(style_uri) : "";
  m->thread = std::thread(
      m->continuous ? renderThreadMainContinuous : renderThreadMain, m, width,
      height, pixel_ratio, style);
  {
    std::unique_lock<std::mutex> lk(m->startMutex);
    m->startCv.wait(lk, [m] { return m->started; });
  }
  return m;
}

void mbl_map_set_style(MblMap *m, const char *style_uri) {
  if (m == nullptr || style_uri == nullptr) {
    return;
  }
  const std::string style(style_uri);
  m->post([m, style] {
    m->map->getStyle().loadURL(style);
    m->renderRequested = true;
  });
}

void mbl_map_set_camera(MblMap *m, double lat, double lng, double zoom,
                        double bearing, double pitch) {
  if (m == nullptr) {
    return;
  }
  {
    std::lock_guard<std::mutex> lk(m->cameraMutex);
    m->camera = {lat, lng, zoom, bearing, pitch};
  }
  m->post([m, lat, lng, zoom, bearing, pitch] {
    m->map->jumpTo(mbgl::CameraOptions()
                       .withCenter(mbgl::LatLng{lat, lng})
                       .withZoom(zoom)
                       .withBearing(bearing)
                       .withPitch(pitch));
    m->renderRequested = true;
  });
}

void mbl_map_get_camera(MblMap *m, double *out_lat, double *out_lng,
                        double *out_zoom, double *out_bearing,
                        double *out_pitch) {
  if (m == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lk(m->cameraMutex);
  if (out_lat) *out_lat = m->camera.lat;
  if (out_lng) *out_lng = m->camera.lng;
  if (out_zoom) *out_zoom = m->camera.zoom;
  if (out_bearing) *out_bearing = m->camera.bearing;
  if (out_pitch) *out_pitch = m->camera.pitch;
}

void mbl_map_resize(MblMap *m, uint32_t width, uint32_t height) {
  if (m == nullptr || width == 0 || height == 0) {
    return;
  }
  {
    std::lock_guard<std::mutex> lk(m->resizeMutex);
    m->pendingResizeW = width;
    m->pendingResizeH = height;
  }
  // Coalesce on the render thread: apply the LATEST requested size (read here,
  // not captured), and skip when the map is already at it. A fast drag-resize
  // posts many tasks, but only those observing a genuinely new size do a
  // setSize+render, so the texture tracks the live drag size instead of the
  // backlog of stale intermediate readbacks falling further behind the window
  // edge. The unchanged-skip also avoids invalidating mbgl in Continuous mode
  // when nothing changed (no idle busy-loop). All mbgl access stays on the
  // render thread; only the pending size crosses threads.
  m->post([m] {
    uint32_t w, h;
    {
      std::lock_guard<std::mutex> lk(m->resizeMutex);
      w = m->pendingResizeW;
      h = m->pendingResizeH;
    }
    if (w == 0 || h == 0 || (w == m->appliedResizeW && h == m->appliedResizeH)) {
      return;
    }
    m->appliedResizeW = w;
    m->appliedResizeH = h;
    m->frontend->setSize(mbgl::Size{w, h});
    m->map->setSize(mbgl::Size{w, h});
    m->renderWidth = w;
    m->renderHeight = h;
    m->renderRequested = true;
  });
}

void mbl_map_move_by(MblMap *m, double dx, double dy) {
  if (m == nullptr) {
    return;
  }
  m->post([m, dx, dy] {
    m->map->moveBy(mbgl::ScreenCoordinate{dx, dy});
    updateCameraCache(m);
    m->renderRequested = true;
  });
}

void mbl_map_scale_by(MblMap *m, double scale, double anchor_x,
                      double anchor_y) {
  if (m == nullptr) {
    return;
  }
  m->post([m, scale, anchor_x, anchor_y] {
    m->map->scaleBy(scale, mbgl::ScreenCoordinate{anchor_x, anchor_y});
    updateCameraCache(m);
    m->renderRequested = true;
  });
}

void mbl_map_set_frame_callback(MblMap *m, MblFrameCallback callback,
                                void *user) {
  if (m == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lk(m->cbMutex);
  m->frameCb = callback;
  m->frameCbUser = user;
}

int mbl_map_await_frame(MblMap *m, uint32_t timeout_ms) {
  if (m == nullptr) {
    return 0;
  }
  std::unique_lock<std::mutex> lk(m->frameMutex);
  if (m->frameCount > 0) {
    return 1;
  }
  m->frameCv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                      [m] { return m->frameCount > 0; });
  return m->frameCount > 0 ? 1 : 0;
}

int mbl_map_copy_frame(MblMap *m, uint8_t *dst, size_t dst_capacity,
                       uint32_t *out_width, uint32_t *out_height,
                       uint32_t *out_stride) {
  if (m == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lk(m->frameMutex);
  if (m->frameCount == 0 || m->frame.size.width == 0) {
    return 0;
  }
  const uint32_t w = m->frame.size.width;
  const uint32_t h = m->frame.size.height;
  const uint32_t stride = w * 4;
  if (out_width) *out_width = w;
  if (out_height) *out_height = h;
  if (out_stride) *out_stride = stride;
  // Query mode: a null dst reports the frame dimensions only (so a caller can
  // size a destination buffer before copying).
  if (dst == nullptr) {
    return 1;
  }
  if (dst_capacity < static_cast<size_t>(stride) * h) {
    return 0;
  }
  const uint8_t *src = m->frame.data.get();
  if (m->outputBgra) {
    // mbgl yields RGBA; swizzle to BGRA for the macOS CVPixelBuffer.
    for (uint32_t i = 0; i < w * h; ++i) {
      dst[i * 4 + 0] = src[i * 4 + 2]; // B
      dst[i * 4 + 1] = src[i * 4 + 1]; // G
      dst[i * 4 + 2] = src[i * 4 + 0]; // R
      dst[i * 4 + 3] = src[i * 4 + 3]; // A
    }
  } else {
    // RGBA straight through (Linux FlPixelBufferTexture).
    std::memcpy(dst, src, static_cast<size_t>(w) * h * 4);
  }
  return 1;
}

void mbl_map_set_pixel_format_bgra(MblMap *m, int bgra) {
  if (m == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lk(m->frameMutex);
  m->outputBgra = bgra != 0;
}

void mbl_map_set_zero_copy(MblMap *m, int enabled) {
#if defined(__APPLE__)
  if (m == nullptr) {
    return;
  }
  const bool on = enabled != 0;
  m->post([m, on] {
    m->zeroCopy = on;
    if (on && m->blitter == nullptr) {
      m->blitter = mbl_metal_blitter_create();
    }
    m->renderRequested = true;
  });
#elif defined(_WIN32)
  if (m == nullptr) {
    return;
  }
  const bool on = enabled != 0;
  m->post([m, on] {
    m->zeroCopy = on;
    if (on && m->vkPresenter == nullptr) {
      // The presenter matches mbgl's Vulkan device (by LUID) to a D3D11 adapter and
      // builds a shared-texture ring; a NULL result (no valid LUID / external-memory
      // unsupported / D3D device-creation failure) leaves zeroCopy off so the CPU
      // PixelBufferTexture path stays. It needs mbgl's Vulkan backend (device/queue/
      // dispatcher + the per-frame rendered image), so pass it the backend.
      mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
      m->vkPresenter = mbl_vk_presenter_create(m->frontend->getBackend());
      if (m->vkPresenter == nullptr) {
        m->zeroCopy = false; // unsupported config → stay on CPU readback
      } else {
        std::lock_guard<std::mutex> lk(m->frameMutex);
        m->d3dActive = true;
      }
    }
    m->renderRequested = true;
  });
#else
  if (m == nullptr) {
    return;
  }
  const bool on = enabled != 0;
  m->post([m, on] {
    m->zeroCopy = on;
    if (on && m->glPresenter == nullptr) {
      // The presenter probes EGLImage support; a NULL result (e.g. software GL)
      // leaves zeroCopy off so the CPU FlPixelBufferTexture path stays in use.
      mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
      m->glPresenter = mbl_gl_presenter_create();
      if (m->glPresenter == nullptr) {
        m->zeroCopy = false; // unsupported config → stay on CPU readback
      } else {
        std::lock_guard<std::mutex> lk(m->frameMutex);
        m->glActive = true;
      }
    }
    m->renderRequested = true;
  });
#endif
}

void *mbl_map_current_iosurface(MblMap *m) {
#if defined(__APPLE__)
  if (m == nullptr) {
    return nullptr;
  }
  std::lock_guard<std::mutex> lk(m->frameMutex);
  // Hand the caller (Flutter's raster thread) its own +1 ref so the surface can't
  // be freed mid-wrap by a concurrent ring teardown on the render thread. The
  // caller MUST release it once it has retained the surface itself (see
  // MapLibreTexture.copyPixelBuffer, which releases after CVPixelBufferCreate...).
  if (m->currentSurface != nullptr) {
    CFRetain(m->currentSurface);
  }
  return (void *)m->currentSurface;
#else
  (void)m;
  return nullptr;
#endif
}

// Latest zero-copy GL frame descriptor for the FlTextureGL populate callback
// (called by address on the raster thread). Reads only frameMutex-guarded fields;
// never touches GL/EGL. Returns 0 when zero-copy is off, no frame exists yet, or
// the map is tearing down (so the plugin falls back / stops importing).
int mbl_map_current_gl_image(MblMap *m, MblGlDmabufFrame *out) {
#if defined(__APPLE__) || defined(_WIN32)
  (void)m;
  (void)out;
  return 0;
#else
  if (m == nullptr || out == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lk(m->frameMutex);
  if (m->currentGlFrame.fd < 0 || m->glTearingDown) {
    return 0;
  }
  *out = m->currentGlFrame;
  return 1;
#endif
}

// Non-zero if the GL zero-copy presenter is live (dmabuf exporter initialised) and
// not tearing down. Lets Dart confirm zero-copy actually activated before
// committing to the FlTextureGL path.
int mbl_map_gl_active(MblMap *m) {
#if defined(__APPLE__) || defined(_WIN32)
  (void)m;
  return 0;
#else
  if (m == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lk(m->frameMutex);
  return (m->glActive && !m->glTearingDown) ? 1 : 0;
#endif
}

int mbl_map_current_d3d_handle(MblMap *m, void **out_handle, uint32_t *out_width,
                               uint32_t *out_height) {
#if defined(_WIN32)
  if (m == nullptr || out_handle == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lk(m->frameMutex);
  if (m->currentD3dHandle == nullptr || m->d3dTearingDown) {
    return 0;
  }
  *out_handle = m->currentD3dHandle;
  if (out_width) *out_width = m->d3dWidth;
  if (out_height) *out_height = m->d3dHeight;
  return 1;
#else
  (void)m;
  (void)out_handle;
  (void)out_width;
  (void)out_height;
  return 0;
#endif
}

int mbl_map_d3d_active(MblMap *m) {
#if defined(_WIN32)
  if (m == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lk(m->frameMutex);
  return (m->d3dActive && !m->d3dTearingDown) ? 1 : 0;
#else
  (void)m;
  return 0;
#endif
}

int mbl_map_write_png(MblMap *m, const char *path) {
  if (m == nullptr || path == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lk(m->frameMutex);
  if (m->frameCount == 0 || m->frame.size.width == 0) {
    return 0;
  }
  const std::string png = mbgl::encodePNG(m->frame);
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  out.write(png.data(), static_cast<std::streamsize>(png.size()));
  return out.good() ? 1 : 0;
}

void mbl_map_destroy(MblMap *m) {
  if (m == nullptr) {
    return;
  }
  if (m->continuous) {
    // Stop the render thread's RunLoop (thread-safe — schedules onto it), which
    // ends loop.run() and lets the thread tear down the map/frontend.
    if (m->renderLoop != nullptr) {
      m->renderLoop->stop();
    }
  } else {
    {
      std::lock_guard<std::mutex> lk(m->queueMutex);
      m->stop = true;
    }
    m->queueCv.notify_all();
  }
  if (m->thread.joinable()) {
    m->thread.join();
  }
  delete m;
}

#if defined(__ANDROID__)
// Zero-copy present (EGL window surface). These run a command on the render thread
// (where mbgl's EGL context lives) and block until it completes, so the plugin can
// safely sequence ANativeWindow ownership around them.
int mbl_map_set_android_window(MblMap *m, void *native_window) {
  // Zero-copy present is wired for the Continuous render loop only (the default);
  // Static builds keep the CPU readback present.
  if (m == nullptr || native_window == nullptr || !m->continuous ||
      m->renderLoop == nullptr) {
    return 0;
  }
  std::mutex mtx;
  std::condition_variable cv;
  bool done = false;
  int result = 0;
  m->post([m, native_window, &mtx, &cv, &done, &result] {
    MblAndroidPresenter *p = nullptr;
    {
      // mbgl's context current so the presenter can read the EGL display/context.
      mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
      p = mbl_android_presenter_create(native_window);
    }
    m->androidWindow = native_window;
    m->androidPresenter = p;
    m->androidZeroCopy = (p != nullptr);
    result = m->androidZeroCopy ? 1 : 0;
    if (p != nullptr) {
      presentAndroid(m); // immediate first frame (its own BackendScope)
    }
    {
      std::lock_guard<std::mutex> lk(mtx);
      done = true;
    }
    cv.notify_one();
  });
  std::unique_lock<std::mutex> lk(mtx);
  cv.wait(lk, [&done] { return done; });
  return result;
}

void mbl_map_clear_android_window(MblMap *m) {
  if (m == nullptr || m->renderLoop == nullptr) {
    return;
  }
  std::mutex mtx;
  std::condition_variable cv;
  bool done = false;
  m->post([m, &mtx, &cv, &done] {
    m->androidZeroCopy = false;
    if (m->androidPresenter != nullptr) {
      mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
      mbl_android_presenter_destroy(m->androidPresenter);
      m->androidPresenter = nullptr;
    }
    m->androidWindow = nullptr;
    {
      std::lock_guard<std::mutex> lk(mtx);
      done = true;
    }
    cv.notify_one();
  });
  std::unique_lock<std::mutex> lk(mtx);
  cv.wait(lk, [&done] { return done; });
}

int mbl_map_android_zero_copy_active(MblMap *m) {
  return (m != nullptr && m->androidZeroCopy) ? 1 : 0;
}
#endif // __ANDROID__
