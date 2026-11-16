import Flutter
import Foundation

/// Clears the app's on-disk cache on demand (the `dreamplayer/cache` channel).
/// Deletes the contents of the app's Caches directory and tmp - subtitle temp
/// files and anything AetherEngine/FFmpeg dropped there. Both directories are
/// OS-purgeable, so deleting them is always safe. The in-memory image cache
/// (TMDB posters/backdrops/stills) lives in Flutter and is cleared from Dart
/// (`CacheCleaner.clearMemoryImages`).
enum CacheCleaner {

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "dreamplayer/cache",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "size":
                result(diskSizeBytes())
            case "clear":
                result(clearCacheBytes())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static var cacheDirectories: [URL] {
        var urls: [URL] = []
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            urls.append(caches)
        }
        urls.append(FileManager.default.temporaryDirectory)
        return urls
    }

    private static func diskSizeBytes() -> Int64 {
        var total: Int64 = 0
        for dir in cacheDirectories {
            if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
                for case let url as URL in enumerator {
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                          values.isDirectory != true,
                          let size = values.fileSize else { continue }
                    total += Int64(size)
                }
            }
        }
        return total
    }

    private static func clearCacheBytes() -> Int64 {
        var freed: Int64 = 0
        for dir in cacheDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDirectory {
                    continue
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    freed += Int64(size)
                }
            }
        }
        return freed
    }
}
