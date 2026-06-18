# Flutter Linux (GTK) plugin for maplibre_flutter_linux. Builds the native half
# that owns the texture registrar and presents mbgl-core frames (from
# maplibre_flutter_core's .so, over FFI) through a Flutter Texture via an
# FlPixelBufferTexture (CPU pixel buffer; zero-copy FlTextureGL is a later step).
#
# NOTE: not yet built/verified on real Linux hardware (developed on macOS) — see
# CLAUDE.md §8. The structure follows the standard Flutter Linux plugin template.
cmake_minimum_required(VERSION 3.13)
set(PROJECT_NAME "maplibre_flutter_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "maplibre_flutter_linux_plugin")

add_library(${PLUGIN_NAME} SHARED
  "maplibre_flutter_linux_plugin.cc"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

# Libraries bundled with the app. The core engine (libmaplibre_flutter_core.so) is
# produced + bundled by maplibre_flutter_core's build hook, not here.
set(maplibre_flutter_linux_bundled_libraries
  ""
  PARENT_SCOPE
)
