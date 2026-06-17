package dev.maplibreflutter.maplibre_flutter_android

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Native half of the hybrid Android plugin.
 *
 * Its only job (milestone A) is to register the [MapLibreViewFactory] with the
 * engine's platform-view registry so the Dart side can embed an `AndroidView`.
 * This uses the platform-view registrar — not a data-path method channel
 * (CLAUDE.md §10). Camera/style control lands in milestone B via jnigen.
 */
class MaplibreFlutterAndroidPlugin : FlutterPlugin {
    companion object {
        /** Must match the `viewType` the Dart controller reports. */
        const val VIEW_TYPE = "maplibre_flutter/android"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(
            VIEW_TYPE,
            MapLibreViewFactory(),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Nothing engine-scoped to release yet; per-view cleanup is in
        // MapLibrePlatformView.dispose().
    }
}
