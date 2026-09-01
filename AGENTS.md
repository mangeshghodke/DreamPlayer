# DreamPlayer

A cross-platform video player built with Flutter.

## Goal

A video player app supporting:
- **Android** (primary, tested on user's Android phone — CPH2573, Android 16) and **iOS/iPad** (user's iPad Pro M2)
- **All audio codecs**: DTS, DTS-HD, E-AC3, AC3, TrueHD, etc.
- **Dolby Vision** where the display supports it
- **FFmpeg-based** decoding engine

## Current status

- App **UI skeleton** done (library, player, settings; dark theme).
- **HDR / codec on-screen display** done (Dolby Vision, HDR10+, HDR10, SDR; E-AC3, DTS-HD, TrueHD, AAC, ...).
- **Responsive layout** — no overflow on phones/tablets/landscape/large text.
- **Native refresh rate** selected at startup (verified 120 Hz on device).
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
  SMB playback was fully REMOVED (2026-08, see "SMB / network shares") — NAS files reach the app
  via CX/Files "Open with" (iPad) or in-app WebDAV/Jellyfin.
  **Minimum iOS 17.0** (`IPHONEOS_DEPLOYMENT_TARGET = 17.0`; bumped from
  16.0 on 2026-08 because Citadel (SFTP) requires iOS 17; builds through the
  latest, iPhone and iPad).
  - Channel mapping: state 1/2/3/4 (idle/buffering/ready/ended); DV surfaces as
    `dvhe.<profile>.06` so Dart's `dv`-prefix detection fires; `colorTransfer`
    6 for HDR10/10+/DV, 7 for HLG. Audio/subtitle tracks pushed via
    `currentTracks`; `selectAudioTrack`/`selectSubtitleTrack`/`clearSubtitle`
    mapped 1:1 to engine calls.
  - **SMB fully removed (2026-08)**: the in-app iPad SMB browser (`SMBClient.swift`,
    channel `dreamplayer/smb`) and all `AvPlayerView` SMB paths (`smbToken`/
    `isSMBStream`/`reopenSMBStream`/`previousStaleSMBConnection`/
    `sniffFormatFromSMB`) were DELETED — slow, and it didn't play every video
    (the reopen/teardown audio-switch crash never came back but the entry was
    retired for good). NAS playback is via CX/Files "Open with" +
    bookmarked folders, in-app WebDAV, and in-app Jellyfin. `BufferedSMBReader.swift`
    STAYS — the WebDAV playback path (`WebDAVByteRangeSource`) still wraps it for
    read-ahead (32 MiB window / 4 MiB chunks; WebDAV keeps 4 MiB since one HTTP
    Range request ≈ one round-trip, unlike SMB's serial reads — the 256 KiB SMB
    chunk cap now applies only if SMB ever returns, see the roadmap).
    `AetherEngineSMB` product also STAYS in the Xcode project: WebDAV lives in
    that module (`ByteRangeSource` protocol + `WebDAVByteRangeSource`).
    CI will verify
    the iOS build.
  - **iOS "Network shares" → Files app folder picker (2026-08)**: the home
    **+** → "Network shares" tile on iOS (it shows only on iOS; Android keeps
    the in-app `SmbScreen`) opens `pickLibraryFolder`, so the user connects an
    SMB share via Files "Connect to Server" in the document picker, picks the
    share root, and it lands as a **library folder** on the home grid (TMDB
    poster + browsable/playable via the security-scoped bookmark stack).
  - **Replay / scrub-after-end**: AetherEngine's `.ended` is terminal (seek and
    play are explicit no-ops there), so `AvPlayerView` keeps the last-opened
    `url` + `LoadOptions` and a `play`/`seekTo` arriving in `.ended` reloads the
    session (`reloadSession(at:)` — start for replay, target for scrubber
    pull-back) instead of calling a no-op seek. The active subtitle track is
    re-applied after the reload.
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
  view, DV/HDR-capable) and **libmpv** (`media_kit: ^1.2.6` +
  `media_kit_video: ^2.0.1` + `media_kit_libs_android_video: ^1.3.8`;
  renders into a Flutter `Texture` via media_kit's `VideoController`). Both
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
  - **Limits (unchanged)**: can't do DV/HDR (Flutter textures have no HDR
    path) — `Engine · libmpv` + `SDR (MPV)` in the info sheet and the details
    row caption "SDR only — no Dolby Vision / HDR" keep that honest, and
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
| SMB client (iPad) | **removed (2026-08)** | In-app SMB (AMSMB2 browse + AetherEngineSMB playback) was retired; NAS playback is WebDAV / Jellyfin / Files-app "Open with". `AetherEngineSMB` still ships for WebDAV's `ByteRangeSource`. |
| Android audio decode | Media3 `FFmpegAudioRenderer` (ffmpeg extension) | DTS, DTS-HD, E-AC3, AC3, TrueHD — same bundled-FFmpeg approach Nova uses. |
| Reference architecture | **Nova Video Player** (`nova-video-player/aos-AVP`) | See "Playback research notes". |
| **Second engine (Android)** | **media_kit + libmpv** (hardware-first via `hwdec=auto-safe`, FFmpeg software fallback, Flutter `Texture` render) | **User-chosen** second engine: `Play with MPV` on the TMDb details screen (or `Try with MPV` on the Media3 error surface). Renders into a Flutter texture so no DV/HDR — by design, Media3 keeps the project goal. Ships `libmpv.so` via `media_kit_libs_android_video` — Android-only, so iOS doesn't pull in `Mpv.framework` (which breaks SideStore's `ldid` signer). iOS does not run mpv. |
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

- **Friendly error messages + software-decode auto-fallback on hardware-decode failure (2026-08-29)**:
  - **Bug fix (every PlaybackException was showing the raw code)**: the Dart `_friendlyError` switch matched snake_case strings like `error_code_io_bad_http_status` / `error_code_decoder_init_failed`, but Media3's native `emit(errorCodeName = error.errorCodeName, …)` returns `ERROR_CODE_*` names (verified by disassembling `media3-common-1.10.1` — `PlaybackException.getErrorCodeName(int)` returns e.g. `"ERROR_CODE_DECODING_FAILED"`, `"ERROR_CODE_IO_BAD_HTTP_STATUS"`, etc.). The snake_case cases were **dead code** — every real error fell through to the generic `"Playback failed (ERROR_CODE_…).message"`, which is what the user reported as "code decoding failed". The mapping now lives in `lib/screens/player_error.dart` (`friendlyPlayerError` / `isRetryableIoError` / `isVideoDecodeError`) and is unit-tested in `test/player_error_test.dart` (9 new tests, full suite 212 passing). Same fix applied to the IO-retry predicate so the existing exponential-backoff auto-retry now actually fires.
  - **Software-decode auto-fallback**: budget MediaTek/Qualcomm chips sometimes have a **hardware H.265/HEVC decoder that misreports 10-bit Main10 support and then fails at runtime** with `ERROR_CODE_DECODING_FAILED` — VLC/mpv play the same file fine because they use FFmpeg software decode. On any video-decode error (`ERROR_CODE_DECODING_FAILED`, `…_DECODER_INIT_FAILED`, `…_DECODER_QUERY_FAILED`, `…_DECODING_FORMAT_UNSUPPORTED`, `…_DECODING_FORMAT_EXCEEDS_CAPABILITIES`, `…_DECODING_RESOURCES_RECLAIMED`), `_trySoftwareDecodeFallback` in `player_screen.dart` saves the user's original `decoderMode` in `_decoderOverride`, writes `sw` to `DecoderModeStore` (which the native `MediaCodecSelector` lambda re-reads **live** on every query — see `PlayerCodecs.kt:91-94` "Read prefs LIVE on every query"), reopens at the current position with a brief "Hardware decoder failed — retrying with software…" overlay, and restores the user's original mode at the top of `_openCurrent` (next file) and in `dispose`. Override is per-file only. The decoder chip in the ⓘ info sheet shows "· software" so the user can see the fallback engaged. **Verified on user-reported case (Infinix Hot 50i, MediaTek G81)**: their HEVC Main10 10-bit MKV (`Strike the Blood Final [Ma10p_1080p][x265_flac].mkv`, 1080p, SDR) plays in mpv/VLC smoothly; with this fix DreamPlayer will too.

- **Picture-in-Picture (2026-08-26, user-requested — supersedes the 2026-08-22 rejection)**:
  - **Android**: manifest `android:supportsPictureInPicture="true"` on `MainActivity`; **auto-enter** on HOME/recents while playing (`onUserLeaveHint` → `ExoPlayerView.enterPipIfPlaying`, aspect from `videoSize` clamped 0.42–2.39 → `Rational(n,1000)`); **⋮-sheet row** (explicit entry). **Settings toggle** "Picture-in-picture" (Player section, Android-only, pref `dreamplayer.pipEnabled`, default ON) gates **only auto-entry** — `enterPipInternal(auto)` reads the pref natively (`flutter.dreamplayer.pipEnabled` from `FlutterSharedPreferences`) because the decision happens in `onUserLeaveHint` before Dart could weigh in; the ⋮ row is an explicit user action and ignores the toggle. With PiP off, leaving the app **keeps background audio playing** (user decision — the toggle controls the floating window only; swipe-app-away still pause+stops). Pip window shows ONLY the video: every reveal path gated on `_inPip` (`_showControls`, `_syncControlsForPlaybackState`, gestures, TV key-reveal) and the format chips are transient (next bullet), so nothing leaks into the window. **Dismissal-pause gotcha**: swiping the pip away delivers `onStop` while the system STILL reports `isInPictureInPictureMode=true`, so a `currentlyInPip` guard skips the pause and audio plays on invisibly — `onActivityStopped()` instead pauses whenever the `pipSeen` latch is set (set in `onPipModeChanged(true)`, cleared ONLY in `onResumed()` = expand-back). Tap on the pip body = expand to fullscreen (standard). Verified on-device: HOME → pip playing clean (no chips/bars), swipe-dismiss → `state=PAUSED`.
  - **iOS** (`AvPlayerView.swift`): `AVPictureInPictureController(playerLayer:)` (`canStartPictureInPictureAutomaticallyFromInline = true`), `enterPip` channel case, `AVPictureInPictureControllerDelegate` emits `inPip` + restores on expand; native-AVPlayer path only (the FFmpeg custom-source path has no `AVPlayerLayer` → no pip there). **Second-swipe fix (2026-08, `4d11555`)**: `restoreUserInterfaceForPictureInPictureStop` no longer nils `pipController` — it stays valid while its `AVPlayerLayer` is alive; `DidStop` re-arms via `ensurePipController` so HOME floats again.
  - **Stale-build gotcha**: a failed gradle build leaves the PREVIOUS apk in `build/…` — `adb install -r` then installs old code and "fixed" behavior looks broken/random. After any failed build, compare APK mtime vs `adb shell dumpsys package com.dreamplayer.app | grep lastUpdateTime` before testing.

- **Embedded cover-art thumbnails (2026-08-26)**: video cards show the file's **embedded artwork** (MKV attached pictures / MP4 `covr`) instead of the plain gradient. `FileBrowser.getThumbnail` (`dreamplayer/files`) reads **metadata only** — `MediaMetadataRetriever.getEmbeddedPicture` (Android) / `AVURLAsset` `commonMetadata` `commonKeyArtwork` (iOS; MKV attachments unreadable there, MP4/MOV only) — never `getFrameAtTime`, which returns black frames for DV/HDR (do not add frame-extracting thumbnails). Local sources only (path / `file:` / `content:` / `tree:`); remote (SMB/WebDAV/Jellyfin/HTTP) skip the probe. `ThumbnailStore` (`lib/services/thumbnail_store.dart`) caches bytes in memory + disk (`<tmp>/cover_art/<fnv1a32hex>-<tail≤24>.img`), negative-cache in-memory only, keyed by `TmdStore.identityKeyFor` (same key as the details screen). TMDB backdrop still wins on continue-watching cards — embedded art renders only when there's no TMDB match. **Deadlock gotcha**: `future.whenComplete(() => map.remove(key))` DEADLOCKS — the arrow returns `Map.remove`'s value, which IS the same future (it waits on itself); use a block body `{ _inFlight.remove(key); }`. Probe failures/timeouts (10 s guard) just leave the gradient.

- **Transient format chips + Video info sheet (2026-08-26)**: the top-bar chips (HDR / video / audio / resolution / decoder / transcode / boost / night / spatial) no longer persist — they **flash for 5 s on the first STATE_READY per open** (`_flashChips`, `_chipsFlashedForOpen` latch reset in `_openCurrent`), fade via `AnimatedOpacity` + `IgnorePointer`, and are force-hidden on pip entry. The top-bar **ⓘ button** (right corner, `_TvControlButton` so the TV D-pad reaches it) opens a read-only **"Video info" sheet**: Title / HDR / Video / Audio (· Passthrough) / Resolution / **Decoder** (full component name + hardware/software — previously only in a chip tooltip) / Stream (server transcoding) / Spatial audio / Volume boost / Night mode / Bass boost. Motivation: persistent badges cluttered long sessions and leaked into the pip window. Labels shared with the chips through `_videoCodecInfoLabel` / `_audioInfoLabel` / `_resolutionInfoLabel` getters (DV dedup included).

- **NEVER put `Spacer()`/`Expanded()` inside AlertDialog `actions` (2026-08 gotcha, broke every network-server dialog)**: `AlertDialog` lays `actions` out in an **OverflowBar**, not a Flex — a Flex child there throws `Incorrect use of ParentDataWidget … Expanded wants FlexParentData, found _OverflowBarParentData` while mounting and the whole dialog form dies (user-visible: "only the Test button, no input fields" on FTP/WebDAV/Jellyfin/SMB add-server dialogs). The four dialogs had a `const Spacer()` between Test and Cancel for push-right spacing; fix: removed them + `actionsAlignment: MainAxisAlignment.spaceBetween` in the shared `serverDialog()` helper (`lib/widgets/server_form_kit.dart`). Regression-tested in `test/server_dialog_layout_test.dart`, which pumps both dialogs at phone + iPad portrait/landscape sizes and asserts all 6 TextFields mount at full height (≥40 px) — this test is what caught the bug; label-Text heights are NOT a valid size proxy (a floating label is naturally ~16 px).

- **Volume Boost + Night Mode — Android-only (2026-08)**: real effects live in `ExoPlayerView.kt` (`applyAudioEffects`): a `LoudnessEnhancer` on the player's audio session — boost 1.0–3.0× maps to 0–1500 mB gain; Night Mode alone pins 400 mB (compression-ish lift) and combines additively with boost; re-attached on `onAudioSessionIdChanged`, persisted via `flutter.dreamplayer.audioBoost`/`nightMode` prefs, re-applied on every open. **Verified on-device** (OnePlus CPH2573): `dumpsys media.audio_flinger` shows the `Loudness Enhancer` effect chain attach/detach as the toggles change. iOS is a **deliberate no-op** (`AvPlayerView.applyAudioBoost`): `AVPlayer.volume` caps at 1.0 and there is no public DRC-over-AVPlayer API, so boost >1 clamps back to 1.0 and night mode only stores/emits the flag. To avoid fake affordances, both controls are hidden on iOS (Settings Player section + player ⋮ sheet gated on `defaultTargetPlatform == TargetPlatform.android`); settings still persist cross-platform and light up if the engine ever gains a gain/DRC hook. A real iOS fix means routing AetherEngine's decoded PCM through an owned `AVAudioEngine` + Apple's DynamicsProcessor unit — large effort, deferred.

- **Bass Boost — Android-only (2026-08-25)**: `android.media.audiofx.BassBoost` attached to the same session in `applyAudioEffects` (independent of the loudness guard — applies even at 1.0× / night mode off); levels Off/Low/Medium/High → strength ~150–1000; persisted `flutter.dreamplayer.bassBoost`, live via `setBassBoost`, emitted as `bassBoost` in the event map. The ⋮ sheet row is **gated on `_liveSpatial == 'on'`** — it exists to offset HRTF low-end thinning during spatial virtualization, so it appears only while the teal Spatial chip is active and vanishes when routing/content changes. Works on any output (wired/USB/BT) since it's session-level DSP. iOS: no public API over AVPlayer; would need AetherEngine PCM routed through an owned `AVAudioEngine` with an `AVAudioUnitEQ` low-shelf band (+4–8 dB @ ~100 Hz) plus re-plumbing position/pause/rate/seek — deferred alongside volume boost.

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
  - **Sleep timer**: Off / 5 / 10 / 15 / 30 / 60 min / **End of current video**. Minute-based arms a 1 s ticker (`_sleepTicker`, countdown shown in the sheet subtitle, fires → pause + SnackBar); end-of-video sets a flag consumed by the ended-router so nothing auto-plays after. Timer survives auto-next opens, cancelled on player dispose.

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
- **Audio track selection** (mute button replaced): the bottom bar's first button opens an "Audio tracks" bottom sheet listing every audio track from the native Media3 `currentTracks` (language · codec · channels · bitrate), with the active track check-marked. Picking a track calls `setAudioTrack` → native `TrackSelectionParameters` override → `onTracksChanged` re-emits → the top-bar audio chip (live codec + channel count) updates automatically. Native plumbing in `android/.../ExoPlayerView.kt` (`buildAudioTracks`, `selectAudioTrack`), pushed on every event as `audioTracks`/`selectedAudioTrack`; Dart model `ExoAudioTrack` in `lib/services/exo_player.dart`. Verified on-device: Sonic (DTS-HD MA + FLAC) switches DTS-HD → FLAC and the chip follows.
  - **Full track names**: the sheet prefers the container-provided track `label` (e.g. `DTS-HD MA 5.1`, `Commentary`) and appends the channel count unless the name already carries it; otherwise it composes `languageName(lang) · codec · channels`. `ExoAudioTrack` gained a `label` field; ISO-639 codes map to full English names via `languageName()` in `codec_info.dart`.
  - **iOS audio fixes (2026-08, 0.3.5)**: **network sources** (WebDAV / Jellyfin / FTP — AetherEngine loopback/`ByteRangeSource` can't re-probe in place, so `AvPlayerView` now proactively `reloadSession` + `waitForEngineReady` (`PlaybackState` `.playing`/`.paused`) and re-applies the track); **opposite-track bug** — `audioTrackMaps` used to emit native `id` as `index` while Dart treated `index` as flat position, so `engine.selectAudioTrack(index:)` hit the wrong track — now iOS mirrors Android (`index` = flat pos, `selectedAudioTrack` = flat pos via `firstIndex(where: id == active)`, `engineAudioId(forFlatPosition:)` converts flat→`id` at the boundary).
- **FLAC via FFmpeg + E-AC3 decoder workaround**: a custom `MediaCodecSelector` in `ExoPlayerView.kt` does two things: (1) returns no decoder for `audio/flac` so FLAC falls through to the bundled FFmpeg renderer — the platform MediaCodec FLAC decoder on some devices (incl. this OnePlus) allocates fixed 32 KiB input buffers and large FLAC frames (24-bit multichannel ~54 KiB) die with `DecoderInputBuffer$InsufficientCapacityException: Buffer too small`; (2) skips any `c2.dolby.eac3.decoder` for `audio/eac3`/`audio/eac3-joc` — on this OnePlus the codec2 resource manager repeatedly releases that hardware decoder as soon as it starts, so Media3's audio renderer spins in an endless re-init loop and **no AudioTrack is ever created (silent playback)**. With the Dolby component excluded, the AOSP software E-AC3 decoder is used and the renderer is stable. Verified on-device: Sonic FLAC plays continuously; an E-AC3 (Dolby Atmos, 5.1) track plays with an active AudioTrack (48 kHz, channelMask `0x3f`, no churn, no errors).
- **NextRenderersFactory killed hardware video decode — root cause of 4K60 lag + washed-out HDR (2026-08, Redmi Note 10)**: the app originally built the player with nextlib's `NextRenderersFactory` (`io.github.anilbeesetti.nextlib:media3ext`, pulled in for its FFmpeg audio). Its `buildVideoRenderers` calls `super` then inserts `FfmpegVideoRenderer` at **index 0** — *before* `MediaCodecVideoRenderer` — and `FfmpegLibrary.supportsFormat` claims `video/hevc`, so **every HEVC file decoded in FFmpeg software**: 4K60 stuttered (Snapdragon 678 cannot software-decode it) and colors were washed out because the FFmpeg GL output carries no HDR dataspace (SF composite: `dataspace 0x0`, `hdr metadata types=0`). Diagnosed by A/B against moneytoo's Just Player (`com.brouken.player`), which uses the **stock** `DefaultRenderersFactory` (`setExtensionRendererMode(mPrefs.decoderPriority)` + `setMapDV7ToHevc`, zero manual HDR code): same file, same `OMX.qcom.video.decoder.hevc`, its layer composited `BT2020_ITU_PQ hdr metadata types=1`. Fix: new `DreamRenderersFactory` (`android/.../DreamRenderersFactory.kt`) — a `DefaultRenderersFactory` subclass that overrides **only** `buildAudioRenderers` to append nextlib's `FfmpegAudioRenderer` **at the end** (audio fallback for DTS/TrueHD/FLAC; stock reflection for `androidx.media3.decoder.ffmpeg.*` finds nothing in the APK, so no video extensions load). Video stays on stock `MediaCodecVideoRenderer`. Verified on Redmi: Sony 4K60 → `[OMX.qcom.video.decoder.hevc] setting surface generation` (hardware session), SF layer `dataspace=BT2020_ITU_PQ hdr metadata types=1` — byte-for-byte the Just Player profile. Note: on API 26–32 the `TIRAMISU` gate keeps `applyHdrHeadroom` off, so SF auto-tone-maps HDR→SDR (correct for a 500-nit HDR10 panel).
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
- **User-added folder library** (`lib/services/library_folders.dart`, `lib/widgets/folder_card.dart`, `lib/screens/folder_screen.dart`): the home "Your library" section lists **only folders the user explicitly adds** (home **+** → "Add folder to library") — nothing is auto-scanned. Adding a TV-show folder kicks off a TMDB lookup (`TmdService.resolveFolder`, TV-biased via `TmdApi.bestForQuery`); the card shows the show's poster + real title + TV/Movie badge. SMB/WebDAV/FTP/DLNA folders can also be **bookmarked straight from their browser** AppBar (`LibraryFolderSource.smb|webdav|ftp|upnp` + per-source badge; see "Library (user-added folders)" roadmap section). Tapping a folder opens its contents (subfolders navigable; episodes listed with parsed `SxxExx` + size; local/Jellyfin route via `TmdDetailsScreen`, network sources open `FolderScreen` directly), and tapping an episode goes to `TmdDetailsScreen` → player. Long-press a folder card to remove it from the library (files untouched).
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

- **In-app SMB / LAN playback: iOS removed (2026-08); Android SMB stays**. The Android in-app SMB server browser (`smb_screen.dart`, `smb_client.dart`, `SMBClient.kt`, `SmbDataSource.kt`, channel `dreamplayer/smb`, jcifs-ng) remains — NAS playback on Android uses the in-app SMB browser, CX Explorer "Open with", WebDAV, and Jellyfin. The iPad flash SMB browser + playback (`SMBClient.swift`, the `smb_screen.dart`/`smb_client.dart` Dart layer, and every `AvPlayerView` SMB path) was deleted — it was **slow** and **didn't play every video**, and audio-track switching could crash the app. **iOS "Network shares" now routes through the Files app (2026-08)**: the home **+** → "Network shares" tile on iOS opens the system folder picker (`pickLibraryFolder` — the document picker lists Files-app "Connect to Server" shares), and the picked share is bookmarked as a **library folder** so it appears on the home grid with a TMDB poster and is browsable/playable through the existing security-scoped bookmark infrastructure. Android's "Network shares" still opens the in-app `SmbScreen`. `BufferedSMBReader.swift` STAYS (WebDAV playback still wraps it for read-ahead) and the `AetherEngineSMB` SPM product STAYS (WebDAV's `ByteRangeSource`/`WebDAVByteRangeSource` live in that module; SMBClient stays bundled transitively via AetherEngineSMB for WebDAV). SMB learnings are preserved in the roadmap section below for future development. **Lesson learned on-device**: jcifs-ng's streaming read size is bound by three interlocking properties (`snd_buf_size`/`rcv_buf_size`/`transaction_buf_size`, defaults 65535); raising only the first two did nothing (still ~64 KB reads / ~5 MB/s with constant ring-buffer stalls), and raising `transaction_buf_size` to 8 MiB made the NAS reject reads with `STATUS_INVALID_PARAMETER` ("The parameter is incorrect"); 1 MiB was still rejected. Do not raise buffers past what the NAS's negotiated `MaxReadSize` accepts. **Wrong-credentials error (2026-08)**: browsing a saved server with a bad username/password used to silently return an empty share list — `listShares` probed `COMMON_SHARES` and its `catch (_: Exception)` swallowed `SmbAuthException` (treated as "no such share"). Fix in `SMBClient.kt`: `listShares` catches `SmbAuthException` separately and, if auth fails on every probed share with nothing found, throws `Login failed — check username/password/domain`; both `listShares` and `listDirectory` channel handlers map `SmbAuthException` to a `smb_auth` error with that friendly message (the Dart screen already renders `e.message` on `PlatformException`). The `testConnection` dialog already reported auth failures; only the browse path was silent. **SMB trailing-slash / double-slash path gotcha (2026-09)**: the native SMB client returns directory entries with **trailing slashes** in their `path` field (e.g. `Video/`, `Video/Kakegurui Twin(2021)/`). When navigating into a directory, the full path accumulates double slashes (`Video//Kakegurui Twin(2021)/`). `_goUp` used `lastIndexOf('/')` which found the **trailing slash** first, stripping it to `Video//Kakegurui Twin(2021)` — the **same folder** — so pressing back just reloaded the current folder instead of navigating to the parent. Fix: `_loadDirectory`, `_openEntry`, and `_goUp` all normalize paths by collapsing `//` → `/` and stripping trailing `/` before computing the parent. **SMB poster not updating after fix-match**: the `_SmbTile` widget read poster metadata from a **local `_tmdbMeta` map** which held stale `TmdMeta` references after fix-match updated the `TmdService` cache. Additionally, the SMB screen had **no `TmdService` listener**, so fix-match cache updates never triggered a rebuild. Fix: added `TmdService.instance.addListener(_onMetadataChanged)` in `initState`/`dispose`, and the tile now reads directly from `TmdService.instance.metaFor(key)` on every rebuild instead of the local map.
- **WebDAV browsing + playback (Android + iOS)** (`lib/screens/webdav_screen.dart`, `lib/services/webdav_client.dart`, `android/.../WebDAVClient.kt`, `ios/Runner/WebDAVClient.swift`, channel `dreamplayer/webdav`): CX-Explorer-style server list → folders → videos → play. Add/edit/delete servers with an inline connection test; browsing streams video straight to the existing ExoPlayer/Media3 pipeline (Android) or AetherEngine (iOS). Reached from the home **+** button → "WebDAV".
  - **Per-server self-signed HTTPS** (`ExoPlayerView.kt`): the default OkHttp `HttpDataSource.Factory` is replaced with a custom one holding TWO OkHttp clients — a standard client and a permissive one (trust-all `X509TrustManager`/`SSLContext`). A `setPermissive(bool)` flag per open picks the client; `allowSelfSigned` is an **opt-in toggle, default off**, set end-to-end from the save dialog → `WebDavServer` model → `VideoItem` → `ExoPlayerController.open` → native `open`. Only the flagged server gets the permissive client — never globally.
  - **Credentials never cross to Dart**: the password lives only in native prefs; Dart sees a `hasPassword` boolean. The `Authorization` header is built natively on demand (`WebDAVClient.authorizationHeader`, `Basic` base64). No `Log`/`println`/`debugPrint` of URLs, headers, or passwords anywhere.
  - **Encrypted storage** (`androidx.security:security-crypto:1.1.0-alpha06`): passwords in `EncryptedSharedPreferences` (`dreamplayer.webdavSecrets`, AES-256-GCM with Keystore master key), server metadata in `dreamplayer.webdavServers`; one-time migration from the old plaintext prefs then delete. Both pref files are excluded from Android backup via `res/xml/backup_rules.xml` + `data_extraction_rules.xml` (wired in the manifest) — important for a public release.
  - **Friendly errors** (`WebDAVClient.friendlyError`): maps `SSLException`/`UnknownHostException`/`ConnectException`/`SocketTimeoutException` to plain-language messages ("Certificate not trusted — enable 'Allow self-signed'", "Server not found", "Can't connect", "Timed out"), shown inline in the dialog pinned below the fields (outside the scroll view).
  - **URL handling**: `testConnection`/`listDirectory` always probe slash-terminated URLs so the redirect-mangled root (`/dav` vs `/dav/`) doesn't 404; HTTP sends an in-dialog plaintext warning when credentials are set. **Filename decoding gotcha (2026-08)**: hrefs are decoded with `android.net.Uri.decode` (NOT `URLDecoder.decode`, which turns a literal `+` into a space and would mangle names like `224kbps + English` into a 404); Dart `_encodePath` re-encodes each path segment (`+`→`%2B`, `[`/`]`→`%5B`/`%5D`) for playback URLs, and the continue-watching rebuild re-encodes the same way.
  - **Dialog UX** (`webdav_screen.dart`): protocol radio (HTTP/HTTPS, port defaults 8080/8443 filled only when the field is empty or holds a stale toggle default — a typed port is never overwritten), Host/Port/Path/Name/Username/Password fields all use placeholders (`192.168.1.16`, `8080`, `/dav`, `admin`, ...), HTTPS-only "Allow self-signed" switch, port 1–65535 validation, result/error text foreground color.
  - **iOS/iPad** (`ios/Runner/WebDAVClient.swift`, registered in `AppDelegate`): same `dreamplayer/webdav` contract as the Android client, with **Keychain** passwords (`com.dreamplayer.app.webdav`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; server metadata in UserDefaults) and a two-session `URLSession` setup — standard trust + `PermissiveTrustDelegate` (opt-in per server, mirroring Android's `setPermissive`). Browsing is `PROPFIND` (`Depth: 1`) parsed by a `MultistatusParser`; `testConnection` probes slash-terminated URLs and falls back to a GET probe on 404, and `friendlyError` maps SSL/DNS/connect/timeout `URLError`s to the same plain-language messages. **XML namespace gotcha (2026-08)**: Apache/nginx/Nextcloud/Synology all emit prefixed multistatus XML (`<D:response xmlns:D="DAV:">`); with `shouldProcessNamespaces` left at its default `false`, Foundation's `XMLParser` reports `elementName` as `"D:response"` (prefix included) so the local-name matches in `MultistatusParser` never fire and the folder list silently comes back empty ("Nothing here", no error). `parseMultistatus` must set `parser.shouldProcessNamespaces = true` before `parse()` (and now surfaces `parser.parse()` failures as a real error instead of a silent `[]`). Android is unaffected (XmlPullParser reports local names).
  - **iOS playback**: AetherEngine's own HTTP stack can't carry auth headers nor bypass TLS validation, so `AvPlayerView.open` routes any http/https URI that has `headers` or `allowSelfSigned` to `WebDAVClient.makeByteRangeSource` — a `WebDAVByteRangeSource` (`ByteRangeSource`, so it lives in the `AetherEngineSMB` module) that serves every engine read as an independent HTTP `Range` request with the `Authorization` header, on the permissive or default-trust session. It's wrapped in the same `BufferedSMBReader` read-ahead used for SMB (32 MiB window, background prefetch) so the loopback producer never starves on per-read round-trips; the source is stateless per read, so the engine's internal reload on audio-track switch is safe (no SMB-style reopen needed). The blocking size probe (Range: bytes=0-0, at open) is dispatched on a `Task.detached` so the main thread never blocks — `source` is built inside the async load task and `lastSource` is set there so replay/scrub-after-end works.
  - **Local test servers** (user's PC, `192.168.1.16`): Docker `webdav` (bytemark/webdav, HTTP `:8080`, `LOCATION=/dav`, user/pass `dream`/`dream`) + `webdav-nginx` (nginx, HTTPS `:8443`, self-signed certs + proxy config in `/tmp/opencode/webdav-ssl`, `proxy_pass http://172.17.0.2:80` — the webdav container's bridge IP; the host-gateway path `172.17.0.1:8080` is NOT reachable from inside containers on this host). App-normalized URLs make the HTTPS root work as `https://192.168.1.16:8443/dav` (no trailing slash needed).
- **FTP / SFTP browsing + playback (iOS/iPad)** (`ios/Runner/FtpClient.swift`, channel `dreamplayer/ftp`, reached from home **+** → "FTP/SFTP"): server list with inline connection test → folders → videos → play. SFTP via **Citadel** (SwiftNIO SSH; requires iOS 17); plain FTP is a hand-rolled client (`FtpControlConnection`) speaking USER/PASS/TYPE/PASV/REST/RETR/LIST over a raw TCP transport. Playback routes through `FtpByteRangeSource` (`ByteRangeSource`, like `WebDAVByteRangeSource`) wrapped in the same `BufferedSMBReader` read-ahead; `makeByteRangeSource` does login + TYPE I + SIZE then returns the ring-buffered source. Passwords stay in Keychain (never to Dart). Verified end-to-end on iPad (2026-08): both test files play, browse/test/login all green.
  - **Gotcha — NWConnection silently hangs (2026-08, the big one)**: the original `TcpConnection` used Network.framework's `NWConnection`; on this iPad it **never dialed local IPs** — `testConnection` hung forever with no `.waiting`/`.failed` state and zero packets reaching the server (proven by pure-ftpd `-d` verbose logs showing no connection while Citadel/NIO's BSD sockets connected instantly). Fix: rewrote `TcpConnection` on **POSIX BSD sockets** — non-blocking `connect` + `poll` (10 s budget so nothing hangs again), a dedicated reader thread doing blocking `recv()` marshalling onto a serial queue, `shutdown(fd, SHUT_RDWR)` before `close()` to wake blocked recvs. Rule of thumb: if NWConnection misbehaves on LAN, drop to sockets — same mechanism the working libraries already use.
  - **Gotcha — MethodChannel reply deadlock (2026-08)**: `handle` originally replied via `Task.detached { result(...) }` — off the main thread, which **deadlocks FlutterMethodChannel** (replies must arrive on the platform main thread). Fix: `Task { await MainActor.run { result(...) } }` (+ `NSNumber(value:)` for Int ports). Symptom was "test spins forever, no error".
  - **Gotcha — OpenSSH sftp-server caps one read at 256 KiB (`MAX_READ_SIZE`, 0x40000)**: `BufferedSMBReader` requests 4 MiB chunks; an oversized SFTP read gets truncated/rejected, tripping the ring's contiguous-frontier logic → engine probe gets no data → `customSourceProbeFailed`. `FtpByteRangeSource.read` loops SFTP reads in **256 KiB slices** until the full length or EOF. This matches VLC's empirically-optimal libssh2 read size; raising the slice gains nothing on OpenSSH (server clamps anyway).
  - **Gotcha — SIZE reply parsing**: `reply()` returns the whole status line ("213 30042485"); parsing it as `Int64` fails → "Server did not report file size". Strip the leading 3-char code before parsing.
  - **Gotcha — ONE transfer per FTP control connection**: FTP has no multiplexing — a concurrent `PASV`/`REST`/`RETR` pair on one control socket crosses replies and corrupts the session. Observed on-device: background chunk fill (offset 4 MiB) raced the engine's moov-atom seek to the file tail (`BufferedSMBReader`'s prefetch is single-threaded per source, but a seek-miss issues a direct fetch in parallel); the second REST overwrote the first, the tail transfer won, probe died. Fix: `AsyncSemaphore(value:1)` gate around all plain-FTP retrieves (SFTP needs none — Citadel reads are stateless). Server log signature of the bug: two back-to-back `rest` commands between one `pasv` pair.
  - **Local Network permission (2026-08)**: iOS has no API to request it on demand — the dialog fires once, on first local-network access. `AppDelegate.triggerLocalNetworkPrompt` starts a throwaway `NWBrowser` Bonjour probe (`_dreamplayer-probe._tcp.`) in `applicationDidBecomeActive` so fresh installs see the prompt **at app open** instead of mid-flow. On already-granted devices nothing pops (expected).
  - **Debugging without a Mac**: `FtpClient.logStatic` appends to `Documents/ftp_debug.log` (exposed via `UIFileSharingEnabled` — Files → On My iPad → DreamPlayer); probe/connectAndLogin/read failures all trace there. Server-side truth: recreate ftpd with `-d` flag (`docker run … stilliard/pure-ftpd /bin/sh -c '/run.sh -l puredb:/etc/pure-ftpd/pureftpd.pdb -E -j -R -d -P $PUBLICHOST'`) so every command lands in `docker logs ftpd`. Local test server: `ftpd` container on host network (:21, pasv 30000-30009 open in UFW, dream/dream, samples under `/home/dream` = `/tmp/opencode/ftpdata`).
- **Jellyfin / Emby browsing + playback (Android + iOS)** (`lib/screens/jellyfin_screen.dart`, `lib/services/jellyfin_client.dart`, pure Dart — no native code): home **+** menu → "Jellyfin" → saved servers + **mDNS auto-discovery** → sign in → libraries → folders → play. Direct-play streams the Jellyfin URL with the token as an `api_key` query param, so playback reuses the existing HTTP data sources with **zero native changes** (Android: `DefaultHttpDataSource`; iOS: AetherEngine's loopback producer; self-signed HTTPS honors the same opt-in permissive path as WebDAV via `allowSelfSigned`).
  - **API surface**: `GET /System/Info/Public` (test connection, no auth), `POST /Users/AuthenticateByName` (`X-Emby-Authorization` header), `GET /Users/{userId}/Views` (libraries), `GET /Users/{userId}/Items?ParentId=…&Fields=MediaSources,Width,Height` (folder contents), direct-play `{url}/Videos/{id}/stream?static=true&mediaSourceId=…&api_key=…` (`/Audio/` for audio items). Uses `dart:io` `HttpClient` with `badCertificateCallback` for self-signed TLS (no `http` package dep).
  - **Persistence**: `JellyfinServer` list in shared_preferences `dreamplayer.jellyfinServers` (server name/url/username/token/userId/allowSelfSigned). Token is a session credential but **not a password** — stored in plain prefs for now (same tier as the resume store); passwords never reach Dart or disk.
  - **mDNS**: `multicast_dns` scanning `_jellyfin._tcp` + `_emby._tcp` (PTR → SRV → A), probing each hit's `/System/Info/Public` for the real name/version (multi-interface `lookup` timeouts; multicast can be flaky on Android Wi-Fi — the **Add server** flow is the reliable fallback and discovery stays best-effort). Permissions: `CHANGE_WIFI_MULTICAST_STATE` (Android manifest), `_jellyfin._tcp`/`_emby._tcp` in `NSBonjourServices` (iOS Info.plist). **Jellyfin 7359 probe is the primary scan (2026-08)**: modern Jellyfin **removed its mDNS/Bonjour responder entirely** (verified against 10.11.11 — the only discovery left is `AutoDiscoveryHost`, a proprietary UDP-7359 broadcast protocol: send `"who is JellyfinServer?"`, server answers unicast JSON `{"Address","Id","Name"}`). `discoverServers()` therefore runs BOTH: (1) the native 7359 broadcast probe — `MulticastLockManager.kt` on Android, `JellyfinDiscovery.swift` on iOS (channel `dreamplayer/multicast`, method `discoverJellyfin`) — and (2) the mDNS scan for legacy Emby servers. **Gotcha (2026-08)**: the Android MethodChannel handler runs on the platform MAIN thread, so the blocking socket probe must run on a `Thread` (result posted back via `Handler(Looper.getMainLooper())`) or every send dies with `NetworkOnMainThreadException` and the scan returns nothing — the app also declares `ACCESS_WIFI_STATE` so `wifiBroadcastAddress()` computes the /24 subnet broadcast target. **Android multicast lock (2026-08)**: pure-Dart `multicast_dns` cannot hold the Wi-Fi `MulticastLock`, so the driver drops multicast frames and scans find nothing. `discoverServers()` acquires/releases the lock via the same native manager (`acquire`/`release`) around the whole scan — on non-Android the channel is absent and the helper no-ops. **Server-side gotcha**: a Linux Jellyfin host behind UFW must allow UDP 7359 (`sudo ufw allow 7359/udp`) or broadcasts are silently dropped before the server sees them (avahi is NOT involved — it was a red herring during debugging; do not stop it for Jellyfin).
  - **Browse**: folders first, then playables, alphabetical; breadcrumb back + server-list button. Tapping a playable opens its TMDB details screen and plays it. 401 during browse → token dropped → sign-in prompt re-authenticates.
  - **Continue watching**: stable resume key `jellyfin:<host>/<itemId>`; `home_screen._restoreJellyfinSource` rebuilds the stream URL from the current saved server + token so session rotation can't break card taps. Cards show a purple **Jellyfin** source badge.
  - **Jellyfin folders in the home library (2026-08)**: the folder tiles in the Jellyfin browser carry an **Add to library** button (`library_add_outlined`, row tap still navigates) that persists a `LibraryFolder` with `source: jellyfin` + the server URL + item id — the token is never stored, the entry is re-matched against the saved servers (`JellyfinClient.serverForUrl`) each time it's opened, so it keeps working across logins. The home "Your library" grid shows these as regular folder cards with a teal **Jellyfin** badge (`folder_card.dart`), and tapping one opens `TmdDetailsScreen(folder:)` in **Jellyfin mode**: `getItems` lists the children via the API (folders then playables, alphabetical), playables show their `IndexNumber`/`ParentIndexNumber` (`Fields=…IndexNumber,ParentIndexNumber`) as `SxxExx` + TMDB episode names when the season data is cached, tapping one carries the show's meta and plays the direct-play URL (`JellyfinClient.videoItem`); subfolders deep-link into `FolderScreen`, which also gained a Jellyfin branch (crumb stack of item ids + names instead of `listDirectory` paths). Removing the folder from the library skips the native `removeLibraryBookmark` (no SAF grant for a Jellyfin folder). `LibraryFolder.fromJson` defaults a missing `source` to `files`, so legacy entries are untouched. **Auto-fetched series info (2026-08)**: bookmarking also fetches the item's own metadata from the server — `JellyfinClient.getItemInfo` builds a `JellyfinItemInfo` (name, year, genres, rating, overview + full poster/backdrop URLs with the token as `api_key` — deliberately NOT folded into `TmdMovie`, whose `posterUrl()` always prefixes `image.tmdb.org`). **Series-poster resolution (2026-08)**: a bookmarked folder is often a plain `Folder`/`Season` with no poster of its own, and Jellyfin answers `/Items/{id}/Images/Primary` for such an item with a **random child image** (a random still from the series) — so `_addToLibrary`, `home_screen._refreshJellyfinMeta` and `TmdDetailsScreen._refreshJellyfinInfo` all call `JellyfinClient.getPrimaryPosterInfo` instead, which keeps the item itself only when it is a `Series`/`Movie` and otherwise walks `getItemAncestors` (`GET /Items/{id}/Ancestors`, a JSON array, hence the `_getJsonRaw` variant of `_getJson`) to the nearest `Series` ancestor and uses that item's Primary poster. Pure decision logic lives in `JellyfinClient.resolvePosterItemId` (unit-tested). and caches it under `dreamplayer.jellyfinFolderMeta` (`saveFolderMeta`/`removeFolderMeta`/`loadAllFolderMeta`). The home card shows the Jellyfin poster + TV/Movie badge as a fallback when no TMDB match exists (`FolderCard.jellyfinInfo`); `TmdDetailsScreen` gained a `jellyfinInfo` param + `_refreshJellyfinInfo` (refreshed on open so the token-embedded artwork stays current, since re-login rotates the token) and `_buildFolderWithoutMatch` renders a full backdrop/poster/rating/genres/overview header for Jellyfin folders. `home_screen._refreshJellyfinMeta` fills cache gaps for folders bookmarked by older builds; `_removeFolder` drops the cached info. Image URLs embed the session token, so they can go stale after re-login — the details-screen refresh covers that (cards fall back to the placeholder on a broken image).
- **TMDB details screen for every source (2026-08, Nova-style redesign 2026-08)**: tapping a video now opens `TmdDetailsScreen` (metadata page with Resume/Play) instead of jumping straight to the player — from continue-watching cards, and from the WebDAV, Jellyfin, and file browsers. **Library folder taps route to the details screen too (2026-08)**: the home "Your library" grid's `_openFolder` pushes `TmdDetailsScreen(folder: folder)` — the folder's TV metadata (poster, seasons, backdrop) with a Play/Resume button — instead of `FolderScreen`. `_resolveFolderMetadata` now ALSO eagerly calls `TmdService.detailsFor(folder.metadataKey)` right after `resolveFolder` so the details/backdrop are already cached when the folder is tapped (add-time fetch). The details screen's folder mode navigates subfolders via `FolderScreen(folder:…, initialPath: entry.path)` — `FolderScreen` gained an `initialPath` parameter (defaults to `widget.folder.path`) so a subfolder tap deep-links straight into that directory. **Nova-style episode header (2026-08)**: the header shows the show name as title, an `S01E01` badge (colored container), the episode name beside the badge, and the season name below. Removed redundant episode number fact chip. **Nova-style cards (2026-08)**: `_FileInfoCard` (video codec, audio codec, resolution, file size, path), `_SubtitlesCard` ("Search subtitles online" → `OpensubtitlesSheet`), `_TrailersCard` (YouTube trailer links via `url_launcher`). **Manual "Get Info" search (2026-08, Nova-style)**: the no-match state shows a filename + "No metadata loaded" + FilledButton that opens `_SearchDialog` (TV/Movie `SegmentedButton` toggle, year param, kind-first search with fallback). **Trailers support (2026-08)**: `TmdTrailer` class (key, name, site, youtubeUrl) + `TmdDetails.trailers` parsed from `videos.results` in `append_to_response=credits,videos`. Up to 5 YouTube trailers shown. **Removed (2026-08)**: `_HeaderImageGallery` (stills gallery), `_HeaderArtwork`, `_CastTile` (cast section), auto-prefetch from all file browsers, file-tap `resolve()` calls, unused `_connectionErrorShown`, unused `_parentFolderName()`, unused `tmdb_client.dart` import from upnp_screen. **JSON dual-key gotcha (2026-08)**: `TmdSeason`/`TmdEpisode` `fromJson` reads both the TMDB API snake_case keys (`season_number`, `episode_number`, `still_path`, `air_date`, `runtime`, `vote_average`) AND the camelCase keys that `toJson` writes (`seasonNumber`, `episodeNumber`, `stillPath`, `airDate`, `runtimeMinutes`, `voteAverage`) — a single-style `fromJson` silently nulls fields when round-tripping through the prefs cache, breaking the episode-name fallback ("Episode N") and season lookups. **Season-folder title parsing (2026-08)**: whole-season folder names like `HOUSE.S02.1080p.10bit.BluRay.English.AAC.5.1.x265-Panda` used to resolve to `"HOUSE S02 English"` — a TMDB query with **0 results**, so the folder card never got its poster and showed the Jellyfin fallback image instead. `ParsedFileName.parse` now (1) strips a **bare season tag** (`\bS(\d{1,2})\b`, matched only after the `SxxEyy`/`NxM` patterns) and records it as `season`, so `HOUSE.S02...` → title `"HOUSE"`; (2) the noise list gained `english`/`eng` (audio-language tags) and `nf`/`netflix`/`amzn`/`amazon`/`hbo`/`hulu` (streaming-provider tags); (3) `_cleanName` explicitly removes `H.265`/`H265`/`H 265`/`X.264`-style codec tags (the dot/space defeats the `\bh265\b` word-boundary noise rule), so `I.Will.Find.You.S01.2160p.NF.WEB-DL...H.265-...` → `"I Will Find You"`. Both regressions are unit-tested in `test/tmdb_test.dart`. **Details-screen header is landscape-aware (2026-08)**: `TmdDetailsScreen._headerBox` keeps the full-width `width * 9/16` banner in portrait but in landscape shows the artwork as a **centered 16:9 box** capped to `(height * 0.32).clamp(140, 240)` — the 16:9 image renders whole (no `cover`-crop) instead of being zoomed into a thin strip or filling the whole landscape viewport. The gallery fills its parent (`SizedBox.expand`) so the call sites own the box; the rating badge is anchored inside the box. **Play-next removed (2026-08)**: the player and detail screens no longer chain a sibling playlist — each video plays on its own; the call sites stopped passing folder playlists. The action button reads `ResumeStore.positionFor(resumeKey)` (same key chain + same <10 s / near-end thresholds as the player) and labels itself **"Resume from m:ss"** when a playhead is saved; the player still auto-resumes via its own lookup, so no start position is passed. The player screen re-checks the label after the player pops. **Playback is never blocked by metadata (2026-08)**: the Play/Resume button is pinned in the bottom bar and always enabled — a slow or failed TMDB lookup (timeouts, unreachable `api.themoviedb.org`, invalid/rate-limited key) shows the real `TmdException` message in the "no match" card instead of the old generic "check your connection", and the video still plays.
  - **Scoped out (v1)**: subtitle delivery (server-side subs via direct-play need a separate `SubtitleConfiguration`/track flow), per-item thumbnail art in browse lists (folder/series art IS done via `JellyfinItemInfo`), HLS/transcode selection, per-library refresh. Add-on checklist if in-app SMB ever returns (below) does not apply here — Jellyfin playback is plain HTTP.
- Tests: 212 (`flutter test`) incl. no-overflow checks on small phone, tablet, landscape, 2.0x text scale, and the TMDB-details/Jellyfin server-list overflow regression states, a file-browser back-navigation test (back goes up one folder at a time; a folder inside a root lands on that root's contents, not the roots list), an About → "Open-source licenses" navigation test, Jellyfin model/URL unit tests (incl. `JellyfinItem` IndexNumber/ParentIndexNumber → `SxxExx`, `videoItem` building the playable `VideoItem`, and `JellyfinItemInfo` fromApi URL construction + cache round-trip + folder-meta store), TMDB filename-parser / metadata-store round-trip tests (incl. the 2026-08 search-query regressions: bracket/paren audio-metadata stripping, bitrate + release-group/site suffix cutting, and underscore-glued episode tags), `TmdSeason`/`TmdEpisode` JSON round-trip + "Episode N" fallback + cast/stills round-trip + `withEpisode` tests (the dual-key `fromJson` regression), library-folder store unit tests (`test/library_folders_test.dart`, incl. the Jellyfin-source round-trip + legacy `source`-less default), UPnP/DLNA model tests (`UpnpEntry` transcoded/externalSubs, `VideoItem.isTranscoded` round-trip), and `player_error_test.dart` (Media3 `ERROR_CODE_*` → friendly message + retry/decode predicates — 9 new tests for the 2026-08-29 hardware-decoder auto-fallback work).
- **Licensing**: the app is **GPLv3** because the Android build links `nextlib-media3ext` (GPLv3 FFmpeg extension). `LICENSE` (GPLv3 text) + `NOTICE` (third-party components: Media3 Apache-2.0, nextlib GPL-3.0, AetherEngine LGPL-3.0 + Apple Store exception, FFmpegBuild LGPL-2.1+, SMBClient MIT — bundled via AetherEngineSMB for WebDAV, Flutter BSD-3-Clause, pub plugins MIT/BSD). The About section of Settings opens `licenses_screen.dart`, which lists every component and its license.
- **TMDB movie metadata** (`lib/services/tmdb_client.dart`, `lib/screens/tmd_details_screen.dart`, `lib/config/tmdb_api_key.dart`, pure Dart — no native code): continue-watching cards resolve their filename against **The Movie Database** for poster/backdrop art, the real title, year, synopsis, rating, genres, runtime, and cast. `TmdApi` keeps **one shared keep-alive `HttpClient`** for the app lifetime (a fresh client per request re-armed DNS+TLS each call → slow + intermittent `SocketException` on flaky links) with 15 s connect / 30 s response timeouts and **one retry** for transient failures (`SocketException`, `TimeoutException`, HTTP 429 rate-limit burst) before surfacing the `TmdException`. The scene-name parser (`ParsedFileName`) strips quality/codec/audio-channel noise (`1080p`, `WEB-DL`, `DDP5.1`, release groups after a dash like `-GROUP`, season/episode tags `S01E03`) while keeping title words like "Part" (`Dune.Part.Two`). **Search-query parser cleanup (2026-08)**: bracketed/parenthesized audio metadata is dropped from the query (`[Hindi AMZN DDP 2.0 224kbps + English DTS-HD MA 5.1]`, `(Hindi DDP 5.1 Korean DTS 5.1)`) unless the group carries an episode tag (`[S02E04]`) or the year (`(2013)`), both of which must survive for detection; bitrate tokens (`224kbps`, `640kbps`) are removed; `<group>-<site>` release suffixes (`USURY-4kHdHub.com`) are cut including the bare group; and underscore/bracket-glued tags (`Stranger_Things_[S02E04]_1080p`) are normalized to spaces so the word-boundary noise rules fire. Verified on-device against real NAS filenames: `Silence`, `Identity`, `Oldboy`, `Her (2013)`, `24`, `Main Vaapas Aaunga` all auto-match at score 1.00 (the old parser searched for garbage like "Silence MA"). Resolution order for the API key: the `--dart-define=TMDB_API_KEY` build-time value (seeded into prefs on first launch so later plain `flutter run`s keep working) → empty. **No key is ever committed**: the repo default is the empty env define; the user's key lives in gitignored `.env` (see `.env.example`) and is baked in via `--dart-define-from-file=.env`. (The Settings → Metadata API-key entry was removed — the key is build-time only.) **UI flow**: tapping a continue-watching card now opens `TmdDetailsScreen` (backdrop header, poster, star rating, runtime + genre chips, overview, cast row, big Play button) instead of the player directly; "Fix match" opens a TMDB search dialog to re-pin the entry (persisted via `TmdStore.setManual`) and "Remove info" clears a wrong auto-fetched match (`TmdService.clear` → cache + prefs dropped, home cards fall back to placeholder). Metadata is cached in shared_preferences (`dreamplayer.tmdbMeta`, keyed by `TmdStore.identityKeyFor` = resumeKey ?? path ?? uri); `home_screen` pre-resolves cards on load and the player shows the movie backdrop behind its loading/error layer. Cards without a match keep the gradient placeholder. Search/details run over `dart:io` HttpClient; no new native code.
- **Per-file TMDB posters in every file list (2026-08)**: the library-folder screens (`folder_screen.dart` — folder root + subfolders, and `tmd_details_screen.dart` folder mode) plus the **WebDAV** (`webdav_screen.dart`) and **Jellyfin** (`jellyfin_screen.dart`) browsers now **auto-fetch** TMDB metadata for each movie/episode as the list loads (`_prefetchMeta`/`_prefetchJellyfinMeta`/`_prefetchTmdbMeta`) and render the file's **poster thumbnail** (`_Poster`, 48×72 rounded; `posterUrlOf()` lives in `tmdb_client.dart` so all row tiles share it) instead of the plain play icon. Each row resolves under the **same stable key its tap uses** (`TmdStore.identityKeyFor` = `resumeKey ?? path ?? uri`; WebDAV `webdav_<serverId><path>`; Jellyfin `_client.resumeKey` = `jellyfin:<host>/<itemId>`), so the prefetched match is a direct cache hit and the details screen opens already resolved. Every screen listens to `TmdService.instance` (rebuild on change), so a manual **"Fix match"/"Search TMDB"** pick from the opened file's details screen persists the poster and the row shows it immediately on return. Prefetch is fire-and-forget (`resolve(...).catchError((_) => null)`) — a TMDB failure just leaves the play icon. **Folder-meta inheritance fix (2026-08)**: `_openFolderEntry`/`_openJellyfinItem` previously called `carryMeta` for **every** file in a folder, stamping the folder's match onto standalone movie keys (a "Movies" folder's meta shown for each movie in it). `carryMeta` now runs only when the tapped file is an **episode** (`ParsedFileName.parse(...).isEpisode`, or Jellyfin `type == 'Episode'`) **and** the folder's meta is `TmdKind.tv`; for non-episode files any folder meta an older build stamped onto the key is cleared (`existing.movie.id == meta.movie.id` → `clear`) so the movie resolves its own title.
- **Per-episode details** (`lib/services/tmdb_client.dart`, `lib/screens/tmd_details_screen.dart`): the single-episode details page shows **that episode's** name, overview, air date, runtime, rating, guest cast, and still frames instead of only the show's metadata. The season endpoint (`/tv/{id}/season/{n}`) supplies the name/overview/still; `TmdApi.episodeDetails` additionally hits the **per-episode endpoint** (`/tv/{id}/season/{n}/episode/{m}` with `append_to_response=credits,images`) for the guest cast + full still gallery. `TmdService.episodeDetailsFor` enriches the cached `TmdEpisode` in place (via `TmdSeason.withEpisode`) and runs only for the single-episode view (video mode), never for whole folder lists — so a folder with 100 files triggers no per-episode requests. `TmdEpisode` gained `cast`/`stills` fields with **dual-key JSON** (API `credits.cast`/`images.stills` vs cached `cast`/`stills`), so the prefs cache round-trips. UI: the header uses the episode still when season data is loaded, and an "Episode cast" row + horizontal **Stills** gallery sit between the episode overview and the show's cast. All best-effort: on API failure the episode silently keeps its season-level data.
- **Donations**: Settings → **Support** lists two donation channels (Razorpay, GitHub Sponsors) via `lib/services/support_links.dart` (`url_launcher`). **Razorpay is set** (`https://rzp.io/rzp/cZ5afqVG`, a live payment link → `plink_TOrUqMDPRxYQFp`) and **GitHub Sponsors is set** (`https://github.com/sponsors/mangeshghodke/`). README has matching badges + a Support section.
- **Settings footer (2026-08)**: Settings → bottom shows "Made with ❤️ by Mangesh Ghodke".

## Roadmap

### SMB / network shares (Android + iPad)

Play files from LAN/NAS SMB shares in-app, mirroring the existing file-browser pattern.

**Status: iOS removed (2026-08); Android SMB stays.** The Android in-app SMB browser (`smb_screen.dart`, `smb_client.dart`, `SMBClient.kt`, `SmbDataSource.kt`, channel `dreamplayer/smb`, jcifs-ng) is implemented and running on-device. The iPad in-app SMB browser (AMSMB2 + AetherEngineSMB) shipped but was retired (2026-08): slow, didn't play every video, audio-track-switch crash. iOS `SMBClient.swift` and Dart layers were DELETED; Android `smb_screen.dart`/`smb_client.dart` remain. The "Network shares" home entry shows **only on Android** — on iOS the tile routes through the Files-app folder picker (`pickLibraryFolder`), so NAS shares connected via Files "Connect to Server" land as library folders on the home grid. WebDAV/Jellyfin/Files-app "Open with" + bookmarked folders cover iOS NAS workflows. The complete SMB knowledge below is the blueprint if iOS SMB ever returns.

**Architecture**
- New native module per platform exposing a MethodChannel (same shape as `FileBrowser.kt` / `dreamplayer/files`):
  - Android: `SMBClient.kt` — channel `dreamplayer/smb`
  - iOS/iPad: **removed** (was `SMBClient.swift` — same channel)
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

### Player feature backlog (prioritized 2026-08-21)

1. ~~Jellyfin transcoding fallback~~ — DONE (2026-08-22): direct-play errors retry once via server-side HLS `master.m3u8` (H.264/AAC, 20 Mbps cap); Media3 HLS module added; job stopped on player close.
2. ~~Subtitle appearance settings~~ — DONE (2026-08-22); Android delay offset still open (cue-pipeline refactor). Entry moved into the player ⋮ sheet (2026-08-25) — no longer reachable from app Settings.
3. ~~Horizontal-swipe seek~~ — DONE (2026-08-22, time-only pill; frame thumbnails impossible for DV/HDR via MMR).
4. Android release signing (deferred — see CI/Deployment).
5. ~~Spatial audio chip (Android)~~ — DONE (2026-08-25, `76f68e3`): teal **"Spatial"** chip in the player top bar when the platform Spatializer is actually engaged — `spatialStatus()` in `ExoPlayerView.kt` returns on/available/unavailable from `AudioManager.spatializer` (`isAvailable` + `isEnabled` + multichannel track, API 33-gated; minSdk stays 21). `canBeSpatialized(attrs, format)` with a mapped channel mask confirms engagement; `OnSpatializerStateChangedListener` re-emits when routing/toggle changes mid-playback (registered once per open, removed on dispose). Dart: `ExoPlayerEvent.spatialAudio` → chip gated on `Platform.isAndroid && _liveSpatial == 'on'`. **API gotcha**: `getSpatializerType()`/`SPATIALIZER_TYPE_*` are hidden SystemApi despite floating docs — verify against the SDK jar (`javap android/media/Spatializer.class`); listener callbacks take `(Spatializer, boolean)`. iOS native AVPlayer path gets Apple Spatial Audio free for Atmos; FFmpeg custom-source path would need `AVAudioEngine` + `AVAudioEnvironmentNode` (deferred). Fire TV passthrough already delivers real Atmos to the AVR. **Rejected**: custom HRTF rendering (Resonance Audio etc.) — reimplements what both OSes do natively.
6. **"Play with external app" (2026-08-28, user feedback, NOT YET IMPLEMENTED — implementation deferred until the user wants it shipped)**: a user replied to a release post with *"the app is good for organizing files, but does not play because it uses Media 3. It's better to include a powerful player like MPV and also the option to allow the use of an external player"*. The user has already replied to that feedback themselves. When this is implemented, it should be an **Android-only `Intent.ACTION_VIEW` chooser** added as a row in the player ⋮ sheet — fires `Intent.createChooser(intent, "Play with…")` with the current video's URI (`file://` for local paths, `content://` for SAF/CX-Explorer hand-offs, `http(s)://` for Jellyfin/WebDAV/URL playback) and a `video/*` MIME. The OS shows a chooser of every installed player that registers for video (MX Player, VLC, Nova, Just Player, Kodi, Plex, …). No engine work, no media3 changes. **iOS is intentionally out of scope**: iOS sandboxing prevents one app from launching another's video player — `UIActivityViewController` can hand a file off to Files/AirDrop/save, but it cannot launch MX Player or VLC, so there is no equivalent feature. Document the limitation in any user-facing reply. The "MPV" half of the feedback is **out of scope** (see "Player engine choice" below).

~~Rejected by user (2026-08-22)~~ — **implemented 2026-08-26 at the user's request**; see "Picture-in-Picture" in Implemented features.

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

**The "external player" half of the feedback IS implementable cheaply.** See item 6 in the Player feature backlog above. When we want to ship it: an Android `Intent.ACTION_VIEW` chooser in the player ⋮ sheet, iOS is out of scope (sandbox limitation).

### iOS monetization — Apple Developer + IAP paywall (planned, 2026-08-25)

User is buying the $99/yr Apple Developer Program; DreamPlayer gets a paid
tier once it's active. Research summary so implementation starts cold:

**Model decision**: single **non-consumable lifetime unlock**
(`com.dreamplayer.app.advanced`) — OutPlayer-style freemium ("Advanced"),
no subscription for v1. Optionally a yearly sub later; never double-gate the
same feature.

**Policy constraints (App Store Review)**:
- Guideline 3.1.1: in-app feature unlocks MUST use Apple IAP — no external
  (Razorpay/UPI) links that gate functionality. Existing Support donations
  are fine as long as they unlock nothing.
- Revenue: 30% cut, **85% under the Small Business Program** (apply in ASC
  immediately; free if revenue < $1M).
- Mandatory: Paid Apps Agreement + bank/tax forms before products can be
  created; **Restore Purchases button** wherever a paywall exists; privacy
  policy URL at submission.
- Prices configured in App Store Connect (localized currencies/taxes handled
  by Apple); receipts validated on-device via StoreKit 2 signed transactions
  (no server needed).

**Implementation sketch**:
- Official `in_app_purchase` Flutter plugin (StoreKit 2 + Play Billing behind
  one API). New `Entitlements` ChangeNotifier service: loads
  `Transaction.currentEntitlements`, caches locally for instant UI, exposes
  `advanced` bool; `buy()` → `buyNonConsumable` + `completePurchase`.
- Paywall sheet widget reads localized price from `Product.products(for:)`.
- Gate NEW premium features only (never strip existing free behavior):
  candidates = Bass Boost/EQ presets, subtitle extras (custom fonts/dual subs),
  themes/accents, future skip-intro/cloud sync.

**Android reality check**: current GitHub-Releases sideloading means Google
Play Billing does NOT work there (needs Play distribution). Options: keep
Android free + donations (recommended v1), publish to Play and mirror IAP,
or self-hosted Razorpay license keys (high effort). Phase: iOS first.

**Testing**: sandbox testers (ASC), `.storekit` configuration file for local/
CI testing without money, TestFlight for production products in sandbox.

**Order of ops when account clears**: agreements/bank/tax -> Small Business
Program -> create product (~₹299/$4.99 tier) -> Entitlements + paywall (1–2
days) -> gate features + Restore button -> sandbox verify -> submit.

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

The home library shows **only folders the user explicitly adds** — nothing is auto-scanned. **Status: implemented (2026-08; on-device verify pending).** Reference-only: videos are never imported or moved; they stay in place and play through the folder's SAF tree (`tree:<id>`), absolute path, or (for Jellyfin folders) the server API.

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

- **iOS builds happen in GitHub Actions** (user has no Mac). Workflow: `.github/workflows/ios.yml`
  - **Manual-only** (`workflow_dispatch` — no push trigger): run it from the Actions tab when a build is wanted; builds unsigned IPA artifact always.
  - Signed build + TestFlight upload run only when secrets are configured.
  - Secrets needed: `IOS_CERT_BASE64`, `IOS_CERT_PASSWORD`, `IOS_PROFILE_BASE64`, `APPSTORE_API_KEY`, `APPSTORE_API_KEY_ID`, `APPSTORE_ISSUER_ID`.
- **GitHub Releases** (`.github/workflows/release.yml`): push a `v*` tag (`git tag v0.3.8 && git push origin v0.3.8`) → builds the **universal** release APK + **split-per-abi** APKs (`arm64-v8a`, `armeabi-v7a`, `x86_64`) on `ubuntu-latest` (+ tests first), and the unsigned iOS IPA (`DreamPlayer-<version>.ipa`) on `macos-latest`; then creates the GitHub Release on the tag with the matching `## <version>` section extracted from CHANGELOG.md + `.github/release_notes.md`, attaching all artifacts. App version is **0.3.8** (`pubspec.yaml` `version: 0.3.8+1`) and must be bumped per release to match the tag. Android APKs are still **debug-signed** (`build.gradle.kts` falls back to debug config) — fine for sideloading; real signing setup was deferred (2026-08-21): generate an upload keystore, gitignored `android/key.properties`, gradle reads it with debug fallback, optional CI secrets later.
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

## Display & smoothness (native refresh rate)

- **Android**: `flutter_displaymode` selects the display's highest refresh rate at app startup (`lib/services/display_refresh_rate.dart`). Many Android devices default apps to 60 Hz even on 90/120/144 Hz panels. Verified: panel runs 120 Hz during animations, 60 Hz when idle.
- **iOS/iPad Pro**: ProMotion 120 Hz is unlocked via `CADisableMinimumFrameDurationOnPhone = true` in `ios/Runner/Info.plist` (already set).
- **Playback cadence**: ExoPlayer renders at the video's FPS onto the platform-view SurfaceView. Revisit frame pacing once smoothness is assessed on-device.
- **DEBUG BUILDS JITTER — always judge smoothness on a RELEASE build (2026-08, Redmi Note 10)**: 4K60 HDR playback in the **debug** APK showed periodic dropped frames while moneytoo's Just Player (release) was buttery smooth — but the ExoPlayer `DecoderCounters` showed `rendered=60fps steady, droppedBuffer=0` and SF `--latency` cadence was clean (0 double/triple frame gaps over 60 s; the only inevitable artefact is the 59.94-on-60 Hz beat, ~1 double frame per 16.7 s, present in both apps). The jitter was Flutter **debug-mode** overhead (JIT VM + hybrid-composition platform-view per-frame cost), not the decode/render path. Installing the **release** APK made it play as smooth as Just Player (user-verified). When the user reports "dropped frames" against a debug install, first re-test with `flutter build apk --release --dart-define-from-file=.env` + `flutter install` before touching the player code. Same rule as the `flutter run --release` comment below.

## Project layout

```
lib/
  main.dart                     # entry point (native refresh rate, runs app)
  app.dart                      # root MaterialApp, dark theme, text-scale clamp, nav shell, double-back-press exit guard (PopScope)
  theme/app_theme.dart          # colors, dark theme (video apps are dark)
  models/
    video_item.dart             # VideoItem + codec label getters
    hdr_format.dart             # HdrFormat enum (SDR/HDR10/HDR10+/DV/HLG)
    library_video.dart          # LibraryVideo model for MediaStore scan results (id, path, title, duration, width, height, sizeBytes, dateAdded, mimeType, resolutionLabel)
  utils/codec_info.dart         # HDR detection + codec -> label mapping + live label merge
  utils/tv_helper.dart          # TV detection (isTvMode, isTvBox), swipe gesture prefs
  services/display_refresh_rate.dart  # high refresh rate selection (Android)
  services/exo_player.dart        # ExoPlayerController + ExoPlayerView platform view (hybrid composition on Android) + PlaybackController interface (brightness/volume) + VideoFitMode/FitModeStore + PlaybackSpeedStore
  services/continue_watching.dart # continue-watching list (shared_preferences JSON)
  services/watched_store.dart     # watched marks (prefs dreamplayer.watched, StringList of resume keys, auto on ended + manual toggle)
  services/jellyfin_client.dart     # Jellyfin/Emby REST + mDNS discovery + JellyfinServer/JellyfinItem/JellyfinItemInfo models + videoItem/serverForUrl/getItemInfo helpers + folder-meta cache + VideoChapter from Item.Chapters
  services/tmdb_client.dart        # TMDB: filename parser (ParsedFileName), TmdApi (search/details/bestForQuery), TmdStore cache, TmdService facade
  services/library_folders.dart    # user-added library folders (LibraryFolder model + LibraryFoldersStore, prefs dreamplayer.libraryFolders; LibraryFolderSource.files|jellyfin|smb|webdav|ftp|upnp)
  services/webdav_client.dart     # WebDAV channel wrapper + WebDavServer model (channel dreamplayer/webdav)
  services/thumbnail_store.dart   # embedded cover-art cache for video cards (memory+disk, local sources only)
  services/mpv_pip.dart           # libmpv fallback engine's picture-in-picture bridge (pipChanged/pipDismissed/pipPlayPause/pipRewind/pipForward; setState pushes state into PipManager)
  config/tmdb_api_key.dart        # default TMDB key from --dart-define=TMDB_API_KEY (never committed)
  screens/
    home_screen.dart            # Continue watching grid (adaptive columns, grouped by TV show) + Your-library folder grid + **+** FAB menu (Jellyfin / WebDAV / Add folder / Internal storage)
    folder_screen.dart          # folder contents / episode list (subfolder navigation, SxxExx labels + sizes)
    player_screen.dart          # ExoPlayer/Media3 playback + live codec/HDR chips + controls + subtitle/audio pickers + gesture controls + libmpv fallback engine (_startMpvFallback / _mpvOpen / _attachMpvExternalSubtitles / _onPipPlayPause / _onPipRewind / _onPipForward)
    player_error.dart           # friendlyPlayerError (Media3 ERROR_CODE_* → user message) + isRetryableIoError / isVideoDecodeError predicates (unit-tested)
    tmd_details_screen.dart     # TMDB details: Nova-style episode header + info/subtitles/trailers cards + cast row + stills gallery + per-episode still thumbnails + Play + Fix match search
    jellyfin_screen.dart        # Jellyfin/Emby server list + 7359-probe/mDNS discovery + login + libraries → folders → play
    webdav_screen.dart          # WebDAV server list → folders → play (add/edit/delete servers, self-signed toggle)
    settings_screen.dart        # settings list + swipe gestures toggle (Player section, phones/tablets only)
  widgets/
    video_card.dart             # library card with HDR/audio badges
    folder_card.dart            # library folder card (TMDB poster or gradient placeholder + TV/Movie badge)
    format_chip.dart            # colored codec/HDR chip
    tv_tile.dart                # shared focus-glow wrapper for TV list items
    tv_overscan.dart            # overscan safe-area padding (36px sides, 20px top/bottom)
    tv_text_field.dart          # TV-friendly TextField with skipTraversal inner node
android/app/src/main/kotlin/com/dreamplayer/app/
  ExoPlayerView.kt              # native PlayerView platform view + channels (open/play/seek/tracks/subtitles) + OkHttp permissive DataSource for self-signed WebDAV
  SubtitleFormats.kt            # extension->MIME map, sibling auto-pairing, charset detection, UTF-8 re-encode
  DreamSubtitleParserFactory.kt # SAMI/MicroDVD/MPL2/SubViewer parsers + default delegate
  FileBrowser.kt                # device storage browsing channel (roots/listing/folder bookmarks; no thumbnails)
  WebDAVClient.kt               # WebDAV browse/test channel; encrypted password storage; friendly errors
  MulticastLockManager.kt       # Wi-Fi MulticastLock + Jellyfin UDP-7359 broadcast probe (channel dreamplayer/multicast)
  PipManager.kt                 # libmpv fallback-engine picture-in-picture (RemoteAction transport buttons: rewind/play-pause/forward); channel dreamplayer/pip
  SmbHttpProxy.kt               # loopback HTTP/1.1 server that exposes an SMB file to libmpv via 127.0.0.1:<port>/<token> with Range support
  MainActivity.kt               # registers platform views + "Open with" intent handling + routes pip/snapshot/stop calls between ExoPlayerView and PipManager based on which engine is active
ios/Runner/
  AvPlayerView.swift            # AetherEngine platform view + channels (same contract as ExoPlayerView.kt); host SubtitleOverlayView; WebDAV http(s) streams with headers/self-signed via WebDAVByteRangeSource
  BufferedSMBReader.swift       # read-ahead sliding-window IOReader (32 MiB) for WebDAV playback
  JellyfinDiscovery.swift       # Jellyfin UDP-7359 broadcast probe (channel dreamplayer/multicast, discoverJellyfin; Android: MulticastLockManager.kt)
  WebDAVClient.swift            # WebDAV browse/test channel (same contract as WebDAVClient.kt); Keychain passwords; WebDAVByteRangeSource for playback
  FtpClient.swift               # FTP/SFTP browse/test/playback channel (POSIX control conn + Citadel SFTP; FtpByteRangeSource + transfer gate)
  FileBrowser.swift             # Documents-folder browsing channel (same contract as FileBrowser.kt); resolveImportedPath
  IntentBridge.swift            # "Open with" intent channel (same contract as MainActivity.kt)
  AppDelegate.swift             # registers the AvPlayerView factory + files/intent/webdav channels
  SceneDelegate.swift           # forwards scene-opened URLs to IntentBridge
test/
  widget_test.dart              # shell/navigation/overflow tests
  codec_info_test.dart          # HDR + codec formatting unit tests
  tmdb_test.dart                # TMDB filename parser + metadata store round-trip + API key fallback tests
  jellyfin_test.dart            # Jellyfin models + stream URL construction
  player_error_test.dart        # friendlyPlayerError (Media3 ERROR_CODE_* mapping) + isRetryableIoError + isVideoDecodeError predicates
  upnp_client_test.dart         # UPnP/DLNA entry + transcoded/externalSubs parsing
  library_folders_test.dart     # library folder store (files vs jellyfin source)
  watched_store_test.dart       # watched marks store
  resume_store_test.dart        # resume position store
  continue_watching_test.dart   # continue-watching list
  subtitle_style_test.dart      # subtitle appearance store
```

## Workflow for the user (no Mac)

- **Standing permission (2026-08-22)**: build and `flutter install --debug -d a019b7f3` directly onto the user's OnePlus CPH2573 for feature verification — no need to ask each time. Test features on-device BEFORE pushing feature commits to GitHub; small compile fixes may follow the tested code.

1. Develop + test on Android phone (USB debugging, `flutter run --dart-define-from-file=.env`).
2. Commit/push to `main`; iOS workflow in GitHub Actions builds the iPad version.
3. Later: configure code-signing secrets + TestFlight for installing on iPad Pro M2.
