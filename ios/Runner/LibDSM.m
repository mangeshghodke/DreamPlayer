//
//  LibDSM.m
//  DreamPlayer
//

#import "LibDSM.h"
#import "SBMLog.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <poll.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#import "bdsm/bdsm.h"

#pragma mark - Entry

@implementation LibDSMEntry

- (instancetype)initWithName:(NSString *)name
                      path:(NSString *)path
                 isDirectory:(BOOL)isDirectory
                         size:(unsigned long long)size
                     modified:(long long)modified {
  self = [super init];
  if (self) {
    _name = [name copy];
    _relativePath = [path copy];
    _isDirectory = isDirectory;
    _size = size;
    _modifiedMillis = modified;
  }
  return self;
}

@end

#pragma mark - Helpers

/// Turns libDSM's C errno-ish return into something a user can act on.
///
/// libDSM returns the negative errno from the wire, so the codes worth naming
/// are the auth and reachability ones — the rest collapse to the numeric value
/// rather than inventing a message we cannot stand behind.
static NSString *LibDSMFriendlyError(int code, NSString *host) {
  switch (code) {
    case -61:  // EACCES
    case -13:
      return @"Login failed — check username, password and domain";
    case -111:  // ECONNREFUSED
      return [NSString stringWithFormat:@"Can't reach %@ on the SMB port", host];
    case -110:  // ETIMEDOUT
      return [NSString stringWithFormat:@"Timed out reaching %@", host];
    case -113:  // EHOSTUNREACH
      return [NSString stringWithFormat:@"%@ is unreachable", host];
    case -101:  // ENETUNREACH
      return @"The network is unreachable";
    default:
      return [NSString stringWithFormat:@"SMB error %d on %@", code, host];
  }
}

/// Share-relative path with backslashes, which is what libDSM's fopen expects.
static NSString *LibDSMNativePath(NSString *path) {
  NSString *trimmed = [path stringByTrimmingCharactersInSet:
                       [NSCharacterSet characterSetWithCharactersInString:@"/"]];
  if (trimmed.length == 0) {
    return @"\\";
  }
  NSString *backslashed = [trimmed stringByReplacingOccurrencesOfString:@"/"
                                                          withString:@"\\"];
  return [@"\\" stringByAppendingString:backslashed];
}

/// Seconds-since-epoch → milliseconds, or 0 when unset.
static long long LibDSMMillis(time_t seconds) {
  if (seconds <= 0) {
    return 0;
  }
  return (long long)seconds * 1000LL;
}

#pragma mark - Session

@implementation LibDSMSession {
  smb_session *_session;
  smb_tid _tid;
  smb_fd _fd;
  BOOL _fileOpen;
  BOOL _isGuest;
  NSString *_host;
  uint16_t _port;
}

- (nullable instancetype)initWithHost:(NSString *)host
                                  port:(uint16_t)port
                              hostname:(nullable NSString *)hostname
                                 share:(NSString *)share
                                   user:(nullable NSString *)user
                               password:(nullable NSString *)password
                                 domain:(nullable NSString *)domain
                                 error:(NSString *_Nullable *_Nullable)error {
  self = [super init];
  if (!self) {
    return nil;
  }
  _host = [host copy];
  _port = port;
  _share = [share copy];
  _fd = 0;

  // An empty user means "no account": ask for guest, which is what a public
  // Samba share on a workstation expects. A supplied user that fails is a real
  // auth error and is reported as one — libDSM's login() returns 0 even when it
  // fell back to guest, which is why is_guest is checked explicitly below.
  BOOL wantsGuest = (user.length == 0);

  struct in_addr addr;
  if (inet_pton(AF_INET, host.UTF8String, &addr) != 1) {
    if (error) {
      *error = [NSString stringWithFormat:@"\"%@\" is not a valid IP address", host];
    }
    return nil;
  }

  _session = smb_session_new();
  if (_session == NULL) {
    if (error) {
      *error = @"Could not allocate an SMB session";
    }
    return nil;
  }

  if (!wantsGuest) {
    smb_session_set_creds(_session,
                          domain.length ? domain.UTF8String : NULL,
                          user.UTF8String,
                          password.length ? password.UTF8String : NULL);
  }

  // Direct TCP on 445. No NetBIOS name lookup: the share is exported by a
  // workstation with no name service, and SMB_TRANSPORT_TCP does not need one.
  // The hostname is still required by the API and goes into session setup, so
  // anything sane is fine.
  NSString *name = hostname.length ? hostname : @"DREAMPLAYER";
  int rc = smb_session_connect(_session, name.UTF8String, addr.s_addr,
                               SMB_TRANSPORT_TCP);
  if (rc != 0) {
    if (error) {
      *error = LibDSMFriendlyError(rc, host);
    }
    smb_session_destroy(_session);
    _session = NULL;
    return nil;
  }

  if (wantsGuest) {
    smb_session_set_creds(_session, NULL, "guest", "");
    // The empty password is passed as a real (empty) string rather than NULL:
    // some servers reject a NULL password outright.
  }

  rc = smb_session_login(_session);
  int guest = smb_session_is_guest(_session);
  _isGuest = (guest == 1);

  if (rc != 0) {
    if (error) {
      *error = LibDSMFriendlyError(rc, host);
    }
    smb_session_destroy(_session);
    _session = NULL;
    return nil;
  }
  if (wantsGuest && guest != 1) {
    // Anonymous was requested and we did not land as guest — say so instead of
    // failing later with a confusing permission error on the share.
    SBMLog.log(@"LibDSM: anonymous login to \\(host) landed as a real user");
  }
  if (!wantsGuest && guest == 1) {
    SBMLog.log(@"LibDSM: \\(user)@\\(host) fell back to guest");
  }

  rc = smb_tree_connect(_session, share.UTF8String, &_tid);
  if (rc != 0 || _tid == 0) {
    if (error) {
      *error = (rc != 0) ? LibDSMFriendlyError(rc, host)
                         : [NSString stringWithFormat:@"Could not open share \"%@\"",
                            share];
    }
    smb_session_destroy(_session);
    _session = NULL;
    return nil;
  }

  return self;
}

- (void)dealloc {
  // Every tid/fid dies with the session, so one destroy is enough. The caller
  // must be sure no read is in flight — SMBBridge serialises this on one queue.
  if (_session != NULL) {
    smb_session_destroy(_session);
    _session = NULL;
  }
}

- (BOOL)loggedInAsGuest {
  return _isGuest;
}

#pragma mark Listing

- (nullable NSArray<LibDSMEntry *> *)listDirectory:(NSString *)path
                                              error:(NSString *_Nullable *_Nullable)error {
  NSString *pattern = LibDSMNativePath(path);
  smb_stat_list list = smb_find(_session, _tid, pattern.UTF8String);
  if (list == NULL) {
    if (error) {
      *error = [NSString stringWithFormat:@"Could not read \"%@\"",
                path.length ? path : @"/"];
    }
    return nil;
  }

  NSMutableArray<LibDSMEntry *> *out = [NSMutableArray array];
  // Walk by index: smb_find returns a NULL-terminated array of smb_file.
  size_t count = 0;
  while (smb_stat_list_at(list, count) != NULL) {
    count++;
  }

  for (size_t i = 0; i < count; i++) {
    smb_stat info = smb_stat_list_at(list, i);
    if (info == NULL) {
      continue;
    }
    const char *rawName = smb_stat_name(info);
    if (rawName == NULL) {
      continue;
    }
    NSString *name = [NSString stringWithUTF8String:rawName];
    if (name == nil || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
      continue;
    }
    BOOL isDir = smb_stat_get(info, SMB_STAT_ISDIR) != 0;
    unsigned long long size = smb_stat_get(info, SMB_STAT_SIZE);
    long long modified = LibDSMMillis((time_t)smb_stat_get(info, SMB_STAT_MTIME));

    NSString *relative = path.length
        ? [NSString stringWithFormat:@"%@/%@", path, name]
        : name;

    [out addObject:[[LibDSMEntry alloc] initWithName:name
                                                 path:relative
                                            isDirectory:isDir
                                                    size:size
                                                modified:modified]];
  }

  smb_stat_list_destroy(list);
  return out;
}

#pragma mark Sizes

- (unsigned long long)fileSizeAtRelativePath:(NSString *)path {
  smb_stat info = smb_fstat(_session, _tid, LibDSMNativePath(path).UTF8String);
  if (info == NULL) {
    return 0;
  }
  return smb_stat_get(info, SMB_STAT_SIZE);
}

#pragma mark Playback

- (BOOL)prepareForPlaybackOfRelativePath:(NSString *)path
                                  error:(NSString *_Nullable *_Nullable)error {
  if (_fileOpen) {
    smb_fclose(_session, _fd);
    _fd = 0;
    _fileOpen = NO;
  }
  int rc = smb_fopen(_session, _tid, LibDSMNativePath(path).UTF8String,
                     SMB_MOD_READ, &_fd);
  if (rc != 0 || _fd == 0) {
    if (error) {
      *error = LibDSMFriendlyError(rc, _host);
    }
    _fd = 0;
    return NO;
  }
  _fileOpen = YES;
  _preparedSize = (long long)fileSizeAtRelativePath:(path);
  return YES;
}

- (nullable NSData *)readAtOffset:(long long)offset length:(NSUInteger)length {
  if (!_fileOpen || _session == NULL || length == 0 || offset < 0) {
    return nil;
  }
  // A seek is the only cursor movement libDSM needs — no reconnect, no new
  // handle, no ring buffer to reset.
  if (smb_fseek(_session, _fd, (off_t)offset, SMB_SEEK_SET) < 0) {
    return nil;
  }
  NSMutableData *out = [NSMutableData dataWithLength:length];
  ssize_t got = smb_fread(_session, _fd, out.mutableBytes, length);
  if (got < 0) {
    return nil;
  }
  // A short read means EOF, which is normal — not an error.
  if ((NSUInteger)got < length) {
    out.length = (NSUInteger)got;
  }
  return out;
}

#pragma mark Shares

+ (nullable NSArray<NSString *> *)listSharesOnHost:(NSString *)host
                                              port:(uint16_t)port
                                             user:(nullable NSString *)user
                                         password:(nullable NSString *)password
                                           domain:(nullable NSString *)domain
                                            error:(NSString *_Nullable *_Nullable)error {
  struct in_addr addr;
  if (inet_pton(AF_INET, host.UTF8String, &addr) != 1) {
    if (error) {
      *error = [NSString stringWithFormat:@"\"%@\" is not a valid IP address", host];
    }
    return nil;
  }

  smb_session *s = smb_session_new();
  if (s == NULL) {
    if (error) {
      *error = @"Could not allocate an SMB session";
    }
    return nil;
  }

  NSMutableString *failure = [NSMutableString string];
  int rc = smb_session_connect(s, "DREAMPLAYER", addr.s_addr, SMB_TRANSPORT_TCP);
  if (rc != 0) {
    [failure appendString:LibDSMFriendlyError(rc, host)];
  } else {
    BOOL wantsGuest = (user.length == 0);
    smb_session_set_creds(s,
                          wantsGuest ? NULL : (domain.length ? domain.UTF8String : NULL),
                          wantsGuest ? "guest" : user.UTF8String,
                          wantsGuest ? "" : (password.length ? password.UTF8String : NULL));
    rc = smb_session_login(s);
    if (rc != 0) {
      [failure appendString:LibDSMFriendlyError(rc, host)];
    } else {
      smb_share_list shares = NULL;
      size_t count = 0;
      rc = smb_share_get_list(s, &shares, &count);
      if (rc != 0) {
        [failure appendString:LibDSMFriendlyError(rc, host)];
      } else {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (size_t i = 0; i < count; i++) {
          const char *n = smb_share_list_at(shares, i);
          if (n != NULL) {
            [names addObject:[NSString stringWithUTF8String:n]];
          }
        }
        smb_share_list_destroy(shares);
        smb_session_destroy(s);
        return names;
      }
    }
  }
  smb_session_destroy(s);
  if (error) {
    *error = failure.length ? failure : @"Could not list shares";
  }
  return nil;
}

+ (BOOL)canReachHost:(NSString *)host port:(uint16_t)port {
  struct in_addr addr;
  if (inet_pton(AF_INET, host.UTF8String, &addr) != 1) {
    return NO;
  }
  int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (fd < 0) {
    return NO;
  }
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  sa.sin_addr = addr;

  int flags = fcntl(fd, F_GETFL, 0);
  fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  int rc = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
  BOOL ok = NO;
  if (rc == 0) {
    ok = YES;
  } else if (errno == EINPROGRESS) {
    struct pollfd pfd = {fd, POLLOUT, 0};
    if (poll(&pfd, 1, 400) > 0) {
      int err = 0;
      socklen_t len = sizeof(err);
      if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0) {
        ok = (err == 0);
      }
    }
  }
  close(fd);
  return ok;
}

@end
