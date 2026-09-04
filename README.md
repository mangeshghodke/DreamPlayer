# DreamPlayer

<p align="center">
  <img src="https://raw.githubusercontent.com/mangeshghodke/DreamPlayer/main/app_icon.png" width="200" alt="DreamPlayer icon">
</p>

[![License: GPLv3](https://img.shields.io/github/license/mangeshghodke/DreamPlayer?style=flat)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20iPad%20%7C%20Android%20TV-blue)](https://github.com/mangeshghodke/DreamPlayer)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-46A6F2?logo=flutter&logoColor=white&color=46A6F2)](https://flutter.dev)
[![iOS build](https://img.shields.io/github/actions/workflow/status/mangeshghodke/DreamPlayer/ios.yml?label=iOS%20build)](https://github.com/mangeshghodke/DreamPlayer/actions/workflows/ios.yml)
[![Donate](https://img.shields.io/badge/Donate-Razorpay-2D8CF0)](https://rzp.io/rzp/cZ5afqVG)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-Support-EA4AAA?logo=github&logoColor=white)](https://github.com/sponsors/mangeshghodke/)
![Vibe Coded](https://img.shields.io/badge/vibe--coded-100%25-8A2BE2)

A cross-platform video player for **Android, iOS/iPad, and Android TV** — built for true Dolby Vision, HDR10/HDR10+, and lossless audio playback.

> **This project is 100% vibe coded** — designed, directed, and tested by a human;
> written end-to-end in collaboration with AI coding agents, one feature at a time.
> Every feature ships only after real on-device verification.

## Highlights

### Dolby Vision & HDR
- Plays **Dolby Vision** Profiles **P4 / P5 / P7 / P8 / P9** at 4K 60fps with zero dropped frames — chip shows `DV P8`, `DV P7`, etc.
- Full **HDR10 / HDR10+ / HLG** passthrough to the display panel
- Live on-screen chips showing the active HDR format (profile-aware), video codec, audio codec, and resolution
- Graceful fallback on non-DV devices (P7/P8 as HDR10, P5 shows clean error)

### Lossless Audio
- All major codecs: **DTS, DTS-HD, TrueHD, E-AC3, AC3, AAC, FLAC** and more
- Mid-playback **audio track switching** with full track names and channel info
- Optional **audio passthrough** over HDMI for Dolby Atmos / DTS:X on compatible soundbars
- **Spatial audio** (Android 13+) — teal chip shows when the system Spatializer virtualizes multichannel surround for your headphones/speakers; works with wired, USB, and Bluetooth output
- **Bass Boost** — Off/Low/Medium/High session-level DSP that restores the low-end HRTF virtualization thins out (appears while Spatial audio is engaged)
- **Volume Boost + Night Mode** — up to 3× loudness lift and dynamic-range compression (Android)

### Subtitles
- **Embedded + sideloaded** — every subtitle file next to the video auto-attaches
- **Network-share sidecars** — `.srt`/`.ass`/`.vtt`/`.sub`/`.ttml`/`.smi`/`.mpl2` files
  in the same SMB / WebDAV / FTP folder as the video are auto-discovered and
  attached as external tracks. The best filename match is auto-selected
  (`Show.S01E01.eng.srt` matches `Show.S01E01.mkv`). Works on Android for
  every network source — local files, SMB shares, WebDAV servers, FTP/SFTP
  servers, Jellyfin libraries, and "Open with" hand-offs. iOS supports the
  same behaviour for local files (via `AetherPlayerView`); server-side
  external sub discovery for WebDAV/FTP on iOS is on the roadmap.
- **Priority: sidecar > server external > embedded.** The first sidecar
  match is flagged as the default track; the rest are reachable from the
  CC button. When a folder has zero matches, the player falls back to the
  container's embedded track automatically.
- **Fallback-engine subs** — the libmpv fallback engine has the same priority
  rule. External subs are added with `sub-add` (non-defaults) and
  `setSubtitleTrack` (default), so mpv's track-list mirrors the Media3 path
  and the CC sheet shows every track by real filename.
- Supports SRT, SSA/ASS, WebVTT, TTML, SAMI, MicroDVD, MPL2, SubViewer
- Full track picker with Off option; subtitles are anchored to the video, not the screen
- **Appearance settings** — size, color, background, outline, and sync delay with live preview (in the player's ⋮ menu; delay live on Android via `DelayingParser` + reopen)
- **OpenSubtitles** — search/download from CC (5/day anon, 20/day free login); Nova-based language catalog (full names, 3-letter `eng/fre/pob/zho`, `zh-CN/zh-TW`) for reading + download prefs + text encoding (CP1250…CP949)

### Network Playback
- **SMB / NAS** — in-app SMB browser on Android; CX Explorer "Open with" handoff
- **WebDAV** — browse and stream from WebDAV servers on both platforms
- **Jellyfin / Emby** — browse libraries, direct-play with auto-discovery
- **FTP / SFTP** — browse and stream from FTP servers and SSH/SFTP file hosts
- **DLNA / UPnP** — discover and play from media servers on your LAN
- **Files app "Open with"** on iPad with bookmarked folders
- Encrypted credentials (Android Keystore / iOS Keychain)

### Smart Library
- **Continue watching** — resume any partially-watched video with progress bars
- **User-added folders** — add a TV show or movie folder, get a TMDB poster and episode list
- **Bookmark any network folder to Home** — pin SMB, WebDAV, FTP, or DLNA folders straight from their browsers, with a colored source badge
- **Jellyfin folders in the home library** — server shows sit alongside local folders
- **SIMKL watched sync** — free unlimited watch-history sync (`simkl.com`); auto-pushes finished videos and syncs watched state across devices
- **File browser** — browse device storage and play any video without importing

### Movie Metadata (TMDB)
- Every video opens a **details screen** with poster, backdrop, synopsis, rating, genres, runtime, and cast
- Metadata auto-fetches in the background — rows show poster thumbnails before you tap
- TV episodes labeled with Season/Episode info
- "Fix match" to correct a wrong auto-match

### Player Controls
- Play/pause, seek, ±10s, fullscreen, auto-hiding UI
- **Swipe gestures** — swipe left side for brightness, right side for system volume (phones/tablets, togglable in Settings)
- Aspect ratio picker: Fit, Crop, Stretch, 16:9, 4:3 (persists per video)
- **Chapters** — MKV chapter ticks in the overflow menu, current chapter highlighted, tap to seek
- **Playback speed** 0.25×–2× with refresh-rate matching on Android
- **Pinch-to-zoom**, horizontal-swipe seek, double-tap-to-seek ±10 s
- **Touch lock** — locks gestures during playback; tap once to reveal the unlock button
- **Watched marks** — videos auto-mark as watched at the end; toggle manually per row
- **Auto-play next episode** within the same folder — local/SMB + **Jellyfin via ParentId sibling walk** (togglable)
- Resumes playback from where you left off, even after app close or screen lock
- **Picture-in-Picture** — system-drawn transport controls (rewind, play-pause, forward) work for BOTH engines, including the libmpv engine (where the video is a Flutter texture that receives no touches in pip)
- **Two play engines — your choice** — every video's details screen shows **Play** (Media3) and **Play with MPV** (libmpv, Android). mpv runs hardware-first (`hwdec=auto-safe`) with its own FFmpeg software fallback, plus Dolby Atmos / DTS-HD / TrueHD audio passthrough. SDR-only by design (Flutter textures have no HDR path) — Media3 keeps the DV/HDR goal.

### Second engine (Android): libmpv

The TMDb details screen offers **Play with MPV** alongside the primary Play
(Music to Media3). The libmpv engine (`media_kit` + bundled libmpv) starts
up front — no Media3 platform view — runs **hardware-first**
(`hwdec=auto-safe` over MediaCodec) and falls back to its bundled FFmpeg
software decode when the hardware can't handle a stream, so anything the
native engine's hardware/software path can't open (12-bit HEVC 4:4:4, a
corrupt container, an unknown codec) plays through FFmpeg. It drives the same
transport, seekbar, gestures, PiP, resume, chapter list, and CC sheet as
Media3, and its `_configureMpvAudio` hands the OS compressed passthrough
(`audio-spdif=ac3,eac3,dts,dts-hd,truehd`; AudioTrack output) for Dolby Atmos
/ DTS-HD / DTS / AC3 / TrueHD — PCM-decoding automatically when the output
can't take a bitstream. Sidecar subtitles are added explicitly
(external > embedded priority, same rule as the main path).

On a terminal Media3 error, the error surface offers **Try with MPV** instead
of a dead end. Media3 never auto-switches — the engine choice is always the
user's (up front, or on the error surface).

It **cannot** do DV/HDR by design: a Flutter texture has no HDR path on any
platform, so the Media3 engine keeps the project goal. iOS does not run mpv;
AetherEngine covers its own failures.

For SMB sources the mpv engine gets the file over a tiny loopback HTTP/1.1
server (`SmbHttpProxy.kt`, bound to `127.0.0.1`, byte-range aware) — jcifs-ng
only talks to Media3-native `DataSource`s, and libmpv can't read `smb://`.

### Android TV / Fire TV
- Full 10-foot UI with D-pad navigation and custom focus highlights
- Leanback launcher banner
- Dolby Vision + HDR10 passthrough to the TV panel
- Audio passthrough for Atmos/DTS:X over HDMI
- Tested on Amazon Fire TV Stick 4K (Fire OS 7.1)

## Engines Used

DreamPlayer is a video player app, but the actual video *engine* depends on
your platform. Different platforms need different engines to do what we
promise: **Dolby Vision + HDR10 passthrough to the panel, lossless audio
decoding, and a stable 4K 60 fps picture on a phone.**

| Engine | Platform | What it does | Why we picked it |
|---|---|---|---|
| **Media3 / ExoPlayer 1.10.x** | Android phone, tablet, Android TV, Fire TV | The Google-maintained Android playback engine. We use it through a **hybrid-composition `PlatformViewLink`** so the `SurfaceView` is a real SurfaceFlinger layer on the physical display. This is the only path that delivers real HDR/DV to the panel. Built on top of Media3 is our `DreamRenderersFactory` which adds the **nextlib FFmpeg audio extension** for DTS / DTS-HD / E-AC3-JOC / TrueHD / FLAC. | The only engine that does hardware Dolby Vision on Android (`c2.qti.dv.decoder` on the OnePlus, `OMX.MTK.VIDEO.DECODER.DVHE.STH` on the Fire TV) with real HDR composited on the panel. Nova Video Player, Just Player, Plex, MX Player Pro all use it. |
| **AetherEngine 6.38.x** | iOS / iPad | Native iOS playback built on AVPlayer + FFmpeg demux/decode. The AetherPlayerView exposes a `videoFormat` for `.hdr10 / .hdr10Plus / .dolbyVision`, the engine reads the container, FFmpeg fills in what AVPlayer can't (DTS / DTS-HD / TrueHD, MKV / WebM / TS / AVI containers), and the engine routes bitstream-audio over HDMI. | The only path that combines AVPlayer's hardware HDR / DV fast path on the panel with FFmpeg's container / codec coverage for non-Apple formats. iOS has no ExoPlayer port. |
| **nextlib `media3ext`** | Android (FFmpeg audio) | The Android FFmpeg extension that adds `FfmpegAudioRenderer` for DTS / DTS-HD / TrueHD / FLAC. Wired into `DreamRenderersFactory` AFTER the stock audio renderer, so it acts as a fallback for the lossless codecs. | The same FFmpeg integration Nova Video Player uses. Video stays on hardware `MediaCodecVideoRenderer`; audio falls back to FFmpeg for the formats the OS can't decode. |
| **Citadel (SwiftNIO SSH)** | iOS / iPad SFTP | Native SFTP client used by the FTP browser for SFTP playback (`FtpByteRangeSource`). | The only maintained Swift SSH client that compiles cleanly on iOS 17. |
| **jcifs-ng** | Android SMB | The Java SMB 2/3 client used by the in-app SMB browser + `SmbDataSource` (custom ExoPlayer `DataSource` that streams from the share). | Nova's and CX Explorer's SMB library; measured ~75 MB/s vs ~4–6 MB/s for smbj on the NAS. |
| **Media3 / DefaultHttpDataSource + OkHttp** | Android HTTP(S) | Standard Media3 HTTP source (with a custom trust-all OkHttp client for self-signed WebDAV). | Reuses Media3's mature HTTP implementation; the self-signed client is opt-in per server. |
| **WebDAVByteRangeSource** (in `AetherEngineSMB`) | iOS / iPad WebDAV | A `ByteRangeSource` that serves every engine read as an independent HTTP `Range` request with the `Authorization` header, on a permissive or default-trust session. Wrapped in `BufferedSMBReader` for read-ahead. | AetherEngine's own HTTP stack can't carry auth headers or bypass TLS validation; this is the cleanest bridge between the WebDAV client and the engine. |
| **media_kit + libmpv** (hardware-first `hwdec=auto-safe`, FFmpeg software fallback) | Android, user-chosen | **Second engine**: `Play with MPV` on the details screen (or `Try with MPV` on the Media3 error surface) starts a bundled libmpv that runs hardware decoders by default and drops to its own FFmpeg software decode when the hardware can't handle a stream — so files the native engine's hardware/software path can't open (12-bit HEVC 4:4:4, corrupt containers, unknown codecs) play through FFmpeg. Renders into a Flutter `Texture` via media_kit's `VideoController` and drives the same player UI as the main engine. Configures AudioTrack + `audio-spdif` passthrough for Atmos / DTS-HD / DTS / AC3 / TrueHD (PCM fallback when the sink can't). Ships `libmpv.so` via `media_kit_libs_android_video` — Android-only, so iOS doesn't pull in `Mpv.framework` (which breaks SideStore's `ldid` signer). | The user gets a second full player for anything Media3 can't decode, without giving up hardware decode or multichannel audio. Cannot do DV/HDR (Flutter textures have no HDR path), so the Media3 engine keeps the project goal. iOS does not run mpv. |
| **SmbHttpProxy** (in-app) | Android fallback over SMB | A tiny HTTP/1.1 server (ServerSocket accept loop, one daemon thread per connection, GET/HEAD + single `Range`) bound to `127.0.0.1` that hands out a jcifs-ng `SmbRandomAccessFile` per token. Idle handles are parked in an `ArrayDeque` per file. | jcifs-ng only talks to Media3-native `DataSource`s, and libmpv can't read `smb://` directly — the loopback bridge is the cleanest way to let the fallback engine stream SMB sources without re-plumbing the network stack. |

### Why is Media3 the primary engine — and how does mpv fit?

We tried mpv earlier. It is not the right choice for the **primary** DV/HDR
path on Android, and we deliberately do not pretend otherwise. The two
blockers:

1. **Dolby Vision RPU parsing fails.** mpv v0.36 + FFmpeg 6.0 cannot read the
   DOVI configuration record in DV P8 MKVs. Result: pink/green output. (mpv
   PR #16818 was the upstream fix attempt; it never landed for our FFmpeg
   version.)
2. **No HDR to the panel.** `media_kit` renders into a Flutter texture.
   Flutter textures have **no HDR path on any platform** (media-kit issue
   #615). The decoded HDR10 buffer is tone-mapped to SDR before the panel
   ever sees it — so even when mpv *decodes* HDR10 correctly, the user
   sees washed-out colors.

So mpv is **not** the primary engine. The exit interview was: keep Media3 +
native SurfaceView for the DV/HDR fast path; ship native FFmpeg audio for the
lossless codecs; that's the same engine stack Nova Video Player uses
(ExoPlayer + FFmpeg audio) and the same one Just Player uses (stock
`DefaultRenderersFactory` + nextlib `media3ext`).

**But** mpv *is* a great second engine, and the choice is yours:

- The main Media3 engine + hardware decoders remain the default play path.
- **Play with MPV** (details screen) starts libmpv up front — hardware-first
  (`hwdec=auto-safe`) with its own FFmpeg software fallback — for anything
  you want routed through mpv's decoder coverage. The ⓘ info sheet shows
  `Engine · libmpv` while it's active.
- On a terminal Media3 error the error surface offers **Try with MPV** instead
  of auto-switching — the engine choice is always explicit.

Documented in `AGENTS.md → Player engine choice` and `Playback research notes`.

### Why not libVLC / other FFmpeg wrappers?

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

## Spatial Audio on Android

DreamPlayer surfaces the **system Spatializer** (Android 13+,
`AudioManager.getSpatializer()`) as a teal **"Spatial"** chip in the
player top bar. When the chip is on, your phone is virtualizing the
surround mix for your output device (stereo headphones, phone speaker,
or a USB DAC). The Spatializer is implemented by the OEM, so the
quality / available modes vary by device. The chip turns on only when
the system reports:

1. The Spatializer is available on this device.
2. The current routing (headphones, USB, etc.) supports spatialization.
3. The currently-playing audio track is multichannel (≥ 6 channels for
   surround, ≥ 8 for Atmos).

To enable spatial audio in DreamPlayer:

1. **Connect headphones or a USB DAC.** Phone speakers don't get
   spatialized on most devices.
2. **Open the file you want to play.** A multichannel track is required
   — a stereo `.aac` won't engage the Spatializer.
3. **Enable system spatial audio:**
   - **OnePlus / OPPO** — Settings → Sound & vibration → Spatial Audio
     → enable, then choose "Music & Video". On ColorOS 13+ this is
     under Settings → Sound & vibration → Dolby Atmos / OPlus Audio.
   - **Samsung (One UI 6+)** — Settings → Sounds and vibration → Sound
     quality and effects → Dolby Atmos for games / movies, **and**
     "Adapt Sound" / "Dolby Atmos for headphones" if you're on the
     built-in speakers. The Spatializer only reports available when
     "Dolby Atmos" is on.
   - **Xiaomi (MIUI 14+)** — Settings → Sound & vibration → Sound
     effects → Immersive Sound / Dolby Atmos. On some MIUI builds the
     option is under "Audio tuner" → "Apply sound effects to media".
   - **Pixel (Android 14+)** — Settings → Sound & vibration → Spatial
     audio. The Pixel implementation is limited; some Pixels only
     spatialize on specific Bluetooth codecs (LDAC / aptX Adaptive).
   - **Nothing OS / Motorola / ASUS ZenUI** — most ship with the
     Spatializer disabled. Install **Dirac Audio** / **Dolby Access** /
     your OEM's audio app and enable spatialization from there; the
     system Spatializer reports available once the OEM app is active.
4. **Look for the "Spatial" chip in the player top bar.** When the
   Spatializer is on for the current track the chip turns teal. Tap
   the **ⓘ** button next to the title — the "Spatial audio" row reads
   "On" with the routing info.

The chip is Android-only. iOS uses Apple's own spatial audio for Atmos
content on the native AVPlayer path; the system toggles it from Control
Center → AirPlay / Head-tracking, not from inside any third-party app.

## Requirements

| Platform | Minimum version |
|---|---|
| Android | 5.0 (API 21) |
| iOS / iPadOS | 17.0 |

## Download

Prebuilt binaries are on the [Releases](https://github.com/mangeshghodke/DreamPlayer/releases) page.

- **Android** — universal APK + per-architecture APKs (arm64, armv7, x86_64)
- **iOS / iPadOS** — unsigned IPA; sideload with [SideStore](https://sidestore.io) or [AltStore](https://altstore.io)

### Installing on iPhone / iPad

1. Install [SideStore](https://sidestore.io) or [AltStore](https://altstore.io) on your device
2. Download `DreamPlayer-*.ipa` from the [latest release](https://github.com/mangeshghodke/DreamPlayer/releases)
3. Open SideStore/AltStore → **+** → select the IPA
4. The 7-day signature auto-refreshes over Wi-Fi

## Getting Started

```bash
flutter pub get
flutter run                    # run on a connected device
flutter test                   # run tests
flutter analyze                # static analysis
```

For TMDB metadata, copy `.env.example` to `.env` and add your API key:

```bash
flutter run --dart-define-from-file=.env
```

## License

Copyright (C) 2026 Mangesh Ghodke. Released under the [GNU General Public License v3.0](LICENSE).

## Support

If DreamPlayer is useful to you, consider supporting the project:

- [Razorpay](https://rzp.io/rzp/cZ5afqVG) — UPI, cards, or netbanking (India)
- [GitHub Sponsors](https://github.com/sponsors/mangeshghodke/) — recurring support

Both are also in the app under **Settings → Support**.
