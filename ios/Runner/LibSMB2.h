#import <Foundation/Foundation.h>

// Opaque libsmb2 handle; the real type comes from <smb2/smb2.h> in the .m.
struct smb2_context;

NS_ASSUME_NONNULL_BEGIN

/// One SMB server identified on the LAN.
@interface LibSMB2Server : NSObject
@property(nonatomic, copy) NSString *host;
@property(nonatomic, assign) uint16_t port;
/// Negotiated dialect, e.g. 0x0311 for SMB 3.1.1. 0 when the probe did not get
/// far enough to negotiate.
@property(nonatomic, assign) uint16_t dialect;
/// Server GUID from the negotiate response — a stable identity for the host,
/// unlike an IP that can change.
@property(nonatomic, copy, nullable) NSString *serverGuid;
/// `SMB 3.1.1`, `SMB 2.1`, … for display. Empty when unknown.
@property(nonatomic, copy) NSString *dialectLabel;
/// Why the probe failed, for the log. Empty on success.
@property(nonatomic, copy) NSString *failure;
@property(nonatomic, assign) BOOL reachable;
@end

/// Thin wrapper over libsmb2 (https://github.com/sahlberg/libsmb2), LGPL 2.1.
///
/// Phase 1 is server identification only. The distinction that matters: a bare
/// TCP connect to 445 proves something is listening, not that it is SMB. This
/// completes a real SMB negotiate against IPC$ — the share every Windows and
/// Samba server exposes and which normally permits anonymous access — and then
/// reports back the negotiated dialect and the server's GUID.
/// One open SMB file, read by explicit offset.
///
/// `smb2_pread` is positional: it takes the offset as an argument and keeps no
/// cursor. That is the property the whole playback design rests on — a source
/// built over this can be thrown away and rebuilt at any moment, and the
/// engine's container probe then reads real bytes instead of nothing. The
/// previous ring-buffer reader was one-shot (drained, cursor at EOF by the time a
/// reload happened), which is what produced "custom source probe failed" on every
/// audio-track switch and resume.
@interface LibSMB2File : NSObject

/// Opens `path` (share-relative, backslashes) for reading. Blocking.
- (nullable instancetype)initWithContext:(struct smb2_context *)context
                                     path:(NSString *)path
                                    error:(NSError *_Nullable *_Nullable)error
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Total length in bytes, from `smb2_fstat` at open.
@property(nonatomic, assign, readonly) long long fileSize;
/// The server's `MaxReadSize`; every pread is clamped to it.
@property(nonatomic, assign, readonly) uint32_t maxReadSize;

/// Reads up to `length` bytes at `offset`, returning nil only on a real failure.
/// A read at or past EOF returns empty data, which is normal: the engine's
/// probe asks for a fixed-size head even on short files.
- (nullable NSData *)readAtOffset:(long long)offset length:(NSUInteger)length;

- (void)closeFile NS_SWIFT_NAME(close());

@end

/// One directory entry, as the browser needs it.
@interface LibSMB2Entry : NSObject
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, assign, readonly) BOOL isDirectory;
@property(nonatomic, assign, readonly) long long size;
/// Modification time in milliseconds since the epoch, 0 when unknown.
@property(nonatomic, assign, readonly) long long modifiedMillis;
@end

/// A logged-in session with one tree connection, owning the `smb2_context`.
///
/// The context is not thread-safe — libsmb2 keeps its message-id counter and
/// credit state in plain struct fields — so every read goes through the caller's
/// lock rather than being made concurrent here.
@interface LibSMB2Session : NSObject
/// Takes ownership of an already-connected context. Private because a session
/// is only ever created by LibSMB2.openSessionToHost:..., which owns the
/// connect sequence.
- (instancetype)initWithContext:(struct smb2_context *)context
                           host:(NSString *)host
                          share:(NSString *)share NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, copy, readonly) NSString *host;
@property(nonatomic, copy, readonly) NSString *share;
/// Opens a file for reading. Blocking.
- (nullable LibSMB2File *)openFile:(NSString *)relativePath
                              error:(NSError *_Nullable *_Nullable)error;

/// Lists one directory. `relativePath` may be empty for the share root.
/// Blocking; returns nil only on a real failure.
- (nullable NSArray<LibSMB2Entry *> *)listDirectory:(NSString *)relativePath
                                                error:(NSError *_Nullable *_Nullable)error;

/// Size of one file, without keeping the handle. Blocking.
- (BOOL)fileSizeAtPath:(NSString *)relativePath
                 size:(long long *)outSize
                error:(NSError *_Nullable *_Nullable)error;

/// Reads up to `length` bytes at `offset` and closes the handle. Used for the
/// small sidecar-subtitle fetches; video goes through LibSMB2File so the handle
/// stays open.
- (nullable NSData *)readFileAtPath:(NSString *)relativePath
                              offset:(long long)offset
                              length:(NSUInteger)length
                               error:(NSError *_Nullable *_Nullable)error;

- (void)closeSession NS_SWIFT_NAME(close());
@end


@interface LibSMB2 : NSObject

/// Library version string, for the startup log. Proves the archive linked.
+ (NSString *)libraryVersion;

/// Identifies one host. Blocking; call from a background queue.
///
/// `timeoutSeconds` bounds the whole attempt so a filtered port cannot stall the
/// sweep — a host that drops packets (rather than refusing) is the common case
/// and would otherwise cost the full timeout each.
+ (LibSMB2Server *)probeHost:(NSString *)host
                       port:(uint16_t)port
                    timeout:(int)timeoutSeconds;

/// Identifies many hosts concurrently, returning whatever answered.
///
/// Bounded so a /24 does not open 254 sockets at once; the sweep is I/O bound on
/// dropped packets, so serialising it would make a scan take minutes.
/// A logged-in session plus a tree connection, ready to open files.
///
/// Split from the discovery probe because those have different lifetimes: a
/// probe is created and destroyed per host, whereas playback holds one session
/// for the length of the video.
+ (nullable LibSMB2Session *)openSessionToHost:(NSString *)host
                                         port:(uint16_t)port
                                          user:(nullable NSString *)user
                                      password:(nullable NSString *)password
                                        domain:(nullable NSString *)domain
                                         share:(NSString *)share
                                     timeout:(int)timeoutSeconds
                                         error:(NSError *_Nullable *_Nullable)error;

/// Share names to probe, because SMB2 has no share-enumeration call — the same
/// limitation Android works around the same way.
+ (NSArray<NSString *> *)commonShareNames;

/// Probes each common share name and returns the ones that exist, in listing
/// order. SMB2 cannot enumerate shares, so a share with an unusual name has to
/// be added by hand — mirrored by the existing "Add share" affordance.
+ (nullable NSArray<NSString *> *)listSharesForHost:(NSString *)host
                                                port:(uint16_t)port
                                                user:(nullable NSString *)user
                                            password:(nullable NSString *)password
                                              domain:(nullable NSString *)domain
                                     extraShareNames:(nullable NSArray<NSString *> *)extraShareNames
                                             timeout:(int)timeoutSeconds
                                               error:(NSError *_Nullable *_Nullable)error;

+ (NSArray<LibSMB2Server *> *)probeHosts:(NSArray<NSString *> *)hosts
                                   port:(uint16_t)port
                                timeout:(int)timeoutSeconds
                              maxParallel:(int)maxParallel;

@end

NS_ASSUME_NONNULL_END
