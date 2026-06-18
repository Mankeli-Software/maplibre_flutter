# Builds the C ABI shim (maplibre_flutter_core.cpp) linked against mbgl-core from
# the vendored submodule, configured as a headless Metal "desktop core" on macOS.
# Driven by hook/build.dart via native_toolchain_cmake (CLAUDE.md §5c).
#
# Why we don't just include the upstream Darwin platform: platform/darwin builds
# the Apple ObjC *SDK* (MLNMapView etc.) and its CMake requires `bazel` to
# codegen the MLN* style-layer wrappers — none of which we use (CLAUDE.md §3:
# macOS uses the core, not the SDK). It also only ships a *GL* (CGL) headless
# backend; Metal-headless lives in platform/default. So we build mbgl-core
# CORE_ONLY (no bazel, no SDK) and attach the "default" desktop platform with
# Apple-native helpers ourselves, mirroring platform/darwin/darwin.cmake's
# pre-SDK integration (its lines 1-109). This block is the macOS arm of the
# shared desktop core; Linux/Windows get analogous attaches later.
cmake_minimum_required(VERSION 3.25)
project(maplibre_flutter_core CXX C)

enable_language(OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 20) # mbgl-core requires C++20.
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_OBJC_FLAGS "${CMAKE_OBJC_FLAGS} -fobjc-arc")
set(CMAKE_OBJCXX_FLAGS "${CMAKE_OBJCXX_FLAGS} -fobjc-arc")

set(MLN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/maplibre-native")

# Core only — skips the root CMakeLists' platform branch (the bazel/SDK path).
# Renderer backends (metal.cmake) are added to mbgl-core before that branch, so
# CORE_ONLY still gives us the Metal renderer; we add the headless backend +
# file source + platform primitives below.
set(MLN_WITH_CORE_ONLY ON CACHE BOOL "" FORCE)
set(MLN_WITH_WERROR OFF CACHE BOOL "" FORCE) # don't fail on upstream warnings
set(MLN_WITH_METAL ON CACHE BOOL "" FORCE)
set(MLN_WITH_OPENGL OFF CACHE BOOL "" FORCE)

# Use ccache when available (portable: ignored if not installed). Must be set
# before add_subdirectory so mbgl-core's targets capture the launcher. Makes the
# ~30-min first build of mbgl-core a one-time cost — rebuilds (and the hook build)
# reuse the cache.
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
  set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
  set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
  set(CMAKE_OBJC_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
  set(CMAKE_OBJCXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
endif()

add_subdirectory("${MLN_ROOT}" "${CMAKE_CURRENT_BINARY_DIR}/mbgl" EXCLUDE_FROM_ALL)

# ---- Attach the default desktop platform to mbgl-core (mirrors darwin.cmake
#      1-109, minus the bazel-generated Apple SDK classes). ----
set(_def "${MLN_ROOT}/platform/default/src/mbgl")
set(_dwn "${MLN_ROOT}/platform/darwin/core")

target_sources(mbgl-core PRIVATE
  # Apple-native run loop / async / timer (GCD-based; no libuv).
  "${_dwn}/async_task.cpp"
  "${_dwn}/run_loop.cpp"
  "${_dwn}/timer.cpp"
  # Apple-native primitives — use Foundation/ImageIO/CoreText so we need no
  # libpng/jpeg/webp/curl/ICU system packages.
  "${_dwn}/collator.mm"
  "${_dwn}/http_file_source.mm"
  "${_dwn}/image.mm"
  "${_dwn}/local_glyph_rasterizer.mm"
  "${_dwn}/logging_nslog.mm"
  "${_dwn}/native_apple_interface.m"
  "${_dwn}/nsthread.mm"
  "${_dwn}/number_format.mm"
  "${_dwn}/string_nsstring.mm"
  # Shared default-platform pieces.
  "${_def}/gfx/headless_backend.cpp"
  "${_def}/gfx/headless_frontend.cpp"
  "${_def}/layermanager/layer_manager.cpp"
  "${_def}/map/map_snapshotter.cpp"
  "${_def}/platform/time.cpp"
  "${_def}/storage/asset_file_source.cpp"
  "${_def}/storage/mbtiles_file_source.cpp"
  "${_def}/storage/database_file_source.cpp"
  "${_def}/storage/file_source_manager.cpp"
  "${_def}/storage/file_source_request.cpp"
  "${_def}/storage/local_file_request.cpp"
  "${_def}/storage/local_file_source.cpp"
  "${_def}/storage/main_resource_loader.cpp"
  "${_def}/storage/offline.cpp"
  "${_def}/storage/offline_database.cpp"
  "${_def}/storage/offline_download.cpp"
  "${_def}/storage/online_file_source.cpp"
  "${_def}/storage/pmtiles_file_source.cpp"
  "${_def}/storage/sqlite3.cpp"
  "${_def}/text/bidi.cpp"
  "${_def}/util/compression.cpp"
  "${_def}/util/filesystem.cpp"
  "${_def}/util/monotonic_timer.cpp"
  "${_def}/util/png_writer.cpp"
  "${_def}/util/thread_local.cpp"
  "${_def}/util/utf.cpp"
  # Metal headless backend (the off-screen render target).
  "${_def}/mtl/headless_backend.cpp"
)

target_include_directories(mbgl-core
  PUBLIC
    "${MLN_ROOT}/platform/darwin/include"
    "${MLN_ROOT}/platform/default/include"
  PRIVATE
    "${MLN_ROOT}/platform/darwin/src"
    "${MLN_ROOT}/platform/macos/src"
)

# Builtin ICU (text shaping/collation) — darwin.cmake includes this.
include("${MLN_ROOT}/vendor/icu.cmake")

target_link_libraries(mbgl-core PRIVATE
  "-framework Foundation"
  "-framework CoreFoundation"
  "-framework CoreGraphics"
  "-framework CoreImage"
  "-framework CoreText"
  "-framework ImageIO"
  "-framework CoreServices"
  "-framework CoreLocation"
  "-framework CFNetwork"
  "-framework SystemConfiguration"
  "-framework Metal"
  "-framework QuartzCore"
  "-framework IOSurface"
  "-framework IOKit"
  mbgl-vendor-icu
  sqlite3
  z
)

# ---- The C ABI shim ----
# maplibre_flutter_core_metal.mm is the ObjC++ zero-copy present helper (the GPU
# blit into an IOSurface); it needs Metal/IOSurface/CoreVideo, which mbgl-core
# links only PRIVATEly, so link them on the shim directly.
add_library(maplibre_flutter_core SHARED
  maplibre_flutter_core.cpp
  maplibre_flutter_core_metal.mm)
# The shim includes mbgl's mtl headless-backend header (for getMetalTexture()),
# which pulls in metal-cpp (NS::SharedPtr etc.); mbgl-core links it PRIVATEly, so
# add metal-cpp to the shim's include path too.
target_include_directories(maplibre_flutter_core PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${MLN_ROOT}/vendor/metal-cpp")
target_link_libraries(maplibre_flutter_core PRIVATE
  mbgl-core
  mbgl-compiler-options
  "-framework Foundation"
  "-framework Metal"
  "-framework IOSurface"
  "-framework CoreVideo")

# Hide everything but the FFI_PLUGIN_EXPORT-annotated C symbols.
set_target_properties(maplibre_flutter_core PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)

install(TARGETS maplibre_flutter_core
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION lib)
