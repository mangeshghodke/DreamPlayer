import AVFoundation
import Flutter
import Foundation
import UniformTypeIdentifiers
import UIKit
import Security

/// iOS implementation of the `dreamplayer/files` channel (same contract as
/// `FileBrowser.kt` on Android). iOS is sandboxed, so there is no whole-storage
/// browsing: the base root is the app's Documents directory (exposed via
/// `UIFileSharingEnabled`), and any other folder is accessed through the system
/// document picker (`pickFolder`). Picked folders are kept usable across
/// launches with security-scoped bookmarks stored in UserDefaults.
final class FileBrowser: NSObject {

    static let shared = FileBrowser()
    private static let channelName = "dreamplayer/files"

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
        "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
    ]

    private static let bookmarksKey = "dreamplayer.folderBookmarks"

    /// Library-folder bookmarks ("Add folder to library") live in their own
    /// UserDefaults key so a library folder never shows up as a file-browser
    /// root — Internal storage stays for browsing individual files only.
    private static let libraryBookmarksKey = "dreamplayer.libraryFolderBookmarks"

    /// Synthetic path of the virtual "Files" root. Tapping it opens the system
    /// document picker (the real Files-app home), so it is never listed — Dart
    /// routes it to `openFilesHome` via the `isFilesHome` flag.
    static let filesHomePath = "dreamplayer/files-home"

    /// Security-scoped bookmarks for videos imported into the library, keyed by
    /// their file path. The library re-resolves (and starts access on) a path
    /// via `resolveImportedPath` before playback so Files-app picks stay
    /// readable across launches.
    private static let importedKey = "dreamplayer.importedVideos"

    /// URLs currently resolved from bookmarks with an active security scope.
    private var activeSecurityScopedURLs: [URL] = []
    /// Every stored folder bookmark resolved to its CURRENT URL (id → URL),
    /// recomputed on each `resolveAllBookmarks()`. Resume keys for files inside
    /// a bookmarked folder are derived relative to this current mount point, so
    /// they stay stable even when the provider remounts at a different path.
    private var bookmarkRoots: [String: URL] = [:]
    private var pickerCompletion: FlutterResult?
    private var pickerMode: PickerMode = .folder

    private override init() { super.init() }

    /// What the currently presented system picker returns.
    private enum PickerMode {
        case folder, libraryFolder, file, subtitle
    }

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
    }

    // MARK: - Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasAllFilesAccess":
            result(true)
        case "openAllFilesAccessSettings":
            result(nil)
        case "getStorageRoots":
            result(storageRoots())
        case "listDirectory":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "bad_args", message: "Missing path", details: nil))
                return
            }
            listDirectory(path, result: result)
        case "pickFolder":
            presentFolderPicker(result)
        case "pickLibraryFolder":
            presentLibraryFolderPicker(result)
        case "pickSubtitle":
            presentSubtitlePicker(result)
        case "openFilesHome":
            presentFilePicker(result)
        case "resolveImportedPath":
            let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
            result(resolveImportedPath(path))
        case "resolvePath":
            let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
            result(resolvePath(path))
        case "getThumbnail":
            let args = call.arguments as? [String: Any]
            let path = args?["path"] as? String
            let uri = args?["uri"] as? String
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let data = self?.embeddedArtwork(path: path, uri: uri)
                Task { @MainActor in result(data) }
            }
        case "removeBookmark":
            let bookmarkId = (call.arguments as? [String: Any])?["bookmarkId"] as? String
            if let bookmarkId {
                removeBookmark(bookmarkId)
            }
            result(nil)
        case "removeLibraryBookmark":
            let bookmarkId = (call.arguments as? [String: Any])?["bookmarkId"] as? String
            if let bookmarkId {
                removeLibraryBookmark(bookmarkId)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Roots

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Virtual "Files" root (opens the system Files-app home via the document
    /// picker) + the app's Documents folder + every bookmarked folder.
    private func storageRoots() -> [[String: Any]] {
        var roots: [[String: Any]] = [[
            "name": "Files",
            "path": Self.filesHomePath,
            "isDirectory": true,
            "size": 0,
            "isFilesHome": true,
        ]]
        roots.append(Self.entryMap(documentsURL, isDirectory: true))
        roots.append(contentsOf: resolvedBookmarkEntries())
        return roots
    }

    // MARK: - Listing

    /// Lists [path] off the main thread. On a bookmarked network share (SMB via
    /// Files "Connect to Server") every attribute read is a round trip to the
    /// NAS, so scanning synchronously on the platform main thread froze the UI
    /// for the whole listing (the Dart spinner couldn't even animate).
    /// Bookmark resolution touches shared state, so it stays on the main thread;
    /// only the scan itself is moved to a background queue.
    private func listDirectory(_ path: String, result: @escaping FlutterResult) {
        resolveAllBookmarks()
        let roots = bookmarkRoots
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = Self.scanDirectory(path, roots: roots)
            DispatchQueue.main.async {
                result(entries)
            }
        }
    }

    private static func scanDirectory(_ path: String, roots: [String: URL]) -> [[String: Any]] {
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [["error": "not_found", "path": path]]
        }

        var dirs: [[String: Any]] = []
        var files: [[String: Any]] = []
        for entry in entries {
            // Prefetched by `includingPropertiesForKeys` above, so these reads
            // hit the URL metadata cache instead of re-stat'ing every file (a
            // per-file network round trip on an SMB share). If the share failed
            // to populate the prefetched value, fall back to a single stat.
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            var isDirectory = values?.isDirectory
            if isDirectory == nil {
                var flag: ObjCBool = false
                if FileManager.default.fileExists(atPath: entry.path, isDirectory: &flag) {
                    isDirectory = flag.boolValue
                }
            }
            guard let isDirectory else { continue }
            if isDirectory {
                dirs.append(entryMap(entry, isDirectory: true))
            } else if isVideo(entry.lastPathComponent) {
                files.append(entryMap(
                    entry,
                    isDirectory: false,
                    size: values?.fileSize ?? 0,
                    resumeKey: resumeKey(for: entry.path, roots: roots)
                ))
            }
        }

        dirs.sort { name($0) < name($1) }
        files.sort { name($0) < name($1) }
        return dirs + files
    }

    private static func entryMap(_ url: URL, isDirectory: Bool, size: Int? = nil, bookmarkId: String? = nil, resumeKey: String? = nil) -> [String: Any] {
        let fileSize = size ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var map: [String: Any] = [
            "name": url.lastPathComponent,
            "path": url.path,
            "isDirectory": isDirectory,
            "size": isDirectory ? 0 : fileSize,
        ]
        if let bookmarkId {
            map["bookmarkId"] = bookmarkId
        }
        if let resumeKey {
            map["resumeKey"] = resumeKey
        }
        return map
    }

    private static func name(_ entry: [String: Any]) -> String {
        (entry["name"] as? String ?? "").lowercased()
    }

    private static func isVideo(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return videoExtensions.contains(ext)
    }

    // MARK: - Bookmarks

    private func loadBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:]
    }

    private func saveBookmarks(_ bookmarks: [String: Data]) {
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
    }

    private func loadLibraryBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: Self.libraryBookmarksKey) as? [String: Data] ?? [:]
    }

    private func saveLibraryBookmarks(_ bookmarks: [String: Data]) {
        UserDefaults.standard.set(bookmarks, forKey: Self.libraryBookmarksKey)
    }

    private func resolvedBookmarkEntries() -> [[String: Any]] {
        resolveAllBookmarks()
        var entries: [[String: Any]] = []
        for (id, data) in loadBookmarks() {
            guard let url = resolve(data),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            entries.append(Self.entryMap(url, isDirectory: true, bookmarkId: id))
        }
        return entries
    }

    /// Resolves every stored bookmark (file-browser AND library) and starts its
    /// security scope so its paths are readable this session. Library folders
    /// must be resolvable here so the folder screen can list them, but they are
    /// never surfaced as file-browser roots (see `storageRoots`).
    private func resolveAllBookmarks() {
        var roots: [String: URL] = [:]
        let all = loadBookmarks().merging(loadLibraryBookmarks()) { first, _ in first }
        for (id, data) in all {
            guard let url = resolve(data) else { continue }
            roots[id] = url
            startAccess(url)
        }
        bookmarkRoots = roots
    }

    /// Resolves a security-scoped bookmark. On iOS the security scope is baked
    /// into the bookmark data automatically (no `.withSecurityScope` option,
    /// which is macOS-only); access still has to be started explicitly.
    private func resolve(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }

    private func startAccess(_ url: URL) {
        guard !activeSecurityScopedURLs.contains(url) else { return }
        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs.append(url)
        }
    }

    private func removeBookmark(_ bookmarkId: String) {
        var bookmarks = loadBookmarks()
        guard let data = bookmarks.removeValue(forKey: bookmarkId) else { return }
        saveBookmarks(bookmarks)
        stopAccess(data)
    }

    private func removeLibraryBookmark(_ bookmarkId: String) {
        var bookmarks = loadLibraryBookmarks()
        guard let data = bookmarks.removeValue(forKey: bookmarkId) else { return }
        saveLibraryBookmarks(bookmarks)
        stopAccess(data)
    }

    private func stopAccess(_ data: Data) {
        if let url = resolve(data),
           let index = activeSecurityScopedURLs.firstIndex(of: url) {
            url.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.remove(at: index)
        }
    }

    // MARK: - Folder picker

    private func presentFolderPicker(_ result: @escaping FlutterResult) {
        presentPicker(result, mode: .folder, contentTypes: [.folder])
    }

    private func presentLibraryFolderPicker(_ result: @escaping FlutterResult) {
        presentPicker(result, mode: .libraryFolder, contentTypes: [.folder])
    }

    /// Presents the system document picker (the Files-app home: iCloud Drive,
    /// On My iPad, Downloads, providers...). The picked video is imported
    /// (bookmarked for future sessions) and returned for playback.
    private func presentFilePicker(_ result: @escaping FlutterResult) {
        presentPicker(result, mode: .file, contentTypes: [.movie])
    }

    private func presentSubtitlePicker(_ result: @escaping FlutterResult) {
        let subtitleTypes: [UTType] = [
            UTType(filenameExtension: "srt") ?? .plainText,
            UTType(filenameExtension: "ass") ?? .plainText,
            UTType(filenameExtension: "ssa") ?? .plainText,
            UTType(filenameExtension: "vtt") ?? .plainText,
            .plainText,
        ]
        presentPicker(result, mode: .subtitle, contentTypes: subtitleTypes)
    }

    private func presentPicker(_ result: @escaping FlutterResult,
                               mode: PickerMode,
                               contentTypes: [UTType]) {
        guard pickerCompletion == nil else {
            result(FlutterError(code: "busy", message: "A picker is already open", details: nil))
            return
        }
        guard let top = topViewController() else {
            result(FlutterError(code: "no_vc", message: "No view controller to present the picker", details: nil))
            return
        }
        pickerCompletion = result
        pickerMode = mode
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        top.present(picker, animated: true)
    }

    // MARK: - Imported videos

    /// Embedded cover-art bytes for a local file (metadata-only read via
    /// AVAsset's `commonKeyArtwork` — never decodes video, so HDR content is
    /// safe). MP4/MOV carry `covr` atoms; MKV attachments aren't readable by
    /// AVFoundation, so those files simply return nil (TMDB poster fallback).
    private func embeddedArtwork(path: String?, uri: String?) -> Data? {
        var fileURL: URL?
        if let path, FileManager.default.fileExists(atPath: path) {
            fileURL = URL(fileURLWithPath: path)
        } else if let uri, uri.hasPrefix("file://"), let u = URL(string: uri) {
            fileURL = u
        }
        guard let url = fileURL else { return nil }
        let asset = AVURLAsset(url: url)
        // "itsk" = the common-key artwork identifier (AVMetadataKey
        // .commonKeyArtwork) — matched via rawValue so the lookup is stable
        // across SDK spellings. Metadata-only: never decodes video.
        for item in asset.commonMetadata where item.identifier?.rawValue == "itsk" {
            if let data = item.dataValue, !data.isEmpty { return data }
        }
        return nil
    }

    /// Re-grants security-scoped access to an imported video's file path (the
    /// grant is remembered as a bookmark at import time). Called by the library
    /// before pushing the player.
    private func resolveImportedPath(_ path: String) -> Bool {
        guard let data = loadImported()[path], let url = resolve(data) else { return false }
        startAccess(url)
        return true
    }

    /// Re-grants security-scoped access to [path] whether it belongs to an
    /// imported video or lives inside a bookmarked folder (re-resolves the
    /// folder bookmark and starts its scope). Used when a continue-watching
    /// card is tapped, since the folder's scope is only kept while browsing.
    private func resolvePath(_ path: String) -> Bool {
        if resolveImportedPath(path) { return true }
        resolveAllBookmarks()
        for (_, url) in bookmarkRoots {
            if path == url.path || path.hasPrefix(url.path + "/") {
                startAccess(url)
                return true
            }
        }
        return false
    }

    /// Stable resume identity for a file inside a bookmarked folder:
    /// `folderbookmark:<bookmarkId>:<path relative to the current mount>`.
    /// The relative part is computed against the CURRENT (re-resolved) root
    /// path, so the key survives the provider remounting the share at a
    /// different location between launches. Files outside bookmarked folders
    /// get no key (their absolute path is used instead).
    private static func resumeKey(for path: String, roots: [String: URL]) -> String? {
        for (id, root) in roots {
            let rootPath = root.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let rel = String(path.dropFirst(rootPath.count))
            return "folderbookmark:\(id)\(rel)"
        }
        return nil
    }

    private func loadImported() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: Self.importedKey) as? [String: Data] ?? [:]
    }

    /// Remembers [url] as an imported video (keyed by path) so its security
    /// scope can be re-granted later via `resolveImportedPath`.
    private func importFile(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .minimalBookmark) else { return }
        var imported = loadImported()
        imported[url.path] = data
        saveImported(imported)
    }

    private func saveImported(_ imported: [String: Data]) {
        UserDefaults.standard.set(imported, forKey: Self.importedKey)
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        return topMost(from: root)
    }

    private func topMost(from viewController: UIViewController) -> UIViewController? {
        if let nav = viewController as? UINavigationController {
            return topMost(from: nav.visibleViewController ?? nav)
        }
        if let tab = viewController as? UITabBarController {
            return topMost(from: tab.selectedViewController ?? tab)
        }
        if let presented = viewController.presentedViewController {
            return topMost(from: presented)
        }
        return viewController
    }
}

// MARK: - UIDocumentPickerDelegate

extension FileBrowser: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let completion = pickerCompletion else { return }
        pickerCompletion = nil
        guard let url = urls.first else {
            completion(FlutterError(code: "no_file", message: "No file was selected", details: nil))
            return
        }
        startAccess(url)
        switch pickerMode {
        case .folder:
            let bookmarkId = UUID().uuidString
            if let data = try? url.bookmarkData(options: .minimalBookmark) {
                var bookmarks = loadBookmarks()
                bookmarks[bookmarkId] = data
                saveBookmarks(bookmarks)
            }
            completion(Self.entryMap(url, isDirectory: true, bookmarkId: bookmarkId))
        case .libraryFolder:
            let bookmarkId = UUID().uuidString
            if let data = try? url.bookmarkData(options: .minimalBookmark) {
                var bookmarks = loadLibraryBookmarks()
                bookmarks[bookmarkId] = data
                saveLibraryBookmarks(bookmarks)
            }
            completion(Self.entryMap(url, isDirectory: true, bookmarkId: bookmarkId))
        case .file:
            // Import the picked video (bookmark it) so it stays readable across
            // launches and continue-watching card taps can re-grant its scope.
            importFile(url)
            completion(Self.entryMap(url, isDirectory: false))
        case .subtitle:
            // Return a content/file URL string for the picked subtitle.
            // On iOS the security scope must be held for the playback session;
            // keep it in activeSecurityScopedURLs via startAccess.
            completion(url.absoluteString)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerCompletion?(nil)
        pickerCompletion = nil
    }
}

final class TheTvdbCredentialStore {
    private static let channelName = "dreamplayer/the_tvdb_credentials"
    private static let service = "com.dreamplayer.app.theTvdb"
    private static let apiKeyAccount = "apiKey"
    private static let pinAccount = "pin"
    private static let legacyApiKey = "dreamplayer.theTvdbApiKey"
    private static let legacyPin = "dreamplayer.theTvdbPin"

    static func register(with messenger: FlutterBinaryMessenger) {
        migrateLegacy()
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            do {
                switch call.method {
                case "read":
                    let apiKey = try read(apiKeyAccount)
                    let pin = try read(pinAccount)
                    result([
                        "apiKey": apiKey ?? NSNull(),
                        "pin": pin ?? NSNull(),
                    ])
                case "write":
                    let args = call.arguments as? [String: Any]
                    try write(args?["apiKey"] as? String, account: apiKeyAccount)
                    try write(args?["pin"] as? String, account: pinAccount)
                    result(nil)
                case "clear":
                    try delete(apiKeyAccount)
                    try delete(pinAccount)
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            } catch {
                result(FlutterError(
                    code: "credential_store",
                    message: error.localizedDescription,
                    details: nil
                ))
            }
        }
    }

    private static func migrateLegacy() {
        let defaults = UserDefaults.standard
        guard let apiKey = defaults.string(forKey: legacyApiKey),
              !apiKey.isEmpty else { return }
        do {
            let existingKey = try read(apiKeyAccount) ?? ""
            if existingKey.isEmpty {
                try write(apiKey, account: apiKeyAccount)
            }
            if let pin = defaults.string(forKey: legacyPin),
               !pin.isEmpty {
                let existingPin = try read(pinAccount) ?? ""
                if existingPin.isEmpty {
                    try write(pin, account: pinAccount)
                }
            }
            defaults.removeObject(forKey: legacyApiKey)
            defaults.removeObject(forKey: legacyPin)
        } catch {
        }
    }

    private static func read(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: service,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "TheTVDB credential could not be read."]
            )
        }
        return value
    }

    private static func write(_ value: String?, account: String) throws {
        try delete(account)
        guard let value, !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    private static func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: service,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "TheTVDB Keychain operation failed (\(status))."]
        )
    }
}
