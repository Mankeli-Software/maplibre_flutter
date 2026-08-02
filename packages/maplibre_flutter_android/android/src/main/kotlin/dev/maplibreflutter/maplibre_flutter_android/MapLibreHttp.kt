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

    /**
     * Called from native: GET [url], deliver the result under [requestId].
     *
     * [extraHeaders] is a newline-separated list of `Name: value` lines the
     * embedder scoped to this URL (see `MapLibreSettings.setHttpHeaders`), or
     * null. The native side has already rejected any name or value containing a
     * control character, so these are safe to splice in — but they are applied
     * with `addHeader`, not `header`, so a caller can legitimately set two
     * values for one name and so nothing here silently replaces the User-Agent.
     */
    @JvmStatic
    fun start(requestId: Long, url: String, extraHeaders: String?) {
        val builder = Request.Builder()
            .url(url)
            .header("User-Agent", "maplibre_flutter (core POC)")
        if (extraHeaders != null) {
            for (line in extraHeaders.split('\n')) {
                val split = line.indexOf(": ")
                if (split <= 0) continue
                builder.addHeader(line.substring(0, split), line.substring(split + 2))
            }
        }
        val request = builder.build()
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
