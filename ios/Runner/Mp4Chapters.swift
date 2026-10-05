import Foundation

/// Nero `moov/udta/chpl` chapter reader (Swift port of `Mp4Chapters.kt`).
/// Media3 / AetherEngine don't surface the Nero `chpl` atom, so we parse the
/// ISO BMFF box tree ourselves: top-level `moov` → `udta` → `chpl`.
///
/// HandBrake writes `chpl` as: version(1) + flags(3) + [4 bytes if version!=0]
/// + count(1 byte, FFmpeg semantics) + entries{ start(8 BE, 100ns) + titleLen(1)
/// + title }. Start is converted to milliseconds (/10000) to match
/// `MkvChapters.Chapter`. A 4-byte and 8-byte count fallback is tried when the
/// 1-byte path yields nothing (handles non-conformant muxers).
enum Mp4Chapters {

    struct Chapter {
        let title: String
        let startMs: Int64
        let endMs: Int64?
    }

    private static let maxChapters = 999

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
        let fileSize = r.length
        guard let moov = try findBox(r, target: "moov", start: 0, end: fileSize) else { return [] }
        let udta = try findBox(r, target: "udta", start: moov.0, end: moov.1)
        let chpl: (UInt64, UInt64)?
        if let udta {
            chpl = try findBox(r, target: "chpl", start: udta.0, end: udta.1)
                ?? findBox(r, target: "chpl", start: moov.0, end: moov.1)
        } else {
            chpl = try findBox(r, target: "chpl", start: moov.0, end: moov.1)
        }
        guard let chplRange = chpl else { return [] }
        var out = try parseChpl(r, start: chplRange.0, end: chplRange.1)
        finalizeEnds(&out)
        return out
    }

    private static func findBox(_ r: ChapterSeekable, target: String, start: UInt64, end: UInt64) throws -> (UInt64, UInt64)? {
        let targetBytes = Array(target.utf8)
        guard targetBytes.count == 4 else { return nil }
        var pos = start
        while pos + 8 <= end {
            try r.seek(to: pos)
            let sizeData = try r.readFully(int: 4)
            let typeData = try r.readFully(int: 4)
            var boxSize = (UInt64(sizeData[0]) << 24) | (UInt64(sizeData[1]) << 16) | (UInt64(sizeData[2]) << 8) | UInt64(sizeData[3])
            var headerSize: UInt64 = 8
            if boxSize == 1 {
                if pos + 16 > end { break }
                let large = try r.readFully(int: 8)
                var v: UInt64 = 0
                for b in large { v = (v << 8) | UInt64(b) }
                boxSize = v
                headerSize = 16
            } else if boxSize == 0 {
                boxSize = end - pos
            }
            if boxSize < headerSize { break }
            let payloadStart = pos + headerSize
            let payloadEnd = pos + boxSize
            if payloadEnd > end || payloadEnd < payloadStart { break }
            if typeData[0] == targetBytes[0] && typeData[1] == targetBytes[1] &&
                typeData[2] == targetBytes[2] && typeData[3] == targetBytes[3] {
                return (payloadStart, payloadEnd)
            }
            pos = payloadEnd
            if pos <= start { break }
        }
        return nil
    }

    private static func parseChpl(_ r: ChapterSeekable, start: UInt64, end: UInt64) throws -> [Chapter] {
        let payloadSize = Int64(end) - Int64(start)
        if payloadSize < 5 { return [] }
        try r.seek(to: start)
        let version = try r.readByte()
        if version < 0 { return [] }
        // flags 3 bytes
        _ = try r.readByte(); _ = try r.readByte(); _ = try r.readByte()
        var headerConsumed: Int64 = 4
        if version != 0 {
            if payloadSize < headerConsumed + 4 + 1 { return [] }
            _ = try r.readByte(); _ = try r.readByte(); _ = try r.readByte(); _ = try r.readByte()
            headerConsumed += 4
        }
        if payloadSize < headerConsumed + 1 { return [] }
        let firstCountByte = try r.readByte()
        if firstCountByte < 0 { return [] }
        headerConsumed += 1
        let count1 = firstCountByte
        var best: [Chapter]? = nil
        if (1...maxChapters).contains(count1) {
            if let parsed = try tryParseEntries(r, count: count1, boxEnd: end) , !parsed.isEmpty {
                best = parsed
            }
        }
        // Fallback: 32-bit count where firstCountByte is high byte
        if (best == nil || best!.isEmpty), payloadSize >= headerConsumed - 1 + 4 {
            try r.seek(to: start + UInt64(headerConsumed - 1))
            let b4 = try r.readFully(int: 4)
            let count32 = (UInt64(b4[0]) << 24) | (UInt64(b4[1]) << 16) | (UInt64(b4[2]) << 8) | UInt64(b4[3])
            if (1...UInt64(maxChapters)).contains(count32) {
                if let parsed = try tryParseEntries(r, count: Int(count32), boxEnd: end), !parsed.isEmpty {
                    best = parsed
                }
            }
        }
        // Fallback: 64-bit count
        if (best == nil || best!.isEmpty), payloadSize >= headerConsumed - 1 + 8 {
            try r.seek(to: start + UInt64(headerConsumed - 1))
            let b8 = try r.readFully(int: 8)
            var v: UInt64 = 0
            for b in b8 { v = (v << 8) | UInt64(b) }
            if (1...UInt64(maxChapters)).contains(v) {
                if let parsed = try tryParseEntries(r, count: Int(v), boxEnd: end), !parsed.isEmpty {
                    best = parsed
                }
            }
        }
        return best ?? []
    }

    private static func tryParseEntries(_ r: ChapterSeekable, count: Int, boxEnd: UInt64) throws -> [Chapter]? {
        if count <= 0 || count > maxChapters { return nil }
        var out: [Chapter] = []
        for i in 0..<count {
            if r.position + 9 > boxEnd { return nil }
            let startData = try r.readFully(int: 8)
            var start100ns: UInt64 = 0
            for b in startData { start100ns = (start100ns << 8) | UInt64(b) }
            let titleLen = try r.readByte()
            if titleLen < 0 { return nil }
            if r.position + UInt64(titleLen) > boxEnd { return nil }
            var title = "Chapter \(i + 1)"
            if titleLen > 0 {
                let titleData = try r.readFully(int: titleLen)
                let raw = String(data: titleData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !raw.isEmpty { title = raw }
            }
            let startMs = Int64(start100ns / 10000)
            out.append(Chapter(title: title, startMs: startMs, endMs: nil))
            if out.count > maxChapters { break }
        }
        return out
    }

    private static func finalizeEnds(_ out: inout [Chapter]) {
        out.sort { $0.startMs < $1.startMs }
        for i in out.indices {
            if out[i].endMs == nil, i + 1 < out.count {
                let c = out[i]
                out[i] = Chapter(title: c.title, startMs: c.startMs, endMs: out[i+1].startMs)
            }
        }
    }
}
