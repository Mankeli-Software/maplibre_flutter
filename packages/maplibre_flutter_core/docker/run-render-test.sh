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
cmake --build "$BUILD" --target render_harness model_harness gltf_probe

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

# --- 3D models on the GL arm -------------------------------------------------
#
# The model renderer was developed on Metal, and three mbgl patches plus the
# lighting shader edits were only ever verified there. GL is the one other
# backend reachable from a Mac (Mesa llvmpipe in this container), so this is where
# "GL needs no patches" and "the GL lighting shader is right" stop being claims.
MODEL=/work/packages/maplibre_flutter/example/assets/models/alto_k10.glb
if [ -f "$MODEL" ]; then
  echo "=== glb parse (GL build) ==="
  "$BUILD/gltf_probe" "$MODEL"

  echo "=== model render (GL) ==="
  mkdir -p /out/model
  # Camera framed as on Metal so the two are directly comparable.
  if EGL_PLATFORM=surfaceless "$BUILD/model_harness" /out/model \
      51.50735 -0.12776 21 55 0 1 \
      "https://demotiles.maplibre.org/style.json" 0 0.00003 "$MODEL" 0 0.15; then
    echo "=== model OK (surfaceless) ==="
  else
    echo "=== surfaceless failed; retry under Xvfb ==="
    xvfb-run -a -s "-screen 0 1280x960x24" "$BUILD/model_harness" /out/model \
      51.50735 -0.12776 21 55 0 1 \
      "https://demotiles.maplibre.org/style.json" 0 0.00003 "$MODEL" 0 0.15
  fi
  ls -l /out/model
else
  echo "=== model asset not found at $MODEL; skipping model checks ==="
fi
