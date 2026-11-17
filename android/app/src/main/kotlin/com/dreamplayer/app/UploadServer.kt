package com.dreamplayer.app

import android.content.Context
import android.os.Environment
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.UUID
import kotlin.concurrent.thread

/**
 * WiFi upload server (competitor-gap #1): a tiny HTTP/1.1 server bound to
 * 0.0.0.0 on a LAN port, serving an upload page so a PC browser can push
 * videos straight into the phone. Uploaded files land in the app's download
 * directory, so the home "Downloaded" grid picks them up like any download.
 *
 * Android ships no `com.sun.net.httpserver`, so this is a hand-rolled server
 * in the same shape as [SmbHttpProxy]: a daemon `ServerSocket` accept loop +
 * one daemon thread per connection, every connection closed after its
 * response.
 *
 * HTTP contract (deliberately NOT multipart - a raw body with the file name
 * in the query is far simpler to stream correctly on both platforms):
 *   GET  /wifi-transfer/           → the upload page (HTML)
 *   GET  /wifi-transfer/health     → JSON status
 *   POST /wifi-transfer/upload?name=<urlencoded>  → raw body (Content-Length
 *                                required; 411 otherwise) streamed to a file
 *
 * The path is fixed and token-free (user request): the URL a user types is
 * `http://<ip>:<port>/wifi-transfer/`, the same shape as every other LAN
 * file-transfer feature. The server listens only while the user turned it on
 * and it is bound to the LAN, so the trade is usability over secrecy -
 * which the transfer screen says plainly.
 *
 * Per-transfer progress (`start` / `progress` / `done` / `failed`) is pushed
 * over [EVENT_CHANNEL] so the transfer screen can show live progress rows.
 */
class UploadServer(private val context: Context) {

    companion object {
        const val CHANNEL = "dreamplayer/upload"
        const val EVENT_CHANNEL = "dreamplayer/upload_events"

        /** The live server instance, so the notification Cancel can reach it. */
        @Volatile
        var instance: UploadServer? = null
            private set
        private const val TAG = "UploadServer"
        private const val PATH_PREFIX = "/wifi-transfer"
        private const val HEADER_CAP = 64 * 1024
        private const val IO_CHUNK = 256 * 1024
        private const val HEADER_TIMEOUT_MS = 30_000
        /**
         * The app's logo-only mark (no wordmark), 128px PNG, inlined so the
         * page needs no second request and no asset lookup.
         */
        private const val LOGO_BASE64 = "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"
private const val MAX_NAME_LEN = 120
        /** Basic-auth challenge header sent with every 401. */
        private const val WWW_AUTHENTICATE_BASIC =
            "WWW-Authenticate: Basic realm=\"DreamPlayer WiFi transfer\", charset=\"UTF-8\""
        /** Progress events per upload are throttled to this interval. */
        private const val PROGRESS_INTERVAL_MS = 500L
    }

    private var server: ServerSocket? = null
    @Volatile private var running = false
    @Volatile private var port = -1
    @Volatile private var destDir: File? = null
    @Volatile private var receivedCount = 0
    @Volatile private var receivedBytes = 0L

    /// Optional page credentials (set by the user in the app). When both are
    /// non-empty every request needs HTTP Basic auth, and the browser shows
    /// its own prompt - no cookies, no session state, no second page.
    @Volatile private var authUser = ""
    @Volatile private var authPass = ""

    /// Sockets with a request in flight, so Cancel from the notification can
    /// tear an active upload down instead of waiting for it to finish.
    private val activeSockets = java.util.Collections.synchronizedSet(
        java.util.Collections.newSetFromMap(java.util.HashMap<Socket, Boolean>()),
    )

    /// Files the user picked in-app to share with a PC ("send files to
    /// computer"). Key = display name, value = [uri, size]. The server
    /// streams them straight from the content URI on download - NO copy
    /// happens, so picking large videos never blocks the UI.
    private val sharedFiles = java.util.Collections.synchronizedMap(
        java.util.LinkedHashMap<String, Pair<String, Long>>(),
    )

    /// Identifies ONE server run. The page stores it with the batch it last
    /// saved, so a page reload never re-downloads files it already received
    /// (and a NEW server run, which restarts [sharedSeq] at 0, is not
    /// mistaken for the old one).
    private val runId: String = java.util.UUID.randomUUID().toString()

    /// Bumped on every [shareFiles] call - one "send" from the phone. The
    /// page uses it to tell a new batch from one it already received.
    @Volatile private var sharedSeq = 0

    /// Non-null while a Dart listener is attached. Every event must hop to
    /// the main thread: Flutter rejects EventChannel calls from any other.
    @Volatile private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    init {
        instance = this
        // The notification's Cancel button: stop the server and every
        // in-flight connection. The partial file dies with the socket error
        // path (saveUpload deletes it) and Dart sees "stopped".
        UploadForegroundService.cancelCallback = { cancelActive() }
    }

    fun configure(channel: MethodChannel, messenger: BinaryMessenger) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val port = (call.argument<Int>("port")) ?: 8080
                    val dest = call.argument<String>("destDir")
                    val user = call.argument<String>("username") ?: ""
                    val pass = call.argument<String>("password") ?: ""
                    result.success(start(port, dest, user, pass))
                }
                "stop" -> { stop(); result.success(null) }
                "status" -> result.success(statusMap())
                "shareFiles" -> {
                    val files = call.argument<List<Map<String, Any?>>>("files") ?: emptyList()
                    sharedFiles.clear()
                    for (f in files) {
                        val name = f["name"] as? String ?: continue
                        val uri = f["uri"] as? String ?: continue
                        val size = (f["size"] as? Number)?.toLong() ?: 0L
                        sharedFiles[name] = uri to size
                    }
                    // A new batch: the page starts receiving it on its next poll.
                    sharedSeq += 1
                    result.success(mapOf("ok" to true, "count" to sharedFiles.size))
                }
                "clearSharedFiles" -> {
                    sharedFiles.clear()
                    sharedSeq = 0
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
    }

    /// Pushes one progress event to Dart on the platform (main) thread.
    private fun emit(type: String, extra: Map<String, Any?> = emptyMap()) {
        val sink = eventSink ?: return
        val event = LinkedHashMap<String, Any?>(extra.size + 1)
        event["type"] = type
        event.putAll(extra)
        mainHandler.post {
            try {
                sink.success(event)
            } catch (_: Exception) {
                // Listener went away between the null check and the hop.
            }
        }
    }

    @Synchronized
    private fun start(
        requestedPort: Int,
        destDirPath: String?,
        username: String?,
        password: String?,
    ): Map<String, Any?> {
        stop()
        val dest = File(
            destDirPath?.takeIf { it.isNotBlank() }
                ?: File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    "DreamPlayer",
                ).absolutePath,
        )
        if (!dest.exists() && !dest.mkdirs()) {
            return mapOf("ok" to false, "error" to "cannot create ${dest.absolutePath}")
        }
        this.destDir = dest
        authUser = username?.trim() ?: ""
        authPass = password ?: ""

        // Try the requested port, then +1..+9, then an ephemeral port.
        var ss: ServerSocket? = null
        var boundPort = requestedPort
        for (offset in 0..10) {
            val candidate = if (offset == 10) 0 else requestedPort + offset
            try {
                val s = ServerSocket()
                s.reuseAddress = true
                s.bind(InetSocketAddress("0.0.0.0", candidate), 16)
                ss = s
                boundPort = s.localPort
                break
            } catch (_: IOException) {
                // port busy - try the next
            }
        }
        if (ss == null) {
            return mapOf("ok" to false, "error" to "no free port near $requestedPort")
        }
        server = ss
        port = boundPort
        running = true
        receivedCount = 0
        receivedBytes = 0L
        // A big transfer must survive the app going to the background, and
        // the user wants to watch it and be able to cancel from the
        // notification panel.
        UploadForegroundService.start(context)
        val sock = ss
        thread(isDaemon = true, name = "wifi-upload-accept") {
            while (running) {
                try {
                    val conn = sock.accept()
                    thread(isDaemon = true, name = "wifi-upload-conn") { serve(conn) }
                } catch (_: IOException) {
                    break
                }
            }
        }
        val urls = lanAddresses().map { "http://$it:$boundPort$PATH_PREFIX/" }
        Log.i(TAG, "upload server on port $boundPort -> $urls (dest=${dest.absolutePath})")
        emit("stopped") // a fresh start also clears any stale Dart-side rows
        return mapOf(
            "ok" to true,
            "port" to boundPort,
            "addresses" to lanAddresses(),
            "destDir" to dest.absolutePath,
        )
    }

    /**
     * Cancels the in-flight uploads (the page's Cancel button): the sockets
     * close, saveUpload's error path deletes the partial files, and Dart's
     * rows flip to failed. The server keeps listening for the next file.
     */
    @Synchronized
    fun cancelTransfers() {
        val sockets = activeSockets.toList()
        for (s in sockets) {
            try { s.close() } catch (_: IOException) {}
        }
        emit("cancelled")
    }

    /**
     * Stops the server AND every in-flight connection (the notification's
     * Cancel button). The half-written file is deleted by saveUpload's error
     * path, and Dart sees "stopped".
     */
    @Synchronized
    fun cancelActive() {
        stop()
        val sockets = activeSockets.toList()
        activeSockets.clear()
        for (s in sockets) {
            try { s.close() } catch (_: IOException) {}
        }
    }

    @Synchronized
    private fun stop() {
        running = false
        sharedFiles.clear()
        sharedSeq = 0
        try { server?.close() } catch (_: IOException) {}
        server = null
        port = -1
        // The transfer is over: drop the notification with it.
        UploadForegroundService.stop()
        emit("stopped")
    }

    private fun statusMap(): Map<String, Any?> = mapOf(
        "running" to running,
        "port" to port,
        "addresses" to lanAddresses(),
        "destDir" to (destDir?.absolutePath ?: ""),
        "receivedCount" to receivedCount,
        "receivedBytes" to receivedBytes,
        "sharedCount" to sharedFiles.size,
    )

    // ------------------------------------------------------------ HTTP ----

    private fun serve(sock: Socket) {
        activeSockets.add(sock)
        try {
            sock.soTimeout = HEADER_TIMEOUT_MS
            val input = sock.getInputStream()
            // The header read stops at CRLFCRLF, but a POST body usually
            // arrives IN THE SAME TCP segments as its headers. Those bytes
            // are part of the body, not the header - losing them made an
            // upload stall forever at the end (the socket had nothing left
            // to give) and the file come up short. Same contract as iOS.
            val parsed = readHead(input)
            if (parsed == null) { sock.close(); return }
            val text = String(parsed.header, StandardCharsets.ISO_8859_1)
            val requestLine = text.substringBefore("\r\n")
            val parts = requestLine.split(" ")
            if (parts.size < 2) { respond(sock, 400, "text/plain", "bad request".toByteArray()); sock.close(); return }
            val method = parts[0]
            val rawPath = parts[1]
            val headers = parseHeaders(text)
            val path = rawPath.substringBefore('?')
            val query = rawPath.substringAfter('?', "")

            // HTTP Basic auth gate: with credentials set, the browser shows its own
            // prompt and retries with an Authorization header. Nothing else
            // is served without it.
            if (!authorized(headers)) {
                val page = unauthorizedPageHtml().toByteArray(StandardCharsets.UTF_8)
                respond(
                    sock, 401, "text/html; charset=utf-8", page,
                    extraHeaders = listOf(WWW_AUTHENTICATE_BASIC),
                )
                return
            }

            when (path) {
                PATH_PREFIX, "$PATH_PREFIX/" -> {
                    if (method != "GET") { respond(sock, 405, "text/plain", "method".toByteArray()); sock.close(); return }
                    val page = pageHtml().toByteArray(StandardCharsets.UTF_8)
                    respond(sock, 200, "text/html; charset=utf-8", page, extraHeaders = listOf("Cache-Control: no-store"))
                }
                "$PATH_PREFIX/health" -> {
                    val body = statusMap().let {
                        org.json.JSONObject(it.filterValues { v -> v != null }).toString()
                    }.toByteArray(StandardCharsets.UTF_8)
                    respond(sock, 200, "application/json", body)
                }
                "$PATH_PREFIX/upload" -> {
                    if (method != "POST") { respond(sock, 405, "text/plain", "method".toByteArray()); sock.close(); return }
                    val length = headers["content-length"]?.toLongOrNull()
                    if (length == null || length < 0) {
                        respond(sock, 411, "text/plain", "Content-Length required".toByteArray())
                        sock.close(); return
                    }
                    val nameParam = query.split('&')
                        .firstOrNull { it.startsWith("name=") }
                        ?.substringAfter('=')
                    val rawName = nameParam?.let {
                        java.net.URLDecoder.decode(it, StandardCharsets.UTF_8.name())
                    } ?: "upload.bin"
                    val saved = saveUpload(input, parsed.bodyPrefix, length, rawName)
                    if (saved == null) {
                        respond(sock, 500, "application/json", """{"ok":false}""".toByteArray())
                    } else {
                        receivedCount++
                        receivedBytes += length
                        val body = """{"ok":true,"saved":"${saved.first}","size":$length}"""
                            .toByteArray(StandardCharsets.UTF_8)
                        respond(sock, 200, "application/json", body)
                    }
                }
                "$PATH_PREFIX/cancel" -> {
                    // The page's Cancel button: abort the in-flight uploads
                    // (partial files are deleted) but keep the server up for
                    // the next file.
                    if (method != "POST") { respond(sock, 405, "text/plain", "method".toByteArray()); sock.close(); return }
                    cancelTransfers()
                    respond(sock, 200, "application/json", """{"ok":true}""".toByteArray())
                }
                "$PATH_PREFIX/files" -> {
                    // JSON list of files shared FROM this device, for the page
                    // to receive automatically. No file I/O - just the
                    // registered list plus the batch identity the page needs
                    // to know whether it already saved this send.
                    if (method != "GET") { respond(sock, 405, "text/plain", "method".toByteArray()); sock.close(); return }
                    val arr = org.json.JSONArray()
                    synchronized(sharedFiles) {
                        for ((name, pair) in sharedFiles) {
                            arr.put(org.json.JSONObject().apply {
                                put("name", name)
                                put("size", pair.second)
                            })
                        }
                    }
                    val obj = org.json.JSONObject()
                    obj.put("runId", runId)
                    obj.put("seq", sharedSeq)
                    obj.put("files", arr)
                    respond(sock, 200, "application/json", obj.toString().toByteArray(StandardCharsets.UTF_8))
                }
                "$PATH_PREFIX/file" -> {
                    // Stream one shared file back OUT to the PC, straight from
                    // its content URI. Supports Range for resume/progress.
                    if (method != "GET") { respond(sock, 405, "text/plain", "method".toByteArray()); sock.close(); return }
                    val nameParam = query.split('&')
                        .firstOrNull { it.startsWith("name=") }
                        ?.substringAfter('=')
                    val rawName = nameParam?.let {
                        java.net.URLDecoder.decode(it, StandardCharsets.UTF_8.name())
                    } ?: ""
                    val pair = sharedFiles[rawName]
                    if (pair == null) {
                        respond(sock, 404, "text/plain", "not found".toByteArray())
                        sock.close(); return
                    }
                    streamSharedFile(sock, rawName, pair.first, pair.second, headers)
                }
                else -> respond(sock, 404, "text/plain", "not found".toByteArray())
            }
        } catch (e: Exception) {
            Log.w(TAG, "connection error: $e")
        } finally {
            activeSockets.remove(sock)
            try { sock.close() } catch (_: IOException) {}
        }
    }

    /// The header bytes (through CRLFCRLF inclusive) plus any BODY bytes that
/// /// arrived in the same read - a browser sends the two together.
    private class Head(val header: ByteArray, val bodyPrefix: ByteArray)

    /// Reads until CRLFCRLF (cap HEADER_CAP). Returns null on timeout/overflow.
    private fun readHead(input: InputStream): Head? {
        val buf = ByteArray(HEADER_CAP)
        var len = 0
        while (len < HEADER_CAP) {
            val n = try { input.read(buf, len, HEADER_CAP - len) } catch (_: IOException) { return null }
            if (n < 0) return null
            len += n
            // scan for \r\n\r\n
            var i = 0
            while (i + 3 < len) {
                if (buf[i] == 13.toByte() && buf[i + 1] == 10.toByte() &&
                    buf[i + 2] == 13.toByte() && buf[i + 3] == 10.toByte()) {
                    return Head(
                        buf.copyOf(i + 4),
                        if (i + 4 < len) buf.copyOfRange(i + 4, len) else ByteArray(0),
                    )
                }
                i++
            }
        }
        return null
    }

    private fun parseHeaders(head: String): Map<String, String> {
        val map = HashMap<String, String>()
        for (line in head.split("\r\n").drop(1)) {
            val idx = line.indexOf(':')
            if (idx > 0) map[line.substring(0, idx).trim().lowercase()] =
                line.substring(idx + 1).trim()
        }
        return map
    }

    /// HTTP Basic check against the credentials the user set in the app.
    /// Both credentials empty = open access (the toggle is the guard).
    private fun authorized(headers: Map<String, String>): Boolean {
        if (authUser.isEmpty() || authPass.isEmpty()) return true
        val header = headers["authorization"] ?: return false
        if (!header.startsWith("Basic ", ignoreCase = true)) return false
        val decoded = try {
            String(
                android.util.Base64.decode(header.substring(6).trim(), android.util.Base64.DEFAULT),
                StandardCharsets.UTF_8,
            )
        } catch (_: IllegalArgumentException) {
            return false
        }
        val sep = decoded.indexOf(':')
        if (sep < 0) return false
        return decoded.substring(0, sep) == authUser && decoded.substring(sep + 1) == authPass
    }

    /// Streams a shared file (registered by the user in-app) from its
    /// content/file URI to the PC browser. Supports HTTP Range so the
    /// browser can resume a partial download. Runs on the connection
    /// thread - never touches the UI thread.
    private fun streamSharedFile(
        sock: Socket,
        name: String,
        uriString: String,
        size: Long,
        headers: Map<String, String>,
    ) {
        val uri = android.net.Uri.parse(uriString)
        val input = when (uri.scheme) {
            null, "file" -> java.io.File(uri.path ?: uriString).inputStream()
            else -> context.contentResolver.openInputStream(uri)
        }
        if (input == null) {
            respond(sock, 404, "text/plain", "file unreadable".toByteArray())
            sock.close(); return
        }
        val rangeHeader = headers["range"]
        var start = 0L
        var end = size - 1
        var partial = false
        if (rangeHeader != null && rangeHeader.startsWith("bytes=")) {
            val spec = rangeHeader.substring(6).split('-')
            start = spec.getOrNull(0)?.toLongOrNull() ?: 0L
            if (spec.size > 1 && spec[1].isNotEmpty()) {
                end = spec[1].toLongOrNull() ?: (size - 1)
            }
            if (size <= 0) { end = -1 }
            partial = true
        }
        val length = if (end >= start && end >= 0) end - start + 1 else size - start
        val mime = guessMime(name)
        val head = buildString {
            if (partial) {
                append("HTTP/1.1 206 Partial Content\r\n")
                append("Content-Range: bytes $start-${if (end >= 0) end else size - 1}/${if (size > 0) size else "*"}\r\n")
            } else {
                append("HTTP/1.1 200 OK\r\n")
            }
            append("Content-Type: $mime\r\n")
            append("Content-Length: $length\r\n")
            append("Accept-Ranges: bytes\r\n")
            append("Content-Disposition: attachment; filename=\"${name.replace("\"", "_")}\"\r\n")
            append("Connection: close\r\n\r\n")
        }.toByteArray(StandardCharsets.ISO_8859_1)
        val out = sock.getOutputStream()
        out.write(head)
        // Skip to start
        if (start > 0) input.skip(start)
        val buf = ByteArray(IO_CHUNK)
        var remaining = length
        try {
            while (remaining > 0) {
                val n = input.read(buf, 0, minOf(IO_CHUNK.toLong(), remaining).toInt())
                if (n < 0) break
                out.write(buf, 0, n)
                remaining -= n
            }
            out.flush()
        } catch (_: IOException) {
            // PC disconnected mid-download - nothing to clean up
        } finally {
            try { input.close() } catch (_: IOException) {}
        }
    }

    private fun guessMime(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "mkv" -> "video/x-matroska"
            "mp4", "m4v" -> "video/mp4"
            "avi" -> "video/x-msvideo"
            "webm" -> "video/webm"
            "ts", "m2ts", "mts" -> "video/mp2t"
            "mov" -> "video/quicktime"
            "wmv" -> "video/x-ms-wmv"
            "flv" -> "video/x-flv"
            "mpg", "mpeg", "vob" -> "video/mpeg"
            "3gp" -> "video/3gpp"
            "ogv" -> "video/ogg"
            "srt" -> "application/x-subrip"
            "ass", "ssa" -> "text/plain"
            "vtt" -> "text/vtt"
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "mp3" -> "audio/mpeg"
            "flac" -> "audio/flac"
            "zip" -> "application/zip"
            else -> "application/octet-stream"
        }
    }

    private fun respond(
        sock: Socket,
        code: Int,
        contentType: String,
        body: ByteArray,
        extraHeaders: List<String> = emptyList(),
    ) {
        val reason = when (code) {
            200 -> "OK"; 400 -> "Bad Request"; 401 -> "Unauthorized"; 404 -> "Not Found"
            405 -> "Method Not Allowed"; 411 -> "Length Required"; 500 -> "Server Error"
            else -> "OK"
        }
        val head = buildString {
            append("HTTP/1.1 $code $reason\r\n")
            append("Content-Type: $contentType\r\n")
            append("Content-Length: ${body.size}\r\n")
            append("Connection: close\r\n")
            for (h in extraHeaders) append("$h\r\n")
            append("\r\n")
        }.toByteArray(StandardCharsets.ISO_8859_1)
        val out = sock.getOutputStream()
        out.write(head)
        out.write(body)
        out.flush()
    }

    /// Streams [length] bytes of [input] into a sanitized, deduped file in the
    /// destination directory. Returns (savedName, file) or null on failure.
    /// Emits start/progress/done/failed events for the transfer screen.
    private fun saveUpload(
        input: InputStream,
        bodyPrefix: ByteArray,
        length: Long,
        rawName: String,
    ): Pair<String, File>? {
        val dest = destDir ?: return null
        val name = sanitizeName(rawName)
        val existing = dest.listFiles()?.map { it.name }?.toHashSet() ?: hashSetOf()
        val finalName = dedupe(name, existing)
        val file = File(dest, finalName)
        val id = UUID.randomUUID().toString()
        emit("start", mapOf("id" to id, "name" to finalName, "total" to length))
        // Bytes that already arrived with the header count as received.
        var received = bodyPrefix.size.toLong()
        UploadForegroundService.update(finalName, received, length)
        var lastEmit = 0L
        try {
            FileOutputStream(file).use { out ->
                if (bodyPrefix.isNotEmpty()) out.write(bodyPrefix)
                val buf = ByteArray(IO_CHUNK)
                var remaining = length - received
                while (remaining > 0) {
                    val n = input.read(buf, 0, minOf(IO_CHUNK.toLong(), remaining).toInt())
                    if (n < 0) throw IOException("client closed early")
                    out.write(buf, 0, n)
                    remaining -= n
                    received += n
                    val now = System.currentTimeMillis()
                    if (now - lastEmit >= PROGRESS_INTERVAL_MS) {
                        lastEmit = now
                        emit("progress", mapOf("id" to id, "received" to received))
                        UploadForegroundService.update(finalName, received, length)
                    }
                }
            }
            Log.i(TAG, "received $finalName ($length bytes)")
            emit("progress", mapOf("id" to id, "received" to received))
            UploadForegroundService.update(null, 0, -1)
            emit("done", mapOf(
                "id" to id,
                "received" to received,
                "path" to file.absolutePath,
            ))
            return finalName to file
        } catch (e: Exception) {
            Log.w(TAG, "upload failed: $e")
            file.delete()
            emit("failed", mapOf("id" to id, "error" to (e.message ?: "failed")))
            UploadForegroundService.update(null, 0, -1)
            return null
        }
    }

    // --------------------------------------------------------- helpers ----

    private fun sanitizeName(raw: String): String {
        var name = raw
        val cut = maxOf(name.lastIndexOf('/'), name.lastIndexOf('\\'))
        if (cut >= 0) name = name.substring(cut + 1)
        name = name.replace(Regex("[\\x00-\\x1f\\x7f]"), "").trim()
        if (name.isEmpty() || name == "." || name == "..") return "upload.bin"
        val base = name.split('.').first().uppercase()
        if (base in setOf("CON", "PRN", "AUX", "NUL") ||
            Regex("^COM[1-9]$").matches(base) || Regex("^LPT[1-9]$").matches(base)) {
            name = "_$name"
        }
        if (name.length > MAX_NAME_LEN) {
            val dot = name.lastIndexOf('.')
            val ext = if (dot > 0 && name.length - dot <= 9) name.substring(dot) else ""
            name = name.substring(0, MAX_NAME_LEN - ext.length) + ext
        }
        return name
    }

    private fun dedupe(name: String, existing: Set<String>): String {
        if (name !in existing) return name
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (i in 2..9999) {
            val candidate = "$stem ($i)$ext"
            if (candidate !in existing) return candidate
        }
        return "$stem (${System.currentTimeMillis()})$ext"
    }

    private fun lanAddresses(): List<String> {
        val out = mutableListOf<String>()
        try {
            val ifs = NetworkInterface.getNetworkInterfaces() ?: return out
            for (ifn in ifs) {
                if (!ifn.isUp || ifn.isLoopback) continue
                for (addr in ifn.inetAddresses) {
                    if (addr is Inet4Address && addr.isSiteLocalAddress) {
                        addr.hostAddress?.let { out.add(it) }
                    }
                }
            }
        } catch (_: Exception) {
        }
        return out.distinct()
    }

    // ------------------------------------------------------------- page ---

/// Themed page behind a failed/dismissed Basic-auth prompt: the browser
    /// shows its own dialog first (that is the login), this is what remains
    /// visible if the user cancels it.
    private fun unauthorizedPageHtml(): String {
        return """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DreamPlayer - Sign in</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; min-height: 100vh; background: #0e0e11; color: #e8e8ec;
         font-family: system-ui, -apple-system, sans-serif;
         display: flex; align-items: center; justify-content: center; padding: 24px; }
  .card { width: min(420px, 100%); background: #17171d; border: 1px solid #26262e;
          border-radius: 18px; padding: 28px 22px; text-align: center; }
  .card img { display: block; width: 52px; height: 52px; border-radius: 14px; margin: 0 auto 16px; }
  h1 { font-size: 19px; margin: 0 0 6px; }
  p { margin: 0; font-size: 13px; color: #9a9aa5; line-height: 1.5; }
</style>
</head>
<body>
  <div class="card">
    <img src="data:image/png;base64,$LOGO_BASE64" alt="DreamPlayer">
    <h1>Sign in required</h1>
    <p>DreamPlayer's WiFi file transfer is protected. Enter the username and
       password you set in the app.</p>
  </div>
</body>
</html>
""".trimIndent()
    }

    private fun pageHtml(): String {
        val port = port
        val addr = lanAddresses().firstOrNull() ?: "localhost"
        // Embed credentials in download URLs so external download managers
        // (which don't carry the browser's Basic-auth cache) still authenticate.
        // Anyone who loaded this page already knows them.
        val authInfo = if (authUser.isNotEmpty() && authPass.isNotEmpty()) {
            "${java.net.URLEncoder.encode(authUser, "UTF-8")}:${java.net.URLEncoder.encode(authPass, "UTF-8")}@"
        } else ""
        return """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DreamPlayer - WiFi file transfer</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; background: #0e0e11; color: #e8e8ec;
         font-family: system-ui, -apple-system, sans-serif; }
  .page { width: min(620px, 100%); margin: 0 auto; padding: 40px 20px 56px; }
  header { display: flex; align-items: center; gap: 14px; margin-bottom: 22px; }
  .logo { flex: none; }
  .logo img { display: block; width: 46px; height: 46px; border-radius: 13px; }
  h1 { font-size: 20px; margin: 0; letter-spacing: -0.01em; }
  header p { margin: 2px 0 0; font-size: 13px; color: #9a9aa5; }
  .card { background: #17171d; border: 1px solid #26262e; border-radius: 18px; padding: 22px; }
  .addr-label { margin: 0 0 6px; font-size: 11px; letter-spacing: 0.08em;
                text-transform: uppercase; color: #9a9aa5; }
  .addr { margin: 0 0 18px; font-size: 15px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          color: #e8e8ec; word-break: break-all; }
  .drop { display: block; border: 2px dashed #4b3e76; border-radius: 14px; padding: 30px 18px;
          text-align: center; cursor: pointer; transition: border-color .15s, background .15s; }
  .drop:hover, .drop.over { border-color: #7c4dff; background: rgba(124, 77, 255, 0.07); }
  .drop .icon { font-size: 26px; line-height: 1; }
  .drop .title { margin-top: 10px; font-size: 15px; font-weight: 600; }
  .drop .hint { margin-top: 3px; font-size: 13px; color: #9a9aa5; }
  input[type=file] { display: none; }
  ul { list-style: none; padding: 0; margin: 18px 0 0; }
  ul:empty { margin: 0; }
  li { background: #1e1e26; border-radius: 11px; padding: 11px 13px; margin-bottom: 8px; }
  li:last-child { margin-bottom: 0; }
  li .row { display: flex; align-items: baseline; gap: 12px; }
  li .nm { flex: 1; min-width: 0; font-size: 14px; overflow: hidden;
           text-overflow: ellipsis; white-space: nowrap; }
  li .sz { flex: none; font-size: 12px; color: #9a9aa5; font-variant-numeric: tabular-nums; }
  li .bar { height: 6px; border-radius: 3px; background: #26262e; margin-top: 9px; overflow: hidden; }
  li .bar > div { height: 100%; width: 0%; background: #7c4dff; border-radius: 3px;
                  transition: width .15s; }
  li.done .bar > div { background: #7ee2a8; }
  li.done .nm { color: #7ee2a8; }
  li.err .nm { color: #ff8a80; }
  .actions { display: flex; gap: 8px; margin-top: 16px; align-items: stretch; }
  .actions button { flex: 1 1 0; min-width: 0; padding: 10px 14px; border-radius: 11px;
                    border: 1px solid #3a3a46; background: #1e1e26; color: #e8e8ec;
                    font: inherit; font-size: 13px; cursor: pointer; transition: background .15s, color .15s; }
  .actions button:hover { background: #2a2a33; color: #fff; }
  .actions .cancel { color: #ff8a80; border-color: #3a2a2a; }
  .actions .cancel:hover { background: #3a2a2a; color: #ffb3b3; border-color: #ff8a80; }
  .actions .clear { color: #9a9aa5; border-color: #3a3a46; }
  .actions .clear:hover { color: #e8e8ec; border-color: #666; }
  .recvdir { width: 100%; margin: 4px 0 12px; padding: 11px 14px; border-radius: 11px;
             border: 1px solid #7c4dff; background: #241d3d; color: #e8e8ec;
             font: inherit; font-size: 13px; font-weight: 600; cursor: pointer; }
  .recvdir:hover { background: #2e2650; color: #fff; }
  .foot { margin: 18px 0 0; font-size: 12px; line-height: 1.5; color: #6a6a75; text-align: center; }
</style>
</head>
<body>
<div class="page">
  <header>
    <div class="logo"><img src="data:image/png;base64,$LOGO_BASE64" alt="DreamPlayer"></div>
    <div>
      <h1>DreamPlayer</h1>
      <p>WiFi file transfer</p>
    </div>
  </header>
  <div class="card">
    <p class="addr-label" style="display:flex;align-items:center;gap:8px;">
      <span style="width:8px;height:8px;border-radius:50%;background:#7ee2a8;display:inline-block;"></span>
      Online on port <span style="font-weight:600;">$port</span>
    </p>
    <p class="addr" id="addr" style="margin:10px 0;">http://$addr:$port$PATH_PREFIX/</p>
    <label class="drop" id="drop">
      <div class="icon">&#8593;</div>
      <div class="title">Click to choose videos</div>
      <div class="hint">or drop them here</div>
      <input type="file" id="files" multiple accept="video/*,.mkv,.mp4,.avi,.ts,.m2ts,.webm,.wmv,.flv,.mpg,.mpeg,.vob,.mov,.m4v,.3gp,.ogv,.rmvb,.divx">
    </label>
    <ul id="list"></ul>
    <div class="actions">
      <button class="cancel" id="cancel" type="button">&#10006; Cancel transfers</button>
      <button class="clear" id="clear" type="button">&#128465; Clear list</button>
    </div>
  </div>
  <div class="card" id="deviceFilesCard" style="margin-top:16px;">
    <p class="addr-label" style="margin:0 0 10px;">&#8595; Receive from your phone</p>
    <p class="hint" id="recvStatus">Waiting for files. Tap Send files on your phone.</p>
    <button class="recvdir" id="recvDir" type="button" style="display:none;">Choose folder to save into</button>
    <ul id="deviceFiles"></ul>
  </div>
  <p class="foot">Files you send from the phone arrive here automatically and are saved into the
     folder you pick. Files you upload on this page land in the phone's download folder and
     appear in DreamPlayer. The page is reachable while the transfer service is on in the app,
     even when the screen is locked.</p>
</div>
<script>
(function () {
  var drop = document.getElementById('drop');
  var input = document.getElementById('files');
  var list = document.getElementById('list');
  var addrEl = document.getElementById('addr');
  var cancelBtn = document.getElementById('cancel');
  var clearBtn = document.getElementById('clear');
  var deviceFilesCard = document.getElementById('deviceFilesCard');
  var deviceFilesList = document.getElementById('deviceFiles');
  // Refresh the address from the server's own view of the LAN (handles a
  // Wi-Fi change between page render and open)
  fetch('$PATH_PREFIX/health', {credentials: 'include'}).then(function (r) { return r.json(); }).then(function (s) {
    if (s.addresses && s.addresses.length) {
      addrEl.textContent = 'http://' + s.addresses[0] + ':' + s.port + '$PATH_PREFIX/';
    }
  }).catch(function () {});

  // Receive station: the phone PUSHES to this page - there is nothing to
  // click here. The moment the phone sends files or a folder, this page
  // starts saving them itself. The destination folder is chosen once
  // (Chromium's directory picker); other browsers fall back to their own
  // downloads folder, so a large video is always streamed to disk rather
  // than held in memory.
  var recvStatus = document.getElementById('recvStatus');
  var recvDirBtn = document.getElementById('recvDir');
  var fsSupported = typeof window.showDirectoryPicker === 'function';
  var destRoot = null;
  var destName = 'your Downloads folder';
  var receiving = false;
  var doneKey = null, doneSeq = -1;
  var announcedSeq = -1;
  try {
    var savedRecv = localStorage.getItem('dp.received');
    if (savedRecv) {
      var savedParts = savedRecv.split('|');
      doneKey = savedParts[0];
      doneSeq = parseInt(savedParts[1] || '-1', 10);
    }
  } catch (e) {}
  function fmtBytes(b) {
    if (!b) return '';
    var u = ['B','KB','MB','GB','TB'], i = 0;
    while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
    return b.toFixed(b < 10 && i > 0 ? 1 : 0) + ' ' + u[i];
  }
  function fileUrl(name) {
    return location.protocol + '//' + '$authInfo' + location.host + '$PATH_PREFIX/file?name=' + encodeURIComponent(name);
  }
  function setStatus(t) { recvStatus.textContent = t; }
  function renderRows(files) {
    deviceFilesList.innerHTML = '';
    files.forEach(function (f) {
      var li = document.createElement('li');
      var row = document.createElement('div');
      row.className = 'row';
      var nm = document.createElement('span');
      nm.className = 'nm';
      nm.textContent = f.name;
      var sz = document.createElement('span');
      sz.className = 'sz';
      sz.textContent = fmtBytes(f.size);
      row.appendChild(nm); row.appendChild(sz);
      var bar = document.createElement('div');
      bar.className = 'bar';
      bar.appendChild(document.createElement('div'));
      li.appendChild(row); li.appendChild(bar);
      deviceFilesList.appendChild(li);
    });
  }
  function markRow(i, cls) {
    var li = deviceFilesList.children[i];
    if (li) li.className = cls;
  }
  function setBar(i, frac) {
    var li = deviceFilesList.children[i];
    if (!li) return;
    var fill = li.querySelector('.bar > div');
    if (fill) fill.style.width = Math.round(frac * 100) + '%';
  }
  function loadDeviceFiles() {
    fetch('$PATH_PREFIX/files', {credentials: 'include'}).then(function (r) { return r.json(); }).then(function (data) {
      var files = (data && data.files) || [];
      deviceFilesCard.style.display = 'block';
      if (!files.length) {
        deviceFilesList.innerHTML = '';
        recvDirBtn.style.display = 'none';
        setStatus('Waiting for files. Tap Send files on your phone.');
        return;
      }
      if (receiving) return;
      var key = (data && data.runId) || '';
      var seq = (data && data.seq) || 0;
      if (key === doneKey && seq <= doneSeq) {
        // Say this ONCE. The 1s poll used to repeat it, which overwrote the
        // "Saved N files to <folder>" line the moment it appeared - so a
        // finished send read as "already saved", i.e. as nothing happening.
        if (announcedSeq !== seq) {
          announcedSeq = seq;
          setStatus(files.length + (files.length === 1 ? ' file' : ' files') + ' already saved');
        }
        return;
      }
      if (fsSupported && !destRoot) {
        recvDirBtn.style.display = '';
        recvDirBtn.textContent = 'Receive ' + files.length + (files.length === 1 ? ' file' : ' files') + ' into a folder';
        setStatus(files.length + (files.length === 1 ? ' file is' : ' files are') + ' ready');
        return;
      }
      receive(files, key, seq);
    }).catch(function () {});
  }
  async function saveWithFs(f, i) {
    try {
      var parts = f.name.split('/').filter(function (p) { return p.length > 0; });
      if (!parts.length) return false;
      var dir = destRoot;
      for (var j = 0; j < parts.length - 1; j++) {
        dir = await dir.getDirectoryHandle(parts[j], {create: true});
      }
      var fh = await dir.getFileHandle(parts[parts.length - 1], {create: true});
      var w = await fh.createWritable();
      var resp = await fetch(fileUrl(f.name), {credentials: 'include'});
      if (!resp.ok) throw new Error('http ' + resp.status);
      var total = parseInt(resp.headers.get('content-length') || '0', 10) || 0;
      var got = 0;
      var reader = resp.body.getReader();
      for (;;) {
        var r = await reader.read();
        if (r.done) break;
        got += r.value.length;
        setBar(i, total > 0 ? got / total : 0.5);
        await w.write(r.value);
      }
      await w.close();
      setBar(i, 1);
      return true;
    } catch (e) {
      return false;
    }
  }
  function saveWithDownload(f, i) {
    // No directory picker here (Firefox/Safari): let the browser's own
    // downloader take it, so a large video streams to disk instead of being
    // buffered in the page.
    var a = document.createElement('a');
    a.href = fileUrl(f.name);
    a.download = f.name.split('/').pop();
    a.style.display = 'none';
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { a.remove(); }, 60000);
    setBar(i, 1);
    return true;
  }
  async function receive(files, key, seq) {
    receiving = true;
    announcedSeq = seq;
    renderRows(files);
    recvDirBtn.style.display = 'none';
    var usedDownloader = false;
    for (var i = 0; i < files.length; i++) {
      var f = files[i];
      setStatus('Receiving ' + (i + 1) + ' of ' + files.length + ' - ' + f.name);
      var ok = destRoot ? await saveWithFs(f, i) : false;
      if (!ok) { ok = await Promise.resolve(saveWithDownload(f, i)); usedDownloader = true; }
      markRow(i, ok ? 'done' : 'err');
    }
    receiving = false;
    doneKey = key;
    doneSeq = seq;
    try { localStorage.setItem('dp.received', key + '|' + seq); } catch (e) {}
    setStatus('Saved ' + files.length + (files.length === 1 ? ' file' : ' files') + ' to ' +
      (usedDownloader ? 'your Downloads folder' : destName));
  }
  function chooseDest() {
    if (!fsSupported) return;
    window.showDirectoryPicker({mode: 'readwrite'}).then(function (h) {
      destRoot = h;
      destName = h.name;
      recvDirBtn.style.display = 'none';
      setStatus('Ready - receiving into "' + h.name + '"');
      loadDeviceFiles();
    }).catch(function () {});
  }
  recvDirBtn.addEventListener('click', chooseDest);
  loadDeviceFiles();
  setInterval(loadDeviceFiles, 1000);




  function prevent(e) { e.preventDefault(); e.stopPropagation(); }
  ['dragenter', 'dragover'].forEach(function (ev) {
    drop.addEventListener(ev, function (e) { prevent(e); drop.classList.add('over'); });
  });
  ['dragleave', 'drop'].forEach(function (ev) {
    drop.addEventListener(ev, function (e) { prevent(e); drop.classList.remove('over'); });
  });
  drop.addEventListener('drop', function (e) {
    if (e.dataTransfer && e.dataTransfer.files) uploadAll(e.dataTransfer.files);
  });
  input.addEventListener('change', function () { uploadAll(input.files); });

  function uploadAll(files) {
    Array.prototype.forEach.call(files, function (f) { uploadOne(f); });
  }

  function uploadOne(file) {
    var li = document.createElement('li');
    li.setAttribute('data-name', file.name);
    var nm = document.createElement('span');
    nm.className = 'nm';
    nm.textContent = file.name;
    var sz = document.createElement('span');
    sz.className = 'sz';
    var row = document.createElement('div');
    row.className = 'row';
    row.appendChild(nm);
    row.appendChild(sz);
    var bar = document.createElement('div');
    bar.className = 'bar';
    var fill = document.createElement('div');
    bar.appendChild(fill);
    li.appendChild(row);
    li.appendChild(bar);
    var xhr = new XMLHttpRequest();
    li._xhr = xhr;
    pending.push(xhr);
    list.appendChild(li);
    xhr.open('POST', '$PATH_PREFIX/upload?name=' + encodeURIComponent(file.name));
    xhr.upload.onprogress = function (e) {
      if (e.lengthComputable) {
        fill.style.width = (e.loaded / e.total * 100).toFixed(1) + '%';
        sz.textContent = (e.loaded / 1048576).toFixed(1) + ' / ' +
          (e.total / 1048576).toFixed(1) + ' MB';
      }
    };
    xhr.onload = function () {
      if (xhr.status === 200) {
        li.classList.add('done');
        nm.textContent = '\u2713 ' + file.name;
        fill.style.width = '100%';
        sz.textContent = 'Saved';
      } else {
        li.classList.add('err');
        nm.textContent = '\u2717 ' + file.name + ' (HTTP ' + xhr.status + ')';
      }
    };
    xhr.onerror = function () {
      li.classList.add('err');
      nm.textContent = '\u2717 ' + file.name + ' (network error)';
    };
    xhr.send(file);
  }

  var pending = [];
  function markCancelled() {
    Array.prototype.forEach.call(list.children, function (li) {
      if (li.classList.contains('done') || li.classList.contains('err')) return;
      li.classList.add('err');
      li.querySelector('.nm').textContent = '\u2717 ' + li.getAttribute('data-name') + ' (cancelled)';
      li.querySelector('.bar > div').style.width = '100%';
      var sz = li.querySelector('.sz');
      if (sz) sz.textContent = '';
    });
  }

  // Cancel transfers: abort in-flight XHRs and tell the server to drop its
  // side too (partial files are deleted). Keeps done/failed rows as-is.
  cancelBtn.addEventListener('click', function () {
    pending.forEach(function (x) { try { x.abort(); } catch (e) {} });
    pending = [];
    markCancelled();
    var r = new XMLHttpRequest();
    r.open('POST', '$PATH_PREFIX/cancel');
    r.send();
  });

  // Clear list: remove every row from the UI and abort anything still in
  // flight.
  clearBtn.addEventListener('click', function () {
    pending.forEach(function (x) { try { x.abort(); } catch (e) {} });
    pending = [];
    markCancelled();
    while (list.firstChild) list.removeChild(list.firstChild);
  });
})();
</script>
</body>
</html>
""".trimIndent()
    }
}
