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
# produced + bundled by maplibre_flutter_core's build hook (native assets).
#
# ANGLE: under the vcpkg triplet the core build uses (src/vcpkg-triplets, static
# library linkage), ANGLE is linked STATICALLY into maplibre_flutter_core.dll, so
# there are no ANGLE runtime DLLs to ship — it calls the system d3d11/dxgi/
# d3dcompiler at runtime (all present on Windows 10+). We still look for
# libEGL.dll/libGLESv2.dll so a future dynamic triplet "just works": any that exist
# are bundled next to the .exe (where the loader resolves mbgl-core's imports).
set(_mlf_vcpkg_root "$ENV{VCPKG_ROOT}")
if(NOT _mlf_vcpkg_root)
  set(_mlf_vcpkg_root "C:/vcpkg")
endif()
file(TO_CMAKE_PATH "${_mlf_vcpkg_root}" _mlf_vcpkg_root)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "[Aa][Rr][Mm]64")
  set(_mlf_triplet "arm64-windows")
else()
  set(_mlf_triplet "x64-windows")
endif()
set(_mlf_angle_dlls "")
foreach(_dll libEGL libGLESv2)
  set(_mlf_dll_path "${_mlf_vcpkg_root}/installed/${_mlf_triplet}/bin/${_dll}.dll")
  if(EXISTS "${_mlf_dll_path}")
    list(APPEND _mlf_angle_dlls "${_mlf_dll_path}")
  endif()
endforeach()

set(maplibre_flutter_windows_bundled_libraries
  ${_mlf_angle_dlls}
  PARENT_SCOPE
)
