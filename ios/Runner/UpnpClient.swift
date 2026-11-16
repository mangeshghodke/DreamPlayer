import Flutter
import Foundation
import Network

/// iOS DLNA / UPnP ContentDirectory browser (channel `dreamplayer/upnp`),
/// mirroring `UpnpClient.kt` on Android.
///
/// Discovery is SSDP M-SEARCH to 239.255.255.250:1900; browsing is SOAP
/// ContentDirectory#Browse against the device's controlURL. HTTP is plain
/// URLSession - DLNA servers are LAN http.
final class UpnpClient: NSObject {

    static let shared = UpnpClient()
    private static let channelName = "dreamplayer/upnp"

    private let standardSession: URLSession
    private var serverCache: [String: UpnpServer] = [:]
    private let cacheQueue = DispatchQueue(label: "dreamplayer.upnp.cache")

    /// Last discovery diagnostics - surfaced to the Dart UI via
    /// `getDiagnostics` so failures are visible on-device (no Mac console).
    private static var lastDiag: [String] = []
    private static func diag(_ line: String) {
        NSLog("[UpnpClient] %@", line)
        lastDiag.append(line)
        if lastDiag.count > 80 { lastDiag.removeFirst(lastDiag.count - 80) }
    }

    private struct UpnpServer {
        let id: String
        let name: String
        let location: String
        let controlUrl: String
        let baseUrl: String
        func toMap() -> [String: Any] { ["id": id, "name": name, "location": location, "controlUrl": controlUrl, "baseUrl": baseUrl] }
    }

    private override init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        standardSession = URLSession(configuration: config)
        super.init()
    }

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "discover":
            Self.lastDiag.removeAll()
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let servers = try await self.discover()
                    self.respond(result, servers.map { $0.toMap() })
                } catch {
                    self.respond(result, FlutterError(code: "upnp", message: error.localizedDescription, details: nil))
                }
            }
        case "getDiagnostics":
            result(Self.lastDiag)
        case "browse":
            guard let args = call.arguments as? [String: Any],
                  let serverId = args["serverId"] as? String else {
                result(FlutterError(code: "bad_args", message: "Missing serverId", details: nil))
                return
            }
            let objectId = args["objectId"] as? String ?? "0"
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let entries = try await self.browse(serverId: serverId, objectId: objectId)
                    self.respond(result, entries)
                } catch {
                    self.respond(result, FlutterError(code: "upnp", message: error.localizedDescription, details: nil))
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func respond(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    // MARK: - Discovery (SSDP)

    private func discover() async throws -> [UpnpServer] {
        Self.diag("discover: localIP=\(Self.localIPv4Address() ?? "nil")")
        let locations = try await ssdpLocations()
        var servers: [String: UpnpServer] = [:]
        for loc in locations {
            if let srv = try? await fetchDeviceInfo(location: loc), !srv.controlUrl.isEmpty {
                servers[srv.id] = srv
            } else {
                Self.diag("device fetch failed for \(loc)")
            }
        }
        // iOS multicast may be blocked without the entitlement (or on a
        // simulator where the 239.255.255.250 route is missing). If SSDP
        // found nothing, synthesize a DLNA entry from any saved Jellyfin
        // server - Jellyfin's DLNA publisher is at
        // http://<host>:8096/dlna/<uuid>/description.xml (uuid from
        // /System/Info/Public) and is the DLNA service running on this
        // LAN (Rogscar-Ubuntu). This at least makes 192.168.1.16 show up
        // on iPad even when multicast is gated.
        if servers.isEmpty {
            Self.diag("SSDP empty → Jellyfin fallback")
            for srv in await jellyfinDLNAFallback() {
                servers[srv.id] = srv
            }
        }
        let list = Array(servers.values)
        cacheQueue.sync { serverCache = servers }
        Self.diag("discover done \(list.count) server(s)")
        return list
    }

    /// Synthesizes DLNA servers from saved Jellyfin hosts when SSDP is
    /// gated. Reads `flutter.dreamplayer.jellyfinServers` (SharedPreferences
    /// JSON string) and probes each host's DLNA description.xml. If no saved
    /// hosts exist (fresh install, never opened Jellyfin screen), it falls
    /// back to the Jellyfin 7359 UDP broadcast (same as JellyfinDiscovery) to
    /// find 192.168.1.16 on the LAN and probes its DLNA - so Rogscar-Ubuntu
    /// shows even on a fresh iPad without any prior Jellyfin setup.
    private func jellyfinDLNAFallback() async -> [UpnpServer] {
        let key = "flutter.dreamplayer.jellyfinServers"
        if let json = UserDefaults.standard.string(forKey: key),
           let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            Self.diag("Jellyfin prefs: \(arr.count) saved")
            var out: [UpnpServer] = []
            for entry in arr {
                guard let urlStr = entry["url"] as? String, !urlStr.isEmpty,
                      let url = URL(string: urlStr),
                      let host = url.host else { continue }
                let base = "\(url.scheme ?? "http")://\(host)\(url.port.map { ":\($0)" } ?? "")"
                if let srv = await probeJellyfinDLNA(base: base) {
                    Self.diag("saved host OK \(base) → \(srv.name)")
                    out.append(srv)
                } else {
                    Self.diag("saved host FAIL \(base)")
                }
            }
            if !out.isEmpty { return out }
        } else {
            Self.diag("Jellyfin prefs: none (key \(key))")
        }
        // No saved hosts or none had DLNA - discover via 7359 broadcast like
        // JellyfinDiscovery (SO_BROADCAST to 255.255.255.255:7359, no multicast
        // entitlement needed). The host at 192.168.1.16 answers with
        // {"Address":"192.168.1.16:8096","Name":"Rogscar-Ubuntu",...}
        let addrs = jellyfin7359Broadcast()
        Self.diag("7359 broadcast: \(addrs.count) addr(s)")
        var out: [UpnpServer] = []
        for addr in addrs {
            // addr is "192.168.1.16:8096" or "192.168.1.16"
            let hostPort = addr.contains(":") ? addr : "\(addr):8096"
            let base = "http://\(hostPort)"
            if let srv = await probeJellyfinDLNA(base: base) {
                Self.diag("7359 host OK \(base) → \(srv.name)")
                out.append(srv)
            }
        }
        // Last resort: directly probe this LAN's known Jellyfin host
        // (covers the 7359 UDP being blocked by UFW without 7359/udp allow).
        if out.isEmpty {
            Self.diag("direct probe http://192.168.1.16:8096 …")
            if let srv = await probeJellyfinDLNA(base: "http://192.168.1.16:8096") {
                Self.diag("direct probe OK → \(srv.name)")
                out.append(srv)
            } else {
                Self.diag("direct probe FAILED (LAN blocked? Local Network denied?)")
            }
        }
        return out
    }

    /// 7359 broadcast probe (copied from JellyfinDiscovery, no multicast).
    private func jellyfin7359Broadcast() -> [String] {
        var addrs: [String] = []
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { return addrs }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        let msg = Data("who is JellyfinServer?".utf8)
        // Use the same poll loop as JellyfinDiscovery so the main thread isn't blocked
        guard let localIP = Self.localIPv4Address() else { return addrs }
        let bcast = broadcastAddress(for: localIP)
        let targets = [ "255.255.255.255", bcast ].filter { !$0.isEmpty }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            for t in targets {
                guard let addr = Self.sockaddrInet(target: t, port: 7359) else { continue }
                withUnsafePointer(to: addr) { ptr in
                    let sock = ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                    msg.withUnsafeBytes { p in _ = sendto(fd, p.baseAddress, msg.count, 0, sock, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 1000) > 0 {
                var buf = [UInt8](repeating: 0, count: 4096)
                var src = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buf.withUnsafeMutableBytes { b in withUnsafeMutablePointer(to: &src) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &len) } } }
                if n > 0, let body = String(data: Data(buf[0..<n]), encoding: .utf8),
                   let data = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let a = json["Address"] as? String, !a.isEmpty, !addrs.contains(a) {
                    addrs.append(a)
                }
            }
        }
        return addrs
    }

    private func broadcastAddress(for ip: String) -> String {
        var inaddr = in_addr()
        guard inet_pton(AF_INET, ip, &inaddr) == 1 else { return "" }
        let net = inaddr.s_addr & UInt32(0xFFFFFF00).bigEndian
        var bc = net | UInt32(0x000000FF).bigEndian
        var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &bc, &out, socklen_t(INET_ADDRSTRLEN))
        return String(cString: out)
    }

    private func probeJellyfinDLNA(base: String) async -> UpnpServer? {
        // 1) Get Id from /System/Info/Public
        guard let publicURL = URL(string: base + "/System/Info/Public") else { return nil }
        var serverId: String?
        do {
            let (data, resp) = try await standardSession.data(from: publicURL)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["Id"] as? String, !id.isEmpty else { return nil }
            serverId = id
        } catch { return nil }
        guard let id = serverId else { return nil }
        // Jellyfin DLNA uses hyphenated UUID in URL path
        let hyphenated: String
        if id.count == 32 {
            hyphenated = "\(id.prefix(8))-\(id.dropFirst(8).prefix(4))-\(id.dropFirst(12).prefix(4))-\(id.dropFirst(16).prefix(4))-\(id.dropFirst(20))"
        } else { hyphenated = id }
        let dlnaURL = base + "/dlna/\(hyphenated)/description.xml"
        return try? await fetchDeviceInfo(location: dlnaURL)
    }

    private func ssdpLocations() async throws -> Set<String> {
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var locations = Set<String>()
                let fd = socket(AF_INET, SOCK_DGRAM, 0)
                if fd < 0 {
                    NSLog("[UpnpClient] socket() failed errno=%d", errno)
                    cont.resume(returning: locations); return
                }
                defer { close(fd) }

                var reuse: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                var broadcast: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
                // Multicast TTL 2 so SSDP reaches the LAN, and bind the
                // multicast egress to the Wi-Fi interface (needed on iOS
                // when the device has multiple interfaces; without it the
                // kernel may send via the wrong interface and get no reply).
                var ttl: Int32 = 2
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
                if let localIP = Self.localIPv4Address() {
                    var mif = in_addr()
                    inet_pton(AF_INET, localIP, &mif)
                    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &mif, socklen_t(MemoryLayout<in_addr>.size))
                    Self.diag("SSDP socket up, IF \(localIP), TTL 2")
                } else {
                    Self.diag("SSDP: no en* IPv4 (Wi-Fi off?)")
                }

                let msg = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\nUSER-AGENT: DreamPlayer/1.0 UPnP/1.0\r\n\r\n".utf8)
                guard let dest = Self.sockaddrInet(target: "239.255.255.250", port: 1900) else {
                    Self.diag("sockaddrInet failed")
                    cont.resume(returning: locations); return
                }

                let deadline = Date().addingTimeInterval(4.0)
                var packets = 0
                var sendErrno = 0
                // Send inside the deadline loop (like JellyfinDiscovery) so
                // lossy Wi-Fi still gets a probe each second, and use poll()
                // with 1 s timeout instead of blocking SO_RCVTIMEO.
                while Date() < deadline {
                    // (Re)send M-SEARCH each second
                    withUnsafePointer(to: dest) { addrPtr in
                        let sockAddr = addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                        msg.withUnsafeBytes { msgPtr in
                            let r = sendto(fd, msgPtr.baseAddress, msg.count, 0, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                            if r < 0 { sendErrno = Int(errno) }
                        }
                    }
                    if sendErrno != 0 {
                        Self.diag("sendto errno=\(sendErrno) (Local Network denied?)")
                        break
                    }
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    // 1 s poll so we stay responsive to deadline and can resend
                    if poll(&pfd, 1, 1000) > 0 {
                        var buf = [UInt8](repeating: 0, count: 8192)
                        var src = sockaddr_in()
                        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                        let n = buf.withUnsafeMutableBytes { bufPtr in
                            withUnsafeMutablePointer(to: &src) { srcPtr in
                                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                                    recvfrom(fd, bufPtr.baseAddress, bufPtr.count, 0, sockPtr, &srcLen)
                                }
                            }
                        }
                        if n > 0 {
                            packets += 1
                            let resp = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                            if let loc = Self.headerValue(resp, name: "LOCATION") ?? Self.headerValue(resp, name: "Location") {
                                let trimmed = loc.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    locations.insert(trimmed)
                                    Self.diag("SSDP reply #\(packets): \(trimmed)")
                                }
                            }
                            // Drain any additional waiting packets without extra poll
                            while true {
                                var peek = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                                if poll(&peek, 1, 0) <= 0 { break }
                                var buf2 = [UInt8](repeating: 0, count: 8192)
                                var src2 = sockaddr_in()
                                var srcLen2 = socklen_t(MemoryLayout<sockaddr_in>.size)
                                let n2 = buf2.withUnsafeMutableBytes { b in
                                    withUnsafeMutablePointer(to: &src2) { s in
                                        s.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                                            recvfrom(fd, b.baseAddress, b.count, 0, sock, &srcLen2)
                                        }
                                    }
                                }
                                if n2 <= 0 { break }
                                let resp2 = String(bytes: buf2[0..<n2], encoding: .utf8) ?? ""
                                if let loc2 = Self.headerValue(resp2, name: "LOCATION") ?? Self.headerValue(resp2, name: "Location") {
                                    let t2 = loc2.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !t2.isEmpty {
                                        locations.insert(t2)
                                        NSLog("[UpnpClient] LOCATION %@", t2)
                                    }
                                }
                            }
                        }
                    }
                }
                Self.diag("SSDP done: \(packets) packet(s), \(locations.count) location(s)")
                cont.resume(returning: locations)
            }
        }
    }

    private static func sockaddrInet(target: String, port: Int) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    private static func headerValue(_ resp: String, name: String) -> String? {
        for line in resp.components(separatedBy: "\r\n") {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            if k.caseInsensitiveCompare(name) == .orderedSame {
                return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// First `en*` interface IPv4 (Wi-Fi / Ethernet), copied from
    /// `JellyfinDiscovery.swift` so SSDP egress uses the right interface.
    private static func localIPv4Address() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let addr = current.pointee.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(current.pointee.ifa_addr, socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    return String(cString: host)
                }
            }
            ptr = current.pointee.ifa_next
        }
        return nil
    }

    private func fetchDeviceInfo(location: String) async throws -> UpnpServer? {
        guard let url = URL(string: location) else { return nil }
        let (data, response) = try await standardSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        let baseUrl = "\(url.scheme ?? "http")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")"
        return parseDeviceXml(data: data, baseUrl: baseUrl, location: location)
    }

    private func parseDeviceXml(data: Data, baseUrl: String, location: String) -> UpnpServer? {
        let delegate = DeviceXmlParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        guard let control = delegate.controlURL, !control.isEmpty else { return nil }
        let resolved = resolveUrl(base: baseUrl, url: control)
        let id = delegate.udn.isEmpty ? location : delegate.udn
        let name = delegate.friendlyName.isEmpty ? (URL(string: location)?.host ?? location) : delegate.friendlyName
        return UpnpServer(id: id, name: name, location: location, controlUrl: resolved, baseUrl: baseUrl)
    }

    private func resolveUrl(base: String, url: String) -> String {
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        if url.hasPrefix("/") { return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + url }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + url
    }

    // MARK: - Browse (SOAP)

    private func browse(serverId: String, objectId: String) async throws -> [[String: Any]] {
        let server: UpnpServer? = cacheQueue.sync { serverCache[serverId] }
        guard let server else { throw NSError(domain: "UpnpClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "DLNA server not found. Discover again."]) }
        let soap = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
            <ObjectID>\(objectId)</ObjectID>
            <BrowseFlag>BrowseDirectChildren</BrowseFlag>
            <Filter>*</Filter>
            <StartingIndex>0</StartingIndex>
            <RequestedCount>0</RequestedCount>
            <SortCriteria></SortCriteria>
            </u:Browse>
            </s:Body>
            </s:Envelope>
            """
        guard let controlURL = URL(string: server.controlUrl) else { throw URLError(.badURL) }
        var req = URLRequest(url: controlURL)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = soap.data(using: .utf8)

        let (data, response) = try await standardSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            Self.diag("browse: no HTTP response")
            throw NSError(domain: "UpnpClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "Browse failed"])
        }
        Self.diag("browse HTTP \(http.statusCode) object=\(objectId)")
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "UpnpClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Browse HTTP \(http.statusCode)"])
        }
        return parseBrowseResult(data: data)
    }

    private func parseBrowseResult(data: Data) -> [[String: Any]] {
        // Pull <Result> which holds escaped DIDL-Lite.
        guard let xml = String(data: data, encoding: .utf8) else {
            Self.diag("SOAP: body not UTF-8")
            return []
        }
        if let nrStart = xml.range(of: "<NumberReturned>"),
           let nrEnd = xml.range(of: "</NumberReturned>") {
            Self.diag("SOAP NumberReturned=\(xml[nrStart.upperBound..<nrEnd.lowerBound])")
        }
        // Tolerant extraction (upnpx/VLC style): allow attributes/whitespace
        // inside the Result tag instead of a literal "<Result>" match.
        guard let startRange = xml.range(of: "<Result[^>]*>", options: .regularExpression),
              let endRange = xml.range(of: "</Result>", options: [.regularExpression, .caseInsensitive]) else {
            Self.diag("SOAP: no <Result> element (fault?)")
            return []
        }
        let didlEscaped = String(xml[startRange.upperBound..<endRange.lowerBound])
        Self.diag("SOAP didl escaped len=\(didlEscaped.count)")
        // Single-pass entity decode - no XMLParser round-trip needed.
        let didl = Self.unescapeEntities(didlEscaped)
        guard let didlData = didl.data(using: .utf8) else { return [] }
        let entries = parseDidl(data: didlData)
        Self.diag("DIDL parsed \(entries.count) entr(ies)")
        return entries
    }

    /// Decodes XML entities (named + numeric refs) in ONE left-to-right pass,
    /// so `&amp;lt;` correctly stays `&lt;`. `&amp;` is handled by the pass
    /// itself rather than a fragile replace order.
    private static func unescapeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = String()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "&" {
                // Find the terminating ';' within 12 characters.
                var j = input.index(after: i)
                var scan = 0
                var semi: String.Index?
                while j < input.endIndex && scan < 12 {
                    if input[j] == ";" { semi = j; break }
                    j = input.index(after: j)
                    scan += 1
                }
                if let semi {
                    let ent = String(input[input.index(after: i)..<semi])
                    switch ent {
                    case "lt": out.append("<"); i = input.index(after: semi); continue
                    case "gt": out.append(">"); i = input.index(after: semi); continue
                    case "quot": out.append("\""); i = input.index(after: semi); continue
                    case "apos": out.append("'"); i = input.index(after: semi); continue
                    case "amp": out.append("&"); i = input.index(after: semi); continue
                    default:
                        if ent.hasPrefix("#") {
                            let hex = ent.hasPrefix("#x") || ent.hasPrefix("#X")
                            let digits = String(ent.dropFirst(hex ? 2 : 1))
                            if let code = UInt32(digits, radix: hex ? 16 : 10),
                               let scalar = Unicode.Scalar(code) {
                                out.unicodeScalars.append(scalar)
                                i = input.index(after: semi)
                                continue
                            }
                        }
                        // Unknown entity: keep verbatim.
                        out.append(c)
                        i = input.index(after: i)
                        continue
                    }
                }
            }
            out.append(c)
            i = input.index(after: i)
        }
        return out
    }

    private func parseDidl(data: Data) -> [[String: Any]] {
        let delegate = DidlParser()
        let parser = XMLParser(data: data)
        // upnpx/VLC-iOS approach: do NOT process namespaces. Foundation's
        // namespace processing on DIDL's default-xmlns + dc:/upnp: prefix mix
        // reported zero usable matches on device; matching qualified names
        // via suffix ("dc:title", "upnp:class") is what VLC does and is
        // parser-behavior independent.
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        parser.parse()
        if let err = parser.parserError?.localizedDescription {
            Self.diag("DIDL parse error: \(err)")
        }
        return delegate.entries.sorted { a, b in
            let da = a["isDirectory"] as? Bool ?? false
            let db = b["isDirectory"] as? Bool ?? false
            if da != db { return da && !db }
            return (a["name"] as? String ?? "").lowercased() < (b["name"] as? String ?? "").lowercased()
        }
    }
}

// MARK: - Device XML parser

private final class DeviceXmlParser: NSObject, XMLParserDelegate {
    var friendlyName = ""
    var udn = ""
    var controlURL: String?
    private var currentServiceType: String?
    private var currentControlURL: String?
    private var text = ""
    private var inDevice = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "device" { inDevice = true }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "friendlyName": if inDevice && friendlyName.isEmpty { friendlyName = value }
        case "UDN": if inDevice && udn.isEmpty { udn = value }
        case "serviceType": currentServiceType = value
        case "controlURL": currentControlURL = value
        case "service":
            if let t = currentServiceType, t.contains("ContentDirectory") {
                controlURL = currentControlURL
            }
            currentServiceType = nil; currentControlURL = nil
        default: break
        }
        text = ""
    }
}

// MARK: - DIDL-Lite parser

private final class DidlParser: NSObject, XMLParserDelegate {
    var entries: [[String: Any]] = []
    private var currentId: String?
    private var currentIsContainer = false
    private var currentTitle: String?
    private var currentRes: String?
    private var currentResSize: Int64 = 0
    private var currentProtocolInfo: String?
    private var currentResIsVideo = false
    // Attributes of the <res> currently being parsed (committed only if this
    // res wins the video-preference selection below).
    private var pendingProtoInfo: String?
    private var pendingResSize: Int64 = 0
    private var currentClass: String?
    // Non-video res entries advertised alongside the video (Jellyfin lists
    // one per external subtitle: text/srt, text/ass DeliveryUrls).
    private var currentExtraSubs: [[String: String]] = []
    private var inContainer = false
    private var inItem = false
    private var text = ""
    private let videoExts: Set<String> = ["mkv","mp4","avi","mov","ts","m2ts","wmv","flv","mpg","mpeg","webm","m4v","3gp","divx","vob"]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        // Namespaces OFF: elementName carries any prefix ("dc:title").
        if Self.matches(elementName, "container") {
            inContainer = true; inItem = false
            currentIsContainer = true
            currentId = attributeDict["id"]
            currentTitle = nil; currentRes = nil; currentClass = nil
        } else if Self.matches(elementName, "item") {
            inItem = true; inContainer = false
            currentIsContainer = false
            currentId = attributeDict["id"]
            currentTitle = nil; currentRes = nil; currentClass = nil; currentResSize = 0
            currentResIsVideo = false
            currentExtraSubs = []
        } else if Self.matches(elementName, "res") {
            pendingProtoInfo = attributeDict["protocolInfo"]
            if let sz = attributeDict["size"], let v = Int64(sz) { pendingResSize = v }
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.matches(elementName, "title") {
            if !value.isEmpty { currentTitle = value }
        } else if Self.matches(elementName, "class") {
            currentClass = value
        } else if Self.matches(elementName, "res") {
            if !value.isEmpty {
                // Servers like Jellyfin advertise MULTIPLE res elements per
                // item - video plus one per external subtitle (DeliveryUrl
                // …/Subtitles/N/0/Stream.srt). Keep the VIDEO res; fall back
                // to the first-seen res otherwise.
                let isVideoRes = pendingProtoInfo?.lowercased().contains("video/") == true
                if currentRes == nil || (isVideoRes && !currentResIsVideo) {
                    currentRes = value
                    currentProtocolInfo = pendingProtoInfo
                    currentResSize = pendingResSize
                    currentResIsVideo = isVideoRes
                } else if !isVideoRes {
                    // A text/* subtitle advertised next to the video -
                    // collect it as an attachable track.
                    let parts = pendingProtoInfo?.split(separator: ":") ?? []
                    var mime = parts.count > 2 ? String(parts[2]).lowercased() : ""
                    if mime.isEmpty || mime == "*" { mime = "application/x-subrip" }
                    currentExtraSubs.append(["url": value, "mime": mime])
                }
            }
        } else if Self.matches(elementName, "container") || Self.matches(elementName, "item") {
            flushEntry()
            inContainer = false; inItem = false
            currentId = nil; currentTitle = nil; currentRes = nil; currentClass = nil
            currentExtraSubs = []
        }
        text = ""
    }

    /// Qualified-name match: plain local name or ANY prefix ("dc:title",
    /// "upnp:class"). This is the upnpx/VLC-iOS matching style.
    private static func matches(_ elementName: String, _ name: String) -> Bool {
        elementName == name || elementName.hasSuffix(":\(name)")
    }

    private func flushEntry() {
        guard let id = currentId else { return }
        if inContainer || currentIsContainer {
            let name = currentTitle ?? id
            entries.append(["name": name, "id": id, "isDirectory": true, "url": NSNull(), "size": 0])
        } else if inItem {
            guard let url = currentRes, !url.isEmpty else { return }
            let isVideo = isVideoCandidate()
            if !isVideo { return }
            let name = currentTitle ?? URL(string: url)?.lastPathComponent ?? id
            // DLNA.ORG_CI=1 → server-side transcode on demand (Jellyfin does
            // this for items with external subtitles → lossy H.264 TS).
            let transcoded = currentProtocolInfo?.range(of: "DLNA.ORG_CI=1", options: .caseInsensitive) != nil
            entries.append([
                "name": name, "id": id, "isDirectory": false, "url": url,
                "size": currentResSize, "transcoded": transcoded,
                "externalSubs": currentExtraSubs.filter { $0["url"] != url },
            ])
        }
    }

    private func isVideoCandidate() -> Bool {
        let pi = currentProtocolInfo?.lowercased() ?? ""
        if pi.contains("video") { return true }
        if currentClass?.lowercased().contains("videoitem") == true { return true }
        if pi.contains("audio") || pi.contains("image") { return false }
        if let url = currentRes, let ext = URL(string: url)?.pathExtension.lowercased(), videoExts.contains(ext) { return true }
        if !pi.isEmpty && !pi.contains("video") { return false }
        return true
    }
}
