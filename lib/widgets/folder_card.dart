import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/file_browser.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';
import '../services/watched_store.dart';
import '../utils/season_group.dart' as sg;
import '../utils/tv_helper.dart';
import 'season_progress_ring.dart';

/// Library card for a user-added folder. Shows the folder's TMDB match (poster
/// art, real title, year, TV/Movie chip) when one resolves, otherwise the
/// server-provided [JellyfinItemInfo] for Jellyfin folders, otherwise a
/// gradient + folder icon placeholder.
class FolderCard extends StatefulWidget {
  const FolderCard({
    super.key,
    required this.folder,
    required this.tmdbMeta,
    this.jellyfinInfo,
    required this.onTap,
    this.onLongPress,
  });

  final LibraryFolder folder;
  final TmdMeta? tmdbMeta;

  /// Server-side metadata for a Jellyfin library folder (poster/title/year),
  /// used when no TMDB match is available.
  final JellyfinItemInfo? jellyfinInfo;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<FolderCard> createState() => _FolderCardState();
}

class _FolderCardState extends State<FolderCard> {
  /// Owned focus node handed to the InkWell. Putting focus directly on the
  /// InkWell (rather than a wrapping `Focus`) means D-pad traversal reaches the
  /// card AND `select`/enter activates it through the InkWell's own
  /// ActivateIntent handler. The highlight follows the node via
  /// [ListenableBuilder].
  final FocusNode _focusNode = FocusNode();

  /// TV long-press: hold select/enter for 500 ms to fire [onLongPress].
  Timer? _holdTimer;
  bool _longPressFired = false;

  int? _seasonWatched;
  int? _seasonTotal;
  int? _seasonNumber;

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = _handleKeyEvent;
    _loadSeasonProgress();
  }

  @override
  void didUpdateWidget(FolderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.folder.id != widget.folder.id ||
        oldWidget.tmdbMeta != widget.tmdbMeta ||
        oldWidget.jellyfinInfo != widget.jellyfinInfo) {
      _loadSeasonProgress();
    }
  }

  bool get _isShow {
    final meta = widget.tmdbMeta;
    if (meta != null) return meta.movie.kind == TmdKind.tv;
    final info = widget.jellyfinInfo;
    if (info != null) return info.isTv;
    return false;
  }

  Future<void> _loadSeasonProgress() async {
    if (!_isShow) return;
    try {
      final folder = widget.folder;
      final watchedKeys = await WatchedStore.load();
      if (folder.isJellyfin) {
        final client = JellyfinClient();
        final server = await client.serverForUrl(folder.jellyfinServerUrl ?? '');
        if (server == null || !server.isAuthenticated) return;
        final items = await client.getItems(server, folder.jellyfinItemId ?? '');
        final playables = items.where((i) => i.isPlayable).toList();
        if (playables.isEmpty) return;
        final episodes = playables
            .where((i) => i.parentIndexNumber != null && i.indexNumber != null)
            .toList();
        final List<dynamic> source = episodes.isNotEmpty ? episodes : playables;
        // Group if episodes, else treat as single season 1.
        Map<int, List<dynamic>> grouped;
        if (episodes.isNotEmpty) {
          grouped = sg.groupBySeason<dynamic>(
            episodes,
            (e) => (e as JellyfinItem).parentIndexNumber ?? 0,
            (e) => (e as JellyfinItem).indexNumber ?? 0,
          );
        } else {
          grouped = {1: source};
        }
        if (grouped.isEmpty) return;
        final season = grouped.keys.reduce((a, b) => a < b ? a : b);
        final list = grouped[season]!;
        final watched = sg.watchedCount<dynamic>(
          list,
          watchedKeys,
          (e) {
            final item = e as JellyfinItem;
            return client.videoItem(server, item).resumeKey;
          },
        );
        if (!mounted) return;
        setState(() {
          _seasonNumber = season;
          _seasonWatched = watched;
          _seasonTotal = list.length;
        });
      } else {
        final entries =
            await FileBrowserService.instance.listDirectory(folder.path);
        final videos = entries.where((e) => !e.isDirectory).toList();
        if (videos.isEmpty) return;
        final episodes = videos
            .where((e) => ParsedFileName.parse(e.name).isEpisode)
            .toList();
        final List<FileEntry> source =
            episodes.isNotEmpty ? episodes : videos;
        Map<int, List<FileEntry>> grouped;
        if (episodes.isNotEmpty) {
          grouped = sg.groupBySeason<FileEntry>(
            episodes,
            (e) => ParsedFileName.parse(e.name).season,
            (e) => ParsedFileName.parse(e.name).episode,
          );
        } else {
          grouped = {1: source};
        }
        if (grouped.isEmpty) return;
        final season = grouped.keys.reduce((a, b) => a < b ? a : b);
        final list = grouped[season]!;
        final watched = sg.watchedCount<FileEntry>(
          list,
          watchedKeys,
          (e) => e.resumeKey,
        );
        if (!mounted) return;
        setState(() {
          _seasonNumber = season;
          _seasonWatched = watched;
          _seasonTotal = list.length;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!isTvMode(context)) return KeyEventResult.ignored;

    if (event is KeyDownEvent && _isSelectKey(event)) {
      _longPressFired = false;
      _holdTimer?.cancel();
      _holdTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        _longPressFired = true;
        widget.onLongPress?.call();
      });
      return KeyEventResult.handled;
    }
    // Auto-repeat while holding: swallow, or ActivateIntent fires onTap
    // mid-hold (folder opens *and* the remove dialog appears).
    if (event is KeyRepeatEvent && _isSelectKey(event)) {
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent && _isSelectKey(event)) {
      _holdTimer?.cancel();
      if (!_longPressFired) {
        widget.onTap();
      }
      _longPressFired = false;
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static String _networkLabel(LibraryFolder folder) {
    switch (folder.source) {
      case LibraryFolderSource.smb:
        return folder.networkLabel?.isNotEmpty == true ? 'SMB · ${folder.networkLabel}' : 'SMB';
      case LibraryFolderSource.webdav:
        return folder.networkLabel?.isNotEmpty == true ? 'WebDAV · ${folder.networkLabel}' : 'WebDAV';
      case LibraryFolderSource.ftp:
        return folder.networkLabel?.isNotEmpty == true ? 'FTP · ${folder.networkLabel}' : 'FTP';
      case LibraryFolderSource.upnp:
        return 'DLNA';
      case LibraryFolderSource.jellyfin:
        return 'Jellyfin';
      case LibraryFolderSource.files:
        return '';
    }
  }

  static Color _networkColor(LibraryFolder folder) {
    switch (folder.source) {
      case LibraryFolderSource.smb:
        return const Color(0xFF1976D2);
      case LibraryFolderSource.webdav:
        return const Color(0xFFEF6C00);
      case LibraryFolderSource.ftp:
        return const Color(0xFF6A1B9A);
      case LibraryFolderSource.upnp:
        return const Color(0xFF455A64);
      case LibraryFolderSource.jellyfin:
        return const Color(0xFF00B8A9);
      case LibraryFolderSource.files:
        return Colors.transparent;
    }
  }

  static bool _isSelectKey(KeyEvent e) =>
      e.physicalKey == PhysicalKeyboardKey.enter ||
      e.physicalKey == PhysicalKeyboardKey.select ||
      e.logicalKey == LogicalKeyboardKey.enter ||
      e.logicalKey == LogicalKeyboardKey.select;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final folder = widget.folder;
    final onTap = widget.onTap;
    final onLongPress = widget.onLongPress;
    final movie = widget.tmdbMeta?.movie;
    final hasMeta = movie != null && movie.title.isNotEmpty;
    final info = widget.jellyfinInfo;
    final hasJellyfin = info != null && info.name.isNotEmpty;
    final title = hasMeta
        ? movie.title
        : (hasJellyfin ? info.name : folder.name);
    final networkTag = folder.isNetwork ? _networkLabel(folder) : null;
    final subtitle = hasMeta
        ? [
            if (movie.year != null) '${movie.year}',
            movie.kind == TmdKind.tv ? 'TV Series' : 'Movie',
            if (networkTag != null && networkTag.isNotEmpty) networkTag,
          ].join(' · ')
        : hasJellyfin
            ? [
                if (info.kindLabel.isNotEmpty) info.kindLabel,
                if (info.year != null) '${info.year}',
                'Jellyfin',
              ].where((s) => s.isNotEmpty).join(' · ')
            : [
                if (folder.name.isNotEmpty) folder.name,
                if (networkTag != null && networkTag.isNotEmpty) networkTag,
              ].join(' · ');

    // Poster: TMDB when matched, else the Jellyfin server art, else the
    // gradient placeholder.
    final posterUrl = hasMeta
        ? movie.posterUrl()
        : (hasJellyfin ? info.imageUrl : null);

    // TV/Movie badge: TMDB kind, else the Jellyfin type, else none.
    final kindBadge = hasMeta
        ? (movie.kind == TmdKind.tv ? 'TV' : 'Movie')
        : (hasJellyfin && info.kindLabel.isNotEmpty
            ? (info.isTv ? 'TV' : 'Movie')
            : null);
    final kindColor = (hasMeta && movie.kind == TmdKind.tv) ||
            (hasJellyfin && info.isTv)
        ? const Color(0xFF9C27B0)
        : const Color(0xFF1565C0);

    final tv = isTvMode(context);

    return ListenableBuilder(
      listenable: _focusNode,
      builder: (context, _) {
        final focused = tv && _focusNode.hasFocus;
        return AnimatedScale(
          scale: focused ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: focused
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.4),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  )
                : null,
            child: Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                focusNode: _focusNode,
                onTap: onTap,
                onLongPress: onLongPress,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          DecoratedBox(
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
                              child: Icon(
                                Icons.video_library_outlined,
                                size: 40,
                                color: Colors.white54,
                              ),
                            ),
                          ),
                          if (posterUrl != null)
                            Image.network(
                              posterUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                              loadingBuilder: (context, child, progress) =>
                                  progress == null
                                      ? child
                                      : const SizedBox.shrink(),
                            ),
                          if (kindBadge != null)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: _FolderBadge(
                                label: kindBadge,
                                background: kindColor,
                              ),
                            ),
                          if (folder.isNetwork)
                            Positioned(
                              top: 8,
                              left: 8,
                              child: _FolderBadge(
                                label: _networkLabel(folder),
                                background: _networkColor(folder),
                              ),
                            ),
                          if (_isShow &&
                              _seasonWatched != null &&
                              _seasonTotal != null &&
                              _seasonTotal! > 0)
                            Positioned(
                              bottom: 8,
                              right: 8,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: SeasonProgressRing(
                                  watched: _seasonWatched!,
                                  total: _seasonTotal!,
                                  size: 32,
                                  strokeWidth: 2.5,
                                ),
                              ),
                            ),
                          if (_isShow &&
                              _seasonWatched != null &&
                              _seasonTotal != null &&
                              _seasonNumber != null &&
                              _seasonTotal! > 0)
                            Positioned(
                              bottom: 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  sg.seasonBadge(_seasonNumber!,
                                      _seasonWatched!, _seasonTotal!),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FolderBadge extends StatelessWidget {
  const _FolderBadge({required this.label, required this.background});

  final String label;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
