import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/file_browser.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/smb_client.dart';
import '../services/simkl_client.dart';
import '../services/tmdb_client.dart';
import '../services/watched_store.dart';
import '../services/webdav_client.dart';
import '../utils/file_info_extractor.dart';
import '../utils/season_group.dart' as sg;
import '../widgets/season_progress_ring.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

/// The contents of a library folder. For a TV-show folder this is the episode
/// list; subfolders navigate one level at a time. Videos open their TMDB
/// details page (Play/Resume) instead of playing directly. Home routes folder
/// taps to `TmdDetailsScreen(folder:)`; this screen is used for subfolder
/// navigation once you're inside. Jellyfin library folders list their children
/// through the server API instead of the file browser.
class FolderScreen extends StatefulWidget {
  const FolderScreen({super.key, required this.folder, this.initialPath});

  final LibraryFolder folder;

  /// Start browsing at this subfolder instead of the folder root (deep links
  /// from the details screen's episode list).
  final String? initialPath;

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  static final FileBrowserService _service = FileBrowserService.instance;
  final JellyfinClient _jellyfin = JellyfinClient();

  late String _currentPath;
  List<FileEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  /// Watched marks for the current list, keyed by each row's stable resume
  /// key (same keys the player auto-marks on completion).
  Set<String> _watchedKeys = {};

  /// SIMKL cloud-done backfill (mirrors smb_screen.dart's sync button).
  bool _syncingSimkl = false;

  bool get _enableSimklSync =>
      (widget.folder.isJellyfin || widget.folder.isNetwork) &&
      _currentEntries.isNotEmpty &&
      !_isSeriesFolder;

  /// Series folder detection (same logic as SMB screen).
  bool _isSeriesFolder = false;
  TmdMeta? _seriesMeta;
  TmdDetails? _seriesDetails;
  bool _loadingSeriesMeta = false;
  final Set<int> _expandedSeasons = {};

  /// Jellyfin mode: the folder crumbs (name + item id) below the root, the
  /// resolved server, and the current level's children.
  List<({String name, String id})> _jellyfinCrumbs = const [];
  JellyfinServer? _jellyfinServer;
  List<JellyfinItem> _jellyfinEntries = const [];

  /// Network modes
  List<SmbEntry> _smbEntries = const [];
  // WebDAV entries reuse simple maps; keep as dynamic for now.
  List<Object> _networkEntries = const [];

  bool get _atRoot {
    if (_isJellyfin) return _jellyfinCrumbs.isEmpty;
    if (_isSmb || _isWebDav) return _currentPath == _networkPath;
    return _currentPath == widget.folder.path;
  }

  bool get _isJellyfin => widget.folder.isJellyfin;
  bool get _isSmb => widget.folder.source == LibraryFolderSource.smb;
  bool get _isWebDav => widget.folder.source == LibraryFolderSource.webdav;
  bool get _isNetworkFolder => widget.folder.isNetwork && !_isJellyfin;

  // Network folder navigation state (SMB/WebDAV share + subpath).
  late String _networkShare;
  late String _networkPath;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath ?? widget.folder.path;
    _networkShare = widget.folder.networkShare ?? '';
    _networkPath = widget.folder.networkPath ?? '';
    // For network folders, _currentPath tracks the subpath under the share.
    if (_isNetworkFolder && widget.initialPath == null) {
      _currentPath = _networkPath;
    }
    TmdService.instance.addListener(_onMetadataChanged);
    _resolveMeta();
    _load();
  }

  @override
  void dispose() {
    TmdService.instance.removeListener(_onMetadataChanged);
    super.dispose();
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _resolveMeta() async {
    try {
      await TmdService.instance
          .resolveFolder(widget.folder.metadataKey, widget.folder.name);
    } catch (_) {
      // Non-fatal: the header just stays a placeholder.
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    if (_isJellyfin) {
      await _loadJellyfin();
      return;
    }
    if (_isSmb) {
      await _loadSmb();
      return;
    }
    if (_isWebDav) {
      await _loadWebDav();
      return;
    }
    try {
      final entries = await _service.listDirectory(_currentPath);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      _refreshWatched();
      // Nova-style: background-resolve TMDB for all video files so metadata
      // is ready when the user taps a file.  Each file resolves independently
      // (no stagger) so the listener fires immediately per file and the tile
      // shows its poster as soon as the TMDB match lands — same as v0.3.8.
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        TmdService.instance.resolve(_toVideoItem(entry)).catchError((_) {
          return null;
        });
      }
      _detectAndLoadSeriesFolder();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Could not list this folder';
        _loading = false;
      });
    }
  }

  /// Detects whether the current folder is a TV series folder (≥1 files with
  /// SxxExx patterns or sequential numbering) and fetches TMDB metadata for
  /// the series header.
  Future<void> _detectAndLoadSeriesFolder() async {
    final entries = _currentEntries;
    if (entries.isEmpty) return;

    // Collect video files (non-directories) with their names.
    final videoNames = <String>[];
    for (final e in entries) {
      if (_isFolderEntry(e)) continue;
      videoNames.add(_nameOf(e));
    }
    if (videoNames.isEmpty) {
      if (_isSeriesFolder) setState(() => _isSeriesFolder = false);
      return;
    }

    // Check for SxxExx episode patterns.
    final episodeNames =
        videoNames.where((n) => ParsedFileName.parse(n).isEpisode).toList();

    // Fallback: sequential numbering detection.
    bool hasSequential = false;
    if (episodeNames.isEmpty) {
      hasSequential = _hasSequentialNumbering(videoNames);
    }

    // Trigger series view for any folder with video files — even a single
    // episode gets the TMDB header so the user sees the show's poster,
    // title, rating, and overview instead of a bare file list.
    if (episodeNames.isEmpty && !hasSequential && videoNames.isEmpty) {
      if (_isSeriesFolder) setState(() => _isSeriesFolder = false);
      return;
    }

    // Series detected — fetch TMDB metadata for the folder.
    final folderName = widget.folder.name;
    final metadataKey = widget.folder.metadataKey;

    setState(() {
      _isSeriesFolder = true;
      _loadingSeriesMeta = true;
    });

    final service = TmdService.instance;
    await service.ensureLoaded();

    var meta = service.metaFor(metadataKey) ??
        await service.resolveFolder(metadataKey, folderName);

    if (!mounted) return;
    if (meta == null) {
      setState(() {
        _seriesMeta = null;
        _seriesDetails = null;
        _loadingSeriesMeta = false;
      });
      return;
    }

    final details = await service.detailsFor(metadataKey);
    if (!mounted) return;

    setState(() {
      _seriesMeta = meta;
      _seriesDetails = details;
      _loadingSeriesMeta = false;
    });

    // Fetch season data for locally-present seasons.
    final seasonsNeeded = <int>{};
    for (final n in episodeNames) {
      final s = ParsedFileName.parse(n).season;
      if (s > 0) seasonsNeeded.add(s);
    }
    // When folderSeason is set (from TMDB season-name matching), always
    // fetch that season's data even if parsed seasons are all 0 (anime [01]).
    if (meta.folderSeason != null) seasonsNeeded.add(meta.folderSeason!);
    if (seasonsNeeded.isEmpty && hasSequential) seasonsNeeded.add(1);
    for (final season in seasonsNeeded) {
      await service.seasonFor(metadataKey, season);
      if (!mounted) return;
    }
    if (!mounted) return;
    // Read the latest meta from the cache (each seasonFor replaces it with a
    // new TmdMeta; the `meta` reference we held earlier is stale). Without
    // this, _episodeFor looks up an empty seasons map and per-episode
    // details (stills/names/ratings/overview) never appear until the user
    // backs out and re-enters — the cache hit on re-entry uses the fresh
    // meta and the UI populates.
    final freshMeta = service.metaFor(metadataKey) ?? meta;
    setState(() {
      _seriesMeta = freshMeta;
    });
  }

  /// Checks whether file names have sequential numbering (e.g. `- 01.mkv`,
  /// `E01.1080p`, `- 02.mkv`). Returns true if ≥2 files have numbers forming
  /// a near-continuous sequence starting from 1.
  static bool _hasSequentialNumbering(List<String> names) {
    if (names.length < 2) return false;

    // Pattern 1: E01 / EP01 / E1 / EP1 style (most common for anime/TV rips)
    final epPattern = RegExp(r'\bE(?:P)?(\d{1,3})\b', caseSensitive: false);
    // Pattern 2: Standalone number (01, 02, 1, 2) — must NOT be preceded by
    // a letter (avoids matching codec tags like x265, h264) and must NOT be
    // followed by a letter (avoids matching res like 1080p).
    final numPattern = RegExp(r'(?<![a-zA-Z])(\d{1,3})(?![a-zA-Z])');

    final numbers = <int>[];
    for (final name in names) {
      // Try E01/EP01 pattern first — highest confidence.
      final epMatch = epPattern.firstMatch(name);
      if (epMatch != null) {
        final n = int.tryParse(epMatch.group(1)!);
        if (n != null && n >= 1 && n <= 999) {
          numbers.add(n);
          continue;
        }
      }
      // Fallback: standalone number anywhere in the name.
      int? best;
      for (final m in numPattern.allMatches(name)) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n >= 1 && n <= 200) {
          // Skip common noise: year (19xx/20xx), resolution (480/720/1080/2160),
          // bitrate (128/256/320/640), codec (264/265/655).
          if (n >= 1900 || n == 480 || n == 720 || n == 1080 || n == 2160 ||
              n == 128 || n == 256 || n == 320 || n == 640 ||
              n == 264 || n == 265 || n == 655) {
            continue;
          }
          best = n;
          break; // Take the first valid number.
        }
      }
      if (best != null) numbers.add(best);
    }

    if (numbers.length < 2) return false;
    numbers.sort();
    if (numbers.first > 1) return false;
    var consecutive = 0;
    var expected = numbers.first;
    for (final n in numbers) {
      if (n == expected || n == expected + 1) {
        consecutive++;
        expected = n + 1;
      }
    }
    return consecutive >= (names.length + 1) ~/ 2;
  }

  Future<void> _loadJellyfin() async {
    try {
      final server =
          await _jellyfin.serverForUrl(widget.folder.jellyfinServerUrl ?? '');
      if (server == null || !server.isAuthenticated) {
        throw const JellyfinException(
          'Jellyfin server is not signed in — open the Jellyfin screen and '
          'sign in first.',
        );
      }
      final parentId = _jellyfinCrumbs.isEmpty
          ? (widget.folder.jellyfinItemId ?? '')
          : _jellyfinCrumbs.last.id;
      final items = await _jellyfin.getItems(server, parentId);
      if (!mounted) return;
      final folders = items.where((i) => i.isFolder).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final playables = items.where((i) => i.isPlayable).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _jellyfinServer = server;
        _jellyfinEntries = [...folders, ...playables];
        _loading = false;
      });
      _refreshWatched();
      _detectAndLoadSeriesFolder();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is JellyfinException
            ? e.message
            : JellyfinClient.friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadSmb() async {
    try {
      final serverId = widget.folder.networkServerId ?? '';
      final share = widget.folder.networkShare ?? _networkShare;
      final path = _currentPath.replaceAll(RegExp(r'/+$'), '').replaceAll(RegExp(r'^/+'), '');
      final entries = await SmbClient.instance.listDirectory(serverId, share, path);
      if (!mounted) return;
      setState(() {
        _smbEntries = entries;
        _loading = false;
      });
      _refreshWatched();
      for (final e in entries) {
        if (e.isDirectory) continue;
        TmdService.instance.resolve(_toVideoItem(e)).catchError((_) => null);
      }
      _detectAndLoadSeriesFolder();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Could not list this folder';
        _loading = false;
      });
    }
  }

  Future<void> _loadWebDav() async {
    try {
      final serverId = widget.folder.networkServerId ?? '';
      final basePath = widget.folder.networkPath ?? '';
      final path = _currentPath.isEmpty ? basePath : _currentPath;
      final entries = await WebDavClient.instance.listDirectory(serverId, path);
      if (!mounted) return;
      setState(() {
        _networkEntries = entries;
        _loading = false;
      });
      _refreshWatched();
      for (final e in entries) {
        if (e.isDirectory) continue;
        TmdService.instance.resolve(_toVideoItem(e)).catchError((_) => null);
      }
      _detectAndLoadSeriesFolder();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Could not list this folder';
        _loading = false;
      });
    }
  }


  Future<void> _openEntry(FileEntry entry) async {
    if (entry.isDirectory) {
      setState(() => _currentPath = entry.path);
      await _load();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: _toVideoItem(entry),
          parentMetadataKey: widget.folder.metadataKey,
        ),
      ),
    );
    // Resume positions may have changed while playing.
    await _load();
  }

  Future<void> _openJellyfinItem(JellyfinItem item) async {
    final server = _jellyfinServer;
    if (server == null) return;
    if (item.isFolder) {
      setState(() {
        _jellyfinCrumbs = [..._jellyfinCrumbs, (name: item.name, id: item.id)];
        _loading = true;
      });
      await _loadJellyfin();
      return;
    }
    if (!item.isPlayable) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: _jellyfin.videoItem(server, item),
          parentMetadataKey: widget.folder.metadataKey,
        ),
      ),
    );
    // Resume positions may have changed while playing.
    await _loadJellyfin();
  }

  Future<void> _openSmbEntry(SmbEntry entry) async {
    if (entry.isDirectory) {
      setState(() {
        _currentPath = entry.path;
        _loading = true;
      });
      await _loadSmb();
      return;
    }
    final serverId = widget.folder.networkServerId ?? '';
    final share = widget.folder.networkShare ?? _networkShare;
    final uri = await SmbClient.instance.openShare(serverId, share, entry.path);
    final resumeKey = 'smb:$serverId/$share/${entry.path}';
    final item = VideoItem(
      id: 'smb_${widget.folder.id}_${entry.path.hashCode}',
      title: entry.name,
      uri: uri,
      resumeKey: resumeKey,
      duration: Duration.zero,
      sizeBytes: entry.size,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: item,
          parentMetadataKey: widget.folder.metadataKey,
        ),
      ),
    );
    await _loadSmb();
  }

  VideoItem _toVideoItem(Object entry) {
    // Bookmarked-tree videos come back as content:// URIs (no real file
    // path), so hand those to the player's `uri` field.
    String name;
    String path;
    String? resumeKey;
    int size;
    if (entry is SmbEntry) {
      name = entry.name;
      path = entry.path;
      resumeKey = 'smb:${widget.folder.networkServerId}/${widget.folder.networkShare}/${entry.path}';
      size = entry.size;
    } else if (entry is WebDavEntry) {
      name = entry.name;
      path = entry.path;
      resumeKey = 'webdav:${widget.folder.networkServerId}${entry.path}';
      size = entry.size;
    } else {
      final fe = entry as FileEntry;
      name = fe.name;
      path = fe.path;
      resumeKey = fe.resumeKey;
      size = fe.size;
    }
    final isContentUri = path.startsWith('content://');
    final info = extractFileInfo(name);
    return VideoItem(
      id: 'folder_${widget.folder.id}_${path.hashCode}',
      title: name,
      path: isContentUri ? null : path,
      uri: isContentUri ? path : null,
      resumeKey: resumeKey,
      duration: Duration.zero,
      sizeBytes: size,
      videoCodec: info.videoCodec,
      audioCodec: info.audioCodec,
      audioChannels: info.audioChannels,
      resolution: info.resolution,
      hdrHint: info.hdrHint,
    );
  }

  /// Reloads the watched-mark set for the current list.
  Future<void> _refreshWatched() async {
    try {
      final watched = await WatchedStore.load();
      if (mounted) setState(() => _watchedKeys = watched);
    } catch (_) {}
  }

  String? _watchedKeyForEntry(Object entry) {
    if (_isJellyfin) {
      final item = entry as JellyfinItem;
      final server = _jellyfinServer;
      if (server == null || item.isFolder) return null;
      return _jellyfin.videoItem(server, item).resumeKey;
    }
    if (_isSmb) {
      final e = entry as SmbEntry;
      if (e.isDirectory) return null;
      final serverId = widget.folder.networkServerId ?? '';
      final share = widget.folder.networkShare ?? _networkShare;
      return 'smb:$serverId/$share/${e.path}';
    }
    if (_isWebDav) {
      // WebDAV entries are maps with 'path'
      if (entry is Map && entry['isDirectory'] == true) return null;
      final id = widget.folder.networkServerId ?? '';
      final p = (entry is Map ? entry['path'] as String? : null) ?? '';
      return 'webdav:$id$p';
    }
    return (entry as FileEntry).isDirectory ? null : entry.resumeKey;
  }

  Future<void> _toggleWatched(Object entry) async {
    final key = _watchedKeyForEntry(entry);
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
  /// store for this folder's entries (mirrors smb_screen.dart's sync button).
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
      for (final e in _currentEntries) {
        final key = _watchedKeyForEntry(e);
        if (key == null || key.isEmpty || _watchedKeys.contains(key)) continue;
        final meta = TmdService.instance
            .metaFor(TmdStore.identityKeyFor(_toVideoItem(e)));
        if (meta == null) continue;
        final id = meta.movie.id;
        final isTv = meta.movie.kind == TmdKind.tv;
        final shouldMark = isTv
            ? watched.showSeasons.containsKey(id)
            : watched.movieIds.contains(id);
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

  Future<void> _goUp() async {
    if (_isJellyfin) {
      if (_jellyfinCrumbs.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _jellyfinCrumbs =
            _jellyfinCrumbs.sublist(0, _jellyfinCrumbs.length - 1);
        _loading = true;
      });
      await _loadJellyfin();
      return;
    }
    if (_atRoot) {
      Navigator.of(context).pop();
      return;
    }
    final fallback = _isNetworkFolder ? _networkPath : widget.folder.path;
    setState(() => _currentPath = _parentOf(_currentPath) ?? fallback);
    await _load();
  }

  static String? _parentOf(String path) {
    final index = path.lastIndexOf('/');
    if (index <= 0) return null;
    return path.substring(0, index);
  }

  String get _title {
    if (_isJellyfin) {
      return _jellyfinCrumbs.isEmpty
          ? widget.folder.name
          : _jellyfinCrumbs.last.name;
    }
    return _atRoot ? widget.folder.name : (_currentPath.split('/').lastOrNull ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        leading: IconButton(
          tooltip: 'Up',
          icon: const Icon(Icons.arrow_back),
          onPressed: _goUp,
        ),
        actions: [
          if (_enableSimklSync)
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
      body: TvOverscan(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _currentEntries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(
          'Error: $_error',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    final entries = _currentEntries;
    if (entries.isEmpty) {
      return Column(
        children: [
          if (_atRoot) _header(context),
          const Expanded(child: Center(child: Text('No videos or folders here'))),
        ],
      );
    }

    // Series folder mode: show TMDB header + season-grouped episodes.
    if (_isSeriesFolder) {
      return _seriesFolderBody(context);
    }

    // Regular mode: folders + season-grouped videos.
    return _regularBody(context);
  }

  /// Nova-style series folder body: series header (poster, title, rating,
  /// overview) at top, season-grouped episode list below.
  Widget _seriesFolderBody(BuildContext context) {
    final theme = Theme.of(context);
    final meta = _seriesMeta;
    final details = _seriesDetails;
    final metadataKey = widget.folder.metadataKey;

    if (_loadingSeriesMeta) {
      return const Center(child: CircularProgressIndicator());
    }

    // No metadata — fall back to regular list.
    if (meta == null) {
      return _regularBody(context);
    }

    // Separate folders from videos — include ALL video files, not just
    // those matching SxxExx patterns, so single episodes (E01, numbered)
    // still appear in the series body.
    final entries = _currentEntries;
    final episodes = <Object>[];
    for (final e in entries) {
      if (_isFolderEntry(e)) continue;
      episodes.add(e);
    }

    // Group by season.
    final seasonGroups = sg.groupBySeason<Object>(
      episodes,
      _seasonOf,
      _episodeOf,
    );
    final sortedSeasons = seasonGroups.keys.toList()..sort();

    // Auto-expand the first season.
    if (_expandedSeasons.isEmpty && sortedSeasons.isNotEmpty) {
      _expandedSeasons.add(sortedSeasons.first);
    }

    return CustomScrollView(
      slivers: [
        // ── Series header ──
        SliverToBoxAdapter(
          child: _SeriesHeader(
            meta: meta,
            details: details,
            metadataKey: metadataKey,
            onFixMatch: () async {
              await _fixMatchSeries();
            },
            onRemoveInfo: () async {
              final service = TmdService.instance;
              await service.clear(metadataKey);
              if (!mounted) return;
              setState(() {
                _seriesMeta = null;
                _seriesDetails = null;
                _isSeriesFolder = false;
              });
            },
          ),
        ),

        // ── Episodes section header ──
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
                const SizedBox(width: 8),
                Text(
                  '${episodes.length} ${episodes.length == 1 ? 'file' : 'files'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Season groups with expand/collapse ──
        for (final s in sortedSeasons) ...[
          Builder(builder: (context) {
            final seasonList = seasonGroups[s]!;
            final expanded = _expandedSeasons.contains(s);
            final watchedCount = sg.watchedCount(
              seasonList,
              _watchedKeys,
              _watchedKeyForEntry,
            );
            final total = seasonList.length;
            final cachedMeta = TmdService.instance.metaFor(metadataKey);
            return _FolderSeasonExpansion(
              season: s,
              expanded: expanded,
              onToggle: () {
                setState(() {
                  if (expanded) {
                    _expandedSeasons.remove(s);
                  } else {
                    _expandedSeasons.add(s);
                  }
                });
              },
              watchedCount: watchedCount,
              total: total,
              seasonName: cachedMeta?.seasons[s]?.name,
              child: Column(
                children: [
                  for (final v in seasonList) _tileFor(v),
                ],
              ),
            );
          }),
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// Regular flat body (non-series folder).
  Widget _regularBody(BuildContext context) {
    final entries = _currentEntries;
    // Separate folders from playable videos so seasons group only videos.
    final folders = <Object>[];
    final videos = <Object>[];
    for (final e in entries) {
      final isFolder = _isJellyfin
          ? (e as JellyfinItem).isFolder
          : _isSmb
              ? (e as SmbEntry).isDirectory
              : _isWebDav
                  ? (e as Map)['isDirectory'] == true
                  : (e as FileEntry).isDirectory;
      (isFolder ? folders : videos).add(e);
    }
    // Build season groups for episode videos; movies stay ungrouped.
    final episodes = videos.where(_isEpisode).toList();
    final movies = videos.where((v) => !_isEpisode(v)).toList();
    final seasonGroups = sg.groupBySeason<Object>(
      episodes,
      _seasonOf,
      _episodeOf,
    );
    final hasSeasons = seasonGroups.isNotEmpty;
    final sortedSeasons = seasonGroups.keys.toList()..sort();

    return Column(
      children: [
        if (_atRoot) _header(context),
        Expanded(
          child: ListView(
            children: [
              for (final f in folders) _tileFor(f),
              if (hasSeasons)
                for (final s in sortedSeasons) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        Text(
                          sg.seasonHeader(s),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Builder(builder: (context) {
                          final seasonList = seasonGroups[s]!;
                          final watched = sg.watchedCount(
                            seasonList,
                            _watchedKeys,
                            _watchedKeyForEntry,
                          );
                          final total = seasonList.length;
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SeasonProgressRing(
                                watched: watched,
                                total: total,
                                size: 28,
                                strokeWidth: 2.5,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                sg.watchedBadge(watched, total),
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          );
                        }),
                      ],
                    ),
                  ),
                  for (final v in seasonGroups[s]!) _tileFor(v),
                ],
              for (final m in movies) _tileFor(m),
            ],
          ),
        ),
      ],
    );
  }

  /// Builds a tile for any entry type.
  Widget _tileFor(Object e) {
    if (_isJellyfin) {
      final item = e as JellyfinItem;
      return _JellyfinFolderTile(
        item: item,
        tmdbMeta: item.isFolder ? null : _tmdbForJellyfin(item),
        watched: _watchedKeys.contains(_watchedKeyForEntry(item)),
        onToggleWatched: () => _toggleWatched(item),
        onTap: () => _openJellyfinItem(item),
      );
    }
    if (_isSmb) {
      final smb = e as SmbEntry;
      return _FolderTile(
        entry: FileEntry(
            name: smb.name,
            path: smb.path,
            isDirectory: smb.isDirectory,
            size: smb.size,
            resumeKey: _watchedKeyForEntry(smb)),
        tmdbMeta: smb.isDirectory ? null : _tmdbForSmb(smb),
        watched: _watchedKeys.contains(_watchedKeyForEntry(smb)),
        onToggleWatched: () => _toggleWatched(smb),
        episode: smb.isDirectory ? null : _episodeFor(smb),
        folderSeason: _seriesMeta?.folderSeason,
        onTap: () => _openSmbEntry(smb),
      );
    }
    final fileEntry = e as FileEntry;
    return _FolderTile(
      entry: fileEntry,
      tmdbMeta: fileEntry.isDirectory ? null : _tmdbFor(fileEntry),
      watched: _watchedKeys.contains(_watchedKeyForEntry(fileEntry)),
      onToggleWatched: () => _toggleWatched(fileEntry),
      episode: fileEntry.isDirectory ? null : _episodeFor(fileEntry),
      folderSeason: _seriesMeta?.folderSeason,
      onTap: () => _openEntry(fileEntry),
    );
  }

  /// Fix match for the series folder — opens the TMDB search dialog.
  Future<void> _fixMatchSeries() async {
    final metadataKey = widget.folder.metadataKey;
    final folderName = widget.folder.name;
    final parsed = ParsedFileName.parse(folderName);
    final picked = await showDialog<TmdMovie>(
      context: context,
      builder: (context) => _FolderSearchDialog(
        initialQuery: parsed.title.isNotEmpty ? parsed.title : folderName,
        initialYear: parsed.year,
        initialKind: TmdKind.tv,
      ),
    );
    if (picked == null || !mounted) return;

    final service = TmdService.instance;
    await service.setManualFolder(metadataKey, picked);
    if (!mounted) return;

    setState(() {
      _loadingSeriesMeta = true;
    });
    final meta = service.metaFor(metadataKey);
    final details = await service.detailsFor(metadataKey);
    if (!mounted) return;

    setState(() {
      _seriesMeta = meta;
      _seriesDetails = details;
      _loadingSeriesMeta = false;
      _isSeriesFolder = true;
    });
  }

  bool _isFolderEntry(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).isFolder;
    if (_isSmb) return (e as SmbEntry).isDirectory;
    if (_isWebDav) return (e as Map)['isDirectory'] == true;
    return (e as FileEntry).isDirectory;
  }

  static final _epPattern = RegExp(
      r'\b(?:S\d{1,2}E\d{1,2}|\d{1,2}x\d{1,3}|E(?:P)?\d{1,3})\b|\[(\d{1,3})\]',
      caseSensitive: false);

  bool _isEpisode(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).type == 'Episode';
    if (_isSmb) {
      final smb = e as SmbEntry;
      final p = ParsedFileName.parse(smb.name);
      return p.isEpisode || _epPattern.hasMatch(smb.name);
    }
    if (_isWebDav) {
      final name = (e as Map)['name'] as String? ?? '';
      final p = ParsedFileName.parse(name);
      return p.isEpisode || _epPattern.hasMatch(name);
    }
    final fe = e as FileEntry;
    final p = ParsedFileName.parse(fe.name);
    return p.isEpisode || _epPattern.hasMatch(fe.name);
  }

  String _nameOf(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).name;
    if (_isSmb) return (e as SmbEntry).name;
    if (_isWebDav) return (e as Map)['name'] as String? ?? '';
    return (e as FileEntry).name;
  }

  int _seasonOf(Object e) {
    final folderSeason = _seriesMeta?.folderSeason;
    if (folderSeason != null) return folderSeason;
    int parsedSeason;
    if (_isJellyfin) {
      parsedSeason = (e as JellyfinItem).parentIndexNumber ?? 0;
    } else if (_isSmb) {
      parsedSeason = ParsedFileName.parse((e as SmbEntry).name).season;
    } else if (_isWebDav) {
      final name = (e as Map)['name'] as String? ?? '';
      parsedSeason = ParsedFileName.parse(name).season;
    } else {
      parsedSeason = ParsedFileName.parse((e as FileEntry).name).season;
    }
    // For anime bracket numbering ([01]/[02]), parsed.season is 0 but the
    // show is a single season — fall back to the first season with TMDB
    // data so episodes group under the right header.
    if (parsedSeason <= 0 && _seriesMeta != null && _seriesMeta!.seasons.isNotEmpty) {
      return _seriesMeta!.seasons.keys.first;
    }
    return parsedSeason;
  }

  TmdEpisode? _episodeFor(Object e) {
    final folderSeason = _seriesMeta?.folderSeason;
    int parsedSeason;
    int parsedEpisode;
    if (_isSmb) {
      final smb = e as SmbEntry;
      final parsed = ParsedFileName.parse(smb.name);
      if (!parsed.isEpisode) return null;
      parsedSeason = parsed.season;
      parsedEpisode = parsed.episode;
    } else {
      final fe = e as FileEntry;
      final parsed = ParsedFileName.parse(fe.name);
      if (!parsed.isEpisode) return null;
      parsedSeason = parsed.season;
      parsedEpisode = parsed.episode;
    }
    int s;
    if (folderSeason != null) {
      s = folderSeason;
    } else if (parsedSeason > 0) {
      s = parsedSeason;
    } else if (_seriesMeta?.seasons.isNotEmpty == true) {
      // Anime bracket numbering ([01]/[02]) — use the first season with
      // fetched TMDB data so episodes resolve to the right episode object.
      s = _seriesMeta!.seasons.keys.first;
    } else {
      s = 1;
    }
    return _seriesMeta?.seasons[s]?.episode(parsedEpisode);
  }

  int _episodeOf(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).indexNumber ?? 0;
    if (_isSmb) return ParsedFileName.parse((e as SmbEntry).name).episode;
    if (_isWebDav) {
      final name = (e as Map)['name'] as String? ?? '';
      return ParsedFileName.parse(name).episode;
    }
    return ParsedFileName.parse((e as FileEntry).name).episode;
  }

  /// The entries for the current mode (files / Jellyfin / network), unified.
  List<Object> get _currentEntries {
    if (_isJellyfin) return _jellyfinEntries;
    if (_isSmb) return _smbEntries;
    if (_isWebDav) return _networkEntries;
    return _entries;
  }

  /// Cached TMDB meta for a video file, looked up under the same identity key
  /// its tile/tap uses so the poster and the opened details screen agree.
  TmdMeta? _tmdbFor(FileEntry entry) {
    if (_isJellyfin) return null;
    return TmdService.instance
        .metaFor(TmdStore.identityKeyFor(_toVideoItem(entry)));
  }

  TmdMeta? _tmdbForSmb(SmbEntry entry) {
    final serverId = widget.folder.networkServerId ?? '';
    final share = widget.folder.networkShare ?? _networkShare;
    final key = 'smb:$serverId/$share/${entry.path}';
    return TmdService.instance.metaFor(key);
  }

  /// Cached TMDB meta for a Jellyfin playable (same key as its tap).
  TmdMeta? _tmdbForJellyfin(JellyfinItem item) {
    final server = _jellyfinServer;
    if (server == null) return null;
    return TmdService.instance
        .metaFor(TmdStore.identityKeyFor(_jellyfin.videoItem(server, item)));
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final meta = TmdService.instance.metaFor(widget.folder.metadataKey);
    final movie = meta?.movie;
    final backdrop = movie?.backdropUrl();
    // Network folders (SMB/WebDAV) keep their entries in _smbEntries /
    // _networkEntries, so read from the unified _currentEntries — never the
    // local _entries list (which is empty for them and would read "0 videos").
    final all = _currentEntries;
    final videoCount = all.where((e) => !_isFolderEntry(e)).length;
    final folderCount = all.where(_isFolderEntry).length;

    return SizedBox(
      width: double.infinity,
      child: Stack(
        children: [
          if (backdrop != null)
            Image.network(
              backdrop,
              height: 140,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : const SizedBox.shrink(),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: backdrop != null ? 0.55 : 0.0),
                  Colors.transparent,
                ],
              ),
            ),
            // The AppBar already shows the title, so the header only carries
            // the metadata line (year, kind, video/folder counts) — never a
            // second copy of the title.
            child: Text(
              _headerSubtitle(movie, videoCount, folderCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _headerSubtitle(TmdMovie? movie, int videoCount, int folderCount) {
    final countParts = <String>[
      videoCount == 1 ? '1 video' : '$videoCount videos',
      if (folderCount > 0)
        folderCount == 1 ? '1 folder' : '$folderCount folders',
    ];
    final countLabel = countParts.join(' · ');
    if (movie == null) return countLabel;
    final parts = <String>[
      if (movie.kind == TmdKind.tv) 'TV Series',
      if (movie.year != null) '${movie.year}',
      countLabel,
    ];
    return parts.join(' · ');
  }
}

/// A Jellyfin folder/playable tile for the folder screen's item list.
class _JellyfinFolderTile extends StatelessWidget {
  const _JellyfinFolderTile({
    required this.item,
    required this.tmdbMeta,
    required this.onTap,
    this.watched = false,
    this.onToggleWatched,
  });

  final JellyfinItem item;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
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
      if (item.sizeLabel.isNotEmpty) item.sizeLabel,
    ].where((s) => s.isNotEmpty).join(' · ');

    final posterUrl = posterUrlOf(tmdbMeta);

    final subtitleWidget = subtitle.isEmpty ? null : Text(subtitle);

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
          IconButton(
            tooltip: watched ? 'Mark as unwatched' : 'Mark as watched',
            icon: Icon(
              watched ? Icons.check_circle : Icons.check_circle_outline,
              color:
                  watched ? Colors.green.shade400 : colorScheme.onSurfaceVariant,
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

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.entry,
    required this.tmdbMeta,
    required this.onTap,
    this.watched = false,
    this.onToggleWatched,
    this.episode,
    this.folderSeason,
  });

  final FileEntry entry;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
  final bool watched;
  final VoidCallback? onToggleWatched;
  final TmdEpisode? episode;
  final int? folderSeason;

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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
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
    final stillUrl = episode?.stillUrl();

    return TvTile(
      leading: stillUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                stillUrl,
                width: 64,
                height: 40,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _fallbackIcon(colorScheme, parsed),
              ),
            )
          : _fallbackIcon(colorScheme, parsed),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (parsed.isEpisode)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    effectiveLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              if (parsed.isEpisode) const SizedBox(width: 6),
              Expanded(
                child: Text(
                  episode?.nameLabel ?? parsed.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          if (episode != null && episode!.overview.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                episode!.overview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (episode != null && episode!.voteAverage > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.star, size: 12, color: Colors.amber),
                  const SizedBox(width: 2),
                  Text(
                    episode!.voteAverage.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          Text(
            _sizeLabel(entry.size),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            tooltip: watched ? 'Mark as unwatched' : 'Mark as watched',
            icon: Icon(
              watched ? Icons.check_circle : Icons.check_circle_outline,
              color:
                  watched ? Colors.green.shade400 : colorScheme.onSurfaceVariant,
            ),
            onPressed: onToggleWatched,
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _fallbackIcon(ColorScheme colorScheme, ParsedFileName parsed) {
    return Icon(
      parsed.isEpisode ? Icons.movie_outlined : Icons.play_circle_outline,
      color: colorScheme.secondary,
    );
  }
}

/// Nova-style series folder header: poster + title + year + rating + genres +
/// overview, shown at the top of the series folder view.
class _SeriesHeader extends StatelessWidget {
  const _SeriesHeader({
    required this.meta,
    required this.metadataKey,
    required this.onFixMatch,
    required this.onRemoveInfo,
    this.details,
  });

  final TmdMeta meta;
  final TmdDetails? details;
  final String metadataKey;
  final VoidCallback onFixMatch;
  final VoidCallback onRemoveInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final movie = meta.movie;
    final posterUrl = movie.posterUrl(width: 342);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: posterUrl != null
                    ? Image.network(
                        posterUrl,
                        width: 104,
                        height: 156,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _posterFallback(colorScheme),
                      )
                    : _posterFallback(colorScheme),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                    _RatingBadge(rating: movie.voteAverage),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (details?.genres != null)
                          for (final genre in details!.genres)
                            _FactChip(label: genre),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (details != null && details!.overview.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'Overview',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              details!.overview,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
          if (details != null && details!.cast.isNotEmpty) ...[
            const SizedBox(height: 20),
            _CastRow(cast: details!.cast),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: onFixMatch,
                child: const Text('Fix match'),
              ),
              TextButton(
                onPressed: onRemoveInfo,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                child: const Text('Remove info'),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Season expansion tile for the folder series view.
class _FolderSeasonExpansion extends StatelessWidget {
  const _FolderSeasonExpansion({
    required this.season,
    required this.expanded,
    required this.onToggle,
    required this.watchedCount,
    required this.total,
    required this.child,
    this.seasonName,
  });

  final int season;
  final bool expanded;
  final VoidCallback onToggle;
  final int watchedCount;
  final int total;
  final Widget child;
  final String? seasonName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final label = seasonName != null && seasonName!.isNotEmpty
        ? 'Season $season · $seasonName'
        : 'Season $season';

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  SeasonProgressRing(
                    watched: watchedCount,
                    total: total,
                    size: 28,
                    strokeWidth: 2.5,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '$watchedCount/$total',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) child,
        ],
      ),
    );
  }
}

/// Manual search dialog for fixing TMDB matches on folder series.
class _FolderSearchDialog extends StatefulWidget {
  const _FolderSearchDialog({this.initialQuery, this.initialYear, this.initialKind});

  final String? initialQuery;
  final int? initialYear;
  final TmdKind? initialKind;

  @override
  State<_FolderSearchDialog> createState() => _FolderSearchDialogState();
}

class _FolderSearchDialogState extends State<_FolderSearchDialog> {
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
    _kind = widget.initialKind ?? TmdKind.tv;
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
    final colorScheme = Theme.of(context).colorScheme;
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

/// Nova-style rating badge.
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

/// Fact chip for genres.
class _FactChip extends StatelessWidget {
  const _FactChip({required this.label});
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

/// Horizontal cast row with circular photos.
class _CastRow extends StatelessWidget {
  const _CastRow({required this.cast});
  final List<TmdCastMember> cast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cast',
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
                              errorBuilder: (_, _, _) =>
                                  _avatarFallback(colorScheme, member.name),
                            )
                          : _avatarFallback(colorScheme, member.name),
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
                          color: colorScheme.onSurfaceVariant,
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
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
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
