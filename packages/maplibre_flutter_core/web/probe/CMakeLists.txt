# Emscripten feasibility probe — does mbgl-core itself compile to WASM?
#
# This is NOT the production web build. It is the minimal empirical test for the
# experimental web-via-core effort (docs/experimental-web-core-wasm.md): configure
# + compile mbgl-core under Emscripten with the OpenGL (→ WebGL2) backend and CORE_ONLY,
# and capture exactly where it fails. Upstream tracks the unsolved library-compilation
# effort at maplibre/maplibre-native#2554; this probe turns "emcmake errors out" into a
# concrete, reproducible gap list for our pinned core.
#
# Run (after `emsdk_env`):
#   emcmake cmake -G Ninja -S . -B ../../build/wasm-probe
#   cmake --build ../../build/wasm-probe --target mbgl-core
cmake_minimum_required(VERSION 3.21)
project(mbgl_wasm_probe CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Pinned, vendored MapLibre Native (same submodule the desktop tiers build).
set(MLN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/maplibre-native")

# CORE_ONLY so mbgl's root CMake return()s before the glfw/test/benchmark/render-test
# apps + their (non-WASM) deps. Select the OpenGL renderer: Emscripten maps GLES/EGL
# onto WebGL2, which (unlike the desktop EGL-pbuffer path) targets a canvas.
set(MLN_WITH_CORE_ONLY ON CACHE BOOL "" FORCE)
set(MLN_WITH_METAL OFF CACHE BOOL "" FORCE)
set(MLN_WITH_VULKAN OFF CACHE BOOL "" FORCE)
set(MLN_WITH_WEBGPU OFF CACHE BOOL "" FORCE)
set(MLN_WITH_OPENGL ON CACHE BOOL "" FORCE)

add_subdirectory("${MLN_ROOT}" "${CMAKE_CURRENT_BINARY_DIR}/mbgl" EXCLUDE_FROM_ALL)
