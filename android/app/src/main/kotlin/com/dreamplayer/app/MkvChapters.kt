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

/// Minimal Matroska chapter reader. Media3 does not surface MKV
/// `Chapters` elements, so the player parses them itself: locate the
/// `Chapters` master element (via the SeekHead when present, else by
/// walking top-level Segment children), then collect `ChapterAtom`
/// start times + display titles from its EBML tree.
///
/// Local files (RandomAccessFile) + SMB (SmbRandomAccessFile) + WebDAV/
/// generic HTTP MKVs (Range: bytes=0-8M → ByteArrayReader) are supported.
/// Jellyfin chapters also come from the server API (Item.Chapters) and are
/// seeded from Dart, so the native HTTP parse is the fallback there.
/// Best-effort: any structural surprise yields whatever was collected so
/// far and never affects playback.
internal object MkvChapters {

    class Chapter(
        val title: String,
        val startMs: Long,
        val endMs: Long?,
    )

    // EBML element IDs used here.
    private const val ID_EBML_HEADER = 0x1A45DFA3L
    private const val ID_SEGMENT = 0x18538067L
    private const val ID_SEEKHEAD = 0x114D9B74L
    private const val ID_SEEK = 0x4DBBL
    private const val ID_SEEK_ID = 0x53ABL
    private const val ID_SEEK_POSITION = 0x53ACL
    private const val ID_CHAPTERS = 0x1043A770L
    private const val ID_EDITION_ENTRY = 0x45B9L
    private const val ID_CHAPTER_ATOM = 0xB6L
    private const val ID_CHAPTER_TIME_START = 0x91L
    private const val ID_CHAPTER_TIME_END = 0x92L
    private const val ID_CHAPTER_DISPLAY = 0x80L
    private const val ID_CHAP_STRING = 0x85L

    /// Upper bounds so a pathological file can't spin us forever.
    private const val MAX_TOP_LEVEL_CHILDREN = 64
    private const val MAX_CHAPTERS = 999
    private const val MAX_HEADER_BYTES = 1 shl 20
    private const val MAX_CHAPTER_ATOM_DEPTH = 32

    fun parse(path: String): List<Chapter> {
        val raf = try {
            RandomAccessFile(path, "r")
        } catch (_: Exception) {
            return emptyList()
        }
        try {
            return doParse(RafReader(raf))
        } catch (e: Exception) {
            Log.i("MkvChapters", "parse failed (${e.javaClass.simpleName}: ${e.message})")
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
            Log.i("MkvChapters", "parseSmb failed (${e.javaClass.simpleName}: ${e.message})")
            return emptyList()
        } finally {
            try { raf.close() } catch (_: Exception) {}
        }
    }

    /// Fetches the first bytes of an HTTP(S) MKV via Range request and parses
    /// chapters from the in-memory buffer. Used for WebDAV and generic HTTP
    /// sources (Jellyfin direct-play is covered by the server API, but this
    /// is a fallback for any http MKV). Best-effort: needs only the EBML
    /// header + Segment SeekHead + Chapters — all near the start.
    fun parseHttp(
        url: String,
        headers: Map<String, String>,
        allowSelfSigned: Boolean,
    ): List<Chapter> {
        return try {
            val bytes = fetchHttpHeader(url, headers, allowSelfSigned) ?: return emptyList()
            doParse(ByteArrayReader(bytes))
        } catch (e: Exception) {
            Log.i("MkvChapters", "parseHttp failed (${e.javaClass.simpleName}: ${e.message})")
            emptyList()
        }
    }

    private fun fetchHttpHeader(
        url: String,
        headers: Map<String, String>,
        allowSelfSigned: Boolean,
    ): ByteArray? {
        val client = if (allowSelfSigned) permissiveClient else standardClient
        val reqBuilder = Request.Builder().url(url).header("Range", "bytes=0-8388607")
        for ((k, v) in headers) reqBuilder.header(k, v)
        val resp = client.newCall(reqBuilder.build()).execute()
        try {
            if (!resp.isSuccessful && resp.code != 206) return null
            val body = resp.body ?: return null
            // Cap at 8 MiB even if server ignores Range and sends the whole file.
            val bytes = body.bytes()
            return if (bytes.size > 8 * 1024 * 1024) bytes.copyOf(8 * 1024 * 1024) else bytes
        } finally {
            resp.close()
        }
    }

    /// FTP/SFTP source (`ftp://<serverId>/<path>`): seekable reads over the
    /// saved server credentials, like the SMB path.
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
            })
        } catch (e: Exception) {
            Log.i("MkvChapters", "parseFtp failed (${e.javaClass.simpleName}: ${e.message})")
            return emptyList()
        } finally {
            src.close()
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

    internal fun openSmbFile(smbUri: String, context: Context): SmbRandomAccessFile? {
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

    // ---- Seekable reader abstraction (local + SMB) ----

    private interface SeekableReader {
        fun read(): Int
        fun readFully(buf: ByteArray)
        fun seek(pos: Long)
        fun pos(): Long
    }

    private class RafReader(private val raf: RandomAccessFile) : SeekableReader {
        override fun read(): Int = raf.read()
        override fun readFully(buf: ByteArray) = raf.readFully(buf)
        override fun seek(pos: Long) = raf.seek(pos)
        override fun pos(): Long = raf.filePointer
    }

    private class SmbReader(private val raf: SmbRandomAccessFile) : SeekableReader {
        override fun read(): Int = raf.read()
        override fun readFully(buf: ByteArray) = raf.readFully(buf)
        override fun seek(pos: Long) = raf.seek(pos)
        override fun pos(): Long = raf.filePointer
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
    }

    private fun doParse(r: SeekableReader): List<Chapter> {
        if (readId(r) != ID_EBML_HEADER) return emptyList()
        val headerSize = readSize(r)
        if (headerSize == null || headerSize < 0 || headerSize > MAX_HEADER_BYTES) return emptyList()
        r.seek(r.pos() + headerSize)

        if (readId(r) != ID_SEGMENT) return emptyList()
        readSize(r)
        val segmentDataStart = r.pos()

        // Bounded walk of top-level Segment children looking for the SeekHead
        // (preferred — O(1) jump to Chapters) or a direct Chapters element.
        var chaptersOffset = -1L
        var walked = 0
        while (walked++ < MAX_TOP_LEVEL_CHILDREN) {
            val id = readId(r) ?: break
            val size = readSize(r) ?: break
            val dataStart = r.pos()
            when (id) {
                ID_SEEKHEAD ->
                    if (size >= 0) {
                        val found = findChaptersInSeekHead(r, dataStart + size, segmentDataStart)
                        if (found != null) chaptersOffset = found
                    }
                ID_CHAPTERS -> chaptersOffset = r.pos() - idBytes(id) - sizeBytes(size)
            }
            if (chaptersOffset >= 0) break
            if (size < 0) break // unknown-size child: stop rather than guess past it
            r.seek(dataStart + size)
        }
        if (chaptersOffset < 0) return emptyList()

        // Verify the target really is a Chapters element (guards against stale
        // seek heads), then parse its tree.
        r.seek(chaptersOffset)
        if (readId(r) != ID_CHAPTERS) return emptyList()
        val chaptersSize = readSize(r) ?: return emptyList()
        val endPos = if (chaptersSize < 0) Long.MAX_VALUE else r.pos() + chaptersSize
        val out = mutableListOf<Chapter>()
        parseContainer(r, endPos, out, editions = true)
        finalizeEnds(out)
        return out
    }

    /// Reads Seek entries inside a SeekHead; returns the absolute file offset
    /// of the Chapters element, or null.
    private fun findChaptersInSeekHead(
        r: SeekableReader,
        endPos: Long,
        segmentDataStart: Long,
    ): Long? {
        while (r.pos() < endPos) {
            val id = readId(r) ?: return null
            val size = readSize(r) ?: return null
            val dataStart = r.pos()
            if (id == ID_SEEK && size >= 0) {
                val seekEnd = dataStart + size
                var isChapters = false
                var position = -1L
                while (r.pos() < seekEnd) {
                    val sid = readId(r) ?: break
                    val ssize = readSize(r) ?: break
                    val sdata = r.pos()
                    when (sid) {
                        ID_SEEK_ID ->
                            if (ssize in 1..8 &&
                                readUint(r, ssize.toInt()) == ID_CHAPTERS
                            ) {
                                isChapters = true
                            }
                        ID_SEEK_POSITION ->
                            if (ssize in 1..8) position = readUint(r, ssize.toInt())
                    }
                    if (ssize < 0) break
                    r.seek(sdata + ssize)
                }
                if (isChapters && position >= 0) return segmentDataStart + position
            }
            if (size < 0) return null
            r.seek(dataStart + size)
        }
        return null
    }

    private fun parseContainer(
        r: SeekableReader,
        endPos: Long,
        out: MutableList<Chapter>,
        editions: Boolean,
    ) {
        while (r.pos() < endPos && out.size < MAX_CHAPTERS) {
            val id = readId(r) ?: return
            val size = readSize(r) ?: return
            val dataStart = r.pos()
            when {
                editions && id == ID_EDITION_ENTRY && size >= 0 ->
                    parseContainer(r, dataStart + size, out, editions = false)
                !editions && id == ID_CHAPTER_ATOM && size >= 0 ->
                    parseAtom(r, dataStart + size, out, depth = 0)
            }
            if (size < 0) return
            r.seek(dataStart + size)
        }
    }

    /// `depth` bounds ChapterAtom nesting: a corrupted/pathological MKV can
    /// nest thousands of levels in only a few bytes each, which would
    /// StackOverflowError this background probe thread and crash the whole
    /// process (an uncaught Error isn't limited to the thread it occurs on).
    /// Real-world chapter trees never nest anywhere close to this deep.
    private fun parseAtom(r: SeekableReader, endPos: Long, out: MutableList<Chapter>, depth: Int) {
        var startNs = -1L
        var endNs = -1L
        var title: String? = null
        while (r.pos() < endPos) {
            val id = readId(r) ?: return
            val size = readSize(r) ?: return
            val dataStart = r.pos()
            when (id) {
                ID_CHAPTER_TIME_START ->
                    if (size in 1..8) startNs = readUint(r, size.toInt())
                ID_CHAPTER_TIME_END ->
                    if (size in 1..8) endNs = readUint(r, size.toInt())
                ID_CHAPTER_DISPLAY ->
                    if (size >= 0) title = title ?: readDisplayTitle(r, dataStart + size)
                // Nested ChapterAtoms (sub-chapters) flatten into one list.
                ID_CHAPTER_ATOM ->
                    if (size >= 0 && depth < MAX_CHAPTER_ATOM_DEPTH) {
                        parseAtom(r, dataStart + size, out, depth + 1)
                    }
            }
            if (size < 0) return
            r.seek(dataStart + size)
        }
        if (startNs >= 0) {
            val name = title?.takeIf { it.isNotBlank() } ?: "Chapter ${out.size + 1}"
            out.add(
                Chapter(
                    name,
                    startNs / 1_000_000,
                    if (endNs > startNs) endNs / 1_000_000 else null,
                ),
            )
        }
    }

    private fun readDisplayTitle(r: SeekableReader, endPos: Long): String? {
        while (r.pos() < endPos) {
            val id = readId(r) ?: return null
            val size = readSize(r) ?: return null
            val dataStart = r.pos()
            if (id == ID_CHAP_STRING && size in 1..4096) {
                val buf = ByteArray(size.toInt())
                r.readFully(buf)
                return String(buf, Charsets.UTF_8).trim()
            }
            if (size < 0) return null
            r.seek(dataStart + size)
        }
        return null
    }

    /// Fills missing ends from the next chapter's start and orders by time.
    private fun finalizeEnds(out: MutableList<Chapter>) {
        out.sortBy { it.startMs }
        for (i in out.indices) {
            val c = out[i]
            if (c.endMs == null && i + 1 < out.size) {
                out[i] = Chapter(c.title, c.startMs, out[i + 1].startMs)
            }
        }
    }

    /// EBML element-ID vint (leading marker bits kept).
    private fun readId(r: SeekableReader): Long? {
        val first = r.read()
        if (first < 0) return null
        val length = countLength(first)
        if (length > 4) return null
        var value = first.toLong() and 0xFFL
        repeat(length - 1) {
            val b = r.read()
            if (b < 0) throw EOFException()
            value = (value shl 8) or (b.toLong() and 0xFFL)
        }
        return value
    }

    /// EBML size vint (marker bit cleared; all payload bits set = unknown → -1).
    private fun readSize(r: SeekableReader): Long? {
        val first = r.read()
        if (first < 0) return null
        val length = countLength(first)
        if (length > 8) return null
        var value = (first.toLong() and 0xFFL) and ((1L shl (8 - length)) - 1)
        repeat(length - 1) {
            val b = r.read()
            if (b < 0) throw EOFException()
            value = (value shl 8) or (b.toLong() and 0xFFL)
        }
        return if (value == (1L shl (7 * length)) - 1) -1L else value
    }

    private fun readUint(r: SeekableReader, length: Int): Long {
        var value = 0L
        repeat(length) {
            val b = r.read()
            if (b < 0) throw EOFException()
            value = (value shl 8) or (b.toLong() and 0xFFL)
        }
        return value
    }

    private fun countLength(firstByte: Int): Int {
        var mask = 0x80
        var length = 1
        while (length < 8 && (firstByte and mask) == 0) {
            mask = mask shr 1
            length++
        }
        return length
    }

    private fun idBytes(id: Long): Int {
        var n = 1
        var v = id
        while (v > 0xFFL) {
            v = v shr 8
            n++
        }
        return n
    }

    private fun sizeBytes(size: Long): Int {
        if (size < 0) return 1 // unknown sizes we bail on anyway; keep math safe
        var n = 1
        var v = size
        while (v > 0x7FL) {
            v = v shr 8
            n++
        }
        return n
    }
}
