package com.dreamplayer.app

import android.app.ActivityManager
import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import jcifs.smb.SmbFile
import jcifs.smb.SmbRandomAccessFile
import java.io.IOException

/// ExoPlayer DataSource that streams a file straight off an SMB share
/// (no local download). URIs look like `smb://<serverId>/<share>/<path...>`;
/// the `<serverId>` resolves to the saved server + encrypted credentials in
/// [SmbStore], so passwords never appear in the URI or on the Dart side.
///
/// Parallel prefetch: [PREFETCH_THREADS] threads each with its own SMB handle
/// (separate TCP connection) read different regions of the file simultaneously.
/// SMB reads go into per-thread temp buffers; the ring-buffer write only
/// happens inside `ringLock` after verifying the ring epoch, preventing stale
/// writes from crashed/restarted threads from corrupting the buffer.
@UnstableApi
class SmbDataSourceFactory(private val context: Context) : DataSource.Factory {
    override fun createDataSource(): DataSource = SmbDataSource(context)
}

/// Heap-aware buffer sizing, shared by [SmbDataSource] (ring + prefetch temps)
/// and the Media3 [DefaultLoadControl] target in ExoPlayerView. The Fire TV
/// Stick 4K has a 192 MB app heap (`dalvik.vm.heapgrowthlimit=192m`); the old
/// fixed budget — 96 MiB ring + 4×4 MiB temps + a 96 MiB sample-queue target —
/// exhausted it mid-playback and surfaced as an "io unspecified" source error
/// (OOM inside DefaultAllocator.allocate). Scale everything by
/// ActivityManager.memoryClass; at the stick's ~1 MB/s SMB fill rate even a
/// 24 MiB ring is ~24 s of read-ahead.
internal object BufferTuning {
    var ringCapacityBytes: Int = 96 * 1024 * 1024
        private set
    var chunkBytes: Int = 4 * 1024 * 1024
        private set
    var prefetchThreads: Int = 4
        private set
    var media3TargetBytes: Int = 96 * 1024 * 1024
        private set

    @Volatile private var tuned = false

    fun tune(context: Context) {
        if (tuned) return
        synchronized(this) {
            if (tuned) return
            val am = context.applicationContext
                .getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            if (am != null) {
                val heapMb = am.memoryClass
                val lowRam = am.isLowRamDevice
                when {
                    lowRam || heapMb <= 192 -> {
                        ringCapacityBytes = 24 * 1024 * 1024
                        chunkBytes = 2 * 1024 * 1024
                        prefetchThreads = 3
                        media3TargetBytes = 24 * 1024 * 1024
                    }
                    heapMb < 256 -> {
                        ringCapacityBytes = 48 * 1024 * 1024
                        chunkBytes = 4 * 1024 * 1024
                        prefetchThreads = 4
                        media3TargetBytes = 48 * 1024 * 1024
                    }
                    else -> {
                        // Large-RAM devices: 96 MiB ring gives ~8s of read-ahead
                        // at 100 Mbps (12.5 MB/s) — enough for Wi-Fi NAS to
                        // sustain 4K streaming without stalling the consumer.
                        // 64 MiB was only ~5s which caused frequent ring-empty
                        // stalls on large SMB files. 96 MiB fits comfortably
                        // in the Java heap on 256+ MB devices.
                        ringCapacityBytes = 96 * 1024 * 1024
                        chunkBytes = 4 * 1024 * 1024
                        prefetchThreads = 6
                        media3TargetBytes = 96 * 1024 * 1024
                    }
                }
                Log.i(
                    "BufferTuning",
                    "heap=${heapMb}MB lowRam=$lowRam -> ring=${ringCapacityBytes / 1048576}MB " +
                        "chunk=${chunkBytes / 1048576}MB threads=$prefetchThreads " +
                        "media3Target=${media3TargetBytes / 1048576}MB",
                )
            }
            tuned = true
        }
    }
}

@UnstableApi
class SmbDataSource(private val context: Context) : BaseDataSource(true) {

    init {
        BufferTuning.tune(context)
    }

    // ---- SMB connection state (guarded by smbLock) ----
    private var file: SmbFile? = null
    private var raf: SmbRandomAccessFile? = null
    private var fileKey: String? = null
    private var openedUri: Uri? = null
    private var httpDataSource: HttpDataSource? = null
    private var httpMode = false
    private var cachedFileSize: Long = 0

    private var savedKey: String? = null
    private var savedCreds: SmbCredentials? = null
    private var savedShare: String? = null
    private var savedPath: String? = null

    private val smbLock = Object()

    // ---- read-ahead ring buffer (guarded by ringLock) ----
    private var ring: ByteArray? = null
    private var ringSize = 0
    private var bufStart: Long = 0
    private var valid: Long = 0
    private var bufEof = false
    private var eofAt: Long = -1
    private var fileSize: Long = 0
    private var position: Long = 0

    private val ringLock = Object()
    private val prefetchers = mutableListOf<Thread>()
    @Volatile private var prefetchKilled = false
    private var prefetchGen = 0L
    private var ringEpoch = 0L
    private var nextWritePos: Long = 0
    /// Set when reads keep failing after reconnect — [read] throws it so the
    /// player surfaces an error (and the Dart side retries with a fresh open)
    /// instead of hanging on a dead SMB session forever.
    @Volatile private var fatalError: IOException? = null
    /// Out-of-order completion tracking.
    private val pendingChunks = java.util.TreeMap<Long, Int>()

    override fun open(dataSpec: DataSpec): Long {
        openedUri = dataSpec.uri
        if (!"smb".equals(dataSpec.uri.scheme, ignoreCase = true)) {
            httpMode = true
            val http = httpDataSource
                ?: DefaultHttpDataSource.Factory().createDataSource().also {
                    httpDataSource = it
                }
            transferInitializing(dataSpec)
            val length = http.open(dataSpec)
            transferStarted(dataSpec)
            return length
        }
        httpMode = false
        transferInitializing(dataSpec)
        val uri = dataSpec.uri
        val serverId = uri.host
            ?: throw IOException("Malformed SMB uri: $uri")
        val segments = uri.pathSegments
        if (segments.isEmpty()) throw IOException("Missing share in SMB uri: $uri")
        val shareName = segments[0]
        val remotePath =
            if (segments.size > 1) segments.subList(1, segments.size).joinToString("/") else ""

        val creds = SmbStore.resolve(context, serverId)
            ?: throw IOException("Unknown SMB server '$serverId'")

        val key = "$serverId/$shareName/$remotePath"

        try {
            val size: Long
            synchronized(smbLock) {
                savedKey = key
                savedCreds = creds
                savedShare = shareName
                savedPath = remotePath
                if (file == null || fileKey != key) {
                    val t0 = System.nanoTime()
                    size = connectLocked(key, creds, shareName, remotePath)
                    val ms = (System.nanoTime() - t0) / 1_000_000
                    Log.i(TAG, "open: connected in ${ms}ms, size=$size")
                } else {
                    size = cachedFileSize
                }
            }

            // Open secondary SMB handles BEFORE taking ringLock — each open is
            // a tree-connect + create round-trip. Doing this under ringLock
            // (old startPrefetchers path) blocked the first Media3 read for
            // seconds on a cold NAS and made SMB start look "stuck".
            //
            // Skip entirely when:
            //  - the seek lands inside the live ring (reuse path — threads
            //    are still running), or
            //  - short/tail probes (dataSpec.length small, remaining < 2
            //    chunks): a cue/duration read of ~1MB never needs 5 parallel
            //    readers, and each secondary open costs a full SMB
            //    tree-connect before open() can return.
            var withinWindow = false
            synchronized(ringLock) {
                withinWindow = fileKey == key && valid > 0 &&
                    dataSpec.position >= bufStart && dataSpec.position < bufStart + valid
            }
            val remaining0 = size - dataSpec.position
            val needPrefetch = !withinWindow &&
                remaining0 > BufferTuning.chunkBytes.toLong() * 2 &&
                (dataSpec.length == C.LENGTH_UNSET.toLong() ||
                    dataSpec.length > BufferTuning.chunkBytes.toLong())
            val secondaries = ArrayList<SmbRandomAccessFile?>(BufferTuning.prefetchThreads)
            if (needPrefetch) {
                try {
                    for (i in 1 until BufferTuning.prefetchThreads) {
                        secondaries.add(openSecondaryHandle())
                    }
                } catch (e: Exception) {
                    secondaries.forEach { h -> try { h?.close() } catch (_: Exception) {} }
                    throw IOException("SMB secondary open failed: ${e.message}", e)
                }
            }

            synchronized(ringLock) {
                fileSize = size
                if (!withinWindow) {
                    ringEpoch++
                    ensureRingCapacity()
                    position = dataSpec.position
                    bufStart = position
                    valid = 0
                    bufEof = false
                    nextWritePos = position
                    pendingChunks.clear()
                    fatalError = null
                    eofAt = -1
                    Log.i(TAG, "open: ring reset, pos=$position, file=$fileSize")
                    // Outside the window: existing prefetchers write the old
                    // region — kill them before the sync fill.
                    killPrefetchersLocked()
                } else {
                    position = dataSpec.position
                    Log.i(TAG, "open: seek within buffer, keeping $valid bytes at $bufStart")
                    // In-window: leave prefetchers running; they continue from
                    // nextWritePos. Only wake them in case they were idle.
                }
                ringLock.notifyAll()
            }

            // Synchronous head (or tail) fill so the FIRST Media3 read does not
            // block on an empty ring. Without this, open() returned with
            // valid=0, the extractor hit RING EMPTY, and startup waited for
            // a whole prefetch round-trip — while HDR/chapter probes already
            // held other SMB sessions and starved the ring even longer.
            // Runs BEFORE prefetchers start so they continue from nextWritePos
            // after the filled head instead of racing the same region.
            // Short probes (explicit small dataSpec.length) only fill what the
            // caller asked for — not a full 4 MiB chunk.
            val remaining = size - dataSpec.position
            val fillWant: Long = when {
                remaining <= 0L -> 0L
                dataSpec.length != C.LENGTH_UNSET.toLong() &&
                    dataSpec.length in 1 until remaining -> dataSpec.length // bounded read
                remaining < BufferTuning.chunkBytes -> remaining // near-EOF: whole tail
                else -> minOf(BufferTuning.chunkBytes.toLong(), remaining) // head prefill
            }
            if (fillWant > 0L) {
                val tmp = ByteArray(fillWant.toInt())
                var off = 0
                var left = fillWant
                val fillAt = dataSpec.position
                while (left > 0) {
                    val got: Int
                    synchronized(smbLock) {
                        val r = raf ?: break
                        try {
                            r.seek(fillAt + off)
                            got = r.read(tmp, off, left.toInt())
                        } catch (e: Exception) {
                            Log.w(TAG, "open sync-fill read error: ${e.message}")
                            break
                        }
                    }
                    if (got <= 0) break
                    off += got
                    left -= got
                }
                if (off > 0) {
                    synchronized(ringLock) {
                        // Only apply if the ring was not re-targeted mid-fill.
                        if (bufStart == fillAt) {
                            ensureRingCapacity()
                            val r = ring!!
                            var wOff = 0
                            var wLeft = off
                            var wIdx = idx(bufStart)
                            while (wLeft > 0) {
                                val chunk = minOf(wLeft, ringSize - wIdx)
                                System.arraycopy(tmp, wOff, r, wIdx, chunk)
                                wIdx = (wIdx + chunk) % ringSize
                                wOff += chunk
                                wLeft -= chunk
                            }
                            if (off > valid) {
                                valid = off.toLong()
                                nextWritePos = bufStart + valid
                            }
                            // Only flag EOF for a full-tail fill; a head prefill
                            // must leave room for prefetchers to continue.
                            if (remaining < BufferTuning.chunkBytes && off >= remaining) {
                                bufEof = true
                                eofAt = bufStart + valid
                            }
                            ringLock.notifyAll()
                            Log.i(TAG, "open: sync-filled $off bytes at $bufStart eof=$bufEof")
                        }
                    }
                }
            }

            // Tail-only / fully-filled short probes / in-window seeks: no new
            // prefetch threads — they would just wait on bufEof (or duplicate
            // the already-running set) while holding secondary handles.
            if (!withinWindow && !bufEofAfterFill()) {
                synchronized(ringLock) {
                    // Only start if this open killed the previous set (or none
                    // were running). In-window reuses the live threads.
                    if (prefetchers.isEmpty()) {
                        startPrefetchers(secondaries)
                    } else {
                        secondaries.forEach { h -> try { h?.close() } catch (_: Exception) {} }
                    }
                    ringLock.notifyAll()
                }
            } else {
                secondaries.forEach { h -> try { h?.close() } catch (_: Exception) {} }
                if (withinWindow) {
                    Log.i(TAG, "open: kept live prefetch threads after in-window seek")
                } else {
                    Log.i(TAG, "open: eof-after-fill, skipped prefetch threads")
                }
            }

            val length =
                if (dataSpec.length != C.LENGTH_UNSET.toLong())
                    dataSpec.length
                else
                    size - dataSpec.position
            transferStarted(dataSpec)
            return length
        } catch (e: Exception) {
            close()
            throw IOException("SMB open failed: ${e.message}", e)
        }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (httpMode) {
            val http = httpDataSource ?: return C.RESULT_END_OF_INPUT
            val n = http.read(buffer, offset, length)
            if (n > 0) bytesTransferred(n)
            return n
        }
        if (length == 0) return 0
        val t0 = System.nanoTime()
        val n: Int
        synchronized(ringLock) {
            if (fatalError != null) throw fatalError!!
            if (position >= bufStart + valid && !bufEof) {
                val waitStart = System.currentTimeMillis()
                Log.w(TAG, "read: RING EMPTY at pos=$position, waiting for prefetch... ringState: bufStart=$bufStart valid=$valid ringSize=$ringSize eof=$bufEof")
                while (position >= bufStart + valid && !bufEof) {
                    ringLock.wait(5000) // 5-second timeout instead of indefinite block
                    if (fatalError != null) throw fatalError!!
                    // Health check after timeout: if still empty, check if prefetch threads are alive
                    if (position >= bufStart + valid && !bufEof) {
                        val elapsed = System.currentTimeMillis() - waitStart
                        val aliveCount = prefetchers.count { it.isAlive }
                        Log.w(TAG, "read: still empty after 5s (${elapsed}ms total), alivePrefetch=$aliveCount/${prefetchers.size}")
                        if (aliveCount == 0 && !bufEof) {
                            // All prefetch threads died — surface fatal error instead of hanging
                            fatalError = IOException("SMB: all prefetch threads died, no data available")
                            throw fatalError!!
                        }
                        if (elapsed > 15_000) {
                            // 15s stall — NAS is unreachable or throughput is below decode bitrate
                            fatalError = IOException("SMB: no data for ${elapsed}ms — NAS may be unreachable or too slow")
                            Log.e(TAG, "fatalError: stall ${elapsed}ms at pos=$position, alivePrefetch=$aliveCount")
                            throw fatalError!!
                        }
                    }
                }
                Log.w(TAG, "read: resumed after ${System.currentTimeMillis() - waitStart}ms")
            }
            if (position >= bufStart + valid) return C.RESULT_END_OF_INPUT
            val r = ring ?: return C.RESULT_END_OF_INPUT
            val available = minOf(length.toLong(), bufStart + valid - position).toInt()
            val rel = (position - bufStart).toInt()
            val fromIdx = idx(bufStart + rel)
            val first = minOf(available, ringSize - fromIdx)
            System.arraycopy(r, fromIdx, buffer, offset, first)
            if (available > first) {
                System.arraycopy(r, 0, buffer, offset + first, available - first)
            }
            position += available
            n = available
            ringLock.notifyAll()
        }
        if (n > 0) {
            bytesTransferred(n)
            val us = (System.nanoTime() - t0) / 1_000
            Log.v(TAG, "read: pos=${position - n} n=$n in ${us}us")
        }
        return n
    }

    override fun getUri(): Uri? =
        if (httpMode) httpDataSource?.uri ?: openedUri else openedUri

    override fun close() {
        if (httpMode) {
            httpMode = false
            try { httpDataSource?.close() } catch (_: IOException) {}
            openedUri = null
            return
        }
        Log.i(TAG, "close: stopping prefetchers + releasing handles")
        synchronized(ringLock) {
            prefetchKilled = true
            prefetchGen++
            ringLock.notifyAll()
        }
        for (p in prefetchers) {
            try { p.join(2000) } catch (_: InterruptedException) {}
            if (p.isAlive) {
                Log.w(TAG, "close: prefetch thread ${p.name} busy")
            }
        }
        prefetchers.clear()
        synchronized(smbLock) {
            closeHandles()
        }
        synchronized(ringLock) {
            prefetchKilled = false
            valid = 0
            position = 0
            bufEof = false
            fileSize = 0
            pendingChunks.clear()
            fatalError = null
            eofAt = -1
        }
        openedUri = null
    }

    /// True when the ring already covers through EOF (no more read-ahead to do).
    private fun bufEofAfterFill(): Boolean = synchronized(ringLock) { bufEof }

    private fun connectLocked(
        key: String,
        creds: SmbCredentials,
        share: String,
        path: String,
    ): Long {
        closeHandles()
        val f = SmbFile(smbUrl(creds, share, path), creds.context())
        val r = SmbRandomAccessFile(f, "r")
        file = f
        raf = r
        fileKey = key
        cachedFileSize = r.length()
        return cachedFileSize
    }

    private fun openSecondaryHandle(): SmbRandomAccessFile? {
        val creds = savedCreds ?: return null
        val share = savedShare ?: return null
        val path = savedPath ?: return null
        return try {
            val f = SmbFile(smbUrl(creds, share, path), creds.context())
            SmbRandomAccessFile(f, "r")
        } catch (e: Exception) {
            Log.w(TAG, "secondary handle open failed: ${e.message}")
            null
        }
    }

    private fun smbUrl(creds: SmbCredentials, share: String, path: String): String {
        val base = "smb://${creds.host}:${creds.port}/$share"
        return if (path.isEmpty()) base else "$base/$path"
    }

    private fun ensureRingCapacity() {
        if (ring != null && ringSize > 0) return
        val target = minOf(
            BufferTuning.ringCapacityBytes.toLong(),
            maxOf(MIN_BUFFER_CAPACITY.toLong(), fileSize),
        ).toInt()
        ring = ByteArray(target)
        ringSize = target
        Log.i(TAG, "ring allocated: ${ringSize / (1024 * 1024)} MiB")
    }

    /// Kill all existing prefetch threads. Caller holds ringLock.
    private fun killPrefetchersLocked() {
        prefetchKilled = true
        prefetchGen++
        ringLock.notifyAll()
        for (p in prefetchers) {
            try { p.join(1000) } catch (_: InterruptedException) {}
            if (p.isAlive) {
                try { raf?.close() } catch (_: Exception) {}
            }
        }
        prefetchers.clear()
        prefetchKilled = false
    }

    /// Starts prefetch threads with secondary handles that were already opened
    /// OUTSIDE ringLock (see [open]). Caller holds ringLock.
    private fun startPrefetchers(secondaries: List<SmbRandomAccessFile?>) {
        for (i in 0 until BufferTuning.prefetchThreads) {
            val handle = if (i == 0) null else secondaries.getOrNull(i - 1)
            val t = Thread { prefetchLoop(prefetchGen, i, handle) }
            t.isDaemon = true
            t.name = "smb-prefetch-$i"
            t.start()
            prefetchers.add(t)
        }
        Log.i(TAG, "started ${BufferTuning.prefetchThreads} prefetch threads")
    }

    private fun prefetchLoop(gen: Long, threadIdx: Int, secondaryHandle: SmbRandomAccessFile?) {
        // Per-thread temp buffer — SMB reads go here first, then get copied
        // into the ring inside ringLock (after epoch check). This prevents
        // stale writes from a killed/restarted thread from corrupting the ring.
        // `handle` is a mutable copy so a dropped connection can be re-opened
        // per-thread without touching the primary shared handle.
        var handle = secondaryHandle
        val tmpBuf = ByteArray(BufferTuning.chunkBytes)

        var lastHeartbeat = System.currentTimeMillis()
        var bytesSinceHeartbeat = 0L
        var consecutiveFails = 0

        while (true) {
            var readAt = 0L
            var readLen = 0
            var epoch = 0L
            synchronized(ringLock) {
                while (true) {
                    if (prefetchKilled || gen != prefetchGen) {
                        if (secondaryHandle != null) {
                            try { secondaryHandle.close() } catch (_: Exception) {}
                        }
                        return
                    }
                    if (bufEof) { ringLock.wait(); continue }
                    val consumed = (position - bufStart).coerceAtLeast(0)
                    if (consumed > 0) {
                        bufStart = position
                        valid -= consumed
                        nextWritePos = maxOf(nextWritePos, bufStart + valid)
                    }
                    val room = ringSize.toLong() - (nextWritePos - bufStart)
                    if (room > 0) {
                        readAt = nextWritePos
                        readLen = minOf(room, BufferTuning.chunkBytes.toLong(), tmpBuf.size.toLong()).toInt()
                        readLen = minOf(readLen, ringSize - idx(readAt))
                        nextWritePos = readAt + readLen
                        epoch = ringEpoch
                        break
                    }
                    ringLock.wait()
                }
            }

            // SMB read into tmpBuf (outside ringLock — parallel with other threads)
            var got = -2
            var attempted = false
            val readStart = System.nanoTime()
            if (threadIdx == 0) {
                synchronized(smbLock) {
                    val r = raf
                    if (r != null) {
                        attempted = true
                        try {
                            r.seek(readAt)
                            got = r.read(tmpBuf, 0, readLen)
                        } catch (e: Exception) {
                            if (!prefetchKilled) Log.w(TAG, "t0 error at $readAt: ${e.message}")
                            got = -2
                        }
                    }
                }
            } else {
                val r = handle
                if (r != null) {
                    attempted = true
                    try {
                        r.seek(readAt)
                        got = r.read(tmpBuf, 0, readLen)
                    } catch (e: Exception) {
                        if (!prefetchKilled) Log.w(TAG, "t$threadIdx error at $readAt: ${e.message}")
                        got = -2
                    }
                }
            }

            // Copy into ring under ringLock (with epoch check)
            if (got > 0) {
                consecutiveFails = 0
                val readMs = (System.nanoTime() - readStart) / 1_000_000
                if (readMs > 500) {
                    Log.w(TAG, "t$threadIdx slow: $got bytes in ${readMs}ms at $readAt -> " +
                        String.format("%.1f MB/s", got / 1024.0 / 1024.0 / (readMs / 1000.0)))
                }
                synchronized(ringLock) {
                    if (epoch == ringEpoch) {
                        // Copy from tmpBuf into ring
                        val r = ring!!
                        var off = idx(readAt)
                        var remaining = got
                        while (remaining > 0) {
                            val chunk = minOf(remaining, ringSize - off)
                            System.arraycopy(tmpBuf, got - remaining, r, off, chunk)
                            off = (off + chunk) % ringSize
                            remaining -= chunk
                        }
                        bytesSinceHeartbeat += got

                        // Advance valid contiguously
                        if (readAt == bufStart + valid) {
                            valid += got
                            while (pendingChunks.isNotEmpty() && pendingChunks.firstKey() == bufStart + valid) {
                                val entry = pendingChunks.pollFirstEntry()!!
                                valid += entry.value
                            }
                            if (bufStart + valid >= fileSize) bufEof = true
                            if (eofAt >= 0 && bufStart + valid >= eofAt) bufEof = true
                        } else if (readAt > bufStart + valid) {
                            pendingChunks[readAt] = got
                        }
                    }
                    ringLock.notifyAll()
                }
                val now = System.currentTimeMillis()
                if (now - lastHeartbeat > 10_000) {
                    val mbps = bytesSinceHeartbeat / 1024.0 / 1024.0 / ((now - lastHeartbeat) / 1000.0)
                    Log.i(TAG, String.format(
                        "heartbeat t%d: pos=%d bufStart=%d valid=%d ring=%dMB eof=%b fill=%.1f MB/s",
                        threadIdx, position, bufStart, valid, ringSize / (1024 * 1024), bufEof, mbps,
                    ))
                    lastHeartbeat = now
                    bytesSinceHeartbeat = 0
                }
            } else if (got == -1) {
                // A read at `readAt` returned EOF. Record the EOF position, but
                // only flip `bufEof` once the *contiguous* frontier reaches it —
                // if a chunk earlier in the file failed and is still a hole, the
                // consumer must keep waiting/retrying for that hole, not get a
                // premature END_OF_INPUT (which makes the extractor throw EOFException
                // and the player reports "io unspecified").
                synchronized(ringLock) {
                    if (epoch == ringEpoch) {
                        eofAt = maxOf(eofAt, readAt)
                        if (bufStart + valid >= eofAt) bufEof = true
                    }
                    ringLock.notifyAll()
                }
            } else if (attempted) {
                // Read failed (transient network blip or dropped SMB session).
                // CRITICAL: `nextWritePos` was already advanced when this region
                // was carved, so if we just loop and move on the carved region is
                // NEVER filled — the consumer blocks at the hole forever and
                // Media3 surfaces an "io unspecified" error. Reconnect the handle
                // and rewind `nextWritePos` to the region start so it gets retried.
                if (threadIdx == 0) {
                    synchronized(smbLock) {
                        try { raf?.close() } catch (_: Exception) {}
                        raf = null
                        val c = savedCreds
                        val sh = savedShare
                        val p = savedPath
                        if (c != null && sh != null && p != null) {
                            try {
                                raf = SmbRandomAccessFile(SmbFile(smbUrl(c, sh, p), c.context()), "r")
                                Log.i(TAG, "t0 reconnected after read error")
                            } catch (ex: Exception) {
                                Log.w(TAG, "t0 reconnect failed: ${ex.message}")
                            }
                        }
                    }
                } else {
                    try { handle?.close() } catch (_: Exception) {}
                    val c = savedCreds
                    val sh = savedShare
                    val p = savedPath
                    handle = if (c != null && sh != null && p != null) {
                        try {
                            SmbRandomAccessFile(SmbFile(smbUrl(c, sh, p), c.context()), "r").also {
                                Log.i(TAG, "t$threadIdx reconnected after read error")
                            }
                        } catch (ex: Exception) {
                            Log.w(TAG, "t$threadIdx reconnect failed: ${ex.message}")
                            null
                        }
                    } else null
                }
                synchronized(ringLock) {
                    // Re-expose the failed region: never move the write head
                    // forward past it, only back to its start.
                    if (readAt >= bufStart) {
                        nextWritePos = minOf(nextWritePos, readAt)
                    }
                }
                // If the connection keeps failing after reconnect, give up and
                // let the player surface the error (Dart retries with a fresh open).
                consecutiveFails++
                if (consecutiveFails >= 6) {
                    fatalError = IOException("SMB read failed repeatedly at $readAt after $consecutiveFails failures")
                    Log.e(TAG, "fatalError set after $consecutiveFails failures at $readAt")
                    return
                }
                try { Thread.sleep(300) } catch (_: InterruptedException) { return }
            } else {
                // No handle available for this secondary thread (open failed at
                // start). Instead of idling forever, try to reconnect, and if
                // that fails too, signal fatalError after a short grace period
                // so the player surfaces an error instead of hanging.
                var handleAttempts = 0
                while (true) {
                    try { Thread.sleep(1000) } catch (_: InterruptedException) { return }
                    if (prefetchKilled || gen != prefetchGen) return
                    handleAttempts++
                    val c = savedCreds
                    val sh = savedShare
                    val p = savedPath
                    if (c != null && sh != null && p != null) {
                        try {
                            handle = SmbRandomAccessFile(SmbFile(smbUrl(c, sh, p), c.context()), "r")
                            Log.i(TAG, "t$threadIdx recovered handle after ${handleAttempts}s")
                            break // got a handle, rejoin the read loop
                        } catch (_: Exception) { /* retry next iteration */ }
                    }
                    if (handleAttempts >= 10) {
                        Log.e(TAG, "t$threadIdx could not recover handle after ${handleAttempts}s")
                        return // thread exits; read() health check will detect all-dead
                    }
                }
            }
        }
    }

    private fun closeHandles() {
        try { raf?.close() } catch (_: Exception) {}
        raf = null
        try { file?.close() } catch (_: Exception) {}
        file = null
    }

    private fun idx(abs: Long): Int = (abs % ringSize.toLong()).toInt()

    companion object {
        private const val TAG = "SmbDataSource"
        private const val MIN_BUFFER_CAPACITY = 8 * 1024 * 1024
    }
}
