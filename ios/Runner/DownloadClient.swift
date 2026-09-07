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
    private var lastUpdateTime: TimeInterval = 0
    /// Only show the banner once per download session — subsequent updates
    /// update the notification panel silently without popping a new banner.
    private var hasShownBanner = false
    /// Stored from startService so updateNotification can include it in userInfo
    /// for the cancel action to work.
    private var currentJobId: String = ""

    // MARK: - Registration

    static func register(with messenger: FlutterBinaryMessenger) {
        let client = DownloadClient()
        let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        client.channel = ch
        ch.setMethodCallHandler { call, result in
            client.handle(call, result: result)
        }
        // Register the cancel action BEFORE setting delegate.
        client.registerNotificationCategories()
        // Set delegate so foreground notifications show and action taps reach Dart.
        UNUserNotificationCenter.current().delegate = client
        // Ask for notification permission early (no-op if already granted).
        client.requestPermission()
    }

    // MARK: - Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "getDownloadDir":
            result(downloadDirectory())
        case "setDownloadDir":
            let path = args?["path"] as? String ?? ""
            result(setDownloadDir(path))
        case "startService":
            let title = args?["title"] as? String ?? "Download"
            let totalBytes = args?["totalBytes"] as? Int64 ?? -1
            let jobId = args?["jobId"] as? String ?? ""
            requestPermission()
            lastUpdateTime = 0
            hasShownBanner = false
            currentJobId = jobId
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
            hasShownBanner = false
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
        let custom = UserDefaults.standard.string(forKey: "dreamplayer.downloadDir")
        if let custom = custom, !custom.isEmpty {
            let dir = URL(fileURLWithPath: custom)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir.path
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("DreamPlayer")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.path
    }

    private func setDownloadDir(_ path: String) -> String {
        if path.isEmpty {
            UserDefaults.standard.removeObject(forKey: "dreamplayer.downloadDir")
        } else {
            UserDefaults.standard.set(path, forKey: "dreamplayer.downloadDir")
        }
        return downloadDirectory()
    }

    // MARK: - Notifications

    private func registerNotificationCategories() {
        let cancelAction = UNNotificationAction(
            identifier: Self.cancelActionId,
            title: "Cancel",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.notificationCategoryId,
            actions: [cancelAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
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

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if hasShownBanner {
            // Silent update — update the panel but don't pop a new banner.
            completionHandler([.list, .badge])
        } else {
            // First notification — show banner + persist in panel.
            hasShownBanner = true
            completionHandler([.list, .banner, .badge])
        }
    }

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
        } else if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            // User swiped away the notification — no-op.
        } else {
            // Tapped the notification body — open the download section.
            channel?.invokeMethod("onNotificationTap", arguments: nil)
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
        // Throttle to once per 5 seconds.
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

        // Preserve jobId in userInfo for the cancel action.
        content.userInfo = ["jobId": currentJobId]

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
