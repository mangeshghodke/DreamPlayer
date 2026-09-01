import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/file_browser.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/smb_client.dart';
import '../services/tmdb_client.dart';
import '../services/watched_store.dart';
import '../services/webdav_client.dart';
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
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Could not list this folder';
        _loading = false;
      });
    }
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
        builder: (_) => TmdDetailsScreen(video: _toVideoItem(entry)),
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
        builder: (_) => TmdDetailsScreen(video: _jellyfin.videoItem(server, item)),
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
        builder: (_) => TmdDetailsScreen(video: item),
      ),
    );
    await _loadSmb();
  }

  VideoItem _toVideoItem(FileEntry entry) {
    // Bookmarked-tree videos come back as content:// URIs (no real file
    // path), so hand those to the player's `uri` field.
    final isContentUri = entry.path.startsWith('content://');
    return VideoItem(
      id: 'folder_${widget.folder.id}_${entry.path.hashCode}',
      title: entry.name,
      path: isContentUri ? null : entry.path,
      uri: isContentUri ? entry.path : null,
      resumeKey: entry.resumeKey,
      duration: Duration.zero,
      sizeBytes: entry.size,
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

    Widget tileFor(Object e) {
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
          entry: FileEntry(name: smb.name, path: smb.path, isDirectory: smb.isDirectory, size: smb.size, resumeKey: _watchedKeyForEntry(smb)),
          tmdbMeta: smb.isDirectory ? null : _tmdbForSmb(smb),
          watched: _watchedKeys.contains(_watchedKeyForEntry(smb)),
          onToggleWatched: () => _toggleWatched(smb),
          onTap: () => _openSmbEntry(smb),
        );
      }
      final fileEntry = e as FileEntry;
      return _FolderTile(
        entry: fileEntry,
        tmdbMeta: fileEntry.isDirectory ? null : _tmdbFor(fileEntry),
        watched: _watchedKeys.contains(_watchedKeyForEntry(fileEntry)),
        onToggleWatched: () => _toggleWatched(fileEntry),
        onTap: () => _openEntry(fileEntry),
      );
    }

    return Column(
      children: [
        if (_atRoot) _header(context),
        Expanded(
          child: ListView(
            children: [
              for (final f in folders) tileFor(f),
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
                  for (final v in seasonGroups[s]!) tileFor(v),
                ],
              for (final m in movies) tileFor(m),
            ],
          ),
        ),
      ],
    );
  }

  bool _isFolderEntry(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).isFolder;
    if (_isSmb) return (e as SmbEntry).isDirectory;
    if (_isWebDav) return (e as Map)['isDirectory'] == true;
    return (e as FileEntry).isDirectory;
  }

  bool _isEpisode(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).type == 'Episode';
    if (_isSmb) return ParsedFileName.parse((e as SmbEntry).name).isEpisode;
    if (_isWebDav) {
      final name = (e as Map)['name'] as String? ?? '';
      return ParsedFileName.parse(name).isEpisode;
    }
    return ParsedFileName.parse((e as FileEntry).name).isEpisode;
  }

  int _seasonOf(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).parentIndexNumber ?? 0;
    if (_isSmb) return ParsedFileName.parse((e as SmbEntry).name).season;
    if (_isWebDav) {
      final name = (e as Map)['name'] as String? ?? '';
      return ParsedFileName.parse(name).season;
    }
    return ParsedFileName.parse((e as FileEntry).name).season;
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
  });

  final FileEntry entry;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
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

    // Episode files get their parsed SxxExx label next to the size.
    final parsed = ParsedFileName.parse(entry.name);
    final subtitle = <String>[
      if (parsed.isEpisode) parsed.episodeLabel,
      _sizeLabel(entry.size),
    ].where((s) => s.isNotEmpty).join(' · ');

    final posterUrl = posterUrlOf(tmdbMeta);

    final subtitleWidget = subtitle.isEmpty ? null : Text(subtitle);

    return TvTile(
      leading: posterUrl != null
          ? _Poster(posterUrl: posterUrl)
          : Icon(
              parsed.isEpisode ? Icons.movie_outlined : Icons.play_circle_outline,
              color: colorScheme.secondary,
            ),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
