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
/// `SMBSourceReader`, and FTP/SFTP's `BufferedSMBReader`.
///
/// Used instead of head+tail windows because those cursors seek natively:
/// one seek lands exactly where the SeekHead points, so there is no gap to
/// model and no need to guess where the tail is.
///
/// ## Why this buffers (this is the whole difference between working and not)
///
/// The container walks are byte-at-a-time: `readId`, `readSize` and `readUInt`
/// each pull a **single** byte through `readByte()`. Neither underlying cursor
/// buffers for us — `SMBSourceReader.read` is a bare `smb2_pread` per call — so
/// an unbuffered adapter turns a 40-chapter file into *thousands* of single-byte
/// SMB round trips. On a LAN that is minutes of background work, which is exactly
/// how the first build shipped a feature that looked like it did nothing at all.
///
/// A 64 KiB window collapses that to a handful of reads: fill near the Segment
/// header, let the walk consume it, seek to the Chapters offset, fill again.
/// Seeks *within* the window are free, which is why [seek] deliberately does not
/// invalidate the buffer — `buffered(_:)` re-fills only when the target falls
/// outside what is already held.
final class ChapterCursorReader: ChapterSeekable {
    private let seekTo: (UInt64) -> Bool
    private let readBytes: (Int) -> [UInt8]?
    private let total: UInt64
    private var pos: UInt64 = 0

    /// Large enough to hold every chapter title block in one fetch, small
    /// enough that a seek never drags megabytes over the wire.
    private static let windowBytes = 64 * 1024

    private var buffer: [UInt8] = []
    private var bufferStart: UInt64 = 0

    init(total: UInt64, seekTo: @escaping (UInt64) -> Bool, readBytes: @escaping (Int) -> [UInt8]?) {
        self.total = total
        self.seekTo = seekTo
        self.readBytes = readBytes
    }

    /// True when [count] bytes at [pos] are already in hand, filling the window
    /// if not. Returns false when the read cannot be satisfied from a window.
    private func buffered(_ count: Int) -> Bool {
        let held = bufferStart + UInt64(buffer.count)
        if pos >= bufferStart, pos + UInt64(count) <= held {
            return true
        }
        // A request wider than the window goes straight to the cursor instead of
        // evicting what we already hold — `readFully` handles that path.
        guard count <= ChapterCursorReader.windowBytes, seekTo(pos) else {
            return false
        }
        guard let bytes = readBytes(ChapterCursorReader.windowBytes), !bytes.isEmpty else {
            buffer.removeAll(keepingCapacity: true)
            bufferStart = pos
            return false
        }
        buffer = bytes
        bufferStart = pos
        return UInt64(buffer.count) >= UInt64(count)
    }

    func readByte() throws -> Int {
        guard buffered(1) else { return -1 }
        let offset = Int(pos - bufferStart)
        pos += 1
        return Int(buffer[offset])
    }

    func readFully(int count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        if buffered(count) {
            let offset = Int(pos - bufferStart)
            pos += UInt64(count)
            return Data(buffer[offset ..< offset + count])
        }
        // Wider than the window: bypass it rather than thrash.
        guard seekTo(pos) else {
            throw NSError(domain: "ChapterReader", code: 4)
        }
        guard let bytes = readBytes(count), bytes.count >= count else {
            throw NSError(domain: "ChapterReader", code: 5)
        }
        pos += UInt64(count)
        return Data(bytes)
    }

    /// Positions the cursor. Deliberately does NOT drop the buffer: a seek back
    /// inside the held window costs nothing, and the next read re-fills only if
    /// the target is genuinely outside it.
    func seek(to newPos: UInt64) throws {
        pos = min(newPos, total)
    }

    var position: UInt64 { pos }
    var length: UInt64 { total }
}
