# Custom vcpkg triplet for the maplibre_flutter_core Windows build (passed via
# --overlay-triplets / VCPKG_OVERLAY_TRIPLETS from hook/build.dart). Mirrors mbgl's
# platform/windows triplet: static C/C++ deps linked into maplibre_flutter_core.dll
# with a dynamic CRT (/MD), built release-only to halve port build time. ANGLE
# overrides this to dynamic (its port is dynamic-only), so libEGL.dll/libGLESv2.dll
# are produced and bundled beside the app (see hook/build.dart).
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_BUILD_TYPE release)
