#!/usr/bin/env bash
# Builds a MINIMAL static FFmpeg (AC3 encoder only - the same encoder Kodi's
# CAEEncoderFFmpeg uses for "transcode to Dolby Digital", see
# xbmc/cores/AudioEngine/Encoders/AEEncoderFFmpeg.cpp) for Android ABIs, into
# android/app/src/main/cpp/ac3enc/prebuilt/<abi>/ so the ac3enc JNI lib can
# link it statically. Run locally before a debug build and in release.yml
# before the APKs; the prebuilt output is gitignored.
#
#   ffmpeg --disable-everything --enable-encoder=ac3
#
# yields a libavcodec with just the AC3 encoder (~1 MB), not the ~4 MB full
# decoder build that media3ext already ships.
#
# Usage: tool/build_ffmpeg_ac3.sh [ffmpeg-tag]   (default: $FFMPEG_TAG below)
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG_TAG="${1:-${FFMPEG_TAG:-n7.1.1}}"
OUT=android/app/src/main/cpp/ac3enc/prebuilt

NDK="${NDK_DIR:-$(ls -d /opt/android-sdk/ndk/* 2>/dev/null | sort -V | tail -1)}"
if [ -z "$NDK" ]; then
  echo "ERROR: no NDK found (set NDK_DIR)" >&2
  exit 1
fi
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

build_abi() {
  local arch="$1" abi="$2" clang="$3" extra="$4"
  local prefix
  prefix="$(pwd)/$OUT/$abi"
  mkdir -p "$prefix"
  if [ -f "$prefix/lib/libavcodec.a" ] && [ -f "$prefix/.tag" ] && [ "$(cat "$prefix/.tag")" = "$FFMPEG_TAG" ]; then
    echo "$abi: already at $FFMPEG_TAG, skipping"
    return 0
  fi
  local src
  src="$(mktemp -d)/ffmpeg"
  echo "$abi: cloning ffmpeg $FFMPEG_TAG ..."
  git clone --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$src" 2>&1 | tail -1
  echo "$abi: configuring + building (a few minutes) ..."
  (cd "$src" && ./configure \
      --target-os=android --arch="$arch" --cpu=generic \
      --cc="$TOOLCHAIN/$clang" --enable-cross-compile \
      --disable-everything --enable-encoder=ac3 \
      --enable-avcodec --enable-avutil --enable-swresample \
      --disable-programs --disable-doc --disable-network \
      --disable-x86asm --disable-asm \
      --disable-shared --enable-static --enable-pic \
      --prefix="$prefix" $extra \
    && make -j"$(nproc)" libavcodec/libavcodec.a libavutil/libavutil.a libswresample/libswresample.a \
    && make install-headers install-libs)
  rm -f "$prefix/lib/libswresample.a" 2>/dev/null || true
  echo "$FFMPEG_TAG" > "$prefix/.tag"
  rm -rf "$(dirname "$src")"
  ls -la "$prefix/lib"
}

build_abi aarch64 arm64-v8a aarch64-linux-android21-clang ""
build_abi arm armeabi-v7a armv7a-linux-androideabi21-clang "--cpu=armv7-a --enable-neon --extra-cflags=-mfloat-abi=softfp"

echo "done."
ls -la "$OUT"/*/lib
