import AVFoundation
import Flutter
import Foundation
import PhotosUI
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
            "strm", "m3u", "m3u8",
    ]

    private static let bookmarksKey = "dreamplayer.folderBookmarks"

    /// Library-folder bookmarks ("Add folder to library") live in their own
    /// UserDefaults key so a library folder never shows up as a file-browser
    /// root - Internal storage stays for browsing individual files only.
    private static let libraryBookmarksKey = "dreamplayer.libraryFolderBookmarks"

    /// Synthetic path of the virtual "Files" root. Tapping it opens the system
    /// document picker (the real Files-app home), so it is never listed - Dart
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
    /// Separate completion for the Photos (PHPicker) picker - it has its
    /// own delegate protocol, so it cannot share `pickerCompletion`.
    private var photoPickerCompletion: FlutterResult?

    private override init() { super.init() }

    /// What the currently presented system picker returns.
    private enum PickerMode {
        case folder, libraryFolder, file, subtitle, font, files, folderContents
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
        case "pickFontFile":
            presentFontPicker(result)
        case "pickFiles":
            presentFilesPicker(result)
        case "pickFolderContents":
            presentFolderContentsPicker(result)
        case "pickPhotos":
            presentPhotosPicker(result)
        case "copyFontFile":
            let args = call.arguments as? [String: Any]
            let uri = args?["uri"] as? String ?? ""
            let destPath = args?["destPath"] as? String ?? ""
            result(copyFontFile(uri: uri, destPath: destPath))
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
        // The app's Documents directory always exists on iOS; fall back to the
        // Caches directory, then to a constructed path, so this can never
        // crash on a force-unwrapped empty array.
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return url
        }
        if let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return url
        }
        return URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true).first ?? NSHomeDirectory())
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
        lastStaleBookmarkURL = nil
        resolveAllBookmarks()
        let roots = bookmarkRoots
        // Did we manage to open a scope for anything? If the drive was picked
        // from an external volume and the scope was refused, every listing
        // under it fails and the caller sees an empty folder.
        let anyScopeOpen = !activeSecurityScopedURLs.isEmpty
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = Self.scanDirectory(
                path,
                roots: roots,
                staleBookmark: self.lastStaleBookmarkURL != nil,
                scopeOpen: anyScopeOpen
            )
            DispatchQueue.main.async {
                result(entries)
            }
        }
    }

    private static func scanDirectory(
        _ path: String,
        roots: [String: URL],
        staleBookmark: Bool = false,
        scopeOpen: Bool = true
    ) -> [[String: Any]] {
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            // Say WHY. A bare "not_found" was indistinguishable from an
            // empty folder, so a failed add looked like a silent no-op.
            let reason: String
            if !scopeOpen {
                reason = "no_permission"
            } else if staleBookmark {
                reason = "stale_bookmark"
            } else {
                reason = "not_found"
            }
            return [["error": reason, "path": path]]
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
        let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale, let url {
            // A stale bookmark still resolves, but on a removable volume the
            // scope it carries is usually no longer valid - which is why an
            // external drive kept failing while internal storage worked.
            // The URL is still the truth right now, so re-issue a fresh
            // bookmark from it and report the staleness for diagnostics.
            lastStaleBookmarkURL = url
        }
        return url
    }

    /// Set when the most recent resolve saw a stale bookmark. Purely
    /// diagnostic: surfaced on list errors so a silent "nothing added" becomes
    /// an explainable failure.
    private var lastStaleBookmarkURL: URL?

    /// Returns false when the security scope could NOT be started. Previously
    /// the return value was discarded, so a refused scope looked exactly like
    /// success and the folder simply listed as empty.
    @discardableResult
    private func startAccess(_ url: URL) -> Bool {
        if activeSecurityScopedURLs.contains(url) { return true }
        let started = url.startAccessingSecurityScopedResource()
        if started { activeSecurityScopedURLs.append(url) }
        return started
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

    /// Picks a font file (.ttf/.otf/.ttc/.woff/.woff2) from anywhere the
    /// document picker can reach (Files, iCloud Drive, Downloads, providers).
    private func presentFontPicker(_ result: @escaping FlutterResult) {
        let fontTypes: [UTType] = [
            .font,
            UTType(filenameExtension: "ttf") ?? .font,
            UTType(filenameExtension: "otf") ?? .font,
            UTType(filenameExtension: "ttc") ?? .font,
            UTType(filenameExtension: "woff") ?? .font,
            UTType(filenameExtension: "woff2") ?? .font,
        ]
        presentPicker(result, mode: .font, contentTypes: fontTypes)
    }

    /// Multi-select picker for "send files to computer": returns a list of
    /// {uri, name, size} for every picked file. NO copying happens - the
    /// upload server streams directly from these URLs when a PC downloads.
    private func presentFilesPicker(_ result: @escaping FlutterResult) {
        guard pickerCompletion == nil else {
            result(FlutterError(code: "busy", message: "A picker is already open", details: nil))
            return
        }
        guard let top = topViewController() else {
            result(FlutterError(code: "no_vc", message: "No view controller", details: nil))
            return
        }
        pickerCompletion = result
        pickerMode = .files
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = true
        picker.delegate = self
        top.present(picker, animated: true)
    }

    /// Multi-select folder picker for "send a whole folder to computer":
    /// opens the system picker limited to folders, then recursively walks the
    /// picked folder and returns every file inside as {uri, name, size}.
    /// NO copying happens - the upload server streams the URLs directly.
    private func presentFolderContentsPicker(_ result: @escaping FlutterResult) {
        guard pickerCompletion == nil else {
            result(FlutterError(code: "busy", message: "A picker is already open", details: nil))
            return
        }
        guard let top = topViewController() else {
            result(FlutterError(code: "no_vc", message: "No view controller", details: nil))
            return
        }
        pickerCompletion = result
        pickerMode = .folderContents
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        top.present(picker, animated: true)
    }

    /// Photos-app picker for "send photos to computer": opens PHPicker
    /// limited to images, copies every picked photo to a STABLE temp file
    /// (PHPicker's file-representation URLs are only valid inside its
    /// callback, and the upload server streams them later, when the PC
    /// downloads), and returns them as {uri, name, size} with names
    /// "Photos/<file>" so the receiving page groups them into a folder.
    private func presentPhotosPicker(_ result: @escaping FlutterResult) {
        guard photoPickerCompletion == nil else {
            result(FlutterError(code: "busy", message: "A picker is already open", details: nil))
            return
        }
        guard let top = topViewController() else {
            result(FlutterError(code: "no_vc", message: "No view controller", details: nil))
            return
        }
        // A new photo send replaces the previous batch, so the previous
        // batch's temp copies are no longer needed - drop them.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dp_photos", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        photoPickerCompletion = result
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 0 // unlimited
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        top.present(picker, animated: true)
    }

    /// Copies a picked font to `destPath` inside the app's own storage, so the
    /// subtitle renderers can read it without a live security scope (iCloud
    /// files may not be resident; the picked scope is released when the
    /// picker closes). Returns true on success.
    private func copyFontFile(uri: String, destPath: String) -> Bool {
        guard !uri.isEmpty, !destPath.isEmpty else { return false }
        guard let url = URL(string: uri) else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = URL(fileURLWithPath: destPath)
        do {
            try? FileManager.default.removeItem(at: dest)
            if let parent = dest.deletingLastPathComponent().path.isEmpty ? nil : dest.deletingLastPathComponent() {
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            let attrs = try FileManager.default.attributesOfItem(atPath: destPath)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            return size > 0
        } catch {
            SBMLog.log("copyFontFile failed: \(error.localizedDescription)")
            return false
        }
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
    /// AVAsset's `commonKeyArtwork` - never decodes video, so HDR content is
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
        // .commonKeyArtwork) - matched via rawValue so the lookup is stable
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
        case .font:
            // The copy into the app's own storage happens in `copyFontFile`;
            // here we just hand back the URL + display name.
            completion([
                "uri": url.absoluteString,
                "name": url.lastPathComponent,
            ])
        case .files:
            // Multi-select: return ALL picked URLs as {uri, name, size}.
            // Each URL gets its security scope started so the upload server
            // can stream it when a PC downloads.
            var out: [[String: Any]] = []
            for u in urls {
                _ = startAccess(u)
                let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                out.append([
                    "uri": u.absoluteString,
                    "name": u.lastPathComponent,
                    "size": size,
                ])
            }
            completion(out)
        case .folderContents:
            // Recursively walk the picked folder and return every file inside.
            // Names are "<PickedFolder>/<relative path>", so the receiving
            // page re-creates the folders in the destination folder it picked
            // (matching Android, whose tree walk prefixes the folder name the
            // same way).
            var out: [[String: Any]] = []
            let rootPath = url.path
            let folderName = url.lastPathComponent
            if let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles],
            ) {
                for case let fileURL as URL in enumerator {
                    let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if values?.isDirectory == true { continue }
                    _ = startAccess(fileURL)
                    // The typed properties are the only API left on
                    // URLResourceValues - the key subscript was removed.
                    let size = Int64(values?.fileSize ?? 0)
                    let rel = fileURL.path.hasPrefix(rootPath + "/")
                        ? String(fileURL.path.dropFirst(rootPath.count + 1))
                        : fileURL.lastPathComponent
                    out.append(["uri": fileURL.absoluteString,
                                "name": "\(folderName)/\(rel)",
                                "size": size])
                    if out.count >= 2000 { break }
                }
            }
            completion(out)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerCompletion?(nil)
        pickerCompletion = nil
    }
}

// MARK: - PHPickerViewControllerDelegate

extension FileBrowser: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let completion = photoPickerCompletion else { return }
        photoPickerCompletion = nil
        guard !results.isEmpty else { completion(nil); return }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dp_photos", isDirectory: true)
        let group = DispatchGroup()
        var out: [[String: Any]?] = Array(repeating: nil, count: results.count)

        for (i, r) in results.enumerated() {
            let provider = r.itemProvider
            // Prefer the original format (HEIC/JPEG/RAW as registered);
            // fall back to a JPEG export if the original cannot be loaded
            // as a file representation.
            let original = provider.registeredTypeIdentifiers.first
            let typeId = original ?? UTType.jpeg.identifier
            group.enter()
            func load(_ id: String, isRetry: Bool) {
                provider.loadFileRepresentation(forTypeIdentifier: id) { url, error in
                    if error != nil || url == nil, !isRetry {
                        group.leave()
                        load(UTType.jpeg.identifier, isRetry: true)
                        return
                    }
                    defer { group.leave() }
                    guard let url, error == nil else { return }
                    let suggested = provider.suggestedName ?? "photo_\(i + 1).jpg"
                    let safe = suggested.replacingOccurrences(of: "/", with: "_")
                    let dest = dir.appendingPathComponent("\(UUID().uuidString)_\(safe)")
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                        // "Photos/" prefix: the receiving page re-creates the
                        // folder, exactly like a picked folder's tree.
                        out[i] = ["uri": dest.absoluteString, "name": "Photos/\(safe)", "size": size]
                    } catch {
                        SBMLog.log("pickPhotos copy failed: \(error.localizedDescription)")
                    }
                }
            }
            load(typeId, isRetry: false)
        }

        group.notify(queue: .main) {
            let files = out.compactMap { $0 }
            SBMLog.log("pickPhotos: \(files.count) of \(results.count) copied")
            completion(files)
        }
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
                    // `x ?? NSNull()` does not typecheck: for a `String?` LHS
                    // the RHS must be `String` or `String?`, and NSNull is
                    // neither. `nullIfNil` widens to Any explicitly so the
                    // value crosses to Dart as null instead of crashing.
                    result([
                        "apiKey": nullIfNil(apiKey),
                        "pin": nullIfNil(pin),
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

    /// Widen an optional String to Any, mapping nil to NSNull so the Flutter
    /// standard codec maps it back to Dart `null`.
    private static func nullIfNil(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
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
