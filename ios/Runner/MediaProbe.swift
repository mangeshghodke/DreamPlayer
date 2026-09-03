import AVFoundation
import Flutter
import Foundation

/// Debug log file exposed via UIFileSharingEnabled (Files app → On My iPad → DreamPlayer)
private let logURL: URL? = {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
    return docs.appendingPathComponent("probe_debug.log")
}()

private func probeDebugLog(_ msg: String) {
    guard let url = logURL else { return }
    let line = "\(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path) {
            if let fh = FileHandle(forWritingAtPath: url.path) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - MKV (Matroska/EBML) probe
//
// AVFoundation cannot read MKV containers at all (-11828 "Cannot Open"), so
// AVURLAsset-based probing returns nothing for every .mkv. This mirrors the
// Android MkvChapters.kt EBML walk to extract the info-card metadata directly
// from the container: duration (Info), video/audio codec + resolution/fps +
// channels + language (Tracks). Best-effort — any structural surprise yields
// whatever was collected, never affects playback.

private struct MkvInfo {
    var timecodeScale: UInt64 = 1_000_000
    var durationNs: UInt64?
    var videoCodecId: String?
    var audioCodecId: String?
    var width: UInt64?
    var height: UInt64?
    var displayWidth: UInt64?
    var displayHeight: UInt64?
    var fps: Double?
    var audioChannels: UInt64?
    var audioLanguage: String?
}

/// Minimal random-access reader over a local file.
private struct MkvReader {
    let fh: FileHandle
    var pos: UInt64 = 0
    let fileSize: UInt64

    init?(path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        self.fh = fh
        self.fileSize = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: 0)
    }

    mutating func seek(_ p: UInt64) {
        pos = min(p, fileSize)
        try? fh.seek(toOffset: pos)
    }

    mutating func readByte() -> UInt8 {
        guard pos < fileSize, let d = try? fh.read(upToCount: 1), let b = d.first else { return 0 }
        pos += 1
        return b
    }

    mutating func readBytes(_ n: Int) -> [UInt8] {
        guard n > 0, pos + UInt64(n) <= fileSize, let d = try? fh.read(upToCount: n) else { return [] }
        pos += UInt64(d.count)
        return Array(d)
    }

    /// Read an EBML element ID. The marker bit in the first byte (the highest
    /// set bit) determines the total length; the marker bit is part of the ID
    /// value (e.g. Segment = 0x1A45DFA3).
    mutating func readID() -> UInt64? {
        let b = readByte()
        if b == 0 { return nil }
        var len = 1
        var probe: UInt8 = 0x80
        while (b & probe) == 0 && len < 4 {
            len += 1
            probe >>= 1
        }
        var val = UInt64(b)
        for _ in 1..<len {
            val = (val << 8) | UInt64(readByte())
        }
        return val
    }

    /// Read an EBML element size (VINT). Returns nil on overlong/clear top bit.
    mutating func readSize() -> UInt64? {
        var b = readByte()
        var mask: UInt8 = 0x80
        var len = 1
        while (b & mask) == 0 && len < 8 {
            len += 1
            mask >>= 1
        }
        if mask == 0 { return nil }
        var val = UInt64(b & (mask - 1))
        if val == UInt64(mask - 1) { return nil } // all-ones = unknown size
        for _ in 1..<len {
            val = (val << 8) | UInt64(readByte())
        }
        return val
    }

    mutating func readUInt(_ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<n { v = (v << 8) | UInt64(readByte()) }
        return v
    }

    mutating func readString(_ n: Int) -> String {
        let bytes = readBytes(n)
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Read a float (4 or 8 byte) as Double.
    mutating func readFloat(_ n: Int) -> Double {
        if n == 4 {
            let b = readBytes(4)
            if b.count == 4 {
                let u = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
                return Double(Float(bitPattern: u))
            }
            return 0
        }
        let b = readBytes(8)
        if b.count == 8 {
            var u: UInt64 = 0
            for x in b { u = (u << 8) | UInt64(x) }
            return Double(bitPattern: u)
        }
        return 0
    }
}

private func mkvProbe(path: String) -> MkvInfo {
    var info = MkvInfo()
    guard var reader = MkvReader(path: path), reader.fileSize > 8 else {
        probeDebugLog("  mkv: cannot open or too small")
        return info
    }

    // Skip the EBML header (0x1A45DFA3) and any leading elements until we
    // reach the Segment (0x18538067), whose children we walk for Info/Tracks.
    // MKV Segment elements almost always use undefined/unknown size
    // (all-ones VINT), so readSize returns nil — that means "extends to EOF".
    let scanLimit = min(reader.fileSize, 64 * 1024)
    while reader.pos + 4 <= scanLimit {
        let id = reader.readID() ?? 0
        let sizeOpt = reader.readSize()
        if id == 0x18538067 { // Segment
            let segEnd: UInt64
            if let s = sizeOpt {
                segEnd = reader.pos + s
            } else {
                segEnd = reader.fileSize
            }
            probeDebugLog("  mkv: found Segment at pos=\(reader.pos) end=\(segEnd)")
            mkvWalkSegment(&reader, &info, segEnd: segEnd)
            return info
        }
        guard let size = sizeOpt else { break }
        guard reader.pos + size <= reader.fileSize else { break }
        reader.seek(reader.pos + size) // skip the element's content
    }
    probeDebugLog("  mkv: no Segment found (pos=\(reader.pos) limit=\(scanLimit))")
    return info
}

/// Walk the Segment's top-level children (bounded) and parse Info/Tracks.
/// Segment topological structure: SeekHead, Info, Tracks, Clusters, Chapters...
/// We seek past any child we don't need, so the walk converges quickly.
private func mkvWalkSegment(_ reader: inout MkvReader, _ info: inout MkvInfo, segEnd: UInt64) {
    let maxChildren = 4096
    var parsedChildren = 0
    while parsedChildren < maxChildren, reader.pos + 2 < segEnd, reader.pos + 2 <= reader.fileSize {
        let id = reader.readID() ?? 0
        let sizeOpt = reader.readSize()
        let childStart = reader.pos
        let childEnd: UInt64
        if let s = sizeOpt {
            childEnd = childStart + s
        } else {
            childEnd = segEnd
        }
        guard childEnd <= reader.fileSize else { break }
        parsedChildren += 1

        switch id {
        case 0x1549A966: // Info
            if let s = sizeOpt { mkvParseInfo(&reader, &info, Int(s)) }
        case 0x1654AE6B: // Tracks
            if let s = sizeOpt { mkvParseTracks(&reader, &info, Int(s)) }
        default:
            break
        }
        reader.seek(childEnd) // always advance past this child

        if info.durationNs != nil, info.videoCodecId != nil || info.audioCodecId != nil {
            break
        }
    }
    if info.durationNs == nil && info.videoCodecId == nil && info.audioCodecId == nil {
        probeDebugLog("  mkv: walked \(parsedChildren) children, captured nothing")
    }
}

private func mkvParseInfo(_ reader: inout MkvReader, _ info: inout MkvInfo, _ len: Int) {
    let end = reader.pos + UInt64(len)
    while reader.pos + 2 <= end && reader.pos + 2 <= reader.fileSize {
        let id = reader.readID() ?? 0
        guard let size = reader.readSize(), reader.pos + size <= end else { break }
        switch id {
        case 0x2AD7B1: // TimecodeScale
            if size > 0 && size <= 8 { info.timecodeScale = reader.readUInt(Int(size)) }
            else if size > 0 { _ = reader.readBytes(Int(size)) }
        case 0x4489: // Duration
            if size == 4 || size == 8 {
                info.durationNs = UInt64(reader.readFloat(Int(size)) * Double(info.timecodeScale))
            } else if size > 0 {
                _ = reader.readBytes(Int(size))
            }
        default:
            _ = reader.readBytes(Int(size))
        }
    }
    reader.seek(min(end, reader.fileSize))
}

private func mkvParseTracks(_ reader: inout MkvReader, _ info: inout MkvInfo, _ len: Int) {
    let end = reader.pos + UInt64(len)
    while reader.pos < end && reader.pos + 2 <= reader.fileSize {
        let id = reader.readID() ?? 0
        guard let size = reader.readSize(), reader.pos + size <= end else { break }
        if id == 0xAE { // TrackEntry
            mkvParseTrackEntry(&reader, &info, Int(size))
        } else {
            _ = reader.readBytes(Int(size))
        }
    }
    reader.seek(reader.pos)
}

private func mkvParseTrackEntry(_ reader: inout MkvReader, _ info: inout MkvInfo, _ len: Int) {
    let end = reader.pos + UInt64(len)
    var trackType: UInt64 = 0
    var codecId: String?
    var language: String?
    var defaultDurationNs: UInt64?
    var videoW: UInt64?, videoH: UInt64?, dispW: UInt64?, dispH: UInt64?
    var channels: UInt64?

    while reader.pos < end && reader.pos + 2 <= reader.fileSize {
        let id = reader.readID() ?? 0
        guard let size = reader.readSize(), reader.pos + size <= end else { break }
        let childStart = reader.pos
        switch id {
        case 0x83: // TrackType
            if size > 0 { trackType = reader.readUInt(Int(size)) }
        case 0x86: // CodecID
            codecId = reader.readString(Int(size))
        case 0x22B59C: // Language
            language = reader.readString(Int(size))
        case 0x23E383: // DefaultDuration
            if size > 0 && size <= 8 { defaultDurationNs = reader.readUInt(Int(size)) }
        case 0xE0: // Video
            mkvParseVideo(&reader, &videoW, &videoH, &dispW, &dispH, Int(size))
            reader.seek(childStart + size)
        case 0xE1: // Audio
            mkvParseAudio(&reader, &channels, Int(size))
            reader.seek(childStart + size)
        default:
            _ = reader.readBytes(Int(size))
        }
    }

    guard trackType == 1 || trackType == 2 else { return }
    if trackType == 1 {
        if info.videoCodecId == nil { info.videoCodecId = codecId }
        if let w = videoW, info.width == nil { info.width = w }
        if let h = videoH, info.height == nil { info.height = h }
        if let w = dispW, info.displayWidth == nil { info.displayWidth = w }
        if let h = dispH, info.displayHeight == nil { info.displayHeight = h }
        if let d = defaultDurationNs, d > 0, info.fps == nil {
            info.fps = 1_000_000_000.0 / Double(d)
        }
    } else if trackType == 2 {
        if info.audioCodecId == nil { info.audioCodecId = codecId }
        if let c = channels, info.audioChannels == nil { info.audioChannels = c }
        if let l = language, !l.isEmpty, l != "und", info.audioLanguage == nil { info.audioLanguage = l }
    }
}

private func mkvParseVideo(_ reader: inout MkvReader, _ w: inout UInt64?, _ h: inout UInt64?,
                           _ dw: inout UInt64?, _ dh: inout UInt64?, _ len: Int) {
    let end = reader.pos + UInt64(len)
    while reader.pos < end && reader.pos + 2 <= reader.fileSize {
        let id = reader.readID() ?? 0
        guard let size = reader.readSize(), reader.pos + size <= end else { break }
        switch id {
        case 0xB0: if size > 0 { w = reader.readUInt(Int(size)) }
        case 0xBA: if size > 0 { h = reader.readUInt(Int(size)) }
        case 0x54B0: if size > 0 { dw = reader.readUInt(Int(size)) }
        case 0x54BA: if size > 0 { dh = reader.readUInt(Int(size)) }
        default: _ = reader.readBytes(Int(size))
        }
    }
    reader.seek(reader.pos)
}

private func mkvParseAudio(_ reader: inout MkvReader, _ ch: inout UInt64?, _ len: Int) {
    let end = reader.pos + UInt64(len)
    while reader.pos < end && reader.pos + 2 <= reader.fileSize {
        let id = reader.readID() ?? 0
        guard let size = reader.readSize(), reader.pos + size <= end else { break }
        switch id {
        case 0x9F: if size > 0 { ch = reader.readUInt(Int(size)) }
        default: _ = reader.readBytes(Int(size))
        }
    }
    reader.seek(reader.pos)
}

/// Map an MKV CodecID to a MediaExtractor-style MIME string.
private func mkvCodecToMime(_ codecId: String) -> String? {
    switch codecId {
    case "V_MPEGH/ISO/HEVC", "V_MPEGH/ISO/HVC1": return "video/hevc"
    case "V_MPEG4/ISO/AVC": return "video/avc"
    case "V_AV1": return "video/av01"
    case "V_VP9": return "video/x-vnd.on2.vp9"
    case "V_VP8": return "video/vp8"
    case "V_MPEG4/ISO/SP", "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/AP", "V_MPEG4/MS/V3": return "video/mp4v-es"
    case "A_AAC": return "audio/mp4a-latm"
    case "A_AC3": return "audio/ac3"
    case "A_EAC3": return "audio/eac3"
    case "A_DTS": return "audio/vnd.dts"
    case "A_DTS/EXPRESS", "A_DTS/LOSSLESS", "A_DTS/LBR", "A_DTS/HD", "A_DTS/HD/MA", "A_DTS/HD/MA/EX", "A_DTS/HD/LBR": return "audio/vnd.dts.hd"
    case "A_TRUEHD": return "audio/true-hd"
    case "A_MLP": return "audio/mlp"
    case "A_FLAC": return "audio/flac"
    case "A_OPUS": return "audio/opus"
    case "A_VORBIS": return "audio/vorbis"
    case "A_MPEG/L3": return "audio/mpeg"
    case "A_MPEG/L2": return "audio/mpeg"
    case "A_PCM/INT/LIT": return "audio/raw"
    default: return nil
    }
}

// MARK: - MediaProbe

/// Native media probe for iOS — extracts video/audio codec, resolution, fps,
/// duration, language, and channel count from any URL. AVURLAsset handles the
/// containers AVFoundation supports (mp4/mov/m4v/ts/m2ts); MKV is parsed
/// directly from the EBML container since AVFoundation can't open .mkv.
final class MediaProbe: NSObject {

    static let shared = MediaProbe()
    private static let channelName = "dreamplayer/mediaProbe"

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
        if let url = logURL { try? FileManager.default.removeItem(at: url) }
        probeDebugLog("=== MediaProbe session started ===")
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "probe":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "bad_args", message: nil, details: nil))
                return
            }
            let path = args["path"] as? String
            let uri = args["uri"] as? String
            let headers = args["headers"] as? [String: String] ?? [:]
            Task { result(await self.probe(path: path, uri: uri, headers: headers)) }
        case "probeFile":
            guard let args = call.arguments as? [String: Any],
                  let filePath = args["filePath"] as? String else {
                result(FlutterError(code: "bad_args", message: nil, details: nil))
                return
            }
            Task { result(await self.probeLocal(filePath: filePath)) }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Probe dispatch

    private func probe(path: String?, uri: String?, headers: [String: String]) async -> [String: Any] {
        probeDebugLog("PROBE path=\(path ?? "nil") uri=\(uri ?? "nil")")
        if let u = uri ?? path, u.hasPrefix("http://") || u.hasPrefix("https://") {
            probeDebugLog("→ probeHttp")
            return await probeHttp(url: u, headers: headers)
        }
        if let p = path, !p.hasPrefix("smb://") && !p.hasPrefix("ftp://") &&
            !p.hasPrefix("sftp://") && !p.hasPrefix("content://") {
            probeDebugLog("→ probeLocal")
            return await probeLocal(filePath: p)
        }
        if let u = uri ?? path, u.hasPrefix("content://") {
            probeDebugLog("→ probeContentUri")
            return await probeContentUri(u)
        }
        probeDebugLog("→ no matching dispatch")
        return [:]
    }

    // MARK: - HTTP

    private func probeHttp(url: String, headers: [String: String]) async -> [String: Any] {
        guard let nsUrl = URL(string: url) else { return [:] }
        let opts: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: nsUrl, options: opts)
        return await probeAsset(asset)
    }

    // MARK: - Local

    private func probeLocal(filePath: String) async -> [String: Any] {
        let exists = FileManager.default.fileExists(atPath: filePath)
        probeDebugLog("PROBE_LOCAL path=\(filePath) exists=\(exists)")
        guard exists else { return [:] }

        let lower = filePath.lowercased()
        if lower.hasSuffix(".mkv") || lower.hasSuffix(".mka") || lower.hasSuffix(".webm") {
            probeDebugLog("→ MKV container, using EBML parser")
            return await mkvProbeFile(path: filePath)
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
        return await probeAsset(asset)
    }

    private func mkvProbeFile(path: String) async -> [String: Any] {
        let info = mkvProbe(path: path)

        var out: [String: Any] = [:]
        if let d = info.durationNs { out["durationMs"] = Int(d / 1_000_000) }
        let w = info.displayWidth ?? info.width
        let h = info.displayHeight ?? info.height
        if let w = w, let h = h {
            out["width"] = Int(w)
            out["height"] = Int(h)
        }
        if let v = info.videoCodecId, let m = mkvCodecToMime(v) { out["videoMime"] = m }
        if let a = info.audioCodecId, let m = mkvCodecToMime(a) { out["audioMime"] = m }
        if let c = info.audioChannels { out["audioChannels"] = Int(c) }
        if let l = info.audioLanguage { out["audioLanguage"] = l }
        if let f = info.fps { out["fps"] = Int(round(f)) }
        probeDebugLog("  MKV parse result: \(out)")
        return out
    }

    // MARK: - content://

    private func probeContentUri(_ uri: String) async -> [String: Any] {
        guard let url = URL(string: uri) else { return [:] }
        return await probeAsset(AVURLAsset(url: url))
    }

    // MARK: - AVAsset core (mp4/mov/m4v/ts/m2ts)

    private func probeAsset(_ asset: AVAsset) async -> [String: Any] {
        var out: [String: Any] = [:]
        probeDebugLog("PROBE_ASSET \(asset.description)")

        do {
            let dur = try await asset.load(.duration)
            if dur.isNumeric {
                out["durationMs"] = Int(CMTimeGetSeconds(dur) * 1000)
                probeDebugLog("  duration=\(out["durationMs"]!)ms")
            }
        } catch {
            probeDebugLog("  duration error: \(error)")
        }

        do {
            let tracks = try await asset.load(.tracks)
            probeDebugLog("  tracks count=\(tracks.count)")
            for track in tracks {
                let mediaType = track.mediaType
                if mediaType == .video {
                    let dim = track.naturalSize.applying(track.preferredTransform)
                    if !out.keys.contains("width") { out["width"] = Int(dim.width) }
                    if !out.keys.contains("height") { out["height"] = Int(dim.height) }
                    if let desc = track.formatDescriptions.first {
                        let fourCC = CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription)
                        out["videoMime"] = fourCCtoString(fourCC)
                    }
                    let rate = track.nominalFrameRate
                    if rate > 0 { out["fps"] = Int(round(rate)) }
                } else if mediaType == .audio {
                    if let desc = track.formatDescriptions.first {
                        let fourCC = CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription)
                        out["audioMime"] = fourCCtoString(fourCC)
                    }
                    let lang = track.languageCode ?? ""
                    if !lang.isEmpty && lang != "und" { out["audioLanguage"] = lang }
                }
            }
        } catch {
            probeDebugLog("  tracks error: \(error)")
        }

        probeDebugLog("PROBE_RESULT \(out)")
        return out
    }

    // MARK: - FourCC → codec name

    private func fourCCtoString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let str = String(bytes: bytes, encoding: .ascii) ?? "unknown"
        switch str {
        case "hvc1", "hev1": return "video/hevc"
        case "avc1":         return "video/avc"
        case "vp09":         return "video/x-vnd.on2.vp9"
        case "av01":         return "video/av01"
        case "mp4a":         return "audio/mp4a-latm"
        case "ec-3":         return "audio/eac3"
        case "ac-3":         return "audio/ac3"
        case "fLaC":         return "audio/flac"
        case "Opus", "Opls": return "audio/opus"
        default:             return str
        }
    }
}
