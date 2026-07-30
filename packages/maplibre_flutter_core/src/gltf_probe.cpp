// Parse-level checks for the .glb reader, independent of any rendering.
//
// Built only with MAPLIBRE_FLUTTER_BUILD_HARNESS=ON; not shipped.
//
// Usage: gltf_probe <file.glb> [more.glb ...]
//        gltf_probe --expect-fail <file>   (negative case; must NOT load)
#include "maplibre_flutter_core_gltf.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>

namespace {

// mbgl's IndexVector is uint16-based; a part that exceeds this cannot be drawn.
constexpr size_t kMaxVerticesPerPart = 65536;

int describe(const std::string &path) {
  MblMeshData mesh;
  std::string error;
  if (!mblLoadGlb(path, mesh, error)) {
    printf("FAIL %s: %s\n", path.c_str(), error.c_str());
    return 1;
  }

  printf("OK   %s\n", path.c_str());
  printf("       parts=%zu vertices=%zu triangles=%zu images=%zu\n",
         mesh.parts.size(), mesh.totalVertices(), mesh.totalTriangles(),
         mesh.images.size());
  printf("       bbox min=(%.3f %.3f %.3f) max=(%.3f %.3f %.3f)  [X east, Y "
         "south, Z up, metres]\n",
         mesh.minPosition[0], mesh.minPosition[1], mesh.minPosition[2],
         mesh.maxPosition[0], mesh.maxPosition[1], mesh.maxPosition[2]);
  printf("       extent=(%.3f %.3f %.3f)\n",
         mesh.maxPosition[0] - mesh.minPosition[0],
         mesh.maxPosition[1] - mesh.minPosition[1],
         mesh.maxPosition[2] - mesh.minPosition[2]);

  int failures = 0;
  size_t largestPart = 0;
  size_t untextured = 0;
  std::set<int> usedImages;
  float uMin = 1e9f, uMax = -1e9f, vMin = 1e9f, vMax = -1e9f;

  for (size_t pi = 0; pi < mesh.parts.size(); ++pi) {
    const auto &part = mesh.parts[pi];
    largestPart = std::max(largestPart, part.vertices.size());

    // Every part must fit the uint16 ceiling on its own, or it cannot be drawn.
    if (part.vertices.size() > kMaxVerticesPerPart) {
      printf("       *** part %zu has %zu vertices, over the uint16 ceiling "
             "***\n",
             pi, part.vertices.size());
      ++failures;
    }
    // Every index must address a real vertex IN ITS OWN PART — chunking
    // re-indexes per part, so a bug here would draw garbage triangles or read
    // out of bounds on the GPU.
    for (const auto idx : part.indices) {
      if (idx >= part.vertices.size()) {
        printf("       *** part %zu: index %u >= its %zu vertices ***\n", pi,
               idx, part.vertices.size());
        ++failures;
        break;
      }
    }
    if (part.indices.size() % 3 != 0) {
      printf("       *** part %zu: index count not a multiple of 3 ***\n", pi);
      ++failures;
    }
    if (part.imageIndex >= 0) {
      usedImages.insert(part.imageIndex);
      if (static_cast<size_t>(part.imageIndex) >= mesh.images.size()) {
        printf("       *** part %zu: imageIndex %d out of range ***\n", pi,
               part.imageIndex);
        ++failures;
      }
    } else {
      ++untextured;
    }

    float partUMin = 1e9f, partUMax = -1e9f;
    for (const auto &vert : part.vertices) {
      partUMin = std::min(partUMin, vert.texcoords[0]);
      partUMax = std::max(partUMax, vert.texcoords[0]);
      vMin = std::min(vMin, vert.texcoords[1]);
      vMax = std::max(vMax, vert.texcoords[1]);
    }
    uMin = std::min(uMin, partUMin);
    uMax = std::max(uMax, partUMax);
    // UVs outside [0,1] REQUIRE Repeat; with Clamp the part samples one edge
    // colour and reads as untextured.
    if ((partUMax > 1.001f || partUMin < -0.001f) && !part.wrapRepeatU) {
      printf("       *** part %zu: u exceeds [0,1] but wrapU is Clamp ***\n",
             pi);
      ++failures;
    }
  }

  printf("       largest part=%zu vertices (ceiling %zu)  untextured parts=%zu "
         " distinct images used=%zu\n",
         largestPart, kMaxVerticesPerPart, untextured, usedImages.size());
  printf("       uv range u=[%.3f %.3f] v=[%.3f %.3f]\n", uMin, uMax, vMin,
         vMax);

  // A model that collapsed to a point means the node transforms were dropped.
  if (mesh.minPosition[0] == mesh.maxPosition[0] &&
      mesh.minPosition[1] == mesh.maxPosition[1] &&
      mesh.minPosition[2] == mesh.maxPosition[2]) {
    printf("       *** bounding box is degenerate ***\n");
    ++failures;
  }

  for (size_t i = 0; i < mesh.images.size() && i < 4; ++i) {
    const auto &img = mesh.images[i];
    if (!img) {
      printf("       image[%zu] = null\n", i);
      continue;
    }
    printf("       image[%zu] %ux%u\n", i, img->size.width, img->size.height);
  }
  if (mesh.images.size() > 4) {
    printf("       ... and %zu more images\n", mesh.images.size() - 4);
  }
  return failures;
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: gltf_probe <file.glb> [...]\n");
    return 2;
  }

  if (std::strcmp(argv[1], "--expect-fail") == 0) {
    if (argc < 3) {
      fprintf(stderr, "usage: gltf_probe --expect-fail <file>\n");
      return 2;
    }
    MblMeshData mesh;
    std::string error;
    if (mblLoadGlb(argv[2], mesh, error)) {
      printf("FAIL %s: expected a rejection but it loaded\n", argv[2]);
      return 1;
    }
    printf("OK   %s correctly rejected: %s\n", argv[2], error.c_str());
    return 0;
  }

  int failures = 0;
  for (int i = 1; i < argc; ++i) {
    failures += describe(argv[i]);
  }
  printf("%s\n", failures == 0 ? "ALL GLB CHECKS PASSED" : "GLB CHECKS FAILED");
  return failures == 0 ? 0 : 1;
}
