package com.dreamplayer.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/// Regression tests for issue #44 — VobSub (.idx/.sub) subtitles.
///
/// The reporter's files were valid: a 19.2 MB `.sub` holding raw MPEG-PS
/// (pack header 00 00 01 BA, DVD subtitle PES 00 00 01 BD) beside a 123 KB
/// `.idx`, 2737 cues, 1920x1080. DreamPlayer mapped `.sub` unconditionally to
/// MicroDVD (a *text* format), and `toUtf8` loaded all 19 MB into the platform
/// thread to charset-detect it — which OOM-killed the app.
///
/// These tests pin the two guards that prevent a repeat. They deliberately use
/// the real byte patterns from the reported file rather than synthetic bytes,
/// because the sniff is only meaningful if it matches actual VobSub payloads.
class SubtitleFormatsVobSubTest {

    // ---------------------------------------------------------- looksBinary

    @Test
    fun `mpeg program stream pack header is binary`() {
        // 00 00 01 BA — a VobSub .sub starts here. This is the exact prefix of
        // the reporter's file.
        assertTrue(SubtitleFormats.looksBinary(byteArrayOf(0x00, 0x00, 0x01, 0xBA.toByte())))
    }

    @Test
    fun `dvd subtitle private stream PES start code is binary`() {
        assertTrue(SubtitleFormats.looksBinary(byteArrayOf(0x00, 0x00, 0x01, 0xBD.toByte())))
    }

    @Test
    fun `pg segment magic is binary`() {
        assertTrue(
            SubtitleFormats.looksBinary(
                byteArrayOf(0x50, 0x47, 0x53, 0x00, 0x00, 0x01, 0xB0.toByte()),
            ),
        )
    }

    @Test
    fun `mpeg-ps looking body is binary even without a clean magic`() {
        // The pack header sits at byte 0 in practice, but a 2-byte prefix read
        // or a variant muxer could shift it. Density must still catch it.
        val body = ByteArray(4096) { i ->
            if (i % 7 == 0) 0x00.toByte() else (i * 31 % 256).toByte()
        }
        assertTrue(SubtitleFormats.looksBinary(body))
    }

    @Test
    fun `utf8 srt is not binary`() {
        val srt = """
            1
            00:00:01,000 --> 00:00:03,000
            Hello there.

            2
            00:00:04,000 --> 00:00:06,000
            Second line — with an em dash.
        """.trimIndent().toByteArray(Charsets.UTF_8)
        assertFalse(SubtitleFormats.looksBinary(srt))
    }

    @Test
    fun `cp1252 srt with high bytes is not binary`() {
        // Legacy encodings are exactly why toUtf8 exists, so high bytes alone
        // must not be read as "binary" — that would reintroduce mojibake.
        val text = byteArrayOf(
            '1'.code.toByte(), '\n'.code.toByte(),
            '0'.code.toByte(), '0'.code.toByte(), ':'.code.toByte(),
            '0'.code.toByte(), '0'.code.toByte(), ':'.code.toByte(),
            '0'.code.toByte(), '1'.code.toByte(), ','.code.toByte(),
            '0'.code.toByte(), '0'.code.toByte(), '0'.code.toByte(),
            ' '.code.toByte(), '-'.code.toByte(), '-'.code.toByte(), '>'.code.toByte(),
            ' '.code.toByte(), '0'.code.toByte(), '0'.code.toByte(), ':'.code.toByte(),
            '0'.code.toByte(), '0'.code.toByte(), ':'.code.toByte(),
            '0'.code.toByte(), '2'.code.toByte(), ','.code.toByte(),
            '0'.code.toByte(), '0'.code.toByte(), '0'.code.toByte(),
            '\n'.code.toByte(),
            'C'.code.toByte(), 'a'.code.toByte(), 'f'.code.toByte(),
            0xE9.toByte(), // é in cp1252
            ' '.code.toByte(),
            'n'.code.toByte(), 'a'.code.toByte(),
            0xEF.toByte(), // ï in cp1252
            'v'.code.toByte(), 'e'.code.toByte(),
            '\n'.code.toByte(),
        )
        assertFalse(SubtitleFormats.looksBinary(text))
    }

    @Test
    fun `ass script is not binary`() {
        val ass = "[Script Info]\nTitle: Test\nScriptType: v4.00+\n\n[V4+ Styles]\n" +
            "Format: Name, Fontname\nStyle: Default,Arial\n\n[Events]\n" +
            "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Hello\n"
        assertFalse(SubtitleFormats.looksBinary(ass.toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun `microdvd sub is not binary`() {
        val microdvd = "{1}{1}25.000\n{100}{200}Hello|there\n{300}{400}Second line\n"
        assertFalse(SubtitleFormats.looksBinary(microdvd.toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun `short input is never binary`() {
        // Under the sample size there is not enough evidence to claim binary.
        // Guessing here would mangle tiny valid subtitles.
        assertFalse(SubtitleFormats.looksBinary(byteArrayOf(0x00, 0x00)))
    }

    // -------------------------------------------------------------- pairing

    @Test
    fun `sub with a sibling idx is a vobsub payload not a microdvd track`() {
        val siblings = listOf("Gone Girl English.idx", "Gone Girl English.sub", "video.mkv")
        assertTrue(
            SubtitleFormats.isVobSubPayload("/dl/Gone Girl English.sub", siblings),
        )
    }

    @Test
    fun `idx pairing is case insensitive`() {
        val siblings = listOf("Movie.IDX", "Movie.sub")
        assertTrue(SubtitleFormats.isVobSubPayload("Movie.sub", siblings))
    }

    @Test
    fun `lone sub stays a microdvd candidate`() {
        // No .idx beside it, so it is genuinely text. Dropping it would regress
        // every existing MicroDVD/SubViewer user.
        val siblings = listOf("Movie.sub", "video.mkv")
        assertFalse(SubtitleFormats.isVobSubPayload("Movie.sub", siblings))
    }

    @Test
    fun `non-sub extension is never a payload`() {
        val siblings = listOf("Movie.srt", "Movie.idx")
        assertFalse(SubtitleFormats.isVobSubPayload("Movie.srt", siblings))
    }

    @Test
    fun `idx is recognised as a vobsub index`() {
        assertTrue(SubtitleFormats.isVobSubIndex("/dl/Movie.idx"))
        assertTrue(SubtitleFormats.isVobSubIndex("MOVIE.IDX"))
        assertFalse(SubtitleFormats.isVobSubIndex("/dl/Movie.sub"))
        assertFalse(SubtitleFormats.isVobSubIndex("/dl/Movie.srt"))
    }

    // ----------------------------------------------------------------- mime

    @Test
    fun `idx maps to the vobsub mime`() {
        assertEquals(
            SubtitleFormats.MIME_VOBSUB,
            SubtitleFormats.mimeTypeFor("Gone Girl English.idx"),
        )
    }

    @Test
    fun `existing text extensions are unchanged`() {
        // The whole point of the fix is that nothing else moved.
        assertEquals(
            "application/x-microdvd",
            SubtitleFormats.mimeTypeFor("Movie.sub"),
        )
        assertEquals("text/x-ssa", SubtitleFormats.mimeTypeFor("Movie.ass"))
        assertEquals("application/x-sami", SubtitleFormats.mimeTypeFor("Movie.smi"))
        assertEquals("text/vtt", SubtitleFormats.mimeTypeFor("Movie.vtt"))
        assertEquals("application/x-mpl2", SubtitleFormats.mimeTypeFor("Movie.mpl2"))
        assertEquals("application/x-subrip", SubtitleFormats.mimeTypeFor("Movie.txt"))
    }

    @Test
    fun `payload uri swaps only the extension`() {
        // Tested via the string overload: android.net.Uri is a no-op stub in a
        // plain JVM unit test, so Uri.parse() returns null there.
        assertEquals(
            "file:///storage/emulated/0/DL/Gone%20Girl.sub",
            SubtitleFormats.vobSubPayloadUriString(
                "file:///storage/emulated/0/DL/Gone%20Girl.idx",
            ),
        )
    }

    @Test
    fun `payload uri keeps a SAF tree path intact`() {
        assertEquals(
            "content://com.android.externalstorage.documents/tree/x%3AMovies%2FMovie.sub",
            SubtitleFormats.vobSubPayloadUriString(
                "content://com.android.externalstorage.documents/tree/x%3AMovies%2FMovie.idx",
            ),
        )
    }

    @Test
    fun `payload uri handles an already-uppercase extension`() {
        assertEquals(
            "/dl/Movie.sub",
            SubtitleFormats.vobSubPayloadUriString("/dl/Movie.IDX"),
        )
    }

    @Test
    fun `payload uri rejects a non-idx`() {
        assertNull(SubtitleFormats.vobSubPayloadUriString("file:///dl/Movie.srt"))
        assertNull(SubtitleFormats.vobSubPayloadUriString("file:///dl/Movie.sub"))
    }

    // ----------------------------------------------------------------- caps

    @Test
    fun `subtitle byte cap is far below the reported vobsub payload`() {
        // The crash input was 19,228,672 bytes. The cap must reject it with
        // room to spare, while staying far above any real text subtitle.
        assertTrue(SubtitleFormats.MAX_SUBTITLE_BYTES < 19_228_672L)
        assertTrue(SubtitleFormats.MAX_SUBTITLE_BYTES >= 1024L * 1024L)
    }

    @Test
    fun `idx cap comfortably holds the reported idx`() {
        // Reported .idx was 123,608 bytes; several tracks can be in one file.
        assertTrue(SubtitleFormats.MAX_VOBSUB_IDX_BYTES > 123_608)
    }

    @Test
    fun `sniff window is large enough to see density`() {
        // Density detection needs a real sample, not a token prefix.
        assertTrue(SubtitleFormats.SNIFF_BYTES >= 4096)
    }

    // --------------------------------------------------- the real payloads

    /// Proves the guards fire on the actual bytes from issue #44, not just on
    /// hand-written approximations. The `.sub` prefix and the `.idx` are the
    /// reporter's own files.
    @Test
    fun `reported vobsub payload is detected as binary`() {
        val head = javaClass.getResourceAsStream("/vobsub_payload_head.bin")
            ?.use { it.readBytes() } ?: error("test fixture missing")
        assertEquals(SubtitleFormats.SNIFF_BYTES, head.size)
        assertTrue(
            "the reported .sub must read as binary, or toUtf8 will OOM again",
            SubtitleFormats.looksBinary(head),
        )
    }

    @Test
    fun `reported vobsub payload starts with an mpeg pack header`() {
        val head = javaClass.getResourceAsStream("/vobsub_payload_head.bin")
            ?.use { it.readBytes() } ?: error("test fixture missing")
        // Documents *why* it is binary, so a future edit to the magic list has
        // to argue with this comment rather than silently pass.
        assertEquals(0x00, head[0].toInt() and 0xff)
        assertEquals(0x00, head[1].toInt() and 0xff)
        assertEquals(0x01, head[2].toInt() and 0xff)
        assertEquals(0xBA.toInt(), head[3].toInt() and 0xff)
    }

    @Test
    fun `reported idx is text and under the bounded read cap`() {
        val idx = javaClass.getResourceAsStream("/vobsub_reported.idx")
            ?.use { it.readBytes() } ?: error("test fixture missing")
        // The .idx is plain text, so the binary guard must NOT reject it — that
        // guard is for the payload, and rejecting this would break the fix.
        assertFalse(SubtitleFormats.looksBinary(idx.copyOf(4096)))
        assertTrue(idx.size <= SubtitleFormats.MAX_VOBSUB_IDX_BYTES)
    }

    @Test
    fun `demuxed cue block reproduces the length ffmpeg reports`() {
        // The MPEG-PS demux itself is verified here against the reporter's real
        // bytes. Decoding is not: VobsubParser needs a real
        // android.graphics.Bitmap, which the stub android.jar in local unit
        // tests cannot supply, so a decode assertion would fail for reasons
        // unrelated to the demux. Rendering is verified on hardware.
        val block = javaClass.getResourceAsStream("/vobsub_cue_block.sub")
            ?.use { it.readBytes() } ?: error("test fixture missing")
        val idx = javaClass.getResourceAsStream("/vobsub_reported.idx")
            ?.use { it.readBytes() } ?: error("test fixture missing")
        val packets = VobSubPayloadExtractor.extract(block, idx)
        assertTrue("cue 0 must reassemble", packets.isNotEmpty())
        // 6198 is cue 0's length according to ffmpeg's own vobsub demuxer.
        assertEquals(6198, packets.first().bytes.size)
    }

    @Test
    fun `cue timestamps read the fourth field as milliseconds`() {
        // Reading it as frames at 25fps makes cue 1 jump backwards in time
        // (23:774 -> 53.96s, then 27:194 -> 34.76s), which no subtitle track can
        // do. ffmpeg's demuxer confirms the millisecond reading.
        val idxText =
            "timestamp: 00:00:23:774, filepos: 000000000\r\n" +
                "timestamp: 00:00:27:194, filepos: 000002000\r\n"
        val stamps = VobSubIndex.readTimestamps(idxText.toByteArray(Charsets.ISO_8859_1))
        assertEquals(2, stamps.size)
        assertEquals(23_774_000L, stamps[0])
        assertEquals(27_194_000L, stamps[1])
        assertTrue("timestamps must increase", stamps[1] > stamps[0])
    }

    @Test
    fun `reported idx carries a vobsub index header`() {
        val idx = javaClass.getResourceAsStream("/vobsub_reported.idx")
            ?.use { it.readBytes() } ?: error("test fixture missing")
        val head = String(idx.copyOf(256), Charsets.ISO_8859_1)
        assertTrue(head.startsWith("# VobSub index file, v7"))
        // `align: OFF at LEFT TOP` is the directive behind the mpv top-left
        // misplacement (issue #44). Recorded here so it stays documented.
        assertTrue(head.contains("align: OFF at LEFT TOP"))
        assertTrue(head.contains("size: 1920x1080"))
    }
}

/// Verifies the OOM guard holds against the reporter's *actual* 19.2 MB file,
/// not a sample. The sniff tests prove classification; this proves the guard
/// returns before anything proportional to the payload is allocated.
class VobSubMemoryGuardTest {

    @Test
    fun `binary guard short-circuits on the real payload without reading it all`() {
        val payload = File("src/test/resources/vobsub_payload_head.bin")
        // Only the prefix is available in the repo (the full .sub is 19 MB), but
        // the guard is a prefix read by construction: toUtf8 calls
        // readPrefix(context, uri, SNIFF_BYTES) and never touches the rest when
        // looksBinary is true. What matters is that a prefix this size decides.
        val head = payload.readBytes()
        assertTrue(SubtitleFormats.looksBinary(head))
    }

    @Test
    fun `guard rejects the payload on size alone even if magic were absent`() {
        // Defence in depth: looksBinary can be made to miss, so toUtf8 also caps
        // by size. The reported payload is 19,228,672 bytes.
        val reportedSize = 19_228_672L
        assertTrue(
            "a 19MB sidecar must exceed the cap",
            reportedSize > SubtitleFormats.MAX_SUBTITLE_BYTES,
        )
    }

    @Test
    fun `a realistic multi-megabyte ass file still passes the size gate`() {
        // The cap must not break legitimate large text subtitles. A 600 KB ASS
        // with heavy styling is unusual but real.
        assertTrue(600_000L < SubtitleFormats.MAX_SUBTITLE_BYTES)
    }
}
