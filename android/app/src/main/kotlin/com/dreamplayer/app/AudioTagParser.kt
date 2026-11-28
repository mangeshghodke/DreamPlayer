package com.dreamplayer.app

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Parses embedded audio tags from the HEAD of a file: FLAC metadata blocks
 * (vorbis comments + STREAMINFO), ID3v2 frames (text frames, USLT lyrics,
 * APIC artwork), and RIFF/WAVE chunks (fmt + LIST INFO + id3 chunk).
 *
 * MediaMetadataRetriever exposes title/artist/album but has NO lyrics key,
 * and AVFoundation on iOS cannot read FLAC/WAV at all - so this parser is
 * what surfaces embedded (often LRC time-synced) lyrics on both platforms
 * (user request 2026-11-28).
 *
 * Best-effort: any parse error returns whatever was collected so far.
 */
object AudioTagParser {

    /** Result of a parse: tag text keys + optional embedded artwork bytes. */
    class Result {
        val tags = HashMap<String, String>()
        var artwork: ByteArray? = null
        var sampleRate: Int? = null
        var bits: Int? = null
        var channels: Int? = null

        fun mergeInto(out: MutableMap<String, Any?>) {
            fun putIfAbsent(key: String, value: String) {
                val existing = out[key] as? String
                if (existing.isNullOrBlank() && value.isNotBlank()) out[key] = value
            }
            putIfAbsent("audioTitle", tags["title"] ?: "")
            putIfAbsent("audioArtist", tags["artist"] ?: "")
            putIfAbsent("audioAlbum", tags["album"] ?: "")
            if ((out["audioLyrics"] as? String).isNullOrBlank() &&
                !tags["lyrics"].isNullOrBlank()) {
                out["audioLyrics"] = tags["lyrics"]
            }
            if (sampleRate != null && out["audioSampleRate"] == null) out["audioSampleRate"] = sampleRate
            if (bits != null && out["audioBits"] == null) out["audioBits"] = bits
            if (channels != null && out["audioChannels"] == null) out["audioChannels"] = channels
        }
    }

    fun parse(bytes: ByteArray): Result {
        val r = Result()
        if (bytes.size < 12) return r
        when {
            bytes.size >= 4 && String(bytes, 0, 4) == "fLaC" -> parseFlac(bytes, r)
            bytes.size >= 10 && String(bytes, 0, 3) == "ID3" -> parseId3(bytes, r)
            bytes.size >= 12 && String(bytes, 0, 4) == "RIFF" && String(bytes, 8, 4) == "WAVE" -> parseWav(bytes, r)
        }
        return r
    }

    // MARK: - FLAC

    private fun parseFlac(b: ByteArray, r: Result) {
        var pos = 4
        while (pos + 4 <= b.size) {
            val header = b[pos].toInt()
            val last = header and 0x80 != 0
            val type = header and 0x7F
            val len = ((b[pos + 1].toInt() and 0xFF) shl 16) or
                ((b[pos + 2].toInt() and 0xFF) shl 8) or
                (b[pos + 3].toInt() and 0xFF)
            val data = pos + 4
            if (data + len > b.size) break
            when (type) {
                0 -> { // STREAMINFO
                    if (len >= 18) {
                        val rate = ((b[data].toInt() and 0xFF) shl 12) or
                            ((b[data + 1].toInt() and 0xFF) shl 4) or
                            ((b[data + 2].toInt() and 0xFF) ushr 4)
                        r.sampleRate = rate
                        r.channels = (((b[data + 2].toInt() and 0xFF) ushr 1) and 0x07) + 1
                        r.bits = ((((b[data + 2].toInt() and 0xFF) and 0x01) shl 4) or
                            ((b[data + 3].toInt() and 0xFF) ushr 4)) + 1
                    }
                }
                4 -> parseVorbisComment(b, data, len, r)
                6 -> { // PICTURE
                    try {
                        val buf = ByteBuffer.wrap(b, data, len).order(ByteOrder.BIG_ENDIAN)
                        val mimeLen = buf.int
                        var p = 4 + mimeLen
                        val descLen = buf.getInt(p); p += 4 + descLen
                        p += 16 // width, height, depth, colors
                        val dataLen = buf.getInt(p); p += 4
                        if (dataLen > 0 && p + dataLen <= len) {
                            r.artwork = b.copyOfRange(data + p, data + p + dataLen)
                        }
                    } catch (_: Exception) {}
                }
            }
            pos = data + len
            if (last) break
        }
    }

    private fun parseVorbisComment(b: ByteArray, data: Int, len: Int, r: Result) {
        try {
            val buf = ByteBuffer.wrap(b, data, len).order(ByteOrder.LITTLE_ENDIAN)
            val vendorLen = buf.int
            var p = 4 + vendorLen
            val count = buf.getInt(p); p += 4
            for (i in 0 until count) {
                if (p + 4 > len) break
                val flen = buf.getInt(p); p += 4
                if (flen <= 0 || p + flen > len) break
                val field = String(b, data + p, flen, Charsets.UTF_8)
                p += flen
                val eq = field.indexOf('=')
                if (eq <= 0) continue
                val key = field.substring(0, eq).uppercase()
                val value = field.substring(eq + 1)
                when (key) {
                    "TITLE" -> r.tags["title"] = value
                    "ARTIST" -> r.tags["artist"] = value
                    "ALBUM" -> r.tags["album"] = value
                    "LYRICS", "UNSYNCEDLYRICS" -> if (!r.tags.containsKey("lyrics")) r.tags["lyrics"] = value
                }
            }
        } catch (_: Exception) {}
    }

    // MARK: - ID3v2

    private fun parseId3(b: ByteArray, r: Result) {
        val ver = b[3].toInt()
        val flags = b[5].toInt()
        var size = syncsafe(b, 6)
        var pos = 10
        if (flags and 0x40 != 0 && pos + 4 <= b.size) { // extended header
            val ext = if (ver == 4) syncsafe(b, pos) else readBeInt(b, pos)
            pos += if (ver == 4) ext else ext + 4
            size -= 0
        }
        val end = minOf(b.size, pos + size)
        while (pos + 10 <= end) {
            val id = String(b, pos, 4)
            if (id[0] == 0.toChar()) break
            val fsize = if (ver == 4) syncsafe(b, pos + 4) else readBeInt(b, pos + 4)
            if (fsize <= 0 || pos + 10 + fsize > b.size) break
            val body = pos + 10
            try {
                when {
                    id == "USLT" -> r.tags.setLyrics(decodeId3Text(b, body, fsize))
                    id == "SYLT" -> {} // binary synced lyrics - left unparsed
                    id.startsWith("T") -> {
                        val text = decodeId3Text(b, body, fsize)
                        when (id) {
                            "TIT2" -> r.tags["title"] = text
                            "TPE1" -> r.tags["artist"] = text
                            "TALB" -> r.tags["album"] = text
                            "TXXX" -> {
                                // TXXX: encoding, description\0, value
                                val t = decodeId3Text(b, body, fsize)
                                val sep = t.indexOf('\u0000')
                                // decodeId3Text stops at NUL for text frames; handle raw:
                            }
                        }
                    }
                    id == "TXXX" -> {
                        val enc = b[body].toInt()
                        val nul = findNul(b, body + 1, fsize - 1, enc)
                        if (nul > 0) {
                            val desc = decodeText(b, body + 1, nul - 1, enc)
                            val value = decodeText(b, body + nul + 1, fsize - (nul - body) - 2, enc)
                            if (desc.equals("LYRICS", ignoreCase = true) ||
                                desc.equals("UNSYNCEDLYRICS", ignoreCase = true)) {
                                r.tags.setLyrics(value)
                            }
                        }
                    }
                    id == "APIC" -> {
                        val enc = b[body].toInt()
                        val mimeEnd = findNul(b, body + 1, fsize - 1, 1)
                        if (mimeEnd > 0) {
                            val picStart = body + mimeEnd + 1 + 1 // mime\0 + picture-type byte
                            val descEnd = findNul(b, body + mimeEnd + 2, fsize - (mimeEnd + 2 - body), enc)
                            val dataStart = if (descEnd > 0) body + descEnd + 1 else picStart
                            if (dataStart < body + fsize) {
                                r.artwork = b.copyOfRange(dataStart, body + fsize)
                            }
                        }
                    }
                }
            } catch (_: Exception) {}
            pos += 10 + fsize
        }
    }

    private fun MutableMap<String, String>.setLyrics(v: String) {
        if (v.isNotBlank() && !containsKey("lyrics")) put("lyrics", v)
    }

    private fun syncsafe(b: ByteArray, at: Int): Int =
        ((b[at].toInt() and 0x7F) shl 21) or ((b[at + 1].toInt() and 0x7F) shl 14) or
            ((b[at + 2].toInt() and 0x7F) shl 7) or (b[at + 3].toInt() and 0x7F)

    private fun readBeInt(b: ByteArray, at: Int): Int =
        ((b[at].toInt() and 0xFF) shl 24) or ((b[at + 1].toInt() and 0xFF) shl 16) or
            ((b[at + 2].toInt() and 0xFF) shl 8) or (b[at + 3].toInt() and 0xFF)

    private fun findNul(b: ByteArray, from: Int, max: Int, enc: Int): Int {
        val n = minOf(b.size, from + max)
        if (enc == 1 || enc == 2) { // UTF-16: NUL is a 2-byte 0x0000
            var i = from
            while (i + 1 < n) {
                if (b[i] == 0.toByte() && b[i + 1] == 0.toByte()) return i - from
                i += 2
            }
            return -1
        }
        var i = from
        while (i < n) {
            if (b[i] == 0.toByte()) return i - from
            i++
        }
        return -1
    }

    private fun decodeId3Text(b: ByteArray, body: Int, fsize: Int): String {
        if (fsize <= 1) return ""
        val enc = b[body].toInt()
        return decodeText(b, body + 1, fsize - 1, enc)
    }

    private fun decodeText(b: ByteArray, from: Int, len: Int, enc: Int): String {
        if (len <= 0) return ""
        val n = minOf(b.size, from + len)
        return when (enc) {
            0 -> String(b, from, n - from, Charsets.ISO_8859_1)
            3 -> String(b, from, n - from, Charsets.UTF_8)
            1 -> String(b, from, n - from, Charsets.UTF_16) // BOM handled by charset
            2 -> String(b, from, n - from, Charsets.UTF_16BE)
            else -> String(b, from, n - from, Charsets.UTF_8)
        }.trimEnd('\u0000', ' ', '\n', '\r')
    }

    // MARK: - RIFF/WAVE

    private fun parseWav(b: ByteArray, r: Result) {
        var pos = 12
        while (pos + 8 <= b.size) {
            val id = String(b, pos, 4)
            val size = readLeInt(b, pos + 4)
            val data = pos + 8
            if (data + size > b.size) break
            when (id) {
                "fmt " -> {
                    if (size >= 16) {
                        r.channels = readLeShort(b, data + 2)
                        r.sampleRate = readLeInt(b, data + 4)
                        r.bits = readLeShort(b, data + 14)
                    }
                }
                "LIST" -> {
                    if (size >= 4 && String(b, data, 4) == "INFO") {
                        var p = data + 4
                        val end = data + size
                        while (p + 8 <= end) {
                            val sid = String(b, p, 4)
                            val ssize = readLeInt(b, p + 4)
                            val sd = p + 8
                            if (sd + ssize > b.size) break
                            val value = String(b, sd, ssize, Charsets.UTF_8).trimEnd('\u0000', ' ')
                            when (sid) {
                                "INAM" -> r.tags["title"] = value
                                "IART" -> r.tags["artist"] = value
                                "IPRD" -> r.tags["album"] = value
                                "ICMT" -> r.tags.setLyrics(value)
                            }
                            p = sd + ssize + (ssize and 1) // chunks are word-aligned
                        }
                    }
                }
                "id3 ", "ID3 " -> parseId3(b.copyOfRange(data, minOf(b.size, data + size)), r)
            }
            pos = data + size + (size and 1)
        }
    }

    private fun readLeInt(b: ByteArray, at: Int): Int =
        (b[at].toInt() and 0xFF) or ((b[at + 1].toInt() and 0xFF) shl 8) or
            ((b[at + 2].toInt() and 0xFF) shl 16) or ((b[at + 3].toInt() and 0xFF) shl 24)

    private fun readLeShort(b: ByteArray, at: Int): Int =
        (b[at].toInt() and 0xFF) or ((b[at + 1].toInt() and 0xFF) shl 8)
}
