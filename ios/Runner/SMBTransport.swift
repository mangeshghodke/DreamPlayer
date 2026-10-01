//
//  SMBTransport.swift
//  DreamPlayer
//
//  Chooses the SMB implementation and hides the difference from SMBBridge.
//
//  Two backends exist during the migration:
//   * libDSM — the current one. Owns its buffering and seeking, so the
//     hand-written read-ahead that produced every earlier bug is gone.
//   * SMBClient (pure Swift over NWConnection) — still linked so playback keeps
//     working until libDSM playback lands. Removed once it does.
//
//  Everything below is blocking C, so nothing here may be called on the main
//  actor; SMBBridge runs all of it on its own queue.
//

import Foundation

/// One backend, as SMBBridge sees it: connect, list, size, read ranges.
protocol SMBBackend: AnyObject {
    /// Lists one directory. `path` is share-relative with forward slashes.
    func listDirectory(path: String) throws -> [SMBEntry]
    /// Size of a file in bytes, 0 when unavailable.
    func fileSize(path: String) -> Int64
    /// Reads up to `length` bytes at an absolute `offset`. Short read = EOF.
    func read(offset: Int64, length: Int) throws -> Data
    /// Opens the file so later reads need no reopen.
    func prepare(path: String) throws
    func close()
}

/// Mirrors the Dart `SmbEntry` shape.
struct SMBEntry {
    let name: String
    /// Path relative to the share, forward slashes.
    let relativePath: String
    let isDirectory: Bool
    let size: UInt64
    let modifiedMillis: Int64
}

/// Errors surfaced to Dart, which renders `message` verbatim.
/// Unwraps an `NSError` out-parameter into a message Dart can show, falling
/// back when the callee returned nil without saying why.
enum LibDSM {
    // Takes `any Error` rather than NSError, because a Swift `catch` binds the
    // thrown error as `Error`; only at runtime is it the bridged NSError.
    static func message(_ error: Error?, _ fallback: String) -> String {
        guard let error else { return fallback }
        let text = (error as NSError).localizedDescription
        return text.isEmpty ? fallback : text
    }
}

enum SMBError: LocalizedError {
    case connect(String)
    case auth(String)
    case listing(String)
    case read(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .connect(let m), .auth(let m), .listing(let m), .read(let m):
            return m
        case .unavailable:
            return "No SMB backend is available"
        }
    }
}

enum SMBTransport {

    /// Which backend playback uses.
    ///
    /// `.libDSM` once its read path is wired; `.legacy` until then, so a
    /// libDSM problem cannot also break playback.
    static var playbackBackend: PlaybackChoice = .legacy

    enum PlaybackChoice {
        case libDSM
        case legacy
    }

    // MARK: - libDSM

    /// Opens a libDSM session for browsing. One session per listing keeps the
    /// C pointers short-lived: `smb_session_destroy` invalidates every tree and
    /// file id taken from it, so a session is never shared across queues.
    static func libDSMSession(
        host: String,
        port: UInt16,
        share: String,
        user: String?,
        password: String?,
        domain: String?
    ) throws -> LibDSMSession {
        // NSError** on a nullable-returning method imports as `throws` — but
        // only while the return stays nullable, since nil is how the ObjC side
        // signals failure. Marking it nonnull silently disables the convention.
        let session: LibDSMSession
        do {
            session = try LibDSMSession(
                host: host,
                port: port,
                hostname: nil,
                share: share,
                user: user,
                password: password,
                domain: domain
            )
        } catch {
            throw SMBError.connect(
                LibDSM.message(error, "Could not connect to the SMB server"))
        }
        SBMLog.log(
            "libDSM session ok \(host):\(port) share=\\(share) "
            + "guest=\\(session.loggedInAsGuest)")
        return session
    }

    /// Lists a directory through libDSM.
    static func libDSMList(session: LibDSMSession, path: String) throws -> [SMBEntry] {
        let entries: [LibDSMEntry]
        do {
            entries = try session.listDirectory(path)
        } catch {
            throw SMBError.listing(
                LibDSM.message(error, "Could not read that folder"))
        }
        return entries.map {
            SMBEntry(
                name: $0.name,
                relativePath: $0.relativePath,
                isDirectory: $0.isDirectory,
                size: $0.size,
                modifiedMillis: $0.modifiedMillis
            )
        }
    }

    /// Enumerates shares. Needs a session, but tree-connect is deferred: the
    /// share is not known until this returns.
    static func libDSMListShares(
        host: String,
        port: UInt16,
        user: String?,
        password: String?,
        domain: String?
    ) throws -> [String] {
        do {
            return try LibDSMSession.listShares(
                onHost: host, port: port, user: user,
                password: password, domain: domain
            )
        } catch {
            throw SMBError.connect(
                LibDSM.message(error, "Could not list shares"))
        }
    }

    /// Reachability probe, used for the online/offline dot.
    static func libDSMCanReach(host: String, port: UInt16) -> Bool {
        LibDSMSession.canReachHost(host, port: port)
    }
}
