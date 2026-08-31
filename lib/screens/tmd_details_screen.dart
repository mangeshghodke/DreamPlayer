import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;

import '../models/video_item.dart';
import '../services/file_browser.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/resume_store.dart';
import '../services/tmdb_client.dart';
import '../services/watched_store.dart';
import '../utils/season_group.dart' as sg;
import '../widgets/season_progress_ring.dart';
import '../widgets/tv_tile.dart';
import 'folder_screen.dart';
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
  }) : assert(video != null || folder != null);

  final VideoItem? video;

  /// When set, shows the folder's details + its file list instead of a single
  /// playable video. The folder's name is the TMDB search query.
  final LibraryFolder? folder;

  /// Server-side metadata for a Jellyfin library folder (cached on bookmark,
  /// refreshed here on open) shown when no TMDB match resolves.
  final JellyfinItemInfo? jellyfinInfo;

  @override
  State<TmdDetailsScreen> createState() => _TmdDetailsScreenState();
}

class _TmdDetailsScreenState extends State<TmdDetailsScreen> {
  late final String _identityKey = widget.folder?.metadataKey ??
      TmdStore.identityKeyFor(widget.video!);
  late final String _resumeKey = widget.folder == null
      ? (widget.video!.resumeKey ?? widget.video!.path ?? widget.video!.uri ?? '')
      : '';
  late final ParsedFileName _parsed =
      ParsedFileName.parse(widget.folder?.name ?? widget.video!.title);
  final TmdService _service = TmdService.instance;

  TmdMeta? _meta;
  TmdDetails? _details;
  bool _loading = true;

  /// Latches so a failed metadata lookup pops the "can't connect" SnackBar
  /// at most once per screen (not on every rebuild/retry).
  bool _connectionErrorShown = false;

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

  /// Which seasons are expanded (all true initially).
  final Set<int> _expandedSeasons = {};

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _jellyfinInfo = widget.jellyfinInfo;
    _load();
    _refreshWatched();
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
      final map = <String, Duration>{};
      for (final k in keys) {
        final pos = await ResumeStore.positionFor(k);
        if (pos != null) map[k] = pos;
      }
      if (mounted) setState(() => _positions = map);
    } catch (_) {}
  }

  String? _watchedKeyForFile(FileEntry e) =>
      e.isDirectory ? null : e.resumeKey;

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
    return 0.35;
  }

  double? _resumeProgressForJellyfin(JellyfinItem item) {
    final k = _watchedKeyForJellyfin(item);
    if (k == null) return null;
    if (_watchedKeys.contains(k)) return 1.0;
    final pos = _positions[k];
    if (pos == null) return null;
    final dur = item.duration;
    if (dur > Duration.zero) {
      return (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
    }
    return 0.35;
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
    }
    // Server-side series info (poster/title/year/overview) for Jellyfin
    // folders — refreshed on open so image URLs carry the current token.
    if (widget.folder?.isJellyfin ?? false) {
      await _refreshJellyfinInfo();
      if (!mounted) return;
    }
    if (_meta == null) {
      try {
        if (widget.folder != null) {
          await _service.resolveFolder(
            widget.folder!.metadataKey,
            widget.folder!.name,
          );
        } else {
          await _service.resolve(widget.video!);
        }
        if (!mounted) return;
        final meta = _service.metaFor(_identityKey);
        setState(() {
          _meta = meta;
          _loading = false;
        });
      } catch (e) {
        if (mounted) {
          setState(() => _loading = false);
          // A failed lookup surfaces as a transient popup, not inline text on
          // the "no match" card — the card stays blank apart from the "Could
          // not find …" headline and the Search TMDB button.
          if (!_connectionErrorShown) {
            _connectionErrorShown = true;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Can\'t connect to TMDB right now. Check your connection '
                      'and try again.',
                ),
              ),
            );
          }
        }
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
      _prefetchFolderMeta(entries);
      _refreshWatched();
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
      _prefetchJellyfinMeta(server);
      _refreshWatched();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _folderError = e is JellyfinException
            ? e.message
            : JellyfinClient.friendlyError(e);
      });
    }
  }

  /// Best-effort TMDB prefetch for the folder's video files. Each file resolves
  /// under the SAME stable key its tile/tap uses, so the row's poster appears
  /// when a match exists and opening the file is a cache hit. Never blocks the
  /// list.
  void _prefetchFolderMeta(List<FileEntry> entries) {
    final service = _service;
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      service.resolve(_toVideoItem(entry)).catchError((_) {
        // Best-effort; a TMDB failure just leaves the row without a poster.
        return null;
      });
    }
  }

  /// Jellyfin variant: prefetch each playable under the same key its tap uses.
  void _prefetchJellyfinMeta(JellyfinServer server) {
    final service = _service;
    for (final item in _jellyfinEntries) {
      if (!item.isPlayable) continue;
      service.resolve(_jellyfin.videoItem(server, item)).catchError((_) {
        return null;
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
    if (widget.folder == null &&
        _parsed.isEpisode &&
        _parsed.season > 0 &&
        _parsed.episode > 0) {
      await _service.episodeDetailsFor(
        _identityKey,
        _parsed.season,
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
          .toList();
    }
    if (_parsed.isEpisode) return [_parsed.season].where((s) => s > 0).toList();
    return const [];
  }

  /// The TMDB episode matching a local file, or null (movie / no season data).
  TmdEpisode? _episodeFor(FileEntry entry) {
    final parsed = ParsedFileName.parse(entry.name);
    if (!parsed.isEpisode) return null;
    return _meta?.seasons[parsed.season]?.episode(parsed.episode);
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
    ]);
    var position = results[0];
    var positionMpv = results[1];
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
    if (mounted && (position != _resumePosition || positionMpv != _resumePositionMpv)) {
      setState(() {
        _resumePosition = position;
        _resumePositionMpv = positionMpv;
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
    final picked = await showDialog<TmdMovie>(
      context: context,
      builder: (context) => _SearchDialog(
        initialQuery: ParsedFileName.parse(
          widget.folder?.name ?? widget.video!.title,
        ).title,
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
    PlayEngine engine = PlayEngine.media3,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          video: widget.video!,
          startFromBeginning: fromBeginning,
          initialEngine: engine,
        ),
      ),
    );
    // The playhead may have moved (or the video finished) — refresh the label.
    await _loadResume();
  }

  /// The libmpv engine is Android-only (iOS playback is AetherEngine), so the
  /// "Play with MPV" option only shows on Android — iOS keeps its single Play.
  bool get showMpvOption => Platform.isAndroid;

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
    final isEpisode = ParsedFileName.parse(entry.name).isEpisode;
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
  }

  VideoItem _toVideoItem(FileEntry entry) {
    final isContentUri = entry.path.startsWith('content://');
    return VideoItem(
      id: 'folder_${widget.folder!.id}_${entry.path.hashCode}',
      title: entry.name,
      path: isContentUri ? null : entry.path,
      uri: isContentUri ? entry.path : null,
      resumeKey: entry.resumeKey,
      duration: Duration.zero,
      sizeBytes: entry.size,
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
    final hasAnyResume = resume != null || resumeMpv != null;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
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
                          if (resume != null) ...[
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
                                      'Resume from ${_formatClock(resume)}',
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
                              label: const Text('Play'),
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
                            label: const Text('Play'),
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
  Widget _headerBox(BuildContext context, Widget child) {
    final size = MediaQuery.sizeOf(context);
    if (MediaQuery.orientationOf(context) == Orientation.landscape) {
      final height = (size.height * 0.32).clamp(140.0, 240.0);
      return Center(
        child: SizedBox(
          width: height * 16 / 9,
          height: height,
          child: child,
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      height: size.width * 9 / 16,
      child: child,
    );
  }

  Widget _buildBody(ThemeData theme, TmdMeta? meta) {
    if (meta == null) {
      if (widget.folder != null) return _buildFolderWithoutMatch(theme);
      return _buildNoMatch(theme);
    }
    final movie = meta.movie;
    final details = _details;
    final colorScheme = theme.colorScheme;
    final singleEpisode = _parsed.isEpisode && widget.folder == null
        ? meta.seasons[_parsed.season]?.episode(_parsed.episode)
        : null;
    // For a single episode, the still frame takes over the header (when the
    // show's season data is loaded) so the page reads as "this episode".
    final headerImage = singleEpisode?.stillUrl() ?? movie.backdropUrl();
    final episodeAirDate = singleEpisode?.airDate;
    final episodeOverview =
        (singleEpisode?.overview.isNotEmpty ?? false) ? singleEpisode!.overview : null;

    // Horizontal scrollable images for the single-episode page: the episode's
    // own still frames when the per-episode fetch landed, otherwise fall back
    // to the header still then the show backdrop so the strip is never empty.
    final episodeImages = singleEpisode == null
        ? const <String>[]
        : singleEpisode.stills.isNotEmpty
            ? singleEpisode.stillUrls()
            : <String>[
                if (singleEpisode.stillUrl() != null) singleEpisode.stillUrl()!,
                if (singleEpisode.stillUrl() == null && movie.backdropUrl() != null)
                  movie.backdropUrl()!,
              ];

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _headerBox(
            context,
            Stack(
              children: [
                _HeaderImageGallery(
                  images: episodeImages.isNotEmpty
                      ? episodeImages
                      : [?headerImage],
                  fallback: _artworkFallback(colorScheme),
                ),
                Positioned(
                  bottom: 8,
                  right: 12,
                  child: _RatingBadge(
                    rating: singleEpisode != null && singleEpisode.voteAverage > 0
                        ? singleEpisode.voteAverage
                        : movie.voteAverage,
                  ),
                ),
              ],
            ),
          ),
        ),
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
                          if (_parsed.isEpisode)
                            Text(
                              _parsed.seasonEpisodeLabel,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          if (singleEpisode != null)
                            Text(
                              singleEpisode.nameLabel,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          if (movie.year != null)
                            Text(
                              '${movie.year}',
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (_parsed.isEpisode)
                                _FactChip(
                                  icon: Icons.tag,
                                  label: _parsed.episodeLabel,
                                ),
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
                              // The show's average runtime only outside the
                              // single-episode page and the parent folder
                              // page, where the episode's own runtime chip
                              // would otherwise duplicate it.
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
                if (singleEpisode != null) ...[
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 0,
                    children: [
                      Text(
                        'Episode cast',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Wrap(
                        spacing: 0,
                        children: [
                          TextButton(
                            onPressed: _removeInfo,
                            style: TextButton.styleFrom(
                              foregroundColor: theme.colorScheme.error,
                            ),
                            child: const Text('Remove info'),
                          ),
                          TextButton(
                            onPressed: _fixMatch,
                            child: const Text('Fix match'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (singleEpisode.cast.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 96,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: singleEpisode.cast.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) =>
                            _CastTile(member: singleEpisode.cast[index]),
                      ),
                    ),
                  ],
                  if (singleEpisode.guestStars.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Guest stars',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 96,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: singleEpisode.guestStars.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) => _CastTile(
                          member: singleEpisode.guestStars[index],
                        ),
                      ),
                    ),
                  ],
                ] else ...[
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 0,
                    children: [
                      Text(
                        'Cast',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Wrap(
                        spacing: 0,
                        children: [
                          TextButton(
                            onPressed: _removeInfo,
                            style: TextButton.styleFrom(
                              foregroundColor: theme.colorScheme.error,
                            ),
                            child: const Text('Remove info'),
                          ),
                          TextButton(
                            onPressed: _fixMatch,
                            child: const Text('Fix match'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (details != null && details.cast.isNotEmpty)
                    SizedBox(
                      height: 96,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: details.cast.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) =>
                            _CastTile(member: details.cast[index]),
                      ),
                    ),
                ],
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
    final episodes = videos
        .where((e) => ParsedFileName.parse(e.name).isEpisode)
        .toList();
    final movies = videos
        .where((e) => !ParsedFileName.parse(e.name).isEpisode)
        .toList();
    final seasonGroups = sg.groupBySeason<FileEntry>(
      episodes,
      (e) => ParsedFileName.parse(e.name).season,
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
            child: _headerBox(
              context,
              Stack(
                children: [
                  if (info.backdropUrl != null)
                    Image.network(
                      info.backdropUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          _artworkFallback(colorScheme),
                      loadingBuilder: (context, child, progress) =>
                          progress == null
                              ? child
                              : _artworkFallback(colorScheme),
                    )
                  else
                    _artworkFallback(colorScheme),
                  if (info.communityRating > 0)
                    Positioned(
                      bottom: 8,
                      right: 12,
                      child: _RatingBadge(rating: info.communityRating),
                    ),
                ],
              ),
            ),
          ),
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
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.movie_filter_outlined,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'Could not find "${widget.folder?.name ?? widget.video!.title}" on TMDB',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _fixMatch,
              icon: const Icon(Icons.search),
              label: const Text('Search TMDB'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _artworkFallback(ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.tertiaryContainer,
          ],
        ),
      ),
      child: const Center(
        child: Icon(Icons.movie_filter, size: 48, color: Colors.white24),
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

class _CastTile extends StatelessWidget {
  const _CastTile({required this.member});

  final TmdCastMember member;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipOval(
            child: member.profileUrl(width: 185) != null
                ? Image.network(
                    member.profileUrl(width: 185)!,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _avatarFallback(colorScheme),
                  )
                : _avatarFallback(colorScheme),
          ),
          const SizedBox(height: 6),
          // Name + character must fit the fixed 96px tile height at any text
          // scale — scale the two lines down together when they don't.
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    member.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (member.character != null)
                    Text(
                      member.character!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatarFallback(ColorScheme colorScheme) {
    return Container(
      width: 56,
      height: 56,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.person, color: colorScheme.onSurfaceVariant),
    );
  }
}

/// The top header artwork: a horizontal swipeable gallery of the episode's
/// TMDB still frames (a dot indicator shows the current frame). Falls back to
/// a single static frame when the page isn't an episode gallery.
class _HeaderImageGallery extends StatefulWidget {
  const _HeaderImageGallery({
    required this.images,
    required this.fallback,
  });

  final List<String> images;
  final Widget fallback;

  @override
  State<_HeaderImageGallery> createState() => _HeaderImageGalleryState();
}

class _HeaderImageGalleryState extends State<_HeaderImageGallery> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    return Stack(
      children: [
        SizedBox.expand(
          child: images.isNotEmpty
              ? PageView.builder(
                  itemCount: images.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, index) => _HeaderArtwork(
                    url: images[index],
                    fallback: widget.fallback,
                  ),
                )
              : _HeaderArtwork(
                  url: null,
                  fallback: widget.fallback,
                ),
        ),
        if (images.length > 1)
          Positioned(
            bottom: 10,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < images.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: i == _page ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// A full-bleed header frame for the details screen: one page of the episode
/// still gallery, or the single static artwork on non-episode pages.
class _HeaderArtwork extends StatelessWidget {
  const _HeaderArtwork({required this.url, required this.fallback});

  final String? url;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    if (url == null) return fallback;
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : fallback,
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
  });

  final int season;
  final List<T> entries;
  final Set<String> watchedKeys;
  final String? Function(T) keyOf;
  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;
  final Widget Function(T) tileBuilder;

  @override
  Widget build(BuildContext context) {
    final watched = sg.watchedCount(entries, watchedKeys, keyOf);
    final total = entries.length;
    final colorScheme = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        onExpansionChanged: onExpansionChanged,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        childrenPadding: EdgeInsets.zero,
        title: Row(
          children: [
            Text(
              sg.seasonHeader(season),
              style: TextStyle(
                color: colorScheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: 13,
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
  });

  final FileEntry entry;
  final TmdEpisode? episode;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
  final double? resumeProgress;

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
    final subtitle = <String>[
      if (parsed.isEpisode) parsed.episodeLabel,
      if (episode != null) episode!.nameLabel,
      _sizeLabel(entry.size),
    ].where((s) => s.isNotEmpty).join(' · ');

    final posterUrl = posterUrlOf(tmdbMeta);

    final subtitleWidget = subtitle.isEmpty && resumeProgress == null
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
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
              parsed.isEpisode ? Icons.movie_outlined : Icons.play_circle_outline,
              color: colorScheme.secondary,
            ),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitleWidget,
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
  });

  final JellyfinItem item;
  final TmdEpisode? episode;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
  final double? resumeProgress;

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

    final posterUrl = posterUrlOf(tmdbMeta);

    final subtitleWidget = subtitle.isEmpty && resumeProgress == null
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
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
  const _SearchDialog({this.initialQuery});

  final String? initialQuery;

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

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery ?? '';
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
      // Search TV and movies together so a folder can be pinned to a series.
      final all = await Future.wait([
        _api.search(query, kind: TmdKind.tv),
        _api.search(query, kind: TmdKind.movie),
      ]);
      final results = <TmdMovie>[...all[0], ...all[1]];
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
      title: const Text('Search TMDB'),
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
                hintText: 'Movie title',
                prefixIcon: Icon(Icons.search),
              ),
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
