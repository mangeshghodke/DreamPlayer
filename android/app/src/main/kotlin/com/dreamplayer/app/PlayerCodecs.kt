package com.dreamplayer.app

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import androidx.media3.common.MimeTypes
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import okhttp3.OkHttpClient
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

/// Shared codec/decoder selection for the in-app playback surface (the hybrid
/// platform view) and the audio-passthrough path:
///  * FLAC always goes through the FFmpeg renderer (platform MediaCodec FLAC
///    buffers are too small for 24-bit multi-channel frames on some devices);
///  * the Dolby E-AC3 component is skipped on devices where the codec2
///    resource manager churns it (endless audio-renderer re-init, no AudioTrack);
///  * audio passthrough (TV): when enabled AND HDMI is detected, return empty
///    decoder lists for the compressed surround formats so AudioTrack
///    bitstreams them to the TV / soundbar / AVR;
///  * Dolby Vision falls back to HEVC when no DV decoder exists (P7/P8 base
///    layers are HDR10 HEVC).
object PlayerCodecs {

    /// Whether audio passthrough is active: user toggle ON in Settings AND an
    /// HDMI output (TV / soundbar / AVR) is currently connected.
    fun passthroughEnabled(context: Context): Boolean {
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE,
        )
        if (!prefs.getBoolean("flutter.dreamplayer.audioPassthrough", false)) {
            return false
        }
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val hdmi = devices.any { d ->
            d.type == AudioDeviceInfo.TYPE_HDMI ||
                (Build.VERSION.SDK_INT >= 31 && d.type == AudioDeviceInfo.TYPE_HDMI_ARC) ||
                (Build.VERSION.SDK_INT >= 31 && d.type == AudioDeviceInfo.TYPE_HDMI_EARC)
        }
        android.util.Log.i("PlayerCodecs", "Audio passthrough: setting=ON, hdmi=$hdmi")
        return hdmi
    }

    fun isPassthroughFormat(mimeType: String?): Boolean = when (mimeType) {
        MimeTypes.AUDIO_AC3, MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC,
        MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD, MimeTypes.AUDIO_TRUEHD -> true
        else -> false
    }

    /// OkHttp HTTP data source factory. When [allowSelfSigned] is set the
    /// client trusts any certificate (per-server opt-in for self-signed WebDAV
    /// servers); otherwise the system trust store is used.
    fun httpDataSourceFactory(allowSelfSigned: Boolean): HttpDataSource.Factory {
        if (!allowSelfSigned) {
            return OkHttpDataSource.Factory(OkHttpClient())
        }
        val trustAll = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(null, arrayOf(trustAll), SecureRandom())
        val client = OkHttpClient.Builder()
            .sslSocketFactory(sslContext.socketFactory, trustAll)
            .hostnameVerifier { _, _ -> true }
            .build()
        return OkHttpDataSource.Factory(client)
    }

    fun decoderMode(context: Context): String {
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE,
        )
        return prefs.getString("flutter.dreamplayer.decoderMode", null) ?: "auto"
    }

    /**
     * Whether Media3 should decode audio with the bundled FFmpeg extension
     * instead of the platform MediaCodec decoders (issue #41).
     *
     * The libmpv engine decodes every track with `ad: ffmpeg`, so with this on
     * both engines run audio through the same libavcodec and the only
     * remaining difference is the sink.
     *
     * Opt-in rather than the default for two reasons:
     *  * TV/HDMI passthrough must win. The passthrough branch below is checked
     *    BEFORE this one, so bitstream output is unaffected when enabled.
     *  * FFmpeg audio is software decode. It is cheap for audio, but it is
     *    still a behaviour change for a path that currently works.
     */
    fun ffmpegAudioEnabled(context: Context): Boolean =
        context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE,
        ).getBoolean("flutter.dreamplayer.ffmpegAudio", false)

    private fun isSoftwareVideoDecoder(name: String): Boolean {
        val n = name.lowercase()
        return n.contains("google") || n.contains("ffmpeg") || n.startsWith("c2.android.")
    }

    fun mediaCodecSelector(context: Context): MediaCodecSelector {
        return MediaCodecSelector { mimeType, requiresSecureDecoder, requiresTunnelingDecoder ->
            // Read prefs LIVE on every query so a mode toggle takes effect on
            // the next `open()` without recreating the whole player view. Same
            // for passthrough (HDMI may be plugged/unplugged between files).
            val modeLive = decoderMode(context)
            val passthroughLive = passthroughEnabled(context)
            val ffmpegAudioLive = ffmpegAudioEnabled(context)
            val isVideo = mimeType?.startsWith("video/") == true
            fun filterByMode(list: List<androidx.media3.exoplayer.mediacodec.MediaCodecInfo>): List<androidx.media3.exoplayer.mediacodec.MediaCodecInfo> = when (modeLive) {
                "hw" -> list.filterNot { isSoftwareVideoDecoder(it.name) }
                "sw" -> list.filter { isSoftwareVideoDecoder(it.name) }
                // FFmpeg video: empty for video so Media3 uses the FfmpegVideoRenderer
                // extension; audio decoders stay normal (MediaCodec for best quality).
                "ffmpeg_video" -> if (isVideo) emptyList() else list
                else -> list
            }
            when {
                mimeType == MimeTypes.AUDIO_FLAC -> emptyList()
                // Passthrough: return empty for compressed surround formats so
                // DefaultAudioSink routes them to AudioTrack passthrough mode.
                // Checked BEFORE the FFmpeg-audio branch on purpose: on a TV
                // this must stay a raw bitstream, not get decoded to PCM.
                passthroughLive && isPassthroughFormat(mimeType) -> emptyList()
                // Match the libmpv engine: no platform decoder for audio, so
                // Media3 falls through to FfmpegAudioRenderer (the nextlib
                // extension appended in DreamRenderersFactory). One decoder for
                // both engines, which is the only way to compare their levels
                // meaningfully (issue #41).
                ffmpegAudioLive && !isVideo -> emptyList()
                mimeType == MimeTypes.AUDIO_E_AC3 || mimeType == MimeTypes.AUDIO_E_AC3_JOC ->
                    MediaCodecSelector.DEFAULT.getDecoderInfos(
                        mimeType,
                        requiresSecureDecoder,
                        requiresTunnelingDecoder,
                    ).filterNot { it.name.contains("dolby", ignoreCase = true) }
                // Dolby Vision: use the device's DV decoder when one exists
                // (P7/P8 base layers are HDR10 HEVC, so DV-less devices fall
                // back to the HEVC hardware decoder and play as HDR10).
                mimeType == MimeTypes.VIDEO_DOLBY_VISION -> {
                    val dv = filterByMode(
                        MediaCodecSelector.DEFAULT.getDecoderInfos(
                            mimeType,
                            requiresSecureDecoder,
                            requiresTunnelingDecoder,
                        ),
                    )
                    if (dv.isNotEmpty()) dv else filterByMode(
                        MediaCodecSelector.DEFAULT.getDecoderInfos(
                            MimeTypes.VIDEO_H265,
                            requiresSecureDecoder,
                            requiresTunnelingDecoder,
                        ),
                    )
                }
                isVideo -> filterByMode(
                    MediaCodecSelector.DEFAULT.getDecoderInfos(
                        mimeType,
                        requiresSecureDecoder,
                        requiresTunnelingDecoder,
                    ),
                )
                else -> MediaCodecSelector.DEFAULT.getDecoderInfos(
                    mimeType,
                    requiresSecureDecoder,
                    requiresTunnelingDecoder,
                )
            }
        }
    }
}