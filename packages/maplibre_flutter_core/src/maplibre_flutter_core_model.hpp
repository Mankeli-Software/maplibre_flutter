// Spike: an animated 3D mesh drawn INSIDE mbgl, glued to a LatLng.
//
// This is deliberately a C++-only header (not part of the C ABI ffigen parses —
// see maplibre_flutter_core.h for that). It exists to keep every mbgl include out
// of the shim's translation unit except where it is already needed.
//
// Mechanism: mbgl::style::CustomDrawableLayer. The host hands mbgl a triangle
// mesh (position + uv) plus a per-frame mat4; mbgl draws it with its own
// `CustomGeometryShader`, which exists for Metal, Vulkan, OpenGL and WebGPU — so
// unlike the raw CustomLayer escape hatch (registered only under
// MLN_RENDER_BACKEND_OPENGL, see layer_manager.cpp) this path is available on
// every tier we ship.
//
// Known ceiling of that shader: `gl_Position = u_matrix * vec4(a_pos,1)` and
// `color = texture(u_image, uv) * u_color`. No normals, no lighting, one texture,
// one tint. Rigid-body animation (what this spike drives) is expressible; skeletal
// animation is not.
#ifndef MAPLIBRE_FLUTTER_CORE_MODEL_HPP
#define MAPLIBRE_FLUTTER_CORE_MODEL_HPP

#include <mbgl/style/layers/custom_drawable_layer.hpp>

#include <memory>

// Build the spike's test model host: a rectangular-base pyramid (asymmetric in X
// vs Y, and pointing +Z) anchored at `lat`/`lng`, spinning about the vertical
// axis at `spinDegreesPerSecond`.
//
// `metresPerUnit` sizes the mesh in REAL-WORLD METRES — one model unit is that
// many metres on the ground, so the model keeps its footprint as you zoom. The
// mesh spans 2 units in X, 1 in Y and 1.5 in Z, so metresPerUnit=50 is a
// 100m x 50m footprint standing 75m tall.
//
// The shape is deliberately asymmetric and per-face coloured: a symmetric mesh
// (a cone) would hide exactly the bugs this spike exists to catch — a mirrored
// anchor, a Y-flip, a wrong winding, or a rotation that never advances.
//
// Must be constructed on the render thread (the host is handed straight to
// mbgl::style::CustomDrawableLayer, whose lifecycle mbgl drives).
std::unique_ptr<mbgl::style::CustomDrawableLayerHost> mblMakeTestModelHost(
    double lat, double lng, double metresPerUnit, double spinDegreesPerSecond);

#endif // MAPLIBRE_FLUTTER_CORE_MODEL_HPP
