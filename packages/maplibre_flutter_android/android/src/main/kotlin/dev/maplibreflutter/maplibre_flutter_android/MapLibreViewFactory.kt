package dev.maplibreflutter.maplibre_flutter_android

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Builds a [MapLibrePlatformView] per `AndroidView`. The creation args are the
 * `creationParams` map the Dart controller serialises from `MapOptions`
 * (styleUri + camera), decoded via [StandardMessageCodec].
 */
class MapLibreViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?> ?: emptyMap()
        return MapLibrePlatformView(context, params)
    }
}
