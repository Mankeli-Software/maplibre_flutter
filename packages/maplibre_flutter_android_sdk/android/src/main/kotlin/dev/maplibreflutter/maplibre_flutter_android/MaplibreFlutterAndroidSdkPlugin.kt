package dev.maplibreflutter.maplibre_flutter_android

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Native half of the opt-in MapLibre Android SDK plugin.
 *
 * Registers the [MapLibreViewFactory] with the platform-view registry so the Dart
 * side can embed the SDK's `MapView` in an `AndroidView`. Control flows Dart → jni
 * → [MapLibreController] (no data-path method channel; CLAUDE.md §3/§10).
 */
class MaplibreFlutterAndroidSdkPlugin : FlutterPlugin {
    companion object {
        /** Must match the `viewType` the Dart SDK controller reports. */
        const val VIEW_TYPE = "maplibre_flutter/android"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(VIEW_TYPE, MapLibreViewFactory())
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
