import AetherEngineSMB
import Flutter
import Foundation
import Security
import SMBClient

/// In-app SMB2/3 browsing and playback for iOS.
///
/// Replaces the retired Files-app bridge, whose security-scoped bookmarks were
/// unreliable. The transport is the same pure-Swift `SMBClient` that
/// `AetherEngineSMB` itself uses (MIT, speaks SMB2/3 over `NWConnection`).
/// The previous AMSMB2/libsmb2 backend is NOT used: it failed with POSIX
/// `EPERM` on the first `connectShare` on iOS, a known long-standing libsmb2
/// issue, which is why in-app SMB was withdrawn in 2026-08.
///
/// Two distinct roles, deliberately kept separate:
///  * **browsing** talks to `SMBClient` directly (login / listShares /
///    connectShare / listDirectory);
///  * **playback** goes through `AetherEngineSMB.SMBConnection`, a
///    `ByteRangeSource` the engine consumes via `SMBIOReader`.
///
/// Credentials never cross to Dart: passwords live in the Keychain and Dart
/// only ever sees a `hasPassword` boolean, mirroring `WebDAVClient`.
final class SMBBridge: NSObject {
    static let shared = SMBBridge()
    private static let channelName = "dreamplayer/smb"
    private static let serversKey = "dreamplayer.smbServers"
    private static let keychainService = "com.dreamplayer.app.smb"
    private static let keychainAccountPrefix = "smb."
    /// Matches Android's listing TTL: re-visiting a folder is instant.
    private static let listingTTL: TimeInterval = 60

    /// One saved server. Password lives in the Keychain under [id].
    private struct ServerMeta: Codable {
        var id: String
        var name: String
        var host: String
        var port: Int
        var username: String
        var domain: String
        var anonymous: Bool
    }

    private struct ListingCacheKey: Hashable {
        let serverId: String
        let share: String
        let path: String
    }

    private final class CachedListing {
        let entries: [[String: Any]]
        let stamp: Date
        init(_ entries: [[String: Any]]) {
            self.entries = entries
            self.stamp = Date()
        }
        var isFresh: Bool { Date().timeIntervalSince(stamp) < SMBBridge.listingTTL }
    }

    /// Guards the mutable state below. Network work is awaited off this lock.
    private let lock = NSLock()
    private var servers: [String: ServerMeta] = [:]
    private var listingCache: [ListingCacheKey: CachedListing] = [:]
    /// Live playback connections by token, so `closeShare` is exact.
    private var playback: [String: SMBConnection] = [:]
    private var tokenCounter: UInt64 = 0

    // MARK: - Registration

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            SMBBridge.shared.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "listServers":
            result(listServers())
        case "saveServer":
            saveServer(args)
            result(nil)
        case "deleteServer":
            deleteServer(id: args["id"] as? String)
            result(nil)
        case "testConnection":
            let host = args["host"] as? String ?? ""
            testConnection(
                host: host,
                port: args["port"] as? Int ?? 445,
                username: args["username"] as? String ?? "",
                password: args["password"] as? String ?? "",
                domain: args["domain"] as? String ?? "",
                anonymous: args["anonymous"] as? Bool ?? false
            ) { ok, error in
                result(["ok": ok, "error": error as Any])
            }
        case "invalidateListingCache":
            let id = args["id"] as? String
            invalidateListingCache(serverId: id)
            result(nil)
        case "listShares":
            withServer(args["id"] as? String, result: result) { server, reply in
                self.listShares(server: server) { shares in
                    reply(shares, error: shares == nil ? "Could not list shares" : nil)
                }
            }
        case "addShare":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                self.addShare(server: server, share: share) { ok in
                    reply(ok, error: ok ? nil : "Could not connect to share \(share)")
                }
            }
        case "listDirectory", "listDirectoryAll":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                let path = args["path"] as? String ?? ""
                self.listDirectory(server: server, share: share, path: path) { entries in
                    reply(entries, error: entries == nil ? "Could not read that folder" : nil)
                }
            }
        case "fetchSizes":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                let paths = args["paths"] as? [String] ?? []
                self.fetchSizes(server: server, share: share, paths: paths) { sizes in
                    reply(sizes, error: nil)
                }
            }
        case "fetchBytes":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                let path = args["path"] as? String ?? ""
                let maxBytes = args["maxBytes"] as? Int ?? (50 * 1024 * 1024)
                self.fetchBytes(
                    server: server, share: share, path: path, maxBytes: maxBytes
                ) { bytes in
                    reply(bytes, error: bytes == nil ? "Could not read \(path)" : nil)
                }
            }
        case "openShare":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                let path = args["path"] as? String ?? ""
                self.openShare(server: server, share: share, path: path) { token in
                    reply(token, error: token == nil ? "Could not open \(path)" : nil)
                }
            }
        case "closeShare":
            closeShare(id: args["id"] as? String)
            result(nil)
        // Android-only: LAN subnet scan, and the mpv loopback bridge (iOS has
        // no mpv engine). Answered so Dart never blocks on a missing handler.
        case "discoverServers":
            result([])
        case "checkServer":
            result(false)
        case "startLoopback", "stopLoopback":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Resolves a saved server and hands it to [body], replying exactly once.
    ///
    /// The reply is always delivered on the main thread: a `FlutterResult`
    /// invoked off it deadlocks the method channel. [body] is async and must
    /// call [reply] exactly once.
    private func withServer(
        _ id: String?,
        result: @escaping FlutterResult,
        _ body: @escaping (ServerMeta, @escaping (Any?, String?) -> Void) -> Void
    ) {
        guard let id, let server = server(id: id) else {
            result(FlutterError(
                code: "smb_unknown_server",
                message: "That server is no longer saved",
                details: nil
            ))
            return
        }
        var replied = false
        let reply: (Any?, String?) -> Void = { value, error in
            guard !replied else { return }
            replied = true
            if let error {
                result(FlutterError(code: "smb_error", message: error, details: nil))
            } else {
                result(value)
            }
        }
        body(server, reply)
    }

    // MARK: - Saved servers

    private func loadServersIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard servers.isEmpty else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.serversKey),
              let decoded = try? JSONDecoder().decode([ServerMeta].self, from: data)
        else { return }
        servers = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func server(id: String) -> ServerMeta? {
        loadServersIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return servers[id]
    }

    private func allServers() -> [[String: Any]] {
        loadServersIfNeeded()
        lock.lock()
        let list = Array(servers.values)
        lock.unlock()
        return list
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { meta in
                [
                    "id": meta.id,
                    "name": meta.name,
                    "host": meta.host,
                    "port": meta.port,
                    "username": meta.username,
                    "domain": meta.domain,
                    "anonymous": meta.anonymous,
                    "hasPassword": !self.getPassword(meta.id).isEmpty,
                ] as [String: Any]
            }
    }

    private func listServers() -> [[String: Any]] { allServers() }

    private func saveServer(_ args: [String: Any]) {
        let id = (args["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let meta = ServerMeta(
            id: id,
            name: args["name"] as? String ?? "",
            host: args["host"] as? String ?? "",
            port: args["port"] as? Int ?? 445,
            username: args["username"] as? String ?? "",
            domain: args["domain"] as? String ?? "",
            anonymous: args["anonymous"] as? Bool ?? false
        )
        lock.lock()
        servers[id] = meta
        // A credential or address change invalidates every cached listing.
        listingCache = listingCache.filter { $0.key.serverId != id }
        let snapshot = Array(servers.values)
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
        }
        // An explicitly empty password means "leave the saved one alone" when
        // editing; a save from the add dialog always carries the real value.
        if let password = args["password"] as? String, !password.isEmpty {
            setPassword(password, for: id)
        }
    }

    private func deleteServer(id: String?) {
        guard let id else { return }
        lock.lock()
        servers.removeValue(forKey: id)
        listingCache = listingCache.filter { $0.key.serverId != id }
        let snapshot = Array(servers.values)
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
        }
        deletePassword(id)
    }

    private func invalidateListingCache(serverId: String?) {
        lock.lock()
        if let serverId {
            listingCache = listingCache.filter { $0.key.serverId != serverId }
        } else {
            listingCache.removeAll()
        }
        lock.unlock()
    }

    // MARK: - Keychain

    private func setPassword(_ password: String, for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccountPrefix + id,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
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
              let data = item as? Data
        else { return "" }
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

    // MARK: - Connection

    /// A logged-in `SMBClient` for one server, or a friendly error.
    ///
    /// An empty username means "no explicit account": SMBClient is asked for a
    /// guest session first and then a fully anonymous one, which is what a NAS
    /// with a public share expects. An explicit username that fails is a real
    /// auth error and must not silently downgrade.
    private func connect(
        _ server: ServerMeta,
        _ body: @escaping @MainActor (SMBClient) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        let password = getPassword(server.id)
        Task.detached(priority: .userInitiated) {
            let client = server.port > 0 && server.port != 445
                ? SMBClient(host: server.host, port: server.port)
                : SMBClient(host: server.host)
            do {
                if server.anonymous || (server.username.isEmpty && password.isEmpty) {
                    try await client.login(username: nil, password: nil)
                } else {
                    try await client.login(
                        username: server.username,
                        password: password.isEmpty ? nil : password,
                        domain: server.domain.isEmpty ? nil : server.domain
                    )
                }
                await MainActor.run { body(client) }
            } catch {
                client.session.disconnect()
                await MainActor.run { onError(Self.friendly(error, host: server.host)) }
            }
        }
    }

    private static func friendly(_ error: Error, host: String) -> String {
        let text = (error as NSError)
        let code = text.code
        let lower = (error.localizedDescription + " " + String(describing: error)).lowercased()
        if lower.contains("logon failure") || lower.contains("authentication")
            || lower.contains("credential") || code == 0xC000006D {
            return "Login failed — check username, password and domain"
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Timed out reaching \(host). Is SMB enabled on the NAS?"
        }
        if lower.contains("refused") || lower.contains("unreachable") {
            return "Can't reach \(host) on the SMB port"
        }
        if lower.contains("status_logon_failure") {
            return "Login failed — check username, password and domain"
        }
        let message = error.localizedDescription
        return message.isEmpty ? "SMB error on \(host)" : message
    }

    // MARK: - Browsing

    private func listShares(
        server: ServerMeta,
        completion: @escaping ([[String: Any]]?) -> Void
    ) {
        connect(server) { client in
            Task {
                do {
                    let shares = try await client.listShares()
                    // Dart parses these as SmbEntry, so return entry-shaped maps.
                    let entries = shares
                        .filter { !$0.type.contains(.ipc) && !$0.type.contains(.printQueue) }
                        .map { share in
                            [
                                "name": share.name,
                                "path": share.name,
                                "isDirectory": true,
                                "size": 0,
                                "modified": 0,
                            ] as [String: Any]
                        }
                    _ = try? await client.logoff()
                    client.session.disconnect()
                    await MainActor.run { completion(entries) }
                } catch {
                    client.session.disconnect()
                    await MainActor.run { completion(nil) }
                }
            }
        } onError: { _ in
            completion(nil)
        }
    }

    private func addShare(
        server: ServerMeta,
        share: String,
        completion: @escaping (Bool) -> Void
    ) {
        connect(server) { client in
            Task {
                do {
                    try await client.connectShare(share)
                    await MainActor.run { completion(true) }
                } catch {
                    await MainActor.run { completion(false) }
                } finally {
                    _ = try? await client.logoff()
                    client.session.disconnect()
                }
            }
        } onError: { _ in
            completion(false)
        }
    }

    private func listDirectory(
        server: ServerMeta,
        share: String,
        path: String,
        completion: @escaping ([[String: Any]]?) -> Void
    ) {
        let key = ListingCacheKey(serverId: server.id, share: share, path: path)
        lock.lock()
        if let cached = listingCache[key], cached.isFresh {
            let entries = cached.entries
            lock.unlock()
            completion(entries)
            return
        }
        lock.unlock()

        connect(server) { client in
            Task {
                do {
                    try await client.connectShare(share)
                    let files = try await client.listDirectory(path: Self.normalized(path))
                    let built = self.buildEntries(files: files, share: share, path: path)
                    self.lock.lock()
                    self.listingCache[key] = CachedListing(built)
                    self.lock.unlock()
                    await MainActor.run { completion(built) }
                } catch {
                    await MainActor.run { completion(nil) }
                } finally {
                    _ = try? await client.logoff()
                    client.session.disconnect()
                }
            }
        } onError: { _ in
            completion(nil)
        }
    }

    /// Normalises a browse path the way the Dart side hands it over: no
    /// leading slash, no trailing slash, no `//` runs. `SMBClient` normalises
    /// its own input, but building the child's full path is ours.
    private static func normalized(_ path: String) -> String {
        var out = path.replacingOccurrences(of: "//", with: "/")
        while out.hasSuffix("/") { out.removeLast() }
        while out.hasPrefix("/") { out.removeFirst() }
        return out
    }

    /// Sibling subtitle auto-pairing, mirroring Android: every subtitle file in
    /// the listing is offered to Dart, and the best match for a video (same
    /// base name, an English/default-ish tag first) is named separately.
    private func buildEntries(
        files: [File],
        share: String,
        path: String
    ) -> [[String: Any]] {
        let subtitles = files.filter { Self.isSubtitle($0.name) }
        let subtitleBases = subtitles.map { Self.baseName($0.name) }

        return files
            .filter { !$0.isHidden && !$0.isSystem }
            .filter { $0.isDirectory || !Self.isJunk($0.name) }
            .map { file -> [String: Any] in
                var entry: [String: Any] = [
                    "name": file.name,
                    "path": Self.join(path, file.name),
                    "isDirectory": file.isDirectory,
                    "size": file.size,
                    "modified": Int(file.lastWriteTime.timeIntervalSince1970 * 1000),
                ]
                if !file.isDirectory {
                    let base = Self.baseName(file.name)
                    // Index of this video's sibling subtitles, in listing order.
                    var matches: [(index: Int, name: String)] = []
                    for (i, sub) in subtitles.enumerated() where subtitleBases[i] == base {
                        matches.append((i, sub.name))
                    }
                    if !matches.isEmpty {
                        entry["subtitlePaths"] = matches.map {
                            Self.join(path, $0.name)
                        }
                        // Best match: an English tag wins, else the first.
                        let preferred = matches.first { entry2 in
                            let n = entry2.name.lowercased()
                            return n.contains(".en.") || n.contains(".eng.")
                        } ?? matches[0]
                        entry["subtitlePath"] = Self.join(path, preferred.name)
                    }
                }
                return entry
            }
    }

    private static func join(_ path: String, _ name: String) -> String {
        let base = normalized(path)
        return base.isEmpty ? name : base + "/" + name
    }

    private static func baseName(_ name: String) -> String {
        let lower = name.lowercased()
        // Strip the video's own extension, then any subtitle extension.
        var base = (name as NSString).deletingPathExtension
        for ext in subtitleExtensions where lower.hasSuffix("." + ext) {
            base = (base as NSString).deletingPathExtension
            break
        }
        return base.lowercased()
    }

    private static let subtitleExtensions = [
        "srt", "ass", "ssa", "vtt", "ttml", "dfxp", "smi", "sami", "sub", "mpl2", "idx", "sup",
    ]

    private static func isSubtitle(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return subtitleExtensions.contains(ext)
    }

    /// Directories and non-media clutter never reach the list.
    private static func isJunk(_ name: String) -> Bool {
        if isSubtitle(name) { return true }
        let lower = name.lowercased()
        if lower.hasPrefix(".") { return true }
        for token in ["featurette", "trailer", "sample", "proof", "teaser"] where lower
            .contains(token)
        {
            return true
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let media = [
            "mkv", "mp4", "avi", "mov", "m2ts", "ts", "webm", "wmv", "flv", "ogv", "m4v",
            "mpg", "mpeg", "rmvb", "vob", "iso", "divx", "3gp",
        ]
        return !media.contains(ext)
    }

    // MARK: - Sizes and sidecar bytes

    private func fetchSizes(
        server: ServerMeta,
        share: String,
        paths: [String],
        completion: @escaping ([String: Int]) -> Void
    ) {
        guard !paths.isEmpty else {
            completion([:])
            return
        }
        let password = getPassword(server.id)
        Task.detached(priority: .utility) {
            var sizes: [String: Int] = [:]
            let client = server.port > 0 && server.port != 445
                ? SMBClient(host: server.host, port: server.port)
                : SMBClient(host: server.host)
            do {
                if server.anonymous || (server.username.isEmpty && password.isEmpty) {
                    try await client.login(username: nil, password: nil)
                } else {
                    try await client.login(
                        username: server.username,
                        password: password.isEmpty ? nil : password,
                        domain: server.domain.isEmpty ? nil : server.domain
                    )
                }
                try await client.connectShare(share)
                for path in paths {
                    let clean = Self.normalized(path)
                    if let stat = try? await client.fileStat(path: clean) {
                        sizes[path] = Int(stat.size)
                    }
                }
            } catch {
                // Best effort: entries without a size simply stay 0.
            }
            _ = try? await client.logoff()
            client.session.disconnect()
            await MainActor.run { completion(sizes) }
        }
    }

    private func fetchBytes(
        server: ServerMeta,
        share: String,
        path: String,
        maxBytes: Int,
        completion: @escaping (FlutterStandardTypedData?) -> Void
    ) {
        let password = getPassword(server.id)
        Task.detached(priority: .utility) {
            let client = server.port > 0 && server.port != 445
                ? SMBClient(host: server.host, port: server.port)
                : SMBClient(host: server.host)
            do {
                if server.anonymous || (server.username.isEmpty && password.isEmpty) {
                    try await client.login(username: nil, password: nil)
                } else {
                    try await client.login(
                        username: server.username,
                        password: password.isEmpty ? nil : password,
                        domain: server.domain.isEmpty ? nil : server.domain
                    )
                }
                try await client.connectShare(share)
                let reader = client.fileReader(path: Self.normalized(path))
                let want = maxBytes > 0 ? maxBytes : (50 * 1024 * 1024)
                // One bounded read; sidecars are small, and a single call keeps
                // this off the reopen/track-switch critical path.
                let data = try await reader.read(offset: 0, length: UInt32(want))
                try? await reader.close()
                await MainActor.run {
                    completion(FlutterStandardTypedData(bytes: data))
                }
            } catch {
                await MainActor.run { completion(nil) }
            }
            _ = try? await client.logoff()
            client.session.disconnect()
        }
    }

    // MARK: - Playback

    /// Opens an SMB file for playback and returns the token URL the player
    /// resolves back to the live connection.
    ///
    /// The connection is held here (keyed by token) rather than re-opened per
    /// read, so an audio-track switch does not have to rebuild the socket.
    private func openShare(
        server: ServerMeta,
        share: String,
        path: String,
        completion: @escaping (String?) -> Void
    ) {
        let password = getPassword(server.id)
        Task.detached(priority: .userInitiated) {
            var serverURL = URLComponents()
            serverURL.scheme = "smb"
            serverURL.host = server.host
            if server.port > 0 && server.port != 445 {
                serverURL.port = server.port
            }
            guard let url = serverURL.url else {
                await MainActor.run { completion(nil) }
                return
            }
            do {
                let connection = try await SMBConnection.connect(
                    server: url,
                    share: share,
                    path: Self.normalized(path),
                    user: server.anonymous ? "" : server.username,
                    password: server.anonymous ? "" : password,
                    domain: server.domain
                )
                let ext = (path as NSString).pathExtension
                self.lock.lock()
                self.tokenCounter += 1
                let token = "\(server.id)-\(self.tokenCounter)"
                self.playback[token] = connection
                self.lock.unlock()
                await MainActor.run {
                    completion("dreamplayersmb://\(token).\(ext.isEmpty ? "mkv" : ext)")
                }
            } catch {
                await MainActor.run { completion(nil) }
            }
        }
    }

    /// Tears down a playback connection by the server id the token embeds.
    private func closeShare(id: String?) {
        guard let id else { return }
        closePlayback(serverId: id)
    }

    /// Public so the player view can release its socket on teardown. Must only
    /// be called once the engine has stopped, or a demux thread may still be
    /// mid-read on the connection.
    func closePlayback(serverId: String) {
        lock.lock()
        let doomed = playback.keys.filter { $0.hasPrefix("\(serverId)-") }
        for token in doomed {
            playback[token]?.close()
            playback.removeValue(forKey: token)
        }
        lock.unlock()
    }

    /// Resolves a `dreamplayersmb://` URL handed to the player back to its
    /// live connection. Returns nil once the session has been closed.
    func connection(for urlString: String) -> SMBConnection? {
        guard urlString.hasPrefix("dreamplayersmb://") else { return nil }
        var token = String(urlString.dropFirst("dreamplayersmb://".count))
        if let dot = token.lastIndex(of: ".") {
            token = String(token[token.startIndex..<dot])
        }
        lock.lock()
        defer { lock.unlock() }
        return playback[token]
    }

    /// The `IOReader` the engine plays from, with read-ahead disabled by
    /// default: `SMBIOReader` already drives a real `ByteRangeSource`, and
    /// wrapping it in a second buffering layer only added latency.
    func makeReader(for urlString: String) -> SMBIOReader? {
        guard let connection = connection(for: urlString) else { return nil }
        return SMBIOReader(
            source: connection,
            ownsSource: false, // the registry owns teardown via closeShare
            discImageProbeEnabled: false
        )
    }
}
