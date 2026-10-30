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
# by compiling every translation unit on a Linux host before it was first run
# on a Mac. The non-obvious parts, in the order they bite:
#
#   -DHAVE_CONFIG_H          include/config.h (upstream's include/apple/config.h)
#                            carries the HAVE_* answers for Darwin.
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
  -D_U_=
)

# NOT -DHAVE_DCERPC_FULL. That flag enables the YAML/JSON DCE/RPC encodings and
# the extra LSA/WKSSVC/WinReg service modules, none of which this app uses; the
# share enumeration path is plain NDR. Leaving it off also keeps dcerpc.c from
# pulling in the MS-DTYP/ACL coders, which is what the prefix header documents
# as the minimal configuration.

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
compile() {
  unit="$1"
  shift
  [ -e "$unit" ] || return 0
  obj="$OBJ_DIR/$(echo "${unit#$SRC/}" | tr '/' '_' | sed 's/\.c$/.o/')"
  "$CC" -c "$unit" -o "$obj" "${FLAGS[@]}" "${DEFINES[@]}" "${INCLUDES[@]}" "$@"
  count=$((count + 1))
}

for unit in "$SRC"/lib/*.c "$SRC"/shim/*.c; do
  compile "$unit"
done

# libsmb2's DCE/RPC internals are renamed with a libsmb2_ prefix so they cannot
# clash with another libdcerpc in the link. smb2-share-enum.c includes that
# header itself; the units that DEFINE the functions must be compiled with it
# too, or the archive exports dcerpc_create_context while the share-enum object
# asks for libsmb2_dcerpc_create_context and the app fails to link with
# `Undefined symbol: _libsmb2_dcerpc_create_context` (build 46, 2026-10-21).
# Only these two units are needed without HAVE_DCERPC_FULL; the other
# libdcerpc modules belong to services this app never calls.
DCERPC_PREFIX_HEADER="$SRC/lib/libsmb2-dcerpc-prefix.h"
for unit in "$SRC/libdcerpc/dcerpc.c" "$SRC/libdcerpc/dcerpc-srvsvc.c"; do
  compile "$unit" -include "$DCERPC_PREFIX_HEADER"
done

echo "libsmb2: compiled $count translation units"

if [ "$count" -lt 55 ]; then
  echo "libsmb2: expected >=55 units, got $count — vendored sources look truncated" >&2
  exit 1
fi

rm -f "$OUT_DIR/libsmb2.a"
ar rcs "$OUT_DIR/libsmb2.a" "$OBJ_DIR"/*.o

# The NetrShareEnum path is the only user of DCE/RPC, and build 46 failed at the
# very end of a six-minute Xcode archive because those definitions were missing.
# Check them here instead: this step is seconds, the archive is local, and a
# missing symbol is the same finding either way. `nm -gU` on macOS lists only
# defined external symbols (note: -U means the opposite of GNU nm).
for sym in \
  libsmb2_dcerpc_call_async \
  libsmb2_dcerpc_connect_context_async \
  libsmb2_dcerpc_create_context \
  libsmb2_dcerpc_destroy_context \
  libsmb2_dcerpc_get_smb2_context \
  libsmb2_srvsvc_interface \
  libsmb2_srvsvc_NetrShareEnum_req_coder \
  libsmb2_srvsvc_NetrShareEnum_rep_coder
do
  if ! nm -gU "$OUT_DIR/libsmb2.a" 2>/dev/null | grep -qE " [A-Z] _${sym}$"; then
    echo "libsmb2: archive is missing $sym — the share enumeration path will fail to link" >&2
    exit 1
  fi
done

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

# ---------------------------------------------------------------------------
# LGPL-2.1 section 6(a): a statically linked library must be ACCOMPANIED by
# its object code, so the user can modify the Library and relink it.
#
# The archive above is a container of the object files, but the relinkable
# form is the individual .o files, and section 6 also wants the Library's
# machine-readable source and a copy of the license next to the work. So ship
# all three to the user through the app's own asset pipeline: the app copies
# this archive into its Documents directory (visible in the Files app under
# "On My iPad > DreamPlayer") and the licences screen points at it.
#
# LGPL-3.0 has an "App Store exception" that removes this obligation
# entirely; libsmb2 is LGPL-2.1, which does not have one, so the object code
# has to travel with the app.
# ---------------------------------------------------------------------------
OBJECTS_ASSET_DIR="$HERE/../assets/libsmb2-objects"
OBJECTS_ZIP="$OBJECTS_ASSET_DIR/libsmb2-objects.zip"

if [ ! -d "$OBJECTS_ASSET_DIR" ]; then
  echo "libsmb2: asset directory $OBJECTS_ASSET_DIR is missing" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/obj" "$STAGE/source"
cp "$OBJ_DIR"/*.o "$STAGE/obj/"
cp "$SRC/LICENCE-LGPL-2.1.txt" "$STAGE/"
[ -f "$SRC/COPYING" ] && cp "$SRC/COPYING" "$STAGE/"
cp -R "$SRC/lib" "$SRC/include" "$SRC/libdcerpc" "$SRC/shim" "$STAGE/source/"

cat > "$STAGE/RELINK.txt" <<'RELINK'
libsmb2 object code — relinking instructions
===========================================

This archive accompanies DreamPlayer because libsmb2 is licensed under the
GNU Lesser General Public License version 2.1 and is linked STATICALLY into
the iOS app. LGPL-2.1 section 6(a) requires the object code of the library
to accompany the work, so that you can modify libsmb2 and relink a modified
executable.

What is here
------------
  obj/                 the compiled object files (arm64 Mach-O) of every
                       libsmb2 translation unit, exactly as they were linked
                       into DreamPlayer
  source/              the complete libsmb2 sources this build was compiled
                       from, including the iOS shim and the DCE/RPC prefix
                       header
  LICENCE-LGPL-2.1.txt the license libsmb2 is distributed under
  COPYING              libsmb2's own copyright notice

Relinking
---------
1. Modify the sources under source/ (for example a bug fix).
2. Compile them with the SAME flags DreamPlayer used, so the ABI matches:

     xcrun --sdk iphoneos clang -c <file>.c -o <file>.o \
       -arch arm64 -miphoneos-version-min=17.0 -std=gnu11 -O2 -w \
       -DHAVE_CONFIG_H -D_U_= \
       -I source/include -I source/include/smb2 -I source/include/dcerpc \
       -I source/lib -I source/libdcerpc

   The two DCE/RPC units need the prefix header as well:

     ... -include source/lib/libsmb2-dcerpc-prefix.h

3. Replace the matching files in obj/ with your recompiled ones and archive
   them, or link them straight into your own application:

     ar rcs libsmb2.a obj/*.o

4. Link your application against the new archive in place of the one
   DreamPlayer ships.

DreamPlayer itself is open source under the GNU General Public License v3.0
and its own source (including the vendored libsmb2 tree and the build script
that produced these object files) is published at:

  https://github.com/mangeshghodke/DreamPlayer
RELINK

rm -f "$OBJECTS_ZIP"
( cd "$STAGE" && zip -qry "$OBJECTS_ZIP" . )
rm -rf "$STAGE"
trap - EXIT

objects_size=$(stat -f%z "$OBJECTS_ZIP" 2>/dev/null || stat -c%s "$OBJECTS_ZIP")
if [ "$objects_size" -lt 100000 ]; then
  echo "libsmb2: object-code archive is only $objects_size bytes — the LGPL-2.1 relinking material did not really get packaged" >&2
  exit 1
fi
echo "libsmb2: packaged object code for LGPL-2.1 relinking -> $OBJECTS_ZIP ($(du -h "$OBJECTS_ZIP" | cut -f1))"

