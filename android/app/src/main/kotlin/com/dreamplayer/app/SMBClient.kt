package com.dreamplayer.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodChannel
import jcifs.CIFSContext
import jcifs.Config
import jcifs.smb.NtlmPasswordAuthenticator
import jcifs.smb.SmbFile
import jcifs.smb.SmbRandomAccessFile
import jcifs.context.SingletonContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyStore
import java.util.Collections
import java.util.Locale
import java.util.Properties
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.concurrent.thread

/// Global jcifs-ng setup. Must run before ANY SmbFile/context is created so the
/// tuned properties (SMB2/3 only, big read sizes, no idle teardown) are baked
/// into the singleton context. Both the browse client and the streaming
/// [SmbDataSource] funnel through [context].
object SmbEngine {
    @Volatile
    private var initialized = false

    @Synchronized
    fun initialize() {
        if (initialized) return
        // Ensure jcifs-ng uses the bundled BouncyCastle, not Android's stripped
        // system "BC" provider (which lacks algorithms jcifs-ng relies on).
        // Installing the real BouncyCastleProvider at priority 1 shadows it.
        try {
            java.security.Security.removeProvider("BC")
        } catch (_: Exception) {}
        try {
            java.security.Security.insertProviderAt(
                org.bouncycastle.jce.provider.BouncyCastleProvider(), 1
            )
        } catch (_: Exception) {}
        try {
            SingletonContext.init(properties())
        } catch (_: Exception) {
            return
        }
        Config.registerSmbURLHandler()
        initialized = true
    }

    fun context(): CIFSContext {
        initialize()
        return SingletonContext.getInstance()
    }

    private fun properties(): Properties {
        val p = Properties()
        // SMB2.02 .. 3.1.1 only (matches smbj's SMB2/3-only stance; no SMB1).
        p["jcifs.smb.client.minVersion"] = "SMB202"
        p["jcifs.smb.client.maxVersion"] = "SMB311"
        p["jcifs.smb.client.disableSMB1"] = "true"
        // Streaming timeouts: snappier than the 35 s defaults so a dead NAS
        // stalls playback for 20 s max instead of 35 s.
        p["jcifs.smb.client.connTimeout"] = "15000"
        p["jcifs.smb.client.soTimeout"] = "20000"
        p["jcifs.smb.client.responseTimeout"] = "30000"
        // Never tear the transport down while a playback session is paused —
        // the prefetch thread keeps the ring full, but a long pause would
        // otherwise kill the connection under the default idle timeout.
        p["jcifs.smb.client.disableIdleTimeout"] = "true"
        p["jcifs.smb.client.tcpNoDelay"] = "true"
        p["jcifs.smb.client.useBatching"] = "true"
        // Increase SMB2 credits so more reads can be pipelined concurrently.
        // Default is 32 for SMB 3.1.1; raising to 64 doubles the read window
        // and should improve throughput on Wi-Fi where per-request latency is
        // the bottleneck.
        p["jcifs.smb.client.maxCredits"] = "64"
        // Larger TCP send/receive buffers reduce syscall overhead for bulk
        // transfers. Default is 65535 (64 KB); 1 MB gives the kernel more
        // room to batch SMB2 read responses.
        p["jcifs.smb.client.rcv_buf_size"] = "1048576"
        p["jcifs.smb.client.snd_buf_size"] = "1048576"
        return p
    }
}

/// Credentials bundle for one SMB server, used both by the browser and the
/// ExoPlayer streaming data source. jcifs-ng credentials live inside a
/// [CIFSContext] chain built off the shared [SmbEngine] singleton, so equal
/// credentials across calls hit the same pooled transport (no reconnect).
data class SmbCredentials(
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
    val domain: String,
    val anonymous: Boolean,
) {
    fun context(): CIFSContext {
        val base = SmbEngine.context()
        return if (anonymous) {
            base.withAnonymousCredentials()
        } else {
            base.withCredentials(NtlmPasswordAuthenticator(domain, username, password))
        }
    }
}

/// AES-GCM (AndroidKeyStore) password encryption so SMB passwords are never
/// stored in plaintext — they stay encrypted in SharedPreferences.
private object SmbCrypto {
    private const val ALIAS = "dreamplayer_smb_key"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore")
        ks.load(null)
        if (!ks.containsAlias(ALIAS)) {
            val gen = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                "AndroidKeyStore",
            )
            gen.init(
                KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            gen.generateKey()
        }
        return ks.getKey(ALIAS, null) as SecretKey
    }

    fun encrypt(plain: String): String? = try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val enc = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        Base64.encodeToString(iv + enc, Base64.NO_WRAP)
    } catch (_: Exception) {
        null
    }

    fun decrypt(encoded: String): String? = try {
        val raw = Base64.decode(encoded, Base64.NO_WRAP)
        val iv = raw.copyOfRange(0, 12)
        val data = raw.copyOfRange(12, raw.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        String(cipher.doFinal(data), Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }
}

/// Server list + encrypted credentials, shared between the browse UI and the
/// ExoPlayer `SmbDataSource` (which resolves `smb://<serverId>/...` URIs).
object SmbStore {

    private const val PREFS = "dreamplayer_smb"
    private const val KEY_SERVERS = "servers"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun servers(context: Context): List<JSONObject> {
        val raw = prefs(context).getString(KEY_SERVERS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getJSONObject(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun serverById(context: Context, id: String): JSONObject? =
        servers(context).firstOrNull { it.optString("id") == id }

    fun save(context: Context, server: JSONObject) {
        val id = server.optString("id").ifEmpty { UUID.randomUUID().toString() }
        server.put("id", id)
        val list = servers(context).filterNot { it.optString("id") == id }.toMutableList()
        list.add(server)
        prefs(context).edit().putString(KEY_SERVERS, JSONArray(list).toString()).apply()
    }

    fun delete(context: Context, id: String) {
        val list = servers(context).filterNot { it.optString("id") == id }
        prefs(context).edit().putString(KEY_SERVERS, JSONArray(list).toString()).apply()
    }

    /// Manually-added share names (SMB2 has no NetShareEnum, so we can't list a
    /// server's shares; we probe well-known names instead).
    fun shares(context: Context, serverId: String): List<String> {
        val raw = prefs(context).getString("shares_$serverId", null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getString(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun addShare(context: Context, serverId: String, shareName: String): Boolean {
        val list = shares(context, serverId).toMutableSet()
        val added = list.add(shareName)
        if (added) {
            prefs(context)
                .edit()
                .putString("shares_$serverId", JSONArray(list.toList()).toString())
                .apply()
        }
        return added
    }

    /// Resolves an `smb://<serverId>/...` URI back to a credential bundle.
    fun resolve(context: Context, serverId: String): SmbCredentials? {
        val s = serverById(context, serverId) ?: return null
        val password = s.optString("passwordEnc").ifEmpty { "" }
            .let { if (it.isEmpty()) "" else SmbCrypto.decrypt(it) ?: "" }
        return SmbCredentials(
            host = s.optString("host"),
            port = s.optInt("port", 445),
            username = s.optString("username"),
            password = password,
            domain = s.optString("domain"),
            anonymous = s.optBoolean("anonymous"),
        )
    }

    fun toMap(server: JSONObject): Map<String, Any?> = mapOf(
        "id" to server.optString("id"),
        "name" to server.optString("name"),
        "host" to server.optString("host"),
        "port" to server.optInt("port", 445),
        "username" to server.optString("username"),
        "domain" to server.optString("domain"),
        "anonymous" to server.optBoolean("anonymous"),
        "hasPassword" to (server.optString("passwordEnc").isNotEmpty()),
    )
}

/// SMB2/3 browse client exposed over the `dreamplayer/smb` MethodChannel.
///
/// Each call makes a fresh connection (simple + robust to NAS sleep); the
/// roadmap's reconnect/reuse is a later refinement.
class SMBClient(private val context: Context) {

    companion object {
        const val CHANNEL = "dreamplayer/smb"

        private val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
            "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
        )

        /// Sideloaded subtitles auto-paired with a same-named video in a folder.
        private val SUBTITLE_EXTENSIONS = setOf("srt", "ass", "ssa", "vtt", "sub", "smi")

        private const val SMB_PORT = 445
        private const val SCAN_TIMEOUT_MS = 500
        private const val PROBE_TIMEOUT_MS = 1500

        /// Cap for a fetched sidecar subtitle file (50 MiB — far larger than any
        /// real .srt/.ass/.vtt; protects against a misread/wrong file).
        private const val MAX_ALT_SUB_BYTES = 50 * 1024 * 1024

        /// Share names probed on every server browse, since SMB2 can't
        /// enumerate shares. NAS boxes (Synology/QNAP/OpenMediaVault/Windows)
        /// almost always expose one of these.
        private val COMMON_SHARES = listOf(
            "videos", "video", "movies", "movie", "tv", "tvshows", "series",
            "media", "downloads", "download", "public", "share", "shares",
            "shared", "files", "home", "homes", "music", "photos", "photo",
            "Documents", "Desktop",
        )
    }

    // 4-thread pool: directory listings + share probes + open-share can run in
    // parallel. SingleThread was the stall source — browsing a folder queued
    // behind a slow listShares probe. Nova's FileCoreLibrary uses a cached pool
    // for the same reason (jcifs-ng CIFSContext child per call is thread-safe).
    private val executor = Executors.newFixedThreadPool(4)

    /// Discovery + reachability probes are fast and must NOT block the browse
    /// executor (a slow scan would stall folder browsing), so they get their
    /// own pool and run concurrently.
    private val quickExecutor = Executors.newCachedThreadPool()

    /// Directory-listing cache: re-visiting a folder is instant (Nova's smbj
    /// keeps the DiskShare cached, but the QUERY_DIRECTORY still re-runs).
    /// Key = "$serverId|$shareName|$path", value = (entries, fetchedAtMs).
    /// TTL 60 s; invalidated on refresh or when the user navigates back to
    /// a share root. The underlying jcifs-ng tree-connect is already pooled
    /// via SingletonContext, so the network cost is one QUERY_DIRECTORY
    /// round-trip per cache miss.
    private data class CachedListing(
        val entries: List<Map<String, Any?>>,
        val fetchedAtMs: Long,
    )
    private val listingCache = java.util.concurrent.ConcurrentHashMap<String, CachedListing>()
    private val listingTtlMs = 60_000L

    private fun cacheKey(serverId: String, shareName: String, path: String): String =
        "$serverId|$shareName|${path.replace(Regex("/+"), "/").trim('/')}"

    fun invalidateListingCache(serverId: String? = null, shareName: String? = null) {
        if (serverId == null) {
            listingCache.clear()
        } else {
            listingCache.keys.removeAll { key ->
                val prefix = if (shareName != null) "$serverId|$shareName|" else "$serverId|"
                key.startsWith(prefix)
            }
        }
    }

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "listServers" -> result.success(SmbStore.servers(context).map(SmbStore::toMap))
                "saveServer" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("bad_args", "Missing server", null)
                    } else {
                        executor.execute {
                            try {
                                result.success(saveServer(args))
                            } catch (e: Exception) {
                                result.error("save_failed", e.message, null)
                            }
                        }
                    }
                }
                "deleteServer" -> {
                    val id = call.argument<String>("id")
                    if (id == null) {
                        result.error("bad_args", "Missing id", null)
                    } else {
                        SmbStore.delete(context, id)
                        invalidateListingCache(serverId = id)
                        result.success(null)
                    }
                }
                "invalidateListingCache" -> {
                    val id = call.argument<String>("id")
                    invalidateListingCache(serverId = id)
                    result.success(null)
                }
                "testConnection" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("bad_args", "Missing params", null)
                    } else {
                        executor.execute {
                            result.success(testConnection(args))
                        }
                    }
                }
                "listShares" -> {
                    val id = call.argument<String>("id")
                    if (id == null) {
                        result.error("bad_args", "Missing id", null)
                    } else {
                        executor.execute {
                            try {
                                result.success(listShares(id))
                            } catch (e: jcifs.smb.SmbAuthException) {
                                result.error("smb_auth", "Login failed — check username/password/domain", null)
                            } catch (e: Exception) {
                                result.error("smb_error", e.message, null)
                            }
                        }
                    }
                }
                "addShare" -> {
                    val id = call.argument<String>("id")
                    val shareName = call.argument<String>("share")
                    if (id == null || shareName.isNullOrBlank()) {
                        result.error("bad_args", "Missing id or share", null)
                    } else {
                        result.success(SmbStore.addShare(context, id, shareName.trim()))
                    }
                }
                "listDirectory" -> {
                    val id = call.argument<String>("id")
                    val shareName = call.argument<String>("share")
                    val path = call.argument<String>("path") ?: ""
                    if (id == null || shareName == null) {
                        result.error("bad_args", "Missing id or share", null)
                    } else {
                        executor.execute {
                            try {
                                result.success(listDirectory(id, shareName, path))
                            } catch (e: jcifs.smb.SmbAuthException) {
                                result.error("smb_auth", "Login failed — check username/password/domain", null)
                            } catch (e: Exception) {
                                result.error("smb_error", e.message, null)
                            }
                        }
                    }
                }
                // Nova-parity sidecar enumeration: return the *full* directory
                // listing (videos AND subtitle sidecars) without the native
                // subtitle-attachment logic, so the sidecar service can pair
                // by name. The regular `listDirectory` filters to videos and
                // only attaches subtitles to their video entry — which would
                // hide the `.srt` from the sidecar fallback.
                "listDirectoryAll" -> {
                    val id = call.argument<String>("id")
                    val shareName = call.argument<String>("share")
                    val path = call.argument<String>("path") ?: ""
                    if (id == null || shareName == null) {
                        result.error("bad_args", "Missing id or share", null)
                    } else {
                        executor.execute {
                            try {
                                result.success(listDirectoryAll(id, shareName, path))
                            } catch (e: jcifs.smb.SmbAuthException) {
                                result.error("smb_auth", "Login failed — check username/password/domain", null)
                            } catch (e: Exception) {
                                result.error("smb_error", e.message, null)
                            }
                        }
                    }
                }
                "discoverServers" -> {
                    quickExecutor.execute {
                        try {
                            result.success(discoverServers())
} catch (e: Exception) {
                result.error("discovery_failed", e.message, null)
                        }
                    }
                }
                "checkServer" -> {
                    val host = call.argument<String>("host")
                    if (host.isNullOrBlank()) {
                        result.error("bad_args", "Missing host", null)
                    } else {
                        val port = call.argument<Number>("port")?.toInt() ?: SMB_PORT
                        quickExecutor.execute {
                            result.success(isPortOpen(host, port, PROBE_TIMEOUT_MS))
                        }
                    }
                }
                // Android returns an smb:// URI — ExoPlayer's SmbDataSource
                // resolves it to the saved server + encrypted credentials.
                "openShare" -> {
                    val id = call.argument<String>("id")
                    val share = call.argument<String>("share")
                    val path = call.argument<String>("path") ?: ""
                    if (id == null || share == null) {
                        result.error("bad_args", "Missing id or share", null)
                    } else {
                        val uri = if (path.isEmpty()) "smb://$id/$share/"
                            else "smb://$id/$share/$path"
                        result.success(uri)
                    }
                }
                // No per-share teardown needed on Android — SmbDataSource
                // closes its handles on close(); SmbClient owns the
                // credential store lifetime.
                "closeShare" -> {
                    result.success(null)
                }
                // Loopback HTTP bridge for the libmpv fallback engine: serve
                // the SMB file over a local 127.0.0.1 HTTP endpoint that
                // supports byte ranges, and hand the returned URL to mpv.
                "startLoopback" -> {
                    val id = call.argument<String>("id")
                    val share = call.argument<String>("share")
                    val path = call.argument<String>("path") ?: ""
                    if (id == null || share == null) {
                        result.error("bad_args", "Missing id or share", null)
                    } else {
                        val main = Handler(Looper.getMainLooper())
                        thread(isDaemon = true, name = "smb-loopback-open") {
                            val url = SmbHttpProxy.start(context, id, share, path)
                            main.post {
                                if (url == null) {
                                    result.error("smb_error", "Could not open this file for streaming", null)
                                } else {
                                    result.success(url)
                                }
                            }
                        }
                    }
                }
                "stopLoopback" -> {
                    val token = call.argument<String>("token")
                    if (token != null) SmbHttpProxy.stop(token)
                    result.success(null)
                }
                // Nova-parity sidecar prefetch: read a subtitle file's bytes
                // straight off the share (same jcifs-ng handle machinery as
                // SmbDataSource), so the Dart side can write it to a local
                // cache and hand the engine a file:// track (AVP issue #1605).
                "fetchBytes" -> {
                    val args = call.arguments as? Map<*, *>
                    val id = args?.get("id") as? String
                    val share = args?.get("share") as? String
                    val path = args?.get("path") as? String
                    val maxBytes = (args?.get("maxBytes") as? Number)?.toInt() ?: MAX_ALT_SUB_BYTES
                    if (id == null || share == null) {
                        result.error("bad_args", "Missing id or share", null)
                    } else {
                        executor.execute {
                            try {
                                result.success(altSubBytes(id, share, path ?: "", maxBytes))
                            } catch (e: jcifs.smb.SmbAuthException) {
                                result.error("smb_auth", "Login failed — check username/password/domain", null)
                            } catch (e: Exception) {
                                result.error("smb_error", e.message, null)
                            }
                        }
                    }
                }
                // Background size fetch: open each file and call length() on
                // a daemon thread, returning a map of path→size. Called after
                // listDirectory returns so the UI shows entries immediately
                // and sizes fill in progressively.
                "fetchSizes" -> {
                    val args = call.arguments as? Map<*, *>
                    val id = args?.get("id") as? String
                    val share = args?.get("share") as? String
                    val paths = args?.get("paths") as? List<*>
                    if (id == null || share == null || paths == null) {
                        result.error("bad_args", "Missing id, share, or paths", null)
                    } else {
                        executor.execute {
                            try {
                                result.success(fetchSizes(id, share, paths.filterIsInstance<String>()))
                            } catch (e: jcifs.smb.SmbAuthException) {
                                result.error("smb_auth", "Login failed — check username/password/domain", null)
                            } catch (e: Exception) {
                                result.error("smb_error", e.message, null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Reads up to [maxBytes] of the file at [share]/[path] on the saved server
    /// [id] into a ByteArray (nil-safe: returns null on 404/no access so sidecar
    /// discovery treats it as "no subtitle"). Mirrors SmbDataSource's credential
    /// resolution so passwords never touch Dart.
    private fun altSubBytes(id: String, share: String, path: String, maxBytes: Int): ByteArray? {
        val creds = SmbStore.resolve(context, id) ?: return null
        val base = "smb://${creds.host}:${creds.port}/$share"
        val url = if (path.isEmpty()) base else "$base/$path"
        // jcifs-ng SmbFile/Defaults handle capitalization; reuse SmbStore's
        // NtlmPasswordAuthenticator via creds.context().
        return try {
            SmbRandomAccessFile(SmbFile(url, creds.context()), "r").use { raf ->
                val len = raf.length()
                if (len <= 0) return null
                val read = minOf(len.toInt(), maxBytes)
                val buf = ByteArray(read)
                var off = 0
                var left = read
                while (left > 0) {
                    val n = raf.read(buf, off, left)
                    if (n < 0) break
                    off += n
                    left -= n
                }
                if (off == 0) null else buf.copyOf(off)
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun saveServer(args: Map<*, *>): Map<String, Any?> {
        val id = args["id"] as? String
        val server = SmbStore.serverById(context, id ?: "")?.let { JSONObject(it.toString()) }
            ?: JSONObject()
        val host = (args["host"] as? String)?.trim().orEmpty()
        require(host.isNotEmpty()) { "Host is required" }
        val password = (args["password"] as? String).orEmpty()
        val name = (args["name"] as? String)?.trim()
        server.put("name", if (name.isNullOrEmpty()) host else name)
        server.put("host", host)
        server.put("port", (args["port"] as? Number)?.toInt() ?: 445)
        server.put("domain", (args["domain"] as? String).orEmpty())
        server.put("username", (args["username"] as? String).orEmpty())
        server.put("anonymous", args["anonymous"] == true)
        if (args.containsKey("password") && password.isNotEmpty()) {
            server.put("passwordEnc", SmbCrypto.encrypt(password) ?: "")
        } else if (!args.containsKey("password")) {
            // keep existing stored password on partial updates
        }
        SmbStore.save(context, server)
        return SmbStore.toMap(server)
    }

    private fun testConnection(args: Map<*, *>): Map<String, Any?> {
        val host = (args["host"] as? String)?.trim().orEmpty()
        try {
            require(host.isNotEmpty()) { "Host is required" }
            val creds = SmbCredentials(
                host = host,
                port = (args["port"] as? Number)?.toInt() ?: 445,
                username = (args["username"] as? String).orEmpty(),
                password = (args["password"] as? String).orEmpty(),
                domain = (args["domain"] as? String).orEmpty(),
                anonymous = args["anonymous"] == true,
            )
            val ctx = creds.context()
            var ok = false
            var reachable = false
            for (name in COMMON_SHARES) {
                try {
                    if (SmbFile("smb://$host:${creds.port}/$name/", ctx).exists()) {
                        ok = true
                        reachable = true
                        break
                    }
                } catch (e: jcifs.smb.SmbAuthException) {
                    return mapOf("ok" to false, "error" to "Login failed — check username/password/domain")
                } catch (e: jcifs.CIFSException) {
                    // Authenticated, but this share doesn't exist / is denied —
                    // keep probing so we don't report a bad share as a bad login.
                    reachable = true
                } catch (_: Exception) {
                    // Unreachable or DNS failure — fall through to the summary.
                }
            }
            return if (ok || reachable) {
                mapOf("ok" to true, "error" to null)
            } else {
                mapOf("ok" to false, "error" to "No SMB response from $host")
            }
        } catch (e: Exception) {
            return mapOf("ok" to false, "error" to (e.message ?: "Connection failed"))
        }
    }

    private fun listShares(serverId: String): List<Map<String, Any?>> {
        val creds = SmbStore.resolve(context, serverId)
            ?: throw IllegalStateException("Unknown server")
        val ctx = creds.context()
        // Case-insensitive dedup — "Videos" and "videos" are the same share
        // on Windows/SMB. Preserve the first-seen casing (usually the server's
        // real name from enumeration).
        android.util.Log.d("SMBClient", "listShares: serverId=$serverId host=${creds.host} port=${creds.port}")
        val lowerToName = LinkedHashMap<String, String>()
        fun addName(n: String) {
            val lower = n.lowercase(Locale.ROOT)
            if (!lowerToName.containsKey(lower)) lowerToName[lower] = n
        }
        SmbStore.shares(context, serverId).forEach { addName(it) }
        var authFailed = false
        // Try proper share enumeration first (SMB2 via MS-SRVS RAP). This
        // catches custom share names that aren't in COMMON_SHARES. If the
        // server denies enumeration, fall back to probing well-known names.
        try {
            val root = SmbFile("smb://${creds.host}:${creds.port}/", ctx)
            val files = root.listFiles()
            android.util.Log.d("SMBClient", "listShares: enumeration returned ${files?.size ?: 0} entries")
            files?.forEach { f ->
                val raw = f.name.trimEnd('/', '\\')
                if (raw.isEmpty() || raw == "." || raw == "..") return@forEach
                // Filter IPC$ / admin hidden shares — not browsable media.
                if (raw.equals("IPC\$", ignoreCase = true)) return@forEach
                if (raw.endsWith("$")) return@forEach
                addName(raw)
            }
            android.util.Log.d("SMBClient", "listShares: after enumeration lowerToName=${lowerToName.keys}")
        } catch (e: jcifs.smb.SmbAuthException) {
            android.util.Log.d("SMBClient", "listShares: enumeration authFailed $e")
            authFailed = true
        } catch (e: Exception) {
            android.util.Log.d("SMBClient", "listShares: enumeration failed ${e.message}")
            // Enumeration not supported / denied — fall through to probing.
        }
        for (name in COMMON_SHARES) {
            val lower = name.lowercase(Locale.ROOT)
            if (lowerToName.containsKey(lower)) continue
            try {
                if (SmbFile("smb://${creds.host}:${creds.port}/$name/", ctx).exists()) {
                    android.util.Log.d("SMBClient", "listShares: probe found $name")
                    addName(name)
                }
            } catch (e: jcifs.smb.SmbAuthException) {
                android.util.Log.d("SMBClient", "listShares: probe $name authFailed")
                // Wrong/empty credentials get SmbAuthException — remember it and
                // keep probing, but report a bad login if nothing was found.
                authFailed = true
            } catch (e: Exception) {
                android.util.Log.d("SMBClient", "listShares: probe $name failed ${e.message}")
                // not a disk share / no access — skip
            }
        }
        android.util.Log.d("SMBClient", "listShares: final lowerToName=${lowerToName.keys} authFailed=$authFailed")
        if (authFailed && lowerToName.isEmpty()) {
            throw IllegalStateException("Login failed — check username/password/domain")
        }
        return lowerToName.values.sortedBy { it.lowercase(Locale.ROOT) }
            .map { name ->
                mapOf(
                    "name" to name,
                    "path" to name,
                    "isDirectory" to true,
                    "size" to 0L,
                    "modified" to 0L,
                )
            }
    }

    private fun listDirectory(
        serverId: String,
        shareName: String,
        path: String,
    ): List<Map<String, Any?>> {
        val key = cacheKey(serverId, shareName, path)
        val now = System.currentTimeMillis()
        val cached = listingCache[key]
        if (cached != null && now - cached.fetchedAtMs < listingTtlMs) {
            android.util.Log.d("SMBClient", "listDirectory cache hit: $key")
            return cached.entries
        }

        val creds = SmbStore.resolve(context, serverId)
            ?: throw IllegalStateException("Unknown server")
        val ctx = creds.context()
        val dirUrl = "smb://${creds.host}:${creds.port}/$shareName/" +
            if (path.isEmpty()) "" else "$path/"
        val entries = SmbFile(dirUrl, ctx).listFiles() ?: emptyArray()
        val dirs = mutableListOf<Map<String, Any?>>()
        val videos = mutableListOf<Pair<String, Map<String, Any?>>>()
        val subtitles = HashMap<String, MutableList<String>>()
        for (f in entries) {
            val name = f.name
            if (name == "." || name == "..") continue
            val isDir = f.isDirectory()
            val relPath = if (path.isEmpty()) name else "$path/$name"
            if (isDir) {
                dirs.add(entryMap(name, relPath, true, 0L, 0L))
            } else if (isVideo(name)) {
                // Skip per-file length()/lastModified() — each is a separate
                // SMB GetInfo round-trip; for large folders this adds minutes.
                // Size is reported as 0 here; the streaming path fetches it.
                videos.add(
                    name to entryMap(name, relPath, false, 0L, 0L),
                )
            } else if (isSubtitle(name)) {
                subtitles.getOrPut(baseName(name).lowercase(Locale.ROOT)) { mutableListOf() }
                    .add(relPath)
            }
        }
        val files = videos.map { (name, entry) ->
            val matches = findMatchingSubtitles(baseName(name).lowercase(Locale.ROOT), subtitles)
            if (matches.isNotEmpty()) entry + mapOf(
                "subtitlePath" to matches.first(),
                "subtitlePaths" to matches,
            ) else entry
        }.toMutableList()
        dirs.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
        files.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
        val result = dirs + files
        listingCache[key] = CachedListing(result, now)
        return result
    }

    /// Full directory listing (videos + sidecar subtitles) without the native
    /// video→subtitle attachment, so the sidecar service can pair by name
    /// (Nova `RawListerFactory.getFileList()` parity). Mirrors the FTP
    /// `listDirectoryAll` channel method.
    private fun listDirectoryAll(
        serverId: String,
        shareName: String,
        path: String,
    ): List<Map<String, Any?>> {
        val key = cacheKey(serverId, shareName, path) + "|all"
        val now = System.currentTimeMillis()
        val cached = listingCache[key]
        if (cached != null && now - cached.fetchedAtMs < listingTtlMs) {
            android.util.Log.d("SMBClient", "listDirectoryAll cache hit: $key")
            return cached.entries
        }

        val creds = SmbStore.resolve(context, serverId)
            ?: throw IllegalStateException("Unknown server")
        val ctx = creds.context()
        val dirUrl = "smb://${creds.host}:${creds.port}/$shareName/" +
            if (path.isEmpty()) "" else "$path/"
        val entries = SmbFile(dirUrl, ctx).listFiles() ?: emptyArray()
        val dirs = mutableListOf<Map<String, Any?>>()
        val files = mutableListOf<Map<String, Any?>>()
        for (f in entries) {
            val name = f.name
            if (name == "." || name == "..") continue
            val isDir = f.isDirectory()
            val relPath = if (path.isEmpty()) name else "$path/$name"
            if (isDir) {
                dirs.add(entryMap(name, relPath, true, 0L, 0L))
            } else {
                files.add(entryMap(name, relPath, false, 0L, 0L))
            }
        }
        dirs.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
        files.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
        val result = dirs + files
        listingCache[key] = CachedListing(result, now)
        return result
    }

    private fun entryMap(
        name: String,
        path: String,
        isDir: Boolean,
        size: Long,
        modified: Long,
    ): Map<String, Any?> = mapOf(
        "name" to name,
        "path" to path,
        "isDirectory" to isDir,
        "size" to size,
        "modified" to modified,
    )

    /// Opens each file at [paths] and calls length() to populate sizes
    /// that `listDirectory` skipped. Returns a map of path→size for entries
    /// where the size is > 0.
    private fun fetchSizes(
        serverId: String,
        shareName: String,
        paths: List<String>,
    ): Map<String, Long> {
        val creds = SmbStore.resolve(context, serverId)
            ?: throw IllegalStateException("Unknown server")
        val ctx = creds.context()
        val base = "smb://${creds.host}:${creds.port}/$shareName"
        val sizes = HashMap<String, Long>()
        for (p in paths) {
            try {
                val url = "$base/$p"
                val len = SmbRandomAccessFile(SmbFile(url, ctx), "r").use { it.length() }
                if (len > 0) sizes[p] = len
            } catch (_: Exception) {
                // Best-effort: skip files that can't be opened
            }
        }
        return sizes
    }

    private fun isVideo(name: String): Boolean = hasExtension(name, VIDEO_EXTENSIONS)

    private fun isSubtitle(name: String): Boolean = hasExtension(name, SUBTITLE_EXTENSIONS)

    private fun hasExtension(name: String, extensions: Set<String>): Boolean {
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.length - 1) return false
        return name.substring(dot + 1).lowercase(Locale.ROOT) in extensions
    }

    /// File name without its last extension (e.g. `Show.S01E01.eng.srt` ->
    /// `Show.S01E01.eng`).
    private fun baseName(name: String): String {
        val dot = name.lastIndexOf('.')
        return if (dot > 0) name.substring(0, dot) else name
    }

    /// Finds the best subtitle for a video in the same folder: prefer an exact
    private fun findMatchingSubtitles(
        videoBase: String,
        subtitles: Map<String, List<String>>,
    ): List<String> {
        subtitles[videoBase]?.sorted()?.let { return it }
        val out = mutableListOf<String>()
        for ((subBase, paths) in subtitles) {
            if (subBase.startsWith("$videoBase.")) out.addAll(paths)
        }
        return out.sorted()
    }

    @Suppress("unused")
    private fun findMatchingSubtitle(
        videoBase: String,
        subtitles: Map<String, List<String>>,
    ): String? = findMatchingSubtitles(videoBase, subtitles).firstOrNull()

    /// Finds SMB hosts on the local LAN: TCP-ports-445 subnet scan (capped at a
    /// /24 window so big subnets stay quick), then resolves each open host's
    /// display name via reverse DNS. jcifs-ng has no NetBIOS/SMB1 discovery —
    /// SMB2/3 only.
    private fun discoverServers(): List<Map<String, Any?>> {
        val subnet = localSubnet() ?: return emptyList()
        val found = Collections.synchronizedSet(LinkedHashSet<Long>())
        val pool = Executors.newFixedThreadPool(32)
        val tasks = ArrayList<Future<*>>()
        var ip = subnet.first + 1
        while (ip < subnet.second) {
            if (ip != subnet.third) {
                val candidate = ip
                tasks.add(
                    pool.submit {
                        if (isPortOpen(intToIp(candidate), SMB_PORT, SCAN_TIMEOUT_MS)) {
                            found.add(candidate)
                        }
                    },
                )
            }
            ip++
        }
        pool.shutdown()
        try {
            pool.awaitTermination(30, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return found.sorted().map { ip ->
            val ipStr = intToIp(ip)
            mapOf(
                "host" to ipStr,
                "hostname" to (serverName(ipStr) ?: ipStr),
            )
        }
    }

    /// The Wi-Fi/LAN interface's IPv4 subnet as (network, broadcast, ownIp),
    /// with the scan window capped at /24.
    private fun localSubnet(): Triple<Long, Long, Long>? {
        val interfaces = java.net.NetworkInterface.getNetworkInterfaces() ?: return null
        for (ni in interfaces) {
            if (!ni.isUp || ni.isLoopback) continue
            for (ia in ni.interfaceAddresses) {
                val addr = ia.address as? Inet4Address ?: continue
                if (addr.isLoopbackAddress || addr.isLinkLocalAddress || !addr.isSiteLocalAddress) continue
                val prefix = ia.networkPrefixLength.toInt().coerceIn(24, 32)
                val mask = if (prefix == 32) {
                    0xFFFFFFFFL
                } else {
                    (0xFFFFFFFFL shl (32 - prefix)) and 0xFFFFFFFFL
                }
                val ip = ipToLong(addr)
                return Triple(ip and mask, ip or (mask.inv() and 0xFFFFFFFFL), ip)
            }
        }
        return null
    }

    private fun ipToLong(addr: Inet4Address): Long {
        val b = addr.address
        return ((b[0].toLong() and 0xFF) shl 24) or
            ((b[1].toLong() and 0xFF) shl 16) or
            ((b[2].toLong() and 0xFF) shl 8) or
            (b[3].toLong() and 0xFF)
    }

    private fun intToIp(v: Long): String =
        "${(v shr 24) and 0xFF}.${(v shr 16) and 0xFF}.${(v shr 8) and 0xFF}.${v and 0xFF}"

    private fun isPortOpen(host: String, port: Int, timeoutMs: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs) }
        true
    } catch (_: Exception) {
        false
    }

    /// Resolves a host's display name: reverse DNS, falling back to the raw IP.
    private fun serverName(ip: String): String? = try {
        val host = InetAddress.getByName(ip).hostName
        if (host.isNullOrBlank() || host == ip) null else host
    } catch (_: Exception) {
        null
    }
}
