// Headless assertion loop for the 3D-model spike. Built only when
// MAPLIBRE_FLUTTER_BUILD_HARNESS=ON; not shipped.
//
// This exists because of the §7 lesson the Windows blank-map bug produced: an
// integration test that only checks "a frame came back" does NOT prove anything
// is visible. So this harness asserts on actual pixels, and specifically that:
//
//   1. Adding the custom-drawable model layer CHANGES the frame (it renders at
//      all under this backend + CORE_ONLY + our headless frontend).
//   2. The changed pixels land where mbl_map_pixel_for_lat_lng says the model's
//      LatLng projects (it is anchored, not just painted somewhere).
//   3. Successive frames keep changing while only the animation clock advances
//      (mbl_map_trigger_repaint actually drives an animation through Continuous
//      mode — the single biggest unknown going in).
//
// It also writes PNGs for eyeballing, since "the pixels changed" still cannot
// tell you the model looks right.
//
// The camera is deliberately OFFSET from the model, so "the changed pixels are
// where the LatLng projects" is a real assertion. With the model at screen centre
// a full-viewport bug would satisfy that check trivially — which is exactly what
// happened on the first run, before the size was corrected to real-world metres.
//
// Usage: model_harness [outDir] [lat] [lng] [zoom] [pitch] [bearing]
//                      [metresPerUnit] [styleUri] [spinDps] [camOffsetDeg]
#include "maplibre_flutter_core.h"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr uint32_t kWidth = 800;
constexpr uint32_t kHeight = 600;
// Per-channel difference that counts as "this pixel changed". Above encoder/
// dither noise, well below a real colour change.
constexpr int kChannelTolerance = 8;

struct Frame {
  std::vector<uint8_t> pixels;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t stride = 0;
};

bool capture(MblMap *map, Frame &out) {
  uint32_t w = 0, h = 0, stride = 0;
  if (mbl_map_copy_frame(map, nullptr, 0, &w, &h, &stride) == 0) {
    return false;
  }
  out.pixels.assign(static_cast<size_t>(stride) * h, 0);
  if (mbl_map_copy_frame(map, out.pixels.data(), out.pixels.size(), &w, &h,
                         &stride) == 0) {
    return false;
  }
  out.width = w;
  out.height = h;
  out.stride = stride;
  return true;
}

struct Diff {
  size_t changed = 0;
  double centroidX = 0;
  double centroidY = 0;
  uint32_t minX = 0, minY = 0, maxX = 0, maxY = 0;
};

Diff diffFrames(const Frame &a, const Frame &b) {
  Diff d;
  if (a.width != b.width || a.height != b.height || a.pixels.empty() ||
      b.pixels.empty()) {
    return d;
  }
  double sumX = 0, sumY = 0;
  uint32_t minX = a.width, minY = a.height, maxX = 0, maxY = 0;
  for (uint32_t y = 0; y < a.height; ++y) {
    const uint8_t *ra = a.pixels.data() + static_cast<size_t>(y) * a.stride;
    const uint8_t *rb = b.pixels.data() + static_cast<size_t>(y) * b.stride;
    for (uint32_t x = 0; x < a.width; ++x) {
      const uint8_t *pa = ra + static_cast<size_t>(x) * 4;
      const uint8_t *pb = rb + static_cast<size_t>(x) * 4;
      bool changed = false;
      for (int c = 0; c < 3; ++c) {
        if (std::abs(static_cast<int>(pa[c]) - static_cast<int>(pb[c])) >
            kChannelTolerance) {
          changed = true;
          break;
        }
      }
      if (changed) {
        ++d.changed;
        sumX += x;
        sumY += y;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (d.changed > 0) {
    d.centroidX = sumX / static_cast<double>(d.changed);
    d.centroidY = sumY / static_cast<double>(d.changed);
    d.minX = minX;
    d.minY = minY;
    d.maxX = maxX;
    d.maxY = maxY;
  }
  return d;
}

// Pump repaints for `ms`, so an animation driven off the render clock advances
// and the frontend actually publishes frames.
void pump(MblMap *map, int ms) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
  while (std::chrono::steady_clock::now() < deadline) {
    mbl_map_trigger_repaint(map);
    std::this_thread::sleep_for(std::chrono::milliseconds(16));
  }
}

} // namespace

int main(int argc, char **argv) {
  const std::string outDir = argc > 1 ? argv[1] : ".";
  const double lat = argc > 2 ? std::atof(argv[2]) : 37.7749;
  const double lng = argc > 3 ? std::atof(argv[3]) : -122.4194;
  const double zoom = argc > 4 ? std::atof(argv[4]) : 15.0;
  const double pitch = argc > 5 ? std::atof(argv[5]) : 0.0;
  const double bearing = argc > 6 ? std::atof(argv[6]) : 0.0;
  const double metresPerUnit = argc > 7 ? std::atof(argv[7]) : 200.0;
  const std::string style =
      argc > 8 ? argv[8] : "https://demotiles.maplibre.org/style.json";
  const double spinDps = argc > 9 ? std::atof(argv[9]) : 90.0;
  const double camOffset = argc > 10 ? std::atof(argv[10]) : 0.00255;

  // Offset the camera from the model so the model projects well away from screen
  // centre (a centred model would satisfy the anchor check trivially) while still
  // sitting fully inside the viewport — clipped geometry makes the pixel
  // measurements meaningless. ~150 px at this zoom.
  const double camLat = lat + camOffset;
  const double camLng = lng + camOffset;

  MblMap *map = mbl_map_create(kWidth, kHeight, 1.0f, style.c_str(),
                               /*continuous=*/1);
  if (map == nullptr) {
    fprintf(stderr, "model_harness: mbl_map_create failed\n");
    return 1;
  }
  mbl_map_set_camera(map, camLat, camLng, zoom, bearing, pitch);

  if (mbl_map_await_frame(map, 30000) == 0) {
    fprintf(stderr, "model_harness: no frame within 30s\n");
    mbl_map_destroy(map);
    return 2;
  }
  // Let tiles finish streaming, so later diffs are the model and not the basemap
  // still resolving.
  std::this_thread::sleep_for(std::chrono::seconds(20));

  Frame before;
  if (!capture(map, before)) {
    fprintf(stderr, "model_harness: capture(before) failed\n");
    mbl_map_destroy(map);
    return 3;
  }
  mbl_map_write_png(map, (outDir + "/model_0_before.png").c_str());

  // Baseline noise: with no model and a settled basemap, two captures a beat
  // apart should be near-identical. Anything large here means the map is still
  // churning and the later assertions would be measuring the wrong thing.
  pump(map, 500);
  Frame settle;
  if (!capture(map, settle)) {
    fprintf(stderr, "model_harness: capture(settle) failed\n");
    mbl_map_destroy(map);
    return 3;
  }
  const Diff noise = diffFrames(before, settle);
  printf("baseline noise: %zu px changed\n", noise.changed);

  // --- 1. does the model render at all? ---
  mbl_map_add_test_model(map, lat, lng, metresPerUnit, spinDps);
  pump(map, 1200);

  Frame withModel;
  if (!capture(map, withModel)) {
    fprintf(stderr, "model_harness: capture(withModel) failed\n");
    mbl_map_destroy(map);
    return 3;
  }
  mbl_map_write_png(map, (outDir + "/model_1_added.png").c_str());

  const Diff added = diffFrames(settle, withModel);
  printf("model added:    %zu px changed, centroid=(%.1f, %.1f), bbox=(%u,%u)-(%u,%u)\n",
         added.changed, added.centroidX, added.centroidY, added.minX, added.minY,
         added.maxX, added.maxY);

  // --- 2. is it anchored where the LatLng projects? ---
  double px = 0, py = 0;
  int visible = 0;
  const int projected = mbl_map_pixel_for_lat_lng(map, lat, lng, &px, &py, &visible);
  printf("projected anchor: ok=%d visible=%d at (%.1f, %.1f)\n", projected,
         visible, px, py);

  // --- 3. does the animation advance across repaints? ---
  pump(map, 1200);
  Frame later;
  if (!capture(map, later)) {
    fprintf(stderr, "model_harness: capture(later) failed\n");
    mbl_map_destroy(map);
    return 3;
  }
  mbl_map_write_png(map, (outDir + "/model_2_spun.png").c_str());

  const Diff spun = diffFrames(withModel, later);
  printf("after spin:     %zu px changed, centroid=(%.1f, %.1f)\n", spun.changed,
         spun.centroidX, spun.centroidY);

  mbl_map_destroy(map);

  // --- verdict ---
  int failures = 0;
  const size_t kMinModelPixels = 200;

  if (added.changed < kMinModelPixels) {
    printf("FAIL: model layer produced no visible pixels (%zu < %zu) — the "
           "custom drawable did not render\n",
           added.changed, kMinModelPixels);
    ++failures;
  } else {
    printf("PASS: model renders (%zu px)\n", added.changed);
  }

  if (projected == 1 && added.changed >= kMinModelPixels) {
    // The mesh's BASE sits on the anchor and it extrudes upward, so comparing
    // painted centroids is the wrong test — the centroid legitimately sits above
    // the anchor. Assert instead that the anchor falls inside the drawn bounding
    // box (slightly inflated). That catches a Y-flip or transposed anchor, which
    // put the anchor hundreds of pixels outside the box, without being fooled by
    // the model's vertical extent.
    const double pad = 24.0;
    const bool inX = px >= added.minX - pad && px <= added.maxX + pad;
    const bool inY = py >= added.minY - pad && py <= added.maxY + pad;
    const bool clipped = added.minX == 0 || added.minY == 0 ||
                         added.maxX >= kWidth - 1 || added.maxY >= kHeight - 1;
    if (clipped) {
      printf("FAIL: model touches a viewport edge — it is clipped, so the pixel "
             "measurements are not trustworthy\n");
      ++failures;
    } else if (!inX || !inY) {
      printf("FAIL: projected anchor (%.1f, %.1f) is outside the drawn bbox "
             "(%u,%u)-(%u,%u) — anchor/flip bug\n",
             px, py, added.minX, added.minY, added.maxX, added.maxY);
      ++failures;
    } else {
      printf("PASS: model is anchored (anchor inside drawn bbox)\n");
    }
  }

  if (spun.changed < kMinModelPixels) {
    printf("FAIL: frame did not change while spinning (%zu px) — repaint does "
           "not drive the animation\n",
           spun.changed);
    ++failures;
  } else {
    printf("PASS: animation advances across repaints (%zu px)\n", spun.changed);
  }

  printf("%s\n", failures == 0 ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED");
  return failures == 0 ? 0 : 4;
}
