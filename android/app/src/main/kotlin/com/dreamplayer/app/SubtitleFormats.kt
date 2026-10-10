package com.dreamplayer.app

import android.content.Context
import android.net.Uri
import androidx.media3.common.MimeTypes
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Locale

/// Subtitle format detection and sibling auto-pairing, mirroring Just Player's
/// `SubtitleUtils` but expanded to every format the player supports.
///
/// Sideloaded sidecar files are matched to Media3 MIME types so they flow
/// through Media3's subtitle stack. Formats Media3 parses natively (SubRip,
/// SSA/ASS, WebVTT, TTML) map to the stock MIME constants; the formats Media3
/// lacks (SAMI, MicroDVD, MPL2, SubViewer) use the custom MIME types served by
/// [DreamSubtitleParserFactory].
object SubtitleFormats {

    const val MIME_SAMI = "application/x-sami"
    const val MIME_MICRODVD = "application/x-microdvd"
    const val MIME_MPL2 = "application/x-mpl2"

    /// VobSub bitmap subtitles. Media3 has no filesystem extractor for these, so
    /// a sidecar pair has to be fed through [MimeTypes.APPLICATION_VOBSUB] with
    /// the `.idx` handed over as `initializationData` (see [vobSubPairFor]).
    const val MIME_VOBSUB = MimeTypes.APPLICATION_VOBSUB

    /// Enough to sniff a format without touching the rest of the file.
    internal const val SNIFF_BYTES = 64 * 1024

    /// Real text subtitles are tiny. A 1 MB `.srt` is already pathological, and
    /// anything past this is binary payload being fed to a text parser.
    internal const val MAX_SUBTITLE_BYTES = 1024L * 1024L

    private const val UTF8_CACHE_PREFIX = "dreamplayer_sub_"
    private const val UTF8_CACHE_MAX_AGE_MS = 24L * 60L * 60L * 1000L
    private const val IDX_EXTENSION = ".idx"
    private const val VOBSUB_PAYLOAD_EXTENSION = "sub"

    private val VIDEO_EXTENSIONS = setOf(
        "mp4", "m4v", "mkv", "webm", "avi", "mov", "3gp", "3g2", "ts", "m2ts",
        "mts", "wmv", "flv", "mpg", "mpeg", "m2v", "vob", "divx", "ogv",
    )

    private val SUBTITLE_EXTENSIONS = setOf(
        "srt", "ass", "ssa", "vtt", "ttml", "dfxp", "xml", "smi", "sub", "mpl2",
        "idx",
    )

    /// Full extension -> MIME map. Anything unknown falls back to SubRip so
    /// odd-but-SRT-shaped files (e.g. mislabeled `.txt`) still play.
    ///
    /// `.sub` maps to MicroDVD here because it is genuinely ambiguous: MicroDVD
    /// and SubViewer are both plain text with a `.sub` extension, while a VobSub
    /// `.sub` is binary bitmap data. Callers that can read the first bytes
    /// should use [mimeTypeFor] with [looksBinary] and get the right answer for
    /// all three; issue #44 shipped a 19 MB VobSub payload into the MicroDVD
    /// text parser because nothing ever checked.
    fun mimeTypeFor(path: String): String {
        return when (extensionOf(path)) {
            "ass", "ssa" -> MimeTypes.TEXT_SSA
            "vtt" -> MimeTypes.TEXT_VTT
            "ttml", "dfxp", "xml" -> MimeTypes.APPLICATION_TTML
            "smi" -> MIME_SAMI
            "sub" -> MIME_MICRODVD
            "mpl2" -> MIME_MPL2
            "idx" -> MIME_VOBSUB
            else -> MimeTypes.APPLICATION_SUBRIP
        }
    }

    /// Whether [path] is a VobSub index (`.idx`) rather than a text subtitle.
    fun isVobSubIndex(path: String): Boolean = extensionOf(path) == "idx"

    /// Whether [subPath] is the binary payload belonging to a sibling `.idx`.
    ///
    /// A VobSub track is two files with a shared basename. The `.idx` is the
    /// descriptor (timings, palette, canvas size) and is the file that should
    /// appear as a selectable track; the `.sub` is the bitmap payload. Treating
    /// the payload as its own MicroDVD track is what broke issue #44, so it is
    /// excluded when an index is present.
    fun isVobSubPayload(subPath: String, siblingNames: Collection<String>): Boolean {
        if (extensionOf(subPath) != "sub") return false
        // Compare basenames, not whole paths: `siblingNames` arrives from
        // File.listFiles() (bare names) while `subPath` is a full path.
        val base = subPath.substringAfterLast('/').substringBeforeLast('.')
        return siblingNames.any {
            it.substringBeforeLast('.').equals(base, ignoreCase = true) &&
                extensionOf(it) == "idx"
        }
    }

    /// e.g. `Show.S01E01.eng.srt` -> `eng` (Just Player's rule: the 2..6-char
    /// segment between the last two dots is treated as a language tag).
    fun languageFromFileName(path: String): String? {
        val lower = path.lowercase(Locale.ROOT)
        val last = lower.lastIndexOf('.')
        if (last <= 0) return null
        var prev = last
        var i = last - 1
        while (i >= 0) {
            if (lower[i] == '.') {
                prev = i
                break
            }
            i--
        }
        val len = last - prev - 1
        return if (len in 2..6) lower.substring(prev + 1, last) else null
    }

    /// Display label, e.g. `Show.S01E01.eng` for `Show.S01E01.eng.srt`.
    fun labelFromFileName(path: String): String {
        val name = path.substringAfterLast('/')
        val base = name.substringBeforeLast('.')
        return if (base.isEmpty()) name else base
    }

    /// Whether [name] is a subtitle file we understand.
    fun isSubtitleFile(name: String): Boolean =
        extensionOf(name) in SUBTITLE_EXTENSIONS

    /// Whether [name] is a video file.
    fun isVideoFile(name: String): Boolean =
        extensionOf(name) in VIDEO_EXTENSIONS

    private fun extensionOf(path: String): String =
        path.substringAfterLast('.').lowercase(Locale.ROOT)

    /// All subtitle files in the video's folder that plausibly pair with it
    /// (Just Player's `findSubtitle` rule, expanded to keep every candidate):
    /// an exact filename-prefix match always wins; when the folder has exactly
    /// one video and one subtitle, that subtitle is the only candidate. The
    /// list is ordered best-match first so the caller can mark the first entry
    /// as the default-selected track.
    fun findSiblingSubtitles(videoPath: String): List<File> {
        val video = File(videoPath)
        val dir = video.parentFile ?: return emptyList()
        val files = dir.listFiles()?.toList() ?: return emptyList()

        // A VobSub pair is one logical track, not two. Keep the `.idx` (the
        // descriptor, which is what a player should list) and drop the `.sub`
        // payload so it is never mistaken for a MicroDVD subtitle -- that
        // misroute is issue #44. A `.sub` with no `.idx` sibling is still a
        // legitimate MicroDVD/SubViewer text file and stays.
        val siblingNames = files.map { it.name }
        val subtitles = files.filter { file ->
            file.isFile &&
                isSubtitleFile(file.name) &&
                !isVobSubPayload(file.name, siblingNames)
        }
        if (subtitles.isEmpty()) return emptyList()

        val videoBase = video.name.substringBeforeLast('.')
        val videoCount = files.count { it.isFile && isVideoFile(it.name) }

        // Single video + single subtitle in the folder: unambiguous pair.
        if (videoCount == 1 && subtitles.size == 1) {
            return subtitles
        }

        val lowerBase = videoBase.lowercase(Locale.ROOT)
        val prefixed = subtitles.filter { it.name.lowercase(Locale.ROOT).startsWith("$lowerBase.") }
        val ordered = prefixed.sortedBy { it.name.lowercase(Locale.ROOT) }
        if (ordered.isNotEmpty()) return ordered

        // No prefix match: still expose all subtitles so the picker can choose.
        return subtitles.sortedBy { it.name.lowercase(Locale.ROOT) }
    }

    /// Re-encodes a subtitle file to UTF-8 if it isn't already, writing the
    /// converted bytes to a cache file. Files that already decode as UTF-8 (or
    /// carry a UTF-8/UTF-16 BOM) pass through untouched, so no temp file is
    /// created for the common case.
    ///
    /// Media3's text parsers decode UTF-8 only; many `.srt` files on Android /
    /// NAS are CP1252/CP1251, which otherwise render as mojibake.
    ///
    /// This runs on the platform thread during `open()`, so it must never load
    /// an arbitrarily large file. It previously did `readBytes()` on the whole
    /// sidecar with no size cap, then strictly UTF-8-decoded it, then built a
    /// String and re-encoded it. A 19 MB bitmap subtitle (VobSub `.sub`) put
    /// ~150-250 MB through the allocator on that thread and OOM-killed the app
    /// (issue #44). Charset sniffing is therefore bounded in three ways: a
    /// prefix is read rather than the file, a byte cap is enforced, and binary
    /// content is rejected outright. [pruneUtf8Cache] cleans up the temp files
    /// this can leave behind, which previously accumulated forever.
    fun toUtf8(context: Context, uri: Uri): Uri {
        val head = readPrefix(context, uri, SNIFF_BYTES) ?: return uri

        // A binary sidecar is never text. Never decode one as CP1252.
        if (looksBinary(head)) return uri

        val size = sizeOf(context, uri) ?: return uri
        if (size > MAX_SUBTITLE_BYTES) return uri

        val bytes = readAllBytes(context, uri) ?: return uri
        if (looksBinary(bytes)) return uri

        val charset = detectCharset(bytes)
        if (charset == StandardCharsets.UTF_8) return uri

        pruneUtf8Cache(context)
        val text = String(bytes, charset)
        val temp = File(context.cacheDir, "dreamplayer_sub_${System.currentTimeMillis()}.utf8")
        return try {
            temp.writeText(text, StandardCharsets.UTF_8)
            Uri.fromFile(temp)
        } catch (_: IOException) {
            uri
        }
    }

    /// Whether [head] looks like binary data rather than a text subtitle.
    ///
    /// Deliberately conservative: it only reports `true` on signals that no
    /// text subtitle format produces, because a false positive means the file
    /// is handed to the parser un-normalised (mojibake risk) while a false
    /// negative means the memory bomb in [toUtf8] comes back.
    internal fun looksBinary(head: ByteArray): Boolean {
        if (head.size >= 4 &&
            head[0] == 0x00.toByte() && head[1] == 0x00.toByte() &&
            head[2] == 0x01.toByte()
        ) {
            // MPEG program-stream pack header (00 00 01 BA) or a private-stream
            // PES start code (00 00 01 BD). VobSub `.sub` payloads are exactly
            // this: raw MPEG-PS carrying DVD subtitle packets.
            val third = head[2].toInt() and 0xff
            val fourth = head[3].toInt() and 0xff
            if (third == 0x01 && (fourth == 0xba || fourth == 0xbd)) return true
        }
        // PGS/DVB and other binary subtitle payloads start with a segment magic.
        if (head.size >= 4 && head[0] == 0x50.toByte() && head[1] == 0x47.toByte() &&
            head[2] == 0x53.toByte() && head[3] == 0x00.toByte()
        ) {
            return true
        }

        val limit = minOf(head.size, SNIFF_BYTES)
        if (limit < 16) return false

        var suspicious = 0
        for (i in 0 until limit) {
            val b = head[i].toInt() and 0xff
            val printable = b == 0x09 || b == 0x0a || b == 0x0d || (b in 0x20..0x7e) ||
                b == 0xef || b == 0xbb || b == 0xbf || b == 0xc2 || b in 0x80..0x9f
            if (!printable) {
                suspicious++
                // Short-circuit: a handful of odd bytes in a big text file is
                // normal, a fifth of them is not.
                if (suspicious * 20 > limit) return true
            }
        }
        return false
    }

    /// Deletes stale re-encoded subtitle temp files from a previous session.
    /// They are pure cache, so they are safe to drop unconditionally.
    internal fun pruneUtf8Cache(context: Context) {
        try {
            val dir = context.cacheDir
            val stale = dir.listFiles { f ->
                f.isFile && f.name.startsWith(UTF8_CACHE_PREFIX)
            } ?: return
            for (f in stale) {
                if (System.currentTimeMillis() - f.lastModified() > UTF8_CACHE_MAX_AGE_MS) {
                    f.delete()
                }
            }
        } catch (_: Exception) {
            // Cache cleanup is best-effort; never let it break playback.
        }
    }

    /// Sibling `.sub` payload URI for a VobSub `.idx`, or null when [uri] is not
    /// an `.idx` at all.
    ///
    /// Only the extension is rewritten — the directory, and any SAF tree or
    /// content authority in the URI, is preserved, so this works for local
    /// files and for tree-backed paths alike. Existence is not checked here;
    /// the caller decides how to handle an `.idx` with no payload beside it.
    ///
    /// Implemented as a string rewrite rather than through `Uri` so the rule is
    /// unit-testable on a plain JVM: `android.net.Uri` is a stub there and
    /// `Uri.parse` returns null under the standard unit-test android.jar.
    fun vobSubPayloadUri(idxUri: Uri): Uri? = vobSubPayloadUriString(idxUri.toString())?.let(Uri::parse)

    /// String form of [vobSubPayloadUri]. Split out so the extension-swap rule
    /// can be tested without an Android runtime.
    internal fun vobSubPayloadUriString(idxPath: String): String? {
        if (!isVobSubIndex(idxPath)) return null
        // substringBeforeLast('.') drops the extension *and* its dot, so the
        // dot has to go back on. Trimming by a literal length would strip the
        // dot too and yield "Movie sub"-style names.
        return idxPath.substringBeforeLast('.') + ".$VOBSUB_PAYLOAD_EXTENSION"
    }

    /// Reads at most [maxBytes] from [uri], or null if it cannot be read.
    ///
    /// Used for the VobSub `.idx`, which must be read whole (it carries the
    /// timings, palette and canvas size) but is a small text file. Bounded so a
    /// mislabeled file cannot pull an arbitrary blob into memory on the platform
    /// thread.
    internal fun readBounded(context: Context, uri: Uri, maxBytes: Int): ByteArray? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(maxBytes)
                var total = 0
                while (total < maxBytes) {
                    val read = input.read(buffer, total, maxBytes - total)
                    if (read <= 0) break
                    total += read
                }
                if (total == maxBytes && input.read() != -1) null else buffer.copyOf(total)
            }
        } catch (_: Exception) {
            null
        }
    }

    /// Upper bound for a VobSub `.idx`. Real ones are ~100-150 KB; this leaves
    /// plenty of headroom while still refusing a multi-megabyte blob.
    internal const val MAX_VOBSUB_IDX_BYTES = 4 * 1024 * 1024

    private fun readPrefix(context: Context, uri: Uri, count: Int): ByteArray? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(count)
                var total = 0
                while (total < count) {
                    val read = input.read(buffer, total, count - total)
                    if (read <= 0) break
                    total += read
                }
                if (total == count) buffer else buffer.copyOf(total)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun sizeOf(context: Context, uri: Uri): Long? {
        return try {
            if (uri.scheme == "file") {
                uri.path?.let { File(it).length() }
            } else {
                context.contentResolver.openAssetFileDescriptor(uri, "r")?.use {
                    it.length
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    /// Detects the charset of [bytes]: a UTF-16/UTF-8 BOM wins; otherwise a
    /// strict UTF-8 decode decides (valid -> UTF-8, invalid -> windows-1252).
    private fun detectCharset(bytes: ByteArray): Charset {
        if (bytes.size >= 2) {
            val first = bytes[0].toInt() and 0xff
            val second = bytes[1].toInt() and 0xff
            if (first == 0xfe && second == 0xff) return StandardCharsets.UTF_16BE
            if (first == 0xff && second == 0xfe) return StandardCharsets.UTF_16LE
        }
        if (bytes.size >= 3 &&
            (bytes[0].toInt() and 0xff) == 0xef &&
            (bytes[1].toInt() and 0xff) == 0xbb &&
            (bytes[2].toInt() and 0xff) == 0xbf
        ) {
            return StandardCharsets.UTF_8
        }
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes))
            StandardCharsets.UTF_8
        } catch (_: CharacterCodingException) {
            cp1252
        }
    }

    private fun readAllBytes(context: Context, uri: Uri): ByteArray? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (_: Exception) {
            null
        }
    }

    /// Decodes subtitle bytes to a String, honoring a UTF-8 BOM (which
    /// `String(bytes, UTF_8)` would otherwise surface as an invisible U+FEFF).
    /// All sidecars are normalized to UTF-8 by [toUtf8] before reaching a
    /// parser, so no other charset handling is needed here.
    fun decodeToString(bytes: ByteArray, offset: Int, length: Int): String {
        var start = offset
        var end = offset + length
        if (length >= 3 &&
            (bytes[offset].toInt() and 0xff) == 0xef &&
            (bytes[offset + 1].toInt() and 0xff) == 0xbb &&
            (bytes[offset + 2].toInt() and 0xff) == 0xbf
        ) {
            start += 3
        }
        return String(bytes, start, end - start, StandardCharsets.UTF_8)
    }

    /// windows-1252, the de-facto charset for legacy `.srt` files on Android
    /// (Media3 has no constant for it).
    private val cp1252: Charset by lazy {
        try {
            Charset.forName("windows-1252")
        } catch (_: Exception) {
            StandardCharsets.ISO_8859_1
        }
    }
}
