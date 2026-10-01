# libDSM C API (what DreamPlayer uses)

Upstream C library: VideoLabs liBDSM, LGPLv2.1 or commercial
(https://github.com/videolan/libdsm).

The prebuilt archives are taken verbatim from the upstream project's own iOS
distribution (`distribution/ios/libdsm/` at
https://github.com/biezhihua/libdsm), so the headers and the binaries come from
one build. `libdsm.a` and `libtasn1.a` are Mach-O universal archives over
**x86_64, arm64 and arm64e**. No build step required.

The distribution also ships `libiconv.a` and `libcharset.a`. They are
deliberately **not** vendored: libdsm only calls `iconv_open`/`iconv_close`,
which Apple's system `libiconv` provides via `-liconv`, and nothing references
`locale_charset`, so `libcharset` is unnecessary. Bundling GNU libiconv would
both collide with the system iconv other dependencies pull in and run into
Apple's restrictions on shipping it.

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
