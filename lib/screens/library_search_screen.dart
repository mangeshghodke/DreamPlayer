import 'dart:async';

import 'package:flutter/material.dart';

import '../services/library_folders.dart';
import '../services/manual_groups.dart';
import '../services/network_video_resolver.dart';
import '../services/series_grouping.dart';
import '../services/tmdb_client.dart';
import '../utils/display_title.dart';
import '../utils/search_match.dart';
import '../widgets/library_list_row.dart';
import '../widgets/tv_overscan.dart';
import 'movie_group_screen.dart';
import 'series_seasons_screen.dart';
import 'tmd_details_screen.dart';

/// One row on the search screen.
///
/// Folders, file entries and manual groups are three different things to
/// *open*, so the row carries whichever one produced it instead of a closure:
/// the tap handler needs the [SeriesGroup] for season pages and the
/// [LibraryFolder] for a file, and a single `onTap` would hide which is which.
class _Hit {
  const _Hit({
    required this.rank,
    required this.title,
    required this.subtitle,
    required this.meta,
    this.group,
    this.file,
    this.manual,
    this.members = const [],
  });

  final int rank;
  final String title;
  final String subtitle;
  final TmdMeta? meta;
  final SeriesGroup? group;
  final LibraryFolder? file;
  final ManualGroup? manual;
  final List<LibraryFolder> members;

  String get sortKey => title.toLowerCase();
}

/// Search across everything the home library already knows about - series
/// folders, the file entries the scanner expanded from them, and manual
/// groups.
///
/// It is deliberately **offline and instant**: the entries come from
/// `LibraryFoldersStore`, which is exactly what Home renders, so no network
/// listing runs while the user types. Searching *inside* a folder that was
/// never expanded would cost one round-trip per folder on every keystroke
/// (SMB/WebDAV/FTP/UPnP), so it is not done here - a folder result opens that
/// folder instead.
class LibrarySearchScreen extends StatefulWidget {
  const LibrarySearchScreen({super.key});

  @override
  State<LibrarySearchScreen> createState() => _LibrarySearchScreenState();
}

class _LibrarySearchScreenState extends State<LibrarySearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  List<LibraryFolder> _folders = const [];
  List<ManualGroup> _manual = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged() => setState(() {});

  Future<void> _load() async {
    final folders = await LibraryFoldersStore.load();
    final manual = await ManualGroupsStore.instance.load();
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _manual = manual;
      _loading = false;
    });
  }

  String get _query => _controller.text.trim();

  String _sourceLabel(LibraryFolderSource source) => switch (source) {
    LibraryFolderSource.files => 'On device',
    LibraryFolderSource.jellyfin => 'Jellyfin',
    LibraryFolderSource.smb => 'SMB',
    LibraryFolderSource.webdav => 'WebDAV',
    LibraryFolderSource.ftp => 'FTP',
    LibraryFolderSource.upnp => 'DLNA',
  };

  /// All matching folders, file entries and manual groups, best match first.
  List<_Hit> _search() {
    if (_query.isEmpty) return const [];
    final service = TmdService.instance;
    final hits = <_Hit>[];

    // --- Series / folder cards: the same grouping Home renders. -----------
    final groups = SeriesGroupingService().group(
      _folders.where((f) => !f.isFile).toList(),
    );
    for (final group in groups) {
      final meta = service.metaFor(group.metadataKey);
      final title = folderDisplayTitle(folder: group.primary, meta: meta);
      final seasonNames =
          meta?.seasons.values
              .map((s) => s.name)
              .where((n) => n.isNotEmpty)
              .toList() ??
          const <String>[];
      final rank = searchRank(
        _query,
        primary: title,
        secondary: [
          group.primary.name,
          ...group.folders.map((f) => f.name),
          meta?.movie.originalTitle,
          ...seasonNames,
        ],
      );
      if (rank == null) continue;
      final count = group.folders.length;
      hits.add(
        _Hit(
          rank: rank,
          title: title,
          subtitle: count > 1
              ? '${_sourceLabel(group.primary.source)} · $count folders'
              : _sourceLabel(group.primary.source),
          meta: meta,
          group: group,
        ),
      );
    }

    // --- Manual groups keep their user-typed name. ------------------------
    for (final manual in _manual) {
      final members = _folders
          .where((f) => manual.folderIds.contains(f.id))
          .toList();
      if (members.isEmpty) continue; // stale group, pruned on Home
      final rank = searchRank(
        _query,
        primary: manual.name,
        secondary: members.map((f) => f.name),
      );
      if (rank == null) continue;
      hits.add(
        _Hit(
          rank: rank,
          title: manual.name,
          subtitle: 'Group · ${members.length} items',
          meta: manual.posterMeta ?? service.metaFor(members.first.metadataKey),
          manual: manual,
          members: members,
        ),
      );
    }

    // --- Expanded file entries (episodes / films added as individual cards).
    for (final file in _folders.where((f) => f.isFile)) {
      final meta = service.metaFor(file.metadataKey);
      final parsed = ParsedFileName.parse(file.name);
      final metaTitle = meta?.movie.title ?? '';
      final title = metaTitle.isNotEmpty
          ? metaTitle
          : (parsed.isEpisode && (parsed.seriesName ?? '').isNotEmpty
                ? parsed.seriesName!
                : parsed.title);
      final rank = searchRank(
        _query,
        primary: title,
        secondary: [file.name, parsed.episodeLabel, meta?.movie.originalTitle],
      );
      if (rank == null) continue;
      hits.add(
        _Hit(
          rank: rank,
          title: title,
          subtitle: [
            if (parsed.episodeLabel.isNotEmpty) parsed.episodeLabel,
            if (parsed.isEpisode && metaTitle.isNotEmpty) file.name,
            _sourceLabel(file.source),
            if ((file.videoSizeBytes ?? 0) > 0)
              _sizeLabel(file.videoSizeBytes!),
          ].join(' · '),
          meta: meta,
          file: file,
        ),
      );
    }

    hits.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      return byRank != 0 ? byRank : a.sortKey.compareTo(b.sortKey);
    });
    return hits;
  }

  static String _sizeLabel(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} '
        '${units[unit]}';
  }

  Future<void> _open(_Hit hit) async {
    if (hit.manual != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MovieGroupScreen(
            group: SeriesGroup(
              baseName: '',
              displayName: hit.manual!.name,
              folders: hit.members,
            ),
            posterMeta: hit.manual!.posterMeta,
            manualGroupId: hit.manual!.id,
          ),
        ),
      );
      return;
    }
    final file = hit.file;
    if (file != null) {
      final video = await NetworkVideoResolver.resolve(file);
      if (!mounted) return;
      if (video == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Can't open this file - its source is unavailable."),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TmdDetailsScreen(
            video: video,
            parentMetadataKey: file.metadataKey,
          ),
        ),
      );
      return;
    }
    final group = hit.group;
    if (group == null) return;
    final isMovie = hit.meta?.movie.kind == TmdKind.movie;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => group.folders.length == 1 && isMovie
            ? TmdDetailsScreen(folder: group.primary)
            : SeriesSeasonsScreen(group: group),
      ),
    );
  }

  Widget _art(_Hit hit) => FolderRowArt(meta: hit.meta);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hits = _search();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: theme.textTheme.titleMedium,
          decoration: const InputDecoration(
            hintText: 'Search your library',
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Clear',
              onPressed: () => _controller.clear(),
            ),
        ],
      ),
      body: TvOverscan(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : hits.isEmpty
            ? _emptyState(theme)
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: hits.length,
                itemBuilder: (context, index) {
                  final hit = hits[index];
                  return LibraryListRow(
                    title: hit.title,
                    subtitle: hit.subtitle,
                    leading: _art(hit),
                    onTap: () => unawaited(_open(hit)),
                  );
                },
              ),
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    final searching = _query.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              searching ? Icons.search_off : Icons.search,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              searching
                  ? 'Nothing in your library matches “$_query”.'
                  : 'Search by title, folder or file name.\n'
                        'Only what is already in your library is searched.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
