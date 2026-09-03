import AVFoundation
import Flutter
import Foundation

/// Native media probe for iOS — extracts video/audio codec, resolution, fps,
/// duration, language, and channel count from any URL that AVFoundation can open.
final class MediaProbe: NSObject {

    static let shared = MediaProbe()
    private static let channelName = "dreamplayer/mediaProbe"

    /// Debug log file exposed via UIFileSharingEnabled (Files app → On My iPad → DreamPlayer)
    private static var logURL: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docs.appendingPathComponent("probe_debug.log")
    }

    private static func log(_ msg: String) {
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

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
        // Clear log on each app launch
        if let url = logURL { try? FileManager.default.removeItem(at: url) }
        log("=== MediaProbe session started ===")
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
        log("PROBE path=\(path ?? "nil") uri=\(uri ?? "nil")")
        if let u = uri ?? path, u.hasPrefix("http://") || u.hasPrefix("https://") {
            log("→ dispatching to probeHttp")
            return await probeHttp(url: u, headers: headers)
        }
        if let p = path, !p.hasPrefix("smb://") && !p.hasPrefix("ftp://") &&
            !p.hasPrefix("sftp://") && !p.hasPrefix("content://") {
            log("→ dispatching to probeLocal")
            return await probeLocal(filePath: p)
        }
        if let u = uri ?? path, u.hasPrefix("content://") {
            log("→ dispatching to probeContentUri")
            return await probeContentUri(u)
        }
        log("→ no matching dispatch, returning empty")
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
        log("PROBE_LOCAL path=\(filePath) exists=\(exists)")
        guard exists else { return [:] }
        let fileURL = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: fileURL)
        return await probeAsset(asset)
    }

    // MARK: - content://

    private func probeContentUri(_ uri: String) async -> [String: Any] {
        guard let url = URL(string: uri) else { return [:] }
        return await probeAsset(AVURLAsset(url: url))
    }

    // MARK: - Core

    private func probeAsset(_ asset: AVAsset) async -> [String: Any] {
        var out: [String: Any] = [:]
        let desc = asset.description
        log("PROBE_ASSET \(desc)")

        // Duration
        do {
            let dur = try await asset.load(.duration)
            if dur.isNumeric {
                out["durationMs"] = Int(CMTimeGetSeconds(dur) * 1000)
                log("  duration=\(out["durationMs"]!)ms")
            } else {
                log("  duration not numeric: \(dur)")
            }
        } catch {
            log("  duration error: \(error)")
        }

        // Tracks
        do {
            let tracks = try await asset.load(.tracks)
            log("  tracks count=\(tracks.count)")
            for track in tracks {
                let mediaType = track.mediaType
                log("  track: type=\(mediaType) formatDescs=\(track.formatDescriptions.count)")
                if mediaType == .video {
                    let size = track.naturalSize
                    let dim = size.applying(track.preferredTransform)
                    if !out.keys.contains("width") { out["width"] = Int(dim.width) }
                    if !out.keys.contains("height") { out["height"] = Int(dim.height) }
                    log("  video: \(dim.width)x\(dim.height) fps=\(track.nominalFrameRate)")
                    if let desc = track.formatDescriptions.first {
                        let fmtDesc = desc as! CMFormatDescription
                        let codec = CMFormatDescriptionGetMediaSubType(fmtDesc)
                        let mime = fourCCtoString(codec)
                        out["videoMime"] = mime
                        log("  video codec=\(mime) fourCC=\(codec)")
                    }
                    let rate = track.nominalFrameRate
                    if rate > 0 { out["fps"] = Int(round(rate)) }
                } else if mediaType == .audio {
                    if let desc = track.formatDescriptions.first {
                        let fmtDesc = desc as! CMFormatDescription
                        let codec = CMFormatDescriptionGetMediaSubType(fmtDesc)
                        let mime = fourCCtoString(codec)
                        out["audioMime"] = mime
                        log("  audio codec=\(mime) fourCC=\(codec)")
                    }
                    let lang = track.languageCode ?? ""
                    if !lang.isEmpty && lang != "und" { out["audioLanguage"] = lang }
                }
            }
        } catch {
            log("  tracks error: \(error)")
        }

        log("PROBE_RESULT \(out)")
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
