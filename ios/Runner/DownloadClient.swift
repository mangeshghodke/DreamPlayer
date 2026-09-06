import Flutter
import Foundation
import UserNotifications

/// iOS download client (channel `dreamplayer/download`), mirroring
/// `DownloadClient.kt`. iOS has no foreground-service model, so the Dart
/// `DownloadManager` handles the actual HTTP download — this class only
/// provides the download directory and drives a progress notification.
final class DownloadClient: NSObject, UNUserNotificationCenterDelegate {

    private static let channelName = "dreamplayer/download"
    private static let notificationId = "dreamplayer_download"
    private static let notificationCategoryId = "download_progress"
    private static let cancelActionId = "download_cancel"

    private var channel: FlutterMethodChannel?
    private var hasRequestedPermission = false

    // MARK: - Registration

    static func register(with messenger: FlutterBinaryMessenger) {
        let client = DownloadClient()
        let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        client.channel = ch
        ch.setMethodCallHandler { call, result in
            client.handle(call, result: result)
        }
        // Set ourselves as the notification center delegate so foreground
        // notifications are shown and action taps are forwarded to Dart.
        UNUserNotificationCenter.current().delegate = client
        // Register the cancel action with the notification category.
        client.registerNotificationCategories()
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
            showNotification(title: title, bytesCopied: 0, totalBytes: totalBytes, jobId: jobId)
            result(true)
        case "updateProgress":
            let title = args?["title"] as? String ?? "Download"
            let bytesCopied = args?["bytesCopied"] as? Int64 ?? 0
            let totalBytes = args?["totalBytes"] as? Int64 ?? -1
            updateNotification(title: title, bytesCopied: bytesCopied, totalBytes: totalBytes)
            result(true)
        case "stopService":
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

    /// Returns `Documents/DreamPlayer`, creating it if needed.
    private func downloadDirectory() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("DreamPlayer")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.path
    }

    // MARK: - Notifications

    private func registerNotificationCategories() {
        let cancelAction = UNNotificationAction(
            identifier: Self.cancelActionId,
            title: "Cancel",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.notificationCategoryId,
            actions: [cancelAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func requestPermission() {
        guard !hasRequestedPermission else { return }
        hasRequestedPermission = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                print("[DownloadClient] Notification permission denied")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge])
    }

    /// Forward action taps (cancel) to the Dart DownloadManager.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.cancelActionId {
            let jobId = response.notification.request.content.userInfo["jobId"] as? String ?? ""
            if !jobId.isEmpty {
                channel?.invokeMethod("onCancelFromNotification", arguments: jobId)
            }
        }
        completionHandler()
    }

    private func showNotification(title: String, bytesCopied: Int64, totalBytes: Int64, jobId: String) {
        let content = UNMutableNotificationContent()
        content.title = "DreamPlayer"
        content.body = "Downloading \(title)…"
        content.sound = nil
        content.categoryIdentifier = Self.notificationCategoryId

        // Progress info for the notification extension (if ever added) + badge.
        var userInfo: [String: Any] = ["jobId": jobId]
        if totalBytes > 0 {
            let progress = Float(bytesCopied) / Float(totalBytes)
            userInfo["progress"] = min(max(progress, 0), 1)
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: Self.notificationId,
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func updateNotification(title: String, bytesCopied: Int64, totalBytes: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "DreamPlayer"

        if totalBytes > 0 {
            let pct = Int(min(bytesCopied * 100 / totalBytes, 100))
            let downloaded = byteCount(bytesCopied)
            let total = byteCount(totalBytes)
            content.body = "\(title) — \(downloaded) / \(total) (\(pct)%)"
            content.userInfo = [
                "progress": min(max(Float(bytesCopied) / Float(totalBytes), 0), 1),
            ]
        } else {
            let downloaded = byteCount(bytesCopied)
            content.body = "\(title) — \(downloaded)"
        }
        content.sound = nil
        content.categoryIdentifier = Self.notificationCategoryId

        let request = UNNotificationRequest(
            identifier: Self.notificationId,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func removeNotification() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.notificationId])
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationId])
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Resolves a local file URI/path to a readable file path.
    /// For `file://` URIs from the Files app, this returns the path directly.
    private func resolveLocalPath(uri: String, path: String) -> String? {
        // Try the path first (already a filesystem path).
        if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            return path
        }
        // Try the URI (may be a file:// URL).
        if !uri.isEmpty, let url = URL(string: uri) {
            let filePath = url.path
            if FileManager.default.fileExists(atPath: filePath) {
                return filePath
            }
        }
        return nil
    }
}
