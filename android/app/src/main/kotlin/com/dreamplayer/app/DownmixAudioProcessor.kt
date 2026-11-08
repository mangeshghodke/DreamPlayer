package com.dreamplayer.app

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/**
 * PCM16 surround-to-stereo downmix processor ("Downmix to stereo",
 * Settings -> Audio).
 *
 * Why this exists. Most movie/series audio is 5.1 or 7.1, and most people
 * listen on stereo headphones or speakers. A naive fold that just keeps
 * L/R drops the CENTRE channel — where the dialogue lives — so voices go
 * quiet while effects stay loud. This processor applies the standard
 * downmix matrix instead: centre and surrounds are mixed into both fronts
 * at -3 dB (sqrt(1/2)), LFE is dropped (no sub on a stereo setup):
 *
 *   6ch (5.1: FL FR FC LFE BL BR)   -> L' = FL + g*FC + g*BL,  R' = FR + g*FC + g*BR
 *   8ch (7.1: FL FR FC LFE BL BR SL SR) -> L' = FL + g*FC + g*BL + g*SL,
 *                                          R' = FR + g*FC + g*BR + g*SR
 *   other N>2                      -> L' = ch0 + g*avg(ch2..), R' = ch1 + g*avg(ch2..)
 *
 * This is the same matrix swresample/ffmpeg use by default, so Media3's
 * downmix and MPV's `audio-channels=stereo` sound alike.
 *
 * The output CHANNEL COUNT is fixed when the sink configures the chain, so
 * [enabled] is read in [configure] only: toggling the setting mid-playback
 * takes effect on the next track change / reopen (a sink reconfigure), not
 * mid-buffer — flipping the frame size under a live sink would corrupt it.
 *
 * The processor sits BEFORE [BoostLimiterProcessor] in the chain, so the
 * limiter catches any peak the downmix summing produces when boost is on.
 *
 * PCM16 only, like [AudioDelayProcessor] and [BoostLimiterProcessor]:
 * anything else throws `UnhandledAudioFormatException` so the sink uses
 * the raw path — which is how HDMI bitstream passthrough survives (a
 * bitstream is never decoded to PCM, so it is never downmixed here; the
 * receiver does its own downmix).
 */
class DownmixAudioProcessor : AudioProcessor {

    @Volatile
    private var enabled: Boolean = false

    /// Whether the CURRENT stream is being downmixed (decided in configure).
    private var active: Boolean = false

    private var inputChannels: Int = 0

    private var outputBuffer: ByteBuffer = AudioProcessor.EMPTY_BUFFER

    private var inputEnded: Boolean = false

    /** Enable/disable downmixing. Applies at the next sink configure. */
    fun setEnabled(value: Boolean) {
        enabled = value
    }

    fun isEnabled(): Boolean = enabled

    override fun configure(
        inputAudioFormat: AudioProcessor.AudioFormat
    ): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        inputChannels = inputAudioFormat.channelCount
        active = enabled && inputAudioFormat.channelCount > 2
        inputEnded = false
        outputBuffer = AudioProcessor.EMPTY_BUFFER
        return if (active) {
            AudioProcessor.AudioFormat(
                inputAudioFormat.sampleRate,
                2,
                inputAudioFormat.encoding,
            )
        } else {
            inputAudioFormat
        }
    }

    /// Always active: the chain is configured once per stream and the
    /// passthrough-vs-downmix decision is made in [configure]/[queueInput],
    /// never by adding/removing the processor (same reasoning as the delay
    /// and boost processors).
    override fun isActive(): Boolean = true

    override fun queueInput(input: ByteBuffer) {
        if (!active) {
            outputBuffer = input
            return
        }
        val channels = inputChannels.coerceAtLeast(1)
        val inBytesPerFrame = channels * 2
        val frames = input.remaining() / inBytesPerFrame
        if (frames <= 0) {
            outputBuffer = AudioProcessor.EMPTY_BUFFER
            return
        }
        val frame = IntArray(channels)
        val out = ByteArray(frames * 4)
        var outPos = 0
        for (f in 0 until frames) {
            for (c in 0 until channels) {
                frame[c] = ((input.get().toInt() and 0xFF) or (input.get().toInt() shl 8))
                    .toShort().toInt()
            }
            val stereo = downmixFrame(frame, channels)
            for (c in 0..1) {
                val v = stereo[c]
                out[outPos++] = (v and 0xFF).toByte()
                out[outPos++] = ((v shr 8) and 0xFF).toByte()
            }
        }
        outputBuffer = ByteBuffer.wrap(out)
    }

    override fun queueEndOfStream() {
        inputEnded = true
    }

    override fun getOutput(): ByteBuffer = outputBuffer

    override fun isEnded(): Boolean = inputEnded && !outputBuffer.hasRemaining()

    override fun flush() {
        // Seek / track transition: drop the pending output, keep the config.
        inputEnded = false
        outputBuffer = AudioProcessor.EMPTY_BUFFER
    }

    override fun reset() {
        flush()
        active = false
        inputChannels = 0
        // Keep `enabled`: Media3 calls reset() on sink teardown, and the next
        // configure() re-derives `active` from it (same rule as the boost
        // processor keeping its gain).
    }

    companion object {
        /// -3 dB mix gain for centre/surround channels (sqrt(1/2)).
        const val MIX_GAIN: Float = 0.7071f

        /**
         * Downmixes ONE interleaved frame of [channels] PCM16 samples to
         * stereo. [samples] holds exactly one frame (length == channels).
         * Pure — unit-tested without a device.
         */
        fun downmixFrame(samples: IntArray, channels: Int): IntArray {
            val g = MIX_GAIN
            val out = IntArray(2)
            when (channels) {
                6 -> {
                    // FL FR FC LFE BL BR
                    out[0] = samples[0] + (g * samples[2]).roundToInt() + (g * samples[4]).roundToInt()
                    out[1] = samples[1] + (g * samples[2]).roundToInt() + (g * samples[5]).roundToInt()
                }
                8 -> {
                    // FL FR FC LFE BL BR SL SR
                    out[0] = samples[0] + (g * samples[2]).roundToInt() +
                        (g * samples[4]).roundToInt() + (g * samples[6]).roundToInt()
                    out[1] = samples[1] + (g * samples[2]).roundToInt() +
                        (g * samples[5]).roundToInt() + (g * samples[7]).roundToInt()
                }
                else -> {
                    // Generic fold for any other layout > 2: average everything
                    // after the front pair into both outputs at -3 dB.
                    var rest = 0
                    for (c in 2 until channels) rest += samples[c]
                    val avg = if (channels > 2) rest.toFloat() / (channels - 2) else 0f
                    out[0] = samples[0] + (g * avg).roundToInt()
                    out[1] = samples[1] + (g * avg).roundToInt()
                }
            }
            out[0] = out[0].coerceIn(-32768, 32767)
            out[1] = out[1].coerceIn(-32768, 32767)
            return out
        }
    }
}
