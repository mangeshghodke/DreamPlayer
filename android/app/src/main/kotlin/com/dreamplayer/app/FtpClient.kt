package com.dreamplayer.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.JSch
import io.flutter.plugin.common.MethodChannel
import org.apache.commons.net.ftp.FTP
import org.apache.commons.net.ftp.FTPClient
import org.json.JSONObject
import java.util.Properties
import java.util.UUID
import java.util.Vector

/// FTP / SFTP client for the `dreamplayer/ftp` channel, mirroring
/// `WebDAVClient.kt` / `SMBClient.kt`.
///
/// - FTP via Apache Commons Net `FTPClient` (plain FTP, passive + binary).
/// - SFTP via JSch `ChannelSftp` (SSH).
/// - Servers persisted in plain SharedPreferences + EncryptedSharedPreferences
///   for passwords (same tier as WebDAV/SMB).
/// - Playback URIs are `ftp://<serverId>/<path>` and `sftp://<serverId>/<path>`,
///   resolved by [FtpDataSource] at open time (like `smb://<serverId>/...`).
class FtpClient(private val context: Context) {

    companion object {
        const val CHANNEL = "dreamplayer/ftp"

        private const val PREFS = "dreamplayer.ftpServers"
        private const val SECRETS_PREFS = "dreamplayer.ftpSecrets"
        private const val PASSWORD_KEY = "password."
        private const val SERVER_KEY = "server."

        private val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
            "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
        )

        /// Cap for a fetched sidecar subtitle file (50 MiB).
        private const val MAX_ALT_SUB_BYTES = 50 * 1024 * 1024
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /// Directory-listing cache: re-visiting a folder is instant.
    /// Key = "$serverId|$path|videoOnly", value = (entries, fetchedAtMs).
    /// TTL 60 s. For plain FTP each listing reconnects (one full PASV login),
    /// for SFTP each directory is a fresh SFTP session — both benefit a lot
    /// from caching on quick re-visits.
    private data class CachedListing(
        val entries: List<Map<String, Any?>>,
        val fetchedAtMs: Long,
    )
    private val listingCache = java.util.concurrent.ConcurrentHashMap<String, CachedListing>()
    private val listingTtlMs = 60_000L

    private fun cacheKey(serverId: String, path: String, videoOnly: Boolean): String =
        "$serverId|${path.replace(Regex("/+"), "/").trim('/')}|$videoOnly"

    fun invalidateListingCache(serverId: String? = null) {
        if (serverId == null) {
            listingCache.clear()
        } else {
            val prefix = "$serverId|"
            listingCache.keys.removeAll { it.startsWith(prefix) }
        }
    }

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveServer" -> {
                    val id = call.argument<String>("id")
                    val name = call.argument<String>("name") ?: ""
                    val host = call.argument<String>("host") ?: ""
                    val port = call.argument<Number>("port")?.toInt() ?: 21
                    val path = call.argument<String>("path") ?: "/"
                    val username = call.argument<String>("username") ?: ""
                    val password = call.argument<String>("password") ?: ""
                    val isSftp = call.argument<Boolean>("isSftp") ?: false
                    try {
                        result.success(saveServer(id, name, host, port, path, username, password, isSftp))
                    } catch (e: Exception) {
                        result.error("save_failed", e.message, null)
                    }
                }
                "listServers" -> result.success(listServers())
                "deleteServer" -> {
                    call.argument<String>("id")?.let { deleteServer(it) }
                    result.success(null)
                }
                "invalidateListingCache" -> {
                    call.argument<String>("id")?.let { invalidateListingCache(it) }
                    result.success(null)
                }
                "testConnection" -> {
                    val host = call.argument<String>("host") ?: ""
                    val port = call.argument<Number>("port")?.toInt() ?: 21
                    val path = call.argument<String>("path") ?: "/"
                    val username = call.argument<String>("username") ?: ""
                    val password = call.argument<String>("password") ?: ""
                    val isSftp = call.argument<Boolean>("isSftp") ?: false
                    runAsync(result) {
                        val r = testConnection(host, port, path, username, password, isSftp)
                        mapOf("ok" to r.ok, "error" to r.error)
                    }
                }
                "listDirectory" -> {
                    val id = call.argument<String>("id")
                    val path = call.argument<String>("path") ?: "/"
                    runAsync(result) {
                        val server = id?.let { serverById(it) }
                            ?: throw RuntimeException("FTP server not found")
                        listDirectory(server, path, videoOnly = true)
                    }
                }
                // Nova-parity: the sidecar service needs the *full* directory
                // listing (videos AND sidecar subs) to pair by name — the
                // regular `listDirectory` filters to video extensions only and
                // would strip the `.srt` so `_findFtp` never sees it.
                "listDirectoryAll" -> {
                    val id = call.argument<String>("id")
                    val path = call.argument<String>("path") ?: "/"
                    runAsync(result) {
                        val server = id?.let { serverById(it) }
                            ?: throw RuntimeException("FTP server not found")
                        listDirectory(server, path, videoOnly = false)
                    }
                }
                // Nova-parity sidecar prefetch: read a subtitle file's bytes so
                // the Dart side can write it to a local cache and hand the engine
                // a file:// track (AVP issue #1605) instead of streaming the
                // remote ftp:// URL (which is fragile to reconnect/seek).
                "fetchBytes" -> {
                    val id = call.argument<String>("id")
                    val path = call.argument<String>("path") ?: "/"
                    val maxBytes = call.argument<Number>("maxBytes")?.toInt() ?: MAX_ALT_SUB_BYTES
                    runAsync(result) {
                        val server = id?.let { serverById(it) }
                            ?: throw RuntimeException("FTP server not found")
                        altSubBytes(server, path, maxBytes)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Reads up to [maxBytes] of the file at [remotePath] on [server] into a
    /// ByteArray (null on 404/no-access so sidecar discovery treats it as "no
    /// subtitle"). Mirrors FtpDataSource's FTP/SFTP open logic.
    private fun altSubBytes(server: FtpServer, remotePath: String, maxBytes: Int): ByteArray? = try {
        if (server.isSftp) {
            val jsch = JSch()
            val session = jsch.getSession(server.username.ifEmpty { "anonymous" }, server.host, server.port)
            if (server.password.isNotEmpty()) session.setPassword(server.password)
            val config = Properties()
            config["StrictHostKeyChecking"] = "no"
            session.setConfig(config)
            session.timeout = 10000
            session.connect(10000)
            try {
                val channel = session.openChannel("sftp") as ChannelSftp
                try {
                    channel.connect(5000)
                    val len = channel.lstat(remotePath).size
                    if (len <= 0) return null
                    channel.get(remotePath).use { ins ->
                        readCapped(ins, len.toInt(), maxBytes)
                    }
                } finally {
                    try { channel.disconnect() } catch (_: Exception) {}
                }
            } finally {
                try { session.disconnect() } catch (_: Exception) {}
            }
        } else {
            val ftp = FTPClient().apply {
                connectTimeout = 10000
                defaultTimeout = 15000
            }
            ftp.connect(server.host, server.port)
            try {
                val user = server.username.ifEmpty { "anonymous" }
                val pass = server.password.ifEmpty { "anonymous@" }
                if (!ftp.login(user, pass)) return null
                ftp.enterLocalPassiveMode()
                ftp.setFileType(FTP.BINARY_FILE_TYPE)
                val stream = ftp.retrieveFileStream(remotePath) ?: return null
                try {
                    val len = ftpFileSize(ftp, remotePath)
                    val cap = if (len > 0) len.toInt() else maxBytes
                    stream.use { readCapped(it, cap, maxBytes) }
                } finally {
                    try { stream.close() } catch (_: Exception) {}
                }
            } finally {
                try { ftp.logout() } catch (_: Exception) {}
                try { ftp.disconnect() } catch (_: Exception) {}
            }
        }
    } catch (_: Exception) {
        null
    }

    private fun readCapped(ins: java.io.InputStream, knownSize: Int, maxBytes: Int): ByteArray? {
        val read = minOf(if (knownSize > 0) knownSize else maxBytes, maxBytes)
        val buf = ByteArray(read)
        var off = 0
        var left = read
        while (left > 0) {
            val n = ins.read(buf, off, left)
            if (n < 0) break
            off += n
            left -= n
        }
        return if (off == 0) null else buf.copyOf(off)
    }

    private fun ftpFileSize(ftp: FTPClient, path: String): Long {
        try {
            ftp.sendCommand("SIZE", path)
            if (ftp.replyCode == 213) {
                return ftp.replyString.trim().substringAfter("213").trim().toLongOrNull() ?: -1L
            }
        } catch (_: Exception) {}
        return try {
            val parent = path.substringBeforeLast('/', "/")
            val name = path.substringAfterLast('/')
            ftp.listFiles(if (parent.isEmpty()) "/" else parent)
                .firstOrNull { it.name == name }?.size ?: -1L
        } catch (_: Exception) {
            -1L
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        Thread {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post { result.error("ftp", friendlyError(e), null) }
            }
        }.start()
    }

    private fun friendlyError(e: Exception): String = when (e) {
        is java.net.UnknownHostException -> "Can't reach the host. Check the address."
        is java.net.ConnectException -> "Connection refused. Check host, port, and server."
        is java.net.SocketTimeoutException -> "Timed out connecting to the server."
        is com.jcraft.jsch.JSchException -> {
            val msg = e.message ?: ""
            when {
                msg.contains("Auth", ignoreCase = true) || msg.contains("password", ignoreCase = true) ->
                    "Login failed — check username/password."
                msg.contains("UnknownHost", ignoreCase = true) -> "Can't reach the host. Check the address."
                else -> msg.ifEmpty { "SFTP connection failed" }
            }
        }
        else -> e.message ?: "Connection failed"
    }

    // MARK: - Server persistence

    data class FtpServer(
        val id: String,
        val name: String,
        val host: String,
        val port: Int,
        val path: String,
        val username: String,
        val password: String,
        val isSftp: Boolean,
    ) {
        val defaultPort: Int get() = if (isSftp) 22 else 21
        fun toMap(hasPassword: Boolean = password.isNotEmpty()): Map<String, Any?> = mapOf(
            "id" to id,
            "name" to name,
            "host" to host,
            "port" to port,
            "path" to path,
            "username" to username,
            "hasPassword" to hasPassword,
            "isSftp" to isSftp,
        )
    }

    private fun serverPrefs() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private val secretsPrefs by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context, SECRETS_PREFS, masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    private fun readPassword(id: String): String {
        val plain = serverPrefs().getString(PASSWORD_KEY + id, null)
        val encrypted = secretsPrefs.getString(PASSWORD_KEY + id, null)
        if (plain != null && encrypted == null) {
            secretsPrefs.edit().putString(PASSWORD_KEY + id, plain).apply()
            serverPrefs().edit().remove(PASSWORD_KEY + id).apply()
            return plain
        }
        return encrypted ?: ""
    }

    private fun savePassword(id: String, password: String) {
        secretsPrefs.edit().putString(PASSWORD_KEY + id, password).apply()
        serverPrefs().edit().remove(PASSWORD_KEY + id).apply()
    }

    private fun saveServer(
        id: String?,
        name: String,
        host: String,
        port: Int,
        path: String,
        username: String,
        password: String,
        isSftp: Boolean,
    ): Map<String, Any?> {
        require(host.isNotBlank()) { "Host is required" }
        val serverId = id ?: UUID.randomUUID().toString()
        val normalizedPath = normalizeServerPath(path)
        val server = JSONObject()
            .put("name", name.ifEmpty { host })
            .put("host", host.trim())
            .put("port", port)
            .put("path", normalizedPath)
            .put("username", username)
            .put("isSftp", isSftp)
        serverPrefs().edit().putString(SERVER_KEY + serverId, server.toString()).apply()
        if (password.isNotEmpty()) {
            savePassword(serverId, password)
        } else if (id == null) {
            savePassword(serverId, "")
        }
        return serverById(serverId)?.toMap() ?: emptyMap()
    }

    private fun serverById(id: String): FtpServer? {
        val raw = serverPrefs().getString(SERVER_KEY + id, null) ?: return null
        return try {
            val json = JSONObject(raw)
            val isSftp = json.optBoolean("isSftp", false)
            val defaultPort = if (isSftp) 22 else 21
            FtpServer(
                id = id,
                name = json.optString("name"),
                host = json.optString("host"),
                port = json.optInt("port", defaultPort),
                path = json.optString("path", "/").ifEmpty { "/" },
                username = json.optString("username"),
                password = readPassword(id),
                isSftp = isSftp,
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun listServers(): List<Map<String, Any?>> {
        val ids = serverPrefs().all.keys
            .filter { it.startsWith(SERVER_KEY) }
            .map { it.removePrefix(SERVER_KEY) }
            .sorted()
        return ids.mapNotNull { serverById(it)?.toMap() }
    }

    private fun deleteServer(id: String) {
        serverPrefs().edit().remove(SERVER_KEY + id).remove(PASSWORD_KEY + id).apply()
        secretsPrefs.edit().remove(PASSWORD_KEY + id).apply()
        invalidateListingCache(id)
    }

    // MARK: - Store for DataSource playback

    object FtpStore {
        fun resolve(context: Context, serverId: String): FtpServer? {
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(SERVER_KEY + serverId, null) ?: return null
            return try {
                val json = JSONObject(raw)
                val isSftp = json.optBoolean("isSftp", false)
                val defaultPort = if (isSftp) 22 else 21
                val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val secrets = run {
                    val masterKey = MasterKey.Builder(context)
                        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
                    EncryptedSharedPreferences.create(
                        context, SECRETS_PREFS, masterKey,
                        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                    )
                }
                val plain = prefs.getString(PASSWORD_KEY + serverId, null)
                val encrypted = secrets.getString(PASSWORD_KEY + serverId, null)
                val password = if (plain != null && encrypted == null) {
                    secrets.edit().putString(PASSWORD_KEY + serverId, plain).apply()
                    prefs.edit().remove(PASSWORD_KEY + serverId).apply()
                    plain
                } else encrypted ?: ""
                FtpServer(
                    id = serverId,
                    name = json.optString("name"),
                    host = json.optString("host"),
                    port = json.optInt("port", defaultPort),
                    path = json.optString("path", "/").ifEmpty { "/" },
                    username = json.optString("username"),
                    password = password,
                    isSftp = isSftp,
                )
            } catch (_: Exception) { null }
        }
    }

    // MARK: - Protocol

    data class TestResult(val ok: Boolean, val error: String?)

    fun testConnection(
        host: String,
        port: Int,
        path: String,
        username: String,
        password: String,
        isSftp: Boolean,
    ): TestResult {
        if (host.isBlank()) return TestResult(false, "Host is required")
        return try {
            if (isSftp) testSftp(host, port, path, username, password)
            else testFtp(host, port, path, username, password)
            TestResult(true, null)
        } catch (e: Exception) {
            TestResult(false, friendlyError(e))
        }
    }

    private fun testFtp(host: String, port: Int, path: String, username: String, password: String) {
        val ftp = FTPClient().apply {
            connectTimeout = 8000
            defaultTimeout = 8000
        }
        try {
            ftp.connect(host, port)
            if (!ftp.login(username.ifEmpty { "anonymous" }, password.ifEmpty { "anonymous@" })) {
                throw RuntimeException("Login failed — check username/password")
            }
            ftp.enterLocalPassiveMode()
            ftp.setFileType(FTP.BINARY_FILE_TYPE)
            val p = normalizeServerPath(path)
            // List the path to confirm it exists / is listable.
            val files = ftp.listFiles(p)
            // listFiles returns empty for non-existent on some servers; treat empty as ok
            // unless reply is error.
            if (ftp.replyCode in 500..599) {
                throw RuntimeException("FTP error ${ftp.replyCode}: ${ftp.replyString?.trim()}")
            }
        } finally {
            try { ftp.logout() } catch (_: Exception) {}
            try { ftp.disconnect() } catch (_: Exception) {}
        }
    }

    private fun testSftp(host: String, port: Int, path: String, username: String, password: String) {
        val jsch = JSch()
        val session = jsch.getSession(username.ifEmpty { "anonymous" }, host, port)
        if (password.isNotEmpty()) session.setPassword(password)
        val config = Properties(); config["StrictHostKeyChecking"] = "no"
        session.setConfig(config)
        session.timeout = 8000
        session.connect(8000)
        try {
            val channel = session.openChannel("sftp") as ChannelSftp
            channel.connect(5000)
            try {
                val p = normalizeServerPath(path)
                channel.ls(p)
            } finally {
                channel.disconnect()
            }
        } finally {
            session.disconnect()
        }
    }

    fun listDirectory(server: FtpServer, path: String, videoOnly: Boolean = true): List<Map<String, Any?>> {
        val key = cacheKey(server.id, path, videoOnly)
        val now = System.currentTimeMillis()
        val cached = listingCache[key]
        if (cached != null && now - cached.fetchedAtMs < listingTtlMs) {
            android.util.Log.d("FtpClient", "listDirectory cache hit: $key")
            return cached.entries
        }
        val effective = effectivePath(server.path, path)
        val result = if (server.isSftp) listSftpDirectory(server, effective, videoOnly)
        else listFtpDirectory(server, effective, videoOnly)
        listingCache[key] = CachedListing(result, now)
        return result
    }

    private fun listFtpDirectory(server: FtpServer, effective: String, videoOnly: Boolean): List<Map<String, Any?>> {
        val ftp = FTPClient().apply {
            connectTimeout = 10000
            defaultTimeout = 15000
        }
        try {
            ftp.connect(server.host, server.port)
            val user = server.username.ifEmpty { "anonymous" }
            val pass = server.password.ifEmpty { "anonymous@" }
            if (!ftp.login(user, pass)) {
                throw RuntimeException("Login failed — check username/password")
            }
            ftp.enterLocalPassiveMode()
            ftp.setFileType(FTP.BINARY_FILE_TYPE)
            val files = ftp.listFiles(effective)
            if (ftp.replyCode in 500..599) {
                throw RuntimeException("FTP error ${ftp.replyCode}")
            }
            val entries = files.mapNotNull { f ->
                val name = f.name ?: return@mapNotNull null
                if (name == "." || name == "..") return@mapNotNull null
                val isDir = f.isDirectory
                if (!isDir && videoOnly && !isVideo(name)) return@mapNotNull null
                val childPath = joinPath(effective, name)
                mapOf(
                    "name" to name,
                    "path" to childPath,
                    "isDirectory" to isDir,
                    "size" to f.size,
                )
            }
            return entries.sortedWith(
                compareByDescending<Map<String, Any?>> { it["isDirectory"] == true }
                    .thenBy { (it["name"] as? String ?: "").lowercase() }
            )
        } finally {
            try { ftp.logout() } catch (_: Exception) {}
            try { ftp.disconnect() } catch (_: Exception) {}
        }
    }

    private fun listSftpDirectory(server: FtpServer, effective: String, videoOnly: Boolean): List<Map<String, Any?>> {
        val jsch = JSch()
        val session = jsch.getSession(server.username.ifEmpty { "anonymous" }, server.host, server.port)
        if (server.password.isNotEmpty()) session.setPassword(server.password)
        val config = Properties(); config["StrictHostKeyChecking"] = "no"
        session.setConfig(config)
        session.timeout = 10000
        session.connect(10000)
        try {
            val channel = session.openChannel("sftp") as ChannelSftp
            channel.connect(5000)
            try {
                @Suppress("UNCHECKED_CAST")
                val vector = channel.ls(effective) as Vector<ChannelSftp.LsEntry>
                val entries = vector.mapNotNull { entry ->
                    val name = entry.filename
                    if (name == "." || name == "..") return@mapNotNull null
                    val isDir = entry.attrs.isDir
                    if (!isDir && videoOnly && !isVideo(name)) return@mapNotNull null
                    val childPath = joinPath(effective, name)
                    mapOf(
                        "name" to name,
                        "path" to childPath,
                        "isDirectory" to isDir,
                        "size" to entry.attrs.size,
                    )
                }
                return entries.sortedWith(
                    compareByDescending<Map<String, Any?>> { it["isDirectory"] == true }
                        .thenBy { (it["name"] as? String ?: "").lowercase() }
                )
            } finally {
                channel.disconnect()
            }
        } finally {
            session.disconnect()
        }
    }

    private fun normalizeServerPath(raw: String): String {
        var p = raw.trim()
        if (p.isEmpty()) return "/"
        if (!p.startsWith("/")) p = "/$p"
        return p.trimEnd('/').ifEmpty { "/" }
    }

    private fun effectivePath(base: String, requested: String): String {
        val b = normalizeServerPath(base)
        var r = requested.trim()
        if (r.isEmpty() || r == "/") return b
        if (!r.startsWith("/")) r = "/$r"
        return if (b == "/") r.trimEnd('/').ifEmpty { "/" }
        else (b.trimEnd('/') + r).trimEnd('/').ifEmpty { "/" }
    }

    private fun joinPath(parent: String, child: String): String {
        val p = parent.trimEnd('/')
        return if (p.isEmpty() || p == "/") "/$child" else "$p/$child"
    }

    private fun isVideo(name: String): Boolean {
        val dot = name.lastIndexOf('.')
        if (dot < 0) return false
        return name.substring(dot + 1).lowercase() in VIDEO_EXTENSIONS
    }
}
