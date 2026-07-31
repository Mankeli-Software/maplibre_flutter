#!/usr/bin/env bash
# Copies the Emscripten core artifact into an app's web/ directory.
#
# The WASM arm is a standalone Emscripten build (not `flutter build web`, not
# hook/build.dart), and its output is multi-megabyte, so it is neither committed
# nor shipped in the pub package. It belongs next to the app's index.html, where
# the app controls the COOP/COEP headers the threaded build requires.
#
#   tool/install_web_core.sh <app-dir> [build-dir]
#
# Example, from the repo root after building the module:
#   packages/maplibre_flutter_web/tool/install_web_core.sh \
#     packages/maplibre_flutter/example
#
# CI publishes the same two files as the `maplibre-flutter-core-wasm` artifact
# (see .github/workflows/ci.yml), so a consumer can download rather than build.
set -euo pipefail

APP_DIR="${1:?usage: install_web_core.sh <app-dir> [build-dir]}"
BUILD_DIR="${2:-packages/maplibre_flutter_core/build/wasm}"
DEST="$APP_DIR/web"

for f in maplibre_flutter_core.js maplibre_flutter_core.wasm; do
  if [ ! -f "$BUILD_DIR/$f" ]; then
    echo "missing $BUILD_DIR/$f" >&2
    echo "build it first:" >&2
    echo "  source /path/to/emsdk/emsdk_env.sh" >&2
    echo "  cd packages/maplibre_flutter_core/web" >&2
    echo "  emcmake cmake -G Ninja -S . -B ../build/wasm" >&2
    echo "  cmake --build ../build/wasm --target maplibre_flutter_core_wasm" >&2
    exit 1
  fi
done

mkdir -p "$DEST"
cp "$BUILD_DIR"/maplibre_flutter_core.{js,wasm} "$DEST/"
echo "installed into $DEST"
echo
echo "Serve with:"
echo "  Cross-Origin-Opener-Policy: same-origin"
echo "  Cross-Origin-Embedder-Policy: require-corp"
echo "(pthreads need cross-origin isolation; without it the module fails to start)"
