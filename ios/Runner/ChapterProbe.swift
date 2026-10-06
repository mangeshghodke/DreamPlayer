import Foundation
import AetherEngine
import AetherEngineSMB

/// Fetches container chapters for sources that are **not** local files.
///
/// Until now iOS only parsed chapters from a `FileHandle`, because both
/// chapter parsers took a local path. That made chapters a local-files-only
/// feature here while Android had them on every source — the same
/// "whichever engine/source you happened to use" trap that hit #40 on Android.
///
/// Android solves this by issuing its own ranged HTTP GETs. iOS already has
/// something better: every streaming source (WebDAV, FTP/SFTP, in-app SMB) is
/// handed to the engine as a reader that can fetch an arbitrary byte range, and
/// the auth, self-signed trust and connection reuse are already handled per
/// source. So this reads two windows through that reader instead of
/// re-implementing HTTP per transport.
///
/// ## Why head AND tail
///
/// Matroska keeps `Chapters` at the **end** of the segment and MP4 keeps `moov`
/// there too, so the original head-only read found chapters in exactly the
/// files that don't have them. Two 8 MiB windows match Android's
/// `HEAD_RANGE_BYTES` / `TAIL_RANGE_BYTES`.
enum ChapterProbe {
    /// 8 MiB, matching Android's window size.
    static let windowBytes = 8 * 1024 * 1024

    /// Extensions whose chapters live in Matroska.
    static let mkvExtensions: Set<String> = ["mkv", "mka", "mks", "webm", "mk3d"]
    /// Extensions whose chapters live in an MP4 `moov/udta/chpl` box.
    static let mp4Extensions: Set<String> = ["mp4", "mov", "m4v", "m4b", "3gp"]

    /// Wraps an engine cursor (`IOReader`) as a chapter reader.
    ///
    /// Needed for FTP/SFTP, which reach the engine as a `BufferedSMBReader`
    /// (a cursor with a read-ahead ring) rather than a `ByteRangeSource`. The
    /// caller must pass a reader it is NOT already streaming from — seeking the
    /// engine's live reader would drag playback's position along with it —
    /// which is what `makeIndependentReader()` exists for.
    ///
    /// Size comes from `AVSEEK_SIZE` (whence 65536): `BufferedSMBReader.fileSize`
    /// is private, and that seek is the only public door to it. It returns
    /// before moving the cursor, so querying it is free of side effects.
    static func cursorReader(_ source: IOReader) -> ChapterCursorReader {
        // `var` deliberately, not `let`. `ByteRangeSource` is provably
        // non-mutating (BufferedSMBReader holds `[ByteRangeSource]` in a `let`
        // and calls `read` on it), but nothing in the tree proves the same for
        // `IOReader` -- both are implemented only by final classes with a
        // `close()`, which is not conclusive. A `var` is correct either way; a
        // `let` fails the build only if the requirement turns out to be
        // `mutating`. Worst case here is one "never mutated" warning.
        var reader = source
        let size = reader.seek(offset: 0, whence: 65536)
        return ChapterCursorReader(
            total: size > 0 ? UInt64(size) : UInt64.max,
            seekTo: { offset in
                reader.seek(offset: Int64(offset), whence: Int32(SEEK_SET)) >= 0
            },
            readBytes: { count in
                guard count > 0 else { return nil }
                var buffer = [UInt8](repeating: 0, count: count)
                let read = buffer.withUnsafeMutableBytes { raw in
                    reader.read(
                        raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        size: Int32(count)
                    )
                }
                guard read > 0 else { return nil }
                return Array(buffer[0 ..< Int(read)])
            }
        )
    }

    /// Parses from a seekable byte-range source: WebDAV, FTP/SFTP, plain HTTP.
    ///
    /// Runs off the main actor by the caller. Two ranged reads, then the parse
    /// itself is synchronous over the in-memory windows.
    static func probe(byteSource: ByteRangeSource, ext: String) async -> [[String: Any]] {
        let ext = ext.lowercased()
        guard mkvExtensions.contains(ext) || mp4Extensions.contains(ext) else { return [] }
        let total = byteSource.byteSize
        guard total > 0 else { return [] }

        let totalU = UInt64(total)
        let headLen = Int(min(UInt64(windowBytes), totalU))
        let head: Data
        do {
            head = try await byteSource.read(at: 0, length: headLen)
        } catch {
            SBMLog.log("chapters: head read failed for .\(ext) (\(error.localizedDescription))")
            return []
        }
        guard !head.isEmpty else { return [] }

        // Whole file already in hand (or smaller than one window) — no tail.
        if UInt64(head.count) >= totalU {
            return parse(head: head, tail: nil, total: totalU, ext: ext)
        }

        var tail: Data?
        let tailStart = totalU > UInt64(windowBytes) ? totalU - UInt64(windowBytes) : 0
        let tailLen = Int(totalU - tailStart)
        if tailLen > 0, let data = try? await byteSource.read(at: Int64(tailStart), length: tailLen) {
            if !data.isEmpty { tail = data }
        } else {
            SBMLog.log("chapters: tail read failed for .\(ext) — parsing head only")
        }
        return parse(head: head, tail: tail, total: totalU, ext: ext)
    }

    /// Parses from a synchronous, *positional* cursor — in-app SMB, where
    /// `smb2_pread` means a seek lands exactly on the target offset. No gap to
    /// model and no tail to guess at, so this skips the window dance entirely.
    static func probe(cursor: ChapterSeekable, ext: String) -> [[String: Any]] {
        let ext = ext.lowercased()
        if mkvExtensions.contains(ext) { return MkvChapters.parseMaps(reader: cursor) }
        if mp4Extensions.contains(ext) { return Mp4Chapters.parseMaps(reader: cursor) }
        return []
    }

    /// Dispatches on container. Unknown extensions are skipped rather than
    /// guessed at — both walks start by validating their own magic, so a wrong
    /// guess costs a pointless 16 MiB of reads.
    static func parse(head: Data, tail: Data?, total: UInt64, ext: String) -> [[String: Any]] {
        let ext = ext.lowercased()
        if mkvExtensions.contains(ext) {
            return MkvChapters.parseMaps(head: head, tail: tail, totalSize: total)
        }
        if mp4Extensions.contains(ext) {
            return Mp4Chapters.parseMaps(head: head, tail: tail, totalSize: total)
        }
        return []
    }
}
