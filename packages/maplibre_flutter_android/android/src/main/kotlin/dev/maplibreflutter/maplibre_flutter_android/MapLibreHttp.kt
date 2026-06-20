package dev.maplibreflutter.maplibre_flutter_android

import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/**
 * OkHttp backing for the experimental core-on-Android HTTP bridge (CLAUDE.md §3).
 *
 * mbgl-core's `HTTPFileSource` (in the core .so) calls [start]/[cancel] via JNI; this
 * runs the request on OkHttp (system TLS + trust store) and feeds the result back to
 * the core via [MapLibreCoreBridge.nativeHttpRespond]. Only used on the core path.
 */
internal object MapLibreHttp {
    private val client = OkHttpClient()
    private val calls = ConcurrentHashMap<Long, Call>()

    /** Called from native: GET [url], deliver the result under [requestId]. */
    @JvmStatic
    fun start(requestId: Long, url: String) {
        val request = Request.Builder()
            .url(url)
            .header("User-Agent", "maplibre_flutter (core POC)")
            .build()
        val call = client.newCall(request)
        calls[requestId] = call
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                calls.remove(requestId)
                if (call.isCanceled()) return
                MapLibreCoreBridge.nativeHttpRespond(requestId, -1, null, null)
            }

            override fun onResponse(call: Call, response: Response) {
                calls.remove(requestId)
                response.use {
                    val body = it.body?.bytes()
                    MapLibreCoreBridge.nativeHttpRespond(
                        requestId, it.code, body, it.header("ETag"),
                    )
                }
            }
        })
    }

    /** Called from native: abort the in-flight request for [requestId]. */
    @JvmStatic
    fun cancel(requestId: Long) {
        calls.remove(requestId)?.cancel()
    }
}
