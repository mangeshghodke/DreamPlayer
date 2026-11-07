# Playback engines


DreamPlayer is a video player app, but the actual video *engine* depends on
your platform. Different platforms need different engines to do what we
promise: **Dolby Vision + HDR10 passthrough to the panel, lossless audio
decoding, and a stable 4K 60 fps picture on a phone.**

| Engine | Platform | What it does | Why we picked it |
|---|---|---|---|
| **Media3 / ExoPlayer 1.10.x** | Android phone, tablet, Android TV, Fire TV | The Google-maintained Android playback engine. We use it through a **hybrid-composition `PlatformViewLink`** so the `SurfaceView` is a real SurfaceFlinger layer on the physical display. This is the only path that delivers real HDR/DV to the panel. Built on top of Media3 is our `DreamRenderersFactory` which adds the **nextlib FFmpeg audio extension** for DTS / DTS-HD / E-AC3-JOC / TrueHD / FLAC. | The only engine that does hardware Dolby Vision on Android (`c2.qti.dv.decoder` on the OnePlus, `OMX.MTK.VIDEO.DECODER.DVHE.STH` on the Fire TV) with real HDR composited on the panel. Nova Video Player, Just Player, Plex, MX Player Pro all use it. |
| **AetherEngine 7.53.x** | iOS / iPad | Native iOS playback built on AVPlayer + FFmpeg demux/decode. The AetherPlayerView exposes a `videoFormat` for `.hdr10 / .hdr10Plus / .dolbyVision`, the engine reads the container, FFmpeg fills in what AVPlayer can't (DTS / DTS-HD / TrueHD, MKV / WebM / TS / AVI containers), and the engine routes bitstream-audio over HDMI. | The only path that combines AVPlayer's hardware HDR / DV fast path on the panel with FFmpeg's container / codec coverage for non-Apple formats. iOS has no ExoPlayer port. |
| **nextlib `media3ext`** | Android (FFmpeg audio) | The Android FFmpeg extension that adds `FfmpegAudioRenderer` for DTS / DTS-HD / TrueHD / FLAC. Wired into `DreamRenderersFactory` AFTER the stock audio renderer, so it acts as a fallback for the lossless codecs. | The same FFmpeg integration Nova Video Player uses. Video stays on hardware `MediaCodecVideoRenderer`; audio falls back to FFmpeg for the formats the OS can't decode. |
| **Citadel (SwiftNIO SSH)** | iOS / iPad SFTP | Native SFTP client used by the FTP browser for SFTP playback (`FtpByteRangeSource`). | The only maintained Swift SSH client that compiles cleanly on iOS 18. |
| **libsmb2** | **Android + iOS / iPad SMB reads** | The C SMB 2/3 library behind **all** SMB playback. On iOS it also does browsing, share listing, LAN discovery and stat: discovery is a subnet sweep plus a real IPC$ handshake to report dialect and server GUID, and playback serves the engine through a synchronous `smb2_pread` reader — no async-to-sync bridging, so the deadlock class the old iOS transport hit cannot recur. On **Android** the *read* path uses it too (a JNI bridge over the same vendored sources), for both the native engine and the MPV fallback. Vendored under `ios/Runner/libsmb2`, compiled for iOS by `ios/libsmb2_build.sh` and for Android by `android/app/src/main/cpp/CMakeLists.txt`. LGPL 2.1. |
| **jcifs-ng** | Android SMB **browsing** | The Java SMB 2/3 client behind the in-app SMB browser (directory listing) and the small sidecar-subtitle fetch on Android. The bulk byte reads no longer go through it. | Nova's and CX Explorer's SMB library; measured ~75 MB/s vs ~4–6 MB/s for smbj on the NAS. Kept for browsing because it is pure Java and needs no native build step. |
| **Media3 / DefaultHttpDataSource + OkHttp** | Android HTTP(S) | Standard Media3 HTTP source (with a custom trust-all OkHttp client for self-signed WebDAV). | Reuses Media3's mature HTTP implementation; the self-signed client is opt-in per server. |
| **WebDAVByteRangeSource** (in `AetherEngineSMB`) | iOS / iPad WebDAV | A `ByteRangeSource` that serves every engine read as an independent HTTP `Range` request with the `Authorization` header, on a permissive or default-trust session. Wrapped in `BufferedSMBReader` for read-ahead. | AetherEngine's own HTTP stack can't carry auth headers or bypass TLS validation; this is the cleanest bridge between the WebDAV client and the engine. |
| **media_kit + libmpv** (hardware-first `hwdec=auto-safe`, FFmpeg software fallback; video → **native SurfaceView**) | Android, user-chosen | **Second engine**: `Play with MPV` on the details screen (or `Try with MPV` on the Media3 error surface) starts a bundled libmpv that runs hardware decoders by default and drops to its own FFmpeg software decode when the hardware can't handle a stream — so files the native engine's hardware/software path can't open (12-bit HEVC 4:4:4, corrupt containers, unknown codecs) play through FFmpeg. Video renders into `MpvSurfaceView` (hybrid-composition platform view — same pattern as Media3; **no Flutter `Texture`**, which stuttered). media_kit `Player` is control-only (`media_kit_video` removed). Configures Android AudioTrack + FFmpeg PCM output; DTS / DTS-HD / TrueHD / E-AC3 / AC3 / FLAC / AAC sources can feed the platform Spatializer when the route stays 5.1/7.1. It observes `audio-out-params` and does not enable `audio-spdif`, so encoded passthrough is not reported as spatial. Pins the container-default audio track on open and restores the user's pick on resume. Ships `libmpv.so` via `media_kit_libs_android_video` — optionally overridden by a libplacebo/`gpu-next` build under `jniLibs/` (Gradle `pickFirsts`) for HDR tone-map. Android-only, so iOS doesn't pull in `Mpv.framework` (which breaks SideStore's `ldid` signer). | The user gets a second full player for anything Media3 can't decode, without giving up hardware decode or multichannel audio. Media3 remains the DV/HDR engine; MPV can tone-map to SDR when asked. iOS does not run mpv. |
| **SmbHttpProxy** (in-app) | Android fallback over SMB | A tiny HTTP/1.1 server (ServerSocket accept loop, one daemon thread per connection, GET/HEAD + single `Range`) bound to `127.0.0.1` that serves an SMB file to the MPV engine. The bytes come out of `SmbDataSource` — the same libsmb2 reader with the parallel read-ahead ring the native engine uses — so the NAS is never on the socket's critical path and the engine sees a continuous stream instead of a gap per SMB round-trip. | libmpv can't read `smb://` directly, and Media3-native `DataSource`s are not reachable from it, so a loopback HTTP bridge is the cleanest way to let the second engine stream a share. Reading *ahead* (instead of read-then-write per round-trip) is what keeps it from reporting "buffering". |

## Why is Media3 the primary engine — and how does mpv fit?

We tried mpv earlier as the **primary** path. It is not the right choice for
the primary DV/HDR path on Android, and we deliberately do not pretend
otherwise. The two blockers for *mpv-as-primary*:

1. **Dolby Vision RPU parsing fails** on the stock mpv/FFmpeg pairing we first
   tested. Result: pink/green output. (mpv PR #16818 was the upstream fix
   attempt; it never landed for our original FFmpeg version.)
2. **Flutter textures have no HDR path** (media-kit issue #615) — so the old
   texture-based mpv path tone-mapped to SDR before the panel ever saw the
   frame. We fixed the *renderer* (mpv now uses a native SurfaceView) but
   Media3 remains the engine that does hardware DV/HDR passthrough.

So mpv is **not** the primary engine. The exit interview was: keep Media3 +
native SurfaceView for the DV/HDR fast path; ship native FFmpeg audio for the
lossless codecs; that's the same engine stack Nova Video Player uses
(ExoPlayer + FFmpeg audio) and the same one Just Player uses (stock
`DefaultRenderersFactory` + nextlib `media3ext`).

**But** mpv *is* a great second engine, and the choice is yours:

- The main Media3 engine + hardware decoders remain the default play path.
- **Play with MPV** (details screen) starts libmpv up front — hardware-first
  (`hwdec=auto-safe`) with its own FFmpeg software fallback — for anything
  you want routed through mpv's decoder coverage. Video goes to a real
  SurfaceView; the ⓘ info sheet shows `Engine · libmpv` while it's active.
- On a terminal Media3 error the error surface offers **Try with MPV** instead
  of auto-switching — the engine choice is always explicit.

Documented in `AGENTS.md → Player engine choice` and `Playback research notes`.

## Why not libVLC / other FFmpeg wrappers?

- **libVLC** — works for SD content, but VLC's Android player renders
  into a `Surface` it doesn't own. To get real HDR passthrough you'd
  need VLC's `mediacodec-hardware` decoder chain, which still doesn't
  handle the DOVI RPU correctly on most devices. The VLC-for-Android
  fork that *does* (libVLC ≥ 4.0 with the `dovi` plugin) is a 100 MB
  binary, ships its own player UI, and is licensed LGPL-2.1 (the
  App Store constraint would force us to relink it).
- **"ffmpeg-kant" / other FFmpeg wrappers** — pure-software decode on a
  phone. 4K HDR HEVC at 60 fps stutters on every Snapdragon 678 / 7
  gen 1 / 8 gen 2 device we've tested. No native hardware path.
