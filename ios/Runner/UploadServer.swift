import Flutter
import Foundation
import Network
import Security

/// WiFi upload server (competitor-gap #1): a tiny HTTP/1.1 server bound to
/// 0.0.0.0 on a LAN port, serving an upload page so a PC browser can push
/// videos straight into the phone. Uploaded files land in the app's download
/// directory so the home "Downloaded" grid picks them up.
///
/// iOS ships no `com.sun.net.httpserver`, so this is a hand-rolled server:
/// a `NWListener` TCP accept loop + one `NWConnection` per connection, every
/// connection closed after its response.
///
/// HTTP contract (deliberately NOT multipart — a raw body with the file name
/// in the query is far simpler to stream correctly on both platforms):
///   GET  /u/<token>/           → the upload page (HTML)
///   GET  /u/<token>/health     → JSON status
///   POST /u/<token>/upload?name=<urlencoded>  → raw body (Content-Length
///                                required; 411 otherwise) streamed to a file
///
/// Security model: a fresh 128-bit random token per start, in the path. Anyone
/// on the LAN who can guess the token can upload — acceptable for a home-LAN
/// feature, and the server only runs while the user enabled it.
final class UploadServer {

    static let shared = UploadServer()

    static let CHANNEL = "dreamplayer/upload"

    private let maxHeader = 64 * 1024
    private let ioChunk = 256 * 1024
    private let headerTimeoutMs: Int64 = 30_000
    private let maxNameLen = 120

    private var listener: NWListener?
    @Atomic private var running = false
    @Atomic private var port = -1
    @Atomic private var token = ""
    @Atomic private var destDir: URL? = nil
    @Atomic private var receivedCount = 0
    @Atomic private var receivedBytes = 0

    func configure(messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: Self.CHANNEL, binaryMessenger: messenger)
            .setMethodCallHandler { [weak self] call, result in
                guard let self else { result(FlutterMethodNotImplemented); return }
                switch call.method {
                case "start":
                    let args = call.arguments as? [String: Any] ?? [:]
                    let requestedPort = args["port"] as? Int ?? 8080
                    let dest = args["destDir"] as? String
                    result(self.start(port: requestedPort, destDir: dest))
                case "stop":
                    self.stop(); result(nil)
                case "status":
                    result(self.statusMap())
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
    }

    @discardableResult
    private func start(port requestedPort: Int, destDir destDirPath: String?) -> [String: Any?] {
        stop()

        let dest: URL
        if let destDirPath, !destDirPath.isEmpty {
            dest = URL(fileURLWithPath: destDirPath)
        } else {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return ["ok": false, "error": "no documents directory"]
            }
            dest = docs.appendingPathComponent("DreamPlayer")
        }

        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return ["ok": false, "error": "cannot create \(dest.path): \(error.localizedDescription)"]
        }

        self.destDir = dest

        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()

        // Try the requested port, then +1..+9. If all are busy, report failure
        // so the user can pick a different port in Settings.
        var listener: NWListener? = nil
        var boundPort = -1
        for offset in 0..<10 {
            let candidate = requestedPort + offset
            guard let port = NWEndpoint.Port(rawValue: UInt16(candidate)) else { continue }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            do {
                let l = try NWListener(using: params, on: port)
                l.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .failed(let error) = state {
                        print("[UploadServer] listener on port \(candidate) failed: \(error)")
                    }
                }
                l.newConnectionHandler = { [weak self] conn in
                    self?.serve(conn)
                }
                l.start(queue: .global())
                listener = l
                boundPort = candidate
                break
            } catch {
                // port busy — try the next
            }
        }
        guard let l = listener, boundPort >= 0 else {
            return ["ok": false, "error": "no free port near \(requestedPort)"]
        }
        self.listener = l
        self.port = boundPort
        self.running = true
        self.receivedCount = 0
        self.receivedBytes = 0

        let addresses = localIPv4Addresses()
        let urls = addresses.map { "http://\($0):\(boundPort)/u/\(token)/" }
        print("[UploadServer] upload server on port \(boundPort) -> \(urls.joined(separator: ", ")) (dest=\(dest.path))")
        return [
            "ok": true,
            "port": boundPort,
            "token": token,
            "addresses": addresses,
            "destDir": dest.path,
        ]
    }

    private func stop() {
        running = false
        listener?.cancel()
        listener = nil
        port = -1
    }

    private func statusMap() -> [String: Any?] {
        [
            "running": running,
            "port": port,
            "token": token,
            "addresses": localIPv4Addresses(),
            "destDir": destDir?.path ?? "",
            "receivedCount": receivedCount,
            "receivedBytes": receivedBytes,
        ]
    }

    // MARK: - HTTP

    private func serve(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[UploadServer] connection failed: \(error)")
            }
        }
        connection.start(queue: .global())

        var head = Data()
        var headComplete = false
        let headerTimeout = DispatchTime.now() + .milliseconds(headerTimeoutMs)

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxHeader - head.count,
                               completion: { data, context, isComplete, error in
                if let data = data, !data.isEmpty {
                    head.append(data)
                    if head.range(of: Data("\r\n\r\n".utf8)) != nil {
                        headComplete = true
                        self.handleRequest(connection: connection, head: head)
                    } else if head.count >= maxHeader {
                        self.respond(connection: connection, code: 431, contentType: "text/plain",
                                     body: "header too large")
                    } else {
                        readMore()
                    }
                    return
                }
                if let error = error {
                    print("[UploadServer] header read error: \(error)")
                }
                connection.cancel()
            })
        }

        readMore()

        DispatchQueue.global().asyncAfter(deadline: headerTimeout) { [weak self, weak connection] in
            guard let self, let connection else { return }
            if !headComplete {
                connection.cancel()
            }
        }
    }

    private func handleRequest(connection: NWConnection, head: Data) {
        let separator = Data("\r\n\r\n".utf8)
        let sepRange = head.range(of: separator)
        guard let sepEnd = sepRange?.upperBound else {
            respond(connection: connection, code: 400, contentType: "text/plain", body: "bad request")
            return
        }
        let headerData = head[..<sepEnd]
        let bodyPrefix = head[sepEnd...] // any body bytes that arrived with the header

        let text = String(data: headerData, encoding: .utf8) ?? ""
        guard let requestLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            respond(connection: connection, code: 400, contentType: "text/plain", body: "bad request")
            return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            respond(connection: connection, code: 400, contentType: "text/plain", body: "bad request")
            return
        }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let headers = parseHeaders(text)
        let path = rawPath.split(separator: "?", maxSplits: 1).map(String.init).first ?? rawPath
        let query = rawPath.split(separator: "?", maxSplits: 1).map(String.init).dropFirst().joined(separator: "?")

        let t = token
        if path == "/u/\(t)" || path == "/u/\(t)/" {
            guard method == "GET" else {
                respond(connection: connection, code: 405, contentType: "text/plain", body: "method")
                return
            }
            let page = pageHtml().data(using: .utf8) ?? Data()
            respond(connection: connection, code: 200, contentType: "text/html; charset=utf-8",
                    body: page, extraHeaders: ["Cache-Control: no-store"])
            return
        }
        if path == "/u/\(t)/health" {
            let body = try? JSONSerialization.data(withJSONObject: statusMap().compactMapValues { $0 })
            respond(connection: connection, code: 200, contentType: "application/json",
                    body: body ?? Data("{}".utf8))
            return
        }
        if path == "/u/\(t)/upload" {
            guard method == "POST" else {
                respond(connection: connection, code: 405, contentType: "text/plain", body: "method")
                return
            }
            guard let lengthStr = headers["content-length"],
                  let length = Int(lengthStr), length >= 0 else {
                respond(connection: connection, code: 411, contentType: "text/plain", body: "Content-Length required")
                return
            }
            let nameParam = query.split(separator: "&").first { $0.hasPrefix("name=") }?
                .dropFirst(5) ?? ""
            let rawName = String(nameParam).removingPercentEncoding ?? "upload.bin"
            saveUpload(connection: connection, length: length, rawName: rawName, bodyPrefix: Data(bodyPrefix))
            return
        }
        respond(connection: connection, code: 404, contentType: "text/plain", body: "not found")
    }

    private func saveUpload(connection: NWConnection, length: Int, rawName: String, bodyPrefix: Data) {
        guard let dest = destDir else {
            respond(connection: connection, code: 500, contentType: "application/json",
                    body: Data("{\"ok\":false}".utf8))
            return
        }
        let name = sanitizeName(rawName)
        let existing = (try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil))
            .map { $0.lastPathComponent } ?? []
        let finalName = dedupe(name, Set(existing))
        let file = dest.appendingPathComponent(finalName)

        var remaining = length - bodyPrefix.count
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            if !bodyPrefix.isEmpty {
                try handle.write(contentsOf: bodyPrefix)
            }
            var readError: Error?
            let semaphore = DispatchSemaphore(value: 0)

            func readChunk() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(ioChunk, remaining),
                                   completion: { data, context, isComplete, error in
                    if let data = data, !data.isEmpty {
                        do { try handle.write(contentsOf: data) } catch { readError = error }
                        remaining -= data.count
                        if remaining > 0 && readError == nil {
                            readChunk()
                            return
                        }
                    }
                    semaphore.signal()
                })
            }

            readChunk()
            _ = semaphore.wait(timeout: .now() + .seconds(300))

            if let readError = readError { throw readError }
            if remaining > 0 {
                throw NSError(domain: "UploadServer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "client closed early"])
            }
        } catch {
            print("[UploadServer] upload failed: \(error)")
            try? FileManager.default.removeItem(at: file)
            respond(connection: connection, code: 500, contentType: "application/json",
                    body: Data("{\"ok\":false}".utf8))
            return
        }

        receivedCount += 1
        receivedBytes += length
        let body = "{\"ok\":true,\"saved\":\"\(finalName)\",\"size\":\(length)}".data(using: .utf8) ?? Data()
        respond(connection: connection, code: 200, contentType: "application/json", body: body)
    }

    // MARK: - helpers

    private func parseHeaders(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in text.split(separator: "\r\n").dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                map[key] = value
            }
        }
        return map
    }

    private func respond(connection: NWConnection, code: Int, contentType: String, body: Data,
                         extraHeaders: [String] = []) {
        let reason: String
        switch code {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 411: reason = "Length Required"
        case 431: reason = "Request Header Fields Too Large"
        case 500: reason = "Server Error"
        default: reason = "OK"
        }
        var head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for h in extraHeaders { head += "\(h)\r\n" }
        head += "\r\n"
        var out = head.data(using: .utf8) ?? Data()
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { error in
            if let error = error { print("[UploadServer] respond error: \(error)") }
            connection.cancel()
        })
    }

    private func sanitizeName(_ raw: String) -> String {
        var name = raw
        if let slash = name.lastIndex(of: "/"), let backslash = name.lastIndex(of: "\\") {
            let cut = max(slash, backslash)
            name = String(name[name.index(after: cut)...])
        } else if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        } else if let backslash = name.lastIndex(of: "\\") {
            name = String(name[name.index(after: backslash)...])
        }
        name = name.replacingOccurrences(of: "[\\u{0000}-\\u{001f}\\u{007f}]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { return "upload.bin" }
        let base = name.split(separator: ".").first.map { String($0).uppercased() } ?? ""
        if base == "CON" || base == "PRN" || base == "AUX" || base == "NUL" ||
            base.range(of: "^COM[1-9]$", options: .regularExpression) != nil ||
            base.range(of: "^LPT[1-9]$", options: .regularExpression) != nil {
            name = "_" + name
        }
        if name.count > maxNameLen {
            let dot = name.lastIndex(of: ".")
            let ext: String
            if let dot, name.count - name.distance(from: name.startIndex, to: dot) <= 9 {
                ext = String(name[dot...])
            } else { ext = "" }
            let keep = maxNameLen - ext.count
            if keep > 0 {
                let end = name.index(name.startIndex, offsetBy: keep, limitedBy: name.endIndex) ?? name.endIndex
                name = String(name[name.startIndex..<end]) + ext
            }
        }
        return name
    }

    private func dedupe(_ name: String, _ existing: Set<String>) -> String {
        if !existing.contains(name) { return name }
        let dot = name.lastIndex(of: ".")
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        for i in 2...9999 {
            let candidate = "\(stem) (\(i))\(ext)"
            if !existing.contains(candidate) { return candidate }
        }
        return "\(stem) (\(Date().timeIntervalSince1970))\(ext)"
    }

    // First non-loopback IPv4 address of any `en*` interface (Wi-Fi / Ethernet).
    private func localIPv4Addresses() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }

        var out: [String] = []
        var ptr = first
        while let current = ptr {
            let addr = current.pointee.ifa_addr
            guard addr != nil, addr!.pointee.sa_family == UInt8(AF_INET) else {
                ptr = current.pointee.ifa_next
                continue
            }
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr!.pointee.sa_len), &host, socklen_t(host.count),
                            nil, 0, NI_NUMERICHOST)
                let addrStr = String(cString: host)
                if !addrStr.isEmpty, !addrStr.hasPrefix("127.") {
                    out.append(addrStr)
                }
            }
            ptr = current.pointee.ifa_next
        }
        return out
    }

    // MARK: - upload page

    private func pageHtml() -> String {
        let t = token
        let port = port
        var html = ""
        html += "<!DOCTYPE html>\n"
        html += "<html lang=\"en\">\n"
        html += "<head>\n"
        html += "<meta charset=\"utf-8\">\n"
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        html += "<title>DreamPlayer — WiFi upload</title>\n"
        html += "<style>\n"
        html += "  :root { color-scheme: dark; }\n"
        html += "  body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;\n"
        html += "         background: #0e0e11; color: #e8e8ec; font-family: system-ui, sans-serif; }\n"
        html += "  main { width: min(560px, 92vw); padding: 24px; }\n"
        html += "  h1 { font-size: 22px; margin: 0 0 4px; }\n"
        html += "  p.sub { color: #9a9aa5; margin: 0 0 20px; font-size: 14px; word-break: break-all; }\n"
        html += "  .drop { border: 2px dashed #4b3e76; border-radius: 14px; padding: 36px 20px; text-align: center;\n"
        html += "          cursor: pointer; transition: border-color .15s; }\n"
        html += "  .drop:hover, .drop.over { border-color: #7c4dff; }\n"
        html += "  .drop .big { font-size: 40px; }\n"
        html += "  .drop .hint { color: #9a9aa5; font-size: 13px; margin-top: 8px; }\n"
        html += "  input[type=file] { display: none; }\n"
        html += "  ul { list-style: none; padding: 0; margin: 18px 0 0; }\n"
        html += "  li { padding: 8px 10px; border-radius: 8px; background: #17171d; margin-bottom: 8px; font-size: 13px; }\n"
        html += "  li .bar { height: 6px; border-radius: 3px; background: #26262e; margin-top: 6px; overflow: hidden; }\n"
        html += "  li .bar > div { height: 100%; width: 0%; background: #7c4dff; }\n"
        html += "  li.done { color: #7ee2a8; }\n"
        html += "  li.err { color: #ff8a80; }\n"
        html += "  .foot { color: #6a6a75; font-size: 12px; margin-top: 18px; }\n"
        html += "</style>\n"
        html += "</head>\n"
        html += "<body>\n"
        html += "<main>\n"
        html += "  <h1>DreamPlayer WiFi upload</h1>\n"
        html += "  <p class=\"sub\">This device: <b>http://LOCALHOST:\(port)/u/\(t)/</b> — send files to this phone.</p>\n"
        html += "  <label class=\"drop\" id=\"drop\">\n"
        html += "    <div class=\"big\">⬆️</div>\n"
        html += "    <div>Click to choose videos, or drop them here</div>\n"
        html += "    <div class=\"hint\">They are saved to this device's download folder and appear in DreamPlayer automatically.</div>\n"
        html += "    <input type=\"file\" id=\"files\" multiple accept=\"video/*,.mkv,.mp4,.avi,.ts,.m2ts,.webm,.wmv,.flv,.mpg,.mpeg,.vob,.mov,.m4v,.3gp,.ogv,.rmvb,.divx\">\n"
        html += "  </label>\n"
        html += "  <ul id=\"list\"></ul>\n"
        html += "  <p class=\"foot\">Only reachable while this screen's server is running. Token-protected; do not share the link.</p>\n"
        html += "</main>\n"
        html += "<script>\n"
        html += "(function () {\n"
        html += "  var drop = document.getElementById('drop');\n"
        html += "  var input = document.getElementById('files');\n"
        html += "  var list = document.getElementById('list');\n"
        html += "  fetch('/u/\(t)/health').then(function (r) { return r.json(); }).then(function (s) {\n"
        html += "    if (s.addresses && s.addresses.length) {\n"
        html += "      document.querySelector('p.sub b').textContent =\n"
        html += "        'http://' + s.addresses[0] + ':' + s.port + '/u/\(t)/';\n"
        html += "    }\n"
        html += "  }).catch(function () {});\n"
        html += "\n"
        html += "  function prevent(e) { e.preventDefault(); e.stopPropagation(); }\n"
        html += "  ['dragenter', 'dragover'].forEach(function (ev) {\n"
        html += "    drop.addEventListener(ev, function (e) { prevent(e); drop.classList.add('over'); });\n"
        html += "  });\n"
        html += "  ['dragleave', 'drop'].forEach(function (ev) {\n"
        html += "    drop.addEventListener(ev, function (e) { prevent(e); drop.classList.remove('over'); });\n"
        html += "  });\n"
        html += "  drop.addEventListener('drop', function (e) {\n"
        html += "    if (e.dataTransfer && e.dataTransfer.files) uploadAll(e.dataTransfer.files);\n"
        html += "  });\n"
        html += "  input.addEventListener('change', function () { uploadAll(input.files); });\n"
        html += "\n"
        html += "  function uploadAll(files) {\n"
        html += "    Array.prototype.forEach.call(files, function (f) { uploadOne(f); });\n"
        html += "  }\n"
        html += "\n"
        html += "  function uploadOne(file) {\n"
        html += "    var li = document.createElement('li');\n"
        html += "    li.innerHTML = escapeHtml(file.name) + ' <span class=\"sz\"></span>' +\n"
        html += "      '<div class=\"bar\"><div></div></div>';\n"
        html += "    list.appendChild(li);\n"
        html += "    var bar = li.querySelector('.bar > div');\n"
        html += "    var sz = li.querySelector('.sz');\n"
        html += "    var xhr = new XMLHttpRequest();\n"
        html += "    xhr.open('POST', '/u/\(t)/upload?name=' + encodeURIComponent(file.name));\n"
        html += "    xhr.upload.onprogress = function (e) {\n"
        html += "      if (e.lengthComputable) {\n"
        html += "        bar.style.width = (e.loaded / e.total * 100).toFixed(1) + '%';\n"
        html += "        sz.textContent = (e.loaded / 1048576).toFixed(1) + ' / ' +\n"
        html += "          (e.total / 1048576).toFixed(1) + ' MB';\n"
        html += "      }\n"
        html += "    };\n"
        html += "    xhr.onload = function () {\n"
        html += "      if (xhr.status === 200) {\n"
        html += "        li.classList.add('done');\n"
        html += "        li.firstChild.textContent = '✓ ' + file.name;\n"
        html += "        bar.style.width = '100%';\n"
        html += "      } else {\n"
        html += "        li.classList.add('err');\n"
        html += "        li.firstChild.textContent = '✗ ' + file.name + ' (HTTP ' + xhr.status + ')';"
        html += "\n"
        html += "      }\n"
        html += "    };\n"
        html += "    xhr.onerror = function () {\n"
        html += "      li.classList.add('err');\n"
        html += "      li.firstChild.textContent = '✗ ' + file.name + ' (network error)';\n"
        html += "    };\n"
        html += "    xhr.send(file);\n"
        html += "  }\n"
        html += "\n"
        html += "  function escapeHtml(s) {\n"
        html += "    var entities = { '&': '&amp;', '<': '&lt;', '>': '&gt;' }\n"
        html += "    return s.replace(/[&<>]/g, function (c) { return entities[c] || c; })\n"
        html += "  }\n"
        html += "})();\n"
        html += "</script>\n"
        html += "</body>\n"
        html += "</html>\n"
        return html
    }
}

/// Tiny thread-safe value wrapper so the server can be read/written from both
/// the method-channel queue and the NW listener queue.
@propertyWrapper
struct Atomic<Value> {
    private let lock = NSLock()
    private var _value: Value
    init(wrappedValue: Value) { _value = wrappedValue }
    var wrappedValue: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
