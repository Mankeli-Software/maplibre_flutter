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
#include <mbgl/util/size.hpp>

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

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

  // Construction handshake (create() returns once the map is built).
  std::mutex startMutex;
  std::condition_variable startCv;
  bool started = false;

  // Latest rendered frame (RGBA premultiplied), guarded.
  std::mutex frameMutex;
  std::condition_variable frameCv;
  mbgl::PremultipliedImage frame;
  uint64_t frameCount = 0;

  // Cached camera (set-through, read by the getter without touching the map).
  std::mutex cameraMutex;
  CameraState camera;

  // Frame-ready callback (called on the render thread).
  std::mutex cbMutex;
  MblFrameCallback frameCb = nullptr;
  void *frameCbUser = nullptr;

  void post(std::function<void()> fn) {
    {
      std::lock_guard<std::mutex> lk(queueMutex);
      queue.push_back(std::move(fn));
    }
    queueCv.notify_one();
  }
};

namespace {

void publishFrame(MblMap *m, mbgl::PremultipliedImage img) {
  {
    std::lock_guard<std::mutex> lk(m->frameMutex);
    m->frame = std::move(img);
    ++m->frameCount;
  }
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

// Render thread only. Guards against mbgl throwing (e.g. a style/tile load
// failure surfaces as std::runtime_error during render) so it logs instead of
// terminating the host process.
void renderNow(MblMap *m) {
  if (m->map == nullptr || m->frontend == nullptr) {
    return;
  }
  try {
    auto result = m->frontend->render(*m->map);
    publishFrame(m, std::move(result.image));
  } catch (const std::exception &e) {
    fprintf(stderr, "maplibre_flutter_core: render failed: %s\n", e.what());
  } catch (...) {
    fprintf(stderr, "maplibre_flutter_core: render failed (unknown)\n");
  }
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
    std::function<void()> cmd;
    {
      std::unique_lock<std::mutex> lk(m->queueMutex);
      m->queueCv.wait(lk, [m] { return m->stop || !m->queue.empty(); });
      if (m->stop && m->queue.empty()) {
        break;
      }
      cmd = std::move(m->queue.front());
      m->queue.pop_front();
    }
    cmd();
  }

  m->map = nullptr;
  m->frontend = nullptr;
  // map / frontend / loop are destroyed here, on the render thread.
}

} // namespace

MblMap *mbl_map_create(uint32_t width, uint32_t height, float pixel_ratio,
                       const char *style_uri) {
  if (width == 0 || height == 0) {
    return nullptr;
  }
  auto *m = new MblMap();
  const std::string style = style_uri != nullptr ? std::string(style_uri) : "";
  m->thread =
      std::thread(renderThreadMain, m, width, height, pixel_ratio, style);
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
    renderNow(m);
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
    renderNow(m);
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
    renderNow(m);
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
  if (m == nullptr || dst == nullptr) {
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
  if (dst_capacity < static_cast<size_t>(stride) * h) {
    return 0;
  }
  // mbgl yields RGBA; swizzle to BGRA for the macOS CVPixelBuffer.
  const uint8_t *src = m->frame.data.get();
  for (uint32_t i = 0; i < w * h; ++i) {
    dst[i * 4 + 0] = src[i * 4 + 2]; // B
    dst[i * 4 + 1] = src[i * 4 + 1]; // G
    dst[i * 4 + 2] = src[i * 4 + 0]; // R
    dst[i * 4 + 3] = src[i * 4 + 3]; // A
  }
  return 1;
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
  {
    std::lock_guard<std::mutex> lk(m->queueMutex);
    m->stop = true;
  }
  m->queueCv.notify_all();
  if (m->thread.joinable()) {
    m->thread.join();
  }
  delete m;
}
