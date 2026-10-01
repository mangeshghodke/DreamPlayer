import Foundation
import AetherEngine
import AetherEngineSMB

/// Ring-buffer + multi-thread prefetch reader for SMB/WebDAV playback.
///
/// Ports the Android `SmbDataSource` design (parallel prefetch threads, each
/// with its own SMB handle / TCP connection) to iOS:
///
/// - **Ring buffer** (96 MiB) keeps data ahead of the read cursor.
/// - **Up to 4 prefetch tasks** read different regions of the file
///   simultaneously, one per underlying connection, then copy into the ring
///   under lock (with epoch check to prevent stale writes from killed/restarted
///   tasks). A single source therefore gets exactly one prefetch task.
/// - **Out-of-order completion** merges chunks that land ahead of the contiguous
///   write frontier; a failed read rewinds its chunk so it is retried rather
///   than leaving a permanent hole.
/// - `read()` blocks until data arrives (Android parity — no early -1 to the
///   demuxer); `seek()` within the ring is a cheap cursor move; outside
///   triggers a re-anchor.
///
/// Lifecycle: `cancel()` unblocks a pending read; `close()` stops prefetch
/// tasks and does NOT close the underlying sources (the source provider owns
/// their lifetime).
final class BufferedSMBReader: IOReader, @unchecked Sendable {

    // ---- Configuration ----
    private let sources: [ByteRangeSource]
    private let ownsSources: Bool
    private let discProbe: Bool
    private let ringCapacity: Int
    private let chunkSize: Int

    // ---- Ring buffer (guarded by ringLock) ----
    private let ringLock = NSCondition()
    private var ring: UnsafeMutableRawPointer?
    private var ringSize = 0
    private var bufStart: Int64 = 0
    private var valid: Int64 = 0
    private var bufEof = false
    private var fileSize: Int64 = 0
    private var position: Int64 = 0
    private var nextWritePos: Int64 = 0
    private var pendingChunks: [Int64: Int] = [:]
    private var ringEpoch: UInt64 = 0

    // ---- Prefetch ----
    private var prefetchTasks: [Task<Void, Never>] = []
    private var prefetchGen: UInt64 = 0

    // ---- Read cancellation ----
    private var cancelEpoch: UInt64 = 0
    private var closed = false
    private var lastServed = 0

    // MARK: - Init

    /// Single-source convenience init (backward compat / makeIndependentReader).
    convenience init(
        source: ByteRangeSource,
        ownsSource: Bool = false,
        discImageProbeEnabled: Bool = false,
        chunkSize: Int = 4 * 1024 * 1024,
        windowGoal: Int = 32 * 1024 * 1024
    ) {
        self.init(
            sources: [source],
            ownsSource: ownsSource,
            discImageProbeEnabled: discImageProbeEnabled,
            chunkSize: chunkSize,
            ringCapacity: max(8 * 1024 * 1024, min(96 * 1024 * 1024, windowGoal * 3))
        )
    }

    /// Multi-source init for parallel prefetch.  `sources[0]` is the primary;
    /// additional sources give prefetch tasks independent TCP connections.
    init(
        sources: [ByteRangeSource],
        ownsSource: Bool = false,
        discImageProbeEnabled: Bool = false,
        chunkSize: Int = 4 * 1024 * 1024,
        ringCapacity: Int = 96 * 1024 * 1024
    ) {
        self.sources = sources
        self.ownsSources = ownsSource
        self.discProbe = discImageProbeEnabled
        self.chunkSize = chunkSize
        self.ringCapacity = ringCapacity
        fileSize = sources.first?.byteSize ?? 0
        allocateRing()
        startPrefetchers()
    }

    var discImageProbeEnabled: Bool { discProbe }

    deinit {
        ringLock.lock()
        closed = true
        prefetchGen &+= 1
        ringLock.broadcast()
        let tasks = prefetchTasks
        prefetchTasks.removeAll()
        ringLock.unlock()
        for t in tasks { t.cancel() }
        if ownsSources { sources.forEach { $0.close() } }
        ring?.deallocate()
    }

    // MARK: - IOReader

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        let epoch = cancelEpoch
        ringLock.lock()

        // Wait for data if the ring is empty. Mirrors Android's SmbDataSource,
        // which blocks indefinitely — an early -1 would hard-abort the FFmpeg
        // probe mid-open on any slow/transient Wi-Fi. A 60 s hard-stall
        // deadline is kept purely as a backstop so a genuinely dead connection
        // surfaces as an error instead of hanging the reader forever.
        if availableLocked() == 0 && !bufEof && !closed {
            let deadline = Date().addingTimeInterval(60)
            while availableLocked() == 0 && !bufEof && !closed && cancelEpoch == epoch {
                if Date() >= deadline { break }
                ringLock.wait(until: deadline)
            }
        }

        let avail = availableLocked()
        guard avail > 0 else {
            ringLock.unlock()
            return bufEof ? 0 : -1
        }

        let toRead = min(Int(size), avail)
        let fromIdx = ringIdx(position)
        let first = min(toRead, ringSize - fromIdx)
        memcpy(buffer, ring!.advanced(by: fromIdx), first)
        if toRead > first {
            memcpy(buffer.advanced(by: first), ring!, toRead - first)
        }
        position += Int64(toRead)
        lastServed = toRead
        ringLock.broadcast()
        ringLock.unlock()
        return Int32(toRead)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        ringLock.lock()
        defer { ringLock.unlock() }
        let candidate: Int64
        switch whence {
        case Int32(SEEK_SET): candidate = offset
        case Int32(SEEK_CUR): candidate = position + offset
        case Int32(SEEK_END): candidate = fileSize + offset
        case 65536:           return fileSize   // AVSEEK_SIZE
        default:              return -1
        }
        guard candidate >= 0 else { return -1 }
        let end = bufStart + valid
        if candidate < bufStart || candidate > end {
            reanchorLocked(at: candidate)
        }
        position = candidate
        ringLock.broadcast()
        return position
    }

    func close() {
        ringLock.lock()
        closed = true
        prefetchGen &+= 1
        ringLock.broadcast()
        let tasks = prefetchTasks
        prefetchTasks.removeAll()
        ringLock.unlock()
        for t in tasks { t.cancel() }
    }

    func cancel() {
        ringLock.lock()
        cancelEpoch &+= 1
        ringLock.broadcast()
        ringLock.unlock()
    }

    func makeIndependentReader() -> IOReader? {
        BufferedSMBReader(
            source: sources[0],
            ownsSource: false,
            discImageProbeEnabled: discProbe,
            chunkSize: chunkSize
        )
    }

    // MARK: - Ring helpers (ringLock held)

    private func allocateRing() {
        let target = min(ringCapacity, max(8 * 1024 * 1024, Int(fileSize)))
        ring = UnsafeMutableRawPointer.allocate(byteCount: target, alignment: 16)
        ringSize = target
    }

    private func ringIdx(_ abs: Int64) -> Int {
        Int(abs % Int64(ringSize))
    }

    /// Contiguous valid bytes from `position`.
    private func availableLocked() -> Int {
        let end = bufStart + valid
        guard position >= bufStart, position < end else { return 0 }
        return Int(end - position)
    }

    /// Re-anchor ring to a new position (outside current window).
    /// Resets ring state and starts fresh prefetchers.
    /// Caller holds ringLock. Does NOT release it (avoids the race window
    /// where the ring is reset but no prefetchers are filling it).
    private func reanchorLocked(at newpos: Int64) {
        // Increment ring epoch so any in-flight writes from old prefetchers
        // are rejected when they try to copy into the ring.
        ringEpoch &+= 1
        // Reset ring to new position.
        position = newpos
        bufStart = position
        valid = 0
        bufEof = false
        nextWritePos = position
        pendingChunks.removeAll(keepingCapacity: true)
        // Cancel the previous generation explicitly. startPrefetchers only
        // bumps the counter, which a prefetcher notices at its next gen check
        // — but a prefetcher parked in ringLock.wait() would sit there until
        // something broadcast. With four sockets and a seek that lands outside
        // the window, the old tasks were still holding the connections while
        // the new ones queued behind them, so the reader's window never filled
        // and read() blocked out its 60s deadline.
        for task in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll(keepingCapacity: true)
        // Start fresh prefetchers. Old tasks exit on next gen check.
        startPrefetchers()
        ringLock.broadcast()
    }

    // MARK: - Prefetch management

    private static let PREFETCH_THREADS = 4

    /// Start prefetch tasks — at most one per underlying connection.  Caller
    /// MUST hold ringLock.
    ///
    /// Bumping `prefetchGen` first retires any still-running tasks from a
    /// previous spawn (they exit at their next generation check), so repeated
    /// calls from `read()`/`reanchorLocked()` never pile tasks up on the same
    /// connections — concurrent SMB reads on one connection corrupt the protocol.
    private func startPrefetchers() {
        prefetchGen &+= 1
        let gen = prefetchGen
        let count = min(Self.PREFETCH_THREADS, sources.count)
        for i in 0..<count {
            let src = sources[i]
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                await self.prefetchLoop(gen: gen, threadIdx: i, source: src)
            }
            prefetchTasks.append(task)
        }
    }

    private func prefetchLoop(gen: UInt64, threadIdx: Int, source: ByteRangeSource) async {
        let tmpBuf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { tmpBuf.deallocate() }

        while !Task.isCancelled {
            var readAt: Int64 = 0
            var readLen = 0
            var epoch: UInt64 = 0

            // ---- Acquire a chunk to read ----
            ringLock.lock()
            while true {
                if gen != prefetchGen || closed {
                    ringLock.unlock()
                    return
                }
                if bufEof { ringLock.wait(); continue }

                // Where the playhead sits relative to the buffered window.
                let delta = position - bufStart
                if delta < 0 || delta >= valid {
                    // Outside the window: a backward seek, or a forward jump
                    // past everything we hold (a seekbar drag). The ring has to
                    // be reset to the new position, NOT trimmed.
                    //
                    // Trimming here stalled every large seek: nextWritePos was
                    // already ahead of `position`, so `max` kept that larger
                    // value and the prefetcher kept filling the old region
                    // while the reader waited on the new one — forever. Small
                    // seeks only worked because nextWritePos was barely ahead.
                    bufStart = position
                    valid = 0
                    nextWritePos = position
                } else {
                    // Sequential consumption: drop the prefix we just read past.
                    bufStart = position
                    valid -= delta
                    nextWritePos = max(nextWritePos, bufStart + valid)
                }

                let room = Int64(ringSize) - (nextWritePos - bufStart)
                if room >= Int64(chunkSize) {
                    readAt = nextWritePos
                    readLen = min(chunkSize, Int(room))
                    // Don't wrap inside a single chunk read.
                    readLen = min(readLen, ringSize - ringIdx(readAt))
                    nextWritePos = readAt + Int64(readLen)
                    epoch = ringEpoch
                    break
                }
                ringLock.wait()
            }
            ringLock.unlock()

            // ---- SMB read (outside lock — parallel with other threads) ----
            var got = -2
            do {
                let data = try await source.read(at: readAt, length: readLen)
                got = data.count
                data.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        tmpBuf.copyMemory(from: base, byteCount: got)
                    }
                }
            } catch {
                got = -2
            }

            // ---- Copy into ring under lock ----
            if got > 0 {
                ringLock.lock()
                if epoch == ringEpoch && ring != nil {
                    var off = ringIdx(readAt)
                    var srcOff = 0
                    var remaining = got
                    while remaining > 0 {
                        let chunk = min(remaining, ringSize - off)
                        ring!.advanced(by: off).copyMemory(from: tmpBuf.advanced(by: srcOff), byteCount: chunk)
                        off = (off + chunk) % ringSize
                        srcOff += chunk
                        remaining -= chunk
                    }

                    // Advance valid contiguously.
                    if readAt == bufStart + valid {
                        valid += Int64(got)
                        // Merge pending out-of-order chunks.
                        while let first = pendingChunks.keys.min(),
                              first == bufStart + valid {
                            let entry = pendingChunks.removeValue(forKey: first)!
                            valid += Int64(entry)
                        }
                        if bufStart + valid >= fileSize { bufEof = true }
                    } else if readAt > bufStart + valid {
                        pendingChunks[readAt] = got
                    }
                }
                ringLock.broadcast()
                ringLock.unlock()
            } else if got == -1 || (got == 0 && readLen > 0) {
                ringLock.lock()
                if epoch == ringEpoch { bufEof = true }
                ringLock.broadcast()
                ringLock.unlock()
            } else {
                // Transient error: give the chunk back so it's retried. Without
                // the rewind, nextWritePos already advanced past this region and
                // the failed bytes would form a permanent hole the contiguous
                // frontier can never cross — the ring would never fill again.
                ringLock.lock()
                if epoch == ringEpoch {
                    nextWritePos = min(nextWritePos, readAt)
                }
                ringLock.broadcast()
                ringLock.unlock()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}
