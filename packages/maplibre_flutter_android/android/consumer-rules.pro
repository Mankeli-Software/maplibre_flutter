# Consumer R8/ProGuard rules shipped to apps that depend on this plugin.
#
# The mbgl-core present bridge is called across the JNI boundary by name (C++ →
# Kotlin for the HTTP file source; native methods on the bridge). R8 must not
# rename, repackage, or strip these classes or their members, or the calls fail
# at runtime in minified release builds. @Keep alone is not enough under AGP
# 9.1's changed default repackaging (CLAUDE.md §9), so keep them explicitly.
-keep class dev.maplibreflutter.maplibre_flutter_android.MapLibreCoreBridge { *; }
-keep class dev.maplibreflutter.maplibre_flutter_android.MapLibreHttp { *; }
