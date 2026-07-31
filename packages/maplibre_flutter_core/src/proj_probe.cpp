// Focused probe for mbl_map_pixel_for_lat_lng / mbl_map_lat_lng_for_pixel.
//
// The 3D-model spike found the model rendering 400.9 px BELOW centre while the
// projector reported the same point 400.9 px ABOVE it — equal magnitude, opposite
// sign. Since the projector (added by the glued-widget-markers work) has never
// actually been run on a machine, this checks its signs from first principles
// instead of trusting either side:
//
//   north of the camera must project ABOVE centre (smaller y, top-left origin)
//   south must project BELOW (larger y)
//   east must project RIGHT (larger x), west LEFT
//
// Built only with MAPLIBRE_FLUTTER_BUILD_HARNESS=ON; not shipped.
#include "maplibre_flutter_core.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <thread>

namespace {

constexpr uint32_t kWidth = 800;
constexpr uint32_t kHeight = 600;

// Project against the newest transform. The probe drives the map itself and
// waits for each frame, so there is no presented-vs-newest skew to correct for;
// the app tiers pass mbl_map_presented_generation() instead.
constexpr uint64_t kNewest = 0;

// Block until the render thread has applied a posted command, or give up.
//
// Take `before` from mbl_map_proj_generation() before issuing the command. The
// generation is bumped by updateProjState, which runs inside the posted lambda
// after the transform is mutated, so an advance means a new transform has been
// published.
//
// Neither obvious alternative works. mbl_map_await_frame returns as soon as ANY
// frame exists, including one rendered before the command landed. And polling
// mbl_map_get_camera is worse than useless: mbl_map_set_camera writes the camera
// cache SYNCHRONOUSLY on the calling thread and only then posts the jumpTo, so
// the getter reports the requested camera immediately and a wait on it returns
// at once, having proved nothing. That version failed ~40% of runs.
//
// One bump is not enough either, which is the subtle part: updateProjState is
// also called by the initial style load and by resize, so the first bump after
// `before` is often one of those and the wait returns with the jumpTo still
// queued. That failed about 1 run in 8 — rare enough to read as a real
// intermittent projection bug, in the one tool whose job is to adjudicate
// projection bugs. Hence QUIESCENCE: at least one bump, and then the generation
// must hold still, meaning every posted command has landed.
bool waitForApplied(MblMap *map, uint64_t before) {
  constexpr int kQuietPolls = 10; // 200 ms of no transform updates
  uint64_t last = before;
  int quiet = 0;
  for (int i = 0; i < 500; ++i) {
    const uint64_t now = mbl_map_proj_generation(map);
    if (now == last && now > before) {
      if (++quiet >= kQuietPolls) {
        return true;
      }
    } else {
      quiet = 0;
      last = now;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  return false;
}

int checkSign(const char *label, double got, double centre, bool expectGreater) {
  const bool ok = expectGreater ? (got > centre) : (got < centre);
  printf("  %-22s %8.1f  (expected %s %.0f)  %s\n", label, got,
         expectGreater ? ">" : "<", centre, ok ? "OK" : "*** WRONG SIGN ***");
  return ok ? 0 : 1;
}

} // namespace

int main() {
  const double lat = 37.7749;
  const double lng = -122.4194;
  const double zoom = 15.0;
  const double delta = 0.0068; // ~757 m N/S, ~600 m E/W at this latitude

  MblMap *map = mbl_map_create(kWidth, kHeight, 1.0f,
                               "https://demotiles.maplibre.org/style.json",
                               /*continuous=*/0);
  if (map == nullptr) {
    fprintf(stderr, "proj_probe: mbl_map_create failed\n");
    return 1;
  }
  const uint64_t genBeforeCamera = mbl_map_proj_generation(map);
  mbl_map_set_camera(map, lat, lng, zoom, 0.0, 0.0);
  if (mbl_map_await_frame(map, 30000) == 0) {
    fprintf(stderr, "proj_probe: no frame\n");
    mbl_map_destroy(map);
    return 2;
  }
  if (!waitForApplied(map, genBeforeCamera)) {
    fprintf(stderr, "proj_probe: camera never applied on the render thread\n");
    mbl_map_destroy(map);
    return 2;
  }

  int failures = 0;
  double x = 0, y = 0;
  int visible = 0;

  mbl_map_pixel_for_lat_lng(map, lat, lng, &x, &y, &visible, kNewest);
  printf("centre -> (%.1f, %.1f) [expect (%.1f, %.1f)]\n", x, y, kWidth / 2.0,
         kHeight / 2.0);
  if (std::abs(x - kWidth / 2.0) > 1.0 || std::abs(y - kHeight / 2.0) > 1.0) {
    printf("  *** centre does not project to viewport centre ***\n");
    ++failures;
  }

  printf("directional signs (top-left origin):\n");
  mbl_map_pixel_for_lat_lng(map, lat + delta, lng, &x, &y, &visible, kNewest);
  failures += checkSign("north  -> y", y, kHeight / 2.0, /*expectGreater=*/false);
  mbl_map_pixel_for_lat_lng(map, lat - delta, lng, &x, &y, &visible, kNewest);
  failures += checkSign("south  -> y", y, kHeight / 2.0, /*expectGreater=*/true);
  mbl_map_pixel_for_lat_lng(map, lat, lng + delta, &x, &y, &visible, kNewest);
  failures += checkSign("east   -> x", x, kWidth / 2.0, /*expectGreater=*/true);
  mbl_map_pixel_for_lat_lng(map, lat, lng - delta, &x, &y, &visible, kNewest);
  failures += checkSign("west   -> x", x, kWidth / 2.0, /*expectGreater=*/false);

  // Round-trip: unprojecting a screen point above centre must give a latitude
  // NORTH of the camera.
  double rlat = 0, rlng = 0;
  if (mbl_map_lat_lng_for_pixel(map, kWidth / 2.0, kHeight / 2.0 - 200.0, &rlat,
                                &rlng, kNewest) == 1) {
    printf("unproject 200px above centre -> lat %.5f (camera %.5f) %s\n", rlat,
           lat, rlat > lat ? "OK" : "*** WRONG SIGN ***");
    if (rlat <= lat) {
      ++failures;
    }
  }

  // The other half of the question: which origin does the GESTURE anchor space
  // use? The projector's header claims both are the same space, so pin the anchor
  // convention down independently instead of assuming. Zooming in about the
  // TOP-LEFT of the viewport must pull the camera centre toward the north-west —
  // latitude up, longitude down — if anchors are top-left origin.
  const uint64_t genBeforeReset = mbl_map_proj_generation(map);
  mbl_map_set_camera(map, lat, lng, zoom, 0.0, 0.0);
  waitForApplied(map, genBeforeReset);
  const uint64_t genBeforeScale = mbl_map_proj_generation(map);
  mbl_map_scale_by(map, 2.0, 0.0, 0.0);
  waitForApplied(map, genBeforeScale);

  double alat = 0, alng = 0, azoom = 0, abearing = 0, apitch = 0;
  mbl_map_get_camera(map, &alat, &alng, &azoom, &abearing, &apitch);
  const bool northWest = alat > lat && alng < lng;
  printf("zoom about (0,0): centre %.5f,%.5f -> %.5f,%.5f (%s)\n", lat, lng, alat,
         alng,
         northWest ? "north-west => anchors are TOP-LEFT origin"
                   : "south-west => anchors are BOTTOM-LEFT origin");
  if (!northWest) {
    ++failures;
  }

  mbl_map_destroy(map);
  printf("%s\n", failures == 0 ? "PROJECTOR OK" : "PROJECTOR HAS SIGN ERRORS");
  return failures == 0 ? 0 : 3;
}
