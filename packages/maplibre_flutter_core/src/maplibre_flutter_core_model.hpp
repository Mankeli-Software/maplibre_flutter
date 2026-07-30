// Draws a textured 3D mesh INSIDE mbgl, anchored to a LatLng and animated.
//
// This is a C++-only header (not part of the C ABI ffigen parses — see
// maplibre_flutter_core.h for that), so mbgl includes stay out of the shim's
// translation unit except where already needed.
//
// Mechanism: mbgl::style::CustomDrawableLayer. The host hands mbgl a triangle
// mesh plus a per-frame mat4; mbgl draws it with its own CustomGeometryShader,
// which exists for Metal, Vulkan, OpenGL and WebGPU — so unlike the raw
// CustomLayer escape hatch (whose factory is gated on MLN_RENDER_BACKEND_OPENGL,
// see layer_manager.cpp) this path works on every tier we ship.
//
// Ceiling of that shader: `gl_Position = u_matrix * vec4(a_pos,1)` and
// `color = texture(u_image, uv) * u_color`. No normals, no lighting, one texture,
// one tint. Rigid-body animation is expressible; skeletal animation is not — bake
// lighting into the texture and animate by moving, not deforming.
//
// Depth: correct occlusion (against fill-extrusion buildings AND within the mesh)
// requires patches/metal-custom-drawable-3d-depth.patch on Apple platforms. See
// docs/3d-models-research.md.
#ifndef MAPLIBRE_FLUTTER_CORE_MODEL_HPP
#define MAPLIBRE_FLUTTER_CORE_MODEL_HPP

#include "maplibre_flutter_core_gltf.hpp"

#include <mbgl/style/layers/custom_drawable_layer.hpp>

#include <memory>

// Where and how a model sits on the map. Held by shared_ptr so it can be MUTATED
// to move the model without re-uploading its mesh — driving a vehicle along a
// path by re-adding the model each frame would re-parse and re-upload the whole
// .glb every frame, which for a real model is tens of megabytes.
//
// Render-thread confined: the C API mutates it from a posted command and the
// per-frame tweaker reads it, both on the render thread, so no lock is needed.
// The host and the shim's registry each hold a reference, so the struct outlives
// a host destroyed by a style reload.
struct MblModelPlacement {
  double lat = 0;
  double lng = 0;
  // Multiplies the mesh's own units; 1.0 renders a glTF authored in metres at
  // life size.
  double scale = 1;
  // Clockwise from north.
  double headingDegrees = 0;
  // Continuous yaw added on top, degrees per second (0 = static).
  double spinDegreesPerSecond = 0;
  // Lifts the model off the ground, in metres.
  //
  // A model whose base sits exactly at z=0 is coplanar with the basemap's ground
  // geometry, which z-fights — the map bleeds through the bodywork. A few
  // centimetres of lift resolves it.
  double elevationMetres = 0;
};

// Build a host that draws `mesh` at `placement`, which it keeps a reference to
// and re-reads every frame (so later mutations move the model).
//
// `mesh` is in map model space (X east, Y south, Z up, one unit = one metre as
// produced by mblLoadGlb).
//
// Must be called on the render thread — the host is handed straight to
// mbgl::style::CustomDrawableLayer, whose lifecycle mbgl drives.
// `mesh` is shared and immutable, so the same parsed model can back several
// hosts over time — notably when a style reload destroys the layer and it is
// re-added, which must not re-read the .glb.
std::unique_ptr<mbgl::style::CustomDrawableLayerHost>
mblMakeModelHost(std::shared_ptr<const MblMeshData> mesh,
                 std::shared_ptr<MblModelPlacement> placement);

// The procedural test mesh: a rectangular-base pyramid, 2 units across X, 1
// across Y, apex 1.5 up +Z, with each face a flat distinct colour.
//
// Deliberately asymmetric and per-face coloured — a symmetric mesh (a cone) would
// hide exactly the bugs this exists to catch: a mirrored or transposed anchor, a
// sign-flipped up axis, inverted winding, or depth that is really painter's order.
// Viewed top-down it must read as a four-colour pinwheel: red north, green east,
// blue south, yellow west.
MblMeshData mblMakeTestPyramid();

#endif // MAPLIBRE_FLUTTER_CORE_MODEL_HPP
