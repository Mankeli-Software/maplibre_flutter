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
//                      [glbPath] [headingDeg] [elevationM]
//
// With a glbPath, mbl_map_add_model loads that .glb instead of the built-in test
// pyramid, and metresPerUnit becomes the model's scale multiplier (1.0 = a glTF
// authored in metres at life size).
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
  const std::string glb = argc > 11 ? argv[11] : "";
  const double headingDeg = argc > 12 ? std::atof(argv[12]) : 0.0;
  const double elevationM = argc > 13 ? std::atof(argv[13]) : 0.0;

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
  if (glb.empty()) {
    mbl_map_add_test_model(map, lat, lng, metresPerUnit, spinDps, elevationM);
  } else {
    char err[512] = {0};
    if (mbl_map_add_model(map, "mbl-model", glb.c_str(), lat, lng, metresPerUnit,
                          headingDeg, spinDps, elevationM, err,
                          sizeof(err)) == 0) {
      fprintf(stderr, "model_harness: mbl_map_add_model failed: %s\n", err);
      mbl_map_destroy(map);
      return 5;
    }
    printf("loaded %s\n", glb.c_str());
  }
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

  // --- 4. does set_model_transform MOVE the model without re-uploading it? ---
  //
  // This is the path an app uses to drive a model along a route; re-adding it
  // each frame would re-parse the whole .glb, so moving must work through the
  // shared placement alone.
  Diff moved;
  bool testedMove = false;
  if (!glb.empty()) {
    // Shift east by ~100 SCREEN pixels, not a fixed distance: a fixed metre
    // offset is invisible when zoomed out and lands off-screen when zoomed in.
    constexpr double kPi = 3.14159265358979323846;
    const double metresPerPixel = 40075017.0 * std::cos(lat * kPi / 180.0) /
                                  (512.0 * std::pow(2.0, zoom));
    const double shiftMetres = 100.0 * metresPerPixel;
    const double eastDeg =
        shiftMetres / (111320.0 * std::cos(lat * kPi / 180.0));
    mbl_map_set_model_transform(map, "mbl-model", lat, lng + eastDeg,
                                metresPerUnit, headingDeg, elevationM);
    pump(map, 800);
    Frame movedFrame;
    if (capture(map, movedFrame)) {
      mbl_map_write_png(map, (outDir + "/model_3_moved.png").c_str());
      moved = diffFrames(later, movedFrame);
      testedMove = true;
      printf("after move:     %zu px changed, centroid=(%.1f, %.1f)\n",
             moved.changed, moved.centroidX, moved.centroidY);
    }
  }

  // --- 5. does the model SURVIVE a style change? ---
  //
  // Loading a style replaces the layer list, dropping every custom layer. The
  // core re-adds retained models from onDidFinishLoadingStyle; without that a
  // user switching basemaps silently loses their models.
  Diff afterStyle;
  bool testedStyle = false;
  if (!glb.empty()) {
    const std::string otherStyle =
        style.find("demotiles") != std::string::npos
            ? "https://tiles.openfreemap.org/styles/liberty"
            : "https://demotiles.maplibre.org/style.json";
    mbl_map_set_style(map, otherStyle.c_str());
    std::this_thread::sleep_for(std::chrono::seconds(12));
    pump(map, 800);
    Frame styled;
    Frame styledNoModel;
    if (capture(map, styled)) {
      mbl_map_write_png(map, (outDir + "/model_4_after_style.png").c_str());
      // Remove the model and re-capture: whatever changes is the model, which
      // isolates it from the completely different basemap underneath.
      mbl_map_remove_model(map, "mbl-model");
      pump(map, 800);
      if (capture(map, styledNoModel)) {
        afterStyle = diffFrames(styled, styledNoModel);
        testedStyle = true;
        printf("after style:    %zu px changed by removing the model\n",
               afterStyle.changed);
      }
    }
  }

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

  if (testedMove) {
    if (moved.changed < kMinModelPixels) {
      printf("FAIL: set_model_transform did not move the model (%zu px)\n",
             moved.changed);
      ++failures;
    } else if (moved.centroidX <= added.centroidX) {
      printf("FAIL: model moved to centroid x=%.1f, expected east of %.1f\n",
             moved.centroidX, added.centroidX);
      ++failures;
    } else {
      printf("PASS: set_model_transform moves the model east (%.1f -> %.1f)\n",
             added.centroidX, moved.centroidX);
    }
  }

  if (testedStyle) {
    if (afterStyle.changed < kMinModelPixels) {
      printf("FAIL: model did not survive a style change (%zu px)\n",
             afterStyle.changed);
      ++failures;
    } else {
      printf("PASS: model survives a style change (%zu px)\n",
             afterStyle.changed);
    }
  }

  printf("%s\n", failures == 0 ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED");
  return failures == 0 ? 0 : 4;
}
