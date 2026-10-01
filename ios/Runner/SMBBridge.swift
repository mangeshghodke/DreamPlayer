import AetherEngineSMB
import Flutter
import Foundation
import Network
import Security
// Legacy playback only, pending the libDSM read path. Browsing does not use it.
import SMBClient

/// In-app SMB browsing and playback for iOS, on the `dreamplayer/smb` channel.
///
/// Replaces the retired Files-app bridge, whose security-scoped bookmarks were
/// unreliable.
///
/// The pure-Swift `SMBClient` (over `NWConnection`) was tried first and
/// removed: it works for browsing, but playback needed a read-ahead layer
/// written on top of it, and every bug we hit lived in that layer rather than
/// in SMB — a ring-trim `max()` that stalled every large seek, a 60s reader
/// deadline that surfaced as "custom source probe failed", prefetcher starvation
/// on an audio-track switch, and a per-session token that was dead by the time a
/// resume needed it. libDSM owns its own buffering and seeking, so none of that
/// code is needed.
///
/// AMSMB2/libsmb2 is NOT used either: it fails with POSIX `EPERM` on the first
/// `connectShare` on iOS (AMSMB2 #32/#63/#64), which is why in-app SMB was
/// withdrawn in 2026-08.
///
/// Two backends during the migration:
///  * **browsing** — libDSM, via `SMBTransport` (all of it off the main actor);
///  * **playback** — still the legacy `AetherEngineSMB.SMBConnection`, so a
///    libDSM fault cannot take playback down in the same build.
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
        var isAnonymous: Bool { anonymous }
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
    /// One entry per playback token, each holding the primary connection
    /// followed by any extra parallel-prefetch sockets. The extras are what
    /// makes read-ahead parallel: SMB serialises requests per connection, so
    /// one socket is one request in flight at a time.
    private var playback: [String: [SMBConnection]] = [:]
    /// Servers a live player is reading from. The browser's dispose calls
    /// closeShare, which must NOT tear the socket out from under a player that
    /// is still using it — the old build had exactly this latch and dropping it
    /// stops playback the moment the browsing screen goes away.
    private var playerActive: Set<String> = []
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
        SBMLog.boot()
        SBMLog.log("-> \(call.method) \(SBMLog.scrub(args))")
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
        // ---- libDSM: browsing. Everything below this line uses the vendored
        // C client, which owns its own buffering. Playback still uses the
        // legacy path until its read path is ported, so a libDSM fault cannot
        // also take playback down.
        case "listShares":
            withServer(args["id"] as? String, result: result) { server, reply in
                self.runOffMain {
                    do {
                        let shares = try SMBTransport.libDSMListShares(
                            host: server.host,
                            port: UInt16(truncatingIfNeeded: server.port),
                            user: server.isAnonymous ? nil : server.username,
                            password: server.isAnonymous ? nil : self.getPassword(server.id),
                            domain: server.domain.isEmpty ? nil : server.domain
                        )
                        // Dart parses shares as SmbEntry, so return entry-shaped maps.
                        let entries: [[String: Any]] = shares.map { name in
                            [
                                "name": name,
                                "path": name,
                                "isDirectory": true,
                                "size": 0,
                                "modified": 0,
                            ]
                        }
                        reply(entries, nil)
                    } catch {
                        reply(nil, (error as? SMBError)?.errorDescription
                            ?? "Could not list shares")
                    }
                }
            }
        case "addShare":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                self.runOffMain {
                    do {
                        // Touch the file API with a no-op open to prove the
                        // share is actually usable, not just enumerable.
                        let session = try SMBTransport.libDSMSession(
                            host: server.host,
                            port: UInt16(truncatingIfNeeded: server.port),
                            share: share,
                            user: server.isAnonymous ? nil : server.username,
                            password: server.isAnonymous ? nil : self.getPassword(server.id),
                            domain: server.domain.isEmpty ? nil : server.domain
                        )
                        let entries = try SMBTransport.libDSMList(session: session, path: "")
                        SBMLog.log("addShare \(share) ok (\(entries.count) entries)")
                        reply(true, nil)
                    } catch {
                        reply(false, (error as? SMBError)?.errorDescription
                            ?? "Could not connect to share \(share)")
                    }
                }
            }
        case "listDirectory", "listDirectoryAll":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                let path = args["path"] as? String ?? ""
                // 60s listing cache, same TTL Android uses.
                let key = ListingCacheKey(serverId: server.id, share: share, path: path)
                self.lock.lock()
                if let cached = self.listingCache[key], cached.isFresh {
                    let entries = cached.entries
                    self.lock.unlock()
                    reply(entries, nil)
                    return
                }
                self.lock.unlock()
                self.runOffMain {
                    do {
                        let session = try SMBTransport.libDSMSession(
                            host: server.host,
                            port: UInt16(truncatingIfNeeded: server.port),
                            share: share,
                            user: server.isAnonymous ? nil : server.username,
                            password: server.isAnonymous ? nil : self.getPassword(server.id),
                            domain: server.domain.isEmpty ? nil : server.domain
                        )
                        let raw = try SMBTransport.libDSMList(session: session, path: path)
                        let built = self.buildEntries(from: raw)
                        self.lock.lock()
                        self.listingCache[key] = CachedListing(built)
                        self.lock.unlock()
                        SBMLog.log(
                            "listDirectory \(share)/\(path) -> \(built.count) entries (libDSM)")
                        reply(built, nil)
                    } catch {
                        SBMLog.log("listDirectory \(share)/\(path) FAILED (libDSM): \(error)")
                        reply(nil, (error as? SMBError)?.errorDescription
                            ?? "Could not read that folder")
                    }
                }
            }
        case "fetchSizes":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                let paths = args["paths"] as? [String] ?? []
                self.fetchSizes(server: server, share: share, paths: paths) { sizes in
                    reply(sizes, nil)
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
                    reply(bytes, bytes == nil ? "Could not read \(path)" : nil)
                }
            }
        case "openShare":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                let path = args["path"] as? String ?? ""
                self.openShare(server: server, share: share, path: path) { token in
                    reply(token, token == nil ? "Could not open \(path)" : nil)
                }
            }
        case "closeShare":
            closeShare(id: args["id"] as? String)
            result(nil)
        // Android-only: LAN subnet scan, and the mpv loopback bridge (iOS has
        // no mpv engine). Answered so Dart never blocks on a missing handler.
        case "discoverServers":
            // The LAN sweep that used to live here was removed with the rest of
            // the pure-Swift path. Dart awaits this call, so it must still
            // answer: an empty list renders "nothing found" immediately instead
            // of hanging the scan button.
            result([])
        case "checkServer":
            let host = args["host"] as? String ?? ""
            let port = UInt16(truncatingIfNeeded: args["port"] as? Int ?? 445)
            self.runOffMain {
                let ok = SMBTransport.libDSMCanReach(host: host, port: port)
                DispatchQueue.main.async {
                    SBMLog.log("checkServer \(host):\(port) -> \(ok)")
                    result(ok)
                }
            }
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
    private func withClient(
        _ server: ServerMeta,
        _ body: @escaping @MainActor (SMBClient) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        withClient(server, password: getPassword(server.id), body, onError: onError)
    }

    /// Same as `connect`, but with the password supplied by the caller — used
    /// by testConnection, which tests credentials that are not saved yet.
    private func withClient(
        _ server: ServerMeta,
        password: String,
        _ body: @escaping @MainActor (SMBClient) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
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
                SBMLog.log("connect ok: \(server.host):\(server.port) as \(server.anonymous || server.username.isEmpty ? "guest/anon" : server.username)")
                await MainActor.run { body(client) }
            } catch {
                client.session.disconnect()
                let message = Self.friendly(error, host: server.host)
                SBMLog.log("connect FAILED \(server.host):\(server.port): \(message) raw=\(error)")
                await MainActor.run { onError(message) }
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

    /// Probes a server with credentials the user has not saved yet.
    ///
    /// Builds a throwaway `ServerMeta` (id "") and connects with the supplied
    /// password, so nothing touches the Keychain. Reports the friendly reason
    /// the Dart dialog shows inline.
    private func testConnection(
        host: String,
        port: Int,
        username: String,
        password: String,
        domain: String,
        anonymous: Bool,
        completion: @escaping (Bool, String?) -> Void
    ) {
        let probe = ServerMeta(
            id: "",
            name: host,
            host: host,
            port: port,
            username: username,
            domain: domain,
            anonymous: anonymous
        )
        withClient(probe, password: password) { client in
            Task {
                // Listing shares proves the credentials AND the tree connect,
                // not just that the socket opened.
                var ok = false
                do {
                    _ = try await client.listShares()
                    ok = true
                } catch {
                    ok = false
                }
                _ = try? await client.logoff()
                client.session.disconnect()
                await MainActor.run { completion(ok, ok ? nil : "Connected, but could not list shares") }
            }
        } onError: { message in
            completion(false, message)
        }
    }

    /// Runs blocking work off the main actor and replies on the main actor.
    ///
    /// libDSM is synchronous C, so every call would freeze the UI (and freeze
    /// it visibly — an SMB handshake is seconds). [FlutterResult] must also be
    /// invoked on the main thread or the method channel deadlocks, which is why
    /// this helper exists rather than ad-hoc Task blocks at each call site.
    private func runOffMain(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    /// Turns libDSM entries into the map shape Dart parses, including sibling
    /// subtitle pairing — same rule the previous implementation used, so the
    /// UI behaves identically.
    private func buildEntries(from raw: [SMBEntry]) -> [[String: Any]] {
        let subtitles = raw.filter { Self.isSubtitle($0.name) }
        return raw
            .filter { !$0.isDirectory || !Self.isJunkFolder($0.name) }
            .filter { $0.isDirectory || !Self.isJunk($0.name) }
            .map { file in
                var entry: [String: Any] = [
                    "name": file.name,
                    "path": file.relativePath,
                    "isDirectory": file.isDirectory,
                    "size": file.size,
                    "modified": file.modifiedMillis,
                ]
                guard !file.isDirectory else { return entry }
                let base = Self.baseName(file.name)
                let matches = subtitles.filter { Self.baseName($0.name) == base }
                if !matches.isEmpty {
                    entry["subtitlePaths"] = matches.map(\.relativePath)
                    let preferred = matches.first {
                        let n = $0.name.lowercased()
                        return n.contains(".en.") || n.contains(".eng.")
                    } ?? matches[0]
                    entry["subtitlePath"] = preferred.relativePath
                }
                return entry
            }
    }

    /// Share-relative path with no leading/trailing slash and no `//` runs,
    /// which is the form both the Dart layer and libDSM want.
    private static func normalized(_ path: String) -> String {
        var out = path.replacingOccurrences(of: "//", with: "/")
        while out.hasSuffix("/") { out.removeLast() }
        while out.hasPrefix("/") { out.removeFirst() }
        return out
    }

    /// Sibling sidecar extensions, matched against the video's own base name.
    private static let subtitleExtensions = [
        "srt", "ass", "ssa", "vtt", "ttml", "dfxp", "smi", "sami", "sub", "mpl2",
        "idx", "sup",
    ]

    private static func isSubtitle(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return subtitleExtensions.contains(ext)
    }

    /// A file's base name with BOTH its own extension and any subtitle
    /// extension removed, so `Movie.mkv` and `Movie.en.srt` pair up.
    private static func baseName(_ name: String) -> String {
        let lower = name.lowercased()
        var base = (name as NSString).deletingPathExtension
        for ext in subtitleExtensions where lower.hasSuffix("." + ext) {
            base = (base as NSString).deletingPathExtension
            break
        }
        return base.lowercased()
    }

    private static func join(_ path: String, _ name: String) -> String {
        let base = normalized(path)
        return base.isEmpty ? name : base + "/" + name
    }

    /// Directories are never media, but obvious clutter is hidden from browsing
    /// so a share root reads cleanly.
    private static func isJunkFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix(".") { return true }
        for token in ["@eaDir", "#recycle", "system volume information", "$recycle.bin"]
        where lower.contains(token) {
            return true
        }
        return false
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
            // Open the primary plus N-1 extra sockets CONCURRENTLY. Opening
            // them one after another cost a full handshake each and was the
            // slowest part of starting playback.
            let cleanPath = Self.normalized(path)
            let user = server.anonymous ? "" : server.username
            let secret = server.anonymous ? "" : password
            let realm = server.domain
            let wanted = Self.prefetchConnectionCount

            var opened: [SMBConnection] = []
            var firstError: Error?
            await withTaskGroup(of: Result<SMBConnection, any Error>.self) { group in
                for _ in 0..<wanted {
                    group.addTask {
                        do {
                            return .success(try await SMBConnection.connect(
                                server: url, share: share, path: cleanPath,
                                user: user, password: secret, domain: realm
                            ))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                for await outcome in group {
                    switch outcome {
                    case .success(let c): opened.append(c)
                    case .failure(let e): if firstError == nil { firstError = e }
                    }
                }
            }

            guard let primary = opened.first else {
                await MainActor.run {
                    SBMLog.log("openShare FAILED \(share)/\(path): \(String(describing: firstError))")
                    completion(nil)
                }
                return
            }
            // Extra sockets are best-effort: one is enough to play, and a
            // NAS that refuses a 4th session still gets a working reader.
            if opened.count < wanted {
                SBMLog.log(
                    "openShare: \(opened.count)/\(wanted) sockets "
                    + "(\(String(describing: firstError)))")
            }
            let ext = (path as NSString).pathExtension
            self.lock.lock()
            self.tokenCounter += 1
            let token = "\(server.id)-\(self.tokenCounter)"
            self.playback[token] = opened
            self.lock.unlock()
            await MainActor.run {
                let tokenURL = "dreamplayersmb://\(token).\(ext.isEmpty ? "mkv" : ext)"
                SBMLog.log(
                    "openShare ok \(share)/\(path) -> \(tokenURL) "
                    + "(\(primary.byteSize) bytes, \(opened.count) socket(s))")
                completion(tokenURL)
            }
        }
    }

    /// Tears down a playback connection by the server id the token embeds.
    private func closeShare(id: String?) {
        guard let id else { return }
        // Honours the player-active latch: the browser calls this on dispose,
        // which can happen while a player is still streaming from the socket.
        closePlayback(serverId: id)
    }

    /// Public so the player view can release its socket on teardown. Must only
    /// be called once the engine has stopped, or a demux thread may still be
    /// mid-read on the connection.
    func closePlayback(serverId: String) {
        lock.lock()
        defer { lock.unlock() }
        if playerActive.contains(serverId) { return }
        let doomed = playback.keys.filter { $0.hasPrefix("\(serverId)-") }
        for token in doomed {
            for c in playback[token] ?? [] { c.close() }
            playback.removeValue(forKey: token)
        }
    }

    /// Called by the player when it takes a connection, and again when it lets
    /// go. While marked, closeShare from the browser is a no-op.
    func setPlayerActive(_ active: Bool, serverId: String) {
        lock.lock()
        if active {
            playerActive.insert(serverId)
        } else {
            playerActive.remove(serverId)
            let doomed = playback.keys.filter { $0.hasPrefix("\(serverId)-") }
            for token in doomed {
                for c in playback[token] ?? [] { c.close() }
                playback.removeValue(forKey: token)
            }
        }
        lock.unlock()
    }

    /// Local error for a host we could not even build a URL for. A distinct
    /// type because `SMBConnection.SMBError`'s memberwise initializer is
    /// internal to AetherEngineSMB and cannot be thrown from here.
    struct BadHost: Error, CustomStringConvertible, LocalizedError {
        let message: String
        var description: String { message }
        var errorDescription: String? { message }
    }

    /// How many independent SMB sockets to open per playback session.
    ///
    /// SMB serialises requests per connection, so a single socket keeps exactly
    /// one read in flight — that ceiling is why one connection felt slow on a
    /// fast NAS. BufferedSMBReader runs `min(4, sources.count)` prefetch
    /// tasks, so 4 is that ceiling.
    ///
    /// A 4-connection attempt previously "failed to play anything" (reverted in
    /// d569489), but that was over AMSMB2/libsmb2, whose first connectShare
    /// EPERMs on iOS — four sockets on a broken transport. The transport is now
    /// a pure-Swift client over NWConnection, so the experiment is worth
    /// repeating. 1 is the safe fallback if a NAS dislikes parallel sessions.
    private static let prefetchConnectionCount = 4

    /// One-shot holder for a connection opened on a background thread. A
    /// class, not a captured `var`: the semaphore's signal/wait is the
    /// happens-before edge, and a reference type makes the sharing explicit.
    private final class ConnectionBox: @unchecked Sendable {
        var connection: SMBConnection?
        var failure: String?
    }

    /// Opens an SMB file from its parts. This is the path a resume takes: the
    /// stored `dreamplayersmb://` token belongs to a previous session and its
    /// connection is long gone, but `smb:<serverId>/<share>/<path>` is durable.
    func openSmb(serverId: String, share: String, path: String) -> SMBConnection? {
        let started = Date()
        loadServersIfNeeded()
        lock.lock()
        let all = Array(servers.values)
        lock.unlock()
        guard let server = all.first(where: { $0.id == serverId }) else {
            SBMLog.log("openSmb: no saved server with id \(serverId)")
            return nil
        }
        return open(
            server: server, share: share, path: path, started: started, tag: "resume"
        )
    }

    /// Opens an SMB file straight from an `smb://host/share/path` URI.
    ///
    /// Not every entry point mints a token first: a bookmarked folder card or a
    /// Continue-Watching entry hands the player its stored `smb://` URI, and
    /// the engine has no `smb` scheme ("protocol not found"). Resolving it
    /// here means every path plays, not just the ones that went through the
    /// browser's openShare. [serverId] comes from the item's resume key
    /// (`smb:<serverId>/<share>/<path>`), with a host match as a fallback.
    func openFromSmbUri(_ uri: String, serverId: String?) -> SMBConnection? {
        let started = Date()
        guard let comps = URLComponents(string: uri), let host = comps.host else {
            SBMLog.log("openFromSmbUri: unparseable \(uri)")
            return nil
        }
        let segments = comps.path.split(separator: "/").map(String.init)
        guard segments.count >= 2 else {
            SBMLog.log("openFromSmbUri: expected /share/path, got \(comps.path)")
            return nil
        }
        let share = segments[0]
        let path = segments.dropFirst().joined(separator: "/")

        loadServersIfNeeded()
        lock.lock()
        let all = Array(servers.values)
        lock.unlock()
        // Prefer the id from the resume key; fall back to host+share match so a
        // stale/missing key still finds the right credentials.
        let server = serverId.flatMap { id in all.first { $0.id == id } }
            ?? all.first { $0.host == host && share.hasPrefix($0.id) == false
                && all.count == 1 }
            ?? all.first { $0.host == host }
        guard let server else {
            SBMLog.log("openFromSmbUri: no saved server for \(host) (id=\(serverId ?? "nil"))")
            return nil
        }
        return open(server: server, share: share, path: path, started: started, tag: "uri")
    }

    /// Shared connect: login + tree connect + stat on a background thread, then
    /// publish the connection under [tag] so it can be found again.
    private func open(
        server: ServerMeta,
        share: String,
        path: String,
        started: Date,
        tag: String
    ) -> SMBConnection? {
        SBMLog.log("open(\(tag)): \(server.name) \(share)/\(path) [\(SBMLog.since(started))]")
        let password = getPassword(server.id)
        let out = ConnectionBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            var serverURL = URLComponents()
            serverURL.scheme = "smb"
            serverURL.host = server.host
            if server.port > 0 && server.port != 445 { serverURL.port = server.port }
            do {
                guard let url = serverURL.url else {
                    throw BadHost(
                        message: "Could not build an smb:// URL for \(server.host)")
                }
                out.connection = try await SMBConnection.connect(
                    server: url,
                    share: share,
                    path: Self.normalized(path),
                    user: server.anonymous ? "" : server.username,
                    password: server.anonymous ? "" : password,
                    domain: server.domain
                )
            } catch {
                out.failure = Self.friendly(error, host: server.host)
            }
            done.signal()
        }
        done.wait()
        if let failure = out.failure {
            SBMLog.log("open(\(tag)) FAILED: \(failure)")
            return nil
        }
        if let result = out.connection {
            let ext = (path as NSString).pathExtension
            let token = "\(server.id)-\(tag)"
            lock.lock()
            for c in playback[token] ?? [] { c.close() }
            playback[token] = [result]
            lock.unlock()
            SBMLog.log("open(\(tag)) ok -> \(result.byteSize) bytes, token \(token).\(ext)")
        }
        return out.connection
    }

    /// The saved-server id embedded in a `dreamplayersmb://` token, or "".
    func serverId(forToken urlString: String) -> String {
        guard urlString.hasPrefix("dreamplayersmb://") else { return "" }
        let tail = String(urlString.dropFirst("dreamplayersmb://".count))
        let stem = (tail as NSString).deletingPathExtension
        let serverId = String(stem.prefix { $0 != "-" })
        return serverId
    }

    /// Every socket for a `dreamplayersmb://` token, primary first. Empty once
    /// the session has been closed.
    func connections(for urlString: String) -> [SMBConnection] {
        guard urlString.hasPrefix("dreamplayersmb://") else { return [] }
        var token = String(urlString.dropFirst("dreamplayersmb://".count))
        if let dot = token.lastIndex(of: ".") {
            token = String(token[token.startIndex..<dot])
        }
        lock.lock()
        defer { lock.unlock() }
        return playback[token] ?? []
    }

    /// The primary (first) socket, or nil once the session is closed.
    func connection(for urlString: String) -> SMBConnection? {
        connections(for: urlString).first
    }
}
