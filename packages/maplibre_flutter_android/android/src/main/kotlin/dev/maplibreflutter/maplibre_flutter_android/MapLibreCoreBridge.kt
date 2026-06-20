package dev.maplibreflutter.maplibre_flutter_android

import android.view.Surface

/**
 * JNI bridge to the experimental core-on-Android present path (CLAUDE.md §3).
 *
 * Loads the native presenter ([maplibre_flutter_android_jni]) and exposes its
 * entry points. The native side calls mbgl-core's FFI functions (whose addresses
 * are passed as [Long]s) to read frames and presents them into a SurfaceProducer's
 * [Surface] via the NDK ANativeWindow API. Only used when the core path is selected
 * by `--dart-define=MAPLIBRE_EXPERIMENTAL_CORE=true`; the SDK path never loads it.
 */
internal object MapLibreCoreBridge {
    init {
        System.loadLibrary("maplibre_flutter_android_jni")
    }

    /**
     * Binds [surface] to the core map at [mapHandle]: attaches a frame callback
     * (via [setFrameCallbackFn]) that copies each rendered frame (via [copyFrameFn])
     * into the surface. Returns an opaque native presenter handle for
     * [nativeUnregister].
     */
    external fun nativeRegister(
        surface: Surface,
        mapHandle: Long,
        copyFrameFn: Long,
        setFrameCallbackFn: Long,
        zeroCopy: Boolean,
    ): Long

    /** Detaches the frame callback and releases the presenter at [presenterHandle]. */
    external fun nativeUnregister(
        presenterHandle: Long,
        mapHandle: Long,
        setFrameCallbackFn: Long,
    )

    /**
     * Resolves the core's HTTP entry points (dlsym) and registers the OkHttp-backed
     * [MapLibreHttp] start/cancel handlers with mbgl-core. Idempotent (native
     * std::call_once). Must run before the first map is created — the Dart controller
     * calls it via the registrar channel ahead of `MapLibreCoreMap.create`.
     */
    external fun nativeSetHttpHandler()

    /** Called by [MapLibreHttp] (on an OkHttp thread) to deliver a completed request. */
    external fun nativeHttpRespond(
        requestId: Long,
        status: Int,
        body: ByteArray?,
        etag: String?,
    )
}
