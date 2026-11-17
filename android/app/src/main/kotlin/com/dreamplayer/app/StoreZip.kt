package com.dreamplayer.app

import java.io.InputStream
import java.io.OutputStream
import java.nio.charset.StandardCharsets
import java.util.zip.CRC32

/**
 * Minimal streaming writer for a STORE-only ZIP archive (method 0 - no
 * compression, so a 50 GB remux costs no CPU), with ZIP64 support for
 * entries and archives over 4 GiB.
 *
 * The CRC of an entry is only known after its bytes have been read, so each
 * local header is written with the data-descriptor flag (bit 3) and the real
 * CRC/sizes follow the data; the central directory carries the real values,
 * which is what every reader (browser, unzip, Archive Utility) actually uses.
 * Deliberately NOT java.util.zip.ZipOutputStream: with STORED entries it
 * demands the CRC up front, which would mean reading every file twice.
 *
 * Pure java.io - unit-tested off-device in StoreZipTest.
 */
object StoreZip {

    /** One file to put in the archive. [open] must return a fresh stream. */
    class Entry(val name: String, val declaredSize: Long, val open: () -> InputStream)

    private const val LOCAL_SIG = 0x04034b50
    private const val DATA_DESC_SIG = 0x08074b50
    private const val CENTRAL_SIG = 0x02014b50
    private const val EOCD_SIG = 0x06054b50
    private const val ZIP64_EOCD_SIG = 0x06064b50
    private const val ZIP64_LOC_SIG = 0x07064b50
    private const val ZIP64_THRESHOLD = 0xFFFFFFFFL
    private const val FLAG_DATA_DESCRIPTOR = 0x0008
    private const val FLAG_UTF8 = 0x0800
    private const val DOS_DATE_1980 = 0x0021 // 1980-01-01, the ZIP epoch

    private class Central(
        val nameBytes: ByteArray,
        val crc: Long,
        val size: Long,
        val declared: Long,
        val localOffset: Long,
    )

    fun write(entries: List<Entry>, out: OutputStream) {
        val central = ArrayList<Central>(entries.size)
        var offset = 0L
        for (e in entries) {
            // Open BEFORE the header so an unreadable file is skipped
            // whole instead of leaving a truncated entry behind.
            val input = try {
                e.open()
            } catch (_: Exception) {
                null
            } ?: continue
            input.use {
                val nameBytes = e.name.toByteArray(StandardCharsets.UTF_8)
                val zip64 = e.declaredSize >= ZIP64_THRESHOLD
                val localOffset = offset

                // ---- local file header ----
                val lh = java.io.ByteArrayOutputStream()
                putInt(lh, LOCAL_SIG)
                putShort(lh, 45) // version needed: 4.5 (ZIP64)
                putShort(lh, FLAG_DATA_DESCRIPTOR or FLAG_UTF8)
                putShort(lh, 0) // method: store
                putShort(lh, 0) // time
                putShort(lh, DOS_DATE_1980) // date
                putInt(lh, 0) // crc - lives in the data descriptor
                putInt(lh, if (zip64) -1 else 0) // compressed size
                putInt(lh, if (zip64) -1 else 0) // uncompressed size
                putShort(lh, nameBytes.size)
                putShort(lh, if (zip64) 20 else 0) // extra field length
                lh.write(nameBytes)
                if (zip64) {
                    putShort(lh, 0x0001) // ZIP64 extra field: usize, csize
                    putShort(lh, 16)
                    putLong(lh, e.declaredSize)
                    putLong(lh, e.declaredSize)
                }
                out.write(lh.toByteArray())
                offset += lh.size().toLong()

                // ---- file data, CRC on the fly ----
                val crc = CRC32()
                var total = 0L
                val buf = ByteArray(256 * 1024)
                var n = it.read(buf)
                while (n > 0) {
                    crc.update(buf, 0, n)
                    out.write(buf, 0, n)
                    total += n
                    offset += n
                    n = it.read(buf)
                }

                // ---- data descriptor (real crc + sizes) ----
                if (total >= ZIP64_THRESHOLD || zip64) {
                    putInt(out, DATA_DESC_SIG)
                    putInt(out, crc.value.toInt())
                    putLong(out, total)
                    putLong(out, total)
                    offset += 24
                } else {
                    putInt(out, DATA_DESC_SIG)
                    putInt(out, crc.value.toInt())
                    putInt(out, total.toInt())
                    putInt(out, total.toInt())
                    offset += 16
                }
                central.add(Central(nameBytes, crc.value, total, e.declaredSize, localOffset))
            }
        }

        // ---- central directory ----
        val cdStart = offset
        for (c in central) {
            // ZIP64 is decided on max(actual, declared) so the local header
            // (declared-based), the central directory and the ZIP64 EOCD can
            // never disagree about whether an entry is oversized.
            val size64 = c.size >= ZIP64_THRESHOLD || c.declared >= ZIP64_THRESHOLD
            val off64 = c.localOffset >= ZIP64_THRESHOLD
            // One 0x0001 field, in spec order (usize, csize, local offset),
            // containing only the values whose 32-bit slots are 0xFFFFFFFF.
            val extraBody = java.io.ByteArrayOutputStream()
            if (size64) {
                putLong(extraBody, c.size)
                putLong(extraBody, c.size)
            }
            if (off64) putLong(extraBody, c.localOffset)
            val extra = extraBody.toByteArray()

            val ch = java.io.ByteArrayOutputStream()
            putInt(ch, CENTRAL_SIG)
            putShort(ch, 45) // version made by
            putShort(ch, 45) // version needed
            putShort(ch, FLAG_DATA_DESCRIPTOR or FLAG_UTF8)
            putShort(ch, 0) // method: store
            putShort(ch, 0) // time
            putShort(ch, DOS_DATE_1980) // date
            putInt(ch, c.crc.toInt())
            putInt(ch, if (size64) -1 else c.size.toInt())
            putInt(ch, if (size64) -1 else c.size.toInt())
            putShort(ch, c.nameBytes.size)
            putShort(ch, if (extra.isEmpty()) 0 else extra.size + 4)
            putShort(ch, 0) // comment length
            putShort(ch, 0) // disk number
            putShort(ch, 0) // internal attributes
            putInt(ch, 0) // external attributes
            putInt(ch, if (off64) -1 else c.localOffset.toInt())
            ch.write(c.nameBytes)
            if (extra.isNotEmpty()) {
                putShort(ch, 0x0001)
                putShort(ch, extra.size)
                ch.write(extra)
            }
            out.write(ch.toByteArray())
            offset += ch.size().toLong()
        }
        val cdSize = offset - cdStart

        // ---- ZIP64 end of central directory, when anything overflowed ----
        val needZip64Eocd = cdStart >= ZIP64_THRESHOLD || cdSize >= ZIP64_THRESHOLD ||
            central.size >= 0xFFFF ||
            central.any {
                it.size >= ZIP64_THRESHOLD || it.declared >= ZIP64_THRESHOLD ||
                    it.localOffset >= ZIP64_THRESHOLD
            }
        if (needZip64Eocd) {
            val z64Start = offset
            putInt(out, ZIP64_EOCD_SIG)
            putLong(out, 44) // size of the record after this field
            putShort(out, 45) // version made by
            putShort(out, 45) // version needed
            putInt(out, 0) // this disk
            putInt(out, 0) // disk with the central directory
            putLong(out, central.size.toLong())
            putLong(out, central.size.toLong())
            putLong(out, cdSize)
            putLong(out, cdStart)
            offset += 56
            putInt(out, ZIP64_LOC_SIG)
            putInt(out, 0) // disk with the ZIP64 EOCD
            putLong(out, z64Start)
            putInt(out, 1) // total disks
            offset += 20
        }

        // ---- end of central directory ----
        putInt(out, EOCD_SIG)
        putShort(out, 0) // this disk
        putShort(out, 0) // disk with the central directory
        putShort(out, minOf(central.size, 0xFFFF))
        putShort(out, minOf(central.size, 0xFFFF))
        putInt(out, if (cdSize >= ZIP64_THRESHOLD) -1 else cdSize.toInt())
        putInt(out, if (cdStart >= ZIP64_THRESHOLD) -1 else cdStart.toInt())
        putShort(out, 0) // comment length
        out.flush()
    }

    private fun putShort(out: OutputStream, v: Int) {
        out.write(v and 0xFF)
        out.write((v ushr 8) and 0xFF)
    }

    private fun putInt(out: OutputStream, v: Int) {
        out.write(v and 0xFF)
        out.write((v ushr 8) and 0xFF)
        out.write((v ushr 16) and 0xFF)
        out.write((v ushr 24) and 0xFF)
    }

    private fun putLong(out: OutputStream, v: Long) {
        for (i in 0..7) out.write(((v ushr (8 * i)) and 0xFF).toInt())
    }
}
