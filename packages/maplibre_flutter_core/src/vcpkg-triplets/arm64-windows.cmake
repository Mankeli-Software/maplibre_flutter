# Custom vcpkg triplet for the maplibre_flutter_core Windows build (arm64). See
# x64-windows.cmake for rationale: static deps + dynamic CRT, release-only.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_BUILD_TYPE release)
