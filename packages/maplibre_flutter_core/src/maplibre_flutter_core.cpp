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

#include "maplibre_flutter_core_model.hpp"

#include <mbgl/gfx/backend_scope.hpp>
#include <mbgl/gfx/headless_frontend.hpp>
#include <mbgl/map/bound_options.hpp>
#include <mbgl/map/camera.hpp>
#include <mbgl/map/map.hpp>
#include <mbgl/map/map_observer.hpp>
#include <mbgl/map/map_options.hpp>
#include <mbgl/map/mode.hpp>
// Private mbgl header (under maplibre-native/src, added to this shim's include
// path in CMakeLists). TransformState is a copyable value type that does the
// pure projection math (latLng <-> screen, exact for bearing/pitch). We snapshot
// a copy on every camera change so projection runs off the render thread.
#include <mbgl/map/transform_state.hpp>
#include <mbgl/storage/file_source_manager.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/style/image_impl.hpp>
#include <mbgl/style/style.hpp>
#include <mbgl/style/style_impl.hpp>
#include <mbgl/style/transition_options.hpp>
// Style mutation (sources/layers/images) for engine-drawn datasets. The
// conversion headers live under mbgl's private src/, which is already on this
// shim's include path (see CMakeLists) — convertJSON gives us the whole style
// spec, including cluster options and data-driven expressions, for free.
#include <mbgl/style/conversion/filter.hpp>
#include <mbgl/style/conversion/geojson.hpp>
#include <mbgl/style/conversion/json.hpp>
#include <mbgl/style/conversion/layer.hpp>
#include <mbgl/style/conversion/stringify.hpp>
#include <mbgl/style/rapidjson_conversion.hpp>
#include <mbgl/style/style_property.hpp>
#include <mbgl/util/rapidjson.hpp>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>
#include <mbgl/style/conversion/source.hpp>
#include <mbgl/style/image.hpp>
#include <mbgl/style/layer.hpp>
#include <mbgl/style/source.hpp>
#include <mbgl/style/sources/geojson_source.hpp>
// Rendered-feature query: the renderer lives on the frontend, and results come
// back as mbgl Features which mapbox::geojson can stringify for us.
#include <mapbox/geojson.hpp>
#include <mbgl/renderer/query.hpp>
#include <mbgl/renderer/renderer.hpp>
#include <mbgl/util/geojson.hpp>
#include <mbgl/util/client_options.hpp>
#include <mbgl/util/geo.hpp>
#include <mbgl/util/image.hpp>
#include <mbgl/util/logging.hpp>
#include <mbgl/util/unitbezier.hpp>
#include <mbgl/util/run_loop.hpp>
#include <mbgl/util/size.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
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
#include <unordered_map>
#include <vector>

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

// Defined with the other diagnostics helpers below; declared here because
// MblMap::post reports through it.
void dispatchDiagnostic(MblMap *m, MblDiagnosticKind kind,
                        MblDiagnosticSeverity severity,
                        const std::string &message);
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

  // Projection snapshot for anchoring widgets to LatLng. On each camera/size
  // change the render thread copies mbgl's TransformState here; the projection
  // functions (mbl_map_pixel(s)_for_lat_lng(s) / lat_lng_for_pixel) run pure math
  // on a copy of it from any thread. `projGeneration` bumps on every update (0 =
  // none yet). A dedicated mutex so projection never contends with getCamera.
  std::mutex projMutex;
  mbgl::TransformState projState;
  uint64_t projGeneration = 0;
  bool projValid = false;

  // Frame-correlated projection. Camera commands are applied ASYNCHRONOUSLY on
  // the render thread, so the newest transform is typically one or more updates
  // AHEAD of the frame the compositor is actually showing. Projecting against
  // the newest one makes anchored widgets swim against the map during movement.
  //
  // So keep a small ring of recent transforms keyed by generation, and record
  // which generation produced the frame that was last published. A caller can
  // then project against the transform of the frame ON SCREEN and stay glued.
  // The ring is tiny and fixed: only a few frames can be in flight, and a miss
  // (generation already evicted) degrades to the newest transform.
  static constexpr size_t kProjRing = 8;
  mbgl::TransformState projRing[kProjRing];
  uint64_t projRingGen[kProjRing] = {};
  // Generation of the most recently PUBLISHED frame. Guarded by projMutex.
  uint64_t presentedGeneration = 0;
  // Render-thread-only handoff: the generation captured for the frame currently
  // being presented, applied to `presentedGeneration` when the frame lands (the
  // zero-copy blit completes asynchronously on a GPU-callback thread).
  uint64_t pendingPresentGen = 0;

  // Sticky style transition options. Loading a style RESETS the style's own
  // transition options to whatever the document says (mbgl style_impl.cpp:
  // `transitionOptions = parser.transition`), so a caller's request has to be
  // remembered and re-applied every time a style finishes loading — the same
  // hazard as sources and layers being wiped by a style swap. Render-thread only.
  bool transitionOptionsSet = false;
  int32_t transitionDurationMs = -1; // <0 = leave the document/engine default
  int32_t transitionDelayMs = -1;
  bool placementTransitions = true;

  // Frame-ready callback (called on the render thread).
  std::mutex cbMutex;
  MblFrameCallback frameCb = nullptr;
  void *frameCbUser = nullptr;

  // Diagnostic callback, guarded by the same mutex. Called on the render thread
  // for observer events, and on whichever thread logged for MBL_DIAG_LOG.
  MblDiagnosticCallback diagCb = nullptr;
  void *diagCbUser = nullptr;

  // Camera-finished callback, guarded by cbMutex like the others. Fires on the
  // render thread when an animated move ends or is superseded.
  MblCameraFinishCallback cameraFinishCb = nullptr;
  void *cameraFinishCbUser = nullptr;

  // How many styles have finished loading. Registration necessarily happens
  // after mbl_map_create — the caller has to have the handle first — and a
  // style can finish loading in under 200 ms, so without remembering this a
  // listener would routinely miss the FIRST load, which is the one that
  // matters. Replayed once on registration; see mbl_map_set_diagnostic_callback.
  std::atomic<uint32_t> styleLoadCount{0};

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

  // Live models by layer id (render thread only).
  //
  // Holds the parsed mesh AND the placement, both shared with the host. The
  // placement lets mbl_map_set_model_transform move a model without re-uploading
  // geometry; keeping the mesh lets a model be re-added after a style reload
  // (which destroys every custom layer) WITHOUT re-reading and re-parsing the
  // .glb — tens of megabytes for a real asset. The mesh is immutable, so sharing
  // costs nothing.
  struct ModelEntry {
    std::shared_ptr<const MblMeshData> mesh;
    std::shared_ptr<MblMeshGpu> gpu;
    std::shared_ptr<MblModelPlacement> placement;
  };
  std::unordered_map<std::string, ModelEntry> models;

  // Runtime images by id (render thread only), retained for the same reason the
  // meshes above are.
  //
  // Style::Impl::parse() does `images = makeMutable<ImageImpls>()`
  // (style_impl.cpp:104), so EVERY style load wipes every runtime image — and
  // unlike a source or a layer, an image has no representation in the style
  // document the app could have put it in. It is a pure runtime registration,
  // so if we do not replay it nobody can: an app that rasterised a Flutter
  // widget into an icon would have to rasterise it again on every style change,
  // and would only find out it needed to because its symbols went blank.
  //
  // The pixels are already heap-held (mbl_map_add_image copies out of the
  // caller's buffer, which is Dart-owned and may be gone by the time the render
  // thread runs), so retaining costs one shared_ptr, not one more copy.
  struct ImageEntry {
    std::shared_ptr<const mbgl::PremultipliedImage> pixels;
    float pixelRatio;
    bool sdf;
  };
  std::unordered_map<std::string, ImageEntry> images;

  // Uploaded textures per .glb path, SHARED by every model this map draws from
  // that mesh (24 instances of one vehicle upload its 10 images once, not 240
  // times).
  //
  // Per-map, unlike the parsed mesh, and that distinction is load-bearing twice
  // over. A Texture2D belongs to ONE map's gfx context, so sharing it between
  // two maps hands the second map textures from a context it does not own; and
  // destroying one after its context is gone aborts with "mutex lock failed".
  // Both used to happen: the textures hung off the global mesh cache, so they
  // outlived every map and were released at static-destruction time — which
  // aborted (SIGABRT, exit 134) any process that had drawn a model, after all
  // its work was done. Cleared on the render thread inside a BackendScope
  // before the map and frontend go away; see renderThreadMain*.
  std::unordered_map<std::string, std::shared_ptr<MblMeshGpu>> gpuByPath;

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
      } else {
        // The window between mbl_map_create returning and the render thread
        // publishing its RunLoop. Anything posted here USED TO VANISH without
        // a trace — the classic shape is a camera set immediately after create
        // that simply does not happen.
        dispatchDiagnostic(
            this, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_ERROR,
            "command dropped: the render thread is not running yet");
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

// --- Diagnostics -------------------------------------------------------------

// Every map that currently has a diagnostic callback installed. Needed because
// mbgl's log observer is PROCESS-wide (Log::setObserver) and so cannot know
// which map a record belongs to; records fan out to all of them. Usually one.
std::mutex gDiagMapsMutex;
std::vector<MblMap *> gDiagMaps;
std::once_flag gLogObserverOnce;

// Hands one event to `m`'s callback, transferring an owned copy of `message`.
// Safe to call with no callback installed (does nothing, allocates nothing).
void dispatchDiagnostic(MblMap *m, MblDiagnosticKind kind,
                        MblDiagnosticSeverity severity,
                        const std::string &message) {
  MblDiagnosticCallback cb = nullptr;
  void *user = nullptr;
  {
    std::lock_guard<std::mutex> lk(m->cbMutex);
    cb = m->diagCb;
    user = m->diagCbUser;
  }
  if (cb == nullptr) return;
  // The receiver is necessarily asynchronous (a Dart NativeCallable.listener
  // hops to the isolate), so the string has to outlive this call. Ownership
  // goes with it; the receiver releases it with mbl_string_free.
  char *owned = static_cast<char *>(std::malloc(message.size() + 1));
  if (owned == nullptr) return;
  std::memcpy(owned, message.data(), message.size());
  owned[message.size()] = '\0';
  cb(user, static_cast<int32_t>(kind), static_cast<int32_t>(severity), owned);
}

// mbgl's own log stream, which is the ONLY place several failures surface.
// A glyph range that 404s is the motivating case: mbgl logs it and never calls
// MapObserver::onGlyphsError, so without this a style naming a font the tile
// server does not serve just renders no text, silently.
class DiagnosticLogObserver final : public mbgl::Log::Observer {
public:
  bool onRecord(mbgl::EventSeverity severity, mbgl::Event, int64_t,
                const std::string &msg) override {
    std::vector<MblMap *> maps;
    {
      std::lock_guard<std::mutex> lk(gDiagMapsMutex);
      maps = gDiagMaps;
    }
    for (MblMap *m : maps) {
      dispatchDiagnostic(m, MBL_DIAG_LOG,
                         static_cast<MblDiagnosticSeverity>(severity), msg);
    }
    // FALSE = not consumed, so mbgl still writes it to stderr. Returning true
    // here would silence the platform logging every existing debugging session
    // relies on.
    return false;
  }
};

// Renders an exception_ptr as a message, since that is all the ABI can carry.
std::string describeException(std::exception_ptr error) {
  if (!error) return "unknown error";
  try {
    std::rethrow_exception(error);
  } catch (const std::exception &e) {
    return e.what();
  } catch (...) {
    return "unknown error";
  }
}

// Turns mbgl's asynchronous events into diagnostic callbacks. Every override
// below reports something that otherwise reaches nobody: mbgl surfaces these
// here and, apart from its log stream, nowhere else — so a 404ing style or a
// missing sprite is a blank map and total silence.
//
// The style-layer id a model is drawn under.
//
// A model layer is a CustomDrawableLayer this shim creates and owns, but until
// now it took the app's id VERBATIM, putting it in the same namespace as every
// layer the app adds itself. Three live bugs came out of that overlap:
//
//   * removeLayer("car") deleted the model's layer but left m->models holding
//     it, so the next style load replayed a model the app had removed;
//   * that stale entry kept the Dart side ticking triggerRepaint forever;
//   * removeModel("car") called removeLayer("car"), which would happily delete
//     an unrelated style layer that happened to be called "car".
//
// Prefixing removes the overlap by construction. The layer is still enumerated
// by mbl_map_get_layer_ids — unlike mbgl's annotation layers, this one IS the
// app's, so moveLayer and queries must be able to name it — it just cannot
// collide with a style-document id, since ':' is not a character mbgl's own
// layer ids use.
constexpr const char *kModelLayerPrefix = "mbl:model:";

std::string modelLayerId(const std::string &appId) {
  return std::string(kModelLayerPrefix) + appId;
}

bool isModelLayerId(const std::string &id) {
  return id.rfind(kModelLayerPrefix, 0) == 0;
}

// Used as-is in Static mode; the Continuous map uses the FrameObserver subclass.
void replayRetainedStyleState(MblMap *m);

class DiagnosticObserver : public mbgl::MapObserver {
public:
  explicit DiagnosticObserver(MblMap *map) : m(map) {}

  void onDidFinishLoadingStyle() override {
    // Put back what the load just wiped, BEFORE telling anyone the style is in
    // — a listener that re-applies its own layers should run on a style that
    // already has ours back.
    replayRetainedStyleState(m);
    m->styleLoadCount.fetch_add(1, std::memory_order_relaxed);
    dispatchDiagnostic(m, MBL_DIAG_STYLE_LOADED, MBL_SEVERITY_INFO, "");
  }

  void onDidFinishLoadingMap() override {
    dispatchDiagnostic(m, MBL_DIAG_MAP_LOADED, MBL_SEVERITY_INFO, "");
  }

  void onDidFailLoadingMap(mbgl::MapLoadError error,
                           const std::string &what) override {
    const char *kind = "unknown error";
    switch (error) {
      case mbgl::MapLoadError::StyleParseError:
        kind = "style parse error";
        break;
      case mbgl::MapLoadError::StyleLoadError:
        kind = "style load error";
        break;
      case mbgl::MapLoadError::NotFoundError:
        kind = "not found";
        break;
      case mbgl::MapLoadError::UnknownError:
        break;
    }
    dispatchDiagnostic(m, MBL_DIAG_MAP_LOAD_FAILED, MBL_SEVERITY_ERROR,
                       std::string(kind) + ": " + what);
  }

  void onDidBecomeIdle() override {
    dispatchDiagnostic(m, MBL_DIAG_IDLE, MBL_SEVERITY_INFO, "");
  }

  void onStyleImageMissing(const std::string &id) override {
    dispatchDiagnostic(m, MBL_DIAG_STYLE_IMAGE_MISSING, MBL_SEVERITY_WARNING,
                       id);
  }

  // NOTE this one is effectively dead in our configuration — mbgl reports a
  // glyph 404 through Log, not here. Bound anyway because it costs nothing and
  // the day it starts firing is the day someone needs it.
  void onGlyphsError(const mbgl::FontStack &fontStack,
                     const mbgl::GlyphRange &range,
                     std::exception_ptr error) override {
    std::string fonts;
    for (const auto &font : fontStack) {
      if (!fonts.empty()) fonts += ",";
      fonts += font;
    }
    dispatchDiagnostic(m, MBL_DIAG_GLYPHS_ERROR, MBL_SEVERITY_ERROR,
                       fonts + " " + std::to_string(range.first) + "-" +
                           std::to_string(range.second) + ": " +
                           describeException(error));
  }

  void onSpriteError(const std::optional<mbgl::style::Sprite> &sprite,
                     std::exception_ptr error) override {
    const std::string id = sprite ? sprite->id : std::string("default");
    dispatchDiagnostic(m, MBL_DIAG_SPRITE_ERROR, MBL_SEVERITY_ERROR,
                       id + ": " + describeException(error));
  }

  void onRenderError(std::exception_ptr error) override {
    dispatchDiagnostic(m, MBL_DIAG_RENDER_ERROR, MBL_SEVERITY_ERROR,
                       describeException(error));
  }

protected:
  MblMap *m;
};


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

// Defined with the projection helpers below; used by the present paths here.
void markPresented(MblMap *m, uint64_t generation);
uint64_t updateProjState(MblMap *m);

void publishFrame(MblMap *m, mbgl::PremultipliedImage img) {
  // Record this frame's transform BEFORE announcing the frame. `frameCount` is
  // the "a frame is ready" signal that awaitFrame() and the present path wait
  // on, so anything woken by it must already see the matching generation —
  // marking afterwards races (the waiter reads the PREVIOUS generation).
  markPresented(m, m->pendingPresentGen);
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
  // Render thread: the frame is drawn, so snapshot the transform that produced
  // it and tag the frame with that generation (publishFrame consumes this).
  // Static mode renders here rather than through publishCurrentFrame, so this
  // is what keeps frame-correlated projection working outside Continuous mode.
  m->pendingPresentGen = updateProjState(m);
  publishFrame(m, std::move(result.image));
}

#if defined(__APPLE__)
// Called (on a Metal-owned thread) when a zero-copy blit's GPU work completes:
// publish the IOSurface as the current frame and announce it. The map outlives
// any in-flight blit — destroy drains the blitter on the render thread before
// the map is freed.
void blitDone(void *user, IOSurfaceRef surface) {
  auto *m = static_cast<MblMap *>(user);
  // Before the frameCount bump below announces the frame — see publishFrame.
  markPresented(m, m->pendingPresentGen);
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
  // Same as the CPU path: tag this frame with the transform it was drawn with,
  // for blitDone to adopt when the async blit lands.
  m->pendingPresentGen = updateProjState(m);
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

// Render thread only. Snapshots mbgl's current transform so the projection
// functions can run off-thread. Call after every camera/size change. Copying the
// TransformState is cheap (no render); getTransfromState() is mbgl's own const
// accessor (the spelling — "Transfrom" — is mbgl's, not a typo here).
uint64_t updateProjState(MblMap *m) {
  auto ts = m->map->getTransfromState();
  std::lock_guard<std::mutex> lk(m->projMutex);
  m->projState = ts;
  ++m->projGeneration;
  m->projValid = true;
  // Retain it in the ring so a frame published later can still be projected
  // against the transform that actually produced it.
  const size_t slot = m->projGeneration % MblMap::kProjRing;
  m->projRing[slot] = ts;
  m->projRingGen[slot] = m->projGeneration;
  return m->projGeneration;
}

// Marks `generation` as the transform of the frame now on screen. Called when a
// frame is published (CPU readback immediately; zero-copy when the blit lands).
void markPresented(MblMap *m, uint64_t generation) {
  if (generation == 0) return;
  std::lock_guard<std::mutex> lk(m->projMutex);
  // Frames can complete out of order across present paths; never move backwards.
  if (generation > m->presentedGeneration) m->presentedGeneration = generation;
}

// Copies out the transform to project against. `generation` 0 means "newest".
// A requested generation still in the ring is used; otherwise (evicted, or not
// yet recorded) this falls back to the newest snapshot. Returns 0 when there is
// no snapshot at all, else the generation actually used.
uint64_t takeProjState(MblMap *m, uint64_t generation,
                       mbgl::TransformState &out) {
  std::lock_guard<std::mutex> lk(m->projMutex);
  if (!m->projValid) return 0;
  if (generation != 0) {
    const size_t slot = generation % MblMap::kProjRing;
    if (m->projRingGen[slot] == generation) {
      out = m->projRing[slot];
      return generation;
    }
  }
  out = m->projState;
  return m->projGeneration;
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

namespace {

// A style can arrive three ways — a URL, a file path, or the document itself —
// and mbgl has two entry points with no sniffing between them. Everything used
// to go to loadURL, so inline JSON silently failed to load even though the C
// header (and four Dart doc comments) have always said it works. This is where
// that promise becomes true.
void loadStyleSpec(mbgl::style::Style &style, const std::string &spec) {
  const auto first = spec.find_first_not_of(" \t\r\n");
  if (first != std::string::npos && spec[first] == '{') {
    style.loadJSON(spec);
    return;
  }
  style.loadURL(spec);
}

} // namespace

void renderThreadMain(MblMap *m, uint32_t width, uint32_t height,
                      float pixelRatio, std::string styleUri) {
  mbgl::util::RunLoop loop;
  mbgl::HeadlessFrontend frontend(mbgl::Size{width, height}, pixelRatio);
  // Diagnostics only — Static mode publishes frames on demand, not on the
  // observer, and mbgl ignores transition options here anyway.
  DiagnosticObserver observer(m);
  mbgl::Map map(frontend, observer,
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
    loadStyleSpec(map.getStyle(), styleUri);
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

  // Release model GPU resources HERE: on the render thread, with the map and
  // frontend still alive so a BackendScope can make the context current.
  //
  // A Texture2D is bound to this map's gfx context. These used to hang off the
  // global mesh cache, so they outlived every map and were destroyed during
  // static destruction — long after the context and mbgl's own globals were
  // gone — which aborted the process with "mutex lock failed: Invalid argument"
  // AFTER all its work was done (SIGABRT / exit 134). Any app that had drawn a
  // model crashed on exit, and the model harness could never report green.
  if (m->frontend != nullptr && (!m->models.empty() || !m->gpuByPath.empty())) {
    mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
    m->models.clear();
    m->gpuByPath.clear();
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
  // Before the frameCount bump announces the frame — see publishFrame.
  markPresented(m, m->pendingPresentGen);
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
  // Render thread, immediately after mbgl finished this frame: snapshot the
  // transform that produced it and remember that generation, so whichever
  // present path runs below can tag the frame with it. (In Continuous mode mbgl
  // advances its own transitions, so re-snapshotting here — rather than reusing
  // the generation from the last camera command — is what keeps the recorded
  // transform truly equal to the one the frame was drawn with.)
  //
  // The CAMERA CACHE has to come along for the same reason. mbgl drives easeTo
  // and flyTo itself, so between the command and the last frame nothing else
  // would refresh it, and getCamera() would report the camera as it was BEFORE
  // the animation — for the whole animation and forever after it.
  updateCameraCache(m);
  m->pendingPresentGen = updateProjState(m);
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

// Pushes the remembered transition options onto the style. Render thread only.
void applyTransitionOptions(MblMap *m) {
  if (!m->transitionOptionsSet || m->map == nullptr) return;
  std::optional<mbgl::Duration> duration;
  std::optional<mbgl::Duration> delay;
  if (m->transitionDurationMs >= 0) {
    duration = mbgl::Milliseconds(m->transitionDurationMs);
  }
  if (m->transitionDelayMs >= 0) {
    delay = mbgl::Milliseconds(m->transitionDelayMs);
  }
  m->map->getStyle().setTransitionOptions(mbgl::style::TransitionOptions(
      duration, delay, m->placementTransitions));
}

// Defined further down with the model C API; declared here because the style
// observer below re-adds models.
void addModelLayerNow(MblMap *m, const std::string &layerId,
                      std::shared_ptr<const MblMeshData> mesh,
                      std::shared_ptr<MblMeshGpu> gpu,
                      std::shared_ptr<MblModelPlacement> placement);
void requestModelRender(MblMap *m);

// Observes the Continuous-mode map; each rendered frame (partial or full) is
// published, so the texture refines progressively as tiles stream in.
class FrameObserver final : public DiagnosticObserver {
public:
  explicit FrameObserver(MblMap *map) : DiagnosticObserver(map) {}
  void onDidFinishRenderingFrame(const RenderFrameStatus &) override {
    publishCurrentFrame(m);
  }

  // A freshly loaded style throws away two things we have to put back.
  //
  // Its transition options have just been overwritten with the document's, so
  // re-assert ours. Continuous mode only, which is also the only mode where mbgl
  // honours them at all (render_orchestrator.cpp forces default TransitionOptions
  // in Static).
  //
  // And the whole layer list is REPLACED, so every custom layer — therefore every
  // model — is dropped. Re-add them here rather than making callers notice and
  // re-add by hand. Free: the parsed mesh is retained and shared, so nothing is
  // re-read or re-parsed.
  // NOTE: no onDidFinishLoadingStyle override. There used to be one, doing the
  // re-adds and then dispatching, and it did NOT delegate — so the base's
  // styleLoadCount never moved, the replay for a late-registering callback
  // never fired, and since every shipped tier runs Continuous the example app
  // waited for a style load forever over a map that had rendered fine. The
  // whole job now lives in the base, where both modes get it and there is no
  // override left to forget to delegate.
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
    loadStyleSpec(map.getStyle(), styleUri);
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
  // Release model GPU resources HERE: on the render thread, with the map and
  // frontend still alive so a BackendScope can make the context current.
  //
  // A Texture2D is bound to this map's gfx context. These used to hang off the
  // global mesh cache, so they outlived every map and were destroyed during
  // static destruction — long after the context and mbgl's own globals were
  // gone — which aborted the process with "mutex lock failed: Invalid argument"
  // AFTER all its work was done (SIGABRT / exit 134). Any app that had drawn a
  // model crashed on exit, and the model harness could never report green.
  if (m->frontend != nullptr && (!m->models.empty() || !m->gpuByPath.empty())) {
    mbgl::gfx::BackendScope guard{*m->frontend->getBackend()};
    m->models.clear();
    m->gpuByPath.clear();
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
    loadStyleSpec(m->map->getStyle(), style);
    m->renderRequested = true;
  });
}

namespace {

// Post a model host onto the render thread as a CustomDrawableLayer. Re-adding
// under the same id must not throw there (an escaping exception would take the
// render loop down), so any previous instance is removed first.
// Adds (or replaces) a model layer on the render thread. Assumes the caller is
// already on it.
void addModelLayerNow(MblMap *m, const std::string &layerId,
                      std::shared_ptr<const MblMeshData> mesh,
                      std::shared_ptr<MblMeshGpu> gpu,
                      std::shared_ptr<MblModelPlacement> placement) {
  if (m->map == nullptr) {
    return;
  }
  if (m->map->getStyle().getLayer(layerId) != nullptr) {
    m->map->getStyle().removeLayer(layerId);
  }
  m->map->getStyle().addLayer(std::make_unique<mbgl::style::CustomDrawableLayer>(
      layerId, mblMakeModelHost(std::move(mesh), std::move(gpu),
                                std::move(placement))));
}

// A model's placement lives outside mbgl, so changing it does not invalidate the
// map. In Continuous mode nothing consumes `renderRequested` — rendering is
// driven by mbgl invalidation — so without an explicit triggerRepaint a moved
// model only appears to move when something ELSE redraws the map (a pan, a tile
// load). That is exactly the "it only drives while the map is moving" symptom.
void requestModelRender(MblMap *m) {
  m->renderRequested = true;
  if (m->map != nullptr) {
    m->map->triggerRepaint();
  }
}

// Put back everything a style load just destroyed that ONLY this layer can put
// back. Runs on the render thread from the style-load observer, in both map
// modes.
//
// The line drawn here is deliberate, and it is not "everything the app added".
// A source or a layer has a representation in a style document, so an app can
// re-add it from onStyleLoaded (that is what gl-js, the Apple SDK and the
// Android SDK all require, and MLNStyle.h:32-36 says so explicitly). These
// three cannot be re-added that way by anyone:
//
//   * transition options — style-global state with no document form in our API;
//   * runtime images — pure registrations; Style::Impl::parse() wipes them with
//     `images = makeMutable<ImageImpls>()` (style_impl.cpp:104);
//   * model layers — CustomDrawableLayers over an uploaded GPU mesh; re-adding
//     one from Dart would re-read and re-parse a .glb, tens of megabytes for a
//     real asset.
//
// Anything whose replay would merely save the app a call belongs in the app,
// behind MapLibreMap.retainRuntimeStyle, not here.
void replayRetainedStyleState(MblMap *m) {
  if (m == nullptr || m->map == nullptr) return;
  applyTransitionOptions(m);

  // Images BEFORE model layers, and before the app's own re-adds: a symbol
  // layer whose icon-image is not registered when it is added reports
  // onStyleImageMissing and draws nothing, so this order is not cosmetic.
  for (const auto &entry : m->images) {
    m->map->getStyle().addImage(std::make_unique<mbgl::style::Image>(
        entry.first, entry.second.pixels->clone(), entry.second.pixelRatio,
        entry.second.sdf));
  }

  for (const auto &entry : m->models) {
    addModelLayerNow(m, entry.first, entry.second.mesh, entry.second.gpu,
                     entry.second.placement);
  }
  if (!m->models.empty()) {
    requestModelRender(m);
  }
}

void addModelLayer(MblMap *m, std::string layerId,
                   std::shared_ptr<const MblMeshData> mesh,
                   std::string meshKey, MblModelPlacement placement) {
  // The mesh goes through a shared_ptr because post() takes a std::function,
  // which requires a COPYABLE callable — and MblMeshData holds a
  // PremultipliedImage (move-only, it owns a unique_ptr buffer), so capturing it
  // by move would make the lambda move-only and fail to convert.
  auto placementPtr = std::make_shared<MblModelPlacement>(placement);
  // Namespace HERE, once. Everything below this line — m->models, the
  // style-load replay, the transform lookup — speaks the style id, so there is
  // exactly one place the two namespaces meet.
  layerId = modelLayerId(layerId);
  m->post([m, layerId = std::move(layerId), meshPtr = std::move(mesh),
           meshKey = std::move(meshKey), placementPtr] {
    // Resolve the shared texture set HERE, on the render thread: gpuByPath is
    // render-thread-confined like models, and the caller runs on whatever thread
    // called the C ABI.
    auto &slot = m->gpuByPath[meshKey];
    if (!slot) {
      slot = std::make_shared<MblMeshGpu>();
    }
    const auto gpuPtr = slot;
    addModelLayerNow(m, layerId, meshPtr, gpuPtr, placementPtr);
    // Retained so transform updates can find this model and so it can be re-added
    // after a style reload.
    m->models[layerId] = MblMap::ModelEntry{meshPtr, gpuPtr, placementPtr};
    requestModelRender(m);
  });
}

// Parsed meshes, shared between every model loaded from the same path and across
// maps. See mbl_map_add_model for why this exists.
//
// CPU data only. The uploaded textures deliberately live on MblMap::gpuByPath
// instead: they are context-bound, so caching them here made them outlive every
// map and abort at static destruction.
std::mutex meshCacheMutex;
std::unordered_map<std::string, std::shared_ptr<const MblMeshData>> meshCache;

void writeError(char *out, size_t capacity, const std::string &message) {
  if (out == nullptr || capacity == 0) {
    return;
  }
  const size_t n = std::min(message.size(), capacity - 1);
  std::memcpy(out, message.data(), n);
  out[n] = '\0';
}

} // namespace

int mbl_map_add_model(MblMap *m, const char *layer_id, const char *glb_path,
                      double lat, double lng, double scale, double heading_deg,
                      double spin_dps, double elevation_m, char *out_error,
                      size_t error_capacity) {
  if (out_error != nullptr && error_capacity > 0) {
    out_error[0] = '\0';
  }
  if (m == nullptr || layer_id == nullptr || glb_path == nullptr) {
    writeError(out_error, error_capacity, "null argument");
    return 0;
  }

  // Parsed on the CALLING thread: pure file/CPU work with no mbgl Map access, so
  // failures can be reported synchronously instead of being swallowed on the
  // render thread.
  // Parsed meshes are cached by path and SHARED between models. Without this, a
  // stress test spawning N copies of one vehicle re-reads and re-parses the whole
  // .glb N times — tens of megabytes each — which would dominate any measurement
  // and makes spawning many models impractical. The mesh is immutable, so sharing
  // is free; only the placement differs per instance.
  const std::string path(glb_path);
  std::shared_ptr<const MblMeshData> meshPtr;
  {
    std::lock_guard<std::mutex> lk(meshCacheMutex);
    const auto it = meshCache.find(path);
    if (it != meshCache.end()) {
      meshPtr = it->second;
    }
  }
  if (!meshPtr) {
    MblMeshData mesh;
    std::string error;
    if (!mblLoadGlb(path, mesh, error)) {
      writeError(out_error, error_capacity, error);
      return 0;
    }
    meshPtr = std::make_shared<const MblMeshData>(std::move(mesh));
    std::lock_guard<std::mutex> lk(meshCacheMutex);
    meshCache.emplace(path, meshPtr);
  }

  // The texture set is resolved on the render thread inside addModelLayer (it is
  // per-map and render-thread-confined); the path is the key it uses.

  addModelLayer(m, std::string(layer_id), meshPtr, path,
                MblModelPlacement{.lat = lat,
                                  .lng = lng,
                                  .scale = scale,
                                  .headingDegrees = heading_deg,
                                  .spinDegreesPerSecond = spin_dps,
                                  .elevationMetres = elevation_m});
  return 1;
}

void mbl_map_set_model_transform(MblMap *m, const char *layer_id, double lat,
                                 double lng, double scale, double heading_deg,
                                 double elevation_m) {
  if (m == nullptr || layer_id == nullptr) {
    return;
  }
  m->post([m, layerId = modelLayerId(std::string(layer_id)), lat, lng, scale,
           heading_deg, elevation_m] {
    const auto it = m->models.find(layerId);
    if (it == m->models.end() || !it->second.placement) {
      return;
    }
    // Mutating the shared placement is enough — the host re-reads it every frame,
    // so the geometry is never re-uploaded.
    auto &p = *it->second.placement;
    p.lat = lat;
    p.lng = lng;
    p.scale = scale;
    p.headingDegrees = heading_deg;
    p.elevationMetres = elevation_m;
    requestModelRender(m);
  });
}

uint64_t mbl_map_frame_count(MblMap *m) {
  if (m == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lk(m->frameMutex);
  return m->frameCount;
}

uint32_t mbl_model_part_count(const char *glb_path) {
  if (glb_path == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lk(meshCacheMutex);
  const auto it = meshCache.find(std::string(glb_path));
  if (it == meshCache.end() || !it->second) {
    return 0;
  }
  return static_cast<uint32_t>(it->second->parts.size());
}

void mbl_map_remove_model(MblMap *m, const char *layer_id) {
  if (m == nullptr || layer_id == nullptr) {
    return;
  }
  m->post([m, layerId = modelLayerId(std::string(layer_id))] {
    if (m->map == nullptr) {
      return;
    }
    if (m->map->getStyle().getLayer(layerId) != nullptr) {
      m->map->getStyle().removeLayer(layerId);
      requestModelRender(m);
    }
    // ALWAYS erase, even when the style layer was already gone: the retention is
    // what the style-load replay reads, so leaving it behind is precisely how a
    // removed model came back.
    m->models.erase(layerId);
  });
}

void mbl_map_add_test_model(MblMap *m, const char *layer_id, double lat,
                            double lng,
                            double metres_per_unit, double spin_dps,
                            double elevation_m) {
  if (m == nullptr) {
    return;
  }
  addModelLayer(m, layer_id == nullptr ? "mbl-test-model" : layer_id,
                std::make_shared<const MblMeshData>(mblMakeTestPyramid()),
                "<test-pyramid>",
                MblModelPlacement{.lat = lat,
                                  .lng = lng,
                                  .scale = metres_per_unit,
                                  .headingDegrees = 0.0,
                                  .spinDegreesPerSecond = spin_dps,
                                  .elevationMetres = elevation_m});
}

void mbl_map_trigger_repaint(MblMap *m) {
  if (m == nullptr) {
    return;
  }
  m->post([m] {
    if (m->map == nullptr) {
      return;
    }
    m->map->triggerRepaint();
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
    updateProjState(m);
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
    updateProjState(m); // viewport size feeds the projection
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
    updateProjState(m);
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
    updateProjState(m);
    m->renderRequested = true;
  });
}

// Both of the following are built on jumpTo + CameraOptions rather than on
// mbgl's own Map::rotateBy / Map::pitchBy, because BOTH of those are broken
// upstream:
//
//   Transform::rotateBy computes
//       std::sqrt(std::pow(2, offset.x) + std::pow(2, offset.y))
//   which is 2^x + 2^y, not x^2 + y^2. Its "if the touch is within 200px of
//   centre, shift the rotation centre" heuristic therefore fires on garbage:
//   the pseudo-distance is ~0 for any negative offset (so the shift ALWAYS
//   fires left/above centre) and passes 200 at about +16px (so it NEVER fires
//   right/below). Rotation would feel wildly asymmetric about the centre.
//   Inherited from mapbox-gl-native; an upstream-PR candidate.
//
//   Map::pitchBy SUBTRACTS its argument
//       easeTo(CameraOptions().withPitch(rad2deg(transform.getPitch()) - pitch))
//   so pitchBy(+10) tilts DOWN, not up.
//
// Two further constraints, both load-bearing:
//   - Never set .withCenter() alongside .withAnchor(): transform.cpp reads
//     `anchor = camera.center ? std::nullopt : camera.anchor`, silently
//     discarding the anchor. That alone rules out implementing these as
//     get-camera-then-set-camera, since mbl_map_set_camera always sends centre.
//   - The read-modify-write must happen INSIDE the posted lambda. Doing the
//     arithmetic in Dart would read m->camera, a cache refreshed on the render
//     thread, so a fast twist would read a stale bearing and drop deltas.
void mbl_map_rotate_by(MblMap *m, double degrees, double anchor_x,
                       double anchor_y) {
  if (m == nullptr) {
    return;
  }
  // mbgl::LatLng's constructor throws on non-finite values and a throw across
  // this extern "C" boundary is UB; a NaN bearing would also poison the camera
  // cache. Reject rather than sanitize — there is no sensible NaN rotation.
  if (!std::isfinite(degrees) || !std::isfinite(anchor_x) ||
      !std::isfinite(anchor_y)) {
    return;
  }
  m->post([m, degrees, anchor_x, anchor_y] {
    const auto cam = m->map->getCameraOptions();
    // Minus: bearing is the compass direction that is up, so turning the
    // content clockwise lowers it. See the header — the sign lives here once.
    m->map->jumpTo(mbgl::CameraOptions()
                       .withBearing(cam.bearing.value_or(0.0) - degrees)
                       .withAnchor(mbgl::ScreenCoordinate{anchor_x, anchor_y}));
    updateCameraCache(m);
    updateProjState(m);
    m->renderRequested = true;
  });
}

// --- Camera commands ---------------------------------------------------------

namespace {

// Translates the C partial camera into mbgl's, field by field.
//
// The ONE rule that matters: never invent a centre. `Transform::startTransition`
// reads `anchor = camera.center ? std::nullopt : camera.anchor`, so a centre
// added here — for convenience, or by a get-then-set caller — silently destroys
// the anchor and every anchored zoom becomes a centre zoom.
mbgl::CameraOptions toCameraOptions(const MblCameraOptions &c) {
  mbgl::CameraOptions out;
  if (c.has_center != 0 && std::isfinite(c.center_lat) &&
      std::isfinite(c.center_lng) && std::abs(c.center_lat) <= 90.0) {
    // mbgl::LatLng throws on NaN / |lat| > 90 and a throw across this extern "C"
    // boundary is UB, so a bad centre is dropped rather than constructed.
    out = out.withCenter(mbgl::LatLng{c.center_lat, c.center_lng});
  }
  if (c.has_zoom != 0 && std::isfinite(c.zoom)) out = out.withZoom(c.zoom);
  if (c.has_bearing != 0 && std::isfinite(c.bearing)) {
    out = out.withBearing(c.bearing);
  }
  if (c.has_pitch != 0 && std::isfinite(c.pitch)) out = out.withPitch(c.pitch);
  if (c.has_roll != 0 && std::isfinite(c.roll)) out = out.withRoll(c.roll);
  if (c.has_padding != 0) {
    out = out.withPadding(mbgl::EdgeInsets{c.padding_top, c.padding_left,
                                           c.padding_bottom, c.padding_right});
  }
  if (c.has_anchor != 0 && std::isfinite(c.anchor_x) &&
      std::isfinite(c.anchor_y)) {
    out = out.withAnchor(mbgl::ScreenCoordinate{c.anchor_x, c.anchor_y});
  }
  return out;
}

void fromCameraOptions(const mbgl::CameraOptions &in, MblCameraOptions *out) {
  if (out == nullptr) return;
  *out = MblCameraOptions{};
  if (in.center) {
    out->has_center = 1;
    out->center_lat = in.center->latitude();
    out->center_lng = in.center->longitude();
  }
  if (in.zoom) {
    out->has_zoom = 1;
    out->zoom = *in.zoom;
  }
  if (in.bearing) {
    out->has_bearing = 1;
    out->bearing = *in.bearing;
  }
  if (in.pitch) {
    out->has_pitch = 1;
    out->pitch = *in.pitch;
  }
  if (in.roll) {
    out->has_roll = 1;
    out->roll = *in.roll;
  }
  if (in.padding) {
    out->has_padding = 1;
    out->padding_top = in.padding->top();
    out->padding_right = in.padding->right();
    out->padding_bottom = in.padding->bottom();
    out->padding_left = in.padding->left();
  }
  if (in.anchor) {
    out->has_anchor = 1;
    out->anchor_x = in.anchor->x;
    out->anchor_y = in.anchor->y;
  }
}

// Fires the caller's completion token. Attached as AnimationOptions::
// transitionFinishFn, which mbgl invokes both on natural end AND when a new
// transition supersedes this one (Transform::startTransition calls the previous
// finish fn before installing its own).
std::function<void()> makeFinishFn(MblMap *m, uint64_t token) {
  if (token == 0) return nullptr;
  return [m, token] {
    MblCameraFinishCallback cb = nullptr;
    void *user = nullptr;
    {
      std::lock_guard<std::mutex> lk(m->cbMutex);
      cb = m->cameraFinishCb;
      user = m->cameraFinishCbUser;
    }
    if (cb != nullptr) cb(user, token);
  };
}

mbgl::AnimationOptions toAnimationOptions(const MblAnimationOptions *a,
                                          MblMap *m, uint64_t token) {
  mbgl::AnimationOptions out;
  if (a != nullptr) {
    if (a->has_duration != 0) {
      out.duration = mbgl::Duration(std::chrono::milliseconds(a->duration_ms));
    }
    if (a->has_easing != 0) {
      // emplace, not assign: UnitBezier has const members, so
      // std::optional<UnitBezier>'s copy-assignment operator is deleted.
      out.easing.emplace(a->easing_x1, a->easing_y1, a->easing_x2,
                         a->easing_y2);
    }
    if (a->has_speed != 0 && std::isfinite(a->speed)) {
      out.velocity = a->speed;
    }
    if (a->has_apex_zoom != 0 && std::isfinite(a->apex_zoom)) {
      out.minZoom = a->apex_zoom;
    }
  }
  out.transitionFinishFn = makeFinishFn(m, token);
  return out;
}

// Runs `work` on the render thread and waits for it, with a deadline. Used by
// the three read-back calls, whose answers need the LIVE transform — a busy
// render thread costs a failed read rather than a hung caller.
bool runOnRenderThread(MblMap *m, uint32_t timeout_ms,
                       std::function<void()> work) {
  struct Sync {
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
  };
  auto sync = std::make_shared<Sync>();
  m->post([sync, work] {
    work();
    {
      std::lock_guard<std::mutex> lk(sync->mutex);
      sync->done = true;
    }
    sync->cv.notify_all();
  });
  std::unique_lock<std::mutex> lk(sync->mutex);
  return sync->cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                           [&] { return sync->done; });
}

mbgl::LatLngBounds toLatLngBounds(const MblLatLngBounds &b) {
  // hull() rather than the private two-corner constructor, and it also copes
  // with an inverted pair instead of asserting.
  return mbgl::LatLngBounds::hull(mbgl::LatLng{b.sw_lat, b.sw_lng},
                                  mbgl::LatLng{b.ne_lat, b.ne_lng});
}

bool boundsAreSane(const MblLatLngBounds &b) {
  return std::isfinite(b.sw_lat) && std::isfinite(b.sw_lng) &&
         std::isfinite(b.ne_lat) && std::isfinite(b.ne_lng) &&
         std::abs(b.sw_lat) <= 90.0 && std::abs(b.ne_lat) <= 90.0;
}

} // namespace

void mbl_map_set_camera_finish_callback(MblMap *m,
                                        MblCameraFinishCallback callback,
                                        void *user) {
  if (m == nullptr) return;
  std::lock_guard<std::mutex> lk(m->cbMutex);
  m->cameraFinishCb = callback;
  m->cameraFinishCbUser = user;
}

void mbl_map_jump_to(MblMap *m, const MblCameraOptions *camera) {
  if (m == nullptr || camera == nullptr) return;
  const MblCameraOptions copy = *camera;
  m->post([m, copy] {
    m->map->jumpTo(toCameraOptions(copy));
    updateCameraCache(m);
    updateProjState(m);
    m->renderRequested = true;
  });
}

void mbl_map_ease_to(MblMap *m, const MblCameraOptions *camera,
                     const MblAnimationOptions *animation, uint64_t token) {
  if (m == nullptr || camera == nullptr) return;
  const MblCameraOptions cam = *camera;
  const bool hasAnim = animation != nullptr;
  const MblAnimationOptions anim = hasAnim ? *animation : MblAnimationOptions{};
  m->post([m, cam, anim, hasAnim, token] {
    m->map->easeTo(toCameraOptions(cam),
                   toAnimationOptions(hasAnim ? &anim : nullptr, m, token));
    updateCameraCache(m);
    updateProjState(m);
    m->renderRequested = true;
  });
}

void mbl_map_fly_to(MblMap *m, const MblCameraOptions *camera,
                    const MblAnimationOptions *animation, uint64_t token) {
  if (m == nullptr || camera == nullptr) return;
  const MblCameraOptions cam = *camera;
  const bool hasAnim = animation != nullptr;
  const MblAnimationOptions anim = hasAnim ? *animation : MblAnimationOptions{};
  m->post([m, cam, anim, hasAnim, token] {
    m->map->flyTo(toCameraOptions(cam),
                  toAnimationOptions(hasAnim ? &anim : nullptr, m, token));
    updateCameraCache(m);
    updateProjState(m);
    m->renderRequested = true;
  });
}

void mbl_map_cancel_transitions(MblMap *m) {
  if (m == nullptr) return;
  m->post([m] {
    m->map->cancelTransitions();
    updateCameraCache(m);
    updateProjState(m);
    m->renderRequested = true;
  });
}

void mbl_map_fit_bounds(MblMap *m, const MblLatLngBounds *bounds,
                        double pad_top, double pad_right, double pad_bottom,
                        double pad_left, int32_t has_bearing, double bearing,
                        int32_t has_pitch, double pitch, int32_t mode,
                        const MblAnimationOptions *animation, uint64_t token) {
  if (m == nullptr || bounds == nullptr || !boundsAreSane(*bounds)) return;
  const MblLatLngBounds b = *bounds;
  const bool hasAnim = animation != nullptr;
  const MblAnimationOptions anim = hasAnim ? *animation : MblAnimationOptions{};
  m->post([m, b, pad_top, pad_right, pad_bottom, pad_left, has_bearing, bearing,
           has_pitch, pitch, mode, anim, hasAnim, token] {
    const mbgl::EdgeInsets padding{pad_top, pad_left, pad_bottom, pad_right};
    const auto camera = m->map->cameraForLatLngBounds(
        toLatLngBounds(b), padding,
        has_bearing != 0 && std::isfinite(bearing)
            ? std::optional<double>(bearing)
            : std::nullopt,
        has_pitch != 0 && std::isfinite(pitch) ? std::optional<double>(pitch)
                                               : std::nullopt);
    const auto options =
        toAnimationOptions(hasAnim ? &anim : nullptr, m, token);
    switch (mode) {
      case 1:
        m->map->easeTo(camera, options);
        break;
      case 2:
        m->map->flyTo(camera, options);
        break;
      default:
        m->map->jumpTo(camera);
        // jumpTo takes no AnimationOptions, so nothing would report the token.
        if (options.transitionFinishFn) options.transitionFinishFn();
        break;
    }
    updateCameraCache(m);
    updateProjState(m);
    m->renderRequested = true;
  });
}

int mbl_map_camera_for_lat_lng_bounds(MblMap *m, const MblLatLngBounds *bounds,
                                      double pad_top, double pad_right,
                                      double pad_bottom, double pad_left,
                                      int32_t has_bearing, double bearing,
                                      int32_t has_pitch, double pitch,
                                      uint32_t timeout_ms,
                                      MblCameraOptions *out_camera) {
  if (m == nullptr || bounds == nullptr || out_camera == nullptr ||
      !boundsAreSane(*bounds)) {
    return 0;
  }
  const MblLatLngBounds b = *bounds;
  auto result = std::make_shared<mbgl::CameraOptions>();
  const bool ok = runOnRenderThread(m, timeout_ms, [=] {
    *result = m->map->cameraForLatLngBounds(
        toLatLngBounds(b), mbgl::EdgeInsets{pad_top, pad_left, pad_bottom, pad_right},
        has_bearing != 0 && std::isfinite(bearing)
            ? std::optional<double>(bearing)
            : std::nullopt,
        has_pitch != 0 && std::isfinite(pitch) ? std::optional<double>(pitch)
                                               : std::nullopt);
  });
  if (!ok) return 0;
  fromCameraOptions(*result, out_camera);
  return 1;
}

int mbl_map_lat_lng_bounds_for_camera(MblMap *m, const MblCameraOptions *camera,
                                      uint32_t timeout_ms,
                                      MblLatLngBounds *out_bounds) {
  if (m == nullptr || camera == nullptr || out_bounds == nullptr) return 0;
  const MblCameraOptions cam = *camera;
  auto result = std::make_shared<mbgl::LatLngBounds>();
  const bool ok = runOnRenderThread(m, timeout_ms, [=] {
    // An empty partial camera means "the one on screen now", which is what
    // gl-js getBounds() asks for.
    const auto options = toCameraOptions(cam);
    *result = m->map->latLngBoundsForCamera(
        options == mbgl::CameraOptions{} ? m->map->getCameraOptions() : options);
  });
  if (!ok) return 0;
  out_bounds->sw_lat = result->south();
  out_bounds->sw_lng = result->west();
  out_bounds->ne_lat = result->north();
  out_bounds->ne_lng = result->east();
  return 1;
}

void mbl_map_set_bounds(MblMap *m, const MblBoundOptions *bounds) {
  if (m == nullptr || bounds == nullptr) return;
  const MblBoundOptions b = *bounds;
  m->post([m, b] {
    mbgl::BoundOptions options;
    if (b.has_bounds != 0 && boundsAreSane(b.bounds)) {
      options = options.withLatLngBounds(toLatLngBounds(b.bounds));
    }
    if (b.has_min_zoom != 0 && std::isfinite(b.min_zoom)) {
      options = options.withMinZoom(b.min_zoom);
    }
    if (b.has_max_zoom != 0 && std::isfinite(b.max_zoom)) {
      options = options.withMaxZoom(b.max_zoom);
    }
    if (b.has_min_pitch != 0 && std::isfinite(b.min_pitch)) {
      options = options.withMinPitch(b.min_pitch);
    }
    if (b.has_max_pitch != 0 && std::isfinite(b.max_pitch)) {
      options = options.withMaxPitch(b.max_pitch);
    }
    m->map->setBounds(options);
    updateCameraCache(m);
    updateProjState(m);
    m->renderRequested = true;
  });
}

int mbl_map_get_bounds(MblMap *m, uint32_t timeout_ms,
                       MblBoundOptions *out_bounds) {
  if (m == nullptr || out_bounds == nullptr) return 0;
  auto result = std::make_shared<mbgl::BoundOptions>();
  const bool ok = runOnRenderThread(
      m, timeout_ms, [m, result] { *result = m->map->getBounds(); });
  if (!ok) return 0;
  *out_bounds = MblBoundOptions{};
  if (result->bounds) {
    out_bounds->has_bounds = 1;
    out_bounds->bounds.sw_lat = result->bounds->south();
    out_bounds->bounds.sw_lng = result->bounds->west();
    out_bounds->bounds.ne_lat = result->bounds->north();
    out_bounds->bounds.ne_lng = result->bounds->east();
  }
  if (result->minZoom) {
    out_bounds->has_min_zoom = 1;
    out_bounds->min_zoom = *result->minZoom;
  }
  if (result->maxZoom) {
    out_bounds->has_max_zoom = 1;
    out_bounds->max_zoom = *result->maxZoom;
  }
  if (result->minPitch) {
    out_bounds->has_min_pitch = 1;
    out_bounds->min_pitch = *result->minPitch;
  }
  if (result->maxPitch) {
    out_bounds->has_max_pitch = 1;
    out_bounds->max_pitch = *result->maxPitch;
  }
  return 1;
}

void mbl_map_set_constrain_mode(MblMap *m, int32_t mode) {
  if (m == nullptr) return;
  m->post([m, mode] {
    mbgl::ConstrainMode value = mbgl::ConstrainMode::HeightOnly;
    switch (mode) {
      case 0: value = mbgl::ConstrainMode::None; break;
      case 1: value = mbgl::ConstrainMode::HeightOnly; break;
      case 2: value = mbgl::ConstrainMode::WidthAndHeight; break;
      case 3: value = mbgl::ConstrainMode::Screen; break;
      default: return;
    }
    m->map->setConstrainMode(value);
    updateCameraCache(m);
    updateProjState(m);
    m->renderRequested = true;
  });
}

void mbl_map_pitch_by(MblMap *m, double degrees) {
  if (m == nullptr || !std::isfinite(degrees)) {
    return;
  }
  m->post([m, degrees] {
    const auto cam = m->map->getCameraOptions();
    // Plus, unlike mbgl's own pitchBy. No clamp here: mbgl clamps to
    // [0, DEFAULT_PITCH_MAX] in Transform, and duplicating it would hide a
    // change to that limit.
    m->map->jumpTo(
        mbgl::CameraOptions().withPitch(cam.pitch.value_or(0.0) + degrees));
    updateCameraCache(m);
    updateProjState(m);
    m->renderRequested = true;
  });
}

// --- Projection -------------------------------------------------------------
// All four run pure math on a copy of the transform snapshot (taken out under
// projMutex, then released), so they never touch the live map and are safe from
// any thread. Screen coordinates are in mbgl Size units (logical points,
// matching the gesture/anchor space). The vec4 overload yields clip space:
// clip[3] (w) > 0 means the point is in front of the camera (visible); w <= 0
// means behind it on a pitched view.
//
// Y-AXIS: TransformState::latLngToScreenCoordinate returns a BOTTOM-UP y (its
// `size.height - y` converts *into* GL's bottom-up convention, not out of it),
// and screenCoordinateToLatLng expects the same. Flutter widget space is
// TOP-LEFT origin, so this shim flips y on the way out of project and on the way
// into unproject. Verified empirically, not assumed: a point NORTH of the camera
// centre must project ABOVE it (smaller y) — see the orientation tests. NOTE the
// flip is symmetric, so a project∘unproject round-trip CANNOT detect it; test
// against absolute directions, never only round-trips.

// mbgl::LatLng's constructor THROWS std::domain_error on NaN/infinite or
// |lat| > 90, and a C++ exception crossing this extern "C" boundary is undefined
// behavior. So sanitize first: reject non-finite, clamp latitude to the valid
// range. Returns false for a point we should not project (caller parks it).
static inline bool mbl_sanitize_lat_lng(double &lat, double &lng) {
  if (!std::isfinite(lat) || !std::isfinite(lng)) return false;
  if (lat < -90.0) lat = -90.0;
  if (lat > 90.0) lat = 90.0;
  return true;
}

int mbl_map_pixel_for_lat_lng(MblMap *m, double lat, double lng, double *out_x,
                              double *out_y, int *out_visible,
                              uint64_t generation) {
  if (m == nullptr) {
    return 0;
  }
  mbgl::TransformState state;
  if (takeProjState(m, generation, state) == 0) return 0;
  if (!mbl_sanitize_lat_lng(lat, lng)) {
    if (out_x) *out_x = 0;
    if (out_y) *out_y = 0;
    if (out_visible) *out_visible = 0;
    return 1;
  }
  mbgl::vec4 clip;
  const auto sc =
      state.latLngToScreenCoordinate(mbgl::LatLng{lat, lng}, clip);
  if (out_x) *out_x = sc.x;
  // mbgl::TransformState::latLngToScreenCoordinate returns a BOTTOM-LEFT-origin
  // y (transform_state.cpp:775 does `size.height - y`), which is NOT the space
  // mbgl's own gesture anchors use — scaleBy/moveBy take a TOP-LEFT-origin
  // ScreenCoordinate, hardware-verified on Linux and Windows. Flutter's widget
  // box is top-left too, so flip back here to make the two spaces agree and
  // match this header's contract. Without it every marker is mirrored
  // vertically about the map centre.
  if (out_y) *out_y = static_cast<double>(state.getSize().height) - sc.y;
  if (out_visible) *out_visible = clip[3] > 0.0 ? 1 : 0;
  return 1;
}

uint64_t mbl_map_pixels_for_lat_lngs(MblMap *m, const double *in_lat_lng,
                                     uint32_t count, double *out_xy,
                                     int *out_visible, uint64_t want_generation) {
  if (m == nullptr || in_lat_lng == nullptr || out_xy == nullptr) {
    return 0;
  }
  mbgl::TransformState state;
  const uint64_t generation = takeProjState(m, want_generation, state);
  if (generation == 0) return 0;
  const double height = static_cast<double>(state.getSize().height);
  for (uint32_t i = 0; i < count; ++i) {
    double lat = in_lat_lng[2 * i];
    double lng = in_lat_lng[2 * i + 1];
    if (!mbl_sanitize_lat_lng(lat, lng)) {
      out_xy[2 * i] = 0;
      out_xy[2 * i + 1] = 0;
      if (out_visible) out_visible[i] = 0;
      continue;
    }
    mbgl::vec4 clip;
    const auto sc = state.latLngToScreenCoordinate(mbgl::LatLng{lat, lng}, clip);
    out_xy[2 * i] = sc.x;
    // Bottom-left -> top-left, as in mbl_map_pixel_for_lat_lng above.
    out_xy[2 * i + 1] = height - sc.y;
    if (out_visible) out_visible[i] = clip[3] > 0.0 ? 1 : 0;
  }
  return generation;
}

int mbl_map_lat_lng_for_pixel(MblMap *m, double x, double y, double *out_lat,
                              double *out_lng, uint64_t generation) {
  if (m == nullptr) {
    return 0;
  }
  mbgl::TransformState state;
  if (takeProjState(m, generation, state) == 0) return 0;
  // Inverse of the flip above: callers pass top-left-origin screen coordinates
  // (Flutter widget space), and screenCoordinateToLatLng expects mbgl's
  // bottom-left-origin ScreenCoordinate.
  const auto ll = state.screenCoordinateToLatLng(
      mbgl::ScreenCoordinate{x, static_cast<double>(state.getSize().height) - y});
  if (out_lat) *out_lat = ll.latitude();
  if (out_lng) *out_lng = ll.longitude();
  return 1;
}

// --- Style sources / layers / images ----------------------------------------
// Parsing runs on the CALLING thread (it needs no map), so bad JSON is reported
// synchronously; only the style mutation is posted to the render thread. The
// converted object is move-only, and `post` stores a copyable std::function, so
// it travels inside a shared_ptr holder.

static void mbl_set_err(char *err, uint32_t err_len, const std::string &msg) {
  if (err == nullptr || err_len == 0) return;
  const size_t n = std::min<size_t>(msg.size(), err_len - 1);
  std::memcpy(err, msg.data(), n);
  err[n] = '\0';
}

int mbl_map_add_source_json(MblMap *m, const char *id, const char *json,
                            char *err, uint32_t err_len) {
  if (m == nullptr || id == nullptr || json == nullptr) {
    mbl_set_err(err, err_len, "null argument");
    return 0;
  }
  mbgl::style::conversion::Error error;
  auto source = mbgl::style::conversion::convertJSON<
      std::unique_ptr<mbgl::style::Source>>(json, error, std::string(id));
  if (!source) {
    mbl_set_err(err, err_len, error.message);
    return 0;
  }
  auto holder = std::make_shared<std::unique_ptr<mbgl::style::Source>>(
      std::move(*source));
  m->post([m, holder] {
    try {
      m->map->getStyle().addSource(std::move(*holder));
      m->renderRequested = true;
    } catch (const std::exception &e) {
      fprintf(stderr, "maplibre_flutter_core: addSource failed: %s\n", e.what());
    }
  });
  return 1;
}

int mbl_map_add_layer_json(MblMap *m, const char *json, const char *before_id,
                           char *err, uint32_t err_len) {
  if (m == nullptr || json == nullptr) {
    mbl_set_err(err, err_len, "null argument");
    return 0;
  }
  mbgl::style::conversion::Error error;
  auto layer = mbgl::style::conversion::convertJSON<
      std::unique_ptr<mbgl::style::Layer>>(json, error);
  if (!layer) {
    mbl_set_err(err, err_len, error.message);
    return 0;
  }
  auto holder =
      std::make_shared<std::unique_ptr<mbgl::style::Layer>>(std::move(*layer));
  // Copy the id now: the caller's buffer is not guaranteed to outlive the post.
  std::string before = before_id != nullptr ? std::string(before_id) : "";
  m->post([m, holder, before] {
    try {
      if (before.empty()) {
        m->map->getStyle().addLayer(std::move(*holder));
      } else {
        m->map->getStyle().addLayer(std::move(*holder), before);
      }
      m->renderRequested = true;
    } catch (const std::exception &e) {
      fprintf(stderr, "maplibre_flutter_core: addLayer failed: %s\n", e.what());
    }
  });
  return 1;
}

int mbl_map_set_geojson_data(MblMap *m, const char *source_id,
                             const char *geojson, char *err, uint32_t err_len) {
  if (m == nullptr || source_id == nullptr || geojson == nullptr) {
    mbl_set_err(err, err_len, "null argument");
    return 0;
  }
  mbgl::style::conversion::Error error;
  auto data =
      mbgl::style::conversion::convertJSON<mbgl::GeoJSON>(geojson, error);
  if (!data) {
    mbl_set_err(err, err_len, error.message);
    return 0;
  }
  auto holder = std::make_shared<mbgl::GeoJSON>(std::move(*data));
  std::string id(source_id);
  m->post([m, holder, id] {
    auto *src = m->map->getStyle().getSource(id);
    if (src == nullptr) {
      dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
                         "setSourceData: no source with id '" + id + "'");
      return;
    }
    auto *geo = src->as<mbgl::style::GeoJSONSource>();
    if (geo == nullptr) {
      // mbgl only lets you replace the data of a GeoJSON source — there is no
      // setter on a vector or raster one — so this is a real limit rather than
      // a missing binding, and worth saying out loud instead of printing.
      dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
                         "setSourceData: source '" + id +
                             "' is not a geojson source, so its data cannot "
                             "be replaced");
      return;
    }
    geo->setGeoJSON(*holder);
    m->renderRequested = true;
  });
  return 1;
}

void mbl_map_remove_layer(MblMap *m, const char *id) {
  if (m == nullptr || id == nullptr) return;
  std::string layerId(id);
  m->post([m, layerId] {
    // A model layer reached through the generic remove still has to drop its
    // retention, or the next style load replays it. Reachable because model
    // layers ARE enumerated by mbl_map_get_layer_ids — deliberately, since they
    // are the app's own.
    if (isModelLayerId(layerId)) {
      m->models.erase(layerId);
    }
    // The unique_ptr this returns is the whole error signal: null means there
    // was no such layer. Discarding it, as this used to, makes a typo'd id
    // indistinguishable from a successful removal.
    if (m->map->getStyle().removeLayer(layerId) == nullptr) {
      dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
                         "removeLayer: no layer with id '" + layerId + "'");
      return;
    }
    m->renderRequested = true;
  });
}

void mbl_map_remove_source(MblMap *m, const char *id) {
  if (m == nullptr || id == nullptr) return;
  std::string sourceId(id);
  m->post([m, sourceId] {
    // Two different failures come back as the same null: the source does not
    // exist, or a layer still references it (style_impl.cpp refuses and logs a
    // warning). Distinguish them here — "still in use" is the actionable one,
    // and it is the usual cause of a removal that appears to do nothing.
    auto &style = m->map->getStyle();
    const bool existed = style.getSource(sourceId) != nullptr;
    if (style.removeSource(sourceId) == nullptr) {
      dispatchDiagnostic(
          m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
          existed ? "removeSource: source '" + sourceId +
                        "' is still in use by a layer"
                  : "removeSource: no source with id '" + sourceId + "'");
      return;
    }
    m->renderRequested = true;
  });
}

int mbl_map_set_layer_property(MblMap *m, const char *layer_id,
                               const char *name, const char *value_json,
                               char *err, uint32_t err_len) {
  if (m == nullptr || layer_id == nullptr || name == nullptr ||
      value_json == nullptr) {
    mbl_set_err(err, err_len, "null argument");
    return 0;
  }
  // Parse HERE, on the calling thread, so malformed JSON is a synchronous
  // failure like the other two JSON entry points rather than a silent drop.
  // The document is shared into the lambda because Convertible borrows it.
  auto holder = std::make_shared<mbgl::JSDocument>();
  holder->Parse<0>(value_json);
  if (holder->HasParseError()) {
    mbl_set_err(err, err_len,
                mbgl::formatJSONParseError(*holder));
    return 0;
  }
  const std::string id(layer_id);
  const std::string property(name);
  m->post([m, holder, id, property] {
    auto *layer = m->map->getStyle().getLayer(id);
    if (layer == nullptr) {
      dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
                         "setLayerProperty: no layer with id '" + id + "'");
      return;
    }
    // One call covers paint, layout, visibility, minzoom, maxzoom and filter —
    // Layer::setProperty falls through to each in turn.
    // ConversionTraits is specialised for `const JSValue*`; JSDocument derives
    // from GenericValue, so this is the upcast rather than a reinterpretation.
    const mbgl::JSValue *value = holder.get();
    const auto failure = layer->setProperty(
        property, mbgl::style::conversion::Convertible(value));
    if (failure) {
      dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
                         "setLayerProperty '" + property + "' on '" + id +
                             "': " + failure->message);
      return;
    }
    m->renderRequested = true;
  });
  return 1;
}

void mbl_map_move_layer(MblMap *m, const char *layer_id,
                        const char *before_id) {
  if (m == nullptr || layer_id == nullptr) return;
  const std::string id(layer_id);
  const std::string before =
      before_id != nullptr ? std::string(before_id) : std::string();
  m->post([m, id, before] {
    // removeLayer returns the owning unique_ptr, so the Layer object itself
    // survives — nothing is re-parsed or re-uploaded to move it.
    auto layer = m->map->getStyle().removeLayer(id);
    if (layer == nullptr) {
      dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
                         "moveLayer: no layer with id '" + id + "'");
      return;
    }
    try {
      if (before.empty()) {
        m->map->getStyle().addLayer(std::move(layer));
      } else {
        m->map->getStyle().addLayer(std::move(layer), before);
      }
      m->renderRequested = true;
    } catch (const std::exception &e) {
      dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_ERROR,
                         "moveLayer '" + id + "': " + e.what());
    }
  });
}

namespace {

// Serialises an mbgl style Value to JSON, for the read side.
std::string styleValueToJson(const mbgl::Value &value) {
  rapidjson::StringBuffer buffer;
  rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
  mbgl::style::conversion::stringify(writer, value);
  return std::string(buffer.GetString(), buffer.GetSize());
}

char *dupToHeap(const std::string &text) {
  char *out = static_cast<char *>(std::malloc(text.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, text.data(), text.size());
  out[text.size()] = '\0';
  return out;
}

} // namespace

char *mbl_map_get_layer_property(MblMap *m, const char *layer_id,
                                 const char *name, uint32_t timeout_ms) {
  if (m == nullptr || layer_id == nullptr || name == nullptr) return nullptr;
  const std::string id(layer_id);
  const std::string property(name);
  auto result = std::make_shared<std::string>();
  auto found = std::make_shared<bool>(false);
  const bool ok = runOnRenderThread(m, timeout_ms, [m, id, property, result,
                                                    found] {
    auto *layer = m->map->getStyle().getLayer(id);
    if (layer == nullptr) return;
    const auto read = layer->getProperty(property);
    if (read.getKind() == mbgl::style::StyleProperty::Kind::Undefined) return;
    *result = styleValueToJson(read.getValue());
    *found = true;
  });
  if (!ok || !*found) return nullptr;
  return dupToHeap(*result);
}

// mbgl::AnnotationManager's SourceID, and the stem of both its layer ids.
// Hardcoded rather than referenced: annotation_manager.hpp is a private header
// under src/, not part of mbgl's installed interface.
constexpr const char *kAnnotationLayerPrefix = "org.maplibre.annotations";
char *mbl_map_get_layer_ids(MblMap *m, uint32_t timeout_ms) {
  if (m == nullptr) return nullptr;
  auto result = std::make_shared<std::string>();
  const bool ok = runOnRenderThread(m, timeout_ms, [m, result] {
    std::vector<mbgl::Value> ids;
    for (const auto *layer : m->map->getStyle().getLayers()) {
      // Skip mbgl's own annotation layers — see the header. Prefix, not equality:
      // shape annotations are "org.maplibre.annotations.shape.<n>", one per
      // shape, so an app with annotations would otherwise see the list grow.
      const auto &id = layer->getID();
      if (id.rfind(kAnnotationLayerPrefix, 0) == 0) continue;
      ids.emplace_back(id);
    }
    *result = styleValueToJson(mbgl::Value{ids});
  });
  return ok ? dupToHeap(*result) : nullptr;
}

char *mbl_map_get_layer_json(MblMap *m, const char *layer_id,
                             uint32_t timeout_ms) {
  if (m == nullptr || layer_id == nullptr) return nullptr;
  const std::string id(layer_id);
  auto result = std::make_shared<std::string>();
  auto found = std::make_shared<bool>(false);
  const bool ok =
      runOnRenderThread(m, timeout_ms, [m, id, result, found] {
        auto *layer = m->map->getStyle().getLayer(id);
        if (layer == nullptr) return;
        // serialize(), not Style::getJSON(): the latter returns the document as
        // LOADED, so it would not show anything the app added or changed.
        *result = styleValueToJson(layer->serialize());
        *found = true;
      });
  if (!ok || !*found) return nullptr;
  return dupToHeap(*result);
}

namespace {

const char *sourceTypeName(mbgl::style::SourceType type) {
  switch (type) {
    case mbgl::style::SourceType::Vector: return "vector";
    case mbgl::style::SourceType::Raster: return "raster";
    case mbgl::style::SourceType::RasterDEM: return "raster-dem";
    case mbgl::style::SourceType::GeoJSON: return "geojson";
    case mbgl::style::SourceType::Video: return "video";
    case mbgl::style::SourceType::Annotations: return "annotations";
    case mbgl::style::SourceType::Image: return "image";
    case mbgl::style::SourceType::CustomVector: return "custom-vector";
  }
  return "unknown";
}

std::string sourceToJson(const mbgl::style::Source &source) {
  rapidjson::StringBuffer buffer;
  rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
  writer.StartObject();
  writer.Key("id");
  writer.String(source.getID().c_str());
  writer.Key("type");
  writer.String(sourceTypeName(source.getType()));
  writer.Key("attribution");
  const auto attribution = source.getAttribution();
  if (attribution) {
    writer.String(attribution->c_str());
  } else {
    writer.Null();
  }
  writer.Key("volatile");
  writer.Bool(source.isVolatile());
  writer.EndObject();
  return std::string(buffer.GetString(), buffer.GetSize());
}

} // namespace

int mbl_map_has_image(MblMap *m, const char *id, uint32_t timeout_ms) {
  if (m == nullptr || id == nullptr) return 0;
  const std::string name(id);
  auto present = std::make_shared<bool>(false);
  const bool ok = runOnRenderThread(m, timeout_ms, [m, name, present] {
    *present = m->map->getStyle().getImage(name).has_value();
  });
  // -1 rather than 0 on timeout: "we could not ask" is not "it is not there",
  // and a caller deciding whether to re-register an image needs the difference.
  if (!ok) return -1;
  return *present ? 1 : 0;
}

char *mbl_map_get_image_ids(MblMap *m, uint32_t timeout_ms) {
  if (m == nullptr) return nullptr;
  auto result = std::make_shared<std::string>();
  const bool ok = runOnRenderThread(m, timeout_ms, [m, result] {
    // INTERNAL API: the public Style has getImage() but no getImages(), so the
    // collection comes from Style::Impl::getImageImpls() — a public accessor on
    // an internal class. `impl` is a public member and the shim already
    // includes internal headers, but this is a coupling to re-check on a core
    // bump; the marker to grep for is `style_impl.hpp`.
    std::vector<mbgl::Value> ids;
    for (const auto &image : *m->map->getStyle().impl->getImageImpls()) {
      ids.emplace_back(image->id);
    }
    *result = styleValueToJson(mbgl::Value{ids});
  });
  return ok ? dupToHeap(*result) : nullptr;
}

char *mbl_map_get_source_json(MblMap *m, const char *source_id,
                              uint32_t timeout_ms) {
  if (m == nullptr || source_id == nullptr) return nullptr;
  const std::string id(source_id);
  auto result = std::make_shared<std::string>();
  auto found = std::make_shared<bool>(false);
  const bool ok = runOnRenderThread(m, timeout_ms, [m, id, result, found] {
    const auto *source = m->map->getStyle().getSource(id);
    if (source == nullptr) return;
    *result = sourceToJson(*source);
    *found = true;
  });
  if (!ok || !*found) return nullptr;
  return dupToHeap(*result);
}

char *mbl_map_get_source_ids(MblMap *m, uint32_t timeout_ms) {
  if (m == nullptr) return nullptr;
  auto result = std::make_shared<std::string>();
  const bool ok = runOnRenderThread(m, timeout_ms, [m, result] {
    std::vector<mbgl::Value> ids;
    for (const auto *source : m->map->getStyle().getSources()) {
      // Same filter as the layer listing: AnnotationManager also injects its
      // own SOURCE, "org.maplibre.annotations", on every style load.
      const auto &id = source->getID();
      if (id.rfind(kAnnotationLayerPrefix, 0) == 0) continue;
      ids.emplace_back(id);
    }
    *result = styleValueToJson(mbgl::Value{ids});
  });
  return ok ? dupToHeap(*result) : nullptr;
}

void mbl_map_add_image(MblMap *m, const char *id, const uint8_t *rgba,
                       uint32_t width, uint32_t height, float pixel_ratio,
                       int sdf) {
  if (m == nullptr || id == nullptr || rgba == nullptr || width == 0 ||
      height == 0) {
    return;
  }
  // Copy the pixels now — the caller's buffer (Dart-owned) may be gone by the
  // time the render thread runs this.
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  mbgl::PremultipliedImage img({width, height});
  std::memcpy(img.data.get(), rgba, bytes);
  auto holder =
      std::make_shared<const mbgl::PremultipliedImage>(std::move(img));
  std::string imageId(id);
  const bool isSdf = sdf != 0;
  m->post([m, holder, imageId, pixel_ratio, isSdf] {
    // clone(), not move: the retained copy has to outlive this call so the
    // style-load observer can put the image back. mbgl takes the Image by value.
    m->images[imageId] = MblMap::ImageEntry{holder, pixel_ratio, isSdf};
    m->map->getStyle().addImage(std::make_unique<mbgl::style::Image>(
        imageId, holder->clone(), pixel_ratio, isSdf));
    m->renderRequested = true;
  });
}

void mbl_map_set_transition_options(MblMap *m, int32_t duration_ms,
                                   int32_t delay_ms,
                                   int placement_transitions) {
  if (m == nullptr) return;
  m->post([m, duration_ms, delay_ms, placement_transitions] {
    m->transitionOptionsSet = true;
    m->transitionDurationMs = duration_ms;
    m->transitionDelayMs = delay_ms;
    m->placementTransitions = placement_transitions != 0;
    applyTransitionOptions(m);
    m->renderRequested = true;
  });
}

void mbl_map_remove_image(MblMap *m, const char *id) {
  if (m == nullptr || id == nullptr) return;
  std::string imageId(id);
  m->post([m, imageId] {
    // Drop the retention FIRST. Without this the next style load replays an
    // image the app explicitly removed — the failure mode of any replay cache
    // that only ever grows.
    m->images.erase(imageId);
    m->map->getStyle().removeImage(imageId);
    m->renderRequested = true;
  });
}

// --- Rendered-feature query --------------------------------------------------

void mbl_string_free(char *s) { std::free(s); }

namespace {

// Splits a comma-separated list into a vector, or nullopt when there is nothing
// to restrict by. Shared by every query entry point.
std::optional<std::vector<std::string>> splitCsv(const char *csv_in) {
  if (csv_in == nullptr || *csv_in == '\0') return std::nullopt;
  std::vector<std::string> ids;
  std::string csv(csv_in);
  size_t start = 0;
  while (start <= csv.size()) {
    const size_t comma = csv.find(',', start);
    const size_t end = comma == std::string::npos ? csv.size() : comma;
    if (end > start) ids.emplace_back(csv.substr(start, end - start));
    if (comma == std::string::npos) break;
    start = comma + 1;
  }
  if (ids.empty()) return std::nullopt;
  return ids;
}

// Parses a style-spec filter expression. Returns nullopt when there is no
// filter; a filter that does not PARSE is reported and then ignored, because
// silently matching everything is the one outcome a caller cannot detect.
std::optional<mbgl::style::Filter> parseFilter(MblMap *m,
                                               const char *filter_json) {
  if (filter_json == nullptr || *filter_json == '\0') return std::nullopt;
  mbgl::style::conversion::Error error;
  auto filter = mbgl::style::conversion::convertJSON<mbgl::style::Filter>(
      std::string(filter_json), error);
  if (!filter) {
    dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
                       "query filter is not a valid style-spec expression: " +
                           error.message);
    return std::nullopt;
  }
  return *filter;
}

// One FeatureCollection string from a feature list. An empty result is still
// valid GeoJSON rather than a null, so the caller parses one shape.
//
// `mbgl::Feature` is a GeoJSONFeature PLUS `source`, `sourceLayer` and `state`,
// and copying into a `feature_collection<double>` slices those three off — so
// the obvious one-liner silently loses exactly what gl-js's MapGeoJSONFeature
// promises. They are re-attached here as siblings of `geometry`/`properties`,
// which is where gl-js puts them.
//
// Serialise-then-augment, rather than writing the geometry by hand: geometry
// serialisation is the part worth not reimplementing.
std::string featuresToJson(const std::vector<mbgl::Feature> &features) {
  const mapbox::feature::feature_collection<double> collection(features.begin(),
                                                               features.end());
  const auto json = mapbox::geojson::stringify(mbgl::GeoJSON{collection});

  rapidjson::Document doc;
  doc.Parse(json.c_str());
  if (doc.HasParseError() || !doc.IsObject()) return json;
  auto members = doc.FindMember("features");
  if (members == doc.MemberEnd() || !members->value.IsArray()) return json;
  auto array = members->value.GetArray();
  // Same order, same count — the collection was built from `features` in order.
  if (array.Size() != features.size()) return json;

  auto &allocator = doc.GetAllocator();
  for (rapidjson::SizeType i = 0; i < array.Size(); ++i) {
    if (!array[i].IsObject()) continue;
    const auto &feature = features[i];
    if (!feature.source.empty()) {
      array[i].AddMember(
          "source",
          rapidjson::Value(feature.source.c_str(), allocator).Move(), allocator);
    }
    if (!feature.sourceLayer.empty()) {
      array[i].AddMember(
          "sourceLayer",
          rapidjson::Value(feature.sourceLayer.c_str(), allocator).Move(),
          allocator);
    }
    if (!feature.state.empty()) {
      std::unordered_map<std::string, mbgl::Value> asMap(feature.state.begin(),
                                                         feature.state.end());
      rapidjson::Document state(&allocator);
      state.Parse(styleValueToJson(mbgl::Value{std::move(asMap)}).c_str());
      if (!state.HasParseError()) {
        array[i].AddMember("state", state.Move(), allocator);
      }
    }
  }

  rapidjson::StringBuffer buffer;
  rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
  doc.Accept(writer);
  return std::string(buffer.GetString(), buffer.GetSize());
}

char *dupJson(const std::string &json) {
  if (json.empty()) return nullptr;
  char *out = static_cast<char *>(std::malloc(json.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, json.data(), json.size());
  out[json.size()] = '\0';
  return out;
}

} // namespace

namespace {

// rapidjson -> mbgl::Value. mbgl has converters INTO its typed style classes
// but none into a bare Value, and feature state is untyped by design, so this
// is the one place that mapping has to exist.
mbgl::Value jsonToValue(const rapidjson::Value &v) {
  if (v.IsBool()) return mbgl::Value{v.GetBool()};
  if (v.IsString()) return mbgl::Value{std::string(v.GetString(),
                                                   v.GetStringLength())};
  if (v.IsUint64()) return mbgl::Value{v.GetUint64()};
  if (v.IsInt64()) return mbgl::Value{v.GetInt64()};
  if (v.IsNumber()) return mbgl::Value{v.GetDouble()};
  if (v.IsArray()) {
    std::vector<mbgl::Value> out;
    out.reserve(v.Size());
    for (const auto &e : v.GetArray()) out.emplace_back(jsonToValue(e));
    return mbgl::Value{std::move(out)};
  }
  if (v.IsObject()) {
    std::unordered_map<std::string, mbgl::Value> out;
    for (const auto &e : v.GetObject()) {
      out.emplace(std::string(e.name.GetString(), e.name.GetStringLength()),
                  jsonToValue(e.value));
    }
    return mbgl::Value{std::move(out)};
  }
  return mbgl::Value{mbgl::NullValue{}};
}

std::optional<std::string> optionalString(const char *s) {
  if (s == nullptr) return std::nullopt;
  return std::string(s);
}

} // namespace

namespace {

// The synthetic cluster feature the supercluster extension wants.
//
// It reads exactly one thing off the feature — the `cluster_id` property
// (render_geojson_source.cpp:133) — so building one here is equivalent to
// Apple's "hand it the cluster shape you got from a query", and spares the
// caller keeping that shape alive between the query and the question.
mbgl::Feature clusterFeature(uint32_t clusterId) {
  mbgl::Feature feature{mbgl::Point<double>{0, 0}};
  feature.properties["cluster"] = true;
  feature.properties["cluster_id"] = static_cast<uint64_t>(clusterId);
  return feature;
}

// Runs one supercluster extension and returns its value, or nullopt.
std::optional<mbgl::FeatureExtensionValue> clusterExtension(
    MblMap *m, const std::string &sourceId, uint32_t clusterId,
    const std::string &field,
    std::optional<std::map<std::string, mbgl::Value>> args,
    uint32_t timeout_ms) {
  auto result = std::make_shared<std::optional<mbgl::FeatureExtensionValue>>();
  const bool ok = runOnRenderThread(
      m, timeout_ms, [m, sourceId, clusterId, field, args, result] {
        auto *renderer =
            m->frontend != nullptr ? m->frontend->getRenderer() : nullptr;
        if (renderer == nullptr) return;
        // MUST catch. mbgl THROWS for a source that does not exist, and a throw
        // crossing `extern "C"` is undefined behaviour — in practice
        // std::terminate, which took the whole test process down with
        // "Abort trap: 6" the first time this was called with a bad source id.
        try {
          *result = renderer->queryFeatureExtensions(
              sourceId, clusterFeature(clusterId), "supercluster", field, args);
        } catch (const std::exception &e) {
          dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
                             "cluster query on source '" + sourceId +
                                 "' failed: " + e.what());
        } catch (...) {
          dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
                             "cluster query on source '" + sourceId +
                                 "' failed");
        }
      });
  if (!ok) return std::nullopt;
  return *result;
}

} // namespace

int32_t mbl_map_get_cluster_expansion_zoom(MblMap *m, const char *source_id,
                                           uint32_t cluster_id,
                                           uint32_t timeout_ms) {
  if (m == nullptr || source_id == nullptr) return -1;
  const auto value = clusterExtension(m, std::string(source_id), cluster_id,
                                      "expansion-zoom", std::nullopt,
                                      timeout_ms);
  if (!value || !value->is<mbgl::Value>()) return -1;
  const auto &raw = value->get<mbgl::Value>();
  if (raw.is<uint64_t>()) return static_cast<int32_t>(raw.get<uint64_t>());
  if (raw.is<int64_t>()) return static_cast<int32_t>(raw.get<int64_t>());
  if (raw.is<double>()) return static_cast<int32_t>(raw.get<double>());
  return -1;
}

// Shared tail for the two extensions that answer with features.
static char *clusterFeatures(
    MblMap *m, const char *source_id, uint32_t cluster_id,
    const char *field, std::optional<std::map<std::string, mbgl::Value>> args,
    uint32_t timeout_ms) {
  if (m == nullptr || source_id == nullptr) return nullptr;
  const auto value = clusterExtension(m, std::string(source_id), cluster_id,
                                      field, std::move(args), timeout_ms);
  if (!value || !value->is<mbgl::FeatureCollection>()) return nullptr;
  const auto &features = value->get<mbgl::FeatureCollection>();
  const mapbox::feature::feature_collection<double> collection(features.begin(),
                                                               features.end());
  return dupToHeap(mapbox::geojson::stringify(mbgl::GeoJSON{collection}));
}

char *mbl_map_get_cluster_children(MblMap *m, const char *source_id,
                                   uint32_t cluster_id, uint32_t timeout_ms) {
  return clusterFeatures(m, source_id, cluster_id, "children", std::nullopt,
                         timeout_ms);
}

char *mbl_map_get_cluster_leaves(MblMap *m, const char *source_id,
                                 uint32_t cluster_id, uint32_t limit,
                                 uint32_t offset, uint32_t timeout_ms) {
  std::map<std::string, mbgl::Value> args{
      {"limit", static_cast<uint64_t>(limit)},
      {"offset", static_cast<uint64_t>(offset)}};
  return clusterFeatures(m, source_id, cluster_id, "leaves", std::move(args),
                         timeout_ms);
}

void mbl_map_set_feature_state(MblMap *m, const char *source_id,
                               const char *source_layer, const char *feature_id,
                               const char *state_json) {
  if (m == nullptr || source_id == nullptr || feature_id == nullptr ||
      state_json == nullptr) {
    return;
  }
  // Parse on the CALLING thread: it needs no map, so bad JSON is reported
  // before anything is posted rather than failing invisibly later.
  rapidjson::Document doc;
  doc.Parse(state_json);
  if (doc.HasParseError() || !doc.IsObject()) {
    dispatchDiagnostic(m, MBL_DIAG_COMMAND_FAILED, MBL_SEVERITY_WARNING,
                       "setFeatureState: state must be a JSON object");
    return;
  }
  mbgl::FeatureState state;
  for (const auto &entry : doc.GetObject()) {
    state.emplace(
        std::string(entry.name.GetString(), entry.name.GetStringLength()),
        jsonToValue(entry.value));
  }

  m->post([m, sourceId = std::string(source_id),
           sourceLayer = optionalString(source_layer),
           featureId = std::string(feature_id), state] {
    auto *renderer = m->frontend != nullptr ? m->frontend->getRenderer()
                                            : nullptr;
    if (renderer == nullptr) return;
    renderer->setFeatureState(sourceId, sourceLayer, featureId, state);
    m->renderRequested = true;
    // Feature state changes nothing mbgl invalidates on its own — the tiles are
    // unchanged — so without this the repaint never happens in Continuous mode.
    if (m->map != nullptr) m->map->triggerRepaint();
  });
}

char *mbl_map_get_feature_state(MblMap *m, const char *source_id,
                                const char *source_layer,
                                const char *feature_id, uint32_t timeout_ms) {
  if (m == nullptr || source_id == nullptr || feature_id == nullptr) {
    return nullptr;
  }
  auto result = std::make_shared<std::string>();
  const bool ok = runOnRenderThread(
      m, timeout_ms,
      [m, sourceId = std::string(source_id),
       sourceLayer = optionalString(source_layer),
       featureId = std::string(feature_id), result] {
        auto *renderer = m->frontend != nullptr ? m->frontend->getRenderer()
                                                : nullptr;
        if (renderer == nullptr) return;
        mbgl::FeatureState state;
        renderer->getFeatureState(state, sourceId, sourceLayer, featureId);
        // An empty state is `{}`, not NULL: "this feature has no state" is a
        // real answer and must not read as "could not ask".
        std::unordered_map<std::string, mbgl::Value> asMap(state.begin(),
                                                           state.end());
        *result = styleValueToJson(mbgl::Value{std::move(asMap)});
      });
  if (!ok) return nullptr;
  return dupToHeap(*result);
}

void mbl_map_remove_feature_state(MblMap *m, const char *source_id,
                                  const char *source_layer,
                                  const char *feature_id,
                                  const char *state_key) {
  if (m == nullptr || source_id == nullptr) return;
  m->post([m, sourceId = std::string(source_id),
           sourceLayer = optionalString(source_layer),
           featureId = optionalString(feature_id),
           stateKey = optionalString(state_key)] {
    auto *renderer = m->frontend != nullptr ? m->frontend->getRenderer()
                                            : nullptr;
    if (renderer == nullptr) return;
    renderer->removeFeatureState(sourceId, sourceLayer, featureId, stateKey);
    m->renderRequested = true;
    if (m->map != nullptr) m->map->triggerRepaint();
  });
}

char *mbl_map_query_rendered_features(MblMap *m, double min_x, double min_y,
                                      double max_x, double max_y,
                                      const char *layer_ids,
                                      const char *filter_json,
                                      uint32_t timeout_ms) {
  if (m == nullptr) return nullptr;

  auto layers = splitCsv(layer_ids);
  auto filter = parseFilter(m, filter_json);

  // The renderer is owned by the render thread, so the query has to run there.
  // Hand the result back through a shared promise and wait with a deadline: a
  // busy render thread then costs a dropped query rather than a hung UI.
  struct QueryResult {
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    std::string json;
  };
  auto result = std::make_shared<QueryResult>();

  const double height = static_cast<double>(m->renderHeight);
  m->post([m, result, min_x, min_y, max_x, max_y, layers, filter, height] {
    std::string json;
    try {
      auto *renderer = m->frontend != nullptr ? m->frontend->getRenderer()
                                              : nullptr;
      if (renderer != nullptr) {
        // NOTE the query is TOP-LEFT origin, unlike TransformState's projection
        // (which is bottom-up and therefore flipped in mbl_map_pixel*). The two
        // mbgl entry points genuinely disagree, so this passes the caller's box
        // through unchanged. Established by test, not by reading: flipping here
        // made every query miss.
        (void)height;
        mbgl::ScreenBox box{{min_x, min_y}, {max_x, max_y}};
        json = featuresToJson(renderer->queryRenderedFeatures(
            box, mbgl::RenderedQueryOptions(layers, filter)));
      }
    } catch (const std::exception &e) {
      fprintf(stderr, "maplibre_flutter_core: query failed: %s\n", e.what());
    } catch (...) {
      fprintf(stderr, "maplibre_flutter_core: query failed (unknown)\n");
    }
    {
      std::lock_guard<std::mutex> lk(result->mutex);
      result->json = std::move(json);
      result->done = true;
    }
    result->cv.notify_all();
  });

  std::unique_lock<std::mutex> lk(result->mutex);
  if (!result->cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                           [&] { return result->done; })) {
    return nullptr; // timed out; the lambda still owns `result` safely
  }
  return dupJson(result->json);
}

void mbl_map_query_rendered_features_async(MblMap *m, double min_x,
                                           double min_y, double max_x,
                                           double max_y, const char *layer_ids,
                                           const char *filter_json,
                                           MblQueryCallback callback,
                                           void *user) {
  if (callback == nullptr) return;
  if (m == nullptr) {
    // Still call back: a caller awaiting a Future must not wait forever on a
    // handle that was already dead.
    callback(user, nullptr);
    return;
  }
  auto layers = splitCsv(layer_ids);
  auto filter = parseFilter(m, filter_json);
  m->post([m, min_x, min_y, max_x, max_y, layers, filter, callback, user] {
    std::string json;
    try {
      auto *renderer =
          m->frontend != nullptr ? m->frontend->getRenderer() : nullptr;
      if (renderer != nullptr) {
        mbgl::ScreenBox box{{min_x, min_y}, {max_x, max_y}};
        json = featuresToJson(renderer->queryRenderedFeatures(
            box, mbgl::RenderedQueryOptions(layers, filter)));
      }
    } catch (const std::exception &e) {
      fprintf(stderr, "maplibre_flutter_core: query failed: %s\n", e.what());
    } catch (...) {
      fprintf(stderr, "maplibre_flutter_core: query failed (unknown)\n");
    }
    callback(user, dupJson(json));
  });
}

char *mbl_map_query_source_features(MblMap *m, const char *source_id,
                                    const char *source_layers,
                                    const char *filter_json,
                                    uint32_t timeout_ms) {
  if (m == nullptr || source_id == nullptr) return nullptr;
  const std::string sourceId(source_id);
  auto sourceLayers = splitCsv(source_layers);
  auto filter = parseFilter(m, filter_json);

  auto result = std::make_shared<std::string>();
  const bool ok = runOnRenderThread(
      m, timeout_ms, [m, sourceId, sourceLayers, filter, result] {
        auto *renderer =
            m->frontend != nullptr ? m->frontend->getRenderer() : nullptr;
        if (renderer == nullptr) return;
        *result = featuresToJson(renderer->querySourceFeatures(
            sourceId, mbgl::SourceQueryOptions(sourceLayers, filter)));
      });
  if (!ok) return nullptr;
  return dupJson(*result);
}

uint64_t mbl_map_presented_generation(MblMap *m) {
  if (m == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lk(m->projMutex);
  return m->presentedGeneration;
}

uint64_t mbl_map_proj_generation(MblMap *m) {
  if (m == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lk(m->projMutex);
  return m->projGeneration;
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

void mbl_map_set_diagnostic_callback(MblMap *m, MblDiagnosticCallback callback,
                                     void *user) {
  if (m == nullptr) {
    return;
  }
  {
    std::lock_guard<std::mutex> lk(m->cbMutex);
    m->diagCb = callback;
    m->diagCbUser = user;
  }
  {
    // Keep the log-observer fan-out list in step. Registering twice would
    // deliver every record twice.
    std::lock_guard<std::mutex> lk(gDiagMapsMutex);
    auto it = std::find(gDiagMaps.begin(), gDiagMaps.end(), m);
    if (callback == nullptr) {
      if (it != gDiagMaps.end()) gDiagMaps.erase(it);
    } else if (it == gDiagMaps.end()) {
      gDiagMaps.push_back(m);
    }
  }
  if (callback != nullptr) {
    // Process-wide and irreversible-ish, so install exactly once and only when
    // somebody is actually listening.
    std::call_once(gLogObserverOnce, [] {
      mbgl::Log::setObserver(std::make_unique<DiagnosticLogObserver>());
    });
    // Replay the initial style load if it already happened. Registering cannot
    // precede creation, and a style often loads within ~200 ms of it, so a
    // strictly live stream would drop the load a caller most needs — the one
    // that says "the map is usable". Reported once, at registration, so the
    // repeating semantics of later loads are unaffected.
    if (m->styleLoadCount.load(std::memory_order_relaxed) > 0) {
      dispatchDiagnostic(m, MBL_DIAG_STYLE_LOADED, MBL_SEVERITY_INFO, "");
    }
  }
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
  // Before anything is torn down: stop the log observer's fan-out from reaching
  // this map, and clear the callback so an event already inside the render
  // thread finds nothing to call.
  mbl_map_set_diagnostic_callback(m, nullptr, nullptr);
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
