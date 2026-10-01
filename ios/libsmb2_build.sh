#!/usr/bin/env bash
#
# Builds libsmb2 as a static arm64 archive for the iOS app.
#
# Why a script and not CMake: the app needs one static archive with no
# dependencies, and CMake would drag in a second build system plus the whole
# toolchain-detection dance for a project we already vendor the sources of.
# `xcrun clang` is already on the runner because the Xcode build needs it.
#
# The flag set below was derived from the upstream CMakeLists and then verified
# by compiling all 61 translation units on a Linux host before it was first run
# on a Mac. The non-obvious parts, in the order they bite:
#
#   -DHAVE_CONFIG_H          include/config.h (upstream's include/apple/config.h)
#                            carries the HAVE_* answers for Darwin.
#   -DHAVE_DCERPC_FULL=1     libdcerpc/CMakeLists.txt sets this unconditionally;
#                            without it smb2-share-enum.c calls
#                            dcerpc_pdu_yaml_key() which dcerpc.c then compiles
#                            out, so the link fails on an undefined symbol.
#   -D_U_=                   aes128ccm.c marks intentionally-unused variables
#                            with OpenSSL's _U_. We do not link OpenSSL — SMB3
#                            encryption is optional and aes_apple.c uses Apple's
#                            CommonCrypto — so the macro is defined empty.
#   NO NEED_* DEFINES        NEED_READV / NEED_WRITEV / NEED_POLL /
#                            NEED_GETADDRINFO / NEED_FREEADDRINFO select the
#                            Amiga and console fallback implementations in
#                            compat.c, not the POSIX ones. Darwin has the real
#                            functions, so upstream's CMake adds none of these
#                            for Darwin/iOS either. Defining them makes compat.c
#                            fail to compile.
#   NO NEED_GETLOGIN_R       See shim/ios_shim.c: the fallback references a
#                            `login_num` variable that only exists in compat.c's
#                            Dreamcast section, so it does not compile anywhere
#                            else. The shim supplies the function instead.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/Runner/libsmb2"
OUT_DIR="$SRC/build"
OBJ_DIR="$OUT_DIR/obj"

if [ ! -d "$SRC/lib" ]; then
  echo "libsmb2 sources not found at $SRC/lib" >&2
  exit 1
fi

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN_IOS="${LIBSMB2_MIN_IOS:-17.0}"

CC="$(xcrun --sdk iphoneos --find clang)"
echo "libsmb2: compiler  $CC"
echo "libsmb2: sdk       $SDK_PATH"
echo "libsmb2: min iOS   $MIN_IOS"

rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR"

DEFINES=(
  -DHAVE_CONFIG_H
  -DHAVE_DCERPC_FULL=1
  -D_U_=
)

INCLUDES=(
  -I "$SRC/include"
  -I "$SRC/include/smb2"
  -I "$SRC/include/dcerpc"
  -I "$SRC/lib"
  -I "$SRC/libdcerpc"
)

FLAGS=(
  -arch arm64
  -isysroot "$SDK_PATH"
  -miphoneos-version-min="$MIN_IOS"
  -std=gnu11
  -O2
  -fembed-bitcode
  -w
)

count=0
for unit in "$SRC"/lib/*.c "$SRC"/libdcerpc/*.c "$SRC"/shim/*.c; do
  [ -e "$unit" ] || continue
  obj="$OBJ_DIR/$(echo "${unit#$SRC/}" | tr '/' '_' | sed 's/\.c$/.o/')"
  "$CC" -c "$unit" -o "$obj" "${FLAGS[@]}" "${DEFINES[@]}" "${INCLUDES[@]}"
  count=$((count + 1))
done

echo "libsmb2: compiled $count translation units"

if [ "$count" -lt 60 ]; then
  echo "libsmb2: expected >=60 units, got $count — vendored sources look truncated" >&2
  exit 1
fi

rm -f "$OUT_DIR/libsmb2.a"
ar rcs "$OUT_DIR/libsmb2.a" "$OBJ_DIR"/*.o

# The real link happens in Xcode, which reports anything genuinely missing far
# more clearly than a symbol scan here. Just assert the archive is non-trivial
# and arm64, so a silently empty or wrong-arch build fails in this step instead
# of much later.
size=$(stat -f%z "$OUT_DIR/libsmb2.a" 2>/dev/null || stat -c%s "$OUT_DIR/libsmb2.a")
if [ "$size" -lt 200000 ]; then
  echo "libsmb2: archive is only $size bytes — the compile step did not really run" >&2
  exit 1
fi

echo "libsmb2: built $OUT_DIR/libsmb2.a ($(du -h "$OUT_DIR/libsmb2.a" | cut -f1))"
file "$OUT_DIR/libsmb2.a"
