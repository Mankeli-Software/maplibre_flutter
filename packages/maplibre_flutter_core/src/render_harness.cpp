// Headless render-to-PNG harness for verifying a non-Apple (OpenGL/EGL) build of
// the core, intended to run in a Mesa-software-GL Docker container (no GPU/X11) —
// so the Linux GL render path can be checked from a macOS dev machine. Built only
// when MAPLIBRE_FLUTTER_BUILD_HARNESS=ON (off for the normal plugin build); not
// shipped. Renders a keyless style in Static mode and writes a PNG via the shim's
// mbl_map_write_png, which a human/agent then eyeballs for correctness
// (non-blank, right-side-up, correct colours).
//
// Usage: render_harness [styleUri] [outPath] [lat] [lng] [zoom]
#include "maplibre_flutter_core.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

int main(int argc, char **argv) {
  const std::string style =
      argc > 1 ? argv[1] : "https://demotiles.maplibre.org/style.json";
  const std::string out = argc > 2 ? argv[2] : "frame.png";
  const double lat = argc > 3 ? std::atof(argv[3]) : 30.0;
  const double lng = argc > 4 ? std::atof(argv[4]) : 10.0;
  const double zoom = argc > 5 ? std::atof(argv[5]) : 2.0;

  MblMap *map =
      mbl_map_create(800, 600, 1.0f, style.c_str(), /*continuous=*/0);
  if (map == nullptr) {
    fprintf(stderr, "render_harness: mbl_map_create failed\n");
    return 1;
  }
  mbl_map_set_camera(map, lat, lng, zoom, 0.0, 0.0);

  if (mbl_map_await_frame(map, 30000) == 0) {
    fprintf(stderr, "render_harness: no frame within 30s\n");
    mbl_map_destroy(map);
    return 2;
  }
  // Static renderStill already blocks until tiles load, but give the post-camera
  // render a moment to be the latest published frame before we snapshot it.
  std::this_thread::sleep_for(std::chrono::seconds(3));

  const int ok = mbl_map_write_png(map, out.c_str());
  mbl_map_destroy(map);
  if (ok == 0) {
    fprintf(stderr, "render_harness: mbl_map_write_png failed\n");
    return 3;
  }
  fprintf(stderr, "render_harness: wrote %s\n", out.c_str());
  return 0;
}
