package com.dreamplayer.app

import androidx.media3.common.MimeTypes
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pins the TV audio-passthrough format list: an Atmos .m4a carries
/// E-AC3-JOC and MUST bitstream to HDMI when passthrough is on (user request:
/// ".m4a is Atmos music file ... proper native decoding on passthrough").
class PlayerCodecsTest {

    @Test
    fun `passthrough formats include all compressed surround codecs`() {
        assertTrue(PlayerCodecs.isPassthroughFormat(MimeTypes.AUDIO_AC3))
        assertTrue(PlayerCodecs.isPassthroughFormat(MimeTypes.AUDIO_E_AC3))
        // Dolby Atmos in m4a / E-AC3-JOC:
        assertTrue(PlayerCodecs.isPassthroughFormat(MimeTypes.AUDIO_E_AC3_JOC))
        assertTrue(PlayerCodecs.isPassthroughFormat(MimeTypes.AUDIO_DTS))
        assertTrue(PlayerCodecs.isPassthroughFormat(MimeTypes.AUDIO_DTS_HD))
        assertTrue(PlayerCodecs.isPassthroughFormat(MimeTypes.AUDIO_TRUEHD))
    }

    @Test
    fun `passthrough excludes PCM and lossy stereo formats`() {
        assertFalse(PlayerCodecs.isPassthroughFormat(MimeTypes.AUDIO_FLAC))
        assertFalse(PlayerCodecs.isPassthroughFormat(MimeTypes.AUDIO_AAC))
        assertFalse(PlayerCodecs.isPassthroughFormat("audio/mpeg"))   // mp3
        assertFalse(PlayerCodecs.isPassthroughFormat("audio/opus"))
        assertFalse(PlayerCodecs.isPassthroughFormat("audio/vorbis"))
        assertFalse(PlayerCodecs.isPassthroughFormat("audio/wav"))
        assertFalse(PlayerCodecs.isPassthroughFormat(null))
    }
}
