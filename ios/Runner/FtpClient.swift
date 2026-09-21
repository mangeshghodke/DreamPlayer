import AetherEngineSMB
import Citadel
import Flutter
import Foundation
import NIOCore

/// iOS FTP/SFTP client (channel `dreamplayer/ftp`), mirroring `FtpClient.kt`.
///
/// - Plain FTP over raw TCP (`Network.framework`): control connection +
///   PASV data channels, Unix/Windows LIST parsing, REST-offset reads.
/// - SFTP via [Citadel] (swift-nio-ssh): password auth, directory listing,
///   offset reads off one persistent file handle.
/// - Servers persist in UserDefaults; passwords in Keychain (never to Dart).
/// - Playback: `makeByteRangeSource(uri:)` builds an [FtpByteRangeSource]
///   wrapped by `BufferedSMBReader` in `AvPlayerView.open`, like WebDAV.
final class FtpClient: NSObject {

    static let shared = FtpClient()
    private static let channelName = "dreamplayer/ftp"

    private static let serversKey = "dreamplayer.ftpServers"
    private static let keychainService = "com.dreamplayer.app.ftp"
    private static let keychainAccountPrefix = "password."

    /// Same set as `VIDEO_EXTENSIONS` in FtpClient.kt.
    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
        "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
    ]

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
    }

    // MARK: - Channel

    private func log(_ msg: String) {
        Self.logStatic(msg)
    }

    /// Shared file+console logger (usable from static methods too).
    static func logStatic(_ msg: String) {
        NSLog("[FTP] %@", msg)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        log("handle \(call.method) args=\(args ?? [:])")
        switch call.method {
        case "saveServer":
            let r = saveServer(
                id: args?["id"] as? String,
                name: args?["name"] as? String ?? "",
                host: args?["host"] as? String ?? "",
                port: args?["port"] as? Int ?? 21,
                path: args?["path"] as? String ?? "/",
                username: args?["username"] as? String ?? "",
                password: args?["password"] as? String ?? "",
                isSftp: args?["isSftp"] as? Bool ?? false
            )
            log("saveServer → \(r)")
            result(r)
        case "listServers":
            let r = listServers()
            log("listServers → \(r.count) servers")
            result(r)
        case "deleteServer":
            if let id = args?["id"] as? String { deleteServer(id) }
            result(nil)
        case "testConnection":
            let host = args?["host"] as? String ?? ""
            let port = (args?["port"] as? NSNumber)?.intValue ?? (args?["port"] as? Int) ?? 21
            let path = args?["path"] as? String ?? "/"
            let username = args?["username"] as? String ?? ""
            let password = args?["password"] as? String ?? ""
            let isSftp = args?["isSftp"] as? Bool ?? false
            log("testConnection \(isSftp ? "SFTP" : "FTP") \(host):\(port) user=\(username) path=\(path)")
            Task {
                do {
                    try await Self.probe(
                        host: host, port: port, path: path,
                        username: username, password: password, isSftp: isSftp)
                    log("testConnection OK")
                    await MainActor.run { result(["ok": true]) }
                } catch {
                    let msg = Self.friendlyError(error)
                    log("testConnection FAILED: \(msg)")
                    await MainActor.run { result(["ok": false, "error": msg]) }
                }
            }
        case "listDirectory":
            let id = args?["id"] as? String
            let path = args?["path"] as? String ?? "/"
            log("listDirectory id=\(id ?? "nil") path=\(path)")
            Task {
                do {
                    guard let id else { throw FtpError.badRequest("Missing server id") }
                    let entries = try await Self.listDirectory(serverId: id, requestedPath: path)
                    log("listDirectory OK: \(entries.count) entries")
                    await MainActor.run { result(entries) }
                } catch {
                    let err = FlutterError(code: "ftp", message: Self.friendlyError(error), details: nil)
                    log("listDirectory FAILED: \(Self.friendlyError(error))")
                    await MainActor.run { result(err) }
                }
            }
        case "listDirectoryAll":
            let id = args?["id"] as? String
            let path = args?["path"] as? String ?? "/"
            log("listDirectoryAll id=\(id ?? "nil") path=\(path)")
            Task {
                do {
                    guard let id else { throw FtpError.badRequest("Missing server id") }
                    let entries = try await Self.listDirectoryAll(serverId: id, requestedPath: path)
                    log("listDirectoryAll OK: \(entries.count) entries")
                    await MainActor.run { result(entries) }
                } catch {
                    let err = FlutterError(code: "ftp", message: Self.friendlyError(error), details: nil)
                    log("listDirectoryAll FAILED: \(Self.friendlyError(error))")
                    await MainActor.run { result(err) }
                }
            }
        case "fetchBytes":
            let id = args?["id"] as? String
            let path = args?["path"] as? String ?? "/"
            let maxBytes = (args?["maxBytes"] as? NSNumber)?.intValue ?? 50 * 1024 * 1024
            log("fetchBytes id=\(id ?? "nil") path=\(path) max=\(maxBytes)")
            Task {
                do {
                    guard let id else { throw FtpError.badRequest("Missing server id") }
                    let data = try await Self.fetchBytes(serverId: id, remotePath: path, maxBytes: maxBytes)
                    if let data {
                        await MainActor.run { result(FlutterStandardTypedData(bytes: data)) }
                    } else {
                        await MainActor.run { result(nil) }
                    }
                } catch {
                    let err = FlutterError(code: "ftp", message: Self.friendlyError(error), details: nil)
                    log("fetchBytes FAILED: \(Self.friendlyError(error))")
                    await MainActor.run { result(err) }
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Server persistence (unchanged shape)

    struct Server {
        let id: String
        let name: String
        let host: String
        let port: Int
        let path: String
        let username: String
        let password: String
        let isSftp: Bool
    }

    private func loadServersMeta() -> [String: [String: Any]] {
        UserDefaults.standard.dictionary(forKey: Self.serversKey) as? [String: [String: Any]] ?? [:]
    }

    private func saveServersMeta(_ servers: [String: [String: Any]]) {
        UserDefaults.standard.set(servers, forKey: Self.serversKey)
    }

    private func saveServer(
        id: String?, name: String, host: String, port: Int, path: String,
        username: String, password: String, isSftp: Bool
    ) -> [String: Any] {
        let serverId = id ?? UUID().uuidString
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        var servers = loadServersMeta()
        servers[serverId] = [
            "name": name.isEmpty ? host : name,
            "host": host.trimmingCharacters(in: .whitespaces),
            "port": port,
            "path": p,
            "username": username,
            "isSftp": isSftp,
        ]
        saveServersMeta(servers)
        if !password.isEmpty || id == nil {
            setPassword(password, for: serverId)
        }
        return serverMap(Server(
            id: serverId,
            name: name.isEmpty ? host : name,
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            path: p,
            username: username,
            password: password.isEmpty ? getPassword(serverId) : password,
            isSftp: isSftp))
    }

    private func serverMap(_ s: Server) -> [String: Any] {
        [
            "id": s.id, "name": s.name, "host": s.host, "port": s.port,
            "path": s.path, "username": s.username,
            "hasPassword": !s.password.isEmpty, "isSftp": s.isSftp,
        ]
    }

    private func resolveServer(_ id: String) throws -> Server {
        guard let meta = loadServersMeta()[id] else {
            throw FtpError.badRequest("FTP server not found")
        }
        return Server(
            id: id,
            name: meta["name"] as? String ?? "",
            host: meta["host"] as? String ?? "",
            port: meta["port"] as? Int ?? 21,
            path: meta["path"] as? String ?? "/",
            username: meta["username"] as? String ?? "",
            password: getPassword(id),
            isSftp: meta["isSftp"] as? Bool ?? false)
    }

    private func listServers() -> [[String: Any]] {
        loadServersMeta().keys.sorted().compactMap { id in
            guard let meta = loadServersMeta()[id] else { return nil }
            return serverMap(Server(
                id: id,
                name: meta["name"] as? String ?? "",
                host: meta["host"] as? String ?? "",
                port: meta["port"] as? Int ?? 21,
                path: meta["path"] as? String ?? "/",
                username: meta["username"] as? String ?? "",
                password: getPassword(id),
                isSftp: meta["isSftp"] as? Bool ?? false))
        }
    }

    private func deleteServer(_ id: String) {
        var servers = loadServersMeta()
        servers.removeValue(forKey: id)
        saveServersMeta(servers)
        deletePassword(id)
    }

    // MARK: - Keychain (unchanged)

    private func setPassword(_ password: String, for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccountPrefix + id,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
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
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccountPrefix + id,
        ] as CFDictionary)
    }

    // MARK: - Probe / listing (shared by channel + playback)

    static func probe(host: String, port: Int, path: String, username: String, password: String, isSftp: Bool) async throws {
        logStatic("probe host=\(host) port=\(port) isSftp=\(isSftp)")
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            throw FtpError.badRequest("Host is required")
        }
        if isSftp {
            logStatic("probe SFTP connect...")
            let session = try await SftpSession.connect(
                host: host, port: port, username: username, password: password)
            defer { Task { await session.close() } }
            logStatic("probe SFTP connected, checking path...")
            _ = try await session.attributes(path: normalized(path))
            logStatic("probe SFTP OK")
        } else {
            logStatic("probe FTP creating control connection...")
            let conn = FtpControlConnection(host: host, port: port)
            try await conn.connectAndLogin(username: username, password: password)
            defer { Task { await conn.quit() } }
            try await conn.setTypeI()
            logStatic("probe FTP verifyPath \(normalized(path))...")
            try await conn.verifyPath(normalized(path))
            logStatic("probe FTP OK")
        }
    }

    static func listDirectory(serverId: String, requestedPath: String) async throws -> [[String: Any]] {
        try await listDirectory(serverId: serverId, requestedPath: requestedPath, videoOnly: true)
    }

    /// Full directory listing (videos AND sidecar subtitle files) without the
    /// video-only filter the browser uses — mirrors the Android
    /// `listDirectoryAll` so the Dart sidecar service can pair `.srt`/`.ass`
    /// files by name (Nova `RawListerFactory.getFileList()`).
    static func listDirectoryAll(serverId: String, requestedPath: String) async throws -> [[String: Any]] {
        try await listDirectory(serverId: serverId, requestedPath: requestedPath, videoOnly: false)
    }

    private static func listDirectory(serverId: String, requestedPath: String, videoOnly: Bool) async throws -> [[String: Any]] {
        let server = try FtpClient.shared.resolveServer(serverId)
        let effective = effectivePath(base: server.path, requested: requestedPath)

        struct Entry { let name: String; let isDir: Bool; let size: Int64 }
        let raw: [(String, Entry)]

        if server.isSftp {
            let session = try await SftpSession.connect(
                host: server.host, port: server.port,
                username: server.username, password: server.password)
            defer { Task { await session.close() } }
            let comps = try await session.listComponents(path: effective)
            raw = comps.map { ($0.filename, Entry(name: $0.filename, isDir: $0.isDir, size: $0.size ?? 0)) }
        } else {
            let conn = FtpControlConnection(host: server.host, port: server.port)
            try await conn.connectAndLogin(username: server.username, password: server.password)
            defer { Task { await conn.quit() } }
            try await conn.setTypeI()
            let lines = try await conn.list(effective)
            raw = parseListing(lines).map { line in
                (line.name, Entry(name: line.name, isDir: line.isDir, size: line.size))
            }
        }

        return raw
            .filter { videoOnly && !$0.1.isDir && !Self.videoExtensions.contains(ext($0.1.name)) ? false : true }
            .filter { $0.1.name != "." && $0.1.name != ".." }
            .sorted { a, b in
                if a.1.isDir != b.1.isDir { return a.1.isDir }
                return a.1.name.lowercased() < b.1.name.lowercased()
            }
            .map { name, e in
                var m: [String: Any] = [
                    "name": name,
                    "path": joinPath(parent: effective, child: name),
                    "isDirectory": e.isDir,
                ]
                if !e.isDir { m["size"] = e.size }
                return m
            }
    }

    // MARK: - Playback source factory (called from AvPlayerView)

    /// Builds a read-ahead-buffered `ByteRangeSource` for an
    /// `ftp://<serverId>/<abs path>` / `sftp://…` URI.
    static func makeByteRangeSource(uriText: String) async throws -> BufferedSMBReader {
        Self.logStatic("makeByteRangeSource uri=\(uriText)")
        guard let uri = URL(string: uriText),
              let scheme = uri.scheme?.lowercased(),
              scheme == "ftp" || scheme == "sftp",
              let serverId = uri.host else {
            throw FtpError.badRequest("Malformed FTP uri")
        }
        let remotePath = decodePercent(uri.path.isEmpty ? "/" : uri.path)
        let server = try FtpClient.shared.resolveServer(serverId)
        Self.logStatic("makeByteRangeSource scheme=\(scheme) serverId=\(serverId) remotePath=\(remotePath) host=\(server.host):\(server.port)")

        if scheme == "sftp" {
            let session = try await SftpSession.connect(
                host: server.host, port: server.port,
                username: server.username, password: server.password)
            Self.logStatic("makeByteRangeSource SFTP connected, opening handle...")
            let source = try await FtpByteRangeSource(sftp: session, path: remotePath)
            Self.logStatic("makeByteRangeSource SFTP source ready byteSize=\(source.byteSize)")
            return BufferedSMBReader(source: source, ownsSource: true)
        }

        let conn = FtpControlConnection(host: server.host, port: server.port)
        try await conn.connectAndLogin(username: server.username, password: server.password)
        try await conn.setTypeI()
        let totalSize = try await conn.fileSize(path: remotePath)
        Self.logStatic("makeByteRangeSource FTP source ready size=\(totalSize)")
        let source = FtpByteRangeSource(ftp: conn, path: remotePath, size: totalSize)
        return BufferedSMBReader(source: source, ownsSource: true)
    }

    // MARK: - Path helpers (mirror FtpClient.kt)

    /// Reads up to [maxBytes] of the file at [remotePath] (a **decoded**
    /// absolute server path) into a `Data`, or nil on 404/no-access so sidecar
    /// discovery treats it as "no subtitle". Mirrors the Android
    /// `altSubBytes`/`readCapped` semantics by reusing the playback FTP/SFTP
    /// byte-range source (per-read REST/RETR or SFTP offset reads).
    static func fetchBytes(serverId: String, remotePath: String, maxBytes: Int) async throws -> Data? {
        guard !remotePath.isEmpty else { return nil }
        let server = try FtpClient.shared.resolveServer(serverId)
        var source: FtpByteRangeSource?
        if server.isSftp {
            let session = try await SftpSession.connect(
                host: server.host, port: server.port,
                username: server.username, password: server.password)
            let s = try await FtpByteRangeSource(sftp: session, path: remotePath)
            source = s
        } else {
            let conn = FtpControlConnection(host: server.host, port: server.port)
            try await conn.connectAndLogin(username: server.username, password: server.password)
            try await conn.setTypeI()
            let totalSize = try await conn.fileSize(path: remotePath)
            if totalSize <= 0 { return nil }
            source = FtpByteRangeSource(ftp: conn, path: remotePath, size: totalSize)
        }
        guard let src = source else { return nil }
        defer { src.close() }
        var result = Data()
        var offset: Int64 = 0
        while result.count < maxBytes {
            let want = min(maxBytes - result.count, 256 * 1024)
            let chunk = try await src.read(at: offset, length: want)
            if chunk.isEmpty { break }
            result.append(chunk)
            offset += Int64(chunk.count)
        }
        return result.isEmpty ? nil : result
    }

    private static func normalized(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "/" }
        if !s.hasPrefix("/") { s = "/" + s }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func effectivePath(base: String, requested: String) -> String {
        let b = normalized(base)
        var r = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty || r == "/" { return b }
        if !r.hasPrefix("/") { r = "/" + r }
        while r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        if b == "/" { return r == "" ? "/" : r }
        return (b.hasSuffix("/") ? String(b.dropLast()) : b) + r
    }

    private static func joinPath(parent: String, child: String) -> String {
        let p = parent.hasSuffix("/") && parent.count > 1 ? String(parent.dropLast()) : parent
        return p == "/" ? "/" + child : p + "/" + child
    }

    private static func ext(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) != name.endIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    private static func decodePercent(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding ?? s
    }

    /// Parses Unix `ls -l` and Windows DOS LIST lines.
    static func parseListing(_ lines: [String]) -> [(name: String, isDir: Bool, size: Int64)] {
        var out: [(String, Bool, Int64)] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("total ") { continue }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            // Unix: drwxr-xr-x 1 owner group 4096 Aug 24 12:00 name
            if tokens.count >= 9, tokens[0].first != nil,
               let size = Int64(tokens[4]) {
                let perms = String(tokens[0])
                let isDir = perms.hasPrefix("d")
                let name = tokens[8...].joined(separator: " ")
                if !name.isEmpty, name != "." , name != ".." {
                    out.append((name, isDir, isDir ? 0 : size))
                }
                continue
            }
            // DOS: 08-24-26  12:00AM <DIR> name | 08-24-26 12:00AM 123456 name
            if tokens.count >= 4, tokens[0].contains("-"), tokens[1].contains(":") {
                let isDir = tokens[2].uppercased() == "<DIR>"
                let name = tokens[3...].joined(separator: " ")
                let size: Int64 = isDir ? 0 : (Int64(tokens[2]) ?? 0)
                if !name.isEmpty {
                    out.append((name, isDir, size))
                }
                continue
            }
        }
        return out
    }

    static func friendlyError(_ error: Error) -> String {
        if let e = error as? FtpError { return e.message }
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            switch ns.code {
            case NSURLErrorTimedOut: return "Timed out connecting to the server."
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "Can't reach the host. Check the address."
            default: break
            }
        default: break
        }
        let text = ns.localizedDescription
        if text.lowercased().contains("auth") || text.lowercased().contains("password") ||
            text.lowercased().contains("530") {
            return "Login failed — check username/password."
        }
        return text.isEmpty ? "Connection failed" : text
    }
}

enum FtpError: Error {
    case badRequest(String)
    case authFailed
    case timeout
    case protocolError(String)
    case notFound(String)

    var message: String {
        switch self {
        case .badRequest(let m): return m
        case .authFailed: return "Login failed — check username/password."
        case .timeout: return "Timed out connecting to the server."
        case .protocolError(let m): return m
        case .notFound(let m): return m
        }
    }
}

// MARK: - Plain FTP over Network.framework

/// One FTP control connection. An actor, so command/reply pairs issued from
/// concurrent callers (browse + chunked playback reads) stay serialized.
actor FtpControlConnection {

    private let host: String
    private let port: UInt16
    private var control: TcpConnection?
    private var loggedIn = false

    init(host: String, port: Int) {
        self.host = host
        self.port = UInt16(clamping: max(1, port))
    }

    struct RawEntry { let name: String; let isDir: Bool; let size: Int64 }

    func connectAndLogin(username: String, password: String) async throws {
        FtpClient.logStatic("connectAndLogin host=\(host) port=\(port) user=\(username)")
        let conn = TcpConnection(host: host, port: port)
        try await conn.connect()
        control = conn
        let greeting = try await reply()
        FtpClient.logStatic("connectAndLogin greeting=\(greeting.code) \(greeting.text)")
        guard greeting.code == 220 else { throw FtpError.protocolError("Unexpected server greeting") }
        try await send("USER \(username.isEmpty ? "anonymous" : username)")
        let userReply = try await reply()
        FtpClient.logStatic("connectAndLogin USER reply=\(userReply.code)")
        if userReply.code == 230 {
            loggedIn = true
            return
        }
        guard userReply.code == 331 else {
            if userReply.code == 530 { throw FtpError.authFailed }
            throw FtpError.protocolError("Login rejected (\(userReply.code))")
        }
        try await send("PASS \(password)")
        let passReply = try await reply()
        FtpClient.logStatic("connectAndLogin PASS reply=\(passReply.code)")
        guard passReply.code == 230 || passReply.code == 202 else {
            if passReply.code == 530 { throw FtpError.authFailed }
            throw FtpError.protocolError("Login rejected (\(passReply.code))")
        }
        loggedIn = true
    }

    func quit() {
        if loggedIn {
            try? sendSync("QUIT")
        }
        control?.close()
        control = nil
        loggedIn = false
    }

    func setTypeI() async throws {
        try await send("TYPE I")
        let r = try await reply()
        guard r.code == 200 else { throw FtpError.protocolError("TYPE I rejected") }
    }

    /// SIZE (or CWD probe) so Test can catch a missing folder/file.
    func verifyPath(_ path: String) async throws {
        try await send("SIZE \(path)")
        var r = try await reply()
        if r.code == 213 { return }
        try await send("CWD \(path)")
        r = try await reply()
        if r.code == 250 { return }
        if r.code >= 500 { throw FtpError.notFound("Folder not found on server") }
    }

    func fileSize(path: String) async throws -> Int64 {
        try await send("SIZE \(path)")
        let r = try await reply()
        guard r.code == 213 else {
            throw FtpError.protocolError("Server did not report file size (\(r.code))")
        }
        // `reply()` returns the whole line ("213 30042485") — drop the
        // 3-char code prefix before parsing the payload.
        let payload = r.text.dropFirst(3).trimmingCharacters(in: .whitespaces)
        if let n = Int64(payload) { return n }
        throw FtpError.protocolError("Server did not report file size")
    }

    /// Opens a PASV data channel and lists [path]; returns raw lines.
    func list(_ path: String) async throws -> [String] {
        let endpoint = try await pasv()
        let data = TcpConnection(host: endpoint.host, port: endpoint.port)
        async let connectData: Void = try data.connect()

        try await send("LIST \(path)")
        let r = try await reply()
        guard r.code == 125 || r.code == 150 else {
            data.close()
            _ = try? await connectData
            throw FtpError.notFound("Listing failed (\(r.code))")
        }
        try await connectData
        let body = try await data.readUntilEOF()
        data.close()
        _ = try? await reply() // 226
        return String(decoding: body, as: UTF8.self)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Reads up to [maxLength] bytes at [offset] via REST + RETR. Stateless
    /// per call — BufferedSMBReader issues sequential chunks, so cost is one
    /// PASV+RETR round-trip per chunk.
    func retrieve(path: String, offset: Int64, maxLength: Int) async throws -> Data {
        let endpoint = try await pasv()
        let data = TcpConnection(host: endpoint.host, port: endpoint.port)
        async let connectData: Void = try data.connect()

        if offset > 0 {
            try await send("REST \(offset)")
            let rr = try await reply()
            guard rr.code == 350 else {
                data.close()
                throw FtpError.protocolError("REST rejected (\(rr.code))")
            }
        }
        try await send("RETR \(path)")
        let r = try await reply()
        guard r.code == 125 || r.code == 150 else {
            data.close()
            _ = try? await connectData
            throw FtpError.notFound("Open failed (\(r.code))")
        }
        try await connectData
        let body = try await data.read(upTo: maxLength)
        data.close()
        _ = try? await reply() // 226 (or 426 when we cut early)
        return body
    }

    private func pasv() async throws -> (host: String, port: UInt16) {
        try await send("PASV")
        let r = try await reply()
        guard r.code == 227 else { throw FtpError.protocolError("PASV rejected") }
        // (h1,h2,h3,h4,p1,p2)
        guard let open = r.text.firstIndex(of: "("), let close = r.text.firstIndex(of: ")") else {
            throw FtpError.protocolError("Bad PASV response")
        }
        let parts = r.text[r.text.index(after: open)..<close]
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 6 else { throw FtpError.protocolError("Bad PASV response") }
        let h = "\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])"
        let p = parts[4] * 256 + parts[5]
        guard p > 0, p < 65536 else { throw FtpError.protocolError("Bad PASV port") }
        return (h, UInt16(p))
    }

    private func send(_ cmd: String) async throws {
        guard let control else { throw FtpError.badRequest("Not connected") }
        try await control.send(Data((cmd + "\r\n").utf8))
    }

    private func sendSync(_ cmd: String) {
        guard let control else { return }
        control.sendNow(Data((cmd + "\r\n").utf8))
    }

    private func reply() async throws -> (code: Int, text: String) {
        guard let control else { throw FtpError.badRequest("Not connected") }
        var first = try await control.readLine()
        first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            throw FtpError.protocolError("Malformed reply")
        }
        // Multiline: "220-" continues until "220 ".
        if first.dropFirst(3).hasPrefix("-") {
            let marker = first.prefix(4).replacingOccurrences(of: "-", with: " ")
            while true {
                var line = try await control.readLine()
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix(marker) {
                    return (code, line)
                }
            }
        }
        return (code, first)
    }
}

// MARK: - Minimal async TCP wrapper

/// A tiny BSD-socket (POSIX) TCP wrapper exposing line/partial reads through
/// continuations. POSIX sockets are used instead of Network.framework's
/// `NWConnection` deliberately: on-device verification showed NWConnection
/// silently never dialing local-network IPs (state stuck before `.ready`, the
/// continuation hanging forever), while this app's BSD-socket traffic
/// (swift-nio / Citadel SFTP) connects fine to the same hosts. Reads run on a
/// dedicated background thread; the inbox/waiters are confined to `queue`.
final class TcpConnection: @unchecked Sendable {

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "dreamplayer.ftp.tcp")

    // Confined to `queue`.
    private var fd: Int32 = -1
    private var inbox = Data()
    private var eof = false
    private var error: Error?
    private var waiters: [(Data?) -> Void] = []
    private var connectedContinuation: CheckedContinuation<Void, Error>?
    private var readerThread: Thread?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                connectedContinuation = cont
                do {
                    try openSocket()
                    startReaderThread()
                    FtpClient.logStatic("TcpConnection connected \(host):\(port)")
                    connectedContinuation?.resume(returning: ())
                } catch {
                    FtpClient.logStatic("TcpConnection connect FAILED \(host):\(port): \(error)")
                    connectedContinuation?.resume(throwing: error)
                }
                connectedContinuation = nil
            }
        }
    }

    /// Blocking DNS + TCP connect with a 10 s budget. Runs on `queue`; no reads
    /// are possible before it returns, so blocking there is safe.
    private func openSocket() throws {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            throw FtpError.badRequest("Can't resolve \(host)")
        }
        defer { freeaddrinfo(result) }

        var lastErr = "connect failed"
        for addr in sequence(first: first, next: { $0.pointee.ai_next }) {
            let sock = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            guard sock >= 0 else {
                lastErr = String(cString: strerror(errno))
                continue
            }
            // Non-blocking connect + poll so an unreachable host fails in
            // seconds instead of hanging on the default TCP timeout (~75 s).
            let flags = fcntl(sock, F_GETFL, 0)
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
            if Darwin.connect(sock, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 {
                _ = fcntl(sock, F_SETFL, flags)
                fd = sock
                return
            }
            if errno == EINPROGRESS {
                var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                let prc = poll(&pfd, 1, 10_000)
                if prc > 0 {
                    var soerr: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(sock, SOL_SOCKET, SO_ERROR, &soerr, &len)
                    if soerr == 0 {
                        _ = fcntl(sock, F_SETFL, flags)
                        fd = sock
                        return
                    }
                    lastErr = String(cString: strerror(soerr))
                } else {
                    lastErr = prc == 0 ? "timed out" : String(cString: strerror(errno))
                }
            } else {
                lastErr = String(cString: strerror(errno))
            }
            Darwin.close(sock)
        }
        throw FtpError.badRequest("Can't reach \(host):\(port) — \(lastErr)")
    }

    /// Dedicated thread running a blocking recv() loop; chunks are marshalled
    /// onto `queue` where the inbox/waiters live.
    private func startReaderThread() {
        let sock = fd
        let thread = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = recv(sock, &buf, buf.count, 0)
                if n > 0 {
                    let data = Data(buf[0..<n])
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        self.inbox.append(data)
                        self.serveWaiters()
                    }
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                let failed = n < 0 && errno != EBADF   // EBADF = closed locally
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    if failed && self.error == nil {
                        self.failAll(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                    } else {
                        self.eof = true
                        self.serveWaiters()
                    }
                }
                break
            }
        }
        thread.name = "dreamplayer.ftp.read"
        readerThread = thread
        thread.start()
    }

    private func failAll(_ err: Error) {
        error = err
        eof = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0(nil) }
    }

    /// Resumes queued readers with whatever is buffered (or EOF/error).
    /// Drains the inbox — both this and `readSome`'s fast path must hand off
    /// exactly once, or bytes would be delivered twice.
    private func serveWaiters() {
        while !waiters.isEmpty {
            if !inbox.isEmpty {
                let ready = inbox
                inbox = Data()
                waiters.removeFirst()(ready)
            } else if eof {
                waiters.removeFirst()(nil)
            } else {
                break
            }
        }
    }

    func send(_ data: Data) async throws {
        let sock = queue.sync { fd }
        guard sock >= 0 else { throw FtpError.badRequest("Not connected") }
        try await Task.detached(priority: .userInitiated) {
            var sent = 0
            while sent < data.count {
                let n = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    return Darwin.send(sock, base + sent, data.count - sent, 0)
                }
                if n > 0 { sent += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw FtpError.protocolError("Write failed (\(errno))")
            }
        }.value
    }

    func sendNow(_ data: Data) {
        let sock = queue.sync { fd }
        guard sock >= 0 else { return }
        _ = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return Darwin.send(sock, base, data.count, 0)
        }
    }

    /// Returns ≥1 bytes when available, empty Data on clean EOF, throws on error.
    func readSome() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                if !inbox.isEmpty {
                    cont.resume(returning: inbox)
                    inbox = Data()
                } else if let error {
                    cont.resume(throwing: error)
                } else if eof {
                    cont.resume(returning: Data())
                } else {
                    waiters.append { data in
                        guard let data, !data.isEmpty else {
                            cont.resume(returning: Data())
                            return
                        }
                        cont.resume(returning: data)
                    }
                }
            }
        }
    }

    /// Pushes unconsumed bytes back to the front of the inbox (queue-confined).
    func unread(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            inbox.insert(contentsOf: data, at: inbox.startIndex)
            serveWaiters()
        }
    }

    func readLine() async throws -> String {
        var pending = Data()
        while true {
            if let r = pending.range(of: Data("\r\n".utf8)) {
                let line = pending[pending.startIndex..<r.lowerBound]
                pending.removeSubrange(pending.startIndex..<r.upperBound)
                unread(pending)
                pending = Data()
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = try await readSome()
            if chunk.isEmpty { return String(decoding: pending, as: UTF8.self) }
            pending.append(chunk)
        }
    }

    func read(upTo max: Int) async throws -> Data {
        var out = Data()
        while out.count < max {
            let chunk = try await readSome()
            if chunk.isEmpty { break }
            let take = min(chunk.count, max - out.count)
            out.append(chunk.prefix(take))
            if take < chunk.count {
                unread(Data(chunk.suffix(chunk.count - take)))
            }
        }
        return out
    }

    func readUntilEOF() async throws -> Data {
        var out = Data()
        while true {
            let chunk = try await readSome()
            if chunk.isEmpty { break }
            out.append(chunk)
        }
        return out
    }

    func close() {
        queue.async { [self] in
            if fd >= 0 {
                // shutdown() first: it wakes a recv() blocked on another
                // thread; plain close() does not.
                shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
                fd = -1
            }
            eof = true
            serveWaiters()
        }
    }
}

// MARK: - SFTP (Citadel)

final class SftpSession: @unchecked Sendable {

    private let client: SSHClient
    private let sftp: SFTPClient

    private init(client: SSHClient, sftp: SFTPClient) {
        self.client = client
        self.sftp = sftp
    }

    static func connect(host: String, port: Int, username: String, password: String) async throws -> SftpSession {
        let settings = SSHClientSettings(
            host: host,
            port: max(1, port),
            authenticationMethod: { .passwordBased(
                username: username.isEmpty ? "anonymous" : username,
                password: password) },
            hostKeyValidator: .acceptAnything())
        let ssh = try await SSHClient.connect(to: settings)
        do {
            let sftp = try await ssh.openSFTP()
            return SftpSession(client: ssh, sftp: sftp)
        } catch {
            Task { try? await ssh.close() }
            throw error
        }
    }

    struct Component {
        let filename: String
        let longname: String
        let isDir: Bool
        let size: Int64?
    }

    func listComponents(path: String) async throws -> [Component] {
        let names = try await sftp.listDirectory(atPath: path)
        var out: [Component] = []
        for name in names {
            for comp in name.components {
                let isDir = comp.longname.hasPrefix("d") ||
                    ((comp.attributes.permissions ?? 0) & 0o170000) == 0o40000
                out.append(Component(
                    filename: comp.filename,
                    longname: comp.longname,
                    isDir: isDir,
                    size: comp.attributes.size.map(Int64.init)))
            }
        }
        return out
    }

    struct AttrInfo { let isDir: Bool; let size: Int64? }

    func attributes(path: String) async throws -> AttrInfo {
        let attrs = try await sftp.getAttributes(at: path)
        return AttrInfo(
            isDir: ((attrs.permissions ?? 0) & 0o170000) == 0o40000,
            size: attrs.size.map(Int64.init))
    }

    /// Opens a persistent read handle for playback.
    func openReadHandle(path: String) async throws -> SFTPFile {
        try await sftp.openFile(filePath: path, flags: [.read])
    }

    func close() {
        Task {
            try? await sftp.close()
            try? await client.close()
        }
    }
}

// MARK: - ByteRangeSource for the engine

/// Minimal async counting semaphore. FTP control connections allow only ONE
/// transfer at a time — concurrent PASV/REST/RETR streams from a background
/// chunk fill + an engine seek cross replies on the shared control socket and
/// corrupt the session (observed on-device: two RESTs, the tail transfer won,
/// probe died). This gates all plain-FTP reads to one in-flight RETR.
final class AsyncSemaphore: @unchecked Sendable {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(value: Int) { self.value = value }

    func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if value > 0 {
                value -= 1
                lock.unlock()
                cont.resume()
                return
            }
            waiters.append(cont)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
            return
        }
        value += 1
        lock.unlock()
    }

    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

/// Random-access reader over FTP/SFTP for AetherEngine, mirroring
/// `WebDAVByteRangeSource`. Wrapped in `BufferedSMBReader` by the caller.
final class FtpByteRangeSource: ByteRangeSource, @unchecked Sendable {

    // SFTP mode
    private var sftpSession: SftpSession?
    private var sftpFile: SFTPFile?

    // Plain-FTP mode (one control connection; sequential chunks fast-path).
    private var ftpConn: FtpControlConnection?
    private let ftpPath: String?
    private let ftpGate = AsyncSemaphore(value: 1)

    private(set) var byteSize: Int64

    init(sftp: SftpSession, path: String) async throws {
        sftpSession = sftp
        sftpFile = try await sftp.openReadHandle(path: path)
        ftpConn = nil
        ftpPath = nil
        let attrs = try await sftp.attributes(path: path)
        byteSize = attrs.size ?? -1
    }

    init(ftp: FtpControlConnection, path: String, size: Int64) {
        sftpSession = nil
        sftpFile = nil
        ftpConn = ftp
        ftpPath = path
        byteSize = size
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        if let sftpFile {
            // OpenSSH's sftp-server caps a single read at 256 KiB (MAX_READ_SIZE);
            // a larger request is either rejected or truncated, which trips the
            // ring-buffer's contiguous-frontier logic. Loop in 256 KiB slices so
            // the source always returns the full requested length (except at EOF).
            var result = Data()
            var off = max(0, offset)
            var remaining = length
            while remaining > 0 {
                let chunkLen = min(remaining, 256 * 1024)
                let buffer = try await sftpFile.read(
                    from: UInt64(off),
                    length: UInt32(chunkLen))
                let data = Data(buffer.readableBytesView)
                if data.isEmpty { break }
                result.append(data)
                off += Int64(data.count)
                remaining -= data.count
            }
            return result
        }
        guard let ftpConn, let ftpPath else {
            throw FtpError.badRequest("Source closed")
        }
        // Reads at/past EOF: answer empty without a server round-trip — a
        // RETR from REST >= fileSize is rejected by servers (4xx), which
        // would surface an end-of-stream playback error.
        let off = max(0, offset)
        if byteSize > 0, off >= byteSize { return Data() }
        do {
            // One REST/RETR transfer at a time on the shared control
            // connection (see AsyncSemaphore above).
            return try await ftpGate.withLock {
                try await ftpConn.retrieve(path: ftpPath, offset: off, maxLength: length)
            }
        } catch {
            FtpClient.logStatic("FTP read off=\(offset) len=\(length) failed: \(error)")
            throw error
        }
    }

    func close() {
        if let file = sftpFile {
            Task { try? await file.close() }
        }
        sftpFile = nil
        sftpSession?.close()
        sftpSession = nil
        if let c = ftpConn { Task { await c.quit() } }
        ftpConn = nil
    }
}
