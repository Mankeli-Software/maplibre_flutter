# Flutter Linux (GTK) plugin for maplibre_flutter_linux. Builds the native half
# that owns the texture registrar and presents mbgl-core frames (from
# maplibre_flutter_core's .so, over FFI) through a Flutter Texture — either an
# FlPixelBufferTexture (CPU pixel buffer, default) or a zero-copy FlTextureGL that
# samples the core's EGLImage frame (opt-in via --dart-define=MAPLIBRE_ZEROCOPY).
#
# The structure follows the standard Flutter Linux plugin template.
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

# Zero-copy GL present: the plugin imports the core's EGLImage frame into a
# Flutter-context texture, so it needs EGL + GLES symbols (eglGetProcAddress,
# eglGetCurrentDisplay, glGenTextures/glBindTexture/glTexParameteri).
find_package(PkgConfig REQUIRED)
pkg_check_modules(EGL REQUIRED IMPORTED_TARGET egl)
pkg_check_modules(GLESV2 REQUIRED IMPORTED_TARGET glesv2)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::EGL PkgConfig::GLESV2)

# Libraries bundled with the app. The core engine (libmaplibre_flutter_core.so) is
# produced + bundled by maplibre_flutter_core's build hook, not here.
set(maplibre_flutter_linux_bundled_libraries
  ""
  PARENT_SCOPE
)
