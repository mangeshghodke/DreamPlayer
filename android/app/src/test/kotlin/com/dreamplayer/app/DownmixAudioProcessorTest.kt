package com.dreamplayer.app

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/// Unit tests for the surround-to-stereo downmix processor (Settings -> Audio
/// "Downmix to stereo").
///
/// The point of the feature: on stereo headphones/speakers a naive fold that
/// keeps only L/R drops the centre channel, so dialogue goes quiet while
/// effects stay loud. These tests pin that the centre is mixed into BOTH
/// outputs at -3 dB, that LFE is dropped, that clipping saturates instead of
/// wrapping, and that disabled/stereo streams pass through byte-identical.
class DownmixAudioProcessorTest {

    private val sampleRate = 48000
    private val g = DownmixAudioProcessor.MIX_GAIN

    private fun pcm16(values: IntArray): ByteBuffer {
        val bytes = ByteArray(values.size * 2)
        values.forEachIndexed { i, v ->
            bytes[i * 2] = (v and 0xFF).toByte()
            bytes[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return ByteBuffer.wrap(bytes)
    }

    private fun decode(buf: ByteBuffer): IntArray {
        val bytes = ByteArray(buf.remaining())
        buf.get(bytes)
        return IntArray(bytes.size / 2) { i ->
            ((bytes[i * 2].toInt() and 0xFF) or (bytes[i * 2 + 1].toInt() shl 8))
                .toShort().toInt()
        }
    }

    private fun processor(enabled: Boolean, channels: Int): DownmixAudioProcessor {
        val p = DownmixAudioProcessor()
        p.setEnabled(enabled)
        p.configure(AudioProcessor.AudioFormat(sampleRate, channels, C.ENCODING_PCM_16BIT))
        return p
    }

    // ---- pure matrix ----

    @Test
    fun `5_1 centre is mixed into both outputs at -3dB`() {
        val out = DownmixAudioProcessor.downmixFrame(intArrayOf(0, 0, 10000, 0, 0, 0), 6)
        val expected = (g * 10000).roundToInt()
        assertArrayEquals(intArrayOf(expected, expected), out)
        assertEquals(7071, expected) // sanity: -3 dB of 10000
    }

    @Test
    fun `5_1 LFE is dropped`() {
        val out = DownmixAudioProcessor.downmixFrame(intArrayOf(0, 0, 0, 32767, 0, 0), 6)
        assertArrayEquals(intArrayOf(0, 0), out)
    }

    @Test
    fun `5_1 front left goes only to left`() {
        val out = DownmixAudioProcessor.downmixFrame(intArrayOf(10000, 0, 0, 0, 0, 0), 6)
        assertArrayEquals(intArrayOf(10000, 0), out)
    }

    @Test
    fun `5_1 surrounds fold to their side`() {
        val bl = DownmixAudioProcessor.downmixFrame(intArrayOf(0, 0, 0, 0, 10000, 0), 6)
        val br = DownmixAudioProcessor.downmixFrame(intArrayOf(0, 0, 0, 0, 0, 10000), 6)
        assertArrayEquals(intArrayOf((g * 10000).roundToInt(), 0), bl)
        assertArrayEquals(intArrayOf(0, (g * 10000).roundToInt()), br)
    }

    @Test
    fun `7_1 side surrounds fold to their side`() {
        val sl = DownmixAudioProcessor.downmixFrame(
            intArrayOf(0, 0, 0, 0, 0, 0, 10000, 0), 8,
        )
        val sr = DownmixAudioProcessor.downmixFrame(
            intArrayOf(0, 0, 0, 0, 0, 0, 0, 10000), 8,
        )
        assertArrayEquals(intArrayOf((g * 10000).roundToInt(), 0), sl)
        assertArrayEquals(intArrayOf(0, (g * 10000).roundToInt()), sr)
    }

    @Test
    fun `summing clips at full scale instead of wrapping`() {
        val out = DownmixAudioProcessor.downmixFrame(
            intArrayOf(32767, 32767, 32767, 0, 32767, 32767), 6,
        )
        assertArrayEquals(intArrayOf(32767, 32767), out)
    }

    @Test
    fun `generic layout averages the rest into both outputs`() {
        // 4ch: front pair + two rears, no centre/LFE slot semantics.
        val out = DownmixAudioProcessor.downmixFrame(intArrayOf(1000, 2000, 3000, 4000), 4)
        val avg = (3000f + 4000f) / 2
        assertArrayEquals(
            intArrayOf(1000 + (g * avg).roundToInt(), 2000 + (g * avg).roundToInt()),
            out,
        )
    }

    // ---- processor behaviour ----

    @Test
    fun `enabled 6ch configures a stereo output format and downmixes`() {
        val p = processor(enabled = true, channels = 6)
        val outFormat = p.configure(
            AudioProcessor.AudioFormat(sampleRate, 6, C.ENCODING_PCM_16BIT),
        )
        assertEquals(2, outFormat.channelCount)
        assertEquals(sampleRate, outFormat.sampleRate)

        p.queueInput(pcm16(intArrayOf(1000, 2000, 3000, 0, 4000, 5000)))
        val out = decode(p.getOutput())
        assertEquals(2, out.size)
        val c = (g * 3000).roundToInt()
        assertEquals(1000 + c + (g * 4000).roundToInt(), out[0])
        assertEquals(2000 + c + (g * 5000).roundToInt(), out[1])
    }

    @Test
    fun `disabled leaves the format and bytes untouched`() {
        val p = processor(enabled = false, channels = 6)
        val outFormat = p.configure(
            AudioProcessor.AudioFormat(sampleRate, 6, C.ENCODING_PCM_16BIT),
        )
        assertEquals(6, outFormat.channelCount)
        val input = pcm16(intArrayOf(1, 2, 3, 4, 5, 6))
        p.queueInput(input)
        val outBytes = ByteArray(p.getOutput().remaining())
        p.getOutput().get(outBytes)
        val expected = ByteArray(12)
        intArrayOf(1, 2, 3, 4, 5, 6).forEachIndexed { i, v ->
            expected[i * 2] = (v and 0xFF).toByte()
            expected[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        assertArrayEquals(expected, outBytes)
    }

    @Test
    fun `enabled stereo input still passes through`() {
        val p = processor(enabled = true, channels = 2)
        val outFormat = p.configure(
            AudioProcessor.AudioFormat(sampleRate, 2, C.ENCODING_PCM_16BIT),
        )
        assertEquals(2, outFormat.channelCount)
        p.queueInput(pcm16(intArrayOf(111, -222)))
        assertArrayEquals(intArrayOf(111, -222), decode(p.getOutput()))
    }

    @Test
    fun `mono is not forced to stereo`() {
        val p = processor(enabled = true, channels = 1)
        val outFormat = p.configure(
            AudioProcessor.AudioFormat(sampleRate, 1, C.ENCODING_PCM_16BIT),
        )
        assertEquals(1, outFormat.channelCount)
    }

    @Test
    fun `non-PCM16 input is rejected so passthrough survives`() {
        val p = DownmixAudioProcessor()
        p.setEnabled(true)
        val threw = try {
            p.configure(AudioProcessor.AudioFormat(sampleRate, 6, C.ENCODING_PCM_FLOAT))
            false
        } catch (e: AudioProcessor.UnhandledAudioFormatException) {
            true
        }
        assertTrue("float (bitstream-adjacent) formats must throw", threw)
    }

    @Test
    fun `reset keeps the enabled flag for the next configure`() {
        val p = processor(enabled = true, channels = 6)
        p.reset()
        assertTrue(p.isEnabled())
        val outFormat = p.configure(
            AudioProcessor.AudioFormat(sampleRate, 6, C.ENCODING_PCM_16BIT),
        )
        assertEquals(2, outFormat.channelCount)
        assertFalse(processor(enabled = false, channels = 6).let { p2 ->
            p2.configure(AudioProcessor.AudioFormat(sampleRate, 6, C.ENCODING_PCM_16BIT)).channelCount == 2
        })
    }
}
