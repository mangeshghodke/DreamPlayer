package com.dreamplayer.app

import android.content.Context
import android.net.Uri
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.JSch
import org.apache.commons.net.ftp.FTP
import org.apache.commons.net.ftp.FTPClient
import java.io.InputStream
import java.util.Properties

/// Seekable random-read access to an `ftp://<serverId>/<path>` or
/// `sftp://…` remote file, used by the chapter probes ([MkvChapters] /
/// [Mp4Chapters]). Credentials resolve from [FtpClient.FtpStore] like
/// [FtpDataSource]. One control connection is reused; every out-of-order
/// read reissues REST/RETR (FTP) or an offset `get` (SFTP) - chapter parsing
/// performs only a handful of small reads, so the churn is fine.
internal class FtpSeekSource private constructor(
    private val isSftp: Boolean,
    private val host: String,
    private val port: Int,
    private val user: String,
    private val password: String,
    private val remotePath: String,
) {
    private var ftp: FTPClient? = null
    private var ftpStream: InputStream? = null
    private var ftpStreamPos: Long = -1

    private var sftpSession: com.jcraft.jsch.Session? = null
    private var sftpChannel: ChannelSftp? = null

    /** File size, or Long.MAX_VALUE when unknown (parsers treat it as unbounded). */
    var size: Long = Long.MAX_VALUE
        private set

    companion object {
        fun open(uriText: String, context: Context): FtpSeekSource? {
            val uri = Uri.parse(uriText) ?: return null
            val scheme = uri.scheme?.lowercase() ?: return null
            if (scheme != "ftp" && scheme != "sftp") return null
            val serverId = uri.host ?: return null
            val remotePath = uri.path?.takeIf { it.isNotEmpty() } ?: return null
            val creds = FtpClient.FtpStore.resolve(context, serverId) ?: return null
            return try {
                FtpSeekSource(
                    isSftp = scheme == "sftp",
                    host = creds.host,
                    port = creds.port,
                    user = creds.username.ifEmpty { "anonymous" },
                    password = creds.password,
                    remotePath = remotePath,
                ).also { it.connect() }
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun connect() {
        if (isSftp) {
            val jsch = JSch()
            val session = jsch.getSession(user, host, port)
            if (password.isNotEmpty()) session.setPassword(password)
            val config = Properties()
            config["StrictHostKeyChecking"] = "no"
            session.setConfig(config)
            session.timeout = 10000
            session.connect(10000)
            val channel = session.openChannel("sftp") as ChannelSftp
            channel.connect(5000)
            sftpSession = session
            sftpChannel = channel
            size = try {
                channel.lstat(remotePath).size
            } catch (_: Exception) {
                Long.MAX_VALUE
            }
        } else {
            val client = FTPClient().apply {
                connectTimeout = 10000
                defaultTimeout = 15000
            }
            client.connect(host, port)
            if (!client.login(user, password.ifEmpty { "anonymous@" })) {
                throw java.io.IOException("FTP login failed")
            }
            client.enterLocalPassiveMode()
            client.setFileType(FTP.BINARY_FILE_TYPE)
            ftp = client
            size = try {
                client.sendCommand("SIZE", remotePath)
                if (client.replyCode == 213) {
                    client.replyString.trim().substringAfter("213").trim().toLongOrNull()
                        ?: Long.MAX_VALUE
                } else Long.MAX_VALUE
            } catch (_: Exception) {
                Long.MAX_VALUE
            }
        }
    }

    /** Fills [buf] entirely starting at absolute [pos]. Returns false on EOF. */
    fun readFullyAt(pos: Long, buf: ByteArray): Boolean {
        var off = 0
        while (off < buf.size) {
            val n = readAt(pos + off, buf, off, buf.size - off)
            if (n <= 0) return false
            off += n
        }
        return true
    }

    /** Reads up to [len] bytes at absolute [pos] into [buf] at [off]. */
    @Suppress("SameParameterValue")
    private fun readAt(pos: Long, buf: ByteArray, off: Int, len: Int): Int {
        if (isSftp) {
            val channel = sftpChannel ?: throw java.io.IOException("SFTP not connected")
            val stream = channel.get(remotePath, null, pos)
            stream.use {
                return readStream(it, buf, off, len)
            }
        }
        // FTP: reuse the open data stream while reads stay sequential.
        val client = ftp ?: throw java.io.IOException("FTP not connected")
        val cur = ftpStream
        if (cur != null && ftpStreamPos == pos) {
            val n = readStream(cur, buf, off, len)
            ftpStreamPos += if (n > 0) n.toLong() else 0
            return n
        }
        // Out-of-order read: drain + finish the pending transfer first.
        try { cur?.close() } catch (_: Exception) {}
        ftpStream = null
        try { client.completePendingCommand() } catch (_: Exception) {}
        client.setRestartOffset(pos)
        val stream = client.retrieveFileStream(remotePath)
            ?: throw java.io.IOException("RETR failed: ${client.replyString}")
        ftpStream = stream
        ftpStreamPos = pos
        val n = readStream(stream, buf, off, len)
        ftpStreamPos += if (n > 0) n.toLong() else 0
        return n
    }

    private fun readStream(stream: InputStream, buf: ByteArray, off: Int, len: Int): Int {
        var total = 0
        while (total < len) {
            val n = stream.read(buf, off + total, len - total)
            if (n < 0) break
            total += n
        }
        return if (total == 0) -1 else total
    }

    fun close() {
        try { ftpStream?.close() } catch (_: Exception) {}
        ftpStream = null
        val client = ftp
        ftp = null
        if (client != null) {
            try { if (client.isConnected) client.completePendingCommand() } catch (_: Exception) {}
            try { client.logout() } catch (_: Exception) {}
            try { client.disconnect() } catch (_: Exception) {}
        }
        try { sftpChannel?.disconnect() } catch (_: Exception) {}
        sftpChannel = null
        try { sftpSession?.disconnect() } catch (_: Exception) {}
        sftpSession = null
    }
}
