package dev.maplibreflutter.maplibre_flutter_android

import android.content.Context
import android.view.View
import io.flutter.plugin.platform.PlatformView
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMapOptions
import org.maplibre.android.maps.MapView

/**
 * A single embedded MapLibre map (milestone A: render only).
 *
 * Builds a [MapView], pumps the minimal lifecycle it needs to draw (skipping it
 * is the classic blank-map cause), and loads the style + initial camera from the
 * `creationParams`. `textureMode(true)` makes the map a `TextureView` so it
 * composites correctly under Flutter's default Virtual Display `AndroidView`.
 *
 * Milestone B will register `viewId -> controller` here so Dart can drive the
 * camera/style over jnigen.
 */
class MapLibrePlatformView(
    context: Context,
    params: Map<String, Any?>,
) : PlatformView {

    private val mapView: MapView

    // Dart-minted id used to look this map's controller up over jnigen. -1 means
    // the Dart side did not request control (still renders fine).
    private val mapId: Int = (params["mapId"] as? Number)?.toInt() ?: -1
    private val controller: MapLibreController? =
        if (mapId >= 0) MapRegistry.register(mapId) else null

    init {
        // Must run before any MapView is constructed.
        MapLibre.getInstance(context)

        val styleUri = params["styleUri"] as? String
            ?: "https://demotiles.maplibre.org/style.json"
        val lat = (params["lat"] as? Number)?.toDouble() ?: 0.0
        val lng = (params["lng"] as? Number)?.toDouble() ?: 0.0
        val zoom = (params["zoom"] as? Number)?.toDouble() ?: 0.0
        val bearing = (params["bearing"] as? Number)?.toDouble() ?: 0.0
        val pitch = (params["pitch"] as? Number)?.toDouble() ?: 0.0

        val options = MapLibreMapOptions.createFromAttributes(context)
            .textureMode(true)
            .camera(
                CameraPosition.Builder()
                    .target(LatLng(lat, lng))
                    .zoom(zoom)
                    .bearing(bearing)
                    .tilt(pitch)
                    .build(),
            )

        mapView = MapView(context, options)
        mapView.onCreate(null)
        mapView.onStart()
        mapView.onResume()
        mapView.getMapAsync { map ->
            map.setStyle(styleUri)
            controller?.attachMap(map)
        }
    }

    override fun getView(): View = mapView

    override fun dispose() {
        if (mapId >= 0) MapRegistry.unregister(mapId)
        mapView.onPause()
        mapView.onStop()
        mapView.onDestroy()
    }
}
