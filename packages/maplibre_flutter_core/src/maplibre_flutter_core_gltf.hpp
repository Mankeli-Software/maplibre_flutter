// Minimal glTF 2.0 / GLB reader, producing what mbgl's built-in
// CustomGeometryShader can draw: position+uv triangle lists, each with one
// base-colour texture and one tint.
//
// Deliberately hand-written rather than vendoring cgltf/tinygltf: mbgl already
// vendors rapidjson (linked PUBLIC into mbgl-core, so its headers reach this
// shim) and already has an image decoder, so a reader scoped to what the shader
// can consume needs NO new third-party dependency, no FetchContent, and no
// build-time network access on any of the six platform arms.
//
// THE MESH IS SPLIT INTO PARTS, one drawable each, rather than merged into a
// single buffer. That is what makes real models work:
//   * mbgl's IndexVector is std::vector<uint16_t> (gfx/index_vector.hpp), so a
//     single drawable can address at most 65536 vertices. Production models blow
//     straight through that — a Sketchfab car came in at 509k vertices across 149
//     primitives — but each part stays under the ceiling, and any primitive that
//     alone exceeds it is split across parts by re-indexing.
//   * Each part carries its OWN texture and tint, so multi-material models render
//     correctly instead of having one arbitrary material smeared over everything.
//
// Scope, and why — the shader is `gl_Position = u_matrix * vec4(a_pos,1)` and
// `color = texture(u_image, uv) * u_color`, so anything it cannot express is
// dropped on purpose rather than half-supported:
//   * POSITION + TEXCOORD_0 only. NORMAL/TANGENT/COLOR_n are ignored (no
//     lighting exists to consume them), as are metallic/roughness/normal maps.
//   * Triangles only (glTF mode 4).
//   * No skins/animations. mbgl's shader cannot skin. Animate with the model
//     matrix instead.
//   * No Draco/meshopt compression, no external .bin or image files (GLB only,
//     everything must live in the BIN chunk).
//   * KHR_texture_transform IS applied (baked into the UVs); other extensions are
//     ignored, which is safe as long as they are not in extensionsRequired.
#ifndef MAPLIBRE_FLUTTER_CORE_GLTF_HPP
#define MAPLIBRE_FLUTTER_CORE_GLTF_HPP

#include <mbgl/util/image.hpp>

#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// One mesh ready for CustomDrawableLayerHost::Interface, in the map's model
// space: X east, Y south, Z up, one unit = one metre.
struct MblMeshData {
  struct Vertex {
    std::array<float, 3> position;
    std::array<float, 2> texcoords;
  };

  // One drawable's worth of geometry plus the material state it draws with.
  struct Part {
    std::vector<Vertex> vertices;
    std::vector<uint16_t> indices;

    // Index into `images`, or -1 for untextured (the host then supplies a white
    // texture and the tint alone shows).
    int imageIndex = -1;

    // pbrMetallicRoughness.baseColorFactor — the shader's tint. Opaque white by
    // default so an untextured part shows its factor colour.
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

    // glTF alphaMode BLEND, or a base-colour alpha below 1.
    //
    // Blended parts are emitted AFTER all opaque ones, because every part is
    // drawn with depth write on: glass drawn before the bodywork behind it would
    // write depth and cull that bodywork entirely — you would look through a
    // windscreen and see nothing of the car's far side.
    bool blended = false;
  };

  std::vector<Part> parts;

  // Decoded textures, shared between parts by index so an image referenced by
  // many materials is decoded (and later uploaded) once.
  std::vector<std::shared_ptr<mbgl::PremultipliedImage>> images;

  // Bounding box over all parts, in model space, for sanity-checking scale.
  std::array<float, 3> minPosition = {0, 0, 0};
  std::array<float, 3> maxPosition = {0, 0, 0};

  size_t totalVertices() const {
    size_t n = 0;
    for (const auto &p : parts) n += p.vertices.size();
    return n;
  }
  size_t totalTriangles() const {
    size_t n = 0;
    for (const auto &p : parts) n += p.indices.size() / 3;
    return n;
  }
};

// Parse a binary glTF (.glb) file into `out`. Returns false and sets `error` on
// any problem. Pure CPU work with no mbgl Map access, so this runs on the CALLING
// thread — that is what lets the C ABI report a parse failure synchronously
// instead of swallowing it on the render thread.
//
// Coordinate conversion, applied to every vertex: glTF is Y-up / -Z-forward and
// right-handed; the map's model space is Z-up with +Y running SOUTH. Vertices are
// mapped (x, y, z) -> (-x, z, y), a proper rotation (determinant +1, so winding
// is preserved) chosen so that a model's glTF "forward" (-Z) faces map NORTH at
// zero heading — the intuitive default for a vehicle.
bool mblLoadGlb(const std::string &path, MblMeshData &out, std::string &error);

#endif // MAPLIBRE_FLUTTER_CORE_GLTF_HPP
