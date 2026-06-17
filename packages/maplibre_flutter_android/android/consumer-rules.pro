# Consumer R8/ProGuard rules shipped to apps that depend on this plugin.
#
# The jnigen control layer (CLAUDE.md §5a/§5d) looks these shim classes up from
# Dart by their fully-qualified name over JNI. R8 must not rename, repackage, or
# strip them (or their members) or the lookup fails at runtime in minified
# release builds. @Keep alone is not enough under AGP 9.1's changed default
# repackaging (CLAUDE.md §9), so keep them explicitly.
-keep class dev.maplibreflutter.maplibre_flutter_android.MapRegistry { *; }
-keep class dev.maplibreflutter.maplibre_flutter_android.MapLibreController { *; }

# The MapLibre Android SDK ships its own consumer rules; nothing needed for it here.
