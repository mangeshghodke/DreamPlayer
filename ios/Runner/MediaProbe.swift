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
        let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
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
        }

        // Tracks
        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                let mediaType = try? await track.load(.mediaType)
                if mediaType == .video {
                    let size = try? await track.load(.naturalSize)
                    let xform = try? await track.load(.naturalSizeTransform)
                    if let s = size, let t = xform {
                        let dim = t.transformedSize(s)
                        if !out.keys.contains("width") { out["width"] = Int(dim.width) }
                        if !out.keys.contains("height") { out["height"] = Int(dim.height) }
                    }
                    if let desc = try? await track.load(.formatDescriptions), let fmt = desc.first {
                        out["videoMime"] = fourCCtoString(CMFormatDescriptionGetMediaSubType(fmt))
                    }
                    if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                        out["fps"] = Int(round(rate))
                    }
                } else if mediaType == .audio {
                    if let desc = try? await track.load(.formatDescriptions), let fmt = desc.first {
                        out["audioMime"] = fourCCtoString(CMFormatDescriptionGetMediaSubType(fmt))
                    }
                    if let ch = try? await track.load(.channelCount) {
                        out["audioChannels"] = Int(ch)
                    }
                    if let lang = try? await track.load(.languageCode), !lang.isEmpty, lang != "und" {
                        out["audioLanguage"] = lang
                    }
                }
            }
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
