package com.dreamplayer.app

import androidx.media3.common.MimeTypes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Issue #70: IEC 61937 AC3 packing + the transcode passthrough rule. */
class Ac3TranscodeTest {

    // ── packAc3Iec61937 (pure) ─────────────────────────────────────────────

    @Test
    fun `packer writes sync words, AC3 type and bit length big-endian`() {
        // fake AC3 frame: byte 5 carries the bitstream mode (0x07 & 0x7)
        val frame = byteArrayOf(0x0B, 0x77, 0x10, 0x20, 0x30, 0x05, 0x60, 0x70)
        val packed = packAc3Iec61937(frame)
        // Pa/Pb sync words
        assertEquals(0xF8.toByte(), packed[0])
        assertEquals(0x72.toByte(), packed[1])
        assertEquals(0x4E.toByte(), packed[2])
        assertEquals(0x1F.toByte(), packed[3])
        // Pc = type AC3 (0x0001) | bsmod(0x05) << 8 = 0x0501, big-endian
        assertEquals(0x05.toByte(), packed[4])
        assertEquals(0x01.toByte(), packed[5])
        // Pd = frame size in bits = 8 * 8 = 64 = 0x0040, big-endian
        assertEquals(0x00.toByte(), packed[6])
        assertEquals(0x40.toByte(), packed[7])
        // payload: 16-bit words byte-swapped (big-endian), even-padded
        assertEquals(8 + 8, packed.size)
        assertEquals(0x77.toByte(), packed[8]) // swap(0x0B,0x77) -> 77 0B
        assertEquals(0x0B.toByte(), packed[9])
    }

    @Test
    fun `packer pads an odd-sized frame to even length`() {
        val frame = byteArrayOf(0x0B, 0x77, 0x55) // 3 bytes, bsmod = 0x55 & 7 = 5
        val packed = packAc3Iec61937(frame)
        assertEquals(8 + 4, packed.size)
        assertEquals(24.toByte(), packed[7]) // 3 * 8 = 24 bits
        assertEquals(0x00.toByte(), packed[8 + 3]) // pad byte stays zero
    }

    // ── passthroughFormatWithTranscode (pure) ──────────────────────────────

    @Test
    fun `transcode off keeps the full passthrough set`() {
        assertTrue(PlayerCodecs.passthroughFormatWithTranscode(MimeTypes.AUDIO_AC3, false))
        assertTrue(PlayerCodecs.passthroughFormatWithTranscode(MimeTypes.AUDIO_E_AC3_JOC, false))
        assertTrue(PlayerCodecs.passthroughFormatWithTranscode(MimeTypes.AUDIO_DTS_HD, false))
        assertFalse(PlayerCodecs.passthroughFormatWithTranscode(MimeTypes.AUDIO_AAC, false))
    }

    @Test
    fun `transcode on allows only AC3 to pass through`() {
        assertTrue(PlayerCodecs.passthroughFormatWithTranscode(MimeTypes.AUDIO_AC3, true))
        assertFalse(PlayerCodecs.passthroughFormatWithTranscode(MimeTypes.AUDIO_E_AC3, true))
        assertFalse(PlayerCodecs.passthroughFormatWithTranscode(MimeTypes.AUDIO_E_AC3_JOC, true))
        assertFalse(PlayerCodecs.passthroughFormatWithTranscode(MimeTypes.AUDIO_DTS, true))
        assertFalse(PlayerCodecs.passthroughFormatWithTranscode(MimeTypes.AUDIO_TRUEHD, true))
        assertFalse(PlayerCodecs.passthroughFormatWithTranscode(MimeTypes.AUDIO_AAC, true))
    }

    @Test
    fun `ac3 bitrate is 640k for multichannel and 320k for stereo`() {
        assertEquals(640_000, Ac3Encoder.bitRateFor(6))
        assertEquals(640_000, Ac3Encoder.bitRateFor(8))
        assertEquals(320_000, Ac3Encoder.bitRateFor(2))
        assertEquals(320_000, Ac3Encoder.bitRateFor(1))
    }
}
