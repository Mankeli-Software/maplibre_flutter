#!/usr/bin/env bash
# Checks that reconfiguring an Apple build dir leaves every compile and link command
# unchanged (src/cmake/toolchain_flags.cmake). Configure only: it builds nothing, so
# it takes seconds and never touches mbgl-core.
#
# A tiny fixture project that includes the module the way src/CMakeLists.txt does is
# configured three times per Apple platform with the arguments native_toolchain_cmake
# passes, and `ninja -t commands` (every command a build would run, without running
# any) must be byte-identical across the three. It must also equal a fresh configure
# WITHOUT the module, which is the shape build dirs configured before the fix have.
#
#   tool/check_toolchain_flags.sh
#
# macOS only (the toolchain needs Xcode). Needs cmake and ninja on PATH, and
# `dart pub get` run in the workspace (for the native_toolchain_cmake path).
set -euo pipefail

cd "$(dirname "$0")/.."
PKG="$PWD"
CONFIG="$PKG/../../.dart_tool/package_config.json"
ROOT_URI=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(next(p['rootUri'] for p in d['packages'] if p['name'] == 'native_toolchain_cmake'))
" "$CONFIG")
TOOLCHAIN="${ROOT_URI#file://}/cmake/ios.toolchain.cmake"
[[ -f "$TOOLCHAIN" ]] || { echo "toolchain not found: $TOOLCHAIN" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/fixture/cmake"
cp "$PKG/src/cmake/toolchain_flags.cmake" "$WORK/fixture/cmake/"
echo 'int c(void) { return 1; }' > "$WORK/fixture/c.c"
echo 'int cxx() { return 2; }' > "$WORK/fixture/cxx.cpp"
echo 'int objc(void) { return 3; }' > "$WORK/fixture/objc.m"
echo 'int objcxx() { return 4; }' > "$WORK/fixture/objcxx.mm"
SOURCES='add_library(fixture SHARED c.c cxx.cpp objc.m objcxx.mm)'
cat > "$WORK/with_module.txt" <<EOF
cmake_minimum_required(VERSION 3.25)
include("\${CMAKE_CURRENT_SOURCE_DIR}/cmake/toolchain_flags.cmake")
mfc_toolchain_flags_before_project()
project(fixture CXX C \${MFC_TOOLCHAIN_LANGUAGES})
mfc_toolchain_flags_after_project()
enable_language(OBJC OBJCXX)
set(CMAKE_OBJC_FLAGS "\${CMAKE_OBJC_FLAGS} -fobjc-arc")
$SOURCES
EOF
cat > "$WORK/without_module.txt" <<EOF
cmake_minimum_required(VERSION 3.25)
project(fixture CXX C)
enable_language(OBJC OBJCXX)
set(CMAKE_OBJC_FLAGS "\${CMAKE_OBJC_FLAGS} -fobjc-arc")
$SOURCES
EOF

# configure <CMakeLists variant> <build dir> <platform> <deployment target>
configure() {
  cp "$WORK/$1.txt" "$WORK/fixture/CMakeLists.txt"
  cmake --log-level=ERROR -S "$WORK/fixture" -B "$2" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DPLATFORM="$3" -DDEPLOYMENT_TARGET="$4" -DENABLE_BITCODE=OFF -DENABLE_ARC=ON \
    -DENABLE_VISIBILITY=ON -DENABLE_STRICT_TRY_COMPILE=OFF >"$2.log" 2>&1 \
    || { cat "$2.log" >&2; exit 1; }
  # Build dirs differ, so compare commands relative to them.
  ninja -C "$2" -t commands fixture | sed "s#$2/*#BUILD/#g"
}

failed=0
for target in MAC_ARM64:13 MAC:13 OS64:15 SIMULATORARM64:15; do
  platform="${target%%:*}"
  deployment="${target##*:}"
  platform_failed=0
  reference=$(configure without_module "$WORK/reference-$platform" "$platform" "$deployment")
  for run in 1 2 3; do
    commands=$(configure with_module "$WORK/build-$platform" "$platform" "$deployment")
    if [[ "$commands" != "$reference" ]]; then
      echo "FAIL $platform: configure $run differs from a fresh configure:" >&2
      diff <(echo "$reference") <(echo "$commands") >&2 || true
      platform_failed=1
    fi
  done
  if ((platform_failed)); then
    failed=1
  else
    echo "ok   $platform: 3 configures, commands identical to a fresh one"
  fi
done
exit $failed
