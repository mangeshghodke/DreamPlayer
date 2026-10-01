import Foundation
import SMBClient
// IOReader is declared by AetherEngine, not AetherEngineSMB. Importing only
// the SMB product leaves the protocol unresolved ("Cannot find type 'IOReader'").
import AetherEngine
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
    /// The libsmb2 handle every read goes through: one authenticated session,
    /// one tree connect, one open file, for the whole life of the video.
    ///
    /// libsmb2 is the only playback transport. An earlier version also opened an
    /// SMBClient session to the same file and kept it as a fallback, which meant
    /// two negotiates, two session setups, two tree connects and two file handles
    /// per play — with the SMBClient one never read from. Beyond the wasted
    /// latency that also occupies a server-side open-session slot and holds the
    /// credentials twice, and some NAS/Samba configurations cap those per user.
    let libsmb2File: LibSMB2File
    private let libsmb2Session: LibSMB2Session

    init(file: LibSMB2File, session: LibSMB2Session) {
        self.libsmb2File = file
        self.libsmb2Session = session
    }

    var byteSize: UInt64 { UInt64(max(0, libsmb2File.fileSize)) }

    /// A fresh reader over the live handle for `engine.load(source: .custom(...))`.
    func makeReader() -> IOReader {
        SMBSourceReader(file: libsmb2File)
    }

    func close() {
        // File before session: closing the session destroys the context the
        // handle lives in.
        libsmb2File.close()
        libsmb2Session.close()
    }
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

        guard let data = file.read(atOffset: cursor, length: UInt(size)) else {
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
