# Changelog

All notable changes to DreamPlayer are documented here. Each release's entry is
pulled into the GitHub Release body automatically by `.github/workflows/release.yml`.

## 0.3.9

### Added

- **Play with external app (Android)** — the player ⋮ sheet (Playback settings) gained a `Play with external app` row. It pauses the current playback and fires an Android `Intent.ACTION_VIEW` chooser ("Play with…") with the current video's URI (`file://` for local paths, `content://` for SAF / CX-Explorer "Open with" hand-offs, plain `http(s)://` for Jellyfin / UPnP / URL playback) and a `video/*` MIME, so the OS lists every installed player (MX Player, VLC, Nova, Just Player, Kodi, Plex, …) and the user can hand the file off. Sources that can't be shared as a standalone URL (WebDAV Basic-auth, Jellyfin token URLs, in-app SMB) show a snackbar instead. iOS is intentionally out of scope (sandboxing — no app can launch another's player).
- **60s directory-listing cache for all four network sources** — each native client (SMB, WebDAV, FTP/SFTP, UPnP/DLNA) keeps an in-memory `CachedListing` map with a **60-second TTL**, so re-visiting a folder within the TTL is instant (no SMB2 `QUERY_DIRECTORY`, no WebDAV `PROPFIND` + DIDL parse, no fresh FTP/SFTP login, no DLNA SOAP `Browse`). The cache auto-invalidates on `deleteServer`, and a new `invalidateListingCache` channel method is exposed for pull-to-refresh. Wins the most for plain FTP/SFTP (full handshake per listing) and UPnP (SOAP round-trip + DIDL-Lite XML parse). SMB's per-file `length()`/`lastModified()` were already removed earlier; this is the next layer above the protocol.
- **Bookmarked SMB / WebDAV / Jellyfin folders render the full Nova-style series view** — opening a TV-series folder from the home library grid now shows the same poster + title + rating + genres + overview + cast header and season-grouped episodes with stills / names / ratings / overviews as the SMB browser (not just a bare file list). `_loadSmb`, `_loadWebDav`, and `_loadJellyfin` in `folder_screen.dart` now call `_detectAndLoadSeriesFolder()` after the directory listing returns (was missing on the home-bookmark path). The missing widget classes (`_RatingBadge`, `_FactChip`, `_CastRow`, `_posterFallback`) were copied into `folder_screen.dart` so `_SeriesHeader` can build the same layout as `smb_screen.dart`'s `_SeriesFolderHeader`. The `_FolderTile` episode row also gained the rating star + value that `_SmbEpisodeTile` already had.
- **Per-episode `parentMetadataKey` on `TmdDetailsScreen`** — tapping a video from inside a series folder view passes the folder's cached TMDB metadata key through, so the episode details screen uses the folder's show match (with correct season/episode data) instead of re-resolving from scratch. Wired into SMB, WebDAV, FTP, UPnP, Jellyfin, and folder navigation.

### Fixed

- **Files now render before TMDB metadata resolves (series folder views)** — the series folder body in `folder_screen.dart` (home-bookmark folders: local / SMB / WebDAV / FTP / UPnP / Jellyfin) and `smb_screen.dart` (in-app SMB browser) showed a **full-screen spinner while the Nova-style TMDB header (poster/title/overview + season data) fetched** — `_loadingSeriesMeta` gated the whole body behind `CircularProgressIndicator`, so the actual files stayed invisible until the TMDB API round-trips finished. Fix: while metadata is still resolving, render the regular file list immediately (files are the first priority); the series header swaps in via `setState` the moment the fetch completes. If metadata never resolves, the files are already on screen (and the "Get Info" / "Fix match" escape hatch still works). The directory listing itself was always shown first — only the series-header decoration was blocking.

- **Stale `_seriesMeta` after `seasonFor` (first-open episode data missing)** — `TmdMeta` is immutable; each `seasonFor` replaces the cache entry with a brand-new object via `cached.withSeason(season)`. Folder/SMB screens stored a reference to the *pre-season* `meta` returned from `resolveFolder`, so `_seriesMeta?.seasons[s]?.episode(parsed.episode)` always looked up an empty map until the user backed out and re-entered (the cache hit on re-entry returned the fresh meta and the UI populated). Fix: after the season-fetch loop, read the latest meta via `service.metaFor(metadataKey)` and assign via `setState`. Applied to `folder_screen._detectAndLoadSeriesFolder`, both SMB screen paths (initial load + fix-match re-load), and `tmd_details_screen._load`.
- **Anime bracket `[01]` episode lookup missed (still / name / rating blank)** — anime fansub numbering (`[01]/[02]/[03]…` in brackets, VCB-Studio / Kakegurui-Twin style) parses with `season=0, episode=N`. TMDB season data was fetched for season 1, but episode lookup did `_seriesMeta?.seasons[0]?.episode(N)` which returned null — so all episode detail fields came back blank. Fix in `folder_screen._episodeFor` / `_seasonOf` and `smb_screen._episodeForEntry`: when `parsedSeason <= 0` AND `folderSeason == null`, fall back to the first season in `_seriesMeta.seasons` (or scan `cachedMeta.seasons.values` for SMB browse) so anime-bracket episodes resolve to the right `TmdEpisode` object.

- **On-screen badge preferences (Settings → Player)** — the chip row that shows during playback (HDR format, audio codec, resolution, video codec) is now fully configurable. A new **"On-screen badges"** toggle in Settings → Player controls whether any chips appear, and underneath it are two groups: **Format** (HDR, Audio codec, Video codec, Resolution) and **Playback** (Spatial audio, Server transcoding). Each is a compact switch row — no clutter, no overflow. Both Media3 and MPV modes respect the same per-category toggles. The Spatial and Transcoding chips appear only when active (Spatial on Android when the platform Spatializer is engaged; Transcoding when a Jellyfin/server transcode fallback is in progress).
- **Two play engines, your choice — "Play with MPV" (Android)** — the TMDb details screen now offers a second, user-selected engine next to the primary Play button. `Play with MPV` starts the bundled libmpv engine up front (no ExoPlayer backend at all), so any file that Media3's hardware/software decode can't open (12-bit HEVC Rext 4:4:4 like the `yuv444p12le` Kakegurui files, corrupt containers, unknown codecs) plays through libmpv's bundled FFmpeg instead — pick the engine before you hit the wall. mpv runs **hardware-first** (`hwdec=auto-safe` over MediaCodec) and falls back to its own FFmpeg software decode when the hardware can't handle a stream. Renders into a Flutter texture, so it is **SDR-only** — Dolby Vision / HDR10(+) files keep the Media3 engine (the chip in the row tells you: "SDR only — no Dolby Vision / HDR"). The ⓘ info sheet labels the active engine `Engine · libmpv`. iOS keeps a single Play (AetherEngine); the MPV option is Android-only.
- **MPV audio passthrough config (Android)** — the mpv engine switches to the AudioTrack audio output and enables SpDIF passthrough for `ac3,eac3,dts,dts-hd,truehd` (Dolby Atmos / DTS-HD / DTS / AC3 / TrueHD). When the active output device can't take a bitstream (phone speakers, Bluetooth earbuds) libmpv transparently decodes to PCM, so audio always plays.
- **"Try with MPV" on the Media3 error surface (Android)** — when the native engine reaches a terminal error that its own software-decode fallback couldn't recover from, the error overlay now shows a `Try with MPV` button that hands the same file to the libmpv engine on the spot.
- **Resume button highlights the engine that played last** — the TMDb details screen now tracks which engine (Media3 or MPV) was last used per video via `LastEngineStore`. When a video was last played through MPV, the MPV button shows "Resume from m:ss (MPV)" with a highlighted tint, and the main Play button stays plain. When last played through Media3 (or never played), the main button shows "Resume from m:ss" as before.

### Changed

- **Media3 no longer auto-switches to mpv.** The old behavior (a terminal Media3 decode error silently flipped the whole screen to the mpv fallback) is gone: the native engine now exhausts its own software-decode retries and then shows the error, and the choice to switch engines is always the user's (up front on the details screen, or via `Try with MPV` on the error surface).
- **MPV surface attach race fixed** — replaced the brittle 150ms delay before `player.play()` with `controller.platform.future` (deterministic signal from the native surface attach). hwdec + audio output are now configured AFTER the surface is attached but BEFORE `player.play()`, so MediaCodec hwdec gets a valid surface from the first decoded frame (fixes the "Both surface and native_window are NULL" race, matching mpv-android's attach-before-decode pattern).
- **MPV auto software decode for transport streams and legacy containers** — files with extensions `.m2ts`, `.ts`, `.m2t`, `.m2p`, `.vob`, `.mpg`, `.mpeg`, `.wmv`, `.rmvb`, `.flv`, `.ogv`, `.dat` now force `hwdec=no` in the mpv engine regardless of the user's decoder mode setting, because these containers routinely stall or fail under MediaCodec hardware decode (e.g. the Dolby Atmos `.m2ts` test file hung on the first frame with hwdec). The decoder mode toggle in the ⋮ sheet still works for overriding.
- **SMB loopback read cap lowered to 256 KiB** — `SmbHttpProxy.kt` CHUNK reduced from 1 MiB to 256 KiB, the empirically-safe SMB read size that matches the NAS's negotiated MaxReadSize and prevents mid-stream `SmbRandomAccessFile.read` failures that truncated the HTTP body and surfaced in mpv as "http: Stream ends prematurely".
- **MPV audio codec labels now match Media3** — the MPV audio chip now uses `formatAudioCodec` (the same formatter Media3 uses) so codec names render identically across engines: "E-AC3 · 5.1" instead of "EAC3 · 6 ch", "DTS-HD · 7.1" instead of "DTSHD · 8 ch", "TrueHD · 5.1" instead of "TRUEHD · 6 ch". Channel count uses the standard label (2.0 / 5.1 / 7.1) instead of raw integer channels.

## 0.3.8

### Added

- **libmpv fallback engine (Android)** — when the native ExoPlayer/Media3 engine surfaces a terminal decode error that its own software-decoder auto-fallback can't recover (a hardware decoder that misreports HEVC Main10 support and fails at runtime, a corrupt container, a codec no Media3 renderer can find), DreamPlayer transparently flips the same player screen over to a bundled **libmpv** (`media_kit` + bundled FFmpeg software decode). The user sees a one-time toast — "This video isn't supported by the built-in player, so the fallback player is being used." — and keeps the same transport, seekbar, gestures, PiP, resume, and chapter list. The ⓘ info sheet shows `Engine · libmpv (software)` so the user can see the active engine. **Cannot** do DV/HDR by design (Flutter textures have no HDR path on any platform, see media-kit issue #615) — the native engine keeps the project goal; the fallback exists so a user gets a working player instead of an error overlay when the native engine can't. iOS does not fall back (AetherEngine handles its own failures). Triggered for `ERROR_CODE_DECODING_FAILED`, `…_DECODER_INIT_FAILED`, `…_DECODER_QUERY_FAILED`, `…_DECODING_FORMAT_UNSUPPORTED`, `…_DECODING_FORMAT_EXCEEDS_CAPABILITIES`, and `…_DECODING_RESOURCES_RECLAIMED`.

- **External subtitles for the fallback engine** — mirrors the main engine's **external > embedded always** priority rule. mpv's own `sub-auto=exact` only scans sidecars next to a local video file, but the fallback's sources are loopback HTTP URLs (SMB) and remote schemes with no directory to scan. `_attachMpvExternalSubtitles` adds the Media3 path's resolved subs explicitly: non-defaults first via raw `sub-add <uri> <title> <lang>` (so they populate mpv's `track-list` for the CC sheet to pick from), then the default track last via `SubtitleTrack.uri(...)` (`setSubtitleTrack`) so mpv's final selected track is the one the Media3 path would have selected. Each track is labeled with the real filename + language, not the generic `external` placeholder.

- **SMB → loopback HTTP bridge** — jcifs-ng only talks to Media3-native `DataSource`s, and libmpv can't read `smb://` directly. Solution: a tiny HTTP/1.1 server (`SmbHttpProxy.kt`, `ServerSocket` accept loop + one daemon thread per connection, GET/HEAD + single `Range` bytes=) bound to `127.0.0.1` on a free port that hands out a `SmbRandomAccessFile` per token. Idle handles are parked in an `ArrayDeque` per file (re-opening an SMB handle costs a tree-connect + create round-trip — mpv's probe fires ~15 ranges back to back, so closing every time is what made startup slow). Reads are serialized per file via a `ReentrantLock` because `SmbRandomAccessFile` is not thread-safe.

- **Picture-in-Picture for the fallback engine** — a Flutter texture receives no touches in pip, so the Media3 path's normal player chrome is useless there. New Activity-level `PipManager` (`dreamplayer/pip` channel) handles pip for the fallback engine: Dart pushes playback state via `setMpvState` on every playing/pause/buffering transition (cannot round-trip in `onUserLeaveHint`), and the native side answers synchronously. `MainActivity.onUserLeaveHint` / `onPictureInPictureModeChanged` / `onStop` / `onResume` route through `PipManager` first, falling back to `ExoPlayerView` when the fallback isn't active. The pip window shows ONLY the video (player screen already hides chrome on `_inPip`).

- **Pip transport controls for the fallback engine** — three system-drawn `RemoteAction` buttons (`ic_stat_rewind` / `ic_stat_pause`/`ic_stat_play` / `ic_stat_forward`), rebuilt on every play-state change while in pip so the play/pause icon flips with reality. Each fires a package-scoped broadcast (`com.dreamplayer.app.PIP_CONTROL` + `EXTRA_CONTROL`); `PipManager` registers an inline `BroadcastReceiver` while pip is active (API 33+ uses `RECEIVER_NOT_EXPORTED`) and forwards each tap to a method call (`pipPlayPause` / `pipRewind` / `pipForward`) that hits dedicated Dart handlers. Same dismissal-latch (`pipSeen` + `onActivityStopped`) as the main engine — swiping the pip away delivers `onStop` while the system STILL reports `isInPictureInPictureMode=true`; without the latch the pause is skipped and audio plays invisibly.

### Fixed

- **iOS SideStore install crashed with `ldid.cpp(1461): _assert(): end >= size - 0x10`** — the iOS bundle was embedding `Mpv.framework` + `media_kit_libs_ios_video.framework` + `media_kit_video.framework` from `media_kit_libs_video: ^1.0.7` (a facade package that pulls in both Android and iOS native libs). We never use libmpv on iOS (AetherEngine handles that), but SideStore's `ldid` pseudo-signer tried to sign every embedded framework and `Mpv`'s code-signature blob layout doesn't match what it expects. Switched to `media_kit_libs_android_video: ^1.3.8` (Android-only) — `Mpv.framework` is no longer pulled into the iOS bundle. Added a `Platform.isAndroid` guard at the top of `_startMpvFallback` as belt-and-braces so the iOS Dart side can never instantiate a Player.

## 0.3.7

### Fixed

- **External subtitles now auto-pair across every source and platform** — same-name sidecars (`.srt` / `.ass` / `.vtt` / `.sub` / `.ttml` / `.smi` / `.mpl2`) next to a video now auto-load on **WebDAV, FTP, SFTP, SMB, Jellyfin, UPnP, local storage, and the SAF bookmarked-folder picker**, on **both Android and iOS**. Three issues were fixed:
  1. **Native listings filtered to video extensions only**, so the sidecar service never saw the `.srt` in the parent folder and couldn't pair it with the video by name (Nova's `RawListerFactory` returns everything and lets the caller filter). Android + iOS now expose a `listDirectoryAll` channel method that returns every entry, with `listDirectory` refactored behind a `videoOnly` flag.
  2. **FTP browser percent-encodes path segments** when building the playback URI (`Test%20Video.en.mp4`), but the native `listDirectory` / `fetchBytes` expected the raw decoded path — so listing targeted a non-existent folder and the sidecar fetch looked for a file literally named `Test%20Video.en.srt`. `_decodePath` now reverses the encoding before the native call, and `_encodePath` re-encodes only for the playback URI.
  3. **Even when a remote sidecar was found, the engine was handed the raw `ftp://` / `sftp://` / `smb://` / `http://` URI for the subtitle track** (AVP issue #1605: fragile to auth reflow, connectivity drops, redirects — Nova's rule is "copy remote subs locally first"). A new `SidecarSubtitleService.ensureLocal` prefetches every remote sidecar to a `file://` in the app's cache and rewrites the track URI before the engine opens. **iOS parity**: iOS previously gated sidecar discovery on `Platform.isAndroid` and had no `fetchUrl` channel method; the gate is removed (SMB discovery stays Android-only since the iOS SMB channel was retired in 2026-08) and `iOS WebDAVClient.swift` + `FtpClient.swift` now expose `fetchBytes` / `fetchUrl` with auth headers and self-signed support, so WebDAV and FTP/SFTP sidecars work the same way on iPad. Verified end-to-end on-device: `Test Video.en.srt` next to `Test Video.en.mp4` on the FTP share auto-loads on Android and iPad.

- **Raw "Playback failed (ERROR_CODE_…)" errors are now actionable** — the Dart friendly-error mapping matched snake_case codes (`error_code_io_*`, `error_code_decoder_init_failed`, …) that Media3 never emits, so every real `PlaybackException` fell through to the generic "Playback failed (CODE).message" string. The mapping is now driven off Media3's actual `errorCodeName` strings (`ERROR_CODE_IO_*`, `ERROR_CODE_DECODING_FAILED`, `ERROR_CODE_PARSING_*`, `ERROR_CODE_AUDIO_TRACK_*`, plus the custom `UnsupportedDolbyVisionProfile5`), covering network/server timeouts, expired handoff URLs, file-not-found/no-permission, all decoder init/query/format failures, audio-track init failures, container-parse errors, and the cleartext-not-permitted case. The mapping is extracted to `lib/screens/player_error.dart` and unit-tested in `test/player_error_test.dart` (9 new tests). Same fix applied to `_isRetryableIoError` so the existing exponential-backoff auto-retry now actually fires on the right codes.
- **Hardware-decoder failure (HEVC Main10 on MediaTek G81 / budget chips) now auto-falls back to software decode, like VLC and mpv** — some devices' hardware H.265/HEVC decoders advertise 10-bit Main10 support but then fail at runtime with `ERROR_CODE_DECODING_FAILED`; the same file plays fine through FFmpeg software decode (verified on Infinix Hot 50i, MediaTek G81: VLC/mpv play `Strike the Blood Final [Ma10p_1080p][x265_flac].mkv` smoothly). On a video-decode error the player now transparently switches `decoderMode` to `sw`, reopens at the current position (you see a brief "Hardware decoder failed — retrying with software…" message), and restores the user's original decoder mode when the player closes or a different file opens. The override is per-file only, so the next video returns to your preferred mode automatically. Triggered for `ERROR_CODE_DECODING_FAILED`, `ERROR_CODE_DECODER_INIT_FAILED`, `ERROR_CODE_DECODER_QUERY_FAILED`, `ERROR_CODE_DECODING_FORMAT_UNSUPPORTED`, `ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES`, and `ERROR_CODE_DECODING_RESOURCES_RECLAIMED`. The decoder chip in the ⓘ info sheet shows "· software" so the user can see the fallback engaged.

## 0.3.6

### Fixed

- **External .srt with exactly the same name as the video now auto-loads everywhere** — a sidecar like `Movie.srt` next to `Movie.mkv` was missed in some setups. Root causes fixed: (1) `SubtitleFormats.findSiblingSubtitles` prefix check was case-sensitive (`startsWith`); now `lowercase` on both sides with case-insensitive sort; (2) **SAF bookmarked folders** (`tree:<id>/…` from **+ → Add folder to library**) store videos as `content://` `DocumentFile` URIs — `File.listFiles()` on the synthetic `tree:` path always returned empty, so no sidecar was ever found. `ExoPlayerView` now resolves the tree via `DocumentFile.fromTreeUri` and lists siblings in the parent `DocumentFile`, building `MediaItem.SubtitleConfiguration` from `content://` URIs (with `toUtf8` + `isDefault` on the best filename match). Covers internal storage, removable/USB SAF trees and `content://` handoffs. (3) **Bookmarked folders on iOS**: `siblingSubtitles(for:)` now wraps the parent `contentsOfDirectory` in `startAccessingSecurityScopedResource` / `stop…` so Files-app security-scoped bookmarks list correctly.

## 0.3.5

### Changed

- **Top-chip row is now HDR + audio only** — persistent player chips show only HDR format and audio codec; all other diagnostics (resolution, decoder, transcode, boost, spatial) live exclusively in the ⓘ info sheet. Removes persistence clutter and prevents overlap in PiP.
- **Network activity / bandwidth indicator removed** — the live speed/buffer readout on the player and in the ⓘ sheet was dropped per user request.

### Fixed

- **iOS audio track selection on network sources (WebDAV / FTP / SFTP / Jellyfin)** — `AetherEngine` cannot re-probe the container in place when the reader is a loopback/`ByteRangeSource` (WebDAV auth, FTP, Jellyfin direct-play). Selection now proactively reloads the session from the current position, waits for `.playing`/`.paused` (engine has no `.ready` case — `PlaybackState` is `.idle/.loading/.seeking/.playing/.paused/.ended/.error`), re-applies the chosen track via flat→native `id` conversion, and emits. Verified on Jellyfin/WebDAV/FTP.
- **iOS audio track played the opposite language (English↔Korean swapped)** — `audioTrackMaps` was emitting native `id` as `index` while Dart treated `index` as flat position, so `t.index == selected` and `engine.selectAudioTrack(index:)` were crossed. iOS now mirrors Android's contract: `index = flat position`, `selectedAudioTrack = flat position` (`firstIndex(where: id == active)`), and `engineAudioId(forFlatPosition:)` converts at the engine boundary (`selectAudioTrack` expects native `id`). Picking English now plays English.
- **iOS audio chip shows proper codec + language** — FFmpeg/AetherEngine tags like `dca`, `ac3`, `eac3`, `alac` now map to `DTS`/`AC-3`/`E-AC3`/`ALAC` etc., and the live chip appends `· <Language>` via the selected track's language (with `und`/`zxx`/`mul`/`unknown` treated as empty).
- **SMB mid-playback `io_unspecified` → `EOFException`** — `SmbDataSource` left a permanent hole when a prefetch read failed (`nextWritePos` already advanced) and set `bufEof` on any `END_OF_INPUT` even with pending holes, causing `MatroskaExtractor` to throw `EOFException` mid-file. Now rewinds `nextWritePos` on failure with handle reconnect, tracks `eofAt`/`fatalError` with 12-strike guard, and only sets `bufEof` when the contiguous frontier reaches `eofAt`. Verified on real NAS playback.
- **External subtitles preferred over embedded** — when a sidecar file (`.srt`/`.ass`/`.vtt`/`.sub`/`.ttml`/`.smi`/`.mpl2` etc.) exists next to the video it is now auto-selected first (best filename match gets `SELECTION_FLAG_DEFAULT` / `ExternalSubtitleTrack.isDefault`; otherwise the container's embedded track plays). Priority is `sidecar file > Jellyfin server DeliveryUrl > embedded`, with network-share discovery for SMB/WebDAV/FTP/Jellyfin and CX `content://` handoffs (cached to `file://` for Media3). Covers the `videoname.srt` + `videoname.eng.srt` naming used on NAS shares.
- **iOS `indicatedBitrate` type** — `AVPlayerItemAccessLogEvent.indicatedBitrate` is `Double` (`bits/sec`), not `Int64`.

## 0.3.4

### Fixed

- **iOS subtitle background opacity was ignored** — `UILabel` auto-sets `isOpaque = true` when a `backgroundColor` is assigned, forcing the background to render fully opaque and silently dropping the alpha byte. Explicitly setting `label.isOpaque = false` lets the ARGB alpha through, so "Semi" and custom-alpha backgrounds now blend with the video on iOS. Also reset `label.backgroundColor` to `.clear` (instead of `nil`) and reset `cornerRadius`/`clipsToBounds` when the "None" background option is chosen.

## 0.3.3

### Fixed

- **Seekbar touch alignment & responsiveness** — the seekbar now snaps to the exact finger position on touch-down (no more needing to find the thumb dot), uses `onTapDown` + `HitTestBehavior.opaque` for instant grab instead of waiting for a 20 px drag threshold, and removed the horizontal-padding-from-total-width offset bug that made the thumb jump off your finger. Tappable height increased to 48 dp; thumb grows to 22 dp and track to 6 dp while dragging for clear visual feedback.

## 0.3.2

### Added

- **Bookmark any network folder to Home** — SMB, WebDAV, FTP, and DLNA (UPnP) browser folders can now be pinned to the home "Your library" grid via an AppBar bookmark button (`LibraryFolderSource` no longer just files/jellyfin — SMB/WebDAV/FTP/UPnP each carry a `networkServerId`/`share`/`path`/`label`). Folder cards show a per-source badge (SMB blue, WebDAV orange, FTP purple, DLNA grey, Jellyfin teal). Bookmarked network folders list their files directly in `FolderScreen`; removal releases the bookmark with no SAF grant.
- **SIMKL free sync** — free unlimited watched history sync (`api.simkl.com`, `SIMKL_CLIENT_ID` from `.env` via `lib/config/simkl_keys.dart`). New `lib/services/simkl_client.dart` (`dreamplayer.simkl` prefs, PIN flow `GET /oauth/pin` + 5s poll, `POST /sync/history` with TMDB ids, `GET /sync/all-items`/`/sync/activities` delta) + `lib/services/simkl_sync.dart` throttled pull/apply. Player `player_screen.dart` pushes watched on `ended`; Settings shows Connect/Sync now/Disconnect gated on `simklClientId.isNotEmpty`.
- **SMB watched ticks + SIMKL backfill** — every SMB file row shows a green watched check + per-row toggle (`smb:` resume keys); an AppBar cloud-done button syncs already-watched titles from SIMKL.
- **Series-grouped library with watched progress** — folder and details screens group episodes by season (`lib/utils/season_group.dart` pure helper; `lib/widgets/season_progress_ring.dart` 28–32dp ring). Season headers show `Season N` + `watched/total` badge + circular progress (`WatchedStore` + `ResumeStore.positionFor`), collapsible `ExpansionTile` per season, linear 2px resume bar per episode tile, TV `TvTile` focus kept. Folder cards show a bottom-right ring + `S1 2/5` pill for TV shows.

### Fixed

- **Trakt removed** — stale Trakt sync code was completely removed (client, sync, keys, settings UI, player push, unit tests) in favor of SIMKL free unlimited sync.
- **GDrive removed (2026-08)** — the Google Drive cloud feature was fully taken out of the codebase (client, screen, native authors, OAuth redirect manifest entry, `androidx.browser` Custom Tabs dependency, cloud_keys). Drive support is no longer offered; WebDAV/Jellyfin/SMB/FTP/DLNA remain the cloud/NAS options.
- **Network folder library counts + duplicate title + resume bar** — the folder screen header showed "0 videos" for SMB/WebDAV folders (it read an empty local list instead of the unified `_currentEntries`), duplicated the AppBar title, and showed a redundant per-tile resume bar. Header now counts from `_currentEntries` and only shows the metadata line; the resume bar was removed (resume detail lives in the per-video details screen).
- **Bookmarked network folders opened a blank screen** — a network bookmark previously pushed `TmdDetails`, whose file list only handles FileBrowser/Jellyfin. It now opens `FolderScreen` directly so the file list appears immediately.
- **SMB resume key missing `/`** — the share/path join dropped a slash, so resumed positions didn't match on re-open.
- **iOS "Add folder to library" could hang silently** — when the native document-picker completion never fired, the Dart `await` hung forever with no feedback. Added a 60s timeout + error SnackBar so the flow surfaces a message instead of doing nothing.
- **Fixes to keep iOS building green** — removed orphaned GDrive comment/var left by the removal in `AvPlayerView.swift` and used a portable `catch let error as` form for `CancellationError`, so the unsigned iOS build succeeds.

## 0.3.1

### Fixed

- **SMB HDR10 files played as SDR** — HDR10 rips whose MKV lacks the `Colour` element (metadata only in the HEVC SEI, e.g. the Spider-Verse REMUX) fell back to SDR on NAS playback: the bitstream probe fed the `smb://` URI to `MediaExtractor`, which cannot open SMB. New `SmbMediaDataSource` (`ExoPlayerView.kt`) wraps jcifs `SmbRandomAccessFile` (saved share creds, like `MkvChapters.parseSmb`) in a `MediaDataSource` so MediaExtractor demuxes the remote MKV — wired into both the HDR10 (SEI 137/144) and HDR10+ (ST 2094-40) probes.
- **CC sheet overflowed in landscape** — the subtitle picker was a fixed `Column`; its whole body is now a single scrollable `ListView` so nothing overflows at any height.
- **Subtitle settings changes didn't apply** — the ⋮ → Subtitle settings screen saved prefs but never pushed the new style to the live player. On return the player now reloads the style, applies it natively, and (Android) reopens at the current position so a delay change re-parses cues.

## 0.3.0

### Added

- **Nova-based subtitle language & encoding prefs** — reading language (auto-select track) + download language (OpenSubtitles `languages` param) + text encoding (codepage) modeled on Nova `res/values/arrays.xml` (`system` + 35 full names, not ISO codes; 3-letter Nova codes `eng/fre/ger/pob/zho/zht` → `en/fr/de/pt-BR/zh-CN/zh-TW`). `lib/services/subtitle_languages.dart` / `subtitle_encodings.dart` with `migrateLegacyLangCode`, `openSubsCodeForNovaCode`, `trackMatchesNovaCode`; Settings pickers show full names via `RadioGroup`, sheet `lib/screens/opensubtitles_sheet.dart` uses same list. Persisted as `dreamplayer.subReadingLang` / `subDownloadLang` / `subEncoding`.
- **Phase 3 — parity + binge DONE** — Jellyfin auto-play next now walks `ParentId` siblings (`JellyfinItem.parentId` + `lib/screens/player_screen.dart:893` episodic sort → `videoItem`); Android subtitle delay live via `DelayingParser` + reopen (text cues, PGS/DVB still not shifted).
- **NAS reconnect-on-drop verified** — high-bitrate SMB reconnect/resume confirmed on-device (2026-08-26).
- **Dolby Vision profiles P4/P5/P7/P8/P9** — chip + badge + Video info now show `DV P8`, `DV P7`, etc. (`lib/utils/codec_info.dart:15` `dolbyVisionProfile`/`dolbyVisionLabel`, `lib/screens/player_screen.dart:3059` `_hdrLabel`, `lib/widgets/video_card.dart:368`).

### Fixed

- **iOS OpenSubtitles CC search showed No results** — hash-exact search used `moviehash` only, so unknown hashes returned 0 rows. Now sends both `query` + `moviehash` and falls back to `query`-only (`lib/services/opensubtitles_client.dart:258`).
- **CI now bakes `OPENSUBTITLES_API_KEY`** — `ios.yml` + `release.yml` pass both `TMDB_API_KEY` + `OPENSUBTITLES_API_KEY` as `dart-define`; added `OPENSUBTITLES_API_KEY` to GitHub secrets from `.env`.
- **Dolby Vision only showed P8** — `detectHdrFormat`/`detectMedia3HdrFormat` now handle all profiles via `dvhe/dvh1/dvav 0?N` + `P4-P9` hints, with `videoMime` support.

### Changed

- Bumped to **0.3.0**; `AGENTS.md:433` NAS status → verified, Phase 3 pending → DONE.

## 0.2.7

### Added

- **FTP / SFTP on iPad** — server list with inline connection test → folders → videos → play. SFTP via Citadel (SwiftNIO SSH); plain FTP is a hand-rolled client over POSIX BSD sockets (non-blocking connect + poll, 10 s timeout). Playback streams through a byte-range source wrapped in the same read-ahead buffer as WebDAV; passwords stay in the Keychain.
- **Spatial audio chip (Android)** — teal "Spatial" chip in the player top bar when the platform Spatializer is actually engaged: enabled in system settings + available for the current routing + multichannel track confirmed spatializable (`canBeSpatialized`). Live updates when headphones plug/unplug or the system toggle flips mid-playback. API 33+; minSdk untouched.
- **Bass Boost (Android)** — Off/Low/Medium/High `BassBoost` session effect that restores the low end HRTF virtualization thins out. Lives in the player ⋮ menu and appears only while Spatial audio is engaged; persisted and re-applied on every open.
- **Subtitle appearance moved into the player** — size / color / background / outline / delay with live preview now live in the ⋮ menu next to the CC picker (removed from app Settings); preview backdrop replaced with a gradient placeholder.

### Fixed

- **HDR badges on SDR content (iOS)** — the HDR10+/HDR10 bitstream probe accepted random compressed bytes as SEI NALs (raw `B5 003C` fallback + header aliasing on H.264 MP4s), so ordinary SDR files showed HDR chips. The probe now requires real NAL structure (Annex-B start codes or chaining AVCC length prefixes), HEVC parameter-set signatures, prefix-SEI-only, and strict payload-size windows.
- **Replay after end failed with "cancellation error" (iOS)** — the replay button's seek+play pair triggered two overlapping engine reloads; AetherEngine supersedes the first load with `CancellationError`. Reloads are now coalesced and supersession is no longer surfaced as a playback failure.
- **Touch lock trapped the player** — after locking, taps were swallowed entirely so controls could never be revealed to unlock. A tap now reveals the bars for the Unlock button; all other transport/seek/sheet controls are gated while locked.
- **+ menu clipped in phone landscape** — default bottom sheets cap at 9/16 screen height; the menu is now scroll-controlled so every entry is reachable.
- **FTP playback failures (iOS)** — SIZE reply parsing now strips the status code; reads at/past EOF answer empty instead of triggering server errors; concurrent chunk fill + moov-seek no longer cross REST/RETR replies on the shared control connection (one transfer at a time).
- **Local Network permission prompt** — iOS fires a harmless Bonjour probe at app open so fresh installs see the permission dialog immediately instead of mid-flow.

## 0.2.6

### Added

- **Playback speed 0.25×–2× + refresh-rate matching (Phase 1)** — bottom-bar overflow holds the current rate (`1×`), dropdown offers 0.25×–2×; persisted as `dreamplayer.playbackSpeed` and re-applied after every open/reopen. Android: `player.setPlaybackSpeed`; iOS: `AVPlayer.defaultRate`/`rate` via layer walk. Android also matches the display mode to the video FPS (`preferredDisplayModeId` on STATE_READY / size change, ±0.5 Hz hysteresis, restores on dispose). iOS FFmpeg custom-source (WebDAV) has no AVPlayer → speed is no-op there until AetherEngine exposes a rate API.
- **Chapters + watched marks + overflow dropdown (Phase 2)** — MKV `Chapters` parsed directly (EBML walk: SeekHead → EditionEntry → ChapterAtom, SeekID `0x1043A770`, ns→ms, first `ChapString` fallback "Chapter N") for local (`RandomAccessFile`), SMB (`SmbRandomAccessFile` + saved share creds), and HTTP/WebDAV (`Range: 0–8M` via OkHttp standard+permissive clients); Jellyfin `Item.Chapters` (`Fields=Chapters`, ticks/10000 ms) seeded from `VideoItem.chapters`. Chapters appear in the bottom-bar overflow `⋮` (Aspect/Speed/Chapters collapsible sections), highlight the current chapter and tap-to-seek. Watched marks auto-set on `STATE_ENDED` and manual via check icon per row, green check = watched, resume labels now `h:mm:ss` for ≥1h. Bottom bar decluttered 6→4 buttons (`audio · CC · ⋮ · fullscreen`).
- **HW / SW decoder toggle + live badge** — Settings + overflow let you pick Auto / Hardware / Software; `PlayerCodecs.mediaCodecSelector` filters `isSoftwareVideoDecoder` live per query (HW filters SW decoders, SW prefers `c2.android.`/`google`/`ffmpeg`). Player top bar shows `Auto, H/W` / `Auto, S/W` etc. via `onVideoDecoderInitialized` (`videoDecoderName/isHwDecoder`), chips wrap in portrait. Verified: software fallback no longer kills HDR — video stays on `MediaCodecVideoRenderer`.
- **DLNA / UPnP browse (Android + iOS, DONE)** — Home **+** → DLNA: SSDP discovery (Android `XmlPullParser`, iOS BSD-socket poll+resend with `IP_MULTICAST_TTL=2` + `IP_MULTICAST_IF=en*`, entitlement `com.apple.developer.networking.multicast`), SOAP `ContentDirectory#Browse`, DIDL parsing with VLC/upnpx semantics (`shouldProcessNamespaces=false` + suffix matching `dc:title`/`upnp:class`, tolerant `<Result>` regex, single-pass entity unescape). On-screen Diagnostics box + `getDiagnostics` channel. iOS fallbacks when SSDP gated: saved-Jellyfin-host probe → UDP-7359 broadcast → direct `http://192.168.1.16:8096` probe.
- **Jellyfin DLNA transcode & multi-res fixes** — Jellyfin serves external-subtitle items as `CI=1` `video/mp2t` live transcodes; `JellyfinClient.upgradeDlnaUrl()` matches `/dlna/(videos|audios)/<id>/` against saved Jellyfin servers (origin match) and rebuilds the item via `getItem`+`videoItem` → original-bytes direct play with sidecar subs as tracks + chapters + stable resume key. Multi-res DIDL (one `text/srt` res per subtitle) no longer hands the player an `.srt` as main media — video `protocolInfo` preferred, every `text/*` res collected into `externalSubs` → selectable tracks on the raw DLNA path. Verified on-device: House S02E04 plays original `hevc` direct (`stream.mkv?Static=true`) or `h264` TS with red badge depending on server session — both work. **Red "Transcoding" chip** whenever playback is server-transcoded (HLS fallback, `CI=1`, or `master.m3u8`).
- **Series grouping + live subtitle delay (Android) + auto-play next (Phase 3 DONE)** — Season grouping for Jellyfin/file folders, Android subtitle delay now live via `DelayingParser` (`SubtitleTiming.delayUs` + reopen on change; PGS/DVB bitmap cues still not shifted), auto-play next episode within the same folder (local/SMB + Jellyfin via `ParentId` sibling walk `lib/screens/player_screen.dart:893`).
- **OOM fix** — `android:largeHeap="true"` + `BufferTuning` 96→64 MiB on large-RAM devices (Fire TV 192 MB heap stays 24 MiB), fixes `MediaCodec.BufferInfo` heap abort on 256 MB devices.

### Fixed

- **iOS DLNA browse empty** — Foundation `XMLParser` with namespaces on silently yields zero entries (prefix `D:response`), fixed by `shouldProcessNamespaces=false` + qualified-name suffix checks; `ResultUnescaper` replaced with single-pass parser.
- **iOS Files-app MKV chapters** — `MkvChapters.swift` EBML probe for `mkv/mka/mks/webm/mk3d`.
- **Decoder badge flicker** — badge no longer vanishes on mode switch; label is mode-aware.
- **Chips overflow in portrait** — chips now `Wrap` to next line when many badges present.
- **iOS discovery gated on managed Wi-Fi** — now falls back through saved Jellyfin hosts and 7359 broadcast before failing.

### Changed

- AetherEngine `6.21.0` → `6.38.0` (latest, drop-in SPM).

## 0.2.5

### Added

- **Double-tap to seek** — double-tap the left half of the video to jump back 10 s, right half to jump forward 10 s, with a brief on-screen ripple indicator (phones/tablets; TV keeps its D-pad buttons)

### Changed

- **Center transport** — the ±10 s skip buttons beside play/pause are now TV-only; phones rely on the double-tap gesture. The dark pill background behind the center controls was removed — only the circular play/pause button floats on the video

## 0.2.4

### Fixed

- **Jellyfin external subtitles** — parses `MediaStreams` (`IsExternal`), builds `DeliveryUrl + api_key` and exposes all `.srt`/`.ass`/`.vtt` in the CC picker (was only embedded)
- **In-app SMB subtitles** — `subtitlePaths` now returns all matches (`video.srt`, `video.eng.ass`…) instead of just the first; CC shows each separately
- **CX / Open-with subtitles** — generic `GET_CONTENT` + `OPEN_DOCUMENT` chooser with `queries` for any file manager (Files, CX, Solid, etc.); NAS siblings auto-discovered via saved SMB server and shown as **"Subtitles on NAS"**; `content://` (CX SMB) is cached to `file://` immediately so ExoPlayer can read it after CX is killed
- **Manual load** — CC sheet always offers **"Load subtitle file…"** (system picker for any manager) plus direct NAS sibling selection

## 0.2.3

### Fixed

- Removed Apple TV / tvOS support (no hardware to test — builds kept failing and the alpha was never verified)
- Removed Google Cast / DLNA casting (removed entirely — broken resume-on-device and audio-track-on-TV bugs, no test device)
- Cleaned stale tvOS references from shared Dart files, README, AGENTS.md, and CI workflows
- Updated repo description to reflect current platform support

## 0.2.2

### New features — playback

- **Jellyfin server transcoding** — when direct play fails (undecodable codec, DV Profile 5 on non-DV hardware, expired stream…), the player retries once through the Jellyfin server's HLS transcoder (`master.m3u8`, H.264 video + AAC/AC3/EAC3 audio, 20 Mbps cap) and resumes at the last position. The server-side transcode job is stopped when the player closes so the host stops burning CPU. Android needed the Media3 HLS module (`media3-exoplayer-hls`); iOS plays HLS natively.
- **Redesigned network-server dialogs (Jellyfin / WebDAV / SMB)** — shared visual language across all three: shaped dialogs with icon-badge titles, rounded icon-prefixed fields, HTTP/HTTPS segmented picker on WebDAV, password show/hide toggles, OS autofill hints, tinted inline test-result banners (SMB results moved out of SnackBars), and consistent action rows. Fields stay D-pad friendly on Fire TV via `TvTextField`.

### New features — player

- **Horizontal-swipe seek** — swipe left/right anywhere on the video to scrub ±90 s per screen width, clamped to the file. A dark pill shows the target timestamp plus a signed delta (green = forward, orange = back); releasing with a change ≥ 500 ms commits the seek. Skipped on TV (D-pad already seeks). Time-only preview by design: frame thumbnails were tried and removed because `MediaMetadataRetriever` decodes Dolby Vision / 10-bit HDR content to blank frames on Qualcomm devices (`c2.qti.dv.decoder`) — exactly the content this app targets.
- **Subtitle appearance settings** — Settings → Player → Subtitles: text size (S/M/L/XL), color swatches, background (none/semi/solid), outline toggle, and delay offset (−30…+30 s) with a live photo-backed preview. Persisted as JSON and pushed to the native player on every open. Android applies size/color/background/outline via Media3 `CaptionStyleCompat` + `SubtitleView.setFractionalTextSize`; **delay offset is currently iOS-only** (AetherEngine cue-window shift — Android needs a cue-pipeline refactor).

### Fixed

- Subtitle settings preview crashed in landscape (`clamp(96.0, …)` with min > max on short viewports) — replaced with explicit caps; preview now sizes adaptively (portrait full-width 16:9, landscape up to 42% of viewport height) over a bright royalty-free still so cue backgrounds/outlines read against real imagery.
- Jellyfin transcode fallback no longer kills itself: the "playing via server transcoding" note used to unmount the player platform view mid-open; the swap now keeps the view alive and shows the buffering spinner.

## 0.2.1

### Bug fixes — player swipe gestures

- **iOS volume gesture actually changes system volume** — `MPVolumeView` builds its internal `UISlider` asynchronously after joining a window, so the old synchronous `subviews.first(where:)` lookup always returned nil and the value was never set (and removing the view immediately made it worse). The view is now retained for the player's lifetime, the slider is found via a bounded async retry (50 ms × max 20), and it's cleaned up on dispose.
- **Swipes start from the live system value** — brightness/volume drags used to build on a value seeded once at player open (system volume only), so a brightness swipe started from the stale volume value and vice versa. Every gesture start now fetches the *current* platform value (`getBrightness` / `getSystemVolume`) as its base; finger deltas accumulate on top of it. Deltas are buffered until the base arrives so an early drag can't flash a wrong absolute value.
- **Swipe pill keeps its icon during fade-out** — drag-end nulled the gesture type immediately while the pill stayed visible for the 800 ms fade, so a brightness pill flipped to the volume icon mid-fade. The type is now retained until the fade completes; a separate active flag gates updates and platform pushes.

## 0.2.0

Major release — **Apple TV support lands**, Android TV / Fire TV playback rebuilt on the in-app player, and phone gesture controls.

### Apple TV (tvOS) — alpha, CI-green
- **tvOS build works end-to-end** — DreamPlayer builds for Apple TV via the community `flutter-tvos` toolchain (Flutter 3.47 base). CI scaffolds `tvos/` fresh each build, overlays our adapted Swift files, injects the AetherEngine packages into the Xcode project, and produces an unsigned `DreamPlayer-tvOS-alpha-<version>.ipa`. **Alpha** — compiles and ships, but not yet verified on Apple TV hardware.
- **AetherEngine on tvOS** — the same playback engine as iOS resolves as a Swift Package Manager dependency for appletvos: `AvPlayerView.swift` imports AetherEngine + AetherEngineSMB; FFmpeg demux/decode and DV/HDR10 via the native AVPlayer path come along automatically. Deployment target raised to **tvOS 17.0** (the engine's minimum — the scaffold pins `TVOS_DEPLOYMENT_TARGET=15.0` at project level, which beats a target-level override, so both names are set at both levels).
- **Adapted Swift files** — `AvPlayerView.swift` guards `MPVolumeView`/brightness/EDR-headroom with `#if !os(tvOS)`; `AppDelegate.swift` drops IntentBridge (no "Open with") and registers the player view factory, file browser, WebDAV client, Jellyfin discovery, and cache cleaner behind the implicit-engine delegate; `FileBrowser.swift` is Documents-only (no document picker — picker calls are graceful no-ops). `WebDAVClient`, `JellyfinDiscovery`, `BufferedSMBReader`, `CacheCleaner` copied unchanged from iOS.
- **tvOS plugins ported** — `shared_preferences_tvos` + `package_info_plus_tvos` (from fluttertv/plugins) give resume/continue-watching, TMDB cache, and saved servers real persistence; `package_info_plus` bumped to ^10.2.1 for compatibility. Plugins without tvOS implementations (`url_launcher`, multicast-lock channel) are wrapped in try/catch so nothing crashes.
- **CI plumbing solved** (`tvos.yml`) — scaffold step backs up our committed `tvos/Runner/*.swift` before regenerating; Ruby `xcodeproj` adds the AetherEngine SPM package reference + both products to the Runner target, disables code signing (flutter-tvos has no `--no-codesign`; equivalent of `flutter build ios --no-codesign`), and registers every overlaid Swift file in the Sources phase; PlistBuddy adds Bonjour services + local-networking ATS; packaging discovers `Runner.app` dynamically instead of hardcoding the output path.
- **Siri Remote** — arrow keys reveal controls / seek ±10s, select activates focused buttons, Menu hides controls then exits; the remote's **play/pause media key toggles playback** even off the TV code path (fixed this release).

### Android TV / Fire TV
- **Custom focus highlight** — blue 3px border + glow shadow + AnimatedScale (1.25× transport buttons, 1.05× cards/list tiles/fields) across all TV-focusable widgets: transport controls, sheet list tiles, seekbar, home cards.
- **TvTile shared widget** — single source of truth for TV focus-glow wrapper (`lib/widgets/tv_tile.dart`).
- **TvOverscan safe-area** — wraps each TV screen with 36px side / 20px top-bottom padding (`lib/widgets/tv_overscan.dart`).
- **TvTextField** — two-FocusNode design: outer glow node for D-pad targeting, inner `skipTraversal` node for the TextField. OK/select opens the system Leanback IME; back/Done hands focus back to the glow node. No custom keyboard.
- **Leanback banner** — 640×360 `banner.png` in `AndroidManifest.xml` for TV launchers.
- **TV long-press** — Enter/select key held 500ms fires `onLongPress`; `KeyRepeatEvent` swallowed.
- **Home scroll-on-return** — `SliverAppBar` pinned, `jumpTo(0)` on load with stable keys.
- **Buffer sizing** — adaptive by heap class: Fire TV 24MB ring buffer (heap 192MB), phones 96MB (heap ≥ 256MB).
- **Transparent window fix** — `MainActivity.kt` sets `Color.TRANSPARENT` on TV devices; `ExoPlayerView.kt` calls `setZOrderMediaOverlay(true)` — video visible on Fire TV Stick.

### Player
- **Gesture controls** — vertical swipe on left half adjusts brightness (`Window.screenBrightness` on Android, `UIScreen.main.brightness` on iOS); right half adjusts system volume (`AudioManager STREAM_MUSIC` on Android, `MPVolumeView` hidden slider on iOS). Dark centered feedback pill with icon + percentage, auto-fades 0.8s. Controls hide during gesture.
- **Swipe gestures toggle** — "Swipe gestures" switch in Settings → Player section (default on); hidden on TV via `isTvMode()`.
- **Play-pause ring highlight** — `_TvControlButton` `alwaysShowRing` parameter; center play-pause uses `alwaysShowRing: !_isTv` so the ring glow shows on phones/tablets without a D-pad.

### Bug fixes
- **SMB badge** — `VideoItem.playbackSource` now accepts both `smb:` and `smb_` prefixes for backward compat with stored data.
- **Double-back-press exit** — root screen shows a SnackBar and requires two taps within 2s to exit (prevents accidental back-press exits on Android).
- **Seekbar minimal highlight** — TV focus highlight on seekbar is a thin 2px border only (no glow, no scale).
- **Flutter 3.47.1** — local toolchain upgraded to match CI and the flutter-tvos base (Dart 3.13); all 129 tests pass, analyzer clean.

## 0.1.11

- **Minimum iOS lowered to 16.0** — the previous floor of iOS 18.0 was conservative; AetherEngine declares `.iOS(.v16)` as its platform minimum and no iOS 18-only APIs are used anywhere. All three Xcode targets updated (`IPHONEOS_DEPLOYMENT_TARGET = 16.0`).

## 0.1.10

- **SMB: wrong credentials now surface an error (Android)** — browsing a saved server with a bad username/password used to silently return an empty share list (the share probe swallowed every exception, so an auth failure was mistaken for "no such share"). `SmbStore`/`SMBClient.kt` now catches `SmbAuthException` separately: if auth fails on every probed share, the shares list and any folder listing report **"Login failed — check username/password/domain"** (a `smb_auth` channel error) instead of a blank screen. The connection-test dialog already reported the failure correctly; only the browse path was silent.

## 0.1.9

- **Per-file TMDB posters in every file list** — the folder screens (library folder contents + subfolders), the WebDAV browser, and the Jellyfin browser now **auto-fetch** TMDB metadata for each movie/episode as the list loads and show the file's **poster thumbnail** instead of the plain play icon. Each row resolves under the *same* stable key its tap uses (`resumeKey`/`folderbookmark:`/`webdav_<server>/<path>`/`jellyfin:<host>/<itemId>`), so opening the file is a direct cache hit — no re-search, the details screen is already resolved. If auto-fetch fails, opening the file and picking the right title via **"Fix match"/"Search TMDB"** persists that poster, and the row updates to show it the moment you return (both screens listen to the TMDB store).
- **Standalone movies no longer inherit a folder's metadata** — in folder mode, a movie file inside a bookmarked folder used to show the *folder's* matched title/poster (e.g. a "Movies" folder's match shown for every file in it). `carryMeta` now runs only for **episodes** of a TV-show folder; movie files resolve their own title, and any folder metadata an older build stamped onto a movie's key is cleared so it re-searches. Jellyfin folder mode applies the same rule (carry only for `Type == Episode`).
- **Shared poster helper** — `posterUrlOf()` lives in `tmdb_client.dart` so the folder, WebDAV, and Jellyfin row tiles all render the same 48×72 rounded poster thumbnail (with the play icon as the error fallback).

## 0.1.8

- **In-app SMB removed from iOS** — the iPad AMSMB2 + AetherEngineSMB browser and playback were deleted: it was slow, didn't play every video, and audio-track switching could crash the app. The "Network shares" home entry is gone on iOS. **Android SMB stays** — the `SmbScreen` + `SmbClient` (jcifs-ng browse + `SmbDataSource` streaming) remain; the "Network shares" entry shows on Android only. NAS playback: **Android** → in-app SMB browser, CX Explorer "Open with", WebDAV, Jellyfin; **iPad** → Files app "Open with", in-app WebDAV, in-app Jellyfin. `BufferedSMBReader` stays for WebDAV's read-ahead; `AetherEngineSMB` stays for WebDAV's `ByteRangeSource`. Full iOS SMB implementation notes preserved in AGENTS.md as a revival blueprint.
- **Source badges** — continue-watching cards show `CX SMB` (Android handoff), `Files / SMB` (iOS Files-app SMB), and legacy `SMB` (old in-app `smb:` keys, historical only).
- **TMDB auto-fetch works for network-share videos** — opening a video from the SMB browser (or any network share) now lands on a fully-resolved details screen instead of prompting "Search TMDB". Root causes fixed: the folder prefetch and the video tap resolved under *different* keys, so the prefetched match was never reused (both now use the same stable key → direct cache hit); a tap during an in-flight prefetch returned a false "no match" (concurrent calls now share one in-flight search future); and a missing TMDB match used to treat filename noise like `MA`, `Hindi`, `SDR`, `ESub` or bracket audio metadata (`[Hindi AMZN DDP 2.0 224kbps + English DTS-HD MA 5.1]`) as part of the search query. Verified on-device: `Silence`, `Identity`, `Oldboy`, `Her (2013)`, `24`, `Main Vaapas Aaunga` all auto-match at score 1.00.
- **Filename → search-query parser cleanup** — audio-language/codec noise (`hindi`, `tamil`, `telugu`, `korean`, `esub`, `uncut`, `sdr`, `ma`, `hdhub4u`, …) is stripped; bracketed/parenthesized audio metadata is dropped (keeping `[S02E04]` episode tags and `(2013)` years for detection); bitrate annotations (`224kbps`, `640kbps`) are removed; `<group>-<site>` release suffixes (`USURY-4kHdHub.com`) are cut including the group; and underscore-glued tags (`Stranger_Things_[S02E04]_1080p`) no longer survive into the cleaned title. New regression tests cover the real NAS filenames.

## 0.1.7

- **Static HDR10 detection for MKV files without Colour element (Android)** — some HEVC MKVs omit the MKV `Colour` element; the PQ/BT.2020 mastering metadata lives only in the HEVC SEI (payload type 137 Mastering Display Colour Volume, payload type 144 Content Light Level). `ExoPlayerView.kt` now probes the first ~10 MB of video samples on a background thread with `MediaExtractor`, scanning Annex-B / AVCC NALs for these SEI payloads. When found, `hdr10Content=true` is set and `stateMap` emits `desired=5.0` + `colorTransfer=6`, engaging the HDR headroom / window color mode path for true HDR10 passthrough even without container-level signalling. Verified on-device: a test MKV with no Colour element but with SEI 137/144 now shows the HDR10 chip and triggers the EDR ramp.

## 0.1.6

- **Real HDR Dolby Vision output (Android) via hybrid-composition platform view** —
  the player previously rendered through Flutter's stock `AndroidView` widget, which
  composites the video into a **virtual display + texture** (a non-HDR path that
  flattens PQ to SDR at ~500 nits and washes colors out). The view is now built with
  `PlatformViewLink` + `initExpensiveAndroidView` (hybrid composition), keeping the
  video `SurfaceView` a real SurfaceFlinger layer on the physical display. Verified
  on-device: the DV P8 file composites as `BT2020_ITU_PQ` with 10-bit PQ buffers,
  `hdr metadata types=9` and `whitePointNits≈1250` — byte-for-byte the profile of a
  pure-native player (Just Player) — and colors now match on screen. DV content also
  skips the window HDR/headroom machinery entirely (decoder-native BT.2020 PQ
  device-composites), and DV tracks whose MKV omits the `Colour` element (Media3
  `colorInfo=null`) are still treated as HDR via their `dvhe`/`dvh1`/`dvav` codec.
- **Jellyfin folders in the home library** — the folder tiles in the Jellyfin
  browser now carry an **Add to library** button that pins that server folder
  onto the home "Your library" grid (teal Jellyfin badge). Tapping it opens the
  TMDB details screen in Jellyfin mode: episodes list through the server API
  with `SxxExx` labels (+ TMDB episode names when the season data is cached),
  and play directly. Only the server URL + item id are stored — the token is
  re-matched against your saved servers on every open, so it keeps working
  across logins. Removing the folder unlists it (no files/grants touched).
- **Jellyfin series info auto-fetched on bookmark** — adding a folder from the
  Jellyfin browser also fetches the series' own metadata from the server
  (`JellyfinItemInfo`: poster + backdrop art, real title, year, rating, genres,
  overview) and caches it, so the home card shows the show's poster and TV/Movie
  badge without needing a TMDB match. The details screen shows a full
  backdrop/poster header with the series overview when TMDB finds nothing, and
  refreshes the info on open so the token-embedded artwork URLs stay current.
- **Per-episode details (TMDB)** — the single-episode details page now shows
  *that episode's* name, overview, air date, runtime, rating, **guest cast**,
  and a **Stills** gallery (via the per-episode endpoint with
  `append_to_response=credits,images`) instead of only the show's metadata. Runs
  only for the single-episode view — a folder with 100 files triggers no extra
  requests. Best-effort: on API failure the episode keeps its season-level data.
- **Season-folder title parsing fixed** — whole-season folders like
  `HOUSE.S02.1080p.10bit.BluRay.English.AAC.5.1.x265-Panda` now resolve to
  `HOUSE` (a bare `Sxx` season tag is stripped, audio-language and streaming-
  provider tags like `english`/`nf`/`amzn`/`hbo` are noise, and `H.265`/`X.264`
  codec tags are explicitly removed) — before, they resolved to a query with 0
  results and never got their poster.
- **Landscape details header shows artwork whole** — in landscape the metadata
  header now renders the poster/backdrop as a centered 16:9 box (capped to the
  viewport height) instead of cropping the art into a thin strip or filling the
  whole landscape screen; the rating badge stays anchored inside the box. Cast
  rows also fit at large text scales.
- **iOS build: CacheCleaner.swift wired into the Runner target** — CI builds
  were failing because the cache-cleaner file was added to the tree but not to
  the Xcode target; it's now in the Runner Sources build phase.

## 0.1.5

- **HDR10+ detected from the real bitstream (Android)** — Media3's format info
  can't tell HDR10+ from HDR10 (both use the same PQ transfer function), so the
  player now probes the video's first samples with `MediaExtractor` on a
  background thread, scanning for the ST 2094-40 SEI (ITU-T T.35 user data,
  country `0xB5` / provider `0x003C`, AVCC + Annex-B NAL framing). When found,
  the top-bar chip upgrades to the amber **HDR10+** label. Verified on-device:
  the HDR10+ "lake" file shows HDR10+, while SDR content is never labeled HDR.
- **PNG HDR badge overlay removed** — the transient bottom-right Dolby Vision /
  HDR10 / HDR10+ / HLG logo that popped in and faded out is gone; the live
  top-bar chip is now the single HDR indicator (it already showed the same
  information).
- **Safe filename-hint parsing** — the hint detector is token-aware, so a full
  title like `Adventure.mkv` can never be misread as Dolby Vision (the old
  substring check tripped on any name containing "dv"); hints are still never
  wired from titles, so labels reflect only the actual content.

## 0.1.4

- **Hardware video decode everywhere (fixes washed-out HDR + 4K HEVC stutter)** —
  the app previously built the player with NextRenderersFactory, which inserted
  `FfmpegVideoRenderer` *before* the MediaCodec renderer and claimed
  `video/hevc`, so every HEVC file decoded in FFmpeg **software**: 4K60
  stuttered and colors were washed out (the FFmpeg GL output carries no HDR
  dataspace). A new `DreamRenderersFactory` overrides only the audio renderers
  (appending the FFmpeg audio renderer for DTS/TrueHD/FLAC) and leaves video on
  the hardware decoder — vendor-agnostic (`c2.qti` / `c2.mtk` / `c2.samsung`).
  Verified on a Redmi Note 10: Sony 4K60 decoded by `OMX.qcom.video.decoder.hevc`
  with the same `BT2020_ITU_PQ` + `hdr metadata types=1` surface profile as
  Just Player.
- **Dolby Vision Profile 5 rejection on DV-less devices** — P5 (IPTPQc2 color)
  renders pink/green without a `video/dolby-vision` decoder, so the player now
  stops it with a friendly "This device cannot decode Dolby Vision Profile 5"
  error instead of garbage frames. P7/P8 keep playing as HDR10 via the HEVC
  fallback.

## 0.1.3

- **Brighter HDR (Android EDR ramp)** — OnePlus/OxygenOS only engages the
  display's HDR mode when the window asks for headroom. The player now sets
  `COLOR_MODE_HDR` + `setDesiredHdrHeadroom(5.0)` on the activity window and
  the video surface's consumer-side dataspace via `SurfaceControl`, so PQ/HDR
  content no longer clips bright highlights flat to white — verified on-device
  with the HDR10+ "lake" clip (`current hdr/sdr ratio > 1.0`, device
  composition instead of a client-composition fallback).
- **Resume survives device lock/unlock (Android)** — locking the phone
  destroys the video surface; the player now pauses on background (saving the
  position) and, on resume, checks the native player's live state via a new
  `getState` channel method (Android + iOS): if the media was lost it reopens
  at the saved position instead of showing a dead screen.
- **Stability fixes** — relaunching from the launcher after unlock no longer
  pushes an empty player screen; TMDB details no longer overflows in landscape
  (regression-tested); the Jellyfin server list no longer overflows at short
  viewports; iOS network-share folder listing is much faster (background scan,
  no per-entry re-stat round-trips).
- **Play-next removed** — the player and details screens no longer chain
  sibling videos as a playlist; each video plays on its own (fixes a build
  failure and simplifies the transport state).
- **Settings footer** — "Made with ❤️ by Mangesh Ghodke".

## 0.1.2

- **TMDB metadata works in release builds** — the release workflow now bakes the
  TMDB API key (from a masked GitHub secret, never committed) into all Android
  APKs/AAB and the iOS IPA, so movie/TV metadata resolves out of the box. The
  misleading "add an API key in Settings → Metadata" prompt (that setting no
  longer exists) was replaced with an accurate no-key message.

## 0.1.1

- **TV series season/episode detection** — the TMDB details screen now shows the
  detected season and episode (`Season 2 · Episode 4`) with an `S02E04` chip for
  episode files, and Continue-watching cards label them too
  (`S02E04 · Continue from m:ss`).
- **File browser opens details first** — tapping a video in the in-app file
  browser (Internal storage / bookmarked folders) now opens the TMDB details
  screen with the folder as its playlist, so Play keeps play-next, instead of
  jumping straight into the player.
- **App icon in the repository** — `app_icon.png` at the repo root (the iOS
  1024px app icon) for use as the GitHub social preview and other branding.

## 0.1.0

First major release — all of the 0.0.x line's fixes plus the metadata and
browsing features below.

- **TMDB movie metadata + details screen** — tapping any video (Continue-watching
  cards, WebDAV/Jellyfin/file-browser listings) now opens a details screen with
  poster/backdrop art, the real title, year, synopsis, star rating, genres,
  runtime, and cast. The big **Play/Resume** button labels itself from the saved
  playhead and is always enabled — a slow or failed lookup shows the real error
  and never blocks playback. "Fix match" re-pins a wrong auto-match via a TMDB
  search and "Remove info" clears it; metadata is cached on-device. The API key
  is build-time only, supplied via `.env` (see below), and is never shown in the
  app or committed.
- **Aspect ratio / fit-mode picker** — the player's aspect button offers five
  modes (Fit, Crop to screen, Stretch to screen, 16:9, 4:3); the choice applies
  to the native video surface and persists per video, re-applied on play-next.
- **Jellyfin LAN discovery fix** — modern Jellyfin (10.11+) removed its mDNS/Bonjour
  responder entirely, so discovery now also runs the proprietary **UDP-7359
  broadcast probe** (native `MulticastLockManager.kt` on Android /
  `JellyfinDiscovery.swift` on iOS), with the legacy mDNS scan kept for Emby.
  The probe holds a Wi-Fi MulticastLock so broadcast frames are not dropped.
- **Build-time API keys via `.env`** — keys are now supplied with
  `--dart-define-from-file=.env` (gitignored; `.env.example` committed with
  placeholders) instead of a tracked file, so no secret ever lands in the repo.
- **iOS subtitle positioning fixes** — PGS/DVB bitmap cues that rendered
  oversized/off-screen in portrait are fixed (the aspect-fit video rect is now
  computed correctly), and all cue positioning moved into the host
  `SubtitleOverlayView`: text and bitmap cues are anchored to the video's
  aspect-fit rect — bottom-aligned to the picture, not the screen — and are
  re-positioned on every rotation/resize, so subtitles stay on the video in
  portrait, landscape, and after rotating mid-cue.

## 0.0.8

- **Jellyfin / Emby browsing + playback (Android + iPad)** — the home **+** menu's
  new **Jellyfin** entry opens a server list (saved + auto-discovered via mDNS on
  `_jellyfin._tcp` / `_emby._tcp`), libraries → folders → play with direct-play
  streaming (token as `api_key` query param, so no native changes were needed on
  either platform). Add/edit/delete servers with an inline connection test and
  optional sign-in; sessions persist in shared_preferences (no plaintext
  passwords), self-signed HTTPS is an opt-in per server, and a Jellyfin source
  badge shows on Continue-watching cards. Continue-watching taps rebuild the
  stream URL from the stable `jellyfin:<host>/<item>` resume key so rotation of
  the session token between launches never breaks resume playback. Added
  `multicast_dns` + the `CHANGE_WIFI_MULTICAST_STATE` permission (Android) and
  `_jellyfin._tcp`/`_emby._tcp` Bonjour services (iOS) for LAN discovery.
- **Source badges on Continue watching cards** — every card shows where the video
  plays from: WebDAV, CX SMB, Files/SMB, Files, or Network (colored badge,
  bottom-left).
- **iOS "Files" home** — the file browser's root now has a **Files** folder that
  opens the system Files-app home (iCloud Drive, On My iPad, Downloads, other
  providers); pick a video and it plays. The Documents folder and bookmarked
  folders stay listed below it.
- **Stable resume keys for network sources** — CX Explorer SMB handoffs resume by
  their stable path (`cx:` key) and iOS bookmarked-folder files by a remount-safe
  `folderbookmark:` key, so Continue watching keeps working even when the source
  URL rotates between sessions.
- **WebDAV browsing + playback (Android + iPad)** — add/edit/delete servers with an
  inline connection test, browse folders and stream videos straight into the
  player; credentials stored encrypted (Android Keystore / iOS Keychain),
  per-server self-signed HTTPS opt-in (default off), friendly plain-language
  errors.
- **iOS WebDAV folder listing fix** — multistatus XML is now parsed with namespace
  processing, so Apache/nginx/Nextcloud/Synology servers list folders correctly
  (the empty "Nothing here" was a silent parse failure, not an auth problem).
- **Card redesign** — home cards show the gradient/play-icon placeholder plus
  Continue-watching progress and source info (thumbnail extraction removed).

## 0.0.7

- **In-app SMB home entry hidden on all platforms** — NAS playback now goes through
  CX Explorer → "Open with" (Android) and the Files app → "Open with" / bookmarked
  folders (iPad), which cover local + NAS workflows without the audio-track-switch
  crash. The SMB code stays in the tree as a rebuild blueprint.
- Added an SMB/NAS playback tutorial with screenshots and a video walkthrough.

## 0.0.6

- **iPad SMB playback hardened** — SMB streams now load through a read-ahead
  sliding-window reader (`BufferedSMBReader`, 32 MiB) so Wi-Fi latency no longer
  triggers the buffering spinner mid-playback; audio-track switching on SMB
  streams reopens the session with a fresh connection (EPERM fix); AetherEngineSMB
  is linked correctly as a static SPM product.

## 0.0.4

- **iPad in-app SMB playback** via AetherEngineSMB — SMB shares browse and stream
  directly through the engine's custom `IOReader` source (AMSMB2 browse client).

## 0.0.3

- iPad SMB playback fixes — ATS local-network allowance, stream-URL extension +
  content type, and a synchronous connect before returning the URL.

## 0.0.2

- **Android playback via ExoPlayer/Media3** in a native `SurfaceView` PlatformView
  with real Dolby Vision output (`c2.qti.dv.decoder`, verified 4K@60 with zero
  dropped frames) and live HDR/codec/resolution chips.
- **iOS/iPad playback via AetherEngine** (FFmpeg demux/decode + native DV/HDR path)
  behind the same platform-view contract.
- **Subtitles** — embedded + sideloaded (SRT, ASS, WebVTT, TTML, SAMI, MicroDVD,
  MPL2, SubViewer) auto-paired from the video's folder, with a full track picker.
- **Audio track selection** — full track names and channels (e.g. DTS-HD MA 5.1);
  FLAC and E-AC3 work around buggy platform decoders via the bundled FFmpeg
  renderer.
- **In-app file browser** (Android storage / iPad Files folders), **"Open with"**
  integration (including CX Explorer's network-stream handoff), **resume playback**,
  **native refresh rate**, dark theme.
