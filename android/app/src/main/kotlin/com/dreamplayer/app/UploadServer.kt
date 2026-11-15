package com.dreamplayer.app

import android.content.Context
import android.os.Environment
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import kotlin.concurrent.thread

/**
 * WiFi upload server (competitor-gap #1): a tiny HTTP/1.1 server bound to
 * 0.0.0.0 on a LAN port, serving an upload page so a PC browser can push
 * videos straight into the phone. Uploaded files land in the app's download
 * directory, so the home "Downloaded" grid picks them up like any download.
 *
 * Android ships no `com.sun.net.httpserver`, so this is a hand-rolled server
 * in the same shape as [SmbHttpProxy]: a daemon `ServerSocket` accept loop +
 * one daemon thread per connection, every connection closed after its
 * response.
 *
 * HTTP contract (deliberately NOT multipart — a raw body with the file name
 * in the query is far simpler to stream correctly on both platforms):
 *   GET  /u/<token>/           → the upload page (HTML)
 *   GET  /u/<token>/health     → JSON status
 *   POST /u/<token>/upload?name=<urlencoded>  → raw body (Content-Length
 *                                required; 411 otherwise) streamed to a file
 *
 * Security model: a fresh 128-bit random token per start, in the path. Anyone
 * on the LAN who can guess the token can upload — acceptable for a home-LAN
 * feature, and the server only runs while the user enabled it.
 */
class UploadServer(private val context: Context) {

    companion object {
        const val CHANNEL = "dreamplayer/upload"
        private const val TAG = "UploadServer"
        private const val HEADER_CAP = 64 * 1024
        private const val IO_CHUNK = 256 * 1024
        private const val HEADER_TIMEOUT_MS = 30_000
        private const val MAX_NAME_LEN = 120
    }

    private var server: ServerSocket? = null
    @Volatile private var running = false
    @Volatile private var port = -1
    @Volatile private var token = ""
    @Volatile private var destDir: File? = null
    @Volatile private var receivedCount = 0
    @Volatile private var receivedBytes = 0L

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val port = (call.argument<Int>("port")) ?: 8080
                    val dest = call.argument<String>("destDir")
                    result.success(start(port, dest))
                }
                "stop" -> { stop(); result.success(null) }
                "status" -> result.success(statusMap())
                else -> result.notImplemented()
            }
        }
    }

    @Synchronized
    private fun start(requestedPort: Int, destDirPath: String?): Map<String, Any?> {
        stop()
        val dest = File(
            destDirPath?.takeIf { it.isNotBlank() }
                ?: File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    "DreamPlayer",
                ).absolutePath,
        )
        if (!dest.exists() && !dest.mkdirs()) {
            return mapOf("ok" to false, "error" to "cannot create ${dest.absolutePath}")
        }
        this.destDir = dest
        val rng = SecureRandom()
        val bytes = ByteArray(16)
        rng.nextBytes(bytes)
        token = bytes.joinToString("") { "%02x".format(it) }

        // Try the requested port, then +1..+9, then an ephemeral port.
        var ss: ServerSocket? = null
        var boundPort = requestedPort
        for (offset in 0..10) {
            val candidate = if (offset == 10) 0 else requestedPort + offset
            try {
                val s = ServerSocket()
                s.reuseAddress = true
                s.bind(InetSocketAddress("0.0.0.0", candidate), 16)
                ss = s
                boundPort = s.localPort
                break
            } catch (_: IOException) {
                // port busy — try the next
            }
        }
        if (ss == null) {
            return mapOf("ok" to false, "error" to "no free port near $requestedPort")
        }
        server = ss
        port = boundPort
        running = true
        receivedCount = 0
        receivedBytes = 0L
        val sock = ss
        thread(isDaemon = true, name = "wifi-upload-accept") {
            while (running) {
                try {
                    val conn = sock.accept()
                    thread(isDaemon = true, name = "wifi-upload-conn") { serve(conn) }
                } catch (_: IOException) {
                    break
                }
            }
        }
        val urls = lanAddresses().map { "http://$it:$boundPort/u/$token/" }
        Log.i(TAG, "upload server on port $boundPort -> $urls (dest=${dest.absolutePath})")
        return mapOf(
            "ok" to true,
            "port" to boundPort,
            "token" to token,
            "addresses" to lanAddresses(),
            "destDir" to dest.absolutePath,
        )
    }

    @Synchronized
    private fun stop() {
        running = false
        try { server?.close() } catch (_: IOException) {}
        server = null
        port = -1
    }

    private fun statusMap(): Map<String, Any?> = mapOf(
        "running" to running,
        "port" to port,
        "token" to token,
        "addresses" to lanAddresses(),
        "destDir" to (destDir?.absolutePath ?: ""),
        "receivedCount" to receivedCount,
        "receivedBytes" to receivedBytes,
    )

    // ------------------------------------------------------------ HTTP ----

    private fun serve(sock: Socket) {
        try {
            sock.soTimeout = HEADER_TIMEOUT_MS
            val input = sock.getInputStream()
            val head = readHead(input)
            if (head == null) { sock.close(); return }
            val text = String(head, StandardCharsets.ISO_8859_1)
            val requestLine = text.substringBefore("\r\n")
            val parts = requestLine.split(" ")
            if (parts.size < 2) { respond(sock, 400, "text/plain", "bad request".toByteArray()); sock.close(); return }
            val method = parts[0]
            val rawPath = parts[1]
            val headers = parseHeaders(text)
            val path = rawPath.substringBefore('?')
            val query = rawPath.substringAfter('?', "")

            val t = token
            when {
                path == "/u/$t" || path == "/u/$t/" -> {
                    if (method != "GET") { respond(sock, 405, "text/plain", "method".toByteArray()); sock.close(); return }
                    val page = pageHtml().toByteArray(StandardCharsets.UTF_8)
                    respond(sock, 200, "text/html; charset=utf-8", page, extraHeaders = listOf("Cache-Control: no-store"))
                }
                path == "/u/$t/health" -> {
                    val body = statusMap().let {
                        org.json.JSONObject(it.filterValues { v -> v != null }).toString()
                    }.toByteArray(StandardCharsets.UTF_8)
                    respond(sock, 200, "application/json", body)
                }
                path == "/u/$t/upload" -> {
                    if (method != "POST") { respond(sock, 405, "text/plain", "method".toByteArray()); sock.close(); return }
                    val length = headers["content-length"]?.toLongOrNull()
                    if (length == null || length < 0) {
                        respond(sock, 411, "text/plain", "Content-Length required".toByteArray())
                        sock.close(); return
                    }
                    val nameParam = query.split('&')
                        .firstOrNull { it.startsWith("name=") }
                        ?.substringAfter('=')
                    val rawName = nameParam?.let {
                        java.net.URLDecoder.decode(it, StandardCharsets.UTF_8.name())
                    } ?: "upload.bin"
                    val saved = saveUpload(input, length, rawName)
                    if (saved == null) {
                        respond(sock, 500, "application/json", """{"ok":false}""".toByteArray())
                    } else {
                        receivedCount++
                        receivedBytes += length
                        val body = """{"ok":true,"saved":"${saved.first}","size":$length}"""
                            .toByteArray(StandardCharsets.UTF_8)
                        respond(sock, 200, "application/json", body)
                    }
                }
                else -> respond(sock, 404, "text/plain", "not found".toByteArray())
            }
        } catch (e: Exception) {
            Log.w(TAG, "connection error: $e")
        } finally {
            try { sock.close() } catch (_: IOException) {}
        }
    }

    /// Reads until CRLFCRLF (cap HEADER_CAP). Returns null on timeout/overflow.
    private fun readHead(input: InputStream): ByteArray? {
        val buf = ByteArray(HEADER_CAP)
        var len = 0
        while (len < HEADER_CAP) {
            val n = try { input.read(buf, len, HEADER_CAP - len) } catch (_: IOException) { return null }
            if (n < 0) return null
            len += n
            // scan for \r\n\r\n
            var i = 0
            while (i + 3 < len) {
                if (buf[i] == 13.toByte() && buf[i + 1] == 10.toByte() &&
                    buf[i + 2] == 13.toByte() && buf[i + 3] == 10.toByte()) {
                    return buf.copyOf(i + 4)
                }
                i++
            }
        }
        return null
    }

    private fun parseHeaders(head: String): Map<String, String> {
        val map = HashMap<String, String>()
        for (line in head.split("\r\n").drop(1)) {
            val idx = line.indexOf(':')
            if (idx > 0) map[line.substring(0, idx).trim().lowercase()] =
                line.substring(idx + 1).trim()
        }
        return map
    }

    private fun respond(
        sock: Socket,
        code: Int,
        contentType: String,
        body: ByteArray,
        extraHeaders: List<String> = emptyList(),
    ) {
        val reason = when (code) {
            200 -> "OK"; 400 -> "Bad Request"; 404 -> "Not Found"
            405 -> "Method Not Allowed"; 411 -> "Length Required"; 500 -> "Server Error"
            else -> "OK"
        }
        val head = buildString {
            append("HTTP/1.1 $code $reason\r\n")
            append("Content-Type: $contentType\r\n")
            append("Content-Length: ${body.size}\r\n")
            append("Connection: close\r\n")
            for (h in extraHeaders) append("$h\r\n")
            append("\r\n")
        }.toByteArray(StandardCharsets.ISO_8859_1)
        val out = sock.getOutputStream()
        out.write(head)
        out.write(body)
        out.flush()
    }

    /// Streams [length] bytes of [input] into a sanitized, deduped file in the
    /// destination directory. Returns (savedName, file) or null on failure.
    private fun saveUpload(input: InputStream, length: Long, rawName: String): Pair<String, File>? {
        val dest = destDir ?: return null
        val name = sanitizeName(rawName)
        val existing = dest.listFiles()?.map { it.name }?.toHashSet() ?: hashSetOf()
        val finalName = dedupe(name, existing)
        val file = File(dest, finalName)
        try {
            FileOutputStream(file).use { out ->
                val buf = ByteArray(IO_CHUNK)
                var remaining = length
                while (remaining > 0) {
                    val n = input.read(buf, 0, minOf(IO_CHUNK.toLong(), remaining).toInt())
                    if (n < 0) throw IOException("client closed early")
                    out.write(buf, 0, n)
                    remaining -= n
                }
            }
            Log.i(TAG, "received $finalName ($length bytes)")
            return finalName to file
        } catch (e: Exception) {
            Log.w(TAG, "upload failed: $e")
            file.delete()
            return null
        }
    }

    // --------------------------------------------------------- helpers ----

    private fun sanitizeName(raw: String): String {
        var name = raw
        val cut = maxOf(name.lastIndexOf('/'), name.lastIndexOf('\\'))
        if (cut >= 0) name = name.substring(cut + 1)
        name = name.replace(Regex("[\\x00-\\x1f\\x7f]"), "").trim()
        if (name.isEmpty() || name == "." || name == "..") return "upload.bin"
        val base = name.split('.').first().uppercase()
        if (base in setOf("CON", "PRN", "AUX", "NUL") ||
            Regex("^COM[1-9]$").matches(base) || Regex("^LPT[1-9]$").matches(base)) {
            name = "_$name"
        }
        if (name.length > MAX_NAME_LEN) {
            val dot = name.lastIndexOf('.')
            val ext = if (dot > 0 && name.length - dot <= 9) name.substring(dot) else ""
            name = name.substring(0, MAX_NAME_LEN - ext.length) + ext
        }
        return name
    }

    private fun dedupe(name: String, existing: Set<String>): String {
        if (name !in existing) return name
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (i in 2..9999) {
            val candidate = "$stem ($i)$ext"
            if (candidate !in existing) return candidate
        }
        return "$stem (${System.currentTimeMillis()})$ext"
    }

    private fun lanAddresses(): List<String> {
        val out = mutableListOf<String>()
        try {
            val ifs = NetworkInterface.getNetworkInterfaces() ?: return out
            for (ifn in ifs) {
                if (!ifn.isUp || ifn.isLoopback) continue
                for (addr in ifn.inetAddresses) {
                    if (addr is Inet4Address && addr.isSiteLocalAddress) {
                        addr.hostAddress?.let { out.add(it) }
                    }
                }
            }
        } catch (_: Exception) {
        }
        return out.distinct()
    }

    // ------------------------------------------------------------- page ---

    private fun pageHtml(): String {
        val t = token
        val port = port
        return """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DreamPlayer — WiFi upload</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
         background: #0e0e11; color: #e8e8ec; font-family: system-ui, sans-serif; }
  main { width: min(560px, 92vw); padding: 24px; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  p.sub { color: #9a9aa5; margin: 0 0 20px; font-size: 14px; word-break: break-all; }
  .drop { border: 2px dashed #4b3e76; border-radius: 14px; padding: 36px 20px; text-align: center;
          cursor: pointer; transition: border-color .15s; }
  .drop:hover, .drop.over { border-color: #7c4dff; }
  .drop .big { font-size: 40px; }
  .drop .hint { color: #9a9aa5; font-size: 13px; margin-top: 8px; }
  input[type=file] { display: none; }
  ul { list-style: none; padding: 0; margin: 18px 0 0; }
  li { padding: 8px 10px; border-radius: 8px; background: #17171d; margin-bottom: 8px; font-size: 13px; }
  li .bar { height: 6px; border-radius: 3px; background: #26262e; margin-top: 6px; overflow: hidden; }
  li .bar > div { height: 100%; width: 0%; background: #7c4dff; }
  li.done { color: #7ee2a8; }
  li.err { color: #ff8a80; }
  .foot { color: #6a6a75; font-size: 12px; margin-top: 18px; }
</style>
</head>
<body>
<main>
  <h1>DreamPlayer WiFi upload</h1>
  <p class="sub">This device: <b>http://LOCALHOST:$port/u/$t/</b> — send files to this phone.</p>
  <label class="drop" id="drop">
    <div class="big">⬆️</div>
    <div>Click to choose videos, or drop them here</div>
    <div class="hint">They are saved to this device's download folder and appear in DreamPlayer automatically.</div>
    <input type="file" id="files" multiple accept="video/*,.mkv,.mp4,.avi,.ts,.m2ts,.webm,.wmv,.flv,.mpg,.mpeg,.vob,.mov,.m4v,.3gp,.ogv,.rmvb,.divx">
  </label>
  <ul id="list"></ul>
  <p class="foot">Only reachable while this screen's server is running. Token-protected; do not share the link.</p>
</main>
<script>
(function () {
  var drop = document.getElementById('drop');
  var input = document.getElementById('files');
  var list = document.getElementById('list');
  // Show the real LAN address(es) the phone is reachable on.
  fetch('/u/$t/health').then(function (r) { return r.json(); }).then(function (s) {
    if (s.addresses && s.addresses.length) {
      document.querySelector('p.sub b').textContent =
        'http://' + s.addresses[0] + ':' + s.port + '/u/$t/';
    }
  }).catch(function () {});

  function prevent(e) { e.preventDefault(); e.stopPropagation(); }
  ['dragenter', 'dragover'].forEach(function (ev) {
    drop.addEventListener(ev, function (e) { prevent(e); drop.classList.add('over'); });
  });
  ['dragleave', 'drop'].forEach(function (ev) {
    drop.addEventListener(ev, function (e) { prevent(e); drop.classList.remove('over'); });
  });
  drop.addEventListener('drop', function (e) {
    if (e.dataTransfer && e.dataTransfer.files) uploadAll(e.dataTransfer.files);
  });
  input.addEventListener('change', function () { uploadAll(input.files); });

  function uploadAll(files) {
    Array.prototype.forEach.call(files, function (f) { uploadOne(f); });
  }

  function uploadOne(file) {
    var li = document.createElement('li');
    li.innerHTML = escapeHtml(file.name) + ' <span class="sz"></span>' +
      '<div class="bar"><div></div></div>';
    list.appendChild(li);
    var bar = li.querySelector('.bar > div');
    var sz = li.querySelector('.sz');
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/u/$t/upload?name=' + encodeURIComponent(file.name));
    xhr.upload.onprogress = function (e) {
      if (e.lengthComputable) {
        bar.style.width = (e.loaded / e.total * 100).toFixed(1) + '%';
        sz.textContent = (e.loaded / 1048576).toFixed(1) + ' / ' +
          (e.total / 1048576).toFixed(1) + ' MB';
      }
    };
    xhr.onload = function () {
      if (xhr.status === 200) {
        li.classList.add('done');
        li.firstChild.textContent = '✓ ' + file.name;
        bar.style.width = '100%';
      } else {
        li.classList.add('err');
        li.firstChild.textContent = '✗ ' + file.name + ' (HTTP ' + xhr.status + ')';
      }
    };
    xhr.onerror = function () {
      li.classList.add('err');
      li.firstChild.textContent = '✗ ' + file.name + ' (network error)';
    };
    xhr.send(file);
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
})();
</script>
</body>
</html>
""".trimIndent()
    }
}
