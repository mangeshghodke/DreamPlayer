# libDSM C API (what DreamPlayer uses)

Upstream C library: VideoLabs liBDSM, LGPLv2.1 or commercial
(https://github.com/videolan/libdsm).

The prebuilt archives are taken verbatim from the upstream project's own iOS
distribution (`distribution/ios/libdsm/` at
https://github.com/biezhihua/libdsm), so the headers and the binaries come from
one build. `libdsm.a` and `libtasn1.a` are Mach-O universal archives over
**x86_64, arm64 and arm64e**. No build step required.

All four archives it ships are vendored, because all four are needed:

| archive | needed by | symbols |
|---|---|---|
| `libdsm.a` | — | the `smb_*` API |
| `libtasn1.a` | `libdsm.a` | ASN.1, pulled in via `#include <libtasn1.h>` |
| `libiconv.a` | `libdsm.a` | `libiconv_open`, `libiconv_close`, `libiconv` |
| `libcharset.a` | `libiconv.a` | `locale_charset` |

`-liconv` alone is **not** enough. Apple's system libiconv exports the plain
`iconv_open`/`iconv_close`, while this libdsm build calls GNU's *prefixed*
`libiconv_open`/`libiconv_close`/`libiconv`, which only `libiconv.a` provides —
linking `-liconv` alone fails with `Undefined symbol: _libiconv_open`.

Link order matters for static archives (a dependent must precede what satisfies
it), so the Frameworks phase is ordered `libdsm.a`, `libtasn1.a`, `libiconv.a`,
`libcharset.a`.

`libtasn1.h` is the only header that must sit on the search path, because
`bdsm/smb_types.h` does `#include <libtasn1.h>`. The distribution's `iconv.h`,
`libcharset.h` and `localcharset.h` are deliberately **not** vendored: nothing
compiles against them, and GNU's `iconv.h` on the header search path would shadow
the system `iconv.h` for the whole Runner target.

## Read this before using the upstream docs

<https://videolabs.github.io/libdsm/> documents **release 0.0.4** and its
examples do not compile against the build vendored here. The differences are
not cosmetic:

| | docs (0.0.4) | vendored build |
|---|---|---|
| header path | `<bsdm/bdsm.h>` | `<bdsm/bdsm.h>` |
| `smb_tree_connect` | 2 args, returns the tid | 3 args, tid via out-param |
| `smb_fopen` | 3 args, read-only implied | 5 args, `SMB_MOD_READ` + `smb_fd*` |
| guest flag | `session->guest` struct field | `smb_session_is_guest()` |

The vendored headers are authoritative — `smb_types.h` declares
`struct smb_session` opaque, so the old field access is impossible.
`tool/libdsm_check.py` validates every call against those headers.

The docs *are* still useful for the things the headers do not state:

- **libiconv and libtasn1 are the only two dependencies.** This is why
  `-liconv` alone is not enough — GNU libiconv's `libiconv_open` /
  `libiconv_close` / `libiconv` are what this build actually calls.
- **A zero tid means failure** (`tid = smb_tree_connect(...); if (!tid)`),
  which is why the wrapper treats `_tid == 0` as an error.
- **`smb_fopen` paths are `"\\My\\File"`** — backslash-separated with a
  leading separator and *no* trailing wildcard, unlike `smb_find`.
- **Host discovery** exists via `netbios_ns_*` (`bdsm.h` already includes
  `netbios_ns.h`), which is the route to use instead of a hand-rolled LAN scan.

## How these methods appear in Swift

`LibDSM.h` uses `NSError **` for every fallible call. Clang imports those as
`throws` under one of two default conventions, documented at
<https://clang.llvm.org/docs/AttributeReference.html> (`swift_error`):

| return type | convention | imported as | throws when |
|---|---|---|---|
| nullable pointer | `null_result` | non-optional value | it returns `nil` |
| `BOOL` | `zero_result` | **`Void`** | it returns `NO` |

Two consequences worth knowing before editing the header:

- **`null_result` is keyed off the return being nullable.** Mark the return
  `nonnull` and the convention stops applying, so the method silently stops
  importing as throwing. The only symptom is `Missing argument for parameter
  'error'` at the *call site*, three CI cycles away from the cause. This is
  exactly what happened here.
- A `BOOL`-returning `NSError **` method loses its result in Swift. That is
  correct and idiomatic for "did it work", but `if try prepareForPlayback(...)`
  will not compile.

`tool/libdsm_check.py` enforces both: a pointer-returning `NSError **` method
must be declared `nullable`, and a `BOOL`-returning one must carry the
`zero_result` note in the header.

## Session
    smb_session *smb_session_new(void);
    void  smb_session_set_creds(smb_session *, const char *domain,
                                const char *login, const char *password);
    int   smb_session_connect(smb_session *, const char *hostname,
                               uint32_t ip, int transport);  // ip = network byte order
    int   smb_session_login(smb_session *);       // 0 = ok (may land as guest)
    int   smb_session_is_guest(smb_session *);    // 1 = guest, 0 = user, -1 = err
    void  smb_session_destroy(smb_session *);

`SMB_TRANSPORT_TCP` = direct TCP on 445 (no NetBIOS name service needed).

## Shares
    int    smb_share_get_list(smb_session *, smb_share_list *list, size_t *count);
    size_t smb_share_list_count(smb_share_list);
    const char *smb_share_list_at(smb_share_list, size_t);
    void   smb_share_list_destroy(smb_share_list);
    int    smb_tree_connect(smb_session *, const char *name, smb_tid *tid);
    int    smb_tree_disconnect(smb_session *, smb_tid);

## Directory listing
    smb_stat_list smb_find(smb_session *, smb_tid, const char *pattern);
    // pattern is a WILDCARD: "\\*" lists the share root, "\\folder\\*" lists a
    // folder's contents. A bare path matches that one entry, not its children.
    size_t smb_stat_list_count(smb_stat_list);       // 0 if the list is invalid
    smb_stat      smb_stat_list_at(smb_stat_list, size_t);
    void          smb_stat_list_destroy(smb_stat_list);
    const char   *smb_stat_name(smb_stat);
    uint64_t      smb_stat_get(smb_stat, int what);

`smb_stat_get` ops: SMB_STAT_SIZE(0), SMB_STAT_ALLOC_SIZE(1),
SMB_STAT_ISDIR(2), SMB_STAT_CTIME(3), SMB_STAT_ATIME(4), SMB_STAT_WTIME(5),
SMB_STAT_MTIME(6).

## Files
    int      smb_fopen(smb_session *, smb_tid, const char *path, int mode, smb_fd *fd);
    ssize_t  smb_fread(smb_session *, smb_fd, void *buf, size_t buf_size);
    ssize_t  smb_fseek(smb_session *, smb_fd, off_t offset, int whence);
    int      smb_fclose(smb_session *, smb_fd);
    smb_stat smb_fstat(smb_session *, smb_tid, const char *path);

## Discovery (NetBIOS name service over broadcast)
    netbios_ns *netbios_ns_new(void);
    int   netbios_ns_discover_start(netbios_ns *, unsigned int timeout, callbacks);
    int   netbios_ns_discover_stop(netbios_ns *);
    void  netbios_ns_destroy(netbios_ns *);

## Notes for the port
- All calls are SYNCHRONOUS and blocking -> run on a background queue only.
- One `smb_session` owns its sockets; `smb_session_destroy` invalidates every
  `smb_tid`/`smb_fd` taken from it. Connection ownership therefore lives in
  SMBBridge, exactly like the SMBConnection registry it replaces.
- Paths are relative to the share: `smb_fopen(s, tid, "\\sub\\file.mkv", ...)`.
