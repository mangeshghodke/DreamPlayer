import Flutter
import Foundation
import UIKit

/// iOS mirror of the Android "Open with" intent flow: implements the
/// `dreamplayer/intent` channel contract (see `MainActivity.kt`).
///
/// - `getInitialIntent`: Dart asks for the URL that launched the app (cold
///   start via the Files app / share sheet), captured from the launch options /
///   scene connection options.
/// - `open`: invoked natively whenever a video URL arrives while the app is
///   running (`application(_:open:options:)` / `scene(_:openURLContexts:)`).
///
/// File URLs handed over by the Files app are security-scoped resources
/// (in-place, possibly iCloud); the scope is kept active for the session so
/// AVPlayer can read the file.
final class IntentBridge {
    static let shared = IntentBridge()
    static let channelName = "dreamplayer/intent"

    private var intentChannel: FlutterMethodChannel?
    private var pendingInitialPayload: [String: Any]?
    /// URLs that arrived before the Flutter engine registered the channel
    /// (e.g. a Shortcuts "Play URL" run, which opens the app and performs the
    /// intent possibly before `configure` ran). Flushed in `configure`.
    private var pendingOpens: [[String: Any]] = []
    private var securityScopedURLs: [URL] = []

    /// Dedupe: on scene-based apps the same URL can arrive through both the app
    /// delegate and the scene delegate; only forward the first copy.
    private var lastURLKey: String?
    private var lastURLTime: Date?

    private init() {}

    func configure(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "getInitialIntent" else {
                result(FlutterMethodNotImplemented)
                return
            }
            let payload = self?.pendingInitialPayload
            self?.pendingInitialPayload = nil
            result(payload)
        }
        intentChannel = channel
        for payload in pendingOpens {
            channel.invokeMethod("open", arguments: payload)
        }
        pendingOpens.removeAll()
    }

    /// Records the URL that launched the app (cold start). Idempotent — the
    /// same launch URL is reported by both the app delegate and the scene
    /// delegate; the later write simply overwrites the same payload.
    func setInitialURL(_ url: URL) {
        pendingInitialPayload = payload(for: url)
    }

    /// Forwards a URL opened while the app is running to the Dart side.
    func handleOpenURL(_ url: URL) {
        let key = url.absoluteString
        if key == lastURLKey,
           let lastURLTime,
           Date().timeIntervalSince(lastURLTime) < 1.5 {
            return
        }
        lastURLKey = key
        lastURLTime = Date()

        let payload = payload(for: url)
        if let intentChannel {
            intentChannel.invokeMethod("open", arguments: payload)
        } else {
            pendingOpens.append(payload)
        }
    }

    private func payload(for url: URL) -> [String: Any] {
        var payload: [String: Any] = [:]
        if url.isFileURL {
            // Keep security-scoped (Files-in-place / iCloud) resources readable
            // for the whole playback session.
            releaseSecurityScopedURLs()
            if url.startAccessingSecurityScopedResource() {
                securityScopedURLs.append(url)
            }
            payload["path"] = url.path
            payload["uri"] = url.absoluteString
            payload["title"] = url.lastPathComponent
        } else {
            payload["uri"] = url.absoluteString
            let name = url.lastPathComponent
            payload["title"] = name.isEmpty ? (url.host ?? "Video") : name
        }
        return payload
    }

    private func releaseSecurityScopedURLs() {
        securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        securityScopedURLs.removeAll()
    }
}
