import AVFoundation
import Flutter
import Foundation
import Network

/// WiFi upload server (competitor-gap #1): a tiny HTTP/1.1 server bound to
/// 0.0.0.0 on a LAN port, serving an upload page so a PC browser can push
/// videos straight into the phone. Uploaded files land in the app's download
/// directory so the home "Downloaded" grid picks them up.
///
/// iOS ships no `com.sun.net.httpserver`, so this is a hand-rolled server:
/// a `NWListener` TCP accept loop + one `NWConnection` per connection, every
/// connection closed after its response.
///
/// HTTP contract (deliberately NOT multipart - a raw body with the file name
/// in the query is far simpler to stream correctly on both platforms):
///   GET  /wifi-transfer/           → the upload page (HTML)
///   GET  /wifi-transfer/health     → JSON status
///   POST /wifi-transfer/upload?name=<urlencoded>  → raw body (Content-Length
///                                required; 411 otherwise) streamed to a file
///
/// The path is fixed and token-free (user request): the URL a user types is
/// `http://<ip>:<port>/wifi-transfer/`, the same shape as every other LAN
/// file-transfer feature. The server listens only while the user turned it on
/// and it is bound to the LAN, so the trade is usability over secrecy -
/// which the transfer screen says plainly.
///
/// Per-transfer progress (`start` / `progress` / `done` / `failed`) is pushed
/// over Self.EVENT_CHANNEL so the transfer screen can show live progress rows.
final class UploadServer: NSObject, FlutterStreamHandler {

    static let shared = UploadServer()

    static let CHANNEL = "dreamplayer/upload"
    static let EVENT_CHANNEL = "dreamplayer/upload_events"
    static let pathPrefix = "/wifi-transfer"

    private let maxHeader = 64 * 1024
    private let ioChunk = 256 * 1024
    private let headerTimeoutMs = 30_000
    private let maxNameLen = 120
    /// The app's logo-only mark (no wordmark), 128px PNG, inlined so the page
    /// needs no second request and no asset lookup.
    private let logoBase64 = "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"
    /// Progress events per upload are throttled to this interval (seconds).
    private let progressInterval = 0.5

    private var listener: NWListener?
    @Atomic private var running = false
    @Atomic private var port = -1
    @Atomic private var destDir: URL? = nil
    @Atomic private var receivedCount = 0
    @Atomic private var receivedBytes = 0

    /// Optional page credentials (set by the user in the app). When both are
    /// non-empty every request needs HTTP Basic auth, and the browser shows
    /// its own prompt - no cookies, no session state, no second page.
    @Atomic private var authUser = ""
    @Atomic private var authPass = ""

    /// Connections with an upload in flight, so the page's Cancel button can
    /// tear them down without stopping the whole server.
    private let activeConnections = NSMutableSet()
    private let connectionsLock = NSLock()

    /// Files the user picked in-app to share with a PC ("send files to
    /// computer"). Key = display name, value = (uri, size). Streamed straight
    /// from the URL on download - NO copy, so picking large videos never
    /// blocks the UI.
    private var sharedFiles: [String: (uri: String, size: Int64)] = [:]
    private let sharedFilesLock = NSLock()
    /// Identifies ONE server run. REGENERATED on every start - the page
    /// stores it with the batch it last saved, so a page reload never
    /// re-downloads files it already received, and a restarted server is
    /// never mistaken for the old one (the old run kept the same id while
    /// the sequence reset to 0, so a re-send after a restart was skipped as
    /// "already saved" - the "can only send once" bug).
    private var runId = UUID().uuidString
    /// Bumped on every shareFiles call - one "send" from the phone. Never
    /// reset except alongside a new runId in start: the page uses it to
    /// tell a new batch from one it already received.
    private var sharedSeq = 0

    /// HTTP Basic challenge header sent with every 401.
    private let wwwAuthenticate =
        "WWW-Authenticate: Basic realm=\"DreamPlayer WiFi transfer\", charset=\"UTF-8\""
    /// Set on the main thread by [FlutterStreamHandler.onListen]; every emit
    /// hops to the main thread because Flutter rejects calls from any other.
    @Atomic private var eventSink: FlutterEventSink? = nil

    func configure(messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: Self.CHANNEL, binaryMessenger: messenger)
            .setMethodCallHandler { [weak self] call, result in
                guard let self else { result(FlutterMethodNotImplemented); return }
                switch call.method {
                case "start":
                    let args = call.arguments as? [String: Any] ?? [:]
                    let requestedPort = args["port"] as? Int ?? 8080
                    let dest = args["destDir"] as? String
                    let user = (args["username"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                    let pass = args["password"] as? String ?? ""
                    result(self.start(port: requestedPort, destDir: dest,
                                      username: user, password: pass))
                case "stop":
                    self.stop(); result(nil)
                case "status":
                    result(self.statusMap())
                case "shareFiles":
                    let args = call.arguments as? [String: Any] ?? [:]
                    let files = args["files"] as? [[String: Any]] ?? []
                    self.sharedFilesLock.lock()
                    self.sharedFiles.removeAll()
                    for f in files {
                        guard let name = f["name"] as? String, let uri = f["uri"] as? String else { continue }
                        let size = (f["size"] as? NSNumber)?.int64Value ?? 0
                        self.sharedFiles[name] = (uri, size)
                    }
                    let count = self.sharedFiles.count
                    // A new batch: the page starts receiving it on its next poll.
                    self.sharedSeq += 1
                    self.sharedFilesLock.unlock()
                    result(["ok": true, "count": count])
                case "clearSharedFiles":
                    self.sharedFilesLock.lock()
                    // Clear the list only. The seq must keep rising: the page
                    // remembers runId|seq, and resetting seq under the same
                    // runId would make the NEXT send look already-saved.
                    self.sharedFiles.removeAll()
                    self.sharedFilesLock.unlock()
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
        FlutterEventChannel(name: Self.EVENT_CHANNEL, binaryMessenger: messenger)
            .setStreamHandler(self)
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    /// Pushes one progress event to Dart on the main thread.
    private func emit(_ type: String, _ extra: [String: Any?] = [:]) {
        guard let sink = eventSink else { return }
        var event: [String: Any?] = ["type": type]
        for (key, value) in extra { event[key] = value }
        let payload = event.compactMapValues { $0 }
        DispatchQueue.main.async {
            sink(payload)
        }
    }

    @discardableResult
    private func start(port requestedPort: Int, destDir destDirPath: String?,
                       username: String, password: String) -> [String: Any?] {
        stop()

        let dest: URL
        if let destDirPath, !destDirPath.isEmpty {
            // Accept a plain absolute path, a file:// URL, or a relative name
            // (anchored in Documents). URL(fileURLWithPath:) on a file:// string
            // would mangle it into a bogus nested path.
            if destDirPath.hasPrefix("file://"), let u = URL(string: destDirPath) {
                dest = u
            } else if destDirPath.hasPrefix("/") {
                dest = URL(fileURLWithPath: destDirPath)
            } else {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                dest = (docs ?? URL(fileURLWithPath: "/")).appendingPathComponent(destDirPath)
            }
        } else {
            // Default: the app's own "DreamPlayer" folder inside Documents,
            // i.e. the folder the Files app shows as On My iPad -> DreamPlayer
            // -> DreamPlayer (UIFileSharingEnabled exposes Documents).
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
        authUser = username
        authPass = password

        // Try the requested port, then +1..+9. A bind conflict is NOT thrown
        // by the NWListener initializer - it arrives asynchronously as a
        // .failed state - so wait briefly for .ready/.failed per candidate and
        // only accept the port that actually came up. Without this the server
        // would report ok:true on a busy port and then silently never serve.
        var listener: NWListener? = nil
        var boundPort = -1
        for offset in 0..<10 {
            let candidate = requestedPort + offset
            guard let port = NWEndpoint.Port(rawValue: UInt16(candidate)) else { continue }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            do {
                let l = try NWListener(using: params, on: port)
                let ready = DispatchSemaphore(value: 0)
                var outcome: NWListener.State?
                l.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .failed, .cancelled:
                        outcome = state
                        ready.signal()
                    default:
                        break
                    }
                }
                l.newConnectionHandler = { [weak self] conn in
                    self?.serve(conn)
                }
                l.start(queue: .global())
                let waitResult = ready.wait(timeout: .now() + 1)
                if waitResult == .timedOut {
                    l.cancel()
                    continue
                }
                if case .some(.ready) = outcome {
                    // Accepted: swap in the handler for the lifetime of the
                    // listener. If it later fails, the server is dead: stop
                    // the keep-alive and tell Dart so the UI flips to stopped.
                    l.stateUpdateHandler = { [weak self] state in
                        if case .failed(let error) = state {
                            print("[UploadServer] listener on port \(candidate) failed: \(error)")
                            self?.stop()
                        }
                    }
                    listener = l
                    boundPort = candidate
                    break
                }
                l.cancel()
            } catch {
                // invalid candidate - try the next
            }
        }
        guard let l = listener, boundPort >= 0 else {
            return ["ok": false, "error": "no free port near \(requestedPort)"]
        }
        self.listener = l
        self.port = boundPort
        self.running = true
        // New run, new id, fresh sequence - so the receiving page treats the
        // next send as a new batch even if it saved one from the previous run.
        self.runId = UUID().uuidString
        self.sharedSeq = 0
        self.receivedCount = 0
        self.receivedBytes = 0
        // Keep the process alive while the screen is locked (see below).
        startKeepAlive()

        let addresses = localIPv4Addresses()
        let urls = addresses.map { "http://\($0):\(boundPort)\(Self.pathPrefix)/" }
        print("[UploadServer] upload server on port \(boundPort) -> \(urls.joined(separator: ", ")) (dest=\(dest.path))")
        return [
            "ok": true,
            "port": boundPort,
            "addresses": addresses,
            "destDir": dest.path,
        ]
    }

    private func stop() {
        running = false
        sharedFilesLock.lock()
        sharedFiles.removeAll()
        sharedFilesLock.unlock()
        stopKeepAlive()
        listener?.cancel()
        listener = nil
        port = -1
        // Tear down in-flight connections too, so an upload being streamed
        // when the user taps Stop does not linger on the 300 s read timeout.
        connectionsLock.lock()
        let connections = activeConnections.allObjects
        activeConnections.removeAllObjects()
        connectionsLock.unlock()
        for object in connections {
            if let connection = object as? NWConnection {
                connection.cancel()
            }
        }
        emit("stopped")
    }

    private func statusMap() -> [String: Any?] {
        sharedFilesLock.lock()
        let sharedCount = sharedFiles.count
        sharedFilesLock.unlock()
        return [
            "running": running,
            "port": port,
            "addresses": localIPv4Addresses(),
            "destDir": destDir?.path ?? "",
            "receivedCount": receivedCount,
            "receivedBytes": receivedBytes,
            "sharedCount": sharedCount,
        ]
    }

    // MARK: - HTTP

    /// Themed page behind a failed/dismissed Basic-auth prompt: the browser
    /// shows its own dialog first (that is the login), this is what remains
    /// visible if the user cancels it.
    private func unauthorizedPageHtml() -> String {
        var html = ""
        html += "<!DOCTYPE html>\n"
        html += "<html lang=\"en\">\n"
        html += "<head>\n"
        html += "<meta charset=\"utf-8\">\n"
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        html += "<title>DreamPlayer - Sign in</title>\n"
        html += "<style>\n"
        html += "  :root { color-scheme: dark; }\n"
        html += "  body { margin: 0; min-height: 100vh; background: #0e0e11; color: #e8e8ec;\n"
        html += "         font-family: system-ui, -apple-system, sans-serif;\n"
        html += "         display: flex; align-items: center; justify-content: center; padding: 24px; }\n"
        html += "  .card { width: min(420px, 100%); background: #17171d; border: 1px solid #26262e;\n"
        html += "          border-radius: 18px; padding: 28px 22px; text-align: center; }\n"
        html += "  .card img { display: block; width: 52px; height: 52px; border-radius: 14px; margin: 0 auto 16px; }\n"
        html += "  h1 { font-size: 19px; margin: 0 0 6px; }\n"
        html += "  p { margin: 0; font-size: 13px; color: #9a9aa5; line-height: 1.5; }\n"
        html += "</style>\n"
        html += "</head>\n"
        html += "<body>\n"
        html += "  <div class=\"card\">\n"
        html += "    <img src=\"data:image/png;base64,\(logoBase64)\" alt=\"DreamPlayer\">\n"
        html += "    <h1>Sign in required</h1>\n"
        html += "    <p>DreamPlayer's WiFi file transfer is protected. Enter the username and\n"
        html += "       password you set in the app.</p>\n"
        html += "  </div>\n"
        html += "</body>\n"
        html += "</html>\n"
        return html
    }

    private func serve(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed(let error) = state {
                print("[UploadServer] connection failed: \(error)")
            }
        }
        connection.start(queue: .global())
        connectionsLock.lock()
        activeConnections.add(connection)
        connectionsLock.unlock()

        var head = Data()
        var headComplete = false
        let headerTimeout = DispatchTime.now() + .milliseconds(headerTimeoutMs)

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: self.maxHeader - head.count,
                               completion: { data, context, isComplete, error in
                if let data = data, !data.isEmpty {
                    head.append(data)
                    if head.range(of: Data("\r\n\r\n".utf8)) != nil {
                        headComplete = true
                        self.handleRequest(connection: connection, head: head)
                    } else if head.count >= self.maxHeader {
                        self.respond(connection: connection, code: 431, contentType: "text/plain",
                                     body: Data("header too large".utf8))
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
            respond(connection: connection, code: 400, contentType: "text/plain", body: Data("bad request".utf8))
            return
        }
        let headerData = head[..<sepEnd]
        let bodyPrefix = head[sepEnd...] // any body bytes that arrived with the header

        let text = String(data: headerData, encoding: .utf8) ?? ""
        guard let requestLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            respond(connection: connection, code: 400, contentType: "text/plain", body: Data("bad request".utf8))
            return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            respond(connection: connection, code: 400, contentType: "text/plain", body: Data("bad request".utf8))
            return
        }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let headers = parseHeaders(text)
        let path = rawPath.split(separator: "?", maxSplits: 1).map(String.init).first ?? rawPath
        let query = rawPath.split(separator: "?", maxSplits: 1).map(String.init).dropFirst().joined(separator: "?")

        // HTTP Basic auth gate: with credentials set, the browser shows its own
        // prompt and retries with an Authorization header. Nothing else is
        // served without it.
        if !authorized(headers) {
            respond(connection: connection, code: 401, contentType: "text/html; charset=utf-8",
                    body: unauthorizedPageHtml().data(using: .utf8) ?? Data(),
                    extraHeaders: [wwwAuthenticate])
            return
        }
        if path == "\(Self.pathPrefix)" || path == "\(Self.pathPrefix)/" {
            guard method == "GET" else {
                respond(connection: connection, code: 405, contentType: "text/plain", body: Data("method not allowed".utf8))
                return
            }
            let page = pageHtml().data(using: .utf8) ?? Data()
            respond(connection: connection, code: 200, contentType: "text/html; charset=utf-8",
                    body: page, extraHeaders: ["Cache-Control: no-store"])
            return
        }
        if path == "\(Self.pathPrefix)/health" {
            let body = try? JSONSerialization.data(withJSONObject: statusMap().compactMapValues { $0 })
            respond(connection: connection, code: 200, contentType: "application/json",
                    body: body ?? Data("{}".utf8))
            return
        }
        if path == "\(Self.pathPrefix)/upload" {
            guard method == "POST" else {
                respond(connection: connection, code: 405, contentType: "text/plain", body: Data("method not allowed".utf8))
                return
            }
            guard let lengthStr = headers["content-length"],
                  let length = Int(lengthStr), length >= 0 else {
                respond(connection: connection, code: 411, contentType: "text/plain", body: Data("Content-Length required".utf8))
                return
            }
            let nameParam = query.split(separator: "&").first { $0.hasPrefix("name=") }?
                .dropFirst(5) ?? ""
            let rawName = String(nameParam).removingPercentEncoding ?? "upload.bin"
            saveUpload(connection: connection, length: length, rawName: rawName, bodyPrefix: Data(bodyPrefix))
            return
        }
        if path == "\(Self.pathPrefix)/cancel" {
            guard method == "POST" else {
                respond(connection: connection, code: 405, contentType: "text/plain",
                        body: Data("method not allowed".utf8))
                return
            }
            cancelTransfers()
            respond(connection: connection, code: 200, contentType: "application/json",
                    body: Data("{\"ok\":true}".utf8))
            return
        }
        if path == "\(Self.pathPrefix)/files" {
            guard method == "GET" else {
                respond(connection: connection, code: 405, contentType: "text/plain", body: Data("method not allowed".utf8))
                return
            }
            sharedFilesLock.lock()
            let list = sharedFiles.map { ["name": $0.key, "size": $0.value.size] as [String: Any] }
            let seq = sharedSeq
            let runId = self.runId
            sharedFilesLock.unlock()
            // The batch identity rides along so the page can tell a new send
            // from one it already received (and a reload from a new batch).
            let body = (try? JSONSerialization.data(withJSONObject: [
                "runId": runId, "seq": seq, "files": list,
            ])) ?? Data("{}".utf8)
            // no-store: the page polls this every second and must never see
            // a cached batch list.
            respond(connection: connection, code: 200, contentType: "application/json", body: body,
                    extraHeaders: ["Cache-Control: no-store"])
            return
        }
        if path == "\(Self.pathPrefix)/files.zip" {
            // ONE archive for the whole send batch (PairDrop zips the same
            // way): browsers without a directory picker (Firefox/Safari)
            // download this single store-only zip instead of N files, so the
            // "multiple downloads" prompt never fires and the folder structure
            // travels inside the archive. Streamed straight from the URIs.
            guard method == "GET" else {
                respond(connection: connection, code: 405, contentType: "text/plain", body: Data("method not allowed".utf8))
                return
            }
            sharedFilesLock.lock()
            let entries = sharedFiles.map { (name: $0.key, uri: $0.value.uri, size: $0.value.size) }
            sharedFilesLock.unlock()
            guard !entries.isEmpty else {
                respond(connection: connection, code: 404, contentType: "text/plain", body: Data("nothing shared".utf8))
                return
            }
            streamSharedZip(connection: connection, entries: entries)
            return
        }
        if path == "\(Self.pathPrefix)/file" {
            guard method == "GET" else {
                respond(connection: connection, code: 405, contentType: "text/plain", body: Data("method not allowed".utf8))
                return
            }
            let nameParam = query.split(separator: "&").first { $0.hasPrefix("name=") }?.dropFirst(5) ?? ""
            let rawName = String(nameParam).removingPercentEncoding ?? ""
            sharedFilesLock.lock()
            let entry = sharedFiles[rawName]
            sharedFilesLock.unlock()
            guard let entry else {
                respond(connection: connection, code: 404, contentType: "text/plain", body: Data("not found".utf8))
                return
            }
            streamSharedFile(connection: connection, name: rawName, uriString: entry.uri, size: entry.size, headers: headers)
            return
        }
        respond(connection: connection, code: 404, contentType: "text/plain", body: Data("not found".utf8))
    }

    private func saveUpload(connection: NWConnection, length: Int, rawName: String, bodyPrefix: Data) {
        guard let dest = destDir else {
            respond(connection: connection, code: 500, contentType: "application/json",
                    body: Data("{\"ok\":false}".utf8))
            return
        }
        let name = sanitizeName(rawName)
        let existing = (try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil))?
            .map { $0.lastPathComponent } ?? []
        let finalName = dedupe(name, Set(existing))
        let file = dest.appendingPathComponent(finalName)

        let id = UUID().uuidString
        emit("start", ["id": id, "name": finalName, "total": length])

        var remaining = length - bodyPrefix.count
        var written = bodyPrefix.count
        var lastProgress = Date()
        do {
            // FileHandle(forWritingTo:) does NOT create a missing file - it
            // throws Cocoa error 4 ("The file ... doesn't exist.") which is
            // exactly the iOS failure Kotlin never has (FileOutputStream
            // creates the file). Create it explicitly first.
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw NSError(domain: "UploadServer", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "cannot create \(file.path)"])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            if !bodyPrefix.isEmpty {
                try handle.write(contentsOf: bodyPrefix)
            }
            var readError: Error?
            let semaphore = DispatchSemaphore(value: 0)

            func readChunk() {
                // remaining can be 0 when the whole body arrived with the
                // header (small files); NWConnection requires maximumLength
                // >= minimumIncompleteLength (1), so never call receive with 0.
                if remaining <= 0 { semaphore.signal(); return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(self.ioChunk, remaining),
                                   completion: { data, context, isComplete, error in
                    if let data = data, !data.isEmpty {
                        do { try handle.write(contentsOf: data) } catch { readError = error }
                        remaining -= data.count
                        written += data.count
                        if Date().timeIntervalSince(lastProgress) >= self.progressInterval {
                            lastProgress = Date()
                            self.emit("progress", ["id": id, "received": written])
                        }
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
            emit("failed", ["id": id, "error": error.localizedDescription])
            respond(connection: connection, code: 500, contentType: "application/json",
                    body: Data("{\"ok\":false}".utf8))
            return
        }

        receivedCount += 1
        receivedBytes += length
        emit("progress", ["id": id, "received": written])
        emit("done", ["id": id, "received": written, "path": file.path])
        let body = (try? JSONSerialization.data(withJSONObject: ["ok": true, "saved": finalName, "size": length] as [String: Any]))
            ?? Data("{\"ok\":true}".utf8)
        respond(connection: connection, code: 200, contentType: "application/json", body: body)
    }

    /// Streams a shared file (registered by the user in-app) from its URL to
    /// the PC browser. Supports HTTP Range so the browser can resume. Runs on
    /// the connection queue - never blocks the main thread.
    private func streamSharedFile(connection: NWConnection, name: String, uriString: String, size: Int64, headers: [String: String]) {
        guard let url = URL(string: uriString) else {
            respond(connection: connection, code: 404, contentType: "text/plain", body: Data("bad uri".utf8))
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let input = try? FileHandle(forReadingFrom: url) else {
            respond(connection: connection, code: 404, contentType: "text/plain", body: Data("file unreadable".utf8))
            return
        }
        defer { try? input.close() }

        let rangeHeader = headers["range"]
        var start: Int64 = 0
        var end: Int64 = size > 0 ? size - 1 : -1
        var partial = false
        if let rangeHeader, rangeHeader.hasPrefix("bytes=") {
            let spec = String(rangeHeader.dropFirst(6)).split(separator: "-")
            start = Int64(spec.first.map { String($0) } ?? "0") ?? 0
            if spec.count > 1, !spec[1].isEmpty {
                end = Int64(spec[1]) ?? (size - 1)
            }
            partial = true
        }
        let length = (end >= 0 && end >= start) ? end - start + 1 : size - start
        let mime = guessMime(name)

        var head = ""
        if partial {
            head += "HTTP/1.1 206 Partial Content\r\n"
            // Both ternary branches must be the same type: the total size is
            // a number when it is known and "*" when the server could not
            // stat the file.
            let totalText = size > 0 ? "\(size)" : "*"
            head += "Content-Range: bytes \(start)-\(end >= 0 ? end : size - 1)/\(totalText)\r\n"
        } else {
            head += "HTTP/1.1 200 OK\r\n"
        }
        head += "Content-Type: \(mime)\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Cache-Control: no-store\r\n"
        // Only the LAST path component: names like "Photos/IMG_0001.HEIC"
        // must download as "IMG_0001.HEIC" - a slash in the header filename
        // makes download managers save a broken ".part" file.
        let dlName = (name as NSString).lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        head += "Content-Disposition: attachment; filename=\"\(dlName)\"\r\n"
        head += "Connection: close\r\n\r\n"

        var out = (head.data(using: .utf8) ?? Data())
        connection.send(content: out, completion: .contentProcessed { _ in })

        // Skip to start
        if start > 0 {
            try? input.seek(toOffset: UInt64(start))
        }

        var remaining = length
        let chunkSize = 256 * 1024
        func sendChunk() {
            if remaining <= 0 {
                connection.cancel()
                return
            }
            let toRead = min(chunkSize, Int(remaining))
            let data = try? input.read(upToCount: toRead)
            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            remaining -= Int64(data.count)
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil && remaining > 0 {
                    sendChunk()
                } else {
                    connection.cancel()
                }
            })
        }
        sendChunk()
    }

    // MARK: - Whole-batch ZIP (store-only, ZIP64-capable)

    // The CRC of an entry is only known after its bytes are read, so each
    // local header uses the data-descriptor flag (bit 3) and the real
    // CRC/sizes follow the data; the central directory carries the real
    // values, which is what every reader (browser, unzip) actually uses.
    // Mirrors StoreZip.kt on Android byte for byte.
    private static let crcTable: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            t[i] = c
        }
        return t
    }()

    private func crc32Update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = crc
        for b in data { c = UploadServer.crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }

    private func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    private func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    private func le64(_ v: Int64) -> Data {
        var d = Data()
        let u = UInt64(bitPattern: v)
        for i in 0..<8 { d.append(UInt8((u >> UInt64(8 * i)) & 0xFF)) }
        return d
    }

    /// Streams the whole shared batch as one store-only ZIP. No
    /// Content-Length: the archive length depends on the bytes actually
    /// read, so the body is close-delimited.
    private func streamSharedZip(connection: NWConnection, entries: [(name: String, uri: String, size: Int64)]) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/zip\r\n"
        head += "Content-Disposition: attachment; filename=\"DreamPlayer_files.zip\"\r\n"
        head += "Accept-Ranges: none\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        struct Cent { var name: [UInt8]; var crc: UInt32; var size: Int64; var declared: Int64; var localOffset: Int64 }
        var centrals: [Cent] = []
        var offset: Int64 = 0
        var idx = 0

        func sendData(_ d: Data, then: @escaping () -> Void) {
            if d.isEmpty { then(); return }
            connection.send(content: d, completion: .contentProcessed { _ in then() })
        }

        func writeCentral(cdStart: Int64) {
            var i = 0
            func nextOne() {
                guard i < centrals.count else { finish(cdStart: cdStart); return }
                let c = centrals[i]; i += 1
                // ZIP64 is decided on max(actual, declared) so the local
                // header, the central directory and the ZIP64 EOCD can never
                // disagree about whether an entry is oversized.
                let size64 = c.size >= 0xFFFFFFFF || c.declared >= 0xFFFFFFFF
                let off64 = c.localOffset >= 0xFFFFFFFF
                // One 0x0001 field, spec order (usize, csize, local offset),
                // only the values whose 32-bit slots are 0xFFFFFFFF.
                var extraBody = Data()
                if size64 { extraBody.append(le64(c.size)); extraBody.append(le64(c.size)) }
                if off64 { extraBody.append(le64(c.localOffset)) }
                var ch = Data()
                ch.append(le32(0x02014b50))
                ch.append(le16(45)); ch.append(le16(45))
                ch.append(le16(0x0808)) // data descriptor + UTF-8
                ch.append(le16(0)) // method: store
                ch.append(le16(0)); ch.append(le16(0x0021))
                ch.append(le32(c.crc))
                ch.append(le32(size64 ? 0xFFFFFFFF : UInt32(truncatingIfNeeded: c.size)))
                ch.append(le32(size64 ? 0xFFFFFFFF : UInt32(truncatingIfNeeded: c.size)))
                ch.append(le16(c.name.count))
                ch.append(le16(extraBody.isEmpty ? 0 : extraBody.count + 4))
                ch.append(le16(0)); ch.append(le16(0)); ch.append(le16(0))
                ch.append(le32(0))
                ch.append(le32(off64 ? 0xFFFFFFFF : UInt32(truncatingIfNeeded: c.localOffset)))
                ch.append(Data(c.name))
                if !extraBody.isEmpty {
                    ch.append(le16(0x0001)); ch.append(le16(extraBody.count)); ch.append(extraBody)
                }
                sendData(ch) { offset += Int64(ch.count); nextOne() }
            }
            nextOne()
        }

        func finish(cdStart: Int64) {
            let cdSize = offset - cdStart
            let need64 = cdStart >= 0xFFFFFFFF || cdSize >= 0xFFFFFFFF || centrals.count >= 0xFFFF ||
                centrals.contains { $0.size >= 0xFFFFFFFF || $0.declared >= 0xFFFFFFFF || $0.localOffset >= 0xFFFFFFFF }
            func writeEocd() {
                var e = Data()
                e.append(le32(0x06054b50))
                e.append(le16(0)); e.append(le16(0))
                e.append(le16(min(centrals.count, 0xFFFF))); e.append(le16(min(centrals.count, 0xFFFF)))
                e.append(le32(cdSize >= 0xFFFFFFFF ? 0xFFFFFFFF : UInt32(truncatingIfNeeded: cdSize)))
                e.append(le32(cdStart >= 0xFFFFFFFF ? 0xFFFFFFFF : UInt32(truncatingIfNeeded: cdStart)))
                e.append(le16(0))
                sendData(e) { connection.cancel() }
            }
            if need64 {
                let z64Start = offset
                var z = Data()
                z.append(le32(0x06064b50))
                z.append(le64(44))
                z.append(le16(45)); z.append(le16(45))
                z.append(le32(0)); z.append(le32(0))
                z.append(le64(Int64(centrals.count))); z.append(le64(Int64(centrals.count)))
                z.append(le64(cdSize)); z.append(le64(cdStart))
                offset += 56
                var loc = Data()
                loc.append(le32(0x07064b50)); loc.append(le32(0)); loc.append(le64(z64Start)); loc.append(le32(1))
                offset += 20
                sendData(z) { sendData(loc) { writeEocd() } }
            } else {
                writeEocd()
            }
        }

        func pumpData(_ input: FileHandle, crc: UInt32, total: Int64, nameBytes: [UInt8],
                      declared: Int64, localOffset: Int64, zip64: Bool, done: @escaping () -> Void) {
            let data = (try? input.read(upToCount: 256 * 1024)) ?? Data()
            if data.isEmpty {
                let finalCrc = crc ^ 0xFFFFFFFF
                var dd = Data()
                if total >= 0xFFFFFFFF || zip64 {
                    dd.append(le32(0x08074b50)); dd.append(le32(finalCrc)); dd.append(le64(total)); dd.append(le64(total))
                } else {
                    dd.append(le32(0x08074b50)); dd.append(le32(finalCrc))
                    dd.append(le32(UInt32(truncatingIfNeeded: total))); dd.append(le32(UInt32(truncatingIfNeeded: total)))
                }
                centrals.append(Cent(name: nameBytes, crc: finalCrc, size: total, declared: declared, localOffset: localOffset))
                sendData(dd) { offset += Int64(dd.count); done() }
                return
            }
            let newCrc = crc32Update(crc, data)
            sendData(data) {
                offset += Int64(data.count)
                pumpData(input, crc: newCrc, total: total + Int64(data.count), nameBytes: nameBytes,
                         declared: declared, localOffset: localOffset, zip64: zip64, done: done)
            }
        }

        func writeEntry() {
            guard idx < entries.count else {
                writeCentral(cdStart: offset)
                return
            }
            let e = entries[idx]; idx += 1
            // Open BEFORE the header so an unreadable file is skipped whole.
            guard let url = URL(string: e.uri) else { writeEntry(); return }
            let scoped = url.startAccessingSecurityScopedResource()
            guard let input = try? FileHandle(forReadingFrom: url) else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                writeEntry(); return
            }
            let nameBytes = Array(e.name.utf8)
            let zip64 = e.size >= 0xFFFFFFFF
            let localOffset = offset
            var lh = Data()
            lh.append(le32(0x04034b50))
            lh.append(le16(45))
            lh.append(le16(0x0808))
            lh.append(le16(0)) // store
            lh.append(le16(0)); lh.append(le16(0x0021))
            lh.append(le32(0)) // crc in descriptor
            lh.append(le32(zip64 ? 0xFFFFFFFF : 0))
            lh.append(le32(zip64 ? 0xFFFFFFFF : 0))
            lh.append(le16(nameBytes.count))
            lh.append(le16(zip64 ? 20 : 0))
            lh.append(Data(nameBytes))
            if zip64 {
                lh.append(le16(0x0001)); lh.append(le16(16)); lh.append(le64(e.size)); lh.append(le64(e.size))
            }
            sendData(lh) {
                offset += Int64(lh.count)
                pumpData(input, crc: 0xFFFFFFFF, total: 0, nameBytes: nameBytes,
                         declared: e.size, localOffset: localOffset, zip64: zip64) {
                    try? input.close()
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    writeEntry()
                }
            }
        }
        writeEntry()
    }

    private func guessMime(_ name: String) -> String {
        let ext = name.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        switch ext {
        case "mkv": return "video/x-matroska"
        case "mp4", "m4v": return "video/mp4"
        case "avi": return "video/x-msvideo"
        case "webm": return "video/webm"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "mov": return "video/quicktime"
        case "wmv": return "video/x-ms-wmv"
        case "flv": return "video/x-flv"
        case "mpg", "mpeg", "vob": return "video/mpeg"
        case "3gp": return "video/3gpp"
        case "ogv": return "video/ogg"
        case "srt": return "application/x-subrip"
        case "ass", "ssa": return "text/plain"
        case "vtt": return "text/vtt"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    // MARK: - background keep-alive

    /// iOS suspends an app when the screen locks unless one of its declared
    /// background modes is actually active. Info.plist declares `audio`, but
    /// that only keeps the process alive while audio is PLAYING - an idle
    /// session is not enough, so the NWListener would stop accepting the
    /// moment the iPad locks. While the upload server runs we therefore play a
    /// looping silent buffer through an active playback session; with
    /// `.mixWithOthers` it is inaudible and does not interrupt video playback
    /// or another app's audio. stop() stops the player, which ends the
    /// sustained background execution again.
    private var keepAlivePlayer: AVAudioPlayer?

    private func startKeepAlive() {
        guard keepAlivePlayer == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            // fileTypeHint is a String (a UTI); AVFileType became a struct in
            // recent SDKs and no longer implicitly converts - use its rawValue.
            let player = try AVAudioPlayer(data: Self.silentWav(seconds: 2, sampleRate: 8000),
                                           fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            keepAlivePlayer = player
        } catch {
            // Foreground-only fallback: the server still works, it just gets
            // suspended on lock like any non-background app.
            print("[UploadServer] keep-alive audio failed (server runs foreground-only): \(error)")
        }
    }

    private func stopKeepAlive() {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        // Deliberately do NOT setActive(false) here: the video engine shares
        // this session and deactivating would pause its audio.
    }

    /// A minimal silent WAV (PCM 16-bit mono) generated in memory - no asset
    /// file needed.
    private static func silentWav(seconds: Int, sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let frameCount = sampleRate * seconds
        let dataSize = frameCount * channels * bytesPerSample
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * bytesPerSample))
        u16(UInt16(channels * bytesPerSample)); u16(UInt16(bitsPerSample))
        str("data"); u32(UInt32(dataSize))
        d.append(Data(count: dataSize)) // all zeros = silence
        return d
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

    /// HTTP Basic check against the credentials the user set in the app.
    /// Both credentials empty = open access (the toggle is the guard).
    private func authorized(_ headers: [String: String]) -> Bool {
        let user = authUser, pass = authPass
        if user.isEmpty || pass.isEmpty { return true }
        guard let header = headers["authorization"],
              header.lowercased().hasPrefix("basic ") else { return false }
        let encoded = String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8),
              let sep = decoded.firstIndex(of: ":") else { return false }
        let sentUser = String(decoded[..<sep])
        let sentPass = String(decoded[decoded.index(after: sep)...])
        return sentUser == user && sentPass == pass
    }

    /// Cancels the in-flight uploads (the page's Cancel button): the
    /// connections close, saveUpload's error path deletes the partial files,
    /// and Dart's rows flip to failed. The server keeps listening.
    private func cancelTransfers() {
        connectionsLock.lock()
        let connections = activeConnections.allObjects
        connectionsLock.unlock()
        for object in connections {
            if let connection = object as? NWConnection {
                connection.cancel()
            }
        }
        emit("cancelled")
    }

    private func respond(connection: NWConnection, code: Int, contentType: String, body: Data,
                         extraHeaders: [String] = []) {
        let reason: String
        switch code {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
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
            self.connectionsLock.lock()
            self.activeConnections.remove(connection)
            self.connectionsLock.unlock()
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
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        guard let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }

        var out: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            let addrStr = String(cString: host)
            if !addrStr.isEmpty, !addrStr.hasPrefix("127.") {
                out.append(addrStr)
            }
        }
        return out
    }

    // MARK: - upload page

private func pageHtml() -> String {
        let port = port
        let pathPrefix = Self.pathPrefix
        let addr = localIPv4Addresses().first ?? "localhost"
        // Embed credentials in download URLs so external download managers
        // (which don't carry the browser's Basic-auth cache) still authenticate.
        // Anyone who loaded this page already knows them.
        let authInfo: String
        if !authUser.isEmpty && !authPass.isEmpty {
            let u = authUser.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? authUser
            let p = authPass.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? authPass
            authInfo = "\(u):\(p)@"
        } else {
            authInfo = ""
        }
        var html = ""
        html += "<!DOCTYPE html>\n"
        html += "<html lang=\"en\">\n"
        html += "<head>\n"
        html += "<meta charset=\"utf-8\">\n"
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        html += "<title>DreamPlayer - WiFi file transfer</title>\n"
        html += "<style>\n"
        html += "  :root { color-scheme: dark; }\n"
        html += "  * { box-sizing: border-box; }\n"
        html += "  body { margin: 0; min-height: 100vh; background: #0e0e11; color: #e8e8ec;\n"
        html += "         font-family: system-ui, -apple-system, sans-serif; }\n"
        html += "  .page { width: min(620px, 100%); margin: 0 auto; padding: 40px 20px 56px; }\n"
        html += "  header { display: flex; align-items: center; gap: 14px; margin-bottom: 22px; }\n"
        html += "  .logo { flex: none; }\n"
        html += "  .logo img { display: block; width: 46px; height: 46px; border-radius: 13px; }\n"
        html += "  h1 { font-size: 20px; margin: 0; letter-spacing: -0.01em; }\n"
        html += "  header p { margin: 2px 0 0; font-size: 13px; color: #9a9aa5; }\n"
        html += "  .card { background: #17171d; border: 1px solid #26262e; border-radius: 18px; padding: 22px; }\n"
        html += "  .addr-label { margin: 0 0 6px; font-size: 11px; letter-spacing: 0.08em;\n"
        html += "                text-transform: uppercase; color: #9a9aa5; }\n"
        html += "  .addr { margin: 0 0 18px; font-size: 15px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;\n"
        html += "          color: #e8e8ec; word-break: break-all; }\n"
        html += "  .drop { display: block; border: 2px dashed #4b3e76; border-radius: 14px; padding: 30px 18px;\n"
        html += "          text-align: center; cursor: pointer; transition: border-color .15s, background .15s; }\n"
        html += "  .drop:hover, .drop.over { border-color: #7c4dff; background: rgba(124, 77, 255, 0.07); }\n"
        html += "  .drop .icon { font-size: 26px; line-height: 1; }\n"
        html += "  .drop .title { margin-top: 10px; font-size: 15px; font-weight: 600; }\n"
        html += "  .drop .hint { margin-top: 3px; font-size: 13px; color: #9a9aa5; }\n"
        html += "  input[type=file] { display: none; }\n"
        html += "  ul { list-style: none; padding: 0; margin: 18px 0 0; }\n"
        html += "  ul:empty { margin: 0; }\n"
        html += "  li { background: #1e1e26; border-radius: 11px; padding: 11px 13px; margin-bottom: 8px; }\n"
        html += "  li:last-child { margin-bottom: 0; }\n"
        html += "  li .row { display: flex; align-items: baseline; gap: 12px; }\n"
        html += "  li .nm { flex: 1; min-width: 0; font-size: 14px; overflow: hidden;\n"
        html += "           text-overflow: ellipsis; white-space: nowrap; }\n"
        html += "  li .sz { flex: none; font-size: 12px; color: #9a9aa5; font-variant-numeric: tabular-nums; }\n"
        html += "  li .bar { height: 6px; border-radius: 3px; background: #26262e; margin-top: 9px; overflow: hidden; }\n"
        html += "  li .bar > div { height: 100%; width: 0%; background: #7c4dff; border-radius: 3px;\n"
        html += "                  transition: width .15s; }\n"
        html += "  li.done .bar > div { background: #7ee2a8; }\n"
        html += "  li.done .nm { color: #7ee2a8; }\n"
        html += "  li.err .nm { color: #ff8a80; }\n"
        html += "  .actions { display: flex; gap: 8px; margin-top: 16px; align-items: stretch; }\n"
        html += "  .actions button { flex: 1 1 0; min-width: 0; padding: 10px 14px; border-radius: 11px;\n"
        html += "                    border: 1px solid #3a3a46; background: #1e1e26; color: #e8e8ec;\n"
        html += "                    font: inherit; font-size: 13px; cursor: pointer; transition: background .15s, color .15s; }\n"
        html += "  .actions button:hover { background: #2a2a33; color: #fff; }\n"
        html += "  .actions .cancel { color: #ff8a80; border-color: #3a2a2a; }\n"
        html += "  .actions .cancel:hover { background: #3a2a2a; color: #ffb3b3; border-color: #ff8a80; }\n"
        html += "  .actions .clear { color: #9a9aa5; border-color: #3a3a46; }\n"
        html += "  .actions .clear:hover { color: #e8e8ec; border-color: #666; }\n"
        html += "  .recvdir { width: 100%; margin: 4px 0 12px; padding: 11px 14px; border-radius: 11px;\n"
        html += "             border: 1px solid #7c4dff; background: #241d3d; color: #e8e8ec;\n"
        html += "             font: inherit; font-size: 13px; font-weight: 600; cursor: pointer; }\n"
        html += "  .recvdir:hover { background: #2e2650; color: #fff; }\n"
        html += "  .authwarn { margin-top: 16px; padding: 12px 14px; border-radius: 11px;\n"
        html += "              border: 1px solid #7a3b2e; background: #3a2320; color: #ffb4a8;\n"
        html += "              font-size: 13px; line-height: 1.5; }\n"
        html += "  .authwarn button { margin-top: 8px; }\n"
        html += "  .foot { margin: 18px 0 0; font-size: 12px; line-height: 1.5; color: #6a6a75; text-align: center; }\n"
        html += "</style>\n"
        html += "</head>\n"
        html += "<body>\n"
        html += "<div class=\"page\">\n"
        html += "  <header>\n"
        html += "    <div class=\"logo\"><img src=\"data:image/png;base64,\(logoBase64)\" alt=\"DreamPlayer\"></div>\n"
        html += "    <div>\n"
        html += "      <h1>DreamPlayer</h1>\n"
        html += "      <p>WiFi file transfer</p>\n"
        html += "    </div>\n"
        html += "  </header>\n"
        html += "  <div class=\"card\">\n"
        html += "    <p class=\"addr-label\" style=\"display:flex;align-items:center;gap:8px;\">\n"
        html += "      <span style=\"width:8px;height:8px;border-radius:50%;background:#7ee2a8;display:inline-block;\"></span>\n"
        html += "      Online on port <span style=\"font-weight:600;\">\(port)</span>\n"
        html += "    </p>\n"
        html += "    <p class=\"addr\" id=\"addr\" style=\"margin:10px 0;\">http://\(addr):\(port)\(pathPrefix)/</p>\n"
        html += "    <label class=\"drop\" id=\"drop\">\n"
        html += "      <div class=\"icon\">&#8593;</div>\n"
        html += "      <div class=\"title\">Click to choose videos</div>\n"
        html += "      <div class=\"hint\">or drop them here</div>\n"
        html += "      <input type=\"file\" id=\"files\" multiple accept=\"video/*,.mkv,.mp4,.avi,.ts,.m2ts,.webm,.wmv,.flv,.mpg,.mpeg,.vob,.mov,.m4v,.3gp,.ogv,.rmvb,.divx\">\n"
        html += "    </label>\n"
        html += "    <ul id=\"list\"></ul>\n"
        html += "    <div class=\"actions\">\n"
        html += "      <button class=\"cancel\" id=\"cancel\" type=\"button\">&#10006; Cancel transfers</button>\n"
        html += "      <button class=\"clear\" id=\"clear\" type=\"button\">&#128465; Clear list</button>\n"
        html += "    </div>\n"
        html += "  </div>\n"
        html += "  <div class=\"authwarn\" id=\"authWarn\" style=\"display:none;\">\n"
        html += "    <strong>Not signed in.</strong> The server rejected the saved login (the password\n"
        html += "    may have changed in the app). Sign in again, then send the files from your phone.\n"
        html += "    <br><button class=\"recvdir\" id=\"loginAgain\" type=\"button\">Log in again</button>\n"
        html += "  </div>\n"
        html += "  <div class=\"card\" id=\"deviceFilesCard\" style=\"margin-top:16px;\">\n"
        html += "    <p class=\"addr-label\" style=\"margin:0 0 10px;\">&#8595; Receive from your phone</p>\n"
        html += "    <p class=\"hint\" id=\"recvStatus\">Waiting for files. Tap Send files on your phone.</p>\n"
        html += "    <button class=\"recvdir\" id=\"recvDir\" type=\"button\" style=\"display:none;\">Choose folder to save into</button>\n"
        html += "    <ul id=\"deviceFiles\"></ul>\n"
        html += "  </div>\n"
        html += "  <p class=\"foot\">Files you send from the phone arrive here automatically: into the folder you\n"
        html += "     pick, or as one zip archive in your Downloads folder on browsers without a folder picker.\n"
        html += "     Files you upload on this page land in the phone's download folder and appear in DreamPlayer.\n"
        html += "     The page is reachable while the transfer service is on in the app, even when the screen is locked.</p>\n"
        html += "</div>\n"
        html += "<script>\n"
        html += "(function () {\n"
        html += "  var drop = document.getElementById('drop');\n"
        html += "  var input = document.getElementById('files');\n"
        html += "  var list = document.getElementById('list');\n"
        html += "  var addrEl = document.getElementById('addr');\n"
        html += "  var cancelBtn = document.getElementById('cancel');\n"
        html += "  var clearBtn = document.getElementById('clear');\n"
        html += "  var deviceFilesCard = document.getElementById('deviceFilesCard');\n"
        html += "  var deviceFilesList = document.getElementById('deviceFiles');\n"
        html += "  var pending = [];\n"
        html += "  // Refresh the address from the server's own view of the LAN (handles a\n"
        html += "  // Wi-Fi change between page render and open)\n"
        html += "  fetch('\(pathPrefix)/health', {credentials: 'include'}).then(function (r) { return r.json(); }).then(function (s) {\n"
        html += "    if (s.addresses && s.addresses.length) {\n"
        html += "      addrEl.textContent = 'http://' + s.addresses[0] + ':' + s.port + '\(pathPrefix)/';\n"
        html += "    }\n"
        html += "  }).catch(function () {});\n"
        html += "\n"
        html += "  // Receive station: the phone PUSHES to this page - there is nothing to\n"
        html += "  // click here. The moment the phone sends files or a folder, this page\n"
        html += "  // starts saving them itself. The destination folder is chosen once\n"
        html += "  // (Chromium's directory picker); other browsers fall back to their own\n"
        html += "  // downloads folder, so a large video is always streamed to disk rather\n"
        html += "  // than held in memory.\n"
        html += "  var recvStatus = document.getElementById('recvStatus');\n"
        html += "  var recvDirBtn = document.getElementById('recvDir');\n"
        html += "  var authWarn = document.getElementById('authWarn');\n"
        html += "  function showAuthWarn(on) {\n"
        html += "    authWarn.style.display = on ? 'block' : 'none';\n"
        html += "    if (on) recvDirBtn.style.display = 'none';\n"
        html += "  }\n"
        html += "  document.getElementById('loginAgain').addEventListener('click', function () { location.reload(); });\n"
        html += "  var fsSupported = typeof window.showDirectoryPicker === 'function';\n"
        html += "  var destRoot = null;\n"
        html += "  var destName = 'your Downloads folder';\n"
        html += "  var receiving = false;\n"
        html += "  var doneKey = null, doneSeq = -1;\n"
        html += "  var announcedSeq = -1;\n"
        html += "  try {\n"
        html += "    var savedRecv = localStorage.getItem('dp.received');\n"
        html += "    if (savedRecv) {\n"
        html += "      var savedParts = savedRecv.split('|');\n"
        html += "      doneKey = savedParts[0];\n"
        html += "      doneSeq = parseInt(savedParts[1] || '-1', 10);\n"
        html += "    }\n"
        html += "  } catch (e) {}\n"
        html += "  function fmtBytes(b) {\n"
        html += "    if (!b) return '';\n"
        html += "    var u = ['B','KB','MB','GB','TB'], i = 0;\n"
        html += "    while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }\n"
        html += "    return b.toFixed(b < 10 && i > 0 ? 1 : 0) + ' ' + u[i];\n"
        html += "  }\n"
        html += "  function fileUrl(name) {\n"
        html += "    return location.protocol + '//' + '\(authInfo)' + location.host + '\(pathPrefix)/file?name=' + encodeURIComponent(name);\n"
        html += "  }\n"
        html += "  function setStatus(t) { recvStatus.textContent = t; }\n"
        html += "  function renderRows(files) {\n"
        html += "    deviceFilesList.innerHTML = '';\n"
        html += "    files.forEach(function (f) {\n"
        html += "      var li = document.createElement('li');\n"
        html += "      var row = document.createElement('div');\n"
        html += "      row.className = 'row';\n"
        html += "      var nm = document.createElement('span');\n"
        html += "      nm.className = 'nm';\n"
        html += "      nm.textContent = f.name;\n"
        html += "      var sz = document.createElement('span');\n"
        html += "      sz.className = 'sz';\n"
        html += "      sz.textContent = fmtBytes(f.size);\n"
        html += "      row.appendChild(nm); row.appendChild(sz);\n"
        html += "      var bar = document.createElement('div');\n"
        html += "      bar.className = 'bar';\n"
        html += "      bar.appendChild(document.createElement('div'));\n"
        html += "      li.appendChild(row); li.appendChild(bar);\n"
        html += "      deviceFilesList.appendChild(li);\n"
        html += "    });\n"
        html += "  }\n"
        html += "  function markRow(i, cls) {\n"
        html += "    var li = deviceFilesList.children[i];\n"
        html += "    if (li) li.className = cls;\n"
        html += "  }\n"
        html += "  function setBar(i, frac) {\n"
        html += "    var li = deviceFilesList.children[i];\n"
        html += "    if (!li) return;\n"
        html += "    var fill = li.querySelector('.bar > div');\n"
        html += "    if (fill) fill.style.width = Math.round(frac * 100) + '%';\n"
        html += "  }\n"
        html += "  function loadDeviceFiles() {\n"
        html += "    fetch('\(pathPrefix)/files', {credentials: 'include', cache: 'no-store'}).then(function (r) {\n"
        html += "      // A 401 means the saved login was rejected (e.g. the password\n"
        html += "      // changed in the app). fetch() never raises the browser auth\n"
        html += "      // popup - say so visibly instead of failing silently.\n"
        html += "      if (r.status === 401) { showAuthWarn(true); return null; }\n"
        html += "      showAuthWarn(false);\n"
        html += "      return r.json();\n"
        html += "    }).then(function (data) {\n"
        html += "      if (!data) return;\n"
        html += "      var files = (data && data.files) || [];\n"
        html += "      deviceFilesCard.style.display = 'block';\n"
        html += "      if (!files.length) {\n"
        html += "        deviceFilesList.innerHTML = '';\n"
        html += "        recvDirBtn.style.display = 'none';\n"
        html += "        setStatus('Waiting for files. Tap Send files on your phone.');\n"
        html += "        return;\n"
        html += "      }\n"
        html += "      if (receiving) return;\n"
        html += "      var key = (data && data.runId) || '';\n"
        html += "      var seq = (data && data.seq) || 0;\n"
        html += "      if (key === doneKey && seq <= doneSeq) {\n"
        html += "        // Say this ONCE. The 1s poll used to repeat it, which overwrote the\n"
        html += "        // \"Saved N files to <folder>\" line the moment it appeared - so a finished\n"
        html += "        // send read as \"already saved\", i.e. as nothing happening.\n"
        html += "        if (announcedSeq !== seq) {\n"
        html += "          announcedSeq = seq;\n"
        html += "          setStatus(files.length + (files.length === 1 ? ' file' : ' files') + ' already saved');\n"
        html += "        }\n"
        html += "        return;\n"
        html += "      }\n"
        html += "      if (fsSupported && !destRoot) {\n"
        html += "        recvDirBtn.style.display = '';\n"
        html += "        recvDirBtn.textContent = 'Receive ' + files.length + (files.length === 1 ? ' file' : ' files') + ' into a folder';\n"
        html += "        setStatus(files.length + (files.length === 1 ? ' file is' : ' files are') + ' ready');\n"
        html += "        return;\n"
        html += "      }\n"
        html += "      receive(files, key, seq);\n"
        html += "    }).catch(function () {});\n"
        html += "  }\n"
        html += "  async function saveWithFs(f, i) {\n"
        html += "    try {\n"
        html += "      var parts = f.name.split('/').filter(function (p) { return p.length > 0; });\n"
        html += "      if (!parts.length) return false;\n"
        html += "      var dir = destRoot;\n"
        html += "      for (var j = 0; j < parts.length - 1; j++) {\n"
        html += "        dir = await dir.getDirectoryHandle(parts[j], {create: true});\n"
        html += "      }\n"
        html += "      var fh = await dir.getFileHandle(parts[parts.length - 1], {create: true});\n"
        html += "      var w = await fh.createWritable();\n"
        html += "      var resp = await fetch(fileUrl(f.name), {credentials: 'include'});\n"
        html += "      if (resp.status === 401) { showAuthWarn(true); throw new Error('login required'); }\n"
        html += "      if (!resp.ok) throw new Error('http ' + resp.status);\n"
        html += "      var total = parseInt(resp.headers.get('content-length') || '0', 10) || 0;\n"
        html += "      var got = 0;\n"
        html += "      var reader = resp.body.getReader();\n"
        html += "      for (;;) {\n"
        html += "        var r = await reader.read();\n"
        html += "        if (r.done) break;\n"
        html += "        got += r.value.length;\n"
        html += "        setBar(i, total > 0 ? got / total : 0.5);\n"
        html += "        await w.write(r.value);\n"
        html += "      }\n"
        html += "      await w.close();\n"
        html += "      setBar(i, 1);\n"
        html += "      return true;\n"
        html += "    } catch (e) {\n"
        html += "      return false;\n"
        html += "    }\n"
        html += "  }\n"
        html += "  function saveWithDownload(f, i) {\n"
        html += "    // No directory picker here (Firefox/Safari), single file: let the\n"
        html += "    // browser's own downloader take it, so a large video streams to disk\n"
        html += "    // instead of being buffered in the page.\n"
        html += "    var a = document.createElement('a');\n"
        html += "    a.href = fileUrl(f.name);\n"
        html += "    a.download = f.name.split('/').pop();\n"
        html += "    a.style.display = 'none';\n"
        html += "    document.body.appendChild(a);\n"
        html += "    a.click();\n"
        html += "    setTimeout(function () { a.remove(); }, 60000);\n"
        html += "    setBar(i, 1);\n"
        html += "    return true;\n"
        html += "  }\n"
        html += "  function zipUrl() {\n"
        html += "    return location.protocol + '//' + '\(authInfo)' + location.host + '\(pathPrefix)/files.zip';\n"
        html += "  }\n"
        html += "  function zipName() {\n"
        html += "    // PairDrop names its client-side archive the same way.\n"
        html += "    var d = new Date();\n"
        html += "    function p(n) { return (n < 10 ? '0' : '') + n; }\n"
        html += "    return 'DreamPlayer_files_' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) +\n"
        html += "           '_' + p(d.getHours()) + p(d.getMinutes()) + '.zip';\n"
        html += "  }\n"
        html += "  function saveZip(files) {\n"
        html += "    // ONE archive for the whole batch (PairDrop zips the same way): the\n"
        html += "    // server streams a single store-only zip, so the browser's \"this site\n"
        html += "    // wants to download multiple files\" prompt never fires and the folder\n"
        html += "    // structure travels inside the archive.\n"
        html += "    var a = document.createElement('a');\n"
        html += "    a.href = zipUrl();\n"
        html += "    a.download = zipName();\n"
        html += "    a.style.display = 'none';\n"
        html += "    document.body.appendChild(a);\n"
        html += "    a.click();\n"
        html += "    setTimeout(function () { a.remove(); }, 60000);\n"
        html += "    for (var i = 0; i < files.length; i++) { setBar(i, 1); markRow(i, 'done'); }\n"
        html += "    return true;\n"
        html += "  }\n"
        html += "  async function receive(files, key, seq) {\n"
        html += "    receiving = true;\n"
        html += "    announcedSeq = seq;\n"
        html += "    renderRows(files);\n"
        html += "    recvDirBtn.style.display = 'none';\n"
        html += "    var dest = destName;\n"
        html += "    if (!destRoot && files.length > 1) {\n"
        html += "      // No directory picker (Firefox/Safari) and more than one file: take\n"
        html += "      // the whole batch as ONE zip instead of N separate downloads.\n"
        html += "      setStatus('Receiving ' + files.length + ' files as one archive');\n"
        html += "      saveZip(files);\n"
        html += "      dest = 'your Downloads folder (one archive)';\n"
        html += "    } else {\n"
        html += "      for (var i = 0; i < files.length; i++) {\n"
        html += "        var f = files[i];\n"
        html += "        setStatus('Receiving ' + (i + 1) + ' of ' + files.length + ' - ' + f.name);\n"
        html += "        var ok = destRoot ? await saveWithFs(f, i) : false;\n"
        html += "        if (!ok) { ok = await Promise.resolve(saveWithDownload(f, i)); dest = 'your Downloads folder'; }\n"
        html += "        markRow(i, ok ? 'done' : 'err');\n"
        html += "      }\n"
        html += "    }\n"
        html += "    receiving = false;\n"
        html += "    doneKey = key;\n"
        html += "    doneSeq = seq;\n"
        html += "    try { localStorage.setItem('dp.received', key + '|' + seq); } catch (e) {}\n"
        html += "    setStatus('Saved ' + files.length + (files.length === 1 ? ' file' : ' files') + ' to ' + dest);\n"
        html += "  }\n"
        html += "  function chooseDest() {\n"
        html += "    if (!fsSupported) return;\n"
        html += "    window.showDirectoryPicker({mode: 'readwrite'}).then(function (h) {\n"
        html += "      destRoot = h;\n"
        html += "      destName = h.name;\n"
        html += "      recvDirBtn.style.display = 'none';\n"
        html += "      setStatus('Ready - receiving into \"' + h.name + '\"');\n"
        html += "      loadDeviceFiles();\n"
        html += "    }).catch(function () {});\n"
        html += "  }\n"
        html += "  recvDirBtn.addEventListener('click', chooseDest);\n"
        html += "  loadDeviceFiles();\n"
        html += "  setInterval(loadDeviceFiles, 1000);\n"
        html += "\n"
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
        html += "    li.setAttribute('data-name', file.name);\n"
        html += "    var nm = document.createElement('span');\n"
        html += "    nm.className = 'nm';\n"
        html += "    nm.textContent = file.name;\n"
        html += "    var sz = document.createElement('span');\n"
        html += "    sz.className = 'sz';\n"
        html += "    var row = document.createElement('div');\n"
        html += "    row.className = 'row';\n"
        html += "    row.appendChild(nm);\n"
        html += "    row.appendChild(sz);\n"
        html += "    var bar = document.createElement('div');\n"
        html += "    bar.className = 'bar';\n"
        html += "    var fill = document.createElement('div');\n"
        html += "    bar.appendChild(fill);\n"
        html += "    li.appendChild(row);\n"
        html += "    li.appendChild(bar);\n"
        html += "    var xhr = new XMLHttpRequest();\n"
        html += "    pending.push(xhr);\n"
        html += "    list.appendChild(li);\n"
        html += "    xhr.open('POST', '\(pathPrefix)/upload?name=' + encodeURIComponent(file.name));\n"
        html += "    xhr.upload.onprogress = function (e) {\n"
        html += "      if (e.lengthComputable) {\n"
        html += "        fill.style.width = (e.loaded / e.total * 100).toFixed(1) + '%';\n"
        html += "        sz.textContent = (e.loaded / 1048576).toFixed(1) + ' / ' +\n"
        html += "          (e.total / 1048576).toFixed(1) + ' MB';\n"
        html += "      }\n"
        html += "    };\n"
        html += "    xhr.onload = function () {\n"
        html += "      if (xhr.status === 200) {\n"
        html += "        li.classList.add('done');\n"
        html += "        nm.textContent = '\\u2713 ' + file.name;\n"
        html += "        fill.style.width = '100%';\n"
        html += "        sz.textContent = 'Saved';\n"
        html += "      } else {\n"
        html += "        li.classList.add('err');\n"
        html += "        if (xhr.status === 401) { showAuthWarn(true); nm.textContent = '\\u2717 ' + file.name + ' (login required)'; }\n"
        html += "        else { nm.textContent = '\\u2717 ' + file.name + ' (HTTP ' + xhr.status + ')'; }\n"
        html += "      }\n"
        html += "    };\n"
        html += "    xhr.onerror = function () {\n"
        html += "      li.classList.add('err');\n"
        html += "      nm.textContent = '\\u2717 ' + file.name + ' (network error)';\n"
        html += "    };\n"
        html += "    xhr.send(file);\n"
        html += "  }\n"
        html += "\n"
        html += "  function markCancelled() {\n"
        html += "    Array.prototype.forEach.call(list.children, function (li) {\n"
        html += "      if (li.classList.contains('done') || li.classList.contains('err')) return;\n"
        html += "      li.classList.add('err');\n"
        html += "      li.querySelector('.nm').textContent = '\\u2717 ' + li.getAttribute('data-name') + ' (cancelled)';\n"
        html += "      li.querySelector('.bar > div').style.width = '100%';\n"
        html += "      var sz = li.querySelector('.sz');\n"
        html += "      if (sz) sz.textContent = '';\n"
        html += "    });\n"
        html += "  }\n"
        html += "\n"
        html += "  // Cancel transfers: abort in-flight XHRs and tell the server to drop its\n"
        html += "  // side too (partial files are deleted). Keeps done/failed rows as-is.\n"
        html += "  cancelBtn.addEventListener('click', function () {\n"
        html += "    pending.forEach(function (x) { try { x.abort(); } catch (e) {} });\n"
        html += "    pending = [];\n"
        html += "    markCancelled();\n"
        html += "    var r = new XMLHttpRequest();\n"
        html += "    r.open('POST', '\(pathPrefix)/cancel');\n"
        html += "    r.send();\n"
        html += "  });\n"
        html += "\n"
        html += "  // Clear list: remove every row from the UI and abort anything still in\n"
        html += "  // flight.\n"
        html += "  clearBtn.addEventListener('click', function () {\n"
        html += "    pending.forEach(function (x) { try { x.abort(); } catch (e) {} });\n"
        html += "    pending = [];\n"
        html += "    markCancelled();\n"
        html += "    while (list.firstChild) list.removeChild(list.firstChild);\n"
        html += "  });\n"
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

