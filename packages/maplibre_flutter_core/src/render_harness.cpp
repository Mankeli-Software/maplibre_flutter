// Headless render-to-PNG harness for verifying a non-Apple (OpenGL/EGL) build of
// the core, intended to run in a Mesa-software-GL Docker container (no GPU/X11) —
// so the Linux GL render path can be checked from a macOS dev machine. Built only
// when MAPLIBRE_FLUTTER_BUILD_HARNESS=ON (off for the normal plugin build); not
// shipped. Renders a keyless style and writes a PNG via the shim's
// mbl_map_write_png, which a human/agent then eyeballs for correctness
// (non-blank, right-side-up, correct colours).
//
// Also doubles as a network-behaviour probe: in Continuous mode (the GUI app's
// default) it holds the map alive while tiles stream, so stderr surfaces any
// HTTP/2 ENHANCE_YOUR_CALM throttling. With the env knob
// MAPLIBRE_MAX_CONCURRENT_REQUESTS this gives a one-binary A/B for that fix.
//
// Usage: render_harness [styleUri] [outPath] [lat] [lng] [zoom] [continuous] [holdSeconds]
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
  const int continuous = argc > 6 ? std::atoi(argv[6]) : 0;
  // How long to keep the map alive after the first frame. In Continuous mode a
  // longer hold lets the tile-request burst (and any throttling) play out.
  const int holdSeconds = argc > 7 ? std::atoi(argv[7]) : (continuous ? 12 : 3);

  MblMap *map = mbl_map_create(800, 600, 1.0f, style.c_str(), continuous);
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
  // Static renderStill already blocks until tiles load; give the post-camera
  // render a moment to be the latest published frame. In Continuous mode this is
  // the window the tiles stream in over.
  std::this_thread::sleep_for(std::chrono::seconds(holdSeconds));

  const int ok = mbl_map_write_png(map, out.c_str());
  mbl_map_destroy(map);
  if (ok == 0) {
    fprintf(stderr, "render_harness: mbl_map_write_png failed\n");
    return 3;
  }
  fprintf(stderr, "render_harness: wrote %s\n", out.c_str());
  return 0;
}
