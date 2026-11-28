import AVFoundation
import Flutter
import Foundation

// MARK: - MKV (Matroska/EBML) probe
//
// AVFoundation cannot read MKV containers at all (-11828 "Cannot Open"), so
// AVURLAsset-based probing returns nothing for every .mkv. This mirrors the
// Android MkvChapters.kt EBML walk to extract the info-card metadata directly
// from the container: duration (Info), video/audio codec + resolution/fps +
// channels + language (Tracks). Best-effort - any structural surprise yields
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
    var audioSampleRate: Double?
    var audioBits: UInt64?
    var audioBitrate: Int?
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

    /// Read an EBML element size (VINT). Returns nil on all-ones (unknown size),
    /// but still advances pos past all VINT bytes so the reader stays synced.
    mutating func readSize() -> UInt64? {
        let startPos = pos
        var b = readByte()
        var mask: UInt8 = 0x80
        var len = 1
        while (b & mask) == 0 && len < 8 {
            len += 1
            mask >>= 1
        }
        if mask == 0 {
            // Malformed - skip all remaining bytes of what we consumed so far.
            return nil
        }
        var val = UInt64(b & (mask - 1))
        for _ in 1..<len {
            val = (val << 8) | UInt64(readByte())
        }
        if val == UInt64(mask - 1) {
            // All-ones = undefined size. We've consumed `len` bytes of the VINT.
            // Return nil but pos is already advanced past the full VINT.
            return nil
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
        return info
    }

    // Skip the EBML header (0x1A45DFA3) and any leading elements until we
    // reach the Segment (0x18538067), whose children we walk for Info/Tracks.
    // MKV Segment elements almost always use undefined/unknown size
    // (all-ones VINT), so readSize returns nil - that means "extends to EOF".
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
            mkvWalkSegment(&reader, &info, segEnd: segEnd)
            return info
        }
        guard let size = sizeOpt else { break }
        guard reader.pos + size <= reader.fileSize else { break }
        reader.seek(reader.pos + size) // skip the element's content
    }
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
    var sampleRate: Double?
    var bits: UInt64?

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
            mkvParseAudio(&reader, &channels, &sampleRate, &bits, Int(size))
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
        if let r = sampleRate, r > 0, info.audioSampleRate == nil { info.audioSampleRate = r }
        if let b = bits, b > 0, info.audioBits == nil { info.audioBits = b }
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

private func mkvParseAudio(_ reader: inout MkvReader, _ ch: inout UInt64?, _ rate: inout Double?, _ bits: inout UInt64?, _ len: Int) {
    let end = reader.pos + UInt64(len)
    while reader.pos < end && reader.pos + 2 <= reader.fileSize {
        let id = reader.readID() ?? 0
        guard let size = reader.readSize(), reader.pos + size <= end else { break }
        switch id {
        case 0x9F: if size > 0 { ch = reader.readUInt(Int(size)) }              // Channels
        case 0xB5: if size == 4 { rate = reader.readFloat(4) }                // SamplingFrequency (float)
                  else if size == 8 { rate = reader.readFloat(8) }             // (double, widened)
        case 0x6264: if size > 0 { bits = reader.readUInt(Int(size)) }          // BitDepth
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

/// Native media probe for iOS - extracts video/audio codec, resolution, fps,
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
            let resumeKey = args["resumeKey"] as? String
            Task { result(await self.probe(path: path, uri: uri, headers: headers, resumeKey: resumeKey)) }
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

    private func probe(path: String?, uri: String?, headers: [String: String], resumeKey: String? = nil) async -> [String: Any] {
        // The smb:// branch must match the PATH even when a uri is set: on iOS
        // SMB playback the uri is a `dreamplayersmb://` token URL, so a plain
        // `uri ?? path` check would hide the smb:// scheme and fall through to
        // a local probe of a non-existent path - no tags/artwork on iPad
        // (user report 2026-11-28).
        if let smb = [uri, path].compactMap({ $0 }).first(where: { $0.hasPrefix("smb://") }) {
            // AVFoundation cannot open smb:// URLs, so the head+tail is fetched
            // through libsmb2 into a sparse temp file (original extension kept,
            // so the .mkv EBML dispatch still fires) and probed from there.
            // This is what gives SMB audio files their embedded tags on iPad.
            return await probeSmb(uri: smb, resumeKey: resumeKey)
        }
        if let u = uri ?? path, u.hasPrefix("http://") || u.hasPrefix("https://") {
            return await probeHttp(url: u, headers: headers)
        }
        if let p = path, !p.hasPrefix("ftp://") &&
            !p.hasPrefix("sftp://") && !p.hasPrefix("content://") {
            return await probeLocal(filePath: p)
        }
        if let u = uri ?? path, u.hasPrefix("content://") {
            return await probeContentUri(u)
        }
        return [:]
    }

    private func probeSmb(uri: String, resumeKey: String?) async -> [String: Any] {
        let serverId: String? = {
            guard let k = resumeKey, k.hasPrefix("smb:") else { return nil }
            let first = k.dropFirst(4).split(separator: "/").first
            return (first == nil || first!.isEmpty) ? nil : String(first!)
        }()
        guard let tmp = SMBBridge.shared.fetchHeadTailToTemp(smbUri: uri, serverId: serverId) else {
            return [:]
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return await probeLocal(filePath: tmp.path)
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
        guard exists else { return [:] }

        let lower = filePath.lowercased()
        if lower.hasSuffix(".mkv") || lower.hasSuffix(".mka") || lower.hasSuffix(".webm") {
            return await mkvProbeFile(path: filePath)
        }

        // FLAC/WAV/MP3/OGG: AVFoundation cannot parse these containers, so the
        // head is parsed directly (tags + lyrics + STREAMINFO). AVAsset still
        // runs afterwards and only FILLS gaps (e.g. mp3 duration) - it must not
        // overwrite the parsed tags (user request 2026-11-28: no title/art on
        // iPad for these files before this).
        if AudioFileTags.isSupported(filePath) {
            let parsed = AudioFileTags.parse(fileAt: filePath)
            var out: [String: Any] = [:]
            if let t = parsed.tags["title"] { out["audioTitle"] = t }
            if let a = parsed.tags["artist"] { out["audioArtist"] = a }
            if let al = parsed.tags["album"] { out["audioAlbum"] = al }
            if let l = parsed.tags["lyrics"] { out["audioLyrics"] = l }
            if let r = parsed.sampleRate { out["audioSampleRate"] = r }
            if let b = parsed.bits { out["audioBits"] = b }
            if let c = parsed.channels { out["audioChannels"] = c }
            if lower.hasSuffix(".flac") { out["audioMime"] = "audio/flac" }
            let assetOut = await probeAsset(AVURLAsset(url: URL(fileURLWithPath: filePath)))
            for (k, v) in assetOut where out[k] == nil { out[k] = v }
            return out
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
        if let r = info.audioSampleRate { out["audioSampleRate"] = Int(r) }
        if let b = info.audioBits { out["audioBits"] = Int(b) }
        if let br = info.audioBitrate, br > 0 { out["audioBitrate"] = Int(br) }
        if let l = info.audioLanguage { out["audioLanguage"] = l }
        if let f = info.fps { out["fps"] = Int(round(f)) }
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

        do {
            let dur = try await asset.load(.duration)
            if dur.isNumeric {
                out["durationMs"] = Int(CMTimeGetSeconds(dur) * 1000)
            }
        } catch {
        }

        // Embedded tag text (title/artist/album) - shown under the vinyl disc
        // for audio-only files (user request 2026-11-24).
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                let value = (try? await item.load(.stringValue)) ?? (item.value as? String)
                guard let value, !value.isEmpty else { continue }
                switch key {
                case .commonKeyTitle: out["audioTitle"] = value
                case .commonKeyArtist: out["audioArtist"] = value
                case .commonKeyAlbumName: out["audioAlbum"] = value
                case .commonKeyLyrics: out["audioLyrics"] = value // MP4 `©lyr`
                default: break
                }
            }
        }
        do {
            let tracks = try await asset.load(.tracks)
            for track in tracks {
                let mediaType = track.mediaType
                if mediaType == .video {                    let dim = track.naturalSize.applying(track.preferredTransform)
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
                        // Sample rate / bit depth / bitrate from the format
                        // description (shown under the vinyl disc for
                        // audio-only files, user request 2026-11-24).
                        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc as! CMFormatDescription) {
                            let rate = asbd.pointee.mSampleRate
                            if rate > 0 { out["audioSampleRate"] = Int(rate.rounded()) }
                            let bits = asbd.pointee.mBitsPerChannel
                            if bits > 0 { out["audioBits"] = Int(bits) }
                        }
                    }
                    let br = track.estimatedDataRate
                    if br > 0 { out["audioBitrate"] = Int(br) }
                    let lang = track.languageCode ?? ""
                    if !lang.isEmpty && lang != "und" { out["audioLanguage"] = lang }
                }
            }
        } catch {
        }

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

// MARK: - FLAC / ID3v2 / WAV tag parser

/// Parses embedded audio tags from the HEAD of a file: FLAC metadata blocks
/// (vorbis comments + STREAMINFO + PICTURE), ID3v2 frames (text frames, USLT
/// lyrics, APIC artwork) and RIFF/WAVE chunks (fmt + LIST INFO + id3 chunk).
///
/// AVFoundation reads MP4/M4A `moov` tags but CANNOT parse FLAC/WAV at all,
/// and exposes no lyrics - so on iOS this parser is what surfaces title /
/// artist / album / cover art / (LRC) lyrics for those files (user request
/// 2026-11-28). FileBrowser.embeddedArtwork uses it for the PICTURE/APIC art.
/// Best-effort: any parse error returns whatever was collected so far.
enum AudioFileTags {

    struct Parsed {
        var tags: [String: String] = [:]
        var artwork: Data?
        var sampleRate: Int?
        var bits: Int?
        var channels: Int?
    }

    static func isSupported(_ path: String) -> Bool {
        let l = path.lowercased()
        return [".flac", ".mp3", ".wav", ".aif", ".aiff", ".ogg", ".opus"]
            .contains { l.hasSuffix($0) }
    }

    static func parse(fileAt path: String, maxBytes: Int = 4 * 1024 * 1024) -> Parsed {
        var p = Parsed()
        guard let fh = try? FileHandle(forReadingAtPath: path),
              let data = try? fh.read(upToCount: maxBytes),
              data.count >= 12 else { return p }
        let b = [UInt8](data)
        let magic4 = String(bytes: b[0..<4], encoding: .ascii) ?? ""
        if magic4 == "fLaC" {
            parseFlac(b, &p)
        } else if b.count >= 10, String(bytes: b[0..<3], encoding: .ascii) == "ID3" {
            parseId3(b, &p)
        } else if magic4 == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WAVE" {
            parseWav(b, &p)
        }
        return p
    }

    // MARK: FLAC

    private static func parseFlac(_ b: [UInt8], _ p: inout Parsed) {
        var pos = 4
        while pos + 4 <= b.count {
            let header = Int(b[pos])
            let last = header & 0x80 != 0
            let type = header & 0x7F
            let len = (Int(b[pos + 1]) << 16) | (Int(b[pos + 2]) << 8) | Int(b[pos + 3])
            let data = pos + 4
            if data + len > b.count { break }
            switch type {
            case 0: // STREAMINFO
                if len >= 18 {
                    p.sampleRate = (Int(b[data]) << 12) | (Int(b[data + 1]) << 4) | (Int(b[data + 2]) >> 4)
                    p.channels = ((Int(b[data + 2]) >> 1) & 0x07) + 1
                    p.bits = (((Int(b[data + 2]) & 0x01) << 4) | (Int(b[data + 3]) >> 4)) + 1
                }
            case 4: // VORBIS_COMMENT (little-endian)
                parseVorbisComment(b, data, len, &p)
            case 6: // PICTURE
                var q = data + 4
                let mimeLen = leInt(b, data)
                q += mimeLen
                if q + 4 > data + len { break }
                let descLen = leInt(b, q); q += 4 + descLen
                q += 16 // width, height, depth, colors
                if q + 4 > data + len { break }
                let dataLen = leInt(b, q); q += 4
                if dataLen > 0 && q + dataLen <= data + len {
                    p.artwork = Data(b[q..<(q + dataLen)])
                }
            default: break
            }
            pos = data + len
            if last { break }
        }
    }

    private static func parseVorbisComment(_ b: [UInt8], _ data: Int, _ len: Int, _ p: inout Parsed) {
        var q = data + 4
        guard q <= data + len else { return }
        let vendorLen = leInt(b, data)
        q += vendorLen
        guard q + 4 <= data + len else { return }
        let count = leInt(b, q); q += 4
        for _ in 0..<count {
            guard q + 4 <= data + len else { break }
            let flen = leInt(b, q); q += 4
            guard flen > 0, q + flen <= data + len else { break }
            let field = String(bytes: b[q..<(q + flen)], encoding: .utf8) ?? ""
            q += flen
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = field[..<eq].uppercased()
            let value = String(field[field.index(after: eq)...])
            switch key {
            case "TITLE": p.tags["title"] = value
            case "ARTIST": p.tags["artist"] = value
            case "ALBUM": p.tags["album"] = value
            case "LYRICS", "UNSYNCEDLYRICS":
                if p.tags["lyrics"] == nil { p.tags["lyrics"] = value }
            default: break
            }
        }
    }

    // MARK: ID3v2

    private static func parseId3(_ b: [UInt8], _ p: inout Parsed) {
        let ver = Int(b[3])
        let flags = Int(b[5])
        let size = syncsafe(b, 6)
        var pos = 10
        if flags & 0x40 != 0, pos + 4 <= b.count { // extended header
            let ext = ver == 4 ? syncsafe(b, pos) : beInt(b, pos)
            pos += ver == 4 ? ext : ext + 4
        }
        let end = min(b.count, pos + size)
        while pos + 10 <= end {
            let id = String(bytes: b[pos..<(pos + 4)], encoding: .ascii) ?? "\0\0\0\0"
            if id.allSatisfy({ $0 == "\0" }) { break }
            let fsize = ver == 4 ? syncsafe(b, pos + 4) : beInt(b, pos + 4)
            if fsize <= 0 || pos + 10 + fsize > b.count { break }
            let body = pos + 10
            switch id {
            case "USLT":
                p.tags.setLyrics(decodeId3Text(b, body, fsize))
            case "TIT2": p.tags["title"] = decodeId3Text(b, body, fsize)
            case "TPE1": p.tags["artist"] = decodeId3Text(b, body, fsize)
            case "TALB": p.tags["album"] = decodeId3Text(b, body, fsize)
            case "TXXX":
                let enc = Int(b[body])
                if let nul = findNul(b, body + 1, fsize - 1, enc) {
                    let desc = decodeText(b, body + 1, nul, enc)
                    let value = decodeText(b, body + 1 + nul + 1, fsize - 1 - nul - 1, enc)
                    if desc.uppercased() == "LYRICS" || desc.uppercased() == "UNSYNCEDLYRICS" {
                        p.tags.setLyrics(value)
                    }
                }
            case "APIC":
                let enc = Int(b[body])
                if let mimeEnd = findNul(b, body + 1, fsize - 1, 1) {
                    let descStart = body + 1 + mimeEnd + 1 + 1 // mime\0 + picture-type byte
                    let descEnd = findNul(b, descStart, fsize - (descStart - body), enc)
                    let dataStart = descEnd > 0 ? body + descEnd + 1 : descStart
                    if dataStart < body + fsize {
                        p.artwork = Data(b[dataStart..<(body + fsize)])
                    }
                }
            default: break
            }
            pos += 10 + fsize
        }
    }

    // MARK: RIFF/WAVE

    private static func parseWav(_ b: [UInt8], _ p: inout Parsed) {
        var pos = 12
        while pos + 8 <= b.count {
            let id = String(bytes: b[pos..<(pos + 4)], encoding: .ascii) ?? ""
            let size = leInt(b, pos + 4)
            let data = pos + 8
            if data + size > b.count { break }
            switch id {
            case "fmt ":
                if size >= 16 {
                    p.channels = leShort(b, data + 2)
                    p.sampleRate = leInt(b, data + 4)
                    p.bits = leShort(b, data + 14)
                }
            case "LIST":
                if size >= 4, String(bytes: b[data..<(data + 4)], encoding: .ascii) == "INFO" {
                    var q = data + 4
                    let end = data + size
                    while q + 8 <= end {
                        let sid = String(bytes: b[q..<(q + 4)], encoding: .ascii) ?? ""
                        let ssize = leInt(b, q + 4)
                        let sd = q + 8
                        if sd + ssize > b.count { break }
                        let value = String(bytes: b[sd..<(sd + ssize)], encoding: .utf8)?
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? ""
                        switch sid {
                        case "INAM": p.tags["title"] = value
                        case "IART": p.tags["artist"] = value
                        case "IPRD": p.tags["album"] = value
                        case "ICMT": p.tags.setLyrics(value)
                        default: break
                        }
                        q = sd + ssize + (ssize & 1)
                    }
                }
            case "id3 ", "ID3 ":
                parseId3(Array(b[data..<min(b.count, data + size)]), &p)
            default: break
            }
            pos = data + size + (size & 1)
        }
    }

    // MARK: helpers

    private static func beInt(_ b: [UInt8], _ at: Int) -> Int {
        (Int(b[at]) << 24) | (Int(b[at + 1]) << 16) | (Int(b[at + 2]) << 8) | Int(b[at + 3])
    }

    private static func leInt(_ b: [UInt8], _ at: Int) -> Int {
        Int(b[at]) | (Int(b[at + 1]) << 8) | (Int(b[at + 2]) << 16) | (Int(b[at + 3]) << 24)
    }

    private static func leShort(_ b: [UInt8], _ at: Int) -> Int {
        Int(b[at]) | (Int(b[at + 1]) << 8)
    }

    private static func syncsafe(_ b: [UInt8], _ at: Int) -> Int {
        (Int(b[at] & 0x7F) << 21) | (Int(b[at + 1] & 0x7F) << 14) |
            (Int(b[at + 2] & 0x7F) << 7) | Int(b[at + 3] & 0x7F)
    }

    private static func findNul(_ b: [UInt8], _ from: Int, _ max: Int, _ enc: Int) -> Int? {
        let n = min(b.count, from + max)
        if enc == 1 || enc == 2 { // UTF-16: NUL is 0x0000
            var i = from
            while i + 1 < n {
                if b[i] == 0, b[i + 1] == 0 { return i - from }
                i += 2
            }
            return nil
        }
        var i = from
        while i < n {
            if b[i] == 0 { return i - from }
            i += 1
        }
        return nil
    }

    private static func decodeId3Text(_ b: [UInt8], _ body: Int, _ fsize: Int) -> String {
        guard fsize > 1 else { return "" }
        return decodeText(b, body + 1, fsize - 1, Int(b[body]))
    }

    private static func decodeText(_ b: [UInt8], _ from: Int, _ len: Int, _ enc: Int) -> String {
        guard len > 0 else { return "" }
        let n = min(b.count, from + len)
        let data = Data(b[from..<n])
        let raw: String
        switch enc {
        case 0: raw = String(data: data, encoding: .isoLatin1) ?? ""
        case 1: raw = String(data: data, encoding: .utf16) ?? ""
        case 2: raw = String(data: data, encoding: .utf16BigEndian) ?? ""
        default: raw = String(data: data, encoding: .utf8) ?? ""
        }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \n\r"))
    }
}

extension Dictionary where Key == String, Value == String {
    /// First non-blank write wins - mirrors the Kotlin parser's setLyrics.
    fileprivate mutating func setLyrics(_ v: String) {
        if !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self["lyrics"] == nil {
            self["lyrics"] = v
        }
    }
}
