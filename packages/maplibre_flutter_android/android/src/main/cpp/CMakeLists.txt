# Native presenter for the experimental core-on-Android path (CLAUDE.md §3).
# Built by gradle's externalNativeBuild (separate from the maplibre_flutter_core
# build hook, which produces libmaplibre_flutter_core.so). This tiny lib bridges
# mbgl-core's FFI frame callback to a Flutter SurfaceProducer's Surface via the NDK
# ANativeWindow API; it resolves the core's functions through addresses passed from
# Dart, so it does not link against the core .so.
cmake_minimum_required(VERSION 3.18)
project(maplibre_flutter_android_jni CXX)

add_library(maplibre_flutter_android_jni SHARED maplibre_flutter_android_jni.cpp)

find_library(log-lib log)
find_library(android-lib android) # ANativeWindow_* + ANativeWindow_fromSurface

target_link_libraries(maplibre_flutter_android_jni ${log-lib} ${android-lib})
