import Flutter
import Foundation
import UserNotifications

/// iOS download client (channel `dreamplayer/download`), mirroring
/// `DownloadClient.kt`. iOS has no foreground-service model, so the Dart
/// `DownloadManager` handles the actual HTTP download — this class only
/// provides the download directory and drives a progress notification.
///
/// The `UNUserNotificationCenterDelegate` is set so notifications display
/// in the foreground and cancel-action taps reach Dart. The native side
/// throttles `add()` to once per 5 seconds to avoid flooding the system.
final class DownloadClient: NSObject, UNUserNotificationCenterDelegate {

    private static let channelName = "dreamplayer/download"
    private static let notificationId = "dreamplayer_download"
    private static let notificationCategoryId = "download_progress"
    private static let cancelActionId = "download_cancel"

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
        // Set delegate so foreground notifications show and action taps reach Dart.
        UNUserNotificationCenter.current().delegate = client
        // Register cancel action.
        client.registerNotificationCategories()
        // Ask for notification permission early (no-op if already granted).
        client.requestPermission()
    }

    // MARK: - Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "getDownloadDir":
            result(downloadDirectory())
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
            result(resolveLocalPath(uri: uri, path: path))
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
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
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

    /// Forward cancel-action taps to the Dart DownloadManager.
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

    // MARK: - Notification posting (throttled)

    private func showNotification(title: String, bytesCopied: Int64, totalBytes: Int64, jobId: String) {
        let content = UNMutableNotificationContent()
        content.title = "DreamPlayer"
        content.body = "Downloading \(title)…"
        content.sound = nil
        content.categoryIdentifier = Self.notificationCategoryId

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
        // Throttle to once per 5 seconds — rapid add() calls crash iPad.
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
        content.categoryIdentifier = Self.notificationCategoryId

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
