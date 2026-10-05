import Foundation

/// Minimal Matroska chapter reader (Swift port of `MkvChapters.kt`).
/// Media3 / AetherEngine don't surface MKV `Chapters`, so we parse the EBML
/// tree ourselves: SeekHead -> Chapters -> EditionEntry -> ChapterAtom.
///
/// Used for every MKV/WebM on iOS — local Documents and bookmarked Files-app
/// SMB shares (file:// via security-scoped bookmark). The provider mounts the
/// share at a local path, so a plain `FileHandle` read is sufficient.
enum MkvChapters {

    struct Chapter {
        let title: String
        let startMs: Int64
        let endMs: Int64?
    }

    // EBML IDs (same as Kotlin)
    private static let idEbmlHeader: UInt64 = 0x1A45DFA3
    private static let idSegment: UInt64 = 0x18538067
    private static let idSeekHead: UInt64 = 0x114D9B74
    private static let idSeek: UInt64 = 0x4DBB
    private static let idSeekId: UInt64 = 0x53AB
    private static let idSeekPosition: UInt64 = 0x53AC
    private static let idChapters: UInt64 = 0x1043A770
    private static let idEditionEntry: UInt64 = 0x45B9
    private static let idChapterAtom: UInt64 = 0xB6
    private static let idChapterTimeStart: UInt64 = 0x91
    private static let idChapterTimeEnd: UInt64 = 0x92
    private static let idChapterDisplay: UInt64 = 0x80
    private static let idChapString: UInt64 = 0x85

    private static let maxTopLevelChildren = 64
    private static let maxChapters = 999
    private static let maxHeaderBytes: Int64 = 1 << 20

    // MARK: - Public

    static func parse(path: String) -> [Chapter] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let r = ChapterFileReader(handle: fh)
        do {
            return try doParse(r)
        } catch {
            return []
        }
    }

    /// Convenience for the event map (`[[String:Any]]`).
    static func parseMaps(path: String) -> [[String: Any]] {
        toMaps(parse(path: path))
    }


    /// Remote probe: the head and (optionally) the tail of a file already held
    /// in memory by `ChapterProbe`. Both parsers expose the same entry point so
    /// the probe can dispatch on container without duplicating the walk.
    ///
    /// `tail` is nil when the whole file fit inside `head`, which is then just
    /// the old single-window behaviour.
    static func parseMaps(head: Data, tail: Data?, totalSize: UInt64) -> [[String: Any]] {
        toMaps((try? doParse(ChapterWindowReader(head: head, tail: tail, total: totalSize))) ?? [])
    }

    /// Parses from an already-built reader. Used for in-app SMB, where
    /// `smb2_pread` is positional: one seek lands exactly where the SeekHead
    /// points, so there is no gap to model and no tail to guess at.
    static func parseMaps(reader: ChapterSeekable) -> [[String: Any]] {
        toMaps((try? doParse(reader)) ?? [])
    }

    private static func toMaps(_ chapters: [Chapter]) -> [[String: Any]] {
        chapters.map { c in
            var m: [String: Any] = ["title": c.title, "startMs": c.startMs]
            if let e = c.endMs { m["endMs"] = e }
            return m
        }
    }

    // MARK: - Parser

    private static func doParse(_ r: ChapterSeekable) throws -> [Chapter] {
        guard try readId(r) == idEbmlHeader else { return [] }
        guard let headerSize = try readSize(r), headerSize >= 0, headerSize <= maxHeaderBytes else { return [] }
        try r.seek(to: r.position + UInt64(headerSize))
        guard try readId(r) == idSegment else { return [] }
        _ = try readSize(r) // segment size (may be unknown)
        let segmentDataStart = r.position

        var chaptersOffset: Int64 = -1
        var walked = 0
        while walked < maxTopLevelChildren {
            walked += 1
            guard let id = try readId(r) else { break }
            guard let size = try readSize(r) else { break }
            let dataStart = r.position
            if id == idSeekHead, size >= 0 {
                if let found = try findChaptersInSeekHead(r, endPos: dataStart + UInt64(size), segmentDataStart: segmentDataStart) {
                    chaptersOffset = found
                }
            } else if id == idChapters {
                chaptersOffset = Int64(r.position) - Int64(idBytes(id)) - Int64(sizeBytes(size))
            }
            if chaptersOffset >= 0 { break }
            if size < 0 { break }
            try r.seek(to: dataStart + UInt64(size))
        }
        if chaptersOffset < 0 { return [] }
        try r.seek(to: UInt64(chaptersOffset))
        guard try readId(r) == idChapters else { return [] }
        guard let chaptersSize = try readSize(r) else { return [] }
        let endPos: UInt64 = chaptersSize < 0 ? UInt64.max : r.position + UInt64(chaptersSize)
        var out: [Chapter] = []
        try parseContainer(r, endPos: endPos, out: &out, editions: true)
        finalizeEnds(&out)
        return out
    }

    private static func findChaptersInSeekHead(_ r: ChapterSeekable, endPos: UInt64, segmentDataStart: UInt64) throws -> Int64? {
        while r.position < endPos {
            guard let id = try readId(r) else { return nil }
            guard let size = try readSize(r) else { return nil }
            let dataStart = r.position
            if id == idSeek, size >= 0 {
                let seekEnd = dataStart + UInt64(size)
                var isChapters = false
                var position: Int64 = -1
                while r.position < seekEnd {
                    guard let sid = try readId(r) else { break }
                    guard let ssize = try readSize(r) else { break }
                    let sdata = r.position
                    if sid == idSeekId, (1...8).contains(ssize) {
                        let v = try readUInt(r, length: Int(ssize))
                        if v == idChapters { isChapters = true }
                    } else if sid == idSeekPosition, (1...8).contains(ssize) {
                        position = Int64(try readUInt(r, length: Int(ssize)))
                    }
                    if ssize < 0 { break }
                    try r.seek(to: sdata + UInt64(ssize))
                }
                if isChapters, position >= 0 { return Int64(segmentDataStart) + position }
            }
            if size < 0 { return nil }
            try r.seek(to: dataStart + UInt64(size))
        }
        return nil
    }

    private static func parseContainer(_ r: ChapterSeekable, endPos: UInt64, out: inout [Chapter], editions: Bool) throws {
        while r.position < endPos, out.count < maxChapters {
            guard let id = try readId(r) else { return }
            guard let size = try readSize(r) else { return }
            let dataStart = r.position
            if editions, id == idEditionEntry, size >= 0 {
                try parseContainer(r, endPos: dataStart + UInt64(size), out: &out, editions: false)
            } else if !editions, id == idChapterAtom, size >= 0 {
                try parseAtom(r, endPos: dataStart + UInt64(size), out: &out)
            }
            if size < 0 { return }
            try r.seek(to: dataStart + UInt64(size))
        }
    }

    private static func parseAtom(_ r: ChapterSeekable, endPos: UInt64, out: inout [Chapter]) throws {
        var startNs: Int64 = -1
        var endNs: Int64 = -1
        var title: String?
        while r.position < endPos {
            guard let id = try readId(r) else { return }
            guard let size = try readSize(r) else { return }
            let dataStart = r.position
            switch id {
            case idChapterTimeStart:
                if (1...8).contains(size) { startNs = Int64(try readUInt(r, length: Int(size))) }
            case idChapterTimeEnd:
                if (1...8).contains(size) { endNs = Int64(try readUInt(r, length: Int(size))) }
            case idChapterDisplay:
                if size >= 0, title == nil { title = try readDisplayTitle(r, endPos: dataStart + UInt64(size)) }
            case idChapterAtom:
                if size >= 0 { try parseAtom(r, endPos: dataStart + UInt64(size), out: &out) }
            default: break
            }
            if size < 0 { return }
            try r.seek(to: dataStart + UInt64(size))
        }
        if startNs >= 0 {
            let name = (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? title! : "Chapter \(out.count + 1)"
            out.append(Chapter(title: name, startMs: startNs / 1_000_000, endMs: endNs > startNs ? endNs / 1_000_000 : nil))
        }
    }

    private static func readDisplayTitle(_ r: ChapterSeekable, endPos: UInt64) throws -> String? {
        while r.position < endPos {
            guard let id = try readId(r) else { return nil }
            guard let size = try readSize(r) else { return nil }
            let dataStart = r.position
            if id == idChapString, (1...4096).contains(size) {
                let data = try r.readFully(int: Int(size))
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if size < 0 { return nil }
            try r.seek(to: dataStart + UInt64(size))
        }
        return nil
    }

    private static func finalizeEnds(_ out: inout [Chapter]) {
        out.sort { $0.startMs < $1.startMs }
        for i in out.indices {
            if out[i].endMs == nil, i + 1 < out.count {
                let c = out[i]
                out[i] = Chapter(title: c.title, startMs: c.startMs, endMs: out[i + 1].startMs)
            }
        }
    }

    // MARK: - EBML vint

    private static func readId(_ r: ChapterSeekable) throws -> UInt64? {
        let first = try r.readByte()
        if first < 0 { return nil }
        let len = countLength(first)
        if len > 4 { return nil }
        var v = UInt64(first & 0xFF)
        for _ in 1..<len {
            let b = try r.readByte()
            if b < 0 { throw NSError(domain: "MkvChapters", code: 2) }
            v = (v << 8) | UInt64(b & 0xFF)
        }
        return v
    }

    private static func readSize(_ r: ChapterSeekable) throws -> Int64? {
        let first = try r.readByte()
        if first < 0 { return nil }
        let len = countLength(first)
        if len > 8 { return nil }
        var v = UInt64(first & 0xFF) & ((1 << (8 - len)) - 1)
        for _ in 1..<len {
            let b = try r.readByte()
            if b < 0 { throw NSError(domain: "MkvChapters", code: 3) }
            v = (v << 8) | UInt64(b & 0xFF)
        }
        let unknown: UInt64 = (1 << (7 * len)) - 1
        return v == unknown ? -1 : Int64(v)
    }

    private static func readUInt(_ r: ChapterSeekable, length: Int) throws -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<length {
            let b = try r.readByte()
            if b < 0 { throw NSError(domain: "MkvChapters", code: 4) }
            v = (v << 8) | UInt64(b & 0xFF)
        }
        return v
    }

    private static func countLength(_ firstByte: Int) -> Int {
        var mask = 0x80
        var len = 1
        while len < 8, (firstByte & mask) == 0 { mask >>= 1; len += 1 }
        return len
    }

    private static func idBytes(_ id: UInt64) -> Int {
        var n = 1; var v = id
        while v > 0xFF { v >>= 8; n += 1 }
        return n
    }
    private static func sizeBytes(_ size: Int64) -> Int {
        if size < 0 { return 1 }
        var n = 1; var v = UInt64(size)
        while v > 0x7F { v >>= 8; n += 1 }
        return n
    }
}
