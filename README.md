# DreamPlayer

<p align="center">
  <img src="https://raw.githubusercontent.com/mangeshghodke/DreamPlayer/main/app_icon.png" width="200" alt="DreamPlayer icon">
</p>

[![License: GPLv3](https://img.shields.io/github/license/mangeshghodke/DreamPlayer?style=flat)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20iPad%20%7C%20Android%20TV-blue)](https://github.com/mangeshghodke/DreamPlayer)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-46A6F2?logo=flutter&logoColor=white&color=46A6F2)](https://flutter.dev)
[![Downloads](https://img.shields.io/github/downloads/mangeshghodke/DreamPlayer/total)](https://github.com/mangeshghodke/DreamPlayer/releases)
[![Donate](https://img.shields.io/badge/Donate-Razorpay-2D8CF0)](https://rzp.io/rzp/cZ5afqVG)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-Support-EA4AAA?logo=github&logoColor=white)](https://github.com/sponsors/mangeshghodke/)

A cross-platform video player for **Android, iOS/iPad, and Android TV** — built for true Dolby Vision, HDR10/HDR10+, and lossless audio playback.

## Highlights

### Dolby Vision & HDR
- Plays **Dolby Vision** Profiles **P4 / P5 / P7 / P8 / P9** at 4K 60fps with zero dropped frames — chip shows `DV P8`, `DV P7`, etc.
- Full **HDR10 / HDR10+ / HLG** passthrough to the display panel
- Live on-screen chips showing the active HDR format (profile-aware), video codec, audio codec, and resolution
- Graceful fallback on non-DV devices (P7/P8 as HDR10, P5 shows clean error)

### Lossless Audio
- All major codecs: **DTS, DTS-HD, TrueHD, E-AC3, AC3, AAC, FLAC** and more
- Mid-playback **audio track switching** with full track names and channel info
- **Default track on open** — the player picks the file's DEFAULT-flagged audio
  track (not merely the first entry in the list); **resume keeps your last pick**
  per video, per engine (Watch from beginning returns to the default)
- Optional **Media3 audio passthrough** over HDMI for Dolby Atmos / DTS:X on compatible soundbars
- **Spatial audio** (Android 13+) — the same phone Spatial-audio setting drives both Media3 and MPV; the teal chip shows when the system Spatializer can virtualize the current multichannel PCM output on wired, USB, and Bluetooth routes
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
- **SMB / NAS** — in-app SMB browser on Android; CX Explorer "Open with" handoff; cold starts fill the ring buffer before the first read and skip Matroska end-of-file cue seeks so large MKVs open fast
- **WebDAV** — browse and stream from WebDAV servers on both platforms
- **Jellyfin / Emby** — browse libraries, direct-play with auto-discovery
- **FTP / SFTP** — browse and stream from FTP servers and SSH/SFTP file hosts
- **DLNA / UPnP** — discover and play from media servers on your LAN
- **Files app "Open with"** on iPad with bookmarked folders
- Encrypted credentials (Android Keystore / iOS Keychain)

### Smart Library
- **Continue watching** — resume any partially-watched video with progress bars
- **User-added folders** — add a TV show or movie folder, get a TMDB poster and episode list; **deep recursive scan** (up to 5 levels) expands mixed containers so loose files aren't hidden behind parent cards
- **Movie-part folders stay separate** — `Das Finale 01`–`04` each get their own card with the correct per-part TMDB match
- **Manual grouping** — select cards (long-press) → Group → one grouped card with the name you choose; TV series still auto-group by name
- **Bookmark network folders to Home** — pin SMB and WebDAV folders straight from their browsers, with a colored source badge (Jellyfin/FTP/DLNA are browse-only via `+` menu)
- **Season auto-expand** — bookmarking a show expands each season into its own card (`House Season02`, `House Season03`); group manually if you want one card
- **Download to device** — download network videos for offline playback (SMB, WebDAV, HTTP, Jellyfin, UPnP)
- **Downloaded files in home grid** — completed downloads appear with a checkmark badge, tap to play
- **SIMKL watched sync** — free unlimited watch-history sync (`simkl.com`); auto-pushes finished videos and syncs watched state across devices
- **File browser** — browse device storage and play any video without importing

### Localization
- **English, Spanish, Chinese Simplified, Russian** — 504 translated strings across all 13 screens
- **Auto-detect** device language on launch; optional **Settings → General → Language** override
- Technical terms (codec names, HDR, Dolby Vision, etc.) stay English by design

### Movie Metadata (TMDB)
- Every video opens a **details screen** with poster, backdrop, synopsis, rating, genres, runtime, and cast
- Metadata auto-fetches in the background — rows show poster thumbnails before you tap
- TV episodes labeled with Season/Episode info
- "Fix match" to correct a wrong auto-match
- **Grouped screens get the full header** — backdrop hero, overview, rating, genres, cast, trailers, then the poster cards
- **Player top bar** shows the TMDB title (falls back to the file name)

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
- **Picture-in-Picture** — system-drawn transport controls (rewind, play-pause, forward) work for BOTH engines, including the libmpv engine
- **Two play engines — your choice** — every video's details screen shows **Play** (Media3) and **Play with MPV** (libmpv, Android). mpv runs hardware-first (`hwdec=auto-safe`) with its own FFmpeg software fallback and decodes lossless codecs to PCM through Android `AudioTrack`; Media3 retains optional HDMI bitstream passthrough. Video renders into a **native SurfaceView** (not a Flutter texture). Media3 remains the DV/HDR engine; the MPV path can optionally **tone-map HDR → SDR** (Settings → Player → HDR tone-map) when a libplacebo-enabled libmpv is present.
- **Anime4K for MPV (Android, opt-in)** — enable the Anime4K toggle in the MPV picture panel, then choose Mode A, B, C, A+A, B+B, or C+A. The selected preset takes effect immediately and an `Upscaled` chip is shown while active. It is limited to SDR MPV playback; HDR/DV and PiP are disabled. The bundled Anime4K v4.0.1 fast presets use legacy `vo=gpu` because they do not compile with `vo=gpu-next`/libplacebo, so libplacebo tone mapping is unavailable while enabled. The panel warns about extra GPU load, heat, battery use, and stutter.
- **Optional TheTVDB metadata** — configure a TheTVDB v4 API key in Settings → Metadata. DreamPlayer keeps TMDB as the primary source, can use TheTVDB as a fallback, and lets you choose it explicitly in Fix Match/Group Poster. Provider IDs and artwork are cached independently; SIMKL matching remains TMDB-only.

### Second engine (Android): libmpv

The TMDb details screen offers **Play with MPV** alongside the primary Play
(Media3). The libmpv engine (`media_kit` + bundled libmpv) starts
up front — no Media3 platform view — runs **hardware-first**
(`hwdec=auto-safe` over MediaCodec) and falls back to its bundled FFmpeg
software decode when the hardware can't handle a stream, so anything the
native engine's hardware/software path can't open (12-bit HEVC 4:4:4, a
corrupt container, an unknown codec) plays through FFmpeg. It drives the same
transport, seekbar, gestures, PiP, resume, chapter list, and CC sheet as
Media3, and it decodes audio through the bundled FFmpeg path before playback.
It configures Android `AudioTrack` output and keeps the source channels when
possible, so the same phone Spatial-audio setting used by Media3 can virtualize
5.1/7.1 PCM from DTS/DTS-HD, TrueHD, E-AC3, AC3, FLAC, AAC, and similar
tracks. The player observes MPV's actual output format and updates the Spatial
chip when the system setting or audio route changes. MPV's `audio-spdif` is
intentionally not enabled, so encoded bitstream passthrough is not presented
as platform spatial audio. Sidecar subtitles are added explicitly
(external > embedded priority, same rule as the main path). Audio follows the
same rules as Media3: the container's default track on open, your last pick on
resume.

**Video output is a real SurfaceView** (`MpvSurfaceView`), not media_kit's
Flutter `Texture` — textures stutter and have no HDR path. media_kit is kept
for `Player` control only; `media_kit_video` is not a dependency. A
libplacebo/`gpu-next`-enabled `libmpv.so` can be dropped under
`android/app/src/main/jniLibs/` (Gradle `pickFirsts` overrides media_kit's
stock binary) so **HDR tone-map → SDR** works for files you do not want in
native HDR.

**Anime4K (Android MPV only)** is exposed in the same in-player tune panel as
Picture. Enable **Anime4K** first; the default Mode A chain is applied, then
select Mode A, B, C, A+A, B+B, or C+A to replace the chain immediately. An
`Upscaled` chip appears while the chain is active. The bundled fast presets are
pinned to Anime4K v4.0.1; `Clamp_Highlights` and the heavier HQ variants are
not included. Only SDR MPV video is eligible, and the feature is unavailable
for HDR/Dolby Vision and PiP. The current Anime4K shaders do not compile
against the `vo=gpu-next`/libplacebo hook interface, so Anime4K temporarily
uses legacy `vo=gpu` with OpenGL. That means libplacebo tone mapping is not
available while the feature is enabled, and zero-copy hardware decode may
switch to `mediacodec-copy`. The setting is session-only; the panel warns that
per-frame GPU work increases heat, battery use, and stutter risk.

On a terminal Media3 error, the error surface offers **Try with MPV** instead
of a dead end. Media3 never auto-switches — the engine choice is always the
user's (up front, or on the error surface).

It is **not** the DV/HDR primary engine by design: Media3 still owns hardware
Dolby Vision / HDR10+ passthrough to the panel. On a stock (no-libplacebo)
libmpv build the MPV path stays SDR (tone-map setting no-ops safely); with the
custom libmpv the HDR tone-map mode can convert to SDR intentionally. iOS does
not run mpv; AetherEngine covers its own failures.

For SMB sources the mpv engine gets the file over a tiny loopback HTTP/1.1
server (`SmbHttpProxy.kt`, bound to `127.0.0.1`, byte-range aware) — jcifs-ng
only talks to Media3-native `DataSource`s, and libmpv can't read `smb://`.

### Optional metadata providers

TMDB remains the default metadata source. Settings → Metadata also accepts an
optional TheTVDB v4 API key and subscriber PIN. When enabled, TheTVDB is tried
only after TMDB fails to produce a confident automatic match; Fix Match and
Group Poster also let you choose TMDB or TheTVDB explicitly. TheTVDB results
reuse the existing title, artwork, cast, season, and episode models, while
provider-qualified IDs prevent collisions in the cache. The API key and optional
PIN are stored in Android Keystore-backed storage or the iOS Keychain; legacy
values are migrated at startup, and Android excludes the legacy Dart preferences
file from backup. SIMKL synchronization continues to use TMDB IDs only.

TheTVDB artwork and episode data remain subject to TheTVDB's API terms and
attribution requirements. See [TheTVDB](https://thetvdb.com/) for details. This
product uses the TheTVDB API but is not endorsed by TheTVDB. TheTVDB is
currently the supported external provider; adult-content providers such as AVDB
are intentionally not enabled.

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
| **media_kit + libmpv** (hardware-first `hwdec=auto-safe`, FFmpeg software fallback; video → **native SurfaceView**) | Android, user-chosen | **Second engine**: `Play with MPV` on the details screen (or `Try with MPV` on the Media3 error surface) starts a bundled libmpv that runs hardware decoders by default and drops to its own FFmpeg software decode when the hardware can't handle a stream — so files the native engine's hardware/software path can't open (12-bit HEVC 4:4:4, corrupt containers, unknown codecs) play through FFmpeg. Video renders into `MpvSurfaceView` (hybrid-composition platform view — same pattern as Media3; **no Flutter `Texture`**, which stuttered). media_kit `Player` is control-only (`media_kit_video` removed). Configures Android AudioTrack + FFmpeg PCM output; DTS / DTS-HD / TrueHD / E-AC3 / AC3 / FLAC / AAC sources can feed the platform Spatializer when the route stays 5.1/7.1. It observes `audio-out-params` and does not enable `audio-spdif`, so encoded passthrough is not reported as spatial. Pins the container-default audio track on open and restores the user's pick on resume. Ships `libmpv.so` via `media_kit_libs_android_video` — optionally overridden by a libplacebo/`gpu-next` build under `jniLibs/` (Gradle `pickFirsts`) for HDR tone-map. Android-only, so iOS doesn't pull in `Mpv.framework` (which breaks SideStore's `ldid` signer). | The user gets a second full player for anything Media3 can't decode, without giving up hardware decode or multichannel audio. Media3 remains the DV/HDR engine; MPV can tone-map to SDR when asked. iOS does not run mpv. |
| **SmbHttpProxy** (in-app) | Android fallback over SMB | A tiny HTTP/1.1 server (ServerSocket accept loop, one daemon thread per connection, GET/HEAD + single `Range`) bound to `127.0.0.1` that hands out a jcifs-ng `SmbRandomAccessFile` per token. Idle handles are parked in an `ArrayDeque` per file. | jcifs-ng only talks to Media3-native `DataSource`s, and libmpv can't read `smb://` directly — the loopback bridge is the cleanest way to let the fallback engine stream SMB sources without re-plumbing the network stack. |

### Why is Media3 the primary engine — and how does mpv fit?

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
3. The current output is decoded multichannel PCM (typically 5.1/7.1); the
   source codec itself is not the deciding factor.

Both Media3 and MPV use the same Android phone setting. MPV decodes DTS/DTS-HD,
TrueHD, E-AC3, AC3, FLAC, AAC, and similar tracks to PCM through
`AudioTrack`; the Spatial chip is shown only when that output remains eligible
for the active route. Stereo/downmixed output and encoded bitstream passthrough
are not platform-spatialized.

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

Prebuilt **Android** binaries are on the [Releases](https://github.com/mangeshghodke/DreamPlayer/releases) page.

- **Android** — universal APK + per-architecture APKs (arm64, armv7, x86_64)

**iOS / iPadOS** — no `.ipa` is published here. Apple only allows distribution via the **App Store**, **TestFlight**, or **Ad Hoc** (DPLA 7.6 / 3.2(g)), so GitHub Releases are Android-only. Signed iOS builds are produced by the separate [`ios.yml`](https://github.com/mangeshghodke/DreamPlayer/actions/workflows/ios.yml) workflow and uploaded to **TestFlight**.

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
