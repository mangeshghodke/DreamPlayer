package com.dreamplayer.app

import android.content.Context
import android.util.Log
import java.io.EOFException
import java.io.RandomAccessFile
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import jcifs.smb.SmbFile
import jcifs.smb.SmbRandomAccessFile
import okhttp3.OkHttpClient
import okhttp3.Request

/// Nero `moov/udta/chpl` chapter reader. Media3 does not surface MP4 chapter
/// atoms, so the player parses them itself: scan top-level boxes for `moov`,
/// then `udta` inside it, then `chpl` inside that. HandBrake and others write
/// `chpl` as Nero chapters (version/flags + count + entries with 8-byte start
/// in 100ns units + 1-byte title length + title). The start is converted to
/// milliseconds (/10000) to match the MKV chapter model.
///
/// Supports local files (RandomAccessFile), SMB (SmbRandomAccessFile), and
/// WebDAV/generic HTTP MP4s (Range: bytes=0-8M → ByteArrayReader). Best-effort:
/// any structural surprise yields whatever was collected so far and never
/// affects playback. Reuses [MkvChapters.Chapter] for emission so the Dart
/// event map stays uniform.
internal object Mp4Chapters {

    class Chapter(
        val title: String,
        val startMs: Long,
        val endMs: Long?,
    )

    /// Head/tail windows for a remote probe — see [SparseReader].
    private const val HEAD_RANGE_BYTES = 8L * 1024 * 1024
    private const val TAIL_RANGE_BYTES = 8L * 1024 * 1024

    private const val MAX_CHAPTERS = 999
    private const val MAX_BOX_HEADER = 16

    fun parse(path: String): List<Chapter> {
        val raf = try {
            RandomAccessFile(path, "r")
        } catch (_: Exception) {
            return emptyList()
        }
        try {
            return doParse(RafReader(raf))
        } catch (e: Exception) {
            Log.i("Mp4Chapters", "parse failed (${e.javaClass.simpleName}: ${e.message})")
            return emptyList()
        } finally {
            try { raf.close() } catch (_: Exception) {}
        }
    }

    fun parseSmb(smbUri: String, context: Context): List<Chapter> {
        val raf = try {
            openSmbFile(smbUri, context) ?: return emptyList()
        } catch (_: Exception) {
            return emptyList()
        }
        try {
            return doParse(SmbReader(raf))
        } catch (e: Exception) {
            Log.i("Mp4Chapters", "parseSmb failed (${e.javaClass.simpleName}: ${e.message})")
            return emptyList()
        } finally {
            try { raf.close() } catch (_: Exception) {}
        }
    }

    fun parseHttp(
        url: String,
        headers: Map<String, String>,
        allowSelfSigned: Boolean,
    ): List<Chapter> {
        return try {
            val reader = fetchHttpRanges(url, headers, allowSelfSigned) ?: return emptyList()
            doParse(reader)
        } catch (e: Exception) {
            Log.i("Mp4Chapters", "parseHttp failed (${e.javaClass.simpleName}: ${e.message})")
            emptyList()
        }
    }

    fun parseFtp(ftpUri: String, context: Context): List<Chapter> {
        val src = FtpSeekSource.open(ftpUri, context) ?: return emptyList()
        try {
            return doParse(object : SeekableReader {
                private var p = 0L
                override fun read(): Int {
                    val buf = ByteArray(1)
                    return if (src.readFullyAt(p, buf)) (buf[0].toInt() and 0xFF).also { p += 1 } else -1
                }
                override fun readFully(buf: ByteArray) {
                    if (!src.readFullyAt(p, buf)) throw EOFException()
                    p += buf.size
                }
                override fun seek(pos: Long) { p = pos }
                override fun pos(): Long = p
                override fun length(): Long = src.size
            })
        } catch (e: Exception) {
            Log.i("Mp4Chapters", "parseFtp failed (${e.javaClass.simpleName}: ${e.message})")
            return emptyList()
        } finally {
            src.close()
        }
    }

    /// Head AND tail windows over a remote file, with the middle missing.
    ///
    /// MP4 keeps `moov` (which carries the Nero chapter list) at the END of the
    /// file unless it was written "fast start", so a single `Range: bytes=0-8M`
    /// read missed chapters on exactly the files that have them. The box walk
    /// seeks from box to box and never touches the gap.
    private class HttpSegment(val start: Long, val data: ByteArray)

    private class SparseReader(
        private val segments: List<HttpSegment>,
        private val totalSize: Long,
    ) : SeekableReader {
        private var p = 0L

        private fun locate(pos: Long): Pair<HttpSegment, Int>? {
            for (segment in segments) {
                if (pos >= segment.start && pos < segment.start + segment.data.size) {
                    return segment to (pos - segment.start).toInt()
                }
            }
            return null
        }

        override fun read(): Int {
            val hit = locate(p) ?: return -1
            p++
            return hit.first.data[hit.second].toInt() and 0xFF
        }

        override fun readFully(buf: ByteArray) {
            val hit = locate(p) ?: throw EOFException()
            val segment = hit.first
            val offset = hit.second
            if (offset + buf.size > segment.data.size) throw EOFException()
            System.arraycopy(segment.data, offset, buf, 0, buf.size)
            p += buf.size
        }

        override fun seek(pos: Long) {
            p = pos.coerceIn(0, totalSize)
        }

        override fun pos(): Long = p

        // MP4's box walk needs the real file size (it walks to EOF looking for
        // `moov`), which is exactly what the Content-Range total gives us.
        override fun length(): Long = totalSize
    }

    private class HttpRange(val data: ByteArray, val totalSize: Long)

    private fun fetchHttpRanges(
        url: String,
        headers: Map<String, String>,
        allowSelfSigned: Boolean,
    ): SeekableReader? {
        val client = if (allowSelfSigned) permissiveClient else standardClient
        val head = requestRange(url, headers, client, 0, HEAD_RANGE_BYTES - 1) ?: return null
        val total = head.totalSize
        if (total <= 0L || head.data.size.toLong() >= total) return ByteArrayReader(head.data)
        val segments = mutableListOf(HttpSegment(0L, head.data))
        val tailStart = (total - TAIL_RANGE_BYTES).coerceAtLeast(head.data.size.toLong())
        requestRange(url, headers, client, tailStart, total - 1)?.let { tail ->
            if (tail.data.isNotEmpty()) segments.add(HttpSegment(tailStart, tail.data))
        }
        return SparseReader(segments, total)
    }

    private fun requestRange(
        url: String,
        headers: Map<String, String>,
        client: OkHttpClient,
        from: Long,
        to: Long,
    ): HttpRange? {
        val reqBuilder = Request.Builder().url(url).header("Range", "bytes=$from-$to")
        for ((k, v) in headers) reqBuilder.header(k, v)
        val resp = client.newCall(reqBuilder.build()).execute()
        try {
            if (!resp.isSuccessful && resp.code != 206) return null
            val body = resp.body ?: return null
            val bytes = body.bytes()
            val capped = if (bytes.size > HEAD_RANGE_BYTES) bytes.copyOf(HEAD_RANGE_BYTES.toInt()) else bytes
            var total = 0L
            resp.header("Content-Range")?.let { cr ->
                val slash = cr.lastIndexOf('/')
                if (slash >= 0 && cr.length > slash + 1) {
                    total = cr.substring(slash + 1).trim().toLongOrNull() ?: 0L
                }
            }
            return HttpRange(capped, total)
        } finally {
            resp.close()
        }
    }

    private val standardClient: OkHttpClient by lazy { OkHttpClient() }

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
            .build()
    }

    private fun openSmbFile(smbUri: String, context: Context): SmbRandomAccessFile? {
        val uri = android.net.Uri.parse(smbUri) ?: return null
        if (!"smb".equals(uri.scheme, ignoreCase = true)) return null
        val serverId = uri.host ?: return null
        val segments = uri.pathSegments
        if (segments.isEmpty()) return null
        val share = segments[0]
        val remotePath = if (segments.size > 1) segments.subList(1, segments.size).joinToString("/") else ""
        val creds = SmbStore.resolve(context, serverId) ?: return null
        val base = "smb://${creds.host}:${creds.port}/$share"
        val url = if (remotePath.isEmpty()) base else "$base/$remotePath"
        val f = SmbFile(url, creds.context())
        return SmbRandomAccessFile(f, "r")
    }

    // ---- Seekable reader abstraction ----

    private interface SeekableReader {
        fun read(): Int
        fun readFully(buf: ByteArray)
        fun seek(pos: Long)
        fun pos(): Long
        fun length(): Long
    }

    private class RafReader(private val raf: RandomAccessFile) : SeekableReader {
        override fun read(): Int = raf.read()
        override fun readFully(buf: ByteArray) = raf.readFully(buf)
        override fun seek(pos: Long) = raf.seek(pos)
        override fun pos(): Long = raf.filePointer
        override fun length(): Long = try { raf.length() } catch (_: Exception) { Long.MAX_VALUE }
    }

    private class SmbReader(private val raf: SmbRandomAccessFile) : SeekableReader {
        override fun read(): Int = raf.read()
        override fun readFully(buf: ByteArray) = raf.readFully(buf)
        override fun seek(pos: Long) = raf.seek(pos)
        override fun pos(): Long = raf.filePointer
        override fun length(): Long = try { raf.length() } catch (_: Exception) { Long.MAX_VALUE }
    }

    private class ByteArrayReader(private val data: ByteArray) : SeekableReader {
        private var p = 0
        override fun read(): Int = if (p >= data.size) -1 else (data[p++].toInt() and 0xFF)
        override fun readFully(buf: ByteArray) {
            if (p + buf.size > data.size) throw EOFException()
            System.arraycopy(data, p, buf, 0, buf.size)
            p += buf.size
        }
        override fun seek(pos: Long) { p = pos.coerceIn(0, data.size.toLong()).toInt() }
        override fun pos(): Long = p.toLong()
        override fun length(): Long = data.size.toLong()
    }

    private fun doParse(r: SeekableReader): List<Chapter> {
        val fileSize = r.length()
        // Find moov at top level.
        val moov = findBox(r, "moov", 0L, fileSize) ?: return emptyList()
        // Inside moov, find udta. Fallback: search chpl directly under moov.
        val udta = findBox(r, "udta", moov.first, moov.second)
        val chplRange = if (udta != null) {
            findBox(r, "chpl", udta.first, udta.second) ?: findBox(r, "chpl", moov.first, moov.second)
        } else {
            findBox(r, "chpl", moov.first, moov.second)
        } ?: return emptyList()
        val out = parseChpl(r, chplRange.first, chplRange.second)
        finalizeEnds(out)
        return out
    }

    private fun findBox(r: SeekableReader, target: String, start: Long, end: Long): Pair<Long, Long>? {
        val targetBytes = target.toByteArray(Charsets.US_ASCII)
        var pos = start
        while (pos + 8 <= end) {
            r.seek(pos)
            val sizeBytes = ByteArray(4)
            try { r.readFully(sizeBytes) } catch (_: Exception) { break }
            val size = ((sizeBytes[0].toLong() and 0xFF) shl 24) or
                ((sizeBytes[1].toLong() and 0xFF) shl 16) or
                ((sizeBytes[2].toLong() and 0xFF) shl 8) or
                (sizeBytes[3].toLong() and 0xFF)
            val typeBytes = ByteArray(4)
            try { r.readFully(typeBytes) } catch (_: Exception) { break }
            var headerSize = 8L
            var boxSize = size
            if (boxSize == 1L) {
                if (pos + 16 > end) break
                val largeBytes = ByteArray(8)
                try { r.readFully(largeBytes) } catch (_: Exception) { break }
                var v = 0L
                for (b in largeBytes) v = (v shl 8) or (b.toLong() and 0xFF)
                boxSize = v
                headerSize = 16L
            } else if (boxSize == 0L) {
                boxSize = end - pos
            }
            if (boxSize < headerSize) break
            val payloadStart = pos + headerSize
            val payloadEnd = pos + boxSize
            if (payloadEnd > end || payloadEnd < payloadStart) break
            if (typeBytes.contentEquals(targetBytes)) {
                return Pair(payloadStart, payloadEnd)
            }
            pos = payloadEnd
            // Safety: avoid infinite loop on malformed size
            if (pos <= start) break
        }
        return null
    }

    private fun parseChpl(r: SeekableReader, start: Long, end: Long): MutableList<Chapter> {
        val payloadSize = end - start
        if (payloadSize < 5) return mutableListOf()
        r.seek(start)
        val version = r.read()
        if (version < 0) return mutableListOf()
        // flags
        r.read(); r.read(); r.read()
        var headerConsumed = 4L
        if (version != 0) {
            if (payloadSize < headerConsumed + 4 + 1) return mutableListOf()
            r.read(); r.read(); r.read(); r.read()
            headerConsumed += 4
        }
        if (payloadSize < headerConsumed + 1) return mutableListOf()
        val firstCountByte = r.read()
        if (firstCountByte < 0) return mutableListOf()
        headerConsumed += 1

        // Primary: 1-byte count (FFmpeg mov_read_chpl)
        val count1 = firstCountByte
        var best: MutableList<Chapter>? = null
        if (count1 in 1..MAX_CHAPTERS) {
            val parsed = tryParseEntries(r, count1, end)
            if (parsed != null && parsed.isNotEmpty()) best = parsed
        } else if (count1 == 0 && payloadSize > headerConsumed) {
            // count 0 with remaining payload suggests alternative encoding; try fallbacks
        }

        // Fallback 1: count is 32-bit BE where firstCountByte is the high byte
        if ((best == null || best.isEmpty()) && payloadSize >= headerConsumed - 1 + 4) {
            r.seek(start + headerConsumed - 1)
            val b4 = ByteArray(4)
            try {
                r.readFully(b4)
                val count32 = ((b4[0].toLong() and 0xFF) shl 24) or
                    ((b4[1].toLong() and 0xFF) shl 16) or
                    ((b4[2].toLong() and 0xFF) shl 8) or
                    (b4[3].toLong() and 0xFF)
                if (count32 in 1..MAX_CHAPTERS.toLong()) {
                    val parsed = tryParseEntries(r, count32.toInt(), end)
                    if (parsed != null && parsed.isNotEmpty()) best = parsed
                }
            } catch (_: Exception) {}
        }

        // Fallback 2: count is 64-bit BE (8 bytes)
        if ((best == null || best.isEmpty()) && payloadSize >= headerConsumed - 1 + 8) {
            r.seek(start + headerConsumed - 1)
            val b8 = ByteArray(8)
            try {
                r.readFully(b8)
                var v = 0L
                for (b in b8) v = (v shl 8) or (b.toLong() and 0xFF)
                if (v in 1..MAX_CHAPTERS.toLong()) {
                    val parsed = tryParseEntries(r, v.toInt(), end)
                    if (parsed != null && parsed.isNotEmpty()) best = parsed
                }
            } catch (_: Exception) {}
        }

        return best ?: mutableListOf()
    }

    private fun tryParseEntries(r: SeekableReader, count: Int, boxEnd: Long): MutableList<Chapter>? {
        if (count <= 0 || count > MAX_CHAPTERS) return null
        val out = mutableListOf<Chapter>()
        for (i in 0 until count) {
            if (r.pos() + 9 > boxEnd) return null
            val startBytes = ByteArray(8)
            try { r.readFully(startBytes) } catch (_: Exception) { return null }
            var start100ns = 0L
            for (b in startBytes) start100ns = (start100ns shl 8) or (b.toLong() and 0xFF)
            val titleLen = r.read()
            if (titleLen < 0) return null
            if (r.pos() + titleLen > boxEnd) return null
            val titleBytes = ByteArray(titleLen)
            if (titleLen > 0) {
                try { r.readFully(titleBytes) } catch (_: Exception) { return null }
            }
            val raw = String(titleBytes, Charsets.UTF_8).trim()
            val title = if (raw.isEmpty()) "Chapter ${i + 1}" else raw
            val startMs = start100ns / 10000L
            out.add(Chapter(title, startMs, null))
            if (out.size > MAX_CHAPTERS) break
        }
        return out
    }

    private fun finalizeEnds(out: MutableList<Chapter>) {
        out.sortBy { it.startMs }
        for (i in out.indices) {
            val c = out[i]
            if (c.endMs == null && i + 1 < out.size) {
                out[i] = Chapter(c.title, c.startMs, out[i + 1].startMs)
            }
        }
    }
}
