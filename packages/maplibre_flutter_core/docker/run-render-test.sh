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
ASSETS=/work/packages/maplibre_flutter/example/assets/models

# The procedural pyramid first: no asset, no texture decode, ~instant, and it is
# the mesh the colour/lighting assertions are written against (four faces each
# sampling one texel of a 2x2 palette, so a UV/normal attribute mix-up shows up
# as a broken pinwheel rather than "some pixels changed").
echo "=== model render, procedural pyramid (GL) ==="
mkdir -p /out/model-pyramid
run_model_harness() {
  local out=$1; shift
  if EGL_PLATFORM=surfaceless "$BUILD/model_harness" "$out" "$@"; then
    echo "=== OK (surfaceless) ==="
  else
    echo "=== surfaceless failed; retry under Xvfb ==="
    xvfb-run -a -s "-screen 0 1280x960x24" "$BUILD/model_harness" "$out" "$@"
    echo "=== OK (xvfb) ==="
  fi
}
# Positional args: lat lng zoom pitch bearing metresPerUnit style spinDps
#                  camOffsetDeg [glb] [headingDeg] [elevationM]
# spinDps MUST be non-zero for the animation assertion to mean anything; passing
# 0 made model_harness fail unconditionally, which under `set -e` aborted this
# whole script — so the GL model checks could never report green, with or
# without a working backend.
run_model_harness /out/model-pyramid \
  51.50735 -0.12776 21 55 0 1 \
  "https://demotiles.maplibre.org/style.json" 90 0.00255

MODEL_SMOKE="$ASSETS/demo_vehicle.glb"
MODEL="$ASSETS/alto_k10.glb"

# demo_vehicle.glb is ~4 KB and alto_k10.glb ~30 MB; run the cheap one first so a
# parse/upload regression fails in seconds rather than after the big decode.
for m in "$MODEL_SMOKE" "$MODEL"; do
  if [ ! -f "$m" ]; then
    echo "=== model asset not found at $m; skipping ==="
    continue
  fi
  echo "=== glb parse (GL build): $(basename "$m") ==="
  "$BUILD/gltf_probe" "$m"

  echo "=== model render (GL): $(basename "$m") ==="
  out=/out/model-$(basename "$m" .glb)
  mkdir -p "$out"
  # Camera framed as on Metal so the two are directly comparable.
  run_model_harness "$out" \
    51.50735 -0.12776 21 55 0 1 \
    "https://demotiles.maplibre.org/style.json" 90 0.00003 "$m" 0 0.15
  ls -l "$out"
done
