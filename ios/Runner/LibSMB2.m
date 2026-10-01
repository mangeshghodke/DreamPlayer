#import "LibSMB2.h"

// Both headers are required and neither includes the other: SMB2_GUID_SIZE and
// smb2_lease_key live in smb2.h, while the smb2_* entry points live in
// libsmb2.h. Importing only libsmb2.h fails to compile.
#import <fcntl.h>
#import <smb2/smb2.h>
#import <smb2/libsmb2.h>

/// LibSMB2File's initialiser is private, but LibSMB2Session.openFile calls it
/// from above, and Objective-C needs a visible declaration before a use.
@interface LibSMB2File ()
- (instancetype)initWithContext:(struct smb2_context *)context
                          handle:(struct smb2fh *)handle
                        fileSize:(long long)fileSize
                          owner:(LibSMB2Session *)owner;
@end

/// SMB dialect constants, mirrored from smb2.h so the display label does not
/// depend on the C enum being visible here.
static NSString *const LibSMB2ErrorDomain = @"com.dreamplayer.app.smb.libsmb2";

/// Assigns a ready-to-display message to an NSError out-parameter.
static void LibSMB2Fail(NSError **error, NSString *message) {
  if (error != NULL) {
    *error = [NSError errorWithDomain:LibSMB2ErrorDomain
                                 code:1
                             userInfo:@{NSLocalizedDescriptionKey: message}];
  }
}

static NSString *LibSMB2DialectLabel(uint16_t dialect) {
  switch (dialect) {
    case 0x0202: return @"SMB 2.0.2";
    case 0x0210: return @"SMB 2.1";
    case 0x0300: return @"SMB 3.0";
    case 0x0302: return @"SMB 3.0.2";
    case 0x0311: return @"SMB 3.1.1";
    default: return @"";
  }
}

@implementation LibSMB2Server
@end


#pragma mark - Session

@implementation LibSMB2Session {
  struct smb2_context *_ctx;
}

- (instancetype)initWithContext:(struct smb2_context *)context
                           host:(NSString *)host
                          share:(NSString *)share {
  self = [super init];
  if (self) {
    _ctx = context;
    _host = [host copy];
    _share = [share copy];
  }
  return self;
}

- (void)dealloc {
  [self closeSession];
}

- (nullable LibSMB2File *)openFile:(NSString *)relativePath
                              error:(NSError *_Nullable *_Nullable)error {
  // The CREATE request's Name is relative to the tree connect, so the path must
  // be share-relative with backslash separators and NO leading separator —
  // libsmb2 hands the string to the server untouched. Prepending a backslash
  // made every open fail with STATUS_INVALID_PARAMETER (0xc000000d).
  NSString *trimmed = relativePath;
  while ([trimmed hasPrefix:@"/"]) {
    trimmed = [trimmed substringFromIndex:1];
  }
  while ([trimmed hasSuffix:@"/"]) {
    trimmed = [trimmed substringToIndex:trimmed.length - 1];
  }
  NSString *native = [trimmed stringByReplacingOccurrencesOfString:@"/"
                                                       withString:@"\\"];

  struct smb2fh *fh = smb2_open(_ctx, native.UTF8String, O_RDONLY);
  if (fh == NULL) {
    const char *msg = smb2_get_error(_ctx);
    if (error != NULL) {
      // The path is not a secret and belongs in the message: without it a
      // failure here is indistinguishable from a permissions problem.
      LibSMB2Fail(error, [NSString stringWithFormat:@"%@ [%@\\%@]",
                           msg != NULL ? @(msg) : @"Could not open the file",
                           _share, native]);
    }
    return nil;
  }

  struct smb2_stat_64 st;
  memset(&st, 0, sizeof(st));
  long long size = 0;
  if (smb2_fstat(_ctx, fh, &st) == 0) {
    size = (long long)st.smb2_size;
  }

  LibSMB2File *file = [[LibSMB2File alloc] initWithContext:_ctx
                                                      handle:fh
                                                   fileSize:size
                                                     owner:self];
  return file;
}

- (void)closeSession {
  if (_ctx != NULL) {
    smb2_disconnect_share(_ctx);
    smb2_destroy_context(_ctx);
    _ctx = NULL;
  }
}

@end

#pragma mark - File

@implementation LibSMB2File {
  struct smb2_context *_ctx;
  struct smb2fh *_fh;
  BOOL _closed;
  /// Retained deliberately. The engine may hold a reader past the point where
  /// SMBBridge drops the session, and smb2_destroy_context frees `_ctx`; without
  /// this the next read would use a dangling pointer. Holding the session keeps
  /// the context alive for exactly as long as any reader can reach it.
  LibSMB2Session *_owner;
}

- (instancetype)initWithContext:(struct smb2_context *)context
                          handle:(struct smb2fh *)handle
                        fileSize:(long long)fileSize
                          owner:(LibSMB2Session *)owner {
  self = [super init];
  if (self) {
    _owner = owner;
    _ctx = context;
    _fh = handle;
    _fileSize = fileSize;
    _maxReadSize = smb2_get_max_read_size(context);
    if (_maxReadSize == 0) {
      _maxReadSize = 64 * 1024;
    }
  }
  return self;
}

- (void)dealloc {
  [self closeFile];
}

- (nullable NSData *)readAtOffset:(long long)offset length:(NSUInteger)length {
  if (_closed || _fh == NULL || length == 0 || offset < 0) {
    return nil;
  }
  if (offset >= _fileSize) {
    return [NSData data];
  }
  NSUInteger want = (NSUInteger)MIN((long long)length, _fileSize - offset);

  NSMutableData *out = [NSMutableData dataWithCapacity:want];
  uint8_t *chunk = malloc(_maxReadSize);
  if (chunk == NULL) {
    return nil;
  }
  while (out.length < want) {
    NSUInteger remaining = want - out.length;
    uint32_t ask = (uint32_t)MIN((NSUInteger)_maxReadSize, remaining);
    // pread is synchronous, so this loop is a sequence of blocking round-trips
    // rather than a chain of suspended tasks — which is what makes it safe to
    // call straight from the engine's demux thread.
    int got = smb2_pread(_ctx, _fh, chunk, ask, (uint64_t)(offset + out.length));
    if (got < 0) {
      free(chunk);
      return nil;
    }
    if (got == 0) {
      break;  // short read: EOF, or the server gave us less than we asked
    }
    [out appendBytes:chunk length:(NSUInteger)got];
    if ((uint32_t)got < ask) {
      break;
    }
  }
  free(chunk);
  return out;
}

- (void)closeFile {
  if (!_closed && _fh != NULL) {
    smb2_close(_ctx, _fh);
    _fh = NULL;
  }
  _closed = YES;
}

@end

#pragma mark - Factory

@implementation LibSMB2

+ (NSString *)libraryVersion {
  struct smb2_libversion v;
  memset(&v, 0, sizeof(v));
  smb2_get_libsmb2Version(&v);
  return [NSString stringWithFormat:@"%u.%u.%u",
          v.major_version, v.minor_version, v.patch_version];
}

+ (LibSMB2Server *)probeHost:(NSString *)host
                       port:(uint16_t)port
                    timeout:(int)timeoutSeconds {
  LibSMB2Server *out = [LibSMB2Server new];
  out.host = host;
  out.port = port;

  struct smb2_context *ctx = smb2_init_context();
  if (ctx == NULL) {
    out.failure = @"Could not allocate an SMB context";
    return out;
  }

  // Bound the whole attempt. Without this a host that silently drops packets on
  // 445 costs the OS TCP timeout, which over a /24 is the difference between a
  // scan finishing and appearing to hang.
  smb2_set_timeout(ctx, timeoutSeconds);
  // Let the server pick the highest dialect it supports, so the label reflects
  // what the host can really do rather than a version we forced.
  smb2_set_version(ctx, SMB2_VERSION_ANY);
  // SMB3 encryption is negotiated when the server wants it but is never
  // *required* here, so an encrypted-only share is out of scope rather than a
  // connection failure. Signing is likewise left at the default.
  smb2_set_seal(ctx, 0);
  // A stable client GUID keeps the server's per-connection view of us
  // consistent across the sweep.
  uint8_t guid[SMB2_GUID_SIZE];
  memset(guid, 0, sizeof(guid));
  smb2_set_client_guid(ctx, guid);

  // IPC$ is the interprocess-communication share that every Windows and Samba
  // server exposes, and it normally allows anonymous access. Connecting to it is
  // therefore the cheapest way to force a real SMB negotiate: unlike a bare TCP
  // connect, a success here proves the peer speaks SMB2/3 and tells us which
  // dialect it settled on. user == NULL selects the anonymous path.
  NSString *server = port == 445
      ? host
      : [NSString stringWithFormat:@"%@:%hu", host, port];

  int rc = smb2_connect_share(ctx, server.UTF8String, "IPC$", NULL);
  if (rc != 0) {
    const char *err = smb2_get_error(ctx);
    out.failure = err != NULL
        ? [NSString stringWithFormat:@"%s", err]
        : [NSString stringWithFormat:@"SMB error %d", rc];
    smb2_destroy_context(ctx);
    return out;
  }

  out.reachable = YES;
  out.dialect = smb2_get_dialect(ctx);
  out.dialectLabel = LibSMB2DialectLabel(out.dialect);
  const char *guidStr = smb2_get_server_guid(ctx);
  if (guidStr != NULL) {
    out.serverGuid = [NSString stringWithUTF8String:guidStr];
  }

  smb2_disconnect_share(ctx);
  smb2_destroy_context(ctx);
  return out;
}

+ (nullable LibSMB2Session *)openSessionToHost:(NSString *)host
                                         port:(uint16_t)port
                                          user:(nullable NSString *)user
                                      password:(nullable NSString *)password
                                        domain:(nullable NSString *)domain
                                         share:(NSString *)share
                                     timeout:(int)timeoutSeconds
                                         error:(NSError *_Nullable *_Nullable)error {
  struct smb2_context *ctx = smb2_init_context();
  if (ctx == NULL) {
    LibSMB2Fail(error, @"Could not allocate an SMB context");
    return nil;
  }
  smb2_set_timeout(ctx, timeoutSeconds);
  smb2_set_version(ctx, SMB2_VERSION_ANY);
  smb2_set_seal(ctx, 0);
  // Signing is negotiated when the server wants it but never *required*, so an
  // encrypted-only share is out of scope rather than a connection failure.
  smb2_set_security_mode(ctx, SMB2_NEGOTIATE_SIGNING_ENABLED);

  // Empty user means anonymous. Windows rejects a NULL password outright on a
  // named account, so an empty string is passed instead when we do have a user.
  BOOL wantsGuest = (user.length == 0);
  smb2_set_user(ctx, wantsGuest ? "guest" : user.UTF8String);
  smb2_set_password(ctx, wantsGuest ? "" : (password.length ? password.UTF8String : ""));
  if (domain.length) {
    smb2_set_domain(ctx, domain.UTF8String);
  }
  smb2_set_workstation(ctx, "DreamPlayer");

  NSString *server = port == 445
      ? host
      : [NSString stringWithFormat:@"%@:%hu", host, port];

  int rc = smb2_connect_share(ctx, server.UTF8String, share.UTF8String,
                              wantsGuest ? NULL : user.UTF8String);
  if (rc != 0) {
    const char *msg = smb2_get_error(ctx);
    LibSMB2Fail(error, msg != NULL ? @(msg) : @"Could not connect to that share");
    smb2_destroy_context(ctx);
    return nil;
  }

  return [[LibSMB2Session alloc] initWithContext:ctx host:host share:share];
}

+ (NSArray<LibSMB2Server *> *)probeHosts:(NSArray<NSString *> *)hosts
                                   port:(uint16_t)port
                                timeout:(int)timeoutSeconds
                            maxParallel:(int)maxParallel {
  if (hosts.count == 0) {
    return @[];
  }
  if (maxParallel < 1) {
    maxParallel = 1;
  }

  // libsmb2 keeps all per-connection state in the context and nothing is shared
  // between contexts, so probing on a concurrent queue needs no locking.
  dispatch_queue_t queue = dispatch_queue_create("app.dreamplayer.smb2.probe",
                                                DISPATCH_QUEUE_CONCURRENT);
  dispatch_semaphore_t gate = dispatch_semaphore_create(maxParallel);
  dispatch_group_t group = dispatch_group_create();
  NSMutableArray<LibSMB2Server *> *found =
      [NSMutableArray arrayWithCapacity:hosts.count];
  // Only touched on `queue`, so no lock is needed for `found`.
  NSLock *foundLock = [NSLock new];

  for (NSString *host in hosts) {
    dispatch_group_enter(group);
    dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    dispatch_async(queue, ^{
      LibSMB2Server *server = [LibSMB2 probeHost:host
                                             port:port
                                          timeout:timeoutSeconds];
      if (server.reachable) {
        [foundLock lock];
        [found addObject:server];
        [foundLock unlock];
      }
      dispatch_semaphore_signal(gate);
      dispatch_group_leave(group);
    });
  }

  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
  return found;
}

@end
