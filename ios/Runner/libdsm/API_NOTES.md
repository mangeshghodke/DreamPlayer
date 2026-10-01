# libDSM C API (what DreamPlayer uses)

Vendored from `TOSMBClient/libdsm` (VideoLabs liBDSM). LGPLv2.1 or commercial.
`libdsm.a` is a Mach-O universal archive: armv7, armv7s, i386, x86_64, **arm64**.
No build step required. `libtasn1.a` is its ASN.1 dependency.

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
    smb_stat_list smb_find(smb_session *, smb_tid, const char *pattern); // "*"
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
