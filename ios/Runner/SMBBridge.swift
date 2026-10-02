import AetherEngineSMB
import Flutter
import Foundation
import Network
import Security

/// In-app SMB2/3 browsing and playback for iOS, entirely on libsmb2.
///
/// libsmb2 (LGPL 2.1, vendored under `Runner/libsmb2`) does everything: it
/// connects, lists shares and directories, stats and fetches small files, and
/// serves playback reads through a synchronous `smb2_pread` reader. The
/// `SMBClient` package that used to drive browsing here has been removed — it
/// was the reason browsing and playback behaved differently, and it is why the
/// old transport needed an async-to-sync reader adaptation that deadlocked.
///
/// SMB2 has no share-enumeration request, so `listShares` probes a list of
/// common share names plus any the user added by hand, exactly as Android does.
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
        /// Share names the user added by hand. SMB2 cannot enumerate shares, so
        /// these are merged into the probe list in `listShares`. Optional so
        /// servers saved before this field existed still decode — a synthesized
        /// `Codable` ignores a declared default for a missing key.
        var addedShares: [String]?
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
    private var playback: [String: SMBPlayback] = [:]
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
                result(found.map { entry in
                    var row: [String: Any] = [
                        "host": entry.host,
                        "hostname": entry.hostname,
                    ]
                    if let dialect = entry.dialectLabel, !dialect.isEmpty {
                        row["dialect"] = dialect
                    }
                    if let guid = entry.serverGuid, !guid.isEmpty {
                        row["serverGuid"] = guid
                    }
                    return row
                })
            }
        case "checkServer":
            // Android answers this with a TCP connect to the SMB port. iOS
            // returned a hardcoded false, so every saved server showed a red
            // dot even when it was perfectly reachable.
            // `args` is non-optional here (the handler takes [String: Any]), so
            // optional chaining on it does not compile.
            let host = (args["host"] as? String) ?? ""
            let port = (args["port"] as? NSNumber)?.uint16Value ?? 445
            guard !host.isEmpty else {
                result(FlutterError(code: "bad_args",
                                    message: "Missing host", details: nil))
                return
            }
            let probe = DispatchQueue(label: "app.dreamplayer.smb2.status",
                                      qos: .utility)
            probe.async {
                let open = Self.isPortOpen(host: host, port: port, timeout: 1.5)
                // A FlutterResult invoked off the main thread deadlocks the
                // method channel, so hop back before replying.
                DispatchQueue.main.async { result(open) }
            }
        case "startLoopback", "stopLoopback":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// TCP reachability probe, matching Android's `isPortOpen` (1.5 s cap).
    ///
    /// BSD sockets rather than Network.framework: this only needs `connect(2)`,
    /// and the non-blocking-connect-then-poll shape is the one FtpClient and
    /// UpnpClient already use successfully here.
    private static func isPortOpen(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // inet_pton, not inet_addr: the latter returns INADDR_NONE for a name it
        // cannot parse, which would silently probe 255.255.255.255.
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let inProgress: Bool = withUnsafePointer(to: &addr) { ptr in
            let sock = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            if connect(fd, sock, addrLen) == 0 { return false }  // connected outright
            return errno == EINPROGRESS
        }
        guard inProgress else { return false }

        // One wedged host must not hold up every other server's dot.
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
        var soerr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len) == 0 else {
            return false
        }
        return soerr == 0
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
            anonymous: args["anonymous"] as? Bool ?? false,
            // Carried over: the add/edit dialog knows nothing about them, and
            // dropping them would silently un-list any hand-added share.
            addedShares: servers[id]?.addedShares
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

    /// Mutates one saved server in place and re-persists the set.
    ///
    /// `saveServer` rebuilds a `ServerMeta` from the dialog's arguments, so it
    /// cannot be used for a field the dialog does not know about — hand-added
    /// share names would be wiped on every edit of the server.
    private func updateServer(_ id: String, _ mutate: (inout ServerMeta) -> Void) {
        loadServersIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard var meta = servers[id] else { return }
        mutate(&meta)
        servers[id] = meta
        if let data = try? JSONEncoder().encode(Array(servers.values)) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
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

    /// A connected libsmb2 session for one share, or a friendly error.
    ///
    /// One session per call and always closed afterwards: browsing is a series
    /// of short list/open operations, and libsmb2 keeps all of its per-connection
    /// state in the context, so a session cannot be reused across shares. This
    /// replaced an `SMBClient` session, which is why the browse path no longer
    /// needs that package at all.
    private func withShareSession(
        _ server: ServerMeta,
        share: String,
        password: String? = nil,
        timeout: Int = 10,
        _ body: @escaping @MainActor (LibSMB2Session) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            let secret = password ?? getPassword(server.id)
            do {
                let session = try LibSMB2.openSession(
                    toHost: server.host,
                    port: UInt16(truncatingIfNeeded: server.port),
                    user: server.anonymous ? nil : server.username,
                    password: server.anonymous ? nil : secret,
                    domain: server.domain.isEmpty ? nil : server.domain,
                    share: share,
                    timeout: timeout)
                SBMLog.log(
                    "connect ok: \(server.host):\(server.port) \\(share) as "
                    + "\(server.anonymous || server.username.isEmpty ? "guest/anon" : server.username)")
                await MainActor.run { body(session) }
                session.close()
            } catch {
                let message = Self.friendly(error, host: server.host)
                SBMLog.log("connect FAILED \(server.host):\(server.port): \(message)")
                await MainActor.run { onError(message) }
            }
        }
    }

    /// Opens a one-off libsmb2 session on a background thread and hands the
    /// result back, for callers that do not want the `withShareSession` shape.
    private func withDetachedSession<T>(
        _ server: ServerMeta,
        share: String,
        password: String? = nil,
        timeout: Int = 10,
        _ body: @escaping (LibSMB2Session) throws -> T
    ) async throws -> T {
        let secret = password ?? getPassword(server.id)
        return try await Task.detached(priority: .userInitiated) {
            let session = try LibSMB2.openSession(
                toHost: server.host,
                port: UInt16(truncatingIfNeeded: server.port),
                user: server.anonymous ? nil : server.username,
                password: server.anonymous ? nil : secret,
                domain: server.domain.isEmpty ? nil : server.domain,
                share: share,
                timeout: timeout)
            defer { session.close() }
            return try body(session)
        }.value
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
        Task.detached(priority: .userInitiated) {
            // Probing for shares proves the credentials AND the tree connect,
            // not just that the socket opened.
            var message: String?
            var ok = false
            do {
                let shares = try LibSMB2.listShares(
                    forHost: host,
                    port: UInt16(truncatingIfNeeded: port),
                    user: anonymous ? nil : username,
                    password: anonymous ? nil : password,
                    domain: domain.isEmpty ? nil : domain,
                    extraShareNames: nil,
                    timeout: 10)
                ok = shares != nil
            } catch {
                message = Self.friendly(error, host: host)
                ok = false
            }
            await MainActor.run {
                completion(ok, ok ? nil : (message ?? "Connected, but could not list shares"))
            }
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
    /// makes the sharing explicit. Same pattern as PlaybackBox above.
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

    private func discoverServers(
        completion: @escaping ([(
            host: String, hostname: String, dialectLabel: String?, serverGuid: String?
        )]) -> Void
    ) {
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
            // A TCP connect only proves something is listening on 445, so the
            // survivors get a real SMB negotiate through libsmb2: connecting to
            // IPC$ forces the handshake and yields the negotiated dialect and
            // the server's GUID. Cheap TCP rejection first means we only build
            // SMB contexts for hosts that plausibly speak SMB at all.
            let candidates = box.snapshot()
            SBMLog.log(
                "discover: sweep done in \(SBMLog.since(started)) — "
                + "\(candidates.count) host(s) answered 445: "
                + (candidates.map(\.host).joined(separator: ", "))
            )
            let identified = await withCheckedContinuation {
                (continuation: CheckedContinuation<[LibSMB2Server], Never>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: LibSMB2.probeHosts(
                        candidates.map(\.host),
                        port: 445,
                        timeout: 2,
                        maxParallel: 12
                    ))
                }
            }
            let byHost = Dictionary(
                uniqueKeysWithValues: identified.map { ($0.host, $0) })
            SBMLog.log(
                "discover: SMB identify done in \(SBMLog.since(started)) — "
                + "\(byHost.count)/\(candidates.count) completed an SMB negotiate")

            await MainActor.run {
                let sorted = candidates.compactMap { entry -> (
                    host: String, hostname: String, dialectLabel: String?, serverGuid: String?
                )? in
                    // Only report hosts that completed an SMB negotiate. The old
                    // behaviour listed anything with 445 open, which put devices
                    // that merely bind the port into the server list.
                    guard let info = byHost[entry.host] else { return nil }
                    return (
                        entry.host, entry.hostname,
                        info.dialectLabel.isEmpty ? nil : info.dialectLabel,
                        info.serverGuid
                    )
                }.sorted { $0.host < $1.host }
                SBMLog.log(
                    "discover: \(sorted.count) host(s) in \(SBMLog.since(started))"
                    + (sorted.isEmpty ? " lastFailure=\(Self.lastProbeFailure)" : "")
                    + " -> "
                    + sorted.map { entry in
                        let name = entry.hostname == entry.host
                            ? "" : " (\(entry.hostname))"
                        let dialect = entry.dialectLabel.map { " [\($0)]" } ?? ""
                        return "\(entry.host)\(name)\(dialect)"
                    }.joined(separator: ", "))
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

    /// The playback transport: one libsmb2 session, tree connect and file open.
    ///
    /// Required, not best-effort, and there is deliberately no second session
    /// here: running two meant two negotiates, two session setups, two tree
    /// connects and two file handles per play, with the spare one never read
    /// from — which also spent a server-side open-session slot and held the
    /// credentials twice.
    private static func openLibSMB2(
        host: String,
        port: UInt16,
        share: String,
        user: String?,
        password: String?,
        domain: String?,
        path: String
    ) throws -> (LibSMB2File, LibSMB2Session) {
        // A nullable return plus a trailing NSError** imports into Swift as
        // `throws` with the error argument removed, so these are `try` calls
        // rather than out-parameter calls.
        let session: LibSMB2Session
        do {
            session = try LibSMB2.openSession(
                toHost: host, port: port, user: user, password: password,
                domain: domain, share: share, timeout: 10)
        } catch {
            SBMLog.log("libsmb2 session failed: \(error.localizedDescription)")
            throw error
        }
        let file: LibSMB2File
        do {
            file = try session.openFile(path)
        } catch {
            SBMLog.log("libsmb2 open failed: \(error.localizedDescription)")
            session.close()
            throw error
        }
        return (file, session)
    }

    /// Why a probe failed, for a host the user believes is on the LAN.
    ///
    /// Written from two different queues: the state handler runs on `probeQueue`
    /// while the probe's own deadline timer runs on a global queue. `String` is
    /// not atomically assignable, so an unsynchronised write from both can tear
    /// and crash, and a /24 sweep does exactly that in parallel. Same
    /// lock-then-copy shape as HostBox below.
    private static let probeFailureLock = NSLock()
    private static var storedProbeFailure: String = ""
    private static var lastProbeFailure: String {
        get {
            probeFailureLock.lock()
            defer { probeFailureLock.unlock() }
            return storedProbeFailure
        }
        set {
            probeFailureLock.lock()
            storedProbeFailure = newValue
            probeFailureLock.unlock()
        }
    }

    /// One queue for every probe connection, so a parallel sweep cannot spawn
    /// one run-loop thread per host.
    private static let probeQueue = DispatchQueue(
        label: "app.dreamplayer.smb.probe", qos: .utility, attributes: .concurrent)

    /// TCP reachability over Network.framework.
    ///
    /// A raw BSD connect() to a LAN address returns EPERM on iOS: Local Network
    /// privacy gates it, and the denial is immediate — which is why the first
    /// sweep returned 0 hosts in 2 ms. Network.framework is the transport the
    /// rest of the app already uses successfully, so the probe uses it too rather
    /// than being refused by a gate the app has already been granted.
    ///
    /// Is something listening on 445?
    ///
    /// The deadline lives *inside* the probe rather than beside it. It used to be
    /// a second child of a task group racing the connection, which could only end
    /// early on success: when the timer won, the loop carried on waiting for the
    /// connection, and NWConnection sits in `.waiting` indefinitely for a
    /// filtered or unrouted address without ever calling back. One blackholed
    /// host in the /24 therefore hung the whole sweep — which is why discovery
    /// never returned a single result.
    private static func port445OpenNW(host: String, timeout: TimeInterval) async -> Bool {
        await nwConnect(host: host, timeout: timeout) == .open
    }

    /// One NWConnection attempt with its own hard deadline.
    ///
    /// Always resolves within `timeout`: whichever gets there first — `.ready`,
    /// `.failed`, `.cancelled`, or the timer — wins, and `ProbeOnce` keeps the
    /// continuation to a single resume.
    private static func nwConnect(host: String, timeout: TimeInterval) async -> ProbeOutcome {
        await withCheckedContinuation {
            (cont: CheckedContinuation<ProbeOutcome, Never>) in
            let conn = NWConnection(
                host: NWEndpoint.Host(host), port: 445, using: .tcp)
            let once = ProbeOnce()
            let finish: (Bool) -> Void = { ok in
                if once.claim() {
                    conn.cancel()
                    cont.resume(returning: ok ? .open : .gaveUp)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout
            ) {
                if !once.claimed {
                    lastProbeFailure = "nw(\(host)) timeout"
                }
                finish(false)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed(let error):
                    lastProbeFailure = "nw(\(host))=\(error)"
                    finish(false)
                case .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            conn.start(queue: probeQueue)
        }
    }

    /// A probe's single verdict, so the call site reads as "did the port answer"
    /// rather than as two anonymous Bools racing each other.
    private enum ProbeOutcome: Sendable, Equatable {
        case open
        case gaveUp
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
        /// Already settled by another path, so a late caller has nothing to add.
        var claimed: Bool {
            lock.lock(); defer { lock.unlock() }
            return done
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
        Task.detached(priority: .userInitiated) {
            do {
                // SMB2 has no share-enumeration request, so this probes the
                // common names plus anything the user added by hand. The
                // `print$`/IPC$ filter is no longer needed: hidden shares are
                // filtered by the trailing `$` when the names are built.
                let shares = try LibSMB2.listShares(
                    forHost: server.host,
                    port: UInt16(truncatingIfNeeded: server.port),
                    user: server.anonymous ? nil : server.username,
                    password: server.anonymous ? nil : getPassword(server.id),
                    domain: server.domain.isEmpty ? nil : server.domain,
                    extraShareNames: server.addedShares ?? [],
                    timeout: 10)
                // Dart parses these as SmbEntry, so return entry-shaped maps.
                let entries = (shares ?? []).map { share in
                    [
                        "name": share,
                        "path": share,
                        "isDirectory": true,
                        "size": 0,
                        "modified": 0,
                    ] as [String: Any]
                }
                await MainActor.run { completion(entries) }
            } catch {
                await MainActor.run { completion(nil) }
            }
        }
    }

    private func addShare(
        server: ServerMeta,
        share: String,
        completion: @escaping (Bool) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            var ok = false
            do {
                let session = try LibSMB2.openSession(
                    toHost: server.host,
                    port: UInt16(truncatingIfNeeded: server.port),
                    user: server.anonymous ? nil : server.username,
                    password: server.anonymous ? nil : getPassword(server.id),
                    domain: server.domain.isEmpty ? nil : server.domain,
                    share: share,
                    timeout: 10)
                session.close()
                ok = true
            } catch {
                ok = false
            }
            await MainActor.run {
                // Remember the name only once it is known to tree-connect, and
                // only when it is not already on the list. This is the whole
                // point of the affordance: the name has to survive so the next
                // probe finds it again.
                if ok, !share.isEmpty {
                    updateServer(server.id) { meta in
                        var names = meta.addedShares ?? []
                        if !names.contains(share) {
                            names.append(share)
                        }
                        meta.addedShares = names
                    }
                }
                completion(ok)
            }
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

        Task.detached(priority: .userInitiated) {
            var built: [[String: Any]]?
            do {
                let session = try LibSMB2.openSession(
                    toHost: server.host,
                    port: UInt16(truncatingIfNeeded: server.port),
                    user: server.anonymous ? nil : server.username,
                    password: server.anonymous ? nil : getPassword(server.id),
                    domain: server.domain.isEmpty ? nil : server.domain,
                    share: share,
                    timeout: 10)
                defer { session.close() }
                let entries = try session.listDirectory(Self.normalized(path))
                built = self.buildEntries(entries: entries ?? [], share: share, path: path)
                if let built {
                    self.lock.lock()
                    self.listingCache[key] = CachedListing(built)
                    self.lock.unlock()
                }
            } catch {
                built = nil
            }
            await MainActor.run { completion(built) }
        }
    }

    /// Normalises a browse path the way the Dart side hands it over: no
    /// leading slash, no trailing slash, no `//` runs.
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
        entries: [LibSMB2Entry],
        share: String,
        path: String
    ) -> [[String: Any]] {
        let files = entries
        let subtitles = files.filter { Self.isSubtitle($0.name) }
        let subtitleBases = subtitles.map { Self.baseName($0.name) }

        return files
            .filter { !$0.name.isEmpty }
            // `.` and `..` come back as directories, and the next line exempts
            // directories from the junk filter, so the dot-prefix rule never
            // reached them. Drop them by name first, before that exemption.
            .filter { Self.isDotEntry($0.name) == false }
            .filter { $0.isDirectory || !Self.isJunk($0.name) }
            .map { file -> [String: Any] in
                var entry: [String: Any] = [
                    "name": file.name,
                    "path": Self.join(path, file.name),
                    "isDirectory": file.isDirectory,
                    "size": file.size,
                    "modified": Int(file.modifiedMillis),
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
    /// `.`, `..` and friends. Checked by name because they are reported as
    /// directories and would otherwise survive every directory-shaped exemption.
    private static func isDotEntry(_ name: String) -> Bool {
        if name == "." || name == ".." { return true }
        // A Samba administrative share: print$, IPC$, admin$, homes$ … The
        // share `type` filter in listShares does not catch these reliably —
        // print$ in particular arrives tagged like a normal disk share on some
        // servers — so the trailing `$` is the dependable signal.
        return name.hasSuffix("$")
    }

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
            // One session for the whole batch: each stat is a tiny query, and
            // re-authenticating per path would be absurd. Best effort — paths
            // that fail simply stay absent and render as size 0.
            if let session = try? LibSMB2.openSession(
                toHost: server.host,
                port: UInt16(truncatingIfNeeded: server.port),
                user: server.anonymous ? nil : server.username,
                password: server.anonymous ? nil : password,
                domain: server.domain.isEmpty ? nil : server.domain,
                share: share,
                timeout: 10) {
                for path in paths {
                    var size: Int64 = 0
                    if (try? session.fileSize(atPath: Self.normalized(path), size: &size)) != nil {
                        sizes[path] = Int(size)
                    }
                }
                session.close()
            }
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
            let want = maxBytes > 0 ? maxBytes : (50 * 1024 * 1024)
            // One bounded read; sidecars are small, and a single call keeps this
            // off the reopen/track-switch critical path.
            if let session = try? LibSMB2.openSession(
                toHost: server.host,
                port: UInt16(truncatingIfNeeded: server.port),
                user: server.anonymous ? nil : server.username,
                password: server.anonymous ? nil : password,
                domain: server.domain.isEmpty ? nil : server.domain,
                share: share,
                timeout: 10),
               let data = try? session.readFile(
                atPath: Self.normalized(path), offset: 0, length: want) {
                session.close()
                await MainActor.run { completion(FlutterStandardTypedData(bytes: data)) }
            } else {
                await MainActor.run { completion(nil) }
            }
        }
    }

    // MARK: - Playback

    /// Opens an SMB file for playback and returns the token URL the player
    /// resolves back to the live session.
    ///
    /// One authenticated session, one tree connect, one open file handle. The
    /// parallel-socket scheme that fed BufferedSMBReader's prefetch tasks is gone
    /// with it: reads are independent ranged READs, so extra sockets bought
    /// nothing and only multiplied the logins.
    private func openShare(
        server: ServerMeta,
        share: String,
        path: String,
        completion: @escaping (String?) -> Void
    ) {
        let password = getPassword(server.id)
        Task.detached(priority: .userInitiated) {
            let cleanPath = Self.normalized(path)
            do {
                let (file, session) = try Self.openLibSMB2(
                    host: server.host,
                    port: UInt16(truncatingIfNeeded: server.port),
                    share: share,
                    user: server.anonymous ? nil : server.username,
                    password: server.anonymous ? nil : password,
                    domain: server.domain.isEmpty ? nil : server.domain,
                    path: cleanPath
                )
                let size = UInt64(max(0, file.fileSize))
                SBMLog.log("openShare: playback transport = libsmb2")

                let ext = (path as NSString).pathExtension
                self.lock.lock()
                self.tokenCounter += 1
                let token = "\(server.id)-\(self.tokenCounter)"
                self.playback[token]?.close()
                self.playback[token] = SMBPlayback(file: file, session: session)
                self.lock.unlock()
                await MainActor.run {
                    let tokenURL = "dreamplayersmb://\(token).\(ext.isEmpty ? "mkv" : ext)"
                    SBMLog.log(
                        "openShare ok \(share)/\(path) -> \(tokenURL) (\(size) bytes)")
                    completion(tokenURL)
                }
            } catch {
                let message = Self.friendly(error, host: server.host)
                await MainActor.run {
                    SBMLog.log("openShare FAILED \(share)/\(path): \(message)")
                    completion(nil)
                }
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
            playback[token]?.close()
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
                playback[token]?.close()
                playback.removeValue(forKey: token)
            }
        }
        lock.unlock()
    }

    /// One-shot holder for a session opened on a background thread. A class, not
    /// a captured `var`: the semaphore's signal/wait is the happens-before edge.
    private final class PlaybackBox: @unchecked Sendable {
        var playback: SMBPlayback?
        var failure: String?
    }

    /// Opens an SMB file from its parts. This is the path a resume takes: the
    /// stored `dreamplayersmb://` token belongs to a previous session and its
    /// connection is long gone, but `smb:<serverId>/<share>/<path>` is durable.
    func openSmb(serverId: String, share: String, path: String) -> SMBPlayback? {
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
    func openFromSmbUri(_ uri: String, serverId: String?) -> SMBPlayback? {
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

    /// Shared connect: login, tree connect and open the file on a background
    /// thread, then publish the session under [tag] so it can be found again.
    private func open(
        server: ServerMeta,
        share: String,
        path: String,
        started: Date,
        tag: String
    ) -> SMBPlayback? {
        SBMLog.log("open(\(tag)): \(server.name) \(share)/\(path) [\(SBMLog.since(started))]")
        let password = getPassword(server.id)
        let out = PlaybackBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let (file, session) = try Self.openLibSMB2(
                    host: server.host,
                    port: UInt16(truncatingIfNeeded: server.port),
                    share: share,
                    user: server.anonymous ? nil : server.username,
                    password: server.anonymous ? nil : password,
                    domain: server.domain.isEmpty ? nil : server.domain,
                    path: Self.normalized(path)
                )
                SBMLog.log("open(\(tag)): playback transport = libsmb2")
                out.playback = SMBPlayback(file: file, session: session)
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
        guard let result = out.playback else { return nil }
        let ext = (path as NSString).pathExtension
        let token = "\(server.id)-\(tag)"
        lock.lock()
        playback[token]?.close()
        playback[token] = result
        lock.unlock()
        SBMLog.log("open(\(tag)) ok -> \(result.byteSize) bytes, token \(token).\(ext)")
        return result
    }

    /// The saved-server id embedded in a `dreamplayersmb://` token, or "".
    func serverId(forToken urlString: String) -> String {
        guard urlString.hasPrefix("dreamplayersmb://") else { return "" }
        let tail = String(urlString.dropFirst("dreamplayersmb://".count))
        let stem = (tail as NSString).deletingPathExtension
        let serverId = String(stem.prefix { $0 != "-" })
        return serverId
    }

    /// The live session for a `dreamplayersmb://` token, or nil once closed.
    func session(for urlString: String) -> SMBPlayback? {
        guard urlString.hasPrefix("dreamplayersmb://") else { return nil }
        var token = String(urlString.dropFirst("dreamplayersmb://".count))
        if let dot = token.lastIndex(of: ".") {
            token = String(token[token.startIndex..<dot])
        }
        lock.lock()
        defer { lock.unlock() }
        return playback[token]
    }

}
