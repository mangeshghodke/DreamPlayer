import Flutter
import Foundation
import Security
import AetherEngineSMB

/// iOS WebDAV client (channel `dreamplayer/webdav`), mirroring `WebDAVClient.kt`.
///
/// Browsing is `PROPFIND` over URLSession; playback is a plain HTTP GET with
/// byte ranges served to the engine as a custom `ByteRangeSource` (wrapped by
/// `BufferedSMBReader`), so auth headers AND per-server self-signed HTTPS work
/// end to end (AetherEngine's own HTTP stack cannot bypass TLS validation).
///
/// Saved servers (name + base URL + credentials) are stored in UserDefaults;
/// passwords go to the Keychain and never cross to Dart — only `hasPassword`
/// is exposed, and Dart asks for the ready-made `Authorization` header via
/// `authorizationHeader`.
final class WebDAVClient: NSObject {

    static let shared = WebDAVClient()
    private static let channelName = "dreamplayer/webdav"

    private static let serversKey = "dreamplayer.webdavServers"
    private static let keychainService = "com.dreamplayer.app.webdav"
    private static let keychainAccountPrefix = "password."

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
        "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
            "strm", "m3u", "m3u8",
    ]

    // MARK: - Networking

    /// Default-trust session (system certificate store).
    private let standardSession: URLSession

    /// Trust-everything session, used ONLY for servers the user explicitly
    /// marked "Accept self-signed certificates".
    private let permissiveDelegate = PermissiveTrustDelegate()
    private let permissiveSession: URLSession

    private override init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        standardSession = URLSession(configuration: config)
        permissiveSession = URLSession(configuration: config, delegate: permissiveDelegate, delegateQueue: nil)
        super.init()
    }

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
    }

    /// A seekable byte source over [url] with [headers] (Basic auth) that
    /// serves engine reads via HTTP Range requests. Self-signed HTTPS
    /// ([allowSelfSigned]) uses the permissive session. Throws when the server
    /// doesn't answer a size probe.
    func makeByteRangeSource(
        url: URL,
        headers: [String: String],
        allowSelfSigned: Bool
    ) throws -> WebDAVByteRangeSource {
        try WebDAVByteRangeSource(
            url: url,
            headers: headers,
            session: allowSelfSigned ? permissiveSession : standardSession
        )
    }

    // MARK: - Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "saveServer":
            result(saveServer(
                id: args?["id"] as? String,
                name: args?["name"] as? String ?? "",
                url: args?["url"] as? String ?? "",
                username: args?["username"] as? String ?? "",
                password: args?["password"] as? String ?? "",
                allowSelfSigned: args?["allowSelfSigned"] as? Bool ?? false
            ))
        case "listServers":
            result(listServers())
        case "deleteServer":
            if let id = args?["id"] as? String { deleteServer(id) }
            result(nil)
        case "testConnection":
            let url = args?["url"] as? String ?? ""
            let username = args?["username"] as? String ?? ""
            let password = args?["password"] as? String ?? ""
            let allowSelfSigned = args?["allowSelfSigned"] as? Bool ?? false
            Task.detached { [weak self] in
                let r = await self?.testConnection(url: url, username: username, password: password, allowSelfSigned: allowSelfSigned)
                    ?? ["ok": false, "error": "Connection failed"]
                self?.respond(result, r)
            }
        case "listDirectory":
            guard let id = args?["id"] as? String, let server = serverById(id) else {
                respond(result, FlutterError(code: "bad_args", message: "WebDAV server not found", details: nil))
                return
            }
            let path = args?["path"] as? String ?? "/"
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let entries = try await self.listDirectory(server: server, path: path)
                    self.respond(result, entries)
                } catch {
                    self.respond(result, FlutterError(code: "webdav", message: self.friendlyError(error), details: nil))
                }
            }
        case "authorizationHeader":
            if let id = args?["id"] as? String, let server = serverById(id) {
                result(server.authorizationHeader)
            } else {
                result(FlutterError(code: "bad_args", message: "WebDAV server not found", details: nil))
            }
        case "fetchUrl":
            // Authenticated GET returning body bytes on HTTP 200 (nil otherwise).
            // Used to probe + download sidecar subtitle URLs, mirroring the
            // Android `fetchUrl`. Resolves the saved server by `id` when given
            // (password stays native); otherwise uses the caller's headers /
            // self-signed flag for generic http(s) sources.
            let url = args?["url"] as? String ?? ""
            guard !url.isEmpty else {
                respond(result, FlutterError(code: "bad_args", message: "Missing url", details: nil))
                return
            }
            let server = (args?["id"] as? String).flatMap { serverById($0) }
            let headers = (args?["headers"] as? [String: String]) ?? [:]
            let allowSelfSigned = (args?["allowSelfSigned"] as? Bool) ?? false
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let bytes = try await self.fetch(url: url,
                                                     server: server,
                                                     extraHeaders: headers,
                                                     allowSelfSigned: allowSelfSigned)
                    if let bytes {
                        self.respond(result, FlutterStandardTypedData(bytes: bytes))
                    } else {
                        self.respond(result, nil)
                    }
                } catch {
                    self.respond(result, FlutterError(code: "webdav", message: self.friendlyError(error), details: nil))
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Authenticated GET: returns body bytes on HTTP 200, nil on any other
    /// status (404/403/5xx) so the caller treats a miss as "no sidecar".
    private func fetch(url: String, server: Server?, extraHeaders: [String: String], allowSelfSigned: Bool) async throws -> Data? {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: u)
        request.httpMethod = "GET"
        if let server {
            // Saved-server credentials never cross to Dart — build auth natively.
            request.setValue(server.authorizationHeader, forHTTPHeaderField: "Authorization")
            for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
            let session = server.allowSelfSigned ? permissiveSession : standardSession
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        } else {
            for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
            let session = allowSelfSigned ? permissiveSession : standardSession
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
    }

    /// `FlutterResult` must be called on the main thread; networking runs on
    /// background tasks.
    private func respond(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    // MARK: - Server persistence

    private struct Server {
        let id: String
        let name: String
        let url: String
        let username: String
        let password: String
        let allowSelfSigned: Bool

        var authorizationHeader: String {
            let raw = "\(username):\(password)"
            return "Basic \(Data(raw.utf8).base64EncodedString())"
        }

        func toMap() -> [String: Any] {
            [
                "id": id,
                "name": name,
                "url": url,
                "username": username,
                "hasPassword": !password.isEmpty,
                "allowSelfSigned": allowSelfSigned,
            ]
        }
    }

    private func loadServersMeta() -> [String: [String: Any]] {
        UserDefaults.standard.dictionary(forKey: Self.serversKey) as? [String: [String: Any]] ?? [:]
    }

    private func saveServersMeta(_ servers: [String: [String: Any]]) {
        UserDefaults.standard.set(servers, forKey: Self.serversKey)
    }

    private func saveServer(
        id: String?,
        name: String,
        url: String,
        username: String,
        password: String,
        allowSelfSigned: Bool
    ) -> [String: Any] {
        let serverId = id ?? UUID().uuidString
        let cleanUrl = url.trimmingCharacters(in: .whitespacesAndNewlines).trimTrailingSlash
        var servers = loadServersMeta()
        servers[serverId] = [
            "name": name,
            "url": cleanUrl,
            "username": username,
            "allowSelfSigned": allowSelfSigned,
        ]
        saveServersMeta(servers)
        if !password.isEmpty {
            setPassword(password, for: serverId)
        } else if id == nil {
            setPassword("", for: serverId)
        }
        return serverById(serverId)?.toMap() ?? [:]
    }

    private func serverById(_ id: String) -> Server? {
        guard let meta = loadServersMeta()[id] else { return nil }
        return Server(
            id: id,
            name: meta["name"] as? String ?? "",
            url: meta["url"] as? String ?? "",
            username: meta["username"] as? String ?? "",
            password: getPassword(id),
            allowSelfSigned: meta["allowSelfSigned"] as? Bool ?? false
        )
    }

    private func listServers() -> [[String: Any]] {
        loadServersMeta().keys.sorted().compactMap { serverById($0)?.toMap() }
    }

    private func deleteServer(_ id: String) {
        var servers = loadServersMeta()
        servers.removeValue(forKey: id)
        saveServersMeta(servers)
        deletePassword(id)
    }

    // MARK: - Keychain (passwords never touch UserDefaults or Dart)

    private func setPassword(_ password: String, for id: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccountPrefix + id,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func getPassword(_ id: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccountPrefix + id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func deletePassword(_ id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccountPrefix + id,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - WebDAV protocol

    private func testConnection(
        url: String,
        username: String,
        password: String,
        allowSelfSigned: Bool
    ) async -> [String: Any] {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines).trimTrailingSlash
        guard !clean.isEmpty else { return ["ok": false, "error": "URL is required"] }
        let probe = clean + "/"
        do {
            let (_, response) = try await webdavRequest(
                url: probe, username: username, password: password,
                depth: 0, allowSelfSigned: allowSelfSigned
            )
            let code = response.statusCode
            // 207 (Multi-Status) is the success code for PROPFIND.
            if code == 207 || code == 200 { return ["ok": true] }
            if code == 404 {
                // PROPFIND on a bare host/port with no dav root -> 404; a GET
                // probe distinguishes "server up but no dav here".
                let (_, r2) = try await webdavRequest(
                    url: probe, username: username, password: password,
                    depth: 0, allowSelfSigned: allowSelfSigned, method: "GET"
                )
                if (200...399).contains(r2.statusCode) { return ["ok": true] }
                return ["ok": false, "error": "HTTP \(r2.statusCode)"]
            }
            return ["ok": false, "error": "HTTP \(code)"]
        } catch {
            return ["ok": false, "error": friendlyError(error)]
        }
    }

    private func listDirectory(server: Server, path: String) async throws -> [[String: Any]] {
        let base = server.url.trimTrailingSlash
        let root = path == "/" || path.isEmpty
        // Always request slash-terminated directory URLs so roots/proxies don't
        // 301-redirect (Location rewriting can drop the port/scheme).
        let requestUrl = root ? base + "/" : (base + path).trimTrailingSlash + "/"
        let (data, response) = try await webdavRequest(
            url: requestUrl, username: server.username, password: server.password,
            depth: 1, allowSelfSigned: server.allowSelfSigned
        )
        let code = response.statusCode
        guard code == 207 || code == 200 else { throw WebDAVError(message: "HTTP \(code)") }
        let basePath = URL(string: base)?.path ?? ""
        return try parseMultistatus(data, basePath: basePath, requestedPath: root ? "/" : path)
    }

    /// Sends a WebDAV request (PROPFIND by default) with Basic auth and returns
    /// body + response. Never throws on HTTP status codes — only on transport
    /// errors, so callers inspect `.statusCode`.
    private func webdavRequest(
        url: String,
        username: String,
        password: String,
        depth: Int = 1,
        allowSelfSigned: Bool,
        method: String = "PROPFIND"
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method == "PROPFIND" {
            request.setValue("\(depth)", forHTTPHeaderField: "Depth")
        }
        if !username.isEmpty || !password.isEmpty {
            let raw = "\(username):\(password)"
            request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        let session = allowSelfSigned ? permissiveSession : standardSession
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Parses a `multistatus` (207) body into entry maps. `basePath` is the
    /// server root path; hrefs are normalized to paths relative to it.
    private func parseMultistatus(_ data: Data, basePath: String, requestedPath: String) throws -> [[String: Any]] {
        let parser = XMLParser(data: data)
        // WebDAV servers (Apache mod_dav, nginx, Nextcloud, Synology…) emit
        // prefixed elements (`<D:response xmlns:D="DAV:">`). With the default
        // `shouldProcessNamespaces = false`, Foundation reports `elementName`
        // as `"D:response"` (prefix included), so the local-name matches in
        // `MultistatusParser` never fire and the list silently comes back
        // empty. Turn on namespace processing to get `"response"`, `"href"`,
        // `"collection"` regardless of prefix.
        parser.shouldProcessNamespaces = true
        let delegate = MultistatusParser()
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw WebDAVError(message: "The server returned a response that could not be parsed: \(reason)")
        }
        var entries: [[String: Any]] = []
        for builder in delegate.builders {
            if let entry = entry(from: builder, basePath: basePath, requestedPath: requestedPath) {
                entries.append(entry)
            }
        }
        entries.sort { a, b in
            let da = a["isDirectory"] as? Bool ?? false
            let db = b["isDirectory"] as? Bool ?? false
            if da != db { return da }
            return (a["name"] as? String ?? "").lowercased() < (b["name"] as? String ?? "").lowercased()
        }
        return entries
    }

    private func entry(from builder: EntryBuilder, basePath: String, requestedPath: String) -> [String: Any]? {
        guard let href = builder.href, let url = URL(string: href) else { return nil }
        // URL.path is already percent-decoded (and keeps a literal `+` intact —
        // do NOT use URLComponents/removingPercentEncoding-style decoding that
        // would turn `+` into a space and 404 names like "224kbps + English").
        let decoded = url.path
        let relative: String
        if basePath.isEmpty {
            relative = decoded
        } else if decoded.hasPrefix(basePath) {
            relative = String(decoded.dropFirst(basePath.count))
        } else {
            relative = decoded
        }
        let rel = relative.isEmpty ? "/" : relative
        let normRequested = requestedPath.trimTrailingSlash
        if rel == "/" || rel == normRequested { return nil } // drop self
        let name = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/").last ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        if !builder.isCollection && !Self.videoExtensions.contains(ext) { return nil }
        return [
            "name": name,
            "path": rel,
            "isDirectory": builder.isCollection,
            "size": builder.contentLength,
        ]
    }

    /// Turns raw transport/SSL errors into messages a user can act on.
    private func friendlyError(_ error: Error) -> String {
        if let w = error as? WebDAVError { return w.message }
        if let ue = error as? URLError {
            switch ue.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "The server's certificate is not trusted. Turn on 'Accept self-signed certificate' if it uses a self-signed or private certificate."
            case .cannotFindHost, .dnsLookupFailed:
                return "Can't reach the host. Check the address and your network."
            case .cannotConnectToHost, .networkConnectionLost:
                return "Connection refused. Check the host, port, and that the server is running."
            case .timedOut:
                return "Timed out connecting to the server."
            case .notConnectedToInternet:
                return "No internet connection. Check your network."
            default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// Thrown for HTTP status codes the caller turns into a message.
private struct WebDAVError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Accepts every server trust challenge (self-signed HTTPS opt-in).
private final class PermissiveTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - ByteRangeSource for playback

/// Serves byte ranges of a WebDAV file over HTTP(S) as the engine's custom
/// `ByteRangeSource` (wrapped by `BufferedSMBReader` for read-ahead buffering).
/// Each read is an independent HTTP Range request, so concurrent readers
/// (demux + scrub) are safe. `close()` is a no-op — there is no persistent
/// connection; the session owns nothing per-source.
final class WebDAVByteRangeSource: ByteRangeSource, @unchecked Sendable {

    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    let size: Int64

    /// Probes the total size synchronously (Range: bytes=0-0). One LAN
    /// round-trip at open; the engine needs `byteSize` before its first read.
    init(url: URL, headers: [String: String], session: URLSession) throws {
        self.url = url
        self.headers = headers
        self.session = session
        self.size = try Self.probeSize(url: url, headers: headers, session: session)
    }

    var byteSize: Int64 { size }

    func read(at offset: Int64, length: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206 || http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func close() {}

    private static func probeSize(url: URL, headers: [String: String], session: URLSession) throws -> Int64 {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var resultSize: Int64 = -1
        var resultError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                resultError = error
            } else if let http = response as? HTTPURLResponse, let data {
                if http.statusCode == 206,
                   let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = Int64(range.components(separatedBy: "/").last ?? "") {
                    resultSize = total
                } else if http.statusCode == 200,
                          let length = http.value(forHTTPHeaderField: "Content-Length"),
                          let total = Int64(length) {
                    resultSize = total
                } else {
                    resultError = URLError(.badServerResponse)
                }
            } else {
                resultError = URLError(.badServerResponse)
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        if let resultError { throw resultError }
        guard resultSize > 0 else { throw URLError(.badServerResponse) }
        return resultSize
    }
}

// MARK: - Multistatus XML parsing

/// Accumulates `<response>` children from a PROPFIND multistatus body.
private final class EntryBuilder {
    var href: String?
    var isCollection = false
    var contentLength: Int64 = 0
}

private final class MultistatusParser: NSObject, XMLParserDelegate {
    var builders: [EntryBuilder] = []
    private var current: EntryBuilder?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "response" {
            current = EntryBuilder()
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href":
            current?.href = value
        case "collection":
            current?.isCollection = true
        case "getcontentlength":
            current?.contentLength = Int64(value) ?? 0
        case "response":
            if let entry = current {
                builders.append(entry)
                current = nil
            }
        default:
            break
        }
        text = ""
    }
}

private extension String {
    var trimTrailingSlash: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
