#!/usr/bin/env bash
# Configure, build and run the native harness probes (CLAUDE.md §7 layer 4).
#
# These assert things no Dart test can reach: the shaping patch against mbgl's
# own text layout, .glb parse invariants, the projection/anchor origin
# conventions, and that a 3D model actually renders. They are gated behind
# MAPLIBRE_FLUTTER_BUILD_HARNESS so a normal build does not pay for them.
#
#   tool/run_harness.sh              # everything
#   tool/run_harness.sh hermetic     # no GPU, no network, no fonts
#   tool/run_harness.sh gpu          # the ones that drive a real headless map
#
# The first run builds mbgl-core and takes a while; ccache makes reruns cheap.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="$PWD/src"
BUILD="${MAPLIBRE_HARNESS_BUILD_DIR:-$PWD/build/harness}"
LABEL="${1:-}"

CCACHE_ARGS=()
if command -v ccache >/dev/null 2>&1; then
  CCACHE_ARGS=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

echo "=== configure ($BUILD) ==="
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DMAPLIBRE_FLUTTER_BUILD_HARNESS=ON \
  "${CCACHE_ARGS[@]}"

echo "=== build ==="
cmake --build "$BUILD" --target shaping_probe offline_url_probe gltf_probe proj_probe model_harness

echo "=== ctest ${LABEL:+(label: $LABEL)} ==="
if [ -n "$LABEL" ]; then
  ctest --test-dir "$BUILD" -L "$LABEL" --output-on-failure
else
  ctest --test-dir "$BUILD" --output-on-failure
fi
