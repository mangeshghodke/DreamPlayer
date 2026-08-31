package com.dreamplayer.app

import android.content.Context
import android.util.Log
import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import jcifs.smb.SmbFile
import jcifs.smb.SmbRandomAccessFile
import kotlin.concurrent.thread
import kotlin.concurrent.withLock

/**
 * Minimal loopback HTTP server that exposes an in-app SMB file over HTTP with
 * byte-range support. Purpose: give the libmpv fallback engine a URL it can
 * read (`http://127.0.0.1:<port>/<token>`) when the source is the in-app SMB
 * stack — jcifs-ng only talks to Media3-native DataSources, and libmpv cannot
 * read `smb://` directly.
 *
 * Android ships no `com.sun.net.httpserver`, so this is a tiny hand-rolled
 * HTTP/1.1 server: a daemon `ServerSocket` accept loop + one daemon thread per
 * connection. It supports GET/HEAD + single `Range` (`bytes=start-end`,
 * `bytes=start-`, `bytes=-suffix`); every connection is closed after its
 * response. Reads are serialized per file via a [ReentrantLock] because
 * `SmbRandomAccessFile` is not thread-safe.
 */
object SmbHttpProxy {

    private data class Handle(
        val token: String,
        val serverId: String,
        val share: String,
        val path: String,
    ) {
        @Volatile var size: Long = -1
        /// Set when the session is torn down; in-flight [serve] loops check it
        /// and abort instead of streaming into a dead socket.
        @Volatile var closed: Boolean = false

        /// Idle `SmbRandomAccessFile`s ready for reuse. One handle per in-flight
        /// request (so no shared seek position), but finished handles are parked
        /// here instead of closed — opening an SMB file costs a tree-connect +
        /// create round-trip each time, and mpv's probe fires ~15 range requests
        /// back to back, so re-opening every time is what made startup slow.
        val idle = ArrayDeque<SmbRandomAccessFile>()
        val idleLock = ReentrantLock()
    }

    private const val MAX_IDLE = 4

    private val handles = hashMapOf<String, Handle>()
    private var server: ServerSocket? = null
    @Volatile private var running = false
    private var port = -1
    @Volatile private var appContext: Context? = null

    // jcifs-ng streaming reads are bound by the NAS's negotiated MaxReadSize
    // (snd/rcv/transaction buf, defaults 65535; larger requests get truncated or
    // rejected — see the "Lesson learned on-device" note). 1 MiB reads caused
    // mid-stream SmbRandomAccessFile.read failures that truncated the HTTP body
    // and surfaced in mpv as "http: Stream ends prematurely". 256 KiB is the
    // empirically-safe SMB read size (same cap the WebDAV/SFTP readers use).
    private const val CHUNK = 256 * 1024  // 256 KiB — safe SMB read size

    // No body cap — streaming is already chunked at CHUNK (256 KiB) so memory
    // is bounded regardless of response size.  The old 16 MB cap caused ffmpeg/
    /// mpv's HTTP demuxer to report "Stream ends prematurely at N, should be
    /// total" on every response: mpv reads Content-Range's total file size,
    /// receives only the capped subset, and treats the gap as a premature
    /// close.  Removing the cap lets the full requested range stream in one
    /// response; abandoned connections (user seeks mid-stream) are handled by
    /// the IOException catch on out.write, which breaks the loop and releases
    /// the handle.

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
    /// opened (bad credentials / not found / server not reachable — the same
    /// conditions the Media3 SMB path would surface).
    @Synchronized
    fun start(context: Context, serverId: String, share: String, path: String): String? {
        if (!ensureStarted(context)) return null
        val token = UUID.randomUUID().toString().replace("-", "")
        val handle = Handle(token, serverId, share, path)
        // Probe once so failures surface here as a clear "couldn't open"
        // instead of a cryptic 500 deep in mpv's probe. The probe handle is
        // PARKED for reuse (not closed) so mpv's very first range request
        // doesn't pay another tree-connect + create round-trip.
        val probe = try {
            openRaf(handle, context).also {
                handle.size = it.length()
            }
        } catch (e: Exception) {
            Log.w("SmbHttpProxy", "open failed serverId=$serverId share=$share path=$path: $e")
            null
        }
        if (probe == null) return null
        handle.idleLock.withLock { handle.idle.addLast(probe) }
        handles[token] = handle
        val url = "http://127.0.0.1:$port/$token"
        Log.i("SmbHttpProxy", "serving serverId=$serverId share=$share path=$path at $url size=${handle.size}")
        return url
    }

    @Synchronized
    fun stop(token: String) {
        val handle = handles.remove(token) ?: return
        handle.closed = true
        closeIdle(handle)
    }

    @Synchronized
    fun stopAll() {
        for (h in handles.values) {
            h.closed = true
            closeIdle(h)
        }
        handles.clear()
    }

    private fun closeIdle(handle: Handle) {
        handle.idleLock.withLock {
            while (handle.idle.isNotEmpty()) {
                try {
                    handle.idle.removeFirst().close()
                } catch (_: IOException) {
                }
            }
        }
    }

    /// Leases an `SmbRandomAccessFile` for one request: an idle handle when one
    /// is parked, otherwise a fresh open. Handles are NEVER shared between
    /// concurrent requests — ffmpeg's HTTP demuxer fires many overlapping range
    /// requests and a shared handle means each request's `seek()` clobbers the
    /// others mid-read (garbage bytes → decoder starvation → ANR).
    private fun leaseRaf(handle: Handle, context: Context): SmbRandomAccessFile {
        handle.idleLock.withLock {
            while (handle.idle.isNotEmpty()) {
                val raf = handle.idle.removeFirst()
                // A parked handle can have gone stale (NAS dropped the session).
                try {
                    raf.length()
                    return raf
                } catch (_: Exception) {
                    try {
                        raf.close()
                    } catch (_: IOException) {
                    }
                }
            }
        }
        return openRaf(handle, context)
    }

    /// Parks a finished handle for reuse, or closes it when the pool is full or
    /// the session is gone.
    private fun releaseRaf(handle: Handle, raf: SmbRandomAccessFile) {
        if (!handle.closed) {
            val parked = handle.idleLock.withLock {
                if (handle.idle.size < MAX_IDLE) {
                    handle.idle.addLast(raf)
                    true
                } else {
                    false
                }
            }
            if (parked) return
        }
        try {
            raf.close()
        } catch (_: IOException) {
        }
    }

    private fun openRaf(handle: Handle, context: Context): SmbRandomAccessFile {
        val creds = SmbStore.resolve(context, handle.serverId)
            ?: throw IOException("Unknown SMB server ${handle.serverId}")
        val base = "smb://${creds.host}:${creds.port}/${handle.share}"
        val url = if (handle.path.isEmpty()) base else "$base/${handle.path}"
        return SmbRandomAccessFile(SmbFile(url, creds.context()), "r")
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
            Log.i("SmbHttpProxy", "req $method $target range=$rangeHeader")
            val token = target.trim('/').substringBefore('?')
            val handle = synchronized(handles) { handles[token] }
            if (handle == null) {
                respondStatus(sock, "404 Not Found")
                return
            }
            val context = appContext ?: return
            // Lease a handle for this request — reused from the idle pool when
            // available, so mpv's burst of probe range requests doesn't pay an
            // SMB open per request.
            val raf = try {
                leaseRaf(handle, context)
            } catch (_: Exception) {
                respondStatus(sock, "404 Not Found")
                return
            }
            try {
                val toRelease = streamResponse(sock, handle, raf, method, rangeHeader, context)
                // A non-null return is the handle to park (usually the original
                // `raf`); null means a mid-stream swap already parked its own
                // fresh handle and closed the original, so nothing to release.
                if (toRelease != null) releaseRaf(handle, toRelease)
            } finally {
                // If a mid-stream SMB failure caused streamResponse to swap in a
                // fresh handle, the ORIGINAL `raf` was already closed inside the
                // swap and must NOT be parked (a closed handle in the idle pool
                // would poison the next lease). streamResponse handles that by
                // returning null — the finally below intentionally does nothing.
            }
        } catch (_: Exception) {
            // Connection-level failures (client closed early) are not errors.
        } finally {
            try {
                sock.close()
            } catch (_: IOException) {
            }
        }
    }

    /// Streams the requested byte range, returning the `SmbRandomAccessFile`
    /// the caller should release. On a persistent SMB read failure it swaps in a
    /// freshly-opened handle (which it closes/parked itself via [releaseRaf])
    /// and returns null so the caller parks nothing and skips the dead original.
    private fun streamResponse(
        sock: Socket,
        handle: Handle,
        raf: SmbRandomAccessFile,
        method: String,
        rangeHeader: String?,
        context: Context,
    ): SmbRandomAccessFile? {
        val total = handle.size
        var start: Long
        var end: Long
        var isRange = false
        if (rangeHeader != null) {
            val parsed = parseRange(rangeHeader, total)
            if (parsed == null) {
                respondStatus(sock, "416 Range Not Satisfiable")
                return raf
            }
            start = parsed.first
            end = parsed.second
            isRange = true
        } else {
            start = 0
            end = total - 1
        }
        if (total < 0) {
            respondStatus(sock, "404 Not Found")
            return raf
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
        val headerBytes = sb.toString().toByteArray(Charsets.US_ASCII)
        val out = sock.getOutputStream()
        out.write(headerBytes)
        out.flush()
        if (method == "HEAD") return raf
        raf.seek(start)
        var remaining = length
        // The handle we're actively reading through. Needs to be reassignable:
        // on a persistent SMB read failure we swap in a freshly-opened handle for
        // the same file and keep streaming, so a stale NAS session doesn't
        // truncate the HTTP body (which mpv reports as "http: Stream ends
        // prematurely" and kills playback).
        var active = raf
        val buf = ByteArray(CHUNK)
        while (remaining > 0) {
            if (handle.closed) break
            val want = minOf(remaining, CHUNK.toLong()).toInt()
            var n = 0
            // Retry a bounded number of recoverable reads. SmbRandomAccessFile
            // can transiently fail mid-stream (NAS session hiccup, read timeout);
            // returning -1 immediately would truncate the HTTP body while
            // Content-Length still promises full bytes -> mpv reports "http:
            // Stream ends prematurely" and playback dies.
            var failCount = 0
            while (n == 0 && failCount < 3) {
                n = try {
                    active.read(buf, 0, want)
                } catch (_: IOException) {
                    failCount++
                    -1
                }
                if (n == 0) failCount++
                if (n < 0) failCount++
            }
            if (n < 0) {
                // A persistent SMB read failure means the parked session went
                // stale. Open ONE fresh handle, re-seek to the current offset,
                // and continue through it — cheap compared to losing the whole
                // stream (mpv would then re-probe from scratch).
                val fresh = try {
                    val f = openRaf(handle, context)
                    f.seek(start + (length - remaining))
                    f
                } catch (_: Exception) {
                    null
                }
                if (fresh != null) {
                    try {
                        active.close()
                    } catch (_: IOException) {
                    }
                    active = fresh
                    continue
                }
                break
            }
            try {
                out.write(buf, 0, n)
            } catch (_: IOException) {
                break
            }
            remaining -= n.toLong()
        }
        try {
            out.flush()
        } catch (_: IOException) {
        }
        // Return the handle the caller should park: the (possibly swapped-in)
        // active one. If it differs from the original `raf`, park it here and
        // return null so the caller parks nothing — the original `raf` was
        // already closed during the swap and must not re-enter the idle pool.
        if (active !== raf) {
            releaseRaf(handle, active)
            return null
        }
        return raf
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
}