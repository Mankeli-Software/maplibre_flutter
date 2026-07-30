// Reproduces the example's "drive around a point" math natively and renders the
// model at four points around the loop, so its facing can be checked against its
// direction of travel.
//
// Built only with MAPLIBRE_FLUTTER_BUILD_HARNESS=ON; not shipped.
//
// At each quarter the model should point along the TANGENT: travelling east at
// the north of the loop, south at the east of it, and so on. A model that instead
// keeps a fixed facing, or rotates the wrong way, is obvious across the four
// frames.
//
// Usage: drive_probe <out_dir> <model.glb> [lat] [lng] [zoom] [scale]
//                    [modelHeading] [radiusM] [elevationM]
#include "maplibre_flutter_core.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: drive_probe <out_dir> <model.glb> ...\n");
    return 2;
  }
  const std::string out = argv[1];
  const std::string glb = argv[2];
  const double lat = argc > 3 ? std::atof(argv[3]) : 51.50735;
  const double lng = argc > 4 ? std::atof(argv[4]) : -0.12776;
  const double zoom = argc > 5 ? std::atof(argv[5]) : 19.0;
  const double scale = argc > 6 ? std::atof(argv[6]) : 0.394;
  const double modelHeading = argc > 7 ? std::atof(argv[7]) : 180.0;
  const double radiusM = argc > 8 ? std::atof(argv[8]) : 10.0;
  const double elevationM = argc > 9 ? std::atof(argv[9]) : 0.15;

  constexpr double kPi = 3.14159265358979323846;

  MblMap *map = mbl_map_create(800, 600, 1.0f,
                               "https://demotiles.maplibre.org/style.json",
                               /*continuous=*/1);
  if (map == nullptr) {
    fprintf(stderr, "drive_probe: create failed\n");
    return 1;
  }
  // Look straight down so facing is unambiguous.
  mbl_map_set_camera(map, lat, lng, zoom, 0.0, 0.0);
  if (mbl_map_await_frame(map, 30000) == 0) {
    fprintf(stderr, "drive_probe: no frame\n");
    mbl_map_destroy(map);
    return 2;
  }
  std::this_thread::sleep_for(std::chrono::seconds(6));

  char err[512] = {0};
  if (mbl_map_add_model(map, "drive", glb.c_str(), lat, lng, scale,
                        modelHeading, 0.0, elevationM, err, sizeof(err)) == 0) {
    fprintf(stderr, "drive_probe: add failed: %s\n", err);
    mbl_map_destroy(map);
    return 3;
  }

  // Same parameterisation as the example: north offset = R cos(theta),
  // east offset = R sin(theta), so the model runs clockwise and the travel
  // bearing is theta + 90.
  const double latPerMetre = 1.0 / 111320.0;
  const double lngPerMetre = 1.0 / (111320.0 * std::cos(lat * kPi / 180.0));

  const int quarters[4] = {0, 90, 180, 270};
  for (int q = 0; q < 4; ++q) {
    const double thetaDeg = quarters[q];
    const double theta = thetaDeg * kPi / 180.0;
    const double pLat = lat + radiusM * latPerMetre * std::cos(theta);
    const double pLng = lng + radiusM * lngPerMetre * std::sin(theta);
    const double tangent = std::fmod(thetaDeg + 90.0, 360.0);
    const double heading = modelHeading + tangent;

    mbl_map_set_model_transform(map, "drive", pLat, pLng, scale, heading,
                                elevationM);
    std::this_thread::sleep_for(std::chrono::milliseconds(900));

    char path[512];
    snprintf(path, sizeof(path), "%s/drive_%03d.png", out.c_str(),
             static_cast<int>(thetaDeg));
    mbl_map_write_png(map, path);
    printf("theta=%3.0f  at(%.6f, %.6f)  travel bearing=%3.0f  heading=%3.0f  "
           "-> %s\n",
           thetaDeg, pLat, pLng, tangent, heading, path);
  }

  mbl_map_destroy(map);
  printf("check: at theta=0 the model sits NORTH of centre and must point EAST; "
         "at 90 it sits EAST and must point SOUTH.\n");
  return 0;
}
