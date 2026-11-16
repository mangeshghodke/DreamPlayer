package com.dreamplayer.app

import android.content.Context
import android.util.Log
import androidx.media3.common.C
import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Minimal loopback HTTP server that exposes an in-app SMB file over HTTP with
 * byte-range support. Purpose: give the libmpv fallback engine a URL it can
 * read (`http://127.0.0.1:<port>/<token>`) when the source is the in-app SMB
 * stack - libmpv cannot read `smb://` directly.
 *
 * Android ships no `com.sun.net.httpserver`, so this is a tiny hand-rolled
 * HTTP/1.1 server: a daemon `ServerSocket` accept loop + one daemon thread per
 * connection. It supports GET/HEAD + single `Range` (`bytes=start-end`,
 * `bytes=start-`, `bytes=-suffix`); every connection is closed after its
 * response.
 *
 * The bytes come from [SmbDataSource] - the SAME libsmb2-backed reader with
 * the parallel read-ahead ring that the Media3 engine uses. Two things matter
 * here and neither is optional:
 *
 *  1. **Read-ahead.** The proxy used to read from SMB and write to the socket
 *     in the same loop, so every SMB round-trip was exposed to mpv as a gap
 *     in the stream. With a ring buffer full of prefetched bytes the socket
 *     is fed continuously and mpv never has to wait on the NAS mid-playback
 *     (which it reports as "buffering").
 *  2. **One SMB session per request, no leaks.** libsmb2 contexts are not
 *     thread-safe, so each reader owns its sessions. A leaked session (a file
 *     handle left open makes the server refuse TREE_DISCONNECT with
 *     STATUS_BUSY, and libsmb2 then skips the socket close) eats one of the
 *     NAS's few per-user session slots - after a handful of them every new
 *     connect fails and playback dies with "one request served, then
 *     nothing". See [Smb2Native] / `smb2_jni.c`.
 */
object SmbHttpProxy {

    private data class Handle(
        val token: String,
        val serverId: String,
        val share: String,
        val path: String,
    ) {
        @Volatile var size: Long = -1
        /// Set when the session is torn down; in-flight streaming loops check it
        /// and abort instead of streaming into a dead socket.
        @Volatile var closed: Boolean = false
    }

    private val handles = hashMapOf<String, Handle>()
    private var server: ServerSocket? = null
    @Volatile private var running = false
    private var port = -1
    @Volatile private var appContext: Context? = null

    /// Per-connection read-ahead budget. These are CAPS: `BufferTuning` still
    /// lowers them on a low-RAM device (the Fire TV Stick has a 192 MB heap).
    private const val RING_CAP_BYTES = 24 * 1024 * 1024
    private const val PREFETCH_THREADS = 3

    /// Socket write chunk. This is the HTTP-side write size, not the SMB read
    /// size - the ring hands us whatever is buffered.
    private const val WRITE_CHUNK = 256 * 1024

    @Synchronized
    private fun ensureStarted(context: Context): Boolean {
        if (running) return true
        return try {
            appContext = context.applicationContext
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(java.net.InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 16)
            server = ss
            port = ss.localPort
            running = true
            thread(isDaemon = true, name = "smb-http-accept") {
                while (running) {
                    try {
                        val sock = ss.accept()
                        thread(isDaemon = true, name = "smb-http-conn") { serve(sock) }
                    } catch (_: IOException) {
                        break
                    }
                }
            }
            true
        } catch (_: Exception) {
            running = false
            false
        }
    }

    /// Starts serving [path] on [share] of server [serverId] and returns the
    /// HTTP URL a ffmpeg/mpv reader can open, or null when the file can't be
    /// opened (bad credentials / not found / server not reachable - the same
    /// conditions the Media3 SMB path would surface).
    @Synchronized
    fun start(context: Context, serverId: String, share: String, path: String): String? {
        if (!ensureStarted(context)) return null
        val token = UUID.randomUUID().toString().replace("-", "")
        val handle = Handle(token, serverId, share, path)
        val size = try {
            probeSize(context, serverId, share, path)
        } catch (e: Exception) {
            Log.w(TAG, "open failed serverId=$serverId share=$share path=$path: $e")
            null
        }
        if (size == null || size <= 0) return null
        handle.size = size
        handles[token] = handle
        val url = "http://127.0.0.1:$port/$token"
        Log.i(TAG, "serving serverId=$serverId share=$share path=$path at $url size=$size")
        return url
    }

    /// Reads the file size with a throw-away libsmb2 session. The session is
    /// closed properly (file handle first, then the tree) so the NAS sees the
    /// session go away instead of holding it until the process dies.
    private fun probeSize(
        context: Context,
        serverId: String,
        share: String,
        path: String,
    ): Long? {
        val creds = SmbStore.resolve(context, serverId)
            ?: throw IOException("Unknown SMB server $serverId")
        val user = if (creds.anonymous) "guest" else creds.username
        val pass = if (creds.anonymous) "" else creds.password
        val session = LibSmb2Session.open(
            creds.host, creds.port, user, pass, creds.domain, share,
        ) ?: throw IOException("libsmb2: could not connect to $share on ${creds.host}")
        try {
            val file = session.openFile(path)
                ?: throw IOException("libsmb2: could not open $path (${session.error()})")
            try {
                Log.i(TAG, "probe: maxReadSize=${file.maxReadSize}")
                return file.size
            } finally {
                file.close()
            }
        } finally {
            session.close()
        }
    }

    @Synchronized
    fun stop(token: String) {
        handles.remove(token)?.closed = true
    }

    @Synchronized
    fun stopAll() {
        for (h in handles.values) h.closed = true
        handles.clear()
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
                respondStatus(sock, "405 Method Not Allowed")
                return
            }
            var rangeHeader: String? = null
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                val lower = line.lowercase()
                if (lower.startsWith("range:")) {
                    rangeHeader = line.substringAfter(':').trim()
                }
            }
            Log.i(TAG, "req $method $target range=$rangeHeader")
            val token = target.trim('/').substringBefore('?')
            val handle = synchronized(handles) { handles[token] }
            if (handle == null) {
                respondStatus(sock, "404 Not Found")
                return
            }
            val context = appContext ?: return
            val total = handle.size
            var start: Long
            var end: Long
            var isRange = false
            if (rangeHeader != null) {
                val parsed = parseRange(rangeHeader, total)
                if (parsed == null) {
                    respondStatus(sock, "416 Range Not Satisfiable")
                    return
                }
                start = parsed.first
                end = parsed.second
                isRange = true
            } else {
                start = 0
                end = total - 1
            }
            val length = end - start + 1
            val status = if (isRange) "206 Partial Content" else "200 OK"
            val sb = StringBuilder(256)
            sb.append("HTTP/1.1 ").append(status).append("\r\n")
            sb.append("Content-Type: application/octet-stream\r\n")
            sb.append("Accept-Ranges: bytes\r\n")
            if (isRange) {
                sb.append("Content-Range: bytes ").append(start).append('-').append(end)
                    .append('/').append(total).append("\r\n")
            }
            sb.append("Content-Length: ").append(length).append("\r\n")
            sb.append("Connection: close\r\n")
            sb.append("\r\n")
            val out = sock.getOutputStream()
            out.write(sb.toString().toByteArray(Charsets.US_ASCII))
            out.flush()
            if (method == "HEAD") return
            streamBody(out, handle, context, start, length)
        } catch (_: Exception) {
            // Connection-level failures (client closed early) are not errors.
        } finally {
            try {
                sock.close()
            } catch (_: IOException) {
            }
        }
    }

    /// Streams [length] bytes starting at [start] out of the SMB file.
    ///
    /// The bytes come from [SmbDataSource], which prefetches in parallel into a
    /// ring buffer, so this loop only ever copies from memory into the socket
    /// - the NAS is never on the critical path of the write.
    private fun streamBody(
        out: java.io.OutputStream,
        handle: Handle,
        context: Context,
        start: Long,
        length: Long,
    ) {
        val source = SmbDataSource(context, RING_CAP_BYTES, PREFETCH_THREADS)
        try {
            source.openSmb(
                handle.serverId, handle.share, handle.path,
                start, C.LENGTH_UNSET.toLong(),
            )
            val buf = ByteArray(WRITE_CHUNK)
            var remaining = length
            val t0 = System.nanoTime()
            var sent = 0L
            while (remaining > 0) {
                if (handle.closed) break
                val want = minOf(remaining, buf.size.toLong()).toInt()
                val n = source.read(buf, 0, want)
                if (n <= 0) break
                out.write(buf, 0, n)
                sent += n
                remaining -= n
            }
            out.flush()
            val secs = (System.nanoTime() - t0) / 1_000_000_000.0
            if (secs > 0.05) {
                Log.i(
                    TAG,
                    String.format("streamed %d bytes in %.2fs (%.1f MB/s)", sent, secs, sent / 1048576.0 / secs),
                )
            }
        } finally {
            source.close()
        }
    }

    /// Returns (start, end) for a single byte range, or null when unsatisfiable.
    private fun parseRange(rangeHeader: String, total: Long): Pair<Long, Long>? {
        if (total <= 0) return null
        val spec = rangeHeader.removePrefix("bytes=").trim()
        if (!spec.matches(Regex("""\d*-\d*"""))) return null
        val dash = spec.indexOf('-')
        if (dash < 0) return null
        val sStr = spec.substring(0, dash).trim()
        val eStr = spec.substring(dash + 1).trim()
        val start: Long
        val end: Long
        if (sStr.isEmpty()) {
            // Suffix range: last N bytes.
            val n = eStr.toLongOrNull() ?: return null
            if (n <= 0) return null
            start = (total - n).coerceAtLeast(0)
            end = total - 1
        } else {
            start = sStr.toLongOrNull() ?: return null
            if (start >= total) return null
            end = if (eStr.isEmpty()) total - 1 else (eStr.toLongOrNull() ?: return null).coerceAtMost(total - 1)
        }
        if (end < start) return null
        return Pair(start, end)
    }

    private fun respondStatus(sock: Socket, status: String) {
        try {
            val body = "HTTP/1.1 $status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
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

    private const val TAG = "SmbHttpProxy"
}
