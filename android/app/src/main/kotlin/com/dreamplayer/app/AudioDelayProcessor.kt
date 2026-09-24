package com.dreamplayer.app

import java.nio.ByteBuffer
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.C

/**
 * PCM16 audio-delay processor: shifts the audio track relative to video for
 * manual A/V sync (the audio-side companion of the subtitle delay).
 *
 * Positive delay = audio plays LATER (held back in a pending buffer);
 * negative delay = audio plays EARLIER (leading samples are dropped).
 * The delay is dynamic — changing it mid-stream takes effect immediately:
 * increasing holds back more audio, reducing flushes the excess (audio jumps
 * forward), crossing into negative starts dropping.
 *
 * PCM16 only (the sink's processing chain operates in PCM16); anything else
 * throws UnhandledAudioFormatException and the sink falls back.
 */
class AudioDelayProcessor : AudioProcessor {

    @Volatile
    private var delayMs: Long = 0L

    private var sampleRate = 0
    private var bytesPerFrame = 0
    private var inputEnded = false

    /// Samples held back for a positive delay (audio not yet emitted).
    private var pending = ByteArray(0)
    private var pendingLen = 0

    /// Bytes still to drop for a negative delay.
    private var dropRemaining = 0L

    private var outputBuffer: ByteBuffer = AudioProcessor.EMPTY_BUFFER

    /** Sets the delay in milliseconds; positive = audio later. Clamped ±5 s. */
    fun setDelayMs(value: Long) {
        delayMs = value.coerceIn(-5000L, 5000L)
    }

    fun delayMilliseconds(): Long = delayMs

    override fun configure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        // A new stream (track change / reconfig): drop any held-back audio.
        pendingLen = 0
        dropRemaining = 0
        inputEnded = false
        outputBuffer = AudioProcessor.EMPTY_BUFFER
        sampleRate = inputAudioFormat.sampleRate
        bytesPerFrame = inputAudioFormat.bytesPerFrame
        return inputAudioFormat
    }

    override fun isActive(): Boolean = true

    override fun queueInput(input: ByteBuffer) {
        val delay = delayMs
        if (delay == 0L) {
            // Drain anything held back from an earlier positive delay first,
            // then pass the input through untouched.
            if (pendingLen > 0) {
                val n = input.remaining()
                outputBuffer = ByteBuffer.allocateDirect(pendingLen + n)
                outputBuffer.put(pending, 0, pendingLen)
                if (n > 0) outputBuffer.put(input)
                outputBuffer.flip()
                pendingLen = 0
            } else {
                outputBuffer = input
            }
            return
        }
        if (delay > 0) {
            appendToPending(input)
            val targetBytes = targetPendingBytes(delay)
            val emit = pendingLen - targetBytes
            outputBuffer = if (emit > 0) {
                val out = ByteBuffer.allocateDirect(emit)
                out.put(pending, 0, emit)
                out.flip()
                removeFromPendingHead(emit)
                out
            } else {
                AudioProcessor.EMPTY_BUFFER
            }
        } else {
            // Negative delay: drop the leading samples of the stream.
            // Audio still held back from a POSITIVE delay (the slider was
            // dragged straight through 0, e.g. +2000ms to -500ms, with no
            // call landing on exactly 0) must be drained here too — this and
            // the delay==0 branch above are the only places that read
            // `pending`, so without this the buffered audio was stranded
            // until one glitchy burst at end-of-stream, or silently lost if
            // a seek's flush() ran first, leaving a lasting A/V desync.
            if (pendingLen > 0) {
                val n = input.remaining()
                val combined = ByteBuffer.allocateDirect(pendingLen + n)
                combined.put(pending, 0, pendingLen)
                if (n > 0) combined.put(input)
                combined.flip()
                pendingLen = 0
                outputBuffer = combined
                return
            }
            var toDrop = -delay * sampleRate * bytesPerFrame / 1000 - dropRemaining
            if (toDrop > 0) {
                val n = minOf(toDrop, input.remaining().toLong()).toInt()
                // Align to whole frames so we never split a sample.
                val aligned = n - (n % bytesPerFrame.coerceAtLeast(1))
                input.position(input.position() + aligned)
                dropRemaining += aligned
                toDrop -= aligned
            }
            outputBuffer = input
        }
    }

    override fun queueEndOfStream() {
        inputEnded = true
        if (pendingLen > 0) {
            outputBuffer = ByteBuffer.allocateDirect(pendingLen)
            outputBuffer.put(pending, 0, pendingLen)
            outputBuffer.flip()
            pendingLen = 0
        }
    }

    override fun getOutput(): ByteBuffer = outputBuffer

    override fun isEnded(): Boolean = inputEnded && pendingLen == 0 &&
        !outputBuffer.hasRemaining()

    override fun flush() {
        // Seek / track transition: discard pending audio, keep the delay.
        pendingLen = 0
        dropRemaining = 0
        inputEnded = false
        outputBuffer = AudioProcessor.EMPTY_BUFFER
    }

    override fun reset() {
        flush()
        sampleRate = 0
        bytesPerFrame = 0
    }

    private fun targetPendingBytes(delayMs: Long): Int {
        val bytes = delayMs * sampleRate * bytesPerFrame / 1000
        // Align down to whole frames.
        val frame = bytesPerFrame.coerceAtLeast(1)
        return (bytes / frame * frame).toInt().coerceAtLeast(0)
    }

    private fun appendToPending(input: ByteBuffer) {
        val n = input.remaining()
        if (n == 0) return
        if (pendingLen + n > pending.size) {
            var newSize = pending.size.coerceAtLeast(8192)
            while (newSize < pendingLen + n) newSize *= 2
            pending = pending.copyOf(newSize)
        }
        input.get(pending, pendingLen, n)
        pendingLen += n
    }

    private fun removeFromPendingHead(count: Int) {
        if (count >= pendingLen) {
            pendingLen = 0
            return
        }
        pending.copyInto(pending, 0, count, pendingLen)
        pendingLen -= count
    }
}
