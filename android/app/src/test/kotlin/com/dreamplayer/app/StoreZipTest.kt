package com.dreamplayer.app

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.zip.CRC32
import java.util.zip.ZipFile
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StoreZipTest {

    private fun entry(name: String, data: ByteArray) =
        StoreZip.Entry(name, data.size.toLong()) { ByteArrayInputStream(data) }

    private fun readLe32(b: ByteArray, at: Int): Int =
        (b[at].toInt() and 0xFF) or
            ((b[at + 1].toInt() and 0xFF) shl 8) or
            ((b[at + 2].toInt() and 0xFF) shl 16) or
            ((b[at + 3].toInt() and 0xFF) shl 24)

    private fun indexOfLe32(b: ByteArray, sig: Int): Int {
        for (i in 0..b.size - 4) if (readLe32(b, i) == sig) return i
        return -1
    }

    /** Reads the archive the way a browser does: via the CENTRAL directory. */
    private fun readViaCentralDir(bytes: ByteArray): Map<String, ByteArray> {
        val f = File.createTempFile("storezip", ".zip")
        try {
            f.writeBytes(bytes)
            ZipFile(f).use { zf ->
                val out = linkedMapOf<String, ByteArray>()
                for (e in zf.entries()) {
                    val content = zf.getInputStream(e).readBytes()
                    // ZipFile surfaces the central-directory values.
                    assertEquals(0, e.method) // method 0: stored, not deflated
                    assertEquals(content.size.toLong(), e.size)
                    assertEquals(content.size.toLong(), e.compressedSize)
                    val crc = CRC32()
                    crc.update(content)
                    assertEquals("crc mismatch for ${e.name}", crc.value, e.crc)
                    out[e.name] = content
                }
                return out
            }
        } finally {
            f.delete()
        }
    }

    @Test
    fun roundTripMultipleFilesWithFolderPaths() {
        val a = "hello".toByteArray()
        val b = ByteArray(1000) { (it % 251).toByte() }
        val out = ByteArrayOutputStream()
        StoreZip.write(
            listOf(
                entry("Movie/clip.mkv", a),
                entry("Movie/Subs/clip.srt", b),
                entry("readme.txt", ByteArray(0)),
            ),
            out,
        )
        val bytes = out.toByteArray()
        // The EOCD record is the last 22 bytes of the archive.
        assertEquals(0x06054b50, readLe32(bytes, bytes.size - 22))

        val files = readViaCentralDir(bytes)
        assertEquals(listOf("Movie/clip.mkv", "Movie/Subs/clip.srt", "readme.txt"), files.keys.toList())
        assertArrayEquals(a, files["Movie/clip.mkv"])
        assertArrayEquals(b, files["Movie/Subs/clip.srt"])
        assertEquals(0, files["readme.txt"]!!.size)
    }

    @Test
    fun zip64ThresholdMarksOversizedEntries() {
        // A declared size over 4 GiB must put 0xFFFFFFFF in the 32-bit
        // slots and carry the real value in the ZIP64 extra field.
        val big = 0x100000000L
        val out = ByteArrayOutputStream()
        StoreZip.write(listOf(StoreZip.Entry("huge.mkv", big) { ByteArrayInputStream(ByteArray(0)) }), out)
        val bytes = out.toByteArray()
        // local header: csize/usize slots are 0xFFFFFFFF at offsets 18 and 22
        assertEquals(-1, readLe32(bytes, 18))
        assertEquals(-1, readLe32(bytes, 22))
        // and a ZIP64 EOCD record exists (the locator carries 0x07064b50)
        assertTrue("ZIP64 EOCD missing", indexOfLe32(bytes, 0x06064b50) > 0)
        assertTrue("ZIP64 locator missing", indexOfLe32(bytes, 0x07064b50) > 0)
    }

    @Test
    fun localHeaderCarriesDescriptorAndUtf8Flags() {
        val out = ByteArrayOutputStream()
        StoreZip.write(listOf(entry("Episode – S01E01.mkv", "x".toByteArray())), out)
        val bytes = out.toByteArray()
        assertEquals(0x04034b50, readLe32(bytes, 0)) // local header signature
        val flags = (bytes[6].toInt() and 0xFF) or ((bytes[7].toInt() and 0xFF) shl 8)
        assertEquals(0x0808, flags) // bit 3 data descriptor + bit 11 UTF-8 names
        assertEquals(0, (bytes[8].toInt() and 0xFF)) // method 0: store
    }

    @Test
    fun unreadableEntryIsSkippedWhole() {
        val out = ByteArrayOutputStream()
        StoreZip.write(
            listOf(
                StoreZip.Entry("gone.bin", 5) { throw java.io.IOException("nope") },
                entry("ok.txt", "x".toByteArray()),
            ),
            out,
        )
        val files = readViaCentralDir(out.toByteArray())
        assertEquals(listOf("ok.txt"), files.keys.toList())
        assertArrayEquals("x".toByteArray(), files["ok.txt"])
    }
}
