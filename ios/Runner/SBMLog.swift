import Foundation
import os

/// Debug log for the iOS SMB stack, written to a file the user can pull off
/// the device: Files -> On My iPad -> DreamPlayer -> smb_debug.log
/// (`UIFileSharingEnabled` is already set, so Documents is visible there).
///
/// Exists because iOS work is verified blind: the only way to see what the
/// SMB bridge actually did on a real NAS is to have the app write it down and
/// hand it back. Also NSLogs, so Xcode's console shows the same lines.
///
/// Passwords are never written: [redact] strips them at the call site.
enum SBMLog {
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "app.dreamplayer.smb.log")
    /// Rotate rather than grow without bound — a long browsing session would
    /// otherwise fill the device.
    private static let maxBytes = 4 * 1024 * 1024
    private static var booted = false

    private static var url: URL? = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent("smb_debug.log")
    }()

    /// One-time header, so a shared log says which build produced it.
    static func boot() {
        lock.lock()
        let already = booted
        booted = true
        lock.unlock()
        guard !already else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        write("""
        ===== DreamPlayer SMB debug =====
        version \(version) (\(build))
        device \(UIDeviceInfo.current)
        started \(timestamp())
        ==================================
        """)
    }

    /// Hides a secret from the log. Used for every password argument.
    static func redact(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<none>" }
        return "<redacted:\(value.count)>"
    }

    /// `args` with anything password-ish blanked, so a raw arg dump is safe.
    static func scrub(_ args: [String: Any]) -> String {
        let safe = args.map { key, value -> String in
            let k = key.lowercased()
            if k.contains("password") || k.contains("passwd") || k.contains("secret")
                || k.contains("token")
            {
                return "\(key): \(redact(value as? String))"
            }
            return "\(key): \(value)"
        }
        return "{" + safe.joined(separator: ", ") + "}"
    }

    static func log(_ message: String) {
        let line = "\(timestamp())  \(message)"
        NSLog("[SMB] %@", message)
        write(line + "\n")
    }

    /// Elapsed milliseconds since a `Date`, for timing the network calls.
    static func since(_ start: Date) -> String {
        String(format: "%.0fms", Date().timeIntervalSince(start) * 1000)
    }

    // MARK: - File IO

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private static func write(_ text: String) {
        queue.async {
            guard let url else { return }
            let data = Data(text.utf8)
            // Truncate in place once the cap is passed; a rotation dance would
            // risk losing the tail that matters most (the last error).
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > maxBytes,
               let handle = try? FileHandle(forWritingTo: url) {
                try? handle.truncate(atOffset: 0)
                try? handle.close()
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }
}

private enum UIDeviceInfo {
    static var current: String {
        let device = UIDevice.current
        return "\(device.model) / \(device.systemName) \(device.systemVersion)"
    }
}
