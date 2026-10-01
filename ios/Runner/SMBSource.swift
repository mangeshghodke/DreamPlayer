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

    init(client: SMBClient, reader: FileReader, byteSize: UInt64) {
        self.client = client
        self.reader = reader
        self.byteSize = byteSize
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
    func makeReader() -> SMBIOReader {
        SMBIOReader(
            source: makeSource(),
            ownsSource: false,
            discImageProbeEnabled: false
        )
    }

    func close() {
        Task.detached(priority: .utility) { [client, reader] in
            try? await reader.close()
            try? await client.logoff()
            client.session.disconnect()
        }
    }
}

/// `ByteRangeSource` over one open SMB file handle.
///
/// The engine only needs `read(at:length:)`, so that is all this provides — the
/// same shape libDSM exposed (`smb_fseek` + `smb_fread`), and the reason the 414
/// line ring buffer with its window, frontier merge and parallel prefetch tasks
/// could go.
///
/// Reads are serialised with a gate. `SMBClient.Session` is a plain class with
/// no lock of its own, and its message-id counter is an unsynchronised `var`, so
/// two overlapping reads could otherwise duplicate a message id. Serialising
/// also removes the check-then-set race in `FileReader.fileProxy()`, which would
/// otherwise open (and leak) a second handle on the first concurrent read.
/// Reads are already sequential in practice — the demuxer probes a container by
/// walking it — so this costs nothing, and `FileReader.read` already issues
/// back-to-back READs to fill the requested length, which is the read-ahead the
/// ring buffer used to provide.
final class SMBByteRangeSource: ByteRangeSource, @unchecked Sendable {
    private let reader: FileReader
    private let byteSize: UInt64
    private let gate = Semaphore(value: 1)

    init(reader: FileReader, byteSize: UInt64) {
        self.reader = reader
        self.byteSize = byteSize
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard length > 0, offset >= 0 else { return Data() }
        // Reading at or past EOF is normal, not an error: the engine's probe
        // asks for a fixed-size head even on short files.
        guard UInt64(offset) < byteSize else { return Data() }
        let available = Int(min(UInt64(length), byteSize - UInt64(offset)))

        await gate.wait()
        defer { Task { await gate.signal() } }
        return try await reader.read(
            offset: UInt64(offset),
            length: UInt32(available)
        )
    }
}
