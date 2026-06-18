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

#if defined(__APPLE__)
  // Zero-copy present (macOS Metal). When `zeroCopy` is set, the render thread
  // renders into mbgl's Metal texture and GPU-blits it into an IOSurface via
  // `blitter` instead of the CPU readback path; `currentSurface` is the latest
  // IOSurface. `blitter`/`currentSurface` are touched only on the render thread,
  // except `currentSurface` is also read under `frameMutex` by the IOSurface
  // getter. `zeroCopy` is flipped via a posted command (so it changes on-thread).
  bool zeroCopy = false;
  MblMetalBlitter *blitter = nullptr;
  IOSurfaceRef currentSurface = nullptr;
#endif

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

  m->map = nullptr;
  m->frontend = nullptr;
#if defined(__APPLE__)
  if (m->blitter != nullptr) {
    mbl_metal_blitter_destroy(m->blitter);
    m->blitter = nullptr;
  }
#endif
  // map / frontend / loop are destroyed here, on the render thread.
}

// Render thread (Continuous). Publishes the frame already drawn into mbgl's
// texture (present + swap have completed by the time the frame observer fires,
// so the texture is final). Zero-copy blit when enabled, else a CPU readback.
void publishCurrentFrame(MblMap *m) {
  if (m->map == nullptr || m->frontend == nullptr) {
    return;
  }
  try {
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
  m->map = nullptr;
  m->frontend = nullptr;
#if defined(__APPLE__)
  if (m->blitter != nullptr) {
    mbl_metal_blitter_destroy(m->blitter);
    m->blitter = nullptr;
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
  m->post([m, width, height] {
    m->frontend->setSize(mbgl::Size{width, height});
    m->map->setSize(mbgl::Size{width, height});
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
#else
  // No zero-copy present off-Apple (GL has no public texture handle); the CPU
  // mbl_map_copy_frame path is used instead.
  (void)m;
  (void)enabled;
#endif
}

void *mbl_map_current_iosurface(MblMap *m) {
#if defined(__APPLE__)
  if (m == nullptr) {
    return nullptr;
  }
  std::lock_guard<std::mutex> lk(m->frameMutex);
  return (void *)m->currentSurface;
#else
  (void)m;
  return nullptr;
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
