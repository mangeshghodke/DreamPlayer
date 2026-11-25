package com.dreamplayer.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackParameters
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer

private const val TAG = "Ac3TranscodeSink"

/**
 * Issue #70 - "Transcode audio to AC3" (Dolby Digital) for receivers that only
 * support AC3 over HDMI (the reporter's Android TV box; Kodi does the same via
 * its AEEncoderFFmpeg).
 *
 * Wraps the normal [DefaultAudioSink] ([delegate]): compressed bitstream
 * formats (AC3 passthrough) keep flowing to the delegate untouched, while PCM
 * formats are re-encoded to AC3 with the FFmpeg AC3 encoder (see [Ac3Encoder])
 * and written to an [AudioTrack] opened with [AudioFormat.ENCODING_IEC61937],
 * IEC61937-packed per [packAc3Iec61937].
 *
 * Only installed by [DreamRenderersFactory.buildAudioSink] when
 * [PlayerCodecs.transcodeAc3Active] is true, so the default path is untouched.
 */
class Ac3TranscodeSink(
    private val context: Context,
    delegate: AudioSink,
) : ForwardingAudioSink(delegate) {

    private var transcoding = false
    private var audioTrack: AudioTrack? = null
    private var encoderHandle: Long = 0
    private var pcmSampleRate = 48000
    /** Channels sent to the AC3 encoder (clamped to 6 max - AC3 supports 5.1, not 7.1). */
    private var pcmChannels = 2
    /** Actual input channel count from the decoder (may exceed encoder max). */
    private var inputChannels = 2
    private var volume = 1f
    private var playbackParameters = PlaybackParameters.DEFAULT
    private var skipSilence = false
    private var started = false

    override fun supportsFormat(format: Format): Boolean {
        if (format.sampleRate > 0 && format.channelCount > 0 &&
            format.sampleMimeType == MimeTypes.AUDIO_RAW
        ) return true
        return super.supportsFormat(format)
    }

    override fun getFormatSupport(format: Format): Int {
        if (format.sampleRate > 0 && format.channelCount > 0 &&
            format.sampleMimeType == MimeTypes.AUDIO_RAW
        ) {
            return AudioSink.SINK_FORMAT_SUPPORTED_DIRECTLY
        }
        return super.getFormatSupport(format)
    }

    override fun configure(
        inputFormat: Format,
        outputStreamOffsetUs: Int,
        outputPcmSampleRateHint: IntArray?,
    ) {
        val isPcm = inputFormat.sampleMimeType == MimeTypes.AUDIO_RAW &&
            inputFormat.sampleRate > 0 && inputFormat.channelCount > 0
        if (!isPcm) {
            transcoding = false
            super.configure(inputFormat, outputStreamOffsetUs, outputPcmSampleRateHint)
            return
        }
        transcoding = true
        pcmSampleRate = inputFormat.sampleRate
        inputChannels = inputFormat.channelCount.coerceAtLeast(1)
        // AC3 encoder max is 5.1 (6 channels) - 7.1/8ch input must be downmixed.
        pcmChannels = inputChannels.coerceAtMost(6)
        if (!Ac3Encoder.ensureLoaded()) {
            Log.w(TAG, "ac3enc lib unavailable - falling back to delegate PCM sink")
            transcoding = false
            super.configure(inputFormat, outputStreamOffsetUs, outputPcmSampleRateHint)
            return
        }
        encoderHandle = Ac3Encoder.nativeOpen(
            pcmSampleRate, pcmChannels, Ac3Encoder.bitRateFor(pcmChannels),
        )
        if (encoderHandle == 0L) {
            Log.w(TAG, "AC3 encoder open failed - falling back to delegate PCM sink")
            transcoding = false
            super.configure(inputFormat, outputStreamOffsetUs, outputPcmSampleRateHint)
            return
        }
        val channelMask = when (pcmChannels) {
            1 -> AudioFormat.CHANNEL_OUT_MONO
            2 -> AudioFormat.CHANNEL_OUT_STEREO
            6 -> AudioFormat.CHANNEL_OUT_5POINT1
            8 -> AudioFormat.CHANNEL_OUT_7POINT1_SURROUND
            else -> AudioFormat.CHANNEL_OUT_STEREO
        }
        val audioFormat = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_IEC61937)
            .setSampleRate(pcmSampleRate)
            .setChannelMask(channelMask)
            .build()
        val minBuf = AudioTrack.getMinBufferSize(
            pcmSampleRate, channelMask, AudioFormat.ENCODING_IEC61937,
        )
        val bufSize = if (minBuf > 0) minBuf * 4 else 32 * 1024
        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setAudioFormat(audioFormat)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufSize)
                .build()
        } catch (e: Exception) {
            // No IEC61937-capable output on this device (e.g. a phone with no
            // HDMI) - fall back to the normal PCM sink instead of failing.
            Log.w(TAG, "IEC61937 AudioTrack unavailable (${e.message}) - falling back to PCM sink")
            if (encoderHandle != 0L) {
                Ac3Encoder.nativeClose(encoderHandle)
                encoderHandle = 0
            }
            transcoding = false
            super.configure(inputFormat, outputStreamOffsetUs, outputPcmSampleRateHint)
            return
        }
        audioTrack = track
        audioTrack?.setVolume(volume)
        Log.i(TAG, "transcoding PCM ${pcmSampleRate}Hz ${pcmChannels}ch -> AC3 IEC61937 (buf=$bufSize)")
    }

    override fun handleBuffer(
        buffer: ByteBuffer,
        presentationTimeUs: Long,
        sampleCount: Int,
    ): Boolean {
        if (!transcoding) return super.handleBuffer(buffer, presentationTimeUs, sampleCount)
        val track = audioTrack ?: return true
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        val samplesPerChannel = bytes.size / 2 / inputChannels
        if (samplesPerChannel <= 0) return true
        val pcmToEncode = if (inputChannels == pcmChannels) bytes else downmix(bytes, inputChannels, pcmChannels, samplesPerChannel)
        val frames = Ac3Encoder.nativeEncode(encoderHandle, pcmToEncode, samplesPerChannel)
            ?: return true
        // The encoder returns concatenated raw AC3 frames; each starts with
        // the 0x0B77 syncword. Split on syncwords and IEC-pack each frame.
        var start = -1
        var i = 0
        while (i + 1 < frames.size) {
            if (frames[i] == 0x0B.toByte() && frames[i + 1] == 0x77.toByte()) {
                if (start >= 0) writeAc3Frame(track, frames, start, i)
                start = i
            }
            i++
        }
        if (start >= 0) writeAc3Frame(track, frames, start, frames.size)
        return true
    }

    private fun writeAc3Frame(track: AudioTrack, data: ByteArray, from: Int, to: Int) {
        val frame = data.copyOfRange(from, to)
        val packed = packAc3Iec61937(frame)
        track.write(packed, 0, packed.size)
    }

    /// Downmixes interleaved s16 PCM from `fromChannels` to `toChannels` by
    /// taking the first `toChannels` channels of each interleaved frame.
    /// For 7.1→5.1 this keeps FL,FR,FC,LFE,SL,SR and drops the two surround-back
    /// channels (AC3 does not support 7.1).
    private fun downmix(pcm: ByteArray, fromChannels: Int, toChannels: Int, samplesPerChannel: Int): ByteArray {
        val out = ByteArray(samplesPerChannel * toChannels * 2)
        val s = ShortArray(samplesPerChannel * fromChannels)
        for (i in s.indices) {
            val b0 = pcm[i * 2].toInt() and 0xFF
            val b1 = pcm[i * 2 + 1].toInt() and 0xFF
            s[i] = (b0 or (b1 shl 8)).toShort()
        }
        var o = 0
        for (i in 0 until samplesPerChannel) {
            for (c in 0 until toChannels) {
                val v = s[i * fromChannels + c].toInt()
                out[o++] = (v and 0xFF).toByte()
                out[o++] = (v shr 8).toByte()
            }
        }
        return out
    }

    override fun play() {
        if (transcoding) {
            audioTrack?.play()
            started = true
        } else super.play()
    }

    override fun pause() {
        if (transcoding) audioTrack?.pause() else super.pause()
    }

    override fun flush() {
        if (transcoding) {
            audioTrack?.flush()
            if (encoderHandle != 0L) Ac3Encoder.nativeFlush(encoderHandle)
        } else super.flush()
    }

    override fun reset() {
        if (transcoding) {
            audioTrack?.flush()
            audioTrack?.release()
            audioTrack = null
            if (encoderHandle != 0L) {
                Ac3Encoder.nativeClose(encoderHandle)
                encoderHandle = 0
            }
            started = false
        } else super.reset()
    }

    override fun release() {
        if (transcoding) {
            reset()
        }
        super.release()
    }

    override fun handleDiscontinuity() {
        if (!transcoding) super.handleDiscontinuity()
        // encoder FIFO keeps continuity across seeks; flush partial frame
        if (transcoding && encoderHandle != 0L) {
            val tail = Ac3Encoder.nativeFlush(encoderHandle)
            val track = audioTrack
            if (tail != null && track != null) {
                val packed = packAc3Iec61937(tail)
                track.write(packed, 0, packed.size)
            }
        }
    }

    override fun getCurrentPositionUs(sourceEnded: Boolean): Long {
        if (!transcoding) return super.getCurrentPositionUs(sourceEnded)
        val track = audioTrack ?: return C.TIME_UNSET
        val frames = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        return if (pcmSampleRate > 0) frames * 1_000_000L / pcmSampleRate else C.TIME_UNSET
    }

    override fun isEnded(): Boolean {
        // Blocking MODE_STREAM writes pace the track; end-of-stream is driven
        // by playToEndOfStream(), so report not-ended here.
        if (!transcoding) return super.isEnded()
        return false
    }

    override fun hasPendingData(): Boolean {
        if (!transcoding) return super.hasPendingData()
        return false // writes are synchronous/blocking
    }

    override fun playToEndOfStream() {
        if (!transcoding) {
            super.playToEndOfStream()
            return
        }
        if (encoderHandle != 0L) {
            val tail = Ac3Encoder.nativeFlush(encoderHandle)
            val track = audioTrack
            if (tail != null && track != null) {
                val packed = packAc3Iec61937(tail)
                track.write(packed, 0, packed.size)
            }
        }
        audioTrack?.play()
    }

    override fun setVolume(volume: Float) {
        this.volume = volume
        if (transcoding) audioTrack?.setVolume(volume) else super.setVolume(volume)
    }

    override fun setPlaybackParameters(playbackParameters: PlaybackParameters) {
        this.playbackParameters = playbackParameters
        // Speed/pitch on an IEC bitstream output is not supported - AC3 frames
        // are fixed-rate. Accepted and ignored; Media3 still tracks the value.
        if (!transcoding) super.setPlaybackParameters(playbackParameters)
    }

    override fun getPlaybackParameters(): PlaybackParameters =
        if (transcoding) playbackParameters else super.getPlaybackParameters()

    override fun setSkipSilenceEnabled(skipSilenceEnabled: Boolean) {
        skipSilence = skipSilenceEnabled
        if (!transcoding) super.setSkipSilenceEnabled(skipSilenceEnabled)
    }

    override fun getSkipSilenceEnabled(): Boolean =
        if (transcoding) skipSilence else super.getSkipSilenceEnabled()

    override fun getAudioTrackBufferSizeUs(): Long {
        if (!transcoding) return super.getAudioTrackBufferSizeUs()
        val track = audioTrack ?: return C.TIME_UNSET
        val size = track.bufferSizeInFrames
        return if (pcmSampleRate > 0) size * 1_000_000L / pcmSampleRate else C.TIME_UNSET
    }

    override fun enableTunnelingV21() {
        if (!transcoding) super.enableTunnelingV21()
    }

    override fun disableTunneling() {
        if (!transcoding) super.disableTunneling()
    }
}
