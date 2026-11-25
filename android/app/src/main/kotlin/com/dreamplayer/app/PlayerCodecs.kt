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

    /// Whether an HDMI output (TV / soundbar / AVR) is currently connected.
    fun hasHdmiOutput(context: Context): Boolean {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return devices.any { d ->
            d.type == AudioDeviceInfo.TYPE_HDMI ||
                (Build.VERSION.SDK_INT >= 31 && d.type == AudioDeviceInfo.TYPE_HDMI_ARC) ||
                (Build.VERSION.SDK_INT >= 31 && d.type == AudioDeviceInfo.TYPE_HDMI_EARC)
        }
    }

    /// Whether audio passthrough is active: user toggle ON in Settings AND an
    /// HDMI output (TV / soundbar / AVR) is currently connected.
    fun passthroughEnabled(context: Context): Boolean {
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE,
        )
        if (!prefs.getBoolean("flutter.dreamplayer.audioPassthrough", false)) {
            return false
        }
        val hdmi = hasHdmiOutput(context)
        android.util.Log.i("PlayerCodecs", "Audio passthrough: setting=ON, hdmi=$hdmi")
        return hdmi
    }

    /// Issue #70: "Transcode audio to AC3" (Settings → Audio, Android only).
    /// Active when the toggle is ON and an HDMI output is connected - the
    /// point is feeding a receiver that only supports Dolby Digital (AC3).
    fun transcodeAc3Active(context: Context): Boolean {
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE,
        )
        val on = prefs.getBoolean("flutter.dreamplayer.audioTranscodeAc3", false)
        if (!on) return false
        // Debug/testing escape hatch: force the transcode path on devices
        // without HDMI (e.g. a phone) so the sink can be exercised on-device.
        val force = prefs.getBoolean("flutter.dreamplayer.audioTranscodeAc3Force", false)
        // Debug builds: the AC3 toggle alone also engages the path, so it can
        // be verified on a phone (release builds still require HDMI).
        if (BuildConfig.DEBUG) {
            android.util.Log.i("PlayerCodecs", "AC3 transcode: toggle=ON (debug build, hdmi=${hasHdmiOutput(context)})")
            return true
        }
        return force || hasHdmiOutput(context)
    }

    fun isPassthroughFormat(mimeType: String?): Boolean = when (mimeType) {
        MimeTypes.AUDIO_AC3, MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC,
        MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD, MimeTypes.AUDIO_TRUEHD -> true
        else -> false
    }

    /// Issue #70: when AC3 transcoding is active, only AC3 itself may pass
    /// through as a bitstream - everything else (E-AC3/DTS/TrueHD/…) must be
    /// decoded to PCM so the sink can re-encode it to AC3. A receiver that
    /// only supports Dolby Digital cannot take the other formats.
    /// Pure so it can be unit-tested without a Context.
    fun passthroughFormatWithTranscode(mimeType: String?, transcodeActive: Boolean): Boolean {
        if (transcodeActive) return mimeType == MimeTypes.AUDIO_AC3
        return isPassthroughFormat(mimeType)
    }

    fun effectivePassthroughFormat(context: Context, mimeType: String?): Boolean =
        passthroughFormatWithTranscode(mimeType, transcodeAc3Active(context))

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
            val transcodeLive = transcodeAc3Active(context)
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
                // Issue #70: with AC3 transcoding active only AC3 passes through
                // (see effectivePassthroughFormat) - the rest is decoded and
                // re-encoded to AC3 by Ac3TranscodeSink.
                passthroughLive && effectivePassthroughFormat(context, mimeType) -> emptyList()
                // Same rule when only transcoding is on (passthrough toggle off):
                // AC3 bitstreams may still pass through; everything else decodes.
                transcodeLive && mimeType == MimeTypes.AUDIO_AC3 -> emptyList()
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