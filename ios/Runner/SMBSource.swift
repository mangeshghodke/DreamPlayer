import Foundation
import SMBClient
import AetherEngineSMB

/// A live SMB playback session: one authenticated session, one tree connect and
/// one open file handle, held for the lifetime of the video.
///
/// This replaces the AetherEngineSMB `SMBConnection` + `BufferedSMBReader`
/// pair. The important property is that `FileReader` reads are *stateless*: every
/// `read(offset:length:)` issues a fresh ranged READ at that offset, with no
/// shared cursor. A source built over this session can therefore be created,
/// discarded and recreated at will — a reload after an audio-track switch just
/// makes a new source, and the engine's container probe reads real bytes again.
/// The old ring reader was one-shot (drained, cursor at EOF), which is exactly
/// what produced "custom source probe failed" on every reload.
final class SMBPlayback: @unchecked Sendable {
    let client: SMBClient
    let reader: FileReader
    let byteSize: UInt64

    /// The libsmb2 file handle, when one could be opened.
    ///
    /// Preferred over the SMBClient path for reads, because `smb2_pread` is
    /// synchronous and positional: it drops straight into the engine's
    /// synchronous `IOReader` with no bridging, and a re-probe only needs a fresh
    /// cursor. The SMBClient handle is kept as the fallback so a libsmb2 failure
    /// costs throughput, not playback.
    let libsmb2File: LibSMB2File?
    private let libsmb2Session: LibSMB2Session?

    init(client: SMBClient,
         reader: FileReader,
         byteSize: UInt64,
         libsmb2File: LibSMB2File? = nil,
         libsmb2Session: LibSMB2Session? = nil) {
        self.client = client
        self.reader = reader
        self.byteSize = byteSize
        self.libsmb2File = libsmb2File
        self.libsmb2Session = libsmb2Session
    }

    /// A fresh `ByteRangeSource` over the *same* live handle. No reconnect and no
    /// re-auth, which is what used to force a full handshake on every track
    /// switch.
    func makeSource() -> SMBByteRangeSource {
        SMBByteRangeSource(reader: reader, byteSize: byteSize)
    }

    /// What `engine.load(source: .custom(...))` actually wants: the engine's
    /// `IOReader` is a *synchronous, cursor-based* interface (`read`/`seek`),
    /// not the async, stateless `ByteRangeSource` underneath. `SMBIOReader` is
    /// the engine's own adapter between the two, so the transport stays ranged
    /// reads and no buffering layer is reintroduced.
    ///
    /// `ownsSource: false` — SMBBridge owns the session's lifetime via
    /// closeShare, and the engine must not close a handle it does not hold.
    func makeReader() -> IOReader {
        if let libsmb2File {
            return SMBSourceReader(file: libsmb2File)
        }
        return SMBIOReader(
            source: makeSource(),
            ownsSource: false,
            discImageProbeEnabled: false
        )
    }

    func close() {
        libsmb2File?.closeFile()
        libsmb2Session?.closeSession()
        Task.detached(priority: .utility) { [client, reader] in
            try? await reader.close()
            try? await client.logoff()
            client.session.disconnect()
        }
    }
}

/// `ByteRangeSource` over one open SMB file handle.
///
/// The engine only needs `read(at:length:)`, so that is all this provides. That
/// is also why the 414-line BufferedSMBReader ring buffer — with its window,
/// out-of-order frontier merge and parallel prefetch tasks — could go: reads are
/// independent ranged requests at explicit offsets, so there is no shared cursor
/// for a buffer to own.
///
/// **No lock here, deliberately.** The first cut guarded `read` with
/// `Semaphore(value: 1)` released from `defer { Task { await gate.signal() } }`,
/// and it deadlocked: the engine drives `IOReader` synchronously and blocks a
/// thread per read, so the detached signal Task could not get a cooperative-pool
/// slot to run in. On-device symptom was exact — a reload at 0.0s (head read
/// only) finished in 102 ms, while any read needing a *second* call hung until
/// the 9-15s timeout, which is why non-zero seeks, resumes, and the big MKVs
/// that must read Cues from the tail all failed.
///
/// A lock is also unnecessary. `SMBIOReader` is cursor-based, so the engine
/// issues one read at a time by contract — the parallel prefetch that once
/// needed the 4-socket scheme is gone. And `FileReader.fileProxy()`'s
/// check-then-set race cannot bite either, because `SMBPlayback` reads
/// `reader.fileSize` while opening, which creates the handle up front.
/// `FileReader.read` also loops internally to fill the requested length, so
/// read-ahead survives without any buffer of our own.
final class SMBByteRangeSource: ByteRangeSource, @unchecked Sendable {
    private let reader: FileReader
    /// Total file length. Named `totalSize` because the protocol's own
    /// requirement is `byteSize: Int64`.
    private let totalSize: UInt64

    init(reader: FileReader, byteSize: UInt64) {
        self.reader = reader
        self.totalSize = byteSize
    }

    /// Read counter plus the slowest read, for the device log. Cheap enough to
    /// leave on: it only formats a string when something looks wrong.
    private let stats = ReadStats()

    private final class ReadStats: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        private(set) var slowestMs = 0
        func record(ms: Int) {
            lock.lock(); defer { lock.unlock() }
            count += 1
            if ms > slowestMs { slowestMs = ms }
        }
    }

    /// The engine asks for the size before its first read, so this cannot be
    /// discovered lazily the way WebDAV's probe can.
    var byteSize: Int64 { Int64(clamping: totalSize) }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard length > 0, offset >= 0 else { return Data() }
        // Reading at or past EOF is normal, not an error: the engine's probe
        // asks for a fixed-size head even on short files.
        guard UInt64(offset) < totalSize else { return Data() }
        // Ask for exactly what was requested, clamped to EOF.
        let available = Int(min(UInt64(length), totalSize - UInt64(offset)))

        let began = Date()
        let data = try await reader.read(
            offset: UInt64(offset),
            length: UInt32(available)
        )
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        stats.record(ms: ms)
        // Only log reads slow enough to threaten playback, so the log stays
        // readable while still pinpointing a stall.
        if ms > 500 {
            SBMLog.log(
                "smb read: offset=\(offset) len=\(length) "
                + "got=\(data.count) in \(ms)ms (total \(stats.count) reads, "
                + "slowest \(stats.slowestMs)ms)")
        }
        return data
    }

    /// No-op on purpose: the session belongs to SMBBridge, which tears it down
    /// via closeShare once the browser and the player have both let go.
    func close() {}
}

/// The engine's reader interface, served straight from libsmb2.
///
/// `IOReader` is *synchronous* and cursor-based (`read`/`seek` into a raw
/// pointer), and `smb2_pread` is synchronous and positional. That match is the
/// whole point of phase 2: no bridging, no `Task`, no semaphore, so the deadlock
/// class that cost four builds on the SMBClient path cannot occur here at all.
/// The previous `SMBByteRangeSource` had to bridge an *async* source into this
/// synchronous interface, and the release half of that bridge is what hung.
///
/// One lock, shared with every reader derived from the same handle, because
/// libsmb2's context keeps its message-id counter and credit accounting in plain
/// struct fields with no internal locking. Holding it across a blocking `pread`
/// is fine — the thread is doing real work, not waiting on the cooperative pool.
final class SMBSourceReader: IOReader, @unchecked Sendable {
    /// Shared with derived readers so the context is never entered twice.
    private let lock: NSRecursiveLock
    private let file: LibSMB2File
    private var cursor: Int64 = 0
    private var closed = false

    init(file: LibSMB2File, lock: NSRecursiveLock = NSRecursiveLock()) {
        self.file = file
        self.lock = lock
    }

    var fileSize: Int64 { file.fileSize }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return -1 }

        guard let data = file.read(atOffset: cursor, length: Int(size)) else {
            return -1
        }
        if data.isEmpty {
            return 0  // clean EOF; the engine treats 0 as end of stream
        }
        let count = min(data.count, Int(size))
        data.copyBytes(to: buffer, count: count)
        cursor += Int64(count)
        return Int32(count)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        switch whence {
        case Int32(SEEK_SET): cursor = offset
        case Int32(SEEK_CUR): cursor += offset
        case Int32(SEEK_END): cursor = file.fileSize + offset
        case 65536: return file.fileSize  // AVSEEK_SIZE
        default: return -1
        }
        if cursor < 0 {
            cursor = 0
            return -1
        }
        return cursor
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    /// No-op, deliberately. The engine calls this to abandon a reader, but a
    /// synchronous `smb2_pread` is a blocking round-trip that cannot be
    /// interrupted; poisoning the reader here would break the engine's own
    /// reuse of it. Teardown is `close()`, and the session is torn down by
    /// SMBBridge once nothing is streaming.
    func cancel() {}

    /// A second reader over the *same* open handle, with its own cursor.
    ///
    /// This is what the engine uses when it re-probes the container, and it is
    /// why the old ring reader failed here: it had drained its buffer and left
    /// its cursor at EOF, so a reload handed the engine a source that read
    /// nothing ("custom source probe failed"). `pread` is positional, so a fresh
    /// cursor is all a re-probe needs.
    func makeIndependentReader() -> IOReader? {
        SMBSourceReader(file: file, lock: lock)
    }
}
