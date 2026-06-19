# Flutter Windows plugin for maplibre_flutter_windows. Builds the native half that
# owns the texture registrar and presents mbgl-core frames (from
# maplibre_flutter_core's .dll, over FFI) through a Flutter Texture via a
# flutter::PixelBufferTexture (CPU pixel buffer; D3D-shared-texture zero-copy is a
# later step).
#
# NOTE: not yet built/verified on real Windows hardware (written on Linux) — see
# CLAUDE.md §8. The structure follows the standard Flutter Windows plugin template.
cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "maplibre_flutter_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

add_library(${PLUGIN_NAME} SHARED
  "maplibre_flutter_windows_plugin.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_STANDARD 17
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Libraries bundled with the app. The core engine (maplibre_flutter_core.dll) is
# produced + bundled by maplibre_flutter_core's build hook. The ANGLE DLLs
# (libEGL.dll / libGLESv2.dll / d3dcompiler_47.dll) that mbgl-core links must sit
# next to the .exe at runtime — wire them in here once the Windows core build is
# verified (see CLAUDE.md §8 risks: ANGLE DLL bundling).
set(maplibre_flutter_windows_bundled_libraries
  ""
  PARENT_SCOPE
)
