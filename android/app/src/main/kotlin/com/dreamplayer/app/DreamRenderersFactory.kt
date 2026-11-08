package com.dreamplayer.app

import android.content.Context
import android.os.Handler
import android.util.Log
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.mediacodec.ForwardingMediaCodecAdapter
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegAudioRenderer
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener
import android.media.MediaFormat
import android.os.Build
import java.util.ArrayList

class DreamRenderersFactory(private val appContext: Context) : DefaultRenderersFactory(appContext) {
    init {
        setAllowedVideoJoiningTimeMs(0L)
    }

    companion object {
        /// Manual A/V sync: shifts audio relative to video (±5 s). Shared so
        /// the `setAudioDelay` channel handler can retune it mid-playback.
        val audioDelayProcessor = AudioDelayProcessor()

        /// Volume boost: make-up gain + peak limiter on the decoded PCM. Shared
        /// so the player can move the gain at gesture rate without rebuilding
        /// the sink, and because it is the ONLY boost path — no vendor audio
        /// effect is involved (issue #41).
        val audioBoostProcessor = BoostLimiterProcessor()

        /// Downmix to stereo (Settings -> Audio): folds 5.1/7.1 PCM into 2.0
        /// with the centre channel kept at -3 dB, so dialogue survives on
        /// stereo headphones/speakers. Sits BEFORE the boost processor so the
        /// limiter catches any peak the downmix summing produces.
        val audioDownmixProcessor = DownmixAudioProcessor()
    }

    /// Inserts the audio-delay and audio-boost processors into every audio
    /// sink (platform and FFmpeg renderers both receive this sink from
    /// buildAudioRenderers).
    override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioTrackPlaybackParams: Boolean,
    ): AudioSink =
        DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(enableFloatOutput)
            .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
            .setAudioProcessors(
                arrayOf(audioDelayProcessor, audioDownmixProcessor, audioBoostProcessor),
            )
            .build()

    /// Injects the hardware SDR tone-mapping request into the video codec
    /// (GitHub issue #55).
    ///
    /// Media3 hands the renderer a `MediaFormat` and then configures the
    /// codec with THAT SAME instance (verified in Media3 1.10.1:
    /// `MediaCodecVideoRenderer.getMediaFormat` → `Configuration
    /// .createForVideoDecoding` → `AsynchronousMediaCodecAdapter$Factory
    /// .createAdapter` → `MediaCodec.configure(mediaFormat, …)`), so setting
    /// `KEY_COLOR_TRANSFER_REQUEST` on `configuration.mediaFormat` here really
    /// reaches the decoder.
    ///
    /// The request is advisory — a codec that does not implement it ignores
    /// the key and keeps its native PQ output. The created adapter is
    /// therefore wrapped so the ACTUAL output transfer can be reported back
    /// (the picture label must not claim an SDR conversion that never
    /// happened).
    override fun getCodecAdapterFactory(): MediaCodecAdapter.Factory {
        val defaultFactory = super.getCodecAdapterFactory()
        return object : MediaCodecAdapter.Factory {
            override fun createAdapter(
                configuration: MediaCodecAdapter.Configuration,
            ): MediaCodecAdapter {
                val format = configuration.format
                val wantsSdr = HwSdrToneMap.shouldRequest(
                    enabled = HwSdrToneMap.isEnabled(appContext),
                    sdkInt = Build.VERSION.SDK_INT,
                    mimeType = format.sampleMimeType,
                    codecs = format.codecs,
                    colorTransfer = format.colorInfo?.colorTransfer,
                )
                if (wantsSdr) {
                    try {
                        configuration.mediaFormat.setInteger(
                            MediaFormat.KEY_COLOR_TRANSFER_REQUEST,
                            MediaFormat.COLOR_TRANSFER_SDR_VIDEO,
                        )
                        HwSdrToneMap.markRequested()
                        Log.i(
                            "DreamRenderersFactory",
                            "hardware SDR tone-map requested for ${format.sampleMimeType} " +
                                "/${format.codecs} (transfer=${format.colorInfo?.colorTransfer})",
                        )
                    } catch (e: Exception) {
                        Log.w("DreamRenderersFactory", "SDR transfer request failed", e)
                    }
                }
                val adapter = defaultFactory.createAdapter(configuration)
                return object : ForwardingMediaCodecAdapter(adapter) {
                    override fun getOutputFormat(): MediaFormat {
                        val out = super.getOutputFormat()
                        if (wantsSdr) HwSdrToneMap.onCodecOutputFormat(out)
                        return out
                    }
                }
            }
        }
    }

    override fun buildVideoRenderers(
        context: Context,
        extensionRendererMode: Int,
        codecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        eventHandler: Handler,
        eventListener: VideoRendererEventListener,
        allowedJoiningTimeMs: Long,
        out: ArrayList<Renderer>,
    ) {
        super.buildVideoRenderers(
            context,
            extensionRendererMode,
            codecSelector,
            enableDecoderFallback,
            eventHandler,
            eventListener,
            allowedJoiningTimeMs,
            out,
        )
        // Add FfmpegVideoRenderer as ultimate fallback (after all MediaCodec
        // renderers). Used when hardware + software MediaCodec decoders both
        // fail (e.g. 10-bit HEVC on devices without 10-bit MediaCodec support).
        // Added at the END so HDR/DV hardware path stays primary.
        // Constructor: (allowedJoiningTimeMs, handler, eventListener, maxDroppedFramesToNotify)
        try {
            out.add(FfmpegVideoRenderer(allowedJoiningTimeMs, eventHandler, eventListener, 0))
            Log.i("DreamRenderersFactory", "Loaded FfmpegVideoRenderer as fallback.")
        } catch (e: Exception) {
            Log.w("DreamRenderersFactory", "FfmpegVideoRenderer unavailable, falling back to MediaCodec only.", e)
        }
    }

    override fun buildAudioRenderers(
        context: Context,
        extensionRendererMode: Int,
        codecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        audioSink: AudioSink,
        eventHandler: Handler,
        eventListener: AudioRendererEventListener,
        out: ArrayList<Renderer>,
    ) {
        super.buildAudioRenderers(
            context,
            extensionRendererMode,
            codecSelector,
            enableDecoderFallback,
            audioSink,
            eventHandler,
            eventListener,
            out,
        )
        try {
            out.add(FfmpegAudioRenderer(eventHandler, eventListener, audioSink))
            Log.i("DreamRenderersFactory", "Loaded FfmpegAudioRenderer.")
        } catch (e: Exception) {
            Log.w("DreamRenderersFactory", "FfmpegAudioRenderer unavailable, falling back to MediaCodec only.", e)
        }
    }
}
