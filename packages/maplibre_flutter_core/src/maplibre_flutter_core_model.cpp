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
  ModelHost(MblMeshData meshData, double lat, double lng, double scale,
            double headingDegrees, double spinDegreesPerSecond)
      : mesh(std::move(meshData)), latLng(lat, lng), modelScale(scale),
        heading(headingDegrees), spinDps(spinDegreesPerSecond) {}

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
    // Textures are uploaded once per distinct image and shared by every part that
    // references it (Texture2DPtr is shared), so 149 parts over 20 images cost 20
    // uploads, not 149.
    std::vector<mbgl::gfx::Texture2DPtr> textures(mesh.images.size());

    // The animation clock is shared by every part, so they move as one rigid
    // body rather than drifting apart.
    const auto start = std::chrono::steady_clock::now();

    for (const auto &part : mesh.parts) {
      if (part.vertices.empty() || part.indices.empty()) {
        continue;
      }

      Interface::GeometryOptions options;
      if (part.imageIndex >= 0 &&
          static_cast<size_t>(part.imageIndex) < mesh.images.size()) {
        auto &cached = textures[static_cast<size_t>(part.imageIndex)];
        if (!cached && mesh.images[static_cast<size_t>(part.imageIndex)]) {
          cached = interface.context.createTexture2D();
          cached->setImage(mesh.images[static_cast<size_t>(part.imageIndex)]);
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
            // Map bearing is clockwise-from-north; model space is right-handed
            // about +Z (up), so a clockwise yaw is a negative rotate_z.
            const double angle =
                -mbgl::util::deg2rad(heading + spinDps * seconds);

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
            const auto sxy = static_cast<float>(modelScale / metresPerPixel);
            const auto sz = static_cast<float>(modelScale);

            mbgl::mat4 model = mbgl::matrix::identity4();
            mbgl::matrix::translate(model, model, center.x, center.y, 0.0);
            mbgl::matrix::rotate_z(model, model, angle);
            mbgl::matrix::scale(model, model, sxy, sxy, sz);
            mbgl::matrix::multiply(current.matrix,
                                   params.transformParams.nearClippedProjMatrix,
                                   model);
          });

      auto vertices = std::make_shared<VertexVector>();
      auto indices = std::make_shared<TriangleIndexVector>();
      vertices->reserve(part.vertices.size());
      for (const auto &v : part.vertices) {
        vertices->emplace_back(
            Interface::GeometryVertex{v.position, v.texcoords});
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
  MblMeshData mesh;
  mbgl::LatLng latLng;
  double modelScale;
  double heading;
  double spinDps;
};

// --- The procedural test pyramid --------------------------------------------

// Texel centres of the 2x2 palette below. Sampled with Nearest, so each face
// reads exactly one texel and comes out a flat, unambiguous colour.
constexpr std::array<float, 2> kUvRed = {0.25f, 0.25f};
constexpr std::array<float, 2> kUvGreen = {0.75f, 0.25f};
constexpr std::array<float, 2> kUvBlue = {0.25f, 0.75f};
constexpr std::array<float, 2> kUvYellow = {0.75f, 0.75f};

void pushTriangle(MblMeshData::Part &part, const std::array<float, 3> &a,
                  const std::array<float, 3> &b, const std::array<float, 3> &c,
                  const std::array<float, 2> &uv) {
  const auto base = static_cast<uint16_t>(part.vertices.size());
  part.vertices.push_back({a, uv});
  part.vertices.push_back({b, uv});
  part.vertices.push_back({c, uv});
  part.indices.push_back(base);
  part.indices.push_back(static_cast<uint16_t>(base + 1));
  part.indices.push_back(static_cast<uint16_t>(base + 2));
}

} // namespace

std::unique_ptr<mbgl::style::CustomDrawableLayerHost>
mblMakeModelHost(MblMeshData mesh, double lat, double lng, double scale,
                 double headingDegrees, double spinDegreesPerSecond) {
  return std::make_unique<ModelHost>(std::move(mesh), lat, lng, scale,
                                     headingDegrees, spinDegreesPerSecond);
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
  MblMeshData::Part part;
  pushTriangle(part, v0, v1, apex, kUvRed);    // north face
  pushTriangle(part, v1, v2, apex, kUvGreen);  // east face
  pushTriangle(part, v2, v3, apex, kUvBlue);   // south face
  pushTriangle(part, v3, v0, apex, kUvYellow); // west face

  // Base, so the model is closed if viewed from below. NOTE: without the Metal
  // depth patch this base paints OVER all four side faces from above, because
  // custom drawables fall back to painter's order — that is the regression this
  // mesh exists to catch.
  pushTriangle(part, v0, v3, v2, kUvBlue);
  pushTriangle(part, v0, v2, v1, kUvBlue);

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
