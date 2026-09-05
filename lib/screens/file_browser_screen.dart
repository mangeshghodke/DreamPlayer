import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/file_browser.dart';
import '../services/tmdb_client.dart';
import '../services/resume_progress_helper.dart';
import '../services/watched_store.dart';
import '../utils/file_info_extractor.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

/// In-app file browser (CX-Explorer style): browse the device's storage and
/// play any video without importing it into the library.
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen>
    with WidgetsBindingObserver {
  static final FileBrowserService _service = FileBrowserService.instance;

  List<FileEntry> _roots = const [];
  String? _currentPath;
  List<FileEntry> _entries = const [];
  bool _loading = true;
  bool _hasAccess = true;
  String? _error;

  /// Watched marks for the current folder, keyed by each file's stable resume
  /// key for playback.
  Set<String> _watchedKeys = {};

  Map<String, int> _resumePositionsMs = {};
  Map<String, int> _durationsMs = {};

  bool get _atRoot => _currentPath == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    TmdService.instance.addListener(_onTmdbChanged);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    TmdService.instance.removeListener(_onTmdbChanged);
    super.dispose();
  }

  void _onTmdbChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshWatched() async {
    try {
      final watched = await WatchedStore.load();
      if (mounted) setState(() => _watchedKeys = watched);
    } catch (_) {}
    await _refreshResumes();
  }

  Future<void> _refreshResumes() async {
    final keys = <String>{};
    for (final e in _entries) {
      if (e.isDirectory) continue;
      if (e.resumeKey != null && e.resumeKey!.isNotEmpty) keys.add(e.resumeKey!);
      if (e.path.isNotEmpty) keys.add(e.path);
    }
    if (keys.isEmpty) return;
    try {
      final result = await ResumeProgressHelper.load(keys.toList());
      if (mounted) {
        setState(() {
          _resumePositionsMs = result.positions;
          _durationsMs = result.durations;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleWatched(FileEntry entry) async {
    final key = entry.resumeKey ?? entry.path;
    if (entry.isDirectory || key.isEmpty) return;
    final now = !_watchedKeys.contains(key);
    setState(() {
      _watchedKeys = {..._watchedKeys};
      now ? _watchedKeys.add(key) : _watchedKeys.remove(key);
    });
    try {
      await WatchedStore.set(key, now);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_hasAccess) {
      _init();
    }
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hasAccess = await _service.hasAllFilesAccess();
      if (!hasAccess) {
        if (mounted) {
          setState(() {
            _hasAccess = false;
            _loading = false;
          });
        }
        return;
      }
      _hasAccess = true;
      if (_currentPath == null) {
        await _loadRoots();
      } else {
        await _load(_currentPath!);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? 'Something went wrong';
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadRoots() async {
    final roots = await _service.storageRoots();
    if (!mounted) return;
    setState(() {
      _roots = roots;
      _entries = roots;
      _loading = false;
    });
    _prefetchTmdb(roots);
  }

  Future<void> _load(String path) async {
    final entries = await _service.listDirectory(path);
    if (!mounted) return;
    setState(() {
      _currentPath = path;
      _entries = entries;
      _loading = false;
    });
    _prefetchTmdb(entries);
    await _refreshWatched();
  }

  void _prefetchTmdb(List<FileEntry> entries) {
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      TmdService.instance.resolve(_toVideoItem(entry)).catchError((_) {
        return null;
      });
    }
  }

  Future<void> _openEntry(FileEntry entry) async {
    if (entry.isDirectory) {
      if (entry.isFilesHome) {
        // iOS: the virtual "Files" root — open the system Files-app home and
        // play whatever video the user picks.
        final picked = await _service.openFilesHome();
        if (picked == null || !mounted) return;
        _playVideo(picked);
        return;
      }
      setState(() => _loading = true);
      await _load(entry.path);
    } else {
      _playVideo(entry);
    }
  }

  /// Opens a video's details page first (TMDB metadata + Play/Resume button),
  /// like the WebDAV/Jellyfin browsers.
  Future<void> _playVideo(FileEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(video: _toVideoItem(entry)),
      ),
    );
    _refreshResumes();
  }

  VideoItem _toVideoItem(FileEntry entry) {
    // Bookmarked-tree videos come back as content:// URIs (no real file
    // path), so hand those to the player's `uri` field.
    final isContentUri = entry.path.startsWith('content://');
    final info = extractFileInfo(entry.name);
    return VideoItem(
      id: 'file_${entry.path.hashCode}',
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

  Future<void> _goUp() async {
    if (_atRoot) {
      Navigator.of(context).pop();
      return;
    }
    final rootPaths = _roots.map((r) => r.path).toSet();
    final parent = _parentOf(_currentPath);
    // Currently viewing a root's contents: back to the roots list.
    if (rootPaths.contains(_currentPath) || parent == null) {
      setState(() {
        _currentPath = null;
        _entries = _roots;
        _loading = false;
      });
      return;
    }
    // One level up. When the parent is itself a root, still show its contents
    // (the page you came from) rather than skipping to the roots list.
    setState(() => _loading = true);
    await _load(parent);
  }

  /// Forgets a bookmarked folder.
  Future<void> _removeBookmark(FileEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove folder?'),
        content: Text(
          '"${entry.name}" will no longer appear here. You can add it again '
          'anytime.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.removeBookmark(entry.bookmarkId!);
      await _loadRoots();
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => _error = e.message ?? 'Could not remove the folder');
      }
    }
  }

  static String? _parentOf(String? path) {
    if (path == null) return null;
    final index = path.lastIndexOf('/');
    if (index <= 0) return null;
    return path.substring(0, index);
  }

  void _grantAccess() {
    _service.openAllFilesAccessSettings();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_atRoot,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _goUp();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(_atRoot
            ? 'Browse files'
            : (_currentPath?.split('/').lastOrNull ?? 'Files')),
        leading: IconButton(
          tooltip: 'Up',
          icon: const Icon(Icons.arrow_back),
          onPressed: _goUp,
        ),
      ),
      body: TvOverscan(child: _body(context)),
    ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Text('Error: $_error',
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    if (!_hasAccess) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_off_outlined, size: 64),
              const SizedBox(height: 16),
              Text(
                'All files access is needed to browse your storage',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _grantAccess,
                child: const Text('Grant access'),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('No videos or folders here'));
    }
    final items = <Widget>[
      for (final entry in _entries)
        _FileTile(
          entry: entry,
          onTap: () => _openEntry(entry),
          onRemove: _atRoot && entry.bookmarkId != null
              ? () => _removeBookmark(entry)
              : null,
          tmdbMeta: TmdService.instance.metaFor(
            TmdStore.identityKeyFor(_toVideoItem(entry)),
          ),
          watched: !entry.isDirectory &&
              _watchedKeys.contains(entry.resumeKey ?? entry.path),
          onToggleWatched:
              entry.isDirectory ? null : () => _toggleWatched(entry),
          resumeProgress: entry.isDirectory
              ? null
              : ResumeProgressHelper.progressFor(
                  entry.resumeKey?.isNotEmpty == true
                      ? entry.resumeKey!
                      : entry.path,
                  _resumePositionsMs,
                  _durationsMs,
                ),
        ),
    ];
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }
}

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

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.entry,
    required this.onTap,
    this.onRemove,
    this.tmdbMeta,
    this.watched = false,
    this.onToggleWatched,
    this.resumeProgress,
  });

  final FileEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final TmdMeta? tmdbMeta;
  final bool watched;
  final VoidCallback? onToggleWatched;
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onRemove != null)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove folder',
                onPressed: onRemove,
              )
            else
              const Icon(Icons.chevron_right),
          ],
        ),
        onTap: onTap,
      );
    }

    final parsed = ParsedFileName.parse(entry.name);
    final effectiveLabel = parsed.isEpisode
        ? 'S${parsed.season.toString().padLeft(2, '0')}E${parsed.episode.toString().padLeft(2, '0')}'
        : '';

    final posterUrl = posterUrlOf(tmdbMeta);

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
            parsed.isEpisode
                ? (tmdbMeta?.movie.title.isNotEmpty == true
                    ? tmdbMeta!.movie.title
                    : parsed.title)
                : (tmdbMeta?.movie.title.isNotEmpty == true
                    ? tmdbMeta!.movie.title
                    : entry.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
        if (tmdbMeta != null && tmdbMeta!.movie.voteAverage > 0) ...[
          const SizedBox(width: 6),
          const Icon(Icons.star, size: 13, color: Colors.amber),
          const SizedBox(width: 2),
          Text(
            tmdbMeta!.movie.voteAverage.toStringAsFixed(1),
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
          if (onRemove != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove folder',
              onPressed: onRemove,
            ),
        ],
      ),
      onTap: onTap,
    );
  }
}
