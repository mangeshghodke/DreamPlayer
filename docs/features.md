# Features

The full feature list. The README carries a short summary; everything below is the detail.


## Dolby Vision & HDR
- Plays **Dolby Vision** Profiles **P7 / P8 / P9** at 4K 60fps with zero dropped frames — chip shows `DV P8`, `DV P7`, etc.
- **Profile 4** (single-layer IPTPQc2, a broadcast/IPTV profile) plays on **Android** only. iOS has no P4 decoder and no backward-compatible base layer to fall back to, so it reports a clear "not supported" message instead of failing silently.
- Full **HDR10 / HDR10+ / HLG** passthrough to the display panel
- **Hardware SDR tone-mapping (Android, opt-in)** — Settings → Player → *Hardware SDR tone-mapping* asks the decoder to output standard SDR instead of the source's HDR/Dolby-Vision signal, so the phone's own hardware tone-mapper converts on the chip. The system colour modes (Vivid/Natural, white balance) apply to the picture again, and **Dolby Vision Profile 5 stops rendering green/purple**. It costs no CPU and 4K60 stays smooth. The trade-off is deliberate — the picture leaves the HDR path, so the panel no longer receives real Dolby Vision or HDR10 — which is why it is off by default. When the codec confirms the conversion, the chip reads **"Tone-mapped SDR"** instead of claiming Dolby Vision
- Live on-screen chips showing the active HDR format (profile-aware), video codec, audio codec, and resolution
- Graceful fallback on non-DV devices (P7/P8 as HDR10, P4/P5 show a clean error)

## Video Upscaling (iOS)
- Optional **MetalFX real-time upscaling** — Settings → Player → *Video upscaling* upscales **SD / 720p / 1080p SDR** video to the display on **iOS 26+ Apple Silicon** devices (e.g. iPad Pro M2). 4K and HDR/Dolby Vision video always play at native quality (the native path is untouched). An **"Upscaled"** chip in the player shows the source → output size while active. The app still runs on iOS 18+; the toggle only appears on iOS 26+.

## Lossless Audio
- All major codecs: **DTS, DTS-HD, TrueHD, E-AC3, AC3, AAC, FLAC** and more
- Mid-playback **audio track switching** with full track names and channel info
- **Default track on open** — the player picks the file's DEFAULT-flagged audio
  track (not merely the first entry in the list); **resume keeps your last pick**
  per video, per engine (Watch from beginning returns to the default)
- Optional **Media3 audio passthrough** over HDMI for Dolby Atmos / DTS:X on compatible soundbars
- **Spatial audio** (Android 13+) — the same phone Spatial-audio setting drives both Media3 and MPV; the teal chip shows when the system Spatializer can virtualize the current multichannel PCM output on wired, USB, and Bluetooth routes
- **Bass Boost** — Off/Low/Medium/High session-level DSP that restores the low-end HRTF virtualization thins out (appears while Spatial audio is engaged)
- **Volume Boost + Night Mode** — swipe the volume past 100% for up to 2× (200%) of make-up gain, applied to the decoded audio itself with a peak limiter, so it lifts the whole mix instead of crushing the centre channel (Android). Night Mode adds a further +4 dB. A warning appears the moment you cross 100%
- **Downmix to stereo** (Settings → Audio) — folds 5.1/7.1 tracks into 2.0 with the centre channel kept at −3 dB and LFE dropped, so dialogue stays loud on stereo headphones and speakers. Android Media3 via a PCM processor in the audio sink (HDMI bitstream passthrough untouched), MPV via `audio-channels=stereo`, iOS via the stereo audio-session lever. Applies on the next playback; free on both platforms

## Subtitles
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
- **VobSub (`.idx` + `.sub`) bitmap subtitles play on the libmpv engine.** These
  are a two-file pair and are *not* offered on the native Media3 engine: ExoPlayer's
  `VobsubParser` only accepts Matroska `S_VOBSUB` framing, so a sidecar pair has
  nowhere to be fed from. Use **Play with MPV** for these — it renders them
  correctly. No other engine-level player supports them either (nextplayer
  whitelists `srt/ssa/ass/vtt/ttml`, Nova uses its own FFmpeg core, Just Player
  silently shows a blank track).
- Full track picker with Off option; subtitles are anchored to the video, not the screen
- **Appearance settings** — size, color, background, outline, and sync delay with live preview (in the player's ⋮ menu; delay live on Android via `DelayingParser` + reopen)
- **OpenSubtitles** — search/download from CC (5/day anon, 20/day free login); Nova-based language catalog (full names, 3-letter `eng/fre/pob/zho`, `zh-CN/zh-TW`) for reading + download prefs + text encoding (CP1250…CP949)

## Network Playback
- **SMB / NAS** — in-app SMB browser on **both** iOS and Android: add a server, browse its shares, pin a folder to Home, and play. A subnet sweep finds servers on the LAN and reports each one's SMB version; saved servers show a green/red reachability dot. Playback reads go straight to the share over **libsmb2**, with parallel read-ahead, on both engines — resume plus the saved audio track both survive reopening. CX Explorer "Open with" handoff also works
- **WebDAV** — browse and stream from WebDAV servers on both platforms
- **Jellyfin / Emby** — browse libraries, direct-play with auto-discovery
- **FTP / SFTP** — browse and stream from FTP servers and SSH/SFTP file hosts
- **DLNA / UPnP** — discover and play from media servers on your LAN
- **Files app "Open with"** on iPad with bookmarked folders
- Encrypted credentials (Android Keystore / iOS Keychain)

## Smart Library
- **Continue watching** — resume any partially-watched video with progress bars
- **Library search** — the Home app bar has a search button for everything already in the library: shows, season folders, episodes, movies and manual groups. It matches titles, file names, episode codes and original titles as you type, is accent- and case-insensitive, and works **offline** — metadata only enriches entries that are already there, it never adds results that cannot be played. Each row names its source
- **User-added folders** — add a TV show or movie folder, get a TMDB poster and episode list; **deep recursive scan** (up to 5 levels) expands mixed containers so loose files aren't hidden behind parent cards
- **Movie-part folders stay separate** — `Das Finale 01`–`04` each get their own card with the correct per-part TMDB match
- **Manual grouping** — select cards (long-press) → Group → one grouped card with the name you choose; TV series still auto-group by name
- **Bookmark network folders to Home** — pin SMB and WebDAV folders straight from their browsers, with a colored source badge (Jellyfin/FTP/DLNA are browse-only via `+` menu)
- **Season auto-expand** — bookmarking a show expands each season into its own card (`House Season02`, `House Season03`); group manually if you want one card
- **Download to device** — download network videos for offline playback (SMB, WebDAV, HTTP, Jellyfin, UPnP), or copy a file off a USB drive or SD card; progress lives in the notification panel and the list is in the home screen's hamburger menu
- **Downloaded files in home grid** — completed downloads appear with a checkmark badge, tap to play
- **SIMKL watched sync** — free unlimited watch-history sync (`simkl.com`); auto-pushes finished videos and syncs watched state across devices
- **File browser** — browse device storage and play any video without importing. USB drives and SD cards appear as volumes ("USB drive (name)"), and the list re-scans whenever you return to the screen or tap **Rescan drives**
- **Multi-select delete** — long-press files or folders to select, then ⋮ → Delete. Folders are deleted recursively, with the confirmation spelling that out

## Localization
- **English, Spanish, Chinese Simplified, Russian, French** — 1100+ translated strings across all screens
- **Auto-detect** device language on launch; optional **Settings → General → Language** override
- Technical terms (codec names, HDR, Dolby Vision, etc.) stay English by design

## Appearance
- **Alternate app icons** — Settings → Appearance → *App icon* switches between five launcher icons (default, logo-only, red, green, cyan). Android switches the launcher component itself; iOS uses the system alternate-icon API

## Movie Metadata (TMDB)
- Every video opens a **details screen** with poster, backdrop, synopsis, rating, genres, runtime, and cast
- Metadata auto-fetches in the background — rows show poster thumbnails before you tap
- TV episodes labeled with Season/Episode info
- "Fix match" to correct a wrong auto-match
- **Grouped screens get the full header** — backdrop hero, overview, rating, genres, cast, trailers, then the poster cards
- **Player top bar** shows the TMDB title (falls back to the file name)
- **Rows fall back to the poster** when an episode has no still of its own, so a missing still never reads as a broken thumbnail

## Player Controls
- Play/pause, seek, ±10s, fullscreen, auto-hiding UI
- **Swipe gestures** — swipe left side for brightness, right side for system volume (phones/tablets, togglable in Settings)
- Aspect ratio picker: Fit, Crop, Stretch, 16:9, 4:3 (persists per video)
- **Chapters** — previous/next chapter buttons beside the transport (press previous twice to walk back, not just restart the current one) and ticks on the seekbar, on both engines and on local, SMB, WebDAV, FTP, UPnP and Jellyfin sources
- **Skip intro / recap / credits** — an on-screen "Skip …" button appears while the playhead is inside (or within 5 s of) a segment, and the ⋮ menu lists all three. Timestamps come from embedded chapter names, **TheIntroDB** (movies & mainstream TV, TMDB-keyed, keyless) and **AniSkip** (anime) — all cached locally, so they work offline and from SMB/USB. Settings → Player → *Skip intro / recap / credits*: Off / Show a skip button (default) / **Auto-skip**
- **AirPlay (iOS)** — the real system AirPlay picker is embedded in the player top bar; video goes out on the native AVPlayer path, while FFmpeg-backed containers (MKV/TS/AVI) can send audio only
- **Keyboard shortcuts (non-TV)** — `K` / Space play-pause, `J` / `L` seek ∓10 s, `F` fullscreen; left/right seek while the controls are hidden
- **Playback speed** 0.25×–2× with refresh-rate matching on Android, plus **press-and-hold for a temporary 2×** — hold the picture ~300 ms and a "2x »" badge shows at the top; release to return to your speed
- **Frame interpolation (MPV, Android)** — the picture panel (the sliders button at the top right) → *Frame interpolation* picks a target rate (30 / 48 / 60 / 120 fps) and a quality (Sharp / Balanced / Smooth), so a 24 fps film plays at 60 fps with blended in-between frames and pans stop looking choppy. It is MPV-only by design: Media3 has no interpolation API, and producing the extra frames on the native engine would mean routing the decoder through our own GPU renderer — which would cost the Dolby Vision / HDR passthrough the native engine exists for. Set a default in Settings → Player, or change it live from the picture panel. The target is also **capped automatically when the phone gets warm** (Android thermal headroom), and the same reading steps the Anime4K preset down — the quality never climbs back on its own, so the picture doesn't keep changing under you
- **Thermal-aware quality (Android)** — while the MPV engine plays, DreamPlayer samples the device's thermal headroom every 10 s and eases the GPU-heavy features down before the phone throttles
- **Pinch-to-zoom**, horizontal-swipe seek, double-tap-to-seek ±10 s
- **Touch lock** — locks gestures during playback; tap once to reveal the unlock button
- **Watched marks** — videos auto-mark as watched at the end; toggle manually per row
- **Auto-play next episode** within the same folder — local/SMB + **Jellyfin via ParentId sibling walk** (togglable)
- Resumes playback from where you left off, even after app close or screen lock
- **Picture-in-Picture** — system-drawn transport controls (rewind, play-pause, forward) work for BOTH engines, including the libmpv engine
- **Two play engines — your choice** — every video's details screen shows **Play** (Media3) and **Play with MPV** (libmpv, Android). mpv runs hardware-first (`hwdec=auto-safe`) with its own FFmpeg software fallback and decodes lossless codecs to PCM through Android `AudioTrack`; Media3 retains optional HDMI bitstream passthrough. Video renders into a **native SurfaceView** (not a Flutter texture). Media3 remains the DV/HDR engine; the MPV path can optionally convert the picture (Settings → Player → *HDR tone-map*: SDR tone-map, Native HDR/DV, Linear HDR, HDR10 PQ, HLG, BT.2020 wide gamut) when a libplacebo-enabled libmpv is present.
- **Anime4K for MPV (Android, opt-in)** — enable the Anime4K toggle in the MPV picture panel, then choose Mode A, B, C, A+A, B+B, or C+A. The selected preset takes effect immediately and an `Upscaled` chip is shown while active. It is limited to SDR MPV playback; HDR/DV and PiP are disabled. The bundled Anime4K v4.0.1 fast presets use legacy `vo=gpu` because they do not compile with `vo=gpu-next`/libplacebo, so libplacebo tone mapping is unavailable while enabled. The panel warns about extra GPU load, heat, battery use, and stutter.
- **Optional TheTVDB metadata** — configure a TheTVDB v4 API key in Settings → Metadata. DreamPlayer keeps TMDB as the primary source, can use TheTVDB as a fallback, and lets you choose it explicitly in Fix Match/Group Poster. Provider IDs and artwork are cached independently; SIMKL matching remains TMDB-only.

## Second engine (Android): libmpv

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
stock binary) so the picture can be **converted** for files you do not want in
native HDR: Settings → Player → *HDR tone-map* offers SDR tone-map, Native
HDR/DV, Linear HDR, HDR10 (PQ), HLG and BT.2020 wide gamut, and the player
always writes the complete property set so a mode switch can never leave stale
primaries or transfer behind.

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
server (`SmbHttpProxy.kt`, bound to `127.0.0.1`, byte-range aware). libmpv
can't read `smb://` directly, and the server streams the bytes out of the
**same libsmb2-backed reader with the parallel read-ahead ring the native
engine uses**, so the share is read ahead of the playback while the socket is
fed from memory — the engine never sees an SMB round-trip as a gap in the
stream.

## Optional metadata providers

TMDB remains the default metadata source. Settings → Metadata also accepts an
optional TheTVDB v4 API key and subscriber PIN. When enabled, TheTVDB is tried
only after TMDB fails to produce a confident automatic match; Fix Match and
Group Poster also let you choose TMDB or TheTVDB explicitly. TheTVDB results
reuse the existing title, artwork, cast, season, and episode models, while
provider-qualified IDs prevent collisions in the cache. The API key and optional
PIN are stored in Android Keystore-backed storage or the iOS Keychain; legacy
values are migrated at startup, and Android excludes the legacy Dart preferences
file from backup. SIMKL synchronization continues to use TMDB IDs only.

Provider artwork and episode data remain subject to each provider's terms and
attribution requirements. See [TheTVDB](https://thetvdb.com/) for details. This
product uses the TheTVDB API but is not endorsed by TheTVDB.

AVDb is also available as a third provider, behind **Settings → Metadata → AVDb**.
It is free, needs no API key, and covers adult titles that neither TMDB nor
TheTVDB carry well. It is deliberately limited to movies: it has no season data
and no ratings, so an episode never resolves through it and rows show no star
rather than an invented score. Selecting a provider there shows only that
provider's credential field, with TheTVDB offered as an optional fallback.

**r18.dev** is the other key-free provider, behind **Settings → Metadata →
r18.dev**. It is a different catalogue from AVDb: it is keyed by the code in the
file name (`SVFLA-012` and `SVFLA012` are the same record) rather than by free
text, so a file whose name carries the code resolves to a rich record with the
poster, the cast, the release date, the studio, the genres and the sample-video
frames. Both are searched when either is enabled, and the one that matches
supplies the artwork and synopsis — the details are never fetched from a
different provider than the one that matched.

Third parties can add a provider through the `MetadataProviderAdapter` seam
(`lib/services/metadata_provider_adapter.dart`) instead of being taught to
`TmdMovie` and the cache one at a time.

**Adult content** is off by default. Settings → Metadata → *Include adult
content* is the only switch: TMDB is asked `include_adult=false` everywhere
until you turn it on, so adult titles resolve to no match at all while it is off.
It affects TMDB metadata matching only and changes nothing about what the app
will play.

## Android TV / Fire TV
- Full 10-foot UI with D-pad navigation and custom focus highlights
- Leanback launcher banner
- Dolby Vision + HDR10 passthrough to the TV panel
- Audio passthrough for Atmos/DTS:X over HDMI
- **Settings → Player is available on the stick** — engine picker, video decoder, auto-play next, Picture-in-picture and the on-screen badges are all reachable with the remote. Only the touch-only *Swipe gestures* row is hidden on TV
- Tested on Amazon Fire TV Stick 4K (Fire OS 7.1)
