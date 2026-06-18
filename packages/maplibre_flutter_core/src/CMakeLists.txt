# Builds the C ABI shim (maplibre_flutter_core.cpp) linked against mbgl-core from
# the vendored submodule. Driven by hook/build.dart via native_toolchain_cmake
# (CLAUDE.md §5c). Two platform arms share the same shim + render thread:
#
# - macOS (Metal): we can't use the upstream Darwin platform — its CMake requires
#   `bazel` to codegen the ObjC MLN* SDK (which we don't use, CLAUDE.md §3) and only
#   ships a GL/CGL headless backend. So we build mbgl-core CORE_ONLY (skips the
#   bazel/SDK branch) and hand-attach `platform/default` + Apple-native helpers +
#   the Metal headless backend ourselves, mirroring platform/darwin/darwin.cmake
#   (lines 1-109). Present is zero-copy via Metal/IOSurface (see *_metal.mm).
#
# - Linux/Windows (OpenGL ES3 + EGL): no bazel/SDK problem exists off-Darwin, so we
#   DON'T use CORE_ONLY — mbgl's own root CMake then includes platform/linux/linux.cmake
#   (or windows.cmake), wiring the GL headless backend + EGL + the default-platform
#   primitives (libuv/curl/png/jpeg/webp/ICU). Present is CPU pixel-buffer (GL has no
#   public texture handle); zero-copy (FlTextureGL / D3D shared handle) is a later step.
cmake_minimum_required(VERSION 3.25)
project(maplibre_flutter_core CXX C)

set(CMAKE_CXX_STANDARD 20) # mbgl-core requires C++20.
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(MLN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/maplibre-native")

set(MLN_WITH_WERROR OFF CACHE BOOL "" FORCE) # don't fail on upstream warnings

# Use ccache when available (portable: ignored if not installed). Must be set
# before add_subdirectory so mbgl-core's targets capture the launcher. Makes the
# ~30-min first build of mbgl-core a one-time cost — rebuilds (and the hook build)
# reuse the cache.
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
  set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
  set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
endif()

if(APPLE)
  # Metal arm: build CORE_ONLY (skip the bazel/SDK Darwin branch) + ObjC++ for the
  # Apple-native helpers and the zero-copy Metal present helper.
  enable_language(OBJC OBJCXX)
  set(CMAKE_OBJC_FLAGS "${CMAKE_OBJC_FLAGS} -fobjc-arc")
  set(CMAKE_OBJCXX_FLAGS "${CMAKE_OBJCXX_FLAGS} -fobjc-arc")
  if(CCACHE_PROGRAM)
    set(CMAKE_OBJC_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
    set(CMAKE_OBJCXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
  endif()
  set(MLN_WITH_CORE_ONLY ON CACHE BOOL "" FORCE)
  set(MLN_WITH_METAL ON CACHE BOOL "" FORCE)
  set(MLN_WITH_OPENGL OFF CACHE BOOL "" FORCE)
else()
  # OpenGL arm (Linux now; Windows later). Build CORE_ONLY so mbgl's root CMake
  # return()s early (no glfw/test/benchmark/render-test apps + their deps), and
  # hand-attach the default platform + GL/EGL headless backend below, mirroring
  # platform/linux/linux.cmake. cmake/opengl.cmake (included before the CORE_ONLY
  # return) compiles the GL renderer into mbgl-core.
  set(MLN_WITH_CORE_ONLY ON CACHE BOOL "" FORCE)
  set(MLN_WITH_METAL OFF CACHE BOOL "" FORCE)
  set(MLN_WITH_VULKAN OFF CACHE BOOL "" FORCE)
  set(MLN_WITH_OPENGL ON CACHE BOOL "" FORCE)
endif()

add_subdirectory("${MLN_ROOT}" "${CMAKE_CURRENT_BINARY_DIR}/mbgl" EXCLUDE_FROM_ALL)

if(APPLE)
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

elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # ---- Attach the default desktop platform + GL/EGL headless backend to
  #      mbgl-core (mirrors platform/linux/linux.cmake, minus X11/GLX/Wayland/
  #      Vulkan and the glfw/test apps that CORE_ONLY skips). ----
  set(_def "${MLN_ROOT}/platform/default/src/mbgl")
  set(_lnx "${MLN_ROOT}/platform/linux/src")

  find_package(CURL REQUIRED)
  find_package(JPEG REQUIRED)
  find_package(PNG REQUIRED)
  find_package(PkgConfig REQUIRED)
  find_package(Threads REQUIRED)
  find_package(OpenGL REQUIRED EGL) # GLVND libOpenGL + libEGL
  pkg_search_module(WEBP libwebp REQUIRED)
  pkg_search_module(LIBUV libuv REQUIRED)
  pkg_search_module(ICUUC icu-uc)
  pkg_search_module(ICUI18N icu-i18n)

  target_sources(mbgl-core PRIVATE
    "${_def}/gfx/headless_backend.cpp"
    "${_def}/gfx/headless_frontend.cpp"
    "${_def}/i18n/collator.cpp"
    "${_def}/i18n/number_format.cpp"
    "${_def}/layermanager/layer_manager.cpp"
    "${_def}/platform/time.cpp"
    "${_def}/storage/asset_file_source.cpp"
    "${_def}/storage/database_file_source.cpp"
    "${_def}/storage/file_source_manager.cpp"
    "${_def}/storage/file_source_request.cpp"
    "${_def}/storage/http_file_source.cpp"
    "${_def}/storage/local_file_request.cpp"
    "${_def}/storage/local_file_source.cpp"
    "${_def}/storage/mbtiles_file_source.cpp"
    "${_def}/storage/main_resource_loader.cpp"
    "${_def}/storage/offline.cpp"
    "${_def}/storage/offline_database.cpp"
    "${_def}/storage/offline_download.cpp"
    "${_def}/storage/online_file_source.cpp"
    "${_def}/storage/pmtiles_file_source.cpp"
    "${_def}/storage/sqlite3.cpp"
    "${_def}/text/bidi.cpp"
    "${_def}/text/local_glyph_rasterizer.cpp"
    "${_def}/util/async_task.cpp"
    "${_def}/util/compression.cpp"
    "${_def}/util/filesystem.cpp"
    "${_def}/util/image.cpp"
    "${_def}/util/jpeg_reader.cpp"
    "${_def}/util/webp_reader.cpp"
    "${_def}/util/logging_stderr.cpp"
    "${_def}/util/monotonic_timer.cpp"
    "${_def}/util/png_reader.cpp"
    "${_def}/util/png_writer.cpp"
    "${_def}/util/run_loop.cpp"
    "${_def}/util/string_stdlib.cpp"
    "${_def}/util/thread.cpp"
    "${_def}/util/thread_local.cpp"
    "${_def}/util/timer.cpp"
    "${_def}/util/utf.cpp"
    # GL headless backend (off-screen render target) + EGL context (headless,
    # works under Mesa software GL).
    "${_def}/gl/headless_backend.cpp"
    "${_lnx}/gl_functions.cpp"
    "${_lnx}/headless_backend_egl.cpp"
  )

  target_include_directories(mbgl-core
    PUBLIC
      "${MLN_ROOT}/platform/default/include"
    PRIVATE
      ${CURL_INCLUDE_DIRS}
      ${JPEG_INCLUDE_DIRS}
      ${LIBUV_INCLUDE_DIRS}
      ${WEBP_INCLUDE_DIRS}
  )

  include("${MLN_ROOT}/vendor/nunicode.cmake")
  include("${MLN_ROOT}/vendor/sqlite.cmake")

  # System ICU if recent enough, else the vendored builtin (mirrors linux.cmake).
  if(NOT ICUUC_FOUND OR "${ICUUC_VERSION}" VERSION_LESS 62.0)
    include("${MLN_ROOT}/vendor/icu.cmake")
    set_source_files_properties("${_def}/i18n/number_format.cpp"
      PROPERTIES COMPILE_DEFINITIONS MBGL_USE_BUILTIN_ICU)
    set(_icu_libs mbgl-vendor-icu)
  else()
    set(_icu_libs ${ICUUC_LIBRARIES} ${ICUI18N_LIBRARIES})
  endif()

  target_link_libraries(mbgl-core PRIVATE
    ${CURL_LIBRARIES}
    ${JPEG_LIBRARIES}
    ${LIBUV_LIBRARIES}
    ${WEBP_LIBRARIES}
    ${CMAKE_THREAD_LIBS_INIT}
    ${_icu_libs}
    PNG::PNG
    mbgl-vendor-nunicode
    mbgl-vendor-sqlite
    OpenGL::EGL
  )
endif()

# ---- The C ABI shim ----
set(_shim_sources maplibre_flutter_core.cpp)
if(APPLE)
  # maplibre_flutter_core_metal.mm is the ObjC++ zero-copy present helper (GPU blit
  # into an IOSurface) — Apple-only.
  list(APPEND _shim_sources maplibre_flutter_core_metal.mm)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # maplibre_flutter_core_gl.cpp is the GL zero-copy present helper (GPU blit into an
  # EGLImage-backed texture ring) — Linux/desktop-GL.
  list(APPEND _shim_sources maplibre_flutter_core_gl.cpp)
endif()

add_library(maplibre_flutter_core SHARED ${_shim_sources})
target_include_directories(maplibre_flutter_core PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(maplibre_flutter_core PRIVATE mbgl-core mbgl-compiler-options)

if(APPLE)
  # The shim includes mbgl's mtl headless-backend header (for getMetalTexture()),
  # which pulls in metal-cpp (NS::SharedPtr etc.); mbgl-core links it PRIVATEly, so
  # add metal-cpp to the shim's include path too. The Metal frameworks back the .mm.
  target_include_directories(maplibre_flutter_core PRIVATE "${MLN_ROOT}/vendor/metal-cpp")
  target_link_libraries(maplibre_flutter_core PRIVATE
    "-framework Foundation"
    "-framework Metal"
    "-framework IOSurface"
    "-framework CoreVideo")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # mbgl links OpenGL::EGL PRIVATEly, so the shim needs its own EGL + GLES symbols
  # for the zero-copy EGLImage present (maplibre_flutter_core_gl.cpp). OpenGL::EGL is
  # already found above (find_package(OpenGL REQUIRED EGL)).
  find_library(GLESV2_LIBRARY NAMES GLESv2)
  target_link_libraries(maplibre_flutter_core PRIVATE OpenGL::EGL ${GLESV2_LIBRARY})
endif()

# Hide everything but the FFI_PLUGIN_EXPORT-annotated C symbols.
set_target_properties(maplibre_flutter_core PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)

install(TARGETS maplibre_flutter_core
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION lib)

# ---- Headless render-to-PNG harness (test only; off by default) ----
# Verifies a non-Apple GL/EGL build renders headless (e.g. Mesa software GL in
# Docker). Not part of the plugin build the hook produces.
option(MAPLIBRE_FLUTTER_BUILD_HARNESS "Build the headless render-to-PNG test harness" OFF)
if(MAPLIBRE_FLUTTER_BUILD_HARNESS)
  add_executable(render_harness render_harness.cpp)
  target_link_libraries(render_harness PRIVATE maplibre_flutter_core)
endif()
