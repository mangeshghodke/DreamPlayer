#import <Foundation/Foundation.h>

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
+ (NSArray<LibSMB2Server *> *)probeHosts:(NSArray<NSString *> *)hosts
                                   port:(uint16_t)port
                                timeout:(int)timeoutSeconds
                              maxParallel:(int)maxParallel;

@end

NS_ASSUME_NONNULL_END
