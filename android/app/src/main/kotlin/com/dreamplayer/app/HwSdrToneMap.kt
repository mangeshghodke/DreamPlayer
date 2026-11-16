package com.dreamplayer.app

import android.content.Context
import android.media.MediaFormat
import android.os.Build
import android.util.Log

/// Hardware SDR tone-mapping (GitHub issue #55).
///
/// When the user asks the decoder for SDR output, Android's
/// `MediaFormat.KEY_COLOR_TRANSFER_REQUEST` (= `COLOR_TRANSFER_SDR_VIDEO`)
/// makes a supporting codec tone-map the HDR/Dolby-Vision stream DOWN to
/// standard BT.709 in hardware. Qualcomm's `c2.qti.dv.decoder` logs
/// "SDR transcoding mode : dynamic!" and outputs
/// `YUV_709_NARROW_GAMMA`, which means:
///  * the system display colour modes (OxygenOS Vivid/Natural, white balance)
///    apply to the video window again, and
///  * Dolby Vision Profile 5 (IPTPQc2) no longer renders green/purple.
///
/// The request is advisory: a codec that does not implement it ignores the
/// key and keeps its native PQ output. So the app asks for it, then reports
/// what the codec ACTUALLY produced (see [outputTransfer]) instead of
/// pretending the conversion happened.
///
/// The key only exists from API 31 (S) - on older devices the request is
/// impossible and the setting is a no-op.
object HwSdrToneMap {

    private const val TAG = "HwSdrToneMap"

    /// Flutter's shared_preferences plugin stores under this file with a
    /// "flutter." key prefix (same file the decoder-mode pref uses).
    private const val PREFS = "FlutterSharedPreferences"
    private const val PREF_KEY = "flutter.dreamplayer.hwSdrToneMap"

    /// `MediaFormat.COLOR_TRANSFER_SDR_VIDEO` (3) - the value the codec
    /// reports when it really tone-mapped the stream to standard SDR.
    const val COLOR_TRANSFER_SDR = 3

    /// True when the user asked for hardware SDR tone-mapping. Read LIVE from
    /// the preferences (same pattern as [PlayerCodecs.decoderMode]) so the
    /// setting takes effect on the next opened video without recreating the
    /// player.
    fun isEnabled(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return prefs.getBoolean(PREF_KEY, false)
    }

    /// True when a request was injected into the current video codec.
    @Volatile
    var requested: Boolean = false
        private set

    /// The transfer characteristic the codec actually output (e.g. 3 = SDR,
    /// 6 = PQ). Null = unknown (codec did not report one). Read by the
    /// player view to label the picture honestly.
    @Volatile
    var outputTransfer: Int? = null
        private set

    /// Called by the renderers factory once the request was injected.
    fun markRequested() {
        requested = true
    }

    /// Per-open state reset.
    fun reset() {
        requested = false
        outputTransfer = null
    }

    /// Records the transfer the codec reported in its output format.
    fun onCodecOutputFormat(format: MediaFormat?) {
        if (format == null) return
        val transfer = try {
            if (format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                format.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
            } else {
                null
            }
        } catch (e: Exception) {
            null
        } ?: return
        if (outputTransfer != transfer) {
            outputTransfer = transfer
            Log.i(TAG, "codec output transfer=$transfer (${transferName(transfer)})")
        }
    }

    fun transferName(transfer: Int): String = when (transfer) {
        1 -> "Linear"
        2 -> "sRGB"
        COLOR_TRANSFER_SDR -> "SDR (709)"
        6 -> "PQ (ST2084)"
        7 -> "HLG"
        else -> "transfer $transfer"
    }

    /// The pure decision: should this video format get an SDR transfer
    /// request? Kept separate from the codec plumbing so it can be unit
    /// tested without a device.
    ///
    /// * [enabled] - the user's setting.
    /// * [sdkInt] - the Android API level of the device.
    /// * [mimeType] / [codecs] - the video track's mime type and codec
    ///   string. Dolby Vision is matched on both because Media3 reports
    ///   `video/dolby-vision` for DV tracks and the `dvhe`/`dvh1`/`dvav`
    ///   codec string; a DV MKV without the Colour element has NO
    ///   `colorInfo` at all, so the colour check alone would miss it.
    /// * [colorTransfer] - the declared transfer characteristic, or null when
    ///   the container does not carry one (the DV-without-Colour case, and
    ///   HDR10 MKVs whose PQ lives only in the HEVC SPS VUI - for those the
    ///   request is allowed only for HEVC Main10, never for 8-bit AVC, see
    ///   issue #64).
    fun shouldRequest(
        enabled: Boolean,
        sdkInt: Int,
        mimeType: String?,
        codecs: String?,
        colorTransfer: Int?,
    ): Boolean {
        if (!enabled) return false
        if (sdkInt < Build.VERSION_CODES.S) return false
        if (mimeType?.startsWith("video/") != true) return false
        if (isDolbyVision(mimeType, codecs)) return true
        if (colorTransfer == 6 || colorTransfer == 7) return true
        // GitHub issue #64: plain HDR10 MKVs often omit the MKV `Colour`
        // element, so `colorTransfer` is null even though the HEVC SPS VUI
        // carries PQ (the SEI probe reports those as HDR10 for the chip, but
        // this decision runs before/independent of it). Only HEVC Main10
        // (`hvc1.2…` / `hev1.2…`) can be HDR10 - and the request must NEVER
        // go to 8-bit AVC: on Qualcomm that froze the pipeline with
        // `QC2PipelinedEntity … failed to queueInputs, err 38` (grey picture,
        // audio kept playing) while an unrequested AVC file in the same
        // TextureView played fine.
        if (colorTransfer == null && mimeType == "video/hevc") {
            return codecs == null ||
                codecs.startsWith("hvc1.2") ||
                codecs.startsWith("hev1.2")
        }
        return false
    }

    /// Dolby Vision detection that does not need a colour info.
    private fun isDolbyVision(mimeType: String?, codecs: String?): Boolean {
        if (mimeType == "video/dolby-vision") return true
        return codecs?.let { Regex("dv(?:he|h1|av)\\.").containsMatchIn(it) } == true
    }
}
