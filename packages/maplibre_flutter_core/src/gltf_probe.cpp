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
#include <string>
#include <vector>

namespace {

int describe(const std::string &path) {
  MblMeshData mesh;
  std::string error;
  if (!mblLoadGlb(path, mesh, error)) {
    printf("FAIL %s: %s\n", path.c_str(), error.c_str());
    return 1;
  }

  printf("OK   %s\n", path.c_str());
  printf("       vertices=%zu indices=%zu triangles=%zu\n", mesh.vertices.size(),
         mesh.indices.size(), mesh.indices.size() / 3);
  printf("       texture=%s", mesh.baseColor.has_value() ? "yes" : "no");
  if (mesh.baseColor.has_value()) {
    printf(" (%ux%u)", mesh.baseColor->size.width, mesh.baseColor->size.height);
  }
  printf("  tint=[%.2f %.2f %.2f %.2f]\n", mesh.baseColorFactor[0],
         mesh.baseColorFactor[1], mesh.baseColorFactor[2],
         mesh.baseColorFactor[3]);
  printf("       bbox min=(%.3f %.3f %.3f) max=(%.3f %.3f %.3f)  [X east, Y "
         "south, Z up, metres]\n",
         mesh.minPosition[0], mesh.minPosition[1], mesh.minPosition[2],
         mesh.maxPosition[0], mesh.maxPosition[1], mesh.maxPosition[2]);

  int failures = 0;

  // Every index must address a real vertex — a merge/offset bug here would draw
  // garbage triangles or read out of bounds on the GPU.
  for (const auto idx : mesh.indices) {
    if (idx >= mesh.vertices.size()) {
      printf("       *** index %u >= vertex count %zu ***\n", idx,
             mesh.vertices.size());
      ++failures;
      break;
    }
  }
  if (mesh.indices.size() % 3 != 0) {
    printf("       *** index count is not a multiple of 3 ***\n");
    ++failures;
  }
  // A model that collapsed to a point means the node transforms were dropped.
  const bool degenerate = mesh.minPosition[0] == mesh.maxPosition[0] &&
                          mesh.minPosition[1] == mesh.maxPosition[1] &&
                          mesh.minPosition[2] == mesh.maxPosition[2];
  if (degenerate) {
    printf("       *** bounding box is degenerate ***\n");
    ++failures;
  }
  // UV spread: if every vertex samples the same texel the model renders as a flat
  // colour even though a texture decoded fine — the failure mode that looks like
  // "the texture is not bound".
  float uMin = 1e9f, uMax = -1e9f, vMin = 1e9f, vMax = -1e9f;
  for (const auto &vert : mesh.vertices) {
    uMin = std::min(uMin, vert.texcoords[0]);
    uMax = std::max(uMax, vert.texcoords[0]);
    vMin = std::min(vMin, vert.texcoords[1]);
    vMax = std::max(vMax, vert.texcoords[1]);
  }
  printf("       uv range u=[%.3f %.3f] v=[%.3f %.3f]\n", uMin, uMax, vMin, vMax);
  printf("       sampler: wrapU=%s wrapV=%s filter=%s\n",
         mesh.wrapRepeatU ? "Repeat" : "Clamp",
         mesh.wrapRepeatV ? "Repeat" : "Clamp",
         mesh.filterLinear ? "Linear" : "Nearest");
  // UVs outside [0,1] REQUIRE Repeat; with Clamp the model samples one edge
  // colour and reads as untextured.
  if ((uMax > 1.001f || uMin < -0.001f) && !mesh.wrapRepeatU) {
    printf("       *** u exceeds [0,1] but wrapU is Clamp ***\n");
    ++failures;
  }
  if (uMax - uMin < 1e-6f && vMax - vMin < 1e-6f) {
    printf("       *** all UVs identical - texture cannot show ***\n");
    ++failures;
  }
  if (mesh.baseColor.has_value()) {
    // Average the decoded texture, so a fully-white or fully-transparent decode
    // is visible here rather than being mistaken for a binding problem.
    const auto &img = *mesh.baseColor;
    unsigned long long sum[4] = {0, 0, 0, 0};
    const size_t px = static_cast<size_t>(img.size.width) * img.size.height;
    for (size_t i = 0; i < px; ++i) {
      for (int c = 0; c < 4; ++c) sum[c] += img.data.get()[i * 4 + c];
    }
    if (px > 0) {
      printf("       texture mean rgba=(%.0f %.0f %.0f %.0f)\n",
             double(sum[0]) / px, double(sum[1]) / px, double(sum[2]) / px,
             double(sum[3]) / px);
    }
  }
  const size_t dump = std::min<size_t>(mesh.vertices.size(), 8);
  for (size_t i = 0; i < dump; ++i) {
    const auto &vert = mesh.vertices[i];
    printf("       v[%zu] pos=(%7.3f %7.3f %7.3f) uv=(%7.3f %7.3f)\n", i,
           vert.position[0], vert.position[1], vert.position[2],
           vert.texcoords[0], vert.texcoords[1]);
  }
  printf("       extent=(%.3f %.3f %.3f)\n",
         mesh.maxPosition[0] - mesh.minPosition[0],
         mesh.maxPosition[1] - mesh.minPosition[1],
         mesh.maxPosition[2] - mesh.minPosition[2]);
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
