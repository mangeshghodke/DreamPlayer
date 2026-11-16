package com.dreamplayer.app

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.roundToInt

/// PCM16 make-up gain with a peak limiter - the volume-boost path (issue #41).
///
/// Why this exists. `DynamicsProcessing` is the "supported" API for this, but it
/// is a vendor HAL effect: this app's test phone creates it, the reporter's
/// OnePlus Pad 2 refuses to create it at all (`setEngineArchitecture()` ->
/// "AudioEffect: bad parameter value"). The old fallback on that failure was
/// `LoudnessEnhancer`: a fixed, untunable compressor that AOSP hard-wires for
/// STEREO. Attaching it to a 5.1 session on the Pad 2 mangled the centre
/// channel - the dialogue - while the rest of the mix kept playing, so the
/// reporter heard "background music continues, vocals disappear".
///
/// So the boost lives here for every device, which also makes it the same
/// mechanism MPV uses (plain gain, no effect chain) - and the reporter
/// confirmed MPV sounds correct on the same speakers.
///
/// This processor runs INSIDE the sink, on whatever layout the decoder
/// produced, so it is channel-agnostic: six channels get six identical gains
/// and the centre channel is never dropped or summed away.
///
/// It is also a limiter, not a compressor. Only samples above the ceiling are
/// attenuated, so the mix keeps its dynamics - which is the whole point of the
/// rewrite away from `LoudnessEnhancer` (that one crushed the dialogue out of
/// the mix, see issue #41).
///
/// The limiter is a feed-forward peak limiter with an instant attack and an
/// exponential release: the gain drops the moment a sample would exceed the
/// ceiling and recovers over [RELEASE_SECONDS]. That is deliberately gentler
/// than a compressor, which would pull the whole band down and take the
/// dialogue with it.
///
/// PCM16 only, like [AudioDelayProcessor]: anything else throws
/// `UnhandledAudioFormatException` so the sink falls back to the raw path
/// (which is how HDMI bitstream passthrough survives the processor chain).
class BoostLimiterProcessor : AudioProcessor {

    @Volatile
    private var boostDb: Float = 0f

    /// Linear make-up gain for [boostDb].
    private var linearGain: Float = 1f

    /// Release coefficient per sample, derived from the sample rate.
    private var releaseCoef: Float = 0f

    /// Current gain-reduction multiplier (1 = untouched).
    private var envelope: Float = 1f

    private var sampleRate: Int = 0

    private var outputBuffer: ByteBuffer = AudioProcessor.EMPTY_BUFFER

    private var inputEnded: Boolean = false

    /** Set the make-up gain in dB. 0 disables the processor's gain. */
    fun setBoostDb(value: Float) {
        val db = value.coerceIn(0f, 12f)
        boostDb = db
        linearGain = 10.0.pow(db / 20.0).toFloat()
    }

    /** The make-up gain currently applied, in dB. */
    fun boostDb(): Float = boostDb

    override fun configure(
        inputAudioFormat: AudioProcessor.AudioFormat
    ): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        sampleRate = inputAudioFormat.sampleRate
        releaseCoef = if (sampleRate > 0) {
            1f - exp(-1.0 / (RELEASE_SECONDS * sampleRate)).toFloat()
        } else {
            0f
        }
        envelope = 1f
        inputEnded = false
        outputBuffer = AudioProcessor.EMPTY_BUFFER
        return inputAudioFormat
    }

    /// Always active: the processor is part of the sink's chain, and the
    /// boost value changes at gesture rate. Staying active means the chain is
    /// configured once and the gain is a parameter write, not a rebuild -
    /// the same reasoning as the in-place gain move on the effect path.
    override fun isActive(): Boolean = true

    override fun queueInput(input: ByteBuffer) {
        val count = input.remaining()
        if (count <= 0) {
            outputBuffer = AudioProcessor.EMPTY_BUFFER
            return
        }
        if (boostDb <= 0.01f || linearGain <= 1.0001f) {
            // Nothing to do: pass the input through untouched.
            outputBuffer = input
            return
        }
        val bytes = ByteArray(count)
        input.get(bytes)
        val out = ByteArray(count)
        var i = 0
        while (i + 1 < count) {
            val sample = ((bytes[i].toInt() and 0xFF) or (bytes[i + 1].toInt() shl 8))
                .toShort().toInt()
            val boosted = sample / 32768f * linearGain
            val magnitude = abs(boosted)
            var target = 1f
            if (magnitude > CEILING) {
                target = CEILING / magnitude
            }
            if (target < envelope) {
                // Instant attack: the peak is limited right here.
                envelope = target
            } else {
                envelope += (target - envelope) * releaseCoef
            }
            val limited = boosted * envelope
            val value = (limited * 32768f).roundToInt().coerceIn(-32768, 32767)
            out[i] = (value and 0xFF).toByte()
            out[i + 1] = ((value shr 8) and 0xFF).toByte()
            i += 2
        }
        // A trailing odd byte cannot be a whole sample; keep it as-is.
        if (i < count) {
            out[i] = bytes[i]
        }
        outputBuffer = ByteBuffer.wrap(out)
    }

    override fun queueEndOfStream() {
        inputEnded = true
    }

    override fun getOutput(): ByteBuffer = outputBuffer

    override fun isEnded(): Boolean = inputEnded && !outputBuffer.hasRemaining()

    override fun flush() {
        // Seek / track change: drop the gain-reduction state so the limiter
        // starts fresh instead of ramping up from the previous track.
        envelope = 1f
        inputEnded = false
        outputBuffer = AudioProcessor.EMPTY_BUFFER
    }

    override fun reset() {
        flush()
        sampleRate = 0
        releaseCoef = 0f
        // Keep the gain the player has already asked for. Media3 calls reset()
        // when the sink is torn down and reconfigured (format change, audio
        // session recreation); dropping the gain here while [boostDb] still
        // says 6 dB would leave the boost silently OFF until the next
        // setBoostDb, because queueInput gates on the linear value.
        linearGain = 10.0.pow(boostDb / 20.0).toFloat()
    }

    companion object {
        /// Ceiling for the limiter: -1 dBFS, so the hardest transient still
        /// has a hair of headroom and does not wrap.
        const val CEILING: Float = 0.891f

        /// How long the gain reduction takes to recover, in seconds.
        const val RELEASE_SECONDS: Float = 0.06f
    }
}
