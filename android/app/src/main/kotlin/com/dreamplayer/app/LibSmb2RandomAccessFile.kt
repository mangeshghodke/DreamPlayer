package com.dreamplayer.app

import java.io.IOException

/**
 * Drop-in replacement for jcifs-ng's `SmbRandomAccessFile` backed by libsmb2.
 *
 * libsmb2 reads are positional (`smb2_pread`), so `seek()` only updates the
 * cursor and `read()` issues a pread at that cursor. This keeps the existing
 * SmbDataSource / SmbHttpProxy / chapter-probe code paths working unchanged
 * while moving the actual I/O onto libsmb2.
 *
 * IMPORTANT: pass the [LibSmb2File] you already opened as [existing]. Opening
 * the file twice leaves a second `smb2fh` open on the same tree, and the
 * server then refuses the TREE_DISCONNECT with STATUS_BUSY - libsmb2 skips
 * the socket close in that case, so the whole SMB session (TCP connection
 * included) leaks. A handful of leaked sessions exhausts the NAS's per-user
 * session limit and every later connect fails.
 */
class LibSmb2RandomAccessFile(
    private val session: LibSmb2Session,
    private val path: String,
    existing: LibSmb2File? = null,
) {
    private var file: LibSmb2File? = null
    private var closed = false
    private var position: Long = 0
    private val lock = Object()

    init {
        file = existing ?: session.openFile(path)
            ?: throw IOException("libsmb2: could not open $path (${session.error()})")
    }

    fun length(): Long = file?.size ?: 0L

    fun seek(pos: Long) {
        synchronized(lock) { position = pos }
    }

    val filePointer: Long get() = synchronized(lock) { position }

    fun pos(): Long = filePointer

    fun read(): Int {
        val buf = ByteArray(1)
        val n = read(buf, 0, 1)
        return if (n <= 0) -1 else buf[0].toInt() and 0xFF
    }

    fun read(buf: ByteArray, off: Int, len: Int): Int {
        if (len <= 0) return 0
        if (closed) return -1
        val f = file ?: return -1
        val pos = synchronized(lock) { position }
        val tmp = if (off == 0) buf else ByteArray(len)
        val n = f.readAt(pos, tmp, len)
        if (n > 0) {
            if (off != 0) System.arraycopy(tmp, 0, buf, off, n)
            synchronized(lock) { position += n }
        }
        return n
    }

    fun readFully(buf: ByteArray) {
        readFully(buf, 0, buf.size)
    }

    fun readFully(buf: ByteArray, off: Int, len: Int) {
        var read = 0
        while (read < len) {
            val n = read(buf, off + read, len - read)
            if (n < 0) throw IOException("unexpected EOF")
            read += n
        }
    }

    fun close() {
        if (closed) return
        closed = true
        file?.close()
        file = null
        try { session.close() } catch (_: Exception) {}
    }
}
