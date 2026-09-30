import AetherEngineSMB
import Flutter
import Foundation
import Network
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
        case "listShares":
            withServer(args["id"] as? String, result: result) { server, reply in
                self.listShares(server: server) { shares in
                    reply(shares, shares == nil ? "Could not list shares" : nil)
                }
            }
        case "addShare":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                self.addShare(server: server, share: share) { ok in
                    reply(ok, ok ? nil : "Could not connect to share \(share)")
                }
            }
        case "listDirectory", "listDirectoryAll":
            withServer(args["id"] as? String, result: result) { server, reply in
                let share = args["share"] as? String ?? ""
                let path = args["path"] as? String ?? ""
                self.listDirectory(server: server, share: share, path: path) { entries in
                    reply(entries, entries == nil ? "Could not read that folder" : nil)
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
            discoverServers { found in
                result(found.map { ["host": $0.host, "hostname": $0.hostname] })
            }
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

    // MARK: - LAN discovery

    /// Scans the local /24 for hosts answering on the SMB port (445).
    ///
    /// A subnet sweep, not NetBIOS broadcast: iOS apps get no broadcast name
    /// service, and a reverse lookup on each hit gives the pretty name. Home
    /// and small-office LANs are /24 in practice; a /16 would take minutes.
    /// Shared, lock-guarded box for results produced on background threads.
    /// A captured `var` written by concurrent task-group children is a data
    /// race even when every write holds a lock: the variable itself lives in a
    /// shared box the compiler is free to treat as non-atomic. A reference type
    /// makes the sharing explicit. Same pattern as SMBIOReader's ReadOutcome.
    private final class HostBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(host: String, hostname: String)] = []
        func append(_ host: String, _ hostname: String) {
            lock.lock(); items.append((host, hostname)); lock.unlock()
        }
        func snapshot() -> [(host: String, hostname: String)] {
            lock.lock(); defer { lock.unlock() }; return items
        }
    }

    private func discoverServers(completion: @escaping ([(host: String, hostname: String)]) -> Void) {
        let started = Date()
        Task.detached(priority: .utility) {
            let box = HostBox()
            guard let local = Self.localIPv4() else {
                await MainActor.run {
                    SBMLog.log("discover: no non-loopback IPv4 interface found")
                    completion([])
                }
                return
            }
            SBMLog.log("discover: sweeping \(local)/24 on port 445")
            let prefix = local.split(separator: ".").dropLast().joined(separator: ".")
                // A small worker pool: a serial sweep of 254 hosts at a
                // 250ms timeout each would take a minute on a dead subnet.
                let hosts = (1...254).map { "\(prefix).\($0)" }
                let workers = 24
                let chunk = max(hosts.count / workers, 1)
                await withTaskGroup(of: Void.self) { group in
                    var index = 0
                    while index < hosts.count {
                        let end = min(index + chunk, hosts.count)
                        let slice = Array(hosts[index..<end])
                        index = end
                        group.addTask {
                            for host in slice
                            where await Self.port445OpenNW(host: host, timeout: 0.6) {
                                box.append(host, Self.reverseName(host))
                            }
                        }
                    }
                }
            await MainActor.run {
                let sorted = box.snapshot().sorted { $0.host < $1.host }
                SBMLog.log(
                    "discover: \(sorted.count) host(s) in \(SBMLog.since(started))"
                    + (sorted.isEmpty ? " lastFailure=\(Self.lastProbeFailure)" : "")
                    + " -> "
                    + sorted.map { "\($0.host)\(($0.hostname == $0.host ? "" : " (\($0.hostname))"))" }.joined(separator: ", "))
                completion(sorted)
            }
        }
    }

    /// First non-loopback IPv4 on an up interface, as a dotted string.
    private static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var result: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            let family = cur.pointee.ifa_addr.pointee.sa_family
            if flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0, family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(cur.pointee.ifa_addr.pointee.sa_len)
                if getnameinfo(
                    cur.pointee.ifa_addr, len,
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
                ) == 0 {
                    result = String(cString: host)
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return result
    }

    /// Non-blocking TCP connect to port 445 with a poll() timeout.
    /// Why a probe failed, for a host the user believes is on the LAN. The
    /// first sweep returned 0 hosts in 2 ms, which is impossible for a real
    /// network scan, so the failure has to be before any packets move.
    private static var lastProbeFailure: String = ""
    /// One queue for every probe connection, so 24 parallel sweeps cannot
    /// spawn 24 run-loop threads.
    private static let probeQueue = DispatchQueue(
        label: "app.dreamplayer.smb.probe", qos: .utility, attributes: .concurrent)

    /// TCP reachability over Network.framework.
    ///
    /// A raw BSD connect() to a LAN address returns EPERM on iOS: Local Network
    /// privacy gates it, and the denial is immediate — which is why the first
    /// sweep reported 0 hosts in 2 ms. Network.framework is the transport the
    /// rest of the app already uses successfully (every SMB session goes
    /// through SMBClient's NWConnection), so the probe uses it too rather than
    /// being refused by a gate the app has already been granted.
    private static func port445OpenNW(host: String, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            // The timeout is a sibling task rather than asyncAfter: a
            // DispatchQueue closure capturing the continuation (and the
            // NWConnection) is an escaping @Sendable capture of both, and it
            // also could not be cancelled — a fast .ready left the timer to
            // fire later and write a stale failure reason.
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    let conn = NWConnection(
                        host: NWEndpoint.Host(host), port: 445, using: .tcp)
                    let once = ProbeOnce()
                    let finish: (Bool) -> Void = { ok in
                        if once.claim() {
                            conn.cancel()
                            cont.resume(returning: ok)
                        }
                    }
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready: finish(true)
                        case .failed(let error):
                            lastProbeFailure = "nw(\(host))=\(error)"
                            finish(false)
                        case .cancelled: finish(false)
                        default: break
                        }
                    }
                    conn.start(queue: probeQueue)
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        lastProbeFailure = "nw(\(host)) timeout"
                        finish(false)
                    }
                }
            }
            // First task to finish wins; the other is cancelled by scope exit.
            for await result in group where result {
                return true
            }
            return false
        }
    }

    /// One-shot guard so a probe continuation resumes exactly once, whichever
    /// of {ready, failed, cancelled, timeout} gets there first.
    private final class ProbeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    /// Reverse DNS, falling back to the address itself when the LAN has no
    /// name service (most home routers do not).
    private static func reverseName(_ host: String) -> String {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_flags = AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let ai = res else { return host }
        defer { freeaddrinfo(res) }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(
            ai.pointee.ai_addr, socklen_t(ai.pointee.ai_addrlen),
            &name, socklen_t(name.count), nil, 0, NI_NAMEREQD
        ) == 0 {
            return String(cString: name)
        }
        return host
    }

    // MARK: - Browsing

    private func listShares(
        server: ServerMeta,
        completion: @escaping ([[String: Any]]?) -> Void
    ) {
        withClient(server) { client in
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
        withClient(server) { client in
            Task {
                var ok = false
                do {
                    try await client.connectShare(share)
                    ok = true
                } catch {
                    ok = false
                }
                _ = try? await client.logoff()
                client.session.disconnect()
                await MainActor.run { completion(ok) }
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

        withClient(server) { client in
            Task {
                var built: [[String: Any]]?
                do {
                    try await client.connectShare(share)
                    let files = try await client.listDirectory(path: Self.normalized(path))
                    built = self.buildEntries(files: files, share: share, path: path)
                    self.lock.lock()
                    self.listingCache[key] = CachedListing(built!)
                    self.lock.unlock()
                } catch {
                    built = nil
                }
                _ = try? await client.logoff()
                client.session.disconnect()
                await MainActor.run { completion(built) }
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
            await withTaskGroup(of: Result<SMBConnection, Error>.self) { group in
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
