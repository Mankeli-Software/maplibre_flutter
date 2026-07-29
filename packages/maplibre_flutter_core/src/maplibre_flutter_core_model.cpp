#include "maplibre_flutter_core_model.hpp"

#include <mbgl/gfx/drawable.hpp>
#include <mbgl/map/transform_state.hpp>
#include <mbgl/math/angles.hpp>
#include <mbgl/renderer/paint_parameters.hpp>
#include <mbgl/util/mat4.hpp>
#include <mbgl/util/projection.hpp>

#include <array>
#include <chrono>
#include <cmath>
#include <memory>

namespace {

using Interface = mbgl::style::CustomDrawableLayerHost::Interface;
using VertexVector = mbgl::gfx::VertexVector<Interface::GeometryVertex>;
using TriangleIndexVector = mbgl::gfx::IndexVector<mbgl::gfx::Triangles>;

// Texel centres of the 2x2 palette texture below. Sampled with Nearest, so each
// face reads exactly one texel and comes out a flat, unambiguous colour.
constexpr std::array<float, 2> kUvRed = {0.25f, 0.25f};
constexpr std::array<float, 2> kUvGreen = {0.75f, 0.25f};
constexpr std::array<float, 2> kUvBlue = {0.25f, 0.75f};
constexpr std::array<float, 2> kUvYellow = {0.75f, 0.75f};

// A 2x2 RGBA palette: red, green / blue, yellow. Opaque, so premultiplication
// is a no-op. Each pyramid face samples one texel, which makes the model's
// facing readable at a glance in a screenshot — the point of the spike.
mbgl::gfx::Texture2DPtr makePaletteTexture(Interface &interface) {
  auto image = std::make_shared<mbgl::PremultipliedImage>(mbgl::Size(2, 2));
  constexpr std::array<uint8_t, 16> texels = {
      255, 40,  40,  255, // red
      40,  200, 40,  255, // green
      60,  110, 255, 255, // blue
      255, 210, 40,  255, // yellow
  };
  std::copy(texels.begin(), texels.end(), image->data.get());

  auto texture = interface.context.createTexture2D();
  texture->setImage(std::move(image));
  texture->setSamplerConfiguration(
      {.filter = mbgl::gfx::TextureFilterType::Nearest,
       .wrapU = mbgl::gfx::TextureWrapType::Clamp,
       .wrapV = mbgl::gfx::TextureWrapType::Clamp});
  return texture;
}

void pushTriangle(VertexVector &vertices, TriangleIndexVector &indices,
                  const std::array<float, 3> &a, const std::array<float, 3> &b,
                  const std::array<float, 3> &c,
                  const std::array<float, 2> &uv) {
  const auto base = static_cast<uint16_t>(vertices.elements());
  vertices.emplace_back(Interface::GeometryVertex{a, uv});
  vertices.emplace_back(Interface::GeometryVertex{b, uv});
  vertices.emplace_back(Interface::GeometryVertex{c, uv});
  indices.emplace_back(base, static_cast<uint16_t>(base + 1),
                       static_cast<uint16_t>(base + 2));
}

// A rectangular-base pyramid: 2 units across X, 1 across Y, apex 1.5 up +Z.
// Asymmetric on purpose — X/Y asymmetry exposes a mirrored or transposed
// anchor, and the +Z apex exposes a sign-flipped up-axis (it would bury the
// model and leave only the base rectangle visible).
//
// NOTE on axes: this mesh is placed in mbgl world space, where +Y runs SOUTH
// (web mercator) and +Z is up.
void buildPyramid(VertexVector &vertices, TriangleIndexVector &indices) {
  constexpr float hx = 1.0f; // half-extent, X
  constexpr float hy = 0.5f; // half-extent, Y
  constexpr float h = 1.5f;  // apex height, +Z

  const std::array<float, 3> v0 = {-hx, -hy, 0.0f};
  const std::array<float, 3> v1 = {hx, -hy, 0.0f};
  const std::array<float, 3> v2 = {hx, hy, 0.0f};
  const std::array<float, 3> v3 = {-hx, hy, 0.0f};
  const std::array<float, 3> apex = {0.0f, 0.0f, h};

  pushTriangle(vertices, indices, v0, v1, apex, kUvRed);    // north face
  pushTriangle(vertices, indices, v1, v2, apex, kUvGreen);  // east face
  pushTriangle(vertices, indices, v2, v3, apex, kUvBlue);   // south face
  pushTriangle(vertices, indices, v3, v0, apex, kUvYellow); // west face

  // Base (two triangles), so the model is closed if viewed from below.
  //
  // WARNING: on this mbgl pin the base PAINTS OVER the four side faces when
  // seen from above, even though it is farther away. Custom drawable layers
  // declare pass3d = NotRequired (custom_drawable_layer.cpp:45) so they render
  // in the Translucent pass, whose per-layer depth range is too compressed to
  // resolve geometry within one layer — the result is painter's order, not
  // depth. See docs/3d-models-research.md.
  pushTriangle(vertices, indices, v0, v3, v2, kUvBlue);
  pushTriangle(vertices, indices, v0, v2, v1, kUvBlue);
}

class TestModelHost final : public mbgl::style::CustomDrawableLayerHost {
public:
  TestModelHost(double lat, double lng, double metresPerUnit,
                double spinDegreesPerSecond)
      : latLng(lat, lng), metresPerUnit(metresPerUnit),
        spinDps(spinDegreesPerSecond) {}

  void initialize() override {}
  void deinitialize() override {}

  void update(Interface &interface) override {
    // mbgl calls update() every frame; build the mesh once and let the
    // per-frame tweaker do the animating (re-uploading vertices every frame
    // would be the wrong shape of work entirely).
    if (interface.getDrawableCount() != 0) {
      return;
    }

    Interface::GeometryOptions options;
    options.texture = makePaletteTexture(interface);
    options.color = mbgl::Color::white(); // tint; the palette has the colour
    interface.setGeometryOptions(options);

    // Runs on the render thread, once per drawable per frame, inside the
    // layer-group render. It owns the animation clock: a steady_clock read
    // rather than a frame counter, so the spin rate is wall-clock correct
    // regardless of how often the frontend actually renders.
    const auto start = std::chrono::steady_clock::now();
    interface.setGeometryTweakerCallback([=](mbgl::gfx::Drawable &,
                                             const mbgl::PaintParameters
                                                 &params,
                                             Interface::GeometryOptions
                                                 &current) {
      const double seconds =
          std::chrono::duration<double>(std::chrono::steady_clock::now() - start)
              .count();
      const double angle = mbgl::util::deg2rad(spinDps * seconds);

      // Anchor in mercator world coordinates at the current scale — the space
      // nearClippedProjMatrix consumes (upstream's own recipe, see
      // platform/glfw/example_custom_drawable_style_layer.cpp:490).
      mbgl::LatLng unwrapped = latLng.wrapped();
      unwrapped.unwrapForShortestPath(
          params.state.getLatLng(mbgl::LatLng::Wrapped));
      const mbgl::Point<double> center =
          mbgl::Projection::project(unwrapped, params.state.getScale());

      const double metresPerPixel = mbgl::Projection::getMetersPerPixelAtLatitude(
          latLng.latitude(), params.state.getZoom());

      // THE AXES USE DIFFERENT UNITS. mbgl's projection matrix takes X/Y in
      // world pixels but Z in METRES — it applies pixelsPerMeter to z itself
      // (camera.cpp:104, "Height value (z) of renderables is in meters. Scale
      // z coordinate by pixelsPerMeter"). Scaling all three axes uniformly, as
      // upstream's flat-geometry example does, silently squashes the model's
      // height by a factor of metresPerPixel — it renders as a flat decal.
      const auto sxy = static_cast<float>(metresPerUnit / metresPerPixel);
      const auto sz = static_cast<float>(metresPerUnit);

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
    buildPyramid(*vertices, *indices);

    // is3D = true → depth ReadWrite + setIs3D, i.e. a real depth-tested mesh
    // rather than a flat overlay (custom_drawable_layer.cpp:741).
    interface.addGeometry(vertices, indices, /*is3D=*/true);
    interface.finish();
  }

private:
  mbgl::LatLng latLng;
  double metresPerUnit;
  double spinDps;
};

} // namespace

std::unique_ptr<mbgl::style::CustomDrawableLayerHost>
mblMakeTestModelHost(double lat, double lng, double metresPerUnit,
                     double spinDegreesPerSecond) {
  return std::make_unique<TestModelHost>(lat, lng, metresPerUnit,
                                         spinDegreesPerSecond);
}
