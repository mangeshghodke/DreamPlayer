# DreamPlayer

A cross-platform video player built with Flutter.

## Goal

A video player app supporting:
- **Android** (primary, tested on user's Android phone — CPH2573, Android 16) and **iOS/iPad** (user's iPad Pro M2)
- **All audio codecs**: DTS, DTS-HD, E-AC3, AC3, TrueHD, etc.
- **Dolby Vision** where the display supports it
- **FFmpeg-based** decoding engine

## Current status

- **Episode rows rebuilt (issue #38, 0.5.1+25, user-verified)**: one shared
  `EpisodeRow` replaces 9 copies of the row across the season, folder, SMB,
  WebDAV, Jellyfin, FTP, UPnP, file-browser and details screens, with a
  Small/Medium/Large setting (Settings -> Layout -> Episode thumbnails) that is
  **responsive** - resolved from the row's own `LayoutBuilder` constraints, so
  it adapts to rotation, split screen, font scale and tablets. Per-episode TMDB
  stills are now fetched lazily (throttled 3 at a time) **and** prefetched,
  because the season endpoint carries no stills. Offline titles fall back to
  `S01E05` instead of the show name. See the roadmap section for the five traps
  (the 56px `ListTile` leading cap in particular).
- App **UI skeleton** done (library, player, settings; dark theme).
- **iOS signed build + TestFlight upload working (2026-09-19)**: `ios.yml` workflow builds, signs, and uploads to App Store Connect via `flutter build ipa` + `ios/signing_setup.py`. Bundle ID: `com.dreamplayer.app`. First TestFlight build (0.4.7) uploaded successfully.
- **HDR / codec on-screen display** done (Dolby Vision, HDR10+, HDR10, SDR; E-AC3, DTS-HD, TrueHD, AAC, ...).
- **Responsive layout** — no overflow on phones/tablets/landscape/large text.
- **Native refresh rate** selected at startup (verified 120 Hz on device).
- **MPV default audio + resume restore (2026-09-23, 0.4.8)**: on open, pin the
  container DEFAULT-flagged track (`pickMpvDefaultAudioId` + raw
  `track-list/<n>/default` probe); latch only after a real selection. User picks
  persist per video + engine via `AudioTrackStore`; "Watch from beginning"
  clears. Unit tests: `test/mpv_audio_select_test.dart`,
  `test/audio_track_store_test.dart`.
- **SMB cold-start fix (2026-09-23, user-verified)**: secondary handles open
  outside `ringLock`, synchronous head/tail prefill in `SmbDataSource.open`,
  `MultiplexDataSource` reuses the same-URI SMB/FTP delegate. Large MKV over
  NAS no longer stalls at open. `FLAG_DISABLE_SEEK_FOR_CUES` was trialed in
  0.4.8 and **removed in 0.4.9** — it broke seeking for every MKV (issue #25).
- **Media3 seek regression fix (2026-09-24, 0.4.9, issue #25)**: double-tap
  +10 s and seekbar both jumped to 00:00 on Media3 (MPV ok) on OnePlus 12R /
  Pad 2 for all files. Global `MatroskaExtractor.FLAG_DISABLE_SEEK_FOR_CUES`
  was the cause — it strips the `Cues` timestamp→byte index. Fix: remove the
  flag (`ExoPlayerView.kt:415`); cold-start is now covered by
  `MultiplexDataSource` + sync prefill.
- **Filename-season grouping + metadata fix (2026-09-24, issue #26,
  user-verified)**: conservative Home grouping now merges same-source folders
  whose names carry explicit season tags (`S1`/`S2`, `Season01`/`Season02`) while
  keeping every physical `LibraryFolder`, name, and metadata key intact. Explicit
  `SxxEyy`/`1xYY` seasons win per episode over conflicting `folderSeason`;
  `E01`/`[01]` retain fallback behavior. Komi-san canonicalizes to TMDB's
  `Komi Can't Communicate`, restoring poster + episode stills. GuP Finale 01–04
  stay four independent movie cards and retain their existing TMDB part matches.
- **Optional TheTVDB metadata provider (2026-09-24, 0.4.9+36)**: TMDB remains
  the primary provider; TheTVDB v4 can be configured in Settings as a fallback
  when TMDB has no confident match, or selected explicitly from Fix Match/Group
  Poster. Provider-qualified IDs, artwork, seasons, episodes, and cast use the
  existing metadata cache. Credentials use platform secure storage (Android
  Keystore-backed preferences / iOS Keychain); SIMKL remains TMDB-only. Android
  analysis, the full 364-test suite, and the arm64 debug APK build pass; live
  TheTVDB API validation still needs a key.
- **MPV picture controls (2026-09-24, issue #24, user-verified)**: an MPV-only
  tune button beside the player info button opens a translucent in-player panel
  for session-only Brightness, Contrast, Saturation, Gamma, and Reset. Values
  are applied through MPV's native equalizer properties, not Flutter filters;
  the controls are hidden for Media3 and PiP, and reapply after surface changes.
- **MPV SurfaceView path Phase 1+2 in tree (2026-09-23)**: `media_kit_video`
  removed; video → `MpvSurfaceView` (hybrid composition). Custom `libmpv.so`
  may live in `android/app/src/main/jniLibs/` (Gradle `pickFirsts`). See
  roadmap "MPV without media_kit" for gates.
- **DOLBY VISION PLAYBACK WORKS on Android via ExoPlayer/Media3 PlatformView.**
  Verified on-device: the DV P8 test file (`dolby-vision-people`) decodes on the
  Qualcomm hardware **`c2.qti.dv.decoder`** at 4K 3840x2160@60 fps with zero
  dropped frames, correct colors (no mpv pink/green), audio via
  `c2.dolby.eac3.decoder` / Media3 `FFmpegAudioRenderer`. Implementation:
  native `SurfaceView` PlayerView in a Flutter **hybrid-composition** platform
  view (`lib/services/exo_player.dart` `PlatformViewLink` +
  `PlatformViewsService.initExpensiveAndroidView`) so the SurfaceView is a real
  SurfaceFlinger layer on the physical display → real HDR to the display +
  `MethodChannel`/`EventChannel` per view. `ExoPlayerController.open()` issued
  before the platform view attaches is queued and flushed in `_attach`.
  **VIRTUAL-DISPLAY gotcha (2026-08, the REAL HDR blocker)**: the stock
  `AndroidView` widget has NO hybrid composition — it uses Flutter's
  **virtual-display + texture** pipeline (`TextureAndroidViewController`). The
  video's `SurfaceView` is composited into a non-HDR virtual display
  (`flutter-vd#1` in `dumpsys SurfaceFlinger`, max 500 nits, `HWC Support:
  dv=false`), read back as a texture, and that SDR-flattened buffer is what
  reaches the panel. Real HDR is physically impossible through that path — no
  amount of window color mode / headroom / dataspace forcing helps; the video
  layer reports `forceClientComposition=true clientType=UNSUPPORTDATASPACE`
  `whitePointNits=-1` and colors come out washed out. **Just Player (a pure
  native Activity) device-composites the same file (`forceClientComposition=false
  whitePointNits=1249.99`) — same decoder, same dataspace, same metadata.** The
  fix: render the platform view with hybrid composition (`PlatformViewLink` +
  `initExpensiveAndroidView`, i.e. HC). Verified on-device after the switch:
  `flutter-vd#1` gone, video layer `composition type=DEVICE`,
  `dataspace=BT2020_ITU_PQ` `hdr metadata types=9`, buffer format
  `Y_CBCR_420_TP10_UBWC` (10-bit PQ), display output `whitePointNits=1249.99`,
  display color mode `DISPLAY_P3` — byte-for-byte the Just Player profile, and
  colors match on screen. (Flutter HC is "expensive" (\> a view-composition
  host) but is the standard hybrid path; HCPP `initHybridAndroidView` needs
  Vulkan + API 34 and is not used.)
  **Gotcha fixed:** the backend must `setState` after creating the controller,
  or the buttons/video layer stay frozen in the pre-init state.
  **HDR10 passthrough re-verified alongside DV (2026-08)**: the HDR10 file
  (`Dolby-Core-Universe-Lossless-Uhd`, HEVC Main10/BT.2020/SMPTE ST 2084)
  decodes on `c2.qti.hevc.decoder` at 4K 3840x2112@24 fps with zero discard, and
  `dumpsys SurfaceFlinger` shows the DreamPlayer `SurfaceView` layer composited
  as `dataspace=BT2020_ITU_PQ` with `hdr metadata types=3` (HDR10 static + HDR10+
  dynamic), `forceClientComposition=true clientType=UNSUPPORTDATASPACE` (handed
  to the display, not GPU tone-mapped) and the display output layer fed
  BT2020_PQ at `dimmingRatio=1.0`. The DV P8 file likewise composites as
  `BT2020_PQ` with `hdr metadata types=8` (DV decoder outputs the base
  HDR10-compatible layer). Panel: `supportedHdrTypes=[1,2,3,4]`,
  `  mMaxLuminance=1400`. (The `IMAX_SONIC_ANTHEM` mkv is actually SDR h264/BT.709
  despite the name — its BT709 layer is correct.)
  **HDR EDR ramp engaged (2026-08, OnePlus)**: with the passthrough working, the
  display was STILL not boosting — bright PQ skies clipped flat to white.
  Root cause: OPLUS only enters HDR mode when the *window* asks for headroom.
  `ExoPlayerView.applyHdrHeadroom` now (1) sets `window.setDesiredHdrHeadroom(5.0)`
  for PQ/HLG content (incl. DV base layer) — the SurfaceView-layer API puts the
  ratio on the video layer where OPLUS ignores it for the EDR ramp; (2) switches
  the window to `ActivityInfo.COLOR_MODE_HDR` (OPLUS gates the headroom/EDR ramp
  on the window layer being in HDR color mode — Nova's dump shows DISPLAY_P3 +
  ratio, ours stayed V0_SRGB which is why headroom alone did nothing); (3) sets
  the video surface's dataspace CONSUMER-side via
  `SurfaceControl.Transaction.setDataSpace` (without it OPLUS HWC reports
  `UNSUPPORTDATASPACE` and SF falls back to client composition, which never
  engages the EDR boost — `current hdr/sdr ratio` stuck at 1.0). Verified
  on-device with the HDR10+ "lake" clip: `desired hdr/sdr ratio=5.0` on the
  window layer, SDR UI dimmed, video layer device-composited with the ratio
  ramping, no more white clipping. **DV-without-Colour-element gotcha (2026-08)**:
  some DV profile-7/8 MKVs omit the MKV `Colour` element — the PQ/BT.2020 info
  lives only in the HEVC SPS VUI (ffprobe parses it, Media3's MatroskaExtractor
  does not), so `player.videoFormat?.colorInfo` is `null` and the headroom
  decision used to fall to SDR (`desired ratio=1.0`) even though the SF video
  layer composites as `BT2020_ITU_PQ`. Fix: `stateMap` treats any
  `dvhe`/`dvh1`/`dvav` codec as HDR (DV is always HDR — profiles 4/7/8 base is
  PQ BT.2020, profile 5 is IPTPQc2), matching the Dart `detectMedia3HdrFormat`
  `dv`-prefix heuristic that already labels the chip correctly. Since the
  hybrid-composition switch (see the VIRTUAL-DISPLAY gotcha above), DV content
  *skips* the window HDR/headroom machinery entirely (`skipWindowHdr`) and
  device-composites with the decoder's native BT.2020 PQ dataspace — verified
  on-device (`dvhe.08.06` track): video layer `BT2020_ITU_PQ hdr metadata
  types=9`, `whitePointNits=1249.99`, display `DISPLAY_P3`, no forced dataspace
  or headroom needed. The `colorInfo=null` detection still matters only for the
  Dart HDR chip label.
  **API-gate gotcha (2026-08, Redmi Note 10 /
  MIUI API 31)**: the two-arg `SurfaceControl.Transaction.setDataSpace(
  SurfaceControl, Int)` overload is **API 33+** — the single-arg
  `setDataSpace(Int)` is API 29, and the target-surface overload does NOT exist
  on API 29-32. Guarding the block with `SDK_INT >= Q` still compiled and R8
  kept the call, so on Android 12 devices it crashed at open with
  `NoSuchMethodError: setDataSpace(Landroid/view/SurfaceControl;I)`. Guard the
  two-arg overload with `SDK_INT >= TIRAMISU` (same gate as
  `setDesiredHdrHeadroom`).
  **Non-DV / non-HDR devices (2026-08, Redmi Note 10 — HDR10 yes, DV no)**:
  three behaviors keep DV/HDR correct across phones:
  (1) **DV P7/P8 → HEVC fallback**: `mediaCodecSelector` in `ExoPlayerView.kt`
  returns `video/dolby-vision` decoder infos when a DV decoder exists, otherwise
  the **HEVC** (`MimeTypes.VIDEO_H265`) decoder infos — P7/P8 base layers ARE
  HDR10 HEVC, so on DV-less devices they play as HDR10 (verified on-device:
  `Dolby-Core-Universe-Lossless-Uhd` decodes via `qcom.decoder.hevc` with
  `setColorMode(2)` engaged). (2) **DV Profile 5 rejection**: P5 (IPTPQc2 color,
  streaming/web rips like `dolby-vision-people`, codec string `dvhe.05.<level>`)
  is NOT HDR10 HEVC and renders pink/green on any DV-less device — `emit()` calls
  `dvP5Rejection()` (lazy `MediaCodecList` check for `video/dolby-vision`;
  `dvRejectionShown` latch reset on `open()`) which `player.stop()`s and surfaces
  `error=UnsupportedDolbyVisionProfile5` → Dart `_friendlyError` shows "This
  device cannot decode Dolby Vision Profile 5…" (verified end-to-end on Redmi via
  uiautomator dump). (3) **SDR-only panels**: `applyHdrHeadroom` early-returns
  when `display.hdrCapabilities?.supportedHdrTypes` is empty — pushing an SDR
  panel into `COLOR_MODE_HDR`/PQ dataspace would break SurfaceFlinger's automatic
  HDR→SDR tone mapping (washed-out colors). `Display.isHdrSupported` is API 34;
  use `hdrCapabilities?.supportedHdrTypes?.isNotEmpty() != true` (API 24+), and
  note `HdrCapabilities` has no `isHdrSupported` in the android-37 stub.

- **iOS/iPad playback via AetherEngine (2026-08)** — the raw **AVPlayer**
  platform view was swapped for an **AetherEngine**-backed one
  (`ios/Runner/AvPlayerView.swift`, `UiKitView` on the Dart side) behind the
  exact same `dreamplayer/exo_<id>` method/event channel contract, so the Dart
  `ExoPlayerController` is unchanged. AetherEngine adds what AVPlayer alone
  cannot: **FFmpeg demux of MKV/TS/AVI/WebM**, **DTS/DTS-HD/TrueHD/E-AC3 audio**
  (AudioToolbox + libavcodec), **Dolby Vision / HDR10(+) via the native AVPlayer
  path** for Apple containers. `engine.bind(view:)` mounts `AetherPlayerView`
  (own `AVPlayerLayer` → real HDR where the panel supports it; iPad Pro M2
  does). Engine added as an SPM dependency (`project.pbxproj`, pinned
  `upToNextMajorVersion` from **6.38.0** (2026-08-24; was 6.21.0) — Xcode auto-resolves FFmpegBuild's
  dynamic FFmpeg xcframeworks into the app bundle. **CI-green** (run on commit
  `82b3dd9`). **Verified on-device (2026-08):** local/Documents files play on the iPad Pro M2;
  SMB playback was REMOVED in 2026-08 (AMSMB2 was slow, wouldn't play every file, and
  audio-switch could crash) and **restored in 0.5.1 on libsmb2** — see
  "iOS in-app SMB on libsmb2" below. NAS files now reach the app through the in-app
  browser on both platforms, plus CX/Files "Open with", WebDAV and Jellyfin.
  **Minimum iOS 17.0** (`IPHONEOS_DEPLOYMENT_TARGET = 17.0`; bumped from
  16.0 on 2026-08 because Citadel (SFTP) requires iOS 17; builds through the
  latest, iPhone and iPad).
  - Channel mapping: state 1/2/3/4 (idle/buffering/ready/ended); DV surfaces as
    `dvhe.<profile>.06` so Dart's `dv`-prefix detection fires; `colorTransfer`
    6 for HDR10/10+/DV, 7 for HLG. Audio/subtitle tracks pushed via
    `currentTracks`; `selectAudioTrack`/`selectSubtitleTrack`/`clearSubtitle`
    mapped 1:1 to engine calls.
  - **SMB was removed in 2026-08 and restored in 0.5.1 on libsmb2** (2026-10).
    The AMSMB2 browser and every `AvPlayerView` SMB path (`smbToken` /
    `isSMBStream` / `reopenSMBStream` / `previousStaleSMBConnection` /
    `sniffFormatFromSMB`) were deleted in 2026-08: it was slow, it didn't play
    every video, and an audio-track switch could crash. Browsing came back
    first on pure-Swift `SMBClient`; see "iOS in-app SMB on libsmb2" below for
    the current architecture and the playback transport.
    `BufferedSMBReader.swift` STAYS — the WebDAV playback path
    (`WebDAVByteRangeSource`) still wraps it for read-ahead — and the
    `AetherEngineSMB` SPM product STAYS because WebDAV's
    `ByteRangeSource`/`WebDAVByteRangeSource` live in that module.
  - **Subtitles render host-side**: AetherEngine decodes cues into
    `engine.$subtitleCues` and its `AetherPlayerView` does NOT paint them, so
    `AvPlayerView` draws its own `SubtitleOverlayView` (text + PGS/DVB bitmap
    cues positioned against the aspect-fit video rect; `zPosition = 1000` above
    the re-attached video layer). **Portrait PGS fix (2026-08)**: the
    `videoRect(in:)` aspect-fit branches were swapped, so in portrait it returned
    a ~2.5×-wide rect and bitmap cues rendered oversized/off-screen; now the
    view-wider-than-video case fills height (bars left/right) and the
    view-taller case fills width (bars top/bottom). `show(image:)` also maps the
    cue's normalized `position` through `SubtitleImage.canvasSize` (width-aligned,
    center-anchored) per the engine's contract, so cropped rips with a taller
    canvas than the video still land correctly. **Cue anchoring (2026-08)**: all
    positioning moved INTO `SubtitleOverlayView` (it keeps the current cue + the
    coded `videoSize`); `layoutSubviews` recomputes the aspect-fit video rect and
    repositions the active cue on every bounds change, so text AND bitmap cues hug
    the video's bottom edge and stay put through rotation — before, the text label
    was Auto-Layout-pinned to the overlay (screen) bottom, so it sat in the
    letterbox bar at the edge of the screen in both orientations. Text cues are
    centered on the video rect, bottom-anchored 12 pt above it, capped to the
    rect's width. Sibling sidecar files (SRT/ASS/
    VTT) auto-pair as `ExternalSubtitleTrack`s (best filename match `isDefault`,
    id = `externalSubtitleTrackIDBase` + ordinal) — like Android.
  - A Documents-folder file browser (`ios/Runner/FileBrowser.swift`, same
    `dreamplayer/files` contract) plus
    `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace` mean videos are
    dropped into the app via the Files app ("On My iPad → DreamPlayer") and
    played in-app. **iOS "Open with" works too** — `CFBundleDocumentTypes`
    (system video UTIs) + **`UTImportedTypeDeclarations`** (custom UTIs mapping
    `mkv`/`ts`/`m2ts`/`webm`/`wmv`/`flv`/`ogv`/`rmvb`/`mpg`/`vob`… to
    `public.movie`, since iOS has no system UTI for those containers) put
    DreamPlayer in the Files/share sheet for every container, and
    `ios/Runner/IntentBridge.swift` mirrors the Android `dreamplayer/intent`
    contract (`getInitialIntent` on launch via scene connection options /
    launch options; `open` from `application(_:open:options:)` +
    `scene(_:openURLContexts:)`, deduped). Security-scoped file URLs from the
    Files app keep their access scope for the playback session. Opening a file
    auto-plays it: the intent pushes `PlayerScreen`, whose `open()` runs with
    `autoplay: true`.
- **libmpv (media_kit) engine (2026-08-29 on-device verified; 2026-08-31 reworked
  from "fallback" into a user-chosen SECOND engine)** — the same `PlayerScreen`
  can run either engine in one build: **Media3** (native ExoPlayer platform
  view, DV/HDR-capable) and **libmpv** (`media_kit: ^1.2.6` for `Player`
  control only + `media_kit_libs_android_video: ^1.3.8`; **`media_kit_video`
  removed** — video renders into `MpvSurfaceView` hybrid composition, not a
  Flutter `Texture`). Both
  drive the SAME UI (transport, seekbar, gestures, auto-hide, ended-routing,
  resume, PiP, chapters, CC sheet). The engine is chosen by the USER: the TMDb
  details screen offers **Play** (Media3) and **Play with MPV** (libmpv),
  and the Media3 error surface offers **Try with MPV**.
  - **No auto-switch (2026-08-31)**: Media3 NO LONGER auto-falls back to mpv.
    On a terminal error after its own software-decoder retry, the error surface
    appears with a manual `Try with MPV` button. The 0.3.8 auto-cascade
    (`_maybeMpvFallback`) was deleted. `PlayEngine { media3, mpv }` +
    `PlayerScreen.initialEngine` (`_engine`) decided in `_init` BEFORE any
    backend is created: `PlayEngine.mpv` skips the ExoPlayer platform view
    entirely and calls `_startMpvPrimary()` (resolves external subs +
    resume position, then `_startMpvFallback(automatic: false)`). The details
    screen's `_play({engine})` passes the choice. iOS keeps a single Play
    (AetherEngine); everything mpv is `Platform.isAndroid`-gated.
  - **mpv is hardware-first, not software**: media_kit's VideoController sets
    `hwdec=auto-safe` (MediaCodec for h264/hevc/mpeg4/mpeg2video/vp8/vp9/av1)
    so libmpv uses the hardware decoder by default and drops to its bundled
    FFmpeg software decode only when the hardware can't handle a stream. The
    trivia in older notes ("libmpv (software)") was about the fallback being
    software-only; as a primary engine it is hardware-backed like Media3.
  - **Audio passthrough (`_configureMpvAudio`)**: media_kit hardcodes
    `ao=opensles` (stereo-only on many SoCs). The bundled libmpv `.so` ships
    the Android **AudioTrack** output + the **spdif** decoder, so on mpv start
    `NativePlayer.setProperty` switches `ao='audiotrack'` (best-effort
    try/catch — failure keeps opensles) and sets
    `audio-spdif='ac3,eac3,dts,dts-hd,truehd'` for Dolby Atmos / AC3 / DTS /
    DTS-HD / TrueHD passthrough on capable outputs; mpv transparently
    PCM-decodes when the sink can't take a bitstream. `NativePlayer` is reached
    via `player.platform` (public `Player` API has no `setProperty`).
  - **Limits (unchanged)**: stock libmpv is SDR-only by default (with tone-map
  mode the MPV path either native-hints HDR to the SurfaceView or intentionally
  tone-maps to SDR via gpu-next — never a fake HDR texture). `Engine · libmpv`
  in the info sheet and the details
    row caption "SDR only — no Dolby Vision / HDR" keep the stock path honest, and
    Media3 stays the DV/HDR engine. **iOS does NOT run mpv** (AetherEngine
    handles everything AetherEngine supports; iOS-only-codec AVPlayer failures
    bubble up normally).
  - **Primary-path subs**: `_startMpvPrimary` resolves sibling sidecars via
    `_resolveExternalSubtitles` and stamps them on `_current` with
    `withExternalSubtitles(...)` so `_attachMpvExternalSubtitles` picks them
    up (the old auto-fallback path relied on browser-carried subs only).
  - **SMB → loopback HTTP bridge (`SmbHttpProxy.kt`)**: jcifs-ng only talks to
    Media3-native `DataSource`s; libmpv can't read `smb://`. Solution: a tiny
    HTTP/1.1 server (`ServerSocket` accept loop, one daemon thread per
    connection, GET/HEAD + single `Range` bytes=) bound to `127.0.0.1` on a
    free port that hands out a `SmbRandomAccessFile` per token. Idle handles
    are parked in an `ArrayDeque` per file (re-opening an SMB handle costs a
    tree-connect + create round-trip — mpv's probe fires ~15 ranges back to
    back, so closing every time is what made startup slow). Reads are
    serialized per file via a `ReentrantLock` because `SmbRandomAccessFile`
    is not thread-safe. Channel methods (`dreamplayer/smb`)
    `startLoopback(serverId, share, path)` → returns the playable URL or
    throws `smb_error`; `stopLoopback(token)` tears the bridge down. Dart
    side: `SmbClient.startLoopback`/`stopLoopback`. `_mpvOpen` calls
    `startLoopback` for any `smb://` source and stores the token in
    `_mpvProxyToken` so the next `stopLoopback` is exact.
  - **External subtitles (`_attachMpvExternalSubtitles`)**: mpv's own
    `sub-auto=exact` only scans sidecars next to a local video file — for
    SMB loopback URLs / http(s) sources there is no directory to scan, so the
    resolved external subs have to be added explicitly. Order: non-default
    subs first via raw `sub-add <uri> <title> <lang>` (so they populate mpv's
    `track-list` for the CC sheet to pick from), then the default track last
    via `SubtitleTrack.uri(…)` (`setSubtitleTrack`) so mpv's final selected
    track is the one the Media3 path would have selected. `_mpvSubtitleOn`
    reflects the current selection. Mirrors Media3's
    **external > embedded always** priority rule.
  - **Picture-in-picture for the fallback engine (`PipManager.kt`,
    `MpvPipService`)**: A Flutter texture receives no touches in pip, so the
    Media3 path's normal player chrome is useless there. New
    Activity-level `PipManager` (`dreamplayer/pip` channel) handles pip for
    the fallback engine: Dart PUSHES playback state via `setMpvState` on
    every playing/pause/buffering transition (cannot round-trip in
    `onUserLeaveHint`), and the native side answers synchronously.
    `MainActivity.onUserLeaveHint` / `onPictureInPictureModeChanged` /
    `onStop` / `onResume` route through `PipManager` first, falling back to
    `ExoPlayerView` when the fallback isn't active. Pip window shows ONLY
    the video (player screen already hides chrome on `_inPip`).
  - **Pip transport controls (system `RemoteAction`s)**: three buttons
    (`ic_stat_rewind` / `ic_stat_pause`/`ic_stat_play` / `ic_stat_forward`),
    rebuilt on every play-state change while in pip so the play/pause icon
    flips. Each fires a package-scoped broadcast
    (`com.dreamplayer.app.PIP_CONTROL` + `EXTRA_CONTROL`); PipManager
    registers an inline `BroadcastReceiver` while pip is active (API 33+
    uses `RECEIVER_NOT_EXPORTED`) and forwards each tap to a method call
    (`pipPlayPause` / `pipRewind` / `pipForward`) that hits dedicated Dart
    handlers `_onPipPlayPause` / `_onPipRewind` / `_onPipForward` (which
    bypass `_touchLocked` since these are deliberate user actions, not
    on-screen touches). `setMpvState` re-publishes the actions on every
    play-state transition while in pip, so the icon matches reality.
  - **Pip dismissal-latch**: same `pipSeen` + `onActivityStopped` pattern
    as ExoPlayerView — swiping the pip window away delivers `onStop` while
    the system STILL reports `isInPictureInPictureMode=true`; without the
    latch the pause is skipped and audio plays invisibly. `onResumed()`
    clears it (real expand-back vs real backgrounding).
  - **MpvPipService** (`lib/services/mpv_pip.dart`) — the Dart side of the
    bridge: handler for `pipChanged` / `pipDismissed` / `pipPlayPause` /
    `pipRewind` / `pipForward`, plus `setState({active, playing, aspect})`
    pushing into native and `enterPip()` for the explicit ⋮-sheet row
    (matches the Settings toggle pattern: explicit user action ignores the
    auto-entry pref). `clear()` drops all five callbacks on player dispose.
  - **Audio sources**: 24-bit multichannel FLAC, DTS-HD MA, TrueHD, and any
    other codec the hardware MediaCodec FLAC/E-AC3 fix-up doesn't cover all
    play through libmpv's bundled FFmpeg software decoder — same trick VLC
    uses. Verified on-device (OnePlus CPH2573): an SDR file that refused to
    play on the native engine (post-software-fallback) opens in the
    fallback engine and plays smoothly.

- **media_kit / libmpv fully REMOVED** from `pubspec.yaml`, `main.dart`,
  `player_screen.dart`, and the APK (no more `libmpv.so`/mediakit libs; only
  `libflutter.so` + `libmedia3ext.so` remain).
  *(This block is outdated and superseded by the 2026-08-29 libmpv fallback
  section above — kept here for the historical record. The current build
  DOES ship `libmpv.so` via `media_kit_libs_android_video`, but only as a fallback
  engine, never as the primary decoder.)*
- **Subtitles done (embedded + sideloaded)**: every sibling subtitle file in
  the video's folder auto-attaches (SRT, SSA/ASS, WebVTT, TTML, SAMI, MicroDVD,
  MPL2, SubViewer via custom parsers), the best match auto-selects, and the CC
  button opens a full track picker over embedded + sideloaded tracks.
- **Static HDR10 detection for MKV files without Colour element (2026-08)**: some HEVC MKVs omit the MKV `Colour` element — the PQ/BT.2020 mastering metadata lives only in the HEVC SEI (payload types 137 Mastering Display Colour Volume, 144 Content Light Level). `ExoPlayerView.kt` now probes the first ~10 MB of video samples on a background thread with `MediaExtractor`, scanning Annex-B / AVCC NALs for these SEI payloads. When found, `hdr10Content=true` is set and `stateMap` emits `desired=5.0` + `colorTransfer=6`, engaging the HDR headroom / window color mode path for true HDR10 passthrough even without container-level signalling. Verified on-device: a test MKV with no Colour element but with SEI 137/144 now shows the HDR10 chip and triggers the EDR ramp.
- **New direction**: playback on Android via **ExoPlayer/Media3** in a Flutter
  **PlatformView + MethodChannel** (HDR/DV-capable native surface), modeled on
  **Nova Video Player** architecture. Keep the Flutter UI/shell, the rendering/
  decoding layer is native Android code.

## Tech stack

| Concern | Choice | Notes |
|---|---|---|
| Framework | Flutter (stable, 3.44.x) | Cross-platform, single codebase |
| Playback engine (Android) | **ExoPlayer / Media3** (native, in hybrid-composition PlatformView) | HDR/DV passthrough-capable; working (`c2.qti.dv.decoder`). Hybrid composition (`PlatformViewLink`) keeps the video SurfaceView on the physical display — the stock `AndroidView` is virtual-display/texture and flattens HDR. |
| Playback engine (iOS/iPad) | **AetherEngine** (native, in PlatformView) | `AvPlayerView.swift` + `AetherEngine` SPM dep; FFmpeg demux/decode + native AVPlayer path for DV/HDR; cues drawn by host `SubtitleOverlayView`. |
| SMB (iPad) | **`libsmb2` 7.0.0 for everything** | In-app SMB returned on iOS in 0.5.1 (2026-10) after AMSMB2 was retired in 2026-08. `SMBClient` drove browsing at first, then was removed too: **libsmb2 now does browsing, share listing, discovery, stat, sidecar fetch and playback** (vendored under `Runner/libsmb2`, built by `ios/libsmb2_build.sh`). Playback feeds the engine through a synchronous `smb2_pread` `IOReader`. The `SMBClient` package still arrives transitively via `AetherEngineSMB` and stays credited in the licences screen. |
| Android audio decode | Media3 `FFmpegAudioRenderer` (ffmpeg extension) | DTS, DTS-HD, E-AC3, AC3, TrueHD — same bundled-FFmpeg approach Nova uses. |
| Reference architecture | **Nova Video Player** (`nova-video-player/aos-AVP`) | See "Playback research notes". |
| Metadata providers | **TMDB primary + optional TheTVDB v4** | TMDB remains the default resolver; TheTVDB can be a configured fallback or explicit Fix Match/Group Poster choice. Provider-qualified metadata is cached in the existing store; credentials use Android Keystore-backed preferences / iOS Keychain. SIMKL remains TMDB-only. |
| **Second engine (Android)** | **media_kit + libmpv** (hardware-first via `hwdec=auto-safe`, FFmpeg software fallback, **`MpvSurfaceView` hybrid composition** — no Flutter Texture) | **User-chosen** second engine: `Play with MPV` on the TMDb details screen (or `Try with MPV` on the Media3 error surface). Video is a real SurfaceView (same pattern as Media3); media_kit `Player` is control-only (`media_kit_video` removed). Stock libmpv is SDR-only (tone-map no-ops safely); optional custom `libmpv.so` under `jniLibs/` (libplacebo/gpu-next) enables HDR tone-map. Ships `libmpv.so` via `media_kit_libs_android_video` — Android-only, so iOS doesn't pull in `Mpv.framework` (which breaks SideStore's `ldid` signer). iOS does not run mpv. |
| Permissions | `permission_handler` | Runtime `READ_MEDIA_VIDEO` request on video open |
| Refresh rate | `flutter_displaymode` | Selects highest refresh mode at startup |

### Device research notes (user's Android phone)
- Display: 1440x3168, supports 60/90/120 Hz, max luminance ~1400 nits.
- `supportedHdrTypes=[1, 2, 3, 4]` → **HDR10, HDR10+, Dolby Vision, HLG** all supported on the panel. Good news for the Dolby Vision goal.
- The phone runs at 60 Hz when the UI is idle and jumps to 120 Hz during animations (adaptive). Verified via `dumpsys SurfaceFlinger` after app launch.

### Playback research notes
- **`media_kit`/mpv is dead for this project's DV goal.** On-device verification:
  - HDR10 (PQ/BT.2020) tone-maps to SDR correctly via mpv `gpu` vo.
  - Dolby Vision P8 renders **pink/green**: mpv v0.36 + FFmpeg 6.0 cannot parse the
    DOVI RPU (file VUI reports `color_transfer/primaries=unknown`), so wrong colors.
    `gpu-next` vo is a frozen frame (media_kit renders via legacy `gpu` path; mpv
    PR #16818 pending). `hwdec:no` (software) gives correct colors but is too slow
    for 4K.
  - Flutter textures (what media_kit uses) have **no HDR path on any platform**
    (media-kit issue #615) — the display only ever sees SDR.
- **New plan (ExoPlayer/Media3, Nova-style):**
  - Render video into a native Android `SurfaceView`/`SurfaceFlinger`-driven
    `PlatformView` so the display receives real HDR/DV signal (the panel supports
    DV — `supportedHdrTypes` includes it).
  - **Nova Video Player architecture** (`https://github.com/nova-video-player/aos-AVP`):
    entry-point repo with `default.xml` manifest. Sub-repos:
    - `aos-Video` — Video UI (Kotlin, ExoPlayer-based playback)
    - `aos-MediaLib` — media library / MediaStore scanning
    - `aos-FileCoreLibrary` — file management (root/network)
    - `aos-avos` — C core multimedia engine using FFmpeg (probing/decoding)
    - Uses ExoPlayer (`exoplayer.xml`) + FFmpeg audio extension for the lossless
      codecs. Building: `cd Video && ./gradlew -Puniversal assembleNoamazonRelease`
  - Android audio codecs map to Media3 `FFmpegAudioRenderer` extension modules;
    `dts`, `truehd`, `eac3`, `ac3` etc. are FFmpeg decoders.
- **Nova buffering / read-ahead (how Nova smooths slow SMB/Wi-Fi; source = `aos-avos`)**:
  - **48 MB ring buffer for network streams** — `Source/avos_mp_video.c:256`
    `stream_set_buffer_size(video->s, 48)`. Wiki "Buffering" history: 12→24 MB
    (2015, high-bitrate 4K) → 48 MB (2022, 2× speed). "Used as cache before the
    parser to tackle buffering issues." Local default is `STREAM_DEFAULT_BUFFER_SIZE`
    64 MB / `STREAM_LARGE_BUFFER_SIZE` 128 MB (`Include/stream.h:41-42`).
  - **Ring buffer + dedicated background pthread** — `Source/stream_buffer.c:162`
    `_buffer_thread` loops `pthread_mutex_trylock` → `buffer->buffer(buffer,1)`,
    sleeps 500 ms when full (`BUFFER_SLEEP`). It refills when the parsed-ahead
    media drops below `stream_drive_wake_sleep = 5000` (5 s, `stream_buffer.c:37`);
    when actively playing it uses `stream_drive_wake_no_sleep = 2000` (s) — i.e.
    keep the ring essentially **always full**.
  - **Rate-aware refill threshold** — `_calc_buffer_threshold` (`stream_buffer.c:55`)
    predicts seconds-ahead from the measured `vcurrent_rate`/`acurrent_rate`
    (min rate floor 250 kbit/s), not just free space. This informed the in-app
    SMB read-ahead design (see "SMB / network shares" roadmap section).
  - **Debugging**: `av.sh smb` prints the current max buffer size; `av.sh dbgv 2`
    shows fill rate.
  - **SMB library**: Nova's SMBv2/3 support is via **jcifs-ng** (wiki "SMBv2 3",
    Apr 2020; earlier jcifs 1.3.19 was SMBv1-only) — **NOT smbj** (see Libraries
    table correction). Nova's C core has no SMB IO module (`stream_io_*.c` are all
    local); network files are opened by the Android app layer and fed to the engine.
  - iOS/iPad DV is restricted by Apple APIs — ExoPlayer/Media3 is Android-only;
    iOS will need a separate native path (AVPlayer). For now focus Android.

## Implemented features

- **MPV default audio track + resume restore (2026-09-23, 0.4.8)**: on open,
  pin the container's DEFAULT-flagged track instead of whatever media_kit
  lands on first (often a non-default language / commentary). Helper:
  `lib/utils/mpv_audio_select.dart` — `pickMpvDefaultAudioId` prefers
  `AudioTrack.isDefault` from the Dart tracks model; `parseMpvDefaultFlag`
  handles MPV flag strings. When the Dart flag was never parsed (media_kit
  only maps `MPV_FORMAT_FLAG` case `'default'`), `_pinMpvDefaultAudio`
  (`player_screen.dart` ~2135) probes libmpv's raw `track-list/<n>/default`
  properties and calls `setAudioTrack` with the winning id. Guards:
  `_mpvAudioDefaultApplied` (one pin per open) + `_mpvAudioPinInFlight`
  (no re-entry) — the latch only sets after a **real** selection or a
  confirmed no-default, so an early tracks event with empty flags no longer
  sticks forever on the wrong track (latches reset at open ~1051/~1076/~1694;
  tracks listener ~1975-2001). User picks are saved per video + **engine**
  (`AudioTrackStore`, `audio_track_{engine}_{resumeKey}`) and re-applied on
  resume; Media3 stores flat track index, MPV stores track id string, so the
  engines never cross-contaminate. "Watch from beginning" clears the save so
  the next open uses the container default again. Unit tests:
  `test/mpv_audio_select_test.dart` (7), `test/audio_track_store_test.dart` (5).
- **Optional TheTVDB v4 metadata provider (2026-09-24, 0.4.9+36)**: TMDB remains
  the primary resolver. `TheTvdbClient` (`lib/services/the_tvdb_client.dart`)
  handles v4 login, search, details, extended records, seasons, and paginated
  episodes; the default season order is preferred and duplicate season entries
  are removed. `MetadataProvider` keeps provider-qualified IDs and cache keys,
  while the existing `TmdMeta` model serializes provider, artwork, seasons,
  episodes, and cast. Settings can enable TheTVDB as a fallback when TMDB has no
  confident match; Fix Match and Group Poster expose an explicit TMDB/TheTVDB
  selector, and details identify the selected provider. Credentials are sent
  through `dreamplayer/the_tvdb_credentials`: Android uses
  `EncryptedSharedPreferences` backed by a Keystore master key, iOS uses
  Keychain, and legacy SharedPreferences/UserDefaults values migrate once at
  startup. Android excludes `FlutterSharedPreferences.xml` from backup because
  it may contain pre-migration credentials. Test connection is
  non-persistent and cannot overwrite saved credentials. SIMKL remains TMDB-only;
  live API validation still needs a TheTVDB key.
- **SMB / NAS cold-start fast again (2026-09-23, user-verified)**: large MKVs
  over SMB used to stall for many seconds at open. Three stacked fixes in
  `SmbDataSource.kt` + `ExoPlayerView.kt`: (1) secondary SMB handles open
  *outside* `ringLock` (each open is a tree-connect round-trip that used to
  block the first Media3 read); (2) a **synchronous head (or tail) fill** in
  `SmbDataSource.open()` so `open()` never returns with an empty ring —
  short/cue probes only fill what was asked for; (3)
  `FLAG_DISABLE_SEEK_FOR_CUES` on the Matroska extractor so Media3 no longer
  seeks to EOF during init (Cues live at the end of large files — that seek
  used to reset the ring mid-startup). `MultiplexDataSource` also reuses the
  same-URI SMB/FTP delegate across `open()` so head→EOF→head cue maps don't
  tear down and rebuild the SMB session three times.
- **MPV SurfaceView path (Phase 1+2, 2026-09-23)**: `media_kit_video`
  (Flutter `Texture` + `VideoController`) is **removed**; video output is
  `MpvSurfaceView.kt` / `lib/services/mpv_surface_view.dart` (viewType
  `dreamplayer/mpv_player`, hybrid composition — same pattern as Media3's
  platform view). media_kit `Player` remains for control only. `_startMpvFallback`
  calls `_teardownExoForMpv()` first (exactly one SurfaceView). Custom
  `libmpv.so` may live under `android/app/src/main/jniLibs/` with Gradle
  `packaging.jniLibs.pickFirsts +=("**/libmpv.so")` overriding media_kit's
  stock binary (libplacebo/gpu-next for issue #21 tone-map). See roadmap
  "MPV without media_kit" for on-device gates.
- **MPV HDR tone-map mode (issue #21, 2026-09-23, 0.4.8)**: Settings → Player
  "HDR tone-map (MPV)" + player ⋮ sheet — **SDR tone-map** (libplacebo
  `gpu-next` + spline / perceptual / BT.709 / BT.1886) vs **Native HDR/DV**.
  Custom arm64 `libmpv.so` with libplacebo ships in
  `android/app/src/main/jniLibs/` (Gradle `pickFirsts`). `_mpvGpuNextAvailable`
  probes `libplacebo-version`; stock libmpv no-ops to `vo=gpu` + bt.2390.
  Android-only; widget test: `test/settings_tone_map_platform_test.dart`.
- **Movie-part folders stay separate + per-part TMDB matches (2026-09, 0.4.7)**: movie-part folders like `[VCB-Studio] GIRLS und PANZER das FINALE 01 [Ma10p_1080p]` (Parts 1–4) previously collapsed into one auto-group AND all matched the same movie. Three fixes: (1) `SeriesGroupingService.baseNameOf` strips trailing numbers ONLY when a season-like tag (`S01`, `Season N`, roman numeral — `_conditionallyStripTrailingNumber`) is present, so `FINALE 01`–`04` keep their numbers → each gets its own card; (2) `resolveFolder` tries the **numbered** query first (base `FINALE` as fallback, `candidates.addAll` not `insertAll(0)`) and threads the folder's trailing number as `desiredPart` through `_resolveFolderCandidates` → `_resolveFolderNow` → `TmdApi.bestForQuery` → `_queryScore`/`_score` (the effective part is `qPart ?? desiredPart`, so even the base query gets the part boost); part match `+0.45`, mismatch `-0.35`, query-has-part-but-title-has-none `-0.25` — `FINALE 01→474659`, `02→496891`, `03→746880`, `04→1051192` each win their own `Part` entry (`_partNumberFromTitle` parses `Part 2` AND Roman `Part II`); (3) stale movie-part caches are detected (folder trailing `02` vs cached title `Part I`) and re-resolved in both `TmdService` and `home_screen._resolveFolderMetadata` — log-only, the stale poster stays visible until the fresh fetch lands (no flash).
- **Manual grouping (2026-09, 0.4.7)**: the user selects 2+ cards on Home (long-press enters selection mode, tap toggles the whole group, ✕/back exits), then Group via the app-bar `library_add_check` button or the ⋮ menu → `_promptGroupNameDialog` asks for a name → one grouped card appears. `ManualGroup`/`ManualGroupsStore` (`lib/services/manual_groups.dart`, prefs `dreamplayer.manualGroups`); `_buildDisplayGroups(folders, manual)` renders manual groups FIRST (members collapsed into one `SeriesGroup`, remaining folders auto-group by name), prunes stale groups (folder removed / below 2 members → dissolved) and persists the pruning. `FolderCard.displayNameOverride` (the user-entered group name) wins over TMDB/folder titles on the card. Removing a folder from the library drops it from any manual group (`removeFolderId`). All manual groups open `MovieGroupScreen` (below); auto groups keep the `SeriesSeasonsScreen` flow.
- **MovieGroupScreen (2026-09, 0.4.7)** (`lib/screens/movie_group_screen.dart`): the grouped-card detail screen, mirroring `SeriesSeasonsScreen`'s layout: backdrop hero `SliverAppBar` (clean backdrop when expanded, fades to toolbar title beside the back arrow when collapsed — same `_CollapsingBackdrop` pattern), `_Header` card (poster + title + year + expandable overview More/Less + star rating + genre chips), `_CastRow` (horizontal circular photos), `_TrailersRow` (up to 5 YouTube buttons), then the grouped folders as poster cards in a `SliverLayoutBuilder` grid using the SAME sizing as the home screen (`_columnsForWidth` 2/3/4/6, `itemWidth * 3/2 + 84`). Header shows only when a member has TMDB info (`_metaForDisplay()`: group key → any member's cached meta) — a random group with no metadata shows just the cards. Details load via `detailsFor` (group key → any member key with meta). Card taps: file entries (`isFile`) build a `VideoItem` from `videoPath`/`videoUri` + `extractFileInfo` and push `TmdDetailsScreen(video:, parentMetadataKey:)` (VIDEO mode — folder mode lists a directory, which a file entry doesn't have: "no videos here" + dead Play button); folder entries push `TmdDetailsScreen(folder:)`.
- **Player top bar TMDB title (2026-09, 0.4.7)**: the player screen's top bar shows the TMDB-fetched title instead of the raw file name (`cocktail 2.mkv` → `Cocktail 2`). `_tmdbMeta` resolved in `_openCurrent` per video (cache hit when the home screen pre-fetched, fire-and-forget `TmdService.resolve` for intent-opened files) + live refresh via a `TmdService` listener; `_displayTitle` getter (`player_screen.dart:416`) falls back to the raw video title with the extension stripped when there's no TMDB data.
- **Global default playback engine (2026-09)**: Settings → Player → "Default playback engine" lets the user choose **Media3** (hardware-accelerated, Dolby Vision / HDR), **libmpv** (software-first, broader codec support, SDR only), or **Ask every time** (both buttons on the details screen). When a specific engine is set, the Play/Resume button uses it directly; the secondary engine button is hidden. The ⓘ info sheet and error surface still allow switching manually. Persisted as `dreamplayer.defaultEngine` (`DefaultEngineStore`, `lib/services/default_engine_store.dart`). The details screen reads the preference on init and passes the resolved engine to `PlayerScreen.initialEngine`.
- **Auto-fallback on engine failure (2026-09)**: when Media3 reaches a terminal error (hardware decode fails, software decode also fails), the player now automatically tries NextLib's FFmpeg video extension **within Media3** first, then libmpv if that also fails. Three-step fallback in `_trySoftwareDecodeFallback` (`player_screen.dart`): (1) set `DecoderMode.ffmpegVideo` which forces `PlayerCodecs.kt` to return an empty video decoder list, making Media3 use the bundled `FfmpegVideoRenderer` extension (same NextLib FFmpeg used for DTS/TrueHD audio — fast, stays in Media3 pipeline); (2) if FFmpeg video also fails, hand off to libmpv's own bundled FFmpeg decode path; (3) terminal error if both engines fail. The `_ffmpegVideoRetried` latch prevents double-retrying per file. `ffmpegVideo` is an internal-only `DecoderMode` (hidden from Settings and player pickers). Reset per-file in `_restoreDecoderOverride`.
- **libmpv purple screen fix (2026-09)**: some HEVC Main10 anime files (10-bit encodes for banding reduction) rendered as a purple/magenta tint when played through the libmpv fallback engine. Root cause: `mediacodec-copy` decodes into P010 (10-bit YUV420P) buffers; mpv's video output must convert them to RGB for the host render path, but without color-space hints the conversion uses the wrong transfer function. Fix: set `target-colorspace-hint=yes` and `force-rgb-colorspace=yes` on the mpv context in `_configureMpvAudio` so the source color space is honored during conversion.
- **libmpv auto-fallback to software on mid-stream codec death (2026-09, issue #7)**: some HEVC Main10 4:2:0 files play for ~0.5 s and then die with a terminal "Could not open codec." even though HEVC 12-bit 4:4:4 plays fine — the MediaCodec hardware decoder starts producing frames and then dies mid-stream. mpv's `hwdec-software-fallback` only rescues *decoder-init* failures, so this surfaces as a playback error (not a fallback trigger). `_maybeMpvSoftwareRetry` (`player_screen.dart`) now auto-reloads the same file in software (`hwdec=no`) at the current position when the error text mentions a codec/decoder/pixel-format/hardware problem (`mpvErrorLooksLikeCodec`, unit-tested in `test/mpv_retry_test.dart`), once per file via `_mpvSwRetriedKey` (keyed by resume key) — a later file still tries hardware first. `_applyMpvHwdec` forces `'no'` when `_mpvSwRetriedKey == _resumeKey`, so the software path survives the reload. Mirrors Media3's `_trySoftwareDecodeFallback`; the ⓘ info sheet's decoder line shows "software" after the retry engages. IO/network errors are never retried (wrong fix). **Verified on-device (2026-09-23)**: GuP FINALE 01 HEVC played 65+ s with `hwdec = mediacodec` applied *before* open (`_mpvOpen` order: surface wait → `_applyMpvHwdec` → `player.open`), `c2.qti.hevc.decoder` at 1920×1080 ~24 fps, no software retry fired — the gap that used to leave a stale `hwdec` across `_reloadMpv` is gone; `_applyMpvHwdec` call sites are the open/reload paths only.
- **Continue-watching cards use the poster-card TMDB path (2026-09)**: CW entries resolve with the same tools as home poster cards — file-level `resolve(..., parentFolderName: <real parent dir>)` (base-query fallback in `bestMatch` for `FINALE 01` → 0 hits → strip trailing number → Part N ranking), then inherit the parent `LibraryFolder`'s `resolveFolder` meta via `carryMeta` when the file search still misses. Display uses `_metaForContinueVideo` (file key first, then folder key) so the grid paints before/without a per-file resolve. Details screen `_inheritLibraryFolderMeta` mirrors the same path-prefix rule. `_computeParentFolderName` fixed to return the parent *directory* (it used to return the file basename, so `parentFolderName` never helped episode-only titles).
- **MPV brightness restore on dispose (2026-09)**: `PlayerScreen.dispose` calls `SystemControls.setBrightness(-1)` on Android and resets `_mpvBrightness = 1.0` so a brightness gesture doesn't stick after the player closes; `system_controls.dart` catches `on Exception` on all four methods.
- **MPV portrait subtitle size fix (2026-09)**: the Flutter subtitle overlay (`_mpvSubtitleLines` + `fontSize = h * 0.0533 * sizeMultiplier`) only rebuilt on an unrelated `setState` — after Subtitle settings returned, `_subtitleStyle` was updated with no rebuild, so the new size only landed on rotation (`_applyOrientation` → setState) or a playing position tick (why landscape “worked”). Also `.clamp(12.0, 300.0)` sat on the floor: in portrait the letterboxed 16:9 video height gives `h * 0.0533 ≈ 12`, so every shrink clamped back to 12. Fixes: `setState` after the settings-return style load (`player_screen.dart` ~4961) and after `_applySubtitleDelay`, and floor lowered to `clamp(1.0, 300.0)`.
- **Download to device (2026-09)**: download video files from network sources (SMB, WebDAV, HTTP, Jellyfin, UPnP/DLNA) to local storage for offline playback. FTP download hidden (Dart `HttpClient` cannot handle `ftp://`). Kotlin foreground service (`DownloadService.kt`, `NOTIF_ID=4211`, `FOREGROUND_SERVICE_TYPE_DATA_SYNC`) + `DownloadClient.kt` method channel with cancel callback bridge to Dart. iOS: `DownloadClient.swift` with `UNUserNotificationCenter` — notification shows banner once at start, then silent progress updates every 5s; cancel action registered via `UNNotificationCategory` + forwards `jobId` to Dart via `onCancelFromNotification`; tap notification body fires `onNotificationTap` which opens the Downloads drawer. Dart `DownloadManager` singleton (`lib/services/download_manager.dart`) handles HTTP streaming (with HEAD probe for `Content-Length`), SMB via loopback proxy (`SmbHttpProxy`/`SmbClient.startLoopback`), local file copy via async chunked I/O (256 KB chunks, event-loop yield each chunk to avoid UI blocking), progress tracking, queue management (one at a time), and SharedPreferences history. Download screen (`lib/screens/download_screen.dart`) shows progress bars (indeterminate when size unknown), status badges, cancel/delete/play. UI triggers: player ⋮ sheet "Download to device" row (visible for network sources except FTP/files) + details screen bottom bar Download button (same filter). Home screen hamburger menu shows active downloads (spinner + bytes + ✕ cancel) and completed/failed downloads (tap to play / delete). Android: `/storage/emulated/0/Download/DreamPlayer/`; iOS: `Documents/DreamPlayer/`.
- **External player handoff (2026-09)**: when both Media3 and libmpv fail (or user explicitly chooses), the error surface offers "Open in external player" via `Intent.createChooser` with `setDataAndType(uri, "video/*")`. VLC handles `smb://` natively (no loopback needed). WebDAV passes the HTTPS URL directly with auth headers. UPnP/DLNA and Jellyfin pass HTTP URLs directly. Android only (iOS has no external player intent system).
- **Downloaded files on home grid + download directory picker (2026-09)**: completed downloads now appear in a "Downloaded" section on the home screen with a green checkmark badge, tap to play, long-press to delete. Settings → Downloads → "Download directory" lets the user choose where downloads are saved (native directory selector on Android, Files-app document picker on iOS). Default: `/storage/emulated/0/Download/DreamPlayer/` (Android), `Documents/DreamPlayer/` (iOS). Native `setDownloadDir`/`getDownloadDir` methods on both platforms store the custom path in SharedPreferences (Android) / UserDefaults (iOS).
- **iOS: resume-after-lock fix (2026-09)**: locking the device for an extended period could revoke security-scoped bookmark access or kill network connections (SMB, WebDAV, FTP, Jellyfin, Files-app bookmarked folders). Previously, `play()` called `engine?.play()` on a dead source with no error. Fix: `needsReloadAfterBackground` flag set on `didEnterBackgroundNotification`; `play()` and `seekTo()` now call `reloadSession(at: currentPosition)` to re-establish the source. Flag cleared on reload completion and on new file open.
- **iOS: stretched-video-after-unlock fix (2026-09)**: AetherEngine's internal `AVPlayerLayer` doesn't have `autoresizingMask`, so it keeps its initial frame when Flutter resizes the platform view after unlock. Fix: `PlayerContainerView` wrapper overrides `layoutSubviews` to call `engineView.layer.layoutSublayers()`, forcing the `AVPlayerLayer` to match the new container bounds immediately. Also: `UiKitView` wrapped in `SizedBox.expand` for tight Flutter constraints; `setState` on resume forces Flutter to rebuild with post-unlock dimensions. `findPlayerLayer()` and `setZoom()` target `engineView` (the inner `AetherPlayerView`), not `container` (the wrapper).
- **iOS: whole-UI stretched after unlock (2026-09)**: NOT the video layer — the entire Flutter UI (home / Jellyfin / WebDAV lists, settings) rendered stretched / aspect-mismatched after device lock → unlock, then self-corrected after an unrelated layout pass. Root cause: iPadOS resizes the scene while the app is backgrounded/locked (Split View snapshot prep, flutter/flutter#128868), and Flutter only re-creates its render surface when the `FlutterViewController` view is laid out again with changed bounds — so the engine kept presenting a stale surface at the wrong size until some later layout happened to re-measure it. Fix: `SceneDelegate.forceFlutterViewRelayout` (called from `sceneDidBecomeActive`) nudges the root view's frame by 0.5 pt and back with two synchronous `layoutIfNeeded()` passes, forcing `viewDidLayoutSubviews` to run and the engine to re-create the surface at the current window size immediately. (Same class as the Apple "improving app responsiveness" guidance: drive layout at the right lifecycle moment instead of waiting for a hitch/self-correction.)
- **Back navigation / SMB path / series-view fixes (2026-09)**: `PopScope.canPop: false` on all seven browse screens so swipe-back goes through `_goUp()` instead of popping the route. SMB trailing-slash normalization (`//` → `/`, strip trailing `/`). `_detectAndLoadSeriesFolder` guards on `hasSubfolders` — series view doesn't activate when the folder has subdirectories. TMDB subfolder name fix (use current subfolder, not root name). Focus highlight + episode poster race condition (generation counter prevents stale async results). Episode still fallback to `posterUrlOf(tmdbMeta)`. Stale `_seriesMeta` fix (re-read from cache after season fetch). Season collapse fix (`_expandedSeasons.clear()` on `_load()`).
- **Offline image cache + backdrop hero + TMDB/season polish (2026-09, 0.4.5)**: `ImageCacheService` (`lib/services/image_cache_service.dart`) + `CachedImage` (`lib/widgets/cached_image.dart`) — permanent disk cache for TMDB posters/backdrops/stills/cast profiles, prefetched on `TmdService` resolve, `CachedImage` replaces `Image.network` across all browsers/folder/details/series screens; Settings shows live cache size with clear action. `SeriesSeasonsScreen` + `TmdDetailsScreen` now use a **backdrop hero** (clean backdrop when expanded, fades to toolbar title beside back arrow when collapsed). TMDB: movie sequel pattern (`Part N`/`Vol N`/`Movie N`/`Chapter N`) boosts movie matches for collections like `Girls und Panzer das Finale`; live-action vs anime disambiguation. Home `needsResolve` guard with `hasSeasonTag` so top-level show folders (e.g. `House`) don't re-resolve offline. TMDB season names seeded from cached `TmdMeta.seasons` on restart with `folderSeason` fallback. **SMB auto-expand**: bookmarked SMB folders now expand into individual folder/file cards with TMDB resolution (parity with local/WebDAV/FTP/UPnP/Jellyfin); file entries skip `listDirectory` and use `parsed.seriesName` so `Lanterns Lights Out` resolves. Home grid single-file cards open `TmdDetailsScreen(video:)` directly (no `SeriesSeasonsScreen` crash on file paths). **Series grouping**: prefix-based merge fallback for unstrippable suffixes (Japanese arc names like `Kieta Seisou Hen`) with tightened threshold `shared ≥ 10 && extra ≥ shared` to avoid `House`/`House of Cards` and `Kakegurui`/`Kakegurui Twin` false positives; standalone non-season folders (e.g. `Kieta Seisou Hen` movie) render as their own card/section — phase-2 refine is the single authority validated against cached season names. **Settings**: all groups collapsible via `ExpansionTile`; delete-sweep icons on `Your library` + `Continue watching` headers clear all with confirmation; folder cards drop watched ring/season badge overlays. **HDR fix**: Android SEI probe now validates luminance (`137` 24 B mastering display `max 50..10000 nits`, `144` 4 B content light `maxCLL 10..10000`) matching iOS parity. **Season discovery**: correct season numbers for standalone entries, TMDB episode details on first open, re-fetch of empty cached seasons. **Episode-level TMDB metadata cached for offline (issue #16)**: `_resolveFolderMetadata` in `home_screen.dart` now parses the folder's file names to discover which seasons are locally present, then calls `seasonFor(key, season)` for each. Previously, only `folderSeason` episodes were cached — when `folderSeason` was null (e.g. "Dark" doesn't match any TMDB season name), zero episodes were cached and episode titles/stills/overviews/ratings disappeared offline. After this fix, all locally-present seasons are fetched during the online prefetch and persist in SharedPreferences. Episode stills are also prefetched to the permanent disk cache (`ImageCacheService`).

- **Friendly error messages + software-decode auto-fallback on hardware-decode failure (2026-08-29)**:
  - **Bug fix (every PlaybackException was showing the raw code)**: the Dart `_friendlyError` switch matched snake_case strings like `error_code_io_bad_http_status` / `error_code_decoder_init_failed`, but Media3's native `emit(errorCodeName = error.errorCodeName, …)` returns `ERROR_CODE_*` names (verified by disassembling `media3-common-1.10.1` — `PlaybackException.getErrorCodeName(int)` returns e.g. `"ERROR_CODE_DECODING_FAILED"`, `"ERROR_CODE_IO_BAD_HTTP_STATUS"`, etc.). The snake_case cases were **dead code** — every real error fell through to the generic `"Playback failed (ERROR_CODE_…).message"`, which is what the user reported as "code decoding failed". The mapping now lives in `lib/screens/player_error.dart` (`friendlyPlayerError` / `isRetryableIoError` / `isVideoDecodeError`) and is unit-tested in `test/player_error_test.dart` (9 new tests, full suite 212 passing). Same fix applied to the IO-retry predicate so the existing exponential-backoff auto-retry now actually fires.
  - **Software-decode auto-fallback**: budget MediaTek/Qualcomm chips sometimes have a **hardware H.265/HEVC decoder that misreports 10-bit Main10 support and then fails at runtime** with `ERROR_CODE_DECODING_FAILED` — VLC/mpv play the same file fine because they use FFmpeg software decode. On any video-decode error (`ERROR_CODE_DECODING_FAILED`, `…_DECODER_INIT_FAILED`, `…_DECODER_QUERY_FAILED`, `…_DECODING_FORMAT_UNSUPPORTED`, `…_DECODING_FORMAT_EXCEEDS_CAPABILITIES`, `…_DECODING_RESOURCES_RECLAIMED`), `_trySoftwareDecodeFallback` in `player_screen.dart` saves the user's original `decoderMode` in `_decoderOverride`, writes `sw` to `DecoderModeStore` (which the native `MediaCodecSelector` lambda re-reads **live** on every query — see `PlayerCodecs.kt:91-94` "Read prefs LIVE on every query"), reopens at the current position with a brief "Hardware decoder failed — retrying with software…" overlay, and restores the user's original mode at the top of `_openCurrent` (next file) and in `dispose`. Override is per-file only. The decoder chip in the ⓘ info sheet shows "· software" so the user can see the fallback engaged. **Verified on user-reported case (Infinix Hot 50i, MediaTek G81)**: their HEVC Main10 10-bit MKV (`Strike the Blood Final [Ma10p_1080p][x265_flac].mkv`, 1080p, SDR) plays in mpv/VLC smoothly; with this fix DreamPlayer will too. **Updated (2026-09, issue #20)**: the fallback now tries FFmpeg video within Media3 first (via `DecoderMode.ffmpegVideo`) before escalating to mpv — see "Auto-fallback on engine failure" above.


- **Picture-in-Picture (2026-08-26, user-requested — supersedes the 2026-08-22 rejection)**:
  - **Android**: manifest `android:supportsPictureInPicture="true"` on `MainActivity`; **auto-enter** on HOME/recents while playing (`onUserLeaveHint` → `ExoPlayerView.enterPipIfPlaying`, aspect from `videoSize` clamped 0.42–2.39 → `Rational(n,1000)`); **⋮-sheet row** (explicit entry). **Settings toggle** "Picture-in-picture" (Player section, Android-only, pref `dreamplayer.pipEnabled`, default ON) gates **only auto-entry** — `enterPipInternal(auto)` reads the pref natively (`flutter.dreamplayer.pipEnabled` from `FlutterSharedPreferences`) because the decision happens in `onUserLeaveHint` before Dart could weigh in; the ⋮ row is an explicit user action and ignores the toggle. With PiP off, leaving the app **keeps background audio playing** (user decision — the toggle controls the floating window only; swipe-app-away still pause+stops). Pip window shows ONLY the video: every reveal path gated on `_inPip` (`_showControls`, `_syncControlsForPlaybackState`, gestures, TV key-reveal) and the format chips are transient (next bullet), so nothing leaks into the window. **Dismissal-pause gotcha**: swiping the pip away delivers `onStop` while the system STILL reports `isInPictureInPictureMode=true`, so a `currentlyInPip` guard skips the pause and audio plays on invisibly — `onActivityStopped()` instead pauses whenever the `pipSeen` latch is set (set in `onPipModeChanged(true)`, cleared ONLY in `onResumed()` = expand-back). Tap on the pip body = expand to fullscreen (standard). Verified on-device: HOME → pip playing clean (no chips/bars), swipe-dismiss → `state=PAUSED`.
  - **iOS** (`AvPlayerView.swift`): `AVPictureInPictureController(playerLayer:)` (`canStartPictureInPictureAutomaticallyFromInline = true`), `enterPip` channel case, `AVPictureInPictureControllerDelegate` emits `inPip` + restores on expand; native-AVPlayer path only (the FFmpeg custom-source path has no `AVPlayerLayer` → no pip there). **Second-swipe fix (2026-08, `4d11555`)**: `restoreUserInterfaceForPictureInPictureStop` no longer nils `pipController` — it stays valid while its `AVPlayerLayer` is alive; `DidStop` re-arms via `ensurePipController` so HOME floats again.
  - **Stale-build gotcha**: a failed gradle build leaves the PREVIOUS apk in `build/…` — `adb install -r` then installs old code and "fixed" behavior looks broken/random. After any failed build, compare APK mtime vs `adb shell dumpsys package com.dreamplayer.app | grep lastUpdateTime` before testing.

- **Embedded cover-art thumbnails (2026-08-26)**: video cards show the file's **embedded artwork** (MKV attached pictures / MP4 `covr`) instead of the plain gradient. `FileBrowser.getThumbnail` (`dreamplayer/files`) reads **metadata only** — `MediaMetadataRetriever.getEmbeddedPicture` (Android) / `AVURLAsset` `commonMetadata` `commonKeyArtwork` (iOS; MKV attachments unreadable there, MP4/MOV only) — never `getFrameAtTime`, which returns black frames for DV/HDR (do not add frame-extracting thumbnails). Local sources only (path / `file:` / `content:` / `tree:`); remote (SMB/WebDAV/Jellyfin/HTTP) skip the probe. `ThumbnailStore` (`lib/services/thumbnail_store.dart`) caches bytes in memory + disk (`<tmp>/cover_art/<fnv1a32hex>-<tail≤24>.img`), negative-cache in-memory only, keyed by `TmdStore.identityKeyFor` (same key as the details screen). TMDB backdrop still wins on continue-watching cards — embedded art renders only when there's no TMDB match. **Deadlock gotcha**: `future.whenComplete(() => map.remove(key))` DEADLOCKS — the arrow returns `Map.remove`'s value, which IS the same future (it waits on itself); use a block body `{ _inFlight.remove(key); }`. Probe failures/timeouts (10 s guard) just leave the gradient.

- **Transient format chips + Video info sheet (2026-08-26)**: the top-bar chips (HDR / video / audio / resolution / decoder / transcode / boost / night / spatial) no longer persist — they **flash for 5 s on the first STATE_READY per open** (`_flashChips`, `_chipsFlashedForOpen` latch reset in `_openCurrent`), fade via `AnimatedOpacity` + `IgnorePointer`, and are force-hidden on pip entry. The top-bar **ⓘ button** (right corner, `_TvControlButton` so the TV D-pad reaches it) opens a read-only **"Video info" sheet**: Title / HDR / Video / Audio (· Passthrough) / Resolution / **Decoder** (full component name + hardware/software — previously only in a chip tooltip) / Stream (server transcoding) / Spatial audio / Volume boost / Night mode / Bass boost. Motivation: persistent badges cluttered long sessions and leaked into the pip window. Labels shared with the chips through `_videoCodecInfoLabel` / `_audioInfoLabel` / `_resolutionInfoLabel` getters (DV dedup included).

- **NEVER put `Spacer()`/`Expanded()` inside AlertDialog `actions` (2026-08 gotcha, broke every network-server dialog)**: `AlertDialog` lays `actions` out in an **OverflowBar**, not a Flex — a Flex child there throws `Incorrect use of ParentDataWidget … Expanded wants FlexParentData, found _OverflowBarParentData` while mounting and the whole dialog form dies (user-visible: "only the Test button, no input fields" on FTP/WebDAV/Jellyfin/SMB add-server dialogs). The four dialogs had a `const Spacer()` between Test and Cancel for push-right spacing; fix: removed them + `actionsAlignment: MainAxisAlignment.spaceBetween` in the shared `serverDialog()` helper (`lib/widgets/server_form_kit.dart`). Regression-tested in `test/server_dialog_layout_test.dart`, which pumps both dialogs at phone + iPad portrait/landscape sizes and asserts all 6 TextFields mount at full height (≥40 px) — this test is what caught the bug; label-Text heights are NOT a valid size proxy (a floating label is naturally ~16 px).

- **Volume Boost + Night Mode — Android-only (2026-08)**: real effects live in `ExoPlayerView.kt` (`applyAudioEffects`): a `LoudnessEnhancer` on the player's audio session — boost 1.0–3.0× maps to 0–1500 mB gain; Night Mode alone pins 400 mB (compression-ish lift) and combines additively with boost; re-attached on `onAudioSessionIdChanged`, persisted via `flutter.dreamplayer.audioBoost`/`nightMode` prefs, re-applied on every open. **Verified on-device** (OnePlus CPH2573): `dumpsys media.audio_flinger` shows the `Loudness Enhancer` effect chain attach/detach as the toggles change. iOS is a **deliberate no-op** (`AvPlayerView.applyAudioBoost`): `AVPlayer.volume` caps at 1.0 and there is no public DRC-over-AVPlayer API, so boost >1 clamps back to 1.0 and night mode only stores/emits the flag. To avoid fake affordances, both controls are hidden on iOS (Settings Player section + player ⋮ sheet gated on `defaultTargetPlatform == TargetPlatform.android`); settings still persist cross-platform and light up if the engine ever gains a gain/DRC hook. A real iOS fix means routing AetherEngine's decoded PCM through an owned `AVAudioEngine` + Apple's DynamicsProcessor unit — large effort, deferred.

- **Bass Boost — Android-only (2026-08-25)**: `android.media.audiofx.BassBoost` attached to the same session in `applyAudioEffects` (independent of the loudness guard — applies even at 1.0× / night mode off); levels Off/Low/Medium/High → strength ~150–1000; persisted `flutter.dreamplayer.bassBoost`, live via `setBassBoost`, emitted as `bassBoost` in the event map. The ⋮ sheet row is **gated on `_liveSpatial == 'on'`** — it exists to offset HRTF low-end thinning during spatial virtualization, so it appears only while the teal Spatial chip is active and vanishes when routing/content changes. Works on any output (wired/USB/BT) since it's session-level DSP. iOS: no public API over AVPlayer; would need AetherEngine PCM routed through an owned `AVAudioEngine` with an `AVAudioUnitEQ` low-shelf band (+4–8 dB @ ~100 Hz) plus re-plumbing position/pause/rate/seek — deferred alongside volume boost. The `_liveSpatial == 'on'` gate this row depends on is set by the **Android-only** `system_controls` channel today; if/when iOS spatial ships (see "iOS spatial audio" in the Roadmap) the same gate starts working on iOS for free, which is the correct behavior — the row exists to offset HRTF low-end thinning.

- **Background playback + media notification controls (2026-08-26)** — the #1 competitor-gap feature: audio keeps playing and lock screen / notification / headset controls work when the app is backgrounded or the screen locks.
  - **Android** (`PlaybackManager.kt`, `PlaybackService.kt`): deliberate **NOT** a Media3 `MediaSessionService` refactor — the player stays in the Activity-scoped platform view, so a plain **`MediaSessionCompat`** (`androidx.media:media:1.7.0`) wraps it and a thin **foreground service** (type `mediaPlayback`) only holds foreground priority + hosts the `MediaStyle` notification (rew-10s / play-pause / ffw-10s / close, tap → app). All actions route through session callbacks back into the live player instance. Player hygiene added in one go: `setAudioAttributes(..., handleAudioFocus=true)` (pauses for calls/other apps), `setHandleAudioBecomingNoisy(true)` (pause on headphone unplug), `setWakeMode(C.WAKE_MODE_NETWORK)` (CPU+Wi-Fi locks so streams keep buffering with screen off). `POST_NOTIFICATIONS` requested fire-and-forget in Dart before first playback (13+; denial hides the notification but playback/service still work).
    - **Gotchas**: (1) `setMediaItem` flips the player to transient `STATE_IDLE` between opens — `sync()` must re-set `session.isActive = true` on every call or the first IDLE emit permanently deactivates the session (no more notification for the rest of the file); (2) `PlaybackManager.release(context)` (from platform-view dispose) MUST stop the service + cancel the notification BEFORE nulling the player — otherwise the foreground service outlives the released player and tapping its play button routes into freed callbacks; (3) rebuild the notification only when visible state changes (key = state|playing|title) — the position ticker emits ~1/s and `notify()` every second is wasteful (lock screen extrapolates position from `state.speed` between updates); (4) notification action PendingIntents are `MediaButtonReceiver.buildMediaButtonPendingIntent` → manifest-declared `androidx.media.session.MediaButtonReceiver` → service `MEDIA_BUTTON` intent-filter → `handleIntent(session, intent)`; (5) API 34 requires `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permission + typed `startForeground` via `ServiceCompat`. Swipe-app-away = pause + stop (safe default; a keep-playing setting is future work). STATE_ENDED tears down the notification.
    - **MediaStyle gotcha (2026-08-26, on-device — the reason the notification "disappears")**: a `MediaStyle` notification bound to the session token is **pulled out of the notification panel entirely** on Android 13+/OxygenOS — the system converts it into the quick-settings media card (Poweramp behaves identically; verified by A/B on the OnePlus CPH2573, Android 16). Users looking in the notification shade see NOTHING. Fix: `buildNotification` posts a **plain `NotificationCompat` row** (no MediaStyle, no session token in extras) — a normal silent notification with Back-10s / Play-Pause / Forward-10s / Close actions + a **live progress bar** (plain rows render `setProgress`, MediaStyle ignores it), rebuilt on visible-state change or ≥1 s cadence while playing for the progress. The MediaSession stays active (headset/Bluetooth keys, `handleIntent` routing) — only the notification template changed. `ic_stat_play` vector is the small icon. Verified end-to-end on-device: row visible in shade while backgrounded, Pause→Play button flips and drives the player.
    - **Pause-on-background removed (2026-08-26)**: `player_screen.didChangeAppLifecycleState` no longer calls `_exo?.pause()` when backgrounded — that defeated the whole feature (audio died on HOME despite the service). Background = bookmark position only; playback continues. `_reopenAfterBackground` now ONLY reopens when the native player reports `STATE_IDLE` (media lost to a platform-view recreation); the `_isNetworkSource` force-reload branch and the unconditional `play()` on resume are gone — a user-paused player stays paused on return. The iOS WebDAV TCP-kill concern is covered by background-audio mode keeping sockets alive + the existing IO-retry path.
  - **iOS** (`AvPlayerView.swift`, Info.plist): `UIBackgroundModes: [audio]` keeps the process alive while the engine renders (the `.playback` AVAudioSession was already activated at open). `updateNowPlaying()` mirrors title/artist/duration/elapsed/rate into `MPNowPlayingInfoCenter` on every `emit()` (the 0.25 s tick timer keeps elapsed fresh in background); cleared on `.idle`/`.error`, parked at rate 0 on `.ended`. `MPRemoteCommandCenter` play/pause/toggle/changePlaybackPosition targets reuse the method-channel semantics — **`.ended` is terminal in AetherEngine, so replay from the lock screen goes through the same `reloadSession(at:)` path** as the Dart replay button. Targets removed + now-playing cleared in `deinit`. No artwork yet (future: TMDB poster).

- **Startup permissions (2026-08-26)**: every runtime permission is requested at app open (`lib/utils/startup_permissions.dart`, called from the home screen's first frame) instead of mid-playback — Photos&videos + Notifications via system dialogs (instant no-ops when already granted), and **All Files Access** through a one-time in-app explainer dialog that routes to the system page (special permission, no system dialog; prefs-gated per install). The video-open flow keeps its own requests as fallback. **iOS is a deliberate no-op**: the sandbox needs none of these (document-picker grants are system-managed, Now Playing needs no permission); the iOS analog — the **Local Network prompt** — already fires at first open via `AppDelegate.triggerLocalNetworkPrompt`.

- **Repeat / shuffle / A-B / sleep timer (Phase 2, 2026-08-26)**: all four live in the player ⋮ sheet as collapsible sections (same `_tvListTile` dropdown pattern as aspect/speed).
  - **Repeat & shuffle** (`lib/services/playback_modes.dart`): `LoopMode` (off/one/all — named `LoopMode` because Flutter's material library exports a clashing `RepeatMode`) + shuffle, persisted (`dreamplayer.repeatMode`/`dreamplayer.shuffle`). **Repeat one** loops natively on Android via a new `setRepeatMode` channel method → `Player.REPEAT_MODE_ONE` (no ended event, seamless — verified on-device: a 60 s clip still `PLAYING position=14.3s` at t≈78 s); iOS restarts from the Dart ended-handler (`seekTo(Duration.zero)` + `play()` → the engine's play-after-ended reload). **Repeat all + shuffle** drive folder loops: `_orderedSiblings()` lists the current folder (season/episode-aware ordering, the old `_findNextEpisode` list source refactored out) and `nextPlaybackIndex()` (pure, unit-tested) picks sequential/wrapping/random — shuffle never repeats the current file when the folder has >1; a single-video folder replays itself under repeat-all. Ended-routing priority: sleep-at-end → repeat-one → (latched) repeat-all/shuffle → existing auto-play-next. Jellyfin folders stay sequential-only (no sibling listing yet).
  - **A-B repeat**: ⋮ sheet sets A/B at the current position (per-video, cleared on open); the event handler seeks back to A when playing position passes B (skipped while dragging). Status label shows `A m:ss – B m:ss`.
  - **Sleep timer**: Off / 5 / 10 / 15 / 30 / 60 min / **End of current video**. Minute-based arms a 1 s ticker (`_sleepTicker`, countdown shown in the sheet subtitle, fires → pause + SnackBar); end-of-video sets a flag consumed by the ended-router so nothing auto-plays after. Timer survives auto-next opens, cancelled on player dispose. **Radio-only-checked fix (2026-09)**: all minute-option radios appeared checked simultaneously because the ternary `(_sleepUntil != null ? option.$1 : Duration.zero) == option.$1` evaluated true for every row; fix: track armed Duration in `_sleepOption` field and compare against `option.$1` directly. **Live-countdown fix (2026-09)**: the 1s ticker called `setState` on the player screen, not the `StatefulBuilder` inside the modal sheet, so the countdown label and radio states froze; fix: capture `setSheet` in `_sheetSetSheet` field and call it from the ticker.

- **Play URL + audio delay (Phase 3, 2026-08-26)**:
  - **Play URL** (both platforms): home **+** → "Play URL" → dialog (`TvTextField`, TV-IME-safe) → any http(s) link plays directly through the normal pipeline (Android `DefaultHttpDataSource`, iOS engine loopback producer). Title = decoded last path segment (fallback host); **resume key is the URL itself** (`url:<url>`), so re-entering the same link resumes. Invalid/non-http(s) input → SnackBar, no navigation. Verified end-to-end on-device: phone streamed `http://<pc>:30000/dp_long.mp4` (`PLAYING position=6194` in dumpsys).
  - **Audio delay (manual A/V sync, Android)**: `AudioDelayProcessor` (`android/.../AudioDelayProcessor.kt`) — a Media3 `AudioProcessor` (PCM16) inserted into every audio sink via `DreamRenderersFactory.buildAudioSink` override (`DefaultAudioSink.Builder(context).setAudioProcessors(...)`; API verified by javap against the 1.10.1 jar). Positive = audio later (samples held back in a pending buffer — audio starts late by exactly the delay), negative = audio earlier (leading samples dropped, frame-aligned). **Dynamic**: `setAudioDelay(ms)` channel handler retunes `@Volatile delayMs` mid-playback without sink reconfig — increasing holds more, reducing flushes the excess immediately; delay==0 drains then passes through (processor stays `isActive()` always to avoid chain reconfig churn). Passthrough (AC3/DTS bitstream on TV) bypasses processor chains natively — no crash. ±5 s clamp. ⋮ sheet "Audio delay" section (Android-only, like the other audio effects): slider −5…+5 s (100 steps) + Reset; session-only, not persisted. **iOS is a no-op** (AetherEngine exposes no audio-offset hook; section hidden) — would need engine-side PCM tap, deferred like bass boost.

- **HDR detection** (`lib/models/hdr_format.dart`, `lib/utils/codec_info.dart`): parses hints like `DV P8`, `HDR10+`, `HDR10` into a `HdrFormat` (incl. `HLG`); maps raw codec names (`dts_hd`, `eac3`, `truehd`, `aac`, ...) to display labels. Live detection from Media3 format info: DV track codecs (`dvhe`/`dvh1`/`dvav`), `colorTransfer` (6→HDR10, 7→HLG). **HDR10+ is detected from the real bitstream** (2026-08): Media3's format info can't tell HDR10+ from HDR10 (both are PQ transfer 6), so `ExoPlayerView.kt` probes the first video samples with `MediaExtractor` for the ST 2094-40 SEI (ITU-T T.35 user data, country `0xB5` / provider `0x003C`, prefix/suffix SEI NAL types 39/40, AVCC + Annex-B handled) on a background thread and emits `isHdr10Plus` in the event map; Dart's `detectMedia3HdrFormat` upgrades to HDR10+ when set. `detectHdrFormat` filename-hint parsing is token-aware (safe on full titles — `Adventure.mkv` stays SDR) but the hint is **not** auto-wired from titles: the top-bar chip and labels reflect only what is actually in the content, so a misnamed file never gets an HDR chip. Probe is best-effort (failure → HDR10 label, playback unaffected); SDR content is never labeled HDR (verified on-device: lake `hdr10+...` file → amber HDR10+ chip via probe, SDR screen-recording → no chip). **iOS (2026-08)**: `ios/Runner/AvPlayerView.swift` mirrors the probe — `scanHdrProbe` scans the first ~8 MiB for HEVC SEI NALs 39/40 (`B5 00 3C` for HDR10+, 137/144 for static HDR10, with raw `B5 00 3C` fallback) plus `engine.videoFormat == .hdr10Plus` fast path, emitting `isHdr10Plus`/`isHdr10` to the same Dart detector; iPad now shows HDR10+ amber chip like Android. **Strict SDR fix (2026-08, `cd06a29`)**: `scanHdrProbe` now requires `137==24 B` with `maxDisplay 50..10000 nits` and `144==4 B` with `10≤maxCLL≤10000` plus luma sanity, and `stateMap` gates `engine.videoFormat` HDR + `colorTransfer` on `hevcFamily` — H.264 SDR no longer aliases HDR10.
- **Real playback** (`lib/screens/player_screen.dart`): Android uses a native **ExoPlayer/Media3 PlatformView** in **hybrid composition** (`lib/services/exo_player.dart` — `PlatformViewLink` + `PlatformViewsService.initExpensiveAndroidView`; the stock `AndroidView` widget is virtual-display + texture and flattens HDR, see the VIRTUAL-DISPLAY gotcha in the top section) with live codec/HDR/resolution chips, play/pause, seek, ±10s, mute, fullscreen, buffering spinner, error surface. Non-Android shows a "not yet supported" message. Widget tests run playback-less (`FLUTTER_TEST` gate).
- **Android permissions**: `READ_MEDIA_VIDEO` (+ `READ_EXTERNAL_STORAGE` ≤ API 32) requested at runtime via `permission_handler` when a video is opened. `compileSdk = 37` required by `permission_handler`.
- **Player overlay** shows HDR format + video/audio codec + resolution chips; library cards show an HDR badge + audio codec label.
  - **DV dedup**: for Dolby Vision the purple HDR chip already says "Dolby Vision", so the redundant video-codec chip is suppressed (no "Dolby Vision" twice).
  - **Chip layout**: landscape puts back button + title + chips in one `Wrap` on the same row; portrait shows title row, then chips `Wrap` below.
- **Player controls**: top bar (back + title) and a slim bottom bar (time + seekbar + audio/CC/aspect/fullscreen) auto-hide after 3 s of playback (tap toggles them; kept visible while paused/buffering/dragging). **Center transport**: `replay_10` / big play-pause / `forward_10` float in a dark rounded pill in the middle of the screen, fading with the other controls. The bottom bar's background is a gradient mirroring the top bar (transparent → `black` 0.72), so both bars read at the same opacity. The player screen is **always immersive** (no system UI toggling during rotation — that fights the rotation animation and makes the video jitter); the bottom fullscreen button just forces landscape/portrait. Top-bar fullscreen button removed. **Play-pause ring highlight on touch devices** (2026-08): `_TvControlButton` gained `alwaysShowRing` — when set, the button always renders its ring highlight (border + glow) even without keyboard/remote focus. The center play-pause button uses `alwaysShowRing: !_isTv` so the ring is visible on phones/tablets without a D-pad. On TV the D-pad focus handles it as before.
- **Aspect / fit-mode picker** (`VideoFitMode` in `exo_player.dart`): the bottom bar's `tune` button opens an "Aspect ratio" sheet with five modes — Fit, Crop to screen, Stretch to screen, 16:9, 4:3 — scrollable and height-capped so it can't overflow in landscape. Choice applies to the native surface (`setResizeMode`) and persists via `FitModeStore` (`dreamplayer.fitMode`), re-applied on every open. Android: `applyFitMode` maps to Media3 `AspectRatioFrameLayout` — Crop to screen = `RESIZE_MODE_ZOOM`, Stretch to screen = `RESIZE_MODE_FILL`, fixed ratios (16:9 / 4:3) = a forced aspect box + zoom-crop (`ForcedAspectPlayerView.forcedAspect`). iOS: `AvPlayerView.setResizeMode` maps to the `AVPlayerLayer.videoGravity` found in the AetherPlayerView hierarchy (fit=`resizeAspect`, crop + fixed ratios=`resizeAspectFill`, stretch=`resize`); fixed ratios are approximations — exact boxes need the engine's own layout hooks, revisit on-device on the iPad.
- **Audio track selection** (mute button replaced): the bottom bar's first button opens an "Audio tracks" bottom sheet listing every audio track from the native Media3 `currentTracks` (language · codec · channels · bitrate), with the active track check-marked. Picking a track calls `setAudioTrack` → native `TrackSelectionParameters` override → `onTracksChanged` re-emits → the top-bar audio chip (live codec + channel count) updates automatically. Native plumbing in `android/.../ExoPlayerView.kt` (`buildAudioTracks`, `selectAudioTrack`), pushed on every event as `audioTracks`/`selectedAudioTrack`; Dart model `ExoAudioTrack` in `lib/services/exo_player.dart`. Verified on-device: Sonic (DTS-HD MA + FLAC) switches DTS-HD → FLAC and the chip follows. **Default + resume (2026-09)**: MPV pins the container DEFAULT track on open and both engines restore the last pick on resume — see "MPV default audio track + resume restore" above.
  - **Full track names**: the sheet prefers the container-provided track `label` (e.g. `DTS-HD MA 5.1`, `Commentary`) and appends the channel count unless the name already carries it; otherwise it composes `languageName(lang) · codec · channels`. `ExoAudioTrack` gained a `label` field; ISO-639 codes map to full English names via `languageName()` in `codec_info.dart`.
  - **iOS audio fixes (2026-08, 0.3.5)**: **network sources** (WebDAV / Jellyfin / FTP — AetherEngine loopback/`ByteRangeSource` can't re-probe in place, so `AvPlayerView` now proactively `reloadSession` + `waitForEngineReady` (`PlaybackState` `.playing`/`.paused`) and re-applies the track); **opposite-track bug** — `audioTrackMaps` used to emit native `id` as `index` while Dart treated `index` as flat position, so `engine.selectAudioTrack(index:)` hit the wrong track — now iOS mirrors Android (`index` = flat pos, `selectedAudioTrack` = flat pos via `firstIndex(where: id == active)`, `engineAudioId(forFlatPosition:)` converts flat→`id` at the boundary).
- **FLAC via FFmpeg + E-AC3 decoder workaround**: a custom `MediaCodecSelector` in `ExoPlayerView.kt` does two things: (1) returns no decoder for `audio/flac` so FLAC falls through to the bundled FFmpeg renderer — the platform MediaCodec FLAC decoder on some devices (incl. this OnePlus) allocates fixed 32 KiB input buffers and large FLAC frames (24-bit multichannel ~54 KiB) die with `DecoderInputBuffer$InsufficientCapacityException: Buffer too small`; (2) skips any `c2.dolby.eac3.decoder` for `audio/eac3`/`audio/eac3-joc` — on this OnePlus the codec2 resource manager repeatedly releases that hardware decoder as soon as it starts, so Media3's audio renderer spins in an endless re-init loop and **no AudioTrack is ever created (silent playback)**. With the Dolby component excluded, the AOSP software E-AC3 decoder is used and the renderer is stable. Verified on-device: Sonic FLAC plays continuously; an E-AC3 (Dolby Atmos, 5.1) track plays with an active AudioTrack (48 kHz, channelMask `0x3f`, no churn, no errors).
- **NextRenderersFactory killed hardware video decode — root cause of 4K60 lag + washed-out HDR (2026-08, Redmi Note 10)**: the app originally built the player with nextlib's `NextRenderersFactory` (`io.github.anilbeesetti.nextlib:media3ext`, pulled in for its FFmpeg audio). Its `buildVideoRenderers` calls `super` then inserts `FfmpegVideoRenderer` at **index 0** — *before* `MediaCodecVideoRenderer` — and `FfmpegLibrary.supportsFormat` claims `video/hevc`, so **every HEVC file decoded in FFmpeg software**: 4K60 stuttered (Snapdragon 678 cannot software-decode it) and colors were washed out because the FFmpeg GL output carries no HDR dataspace (SF composite: `dataspace 0x0`, `hdr metadata types=0`). Diagnosed by A/B against moneytoo's Just Player (`com.brouken.player`), which uses the **stock** `DefaultRenderersFactory` (`setExtensionRendererMode(mPrefs.decoderPriority)` + `setMapDV7ToHevc`, zero manual HDR code): same file, same `OMX.qcom.video.decoder.hevc`, its layer composited `BT2020_ITU_PQ hdr metadata types=1`. Fix: new `DreamRenderersFactory` (`android/.../DreamRenderersFactory.kt`) — a `DefaultRenderersFactory` subclass that overrides **both** `buildAudioRenderers` (appends nextlib's `FfmpegAudioRenderer` **at the end** for DTS/TrueHD/FLAC) and `buildVideoRenderers` (appends `FfmpegVideoRenderer` **at the end** as a software fallback for hardware decode failures). `EXTENSION_RENDERER_MODE_ON` ensures the FFmpeg video renderer is used only when no MediaCodec decoder can handle the format. Verified on Redmi: Sony 4K60 → `[OMX.qcom.video.decoder.hevc] setting surface generation` (hardware session), SF layer `dataspace=BT2020_ITU_PQ hdr metadata types=1` — byte-for-byte the Just Player profile. Note: on API 26–32 the `TIRAMISU` gate keeps `applyHdrHeadroom` off, so SF auto-tone-maps HDR→SDR (correct for a 500-nit HDR10 panel).
- **Subtitles — embedded + sideloaded with a full track picker**:
  - **Sibling auto-pairing** (`android/.../SubtitleFormats.kt` `findSiblingSubtitles`): on open, scans the video's folder and attaches **every** subtitle file as a Media3 `SubtitleConfiguration` (exact-filename-prefix match wins; ordered best-match first). The best match carries `SELECTION_FLAG_DEFAULT` so it's auto-selected; all others remain selectable in the picker. An explicitly passed `subtitleUri` still wins over pairing.
  - **`open()` path fix**: `lib/services/exo_player.dart` `open()` now sends `path` even when a `uri` is present — intent-opened files were dropping the path, so sibling pairing never fired. Verified on-device.
  - **Formats**: SRT, SSA/ASS, WebVTT, TTML/DFXP, SAMI (`.smi`), MicroDVD (`.sub`), MPL2 (`.mpl2`), SubViewer (auto-detected inside `.sub`). `SubtitleFormats` maps extension → MIME (incl. custom `application/x-sami`, `application/x-microdvd`, `application/x-mpl2`).
  - **Custom parsers** (`android/.../DreamSubtitleParserFactory.kt`): Media3's stock `DefaultSubtitleParserFactory` lacks SAMI/MicroDVD/MPL2/SubViewer, so `DreamSubtitleParserFactory` adds `SamiParser` and `FrameSubParser` (MicroDVD/MPL2/SubViewer modes) and delegates everything else (SubRip, SSA, WebVTT, TTML, PGS, VobSub, DVB, TX3G, CEA) to the default. Wired into both `DefaultMediaSourceFactory` and `DefaultExtractorsFactory` so the `SubtitleExtractor` picks it up.
  - **Charset handling**: Media3's text parsers decode UTF-8 only; `SubtitleFormats.toUtf8` detects BOM/strict-UTF-8 vs CP1252 and re-encodes non-UTF-8 sidecars to a cache file so legacy `.srt` files don't render as mojibake. `decodeToString` strips UTF-8 BOM for the custom parsers.
  - **Subtitle picker** (`lib/screens/player_screen.dart`): the bottom bar's CC button opens a sheet listing every subtitle track from native `currentTracks` (embedded container tracks + sideloaded files) plus Off. Labels append the format so sibling files read uniquely (`House.S02E04.eng · SRT`, `House.S02E04 · WebVTT`). Picking a track calls `selectSubtitleTrack` → native `TrackSelectionParameters` override; `selectedSubtitleTrack` re-emits → the CC button reflects the real selection.
  - **Note**: sibling auto-pairing needs `MANAGE_EXTERNAL_STORAGE` — without it, `listFiles()` only sees MediaStore-indexed files (SRT/TTML/SMI) and `.ass`/`.vtt`/`.sub`/`.mpl2` are silently skipped. Every `flutter install` re-revokes All Files Access on Android; re-grant via `adb shell am start -a android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION` (can't be granted via `adb shell pm grant` — this device blocks it).
   - Verified on-device (`House.S02E04` MKV + 7 sidecar formats): embedded PGS + all 7 sidecars attach, best-match `.eng.srt` auto-selected.
   - **OpenSubtitles online search (2026-08)**: CC sheet → "Search online subtitles…" (`lib/screens/opensubtitles_sheet.dart` + `lib/services/opensubtitles_client.dart`) via `api.opensubtitles.com` REST. Search `GET /api/v1/subtitles?query=&languages=&moviehash=` (hash = OpenSubtitles 64-bit first+last 64 KiB via `opensubtitlesHashForFile` when local path available, ordered by `download_count` desc). Download `POST /api/v1/download {file_id}` with `Api-Key` alone = **5/day/IP anonymous**, plus `Authorization: Bearer <JWT>` after `POST /login` = **20/day free** (VIP more); `403` quota → login dialog then retry. Link fetched via `fetchBytes` (retry on `SocketException` RST with `persistentConnection=false`, `c6f616c`), saved persistently to `getApplicationSupportDirectory()/opensubs/<resumeKey>/<fileName>` via `DownloadedSubtitlesStore` (`dreamplayer.downloadedSubs` JSON) and applied mid-playback by copying `_current` with `subtitleUri` and `await _reopenAt(pos)`. Downloaded section appears **at top of CC sheet before embedded tracks** (Nova-style) per-video, re-selectable without re-downloading. Settings → Subtitles → **OpenSubtitles** tile shows login state / remaining downloads and handles sign-in/out (token `dreamplayer.opensubtitlesToken` persisted 23h). Key via `--dart-define=OPENSUBTITLES_API_KEY` (`lib/config/opensubtitles_api_key.dart`, gitignored `.env` like TMDB).
- **File browser (CX-Explorer style)** (`lib/screens/file_browser_screen.dart`): browse storage in-app and play any video without importing. **Back goes up one folder at a time** — only a folder whose path IS a root returns to the roots list; any other folder loads its parent (even when the parent is itself a root), so back from a folder inside a root lands on that root's contents, not on "Browse files". Reached from the home **+** button → "Internal storage" (the root list no longer shows a "Pick a folder" tile — adding folders lives on the home **+** menu's "Add folder to library"). Android side (`android/.../FileBrowser.kt`, channel `dreamplayer/files`): `hasAllFilesAccess` / `openAllFilesAccessSettings` / `getStorageRoots` (internal + SD card) / `listDirectory` (folders then video files, sorted, with sizes) / `pickFolder` (launches `ACTION_OPEN_DOCUMENT_TREE`, persistable URI grants stored in SharedPreferences as `dreamplayer.folderBookmarks`, result delivered via `MainActivity.onActivityResult` → `FileBrowser.onFolderPicked`) / `pickLibraryFolder` (same picker, but stores the tree under a library-only `libfolder.<uuid>` key so it never becomes a file-browser root) / `removeBookmark` / `removeLibraryBookmark`. Bookmarked trees are appended to `getStorageRoots` with a `bookmarkId` and are listed through `DocumentFile` via synthetic paths `tree:<id>` / `tree:<id>/<relative>` (directory entries keep the synthetic path for back-navigation; video entries carry their `content://` document URI so `file_browser_screen.dart` passes it as `VideoItem.uri`, like the "Open with" flow). Requires **`MANAGE_EXTERNAL_STORAGE`** (All Files Access) on Android 11+ — the screen shows a "Grant access" button that opens the system settings and re-checks on app resume (the folder picker works without it, but browsing does not). iOS side (`ios/Runner/FileBrowser.swift`): sandboxed, so the root list is a virtual **"Files"** entry (`isFilesHome: true`, synthetic path `dreamplayer/files-home`) that opens the **system document picker** — the real Files-app home (iCloud Drive, On My iPad, Downloads, other providers); picking a video imports it (`importFile` → bookmark stored in `dreamplayer.importedVideos`, re-granted later via `resolveImportedPath`) and plays it. Below it: the app's Documents folder plus **bookmarked folders picked via the system document picker** (`pickFolder` → `UIDocumentPickerViewController` for `.folder`, `removeBookmark`) — security-scoped bookmarks stored in UserDefaults keep picked folders (iCloud Drive, On My iPad, other providers) readable across launches, so videos outside the sandbox are browsed/played in-app without touching the Files app. The Dart screen shows a "Pick a folder" tile + per-bookmark remove at the root on **both** platforms (subtitle text is platform-specific). Tapping a video builds a `VideoItem` and pushes `PlayerScreen`. Verified on-device (Android): Internal storage → Download → video → Dolby Vision People plays with live HDR/codec chips.
- **"Open with" / file-explorer integration** (`AndroidManifest.xml` `ACTION_VIEW` intent-filters for `content`/`file` schemes + video MIME types incl. `video/*`, matroska, mpeg, ts, avi, wmv, octet-stream): tapping a video anywhere on the device now offers DreamPlayer. `MainActivity` resolves the intent (file path or `content://` URI + display name via `OpenableColumns`) and forwards it over the `dreamplayer/intent` channel (`getInitialIntent` on launch / `open` on `onNewIntent`); `lib/services/open_intent.dart` turns it into a `VideoItem` and pushes `PlayerScreen` via a global `appNavigatorKey` in `lib/app.dart`. `VideoItem` gained an optional `uri` (content URIs) with `path` now nullable; `ExoPlayerView` opens a raw URI when no path is available. Verified on-device: "Open with" chooser lists DreamPlayer and launches Dolby Vision playback.
  - **CX Explorer network-stream handoff**: CX hands SMB videos to players as `http://127.0.0.1:<port>/SMB/...` (its own local HTTP proxy), so the intent filter additionally declares `http`/`https`/empty schemes (`<data android:scheme=""/>`) + the full container-MIME matrix (`video/x-matroska`, `application/octet-stream`, `application/mpeg`, ... — a single filter, since per-vendor MIMEs differ), and `android:usesCleartextTraffic="true"`. Media3's `DefaultDataSource` handles file/content/asset itself and sends every other scheme (http/https) to the base factory, so `ExoPlayerView.kt` wires `DefaultHttpDataSource.Factory()` as that base — CX's proxy streams arrive there with no fallback and no extra code. Verified on-device via logcat: 4K HEVC lossless (3840×2176@60) streamed through CX's proxy decoded at a steady 60 fps / **0 discarded frames** for a full session (`c2.qti.hevc.decoder` telemetry), only jank = the app's cold start.
- **Home/settings status bar**: `RootShell` maps `MediaQuery.viewPadding.top` into `padding` (Android edge-to-edge reports `padding.top == 0`), so `SliverAppBar` never overlaps the status bar.
- **User-added folder library** (`lib/services/library_folders.dart`, `lib/services/folder_scanner.dart`, `lib/widgets/folder_card.dart`, `lib/screens/folder_screen.dart`): the home "Your library" section lists **only folders the user explicitly adds** (home **+** → "Add folder to library") — nothing is auto-scanned. Adding a TV-show folder kicks off a TMDB lookup (`TmdService.resolveFolder`, TV-biased via `TmdApi.bestForQuery`); the card shows the show's poster + real title + TV/Movie badge. **SMB/WebDAV folders can also be bookmarked straight from their browser** AppBar (`LibraryFolderSource.smb|webdav` + per-source badge); **Jellyfin/FTP/DLNA are browse-only** (2026-09, `home_screen._loadLibraryFolders` purges legacy `jellyfin|ftp|upnp` bookmarks) and are accessed via `+` → Jellyfin/FTP/DLNA. Tapping a folder opens its contents (subfolders navigable; episodes listed with parsed `SxxExx` + size; local route via `TmdDetailsScreen`, network sources open `FolderScreen` directly), and tapping an episode goes to `TmdDetailsScreen` → player. Long-press a folder card to remove it from the library (files untouched). **Deep recursive scan (2026-09)**: `FolderScanner` (`lib/services/folder_scanner.dart`) scans up to 5 levels deep (local/SMB/WebDAV for Home bookmarks; Jellyfin/FTP/UPnP still support listing when browsing). Leaf folders (videos, no subdirs) become single library entries; mixed containers (subdirs + loose files) expand into individual cards so files like `lanterns s01e05.mkv` aren't hidden behind a parent `TV Shows` card. Each season auto-expands into a separate card (`House Season02`, `House Season03` via non-strippable `Season02` tag) so the user can manually group them on Home. `LibraryFoldersStore.bulkAdd` deduplicates by `(source, networkPath)` in addition to `id`.
- **Horizontal-swipe seek (2026-08-22)**: swipe left/right on the video scrubs **±90 s per screen width** (clamped to the file); a dark pill shows target timestamp + signed delta (green/orange); release commits if |Δ| ≥ 500 ms; skipped when `_isTv` (`_swipeGestureActive` keeps the pill icon stable through its 800 ms fade). **Time-only by design** — frame thumbnails were built then REMOVED: `MediaMetadataRetriever` returns uniform ~1.5 KB black JPEGs for DV/HDR content on Qualcomm (`c2.qti.dv.decoder`, 4K DV file), so previews were blank exactly where it matters; SDR H.264 extracted fine. Do not re-add MMR-based thumbnails for HDR content.
- **Subtitle appearance settings (2026-08-22)**: Settings → Player → Subtitles (`lib/screens/subtitle_settings_screen.dart`) — size S/M/L/XL, color swatches, background none/semi/solid, outline, delay −30…+30 s, live preview. Persisted as `dreamplayer.subStyle` JSON (`SubtitleStyle` model + store); sent to the native player via `setSubtitleStyle` on open and on change. Android `ExoPlayerView.applySubtitleStyle`: Media3 `CaptionStyleCompat` + `setFractionalTextSize(SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * multiplier)` (**the API name is `setFractionalTextSize(float)`, not `…WithViewHeight`** — that name doesn't exist in media3-exoplayer-ui). iOS `AvPlayerView.applySubtitleStyle` styles the overlay label AND shifts cue evaluation by the delay. **Delay is iOS-only** — Android needs cue-pipeline plumbing to offset timing. Preview: adaptive box over `assets/preview_backdrop.jpg` (Pexels still, free license) — portrait full-width 16:9, landscape ≤ 42% of viewport height with a 120 dp floor (**gotcha: never `.clamp(a,b)` with computed bounds — landscape made min > max → `ArgumentError: 96.0`; cap imperatively instead**, regression-tested at 800×360).
- **Player gesture controls** (2026-08): vertical swipe on the **left half** adjusts **brightness** (`WindowManager.LayoutParams.screenBrightness` on Android, `UIScreen.main.brightness` on iOS — both per-app, revert on player close); vertical swipe on the **right half** adjusts **volume** (`AudioManager.setStreamVolume(STREAM_MUSIC)` system-wide on Android, `MPVolumeView` hidden slider on iOS). A centered dark feedback pill (icon + percentage + progress bar) fades ~0.8 s after gesture ends. Controls hide during the gesture. Wired through the `PlaybackController` interface (`setBrightness`/`getBrightness`/`setSystemVolume`/`getSystemVolume` on both `ExoPlayerView.kt` and `AvPlayerView.swift`). **Settings toggle**: "Swipe gestures" switch in Settings → Player section, default on, hidden on TV via `isTvMode()`.
- **Continue watching** (`lib/services/continue_watching.dart`): the home library grid lists every video with a saved resume position, most recent first, with a progress bar + "Continue from m:ss" subtitle. `ResumeStore` keeps the playhead (position bookmarked every ~5 s, on pause/background/dispose, cleared at the end); `ContinueWatchingStore` (shared_preferences JSON key `dreamplayer.continueWatching`) mirrors it into lightweight `VideoItem` JSON (id/title/path/uri/resumeKey/duration/sizeBytes) for positions ≥ 10 s. Long-press a card to drop it from it. **Source badge**: each card shows a bottom-left badge naming where the video plays from — `VideoItem.playbackSource` (enum `PlaybackSource` in `video_item.dart`) maps the `resumeKey`/`uri`/`path` to WebDAV (`webdav_` key), CX SMB (`cx:`), Files / SMB (`folderbookmark:` iOS pick-a-folder), legacy SMB (`smb:` or `smb_` prefix), Files (`content://`, `file://`, plain path), or Network (other http/https); `video_card.dart` renders it with a per-source color. **Badge fix (2026-08)**: `playbackSource` getter now accepts both `smb:` and `smb_` prefixes for backward compatibility with stored data; new SMB entries use `smb:` (colon) consistently. **No thumbnails**: ~~cards show the gradient/play-icon placeholder only~~ superseded 2026-08-26 — cards now show the file's **embedded cover art** via `ThumbnailStore` (metadata-only read; see "Embedded cover-art thumbnails" in Implemented features). Frame-extraction thumbnails stay removed (`getFrameAtTime`/`AVAssetImageGenerator` return black frames for DV/HDR — do not re-add). The player `open()` re-grants the iOS security-scoped bookmark before playback.
- **Responsive grid** (`lib/screens/home_screen.dart`): column count and card height computed from screen width; card text is `Expanded`/`Flexible`. Text scaling clamped to 1.3x app-wide.
- **Native refresh rate** (`lib/services/display_refresh_rate.dart`): calls `FlutterDisplayMode.setHighRefreshRate()` on Android at startup.
- **Resume playback** (`lib/services/resume_store.dart`, shared_preferences): a video stopped mid-way resumes from where it left off on the next open. Position is bookmarked every ~5 s while playing, on pause, on app-background, and on player dispose; cleared when the video plays to the end. `ExoPlayerController.open` gained `startPositionMs` (native: iOS passes it as `startPosition` to `engine.load`, Android seeks before `play()`). Resume keys are the file path / content URI by default; sources whose playable URL rotates between sessions (iPad SMB token URLs) pass a stable `VideoItem.resumeKey` (`smb:<serverId>/<share>/<path>`). Skips trivial positions (<10 s) and "basically finished" ones (within 5 s of a known duration).
  - **Lock/unlock survival (2026-08)**: Android destroys the video surface on lock and may recreate the whole platform view on unlock, leaving a fresh ExoPlayer reset to IDLE while the UI still shows the old playing state. The player screen pauses on background (saving the position) and, on resume, queries the native player's live state via a new **`getState`** channel method (`dreamplayer/exo_<id>`): if the media was lost (IDLE) it reopens at the saved resume position, otherwise it just continues playing. `getState` is implemented on both Android (`ExoPlayerView.kt`, `state`/`positionMs`/`durationMs`) and iOS (`AvPlayerView.swift`) behind the shared controller contract. Related fix: a launcher tap after unlock (singleTop `MainActivity` MAIN intent via `onNewIntent`) must not push an empty player — non-VIDEO intents return null and are ignored in Dart (`open_intent.dart`) and skipped natively.
  - **Stable resume keys for network/file-provider sources (2026-08)**:
    - **iOS bookmarked folders** (FileBrowser.swift): every video listed under a bookmarked-folder root (iCloud Drive / On My iPad / SMB via Files "Connect to Server") carries `resumeKey: folderbookmark:<bookmarkId>:<path-relative-to-CURRENT-mount>`. The relative part is computed against the re-resolved bookmark root each listing, so the key survives the provider remounting the share at a different path between launches. Continue-watching card taps re-grant the folder's security-scoped access via a new `resolvePath` channel method (`dreamplayer/files`) — it falls back to the per-file imported map, then matches any folder bookmark whose resolved URL is a path prefix of the file. (`resolveImportedPath` alone never matched folder bookmarks, so a card tap after relaunch could fail with a permission error.) Android's `resolvePath` is a no-op `true`.
    - **Android CX Explorer SMB proxy** (open_intent.dart `_stableResumeKey`): CX hands SMB videos to "Open with" as `http://127.0.0.1:<port>/SMB/<server>/<share>/<file>`; the port rotates every CX session, so `OpenIntent.toVideoItem()` keys on the stable path portion only (`resumeKey: cx:<path>`). Reopening the same file via CX after the port changed resumes from the saved position. The card's stored `uri` still holds the session's URL, so tapping it replays only while CX's proxy port is still alive (post-CX-restart it shows the playback error — re-open via CX to continue).

- **In-app SMB / LAN playback: BOTH platforms (0.5.1)**. The Android in-app SMB server browser (`smb_screen.dart`, `smb_client.dart`, `SMBClient.kt`, `SmbDataSource.kt`, channel `dreamplayer/smb`, jcifs-ng) is unchanged. iOS, withdrawn in 2026-08 (AMSMB2 was slow, would not play every file, and an audio-track switch could crash), is back: browsing on pure-Swift `SMBClient`, **discovery and playback on libsmb2**, with playback fed to AetherEngine through a synchronous `smb2_pread` `IOReader`. See "iOS in-app SMB on libsmb2" in the roadmap section for the full architecture, the path/resume-key shapes, and the resume + audio-track interaction. `BufferedSMBReader.swift` stays for WebDAV/FTP read-ahead and the `AetherEngineSMB` SPM product stays for WebDAV's `ByteRangeSource`.
  **Android lessons retained**: jcifs-ng's streaming read size is bound by three interlocking properties (`snd_buf_size`/`rcv_buf_size`/`transaction_buf_size`, defaults 65535); raising only the first two did nothing, and raising `transaction_buf_size` to 8 MiB made the NAS reject reads with `STATUS_INVALID_PARAMETER`. Do not raise buffers past the NAS's negotiated `MaxReadSize`.

## Roadmap

### SMB / network shares (Android + iPad)

Play files from LAN/NAS SMB shares in-app, mirroring the existing file-browser pattern.

**Status: in-app SMB on BOTH platforms (0.5.1, 2026-10).** Android is unchanged (`smb_screen.dart`, `smb_client.dart`, `SMBClient.kt`, `SmbDataSource.kt`, channel `dreamplayer/smb`, jcifs-ng). iOS, withdrawn in 2026-08, is back: browsing on `SMBClient`, discovery and playback on **libsmb2** — see "iOS in-app SMB on libsmb2" below. The "Network shares" home tile opens the in-app browser on both platforms again; the Files-app folder picker stays available as a fallback route.


### iOS in-app SMB on libsmb2 (2026-10, 0.5.1) — architecture

**Everything is libsmb2** (LGPL 2.1), vendored under `ios/Runner/libsmb2/` and compiled by `ios/libsmb2_build.sh` (61 translation units → an arm64 `libsmb2.a` that `OTHER_LDFLAGS` links). `ios.yml` runs that compile as a step before the signed IPA, so a vendored-source break fails early and cheaply. It went in three steps: discovery first, then playback, then browsing — `SMBClient` was deleted at the last step and is now only a transitive dependency of `AetherEngineSMB`.

**Browsing** (`LibSMB2Session.listDirectory` → `smb2_opendir`/`smb2_readdir`, directory bit from `smb2_attributes`), **share listing** (`listSharesForHost`) and **stat/byte fetches** (`fileSizeAtPath`, `readFileAtPath`) are all libsmb2 too. SMB2 has **no share-enumeration request**, so the share list probes the same common names Android uses (`COMMON_SHARES`) plus any the user added by hand — identical to Android, and the reason `addShare` now persists the name it was given instead of discarding it.

- **Discovery (phase 1)** — `LibSMB2.probeHosts` does a `/24` TCP sweep (Network.framework, with a hard per-probe deadline inside `nwConnect`), then a real IPC$ negotiate per candidate to report the **dialect** and **server GUID**. This is what identifies SMB 3.1.1 on the NAS. Verified on-device.
- **Playback (phase 2)** — `SMBSourceReader: IOReader` serves the engine's synchronous `read`/`seek` straight from `smb2_pread`. This is the whole point: `IOReader` is cursor-based and `pread` is positional/synchronous, so there is **no bridging, no `Task`, no semaphore and no ring buffer**. The previous SMBClient path adapted an *async* ranged source into that synchronous interface and the release half of that adaptation is what deadlocked. `makeIndependentReader` returns a second cursor over the same open handle — a positional re-probe just needs a fresh cursor, where the old ring reader had already drained itself to EOF.
- **One session, not two.** An intermediate version opened a libsmb2 session *and* an SMBClient session to the same file and kept SMBClient as a fallback: two negotiates, two session setups, two tree connects and two file handles per play, with the SMBClient one never read from. It also spent a server-side open-session slot and held the credentials twice — and some NAS/Samba configs cap concurrent sessions per user, so it could genuinely fail the open. `SMBPlayback` is now libsmb2-only; `SMBByteRangeSource`/`SMBIOReader` stay in the tree unwired so reverting is a one-line change.
- **`LibSMB2File` retains its `LibSMB2Session`.** The engine can hold a reader past the point where the bridge drops the session, and `smb2_destroy_context` frees the context — without the retain, the next read is a dangling pointer.
- **Path shape (2026-10-02, the bug that blocked everything)**: an SMB2 CREATE `Name` is **relative to the tree connect**, and libsmb2 hands the string to the server untouched. Prepending a `\` made every open fail with `STATUS_INVALID_PARAMETER (0xc000000d)`. `openFile:` now strips leading/trailing `/`, converts the rest to backslashes, and adds **nothing**. The resolved share+path is echoed into the error message, because otherwise this failure is indistinguishable from a permissions problem.
- **Resume-key shape (same day)**: `FolderScanner` wrote the SMB resume key as `smb:<serverId>/<path>` while the `videoUri` beside it included the share. The native side reads the **first segment as the share**, so `Video/Movies/…` silently reconnected to a share literally named `Video` — a wrong target that never reports itself as such. Both sites now include `networkShare`; `test/smb_resume_key_test.dart` pins that the key round-trips to the real share and that `path` and `videoUri` agree.
- **Status dot**: `checkServer` had been `result(false)` on iOS, so every saved server showed red. Now a non-blocking `connect(2)` + `poll` with a 1.5 s cap, matching Android's `isPortOpen`, replying on the main thread (a `FlutterResult` invoked off it deadlocks the method channel).
- **Listing hygiene**: `print$` is filtered by the trailing `$` (the share-`type` filter misses it on some servers), and `.`/`..` are dropped **by name before** the directory exemption in `isJunk` — they arrive as directories, and `isDirectory || !isJunk` let them past the dot-prefix rule.

#### iOS SMB browsing parity and small fixes (0.5.1+25)

- **`addShare` now remembers the name.** It documented itself as remembering an unusual share name but only tested connectivity and threw the name away, so the affordance never worked on iOS. Names are stored per server in `ServerMeta.addedShares`, and `saveServer` carries them through so editing a server no longer wipes them (the dialog knows nothing about them). `addedShares` is **optional** so servers saved before the field existed still decode — a synthesized `Codable` ignores a declared default for a missing key, which is why a non-optional list would have silently dropped every saved server.
- **Status dot** is a non-blocking `connect(2)` + `poll` with a 1.5 s cap, matching Android's `isPortOpen`, replying on the main thread (a `FlutterResult` invoked off it deadlocks the method channel).
- **Listing hygiene**: `print$` is filtered by the trailing `$` (the share-`type` filter misses it on some servers), and `.`/`..` are dropped **by name before** the directory exemption in `isJunk` — they arrive as directories, and `isDirectory || !isJunk` let them past the dot-prefix rule.
- **Unnamed server shows its address**, matching Android's `if (name.isNullOrEmpty()) host else name`. Applied on write *and* on read in `allServers`, so servers saved before the fix stop showing a blank row without being deleted and re-entered. Whitespace-only names count as empty, which Android gets from `trim()`.

#### iOS SMB resume + audio-track interaction (three bugs, one root pattern)

All three were "the saved audio track silently destroyed the saved position", and all three were invisible without the device log. The root pattern: **`engine.load(startPosition:)` is ignored for network sources**, so a resume is applied asynchronously by `reassertPosition` (which sleeps ~900 ms before its first attempt). Anything that reloads the session inside that window reads a playhead of ~0.

1. **Reload aimed at the stale playhead.** Dart's audio-track restore fires ~85 ms into the load, read `engine.currentTime` (~0), and called `reloadSession(at: 0.0)`. That ends in `reassertPosition(0.0)`, whose first line is `guard position > 2.0 else { return }` — so the corrective seek **never ran** and the session stayed pinned to 0. Fixed by carrying `pendingResumeSeconds` and preferring it while the playhead is still within 0.5 s of the start, so a stale target can never yank the viewer back mid-playback.
2. **Armed too late — a no-op first attempt.** The target was initially set *after* `engine.load` returned, but that call does not return until the container is probed, and the restore arrives ~75 ms *into* that window. The fix was live only for a fraction of the window it needed to cover. Now armed immediately before the load.
3. **The default track played before the saved one.** A custom source cannot switch tracks in place, so the saved track needs a reload — and a reloaded session autoplays the container default. The viewer heard ~300 ms of the wrong language first. The reload is now issued with `autoplay: false`; `reloadSession` pauses the new session synchronously right after `engine.load` returns and before any `await`, with a second pause once the engine is genuinely ready (a pause issued while still loading can be dropped). A first attempt gated the hold on `engine.state == .playing`, which can **never** be true there — the engine is in `.loading`, which is exactly what makes `atSessionStart` true — so it was a silent no-op. Mid-playback switches are deliberately untouched: they reload at the current position, so there is no gap to hide.

`AvPlayerView.pendingResumeSeconds`, `reloadSession(at:autoplay:)`, and `reloadSession: paused on load` are the three things to check if any of this regresses. **Lesson: assert new log lines appear in the device log before trusting a fix here — two of the three above looked correct on paper and did nothing.**

**Architecture**
- New native module per platform exposing a MethodChannel (same shape as `FileBrowser.kt` / `dreamplayer/files`):
  - Android: `SMBClient.kt` (jcifs-ng) — channel `dreamplayer/smb`
  - iOS/iPad: `SMBBridge.swift`, which serves the same channel and is backed by
    libsmb2 rather than a separate Swift SMB client
- Dart: `lib/services/smb_client.dart` (models + channel wrapper) + `lib/screens/smb_screen.dart` (server list → shares → folders → tap video → `PlayerScreen`).
- Playback passes an `smb://` URI through the existing `uri` path in `VideoItem` (like the "Open with" flow).

**Libraries**
| Platform | Choice | Why |
|---|---|---|
| Android | **jcifs-ng** (SMB2/3 only) | Nova's and CX File Explorer's SMB library; measured ~75 MB/s vs ~4–6 MB/s for smbj on the NAS. |
| Android (optional) | jcifs-ng SMB1 | SMB1 legacy devices only (disabled by default; SMB1 support is behind a config flag) |
| iPad | **removed (2026-08)** | AMSMB2 / SwiftSMB retired; NAS playback is WebDAV / Jellyfin / Files-app "Open with". `AetherEngineSMB` still ships for WebDAV's `ByteRangeSource`. |
- **Licensing**: libsmb2 is LGPL-2.1 (constrains App Store distribution — needs relinkable/replaceable lib); app already ships GPLv3 FFmpeg extension so not a new concern for Android.

**Features**
1. *Servers*: add/edit/delete saved servers (name, host/IP, port 445, user, password, or Guest); credentials in Keychain (iOS) / Android Keystore (EncryptedSharedPreferences), never plaintext; LAN auto-discovery (broadcast/workgroup) + manual IP fallback; test connection + quick connect; saved-server status dot (online/offline).
2. *Browsing* (CX-Explorer style): server → shares → folders → files; breadcrumbs + up-nav; folders first, sorted by name/size/date; show size + modified date; player back returns to same folder.
3. *Playback*: direct streaming (no download) — Android = custom ExoPlayer `DataSource` over jcifs-ng seekable reads; iPad = `AVAssetResourceLoaderDelegate` serving bytes from the SMB stream; full seek; existing live HDR/codec chips unchanged; play-next-episode in folder; optional prefetch/cache-ahead setting + reconnect-on-drop/resume for high-bitrate files.
4. *Extras*: auto-pair subtitles from same folder (`.srt`/`.ass`); pin recently-used servers on home screen; DNS/WINS hostname resolution for NAS names.
- **Scope (v1)**: manual server add + Guest/basic auth + browse + stream + play-next. Add discovery + subtitles after.
- **Status**: v1 core landed (Android): discovery, status dots, play-next-episode and subtitle auto-pair are implemented and the app is running on-device; **verified against real NAS on-device (2026-08-26, user) — streaming/seek + subtitles + play-next + reconnect-on-drop/resume for high-bitrate files confirmed**. **SMB watched ticks + SIMKL backfill (2026-08)**: every SMB file row shows a green watched check + per-row toggle (`WatchedStore`, keyed `smb:<serverId>/<share>/<path>` — the same resume-key shape as the TMDB prefetch), and an AppBar cloud-done button syncs already-watched titles from SIMKL. **SMB folder → Home bookmark (2026-08)**: the SMB browser's AppBar bookmark button pins the current folder to the home library (`LibraryFolderSource.smb` + blue SMB badge; see "Library (user-added folders)" roadmap section). The Nova-style read-ahead ring buffer is implemented. Remaining: iPad path (needs SMB2 client on Swift side, currently via Files app). **TMDB auto-fetch on video tap (2026-08)**: tapping an SMB video opens the details screen already resolved — the browser prefetches metadata under the same stable key the tap uses (`smb_<serverId>/<share><path>`) so the prefetched match is a direct cache hit (before, the two used different keys and the tap re-searched — and a tap during an in-flight prefetch returned a false "no match" via the old `Set`-based deduper; `TmdService` now dedupes with a `Map<String, Future<TmdMeta?>>` so concurrent callers share one in-flight search). Verified on-device: `Silence`, `Identity`, `Oldboy`, `Her (2013)`, `24`, `Main Vaapas Aaunga` all resolved to score-1.00 matches from the SMB folder prefetch.
- **iOS/iPad status — shipped then DELETED (2026-08)**: the in-app SMB browser + playback landed for iPad via **AMSMB2** (`ios/Runner/SMBClient.swift`, channel `dreamplayer/smb`, same Dart `SmbClient` contract as the removed Android one) + **AetherEngineSMB** (the engine's official SMB product — `SMBConnection` + `SMBIOReader`). `openShare` returned a per-file `dreamplayersmb://<token>.<ext>` URL; the platform view resolved the token to the live `SMBConnection` and loaded it as a custom `IOReader` source (`engine.load(source: .custom(SMBIOReader(...), formatHint: nil))` — the demuxer probed the container itself). `closeShare(serverId)` closed every connection for the server. Servers persisted in UserDefaults (passwords in Keychain, never to Dart); shares listed via `listShares` + manual add-share; directory listing sorted folders-then-videos and auto-paired sibling subtitles (`subtitlePath` downloaded to a temp file — subtitles are small — and returned as a `file://` URL for `ExternalSubtitleTrack`). LAN scan (`discoverServers`) probed the local /24 on port 445. Registered in `AppDelegate`; `NSBonjourServices` + `NSLocalNetworkUsageDescription` in Info.plist; AMSMB2 (SPM 4.0.0) + AetherEngineSMB (product of the AetherEngine package, added to the Runner **Embed Frameworks** phase) were in the project. **Why not the loopback HTTP proxy:** AetherEngine's bundled FFmpeg has **no network stack** — it plays remote URLs through its own "loopback producer" with one long-lived connection + open-ended ranges; a hand-rolled HTTP server (`Connection: close`, no keep-alive) mismatched that protocol and "Share connects but video won't open" persisted across ATS / extension+Content-Type / connect-race fixes (v0.0.3). AetherEngineSMB was the engine-native path for NAS/SMB sources. **Why it was retired (2026-08-13):** it was **slow** and **didn't play every video**, and picking a different audio track on an SMB stream could **crash the app** on-device. The EPERM failure was fixed (`reopenSMBStream` + `SMBClient.reconnect` mint a fresh connection) and the buffering spinner got `BufferedSMBReader`, but a hard crash remained in the reopen/teardown path (stale-connection close racing an in-flight read). Since local playback is smooth and NAS files reach the app via CX/Files "Open with", the entry was removed on all platforms with no feature-loss workaround; the code is gone from the tree, kept as the blueprint below. To revive: fix the teardown race, requiring the iPad crash report/console at the moment of the audio-track tap.
  - **Gotcha fixed on-device — dynamic SPM framework not embedded (code deleted, note preserved)**: AMSMB2's package product is `type: .dynamic`, so linking it into Runner is NOT enough. It must ALSO be added to the Runner target's **Embed Frameworks** copy phase (`PBXCopyFilesBuildPhase`, `dstSubfolderSpec = 10`) as a `PBXBuildFile` with `productRef` + `settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy); }`. Without that, `AMSMB2.framework` is missing from `Runner.app/Frameworks/` (the binary still has an `@rpath/AMSMB2.framework/AMSMB2` load command, so the build passes but dyld crashes at launch with "image not found"). Transitive dynamic products (e.g. FFmpegBuild's xcframeworks pulled in by AetherEngine) are auto-embedded; direct package products added by hand to the Frameworks phase are not. **AetherEngineSMB is the opposite — a STATIC library product (its `Package.swift` `products` entry has no `type:`, so the default static applies; same for its `SMBClient` dependency). It must be in the Frameworks (link) phase + `packageProductDependencies`, and must NOT be added to the Embed Frameworks copy phase — with no `.framework` file to embed, xcodebuild fails with `The file "AetherEngineSMB" couldn't be opened because there is no such file`.** (Note: AMSMB2 is gone from the project; AetherEngineSMB STAYS — WebDAV playback's `ByteRangeSource`/`WebDAVByteRangeSource` live in that module.)
  - **"Share connects but video won't open" fix (2026-08-12, superseded)**: the v0.0.3 loopback-HTTP fixes — (1) ATS (`NSAllowsLocalNetworking` for the `http://127.0.0.1` stream URL, since the native AVPlayer path honors ATS), (2) extension + `Content-Type` on the token URL, (3) synchronous connect before returning the URL — did NOT fix playback on-device; the loopback server was retired in v0.0.4 in favor of AetherEngineSMB (see above). The ATS entry stays in Info.plist (harmless).
  - **Gotcha fixed on-device — dynamic SPM framework not embedded**: AMSMB2's package product is `type: .dynamic`, so linking it into Runner is NOT enough. It must ALSO be added to the Runner target's **Embed Frameworks** copy phase (`PBXCopyFilesBuildPhase`, `dstSubfolderSpec = 10`) as a `PBXBuildFile` with `productRef` + `settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy); }`. Without that, `AMSMB2.framework` is missing from `Runner.app/Frameworks/` (the binary still has an `@rpath/AMSMB2.framework/AMSMB2` load command, so the build passes but dyld crashes at launch with "image not found"). Transitive dynamic products (e.g. FFmpegBuild's xcframeworks pulled in by AetherEngine) are auto-embedded; direct package products added by hand to the Frameworks phase are not. **AetherEngineSMB is the opposite — a STATIC library product (its `Package.swift` `products` entry has no `type:`, so the default static applies; same for its `SMBClient` dependency). It must be in the Frameworks (link) phase + `packageProductDependencies`, and must NOT be added to the Embed Frameworks copy phase — with no `.framework` file to embed, xcodebuild fails with `The file "AetherEngineSMB" couldn't be opened because there is no such file`.**
  - **"Share connects but video won't open" fix (2026-08-12, superseded)**: the v0.0.3 loopback-HTTP fixes — (1) ATS (`NSAllowsLocalNetworking` for the `http://127.0.0.1` stream URL, since the native AVPlayer path honors ATS), (2) extension + `Content-Type` on the token URL, (3) synchronous connect before returning the URL — did NOT fix playback on-device; the loopback server was retired in v0.0.4 in favor of AetherEngineSMB (see above). The ATS entry stays in Info.plist (harmless).

### Player gesture controls (brightness + volume)

Swipe gestures on the player screen to adjust brightness and volume, for **Android phone** and **iOS/iPad**. **Status: DONE (2026-08-21).**

**Implementation:**
- **Gesture zones**: vertical swipe up/down on the **left half** of the video surface adjusts **brightness**; vertical swipe up/down on the **right half** adjusts **volume** (the common player convention, cf. VLC/MX Player). Horizontal swipes are reserved for seek (±10s / scrub) if/when wanted.
- **Brightness**: Android = `WindowManager.LayoutParams.screenBrightness` (0.0–1.0, -1 restores system default); iOS = `UIScreen.main.brightness`. Both are per-app and revert on player close (iOS brightness restored explicitly on dispose).
- **Volume**: Android = `AudioManager.setStreamVolume(STREAM_MUSIC)` — **system-wide media volume**, not per-player; iOS = `MPVolumeView` hidden slider (the only public API for system volume on iOS). Feedback shows the system volume level.
- **Feedback overlay**: a centered dark pill with icon (sun / speaker) + LinearProgressIndicator + percentage, fading ~0.8 s after gesture ends. Controls hide during the gesture.
- **Gesture detection**: `GestureDetector` with `onVerticalDragStart/Update/End` on the transparent tap-catcher layer above the platform view (`HitTestBehavior.translucent`). TV stays untouched (D-pad only — no touchscreen).
- **Settings toggle**: "Swipe gestures" switch in Settings → Player section, default on. Only shown on phones/tablets (hidden on TV via `isTvMode`). Pref key `dreamplayer.swipeGestures`.
- **Native handlers** (both platforms): `setBrightness`/`getBrightness` (window/screen brightness) + `setSystemVolume`/`getSystemVolume` (AudioManager / MPVolumeView). Wired through `PlaybackController` interface in `lib/services/exo_player.dart` and `ExoPlayerController`.

### Android TV

Run DreamPlayer on an Android TV box/panel as a real 10-foot app. **Status: Phase 1–5 done; playback, video passthrough, and audio passthrough all verified on Fire TV Stick 4K (2026-08).**

**Test hardware**: Amazon Fire TV Stick 4K (runs Fire OS, Android-based). TV supports Dolby Vision + Dolby Atmos passthrough. Audio passthrough verified on-device — TV detects Atmos/DTS-HD correctly.

**Core requirement (from the user, 2026-08):** the TV build must pass through, not decode:
- **Video**: Dolby Vision + HDR10/HDR10+/HLG **to the TV panel** (the panel is the display, so the app's existing SurfaceView/compositing path is already correct — the TV displays PQ/BT.2020 natively).
- **Audio**: Dolby Atmos (E-AC3-JOC / TrueHD-Atmos), DTS-HD/DTS:X, DTS, AC3, TrueHD **as a compressed bitstream over HDMI** — when the TV is connected to a soundbar/AVR via **eARC**, the audio must be delivered as the original codec bitstream so the sound system decodes it (NOT decoded-PCM in the app). On the Fire TV Stick, the bitstream goes directly to the TV over HDMI (no eARC needed for TV-decoded Atmos).

**Architecture decision (2026-08): ONE player path everywhere — the in-app hybrid-composition platform view.** A dedicated `TVPlayerActivity` (a second FlutterActivity re-parenting the first activity's FlutterView over a bare native PlayerView in a transparent window) was built, then **fully removed**: it caused the blank-flash / greyed-out-controls issues (the dual-activity overlay stack flips surface generations on decoder format change). TV now plays through the exact same `ExoPlayerController` / `ExoPlayerView.kt` hybrid-composition platform view the phone uses (a real SurfaceView composited device-side — true DV/HDR to the panel, verified `BT2020_ITU_PQ` on the OnePlus). Deleted: `TVPlayerActivity.kt`, `lib/services/tv_player.dart` (`TvPlayerController` + `tvInitialVideo`), the `dreamplayer/tvplayer`-family channels, the `TVPlayerTheme`, the `getRenderMode()` override in MainActivity (reverted to the stock surface default), the `isTvBox` handoff in `ExoPlayerView.open`, and the `tvFinished` event. `isTvBox`/`isTv` stays (TV UI detection for `isTvMode()`); the player screen's `_isTv` UI (D-pad focus, controls, fullscreen hidden) is untouched. The Fire-TV DV→HEVC `mediaCodecSelector` forcing was also removed — the stick's native `OMX.MTK.VIDEO.DECODER.DVHE.STH` DV decoder is used directly (like Just Player), with the non-Fire-TV DV-decoder-first + HEVC-fallback rule kept for DV-less hardware.

**Why it's mostly free already**
- Android TV **is Android** — the whole native stack ships unchanged: ExoPlayer/Media3 + hybrid-composition PlatformView (`ExoPlayerView.kt`), `DreamRenderersFactory`, the DV→HEVC `mediaCodecSelector` fallback, `SmbDataSource` (SMB), WebDAV (`WebDAVClient.kt`), Jellyfin (pure Dart), subtitles, HDR chips. `defaultTargetPlatform == android` already.
- **Video passthrough**: the hybrid-composition SurfaceView is a real SurfaceFlinger layer on the physical output — on a TV this is the panel, so DV/HDR10+ composite as `BT2020_ITU_PQ` directly (the whole point of the VIRTUAL-DISPLAY fix). The `mediaCodecSelector` DV→HEVC fallback handles DV-less hardware; `supportedHdrTypes` on the TV drives which formats get device-composited.
- **Jellyfin/WebDAV/SMB browsing** are focus-based Flutter screens — they need a D-pad pass, not a rewrite.

**Implementation plan (phased)**

**Phase 1 — Manifest & Launcher** (status: done)
- Add `LEANBACK_LAUNCHER` category to the existing launcher intent filter (same `MainActivity`, no new activity)
- Add `<uses-feature android:name="android.software.leanback" android:required="false"/>` — app appears on TV launchers; same APK still installs on phones
- Add `<uses-feature android:name="android.software.touchscreen" android:required="false"/>` — without this, TV devices filter the app out
- Same APK, no build variants or product flavors

**Phase 2 — 10-foot UI Pass (Home + Player only)** (status: done)
- Home screen: `FolderCard`/`VideoCard` wrapped with `Focus` widget + `AnimatedScale` (1.05×) + `AnimatedContainer` (blue border + glow) when focused; D-pad grid traversal works automatically with `SliverGrid` + Material `InkWell`; the home **+** FAB menu is shown on TV too (WebDAV, Jellyfin, Network shares, Add folder, Internal storage — the top-right `SliverAppBar.actions` were removed); "Remove from library" via `onLongPress` (long-press on remote select)
- Player screen (Just Player style, reworked 2026-08): when controls are hidden, D-pad left/right seek ±10s, center/select/media-play-pause toggle play/pause, any other key reveals the controls; when controls are visible, arrow keys drive normal Android focus navigation between the focusable transport buttons (replay_10 / play-pause / forward_10 + audio/CC/aspect buttons) and the system handles button activation on center — the handler only intercepts select/play-pause/seek. `_showControls()` auto-focuses the play/pause button on reveal (`_playPauseFocusNode`). Controls **auto-hide after 3.5 s while playing** (`_restartHideTimer`, `_autoHideAfter = 3500 ms`), stay visible while paused/buffering/dragging, and any remote press reveals them again. **Remote play/pause gotcha (2026-08)**: the dedicated remote media-play/pause keys are intercepted *before* the `okKey` (select/enter/DPAD_CENTER) branch — media keys do NOT activate a focused `InkWell`, so deferring to the focused button made a second play/pause press a dead no-op (pauses but won't resume). Fixed with a `mediaPlayKey` branch that always calls `_togglePlayPause()`. Fullscreen button hidden on TV (always landscape); `_isTv` flag set from `isTvMode(context)` on first build.
- **Custom focus highlight (user-required, 2026-08)**: the system-default focus indicator was rejected as too subtle — all TV-focusable widgets (`_TvControlButton`, `_tvListTile` in bottom sheets, `_BufferedSeekBar`, `VideoCard`, `FolderCard`) share a blue border (3 px) + primary-glow `boxShadow` (40 % alpha, blur 12, spread 2) + `AnimatedScale` (1.25× circular transport buttons, 1.05× cards/list tiles), rendered via a `Focus` + `AnimatedContainer`/`AnimatedScale` wrapper. **Consistency pass**: the same highlight was applied to every sheet row (`_tvListTile`), the seek bar, and the transport buttons so focus is visible everywhere, not just the home grid.
- **TV text input in server forms (`TvTextField`, 2026-08)**: the SMB and WebDAV "Add server" dialogs use plain `TextField`s so the Fire Stick's own Leanback IME (`FireTVIME`) handles typing. The stock `TextField` was unusable with the remote — it auto-opens the IME the instant D-pad focus lands on it, and the keyboard window then swallows the D-pad keys, so focus got **stuck on an empty field** and you could never tab to the next one. `lib/widgets/tv_text_field.dart` wraps each field with the app's blue glow (same 3px border + shadow as the transport buttons) and uses **two `FocusNode`s**: an *outer* glow node that is the D-pad target, and an *inner* `FocusNode(skipTraversal: true)` owned by the `TextField`. `skipTraversal` keeps the field out of D-pad traversal (so the IME never auto-opens and arrow keys keep moving between fields) while still allowing programmatic `requestFocus()` — which fires only on OK/select/enter via the outer node's `onKeyEvent`. When the IME closes (back/Done) the inner node's focus-change listener hands focus back to the outer node so D-pad navigation resumes from that field. **Gotcha**: `descendantsAreFocusable: false` does NOT work here — it flips the inner node's `canRequestFocus` off through its ancestors, silently killing the programmatic `requestFocus()` (focus never reaches the TextField and typing goes nowhere); `skipTraversal` is the correct mechanism. Fields are evenly spaced (`SizedBox(height: 12)` between every field; the WebDAV host/port 3:1 `Row` was replaced with two full-width stacked fields). Verified on-device on the Fire TV: D-pad moves the glow across all six SMB fields with no IME, OK summons the keyboard, typed text lands, and navigation resumes after the keyboard closes.
- **Leanback banner** (2026-08): 640×360 banner image in `assets/banner.png`, wired in `AndroidManifest.xml` as `android:banner` on the `<application>` tag — TV launchers display it instead of the phone icon.
- **Shared TV widgets** (2026-08): `TvTile` (`lib/widgets/tv_tile.dart`) — single source of truth for the TV focus-glow wrapper (blue border + AnimatedScale + AnimatedContainer), used by every browse/settings list item. `TvOverscan` (`lib/widgets/tv_overscan.dart`) — wraps each TV screen with safe-area padding (36 px sides, 20 px top/bottom) to avoid overscan clipping.
- **TV long-press** (2026-08): `VideoCard` and `FolderCard` `onKeyEvent` intercepts Enter/select/DPAD_CENTER `KeyDownEvent` and starts a 500 ms hold timer; if the key is held, `onLongPress` fires and opens the context menu (Remove from library); `KeyRepeatEvent` is swallowed so auto-repeat does not re-trigger the menu.
- **Home scroll-on-return** (2026-08): `SliverAppBar` pinned (no floating), `jumpTo(0)` on initial load with stable `ValueKey`s on the grids, so tapping a card and pressing Back always lands at the top.
- Detection: `isTvMode()` in `lib/utils/tv_helper.dart` — checks `Platform.isAndroid && width >= 960dp` via `MediaQuery`; no platform channel needed

**Phase 3 — Audio Passthrough** (status: done, verified on-device 2026-08)
- Detect HDMI output: `AudioManager.getDevices(GET_DEVICES_OUTPUTS)` → check for `TYPE_HDMI`, `TYPE_HDMI_ARC`, `TYPE_HDMI_EARC`
- `mediaCodecSelector` TV override: when passthrough enabled AND HDMI detected, return empty decoder list for passthrough-capable formats (AC3, E-AC3, DTS, DTS-HD, TrueHD) — forces ExoPlayer's `DefaultAudioSink` to route them through `AudioTrack` passthrough mode to HDMI
- On phone (passthrough OFF): current behavior unchanged — Dolby E-AC3 filter stays, FFmpeg handles DTS/TrueHD/FLAC as PCM decode
- Settings toggle: "Audio passthrough: Off / Auto" in Settings (Android only). `Off` = current PCM decode. `Auto` = passthrough when HDMI output detected. Default off, user enables
- Player overlay shows orange "Passthrough" chip when active
- On Fire TV Stick: TV should show "Dolby Atmos" / "DTS-HD" on its info overlay when playing Atmos/DTS-HD content

**Phase 4 — Video Passthrough Verify** (status: done, verified on-device 2026-08)
- Hybrid-composition SurfaceView already composites as `BT2020_ITU_PQ` directly — confirm on Fire TV Stick
- `applyHdrHeadroom` window machinery is harmless on TV (early-returns or correctly sets HDR mode)
- DV P7/P8 → HEVC fallback + DV P5 rejection still work

**Fire TV — video visible after Nova-style transparent window fix (2026-08-19, on-device):** after the one-player-path rebuild, playback *opens* and *decodes* correctly on the stick (Jellyfin `Minions & Monsters`, DV, 4K 3840×2160). **Root cause of the blocking layer**: two `SurfaceView`s in the same window (Flutter's `FlutterSurfaceView` + ExoPlayer's video `SurfaceView`). On Fire OS 7.1 (API 25), the Android framework inserts an opaque `LayerDim` (alpha=1.0) between them, blocking the video. Nova avoids this with a **transparent window background** — the SurfaceView renders behind the window; a transparent background lets it show through.

**Fix (two changes)**:
1. **`MainActivity.kt`** — `onCreate()`: on TV devices (`isTvBox()`), sets `window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))` — exactly what Nova does (`PlayerActivity.onCreate`: `getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT))`). This eliminates the opaque window layer that triggers the blocking `LayerDim`.
2. **`ExoPlayerView.kt`** — `init`: calls `setZOrderMediaOverlay(true)` on the ExoPlayer `SurfaceView` after creation. This lifts the video surface above any remaining dim layers and above the `FlutterSurfaceView` in the z-order.

**Verified on-device**: `dumpsys SurfaceFlinger` shows the video layer at z=21010 (above `FlutterSurfaceView` at z=21005), window base at z=21015 (`isOpaque=0`, transparent). The `LayerDim` layers that remain have empty buffers (no content). Video picture is visible on the TV panel.

**Phase 5 — CI & Release Notes**
- No new CI jobs — same universal APK
- Add "Android TV / Fire TV support" to release notes

**Files changed:**
- `android/app/src/main/AndroidManifest.xml` — Phase 1
- `lib/utils/tv_helper.dart` — Phase 2 (new: `isTvMode()` detection)
- `lib/screens/home_screen.dart` — Phase 2 (TV action buttons, conditional FAB)
- `lib/screens/player_screen.dart` — Phase 2 (D-pad controls, auto-hide skip, fullscreen hidden)
- `lib/widgets/video_card.dart` — Phase 2 (focus highlight)
- `lib/widgets/folder_card.dart` — Phase 2 (focus highlight)
- `lib/screens/settings_screen.dart` — Phase 3 (passthrough toggle)
- `android/.../ExoPlayerView.kt` — Phase 3 (mediaCodecSelector TV override) + **transparent window fix** (`setZOrderMediaOverlay(true)`)
- `android/.../DreamRenderersFactory.kt` — Phase 3 (passthrough sink config, if needed)
- **`android/.../MainActivity.kt`** — **transparent window background on TV** (`Color.TRANSPARENT` in `onCreate`)
- `AGENTS.md`, `CHANGELOG.md` — Phase 5

**Out of scope for v1**: AirPlay/DLNA casting, CEC control, live-TV tuner, Play Store/TV certification (leanback banner, `android.app.leanbacklauncher`), Android TV-specific recommendations UI.

### Issue #6 — User-requested improvements (phased)

Source: https://github.com/mangeshghodke/DreamPlayer/issues/6

**Phase 1 — Global engine preference + auto-fallback** (DONE 2026-09)
- Settings → Player → "Default playback engine" (Media3 / libmpv / Ask every time / Auto)
- Auto-fallback: when Media3 reaches a terminal error, automatically tries libmpv
- libmpv purple screen fix (`target-colorspace-hint=yes`, `force-rgb-colorspace=yes`)
- Resume across engines: per-engine resume keys (`resume_pos_ms_media3:<key>` / `resume_pos_ms_mpv:<key>`)
- `LastEngineStore` tracks which engine last played each video
- `DefaultEngineStore` persists the user's preference

**Phase 2 — Library improvements (Flux-style)** (DONE 2026-09, ships in 0.4.2)
- **Cross-folder series grouping** (`lib/services/series_grouping.dart` + `lib/screens/series_seasons_screen.dart`): the home "Your library" grid now collapses same-base series folders into one card via `SeriesGroupingService().group(folders)` (`_seriesGroups` in `home_screen.dart`; `ValueKey(group.metadataKey)`). `SeriesGroup.baseName` = lowercase folder name with Roman-numeral/ordinal/season tags stripped; `displayName` = shortest member folder name; `primary => folders.first` drives card artwork; `metadataKey => primary.metadataKey`. Cards pass `groupCount` to `FolderCard` (small count badge when >1 folder; a lone season folder shows its **season** title + season poster, e.g. "Strike the Blood II"). Tapping a **single-folder** group opens the existing per-folder flow (identical to 0.4.1); a **multi-folder** group opens `SeriesSeasonsScreen` — the Nova-style `Series → Seasons` view listing every season across all grouped folders: TMDB header (poster/title/rating/overview/`matchFolderToSeason` from cached season names, zero extra API round-trips), per-season `ExpansionTile`s ("Season 2 · The Name" + `watchedCount` badge `3/10`), per-episode rows with TMDB stills (`episode?.stillUrl()`, fallback movie icon), `SxxExx` badge, green watched check, resume progress bar. All sources list through the folder's backend: local (`FileBrowserService.listDirectory`), SMB, WebDAV, FTP/SFTP, UPnP, Jellyfin (`serverForUrl` + `getItems`); `_toVideoItem` carries the folder's own `metadataKey` into `TmdDetailsScreen` so the right `folderSeason` resolves. `_fetchSeasonData` collects every unique `folderSeason` across the group and always fetches season 1 (anime-bracket `[01]` numbering). Season/episode extraction falls back to `ParsedFileName.parse`. Pure helpers (`groupBySeason`, `watchedCount`, `seasonHeader`, `watchedBadge`, `seasonBadge`) live in `lib/utils/season_group.dart` — no Flutter imports, unit-tested in `test/series_grouping_test.dart`. `TmdService.matchFolderToSeason(String folderName, int showId)` (tmdb_client.dart:1533) scores folder names against the show's cached season names.
- **Live Action vs anime TMDB disambiguation (DONE 2026-09)**: `ParsedFileName.parse` sets a `liveAction` flag when the file/folder name carries "Live Action" / "Drama" / "J-Drama" markers (tmdb_client.dart:793); `resolveFolder` carries it into `bestForQuery(liveAction:)` → `_queryScore` which gently boosts live-action results and penalizes anime-only matches (tmdb_client.dart:1233). Fully implemented, no longer deferred.

**Phase 3 — Per-episode TMDB stills** (DONE 2026-09)
- When a TV folder is detected, fetch season data via `TmdService.seasonFor()`
- Use `TmdEpisode.stillUrl()` for episode thumbnails in browse screens
- Fall back to show poster when no episode still exists
- Applied to: folder_screen.dart, smb_screen.dart, webdav_screen.dart, jellyfin_screen.dart, ftp_screen.dart, upnp_screen.dart, plus series_seasons_screen.dart and tmd_details_screen.dart
- **Flat-source browsers (webdav/ftp/upnp, 2026-09)**: each holds the folder's series meta (`_seriesMeta`, re-read from `TmdService.metaFor` after the season loop — never the pre-season reference) and resolves rows via `_episodeFor(entry)` (folderSeason → parsed season → first fetched season for anime `[01]` numbering). Tiles render the still as a wide 64×40 thumb ahead of the portrait poster, then the icon. Titles fall back to the episode `nameLabel` first, then the show title. Grep-proof: previously these three screens only ever showed the show poster.
- **Jellyfin browser (2026-09)**: no filename parsing needed — `_detectAndLoadSeasonLevel()` resolves the SERIES crumb (`_crumbs[length-2]`, keyed `jellyfin:<host>/<seriesId>`) via `resolveFolder` when the current level holds playables with `parentIndexNumber`/`indexNumber`, then fetches details + every season present; `_episodeForItem(item)` looks up `seasons[parentIndexNumber]?.episode(indexNumber)`. Structured items also label the title as the episode name and badge SxxExx from `item.seasonLabel`.

**Phase 4 — External player handoff** (DONE 2026-09)
- When both Media3 and libmpv fail, offer "Open in external player" option via `Intent.createChooser`
- VLC handles `smb://` natively (no loopback needed); WebDAV passes HTTPS URL with auth headers; UPnP/DLNA and Jellyfin pass HTTP URLs
- Android only (iOS has no external player intent system)

**Phase 5 — Download to device** (DONE 2026-09)
- Kotlin foreground service (`DownloadService.kt`) + `DownloadClient.kt` method channel
- iOS: `DownloadClient.swift` with `UNUserNotificationCenter` — banner once at start, silent 5s updates after; cancel action + tap-to-open-drawer
- Dart `DownloadManager` singleton (`lib/services/download_manager.dart`) — HTTP streaming with HEAD probe for Content-Length, SMB via loopback proxy, local file copy via async chunked I/O (256 KB, event-loop yield), progress tracking, SharedPreferences history
- Download screen (`lib/screens/download_screen.dart`) — progress bars (indeterminate when size unknown), status badges, cancel/delete/play
- Player ⋮ sheet + details screen bottom bar triggers + home screen hamburger drawer (active + completed + failed/cancelled sections)
- Notification: Android silent (`IMPORTANCE_LOW` + `setSilent`) with Cancel action button; iOS local notification with Cancel action + tap-to-open
- Supports: HTTP (WebDAV, Jellyfin, UPnP, network), SMB (via `SmbHttpProxy`/`SmbClient.startLoopback`)
- FTP download hidden — Dart `HttpClient` cannot handle `ftp://` URIs; native download bridge too complex for now
- **All shipped (2026-09)**: downloaded files in home grid with a green "downloaded" badge + local playback (`_buildDownloadedGrid` in home_screen.dart:1080), Settings → Downloads → download directory picker (settings_screen.dart:503, native `setDownloadDir`/`getDownloadDir`). Nothing left in this phase.

### iOS spatial audio — NOT IMPLEMENTED (design decided 2026-09-28, user deferred)

**Current state: iOS does nothing.** `AvPlayerView.swift:729` only does
`setCategory(.playback, mode: .moviePlayback)` + `setActive(true)` and never
declares multichannel support, so **iOS never even offers the user spatial
audio**. There is no iOS handler for the `system_controls` channel at all
(it is registered only in `MainActivity.kt:229`), so
`SystemControls.spatialAudioChanges` never emits on iOS, `_liveSpatial`
stays `''`, and the teal Spatial chip is hard-gated on `Platform.isAndroid`
(`player_screen.dart:4402` and `:6426`). The Android Spatializer wiring
(`ExoPlayerView.kt:147-256`, `spatialStatus()` → `map["spatialAudio"]`) is
Android-only and is the parity target.

**Do NOT use SpatialAudioKit** (researched 2026-09-28,
https://spatialaudiokit.github.io/docs/). It is a Swift package by
@olilarkin for decoding **object-based spatial audio *files*** — Dolby
Atmos ADM/BWF masters and multichannel Opus in Ogg containers — bundling
libiamf, fdk-aac, iamf-tools and opusfile. Its target is apps whose *content*
is a spatial-audio asset (Apple Music style). DreamPlayer plays
**channel-based** movie soundtracks (DTS-HD 5.1/7.1, TrueHD, E-AC3,
multichannel FLAC): there is no spatial file to decode, so SpatialAudioKit
would add a large binary dependency and spatialize nothing. Adding it would
be wasted build weight and licence surface. The same reasoning rules out
`AVAudioEnvironmentNode` / `PHASE` / `AUSpatialMixer` for this feature —
those are for *positional* placement of discrete sources, which a film mix
does not need.

**The correct path is Apple's own AVPlayer spatialization** (channel-based →
binaural HRTF, i.e. the same transform Android's `Spatializer` applies).
Four steps, all in `ios/Runner/AvPlayerView.swift`:

1. **Declare multichannel support** —
   `try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)`.
   This is the call that makes iOS offer spatial audio in Control Center /
   AirPods settings at all. Without it the feature is invisible.
2. **Opt the item in** — `AVPlayerItem.allowedAudioSpatializationFormats =
   .multichannel` (iOS 15+). The default already spatializes, but being
   explicit matters for the AetherEngine FFmpeg path.
3. **Detect the real state** — `AVAudioSession.sharedInstance()
   .currentRoute.outputs.first?.isSpatialAudioEnabled` (iOS 15+). This is
   `true` only when the route can render spatial audio **and** the user has
   permitted it, so it is the honest signal (no separate "user preference"
   flag to get wrong).
4. **Observe changes** — listen for
   `AVAudioSession.spatialPlaybackCapabilitiesChangedNotification`, read
   `notification.userInfo?[AVAudioSessionSpatialAudioEnabledKey]`, and push
   the new value over the **existing** `system_controls` channel as
   `spatialAudioChanged` so `SystemControls.spatialAudioChanges` and the
   existing Dart plumbing work unchanged. Then drop the
   `Platform.isAndroid` gates on the chip (`:4402`, `:6426`).

**No entitlement required.** `com.apple.developer.coremotion.head-pose` and
`com.apple.developer.spatial-audio.profile-access` are only for apps doing
*custom* spatial audio via `AVAudioEngine` / `PHASE` / `AUSpatialMixer`.
We ride AVPlayer's built-in system spatialization, so the provisioning
profile does not need regenerating. We also already register for Now Playing
(`updateNowPlaying()` → `MPNowPlayingInfoCenter`), which per WWDC23 is what
makes the system auto-enable spatial audio on the non-AVPlayer paths.

**Scope rule (same as Android):** only gate on multichannel (5.1/7.1) PCM.
Stereo/downmixed routes and encoded bitstreams are not spatialized, so the
chip must not claim otherwise. Reuse the existing `_liveSpatial == 'on'`
string contract — the Bass Boost row (gated on it, `player_screen.dart:5825`)
would then appear on iOS too, which is correct: it exists to offset the
low-end thinning of HRTF virtualization.

**Verification gap — the reason this is deferred.** There is no Mac and no
iOS device in the dev loop, so this can only be CI-verified. A green build
proves it *compiles*, not that spatial audio *works*; the 2026-09-24
TestFlight run failed on a one-line Swift type error in
`FileBrowser.swift` that local tooling could never have caught. Budget for a
TestFlight cycle and on-device verification with AirPods Pro. Still
needs on-device confirmation: the AetherEngine FFmpeg path (WebDAV/FTP/Files)
decodes to PCM through a loopback producer, and whether
`allowedAudioSpatializationFormats = .multichannel` spatializes that path
is unknown until tested. Also note Apple's Control Center only shows the
spatial icon for `AVPlayer` / `AVSampleBufferAudioRenderer` playback, and
AirPods settings can read "Spatial Audio Not Playing" even while spatial
audio is in fact active — do not treat either as a failure signal.

### Episode rows (issue #38, 0.5.1+25) — read this before touching a row

Episode/video rows are **one widget**: `lib/widgets/episode_row.dart`
(`EpisodeRow` + `EpisodeStillThumb` / `EpisodePosterThumb`), used by
`series_seasons`, `folder` (x2), `smb`, `webdav`, `jellyfin`, `ftp`, `upnp`,
`file_browser` and `tmd_details`. Before this there were **9 copies** of a
`48x72` `_Poster` plus 7 copies of a `64x40` still block. Size preference:
`EpisodeThumbSize.small|medium|large` in `LayoutStore` (third segment of the
`dreamplayer.layout` key; 2-segment values still load).

**Five traps that each cost a shipped bug — all verified by tests now:**

1. **`ListTile` caps `leading` at 56 px, and `ListTileTheme.minTileHeight` does
   NOT lift that cap** (`maxIconHeightConstraint` is hardcoded). The old rows
   asked for `48x72` and really rendered `48x56`. Any row whose thumbnail must
   exceed 56 px tall has to leave `ListTile` — which is why `EpisodeRow` is a
   `Row`. Keep the TV focus chrome by using the public `TvFocusWrap` (extracted
   from `TvTile`); do not re-add a `ListTile`.
2. **Size the row from the ROW's constraints, never `MediaQuery`.** The row is
   narrower than the screen (measured: ~289 dp on a 360 dp phone inside the
   season page), so a `MediaQuery`-based check silently refused to step down and
   Medium/Large did nothing. `EpisodeRow` uses `LayoutBuilder` + `thumbBuilder`.
3. **The title's own rigid children eat the text column.** `SxxEyy` badge and
   the star rating originally lived in the title `Row`, needing ~170 dp of the
   space the check was assuming was all for the title — the row overflowed by
   15 px (45 px at 1.3x text). Both now sit on the metadata line
   (`S01E05` / `★ 8.5 · 439 MB`). `minTextWidth = 80` is derived from the
   measured width; raising it makes Medium/Large silently demote.
4. **A thumbnail must listen to `LayoutStore` ITSELF.** Callers construct the
   thumb and pass it in, so a row-driven rebuild hands back an identical `const`
   widget that Flutter short-circuits — the thumb never resizes. Each thumb
   wraps itself in a `ListenableBuilder`.
5. **`CachedImage` returns `SizedBox.shrink()` while loading.** Thumbnails must
   pin their box or rows collapse and jump while scrolling.

**TMDB still widths are NOT the documented ladder.** Measured on device: a still
returns **HTTP 400** for `w455` and `w640`, while `92/185/300/342/500/780` all
return 200 — and TMDB's docs list `w455`. An invalid width fails silently into
`CachedImage`'s `errorBuilder`, so it looks like "no artwork exists". Always
verify a new width with `adb shell curl -o /dev/null -w '%{http_code}'` on a
real still path. Current: `stillUrl()` = w500, `posterUrlOf` = w300.
**Cache key is the whole URL incl. width**, so a width change orphans the old
entries (only clearable via Settings → cache).

### Episode stills: fetched lazily, then prefetched

TMDB's `/tv/{id}/season/{n}` returns overviews + ratings but **no stills** —
those only come from the per-episode endpoint. So `TmdService.requestEpisodeStills`
fetches them, deduped by the existing `_pendingDetail` set, persisted via the
existing `episodeDetailsFor`, throttled to `maxStillsInFlight = 3` (an expanded
season builds a dozen rows at once), and then **prefetches the image bytes** so
artwork is on screen rather than pulled as the row scrolls into view. Only the
FIRST still is prefetched (the one the row shows); the details gallery
lazy-loads as before.

**Three separate silent no-ops had to be fixed before it worked at all:**
- the key must be the **season folder's** key (`_folderKeyForSeason(s)`), not
  the show's — `seasonFor` is cached per folder (issue #33), so the show key has
  no season and the lookup finds nothing;
- `initState` alone is not enough — season data lands *after* the row is first
  built and a `ListView` reuses row `State`s by position, so `didUpdateWidget`
  re-checks when `episode` first becomes non-null;
- `_episodeFor` read `_meta` (the show) while the enrichment was written to the
  season folder's key, so the row never saw what it had just fetched.

### Offline episode titles

`lib/utils/episode_label.dart`: TMDB name → `S01E05` → file name. The old
fallback was `ParsedFileName.title`, which for `Dark.S01E05.mkv` is the **show**
name, so offline every episode in a season listed as "Dark".
`titleIsEpisodeCode` stops the row then repeating `S01E05 / S01E05`.
Unit-tested in `test/episode_label_test.dart`.

### Image caching (posters, backdrops, stills, cast)

`ImageCacheService` is a **permanent disk cache** at
`<app documents>/image_cache/<hash>-<tail>.img`; memory → disk → network, and
it survives restarts. Every screen renders through `CachedImage`, which calls
`getCached` then `fetch` (so a prefetch in flight is deduped, not
double-downloaded). Toggle + live byte count + clear in Settings.

Known characteristics, not bugs: **no size cap or eviction** (only manual
clear), and poster/backdrop/cast are prefetched on resolve while per-episode
stills are prefetched per row as they are discovered. Embedded cover art
(MKV/MP4 artwork) is a separate cache, `ThumbnailStore`, local-only by design.

### Chapter navigation (issue #40, 0.5.1+26) — read this before touching the seekbar

Chapters were **already parsed on both platforms** long before #40 asked for
navigation: `MkvChapters.kt`/`.swift` (EBML EditionEntry/ChapterAtom) AND
`Mp4Chapters.kt`/`.swift` (Nero `moov/udta/chpl`), read for local files via
`RafReader`; Jellyfin supplies `Item.Chapters` (ticks/10000 ms) server-side.
They reached Dart as `VideoItem.chapters` / `ExoChapter` and were only ever
listed in the ⋮ overflow sheet. **AGENTS.md's old claim that "MP4 chapter
tracks not parsed yet" was stale** — both platforms have had it.

What #40 actually needed was **presentation**, and all three asks were
deliberately scoped:

- **Seekbar ticks** — `_ChapterTickPainter` (end of `player_screen.dart`),
  inserted between the active fill and the thumb so a mark reads against both
  the played and unplayed halves. Each tick is drawn TWICE: a `Colors.black`
  4px line under a `Colors.white` 2px one. White alone disappears into the
  white active fill, which is the whole reason the first version was invisible
  on the played side. A tick at fraction 0 is skipped — it sits on the bar's
  left edge and reads as a rendering glitch.
- **Buttons beside play/pause** — inside the centre pill, not the bottom bar,
  because the pill is already the big-transport cluster and a viewer skipping
  an opening is looking at the video. Shown only when `_chapters.length > 1`,
  on phone, tablet and TV alike. Gated on `_inPip` like every other control.
- **The gesture is a DOUBLE-TAP on the bar, deliberately not the horizontal
  swipe.** That swipe is ±90 s scrub (`±90 s per screen width`); silently
  changing what it means would break it for every video with no chapters.
  A double-tap is unambiguous and costs the existing gesture nothing.

**Chapters were Media3-ONLY for one full release cycle — the "local files only"
trap.** Two independent causes, both found after the reporter said SMB showed
nothing:

1. **The parsers live in `ExoPlayerView`.** `MkvChapters.kt`/`Mp4Chapters.kt`
   are called from `probeChapters`, which only the Media3 platform view runs. The
   MPV engine therefore had NO chapters for ANY source, while Media3 had them
   for local files — so "works on local, not on network" was really "works on
   whichever engine I happened to use". `_loadMpvChapters` now reads mpv's own
   `chapter-list/<n>/title|time` after every `player.open`. mpv has no
   `chapter-list/count` and `getProperty` cannot stringify a node array, so it
   walks indices until a read is empty or throws — the same shape as the
   existing `track-list/<n>/default` DEFAULT-audio probe.
2. **`parseHttp` could only see the FIRST 8 MiB** (`Range: bytes=0-8388607`).
   Matroska keeps Chapters at the END of the segment, and MP4 keeps `moov` at the
   end unless the file was written "fast start" — so every HTTP source
   (WebDAV / Jellyfin / UPnP-DLNA) silently found nothing. Both parsers now use
   `fetchHttpRanges`: an 8 MiB head **plus** an 8 MiB tail, joined by a
   `SparseReader` that serves either window and EOFs in the gap. The box/EBML
   walks never touch the gap — they start at the header/SeekHead and seek
   straight to the element they want. Total size comes from the `Content-Range`
   header of the head request; a server that ignores Range and streams the whole
   body falls back to the old head-only behaviour.

   SMB/FTP were always fine here: `openSmbFile` resolves the saved credentials
   via `SmbStore.resolve` and wraps a real `SmbRandomAccessFile`, which seeks.
   `probeChapters` now logs its inputs and the result under the `MkvChapters`
   tag, so the next "it didn't show" is answerable from logcat instead of guesswork.

**The previous-chapter grace window is the whole UX of the button.** Past 3 s
into a chapter, "previous" restarts THAT chapter; inside 3 s it steps back one.
So pressing twice walks backwards instead of sticking — the CD-player
behaviour. The toast says which of the two happened ("Restart chapter" vs
"Previous chapter") by comparing the target's `startMs` against
`ChapterNav.current`, because the arithmetic alone can't tell you afterwards.

All of it is pure arithmetic in **`lib/utils/chapter_nav.dart`** (`indexAt` /
`next` / `previous` / `current`), unit-tested in `test/chapter_nav_test.dart`
(17 tests) against a real VCB-Studio shape: Opening / Part A / Part B /
Ending. Two decisions worth keeping: `next` returns **null** at the last
chapter rather than wrapping to the first (a next button that jumps you back
to the opening is how you lose an hour), and `indexAt` resolves duplicate
starts to the **last** marker so `next` can never land on the chapter already
playing. The ±10 s buttons are TV-only; the chapter buttons are NOT, because a
D-pad has no double-tap gesture.

**The chapter buttons are NOT `_TvControlButton`s on touch — and that took three attempts.** The ring is drawn inside a Focus + AnimatedContainer wrapping an `IconButton` that never shrinks below its 48px minimum, so around the 40px skip glyphs it rendered a ~63px glowing disc that read as a halo, and it appeared at all on a phone because tapping a button gives it focus. What was tried, in order:

1. `hugIcon` + `focusScale` to shrink the ring to hug the glyph. The user asked
   for the glow gone entirely, so this was reverted rather than left as unused
   API — and it was only ever cosmetic anyway.
2. `ringless` on `_TvControlButton`, suppressing the decoration, the glow and
   the focus scale. **Not enough**: `_TvControlButton` wraps its `IconButton`
   in a `Focus`, but the `IconButton` creates its OWN internal `FocusNode`, and
   Material paints its focus overlay on *that* node. The two cannot be merged —
   a `FocusNode` may only be attached to one `Focus`.
3. Rendering a ringless button as a plain `GestureDetector` + `IconTheme.merge`
   instead of an `IconButton`. That removed the flash on Media3, but with MPV a
   glow still flashed on one button or the other for a frame (MPV's chapters
   arrive *late*, so the buttons are inserted into the tree while the screen is
   already live).

So the chapter buttons now take a **platform split** in `_chapterButton`: TV
gets a real `_TvControlButton` (a D-pad with no visible focus target is worse
than an oversized ring), and touch gets a bare tappable `Icon` with no
`Focus`, no `AnimatedContainer` and no `IconButton` anywhere in the subtree —
which makes the glow impossible rather than merely unlikely. Anything else that
wants "no touch focus ring" should copy that split instead of trying to suppress
the decoration.


### Reading logs off the iPad: there is no Mac in the loop (2026-10-04)

**The device console is NOT an option** — the user has no Mac, so `debugPrint`
output from a TestFlight build is unreachable. The only channel that actually
reaches them is a file they can pull in **Files -> On My iPad -> DreamPlayer**,
which is how `smb_debug.log` has always worked (`ios/Runner/SBMLog.swift` writes
it to the Documents root).

So `lib/services/app_debug_log.dart` mirrors that: `AppDebugLog.mark()` does a
`debugPrint` **and** appends to `app_debug.log` in the same Documents root, next
to `smb_debug.log` and `iap_debug.log`. Design points that matter:

- **Fire-and-forget, never awaited.** `mark()` returns `void` and appends through
  an internal `Future` chain, so a diagnostics aid can never block the UI path —
  the very failure mode being debugged.
- **Off under `flutter test`** (`Platform.environment['FLUTTER_TEST']`), so unit
  tests do no filesystem work.
- **Capped at 256 KiB**, truncating in place and keeping the newest half: the
  markers being read are always the recent ones.

**Use this for any timing/trace work that has to come back from a TestFlight
build.** A `debugPrint`-only marker is effectively invisible here, which is
exactly how build 28's `TMD-OPEN` markers came to nothing.

**Three bugs lived in that logger before it produced a single readable line**,
all found by checking the FILE rather than trusting the code:

1. `'$_stamp  $message'` interpolates the **tear-off**, not the result — every
   line was `Closure: () => String from Function '_stamp'`. It must be
   `${_stamp()}`. Grepping the log for a marker still *found* the message
   (appended after the garbage), so this would have shipped as "logging works".
2. The boot line awaited `PackageInfo.fromPlatform()` before the first write. At
   boot a plugin channel may not be registered, the write threw, and the error
   was swallowed — so the file never appeared and the failure looked like
   "the markers never fired". The boot mark is now plugin-free, and
   `_append` forgets its cached `File` on failure so the **next** mark retries.
3. Failures are now reported once via `debugPrint` instead of vanishing. A
   silently broken log is worse than no log: "no file" then reads as "nothing
   happened" rather than "the writer is broken".

Verified on Android (the bug is in shared Dart, so that is the fast check) by
`run-as … cat app_flutter/app_debug.log` — note Android maps
`getApplicationDocumentsDirectory()` to `app_flutter/`, NOT `files/`, which is
where I first looked and wrongly concluded the writer was broken on both.

### TmdStore writes: why the iPad froze solid on a details screen (2026-10-04)

**Symptom (iOS/SMB):** tapping an episode or movie in the SMB browser froze the
app **solid** — the spinner stopped animating, so it was not "slow", the UI
isolate was *blocked* — for several seconds, then the TMDB details screen
appeared. Movies and episodes alike. Playback itself opened fast, which is the
clue: playback writes no metadata.

**Cause:** `TmdStore.save()` did `loadAll()` → mutate one key → `jsonEncode` the
**entire** cache → `prefs.setString`. So every write paid a full `jsonDecode` of
the whole store *plus* a full re-encode, **on the UI isolate**, and on iOS the
blob also lives in NSUserDefaults where a multi-MB string is slow to write.
Opening a details screen saves several times in a row (`carryMeta`, `resolve`,
`seasonFor`, then one per episode still), so it was N full decodes + N full
encodes + N huge writes.

**Fix:** `_memo` holds the decoded store after the first read; `save()` mutates
memory, notifies, and calls `_schedulePersist()` — a 600 ms debounce that
collapses a burst into ONE encode + ONE write. `_persistNow` serialises writers
and re-arms if something changed mid-encode, so nothing is lost.
`TmdStore.flush()` forces the write for callers that must not return first
(`remove`). `TmdService._cache` and `TmdStore._memo` cannot diverge because every
`TmdStore.save` is preceded by `_cache[key] = meta`.

**Read the symptom correctly:** a *spinning* spinner means awaiting; a *frozen*
one means blocked. That distinction is what pointed at a synchronous CPU cost
rather than a slow channel — and `openShare` was never the suspect, because it
already runs in a `Task.detached` and replies on `MainActor`
(`ios/Runner/SMBBridge.swift`), which the log confirms (~136 ms).

**Not a candidate, despite looking like one:** the repeated `listDirectory` calls
for the same bookmarked folders in `smb_debug.log` are the home screen re-listing
network folders, not part of the freeze.

`test/tmd_store_persist_test.dart` (5 tests) pins it: a burst is NOT written
immediately, `flush` persists all of it, an entry saved *during* a write is not
dropped, `remove` deletes one entry and persists, `clearAll` empties both memory
and disk. A `debugPrint` reports the blob size when it exceeds 100 000 chars —
that single number is what to look for in a device log if this ever regresses.

### Library rescan on refresh (issue #39, 0.5.1+25) — read this before touching the scanner

The home grid was a **one-time snapshot**: `FolderScanner` ran only inside the
three bookmark flows (`home_screen.dart:974` local, `smb_screen.dart:256`,
`webdav_screen.dart:409`), never on refresh. Pull-to-refresh re-read the
persisted prefs, which by definition cannot contain files that were never
scanned, so it could never fix the staleness it appeared to promise. Fixed by
`lib/services/local_library_rescan.dart`, called from `_refreshHome`.

**Scope is deliberately LOCAL (`LibraryFolderSource.files`) only.** A network
source costs one round-trip per subfolder (50 folders ≈ 5-10 s on a LAN), so a
rescan on every pull would stall; network folders are refreshed by re-opening
them (`FolderScreen._load` always re-lists — that path was never stale).

**Four traps, each of which was a real bug found by the tests:**

1. **Ids must be carried over, never regenerated.** A matched entry keeps its
   **existing `id` and `addedAt`** (`copyWith(id:, addedAt:)`). `metadataKey` is
   `folder:<id>` for a folder, and scanner ids embed `String.hashCode`, which
   carries no cross-version guarantee — a regenerated id silently orphans that
   folder's cached TMDB metadata and artwork overrides, so every refresh would
   drop the poster off the grid. Matching is by `scanIdentityOf` (source + path),
   never by id.
2. **An unreadable directory must never read as "empty".** `FolderScanner` now
   counts `failedDirs` (a listing that threw — unmounted SD card, revoked
   permission). If `failedDirs > 0`, OR a root with children scans to empty,
   the plan runs with `allowRemovals: false`: additions apply, **nothing is
   removed**. Strays are pruned by the next clean scan. Deletion is the
   destructive half; losing a library to a card-reader glitch is not acceptable.
3. **The scan root is not in the store.** All three bookmark flows REMOVE the
   parent and keep only children tagged `parentId`, so there was no seed to
   rescan from. Fixed going forward by `LibraryFoldersStore.saveScanRoot`
   (`dreamplayer.libraryScanRoots`). For pre-existing installs,
   `LocalLibraryRescan.reconstructRoot` recovers the root as the **longest
   common directory prefix of the children's paths** (bookmark "Movies" →
   children `tree:X/House`, `tree:X/Dune` → root `tree:X`; bookmark "House"
   directly → `tree:X/House`). Two sub-traps: the reconstruction only earns
   removal rights when it yields a real display name (children sitting directly
   in `tree:X` give an unnamed seed → add-only), and an unnamed reconstruction is
   deliberately **not persisted** — freezing it would make the next refresh trust
   it for removals, the exact thing it was too unsure to allow.
4. **Scan roots are pruned by `remove()`, never by the rescan.** In the rescan,
   "root with no children left" is indistinguishable from "the user emptied the
   folder on purpose", and dropping the seed there would make files added later
   undiscoverable. `LibraryFoldersStore.remove` knows the intent, so that is
   where `_pruneUnreferencedRoots` runs (and `clearAll` clears roots outright).

`LibraryFoldersStore.applyDiff` exists so a refresh is **one** prefs write and
**one** `changes.notify()`: upserts replace matching ids **in place** (a refresh
must not reshuffle the grid), new ids append, and the DANGER half —
`bulkAdd` — is never called from the rescan because its insert-at-0 would float
every rescanned folder to the top. `sameContentAs` keeps unchanged entries out
of the write entirely.

`test/local_library_rescan_test.dart` (21 tests) pins all of it, including both
reconstruction shapes, the add-only fallback, and id/`addedAt` preservation.

### Artwork identity across surfaces (0.5.1+25) — read this before adding a surface

Artwork overrides are keyed by metadata identity, and for a long time one film had
**three** keys at once, so a poster picked in one place never appeared in another
while resume — stored against `resumeKey` — looked correctly synced the whole
time. That asymmetry is what made it look like a rendering bug.

| Surface | Key |
|---|---|
| Home **file** card | the file's `resumeKey` |
| Continue Watching | the file's `resumeKey` |
| SMB/WebDAV/FTP browse → details | the file's `resumeKey` |
| Home **folder** / series card | `folder:<id>` |
| Season card | `folder:<seasonFolderId>` (independent, issue #33) |

Two rules hold it together:

1. **A file's identity is its resume key.** `LibraryFolder.metadataKey` returns `path` when `isFile`, and `NetworkVideoResolver` already puts exactly that string on the `VideoItem` it resolves from the entry's `path`. A real folder keeps `folder:<id>` — it has no resume key, and its card stands for the whole folder. Nothing branches on the `folder:` prefix.
2. **Artwork inherits down an ancestor chain, one way.** `TmdService.metaFor(key, inheritArtworkFrom: [...])` takes the chain nearest-first (for an episode: its season folder, then the show folder) and consults each only when nothing nearer has a pick of that kind. Per *kind*, so a poster pick does not drag the backdrop along with it. It never writes back up: an episode's pick does not reach its season or the show, because seasons keep independent keys precisely so they can differ (issue #33). A consequence worth remembering: an episode's season is parsed from its **filename**, so anything season-keyed must not treat a file as a season page.

**The trap to avoid.** `withArtwork` patches `movie` and `details` but **never `seasons[]`**. So any header that prefers `meta.seasons[n].posterUrl` silently ignores the user's pick. That is why `detailsHeaderPosterUrl` takes `preferSeasonPoster`, which is true only for a season *page* (`widget.folder != null`) and false for an episode. When changing artwork resolution, render from `movie.posterUrl` — that is what `posterUrlOf`, and therefore every card, uses.

### Backdrop hero is width-derived (0.5.1+25)

`CollapsingBackdrop` + `backdropExpandedHeight` in `lib/widgets/collapsing_backdrop.dart`, shared by the details, series-seasons and group screens. It used to be duplicated byte-identically in all three and hardcoded to 200–220 px, which is why tablets showed a thin cropped strip: a 16:9 backdrop at a **fixed** height shows proportionally less of the image as the screen widens. At 200 px a 390-wide phone still fits the full width, while a 1024-wide iPad shows barely a third of the image's height. The height is now `width * 9 / 16` clamped to 200..62% of the viewport height — full image in portrait on any device, slightly cropped in landscape — and `alignment: Alignment(0, -0.25)` biases upward when it does crop, because the subject in movie artwork sits above centre.

### Player feature backlog (prioritized 2026-09)

1. Android release signing (deferred — see CI/Deployment).
2. **Anime4K real-time upscaling (future, low priority)**: [Anime4K](https://github.com/bloc97/anime4k) is a set of open-source GLSL shaders that upscale native 1080p anime → 4K in real-time, designed for mpv's GPU rendering pipeline. **Not implementable today** because (a) Android uses ExoPlayer/Media3 (no GLSL shader injection — video writes directly to a `Surface` backed by `SurfaceFlinger`), (b) the libmpv engine's video path is a platform `SurfaceView` owned by the app (not a raw mpv `--vo=gpu` window we can inject into — Anime4K's shader chain can't run), and (c) it conflicts with HDR/DV passthrough (the panel receives BT.2020 PQ data; running a shader on tone-mapped SDR frames defeats the pipeline). **If the mpv fallback engine is ever promoted to a "GPU filters" path** (mpv `--vf=glslshader=…` with a raw rendering window), Anime4K shaders could be offered as an opt-in toggle for SDR anime content only — DV/HDR10 files must stay on Media3 + native `SurfaceView`. The upstream repo ([bloc97/Anime4K](https://github.com/bloc97/Anime4K)) has 21k stars and active maintenance; [Anime4KMetal](https://github.com/imxieyi/Anime4KMetal) exists for Apple platforms (Metal shaders) which could apply to the iOS AetherEngine path in a distant future. Keep this in the backlog; revisit only if user demand surfaces.
3. **Download to device (done, 2026-09)**: download video files from network sources (SMB, WebDAV, HTTP, Jellyfin, UPnP) to local storage for offline playback. Modeled on Nova Video Player's `CopyCutEngine` + `FileManagerService` pattern. Core is built: Kotlin foreground service + Dart DownloadManager + UI triggers + download screen + SMB via loopback + silent notification with Cancel button + iOS local notification. iOS: notification shows banner once at start, then silent progress updates every 5s; cancel action forwards `jobId` to Dart; tap notification body opens the Downloads drawer. Local file copy uses async chunked I/O (256 KB) with event-loop yield each chunk — sync I/O blocked the UI and caused stutter. Cancel properly interrupts the copy loop via `_activeCompleter` and deletes the partial file. Progress bar renders for all downloads (indeterminate animation when `totalBytes` is unknown; HEAD probe runs before the GET on HTTP sources to resolve size). FTP download is hidden because Dart `HttpClient` cannot handle `ftp://` URIs.
 4. **Localization / internationalization (DONE 2026-09)**: full app translation via Flutter's built-in `flutter_localizations` + `intl` package. Languages: **English** (default/fallback), **Spanish** (es), **Chinese Simplified** (zh), **Russian** (ru). Auto-detects device system language on launch; optional Settings → General → Language override. Technical terms (codec names, HDR, Dolby Vision, etc.) stay English. **504 ARB keys** in English ARB (`lib/l10n/app_en.arb`), all translated to es/zh/ru (~130 key strings per language). Auto-generated `AppLocalizations` class via `gen-l10n` with camelCase getters, `l10n.yaml` at project root. `LanguageService` (`lib/services/language_service.dart`) manages the locale override with SharedPreferences persistence. `MaterialApp` wired with `localizationsDelegates` + `supportedLocales` via `ListenableBuilder` + **`ValueKey`** to force full rebuild on locale change. Language picker uses `StatefulBuilder` + `ListTile` + `onTap` (not `RadioGroup` — nullable `Locale?` generic type issues). **283 strings localized** across 13 screen files. `test/test_helper.dart` provides `localizationDelegates` for widget tests.

   **Architecture (3 layers):**
   - **UI**: player ⋮ sheet "Download to device" row + details screen bottom bar Download button (visible only for network sources)
   - **Service**: `DownloadService` (foreground service, `dreamplayer_download` notification channel, `NOTIF_ID=4211`, `FOREGROUND_SERVICE_TYPE_DATA_SYNC`) + `DownloadManager` (singleton, sequential queue, one download at a time)
   - **Engine**: per-protocol stream readers writing 32 KB chunks to `FileOutputStream` — SMB via `SmbRandomAccessFile` (jcifs-ng), WebDAV via OkHttp GET with `Range`+`Authorization`, FTP/SFTP via existing `PASV`/`RETR` or `ChannelSftp`, Jellyfin via OkHttp GET `streamUrl()` (`static=true`), UPnP via HTTP GET DIDL `<res>` URL

   **Method channel** `dreamplayer/download`:
   - `startDownload { sourceUri, sourceType, destDir, title, httpHeaders?, allowSelfSigned? }` → `{ jobId, destPath }`
   - `cancelDownload { jobId }`
   - `getDownloads` → `List<DownloadJob>`
   - `deleteDownload { jobId }` — deletes local file
   - `getDownloadDir` → default path (`Environment.DIRECTORY_MOVIES/DreamPlayer/`)

   **UI triggers:**
   - Player ⋮ sheet: "Download to device" row — visible when `_current` is network source (`PlaybackSource.smb|webdav|ftp|jellyfin|upnp|network`)
   - Details screen bottom bar: `OutlinedButton.icon` "Download" below Play/Resume — visible when `widget.video` is network source
   - Both show SnackBar "Downloading…" on start; button changes to "Download in progress…" with tap to open download screen

   **Download screen** (`lib/screens/download_screen.dart`): lists all downloads with title, progress bar, status badge, cancel/delete buttons. Accessible from player ⋮ sheet "Downloads" row + Settings → Downloads.

   **Downloaded files management:** scan `DreamPlayer/` subdirectory on app start; match against download history by file name; downloaded files appear in home grid with "downloaded" badge; play locally via `path`; delete via swipe-to-delete or long-press "Remove from device".

   **Folder picker**: default `/Movies/DreamPlayer/` with Settings option to change (unlike Nova which hardcodes `/Movies/`).

   **Permissions:** `MANAGE_EXTERNAL_STORAGE` (already granted), `FOREGROUND_SERVICE_DATA_SYNC` (new, API 34+), `WAKE_LOCK` (already in manifest).

   **Source detection:** `VideoItem.playbackSource` enum maps `resumeKey`/`uri`/`path` to `PlaybackSource.smb|webdav|ftp|jellyfin|upnp|network` — same logic already used for source badges on cards.

   **Dart layer:** `DownloadService` singleton (`ChangeNotifier`) in `lib/services/download_service.dart` — `startDownload(VideoItem)`, `cancelDownload(jobId)`, `downloads` list, `onProgress` stream; `DownloadItem` model with `id, title, sourceUri, sourceType, destPath, status, bytesCopied, totalBytes, createdAt`; download history persisted to `dreamplayer.downloads` in shared_preferences.

   **Nova reference:** `VideoInfoActivityFragment.java:926` (menu add), `FileManagerService` (foreground service), `CopyCutEngine` (FileCoreLibrary, 32 KB chunk copy via `FileEditorFactory`), `Paste` dialog (progress + cancel + "Run in background"). Nova hardcodes `Environment.DIRECTORY_MOVIES`, no folder picker, no queue persistence. We improve on all three.

5. **Recursive library scanner (TODO, 2026-09)**: Flux-style deep scan — when a folder is bookmarked (any source: SMB, WebDAV, FTP, UPnP, Jellyfin, local), recursively traverse ALL subfolders and display expanded poster cards on the home grid. Progress bar shows current folder being scanned + cancel button. Results appear incrementally (each folder resolves TMDB as it's found). **Network shares caveat**: each subfolder = one network round-trip (SMB `QUERY_DIRECTORY`, WebDAV `PROPFIND`, FTP `LIST`, UPnP SOAP `Browse`). 50 folders ≈ 5-10s on LAN. Jellyfin is the exception — API supports `Recursive=true` (1 call for entire tree). Implementation: `LibraryScanner` service with per-source adapters, `ScanProgress` stream (current path, folders found, files found, total), cancellation via `Completer`. Home screen shows scanner overlay during scan, then renders all found items as expanded cards. **Key design decisions needed**: max depth limit (prevent infinite recursion on symlinks), parallel vs sequential requests (SMB/FTP can't parallelize well), cache scan results (avoid re-scanning on refresh), how to handle mixed content (TV show folders vs movie files in the same tree).

~~Rejected by user (2026-08-22)~~ — **implemented 2026-08-26 at the user's request**; see "Picture-in-Picture" in Implemented features.

6. **User-selectable app icon (issue #23, DEFERRED 2026-09-28 by user — "might be a later upgrade")**: community request from `linausix-ui` for a Settings row to switch between the current icon and alternatives; they specifically want the logo **without** the "DreamPlayer" wordmark, since Android already prints the app name under the icon. **Research done, decision pending — the analysis is here so it does not need redoing.**

   **Artwork is a non-issue.** `assets/app_icon_dark.png` is 1024×1024 with the logo in the top ~63% and the wordmark below, so a text-free variant is a crop-and-recenter (PIL is available locally). No redesign needed.

   **The two platforms are NOT equally possible — this is what drives the scope decision:**

   - **iOS is clean and officially supported.** `CFBundleAlternateIcons` in `Info.plist` + `UIApplication.setAlternateIconName()`. Alternate PNGs ship in the bundle, the switch is instant, and the system persists the choice. Image files go in `ios/Runner/Assets.xcassets/` or as loose bundle resources; the app icon is currently generated by `flutter_launcher_icons` from `assets/app_icon_dark.png` (`pubspec.yaml` `flutter_launcher_icons:` block, `adaptive_icon_background: '#0E0E11'`).
   - **Android works but is genuinely fragile, and is the reason this was deferred.** It needs `activity-alias` entries in `AndroidManifest.xml` at build time plus `PackageManager.setComponentEnabledSetting()` to flip between them. Concretely: (a) launchers cache icons hard, so Pixel's launcher frequently does not reflect the change until it restarts — users report it as broken; (b) **if a bug ever disables every launcher alias the app cannot be launched at all** (no enabled component holds the LAUNCHER intent), i.e. a bricked-app failure mode in a *live* app; (c) adaptive icons (API 26+, which this app uses) need a per-alias `mipmap-anydpi-v26` XML, not just a `mipmap`; (d) Google Play is uneasy about launcher-icon changes.

   **Scoping options, cheapest first:**
   1. Not a setting — **make the text-free icon the default**, keep the current one as the iOS alternate only. Least code, no Android failure mode, and it satisfies what the reporter actually asked for.
   2. **iOS only for now** — full alternate-icon support behind a Settings row, Android-gated like the other platform-specific rows in `settings_screen.dart` (e.g. bass boost, spatial). Honors the exact ask on the platform where it is safe.
   3. iOS + Android user-selectable — the complete feature, carrying the alias/bricked-app risk.

   **Recommendation: (1), or (2) if the exact ask must be honored.** Android is the platform we *can* test on a device, but it is the one where this feature is unsafe to ship — which is the opposite of the usual tradeoff, and worth remembering. Note also that a true multi-icon *store* feature (arbitrary user-supplied artwork) is a different and much larger request than what was asked here; the issue only asks for a choice among designs the developer supplies.

### MPV without media_kit — direct SurfaceView (issue #21) + hard Media3 guardrails

**Status: Phases 1–3 LANDED (2026-09-23); issue #21 SHIPPED in 0.4.8.** Goal: reimplement the Android MPV engine **without media_kit's Flutter `Texture`** (stutters), rendering into a **real hybrid-composition `SurfaceView`** (same pattern as `ExoPlayerView`), and ship a custom `libmpv` with **libplacebo / `gpu-next`** for optional HDR/DV → SDR tone mapping (issue #21: spline → perceptual → BT.709/BT.1886).

**Phase 1+2 landed:**
- `MpvSurfaceView.kt` + `mpv_surface_view.dart` — distinct viewType `dreamplayer/mpv_player`, hybrid composition (`PlatformViewLink` + `initExpensiveAndroidView`), surfaceReady/Changed/Lost events, reflection to MediaKitAndroidHelper for the `--wid` global ref.
- `player_screen.dart` — media_kit `VideoController` + Flutter `Video` widget + `media_kit_video` package **removed**; media_kit `Player` (control) stays; `_startMpvFallback` calls `_teardownExoForMpv()` first (one surface only); wid attach order mirrors media_kit (`vo=null` → size → wid → `vo=gpu` → seek); fit modes via `keepaspect`/`panscan` + Flutter `AspectRatio`/`Transform.scale`.
- `pubspec.yaml` — `media_kit_video` dropped (was the Texture path). `media_kit` + `media_kit_libs_android_video` remain for Player control + `libmpv.so` + MediaKitAndroidHelper.
- `MainActivity.kt` registers `dreamplayer/mpv_player`.

**Phase 3 landed (custom libmpv + libplacebo):**
- `android/app/src/main/jniLibs/arm64-v8a/libmpv.so` (~29 MB, NDK r30) with **libplacebo + gpu-next** linked (built via mpv-android buildscripts + NDK r30, Docker `dreamplayer-mpv-builder`); `libc++_shared.so` alongside. Gradle `packaging.jniLibs.pickFirsts` overrides media_kit's stock `libmpv.so`; media_kit's `libmediakitandroidhelper.so` is kept.
- Tone-map UI: Settings → Player → "HDR tone-map (MPV)" + player ⋮ sheet (when `_mpvReady`) — **SDR tone-map** (`vo=gpu-next`, `tone-mapping=spline`, `gamut-mapping-mode=perceptual`, `target-prim=bt.709`, `target-trc=bt.1886`) vs **Native HDR/DV** (`target-colorspace-hint`). Store: `lib/services/tone_map_store.dart` (prefs `dreamplayer.toneMapMode`, default `sdr`).
- Apply: `_applyMpvToneMap` + `_mpvGpuNextAvailable` probe (`libplacebo-version` property) in `player_screen.dart`; wid-attach prefers `gpu-next` when available. Stock libmpv falls back to `vo=gpu` + bt.2390 extras in `_configureMpvAudio`.
- Android-only gate (`defaultTargetPlatform == android`) so the tile never appears on iOS; regression test `test/settings_tone_map_platform_test.dart`.
- **Scope note**: libplacebo runs only on the **MPV engine** (Play with MPV) — Media3's Surface cannot be intercepted (documented in issue #21 close comment). Media3 remains the DV/HDR passthrough engine.

**Why (user 2026-09-23):** the current media_kit Flutter `Texture` path **stutters** MPV video. Replace it with a SurfaceView; do not keep the texture as a fallback for mpv. media_kit is **not** used by Media3 (Media3 = ExoPlayer platform view only) — dropping the texture only affects the MPV engine.

**Target architecture**

```
Dart MpvEngineController  →  MethodChannel/EventChannel
  →  MpvSurfaceView (PlatformView + SurfaceView, hybrid composition / initExpensiveAndroidView)
       →  --wid = Surface global ref
            →  custom libmpv (libplacebo + gpu-next when #21 lands)
```

- **Native**: new `MpvSurfaceView.kt` + factory (register like `dreamplayer/exo_player`); small JNI C shim (`libdreammpv.so`: create/setProperty/command/observeProperty/destroy) wrapping libmpv — no media_kit `Player` / `VideoController` / `Video` widget.
- **Dart**: `MpvEngineController` mirrors the `ExoPlayerController` surface; migrate `_mpv*` state in `player_screen.dart` (resume keys, external subs, PiP/`MpvPipService`, fit/zoom, custom subtitle overlay, gestures). **Remove media_kit `VideoController` + `Video` widget** from the mpv slot — replace with the new SurfaceView platform view (keep media_kit `Player` only if still needed for control until the JNI path is ready; goal is no Flutter texture for video). Engine choice (`PlayEngine.mpv`, “Play with MPV”) stays user-facing.
- **libmpv build**: media_kit's stock `.so` is **`-Dvulkan=disabled -Dlibplacebo=disabled`** — gpu-next / libplacebo is impossible without a custom build. **Phase 3 custom build SHIPPED** under `android/app/src/main/jniLibs/arm64-v8a/libmpv.so` (libplacebo + gpu-next, NDK r30, built via mpv-android buildscripts in Docker `dreamplayer-mpv-builder`); Gradle `pickFirsts` overrides media_kit's binary. media_kit_libs_android_video still ships for `libmediakitandroidhelper.so` + other ABIs' stock libmpv (arm64 uses ours).
- **Tone-map mode (issue #21) DONE 2026-09-23**: Settings → Player →
  "HDR tone-map (MPV)" (`settingsToneMapMode`) + player ⋮ sheet section when
  `_mpvReady` — Native HDR/DV (`target-colorspace-hint`) vs SDR tone-map
  (`vo=gpu-next`, `tone-mapping=spline`, `gamut-mapping-mode=perceptual`,
  `target-prim=bt.709`, `target-trc=bt.1886`). Store:
  `lib/services/tone_map_store.dart` (prefs `dreamplayer.toneMapMode`, default
  `sdr`). Apply: `_applyMpvToneMap` + `_mpvGpuNextAvailable` probe
  (`libplacebo-version` property) in `player_screen.dart`; wid-attach prefers
  `gpu-next` when available. Stock libmpv falls back to `vo=gpu` + bt.2390
  extras in `_configureMpvAudio`. Optional advanced (algorithm / target peak /
  gamut) remains open as a follow-up.

**⚠️ PREVIOUS FAILED ATTEMPT (user, ~2026-09) — do not repeat**

An earlier attempt to put mpv on a SurfaceView went **badly wrong**:

- **Two video layers stacked** on top of each other (mpv SurfaceView + Media3 SurfaceView both alive / both composited).
- **Media3 broke** as well — not just mpv.
- **Both engines** showed the dual-layer mess; **local playback failed** (no playback from local files).

Root-cause class: the two engines must be **mutually exclusive platform views** — never leave an ExoPlayer `PlayerView` and an mpv `SurfaceView` mounted in the same window at the same time; never share one `viewType`/`surfaceFactory` path without tearing the other down first.

**Hard constraints (must hold on every commit that touches this)**

1. **Media3 must keep working** — primary engine, DV/HDR hybrid-composition path (`ExoPlayerView` / `PlatformViewLink` / `initExpensiveAndroidView`) is sacred; regressions here fail the project goal.
2. **Local file playback must keep working** on Media3 **and** on the finished MPV path (user: previous attempt broke local playback entirely).
3. **Mutually exclusive surfaces**: when `_engine == PlayEngine.mpv` / `_mpvActive`, **do not create** `ExoPlayerController` / `ExoPlayerView` (already true in `_init`); when Media3 is active, **do not mount** the mpv platform view. Dispose/release the inactive engine’s platform view **before** the other attaches.
4. **One `viewType` per engine** (e.g. keep `dreamplayer/exo_player` for Media3; new distinct id for mpv) — never reuse ExoPlayer’s factory for mpv.
5. **Surface recreate** (rotation / lock / activity recreate): rebind `--wid` on the new Surface; clear the old global ref; do not leave a stale SurfaceView behind the Flutter layer.
6. **Verify before merging**: on-device — Media3 local 4K/DV still composites `BT2020_ITU_PQ` (dumpsys), Media3 local play/seek **without stutter/regression**, mpv local play/seek **without stutter** (texture gone), switch engines back and forth in one session, confirm **exactly one** video layer in `dumpsys SurfaceFlinger` (no `flutter-vd` dual-stack, no two SurfaceViews).
7. **iOS untouched** — AetherEngine only; mpv remains `Platform.isAndroid`.

**Suggested phases (gate each phase on Media3 + local playback still green)**

1. JNI shim + bare `MpvSurfaceView` — **DONE** (Phase 1+2).
2. Port Dart controller; swap `player_screen` off media_kit — **DONE** (media_kit_video removed).
3. Custom libmpv + libplacebo build — **DONE** (jniLibs arm64, Phase 3).
4. Tone-map mode UI (issue #21) on OnePlus Pad 2 — **DONE** (Settings + player sheet).
5. Optional later: Anime4K / shader path on the same raw surface (SDR only; DV/HDR stay Media3).

Related: "Player engine choice" below still says Media3 is the right *default*; this plan only replaces how the **optional** MPV engine renders — it does not demote Media3.

### Player engine choice (2026-08-28, user feedback response)

A user feedback asked why we use Media3 instead of "a powerful player like MPV". This is the canonical answer if the same question comes up again — keep it in release notes and replies.

**TL;DR**: Media3 is the *correct* engine for this project. MPV is a regression, not an upgrade. External-player handoff is a separate, low-cost option that addresses the spirit of the feedback (let the user pick).

**Why Media3 is the right choice (not a workaround)**

- **Media3 is what every serious Android player uses today.** Google's official, actively-maintained playback engine — the successor to ExoPlayer 2.x. It powers YouTube, Google Play Movies, the official Android sample players, and (under the hood) Nova Video Player, Just Player, Plex, and most pro-tier Android players that aren't a VLC/fork. "Media 3" is a *brand*, not a limitation; the same way "FFmpeg" or "V8" is a brand.
- **We need hardware Dolby Vision, and Media3 is the only Flutter-friendly path that delivers it.** Our `#1` project goal is "Dolby Vision playback where the display supports it" — verified on-device (OnePlus CPH2573): the DV P8 test file decodes on Qualcomm's `c2.qti.dv.decoder` at 4K60 with zero dropped frames and real HDR reaches the panel via the hybrid-composition `SurfaceView`. (See "DOLBY VISION PLAYBACK WORKS" at the top of this file for the verification trail.)
- **Hardware HDR pipeline.** Media3 + the hybrid-composition `PlatformViewLink` + the `c2.qti.hevc.decoder` + `applyHdrHeadroom` window machinery composes video as `BT2020_ITU_PQ` with `hdr metadata types=9` (DV) / `3` (HDR10+/HDR10) on the physical display — verified via `dumpsys SurfaceFlinger`. This is the entire reason we built the in-app native player instead of using a Flutter texture.

**Why we already tried MPV and removed it (`media_kit`/`libmpv`)**

Documented in "Playback research notes" above; the short version:

1. **Dolby Vision RPU parsing fails.** mpv v0.36 + FFmpeg 6.0 cannot read the DOVI configuration record in DV P8 MKVs. Result: pink/green output. (mpv PR #16818 was the upstream fix attempt; it never landed for our FFmpeg version.)
2. **No HDR to the panel.** `media_kit` renders into a Flutter texture. Flutter textures have **no HDR path on any platform** (media-kit issue #615). The decoded HDR10 buffer is tone-mapped to SDR before the panel ever sees it. So even when mpv *decodes* HDR10 correctly, the user sees washed-out colors.
3. **4K60 performance.** `hwdec:no` (the only setting that gives correct colors with mpv) is software decode — too slow for 4K60 on Snapdragon 678. `gpu-next` is a frozen frame because media-kit renders via the legacy `gpu` path.

So adding mpv back would re-break **the thing the user came here for** (real DV + HDR on supported panels). The exit interview was: keep Media3 + native SurfaceView for DV/HDR; ship native FFmpeg audio extension for DTS/DTS-HD/TrueHD/FLAC; that's the same engine stack Nova Video Player uses (ExoPlayer + FFmpeg audio).

**iOS side is AetherEngine, not MPV either.** AetherEngine is AVPlayer + FFmpeg demux/decode + native HDR/DV passthrough for Apple containers. Same trade-off: native AVPlayer for the HDR/DV fast path, FFmpeg only where AVPlayer is too limited (WebDAV, custom containers). iOS has no MPV port that we trust for this scope.

**If MPV is ever added back, it must be opt-in and behind a clear warning.** A future opt-in "MP engine" toggle could route SDR/SDR-HEVC files through libmpv for users who want its filter/subtitle power — but DV/HDR10/HDR10+/HLG files MUST stay on Media3 + native SurfaceView or the panel stops receiving HDR. There is no way to get both from the same engine on Android today.


### iOS monetization — Apple Developer + IAP paywall (LOCKED 2026-09-09)

iOS-ONLY monetization; **Android is explicitly excluded and stays 100% free**
(no Google Play Billing — sideload distribution; Entitlements returns
`advanced = true` on Android, no HDR meter, no paywall). User is buying the
$99/yr Apple Developer Program; the paywall goes live once the account + ASC
products exist. Everything ships behind `--dart-define=PAYWALL_ENABLED=true`;
with the define OFF (shipped releases today) the app is byte-for-byte what it
is now — all free, no meter, no paywall.

**LOCKED MODEL (2026-09-09, user-approved)**:
- **Three product tiers** in App Store Connect (iOS):
  - `dp_premium_monthly_2026` — auto-renew sub, **₹199 (~$1.99)**
  - `dp_premium_yearly_2026` — auto-renew sub, **₹1,499 (~$14.99)**
  - `dp_premium_lifetime_2026` — non-consumable, **₹4,999 (~$49.99)**
    - These are the **live, approved App Store Connect product IDs** (created
      and approved for the 0.4.8 release). `paywall_sheet.dart` queries them
      by name, and `ios/Runner/DreamPlayer.storekit` mirrors them for local
      Xcode sandbox testing. Any ID change must be made in all three places
      (code, `.storekit`, this doc) or the paywall falls back to placeholders.
- **Entitlement logic**: app reads StoreKit 2 `Transaction.currentEntitlements`
  at launch + subscribes to updates. If ANY product is active ends →
  `advanced = true`. No server, no receipt validation beyond StoreKit's built-in.
  Subscriptions are Apple-ID-bound → reinstall/restore is automatic (subs
  auto-restore; lifetime via a mandatory **Restore Purchases** button).
- **NO free-trial period** configured on any subscription. The discovery
  mechanism is instead a **7-day free trial of the whole app**: the trial starts
  on the first launch where the paywall is relevant (real PAYWALL_ENABLED builds
  on iOS, or the debug "simulate free user" build on Android) and runs on the
  **wall clock** (persisted `dreamplayer.trialStartedAt`; `trialActive` =
  now - start < 7 days). While the trial is active every gate passes
  (`isEntitled = isAdvanced || trialActive` — no per-playback meter, nothing to
  reset on seek/resume, which is why the fragile 30-min playback-countdown was
  dropped 2026-09). At trial end, gates fire normally for non-subscribers.
  The Keychain (`trialStartedAt`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  NOT synchronizable) → survives restart AND reinstall on the same device
  (anti free-trial-abuse) is the deferred native-iOS implementation; today the
  start time is in SharedPreferences (per-session/device, testable on Android
  via the two debug toggles).
- **Paywall sheet** (list-based, `ListTile`/`_TvListTile`): three products
  with live StoreKit prices, Buy → Apple sheet → entitlement flips → paywall
  closes instantly (no restart). Restore Purchases button mandatory.
- **Debug toggles (Settings → General, `kDebugMode` only, Android test path)**:
  (1) "Debug: simulate free user" — forces `isAdvanced=false` + paywall active
  on Android (starts the trial lazily on first flip); (2) "Debug: simulate
  trial expired" — forces `trialActive=false` so gates fire immediately without
  waiting 7 days. Both disabled in release builds (Android stays immune).
- **Apple's cut**: 30% standard, **15% Small Business Program** (first $1M/yr,
  apply in ASC immediately). India GST 18% added at checkout by Apple; dev cut
  computed on the base tier (₹169/₹1,274/₹4,249 net @15%).
- **Policy constraints (App Store Review)**: Guideline 3.1.1 (feature unlocks
  MUST use Apple IAP; existing Support/Razorpay donations are fine — they
  unlock nothing); Paid Apps Agreement + bank/tax forms before products;
  Restore Purchases wherever a paywall exists; privacy-policy URL at submission.

**LOCKED GATE MAP (final, 2026-09-09)** — gated features behind `advanced`:

| # | Feature | Gate type |
|---|---|---|
| 9 | **Dolby Vision / HDR10 / HDR10+ / HLG playback** | Trial-gated (7-day free trial; gates fire after expiry) |
| 36 | Subtitle styling (size/color/background/outline/delay) | Choice-gate on tap (paywall) |
| 19 | Playback speed (any value ≠ 1×) | Choice-gate on selecting ≠ 1× |
| 17 | A-B loop | Choice-gate on setting A/B |
| 18 | Sleep timer | Choice-gate on arming timer |
| 56 | Download to device | Choice-gate on start |
| 37 | OpenSubtitles online search | Choice-gate on opening search sheet |

**Explicitly NOT gated (iOS free forever)** — gating these would burn reviews
(OutPlayer lesson: gating table-stakes = 1★ wave):
- **PiP (22)** — only works on the native-AVPlayer path; Jellyfin/WebDAV/Files
  FFmpeg-sourced files have NO PiP on iOS today. Gating it = "paid and PiP
  doesn't work on my NAS file".
- Gestures (15), aspect/fit (12), repeat/shuffle (16), auto-next (20),
  chapters — table-stakes.
- All codec audio decode (24) — every format plays free or the player has no
  reason to exist.
- All sources & browsing library/TMDB (41–55) — bread and butter; never gate
  WebDAV/Jellyfin/SMB/FTP.
- Subtitle VIEWING (32–35, 38–40) — only *styling* is gated.
- Background playback (5), resume (21), watched (45), cover art (54),
  info probe (55), downloads-list VIEWING (57), download dir picker (58).
- **Android = every feature free forever** (hardcoded `advanced = true`,
  zero gated code paths; the gate map is iOS-only).

**ANDROID IMMUNITY GUARANTEE (2026-09-09)** — Android builds (esp. GitHub
Releases sideloads) must NEVER show a paywall even after future bug-fix and
feature releases. Three independent layers make a paywall leak on Android
structurally impossible:
1. **Source-level platform gate (the chokepoint)**: the ONLY authority is
   `Entitlements.advanced` in `lib/services/entitlements.dart`. It returns
   `true` UNCONDITIONALLY when `defaultTargetPlatform == TargetPlatform.android`
   before any StoreKit read. No widget reads StoreKit directly — every gate
   call site consumes this one getter, so Android can never be "not advanced".
2. **StoreKit never initializes on Android**: the `in_app_purchase` plugin
   setup (product fetch, transaction listener, entitlement refresh) is wrapped
   in `Platform.isIOS` and skipped on Android — zero IAP code paths exist on
   that OS, so nothing can even attempt a purchase state.
3. **`PAYWALL_ENABLED` is OFF by default AND ignored on Android**:
   `paywallEnabled = bool.fromEnvironment('PAYWALL_ENABLED', defaultValue: false)`.
   The Android release workflow (`release.yml`) NEVER passes the define. Even
   if someone forces it, every paywall call site ANDs `paywallEnabled &&
   Platform.isIOS && !advanced`; on Android `advanced` is always true so the
   paywall sheet's `show()` is a guaranteed no-op.
Enforced by tests: `test/entitlements_test.dart` asserts (a) on Android
`advanced` is always true, (b) all 7 gate helper functions return
`notRequired` on Android regardless of store state, and (c) the paywall
sheet builder returns null on Android. CI (`flutter test`) gates the paywall
branch. Future Android-only features must follow the same pattern: read
`Entitlements.advanced`, never touch StoreKit, never gate.
- Note: bass/volume-boost/night-mode/spatial (28–31) are **Android-only today**;
  they don't exist on iOS, so they're NOT in this gate map. If iOS audio DSP
  is ever built (AVAudioEngine), it can be added behind the paywall later —
  never double-gate the same feature. (Spatial audio is a different case: it
  is NOT custom DSP on iOS, it rides AVPlayer's built-in system
  spatialization — see "iOS spatial audio" in the Roadmap, which is deferred
  for a verification reason, not an entitlement one.)

**Testing gate** (2026-09-09): ✅ **ALL 7 GATES VERIFIED** on-device
(OnePlus CPH2573, `a019b7f3`, debug APK, 2026-09-09). Paywall code can
now be written behind `PAYWALL_ENABLED`.
- ✅ #9 HDR10+ playback — `hdr10+test_lake_2021_02_01.mp4` decoded via
  `c2.qti.hevc.decoder`, SurfaceFlinger `BT2020_ITU_PQ hdr metadata types=7`,
  `desired hdr/sdr ratio=5.0` (EDR ramp engaged).
- ✅ #36 Subtitle styling — House S02E05 + `.srt` sibling; CC sheet →
  "Subtitle settings" → size/color/background/outline/delay all functional,
  XL preview rendered at 1204 px.
- ✅ #19 Playback speed 1.5× — confirmed via MediaSessionService logcat
  `speed=1.5`.
- ✅ #17 A-B loop — A at 12:29, B at 14:17; user-confirmed loop on-device.
- ✅ #18 Sleep timer — radio-only-checked bug fixed (`_sleepOption` field +
  `_sheetSetSheet` capture), 5-min timer counted down live in sheet, paused
  both engines on fire.
- ✅ #56 Download to device — network source ⋮ → "Download to device" triggers
  foreground service + notification + progress; completed file playable from
  home grid.
- ✅ #37 OpenSubtitles search — CC sheet → "Search online subtitles…" opened
  search form, results returned, subtitle downloaded and applied.

**Implementation sketch**:
- Official `in_app_purchase` Flutter plugin (StoreKit 2 + Play Billing behind
  one API). New `Entitlements` ChangeNotifier service: loads
  `Transaction.currentEntitlements`, caches locally for instant UI, exposes
  `advanced`; `buy()`. Paywall sheet reads localized prices from
  `Product.products(for:)`.
- iOS native: Keychain store for `trialStartedAt` (channel `dreamplayer/trial`)
  so the 7-day trial survives restart/reinstall; gates read `isEntitled`
  (`isAdvanced || trialActive`).
- Gate wiring: paywall-on-tap at the 7 call sites via `_gate()`; all behind
  `PAYWALL_ENABLED`.
- **Settings-tab gates (2026-09-09, premium tiles only)**: `SettingsScreen` has
  its own `_settingsGate()` (same `checkGate` shape as `PlayerScreen._gate`);
  Android is always advanced so it is a guaranteed no-op there. Wired onto the
  **#37 family** only — OpenSubtitles sign-in (settings_screen.dart OpenSubtitles
  tile, gated on the login branch; logout stays free), **Subtitle download
  language** (`settingsSubDownloadLang`), and **Auto-fetch online subtitles**
  (toggle gated only when turning ON; off is always free). Subtitle **Reading
  language** + **Encoding** stay free (documented "subtitle viewing free",
  App Review risk). **Auto-fetch loophole closed (2026-09-09)**: `_maybeAutoFetchSubs`
  (player_screen.dart) downloaded online subtitles with NO gate — an automatic
  bypass of #37's choice-gate; it now calls `_gate()` before searching
  (`_autoFetchFired` latch means a gated user isn't nagged per state change).
- `.storekit` configuration file for local/CI without money; sandbox testers
  + TestFlight for production products.

**Order of ops when account clears**: agreements/bank/tax -> Small Business
Program -> create 3 products (₹199 / ₹1,499 / ₹4,999) -> Entitlements + paywall
(1–2 days) -> gates + Restore button -> sandbox verify -> submit.

### Competitor-gap roadmap, phased (2026-08)

Gap analysis vs Infuse / Just Player / Nova / VLC produced a phased plan. Later
phases start only after the previous phase is verified on-device.

**Phase 1 — speed + cadence (DONE 2026-08-23, on-device verified)**:
- **Playback speed**: bottom-bar overflow now holds the rate (`1×`, `1.5×`);
  the speed dropdown offers 0.25×–2× (`_openMoreSheet` collapsible sections,
  same `_tvListTile` pattern). Persisted as `dreamplayer.playbackSpeed`
  (`PlaybackSpeedStore`), re-applied after every `open()`/`_reopenAt()`.
  Android: Media3 `player.setPlaybackSpeed`. iOS: `AvPlayerView.applySpeed`
  finds the engine's `AVPlayerLayer` (recursive layer walk) and sets
  `AVPlayer.defaultRate` (=16 deployment target) + `rate` when playing;
  re-applied after every load/reload because the engine builds a fresh player.
  **iOS FFmpeg custom-source path (WebDAV) has no AVPlayer → no-op there**
  until AetherEngine exposes a rate API.
- **Refresh-rate matching** (Android, in `ExoPlayerView.kt`):
  `matchRefreshRate()` runs on STATE_READY and onVideoSizeChanged; reads
  `videoFormat.frameRate`, filters `display.supportedModes` to the current
  resolution, picks the mode with the smallest |refresh − fps|, and switches
  only when that candidate beats the current mode by more than rounding noise
  (±0.5 Hz covers 59.94-vs-60). Sets `preferredDisplayModeId` on the window;
  `restoreRefreshRate()` puts back the mode captured at attach (flutter_displaymode's
  high-refresh pick) on dispose.
- **OOM fix (2026-08-24, debug heap)**: `MediaCodec_loop` abort
  (`could not create MediaCodec.BufferInfo` + `growth limit 256 MB`) was a
  Java-heap OOM — `media3TargetBytes` 96 MiB + debug JIT filled the heap.
  Fix: `android:largeHeap="true"` (manifest) + `BufferTuning` 96→64 MiB on
  large-RAM devices (still ~50 s of 10 Mb/s, Fire TV 192 MB heap stays 24 MiB).

**Phase 2 — chapters + watched state (chapters + watched DONE 2026-08-24, on-device
verified for local/SMB/Jellyfin/WebDAV)**:
- **Chapters** (`MkvChapters.kt`, `SeekableReader` abstraction): Media3 has no
  chapters API, so the player parses MKV `Chapters` itself — EBML walk: Segment →
  SeekHead (`SeekID=0x1043A770`, position relative to segment data start,
  verified by re-reading the ID at the target) with a bounded top-level
  fallback walk; `EditionEntry`→`ChapterAtom` (nested atoms flatten) collecting
  `ChapterTimeStart`/`End` (ns→ms) + first `ChapterDisplay`/`ChapString`
  (fallback "Chapter N"); ends backfilled from the next start. `RafReader`
  (local `RandomAccessFile`), `SmbReader` (`SmbRandomAccessFile` via saved share
  credentials), and `ByteArrayReader` (HTTP `Range: 0-8M` via OkHttp, standard +
  permissive clients for self-signed WebDAV) share the same `SeekableReader`
  parser. Jellyfin also provides `Item.Chapters` (`Fields=Chapters` in
  `getItems`; top-level `json['Chapters']` with fallback to
  `MediaSources[0].Chapters` → `VideoChapter` ticks/10000 ms). Parsed on a
  daemon thread after open, pushed as `chapters` in the event map (native) or
  seeded from `VideoItem.chapters` (Jellyfin). Player: the bottom bar's overflow
  `⋮` holds Aspect/Speed/Chapters as collapsible dropdowns — chapters section
  appears only when the file has them, highlights the current chapter and taps
  seek. MP4 chapter tracks not parsed yet.
- **Watched marks** (`lib/services/watched_store.dart`, prefs key
  `dreamplayer.watched`, StringList of resume keys): auto-marked when a video
  plays to STATE_ENDED (`_markedWatched` latch reset per open), manual toggle
  via the check icon on every folder-screen row (files + Jellyfin playables;
  same stable resume keys). Green check = watched. Resume labels now show
  `h:mm:ss` for ≥1h (was `m:ss`) in both the details `Resume from` button
  (`tmd_details_screen.dart:_formatClock`) and home `Continue from`
  (`home_screen.dart:_positionLabel`). Series-page grouping is the remaining
  piece of this phase. The overflow sheet change also declutters the bottom bar
  from 6 → 4 buttons (`audio · CC · ⋮ · fullscreen`; `tune`/`1×`/`chapters`
  now live inside `⋮`).

**Phase 3 — parity + binge (DONE 2026-08-26)**: Android subtitle delay live via
`DelayingParser` (`android/.../DreamSubtitleParserFactory.kt:71` `SubtitleTiming.delayUs` + `ExoPlayerView.kt:2931` reopen on change; PGS/DVB bitmap cues still not shifted), auto-play-next-episode within the same folder (local/SMB via `_orderedSiblings` + `JellyfinClient` `ParentId` sibling walk `lib/screens/player_screen.dart:893`).

**Phase 4 — Nova-style details screen (DONE 2026-08)**:
- **Nova-style details screen redesign**: removed `_HeaderImageGallery` (stills gallery), `_HeaderArtwork`, `_CastTile` (cast section); added Nova-style episode header (show name + S01E01 badge + episode name + season name), `_FileInfoCard` (video/audio codec, resolution, file size, path), `_SubtitlesCard` ("Search subtitles online" → `OpensubtitlesSheet`), `_TrailersCard` (YouTube trailer links via `url_launcher`), `_SearchDialog` (TV/Movie `SegmentedButton` toggle, year param, kind-first search with fallback), `TmdTrailer` class + `TmdDetails.trailers` parsed from `videos.results` in `append_to_response=credits,videos`. Removed auto-prefetch from all file browsers (folder, SMB, WebDAV, FTP, UPnP, Jellyfin) and file-tap `resolve()` calls.

**Phase 5 — Nova feature gaps (DONE 2026-08)**:
- **Cast row** (`_CastRow` widget in `tmd_details_screen.dart`): horizontal scrollable row of cast members with circular photos (TMDB `image.tmdb.org` via `FadeInImage`), names, and character names. Appears below overview for every TMDB-matched movie or single-episode view. `TmdCastMember` model gained `profileUrl()` method; `TmdEpisode` gained `cast` and `guestStars` fields (parsed from `credits.cast` and `credits.guest_stars`).
- **Stills gallery** (`_StillsGallery` widget in `tmd_details_screen.dart`): horizontal scrollable row of 16:9 episode stills from TMDB (`TmdEpisode.stillUrls()`). Appears in single-episode view when stills are available. `TmdEpisode` gained `stills` field parsed from `images.stills`.
- **Per-episode still thumbnails**: `_FolderEntryTile` and `_JellyfinEntryTile` now use `episode?.stillUrl()` for the leading tile image instead of the series poster — matches Nova's behavior where each episode shows its own still. Falls back to `posterUrlOf(meta)` when no TMDB episode data is cached.
- **Season expansion header**: `_SeasonExpansion` now accepts `seasonName` and displays "Season 2 · The Name of the Season" (Flexible for overflow). Both `FileEntry` and `JellyfinItem` season expansions pass `_meta?.seasons[s]?.name`. `TmdSeason` gained `overview` and `posterPath` fields (parsed from TMDB API) with `posterUrl()` method.
- **Continue-watching series grouping** (`_groupedByShow` in `home_screen.dart`): episodes from the same TV show cluster into a single card on the home grid, using the show's poster and the most recently played episode's info. Movies and unmatched episodes pass through ungrouped. `_GroupedContinueWatching` model holds the show title, TMDB meta, and sorted episode entries.
- **VideoItem model extensions**: added `seasonNumber`, `episodeNumber`, `seriesName` fields (serialized to/from JSON) for series grouping without re-parsing filenames.

**Phase 6 — Nova-style file info probe (DONE 2026-09)**:
- **Native file info probe** (`android/.../MediaProbe.kt`, channel `dreamplayer/mediaProbe`): the `_FileInfoCard` on the details screen now shows **real container metadata** (not just filename parsing) for every source — duration, resolution, video codec, fps, audio codec, channels, language — exactly as Nova probes the file header via its FFmpeg core. Implementation: `MediaMetadataRetriever` (fast: duration, dimensions, bitrate) + `MediaExtractor` (detailed: per-track codec, fps, language, channel count). Probe runs on a background thread, result applied via `setState`; a "Probing file…" spinner shows while loading.
  - **SMB files** (`smb://` URIs from home bookmarks): the native `MediaExtractor` can't open `smb://` directly, so `MediaProbe.kt` temporarily starts the `SmbHttpProxy` HTTP loopback, probes via the local `http://127.0.0.1:port/token` endpoint, then tears it down — same loopback infrastructure used by the mpv fallback engine.
  - **FTP/SFTP files** (`ftp://`/`sftp://` URIs): `MediaExtractor` can't open these either. Dart-side `MediaProbe.probeViaTempDownload()` downloads the first 8 MB to a temp file via `HttpClient`, probes the temp file, then deletes it.
  - **HTTP/HTTPS files** (WebDAV, Jellyfin, UPnP/DLNA, SMB browser loopback): probed directly — `MediaExtractor.setDataSource(url, headers)` handles the auth headers for WebDAV/Jellyfin.
  - **Local files** (`/storage/…`, `content://`): probed directly via `setDataSource(path)` / `openFileDescriptor`.
  - **`formatVideoCodec` / `formatAudioCodec` fix** (`codec_info.dart`): these functions now strip MIME prefixes (`video/hevc` → `hevc`, `audio/eac3` → `eac3`) before lookup, so `MediaExtractor` MIME types map correctly to display labels (HEVC, E-AC3, etc.).
  - **`_FileInfoCard` wired for all sources** (`tmd_details_screen.dart:1815`): name, location (SMB `smb://share/path`, WebDAV `https://…`, FTP `ftp://…`, local `/storage/…`, content `content://…`, with loopback `127.0.0.1` filtered), duration, size, video codec·resolution·fps + HDR badge, audio codec·channels·language. Probed values override filename-derived ones.
  - **`_buildNoMatch` fix**: when no TMDB match exists, the card now renders `_FileInfoCard` + `_SubtitlesCard` below the "Get Info" button — file details show even without metadata.
  - **VideoItem model**: added `fps` (int?) and `audioLanguage` (String?) fields, serialized in `toJson`/`fromJson`, carried through `withPlaybackInfo`/`withExternalSubtitles`. All browser screens (SMB, folder, WebDAV, FTP, UPnP, Jellyfin, file browser, open-intent) wire these fields.
  - **`_probing` state**: `TmdDetailsScreen` tracks probing state and passes it to `_FileInfoCard`, which shows a `CircularProgressIndicator` + "Probing file…" text while the native probe runs.

**Home screen + menu cleanup (2026-09)**: the "+" menu was reorganized from a flat list of 8 items into a cleaner two-level structure:
  - **Top level** (always visible): "Add folder to library" + "Internal storage"
  - **Network sources** (collapsed `ExpansionTile`): SMB/WebDAV/FTP/Jellyfin/DLNA/Play URL — collapsed by default so local actions are immediately reachable; expands to show all network options.
  - `_showAddMenu()` in `home_screen.dart` rewritten with `ExpansionTile` for the network section.

**Pull-to-refresh on home (2026-09)**: the home `CustomScrollView` is wrapped in a `RefreshIndicator` (`AlwaysScrollableScrollPhysics` so the gesture works even on an empty library). Pulling down calls `_refreshHome()` (home_screen.dart), which reloads the whole surface in one go however a folder was added: re-reads the persisted `LibraryFolder`s (a folder bookmarked from any network-share browser — SMB/WebDAV/FTP/UPnP/Jellyfin — appears on the grid without reopening the screen), re-fetches Jellyfin server-side posters for any folder missing one (`_refreshJellyfinMeta`), refreshes continue-watching positions, and re-runs the TMDB lookups behind every card (`_resolveFolderMetadata`).


**Content URI path display fix (2026-09)**: `_displayLocation()` in `tmd_details_screen.dart` now decodes `content://` URIs to show clean local paths instead of raw URL-encoded SAF document IDs. For example:
  - Before: `content://com.android.externalstorage.documents/document/primary%3AMovies%2Ffile.mkv`
  - After: `/storage/emulated/0/Movies/file.mkv`
  - Mapping: `primary:` → `/storage/emulated/0/`, `secondary:` → `/storage/sdcard1/`, other providers show the decoded document ID.

Later/demand-driven**: cloud drives.

### UPnP/DLNA browse (DONE 2026-08, both platforms)

Home **+** → "DLNA" (`lib/screens/upnp_screen.dart`, channel
`dreamplayer/upnp`): SSDP discovery → server list → ContentDirectory browse →
TMDB-postered file rows → details screen → player. Android `UpnpClient.kt`
(XmlPullParser SOAP/DIDL), iOS `UpnpClient.swift` (BSD-socket SSDP with poll +
resend, `IP_MULTICAST_TTL=2` + `IP_MULTICAST_IF=en*`; multicast entitlement in
`Runner.entitlements`). **iOS discovery fallbacks when SSDP is gated**
(multicast often dropped on managed Wi-Fi): saved-Jellyfin-hosts probe →
Jellyfin UDP-7359 broadcast → direct probe `http://192.168.1.16:8096`. Parse
layer uses the upnpx/VLC-iOS semantics — `shouldProcessNamespaces=false` +
qualified-name suffix matching (`dc:title`/`upnp:class`) and a single-pass
entity unescaper; Foundation's namespace processing silently yielded zero
entries on iPad. On-screen Diagnostics box (server-list AND browser empty
states) via `getDiagnostics`.

- **Jellyfin DLNA transcode trap (2026-08, the big one)**: Jellyfin refuses
  direct-play for items carrying external subtitles (default DLNA profile has
  no subtitle delivery) and serves a LIVE TRANSCODE instead — HTTP 200 chunked,
  `video/mp2t`, `DLNA.ORG_CI=1`, HEVC→H.264 TS, `Accept-Ranges: none`. Both
  engines choke (Android `parsing_container_unsupported`, iOS "source has no
  audio stream"), it is unseekable, and it strips DV/HDR. Verified against the
  real NAS: sibling without sidecars = instant `stream.mkv` 206; episode with
  `.ass/.srt` = `stream.ts` re-encode. Fix: `JellyfinClient.upgradeDlnaUrl()`
  matches `/dlna/(videos|audios)/<id>/` res URLs against saved Jellyfin servers
  (origin match) and rebuilds the `VideoItem` through `getItem`+`videoItem` —
  original-bytes direct play + sidecar subs as tracks + chapters + stable
  resume key. Non-Jellyfin DLNA URLs play raw as before.
- **Multi-res DIDL trap (2026-08, found via live repro)**: Jellyfin's DIDL
  advertises ONE `<res>` PER EXTERNAL SUBTITLE alongside the video res
  (`text/srt` DeliveryUrls like `/Videos/{id}/{msId}/Subtitles/N/0/Stream.srt`).
  Both native parsers took the LAST res — so any items with sidecars handed the
  player an `.srt` AS THE MAIN MEDIA (`parsing_container_unsupported` /
  "source has no audio stream"). Fix in `UpnpClient.kt` + `UpnpClient.swift`:
  prefer the res whose `protocolInfo` contains `video/`, fall back to
  first-seen; every non-video res is collected into `externalSubs`
  (`UpnpExternalSub` in Dart) and attached as selectable subtitle tracks on
  the raw DLNA path too. NOTE: Jellyfin's DLNA DIDL is INCONSISTENT per
  session — the same item alternates between a `CI=1 stream.ts` transcode
  offer (+ srt res entries) and a clean `stream.mkv?Static=true&VideoCodec=
  hevc` direct offer; both paths are handled (transcode → red badge; direct →
  HEVC chip, no badge). Verified on-device both ways.
- **Transcode badge**: red "Transcoding" chip in the player top bar whenever
  playback is server-transcoded — Jellyfin HLS fallback engaged
  (`_transcodeActive`, which also now actually gets SET, fixing the leak where
  the server-side encode job was never stopped on dispose), DLNA item whose
  `protocolInfo` carries `CI=1` (`UpnpEntry.transcoded`, emitted by both native
  parsers), or a `master.m3u8` URI. `VideoItem.isTranscoded` persists through
  JSON.

### Library (user-added folders)

The home library shows **only folders the user explicitly adds** — nothing is auto-scanned. **Status: implemented (2026-08; verified on-device 2026-09 via the series-grouping / season flow).** Reference-only: videos are never imported or moved; they stay in place and play through the folder's SAF tree (`tree:<id>`), absolute path, or (for Jellyfin folders) the server API.

**Behavior**
- **Add a folder** — home **+** → "Add folder to library" → system folder picker (`pickLibraryFolder`, `ACTION_OPEN_DOCUMENT_TREE`). The picked folder is saved in `LibraryFoldersStore` (shared_preferences `dreamplayer.libraryFolders`, most-recently-added first; `LibraryFolder` model in `lib/services/library_folders.dart`). **Library folders are bookmark-separated** (2026-08): the pick goes through `pickLibraryFolder` → native stores the tree under a library-only bookmark key (Android `libfolder.<uuid>` in `dreamplayer.folderBookmarks`; iOS `dreamplayer.libraryFolderBookmarks` in UserDefaults), so a library folder is listable by `listDirectory`/`resolveAllBookmarks` but **never appears as an Internal-storage file-browser root**. A TV-show folder (or a movie folder, SD card, USB drive, cloud apps) is the typical target.
- **Network folders can be bookmarked to Home too (2026-08)** — the SMB, WebDAV, FTP, and DLNA (UPnP) browsers each gained an AppBar **bookmark** button that pins the current folder to the home library. `LibraryFolderSource` (`files|jellyfin|smb|webdav|ftp|upnp`) selects the listing backend at open time; a network entry stores `networkServerId`/`share`/`path`/`label` (never credentials — those live in the native stores) and lists through the same client that drove the browser (`SmbClient`/`WebDavClient`/`FtpClient`/`UpnpClient`). **Jellyfin folders** are added straight from the Jellyfin browser's folder tiles (see the Jellyfin bullet above); a Jellyfin entry stores only the server URL + item id (token never persisted) and is re-matched to the signed-in server on every open.
- **TMDB poster** — on home load (and after adding), `TmdService.resolveFolder(folder.metadataKey, folder.name)` runs in the background; `TmdApi.bestForQuery` searches **TV then movie** (TV hits get a +0.001 tie-boost — folders are primarily shows) and caches the match under `folder:<id>` in TmdStore. `FolderCard` (`lib/widgets/folder_card.dart`) shows the poster + real title + year + "TV Series"/"Movie" badge plus a **per-source badge** (SMB blue, WebDAV orange, FTP purple, DLNA grey, Jellyfin teal), or a gradient + folder icon while unresolved.
- **Folder contents / episode list** — a network source's home card opens `FolderScreen` **directly** (`TmdDetails`' file list only handles FileBrowser/Jellyfin), which lists via the source client (SMB/WebDAV/FTP/DLNA bookmark branches in `folder_screen.dart`; `initialPath` deep-links into subfolders, trailing slashes trimmed). Local (`files`) and Jellyfin folders keep routing through `TmdDetailsScreen(folder:)` details page → `FolderScreen`. Network branches show folders-then-videos (parsed `SxxExx` labels + file sizes), tap → `TmdDetailsScreen` → player.
- **Remove from library = unlist, never delete** — long-press a folder card → "Remove from library" → the folder is dropped from the store, its native library bookmark is released (`removeLibraryBookmark`, skipped for Jellyfin/network folders — no SAF grant), and its `folder:<id>` TMDB metadata is cleared (a re-add re-matches cleanly). Files on disk are never touched.
- **Cross-platform**: works on Android (SAF bookmarks) and iOS (Files-app picked folders) — unlike the old MediaStore scan, which was Android-only.
- **Superseded (2026-08)**: the Android-only MediaStore scan (scan-and-show every device video, `READ_MEDIA_VIDEO` grant card, exclusion list) was fully **removed** — `lib/services/library_scan.dart` (`LibraryVideo`/`LibraryScanService`/`LibraryStore`), `test/library_scan_test.dart`, and the native `scanLibrary`/`folderFor` + ContentUris/Cursor/MediaStore imports in `FileBrowser.kt` are gone. The prefs keys it used (`dreamplayer.libraryCache`, `dreamplayer.libraryExcluded`) are dead.
- The iPad equivalent (Photos import) is out of scope — Files/WebDAV/Jellyfin already cover iPad local + network playback.

## CI / Deployment

- **TMDB API key policy (2026-09)**: release builds on **both** Android and iOS compile with **no `TMDB_API_KEY`** define (Android `release.yml` APKs; iOS `release.yml` step) — users enter their own key via the first-launch hint dialog → Settings → Metadata. **Test builds bundle it**: the local `flutter run`/debug with `--dart-define-from-file=.env` (Android) and the dedicated `ios.yml` workflow (iPad/TestFlight) inject the key so the feature works without opening Settings. The first-launch **TMDB hint dialog** (`home_screen.dart` `_showTmdbHintOnce`, prefs `dreamplayer.tmdbHintShown`) shows on **both Android and iOS** — a "Get a free TMDB API key" link button opens `themoviedb.org/login` in the external browser (`launchUrl` directly — `canLaunchUrl` is false for https VIEW on Android 11+), and "Open Settings" pushes `SettingsScreen` wrapped in a `Scaffold`+`AppBar` (it is built for the tab IndexedStack, no own Scaffold).
- **iOS builds happen in GitHub Actions** (user has no Mac). Workflow: `.github/workflows/ios.yml`
  - **Manual-only** (`workflow_dispatch` — no push trigger): run it from the Actions tab when a build is wanted; builds unsigned IPA artifact always.
  - Signed build + TestFlight upload run only when secrets are configured.
  - Secrets needed: `IOS_CERT_BASE64`, `IOS_CERT_PASSWORD`, `IOS_PROFILE_BASE64`, `KEYCHAIN_PASSWORD`, `APPSTORE_TEAM_ID`, `APPSTORE_API_KEY`, `APPSTORE_API_KEY_ID`, `APPSTORE_ISSUER_ID`, `TMDB_API_KEY`, `OPENSUBTITLES_API_KEY`, `SIMKL_CLIENT_ID`.
  - **Build command: `flutter build ipa`** (NOT raw `xcodebuild`). `flutter build ipa` handles plugin SPM resolution, `GeneratedPluginRegistrant` regeneration, and passes signing to xcodebuild internally. Raw `xcodebuild archive` bypasses Flutter's plugin reconciliation — any plugin without SPM support at the pinned version causes a hard `Module not found` error deep in compilation that Flutter would catch and name explicitly.
  - **iOS signing gotchas — full debug trail (2026-09)**:
    - **Keychain list must append, not replace**: `security list-keychains -d user -s $KEYCHAIN_PATH $(security list-keychains -d user | tr -d '"')` — replacing kills `login.keychain-db` which `security cms` (used to decode the provisioning profile) and other system tools depend on.
    - **WWDR G3 intermediate cert must be imported** into the custom keychain: `curl -sSL -o /tmp/AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer && security import /tmp/AppleWWDRCAG3.cer -k $KEYCHAIN_PATH`. Without it, `codesign` finds the identity but can't validate the trust chain.
    - **`security set-key-partition-list`** is required after import: `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH`. Without it, `codesign` fails silently or reports `resource envelope is obsolete`.
    - **Provisioning profile must be installed** to `~/Library/MobileDevice/Provisioning Profiles/` AND the profile UUID must match the app's bundle ID. Decoded dynamically via `security cms -D -i $PP_PATH` → plistlib → `Name` field.
    - **`PROVISIONING_PROFILE_SPECIFIER` on xcodebuild cmdline leaks to ALL targets** — including SPM packages (shared_preferences_foundation, permission_handler_apple, swift-crypto) which reject it: `"does not support provisioning profiles"`. Fix: set it ONLY in the Runner target's build settings in `project.pbxproj` via `ios/signing_setup.py`. `CODE_SIGN_STYLE`, `DEVELOPMENT_TEAM`, and `CODE_SIGN_IDENTITY` on the command line are safe (SPM targets don't complain about those).
    - **App ID must be explicit, not wildcard**: `com.dreamplayer.app` works; `3D7UAK63Z2.com.dreamplayer.app.3D7UAK63Z2` (wildcard) is rejected for App Store / IAP. The bundle ID in App Store Connect MUST match `project.pbxproj`'s `PRODUCT_BUNDLE_IDENTIFIER` exactly.
    - **App Store Connect API key (.p8)**: must be the raw file contents (including `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----`). `altool` expects the key on disk at `~/private_keys/AuthKey_<KEY_ID>.p8`. The `apple-actions/upload-testflight-build@v1` action handles this; the manual `xcrun altool` path needs it written explicitly. `altool` does NOT expand shell globs (`*.ipa`) — resolve the path with `ls` first.
    - **Stale `GeneratedPluginRegistrant.m`**: `flutter clean` + `flutter pub get` before building ensures removed plugins (e.g. old `media_kit_video` references) don't produce `Module not found` errors. The registrant is regenerated by Flutter's tooling, not committed to git.
    - **`flutter build ipa` vs raw xcodebuild**: the former runs `pub get`, regenerates the registrant, resolves ephemeral SPM packages, validates plugin integration, then archives+exports. Raw `xcodebuild archive` skips all of that. Every signing/SPM/module error in this project's history traces to invoking xcodebuild by hand.
  - **Signing architecture (`ios/signing_setup.py`)**: a standalone Python script that (1) decodes the `.mobileprovision` via `security cms -D`, (2) patches `project.pbxproj` to set `CODE_SIGN_STYLE = Manual` + `DEVELOPMENT_TEAM` + `CODE_SIGN_IDENTITY` + `PROVISIONING_PROFILE_SPECIFIER` on the Runner target only, (3) builds `ExportOptions.plist` with the profile name, (4) calls `flutter build ipa --release --export-options-plist`. Run from the workflow after keychain setup. The pbxproj patch targets `PRODUCT_BUNDLE_IDENTIFIER = com.dreamplayer.app;` as an anchor (only the Runner target has this exact value; RunnerTests has `com.dreamplayer.app.RunnerTests`).
  - **TestFlight upload**: `xcrun altool --upload-app --type ios --file <ipa> --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>`. The `.p8` private key must be written to `~/private_keys/AuthKey_<KEY_ID>.p8` first. altool does not expand globs — use `ls build/ios/ipa/*.ipa | head -1` to resolve.
  - **7-day free trial**: stored in **SharedPreferences AND the iOS Keychain** (post-approval, shipped in 0.5.0). The Keychain copy is what makes the trial **survive app deletion + reinstall** — `ios/Runner/TrialStore.swift` (channel `dreamplayer/trial`) is mirrored by `lib/services/trial_store.dart`. `_loadTrialStart()` reads SharedPreferences first (so pre-existing installs keep their value and get backfilled into the Keychain) and falls back to the Keychain on a fresh/reinstalled app; `_persistTrialStart()` writes both. The Keychain item is `kSecAttrSynchronizable` (so it follows the user to a new device via iCloud Keychain) with a device-local fallback when iCloud Keychain is unavailable. History: the Keychain was added 2026-09-18, removed 2026-09-20 so pre-approval testers wouldn't hit a stale trial, and re-added 2026-09-28 after the App Store approval (App Store Connect analytics had shown a redownload loop). **Consequence for testing:** any device that ran the 2026-09-18 TestFlight build still holds a months-old Keychain trial marker and will report "trial ended" — that is the anti-abuse working, not a bug. Clear it by removing the Keychain item, and note that a real user who first installed on 2026-09-24 (0.4.8) never ran a Keychain build, so no real user can be affected.
- **GitHub Releases** (`.github/workflows/release.yml`): push a `v*` tag (`git tag v0.4.5 && git push origin v0.4.5`) → builds the **universal** release APK + **split-per-abi** APKs (`arm64-v8a`, `armeabi-v7a`, `x86_64`) on `ubuntu-latest` (+ tests first); then creates the GitHub Release on the tag with the matching `## <version>` section extracted from CHANGELOG.md + `.github/release_notes.md`, attaching all artifacts. No unsigned iOS IPA is built here (retired per DPLA 7.6/3.2(g) — signed TestFlight builds come from the separate `ios.yml` workflow). App version is **0.4.5** (`pubspec.yaml` `version: 0.4.5+1`) and must be bumped per release to match the tag.
- **Android release signing (DONE 2026-09-09)**: `android/app/upload-keystore.jks` (`alias upload`, RSA 2048, 10000-day validity, `CN=DreamPlayer`; `SHA-256 2ff29762…`) + gitignored `android/key.properties` (store/key passwords, alias, `storeFile=upload-keystore.jks` — the `storeFile` path resolves relative to the **app module** dir, so the keystore lives in `android/app/`). `build.gradle.kts` now defines a `release` signing config **only when** `key.properties` exists (`hasUploadKeystore`, existence checked via `file(...)` — NOT `rootProject.file(...)`, which checks the wrong dir — and the debug fallback stays `signingConfigs.getByName("debug")`). Verified on-device builds: with the keystore present the APK signs as `CN=DreamPlayer`; with it absent (CI) it falls back to `Android Debug` — both `assembleRelease` paths build. **The keystore + passwords are irrecoverable — back them up** (they're gitignored, machine-local, 600 perms). CI releases stay **debug-signed** by design (no keystore secrets in a public repo for sideload-only distribution); when Play publishing starts, add the keystore as base64 GH secrets + a `google-play` upload step and switch CI to producing `.aab` via the Play console. Play requires the SAME upload key forever — do not lose it.
- **Bundle ID (iOS)**: `com.dreamplayer.app`. **App display name**: `DreamPlayer`.
- **Android**: app label `DreamPlayer`; package `com.dreamplayer.app` (matches iOS bundle ID `com.dreamplayer.app`). Build/test locally on the phone.

## Repository / Git

- Remote: `https://github.com/mangeshghodke/DreamPlayer.git`
- Branch: `main`
- Never commit secrets.

## Commands

```bash
flutter pub get          # fetch dependencies
flutter analyze          # static analysis
flutter test             # run tests
flutter run --dart-define-from-file=.env   # run on Android phone (USB) — the gitignored .env carries API keys
flutter run --release    # test real-world smoothness (debug is jankier)
flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=.env && flutter install --debug -d <device-id>
flutter build apk        # release APK (use --split-per-abi; TMDB key via --dart-define-from-file=.env)
flutter build appbundle  # for Play Store
adb shell monkey -p com.dreamplayer.app -c android.intent.category.LAUNCHER 1   # launch app
adb shell dumpsys SurfaceFlinger | grep -a activeMode                                  # check refresh rate
```

**iOS has no local Xcode**, so native Swift/Objective-C changes are verified blind.
Two gates stand in for the compiler:

```bash
python3 tool/ios_native_check.py   # C symbols, ObjC declaration-vs-implementation,
                                   # class-method ivars, nested @interface, one
                                   # @implementation per class, methods outside
                                   # any block, selector defined after use, dot
                                   # syntax with an argument label, unterminated
                                   # ObjC literals, control characters, NS_SWIFT_NAME
                                   # consistency, Swift Foundation imports,
                                   # interpolation shapes, pbxproj shape
bash ios/libsmb2_build.sh          # compile the vendored libsmb2 arm64 archive
```

**Do not treat it as a substitute for a build — it cannot typecheck Swift.** But
do run it: every structural Objective-C mistake made while porting the SMB browse
path (a nested `@interface`, methods left outside any `@implementation`, a second
`@implementation` of one class, a stray `U+0001` inside a function name) cost a
signed build before its rule existed, and all of them are now caught in
milliseconds. Each rule was proven by injecting the fault and confirming the
failure.

Two limitations are recorded in the file itself and are **deliberately not
checked**: the `NSError**` → `throws` bridge (Swift prunes trailing type words, so
`readFileAtPath:…error:` is called as `readFile(atPath:…)`, and several screens
define their own `listDirectory`/`openFile` helpers, so no name-based match is
reliable), and Swift name resolution generally.

**Also do not skip asserting in `smb_debug.log` that a new log line actually
appeared.** Two iOS fixes this cycle looked correct, had passing tests, and did
nothing at all: one armed a resume target *after* the load returned when the
racing audio-track restore arrived 75 ms *into* it, and one gated on
`engine.state == .playing` in a branch that can only ever be reached while
`.loading`. A rule that cries wolf is worse than no rule, which is why two
candidate checks were deleted rather than shipped — see the notes in the file.

## Display & smoothness (native refresh rate)

- **Android**: `flutter_displaymode` selects the display's highest refresh rate at app startup (`lib/services/display_refresh_rate.dart`). Many Android devices default apps to 60 Hz even on 90/120/144 Hz panels. Verified: panel runs 120 Hz during animations, 60 Hz when idle.
- **iOS/iPad Pro**: ProMotion 120 Hz is unlocked via `CADisableMinimumFrameDurationOnPhone = true` in `ios/Runner/Info.plist` (already set).
- **Playback cadence**: ExoPlayer renders at the video's FPS onto the platform-view SurfaceView. Revisit frame pacing once smoothness is assessed on-device.
- **DEBUG BUILDS JITTER — always judge smoothness on a RELEASE build (2026-08, Redmi Note 10)**: 4K60 HDR playback in the **debug** APK showed periodic dropped frames while moneytoo's Just Player (release) was buttery smooth — but the ExoPlayer `DecoderCounters` showed `rendered=60fps steady, droppedBuffer=0` and SF `--latency` cadence was clean (0 double/triple frame gaps over 60 s; the only inevitable artefact is the 59.94-on-60 Hz beat, ~1 double frame per 16.7 s, present in both apps). The jitter was Flutter **debug-mode** overhead (JIT VM + hybrid-composition platform-view per-frame cost), not the decode/render path. Installing the **release** APK made it play as smooth as Just Player (user-verified). When the user reports "dropped frames" against a debug install, first re-test with `flutter build apk --release --dart-define-from-file=.env` + `flutter install` before touching the player code. Same rule as the `flutter run --release` comment below.

## Project layout

```
lib/
  main.dart                     # entry point (native refresh rate, runs app)
  app.dart                      # root MaterialApp, dark theme, text-scale clamp, nav shell, double-back-press exit guard (PopScope) + localizationsDelegates + supportedLocales via ListenableBuilder
  l10n.yaml                      # Flutter gen-l10n config (camelCase output)
  l10n/
    app_en.arb                    # English (source of truth, 467 strings)
    app_es.arb                    # Spanish (placeholder)
    app_zh.arb                    # Chinese Simplified (placeholder)
    app_ru.arb                    # Russian (placeholder)
    app_localizations.dart        # Generated AppLocalizations class
    app_localizations_en.dart     # Generated English delegates
    app_localizations_*.dart      # Generated delegates for other locales
  theme/app_theme.dart          # colors, dark theme (video apps are dark)
  models/
    video_item.dart             # VideoItem + codec label getters
    hdr_format.dart             # HdrFormat enum (SDR/HDR10/HDR10+/DV/HLG)
    library_video.dart          # LibraryVideo model for MediaStore scan results (id, path, title, duration, width, height, sizeBytes, dateAdded, mimeType, resolutionLabel)
  utils/codec_info.dart         # HDR detection + codec -> label mapping + live label merge
  utils/tv_helper.dart          # TV detection (isTvMode, isTvBox), swipe gesture prefs
  services/display_refresh_rate.dart  # high refresh rate selection (Android)
  services/language_service.dart  # Language preference persistence (shared_preferences)
  services/exo_player.dart        # ExoPlayerController + ExoPlayerView platform view (hybrid composition on Android) + PlaybackController interface (brightness/volume) + VideoFitMode/FitModeStore + PlaybackSpeedStore
  services/continue_watching.dart # continue-watching list (shared_preferences JSON)
  services/watched_store.dart     # watched marks (prefs dreamplayer.watched, StringList of resume keys, auto on ended + manual toggle)
  services/jellyfin_client.dart     # Jellyfin/Emby REST + mDNS discovery + JellyfinServer/JellyfinItem/JellyfinItemInfo models + videoItem/serverForUrl/getItemInfo helpers + folder-meta cache + VideoChapter from Item.Chapters
  services/tmdb_client.dart        # TMDB: filename parser (ParsedFileName), TmdApi (search/details/bestForQuery), TmdStore cache, TmdService facade
  services/the_tvdb_client.dart    # optional TheTVDB v4 client, provider mapping, pagination, and secure credential channel
  services/library_folders.dart    # user-added library folders (LibraryFolder model + LibraryFoldersStore, prefs dreamplayer.libraryFolders; LibraryFolderSource.files|jellyfin|smb|webdav|ftp|upnp)
  services/folder_scanner.dart     # deep recursive folder scanner (up to 5 levels, all 6 sources; leaf-vs-container logic)
  services/local_library_rescan.dart # local-only rescan on pull-to-refresh (issue #39): add/remove cards when files change on device
  utils/chapter_nav.dart         # pure chapter-jump arithmetic (indexAt/next/previous/current) + grace window
  services/webdav_client.dart     # WebDAV channel wrapper + WebDavServer model (channel dreamplayer/webdav)
  services/thumbnail_store.dart   # embedded cover-art cache for video cards (memory+disk, local sources only)
  services/image_cache_service.dart # offline TMDB image cache (posters/backdrops/stills/profiles, disk + memory, prefetch on resolve)
  services/mpv_pip.dart           # libmpv fallback engine's picture-in-picture bridge (pipChanged/pipDismissed/pipPlayPause/pipRewind/pipForward; setState pushes state into PipManager)
  services/media_probe.dart       # native MediaExtractor probe via MethodChannel; probe() for smb/http/local, probeFile() for temp files, probeViaTempDownload() for ftp/sftp
  services/download_manager.dart  # DownloadManager singleton: HTTP+SMB download, progress tracking, SharedPreferences history, cancel/delete, one-at-a-time queue
  services/series_grouping.dart   # cross-folder series grouping (baseNameOf/prefix merge, pure Dart, unit-tested)
  services/manual_groups.dart     # user-made manual groups (ManualGroup/ManualGroupsStore, prefs dreamplayer.manualGroups; select N cards → Group)
  services/default_engine_store.dart # dreamplayer.defaultEngine (Media3 / libmpv / ask)
  services/audio_track_store.dart # per-video+engine last audio pick (audio_track_{engine}_{resumeKey})
  services/tone_map_store.dart    # dreamplayer.toneMapMode (sdr|native) for MPV HDR tone-map
  services/mpv_surface_view.dart  # MpvSurfaceView platform view (hybrid composition, no Flutter Texture)
  utils/mpv_audio_select.dart     # pickMpvDefaultAudioId + parseMpvDefaultFlag (container DEFAULT audio pin)
  config/tmdb_api_key.dart        # default TMDB key from --dart-define=TMDB_API_KEY (never committed)
  l10n/
    app_en.arb                    # English (source of truth, ~350-400 strings)
    app_es.arb                    # Spanish
    app_zh.arb                    # Chinese Simplified
    app_ru.arb                    # Russian
  screens/
    home_screen.dart            # Continue watching grid (adaptive columns, grouped by TV show) + Your-library folder grid + **+** FAB menu (Jellyfin / WebDAV / Add folder / Internal storage)
    folder_screen.dart          # folder contents / episode list (subfolder navigation, SxxExx labels + sizes)
    player_screen.dart          # ExoPlayer/Media3 playback + live codec/HDR chips + controls + subtitle/audio pickers + gesture controls + libmpv fallback engine (_startMpvFallback / _mpvOpen / _attachMpvExternalSubtitles / _onPipPlayPause / _onPipRewind / _onPipForward)
    player_error.dart           # friendlyPlayerError (Media3 ERROR_CODE_* → user message) + isRetryableIoError / isVideoDecodeError predicates (unit-tested)
    tmd_details_screen.dart     # TMDB details: Nova-style episode header + info/subtitles/trailers cards + cast row + stills gallery + per-episode still thumbnails + Play + Fix match search
    movie_group_screen.dart     # manual-group detail screen: backdrop hero + header (overview/rating/genres) + cast + trailers + grouped poster cards grid
    jellyfin_screen.dart        # Jellyfin/Emby server list + 7359-probe/mDNS discovery + login + libraries → folders → play
    webdav_screen.dart          # WebDAV server list → folders → play (add/edit/delete servers, self-signed toggle)
    settings_screen.dart        # settings list + swipe gestures toggle (Player section, phones/tablets only) + HDR tone-map (Android-only) + default engine
    download_screen.dart        # download list UI: progress bars, status badges, cancel/delete/play buttons
  widgets/
    video_card.dart             # library card with HDR/audio badges
    folder_card.dart            # library folder card (TMDB poster or gradient placeholder + TV/Movie badge)
    cached_image.dart           # CachedImage — disk-cached TMDB image with fade-in (wraps ImageCacheService)
    collapsing_backdrop.dart    # CollapsingBackdrop + backdropExpandedHeight: width-derived hero height, shared by 3 screens
    format_chip.dart            # colored codec/HDR chip
    tv_tile.dart                # shared focus-glow wrapper for TV list items
    tv_overscan.dart            # overscan safe-area padding (36px sides, 20px top/bottom)
    tv_text_field.dart          # TV-friendly TextField with skipTraversal inner node
    episode_row.dart            # shared episode/file row + still & poster thumbs (issue #38)
android/app/src/main/kotlin/com/dreamplayer/app/
  ExoPlayerView.kt              # native PlayerView platform view + channels (open/play/seek/tracks/subtitles) + OkHttp permissive DataSource for self-signed WebDAV
  SubtitleFormats.kt            # extension->MIME map, sibling auto-pairing, charset detection, UTF-8 re-encode
  DreamSubtitleParserFactory.kt # SAMI/MicroDVD/MPL2/SubViewer parsers + default delegate
  FileBrowser.kt                # device storage browsing channel (roots/listing/folder bookmarks; no thumbnails)
  WebDAVClient.kt               # WebDAV browse/test channel; encrypted password storage; friendly errors
  TheTvdbCredentialStore.kt     # Android Keystore-backed TheTVDB API key/PIN store and MethodChannel
  MulticastLockManager.kt       # Wi-Fi MulticastLock + Jellyfin UDP-7359 broadcast probe (channel dreamplayer/multicast)
  MediaProbe.kt                 # native MediaMetadataRetriever + MediaExtractor probe (channel dreamplayer/mediaProbe); SMB via HTTP loopback, local/content direct
  PipManager.kt                 # libmpv fallback-engine picture-in-picture (RemoteAction transport buttons: rewind/play-pause/forward); channel dreamplayer/pip
  SmbHttpProxy.kt               # loopback HTTP/1.1 server that exposes an SMB file to libmpv via 127.0.0.1:<port>/<token> with Range support
  DownloadService.kt            # foreground service for downloads (NOTIF_ID=4211, cancel BroadcastReceiver)
  DownloadClient.kt             # method channel handler for download progress/cancel bridge to Dart
  MpvSurfaceView.kt             # MPV hybrid-composition platform view (viewType dreamplayer/mpv_player; surfaceReady/Changed/Lost)
  MainActivity.kt               # registers platform views (exo + mpv_player) + "Open with" intent handling + routes pip/snapshot/stop calls between ExoPlayerView and PipManager based on which engine is active
ios/Runner/
  LibSMB2.h / LibSMB2.m         # libsmb2 wrapper: LAN sweep + IPC$ identify (LibSMB2Server), plus LibSMB2Session/LibSMB2File for playback (smb2_open/fstat/pread). CREATE Name is share-relative with NO leading separator
  SMBBridge.swift               # in-app SMB browsing, share listing, discovery and playback, all on libsmb2; status probe; junk filtering; unnamed-server name falls back to the host
  SMBSource.swift               # SMBPlayback (libsmb2-only: one session/one handle) + SMBSourceReader: IOReader over smb2_pread; SMBByteRangeSource/SMBIOReader retained unwired
  AvPlayerView.swift            # AetherEngine platform view + channels (same contract as ExoPlayerView.kt); host SubtitleOverlayView; WebDAV http(s) streams with headers/self-signed via WebDAVByteRangeSource; SMB playback + pendingResumeSeconds/reloadSession(at:autoplay:)
  BufferedSMBReader.swift       # read-ahead sliding-window IOReader (32 MiB) for WebDAV playback
  JellyfinDiscovery.swift       # Jellyfin UDP-7359 broadcast probe (channel dreamplayer/multicast, discoverJellyfin; Android: MulticastLockManager.kt)
  WebDAVClient.swift            # WebDAV browse/test channel (same contract as WebDAVClient.kt); Keychain passwords; WebDAVByteRangeSource for playback
  FtpClient.swift               # FTP/SFTP browse/test/playback channel (POSIX control conn + Citadel SFTP; FtpByteRangeSource + transfer gate)
  FileBrowser.swift             # Documents-folder browsing channel (same contract as FileBrowser.kt); resolveImportedPath; TheTVDB Keychain store
  IntentBridge.swift            # "Open with" intent channel (same contract as MainActivity.kt)
  AppDelegate.swift             # registers the AvPlayerView factory + files/intent/webdav channels
  DownloadClient.swift          # download-to-device channel (getDownloadDir, notification progress); registered in AppDelegate
  SceneDelegate.swift           # forwards scene-opened URLs to IntentBridge
test/
  test_helper.dart              # shared localizationDelegates for widget tests
  widget_test.dart              # shell/navigation/overflow tests
  codec_info_test.dart          # HDR + codec formatting unit tests
  tmdb_test.dart                # TMDB filename parser + metadata store round-trip + API key fallback tests
  jellyfin_test.dart            # Jellyfin models + stream URL construction
  player_error_test.dart        # friendlyPlayerError (Media3 ERROR_CODE_* mapping) + isRetryableIoError + isVideoDecodeError predicates
  upnp_client_test.dart         # UPnP/DLNA entry + transcoded/externalSubs parsing
  library_folders_test.dart     # library folder store (files vs jellyfin source)
  watched_store_test.dart       # watched marks store
  mpv_audio_select_test.dart    # container DEFAULT audio pin helper
  audio_track_store_test.dart   # per-video+engine last audio pick
  tone_map_store_test.dart      # dreamplayer.toneMapMode store
  settings_tone_map_platform_test.dart # HDR tone-map tile hidden on iOS / shown on Android
  resume_store_test.dart        # resume position store
  continue_watching_test.dart   # continue-watching list
  subtitle_style_test.dart      # subtitle appearance store
  the_tvdb_client_test.dart     # TheTVDB v4 auth, mapping, pagination, season handling, secure store
  metadata_provider_test.dart   # provider-qualified metadata cache serialization
  smb_resume_key_test.dart      # SMB resume key round-trips to the real share; path and videoUri agree
  backdrop_height_test.dart     # backdrop hero is width-derived and viewport-capped
  artwork_inheritance_test.dart # folder->file artwork inheritance, per-kind, one-way
  continue_watching_identity_test.dart # continue watching resolves to the file card's key
  library_file_identity_test.dart  # a file entry's metadataKey is its resume key
  details_header_poster_test.dart   # an explicit poster pick beats the season poster
  chapter_nav_test.dart           # issue #40 chapter jump: grace window, null-at-end (no wrap), duplicate starts
  app_debug_log_test.dart         # Dart-side log is inert under flutter_test and never throws
  tmd_store_persist_test.dart      # TmdStore writes coalesce; nothing lost mid-write (iOS freeze fix)
  local_library_rescan_test.dart   # issue #39 rescan: id preservation, add-only fallback, root reconstruction, applyDiff ordering
  episode_label_test.dart         # offline episode title fallbacks (TMDB name -> S01E05 -> file name)
  episode_row_test.dart           # shared EpisodeRow: sizes, tap/long-press, icon fallback, no overflow
  episode_row_series_test.dart    # the REAL season-row title/subtitle widgets at phone widths
  episode_row_responsive_test.dart # size follows the ROW width; rotation, font scale, no overflow
  episode_row_real_test.dart      # real trailing chrome (2 IconButtons + chevron) declares its width
```

## Workflow for the user (no Mac)

- **Standing permission (2026-08-22)**: build and `flutter install --debug -d a019b7f3` directly onto the user's OnePlus CPH2573 for feature verification — no need to ask each time. Test features on-device BEFORE pushing feature commits to GitHub; small compile fixes may follow the tested code.

1. Develop + test on Android phone (USB debugging, `flutter run --dart-define-from-file=.env`).
2. Commit/push to `main`; iOS workflow in GitHub Actions builds the iPad version.
3. Later: configure code-signing secrets + TestFlight for installing on iPad Pro M2.
