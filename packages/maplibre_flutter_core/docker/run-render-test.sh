#!/usr/bin/env bash
# Runs inside the Docker image (see Dockerfile): builds the maplibre_flutter_core
# OpenGL/EGL arm + the render harness, then renders a headless PNG to /out.
# The repo is mounted read-only at /work, ccache at /ccache, output at /out.
set -euo pipefail

export CCACHE_DIR=/ccache
ccache --max-size=5G >/dev/null 2>&1 || true

SRC=/work/packages/maplibre_flutter_core/src
BUILD=/build-linux # container-local (fast fs); ccache makes rebuilds cheap

echo "=== configure ==="
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DMAPLIBRE_FLUTTER_BUILD_HARNESS=ON

echo "=== build (cold mbgl GL build is ~tens of minutes; ccache speeds reruns) ==="
cmake --build "$BUILD" --target render_harness

export LD_LIBRARY_PATH="$BUILD:${LD_LIBRARY_PATH:-}"
STYLE="${1:-https://demotiles.maplibre.org/style.json}"
OUT="${2:-/out/frame.png}"
mkdir -p "$(dirname "$OUT")"

echo "=== render (EGL surfaceless + llvmpipe) ==="
if EGL_PLATFORM=surfaceless "$BUILD/render_harness" "$STYLE" "$OUT"; then
  echo "=== OK (surfaceless): $OUT ==="
else
  echo "=== surfaceless failed; retry under Xvfb ==="
  xvfb-run -a -s "-screen 0 1280x960x24" "$BUILD/render_harness" "$STYLE" "$OUT"
  echo "=== OK (xvfb): $OUT ==="
fi
ls -l "$OUT"
