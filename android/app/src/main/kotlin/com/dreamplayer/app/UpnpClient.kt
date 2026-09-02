package com.dreamplayer.app

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Xml
import io.flutter.plugin.common.MethodChannel
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.xmlpull.v1.XmlPullParser
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.net.URL
import java.util.concurrent.TimeUnit

/// DLNA / UPnP ContentDirectory browsing (channel `dreamplayer/upnp`).
///
/// Discovery is SSDP M-SEARCH to 239.255.255.250:1900; browsing is SOAP
/// ContentDirectory#Browse (BrowseDirectChildren) against the device's
/// controlURL. HTTP is plain OkHttp — DLNA servers are LAN http.
class UpnpClient(private val context: Context) {

    companion object {
        const val CHANNEL = "dreamplayer/upnp"
        private const val TAG = "UpnpClient"
        private const val SSDP_ADDR = "239.255.255.250"
        private const val SSDP_PORT = 1900
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private var multicastLock: WifiManager.MulticastLock? = null

    // Cache from last discover so browse can resolve controlURL without
    // re-discovering. Keyed by UDN / id.
    private val serverCache = mutableMapOf<String, UpnpServer>()

    /// Directory-listing cache: re-visiting a folder is instant.
    /// Key = "$serverId|$objectId", value = (entries, fetchedAtMs).
    /// TTL 60 s. DLNA Browse is one SOAP POST + DIDL-Lite XML parse — caching
    /// avoids re-serializing the same SOAP envelope + re-hitting the server.
    private data class CachedListing(
        val entries: List<Map<String, Any?>>,
        val fetchedAtMs: Long,
    )
    private val listingCache = java.util.concurrent.ConcurrentHashMap<String, CachedListing>()
    private val listingTtlMs = 60_000L

    fun invalidateListingCache(serverId: String? = null) {
        if (serverId == null) {
            listingCache.clear()
        } else {
            val prefix = "$serverId|"
            listingCache.keys.removeAll { it.startsWith(prefix) }
        }
    }

    data class UpnpServer(
        val id: String,
        val name: String,
        val location: String,
        val controlUrl: String,
        val baseUrl: String,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "id" to id,
            "name" to name,
            "location" to location,
            "controlUrl" to controlUrl,
            "baseUrl" to baseUrl,
        )
    }

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "discover" -> {
                    Thread {
                        try {
                            val servers = discover()
                            mainHandler.post { result.success(servers) }
                        } catch (e: Exception) {
                            Log.e(TAG, "discover failed: $e")
                            mainHandler.post { result.error("upnp", e.message ?: "Discovery failed", null) }
                        }
                    }.start()
                }
                "browse" -> {
                    val serverId = call.argument<String>("serverId") ?: ""
                    val objectId = call.argument<String>("objectId") ?: "0"
                    Thread {
                        try {
                            val entries = browse(serverId, objectId)
                            mainHandler.post { result.success(entries) }
                        } catch (e: Exception) {
                            Log.e(TAG, "browse $serverId/$objectId failed: $e")
                            mainHandler.post { result.error("upnp", e.message ?: "Browse failed", null) }
                        }
                    }.start()
                }
                "invalidateListingCache" -> {
                    call.argument<String>("serverId")?.let { invalidateListingCache(it) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // MARK: - Discovery (SSDP)

    private fun discover(): List<Map<String, Any?>> {
        acquireLock()
        val found = mutableMapOf<String, UpnpServer>()
        var socket: DatagramSocket? = null
        try {
            socket = DatagramSocket()
            socket.soTimeout = 3500
            socket.broadcast = true
            socket.reuseAddress = true

            val st = "urn:schemas-upnp-org:device:MediaServer:1"
            val msg = (
                "M-SEARCH * HTTP/1.1\r\n" +
                    "HOST: $SSDP_ADDR:$SSDP_PORT\r\n" +
                    "MAN: \"ssdp:discover\"\r\n" +
                    "MX: 3\r\n" +
                    "ST: $st\r\n" +
                    // Also try generic to catch more devices; some servers only answer to ssdp:all.
                    "USER-AGENT: DreamPlayer/1.0 UPnP/1.0\r\n\r\n"
                ).toByteArray(Charsets.UTF_8)
            val pkt = DatagramPacket(msg, msg.size, InetAddress.getByName(SSDP_ADDR), SSDP_PORT)
            // Send twice (common DLNA practice — cheap and helps lossy Wi-Fi).
            repeat(2) {
                try { socket.send(pkt) } catch (_: Exception) {}
            }
            Log.d(TAG, "SSDP M-SEARCH sent for $st")

            val deadline = System.currentTimeMillis() + 4000
            val locations = linkedSetOf<String>()
            while (System.currentTimeMillis() < deadline) {
                val buf = ByteArray(8192)
                val p = DatagramPacket(buf, buf.size)
                try {
                    socket.receive(p)
                } catch (_: SocketTimeoutException) {
                    break
                }
                val resp = String(p.data, p.offset, p.length, Charsets.UTF_8)
                val loc = headerValue(resp, "LOCATION") ?: headerValue(resp, "Location") ?: continue
                val trimmed = loc.trim()
                if (trimmed.isNotEmpty()) locations.add(trimmed)
            }
            Log.d(TAG, "SSDP found ${locations.size} location(s): $locations")
            for (loc in locations) {
                try {
                    val srv = fetchDeviceInfo(loc) ?: continue
                    if (srv.controlUrl.isEmpty()) {
                        Log.w(TAG, "No ContentDirectory for $loc")
                        continue
                    }
                    found[srv.id] = srv
                    Log.d(TAG, "DLNA server: ${srv.name} (${srv.id}) -> ${srv.controlUrl}")
                } catch (e: Exception) {
                    Log.w(TAG, "fetchDeviceInfo $loc failed: $e")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "SSDP discover error: $e")
        } finally {
            try { socket?.close() } catch (_: Exception) {}
            releaseLock()
        }
        // Cache for browse
        serverCache.clear()
        serverCache.putAll(found)
        return found.values.map { it.toMap() }
    }

    private fun headerValue(resp: String, name: String): String? {
        val lines = resp.split("\r\n")
        for (line in lines) {
            val idx = line.indexOf(':')
            if (idx <= 0) continue
            val k = line.substring(0, idx).trim()
            if (k.equals(name, ignoreCase = true)) {
                return line.substring(idx + 1).trim()
            }
        }
        return null
    }

    private fun fetchDeviceInfo(location: String): UpnpServer? {
        val req = Request.Builder().url(location).get().build()
        val xml = client.newCall(req).execute().use {
            if (!it.isSuccessful) throw RuntimeException("HTTP ${it.code}")
            it.body?.string() ?: ""
        }
        if (xml.isEmpty()) return null
        // Base URL for relative controlURLs: scheme://host:port
        val baseUrl = try {
            val u = URL(location)
            "${u.protocol}://${u.host}${if (u.port != -1) ":${u.port}" else ""}"
        } catch (_: Exception) {
            location.substringBefore("/",)
        }

        var friendlyName = ""
        var udn = ""
        var controlUrl: String? = null
        var pendingServiceType: String? = null
        var pendingControlUrl: String? = null
        var inDevice = false

        val parser = Xml.newPullParser()
        parser.setInput(xml.reader())
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> {
                    when (parser.name) {
                        "device" -> inDevice = true
                        "friendlyName" -> if (inDevice && friendlyName.isEmpty()) friendlyName = parser.nextText().trim()
                        "UDN" -> if (inDevice && udn.isEmpty()) udn = parser.nextText().trim()
                        "serviceType" -> pendingServiceType = parser.nextText().trim()
                        "controlURL" -> pendingControlUrl = parser.nextText().trim()
                    }
                }
                XmlPullParser.END_TAG -> {
                    if (parser.name == "service") {
                        if (pendingServiceType != null && pendingServiceType!!.contains("ContentDirectory")) {
                            controlUrl = pendingControlUrl
                        }
                        pendingServiceType = null
                        pendingControlUrl = null
                    }
                    if (parser.name == "device" && controlUrl != null) {
                        // Don't break — continue parsing in case there are multiple devices.
                    }
                }
            }
            event = parser.next()
        }
        if (controlUrl == null) return null
        val resolvedControl = resolveUrl(baseUrl, controlUrl!!)
        val id = udn.ifEmpty { location }
        val name = friendlyName.ifEmpty { try { URL(location).host } catch (_: Exception) { location } }
        return UpnpServer(id = id, name = name, location = location, controlUrl = resolvedControl, baseUrl = baseUrl)
    }

    private fun resolveUrl(base: String, url: String): String {
        if (url.startsWith("http://") || url.startsWith("https://")) return url
        if (url.startsWith("/")) return base.trimEnd('/') + url
        return base.trimEnd('/') + "/" + url
    }

    // MARK: - Browse (SOAP)

    fun browse(serverId: String, objectId: String): List<Map<String, Any?>> {
        val key = "$serverId|${objectId.replace(Regex("/+"), "/").trim('/')}"
        val now = System.currentTimeMillis()
        val cached = listingCache[key]
        if (cached != null && now - cached.fetchedAtMs < listingTtlMs) {
            Log.d(TAG, "browse cache hit: $key")
            return cached.entries
        }
        val server = serverCache[serverId] ?: run {
            // Try to re-discover lazily if cache was cleared (e.g. app restart).
            // Caller should have called discover first; fail fast otherwise.
            throw RuntimeException("DLNA server not found. Discover again.")
        }
        val soap = (
            "<?xml version=\"1.0\"?>" +
                "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" +
                "<s:Body>" +
                "<u:Browse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\">" +
                "<ObjectID>$objectId</ObjectID>" +
                "<BrowseFlag>BrowseDirectChildren</BrowseFlag>" +
                "<Filter>*</Filter>" +
                "<StartingIndex>0</StartingIndex>" +
                "<RequestedCount>0</RequestedCount>" +
                "<SortCriteria></SortCriteria>" +
                "</u:Browse>" +
                "</s:Body>" +
                "</s:Envelope>"
            )
        val req = Request.Builder()
            .url(server.controlUrl)
            .header("Content-Type", "text/xml; charset=\"utf-8\"")
            .header("SOAPAction", "\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"")
            .post(soap.toRequestBody("text/xml; charset=utf-8".toMediaType()))
            .build()
        val body = client.newCall(req).execute().use {
            if (!it.isSuccessful) throw RuntimeException("Browse HTTP ${it.code}")
            it.body?.string() ?: ""
        }
        val result = parseBrowseResult(body)
        listingCache[key] = CachedListing(result, now)
        return result
    }

    private fun parseBrowseResult(soapXml: String): List<Map<String, Any?>> {
        // Pull <Result> which holds the escaped DIDL-Lite.
        var didl = ""
        try {
            val p = Xml.newPullParser()
            p.setInput(soapXml.reader())
            var ev = p.eventType
            while (ev != XmlPullParser.END_DOCUMENT) {
                if (ev == XmlPullParser.START_TAG && p.name == "Result") {
                    didl = p.nextText() ?: ""
                    break
                }
                ev = p.next()
            }
        } catch (e: Exception) {
            Log.w(TAG, "parseBrowseResult SOAP parse failed: $e")
        }
        if (didl.isEmpty()) return emptyList()
        return parseDidl(didl)
    }

    private fun parseDidl(didl: String): List<Map<String, Any?>> {
        val entries = mutableListOf<Map<String, Any?>>()
        try {
            val parser = Xml.newPullParser()
            // DIDL uses dc:/upnp: namespaces — need localName handling.
            parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
            parser.setInput(didl.reader())
            var event = parser.eventType
            var currentId: String? = null
            var currentIsContainer = false
            var currentTitle: String? = null
            var currentRes: String? = null
            var currentResSize = 0L
            var currentResDuration: String? = null
            var currentProtocolInfo: String? = null
            var currentResIsVideo = false
            var currentClass: String? = null
            // Non-video res entries advertised alongside the video (Jellyfin
            // lists one per external subtitle: text/srt, text/ass DeliveryUrls).
            val currentExtraSubs = ArrayList<Map<String, String>>()
            var inContainer = false
            var inItem = false

            fun flushCurrent() {
                if (currentId == null) return
                if (inContainer || currentIsContainer) {
                    // Container: treat as directory.
                    val name = currentTitle ?: currentId!!
                    entries.add(mapOf("name" to name, "id" to currentId!!, "isDirectory" to true, "url" to null, "size" to 0L))
                } else if (inItem) {
                    val url = currentRes ?: return
                    // Filter to video-like items (keep all video containers' children).
                    val isVideo = isVideoCandidate(currentProtocolInfo, url, currentClass)
                    if (!isVideo) return
                    entries.add(
                        mapOf(
                            "name" to (currentTitle ?: url.substringAfterLast('/').substringBefore('?')),
                            "id" to currentId!!,
                            "isDirectory" to false,
                            "url" to url,
                            "size" to currentResSize,
                            "duration" to currentResDuration,
                            // DLNA.ORG_CI=1 → the server will TRANSCODE this item
                            // on demand (e.g. Jellyfin downgrades items with
                            // external subtitles to a lossy H.264 TS stream).
                            "transcoded" to (currentProtocolInfo?.contains("DLNA.ORG_CI=1", ignoreCase = true) == true),
                            // Server-advertised external subtitles → attachable tracks.
                            "externalSubs" to currentExtraSubs.filter { it["url"] != url },
                        ),
                    )
                }
            }

            while (event != XmlPullParser.END_DOCUMENT) {
                when (event) {
                    XmlPullParser.START_TAG -> {
                        val local = parser.name // localName when namespaces on; fallback name
                        when (local) {
                            "container" -> {
                                flushCurrent() // safety if nested incorrectly
                                inContainer = true; inItem = false
                                currentIsContainer = true
                                currentId = parser.getAttributeValue(null, "id") ?: parser.getAttributeValue("", "id")
                                currentTitle = null; currentRes = null; currentClass = null
                            }
                            "item" -> {
                                flushCurrent()
                                inItem = true; inContainer = false
                                currentIsContainer = false
                                currentId = parser.getAttributeValue(null, "id") ?: parser.getAttributeValue("", "id")
                                currentTitle = null; currentRes = null; currentClass = null; currentResSize = 0L
                                currentResIsVideo = false
                                currentExtraSubs.clear()
                            }
                            "title" -> {
                                // dc:title
                                val t = parser.nextText().trim()
                                if (t.isNotEmpty()) currentTitle = t
                            }
                            "class" -> {
                                currentClass = parser.nextText().trim()
                            }
                            "res" -> {
                                val protoInfo = parser.getAttributeValue(null, "protocolInfo")
                                val sz = parser.getAttributeValue(null, "size")?.toLongOrNull()
                                val dur = parser.getAttributeValue(null, "duration")
                                val url = parser.nextText().trim()
                                if (url.isNotEmpty()) {
                                    // Servers like Jellyfin advertise MULTIPLE res elements per
                                    // item — one for the video plus one per external subtitle
                                    // (DeliveryUrl …/Subtitles/N/0/Stream.srt). Taking the last
                                    // one handed the player an .srt as the main media. Keep the
                                    // VIDEO res; fall back to the first-seen res otherwise.
                                    val isVideoRes = protoInfo?.lowercase()?.contains("video/") == true
                                    if (currentRes == null || (isVideoRes && !currentResIsVideo)) {
                                        currentRes = url
                                        currentProtocolInfo = protoInfo
                                        if (sz != null) currentResSize = sz
                                        currentResDuration = dur
                                        currentResIsVideo = isVideoRes
                                    } else if (!isVideoRes) {
                                        // A text/* subtitle advertised next to the video —
                                        // collect it as an attachable track.
                                        val mime = protoInfo?.split(":")?.getOrNull(2)?.takeIf { it.isNotEmpty() && it != "*" }
                                        currentExtraSubs.add(mapOf("url" to url, "mime" to (mime ?: "application/x-subrip")))
                                    }
                                }
                            }
                        }
                    }
                    XmlPullParser.END_TAG -> {
                        val local = parser.name
                        if (local == "container" || local == "item") {
                            flushCurrent()
                            inContainer = false; inItem = false
                            currentId = null; currentTitle = null; currentRes = null; currentClass = null
                            currentExtraSubs.clear()
                        }
                    }
                }
                event = parser.next()
            }
        } catch (e: Exception) {
            Log.w(TAG, "parseDidl failed: $e\n$didl")
        }
        // Sort: folders first, then files alphabetically (matches WebDAV/FileBrowser).
        return entries.sortedWith(compareByDescending<Map<String, Any?>> { it["isDirectory"] == true }.thenBy { (it["name"] as? String ?: "").lowercase() })
    }

    private fun isVideoCandidate(protocolInfo: String?, url: String, upnpClass: String?): Boolean {
        val pi = protocolInfo?.lowercase() ?: ""
        if (pi.contains("video")) return true
        // Some servers report object.item.videoItem.* appropriately.
        if (upnpClass?.lowercase()?.contains("videoitem") == true) return true
        if (upnpClass?.lowercase()?.contains("movie") == true) return true
        if (pi.contains("audio") || pi.contains("image")) return false
        val videoExts = setOf("mkv", "mp4", "avi", "mov", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg", "webm", "m4v", "3gp", "divx", "vob")
        val ext = url.substringAfterLast('.', "").substringBefore('?').lowercase()
        if (videoExts.contains(ext)) return true
        // Unknown — keep it rather than hide a video with a weird MIME.
        // Only hide obvious non-video.
        if (pi.isNotEmpty() && !pi.contains("video")) return false
        return true
    }

    private fun acquireLock() {
        if (multicastLock != null) return
        try {
            val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wm.createMulticastLock("dreamplayer:upnp").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {}
    }

    private fun releaseLock() {
        try { multicastLock?.release() } catch (_: Exception) {}
        multicastLock = null
    }
}
