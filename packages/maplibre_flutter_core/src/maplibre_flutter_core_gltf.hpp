// Minimal glTF 2.0 / GLB reader, producing exactly what mbgl's built-in
// CustomGeometryShader can draw: one interleaved position+uv triangle list, one
// base-colour texture, one tint.
//
// Deliberately hand-written rather than vendoring cgltf/tinygltf: mbgl already
// vendors rapidjson (linked PUBLIC into mbgl-core, so its headers reach this
// shim) and already has an image decoder, so a reader scoped to what the shader
// can consume needs NO new third-party dependency, no FetchContent, and no
// build-time network access on any of the six platform arms.
//
// Scope, and why — the shader is `gl_Position = u_matrix * vec4(a_pos,1)` and
// `color = texture(u_image, uv) * u_color`, so anything it cannot express is
// dropped on purpose rather than half-supported:
//   * POSITION + TEXCOORD_0 only. NORMAL/TANGENT/COLOR_n are ignored (no
//     lighting exists to consume them).
//   * All primitives of all meshes in the scene are MERGED into one buffer, and
//     only the FIRST base-colour texture found is used. Multi-material models
//     therefore render with one material's texture across the whole mesh.
//   * Triangles only (glTF mode 4).
//   * No skins/animations. mbgl's shader cannot skin, and indices are uint16 so
//     per-frame CPU re-upload is not worth it. Animate with the model matrix.
//   * No Draco/meshopt compression, no external .bin or image files (GLB only,
//     everything must be in the BIN chunk).
//
// Hard limit: mbgl's IndexVector is std::vector<uint16_t> (gfx/index_vector.hpp),
// so a model may contribute at most 65535 vertices. Loading fails loudly rather
// than silently truncating.
#ifndef MAPLIBRE_FLUTTER_CORE_GLTF_HPP
#define MAPLIBRE_FLUTTER_CORE_GLTF_HPP

#include <mbgl/util/image.hpp>

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// One mesh ready for CustomDrawableLayerHost::Interface::addGeometry, in the
// map's model space: X east, Y south, Z up, one unit = one metre.
struct MblMeshData {
  struct Vertex {
    std::array<float, 3> position;
    std::array<float, 2> texcoords;
  };

  std::vector<Vertex> vertices;
  std::vector<uint16_t> indices;

  // Decoded base-colour texture, if the model had one we could read.
  std::optional<mbgl::PremultipliedImage> baseColor;

  // pbrMetallicRoughness.baseColorFactor, used as the shader's tint. Defaults to
  // opaque white so an untextured model shows its factor colour.
  std::array<float, 4> baseColorFactor = {1.0f, 1.0f, 1.0f, 1.0f};

  // The base-colour sampler's wrap/filter modes, from the glTF sampler.
  //
  // Defaults are REPEAT, which is glTF's OWN default and NOT what "authored in
  // [0,1]" intuition suggests: real models tile deliberately (the Khronos
  // BoxTextured sample has u spanning [0,6]). Clamping those flattens the model
  // to a single edge colour, which reads as "the texture never bound".
  // MIRRORED_REPEAT degrades to Repeat — mbgl's TextureWrapType has no mirror.
  bool wrapRepeatU = true;
  bool wrapRepeatV = true;
  bool filterLinear = true;

  // Bounding box in model space, for sanity-checking scale at the call site.
  std::array<float, 3> minPosition = {0, 0, 0};
  std::array<float, 3> maxPosition = {0, 0, 0};
};

// Parse a binary glTF (.glb) file into `out`. Returns false and sets `error` on
// any problem, including the uint16 vertex limit. Pure CPU work with no mbgl Map
// access, so this runs on the CALLING thread — that is what lets the C ABI report
// a parse failure synchronously instead of swallowing it on the render thread.
//
// Coordinate conversion, applied to every vertex: glTF is Y-up / -Z-forward and
// right-handed; the map's model space is Z-up with +Y running SOUTH. Vertices are
// mapped (x, y, z) -> (-x, z, y), a proper rotation (determinant +1, so winding
// is preserved) chosen so that a model's glTF "forward" (-Z) faces map NORTH at
// zero heading — the intuitive default for a vehicle.
bool mblLoadGlb(const std::string &path, MblMeshData &out, std::string &error);

#endif // MAPLIBRE_FLUTTER_CORE_GLTF_HPP
