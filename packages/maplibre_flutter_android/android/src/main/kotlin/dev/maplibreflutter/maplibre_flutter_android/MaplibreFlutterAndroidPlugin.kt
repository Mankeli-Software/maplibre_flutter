package dev.maplibreflutter.maplibre_flutter_android

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Native half of the hybrid Android plugin.
 *
 * Default (SDK) path: registers the [MapLibreViewFactory] with the platform-view
 * registry so the Dart side can embed an `AndroidView` (milestone A/B, jnigen).
 *
 * EXPERIMENTAL core path (CLAUDE.md §3): also installs a registrar [MethodChannel]
 * — the one sanctioned platform-channel use, registration only — that hands the
 * engine's [TextureRegistry] (a `SurfaceProducer`) the core map's native handle so
 * mbgl-core's frames present into a Flutter `Texture`. The channel is inert unless
 * the Dart core controller calls it, so the default SDK build pays nothing.
 */
class MaplibreFlutterAndroidPlugin :
    FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        /** Must match the `viewType` the Dart controller reports. */
        const val VIEW_TYPE = "maplibre_flutter/android"

        /** Must match the Dart core controller's registrar channel. */
        const val REGISTRAR_CHANNEL = "maplibre_flutter/android/registrar"
    }

    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private var channel: MethodChannel? = null
    private val textures = HashMap<Long, TextureHolder>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        binding.platformViewRegistry.registerViewFactory(VIEW_TYPE, MapLibreViewFactory())
        channel = MethodChannel(binding.binaryMessenger, REGISTRAR_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        textures.values.forEach { it.dispose() }
        textures.clear()
        this.binding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensureHttpBridge" -> {
                // Register the OkHttp-backed HTTP handler with mbgl-core before any
                // map is created (its style/tile requests start immediately).
                MapLibreCoreBridge.nativeSetHttpHandler()
                result.success(null)
            }
            "registerTexture" -> registerTexture(call, result)
            "resizeTexture" -> {
                val args = call.arguments as Map<*, *>
                val id = (args["textureId"] as Number).toLong()
                val w = (args["widthPx"] as Number).toInt().coerceAtLeast(1)
                val h = (args["heightPx"] as Number).toInt().coerceAtLeast(1)
                textures[id]?.resize(w, h)
                result.success(null)
            }
            "unregisterTexture" -> {
                val id = (call.arguments as Number).toLong()
                textures.remove(id)?.dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun registerTexture(call: MethodCall, result: MethodChannel.Result) {
        val binding = this.binding
        if (binding == null) {
            result.error("no_binding", "plugin not attached", null)
            return
        }
        val args = call.arguments as Map<*, *>
        val mapHandle = (args["mapHandle"] as Number).toLong()
        val copyFrameFn = (args["copyFrameFn"] as Number).toLong()
        val setFrameCallbackFn = (args["setFrameCallbackFn"] as Number).toLong()
        val widthPx = (args["widthPx"] as Number).toInt().coerceAtLeast(1)
        val heightPx = (args["heightPx"] as Number).toInt().coerceAtLeast(1)
        val zeroCopy = args["zeroCopy"] as? Boolean ?: false

        val producer = binding.textureRegistry.createSurfaceProducer()
        producer.setSize(widthPx, heightPx)
        val holder =
            TextureHolder(producer, mapHandle, copyFrameFn, setFrameCallbackFn, zeroCopy)
        producer.setCallback(holder)
        holder.register()
        textures[producer.id()] = holder
        result.success(producer.id())
    }

    /**
     * One registered core texture: owns a `SurfaceProducer` and the native
     * presenter bound to it. The producer's `Surface` is volatile under Impeller
     * (recreated on resize/suspend), so we (re)register the native presenter from
     * the lifecycle callbacks and re-fetch `getSurface()` each time (never cached).
     */
    private inner class TextureHolder(
        val producer: TextureRegistry.SurfaceProducer,
        val mapHandle: Long,
        val copyFrameFn: Long,
        val setFrameCallbackFn: Long,
        val zeroCopy: Boolean,
    ) : TextureRegistry.SurfaceProducer.Callback {
        private var presenter: Long = 0L

        /** Idempotent: binds the current surface to the core map. */
        fun register() {
            if (presenter != 0L) return
            presenter = MapLibreCoreBridge.nativeRegister(
                producer.surface, mapHandle, copyFrameFn, setFrameCallbackFn, zeroCopy,
            )
        }

        private fun unregisterNative() {
            if (presenter != 0L) {
                MapLibreCoreBridge.nativeUnregister(presenter, mapHandle, setFrameCallbackFn)
                presenter = 0L
            }
        }

        /** Resize the producer to device pixels and rebind (setSize may recreate the surface). */
        fun resize(widthPx: Int, heightPx: Int) {
            producer.setSize(widthPx, heightPx)
            unregisterNative()
            register()
        }

        override fun onSurfaceAvailable() = register()

        override fun onSurfaceCleanup() = unregisterNative()

        fun dispose() {
            unregisterNative()
            producer.setCallback(null)
            producer.release()
        }
    }
}
