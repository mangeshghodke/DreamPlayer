/*
 * JNI bridge over libsmb2 (https://github.com/sahlberg/libsmb2), LGPL 2.1.
 *
 * Mirrors the iOS LibSMB2 wrapper: a session owns one smb2_context plus one
 * tree connection to a share, and a file is opened read-only with pread
 * (positional reads, no cursor). The Kotlin side holds opaque long handles.
 *
 * Build: see CMakeLists.txt (libsmb2 sources compiled in).
 */
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <smb2/smb2.h>

/* Disable Android tagged pointers (MTE) for this library - libsmb2 stores
 * pointers in fields that may be 32-bit, and tagged pointers truncate them. */
__attribute__((constructor))
static void disable_tagged_pointers(void) {
    prctl(0x53564d41 /* PR_SET_TAGGED_ADDR_CTRL */, 0, 0, 0, 0);
}
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>

/* dcerpc prefix rename (same as iOS). */
#include "libsmb2-dcerpc-prefix.h"

/* ---------------------------------------------------------------- session */

typedef struct {
    struct smb2_context *ctx;
    char *host;
    uint16_t port;
    char *share;
    char *user;
    char *pass;
    int connected;
} Smb2Session;

static Smb2Session *to_session(jlong h) { return (Smb2Session *)(intptr_t)h; }
typedef struct { struct smb2_context *ctx; struct smb2fh *fh; } Smb2File;
static Smb2File *to_file(jlong h) { return (Smb2File *)(intptr_t)h; }
typedef struct { struct smb2_context *ctx; struct smb2dir *dir; } Smb2Dir;
static Smb2Dir *to_dir(jlong h) { return (Smb2Dir *)(intptr_t)h; }

static char *dupstr(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

JNIEXPORT jlong JNICALL
Java_com_dreamplayer_app_Smb2Native_openSession(JNIEnv *env, jclass cls,
    jstring jhost, jint jport, jstring juser, jstring jpass, jstring jdomain,
    jstring jshare) {
    const char *host = (*env)->GetStringUTFChars(env, jhost, NULL);
    const char *user = (*env)->GetStringUTFChars(env, juser, NULL);
    const char *pass = (*env)->GetStringUTFChars(env, jpass, NULL);
    const char *domain = (*env)->GetStringUTFChars(env, jdomain, NULL);
    const char *share = (*env)->GetStringUTFChars(env, jshare, NULL);

    Smb2Session *s = (Smb2Session *)calloc(1, sizeof(Smb2Session));
    s->host = dupstr(host);
    s->port = (uint16_t)jport;
    s->share = dupstr(share);
    s->user = dupstr(user);
    s->pass = dupstr(pass);

    s->ctx = smb2_init_context();
    if (!s->ctx) {
        (*env)->ReleaseStringUTFChars(env, jhost, host);
        (*env)->ReleaseStringUTFChars(env, juser, user);
        (*env)->ReleaseStringUTFChars(env, jpass, pass);
        (*env)->ReleaseStringUTFChars(env, jdomain, domain);
        (*env)->ReleaseStringUTFChars(env, jshare, share);
        free(s->host); free(s->share); free(s->user); free(s->pass); free(s);
        return 0;
    }

    smb2_set_security_mode(s->ctx, SMB2_NEGOTIATE_SIGNING_ENABLED);
    smb2_set_user(s->ctx, s->user);
    smb2_set_password(s->ctx, s->pass);
    if (domain && domain[0]) smb2_set_domain(s->ctx, domain);

    int rc = smb2_connect_share(s->ctx, s->host, s->share, s->user);
    if (rc < 0) {
        const char *err = smb2_get_error(s->ctx);
        (void)err;
        /* Do NOT call smb2_disconnect_share / smb2_destroy_context here:
         * on a failed connect the context's fd state is partial and
         * destroying it crashes (smb2_close_connecting_fds SIGSEGV).
         * Leak the context on the error path - acceptable for a video player. */
        (*env)->ReleaseStringUTFChars(env, jhost, host);
        (*env)->ReleaseStringUTFChars(env, juser, user);
        (*env)->ReleaseStringUTFChars(env, jpass, pass);
        (*env)->ReleaseStringUTFChars(env, jdomain, domain);
        (*env)->ReleaseStringUTFChars(env, jshare, share);
        free(s->host); free(s->share); free(s->user); free(s->pass); free(s);
        return 0;
    }
    s->connected = 1;

    (*env)->ReleaseStringUTFChars(env, jhost, host);
    (*env)->ReleaseStringUTFChars(env, juser, user);
    (*env)->ReleaseStringUTFChars(env, jpass, pass);
    (*env)->ReleaseStringUTFChars(env, jdomain, domain);
    (*env)->ReleaseStringUTFChars(env, jshare, share);
    return (jlong)(intptr_t)s;
}

JNIEXPORT void JNICALL
Java_com_dreamplayer_app_Smb2Native_closeSession(JNIEnv *env, jclass cls, jlong session) {
    Smb2Session *s = to_session(session);
    if (!s) return;
    if (s->ctx) {
        if (s->connected) {
            smb2_disconnect_share(s->ctx);
            /* libsmb2 closes the socket only when the TREE_DISCONNECT
             * succeeds: on STATUS_BUSY (the server refuses while a file
             * handle is still open on that tree) its disconnect_cb_1 returns
             * early and NEVER closes the fd. The TCP connection and the
             * server-side session then stay alive for the life of the
             * process - and the NAS's per-user session limit is small, so
             * after a handful of leaked sessions every new connect fails.
             * That is exactly what broke the MPV loopback proxy: one
             * request served, then nothing. Close the socket ourselves when
             * libsmb2 left it open. */
            t_socket fd = smb2_get_fd(s->ctx);
            if (fd >= 0) {
                close(fd);
            }
        }
        /* smb2_destroy_context crashes in smb2_free_pdu on some contexts
         * (heap corruption from pending PDUs). Leak the context instead -
         * the OS reclaims it when the app exits. */
        s->ctx = NULL;
    }
    free(s->host); free(s->share); free(s->user); free(s->pass); free(s);
}

/* The server's negotiated MaxReadSize. libsmb2 caps EVERY read request at
 * this value (smb2_pread_async truncates `count` to it and issues a single
 * READ), so a caller asking for more than this gets a SHORT read, not an
 * error. Knowing the value is what lets the read-ahead size its chunks to
 * one round-trip instead of silently wasting a 4 MiB request for 64 KiB. */
JNIEXPORT jint JNICALL
Java_com_dreamplayer_app_Smb2Native_maxReadSize(JNIEnv *env, jclass cls, jlong file) {
    Smb2File *sf = to_file(file);
    if (!sf || !sf->ctx) return 0;
    return (jint)smb2_get_max_read_size(sf->ctx);
}

JNIEXPORT jstring JNICALL
Java_com_dreamplayer_app_Smb2Native_getError(JNIEnv *env, jclass cls, jlong session) {
    Smb2Session *s = to_session(session);
    if (!s || !s->ctx) return (*env)->NewStringUTF(env, "no session");
    const char *e = smb2_get_error(s->ctx);
    return (*env)->NewStringUTF(env, e ? e : "");
}

/* ---------------------------------------------------------------- file */

JNIEXPORT jlong JNICALL
Java_com_dreamplayer_app_Smb2Native_openFile(JNIEnv *env, jclass cls,
    jlong session, jstring jpath) {
    Smb2Session *s = to_session(session);
    if (!s || !s->ctx) return 0;
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    /* share-relative, backslashes, no leading separator */
    if (!path || !path[0]) {
        (*env)->ReleaseStringUTFChars(env, jpath, path);
        return 0;
    }
    char *native = dupstr(path);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    /* normalise */
    char *p = native;
    while (*p == '/') p++;
    if (!p[0]) { free(native); return 0; }
    /* convert remaining slashes */
    char *q = p;
    /* work on a copy */
    char *buf = dupstr(p);
    free(native);
    for (q = buf; *q; q++) if (*q == '/') *q = '\\';
    /* strip trailing backslashes */
    size_t L = strlen(buf);
    while (L > 0 && buf[L-1] == '\\') buf[--L] = '\0';

    struct smb2fh *fh = smb2_open(s->ctx, buf, O_RDONLY);
    free(buf);
    if (!fh) return 0;
    Smb2File *sf = (Smb2File *)calloc(1, sizeof(Smb2File));
    sf->ctx = s->ctx;
    sf->fh = fh;
    return (jlong)(intptr_t)sf;
}

JNIEXPORT void JNICALL
Java_com_dreamplayer_app_Smb2Native_closeFile(JNIEnv *env, jclass cls, jlong file) {
    Smb2File *sf = to_file(file);
    if (sf) { if (sf->fh) smb2_close(sf->ctx, sf->fh); free(sf); }
}

JNIEXPORT jlong JNICALL
Java_com_dreamplayer_app_Smb2Native_fileSize(JNIEnv *env, jclass cls, jlong file) {
    Smb2File *sf = to_file(file);
    if (!sf || !sf->fh) return -1;
    struct smb2_stat_64 st;
    memset(&st, 0, sizeof(st));
    if (smb2_fstat(sf->ctx, sf->fh, &st) < 0) return -1;
    return (jlong)st.smb2_size;
}

JNIEXPORT jint JNICALL
Java_com_dreamplayer_app_Smb2Native_readAt(JNIEnv *env, jclass cls,
    jlong file, jlong offset, jbyteArray jbuf, jint len) {
    Smb2File *sf = to_file(file);
    if (!sf || !sf->fh || !sf->ctx || len <= 0) return -1;
    jbyte *buf = (*env)->GetByteArrayElements(env, jbuf, NULL);
    ssize_t n = smb2_pread(sf->ctx, sf->fh, (uint8_t *)buf, (uint32_t)len, (uint64_t)offset);
    (*env)->ReleaseByteArrayElements(env, jbuf, buf, 0);
    if (n < 0) return -1;
    return (jint)n;
}

/* ---------------------------------------------------------------- dir */

JNIEXPORT jlong JNICALL
Java_com_dreamplayer_app_Smb2Native_openDir(JNIEnv *env, jclass cls,
    jlong session, jstring jpath) {
    Smb2Session *s = to_session(session);
    if (!s || !s->ctx) return 0;
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    char *buf = dupstr(path ? path : "");
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    char *p = buf;
    while (*p == '/') p++;
    char *out = dupstr(p);
    free(buf);
    for (char *q = out; *q; q++) if (*q == '/') *q = '\\';
    size_t L = strlen(out);
    while (L > 0 && out[L-1] == '\\') out[--L] = '\0';

    struct smb2dir *d = smb2_opendir(s->ctx, out[0] ? out : ".");
    free(out);
    if (!d) return 0;
    Smb2Dir *sd = (Smb2Dir *)calloc(1, sizeof(Smb2Dir));
    sd->ctx = s->ctx;
    sd->dir = d;
    return (jlong)(intptr_t)sd;
}

JNIEXPORT void JNICALL
Java_com_dreamplayer_app_Smb2Native_closeDir(JNIEnv *env, jclass cls, jlong dir) {
    Smb2Dir *sd = to_dir(dir);
    if (sd) { if (sd->dir) smb2_closedir(sd->ctx, sd->dir); free(sd); }
}

/* Returns a flat array: [name, isDir(0/1), size, mtimeMs] repeated. */
JNIEXPORT jobjectArray JNICALL
Java_com_dreamplayer_app_Smb2Native_readDir(JNIEnv *env, jclass cls, jlong dir) {
    Smb2Dir *sd = to_dir(dir);
    if (!sd || !sd->dir) return NULL;
    struct smb2dir *d = sd->dir;
    struct smb2_context *ctx = sd->ctx;
    /* First pass: count */
    /* We'll build a list dynamically. Use a growing array of strings + metadata. */
    /* Simpler: return Object[] where each entry is a String[] {name, isDir, size, mtime}. */
    /* Count entries first. */
    int cap = 64, n = 0;
    struct smb2dirent **ents = (struct smb2dirent **)malloc(cap * sizeof(*ents));
    struct smb2dirent *e;
    while ((e = smb2_readdir(sd->ctx, sd->dir)) != NULL) {
        if (n >= cap) { cap *= 2; ents = realloc(ents, cap * sizeof(*ents)); }
        ents[n++] = e;
    }
    jclass strArrCls = (*env)->FindClass(env, "[Ljava/lang/String;");
    jobjectArray result = (*env)->NewObjectArray(env, n, strArrCls, NULL);
    for (int i = 0; i < n; i++) {
        e = ents[i];
        jstring name = (*env)->NewStringUTF(env, e->name ? e->name : "");
        char isDir[2] = { (e->st.smb2_type == SMB2_TYPE_DIRECTORY) ? '1' : '0', 0 };
        char sizeBuf[32]; snprintf(sizeBuf, sizeof(sizeBuf), "%llu", (unsigned long long)e->st.smb2_size);
        char mtimeBuf[32]; snprintf(mtimeBuf, sizeof(mtimeBuf), "%llu", (unsigned long long)e->st.smb2_mtime);
        jstring isDirS = (*env)->NewStringUTF(env, isDir);
        jstring sizeS = (*env)->NewStringUTF(env, sizeBuf);
        jstring mtimeS = (*env)->NewStringUTF(env, mtimeBuf);
        jobjectArray row = (*env)->NewObjectArray(env, 4, (*env)->FindClass(env, "java/lang/String"), NULL);
        (*env)->SetObjectArrayElement(env, row, 0, name);
        (*env)->SetObjectArrayElement(env, row, 1, isDirS);
        (*env)->SetObjectArrayElement(env, row, 2, sizeS);
        (*env)->SetObjectArrayElement(env, row, 3, mtimeS);
        (*env)->SetObjectArrayElement(env, result, i, row);
    }
    free(ents);
    return result;
}
