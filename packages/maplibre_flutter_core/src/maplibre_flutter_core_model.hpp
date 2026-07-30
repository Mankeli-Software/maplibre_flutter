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

// Build a host that draws `mesh` at `lat`/`lng`.
//
// `mesh` is in map model space (X east, Y south, Z up, one unit = one metre as
// produced by mblLoadGlb). `scale` multiplies those units, so 1.0 renders a glTF
// authored in metres at life size. `headingDegrees` yaws the model clockwise from
// north; `spinDegreesPerSecond` adds a continuous yaw on top (0 = static).
//
// Must be called on the render thread — the host is handed straight to
// mbgl::style::CustomDrawableLayer, whose lifecycle mbgl drives.
std::unique_ptr<mbgl::style::CustomDrawableLayerHost>
mblMakeModelHost(MblMeshData mesh, double lat, double lng, double scale,
                 double headingDegrees, double spinDegreesPerSecond);

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
