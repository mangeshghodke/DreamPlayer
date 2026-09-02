package com.dreamplayer.app

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Xml
import io.flutter.plugin.common.MethodChannel
import okhttp3.Credentials
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import java.net.URL
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import android.util.Log

private const val TAG = "WebDAVClient"

/// In-app WebDAV browser (channel `dreamplayer/webdav`).
///
/// Browsing is a `PROPFIND` against the server and playback is a plain HTTP
/// GET served to ExoPlayer's `DefaultHttpDataSource` with a Basic auth header
/// (see [WebDAVClient.authorizationHeader]).
///
/// Networking goes through OkHttp, because Android's `HttpURLConnection`
/// restricts request methods to `OPTIONS GET HEAD POST PUT DELETE TRACE
/// PATCH` — it throws `ProtocolException` on `PROPFIND` ("Expected one of
/// [...] but was PROPFIND"). OkHttp allows arbitrary methods.
///
/// Saved servers (name + base URL + credentials) are stored in app-private
/// SharedPreferences. The password never crosses to Dart — only a `hasPassword`
/// flag is returned; Dart requests the ready-made `Authorization` header via
/// [WebDAVClient.authorizationHeader].
class WebDAVClient(private val context: Context) {

    companion object {
        const val CHANNEL = "dreamplayer/webdav"

        private const val PREFS = "dreamplayer.webdavServers"
        private const val SECRETS_PREFS = "dreamplayer.webdavSecrets"
        private const val PASSWORD_KEY = "password."
        private const val SERVER_KEY = "server."

        private val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
            "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
        )

        /// Reasonable cap for a downloaded subtitle sidecar (50 MiB — far larger
        /// than any real .srt/.ass/.vtt/.sub; protects against a misconfigured
        /// server answering a wrong URL with a huge file, mirroring Nova's
        /// MAX_SUB_SIZE guard).
        private const val MAX_SUB_BYTES = 50 * 1024 * 1024
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /// One client is fine: OkHttp manages its own connection pool and retries.
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    /// Trusts every certificate. Used only for servers the user explicitly
    /// marked "Accept self-signed certificates"; the [client] above keeps the
    /// system trust store for everything else.
    private val permissiveClient: OkHttpClient by lazy {
        val trustAll = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(null, arrayOf(trustAll), SecureRandom())
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .sslSocketFactory(sslContext.socketFactory, trustAll)
            .hostnameVerifier { _, _ -> true }
            .build()
    }

    /// Directory-listing cache: re-visiting a folder is instant.
    /// Key = "$baseUrl|$path|selfSigned", value = (entries, fetchedAtMs).
    /// TTL 60 s. Underlying OkHttp connection pool already reuses connections,
    /// so the network cost on a miss is one PROPFIND round-trip.
    private data class CachedListing(
        val entries: List<Map<String, Any?>>,
        val fetchedAtMs: Long,
    )
    private val listingCache = java.util.concurrent.ConcurrentHashMap<String, CachedListing>()
    private val listingTtlMs = 60_000L

    private fun cacheKey(baseUrl: String, path: String, allowSelfSigned: Boolean): String =
        "${baseUrl.trimEnd('/')}|${path.replace(Regex("/+"), "/").trim('/')}|$allowSelfSigned"

    fun invalidateListingCache(baseUrl: String? = null) {
        if (baseUrl == null) {
            listingCache.clear()
        } else {
            val prefix = "${baseUrl.trimEnd('/')}|"
            listingCache.keys.removeAll { it.startsWith(prefix) }
        }
    }

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveServer" -> {
                    val id = call.argument<String>("id")
                    val name = call.argument<String>("name") ?: ""
                    val url = call.argument<String>("url") ?: ""
                    val username = call.argument<String>("username") ?: ""
                    val password = call.argument<String>("password") ?: ""
                    val allowSelfSigned = call.argument<Boolean>("allowSelfSigned") ?: false
                    result.success(saveServer(id, name, url, username, password, allowSelfSigned))
                }
                "listServers" -> result.success(listServers())
                "deleteServer" -> {
                    call.argument<String>("id")?.let { deleteServer(it) }
                    result.success(null)
                }
                "invalidateListingCache" -> {
                    call.argument<String>("url")?.let { invalidateListingCache(it) }
                    result.success(null)
                }
                "testConnection" -> {
                    val url = call.argument<String>("url") ?: ""
                    val username = call.argument<String>("username") ?: ""
                    val password = call.argument<String>("password") ?: ""
                    val allowSelfSigned = call.argument<Boolean>("allowSelfSigned") ?: false
                    runAsync(result) {
                        val r = testConnection(url, username, password, allowSelfSigned)
                        mapOf("ok" to r.ok, "error" to r.error)
                    }
                }
                "listDirectory" -> {
                    val id = call.argument<String>("id")
                    val path = call.argument<String>("path") ?: "/"
                    runAsync(result) {
                        val server = id?.let { serverById(it) }
                            ?: throw RuntimeException("WebDAV server not found")
                        listDirectory(server.url, server.username, server.password, path, server.allowSelfSigned)
                    }
                }
                "authorizationHeader" -> {
                    val id = call.argument<String>("id")
                    val server = id?.let { serverById(it) }
                    if (server == null) {
                        result.error("bad_args", "WebDAV server not found", null)
                    } else {
                        result.success(server.authorizationHeader)
                    }
                }
                "fetchUrl" -> {
                    // Downloads [url] and returns its bytes when the HTTP status
                    // is 200, otherwise null. Auth/trust come from either a saved
                    // WebDAV server ([id]) or explicit [headers]/[allowSelfSigned]
                    // for generic http(s) sources. Used to probe a candidate
                    // sidecar subtitle URL and fetch it to a local cache file
                    // (Nova-style), so the engine never has to stream an
                    // authenticated subtitle over the network.
                    val id = call.argument<String>("id")
                    val url = call.argument<String>("url") ?: ""
                    val headersArg = call.argument<Map<String, String>>("headers")
                    val allowSelfSigned = call.argument<Boolean>("allowSelfSigned") ?: false
                    if (url.isEmpty()) {
                        result.error("bad_args", "URL is required", null)
                        return@setMethodCallHandler
                    }
                    runAsync(result) {
                        val server = id?.let { serverById(it) }
                        fetchUrl(
                            url,
                            headers = if (server != null) {
                                mapOf("Authorization" to server.authorizationHeader)
                            } else headersArg ?: emptyMap(),
                            selfSigned = if (server != null) server.allowSelfSigned else allowSelfSigned,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Runs a blocking network call off the main thread and resolves [result]
    /// on the main thread once the call completes.
    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        Thread {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("webdav", friendlyError(e), null)
                }
            }
        }.start()
    }

    /// Turns raw networking/SSL exceptions into messages a user can act on.
    private fun friendlyError(e: Exception): String = when (e) {
        is javax.net.ssl.SSLHandshakeException,
        is javax.net.ssl.SSLPeerUnverifiedException,
        is javax.net.ssl.SSLException ->
            "The server's certificate is not trusted. Turn on 'Accept self-signed certificate' if it uses a self-signed or private certificate."
        is java.net.UnknownHostException ->
            "Can't reach the host. Check the address and your network."
        is java.net.ConnectException ->
            "Connection refused. Check the host, port, and that the server is running."
        is java.net.SocketTimeoutException ->
            "Timed out connecting to the server."
        else -> e.message ?: "Connection failed"
    }

    // MARK: - Server persistence

    data class WebDAVServer(
        val id: String,
        val name: String,
        val url: String,
        val username: String,
        val password: String,
        val allowSelfSigned: Boolean = false,
    ) {
        val authorizationHeader: String
            get() {
                val raw = "$username:$password"
                val encoded = Base64.encodeToString(raw.toByteArray(), Base64.NO_WRAP)
                return "Basic $encoded"
            }

        fun toMap(hasPassword: Boolean = password.isNotEmpty()): Map<String, Any?> = mapOf(
            "id" to id,
            "name" to name,
            "url" to url,
            "username" to username,
            "hasPassword" to hasPassword,
            "allowSelfSigned" to allowSelfSigned,
        )
    }

    /// Server metadata (name, URL, username) — not sensitive, plain prefs.
    private fun serverPrefs(): android.content.SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /// Passwords live in an EncryptedSharedPreferences file backed by a
    /// Keystore master key, so app backups / file dumps cannot read them.
    private val secretsPrefs: android.content.SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            SECRETS_PREFS,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /// Reads a password, migrating it from the pre-encryption plaintext prefs
    /// if it was saved there by an older build (then deletes the plaintext).
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
        url: String,
        username: String,
        password: String,
        allowSelfSigned: Boolean,
    ): Map<String, Any?> {
        val serverId = id ?: UUID.randomUUID().toString()
        val server = JSONObject()
            .put("name", name)
            .put("url", url.trim().trimEnd('/'))
            .put("username", username)
            .put("allowSelfSigned", allowSelfSigned)
        serverPrefs().edit().putString(SERVER_KEY + serverId, server.toString()).apply()
        if (password.isNotEmpty()) {
            savePassword(serverId, password)
        } else if (id == null) {
            savePassword(serverId, "")
        }
        return serverById(serverId)?.toMap() ?: emptyMap()
    }

    private fun serverById(id: String): WebDAVServer? {
        val raw = serverPrefs().getString(SERVER_KEY + id, null) ?: return null
        return try {
            val json = JSONObject(raw)
            WebDAVServer(
                id = id,
                name = json.optString("name"),
                url = json.optString("url"),
                username = json.optString("username"),
                password = readPassword(id),
                allowSelfSigned = json.optBoolean("allowSelfSigned", false),
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
        serverPrefs().edit()
            .remove(SERVER_KEY + id)
            .remove(PASSWORD_KEY + id)
            .apply()
        secretsPrefs.edit()
            .remove(PASSWORD_KEY + id)
            .apply()
        // Invalidate any cached listings for this server's URL.
        val serverUrl = serverPrefs().getString(SERVER_KEY + id, null)
        if (serverUrl != null) invalidateListingCache(serverUrl)
    }

    // MARK: - WebDAV protocol

    data class WebDAVEntry(
        val name: String,
        val path: String,
        val isDirectory: Boolean,
        val size: Long,
    )

    /// PROPFIND depth-1 listing. Returns folders first (like the file browser).
    fun listDirectory(
        baseUrl: String,
        username: String,
        password: String,
        path: String,
        allowSelfSigned: Boolean,
    ): List<Map<String, Any?>> {
        val key = cacheKey(baseUrl, path, allowSelfSigned)
        val now = System.currentTimeMillis()
        val cached = listingCache[key]
        if (cached != null && now - cached.fetchedAtMs < listingTtlMs) {
            Log.d(TAG, "listDirectory cache hit: $key")
            return cached.entries
        }
        Log.d(TAG, "listDirectory: baseUrl=$baseUrl path=$path selfSigned=$allowSelfSigned")
        val root = path == "/" || path.isEmpty()
        // Always request slash-terminated directory URLs. Some servers (and
        // reverse proxies in front of them) emit a 301 Location for a missing
        // trailing slash that can be malformed (dropped port/scheme) — sending
        // the slash up front sidesteps the redirect entirely.
        val base = baseUrl.trimEnd('/')
        val requestUrl = if (root) "$base/" else "$base$path".let {
            if (it.endsWith("/")) it else "$it/"
        }
        val xml = propfind(requestUrl, username, password, allowSelfSigned)
        val entries = parseMultistatus(xml, baseUrl)
            .filter { it.path != "/" && it.path != path } // drop self
            .map { e ->
                mapOf(
                    "name" to e.name,
                    "path" to e.path,
                    "isDirectory" to e.isDirectory,
                    "size" to e.size,
                )
            }
            .sortedWith(compareByDescending<Map<String, Any?>> { it["isDirectory"] == true }
                .thenBy { (it["name"] as? String ?: "").lowercase() })
        listingCache[key] = CachedListing(entries, now)
        return entries
    }

    data class TestResult(val ok: Boolean, val error: String?)

    /// Probes a URL with a depth-0 PROPFIND (or GET fallback) to confirm the
    /// Server answers with valid WebDAV credentials.
    fun testConnection(
        url: String,
        username: String,
        password: String,
        allowSelfSigned: Boolean,
    ): TestResult {
        val clean = url.trim().trimEnd('/')
        if (clean.isEmpty()) return TestResult(false, "URL is required")
        // Probe with a trailing slash so directory roots don't 301-redirect
        // through proxies that rewrite Location headers badly.
        val probe = "$clean/"
        return try {
            val status = try {
                val code = propfindCode(probe, username, password, allowSelfSigned)
                // 207 (Multi-Status) is the success code for PROPFIND.
                if (code == 207 || code == 200) null else "HTTP $code"
            } catch (e: java.io.FileNotFoundException) {
                // PROPFIND on a bare host/port with no dav root -> 404; a GET
                // probe distinguishes "server up but no dav here".
                val code = getCode(probe, username, password, allowSelfSigned)
                if (code in 200..399) null else "HTTP $code"
            }
            if (status == null) TestResult(true, null)
            else TestResult(false, status)
        } catch (e: Exception) {
            TestResult(false, friendlyError(e))
        }
    }

    private fun propfindCode(
        url: String,
        username: String,
        password: String,
        allowSelfSigned: Boolean,
        depth: Int = 0,
    ): Int = newCall(url, username, password, method = "PROPFIND", depth = depth, allowSelfSigned = allowSelfSigned)
        .execute().use { it.code }

    private fun getCode(
        url: String,
        username: String,
        password: String,
        allowSelfSigned: Boolean,
    ): Int = newCall(url, username, password, method = "GET", allowSelfSigned = allowSelfSigned)
        .execute().use { it.code }

    /// GETs [url] (with the given [headers] / TLS policy) and returns the body
    /// bytes on HTTP 200, capped at [MAX_SUB_BYTES]; returns null on any other
    /// status (404/403/5xx) or read limit, so callers can treat a miss as "not
    /// a subtitle URL". Never throws for non-200 responses (auth/404 should be
    /// ordinary "not found", not a failure that aborts sidecar discovery).
    fun fetchUrl(
        url: String,
        headers: Map<String, String>,
        selfSigned: Boolean,
    ): ByteArray? {
        // Best-effort by contract (it probes/downloads sidecar subtitles, never
        // plays or tests a user-visible connection): any network failure —
        // timeout, refused, unknown host, TLS — returns null so the caller
        // falls back to "no subtitle data" instead of aborting playback with a
        // PlatformException("webdav", ...). A dead/slow server must never take
        // a Jellyfin video down with it.
        return try {
            val builder = Request.Builder()
                .url(url)
                .get()
                .apply {
                    headers.forEach { (k, v) -> header(k, v) }
                }
            val target = if (selfSigned) permissiveClient else client
            target.newCall(builder.build())
                .execute()
                .use { response ->
                    val code = response.code
                    if (code != 200) {
                        Log.d(TAG, "fetchUrl $url -> $code")
                        return null
                    }
                    val body = response.body
                        ?: return null
                    val bytes = try {
                        body.byteStream().use { input ->
                            val out = java.io.ByteArrayOutputStream()
                            val buf = ByteArray(16 * 1024)
                            var total = 0
                            while (true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                total += n
                                if (total > MAX_SUB_BYTES) {
                                    Log.w(TAG, "fetchUrl too large $total bytes")
                                    return null
                                }
                                out.write(buf, 0, n)
                            }
                            out.toByteArray()
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "fetchUrl read failed $e")
                        return null
                    }
                    bytes
                }
        } catch (e: Exception) {
            Log.w(TAG, "fetchUrl network failed $e")
            null
        }
    }

    private fun newCall(
        url: String,
        username: String,
        password: String,
        method: String,
        allowSelfSigned: Boolean,
        depth: Int = 1,
        body: String? = null,
    ): okhttp3.Call {
        val builder = Request.Builder()
            .url(url)
            .method(method, body?.toRequestBody("application/xml".toMediaType()))
            .apply {
                if (username.isNotEmpty() || password.isNotEmpty()) {
                    header("Authorization", Credentials.basic(username, password))
                }
                if (method == "PROPFIND") {
                    header("Depth", depth.toString())
                }
            }
        val target = if (allowSelfSigned) permissiveClient else client
        return target.newCall(builder.build())
    }

    private fun propfind(
        url: String,
        username: String,
        password: String,
        allowSelfSigned: Boolean,
    ): String {
        Log.d(TAG, "PROPFIND $url user=${username.ifEmpty { "<none>" }} selfSigned=$allowSelfSigned")
        val response = newCall(url, username, password, method = "PROPFIND", depth = 1, allowSelfSigned = allowSelfSigned)
            .execute()
        return try {
            val code = response.code
            Log.d(TAG, "PROPFIND $url -> $code")
            if (code != 207 && code != 200) {
                throw RuntimeException("HTTP $code")
            }
            response.body?.string() ?: ""
        } finally {
            response.close()
        }
    }

    /// Parses a `multistatus` (207) XML body into [WebDAVEntry]s. `baseUrl` is
    /// the server root; hrefs are normalized to paths relative to it.
    private fun parseMultistatus(xml: String, baseUrl: String): List<WebDAVEntry> {
        val base = baseUrl.trimEnd('/')
        val basePath = URL(base).path.trimEnd('/')
        val entries = mutableListOf<WebDAVEntry>()
        val parser = Xml.newPullParser()
        parser.setInput(xml.reader())
        var event = parser.eventType
        var href: String? = null
        var isCollection = false
        var contentLength = 0L
        var inResponse = false
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> {
                    when (parser.name) {
                        "response" -> {
                            inResponse = true
                            href = null
                            isCollection = false
                            contentLength = 0L
                        }
                        "href" -> href = parser.nextText()
                        "collection" -> isCollection = true
                        "getcontentlength" -> {
                            contentLength = parser.nextText().toLongOrNull() ?: 0L
                        }
                    }
                }
                XmlPullParser.END_TAG -> {
                    if (parser.name == "response" && inResponse) {
                        inResponse = false
                        val entry = entryFromHref(href, basePath, isCollection, contentLength)
                        if (entry != null) entries.add(entry)
                    }
                }
            }
            event = parser.next()
        }
        return entries
    }

    private fun entryFromHref(
        href: String?,
        basePath: String,
        isCollection: Boolean,
        contentLength: Long,
    ): WebDAVEntry? {
        if (href == null) return null
        val rawPath = try {
            URL(href).path
        } catch (_: Exception) {
            href.split('?').first()
        }
        // Decode only %xx escapes. (URLDecoder.decode would also turn a literal
        // `+` into a space, mangling filenames like "224kbps + English".)
        val decodedPath = try {
            Uri.decode(rawPath)
        } catch (_: Exception) {
            rawPath
        }
        // Normalize the path relative to the server base path.
        val relative = if (basePath.isEmpty()) {
            decodedPath
        } else if (decodedPath.startsWith(basePath)) {
            decodedPath.removePrefix(basePath)
        } else {
            decodedPath
        }.let { if (it.isEmpty()) "/" else it }
        val name = decodedPath.trimEnd('/').substringAfterLast('/')
        val isVideo = !isCollection && VIDEO_EXTENSIONS.contains(
            name.substringAfterLast('.', "").lowercase(),
        )
        if (!isCollection && !isVideo) return null
        return WebDAVEntry(
            name = name,
            path = relative,
            isDirectory = isCollection,
            size = contentLength,
        )
    }
}
