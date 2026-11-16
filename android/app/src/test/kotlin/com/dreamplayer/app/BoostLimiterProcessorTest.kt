package com.dreamplayer.app

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

/// Unit tests for the PCM boost + limiter (issue #41).
///
/// The OnePlus Pad 2 report: with Volume Boost above 100%, a 5.1 track played
/// through the tablet's speakers lost its dialogue while the rest of the mix
/// kept going. The cause was the fallback path, not the boost itself -
/// `LoudnessEnhancer` is hard-wired for stereo in AOSP, so attaching it to a
/// six-channel session mangled the centre channel. The replacement is this
/// processor: make-up gain plus a peak limiter, applied per channel on
/// whatever layout the decoder produced.
///
/// These tests pin the three properties that matter: no gain means no change,
/// a quiet signal gets exactly the requested gain, and a peak is limited to
/// the ceiling instead of wrapping.
class BoostLimiterProcessorTest {

    private val sampleRate = 48000
    private val channels = 2

    private fun processor(boostDb: Float): BoostLimiterProcessor {
        val p = BoostLimiterProcessor()
        p.configure(AudioProcessor.AudioFormat(sampleRate, channels, C.ENCODING_PCM_16BIT))
        p.setBoostDb(boostDb)
        return p
    }

    /// Runs [samples] (normalised, -1..1) through the processor and returns the
    /// output samples, also normalised.
    private fun run(p: BoostLimiterProcessor, samples: FloatArray): FloatArray {
        val bytes = ByteArray(samples.size * 2)
        samples.forEachIndexed { i, s ->
            val v = (s * 32768f).toInt().coerceIn(-32768, 32767)
            bytes[i * 2] = (v and 0xFF).toByte()
            bytes[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        p.queueInput(ByteBuffer.wrap(bytes))
        val out = p.getOutput()
        val outBytes = ByteArray(out.remaining())
        out.get(outBytes)
        return FloatArray(outBytes.size / 2) { i ->
            val v = ((outBytes[i * 2].toInt() and 0xFF) or (outBytes[i * 2 + 1].toInt() shl 8))
                .toShort().toInt()
            v / 32768f
        }
    }

    @Test
    fun `no boost leaves the samples untouched`() {
        val p = processor(0f)
        val input = floatArrayOf(0.1f, -0.25f, 0.5f, -0.75f)
        val out = run(p, input)
        assertEquals(input.size, out.size)
        input.forEachIndexed { i, v ->
            // Compare against the quantised input: PCM16 cannot hold 0.1
            // exactly, so the round trip is what "untouched" means.
            val quantised = (v * 32768f).toInt().coerceIn(-32768, 32767) / 32768f
            assertEquals(quantised, out[i], 1e-6f)
        }
    }

    @Test
    fun `a quiet signal gets exactly the requested gain`() {
        val p = processor(6f)
        val out = run(p, floatArrayOf(0.1f, -0.1f))
        // +6 dB is a factor of 1.9953.
        assertEquals(0.1f * 1.9953f, out[0], 0.001f)
        assertEquals(-0.1f * 1.9953f, out[1], 0.001f)
    }

    @Test
    fun `a full scale peak is limited to the ceiling instead of wrapping`() {
        val p = processor(12f)
        val out = run(p, floatArrayOf(0.9f, -0.9f))
        val ceiling = BoostLimiterProcessor.CEILING
        assertTrue("peak ${out[0]} must stay under the ceiling $ceiling", kotlin.math.abs(out[0]) <= ceiling + 0.001f)
        assertTrue("peak ${out[1]} must stay under the ceiling $ceiling", kotlin.math.abs(out[1]) <= ceiling + 0.001f)
    }

    @Test
    fun `the limiter recovers after the peak`() {
        val p = processor(12f)
        // One loud sample, then 100 ms of quiet at the same rate.
        val input = FloatArray(4801)
        input[0] = 0.9f
        for (i in 1 until input.size) input[i] = 0.1f
        val out = run(p, input)
        // The gain reduction must have released most of the way back, but the
        // release is exponential, so it is not fully back at 1.0 yet. Measured
        // against the make-up gain, not against the raw sample.
        val makeUp = Math.pow(10.0, 12.0 / 20.0).toFloat()
        val recovered = (out[input.size - 1] / 0.1f) / makeUp
        assertTrue("gain recovered to $recovered", recovered > 0.5f)
        assertTrue("gain recovered to $recovered", recovered <= 1.001f)
    }

    @Test
    fun `reset keeps the requested gain across a sink reconfigure`() {
        // Media3 calls reset() when it tears the sink down and reconfigures it
        // (format change, audio session recreation). The requested gain has to
        // survive that: reset() used to force linearGain back to 1 while
        // boostDb still said 6 dB, so the boost went silently silent until the
        // next gesture wrote a new value (issue #41).
        val p = processor(6f)
        p.reset()
        p.configure(AudioProcessor.AudioFormat(sampleRate, channels, C.ENCODING_PCM_16BIT))
        val out = run(p, floatArrayOf(0.1f, -0.1f))
        assertEquals(0.1f * 1.9953f, out[0], 0.001f)
        assertEquals(-0.1f * 1.9953f, out[1], 0.001f)
        assertEquals(6f, p.boostDb(), 1e-4f)
    }

    @Test
    fun `non PCM16 input is rejected so the sink can use the raw path`() {
        val p = BoostLimiterProcessor()
        var threw = false
        try {
            p.configure(AudioProcessor.AudioFormat(sampleRate, channels, C.ENCODING_PCM_FLOAT))
        } catch (e: AudioProcessor.UnhandledAudioFormatException) {
            threw = true
        }
        assertTrue("PCM float must be rejected", threw)
    }
}
