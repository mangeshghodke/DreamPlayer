//
//  LibDSM.h
//  DreamPlayer
//
//  Thin Objective-C wrapper over liBDSM (VideoLabs), the LGPLv2.1 SMB2 client
//  vendored in Runner/libdsm. Written for this project — the C API is called
//  directly, and every call is blocking, so nothing here may run on the main
//  thread.
//
//  Why libDSM and not the previous pure-Swift client: libDSM owns its own
//  buffering and seeking, which removed the hand-written read-ahead layer where
//  every earlier bug lived (a ring-trim `max()` that stalled large seeks, a
//  60s reader deadline that surfaced as "custom source probe failed", and
//  prefetcher starvation on an audio-track switch).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One entry of a directory listing.
@interface LibDSMEntry : NSObject
@property(nonatomic, copy, readonly) NSString *name;
/// Path relative to the share, using backslashes (what libDSM expects).
@property(nonatomic, copy, readonly) NSString *relativePath;
@property(nonatomic, assign, readonly) BOOL isDirectory;
@property(nonatomic, assign, readonly) unsigned long long size;
/// Milliseconds since the epoch; 0 when the server did not report it.
@property(nonatomic, assign, readonly) long long modifiedMillis;
@end

/// A live SMB session: one socket, one logged-in identity, many trees/files.
///
/// Owns its `smb_session`. Destroying it invalidates every tree and file
/// descriptor taken from it, so this object — not the caller — is the unit of
/// lifetime. Not thread-safe: SMBBridge serialises all access on one queue.
@interface LibDSMSession : NSObject

/// Connects, authenticates and tree-connects to one share.
///
/// @param host      Address to dial (an IP literal works; see `hostname`).
/// @param port      TCP port, normally 445.
/// @param hostname  Name announced in the SMB session setup. When the server
///                  has no NetBIOS name service (a Samba share on a workstation,
///                  most modern routers) any label is accepted; the IP is used
///                  for the actual dial.
/// @param share     Share name to tree-connect.
/// @param user      Empty or nil for a guest/anonymous session.
/// @param password  May be nil when guest.
/// @param domain    May be nil.
/// @param error     Populated on failure with a message already fit to show a
///                  user (the Dart layer renders it verbatim).
- (nullable instancetype)initWithHost:(NSString *)host
                                  port:(uint16_t)port
                              hostname:(nullable NSString *)hostname
                                 share:(NSString *)share
                                   user:(nullable NSString *)user
                               password:(nullable NSString *)password
                                 domain:(nullable NSString *)domain
                                 error:(NSString *_Nullable *_Nullable)error
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, copy, readonly) NSString *share;
/// YES when the server downgraded us to guest after the supplied login failed.
@property(nonatomic, assign, readonly) BOOL loggedInAsGuest;

/// Lists one directory. `path` is share-relative with forward slashes; "" is
/// the share root. Returns nil on failure.
- (nullable NSArray<LibDSMEntry *> *)listDirectory:(NSString *)path
                                              error:(NSString *_Nullable *_Nullable)error;

/// Every share on the server, as a fresh session object (the connection is not
/// reused because share enumeration happens before a share is chosen).
+ (nullable NSArray<NSString *> *)listSharesOnHost:(NSString *)host
                                              port:(uint16_t)port
                                             user:(nullable NSString *)user
                                         password:(nullable NSString *)password
                                           domain:(nullable NSString *)domain
                                            error:(NSString *_Nullable *_Nullable)error;

/// Probes reachability without authenticating. Used by the online/offline dot.
+ (BOOL)canReachHost:(NSString *)host port:(uint16_t)port;

/// Size of one file in bytes, or 0 when it cannot be stat'd.
- (unsigned long long)fileSizeAtRelativePath:(NSString *)path;

/// Reads up to `length` bytes at an absolute `offset`.
///
/// This is the whole playback contract: the engine asks for ranges and we
/// serve them from one already-open handle, so a seek is a `smb_fseek` and
/// nothing else. Returns nil on I/O failure; a short read is not an error.
- (nullable NSData *)readAtOffset:(long long)offset length:(NSUInteger)length;

/// Opens the file once so later reads need no reopen. Call after the engine has
/// probed the container, to keep the first-play latency off the read path.
- (BOOL)prepareForPlaybackOfRelativePath:(NSString *)path
                                  error:(NSString *_Nullable *_Nullable)error;

/// Total size of the prepared file, valid after `prepareForPlayback…`.
@property(nonatomic, assign, readonly) long long preparedSize;

@end

NS_ASSUME_NONNULL_END
