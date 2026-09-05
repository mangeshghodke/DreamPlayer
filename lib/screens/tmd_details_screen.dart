import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'package:url_launcher/url_launcher.dart';

import '../models/hdr_format.dart';
import '../models/video_item.dart';
import '../services/file_browser.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/media_probe.dart';
import '../services/resume_progress_helper.dart';
import '../services/resume_store.dart';
import '../services/default_engine_store.dart';
import '../services/simkl_client.dart';
import '../services/tmdb_client.dart';
import '../services/watched_store.dart';
import '../utils/codec_info.dart';
import '../utils/file_info_extractor.dart';
import '../utils/season_group.dart' as sg;
import '../widgets/season_progress_ring.dart';
import '../widgets/tv_tile.dart';
import 'folder_screen.dart';
import 'opensubtitles_sheet.dart';
import 'player_screen.dart';

/// Shows TMDB metadata with a Play/Resume button and a "Fix match" manual
/// search.
///
/// In [folder] mode (a library folder, typically a TV-show folder) it shows the
/// show's details with the folder's files below, each episode labelled with its
/// TMDB episode name when the season data is available. Tapping a file opens
/// its own details screen; tapping a subfolder goes into [FolderScreen].
class TmdDetailsScreen extends StatefulWidget {
  const TmdDetailsScreen({
    super.key,
    this.video,
    this.folder,
    this.jellyfinInfo,
    this.parentMetadataKey,
  }) : assert(video != null || folder != null);

  final VideoItem? video;

  /// When set, shows the folder's details + its file list instead of a single
  /// playable video. The folder's name is the TMDB search query.
  final LibraryFolder? folder;

  /// Server-side metadata for a Jellyfin library folder (cached on bookmark,
  /// refreshed here on open) shown when no TMDB match resolves.
  final JellyfinItemInfo? jellyfinInfo;

  /// When set, use this key to look up cached TMDB metadata instead of the
  /// video's own identity key. Used when opening a single episode from a
  /// series folder — the folder's metadata (with correct season/episode data)
  /// is already cached and should be reused.
  final String? parentMetadataKey;

  @override
  State<TmdDetailsScreen> createState() => _TmdDetailsScreenState();
}

class _TmdDetailsScreenState extends State<TmdDetailsScreen> {
  static final _epPattern = RegExp(
      r'\b(?:S\d{1,2}E\d{1,2}|\d{1,2}x\d{1,3}|E(?:P)?\d{1,3})\b|\[(\d{1,3})\]',
      caseSensitive: false);
  late final String _identityKey = widget.parentMetadataKey ??
      widget.folder?.metadataKey ??
      TmdStore.identityKeyFor(widget.video!);
  late final String _resumeKey = widget.folder == null
      ? (widget.video!.resumeKey ?? widget.video!.path ?? widget.video!.uri ?? '')
      : '';
  /// When the video came from a plain file path (no library folder), the
  /// parent folder's name is our only hint for episodes named just
  /// `Episode01.mkv` / `01.mkv`. Pulls the last path segment and decodes
  /// percent-escapes (URL-style SMB paths sometimes carry them).
  String get _parentFolderNameFromPath => _computeParentFolderName();
  late final ParsedFileName _parsed =
      ParsedFileName.parse(widget.folder?.name ?? widget.video!.title);

  String _computeParentFolderName() {
    final path = widget.video!.path ?? widget.video!.uri ?? '';
    if (path.isEmpty) return '';
    // SAF content URIs encode the document path in the last URI segment
    // (e.g. `primary%3ADownload%2FShow.Name%2FEpisode01.mkv`).
    // Decode that segment and extract the parent folder name from it.
    if (path.startsWith('content://')) {
      final decoded = _parentFromContentUri(path);
      return decoded;
    }
    // Strip query / fragment, then trailing slash.
    var clean = path.split('?').first.split('#').first;
    if (clean.endsWith('/')) clean = clean.substring(0, clean.length - 1);
    final lastSlash = clean.lastIndexOf('/');
    if (lastSlash < 0) return '';
    final segment = clean.substring(lastSlash + 1);
    try {
      return Uri.decodeComponent(segment);
    } catch (_) {
      return segment;
    }
  }

  /// Extract parent folder name from a SAF content:// URI.
  /// The document ID is encoded in the last path segment, e.g.
  /// `content://com.android.externalstorage.documents/document/primary%3ADownload%2FShow%2FEpisode01.mkv`
  /// → decoded: `primary:Download/Show/Episode01.mkv` → parent: `Show`.
  static String _parentFromContentUri(String uri) {
    try {
      final parsed = Uri.parse(uri);
      // The document ID is the last path segment.
      final docId = parsed.pathSegments.last;
      final decoded = Uri.decodeComponent(docId);
      // Strip the volume prefix (`primary:`, `treeprimary:` etc.)
      final colonIdx = decoded.indexOf(':');
      final withoutVolume = colonIdx >= 0 ? decoded.substring(colonIdx + 1) : decoded;
      // Get parent folder from the decoded path.
      final parts = withoutVolume.split('/');
      if (parts.length < 2) return '';
      return parts[parts.length - 2];
    } catch (_) {
      return '';
    }
  }
  final TmdService _service = TmdService.instance;

  TmdMeta? _meta;
  TmdDetails? _details;
  bool _loading = true;

  /// Saved playhead for this video per engine.
  Duration? _resumePosition;     // Media3 playhead
  Duration? _resumePositionMpv;  // MPV playhead

  /// Folder mode only: the folder's direct entries (files + subfolders).
  List<FileEntry> _entries = const [];
  String? _folderError;

  /// Jellyfin folder mode only: the server the folder belongs to (matched from
  /// the saved servers) and its children, listed through the API instead of the
  /// file browser.
  final JellyfinClient _jellyfin = JellyfinClient();
  JellyfinServer? _jellyfinServer;
  List<JellyfinItem> _jellyfinEntries = const [];

  /// Server-side metadata for the folder (passed in from home when cached,
  /// refreshed here on open) — shown when no TMDB match resolves.
  JellyfinItemInfo? _jellyfinInfo;

  /// Watched marks and resume positions for per-season progress rings and the
  /// per-episode 2px resume bar.
  Set<String> _watchedKeys = {};
  Map<String, Duration> _positions = {};
  Map<String, int> _durationsMs = {};

  /// Which engine was last used for this video (from LastEngineStore).
  String? _lastEngine;

  /// SIMKL cloud-done backfill (mirrors smb_screen.dart's sync button).
  bool _syncingSimkl = false;

  /// Only for TV-show bookmarked folders — SIMKL backfill is meaningless for a
  /// single movie or a plain file list.
  bool get _enableSimklSync =>
      widget.folder != null &&
      (_meta?.movie.kind == TmdKind.tv) &&
      (_entries.isNotEmpty || _jellyfinEntries.isNotEmpty);

  /// Which seasons are expanded (all true initially).
  final Set<int> _expandedSeasons = {};

  MediaProbeResult? _probe;
  bool _probing = false;
  DefaultEngine _defaultEngine = DefaultEngine.ask;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _jellyfinInfo = widget.jellyfinInfo;
    _load();
    _refreshWatched();
    _loadDefaultEngine();
    if (widget.video != null) {
      _probing = true;
      _probeFile();
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final meta = _service.metaFor(_identityKey);
    setState(() {
      _meta = meta;
      _details = meta?.details;
    });
  }

  Future<void> _refreshWatched() async {
    try {
      final watched = await WatchedStore.load();
      if (mounted) setState(() => _watchedKeys = watched);
      await _refreshPositions();
    } catch (_) {}
  }

  Future<void> _loadDefaultEngine() async {
    try {
      final engine = await DefaultEngineStore.load();
      if (mounted) setState(() => _defaultEngine = engine);
    } catch (_) {}
  }

  Future<void> _refreshPositions() async {
    try {
      final keys = <String>[];
      for (final e in _entries) {
        final k = _watchedKeyForFile(e);
        if (k != null && k.isNotEmpty) keys.add(k);
      }
      for (final i in _jellyfinEntries) {
        final k = _watchedKeyForJellyfin(i);
        if (k != null && k.isNotEmpty) keys.add(k);
      }
      final result = await ResumeProgressHelper.load(keys);
      final map = <String, Duration>{};
      for (final e in result.positions.entries) {
        map[e.key] = Duration(milliseconds: e.value);
      }
      if (mounted) {
        setState(() {
          _positions = map;
          _durationsMs = result.durations;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleWatched(Object entry) async {
    final key = entry is FileEntry
        ? _watchedKeyForFile(entry)
        : _watchedKeyForJellyfin(entry as JellyfinItem);
    if (key == null || key.isEmpty) return;
    final now = !_watchedKeys.contains(key);
    setState(() {
      _watchedKeys = {..._watchedKeys};
      now ? _watchedKeys.add(key) : _watchedKeys.remove(key);
    });
    try {
      await WatchedStore.set(key, now);
    } catch (_) {}
  }

  /// Backfills already-watched shows/movies from SIMKL into the local watched
  /// store for this folder's episodes (mirrors smb_screen.dart's sync button).
  Future<void> _syncFromSimkl() async {
    final client = SimklClient();
    if (!client.isConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SIMKL not configured')),
        );
      }
      return;
    }
    if (!await client.isAuthenticated()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign in to SIMKL first')),
        );
      }
      return;
    }
    setState(() => _syncingSimkl = true);
    try {
      final watched = await client.fetchWatched();
      int marked = 0;
      for (final e in _entries) {
        if (e.isDirectory) continue;
        final key = _watchedKeyForFile(e);
        if (key == null || key.isEmpty || _watchedKeys.contains(key)) continue;
        final meta = _service.metaFor(TmdStore.identityKeyFor(_toVideoItem(e)));
        if (meta == null) continue;
        final id = meta.movie.id;
        final isTv = meta.movie.kind == TmdKind.tv;
        final shouldMark =
            isTv ? watched.showSeasons.containsKey(id) : watched.movieIds.contains(id);
        if (shouldMark) {
          await WatchedStore.set(key, true);
          marked++;
        }
      }
      await _refreshWatched();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              marked > 0
                  ? 'Marked $marked as watched from SIMKL'
                  : 'Nothing new from SIMKL',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('SIMKL sync failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _syncingSimkl = false);
    }
  }

  String? _watchedKeyForFile(FileEntry e) =>
      e.isDirectory ? null : (e.resumeKey ?? e.path);

  String? _watchedKeyForJellyfin(JellyfinItem i) {
    final s = _jellyfinServer;
    if (s == null || i.isFolder) return null;
    return _jellyfin.videoItem(s, i).resumeKey;
  }

  double? _resumeProgressForFile(FileEntry entry) {
    final k = _watchedKeyForFile(entry);
    if (k == null) return null;
    if (_watchedKeys.contains(k)) return 1.0;
    final pos = _positions[k];
    if (pos == null) return null;
    final durMs = _durationsMs[k];
    if (durMs != null && durMs > 0) {
      return (pos.inMilliseconds / durMs).clamp(0.0, 1.0);
    }
    return null;
  }

  double? _resumeProgressForJellyfin(JellyfinItem item) {
    final k = _watchedKeyForJellyfin(item);
    if (k == null) return null;
    if (_watchedKeys.contains(k)) return 1.0;
    final pos = _positions[k];
    if (pos == null) return null;
    final durMs = item.duration.inMilliseconds > 0
        ? item.duration.inMilliseconds
        : _durationsMs[k];
    if (durMs != null && durMs > 0) {
      return (pos.inMilliseconds / durMs).clamp(0.0, 1.0);
    }
    return null;
  }

  Future<void> _probeFile() async {
    final v = widget.video;
    if (v == null) return;
    try {
      // Ensure security-scoped bookmark is active for Files-app bookmarked
      // folders (iOS). No-op on Android.
      if (v.path != null) {
        await FileBrowserService.instance.resolvePath(v.path!);
      }
      final uri = v.uri ?? '';
      MediaProbeResult? r;
      if (uri.startsWith('ftp://') || uri.startsWith('sftp://') || uri.startsWith('ftps://')) {
        // FTP/SFTP: MediaExtractor can't open these URIs directly.
        // Download the first 8 MB to a temp file, probe that, clean up.
        r = await MediaProbe.instance.probeViaTempDownload(uri);
      } else {
        r = await MediaProbe.instance.probe(
          path: v.path,
          uri: v.uri,
          headers: v.httpHeaders,
          allowSelfSigned: v.allowSelfSigned,
        );
      }
      if (!mounted) return;
      setState(() {
        _probe = r;
        _probing = false;
      });
    } catch (_) {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _load() async {
    await _service.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _meta = _service.metaFor(_identityKey);
      _details = _meta?.details;
      _loading = _meta == null;
    });
    _loadResume();
    if (widget.folder != null) {
      await _loadFolderEntries();
      if (!mounted) return;
      // Files are the first priority: whatever the TMDB metadata state (not
      // cached yet, slow lookup, or failed), the folder's file list must be
      // visible. Never hold the full-screen spinner hostage to a metadata
      // fetch — details/seasons enrich the header progressively.
      setState(() => _loading = false);
    }
    // Server-side series info (poster/title/year/overview) for Jellyfin
    // folders — refreshed on open so image URLs carry the current token.
    if (widget.folder?.isJellyfin ?? false) {
      await _refreshJellyfinInfo();
      if (!mounted) return;
    }
    // Auto-resolve TMDB metadata if not cached (Nova-style: every file
    // tap triggers a background lookup so the details page is never blank).
    if (_meta == null && widget.video != null) {
      try {
        await _service.resolve(
          widget.video!,
          parentFolderName: _computeParentFolderName(),
        );
      } catch (_) {
        // Network failure is non-fatal; the "Get Info" button remains.
      }
      if (!mounted) return;
      final resolved = _service.metaFor(_identityKey);
      if (resolved != null) {
        setState(() {
          _meta = resolved;
          _loading = false;
        });
      } else if (mounted) {
        setState(() => _loading = false);
      }
    }
    await _loadDetailsAndSeasons();
  }

  /// Folder mode: load the folder's direct entries so the file list renders.
  Future<void> _loadFolderEntries() async {
    if (widget.folder!.isJellyfin) {
      await _loadJellyfinEntries();
      return;
    }
    try {
      final entries =
          await FileBrowserService.instance.listDirectory(widget.folder!.path);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _folderError = null;
      });
      _refreshWatched();
      // Nova-style: background-resolve TMDB for all video files so metadata
      // is ready when the user taps a file.  Each file resolves independently
      // (no stagger) so the listener fires immediately per file and the tile
      // shows its poster as soon as the TMDB match lands — same as v0.3.8.
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        _service.resolve(_toVideoItem(entry)).catchError((_) {
          return null;
        });
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _folderError = e.message ?? 'Could not list this folder';
      });
    }
  }

  /// Jellyfin folder mode: resolve the folder's saved server (by URL, so the
  /// current token is used) and list its children via the API. Folders first,
  /// then playables, each sorted by name — same ordering as the Jellyfin
  /// browser.
  Future<void> _loadJellyfinEntries() async {
    final folder = widget.folder!;
    try {
      final server =
          await _jellyfin.serverForUrl(folder.jellyfinServerUrl ?? '');
      if (server == null || !server.isAuthenticated) {
        throw const JellyfinException(
          'Jellyfin server is not signed in — open the Jellyfin screen and '
          'sign in first.',
        );
      }
      final items =
          await _jellyfin.getItems(server, folder.jellyfinItemId ?? '');
      if (!mounted) return;
      final folders = items.where((i) => i.isFolder).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final playables = items.where((i) => i.isPlayable).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _jellyfinServer = server;
        _jellyfinEntries = [...folders, ...playables];
        _folderError = null;
      });
      _refreshWatched();
      // Nova-style: background-resolve TMDB for all Jellyfin playables so
      // their tile shows a poster and the opened details screen has per-episode
      // names/ratings/stills ready (mirrors the FileBrowser path above).
      for (final item in playables) {
        final video = _jellyfin.videoItem(server, item);
        _service.resolve(video).catchError((_) {
          return null;
        });
      }
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _folderError = e is JellyfinException
            ? e.message
            : JellyfinClient.friendlyError(e);
      });
    }
  }


  /// Refreshes the folder's server-side metadata (poster/title/year/overview)
  /// from the Jellyfin server. Best-effort: a failure keeps whatever was passed
  /// in from home, and the Jellyfin entries still load regardless.
  Future<void> _refreshJellyfinInfo() async {
    final folder = widget.folder;
    final itemId = folder?.jellyfinItemId;
    if (itemId == null || itemId.isEmpty) return;
    try {
      var server = _jellyfinServer;
      server ??= await _jellyfin.serverForUrl(folder!.jellyfinServerUrl ?? '');
      if (server == null || !server.isAuthenticated) return;
      final info = await _jellyfin.getPrimaryPosterInfo(server, itemId);
      if (info == null || !mounted) return;
      await _jellyfin.saveFolderMeta(folder!.id, info);
      if (mounted) setState(() => _jellyfinInfo = info);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Pulls the full details and the per-episode season data (TV shows only).
  /// Season numbers to fetch come from the files actually present.
  Future<void> _loadDetailsAndSeasons() async {
    final meta = _service.metaFor(_identityKey);
    if (meta == null) return;
    final details = await _service.detailsFor(_identityKey);
    if (mounted) setState(() => _details = details);
    if (meta.movie.kind != TmdKind.tv) return;
    for (final season in _seasonsNeeded()) {
      await _service.seasonFor(_identityKey, season);
      if (!mounted) return;
    }
    // Single episode (video mode, not a folder): enrich it with its own cast
    // and still frames once the season list is loaded.
    // When parentMetadataKey is set (opening from a series folder), use
    // folderSeason from the cached metadata instead of parsed.season.
    final effectiveSeason = widget.parentMetadataKey != null
        ? (meta.folderSeason ?? _parsed.season)
        : _parsed.season;
    if (widget.folder == null &&
        _parsed.isEpisode &&
        effectiveSeason > 0 &&
        _parsed.episode > 0) {
      await _service.episodeDetailsFor(
        _identityKey,
        effectiveSeason,
        _parsed.episode,
      );
      if (!mounted) return;
    }
  }

  /// Which season numbers to fetch per-episode data for. Single episode → its
  /// own season; folder mode → the seasons present in the local file list (or
  /// the Jellyfin item's season numbers).
  List<int> _seasonsNeeded() {
    if (widget.folder != null) {
      if (widget.folder!.isJellyfin) {
        return _jellyfinEntries
            .where((i) => i.isPlayable)
            .map((i) => i.parentIndexNumber ?? 0)
            .where((s) => s > 0)
            .toSet()
            .toList();
      }
      return _entries
          .where((e) => !e.isDirectory)
          .map((e) => ParsedFileName.parse(e.name))
          .where((p) => p.isEpisode)
          .map((p) => p.season)
          .where((s) => s > 0)
          .toSet()
          .toList()
        // When folderSeason is set (from TMDB season-name matching), always
        // fetch that season's data even if parsed seasons are all 0 (anime [01]).
        ..addAll([if (_meta?.folderSeason != null) _meta!.folderSeason!]);
    }
    if (_parsed.isEpisode) {
      // When parentMetadataKey is set (from a series folder with folderSeason),
      // use the folder's season instead of the parsed season (which may be 0
      // for anime [01] numbering).
      final effectiveSeason = widget.parentMetadataKey != null
          ? (_meta?.folderSeason ?? _parsed.season)
          : _parsed.season;
      return [effectiveSeason].where((s) => s > 0).toList();
    }
    return const [];
  }

  /// The TMDB episode matching a local file, or null (movie / no season data).
  TmdEpisode? _episodeFor(FileEntry entry) {
    final parsed = ParsedFileName.parse(entry.name);
    if (!parsed.isEpisode) return null;
    final season = _meta?.folderSeason ?? parsed.season;
    return _meta?.seasons[season]?.episode(parsed.episode);
  }

  /// The TMDB episode matching a Jellyfin playable, or null.
  TmdEpisode? _episodeForItem(JellyfinItem item) {
    final season = item.parentIndexNumber;
    final episode = item.indexNumber;
    if (season == null || episode == null) return null;
    return _meta?.seasons[season]?.episode(episode);
  }

  /// Mirrors the player's resume rules: ignore trivial positions and
  /// "basically finished" ones.
  Future<void> _loadResume() async {
    if (_resumeKey.isEmpty) return;
    final results = await Future.wait([
      ResumeStore.positionFor(_resumeKey, engine: 'media3'),
      ResumeStore.positionFor(_resumeKey, engine: 'mpv'),
      LastEngineStore.load(_resumeKey),
    ]);
    Duration? position = results[0] as Duration?;
    Duration? positionMpv = results[1] as Duration?;
    final lastEngine = results[2] as String?;
    // Filter trivial / near-end positions.
    if (position != null && position < const Duration(seconds: 10)) {
      position = null;
    }
    if (positionMpv != null && positionMpv < const Duration(seconds: 10)) {
      positionMpv = null;
    }
    final video = widget.video;
    if (video != null && video.duration > Duration.zero) {
      if (position != null && video.duration - position < const Duration(seconds: 5)) {
        position = null;
      }
      if (positionMpv != null && video.duration - positionMpv < const Duration(seconds: 5)) {
        positionMpv = null;
      }
    }
    if (mounted && (position != _resumePosition || positionMpv != _resumePositionMpv || lastEngine != _lastEngine)) {
      setState(() {
        _resumePosition = position;
        _resumePositionMpv = positionMpv;
        _lastEngine = lastEngine;
      });
    }
  }

  /// Clears a wrong auto-fetched (or manually pinned) match so the metadata
  /// is dropped everywhere (home cards included) and the screen falls back to
  /// the no-match state, where it can be re-searched or just played.
  Future<void> _removeInfo() async {
    await _service.clear(_identityKey);
    if (!mounted) return;
    setState(() {
      _meta = null;
      _details = null;
      _loading = false;
    });
  }

  Future<void> _fixMatch() async {
    final parsed = ParsedFileName.parse(
      widget.folder?.name ?? widget.video!.title,
      parentFolderName: _parentFolderNameFromPath,
    );
    final picked = await showDialog<TmdMovie>(
      context: context,
      builder: (context) => _SearchDialog(
        initialQuery: parsed.seriesName ?? parsed.title,
        initialYear: parsed.year,
        initialKind: parsed.isEpisode ? TmdKind.tv : TmdKind.movie,
      ),
    );
    if (picked == null || !mounted) return;
    if (widget.folder != null) {
      await _service.setManualFolder(widget.folder!.metadataKey, picked);
    } else {
      await _service.setManual(widget.video!, picked);
    }
    if (!mounted) return;
    final meta = _service.metaFor(_identityKey);
    setState(() => _meta = meta);
    await _loadDetailsAndSeasons();
  }

  Future<void> _play({
    bool fromBeginning = false,
    PlayEngine? engine,
  }) async {
    // When resuming (not from beginning), use the same engine that last
    // played this file — otherwise the resume position (per-engine key)
    // won't be found and playback restarts from the beginning.
    PlayEngine resolved;
    if (engine != null) {
      resolved = engine;
    } else if (!fromBeginning && _lastEngine == 'mpv') {
      resolved = PlayEngine.mpv;
    } else {
      resolved = _defaultEngine == DefaultEngine.mpv
          ? PlayEngine.mpv
          : PlayEngine.media3;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          video: widget.video!,
          startFromBeginning: fromBeginning,
          initialEngine: resolved,
        ),
      ),
    );
    // Wait for the player's orientation restore (landscape → portrait) to
    // settle before triggering a rebuild. Without this delay, _loadResume's
    // setState fires while MediaQuery data is still mid-transition, which
    // can corrupt the Scaffold layout (bottom bar jumps to top) and crash.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    // The playhead may have moved (or the video finished) — refresh the label.
    await _loadResume();
    // Also refresh progress bars for sibling episode tiles.
    await _refreshPositions();
  }

  /// The libmpv engine is Android-only (iOS playback is AetherEngine), so the
  /// "Play with MPV" option only shows on Android — iOS keeps its single Play.
  /// When the user has set a default engine, only the "Ask every time" mode
  /// shows both buttons. Auto mode shows only Media3 (mpv is the silent
  /// fallback if Media3 fails).
  bool get showMpvOption =>
      Platform.isAndroid && _defaultEngine == DefaultEngine.ask;

  /// Suffix shown on the Play button when a specific engine is the default.
  String get _engineSuffix => switch (_defaultEngine) {
        DefaultEngine.auto => '',
        DefaultEngine.media3 => '',
        DefaultEngine.mpv => ' (MPV)',
        DefaultEngine.ask => '',
      };

  /// The secondary engine button: picks libmpv up front, before any Media3
  /// backend is created. mpv runs hardware-first (`hwdec=auto-safe`) and falls
  /// back to its own FFmpeg software decode — a full second main player, not a
  /// fallback. Renders SDR (Flutter texture): no Dolby Vision / HDR there.
  ///
  /// When the user previously played this video via mpv, the button is tinted
  /// and carries the "Resume from m:ss" label so the user knows which engine
  /// holds the saved playhead.
  List<Widget> _mpvButton({required Duration? resume}) {
    final hasResume = resume != null;
    final label = hasResume
        ? 'Resume from ${_formatClock(resume)} (MPV)'
        : 'Play with MPV';
    final icon = const Icon(Icons.video_settings_outlined);
    return [
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: hasResume
                ? FilledButton.icon(
                    onPressed: () => _play(engine: PlayEngine.mpv),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                      foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                    icon: icon,
                    label: Text(label, overflow: TextOverflow.ellipsis),
                  )
                : OutlinedButton.icon(
                    onPressed: () => _play(engine: PlayEngine.mpv),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: icon,
                    label: Text(label, overflow: TextOverflow.ellipsis),
                  ),
          ),
          if (hasResume) ...[
            const SizedBox(width: 12),
            Tooltip(
              message: 'Watch from beginning (MPV)',
              child: FilledButton.tonal(
                onPressed: () => _play(fromBeginning: true, engine: PlayEngine.mpv),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: EdgeInsets.zero,
                ),
                child: const Icon(Icons.replay),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 4),
      const Text(
        'SDR only — no Dolby Vision / HDR (Media3 handles those)',
        style: TextStyle(fontSize: 11, color: Colors.white54),
        textAlign: TextAlign.center,
      ),
    ];
  }

  /// Folder mode: open an entry. Subfolders go into [FolderScreen] (deep
  /// navigation); files open their own details screen. Episodes of the
  /// folder's TV show carry the folder's meta (season data shows instantly);
  /// standalone movies must resolve their own title.
  Future<void> _openFolderEntry(FileEntry entry) async {
    if (entry.isDirectory) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              FolderScreen(folder: widget.folder!, initialPath: entry.path),
        ),
      );
      await _loadFolderEntries();
      await _loadDetailsAndSeasons();
      return;
    }
    final video = _toVideoItem(entry);
    final meta = _service.metaFor(_identityKey);
    final videoKey = TmdStore.identityKeyFor(video);
    final parsed = ParsedFileName.parse(entry.name);
    final isEpisode = parsed.isEpisode || _epPattern.hasMatch(entry.name);
    if (meta != null && isEpisode && meta.movie.kind == TmdKind.tv) {
      try {
        // Carry the folder's full meta (movie + details + seasons) onto the
        // episode's key so its details screen shows the episode's own
        // name/overview/rating instantly — a bare `setManual` would drop the
        // already-loaded season data and force a re-fetch on every tap.
        await _service.carryMeta(_identityKey, videoKey);
      } catch (_) {}
    } else if (meta != null) {
      // A standalone movie must resolve its own title. Drop any folder meta
      // previously carried onto this key (from an older build) so the video's
      // details screen re-searches instead of showing the folder's match.
      final existing = _service.metaFor(videoKey);
      if (existing != null && existing.movie.id == meta.movie.id) {
        try {
          await _service.clear(videoKey);
        } catch (_) {}
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(video: video),
      ),
    );
    await _loadResume();
    await _refreshPositions();
  }

  VideoItem _toVideoItem(FileEntry entry) {
    final isContentUri = entry.path.startsWith('content://');
    final info = extractFileInfo(entry.name);
    return VideoItem(
      id: 'folder_${widget.folder!.id}_${entry.path.hashCode}',
      title: entry.name,
      path: isContentUri ? null : entry.path,
      uri: isContentUri ? entry.path : null,
      resumeKey: entry.resumeKey,
      duration: Duration.zero,
      sizeBytes: entry.size,
      videoCodec: info.videoCodec,
      audioCodec: info.audioCodec,
      audioChannels: info.audioChannels,
      audioLanguage: info.audioLanguage,
      resolution: info.resolution,
      fps: info.fps,
      hdrHint: info.hdrHint,
    );
  }

  /// Jellyfin folder mode: open an entry. Subfolders go into [FolderScreen]
  /// (deep navigation); playables open their own details screen. Episodes of
  /// the folder's show carry the folder's TMDB metadata (season data shows
  /// instantly); standalone movies resolve their own title.
  Future<void> _openJellyfinItem(JellyfinItem item) async {
    final server = _jellyfinServer;
    if (server == null) return;
    if (item.isFolder) {
      final subFolder = LibraryFolder(
        id: '${widget.folder!.id}_${item.id}',
        name: item.name,
        path: 'jellyfin:${item.id}',
        addedAt: widget.folder!.addedAt,
        source: LibraryFolderSource.jellyfin,
        jellyfinServerUrl: server.url,
        jellyfinItemId: item.id,
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FolderScreen(folder: subFolder),
        ),
      );
      await _loadFolderEntries();
      await _loadDetailsAndSeasons();
      return;
    }
    if (!item.isPlayable) return;
    final video = _jellyfin.videoItem(server, item);
    final meta = _service.metaFor(_identityKey);
    final videoKey = TmdStore.identityKeyFor(video);
    final isEpisode = item.type == 'Episode' ||
        (item.parentIndexNumber != null && item.indexNumber != null);
    if (meta != null && isEpisode && meta.movie.kind == TmdKind.tv) {
      try {
        await _service.carryMeta(_identityKey, videoKey);
      } catch (_) {}
    } else if (meta != null) {
      // Standalone movie: drop any folder meta carried onto this key so the
      // video's details screen resolves its own title.
      final existing = _service.metaFor(videoKey);
      if (existing != null && existing.movie.id == meta.movie.id) {
        try {
          await _service.clear(videoKey);
        } catch (_) {}
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(video: video),
      ),
    );
    await _loadResume();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = _meta;
    final title = (meta?.movie.title.isNotEmpty ?? false)
        ? meta!.movie.title
        : (widget.folder?.name ?? widget.video!.title);
    final resume = _resumePosition;       // Media3 playhead
    final resumeMpv = _resumePositionMpv; // MPV playhead
    // Use the resume position from the engine that was last used for this
    // video. When a file was played via mpv fallback, the resume is in mpv
    // but the main button was only checking Media3 — so it showed "Play"
    // instead of "Resume from m:ss".
    final bestResume = _lastEngine == 'mpv' ? (resumeMpv ?? resume) : (resume ?? resumeMpv);
    final hasAnyResume = resume != null || resumeMpv != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (widget.folder != null && (_enableSimklSync))
            IconButton(
              tooltip: 'Mark watched from SIMKL',
              icon: _syncingSimkl
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_done_outlined),
              onPressed: _syncingSimkl ? null : _syncFromSimkl,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(theme, meta),
      bottomNavigationBar: widget.folder == null
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                // Always reachable: a metadata failure (or a slow lookup) must
                // never block playing the video, whatever the metadata state.
                child: hasAnyResume
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (bestResume != null) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: _play,
                                    style: FilledButton.styleFrom(
                                      minimumSize: const Size.fromHeight(52),
                                    ),
                                    icon: const Icon(Icons.play_arrow),
                                    label: Text(
                                      'Resume from ${_formatClock(bestResume)}$_engineSuffix',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Tooltip(
                                  message: 'Watch from beginning',
                                  child: FilledButton.tonal(
                                    onPressed: () =>
                                        _play(fromBeginning: true),
                                    style: FilledButton.styleFrom(
                                      minimumSize: const Size(52, 52),
                                      padding: EdgeInsets.zero,
                                    ),
                                    child: const Icon(Icons.replay),
                                  ),
                                ),
                              ],
                            ),
                          ] else ...[
                            FilledButton.icon(
                              onPressed: _play,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(52),
                              ),
                              icon: const Icon(Icons.play_arrow),
                              label: Text('Play$_engineSuffix'),
                            ),
                          ],
                          if (showMpvOption)
                            ..._mpvButton(resume: resumeMpv),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton.icon(
                            onPressed: _play,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                            ),
                            icon: const Icon(Icons.play_arrow),
                            label: Text('Play$_engineSuffix'),
                          ),
                          if (showMpvOption) ..._mpvButton(resume: null),
                        ],
                      ),
              ),
            )
          : null,
    );
  }

  static String _formatClock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// "2024-03-17" → "Mar 17, 2024"; falls back to the raw value.
  static String _formatAirDate(String iso) {
    final parts = iso.split('-');
    if (parts.length != 3) return iso;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return iso;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    if (month < 1 || month > 12) return iso;
    return '${months[month - 1]} $day, $year';
  }

  /// The header banner box: full-width 16:9 in portrait; in landscape a
  /// centered 16:9 box capped small. A full-width strip in landscape would
  /// have to `cover`-crop a 16:9 artwork down to a thin zoomed band, so the
  /// image is instead shown whole, at the small height.
  Widget _buildBody(ThemeData theme, TmdMeta? meta) {
    if (meta == null) {
      if (widget.folder != null) return _buildFolderWithoutMatch(theme);
      return _buildNoMatch(theme);
    }
    final movie = meta.movie;
    final details = _details;
    final colorScheme = theme.colorScheme;
    final effectiveSeason = widget.parentMetadataKey != null
        ? (meta.folderSeason ?? _parsed.season)
        : _parsed.season;
    final singleEpisode = _parsed.isEpisode && widget.folder == null
        ? meta.seasons[effectiveSeason]?.episode(_parsed.episode)
        : null;
    final episodeAirDate = singleEpisode?.airDate;
    final episodeOverview =
        (singleEpisode?.overview.isNotEmpty ?? false) ? singleEpisode!.overview : null;
    // Build episode label using effectiveSeason instead of parsed season (which
    // may be 0 for anime [01] bracket numbering).
    final effectiveEpisodeLabel = _parsed.isEpisode
        ? 'S${effectiveSeason.toString().padLeft(2, '0')}E${_parsed.episode.toString().padLeft(2, '0')}'
        : '';

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: movie.posterUrl(width: 342) != null
                          ? Image.network(
                              movie.posterUrl(width: 342)!,
                              width: 104,
                              height: 156,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  _posterFallback(colorScheme),
                            )
                          : _posterFallback(colorScheme),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_parsed.isEpisode && singleEpisode != null) ...[
                            Text(
                              movie.title,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    effectiveEpisodeLabel,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color:
                                          colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    singleEpisode.nameLabel,
                                    style:
                                        theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            if (_meta?.seasons[effectiveSeason]?.name
                                    .isNotEmpty ??
                                false)
                              Text(
                                _meta!.seasons[effectiveSeason]!.name,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ] else ...[
                            if (movie.title.isNotEmpty)
                              Text(
                                movie.title,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if (movie.year != null)
                              Text(
                                '${movie.year}',
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            const SizedBox(height: 4),
                            _RatingBadge(
                              rating: singleEpisode != null && singleEpisode.voteAverage > 0
                                  ? singleEpisode.voteAverage
                                  : movie.voteAverage,
                            ),
                          ],
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (singleEpisode?.runtimeMinutes != null)
                                _FactChip(
                                  icon: Icons.schedule,
                                  label:
                                      '${singleEpisode!.runtimeMinutes} min',
                                ),
                              if (episodeAirDate != null)
                                _FactChip(
                                  icon: Icons.calendar_today,
                                  label: _formatAirDate(episodeAirDate),
                                ),
                              if (widget.folder == null &&
                                  singleEpisode == null &&
                                  details?.runtimeMinutes != null)
                                _FactChip(
                                  icon: Icons.schedule,
                                  label:
                                      '${details!.runtimeMinutes} min',
                                ),
                              if (details?.genres != null)
                                for (final genre in details!.genres)
                                  _FactChip(label: genre),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            details?.tagline ?? '',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  singleEpisode != null ? 'Episode overview' : 'Overview',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  episodeOverview ?? (details?.overview ?? movie.overview),
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                ),

                // ── Cast row (Nova-style) ──
                if (details != null && details.cast.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _CastRow(cast: details.cast),
                ],
                // Per-episode guest stars (when viewing a single episode)
                if (singleEpisode != null &&
                    (singleEpisode.cast.isNotEmpty ||
                        singleEpisode.guestStars.isNotEmpty)) ...[
                  const SizedBox(height: 20),
                  _CastRow(
                    cast: singleEpisode.guestStars.isNotEmpty
                        ? singleEpisode.guestStars
                        : singleEpisode.cast,
                    title: singleEpisode.guestStars.isNotEmpty
                        ? 'Guest stars'
                        : 'Episode cast',
                  ),
                ],

                // ── Stills gallery (Nova-style, single episode only) ──
                if (singleEpisode != null && singleEpisode.stills.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _StillsGallery(stills: singleEpisode.stillUrls()),
                ],

                // ── File info card (Nova-style) ──
                if (widget.video != null) ...[
                  const SizedBox(height: 20),
                  _FileInfoCard(video: widget.video!, probe: _probe, probing: _probing),
                ],

                // ── Subtitles card ──
                if (widget.video != null) ...[
                  const SizedBox(height: 16),
                  _SubtitlesCard(video: widget.video!),
                ],

                // ── Trailers card (Nova-style) ──
                if (details != null && details.trailers.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _TrailersCard(trailers: details.trailers),
                ],

                // ── Fix match / Remove info ──
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: _fixMatch,
                      child: const Text('Fix match'),
                    ),
                    TextButton(
                      onPressed: _removeInfo,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: const Text('Remove info'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
        if (widget.folder != null) ..._entriesSlivers(theme),
      ],
    );
  }

  /// The folder's file list as slivers (episode files labelled with their TMDB
  /// episode name when the season data is loaded). Episodes are grouped by
  /// season with a collapsible header per season showing a progress ring.
  List<Widget> _entriesSlivers(ThemeData theme) {
    if (widget.folder!.isJellyfin) return _jellyfinEntriesSlivers(theme);
    final colorScheme = theme.colorScheme;
    if (_entries.isEmpty) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Text(
                  'Episodes',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _folderError ?? 'No videos or folders here',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.error,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ];
    }
    final folders = _entries.where((e) => e.isDirectory).toList();
    final videos = _entries.where((e) => !e.isDirectory).toList();
    // Recognize both SxxExx and E01/EP01 patterns as episodes.
    final episodes = videos
        .where((e) =>
            ParsedFileName.parse(e.name).isEpisode ||
            _epPattern.hasMatch(e.name))
        .toList();
    final movies = videos
        .where((e) =>
            !ParsedFileName.parse(e.name).isEpisode &&
            !_epPattern.hasMatch(e.name))
        .toList();
    final seasonGroups = sg.groupBySeason<FileEntry>(
      episodes,
      (e) => _meta?.folderSeason ?? ParsedFileName.parse(e.name).season,
      (e) => ParsedFileName.parse(e.name).episode,
    );
    final sortedSeasons = seasonGroups.keys.toList()..sort();

    Widget entryTile(FileEntry e) => _FolderEntryTile(
          entry: e,
          episode: _episodeFor(e),
          tmdbMeta: _service.metaFor(
            TmdStore.identityKeyFor(_toVideoItem(e)),
          ),
          resumeProgress: _resumeProgressForFile(e),
          folderSeason: _meta?.folderSeason,
          watched: _watchedKeys.contains(_watchedKeyForFile(e)),
          onToggleWatched: e.isDirectory ? null : () => _toggleWatched(e),
          onTap: () => _openFolderEntry(e),
        );

    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Text(
                'Episodes',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                _fileCountLabel(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      if (folders.isNotEmpty)
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final entry = folders[index];
              return _FolderEntryTile(
                entry: entry,
                episode: null,
                tmdbMeta: null,
                onTap: () => _openFolderEntry(entry),
              );
            },
            childCount: folders.length,
          ),
        ),
      for (final s in sortedSeasons)
        SliverToBoxAdapter(
          child: _SeasonExpansion<FileEntry>(
            season: s,
            entries: seasonGroups[s]!,
            watchedKeys: _watchedKeys,
            keyOf: _watchedKeyForFile,
            expanded: _expandedSeasons.isEmpty || _expandedSeasons.contains(s),
            onExpansionChanged: (expanded) {
              setState(() {
                if (expanded) {
                  _expandedSeasons.add(s);
                } else {
                  _expandedSeasons.remove(s);
                }
              });
            },
            tileBuilder: entryTile,
            seasonName: _meta?.seasons[s]?.name,
          ),
        ),
      if (movies.isNotEmpty)
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => entryTile(movies[index]),
            childCount: movies.length,
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
  }

  /// The Jellyfin folder's item list as slivers (playables labelled with their
  /// Jellyfin season number + TMDB episode name when matched).
  List<Widget> _jellyfinEntriesSlivers(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    if (_jellyfinEntries.isEmpty) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Text(
                  'Episodes',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _folderError ?? 'No videos or folders here',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.error,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ];
    }
    final folders = _jellyfinEntries.where((i) => i.isFolder).toList();
    final playables = _jellyfinEntries.where((i) => i.isPlayable).toList();
    final episodes = playables
        .where((i) => i.parentIndexNumber != null && i.indexNumber != null)
        .toList();
    final movies = playables
        .where((i) => i.parentIndexNumber == null || i.indexNumber == null)
        .toList();
    final seasonGroups = sg.groupBySeason<JellyfinItem>(
      episodes,
      (e) => e.parentIndexNumber ?? 0,
      (e) => e.indexNumber ?? 0,
    );
    final sortedSeasons = seasonGroups.keys.toList()..sort();

    Widget itemTile(JellyfinItem item) {
      final server = _jellyfinServer;
      return _JellyfinEntryTile(
        item: item,
        episode: _episodeForItem(item),
        tmdbMeta: item.isFolder || server == null
            ? null
            : _service.metaFor(
                TmdStore.identityKeyFor(_jellyfin.videoItem(server, item)),
              ),
        resumeProgress: _resumeProgressForJellyfin(item),
        watched: _watchedKeys.contains(_watchedKeyForJellyfin(item)),
        onToggleWatched:
            item.isFolder ? null : () => _toggleWatched(item),
        onTap: () => _openJellyfinItem(item),
      );
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Text(
                'Episodes',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                _jellyfinFileCountLabel(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      if (folders.isNotEmpty)
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final item = folders[index];
              return _JellyfinEntryTile(
                item: item,
                episode: null,
                tmdbMeta: null,
                onTap: () => _openJellyfinItem(item),
              );
            },
            childCount: folders.length,
          ),
        ),
      for (final s in sortedSeasons)
        SliverToBoxAdapter(
          child: _SeasonExpansion<JellyfinItem>(
            season: s,
            entries: seasonGroups[s]!,
            watchedKeys: _watchedKeys,
            keyOf: _watchedKeyForJellyfin,
            expanded: _expandedSeasons.isEmpty || _expandedSeasons.contains(s),
            onExpansionChanged: (expanded) {
              setState(() {
                if (expanded) {
                  _expandedSeasons.add(s);
                } else {
                  _expandedSeasons.remove(s);
                }
              });
            },
            tileBuilder: itemTile,
            seasonName: _meta?.seasons[s]?.name,
          ),
        ),
      if (movies.isNotEmpty)
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => itemTile(movies[index]),
            childCount: movies.length,
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
  }

  String _jellyfinFileCountLabel() {
    final files = _jellyfinEntries.where((i) => i.isPlayable).length;
    return files == 1 ? '1 file' : '$files files';
  }

  String _fileCountLabel() {
    final files = _entries.where((e) => !e.isDirectory).length;
    return files == 1 ? '1 file' : '$files files';
  }

  /// Folder mode without a TMDB match: still show the files so playback is
  /// never blocked, with a "Find on TMDB" escape hatch. Jellyfin folders show
  /// the series' server-side info (backdrop/poster/title/year/rating/genres/
  /// overview) instead of a bare title row.
  Widget _buildFolderWithoutMatch(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final info = _jellyfinInfo;
    return CustomScrollView(
      slivers: [
        if (info != null && info.name.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: info.imageUrl != null
                            ? Image.network(
                                info.imageUrl!,
                                width: 104,
                                height: 156,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    _posterFallback(colorScheme),
                              )
                            : _posterFallback(colorScheme),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              info.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (info.year != null)
                              Text(
                                '${info.year}',
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            const SizedBox(height: 4),
                            _RatingBadge(rating: info.communityRating),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                if (info.kindLabel.isNotEmpty)
                                  _FactChip(label: info.kindLabel),
                                if (info.durationLabel.isNotEmpty)
                                  _FactChip(
                                    icon: Icons.schedule,
                                    label: info.durationLabel,
                                  ),
                                for (final genre in info.genres)
                                  _FactChip(label: genre),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (info.overview.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Overview',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      info.overview,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const Spacer(),
                      TextButton(
                        onPressed: _fixMatch,
                        child: const Text('Find on TMDB'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ] else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '"${widget.folder!.name}"',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _fixMatch,
                    child: const Text('Find on TMDB'),
                  ),
                ],
              ),
            ),
          ),
        ..._entriesSlivers(theme),
      ],
    );
  }

  Widget _buildNoMatch(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final fileName = widget.video?.title ?? widget.folder?.name ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Icon(
            Icons.movie_filter_outlined,
            size: 64,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 16),
          Text(
            fileName,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'No metadata loaded',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _fixMatch,
            icon: const Icon(Icons.info_outline),
            label: const Text('Get Info'),
          ),
            if (widget.video != null) ...[
              const SizedBox(height: 24),
              _FileInfoCard(video: widget.video!, probe: _probe, probing: _probing),
              const SizedBox(height: 12),
              _SubtitlesCard(video: widget.video!),
            ],
        ],
      ),
    );
  }

  Widget _posterFallback(ColorScheme colorScheme) {
    return Container(
      width: 104,
      height: 156,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(Icons.movie, color: colorScheme.onSurfaceVariant),
    );
  }
}

class _RatingBadge extends StatelessWidget {
  const _RatingBadge({required this.rating});

  final double rating;

  @override
  Widget build(BuildContext context) {
    if (rating <= 0) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 14, color: Colors.amber),
          const SizedBox(width: 4),
          Text(
            rating.toStringAsFixed(1),
            style: TextStyle(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _FactChip extends StatelessWidget {
  const _FactChip({this.icon, required this.label});

  final IconData? icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Nova-style file info card — shows every technical detail of the file,
/// just as Nova Video Player does. Wired for **all** sources (local,
/// SMB/WebDAV/FTP/UPnP/Jellyfin): name, location (smb:// / file:// /
/// https://), duration, size, video codec · resolution · fps · HDR, and
/// audio codec · channels · language.
///
/// When [probe] is available (native MediaExtractor probe of the file
/// header), its values override the filename-derived ones — exactly how
/// Nova probes the container instead of parsing the filename.
class _FileInfoCard extends StatelessWidget {
  const _FileInfoCard({required this.video, this.probe, this.probing = false});
  final VideoItem video;
  final MediaProbeResult? probe;
  final bool probing;

  String _displayLocation(VideoItem v) {
    // Prefer the human-readable path (local absolute or smb:// share/path).
    // For SMB bookmarks the playable uri is a temp http://127.0.0.1 loopback —
    // never show that; derive from resumeKey instead.
    final p = v.path ?? '';
    final u = v.uri ?? '';
    final k = v.resumeKey ?? '';
    // Filter out temp loopback URLs
    bool isLoopback(String s) => s.contains('127.0.0.1') || s.contains('localhost');
    // Decode URL-encoded content:// URIs to show clean paths
    String decodeContentUri(String uri) {
      if (!uri.startsWith('content://')) return uri;
      // Extract the document ID and decode it (e.g. primary%3AMovies%2Ffile.mkv → primary:Movies/file.mkv)
      try {
        final docId = Uri.decodeComponent(uri.split('/document/').lastOrNull ?? '');
        // Map Android storage IDs to real paths
        if (docId.startsWith('primary:')) {
          return '/storage/emulated/0/${docId.substring(8)}';
        }
        if (docId.startsWith('secondary:')) {
          return '/storage/sdcard1/${docId.substring(9)}';
        }
        // Other providers: show the decoded ID
        return docId;
      } catch (_) {
        return uri;
      }
    }
    if (p.isNotEmpty && !isLoopback(p)) {
      return p.startsWith('content://') ? decodeContentUri(p) : p;
    }
    if (u.isNotEmpty && !isLoopback(u)) {
      return u.startsWith('content://') ? decodeContentUri(u) : u;
    }
    // Fallback to resumeKey formatting (stable, shows share/path for network)
    if (k.startsWith('smb:') || k.startsWith('smb_')) {
      final rest = k.replaceFirst(RegExp(r'^smb[:_]'), '');
      // rest is like "serverId/share/path" or "share/path" — show share/path
      final parts = rest.split('/');
      if (parts.length >= 2) {
        // drop serverId if it looks like uuid/server host
        final share = parts[1];
        final filePath = parts.skip(2).join('/');
        return filePath.isEmpty ? 'smb://$share' : 'smb://$share/$filePath';
      }
      return 'smb://$rest';
    }
    if (k.startsWith('webdav_')) return k.replaceFirst('webdav_', 'webdav://');
    if (k.startsWith('ftp_')) return k.replaceFirst('ftp_', 'ftp://');
    if (k.startsWith('folderbookmark:')) return k;
    if (p.isNotEmpty) return p;
    if (u.isNotEmpty) return u;
    return k;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hdrFormat = video.hdrFormat;
    // Prefer probed values (real container) over filename-derived ones
    final videoCodec = (probe?.videoMime != null ? formatVideoCodec(probe!.videoMime) : null) ?? video.videoCodecLabel;
    final audioCodecRaw = probe?.audioMime ?? video.audioCodec;
    final audioCodec = audioCodecRaw;
    final audioChannels = probe?.audioChannels != null ? '${probe!.audioChannels} ch' : video.audioChannels;
    final audioLanguage = probe?.audioLanguage ?? video.audioLanguage;
    final resolution = probe?.resolutionLabel ?? video.resolution;
    final fps = probe?.fps ?? video.fps;
    // Duration from probe beats the zero before playback
    final duration = (probe?.durationMs != null && probe!.durationMs! > 0) ? Duration(milliseconds: probe!.durationMs!) : video.duration;
    final sizeBytes = video.sizeBytes;
    final location = _displayLocation(video);

    // Build info rows
    final rows = <Widget>[];

    // HDR format badge (Nova-style)
    if (hdrFormat != HdrFormat.sdr) {
      rows.add(_HdrBadge(format: hdrFormat));
      rows.add(const SizedBox(height: 8));
    }

    // File name — always show (Nova header for file info)
    rows.add(_InfoRow(icon: Icons.description_outlined, label: video.title));

    // Location — Nova shows the full SMB / file path under the file info.
    // All sources wire the same card: local absolute, smb://share/…, https://
    // webdav, ftp://, content://, jellyfin server path via resumeKey fallback.
    if (location.isNotEmpty) {
      rows.add(_InfoRow(icon: Icons.folder_open, label: location));
    }

    // Duration (when known — via probe for local/http like Nova, else after playback)
    if (duration > Duration.zero) {
      final label = Duration(milliseconds: duration.inMilliseconds).inHours > 0
          ? '${duration.inHours}:${(duration.inMinutes % 60).toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}'
          : '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
      rows.add(_InfoRow(icon: Icons.schedule, label: label));
    }

    // File size
    if (sizeBytes != null && sizeBytes > 0) {
      rows.add(_InfoRow(
        icon: Icons.storage,
        label: _formatFileSize(sizeBytes),
      ));
    }

    // Video: codec · resolution · fps · HDR already as badge, but also as text
    final videoParts = <String>[];
    if (videoCodec != null && videoCodec.isNotEmpty) videoParts.add(videoCodec);
    if (resolution != null && resolution.isNotEmpty) videoParts.add(resolution);
    if (fps != null && fps > 0) videoParts.add('$fps fps');
    final videoInfo = videoParts.join('  ·  ');
    if (videoInfo.isNotEmpty) {
      rows.add(_InfoRow(icon: Icons.videocam, label: videoInfo));
    }

    // Audio: codec · channels · language (Nova lists each track; we show the
    // primary filename-derived track for all shares — local/SMB/WebDAV/FTP/UPnP).
    if (audioCodec != null && audioCodec.isNotEmpty) {
      final formatted = formatAudioCodec(audioCodec);
      final parts = <String>[formatted];
      if (audioChannels != null && audioChannels.isNotEmpty) {
        parts.add(audioChannels);
      }
      if (audioLanguage != null && audioLanguage.isNotEmpty) {
        parts.add(audioLanguage);
      }
      rows.add(_InfoRow(icon: Icons.audiotrack, label: parts.join('  ·  ')));
    } else if (audioLanguage != null && audioLanguage.isNotEmpty) {
      rows.add(_InfoRow(icon: Icons.audiotrack, label: audioLanguage));
    } else if (audioChannels != null && audioChannels.isNotEmpty) {
      rows.add(_InfoRow(icon: Icons.audiotrack, label: audioChannels));
    }

    if (rows.isEmpty && !probing) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'File info',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            ...rows,
            if (probing && probe == null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Probing file…',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// Nova-style HDR format badge with color coding.
class _HdrBadge extends StatelessWidget {
  const _HdrBadge({required this.format});
  final HdrFormat format;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon) = switch (format) {
      HdrFormat.dolbyVision => (
          const Color(0xFF6B2FA0),
          Icons.movie,
        ),
      HdrFormat.hdr10plus => (
          const Color(0xFFE6A817),
          Icons.brightness_high,
        ),
      HdrFormat.hdr10 => (
          const Color(0xFFE6A817),
          Icons.brightness_high,
        ),
      HdrFormat.hlg => (
          const Color(0xFF4CAF50),
          Icons.wb_sunny,
        ),
      HdrFormat.sdr => (
          theme.colorScheme.surfaceContainerHighest,
          Icons.tv,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            format.label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Nova-style subtitles card with OpenSubtitles search button.
class _SubtitlesCard extends StatelessWidget {
  const _SubtitlesCard({required this.video});
  final VideoItem video;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Subtitles',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.subtitles),
              title: const Text('Search subtitles online'),
              subtitle: const Text('OpenSubtitles'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openSubtitleSearch(context),
            ),
          ],
        ),
      ),
    );
  }

  void _openSubtitleSearch(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => OpensubtitlesSheet(
        initialQuery: video.title,
        filePath: video.path,
        resumeKey: video.resumeKey,
      ),
    );
  }
}

/// Nova-style trailers card — YouTube links.
class _TrailersCard extends StatelessWidget {
  const _TrailersCard({required this.trailers});
  final List<TmdTrailer> trailers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Trailers',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            for (final trailer in trailers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.play_circle_outline, color: Colors.red),
                title: Text(trailer.name),
                subtitle: const Text('YouTube'),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _launchTrailer(context, trailer),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchTrailer(BuildContext context, TmdTrailer trailer) async {
    final url = trailer.youtubeUrl;
    if (url == null) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

/// Horizontal scrollable cast row (Nova-style) showing actor photos, names,
/// and character names.
class _CastRow extends StatelessWidget {
  const _CastRow({required this.cast, this.title = 'Cast'});
  final List<TmdCastMember> cast;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 130,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cast.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final member = cast[index];
              return SizedBox(
                width: 80,
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(40),
                      child: member.profileUrl() != null
                          ? Image.network(
                              member.profileUrl()!,
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => _avatarFallback(
                                  theme.colorScheme, member.name),
                            )
                          : _avatarFallback(theme.colorScheme, member.name),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      member.name,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    if (member.character != null &&
                        member.character!.isNotEmpty)
                      Text(
                        member.character!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 10,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static Widget _avatarFallback(ColorScheme colorScheme, String name) {
    final initial =
        name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 72,
      height: 72,
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Horizontal scrollable stills gallery (Nova-style) for episode detail views.
class _StillsGallery extends StatelessWidget {
  const _StillsGallery({required this.stills});
  final List<String> stills;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Stills',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 120,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: stills.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  stills[index],
                  height: 120,
                  width: 213, // 16:9 aspect
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    height: 120,
                    width: 213,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.broken_image,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Single info row for the file info card.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapsible season section with a progress ring header.
class _SeasonExpansion<T> extends StatelessWidget {
  const _SeasonExpansion({
    required this.season,
    required this.entries,
    required this.watchedKeys,
    required this.keyOf,
    required this.expanded,
    required this.onExpansionChanged,
    required this.tileBuilder,
    this.seasonName,
  });

  final int season;
  final List<T> entries;
  final Set<String> watchedKeys;
  final String? Function(T) keyOf;
  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;
  final Widget Function(T) tileBuilder;

  /// Full season name from TMDB (e.g. "Season 2: The One Where...").
  final String? seasonName;

  @override
  Widget build(BuildContext context) {
    final watched = sg.watchedCount(entries, watchedKeys, keyOf);
    final total = entries.length;
    final colorScheme = Theme.of(context).colorScheme;
    // Show "Season 2: The One Where..." when a name is available,
    // falling back to the generic "Season 2" header.
    final headerLabel = (seasonName != null && seasonName!.isNotEmpty)
        ? '${sg.seasonHeader(season)} · $seasonName'
        : sg.seasonHeader(season);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        onExpansionChanged: onExpansionChanged,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        childrenPadding: EdgeInsets.zero,
        title: Row(
          children: [
            Flexible(
              child: Text(
                headerLabel,
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            SeasonProgressRing(watched: watched, total: total, size: 28, strokeWidth: 2.5),
            const SizedBox(width: 6),
            Text(
              sg.watchedBadge(watched, total),
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        children: [for (final e in entries) tileBuilder(e)],
      ),
    );
  }
}

/// A folder file/subfolder tile for the details screen's episode list.
class _FolderEntryTile extends StatelessWidget {
  const _FolderEntryTile({
    required this.entry,
    required this.episode,
    required this.tmdbMeta,
    required this.onTap,
    this.resumeProgress,
    this.folderSeason,
    this.watched = false,
    this.onToggleWatched,
  });

  final FileEntry entry;
  final TmdEpisode? episode;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
  final double? resumeProgress;
  final int? folderSeason;
  final bool watched;
  final VoidCallback? onToggleWatched;

  static String _sizeLabel(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (entry.isDirectory) {
      return TvTile(
        leading: Icon(Icons.folder, color: colorScheme.primary),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
    }

    final parsed = ParsedFileName.parse(entry.name);
    final effectiveSeason = folderSeason ?? parsed.season;
    final effectiveLabel = parsed.isEpisode
        ? 'S${effectiveSeason.toString().padLeft(2, '0')}E${parsed.episode.toString().padLeft(2, '0')}'
        : '';

    // Prefer per-episode still thumbnail over series poster (Nova-style).
    final stillUrl = episode?.stillUrl();
    final posterUrl = stillUrl ?? posterUrlOf(tmdbMeta);

    // The RAW filename (e.g. House.S02E05.1080p...mkv) shown subdued on its
    // own line — the title row leads with the SxxEyy badge + episode name so
    // the list reads cleanly instead of shouting the full filename.
    final filenameWidget = Text(
      entry.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
    );

    final titleWidget = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (episode != null && episode!.name.isNotEmpty) ...[
          if (parsed.isEpisode) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                effectiveLabel,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onPrimaryContainer,
                    ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              episode!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
        ] else
          Expanded(
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
        if (episode != null && episode!.voteAverage > 0) ...[
          const SizedBox(width: 6),
          const Icon(Icons.star, size: 13, color: Colors.amber),
          const SizedBox(width: 2),
          Text(
            episode!.voteAverage.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );

    final subtitleWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        filenameWidget,
        if (_sizeLabel(entry.size).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _sizeLabel(entry.size),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        if (resumeProgress != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(1),
              child: LinearProgressIndicator(
                value: resumeProgress,
                minHeight: 2,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            ),
          ),
      ],
    );

    return TvTile(
      leading: posterUrl != null
          ? _Poster(posterUrl: posterUrl)
          : Icon(
              parsed.isEpisode ? Icons.movie_outlined : Icons.play_circle_outline,
              color: colorScheme.secondary,
            ),
      title: titleWidget,
      subtitle: subtitleWidget,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onToggleWatched != null)
            IconButton(
              tooltip: watched ? 'Mark as unwatched' : 'Mark as watched',
              icon: Icon(
                watched ? Icons.check_circle : Icons.check_circle_outline,
                color: watched
                    ? Colors.green.shade400
                    : colorScheme.onSurfaceVariant,
              ),
              onPressed: onToggleWatched,
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// A Jellyfin folder/playable tile for the details screen's episode list.
class _JellyfinEntryTile extends StatelessWidget {
  const _JellyfinEntryTile({
    required this.item,
    required this.episode,
    required this.tmdbMeta,
    required this.onTap,
    this.resumeProgress,
    this.watched = false,
    this.onToggleWatched,
  });

  final JellyfinItem item;
  final TmdEpisode? episode;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
  final double? resumeProgress;
  final bool watched;
  final VoidCallback? onToggleWatched;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (item.isFolder) {
      return TvTile(
        leading: Icon(Icons.folder, color: colorScheme.primary),
        title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
    }

    final subtitle = <String>[
      if (item.seasonLabel.isNotEmpty) item.seasonLabel,
      if (episode != null) episode!.nameLabel,
      if (item.sizeLabel.isNotEmpty) item.sizeLabel,
    ].where((s) => s.isNotEmpty).join(' · ');

    // Prefer per-episode still thumbnail over series poster (Nova-style).
    final stillUrl = episode?.stillUrl();
    final posterUrl = stillUrl ?? posterUrlOf(tmdbMeta);

    final subtitleWidget = subtitle.isEmpty && resumeProgress == null
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Show episode name on its own line when available (Nova-style).
              if (episode != null && episode!.name.isNotEmpty)
                Text(
                  episode!.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              if (subtitle.isNotEmpty)
                Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (resumeProgress != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(1),
                    child: LinearProgressIndicator(
                      value: resumeProgress,
                      minHeight: 2,
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                    ),
                  ),
                ),
            ],
          );

    return TvTile(
      leading: posterUrl != null
          ? _Poster(posterUrl: posterUrl)
          : Icon(
              item.seasonLabel.isNotEmpty
                  ? Icons.movie_outlined
                  : Icons.play_circle_outline,
              color: colorScheme.secondary,
            ),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitleWidget,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onToggleWatched != null)
            IconButton(
              tooltip: watched ? 'Mark as unwatched' : 'Mark as watched',
              icon: Icon(
                watched ? Icons.check_circle : Icons.check_circle_outline,
                color: watched
                    ? Colors.green.shade400
                    : colorScheme.onSurfaceVariant,
              ),
              onPressed: onToggleWatched,
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// A small 48×72 rounded poster thumbnail for a file row.
class _Poster extends StatelessWidget {
  const _Poster({required this.posterUrl});

  final String posterUrl;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        posterUrl,
        width: 48,
        height: 72,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Icon(
          Icons.play_circle_outline,
          color: Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
  }
}

/// Manual search dialog for picking the right TMDB entry.
class _SearchDialog extends StatefulWidget {
  const _SearchDialog({this.initialQuery, this.initialYear, this.initialKind});

  final String? initialQuery;
  final int? initialYear;
  final TmdKind? initialKind;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _controller = TextEditingController();
  final _api = TmdApi();

  List<TmdMovie>? _results;
  bool _searching = false;
  bool _noKey = false;
  String? _error;
  late TmdKind _kind;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery ?? '';
    _kind = widget.initialKind ?? TmdKind.movie;
    // Auto-search on open when there's an initial query (Nova-style: the
    // dialog immediately shows matching results without requiring Enter).
    if (_controller.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    final key = await _api.effectiveApiKey();
    if (!mounted) return;
    if (key.isEmpty) {
      setState(() {
        _searching = false;
        _results = null;
        _noKey = true;
      });
      return;
    }
    setState(() {
      _searching = true;
      _results = null;
      _error = null;
      _noKey = false;
    });
    try {
      // Search the selected kind first, then the other as fallback.
      final primary = await _api.search(
        query,
        year: widget.initialYear,
        kind: _kind,
      );
      final fallbackKind = _kind == TmdKind.tv ? TmdKind.movie : TmdKind.tv;
      final fallback = await _api.search(query, kind: fallbackKind);
      final results = <TmdMovie>[...primary, ...fallback];
      final seen = <int>{};
      results.removeWhere((m) => !seen.add(m.id));
      if (!mounted) return;
      setState(() => _results = results);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('Get Info'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(
                hintText: 'Search title',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            // Kind toggle: TV or Movie
            SegmentedButton<TmdKind>(
              segments: const [
                ButtonSegment(value: TmdKind.tv, label: Text('TV Series')),
                ButtonSegment(value: TmdKind.movie, label: Text('Movie')),
              ],
              selected: {_kind},
              onSelectionChanged: (sel) => setState(() => _kind = sel.first),
            ),
            const SizedBox(height: 8),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_noKey)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Search is unavailable right now. Try again in a moment.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Search failed. Try again in a moment.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.error),
                ),
              )
            else if (_results != null)
              if (_results!.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No results. Try a different title.'),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _results!.length,
                    itemBuilder: (context, index) {
                      final movie = _results![index];
                      return ListTile(
                        leading: movie.posterUrl(width: 92) != null
                            ? Image.network(
                                movie.posterUrl(width: 92)!,
                                width: 36,
                                height: 54,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.movie),
                              )
                            : const Icon(Icons.movie),
                        title: Text(movie.title),
                        subtitle: Text(
                          [
                            if (movie.kind == TmdKind.tv) 'TV Series',
                            if (movie.year != null) '${movie.year}',
                            if (movie.voteAverage > 0)
                              movie.voteAverage.toStringAsFixed(1),
                          ].join('  ·  '),
                        ),
                        onTap: () => Navigator.of(context).pop(movie),
                      );
                    },
                  ),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
