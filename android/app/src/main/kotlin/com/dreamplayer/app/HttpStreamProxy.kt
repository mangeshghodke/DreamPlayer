package com.dreamplayer.app

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread

/**
 * Loopback HTTP bridge for the libmpv engine: serves a remote `http(s)` URL
 * over `http://127.0.0.1:<port>/<token>` so mpv can read it.
 *
 * ## WHY this exists
 *
 * The Media3 engine plays http(s) URLs that the libmpv engine refuses to open
 * ("Failed to open https://…"). Both engines end up in the same libavformat
 * world, but the **network stacks are different**:
 *
 *  * Media3 → `OkHttpDataSource` → **OkHttp + Conscrypt** (Android's TLS),
 *    `User-Agent: okhttp/4.x`.
 *  * libmpv → **ffmpeg's own http protocol** → the bundled **mbedtls**, with
 *    ffmpeg's default `User-Agent: Lavf/63.1.100`.
 *
 * CDNs in front of private trackers (the reported case was a Cloudflare-fronted
 * host with a client-bound `?selection=` token) routinely refuse one of those
 * two. `Lavf/…` is on a lot of blocklists, and a token bound to the client's
 * TLS fingerprint is rejected by mbedtls even though the identical URL is
 * accepted over Conscrypt.
 *
 * This bridge removes the difference: the bytes are fetched with **the same
 * OkHttp client the Media3 engine uses** (same TLS stack, same default
 * User-Agent, same extra headers from `VideoItem.httpHeaders`), and mpv reads
 * plain HTTP from loopback. Whatever the CDN accepted for Media3 is accepted
 * here, so the mpv engine can play the same URL.
 *
 * ## Shape
 *
 * Android ships no `com.sun.net.httpserver`, so this is the same hand-rolled
 * HTTP/1.1 server as [SmbHttpProxy]: a daemon `ServerSocket` accept loop plus
 * one daemon thread per connection. GET/HEAD are supported, the client's
 * `Range` header is forwarded upstream, and the upstream status line +
 * range/length headers are mirrored verbatim so mpv's demuxer sees exactly
 * what the origin said (206 + `Content-Range` for a ranged read, 200 for a
 * plain one). The body is streamed through — never buffered whole — and the
 * response is framed with `Content-Length` when the origin gave one, or with
 * chunked encoding when it did not.
 */
object HttpStreamProxy {

    const val CHANNEL = "dreamplayer/httpproxy"

    private class Handle(
        val token: String,
        val url: String,
        val headers: Map<String, String>,
        val allowSelfSigned: Boolean,
    ) {
        /** Set when the bridge is torn down; streaming loops check it and abort. */
        @Volatile var closed: Boolean = false

        /** The in-flight upstream call, so [stop] can cancel it immediately. */
        @Volatile var call: Call? = null
    }

    private val handles = hashMapOf<String, Handle>()
    private var server: ServerSocket? = null
    @Volatile private var running = false
    private var port = -1

    /** Socket write chunk (the HTTP-side write size). */
    private const val WRITE_CHUNK = 256 * 1024

    /**
     * Same defaults as the Media3 path, except for a more forgiving read
     * timeout (a video stream can legitimately pause between chunks).
     */
    private val standardClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()
    }

    /** Trust-all variant for self-signed WebDAV servers (`allowSelfSigned`). */
    private val permissiveClient: OkHttpClient by lazy {
        val trustAll = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(null, arrayOf(trustAll), SecureRandom())
        OkHttpClient.Builder()
            .sslSocketFactory(sslContext.socketFactory, trustAll)
            .hostnameVerifier { _, _ -> true }
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()
    }

    /** Registers the `dreamplayer/httpproxy` method channel. */
    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "Missing url", null)
                        return@setMethodCallHandler
                    }
                    val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                    val allowSelfSigned = call.argument<Boolean>("allowSelfSigned") ?: false
                    val main = Handler(Looper.getMainLooper())
                    thread(isDaemon = true, name = "http-proxy-open") {
                        val bridged = start(url, headers, allowSelfSigned)
                        main.post {
                            if (bridged == null) {
                                result.error(
                                    "http_proxy_error",
                                    "Could not start the local media bridge",
                                    null,
                                )
                            } else {
                                result.success(bridged)
                            }
                        }
                    }
                }
                "stop" -> {
                    val token = call.argument<String>("token")
                    if (!token.isNullOrEmpty()) stop(token)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Starts serving [url] and returns the loopback URL mpv should open, or
     * null when the local server could not be started.
     */
    @Synchronized
    private fun start(
        url: String,
        headers: Map<String, String>,
        allowSelfSigned: Boolean,
    ): String? {
        if (!ensureStarted()) return null
        val token = UUID.randomUUID().toString().replace("-", "")
        handles[token] = Handle(token, url, headers, allowSelfSigned)
        val bridged = "http://127.0.0.1:$port/$token"
        Log.i(TAG, "serving $url at $bridged (headers=${headers.keys})")
        return bridged
    }

    @Synchronized
    private fun stop(token: String) {
        val handle = handles.remove(token) ?: return
        handle.closed = true
        try {
            handle.call?.cancel()
        } catch (_: Exception) {
        }
    }

    /** Tears every bridge down (player disposed / source changed). */
    @Synchronized
    fun stopAll() {
        for (h in handles.values) {
            h.closed = true
            try {
                h.call?.cancel()
            } catch (_: Exception) {
            }
        }
        handles.clear()
    }

    @Synchronized
    private fun ensureStarted(): Boolean {
        if (running) return true
        return try {
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(java.net.InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 16)
            server = ss
            port = ss.localPort
            running = true
            thread(isDaemon = true, name = "http-proxy-accept") {
                while (running) {
                    try {
                        val sock = ss.accept()
                        thread(isDaemon = true, name = "http-proxy-conn") { serve(sock) }
                    } catch (_: IOException) {
                        break
                    }
                }
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "could not start the local bridge: $e")
            running = false
            false
        }
    }

    private fun serve(sock: Socket) {
        try {
            sock.soTimeout = 180_000
            val input = BufferedInputStream(sock.getInputStream(), 8192)
            val requestLine = readLine(input)
            if (requestLine == null || requestLine.isEmpty()) return
            val parts = requestLine.split(" ")
            if (parts.size < 2) return
            val method = parts[0].uppercase()
            val target = parts[1]
            if (method != "GET" && method != "HEAD") {
                respondStatus(sock, 405, "Method Not Allowed")
                return
            }
            val clientHeaders = HashMap<String, String>()
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                val colon = line.indexOf(':')
                if (colon <= 0) continue
                clientHeaders[line.substring(0, colon).trim().lowercase()] =
                    line.substring(colon + 1).trim()
            }
            val token = target.trim('/').substringBefore('?')
            val handle = synchronized(handles) { handles[token] }
            if (handle == null) {
                respondStatus(sock, 404, "Not Found")
                return
            }
            val client = if (handle.allowSelfSigned) permissiveClient else standardClient
            val builder = Request.Builder().url(handle.url)
            for ((name, value) in handle.headers) {
                if (name.isBlank() || value.isBlank()) continue
                if (isHopByHop(name)) continue
                builder.header(name, value)
            }
            // The client's Range is end-to-end: forward it so the origin can
            // answer 206 + Content-Range exactly like it would for Media3.
            clientHeaders["range"]?.let { builder.header("Range", it) }
            val call = client.newCall(builder.build())
            handle.call = call
            val response = try {
                call.execute()
            } catch (e: Exception) {
                Log.w(TAG, "upstream request failed for ${handle.url}: $e")
                respondStatus(sock, 502, "Bad Gateway")
                return
            }
            val body = response.body
            val contentLength = body?.contentLength() ?: -1L
            val out = sock.getOutputStream()
            val sb = StringBuilder(256)
            sb.append("HTTP/1.1 ").append(response.code).append(' ')
                .append(response.message.ifBlank { statusText(response.code) }).append("\r\n")
            response.header("Content-Type")?.let {
                sb.append("Content-Type: ").append(it).append("\r\n")
            }
            response.header("Accept-Ranges")?.let {
                sb.append("Accept-Ranges: ").append(it).append("\r\n")
            }
            response.header("Content-Range")?.let {
                sb.append("Content-Range: ").append(it).append("\r\n")
            }
            if (contentLength >= 0) {
                sb.append("Content-Length: ").append(contentLength).append("\r\n")
            } else {
                sb.append("Transfer-Encoding: chunked\r\n")
            }
            sb.append("Connection: close\r\n\r\n")
            out.write(sb.toString().toByteArray(Charsets.US_ASCII))
            out.flush()
            if (method == "HEAD") {
                response.close()
                return
            }
            if (body == null) {
                response.close()
                return
            }
            streamBody(out, body.byteStream(), contentLength >= 0, handle)
            response.close()
        } catch (_: Exception) {
            // Connection-level failures (the client closed early) are not errors.
        } finally {
            try {
                sock.close()
            } catch (_: IOException) {
            }
        }
    }

    /** Streams the upstream body to the client, chunk-framing when needed. */
    private fun streamBody(
        out: OutputStream,
        source: InputStream,
        chunked: Boolean,
        handle: Handle,
    ) {
        val buf = ByteArray(WRITE_CHUNK)
        try {
            while (true) {
                if (handle.closed) break
                val n = source.read(buf)
                if (n <= 0) break
                if (chunked) {
                    out.write(n.toString(16).toByteArray(Charsets.US_ASCII))
                    out.write("\r\n".toByteArray(Charsets.US_ASCII))
                    out.write(buf, 0, n)
                    out.write("\r\n".toByteArray(Charsets.US_ASCII))
                } else {
                    out.write(buf, 0, n)
                }
                out.flush()
            }
            if (chunked) {
                out.write("0\r\n\r\n".toByteArray(Charsets.US_ASCII))
                out.flush()
            }
        } finally {
            try {
                source.close()
            } catch (_: IOException) {
            }
        }
    }

    /** Hop-by-hop headers must not be forwarded upstream. */
    private fun isHopByHop(name: String): Boolean = when (name.lowercase()) {
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length",
        -> true
        else -> false
    }

    private fun statusText(code: Int): String = when (code) {
        200 -> "OK"
        206 -> "Partial Content"
        301 -> "Moved Permanently"
        302 -> "Found"
        304 -> "Not Modified"
        400 -> "Bad Request"
        401 -> "Unauthorized"
        403 -> "Forbidden"
        404 -> "Not Found"
        416 -> "Range Not Satisfiable"
        500 -> "Internal Server Error"
        502 -> "Bad Gateway"
        503 -> "Service Unavailable"
        else -> "Error"
    }

    private fun respondStatus(sock: Socket, code: Int, text: String) {
        try {
            val body = "HTTP/1.1 $code $text\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            val out = sock.getOutputStream()
            out.write(body.toByteArray(Charsets.US_ASCII))
            out.flush()
        } catch (_: IOException) {
        }
    }

    private fun readLine(input: InputStream): String? {
        val sb = StringBuilder(128)
        while (true) {
            val b = input.read()
            if (b < 0) return if (sb.isEmpty()) null else sb.toString()
            if (b == '\n'.code) break
            if (b != '\r'.code) sb.append(b.toChar())
        }
        return sb.toString()
    }

    private const val TAG = "HttpStreamProxy"
}
