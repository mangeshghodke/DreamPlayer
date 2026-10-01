/*
 * Platform shims for building libsmb2 on iOS.
 *
 * Neither of these is a workaround for a bug in libsmb2 — both are places where
 * the library expects a POSIX facility that iOS does not provide, and where its
 * own fallback in compat.c is written for a different platform.
 *
 * 1. getlogin_r()
 *    lib/init.c calls getlogin_r() unconditionally, only to seed a default
 *    username ("Guest" when it fails) that we always override with
 *    smb2_set_user() before logging in. iOS has getlogin() but not
 *    getlogin_r(). Defining NEED_GETLOGIN_R is not an option: the fallback in
 *    compat.c returns a variable `login_num` that only exists inside the
 *    Dreamcast/Amiga section of that file, so it does not compile anywhere else.
 *
 * 2. _U_
 *    lib/aes128ccm.c sprinkles `_U_` through its declarations. That macro comes
 *    from OpenSSL, which we deliberately do not link — SMB3 encryption is
 *    optional and aes_apple.c uses Apple's CommonCrypto. The build script
 *    passes -D_U_= for exactly the same reason; it is repeated here so this
 *    file documents the dependency.
 */

#include <stddef.h>
#include <sys/types.h>

int getlogin_r(char *buf, size_t size)
{
    (void)size;
    if (buf != NULL) {
        buf[0] = '\0';
    }
    /* Non-zero tells libsmb2 the lookup failed, which is the truth on iOS:
     * there is no login session to ask about. */
    return -1;
}
