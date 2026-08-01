# Toolchain + deps for building the maplibre_flutter_core OpenGL/EGL arm on Linux
# and rendering headless under Mesa software GL (llvmpipe) — used to verify the
# Linux GL render from a macOS dev machine, before real Linux hardware. Pairs with
# run-render-test.sh (which does the cmake build + runs the harness with the repo
# mounted). Not shipped; a CI Linux job can reuse it.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang lld cmake ninja-build ccache pkg-config git ca-certificates \
    libcurl4-openssl-dev libjpeg-dev libpng-dev libwebp-dev libuv1-dev libicu-dev \
    zlib1g-dev libsqlite3-dev \
    libglvnd-dev libegl-dev libgles-dev libgl-dev mesa-common-dev libx11-dev \
    libegl-mesa0 libgl1-mesa-dri libgbm1 mesa-utils xvfb \
    # Software VULKAN (lavapipe), so the Windows arm's backend has an
    # off-target verification path — it has none otherwise, and CLAUDE.md §11
    # forbids extrapolating a Windows behaviour from another platform.
    mesa-vulkan-drivers libvulkan-dev vulkan-tools \
    && rm -rf /var/lib/apt/lists/*

ENV CC=clang CXX=clang++
# Software GL, no GPU / X server needed.
ENV LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
# Pick lavapipe explicitly when a Vulkan build runs here. The filename is
# unsuffixed on arm64 and suffixed on x86_64, so list both — a missing ICD file
# in the list is ignored, a missing driver is not.
ENV VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json:/usr/share/vulkan/icd.d/lvp_icd.x86_64.json
