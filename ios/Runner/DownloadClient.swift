import Flutter
import Foundation
import UserNotifications

/// iOS download client (channel `dreamplayer/download`), mirroring
/// `DownloadClient.kt`. iOS has no foreground-service model, so the Dart
/// `DownloadManager` handles the actual HTTP download — this class only
/// provides the download directory and drives a progress notification.
///
/// IMPORTANT: We must NOT set `UNUserNotificationCenter.current().delegate`
/// because that intercepts ALL system notifications (not just ours) and
/// setting it combined with rapid `add()` calls crashes the iPad.
final class DownloadClient: NSObject {

    private static let channelName = "dreamplayer/download"
    private static let notificationId = "dreamplayer_download"

    private var channel: FlutterMethodChannel?
    private var hasRequestedPermission = false
    private var lastUpdateTime: TimeInterval = 0

    // MARK: - Registration

    static func register(with messenger: FlutterBinaryMessenger) {
        let client = DownloadClient()
        let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        client.channel = ch
        ch.setMethodCallHandler { call, result in
            client.handle(call, result: result)
        }
        // Do NOT set delegate — it would intercept ALL system notifications.
        // Ask for notification permission early (no-op if already granted).
        client.requestPermission()
    }

    // MARK: - Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "getDownloadDir":
            let dir = downloadDirectory()
            result(dir)
        case "startService":
            let title = args?["title"] as? String ?? "Download"
            let totalBytes = args?["totalBytes"] as? Int64 ?? -1
            let jobId = args?["jobId"] as? String ?? ""
            requestPermission()
            lastUpdateTime = 0
            showNotification(title: title, bytesCopied: 0, totalBytes: totalBytes, jobId: jobId)
            result(true)
        case "updateProgress":
            let title = args?["title"] as? String ?? "Download"
            let bytesCopied = args?["bytesCopied"] as? Int64 ?? 0
            let totalBytes = args?["totalBytes"] as? Int64 ?? -1
            updateNotification(title: title, bytesCopied: bytesCopied, totalBytes: totalBytes)
            result(true)
        case "stopService":
            lastUpdateTime = 0
            removeNotification()
            result(true)
        case "resolveLocalPath":
            let uri = args?["uri"] as? String ?? ""
            let path = args?["path"] as? String ?? ""
            if let resolved = resolveLocalPath(uri: uri, path: path) {
                result(resolved)
            } else {
                result(nil)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Directory

    private func downloadDirectory() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("DreamPlayer")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.path
    }

    // MARK: - Notifications

    private func requestPermission() {
        guard !hasRequestedPermission else { return }
        hasRequestedPermission = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func showNotification(title: String, bytesCopied: Int64, totalBytes: Int64, jobId: String) {
        let content = UNMutableNotificationContent()
        content.title = "DreamPlayer"
        content.body = "Downloading \(title)…"
        content.sound = nil

        var userInfo: [String: Any] = ["jobId": jobId]
        if totalBytes > 0 {
            userInfo["progress"] = min(max(Float(bytesCopied) / Float(totalBytes), 0), 1)
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: Self.notificationId,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func updateNotification(title: String, bytesCopied: Int64, totalBytes: Int64) {
        // Throttle to once every 5 seconds — rapid updates crash iPad.
        let now = Date().timeIntervalSince1970
        guard now - lastUpdateTime >= 5 else { return }
        lastUpdateTime = now

        let content = UNMutableNotificationContent()
        content.title = "DreamPlayer"
        if totalBytes > 0 {
            let pct = Int(min(bytesCopied * 100 / totalBytes, 100))
            content.body = "\(title) — \(byteCount(bytesCopied)) / \(byteCount(totalBytes)) (\(pct)%)"
        } else {
            content.body = "\(title) — \(byteCount(bytesCopied))"
        }
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: Self.notificationId,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func removeNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationId])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationId])
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func resolveLocalPath(uri: String, path: String) -> String? {
        if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            return path
        }
        if !uri.isEmpty, let url = URL(string: uri) {
            let filePath = url.path
            if FileManager.default.fileExists(atPath: filePath) {
                return filePath
            }
        }
        return nil
    }
}
