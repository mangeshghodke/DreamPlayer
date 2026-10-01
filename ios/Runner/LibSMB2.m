#import "LibSMB2.h"

#import <smb2/libsmb2.h>

/// SMB dialect constants, mirrored from smb2.h so the display label does not
/// depend on the C enum being visible here.
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
