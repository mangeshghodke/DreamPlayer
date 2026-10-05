import Foundation

/// The synchronous, positional reader the container chapter parsers walk.
///
/// This used to be declared **twice**, as a `private protocol SeekableReader`
/// with its own `FileReader`, inside `MkvChapters.swift` and
/// `Mp4Chapters.swift`. The two copies had already drifted — MP4's carried an
/// extra `length` member that MKV's lacked — so unifying them here is what lets
/// one reader serve every source on every platform the way Android's does.
///
/// Engine-free on purpose: `IOReader` (AetherEngine) and `ByteRangeSource`
/// (AetherEngineSMB) are wrapped by closures in `ChapterCursorReader`, so this
/// file needs no framework import and the parsers stay framework-free too.
protocol ChapterSeekable {
    func readByte() throws -> Int
    func readFully(int count: Int) throws -> Data
    func seek(to pos: UInt64) throws
    var position: UInt64 { get }
    var length: UInt64 { get }
}

/// Local file, or a Files-app share the provider has mounted at a path.
final class ChapterFileReader: ChapterSeekable {
    private let handle: FileHandle
    private var pos: UInt64 = 0
    private let fileLength: UInt64

    init(handle: FileHandle) {
        self.handle = handle
        var len: UInt64 = UInt64.max
        do {
            let cur = try handle.offset()
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: cur)
            len = end
        } catch {
            len = UInt64.max
        }
        fileLength = len
    }

    func readByte() throws -> Int {
        let data = try handle.read(upToCount: 1) ?? Data()
        if data.isEmpty { return -1 }
        pos += 1
        return Int(data[0])
    }

    func readFully(int count: Int) throws -> Data {
        let data = try handle.read(upToCount: count) ?? Data()
        if data.count < count { throw NSError(domain: "ChapterReader", code: 1) }
        pos += UInt64(count)
        return data
    }

    func seek(to newPos: UInt64) throws {
        try handle.seek(toOffset: newPos)
        pos = newPos
    }

    var position: UInt64 { pos }
    var length: UInt64 { fileLength }
}

/// One contiguous `[start, start + bytes.count)` window of a remote file.
struct ChapterWindow {
    let start: UInt64
    let bytes: [UInt8]

    var end: UInt64 { start + UInt64(bytes.count) }

    func contains(_ pos: UInt64) -> Bool {
        pos >= start && pos < end
    }
}

/// The head AND the tail of a remote file, with the middle missing.
///
/// Matroska keeps `Chapters` at the **end** of the segment and MP4 keeps `moov`
/// there too, so the original head-only read (`Range: bytes=0-8M`) found chapters
/// in exactly the files that don't have them. That is why chapters worked for
/// local files and never for SMB / WebDAV / Jellyfin / UPnP.
///
/// The container walks never touch the gap: the EBML walk starts at the Segment
/// header, reads the SeekHead, then seeks *straight* to the Chapters element;
/// the MP4 box walk does the same with `moov`. A read that lands in the gap
/// throws EOF, which the parsers already treat as "no chapters here".
final class ChapterWindowReader: ChapterSeekable {
    private let windows: [ChapterWindow]
    private let total: UInt64
    private var pos: UInt64 = 0

    init(windows: [ChapterWindow], total: UInt64) {
        self.windows = windows
        self.total = total
    }

    /// Convenience for the head/tail shape the probe produces.
    convenience init(head: Data, tail: Data?, total: UInt64) {
        var windows: [ChapterWindow] = [
            ChapterWindow(start: 0, bytes: [UInt8](head))
        ]
        if let tail, !tail.isEmpty, total > UInt64(head.count) {
            let start = total - UInt64(tail.count)
            if start > UInt64(head.count) {
                windows.append(ChapterWindow(start: start, bytes: [UInt8](tail)))
            }
        }
        self.init(windows: windows, total: total)
    }

    private func locate(_ p: UInt64) -> (ChapterWindow, Int)? {
        for window in windows where window.contains(p) {
            return (window, Int(p - window.start))
        }
        return nil
    }

    func readByte() throws -> Int {
        guard let hit = locate(pos) else { return -1 }
        pos += 1
        return Int(hit.0.bytes[hit.1])
    }

    func readFully(int count: Int) throws -> Data {
        guard let hit = locate(pos) else {
            throw NSError(domain: "ChapterReader", code: 2)
        }
        let (window, offset) = hit
        guard offset + count <= window.bytes.count else {
            // Ran off the end of this window — into the gap, or past EOF.
            throw NSError(domain: "ChapterReader", code: 3)
        }
        pos += UInt64(count)
        return Data(window.bytes[offset ..< offset + count])
    }

    func seek(to newPos: UInt64) throws {
        pos = min(newPos, total)
    }

    var position: UInt64 { pos }
    var length: UInt64 { total }
}

/// Wraps a **synchronous cursor** that already exists — in-app SMB's
/// `SMBSourceReader`, which is an `IOReader` over `smb2_pread`.
///
/// Used instead of head+tail windows because `pread` is positional: one seek
/// lands exactly where the SeekHead points, so there is no gap to model and no
/// need to guess where the tail is.
final class ChapterCursorReader: ChapterSeekable {
    private let seekTo: (UInt64) -> Bool
    private let readBytes: (Int) -> [UInt8]?
    private let total: UInt64
    private var pos: UInt64 = 0

    init(total: UInt64, seekTo: @escaping (UInt64) -> Bool, readBytes: @escaping (Int) -> [UInt8]?) {
        self.total = total
        self.seekTo = seekTo
        self.readBytes = readBytes
    }

    func readByte() throws -> Int {
        guard let byte = readBytes(1)?.first else { return -1 }
        pos += 1
        return Int(byte)
    }

    func readFully(int count: Int) throws -> Data {
        guard let bytes = readBytes(count), bytes.count >= count else {
            throw NSError(domain: "ChapterReader", code: 4)
        }
        pos += UInt64(count)
        return Data(bytes)
    }

    func seek(to newPos: UInt64) throws {
        guard seekTo(newPos) else {
            throw NSError(domain: "ChapterReader", code: 5)
        }
        pos = newPos
    }

    var position: UInt64 { pos }
    var length: UInt64 { total }
}
