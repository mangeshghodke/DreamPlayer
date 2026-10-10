package com.dreamplayer.app

import androidx.media3.common.util.UnstableApi

/// Demuxes a VobSub `.sub` file into the DVD subtitle packets Media3's
/// `VobsubParser` expects.
///
/// **Why this exists.** A VobSub track is `Name.idx` (a plain-text index of cue
/// timestamps, canvas size and palette) plus `Name.sub` (the bitmap data).
/// Inside Matroska, `S_VOBSUB` block data is *already* a bare run of DVD
/// subtitle packets, which is what `VobsubParser` consumes. A sidecar `.sub`
/// is instead a whole MPEG-Program-Stream, and one cue's packet is **fragmented
/// across several PES frames** — the reporter's file splits a 6198-byte cue into
/// four ~2028-byte frames. Handing the parser the file verbatim yields nothing.
///
/// **Structure, as written by every VobSub muxer:**
///   `00 00 01 BA`  MPEG-2 pack header — a *fixed* 14 bytes. It has no stuffing
///                  field; reading one produced a 248-byte skip that derailed
///                  the walk entirely.
///   `00 00 01 BD`  PES packet, private stream 1, then a 2-byte length that
///                  covers the *whole* packet including its header.
///                  The first fragment of a cue carries a 9-byte header
///                  (PTS + substream id); continuations carry a 4-byte one.
///   A pack header sits between fragments, so cue boundaries cannot be found by
///   stepping on packet length alone.
///
/// The DVD packet declares its own total length in its first two bytes (the same
/// `AV_RB16(buf)` that `dvdsubdec.c` reads); the reassembly is trimmed to it,
/// which matters when the final PES frame is padded.
///
/// **Validated against ffmpeg rather than assumed**: running ffmpeg's own vobsub
/// demuxer over the reporter's `.idx` agrees with this on 2736 of 2737 cues,
/// and muxing the same VobSub into an MKV yields byte-identical packets.
@UnstableApi
object VobSubPayloadExtractor {

    /// MPEG-2 pack header length. Fixed — there is no stuffing count to read.
    private const val PACK_HEADER_LENGTH = 14

    /// First-fragment PES header: `0x81 0x80` + 5-byte PTS + substream id pair.
    private const val FIRST_FRAGMENT_HEADER = 9

    /// Continuation-fragment PES header: `0x81 0x00 0x00` + 1 byte.
    private const val CONTINUATION_HEADER = 4

    private const val PACK_START = 0x000001BA
    private const val PRIVATE_STREAM_1 = 0x000001BD

    /// A DVD subtitle packet carries a small run of commands; anything larger
    /// means a misread length and must not be allocated.
    private const val MAX_PACKET_LENGTH = 1 shl 20

    private val FILEPOS = Regex("""filepos:\s*([0-9A-Fa-f]+)""")

    data class Packet(val fileOffset: Int, val bytes: ByteArray)

    /// Reassembles every cue between consecutive `filepos` entries.
    fun extract(sub: ByteArray, idx: ByteArray): List<Packet> {
        val offsets = parseFilePositions(idx)
        if (offsets.isEmpty()) {
            android.util.Log.w("DreamSub", "extract: no filepos entries in idx")
            return emptyList()
        }

        val packets = ArrayList<Packet>(offsets.size)
        var skipped = 0
        for (k in offsets.indices) {
            val start = offsets[k]
            // The last cue runs to EOF; every other cue ends where the next begins.
            val declaredEnd = if (k + 1 < offsets.size) offsets[k + 1] else sub.size
            // A truncated payload (partial read, or a caller passing just one
            // cue's block) leaves later cues with an end past the data we hold.
            // Skip those, but never let them suppress cues that *are* complete.
            if (start < 0 || start >= sub.size) {
                skipped++
                continue
            }
            val end = minOf(declaredEnd, sub.size)
            if (start >= end) {
                skipped++
                continue
            }
            val bytes = reassemble(sub, start, end) ?: run {
                skipped++
                continue
            }
            packets.add(Packet(start, bytes))
        }

        android.util.Log.i(
            "DreamSub",
            "extract: sub=${sub.size} cues=${offsets.size} packets=${packets.size} skipped=$skipped",
        )
        return packets
    }

    /// Concatenates the PES payloads for one cue and trims to its declared
    /// length. Null when no fragment was found or the result is implausible.
    private fun reassemble(sub: ByteArray, from: Int, to: Int): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        var i = from
        var first = true

        while (i + 6 <= to) {
            if (matches(sub, i, PACK_START)) {
                // MPEG-2 pack header: fixed 14 bytes, no stuffing count.
                i += PACK_HEADER_LENGTH
                continue
            }
            if (!matches(sub, i, PRIVATE_STREAM_1)) {
                i++
                continue
            }

            val packetLength = ((sub[i + 4].toInt() and 0xff) shl 8) or
                (sub[i + 5].toInt() and 0xff)
            val headerLength = if (first) FIRST_FRAGMENT_HEADER else CONTINUATION_HEADER
            first = false

            val payloadFrom = i + 6 + headerLength
            // packetLength covers the whole PES packet, header included.
            val payloadTo = i + 6 + packetLength
            if (payloadFrom < payloadTo && payloadTo <= sub.size) {
                out.write(sub, payloadFrom, payloadTo - payloadFrom)
            }
            i = payloadTo
        }

        val bytes = out.toByteArray()
        if (bytes.size < 2) return null

        // The DVD packet declares its own total length; the trailing PES frame is
        // often padded past it.
        val declared = ((bytes[0].toInt() and 0xff) shl 8) or (bytes[1].toInt() and 0xff)
        val trimmed = if (declared in 2..MAX_PACKET_LENGTH && declared <= bytes.size) {
            bytes.copyOf(declared)
        } else {
            bytes
        }
        if (trimmed.size < 2 || trimmed.size > MAX_PACKET_LENGTH) return null
        return trimmed
    }

    private fun matches(data: ByteArray, at: Int, code: Int): Boolean {
        if (at < 0 || at + 3 >= data.size) return false
        return ((data[at].toInt() and 0xff) shl 24) or
            ((data[at + 1].toInt() and 0xff) shl 16) or
            ((data[at + 2].toInt() and 0xff) shl 8) or
            (data[at + 3].toInt() and 0xff) == code
    }

    private fun parseFilePositions(idx: ByteArray): IntArray {
        val text = String(idx, Charsets.ISO_8859_1)
        return FILEPOS.findAll(text)
            .mapNotNull { it.groupValues[1].toLongOrNull(16) }
            .filter { it <= Int.MAX_VALUE }
            .map { it.toInt() }
            .toList()
            .toIntArray()
    }
}

/// Cue start times from the `.idx` `timestamp:` entries, in microseconds.
///
/// The VobSub timestamp is `HH:MM:SS:FF` where the fourth field is **milliseconds**,
/// not frames. Reading it as frames at 25fps makes the first cues jump backwards
/// (23:774 -> 53.96s, then 27:194 -> 34.76s), which is impossible for a subtitle
/// track. ffmpeg's own demuxer confirms the millisecond reading, yielding 2737
/// monotonic timestamps ending at 2:24:31.
@UnstableApi
object VobSubIndex {

    private val TIMESTAMP = Regex("""timestamp:\s*(\d+):(\d+):(\d+):(\d+)""")

    fun readTimestamps(idx: ByteArray): LongArray {
        val text = String(idx, Charsets.ISO_8859_1)
        val out = ArrayList<Long>(1024)
        for (m in TIMESTAMP.findAll(text)) {
            val (h, min, s, ms) = m.destructured
            val us = h.toLong() * 3_600_000_000L +
                min.toLong() * 60_000_000L +
                s.toLong() * 1_000_000L +
                ms.toLong() * 1_000L
            out.add(us)
        }
        return out.toLongArray()
    }
}
