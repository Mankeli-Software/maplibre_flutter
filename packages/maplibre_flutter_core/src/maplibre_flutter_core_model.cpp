#include "maplibre_flutter_core_model.hpp"

#include <mbgl/gfx/drawable.hpp>
#include <mbgl/map/transform_state.hpp>
#include <mbgl/math/angles.hpp>
#include <mbgl/renderer/paint_parameters.hpp>
#include <mbgl/util/mat4.hpp>
#include <mbgl/util/projection.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <memory>
#include <utility>
#include <vector>

namespace {

using Interface = mbgl::style::CustomDrawableLayerHost::Interface;
using VertexVector = mbgl::gfx::VertexVector<Interface::GeometryVertex>;
using TriangleIndexVector = mbgl::gfx::IndexVector<mbgl::gfx::Triangles>;

class ModelHost final : public mbgl::style::CustomDrawableLayerHost {
public:
  ModelHost(std::shared_ptr<const MblMeshData> meshData,
            std::shared_ptr<MblMeshGpu> gpuData,
            std::shared_ptr<MblModelPlacement> placement)
      : mesh(std::move(meshData)), gpu(std::move(gpuData)),
        placement(std::move(placement)) {}

  void initialize() override {}
  void deinitialize() override {}

  void update(Interface &interface) override {
    // mbgl calls update() every frame; build the mesh once and let the
    // per-frame tweaker do the animating (re-uploading vertices every frame
    // would be the wrong shape of work entirely).
    if (interface.getDrawableCount() != 0) {
      return;
    }

    // One drawable per part, each with its own texture and tint. Parts exist
    // because mbgl's indices are uint16 (so one drawable caps at 65536 vertices)
    // and because a single texture per model would smear one material over a
    // multi-material mesh — a real car model arrives as ~149 primitives across
    // 64 materials and 20 images.
    //
    // Textures are uploaded once per distinct image and shared by every part
    // that references it AND by every model drawn from the same mesh — the cache
    // lives on the shared MblMeshGpu, not here. Making it a local meant N copies
    // of a vehicle each uploaded the whole texture set.
    if (gpu->textures.size() < mesh->images.size()) {
      gpu->textures.resize(mesh->images.size());
    }
    auto &textures = gpu->textures;

    // The animation clock is shared by every part, so they move as one rigid
    // body rather than drifting apart.
    const auto start = std::chrono::steady_clock::now();

    for (const auto &part : mesh->parts) {
      if (part.vertices.empty() || part.indices.empty()) {
        continue;
      }

      Interface::GeometryOptions options;
      if (part.imageIndex >= 0 &&
          static_cast<size_t>(part.imageIndex) < mesh->images.size()) {
        auto &cached = textures[static_cast<size_t>(part.imageIndex)];
        if (!cached && mesh->images[static_cast<size_t>(part.imageIndex)]) {
          cached = interface.context.createTexture2D();
          cached->setImage(mesh->images[static_cast<size_t>(part.imageIndex)]);
          // Take wrap/filter from the glTF sampler, NOT a hardcoded guess: glTF
          // defaults to REPEAT and models tile deliberately (BoxTextured spans
          // u=[0,6]), so clamping collapses them to one edge colour.
          cached->setSamplerConfiguration(
              {.filter = part.filterLinear
                             ? mbgl::gfx::TextureFilterType::Linear
                             : mbgl::gfx::TextureFilterType::Nearest,
               .wrapU = part.wrapRepeatU ? mbgl::gfx::TextureWrapType::Repeat
                                         : mbgl::gfx::TextureWrapType::Clamp,
               .wrapV = part.wrapRepeatV ? mbgl::gfx::TextureWrapType::Repeat
                                         : mbgl::gfx::TextureWrapType::Clamp});
        }
        options.texture = cached;
      }
      // With no texture, addGeometry substitutes a white 2x2 and this tint is
      // what shows; with one, it multiplies (glTF baseColorFactor semantics).
      options.color =
          mbgl::Color{part.baseColorFactor[0], part.baseColorFactor[1],
                      part.baseColorFactor[2], part.baseColorFactor[3]};
      interface.setGeometryOptions(options);

      // Runs on the render thread, once per drawable per frame, inside the
      // layer-group render. steady_clock rather than a frame counter, so the spin
      // rate is wall-clock correct regardless of how often the frontend renders.
      interface.setGeometryTweakerCallback(
          [=](mbgl::gfx::Drawable &, const mbgl::PaintParameters &params,
              Interface::GeometryOptions &current) {
            const double seconds =
                std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - start)
                    .count();
            // Re-read every frame: the placement is mutable so the model can be
            // driven along a path without re-uploading its mesh.
            const MblModelPlacement p = *placement;
            const mbgl::LatLng latLng{p.lat, p.lng};

            // Map bearing is clockwise from north, and rotate_z here is ALREADY
            // clockwise seen from above: model space is X east, Y south, Z up,
            // which is LEFT-handed (east x south = down, not up), so the standard
            // right-handed rotation formula turns east -> south, i.e. clockwise.
            // Negating it — which looks right if you assume a right-handed frame
            // — makes heading run backwards. That is invisible for a static model
            // (and for heading 180, which is symmetric) and only shows up once
            // heading sweeps: a model driving a circle then counter-rotates and
            // reads as spinning on its own axis instead of facing its travel.
            const double angle = mbgl::util::deg2rad(
                p.headingDegrees + p.spinDegreesPerSecond * seconds);

            // Anchor in mercator world coordinates at the current scale — the
            // space nearClippedProjMatrix consumes (upstream's own recipe, see
            // platform/glfw/example_custom_drawable_style_layer.cpp:490).
            mbgl::LatLng unwrapped = latLng.wrapped();
            unwrapped.unwrapForShortestPath(
                params.state.getLatLng(mbgl::LatLng::Wrapped));
            const mbgl::Point<double> center =
                mbgl::Projection::project(unwrapped, params.state.getScale());

            const double metresPerPixel =
                mbgl::Projection::getMetersPerPixelAtLatitude(
                    latLng.latitude(), params.state.getZoom());

            // THE AXES USE DIFFERENT UNITS. mbgl's projection matrix takes X/Y
            // in world pixels but Z in METRES — it applies pixelsPerMeter to z
            // itself (camera.cpp:104, "Height value (z) of renderables is in
            // meters. Scale z coordinate by pixelsPerMeter"). Scaling all three
            // axes uniformly, as upstream's flat-geometry example does, silently
            // squashes the model's height by metresPerPixel — it becomes a decal.
            const auto sxy = static_cast<float>(p.scale / metresPerPixel);
            const auto sz = static_cast<float>(p.scale);

            // The translate is applied AFTER the scale (M = T * R * S), so its z
            // is already in mbgl's metre units — elevation goes straight in.
            mbgl::mat4 model = mbgl::matrix::identity4();
            mbgl::matrix::translate(model, model, center.x, center.y,
                                    p.elevationMetres);
            mbgl::matrix::rotate_z(model, model, angle);
            mbgl::matrix::scale(model, model, sxy, sxy, sz);
            mbgl::matrix::multiply(current.matrix,
                                   params.transformParams.nearClippedProjMatrix,
                                   model);

            // The shader lights in MODEL space, so rotate the fixed world light
            // (from the north-west and above, a conventional map key light) by
            // the model's own yaw. Without this a turning model would carry its
            // lighting around with it.
            constexpr double kLx = -0.4, kLy = -0.45, kLz = 0.8;
            const double c = std::cos(-angle), s2 = std::sin(-angle);
            current.light = {static_cast<float>(kLx * c - kLy * s2),
                             static_cast<float>(kLx * s2 + kLy * c),
                             static_cast<float>(kLz),
                             0.55f};
          });

      auto vertices = std::make_shared<VertexVector>();
      auto indices = std::make_shared<TriangleIndexVector>();
      vertices->reserve(part.vertices.size());
      for (const auto &v : part.vertices) {
        vertices->emplace_back(
            Interface::GeometryVertex{v.position, v.texcoords, v.normal});
      }
      for (size_t i = 0; i + 2 < part.indices.size(); i += 3) {
        indices->emplace_back(part.indices[i], part.indices[i + 1],
                              part.indices[i + 2]);
      }

      // is3D = true → depth ReadWrite + setIs3D, i.e. a real depth-tested mesh
      // rather than a flat overlay (custom_drawable_layer.cpp:741). On Apple this
      // only actually depth-tests with
      // patches/metal-custom-drawable-3d-depth.patch.
      interface.addGeometry(vertices, indices, /*is3D=*/true);
    }

    interface.finish();
  }

private:
  std::shared_ptr<const MblMeshData> mesh;
  // GPU textures shared with every other model drawn from the same mesh.
  std::shared_ptr<MblMeshGpu> gpu;
  // Shared with the shim's registry and re-read every frame, so the model can be
  // moved (driven along a path) without touching its uploaded geometry.
  std::shared_ptr<MblModelPlacement> placement;
};

// --- The procedural test pyramid --------------------------------------------

// Texel centres of the 2x2 palette below. Sampled with Nearest, so each face
// reads exactly one texel and comes out a flat, unambiguous colour.
constexpr std::array<float, 2> kUvRed = {0.25f, 0.25f};
constexpr std::array<float, 2> kUvGreen = {0.75f, 0.25f};
constexpr std::array<float, 2> kUvBlue = {0.25f, 0.75f};
constexpr std::array<float, 2> kUvYellow = {0.75f, 0.75f};

// Flat-shaded triangle with a real geometric normal.
//
// The normal matters: without one the vertices carry the {0,0,0} default and
// the shaders' lighting term degenerates (see the guard in
// patches/custom-geometry-lighting.patch). This pyramid is the mesh every
// harness draws by default, so leaving it at zero meant the ONE fixture
// exercising the lighting path was exactly the case that does not exercise it.
//
// `outwardFrom` disambiguates the sign without relying on winding order or on
// map model space's left-handedness: flip the cross product until it points
// away from the solid's interior.
void pushTriangle(MblMeshData::Part &part, const std::array<float, 3> &a,
                  const std::array<float, 3> &b, const std::array<float, 3> &c,
                  const std::array<float, 2> &uv,
                  const std::array<float, 3> &outwardFrom = {0.0f, 0.0f, 0.0f}) {
  const std::array<float, 3> ab{b[0] - a[0], b[1] - a[1], b[2] - a[2]};
  const std::array<float, 3> ac{c[0] - a[0], c[1] - a[1], c[2] - a[2]};
  std::array<float, 3> n{ab[1] * ac[2] - ab[2] * ac[1],
                         ab[2] * ac[0] - ab[0] * ac[2],
                         ab[0] * ac[1] - ab[1] * ac[0]};
  const float len = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
  if (len > 1e-8f) {
    n = {n[0] / len, n[1] / len, n[2] / len};
    const std::array<float, 3> centroid{(a[0] + b[0] + c[0]) / 3.0f,
                                        (a[1] + b[1] + c[1]) / 3.0f,
                                        (a[2] + b[2] + c[2]) / 3.0f};
    const float outward = n[0] * (centroid[0] - outwardFrom[0]) +
                          n[1] * (centroid[1] - outwardFrom[1]) +
                          n[2] * (centroid[2] - outwardFrom[2]);
    if (outward < 0.0f) {
      n = {-n[0], -n[1], -n[2]};
    }
  } else {
    n = {0.0f, 0.0f, 0.0f};
  }
  const auto base = static_cast<uint16_t>(part.vertices.size());
  part.vertices.push_back({a, uv, n});
  part.vertices.push_back({b, uv, n});
  part.vertices.push_back({c, uv, n});
  part.indices.push_back(base);
  part.indices.push_back(static_cast<uint16_t>(base + 1));
  part.indices.push_back(static_cast<uint16_t>(base + 2));
}

} // namespace

std::unique_ptr<mbgl::style::CustomDrawableLayerHost>
mblMakeModelHost(std::shared_ptr<const MblMeshData> mesh,
                 std::shared_ptr<MblMeshGpu> gpu,
                 std::shared_ptr<MblModelPlacement> placement) {
  return std::make_unique<ModelHost>(std::move(mesh), std::move(gpu),
                                     std::move(placement));
}

MblMeshData mblMakeTestPyramid() {
  MblMeshData mesh;

  constexpr float hx = 1.0f; // half-extent, X
  constexpr float hy = 0.5f; // half-extent, Y
  constexpr float h = 1.5f;  // apex height, +Z

  const std::array<float, 3> v0 = {-hx, -hy, 0.0f};
  const std::array<float, 3> v1 = {hx, -hy, 0.0f};
  const std::array<float, 3> v2 = {hx, hy, 0.0f};
  const std::array<float, 3> v3 = {-hx, hy, 0.0f};
  const std::array<float, 3> apex = {0.0f, 0.0f, h};

  // +Y is south in map model space, so -Y is the north-facing side.
  // Inside the solid, so every face normal can be oriented outward from it.
  const std::array<float, 3> inside = {0.0f, 0.0f, h / 4.0f};

  MblMeshData::Part part;
  pushTriangle(part, v0, v1, apex, kUvRed, inside);    // north face
  pushTriangle(part, v1, v2, apex, kUvGreen, inside);  // east face
  pushTriangle(part, v2, v3, apex, kUvBlue, inside);   // south face
  pushTriangle(part, v3, v0, apex, kUvYellow, inside); // west face

  // Base, so the model is closed if viewed from below. NOTE: without the Metal
  // depth patch this base paints OVER all four side faces from above, because
  // custom drawables fall back to painter's order — that is the regression this
  // mesh exists to catch.
  pushTriangle(part, v0, v3, v2, kUvBlue, inside);
  pushTriangle(part, v0, v2, v1, kUvBlue, inside);

  mesh.minPosition = {-hx, -hy, 0.0f};
  mesh.maxPosition = {hx, hy, h};

  // A 2x2 RGBA palette: red, green / blue, yellow. Opaque, so premultiplication
  // is a no-op.
  mbgl::PremultipliedImage palette(mbgl::Size(2, 2));
  constexpr std::array<uint8_t, 16> texels = {
      255, 40,  40,  255, // red
      40,  200, 40,  255, // green
      60,  110, 255, 255, // blue
      255, 210, 40,  255, // yellow
  };
  std::copy(texels.begin(), texels.end(), palette.data.get());
  mesh.images.push_back(
      std::make_shared<mbgl::PremultipliedImage>(std::move(palette)));

  part.imageIndex = 0;
  // Nearest + Clamp so each face reads exactly one texel and stays a flat,
  // unambiguous colour (the whole point of the pinwheel regression).
  part.filterLinear = false;
  part.wrapRepeatU = false;
  part.wrapRepeatV = false;
  mesh.parts.push_back(std::move(part));

  return mesh;
}
