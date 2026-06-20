# Web (WASM) build of maplibre_flutter_core. Standalone Emscripten build (run via
# emcmake, NOT flutter/hook/build.dart). Builds mbgl-core + the portable
# platform/default layer + an Emscripten platform layer (run loop, fetch HTTP
# source, WebGL2 backend) into a WASM module. See README.md / the design doc.
#
#   emcmake cmake -G Ninja -S . -B ../build/wasm
#   cmake --build ../build/wasm
cmake_minimum_required(VERSION 3.21)
project(maplibre_flutter_core_web CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT EMSCRIPTEN)
  message(FATAL_ERROR "This CMakeLists must be configured with emcmake (Emscripten).")
endif()

set(MLN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/maplibre-native")
set(WEB_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../src/web")

# Global toolchain flags. -pthread changes the ABI, so it (and the Emscripten
# library ports, whose headers the image readers need) must apply to EVERY object,
# mbgl-core included. -fexceptions: mbgl relies on C++ exceptions.
add_compile_options(-pthread -fexceptions -O2)
add_link_options(-pthread -fexceptions)
add_compile_options("SHELL:-s USE_ZLIB=1" "SHELL:-s USE_LIBPNG=1" "SHELL:-s USE_LIBJPEG=1")
add_link_options("SHELL:-s USE_ZLIB=1" "SHELL:-s USE_LIBPNG=1" "SHELL:-s USE_LIBJPEG=1")

# Build mbgl-core CORE_ONLY with the OpenGL (→ WebGL2) renderer.
set(MLN_WITH_CORE_ONLY ON CACHE BOOL "" FORCE)
set(MLN_WITH_METAL OFF CACHE BOOL "" FORCE)
set(MLN_WITH_VULKAN OFF CACHE BOOL "" FORCE)
set(MLN_WITH_WEBGPU OFF CACHE BOOL "" FORCE)
set(MLN_WITH_OPENGL ON CACHE BOOL "" FORCE)
add_subdirectory("${MLN_ROOT}" "${CMAKE_CURRENT_BINARY_DIR}/mbgl" EXCLUDE_FROM_ALL)

# mbgl forces -Werror unconditionally; Emscripten's (newer) clang flags warnings
# upstream's CI does not. Turn warnings-as-errors off for this third-party build by
# appending -Wno-error after -Werror on the shared options interface (last wins).
# Mirrors the Windows arm's /WX- trick.
if(TARGET mbgl-compiler-options)
  target_compile_options(mbgl-compiler-options INTERFACE -Wno-error)
endif()

set(_def "${MLN_ROOT}/platform/default/src/mbgl")

# Attach the portable platform/default sources + the Emscripten platform layer to
# mbgl-core (mirrors platform/linux/linux.cmake, swapping the libuv run loop, the
# libcurl HTTP source, the WebP reader, and the EGL backend for Emscripten ones).
target_sources(mbgl-core PRIVATE
  # --- storage (http_file_source -> Emscripten fetch) ---
  "${_def}/storage/asset_file_source.cpp"
  "${_def}/storage/database_file_source.cpp"
  "${_def}/storage/file_source_manager.cpp"
  "${_def}/storage/file_source_request.cpp"
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
  # --- util (run_loop/async_task/timer -> Emscripten; webp_reader -> stub) ---
  "${_def}/util/compression.cpp"
  "${_def}/util/filesystem.cpp"
  "${_def}/util/image.cpp"
  "${_def}/util/jpeg_reader.cpp"
  "${_def}/util/logging_stderr.cpp"
  "${_def}/util/monotonic_timer.cpp"
  "${_def}/util/png_reader.cpp"
  "${_def}/util/png_writer.cpp"
  "${_def}/util/string_stdlib.cpp"
  "${_def}/util/thread.cpp"
  "${_def}/util/thread_local.cpp"
  "${_def}/util/utf.cpp"
  # --- i18n / layermanager / platform / text ---
  "${_def}/i18n/collator.cpp"
  "${_def}/i18n/number_format.cpp"
  "${_def}/layermanager/layer_manager.cpp"
  "${_def}/platform/time.cpp"
  "${_def}/text/bidi.cpp"
  "${_def}/text/local_glyph_rasterizer.cpp"
  # --- gfx + GL headless backend ---
  "${_def}/gfx/headless_backend.cpp"
  "${_def}/gfx/headless_frontend.cpp"
  "${_def}/gl/headless_backend.cpp"
  "${MLN_ROOT}/platform/linux/src/gl_functions.cpp"
  # --- Emscripten platform layer (ours) ---
  "${WEB_SRC}/emscripten_run_loop.cpp"
  "${WEB_SRC}/emscripten_http_file_source.cpp"
  "${WEB_SRC}/emscripten_gl_backend.cpp"
  "${WEB_SRC}/emscripten_webp_stub.cpp"
  "${WEB_SRC}/emscripten_posix_stubs.cpp"
)

target_include_directories(mbgl-core PUBLIC "${MLN_ROOT}/platform/default/include")
# Ahead of the sysroot: provides the <GLES3/gl3ext.h> shim Emscripten lacks.
target_include_directories(mbgl-core BEFORE PRIVATE "${WEB_SRC}/include")

include("${MLN_ROOT}/vendor/nunicode.cmake")
include("${MLN_ROOT}/vendor/sqlite.cmake")
include("${MLN_ROOT}/vendor/icu.cmake")

# Builtin ICU: define on the target (directory-scoped set_source_files_properties
# no-ops for mbgl-core, defined in the submodule subdir — see CLAUDE.md), and add
# the builtin ICU include so collator/bidi find <unicode/…>.
target_compile_definitions(mbgl-core PRIVATE MBGL_USE_BUILTIN_ICU)
target_include_directories(mbgl-core PRIVATE "${MLN_ROOT}/vendor/icu/include")

target_link_libraries(mbgl-core PRIVATE
  mbgl-vendor-nunicode
  mbgl-vendor-sqlite
  mbgl-vendor-icu
)

# --- Render probe executable (.html + .js + .wasm) ---
add_executable(web_render_probe web_render_probe.cpp)
target_link_libraries(web_render_probe PRIVATE mbgl-core)
target_link_options(web_render_probe PRIVATE
  "SHELL:-s FETCH=1"
  "SHELL:-s MAX_WEBGL_VERSION=2"
  "SHELL:-s MIN_WEBGL_VERSION=2"
  "SHELL:-s FULL_ES3=1"
  "SHELL:-s ALLOW_MEMORY_GROWTH=1"
  "SHELL:-s EXIT_RUNTIME=0"
  "SHELL:-s ASSERTIONS=1"
  "SHELL:-s WASM_BIGINT=1"
  "SHELL:-s PTHREAD_POOL_SIZE=32"
  "SHELL:-s ENVIRONMENT=web,worker"
)
set_target_properties(web_render_probe PROPERTIES SUFFIX ".html")

# --- The shipped module: maplibre_flutter_core.js (MODULARIZE) + .wasm ---
# Exposes the embind MaplibreFlutterCore JS API the Dart web controller drives.
add_executable(maplibre_flutter_core_wasm "${WEB_SRC}/maplibre_flutter_core_web.cpp")
target_link_libraries(maplibre_flutter_core_wasm PRIVATE mbgl-core)
target_link_options(maplibre_flutter_core_wasm PRIVATE
  --bind
  "SHELL:-s MODULARIZE=1"
  "SHELL:-s EXPORT_NAME=MaplibreFlutterCore"
  "SHELL:-s EXPORT_ES6=0"
  "SHELL:-s FETCH=1"
  "SHELL:-s MAX_WEBGL_VERSION=2"
  "SHELL:-s MIN_WEBGL_VERSION=2"
  "SHELL:-s FULL_ES3=1"
  "SHELL:-s ALLOW_MEMORY_GROWTH=1"
  "SHELL:-s EXIT_RUNTIME=0"
  "SHELL:-s ASSERTIONS=1"
  "SHELL:-s WASM_BIGINT=1"
  "SHELL:-s PTHREAD_POOL_SIZE=32"
  "SHELL:-s ENVIRONMENT=web,worker"
)
set_target_properties(maplibre_flutter_core_wasm PROPERTIES OUTPUT_NAME "maplibre_flutter_core" SUFFIX ".js")
