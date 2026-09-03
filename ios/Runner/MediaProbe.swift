import AVFoundation
import Flutter

/// Native media probe for iOS — extracts video/audio codec, resolution, fps,
/// duration, language, and channel count from any URL that AVFoundation can open.
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
        NSLog("[MediaProbe] probe path=\(path ?? "nil") uri=\(uri ?? "nil")")
        if let u = uri ?? path, u.hasPrefix("http://") || u.hasPrefix("https://") {
            return await probeHttp(url: u, headers: headers)
        }
        if let p = path, !p.hasPrefix("smb://") && !p.hasPrefix("ftp://") &&
            !p.hasPrefix("sftp://") && !p.hasPrefix("content://") {
            return await probeLocal(filePath: p)
        }
        if let u = uri ?? path, u.hasPrefix("content://") {
            return await probeContentUri(u)
        }
        NSLog("[MediaProbe] no matching probe path for path=\(path ?? "nil") uri=\(uri ?? "nil")")
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
        let fileURL = URL(fileURLWithPath: filePath)
        let exists = FileManager.default.fileExists(atPath: filePath)
        NSLog("[MediaProbe] probeLocal path=\(filePath) exists=\(exists)")
        guard exists else { return [:] }
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

        // Duration
        if let dur = try? await asset.load(.duration), dur.isNumeric {
            out["durationMs"] = Int(CMTimeGetSeconds(dur) * 1000)
        } else {
            NSLog("[MediaProbe] duration load failed for \(asset)")
        }

        // Tracks — use sync properties where async ones aren't available
        if let tracks = try? await asset.load(.tracks), !tracks.isEmpty {
            for track in tracks {
                let mediaType = track.mediaType
                if mediaType == .video {
                    let size = track.naturalSize
                    let dim = size.applying(track.preferredTransform)
                    if !out.keys.contains("width") { out["width"] = Int(dim.width) }
                    if !out.keys.contains("height") { out["height"] = Int(dim.height) }
                    // Codec from format description
                    if let desc = track.formatDescriptions.first {
                        out["videoMime"] = fourCCtoString(CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription))
                    }
                    // FPS
                    let rate = track.nominalFrameRate
                    if rate > 0 { out["fps"] = Int(round(rate)) }
                } else if mediaType == .audio {
                    // Codec from format description
                    if let desc = track.formatDescriptions.first {
                        out["audioMime"] = fourCCtoString(CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription))
                    }
                    // Language
                    let lang = track.languageCode ?? ""
                    if !lang.isEmpty && lang != "und" { out["audioLanguage"] = lang }
                }
            }
        } else {
            NSLog("[MediaProbe] tracks load failed or empty for \(asset)")
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
