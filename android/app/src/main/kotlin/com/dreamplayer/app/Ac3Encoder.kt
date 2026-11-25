package com.dreamplayer.app

import android.util.Log

/**
 * JNI wrapper around the minimal FFmpeg build that contains only the AC3
 * encoder (`libac3enc.so`, built from `ac3enc_jni.c` + `tool/build_ffmpeg_ac3.sh`).
 * Same encoder Kodi uses for "transcode to Dolby Digital"
 * (xbmc AEEncoderFFmpeg: AV_CODEC_ID_AC3, S16P planar, 1536-sample frames).
 *
 * Raw AC3 frames out; IEC61937 packing happens in [packAc3Iec61937].
 */
object Ac3Encoder {
    private const val TAG = "Ac3Encoder"
    private var libLoaded = false

    @Synchronized
    fun ensureLoaded(): Boolean {
        if (libLoaded) return true
        return try {
            System.loadLibrary("ac3enc")
            libLoaded = true
            true
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "libac3enc not available on this ABI: ${e.message}")
            false
        }
    }

    external fun nativeOpen(sampleRate: Int, channels: Int, bitRate: Int): Long
    external fun nativeEncode(handle: Long, pcm: ByteArray, samplesPerChannel: Int): ByteArray?
    external fun nativeFlush(handle: Long): ByteArray?
    external fun nativeClose(handle: Long)

    /** AC3 bitrate: 640 kbps for multichannel (the AC3 5.1 ceiling), 320 kbps stereo. */
    fun bitRateFor(channels: Int): Int = if (channels > 2) 640_000 else 320_000
}

/**
 * IEC 61937 burst packing for one raw AC3 frame (per IEC 61937-1 and Kodi's
 * `CAEPackIEC61937::PackAC3`):
 *
 *   Pa = 0xF872, Pb = 0x4E1F  (sync words, big-endian on the wire)
 *   Pc = 0x0001 | (bsmod << 8) (AC3 data type + bitstream mode from frame byte 5)
 *   Pd = frame size in BITS    (big-endian)
 *   payload = AC3 frame with each 16-bit word byte-swapped (big-endian),
 *             zero-padded to an even byte count.
 *
 * Pure function so it can be unit-tested on the JVM.
 */
fun packAc3Iec61937(frame: ByteArray): ByteArray {
    val bsmod = if (frame.size > 5) frame[5].toInt() and 0x7 else 0
    val type = 0x0001 or (bsmod shl 8)
    val bits = frame.size * 8
    val padded = frame.size + (frame.size and 1)
    val out = ByteArray(8 + padded)
    out[0] = 0xF8.toByte()
    out[1] = 0x72.toByte()
    out[2] = 0x4E.toByte()
    out[3] = 0x1F.toByte()
    out[4] = (type shr 8).toByte()
    out[5] = type.toByte()
    out[6] = (bits shr 8).toByte()
    out[7] = bits.toByte()
    var i = 0
    while (i + 1 < frame.size) {
        out[8 + i] = frame[i + 1]
        out[9 + i] = frame[i]
        i += 2
    }
    if (i < frame.size) {
        out[8 + i] = frame[i] // odd tail byte, next byte stays 0
    }
    return out
}
