package com.dreamplayer.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// Unit tests for the hardware SDR tone-mapping decision (issue #55).
///
/// The setting asks the video codec to output standard SDR
/// (`KEY_COLOR_TRANSFER_REQUEST = COLOR_TRANSFER_SDR_VIDEO`) instead of the
/// source's HDR/Dolby-Vision signal, so the system's display colour modes
/// apply again. The request is only worth sending when
///  * the user asked for it,
///  * the device has the key (API 31+), and
///  * the track really is HDR or Dolby Vision.
///
/// The last one is the subtle part: a Dolby Vision MKV without the `Colour`
/// element carries NO colour info at all (Media3's MatroskaExtractor never
/// reads the HEVC VUI), so a colour-info-only check would silently skip
/// exactly the files the feature is for.
class HwSdrToneMapTest {

    private fun request(
        enabled: Boolean = true,
        sdkInt: Int = 31,
        mimeType: String? = "video/hevc",
        codecs: String? = "hev1.2.4.L153.B0",
        colorTransfer: Int? = 6,
    ) = HwSdrToneMap.shouldRequest(
        enabled = enabled,
        sdkInt = sdkInt,
        mimeType = mimeType,
        codecs = codecs,
        colorTransfer = colorTransfer,
    )

    @Test
    fun `disabled setting never requests`() {
        assertFalse(request(enabled = false))
    }

    @Test
    fun `old Android has no transfer request key`() {
        // KEY_COLOR_TRANSFER_REQUEST was added in API 31.
        assertFalse(request(sdkInt = 30))
        assertTrue(request(sdkInt = 31))
    }

    @Test
    fun `hdr10 and hlg are requested`() {
        assertTrue(request(colorTransfer = 6))
        assertTrue(request(colorTransfer = 7))
    }

    @Test
    fun `sdr content is left alone`() {
        assertFalse(request(colorTransfer = 2))
        // 8-bit AVC with no colour info must NEVER get the request: on
        // Qualcomm it froze the pipeline (`queueInputs, err 38`, grey
        // picture) - issue #64.
        assertFalse(
            request(
                mimeType = "video/avc",
                codecs = "avc1.640028",
                colorTransfer = null,
            ),
        )
        // 8-bit HEVC Main (not Main10) with no colour info is not HDR10.
        assertFalse(
            request(
                mimeType = "video/hevc",
                codecs = "hev1.1.6.L120.90",
                colorTransfer = null,
            ),
        )
    }

    @Test
    fun `hdr10 mkv without colour element requests only for hevc main10`() {
        // Issue #64: many HDR10 MKVs omit the `Colour` element, so
        // colorTransfer is null; the PQ info lives only in the HEVC SPS VUI.
        assertTrue(
            request(mimeType = "video/hevc", codecs = "hev1.2.4.L153.B0", colorTransfer = null),
        )
        assertTrue(
            request(mimeType = "video/hevc", codecs = "hvc1.2.4.L153.B0", colorTransfer = null),
        )
        // Unknown codec string on HEVC is allowed (can't tell 8- vs 10-bit).
        assertTrue(
            request(mimeType = "video/hevc", codecs = null, colorTransfer = null),
        )
        // But never AVC (see `sdr content is left alone`) and never 8-bit
        // HEVC Main.
        assertFalse(
            request(mimeType = "video/avc", codecs = null, colorTransfer = null),
        )
        assertFalse(
            request(mimeType = "video/av01", codecs = "av01.0.08M.10", colorTransfer = null),
        )
    }

    @Test
    fun `dolby vision without colour info is still requested`() {
        // The Colour-element-less DV MKV: no colorInfo at all.
        assertTrue(
            request(
                mimeType = "video/dolby-vision",
                codecs = "dvhe.08.06",
                colorTransfer = null,
            ),
        )
        assertTrue(
            request(
                mimeType = "video/hevc",
                codecs = "dvav.09.06",
                colorTransfer = null,
            ),
        )
    }

    @Test
    fun `audio tracks are never touched`() {
        assertFalse(request(mimeType = "audio/mp4a-latm", colorTransfer = null))
    }
}
