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

# native_toolchain_cmake's iOS toolchain (leetal ios-cmake) leaves APPLE=TRUE for BOTH
# macOS (CMAKE_SYSTEM_NAME=Darwin) and iOS (CMAKE_SYSTEM_NAME=iOS; device PLATFORM=OS64,
# simulator SIMULATORARM64). The whole Apple arm below — CORE_ONLY + Metal + the
# platform/darwin Apple-native helpers + the mtl headless backend — is shared by both
# Darwin platforms; this flag disambiguates the few iOS-only deltas (no AppKit/macOS
# sources, a tighter framework link line). This is the macOS desktop-core tier extended
# to iOS as an experimental core-on-mobile path (CLAUDE.md §3 escape hatch).
set(_apple_is_ios FALSE)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  set(_apple_is_ios TRUE)
endif()

# The iOS Simulator's Metal stub library omits two device-only symbols mbgl's mtl.cpp
# references (MTLIOErrorDomain/MTLTensorDomain), so the core dylib won't link for the
# Simulator. mbgl links Metal strongly itself, so `-weak_framework Metal` can't relax it;
# instead we compile maplibre_flutter_core_sim_stubs.mm (which defines those two symbols
# locally) into the dylib for the Simulator only. On an Apple-Silicon Mac the Simulator
# has a real host-GPU Metal, so the core then renders there too.
set(_apple_is_ios_sim FALSE)
if(_apple_is_ios AND CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
  set(_apple_is_ios_sim TRUE)
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
elseif(WIN32)
  # Vulkan arm (Windows): mbgl's Vulkan headless backend. Replaces the former
  # ANGLE/OpenGL-ES (EGL-on-D3D) path, which crashed under rapid tile churn — a
  # DrawableGL/VAO resource-lifetime bug in mbgl's GL renderer that ANGLE's strict
  # D3D11 validation faults on (0xC0000005 in glDrawElements during fly-to). Vulkan
  # has no GL path, so that crash cannot recur, and it keeps the zero-copy present
  # (Vulkan renders into an image we blit into a shared D3D11 texture — see
  # maplibre_flutter_core_vk.cpp). CORE_ONLY so mbgl's root return()s before the
  # glfw/test apps; the Vulkan renderer sources + shaders + glslang/SPIRV/VMA/
  # Vulkan-Headers are wired automatically by the root's cmake/vulkan.cmake (~line
  # 999) + vendor/vulkan.cmake (~1220), BOTH of which run before the CORE_ONLY
  # return() and are keyed on MLN_WITH_VULKAN — so setting the flag is the entire
  # trigger. We hand-attach only the default-platform Vulkan headless backend below
  # (mirroring windows.cmake's MLN_WITH_VULKAN branch). validate-backend-options.cmake
  # requires exactly one backend, so OpenGL/EGL/Metal go OFF.
  set(MLN_WITH_CORE_ONLY ON CACHE BOOL "" FORCE)
  set(MLN_WITH_METAL OFF CACHE BOOL "" FORCE)
  set(MLN_WITH_OPENGL OFF CACHE BOOL "" FORCE)
  set(MLN_WITH_EGL OFF CACHE BOOL "" FORCE)
  set(MLN_WITH_VULKAN ON CACHE BOOL "" FORCE)
else()
  # OpenGL arm (Linux). Build CORE_ONLY so mbgl's root CMake return()s early (no
  # glfw/test/benchmark/render-test apps + their deps), and hand-attach the default
  # platform + GL/EGL headless backend below, mirroring platform/linux/linux.cmake.
  # cmake/opengl.cmake (included before the CORE_ONLY return) compiles the GL
  # renderer into mbgl-core.
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
  )
  if(NOT _apple_is_ios)
    # macOS-only (MLNMapView/AppKit headers). The headless core path references nothing
    # under platform/macos/src, but darwin.cmake puts it on macOS's include path; iOS must
    # NOT pull it — AppKit is unavailable there.
    target_include_directories(mbgl-core PRIVATE "${MLN_ROOT}/platform/macos/src")
  endif()

  # Builtin ICU (text shaping/collation) — darwin.cmake includes this.
  include("${MLN_ROOT}/vendor/icu.cmake")

  # Frameworks shared by macOS + iOS. (CoreServices is macOS-only; IOKit is
  # private/restricted on iOS and App Store review flags it — both are unused by the
  # headless core path, so they are macOS-only additions below. IOSurface is its own
  # public framework on iOS, unrelated to IOKit.)
  set(_apple_frameworks
    "-framework Foundation"
    "-framework CoreFoundation"
    "-framework CoreGraphics"
    "-framework CoreImage"
    "-framework CoreText"
    "-framework ImageIO"
    "-framework CoreLocation"
    "-framework CFNetwork"
    "-framework SystemConfiguration"
    "-framework Metal"
    "-framework QuartzCore"
    "-framework IOSurface"
  )
  if(NOT _apple_is_ios)
    list(APPEND _apple_frameworks "-framework CoreServices" "-framework IOKit")
  endif()

  target_link_libraries(mbgl-core PRIVATE
    ${_apple_frameworks}
    mbgl-vendor-icu
    sqlite3
    z
  )

  if(_apple_is_ios)
    # mbgl hard-codes ghc::filesystem on iOS (action_journal_impl.cpp guards the
    # include on TARGET_OS_IPHONE) instead of std::filesystem, so mbgl-core needs the
    # vendored ghc header path. Upstream's platform/ios/ios.cmake links the same
    # mbgl-vendor-filesystem INTERFACE target for this; it's created by
    # vendor/filesystem.cmake (root CMake ~line 1118, before the CORE_ONLY return()).
    # macOS compiles std::filesystem and needs none of this.
    target_link_libraries(mbgl-core PRIVATE mbgl-vendor-filesystem)
  endif()

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

elseif(WIN32)
  # ---- Attach the default desktop platform + ANGLE (EGL/OpenGL-ES) headless
  #      backend to mbgl-core (mirrors platform/windows/windows.cmake's mbgl-core
  #      attach, minus the glfw/test/benchmark apps CORE_ONLY skips). Dependencies
  #      come from vcpkg: the Windows build must configure with the vcpkg toolchain
  #      file, and mbgl's platform/windows/Get-VendorPackages.ps1 installs
  #      CURL/ICU/JPEG/libuv/PNG/WebP/dlfcn-win32/ANGLE for the target triplet.
  #      Wiring that into hook/build.dart + verifying the MSVC/Ninja build is a
  #      Windows-machine task — UNVERIFIED here (CLAUDE.md §8). ----
  set(_def "${MLN_ROOT}/platform/default/src/mbgl")
  set(_win "${MLN_ROOT}/platform/windows/src")

  # mbgl-core (and our shim, which both link mbgl-compiler-options) inherit two MSVC
  # flags that bite a CORE_ONLY build off mbgl's own CI toolchain:
  #  * upstream forces /WX (warnings-as-errors) UNCONDITIONALLY for MSVC (root
  #    CMakeLists ~line 93), independent of MLN_WITH_WERROR — a newer MSVC than
  #    upstream's CI then fails on new warnings. We don't gate releases on upstream
  #    warnings (MLN_WITH_WERROR is OFF above), so append /WX- (last flag wins for cl).
  #  * mbgl's large translation units can exceed the COFF section limit, so add
  #    /bigobj (upstream's non-CORE_ONLY Windows path doesn't need it per-TU, but a
  #    newer MSVC's inlining can push us over — cheap insurance).
  target_compile_options(mbgl-compiler-options INTERFACE
    $<$<CXX_COMPILER_ID:MSVC>:/WX->
    $<$<CXX_COMPILER_ID:MSVC>:/bigobj>)

  find_package(CURL REQUIRED)
  find_package(dlfcn-win32 REQUIRED)
  find_package(ICU OPTIONAL_COMPONENTS i18n uc)
  find_package(JPEG REQUIRED)
  find_package(libuv REQUIRED)
  find_package(PNG REQUIRED)
  find_package(WebP REQUIRED)

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
    "${_def}/util/timer.cpp"
    "${_def}/util/utf.cpp"
    # Windows-native thread + thread-local (instead of the default util versions).
    "${_win}/thread.cpp"
    "${_win}/thread_local.cpp"
    # Vulkan headless backend (the off-screen render target). The Vulkan renderer
    # core + shaders + glslang/SPIRV/VMA are attached by the root's cmake/vulkan.cmake
    # (keyed on MLN_WITH_VULKAN); this default-platform headless piece is the only
    # source we hand-attach (mirrors windows.cmake's MLN_WITH_VULKAN branch).
    "${_def}/vulkan/headless_backend.cpp"
  )

  target_compile_definitions(mbgl-core PRIVATE
    NOMINMAX
    GHC_WIN_DISABLE_WSTRING_STORAGE_TYPE
    CURL_STATICLIB
    USE_STD_FILESYSTEM)

  target_include_directories(mbgl-core
    PUBLIC
      "${MLN_ROOT}/platform/default/include"
    PRIVATE
      "${MLN_ROOT}/platform/windows/include"
      # mbgl's Vulkan sources + the headless backend include <vulkan/vulkan.hpp>;
      # the vendored Vulkan-Headers supply it (mirrors windows.cmake:148). The root's
      # PUBLIC link of mbgl-vendor-vulkan-headers should also propagate this, but we
      # add it explicitly as belt-and-suspenders.
      "${MLN_ROOT}/vendor/Vulkan-Headers/include"
      ${CURL_INCLUDE_DIRS}
      ${JPEG_INCLUDE_DIRS}
      ${LIBUV_INCLUDE_DIRS}
      ${WEBP_INCLUDE_DIRS}
  )

  include("${MLN_ROOT}/vendor/nunicode.cmake")
  include("${MLN_ROOT}/vendor/sqlite.cmake")

  # System ICU if recent enough, else the vendored builtin (mirrors windows.cmake).
  if(NOT ICU_FOUND OR "${ICU_VERSION}" VERSION_LESS 62.0)
    include("${MLN_ROOT}/vendor/icu.cmake")
    # number_format.cpp is the ONLY file that reads MBGL_USE_BUILTIN_ICU (it swaps the
    # full-ICU number formatter — absent from the stripped vendored ICU — for a builtin
    # one). Define it on the whole mbgl-core target: set_source_files_properties is
    # directory-scoped and would NOT reach mbgl-core, which is defined in the submodule
    # subdirectory (the upstream set_source_files_properties pattern silently no-ops for
    # an out-of-tree core; only system-ICU builds dodged it).
    target_compile_definitions(mbgl-core PRIVATE MBGL_USE_BUILTIN_ICU)
    target_compile_definitions(mbgl-vendor-icu PRIVATE U_STATIC_IMPLEMENTATION)
    # Put the builtin ICU headers on mbgl-core's include path (BEFORE any system ICU)
    # so collator.cpp finds <unicode/...> — windows.cmake does this explicitly; the
    # vendor target's INTERFACE includes alone aren't enough.
    target_include_directories(mbgl-core BEFORE PRIVATE "${MLN_ROOT}/vendor/icu/include")
    set(_icu_libs mbgl-vendor-icu)
  else()
    set(_icu_libs ICU::i18n ICU::uc ICU::data)
  endif()

  # vcpkg's libuv exports libuv::uv_a (static, our triplet) or libuv::uv (shared).
  # Resolve via if(TARGET) — a $<IF:...> genex still names the missing target, and
  # CMake validates every "::" name in target_link_libraries even in an unselected
  # genex branch, which fails configure.
  if(TARGET libuv::uv_a)
    set(_uv_target libuv::uv_a)
  else()
    set(_uv_target libuv::uv)
  endif()

  target_link_libraries(mbgl-core PRIVATE
    ${CURL_LIBRARIES}
    dlfcn-win32::dl
    ${JPEG_LIBRARIES}
    ${WEBP_LIBRARIES}
    ${_icu_libs}
    PNG::PNG
    mbgl-vendor-nunicode
    mbgl-vendor-sqlite
    ${_uv_target}
  )
endif()

# ---- The C ABI shim ----
set(_shim_sources maplibre_flutter_core.cpp)
if(APPLE)
  # maplibre_flutter_core_metal.mm is the ObjC++ zero-copy present helper (GPU blit
  # into an IOSurface) — Apple-only.
  list(APPEND _shim_sources maplibre_flutter_core_metal.mm)
  if(_apple_is_ios_sim)
    # Defines the two device-only Metal symbols mbgl references but the Simulator's
    # Metal stub omits, so the dylib links for the Simulator (see the file's header).
    list(APPEND _shim_sources maplibre_flutter_core_sim_stubs.mm)
  endif()
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # maplibre_flutter_core_gl.cpp is the GL zero-copy present helper (GPU blit into an
  # EGLImage-backed texture ring exported as a dmabuf) — Linux/desktop-GL only.
  list(APPEND _shim_sources maplibre_flutter_core_gl.cpp)
elseif(WIN32)
  # maplibre_flutter_core_vk.cpp is the Windows zero-copy present helper: it imports
  # mbgl's rendered Vulkan image into a ring of shared D3D11 textures and publishes DXGI
  # shared handles for a Flutter GpuSurfaceTexture (the Vulkan->D3D11 analog of the macOS
  # Metal/IOSurface path; replaces the obsolete ANGLE-GL maplibre_flutter_core_d3d.cpp).
  list(APPEND _shim_sources maplibre_flutter_core_vk.cpp)
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
elseif(WIN32)
  # The shim's Vulkan->D3D11 zero-copy present (maplibre_flutter_core_vk.cpp) imports
  # mbgl's rendered Vulkan image into a ring of shared D3D11 textures and publishes DXGI
  # shared handles for Flutter's GpuSurfaceTexture. It needs the system D3D11/DXGI libs
  # and the Vulkan headers. (VK_USE_PLATFORM_WIN32_KHR + the dynamic-dispatcher /
  # no-default-dispatcher defines are set by mbgl's renderer_backend.hpp, which _vk.cpp
  # includes first — so we must NOT redefine them here, else MSVC warns C4005.)
  target_link_libraries(maplibre_flutter_core PRIVATE d3d11 dxgi)
  target_include_directories(maplibre_flutter_core PRIVATE
    "${MLN_ROOT}/vendor/Vulkan-Headers/include"
    # mbgl's public Vulkan headers (include/mbgl/vulkan/*) pull PRIVATE headers from
    # mbgl's src/ (e.g. mbgl/gfx/cull_face_mode.hpp), so the shim — which includes those
    # Vulkan headers for the present helper — needs mbgl's src/ on its include path too.
    "${MLN_ROOT}/src")
  target_compile_definitions(maplibre_flutter_core PRIVATE NOMINMAX)
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
