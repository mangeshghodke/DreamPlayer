import 'dart:async';

import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/file_browser.dart';
import '../services/ftp_client.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/resume_progress_helper.dart';
import '../services/series_grouping.dart';
import '../services/smb_client.dart';
import '../services/tmdb_client.dart';
import '../services/upnp_client.dart';
import '../services/watched_store.dart';
import '../services/webdav_client.dart';
import '../utils/season_group.dart' as sg;
import '../utils/tv_helper.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

/// Flux-style "all seasons" view for a [SeriesGroup] (one or more library
/// folders collapsed into a single series card). When a series has only
/// one folder, the user is taken straight to the existing per-folder
/// flow (so behavior stays identical to v0.4.0). When the group has
/// multiple folders (e.g. `Strike the Blood`, `Strike the Blood II`,
/// `Strike the Blood III`, `Strike the Blood IV`), this screen shows all
/// seasons from all folders in one place.
///
/// This is the in-app equivalent of Flux's "Series → Seasons" hierarchy.
class SeriesSeasonsScreen extends StatefulWidget {
  const SeriesSeasonsScreen({super.key, required this.group});

  final SeriesGroup group;

  @override
  State<SeriesSeasonsScreen> createState() => _SeriesSeasonsScreenState();
}

class _SeriesSeasonsScreenState extends State<SeriesSeasonsScreen> {
  bool _loading = true;
  String? _error;
  final List<({
    String folderLabel,
    String metadataKey,
    List<Object> entries,
    int? folderSeason,
  })> _folders = [];
  TmdMeta? _meta;
  TmdDetails? _details;
  Set<String> _watchedKeys = {};
  Map<String, int> _resumePositionsMs = {};
  Map<String, int> _durationsMs = {};

  String get _groupKey => widget.group.metadataKey;

  @override
  void initState() {
    super.initState();
    TmdService.instance.addListener(_onMetadataChanged);
    WatchedStore.load().then((w) {
      if (mounted) setState(() => _watchedKeys = w);
    });
    _load();
  }

  @override
  void dispose() {
    TmdService.instance.removeListener(_onMetadataChanged);
    super.dispose();
  }

  void _onMetadataChanged() {
    if (!mounted) return;
    final meta = TmdService.instance.metaFor(_groupKey);
    // detailsFor is async — fire and forget; if it returns, refresh again.
    TmdService.instance.detailsFor(_groupKey).then((d) {
      if (!mounted) return;
      setState(() => _details = d);
    });
    setState(() => _meta = meta);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Resolve TMDB for the primary folder's group key.
      final service = TmdService.instance;
      await service.ensureLoaded();

      // Use the cached meta if available; otherwise resolve fresh.
      var meta = service.metaFor(_groupKey);
      meta ??= await service.resolveFolder(
        _groupKey,
        widget.group.displayName,
        yearHint: widget.group.primary.yearHint,
      );

      // Fetch details (overview, genres, etc.) — this is what the old
      // implementation skipped, causing the null-details blank header.
      final details = await service.detailsFor(_groupKey);

      if (!mounted) return;
      setState(() {
        _meta = meta;
        _details = details;
      });

      // List files from each folder in the group, matching each folder to its
      // TMDB season using the season names already fetched by the group-level
      // resolveFolder (no extra API calls).
      final folderEntries = <({
        String folderLabel,
        String metadataKey,
        List<Object> entries,
        int? folderSeason,
      })>[];
      final showId = meta?.movie.id;
      for (final folder in widget.group.folders) {
        // Match folder name to season using cached season names — no API calls.
        int? folderSeason;
        if (showId != null) {
          folderSeason = service.matchFolderToSeason(folder.name, showId);
        }
        // If no season match, try resolveFolder (cached or fresh).
        if (folderSeason == null) {
          final folderMeta = await service.resolveFolder(
            folder.metadataKey,
            folder.name,
            yearHint: folder.yearHint,
          );
          folderSeason = folderMeta?.folderSeason;
        }

        final entries = await _listFolder(folder);
        folderEntries.add((
          folderLabel: folder.name,
          metadataKey: folder.metadataKey,
          entries: entries,
          folderSeason: folderSeason,
        ));
      }
      if (!mounted) return;
      setState(() {
        _folders
          ..clear()
          ..addAll(folderEntries);
        _loading = false;
      });

      // Fetch season data AFTER _folders is populated — _fetchSeasonData reads
      // _folders to collect all folderSeason values it needs to fetch.
      await _fetchSeasonData(meta);

      // Refresh resume positions for everything we found.
      _refreshResumes();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Fetch per-season TMDB data for the matched show so episode stills,
  /// names, and overviews populate in the list.
  Future<void> _fetchSeasonData(TmdMeta? meta) async {
    if (meta == null || meta.movie.kind != TmdKind.tv) return;
    final service = TmdService.instance;

    // Collect all unique folderSeason values across the group — each folder
    // maps to a different TMDB season (e.g. "Strike the Blood II" → Season 2).
    final seasonsNeeded = <int>{};
    for (final f in _folders) {
      if (f.folderSeason != null && f.folderSeason! > 0) {
        seasonsNeeded.add(f.folderSeason!);
      }
    }
    // Always fetch at least season 1 for anime bracket numbering ([01]/[02]).
    if (seasonsNeeded.isEmpty) seasonsNeeded.add(1);

    for (final seasonNum in seasonsNeeded) {
      await service.seasonFor(_groupKey, seasonNum);
      if (!mounted) return;
    }

    // Read the latest meta from the cache (each seasonFor replaces it).
    final freshMeta = service.metaFor(_groupKey) ?? meta;
    setState(() => _meta = freshMeta);
  }

  Future<List<Object>> _listFolder(LibraryFolder folder) async {
    if (folder.isJellyfin) return _listJellyfin(folder);
    if (folder.source == LibraryFolderSource.smb) return _listSmb(folder);
    if (folder.source == LibraryFolderSource.webdav) return _listWebDav(folder);
    if (folder.source == LibraryFolderSource.ftp) return _listFtp(folder);
    if (folder.source == LibraryFolderSource.upnp) return _listUpnp(folder);
    return _listLocal(folder);
  }

  Future<List<Object>> _listLocal(LibraryFolder folder) async {
    final entries = await FileBrowserService.instance.listDirectory(folder.path);
    return entries;
  }

  Future<List<Object>> _listSmb(LibraryFolder folder) async {
    final entries = await SmbClient.instance.listDirectory(
      folder.networkServerId ?? '',
      folder.networkShare ?? '',
      folder.networkPath ?? '',
    );
    return entries;
  }

  Future<List<Object>> _listWebDav(LibraryFolder folder) async {
    final entries = await WebDavClient.instance
        .listDirectory(folder.networkServerId ?? '', folder.networkPath ?? '');
    return entries;
  }

  Future<List<Object>> _listFtp(LibraryFolder folder) async {
    final entries = await FtpClient.instance.listDirectory(
      folder.networkServerId ?? '',
      folder.networkPath ?? '',
    );
    return entries;
  }

  Future<List<Object>> _listUpnp(LibraryFolder folder) async {
    final entries = await UpnpClient.instance.browse(
      folder.networkServerId ?? '',
      folder.networkPath ?? '',
    );
    return entries;
  }

  Future<List<Object>> _listJellyfin(LibraryFolder folder) async {
    final client = JellyfinClient();
    final server = await client.serverForUrl(folder.jellyfinServerUrl ?? '');
    if (server == null) return const [];
    final items = await client.getItems(server, folder.jellyfinItemId ?? '');
    return items;
  }

  Future<void> _refreshResumes() async {
    final keys = <String>[];
    for (final f in _folders) {
      for (final e in f.entries) {
        final k = _resumeKeyFor(e);
        if (k != null && k.isNotEmpty) keys.add(k);
      }
    }
    if (keys.isEmpty) return;
    final result = await ResumeProgressHelper.load(keys);
    if (!mounted) return;
    setState(() {
      _resumePositionsMs = result.positions;
      _durationsMs = result.durations;
    });
  }

  String? _resumeKeyFor(Object entry) {
    if (entry is SmbEntry) {
      if (entry.isDirectory) return null;
      final folder = widget.group.folders.firstWhere(
        (f) => f.source == LibraryFolderSource.smb,
        orElse: () => widget.group.primary,
      );
      return 'smb:${folder.networkServerId ?? ''}/'
          '${folder.networkShare ?? ''}/${entry.path}';
    }
    if (entry is WebDavEntry) {
      if (entry.isDirectory) return null;
      final folder = widget.group.folders.firstWhere(
        (f) => f.source == LibraryFolderSource.webdav,
        orElse: () => widget.group.primary,
      );
      return 'webdav:${folder.networkServerId ?? ''}${entry.path}';
    }
    if (entry is FtpEntry) {
      if (entry.isDirectory) return null;
      final folder = widget.group.folders.firstWhere(
        (f) => f.source == LibraryFolderSource.ftp,
        orElse: () => widget.group.primary,
      );
      return 'ftp:${folder.networkServerId ?? ''}${entry.path}';
    }
    if (entry is UpnpEntry) {
      if (entry.isDirectory) return null;
      final folder = widget.group.folders.firstWhere(
        (f) => f.source == LibraryFolderSource.upnp,
        orElse: () => widget.group.primary,
      );
      return 'upnp:${folder.networkServerId ?? ''}${entry.id}';
    }
    if (entry is JellyfinItem) {
      if (entry.isFolder) return null;
      final folder = widget.group.folders.firstWhere(
        (f) => f.isJellyfin,
        orElse: () => widget.group.primary,
      );
      return 'jellyfin:${folder.jellyfinServerUrl ?? ''}/${entry.id}';
    }
    if (entry is FileEntry) {
      if (entry.isDirectory) return null;
      return entry.resumeKey ?? entry.path;
    }
    return null;
  }

  /// Builds the season-grouped view: one row per season, each holding
  /// every video file across the group's folders that maps to that season.
  Map<int, List<Object>> _seasonGroups() {
    final allEntries = <Object>[];
    for (final f in _folders) {
      allEntries.addAll(f.entries.where((e) => !_isFolder(e)));
    }
    return sg.groupBySeason<Object>(
      allEntries,
      (e) => _seasonOf(e),
      (e) => _episodeOf(e),
    );
  }

  bool _isFolder(Object e) {
    if (e is SmbEntry) return e.isDirectory;
    if (e is WebDavEntry) return e.isDirectory;
    if (e is FtpEntry) return e.isDirectory;
    if (e is UpnpEntry) return e.isDirectory;
    if (e is JellyfinItem) return e.isFolder;
    if (e is FileEntry) return e.isDirectory;
    return false;
  }

  int _seasonOf(Object e) {
    if (e is JellyfinItem) return e.parentIndexNumber ?? 1;

    // Find which folder this entry belongs to and use its folderSeason.
    for (final f in _folders) {
      if (f.entries.contains(e)) {
        if (f.folderSeason != null && f.folderSeason! > 0) {
          return f.folderSeason!;
        }
        break;
      }
    }

    // Fallback: parse the filename.
    final name = _nameOf(e);
    if (name.isEmpty) return 1;
    final parsed = ParsedFileName.parse(name);
    if (parsed.season > 0) return parsed.season;
    return 1;
  }

  int _episodeOf(Object e) {
    if (e is JellyfinItem) return e.indexNumber ?? 0;
    final name = _nameOf(e);
    if (name.isEmpty) return 0;
    final parsed = ParsedFileName.parse(name);
    return parsed.episode;
  }

  String _nameOf(Object e) {
    if (e is SmbEntry) return e.name;
    if (e is WebDavEntry) return e.name;
    if (e is FtpEntry) return e.name;
    if (e is UpnpEntry) return e.name;
    if (e is JellyfinItem) return e.name;
    if (e is FileEntry) return e.name;
    return '';
  }

  TmdEpisode? _episodeFor(Object e) {
    final season = _seasonOf(e);
    final ep = _episodeOf(e);
    if (ep <= 0) return null;
    return _meta?.seasons[season]?.episode(ep);
  }

  String _seasonLabel(int seasonNumber, int episodeCount) {
    final season = _meta?.seasons[seasonNumber];
    final tmdbName = season?.name.trim();
    if (tmdbName != null && tmdbName.isNotEmpty) {
      return '${sg.seasonHeader(seasonNumber)} · $tmdbName';
    }
    return sg.seasonHeader(seasonNumber);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tv = isTvMode(context);
    final backdrop = _meta?.movie.backdropUrl();
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: tv ? 200 : 220,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                _meta?.movie.title.isNotEmpty == true
                    ? _meta!.movie.title
                    : widget.group.displayName,
              ),
              background: backdrop != null
                  ? Image.network(
                      backdrop,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Container(color: theme.colorScheme.surfaceContainerHighest),
                    )
                  : Container(color: theme.colorScheme.surfaceContainerHighest),
            ),
          ),
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Error: $_error'),
                ),
              ),
            )
          else
            ..._buildBody(context),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }

  List<Widget> _buildBody(BuildContext context) {
    final grouped = _seasonGroups();
    final sortedSeasons = grouped.keys.toList()..sort();
    final slivers = <Widget>[];

    // Series header — poster + meta, only when TMDB resolved.
    final meta = _meta;
    if (meta != null && meta.movie.title.isNotEmpty) {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          sliver: SliverToBoxAdapter(
            child: _SeriesHeader(
              meta: meta,
              details: _details,
              onFixMatch: () => _fixMatch(),
            ),
          ),
        ),
      );
    }

    // Naming hint when no TMDB metadata resolved — tell the user to
    // name files with SxxExx patterns so the parser can find them.
    if (meta == null || meta.movie.title.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 8),
                    Text(
                      'Name your files for better results',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'For "${widget.group.displayName}", use SxxExx patterns '
                      '(e.g. S01E01, S02E05) or season folders '
                      '(e.g. Season 1/, Season 2/) so episodes are detected correctly.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Total file count header.
    final totalCount = grouped.values.fold<int>(0, (sum, l) => sum + l.length);
    slivers.add(
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Text(
                'Seasons',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(width: 8),
              Text(
                '$totalCount ${totalCount == 1 ? 'file' : 'files'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );

    for (final s in sortedSeasons) {
      final entries = grouped[s]!;
      entries.sort((a, b) => _episodeOf(a).compareTo(_episodeOf(b)));
      final watchedCount =
          sg.watchedCount(entries, _watchedKeys, _resumeKeyFor);
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverToBoxAdapter(
            child: ExpansionTile(
              initiallyExpanded: true,
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              shape: const Border(),
              collapsedShape: const Border(),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      _seasonLabel(s, entries.length),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  ),
                  _SeasonBadge(
                    text: sg.watchedBadge(watchedCount, entries.length),
                  ),
                ],
              ),
              children: [
                for (final entry in entries)
                  _EntryTile(
                    entry: entry,
                    resumePositionMs:
                        _resumePositionsMs[_resumeKeyFor(entry) ?? ''],
                    durationMs: _durationsMs[_resumeKeyFor(entry) ?? ''],
                    watched:
                        _watchedKeys.contains(_resumeKeyFor(entry) ?? ''),
                    seasonNumber: s,
                    episode: _episodeFor(entry),
                    onTap: () => _openEntry(entry),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  Future<void> _fixMatch() async {
    final picked = await showDialog<TmdMovie>(
      context: context,
      builder: (context) => _FixMatchDialog(
        initialQuery: widget.group.displayName,
        initialYear: ParsedFileName.parse(widget.group.displayName).year,
      ),
    );
    if (picked == null || !mounted) return;
    await TmdService.instance.setManualFolder(_groupKey, picked);
    if (mounted) setState(() {});
  }

  Future<void> _openEntry(Object entry) async {
    final item = await _toVideoItem(entry);
    if (item == null || !mounted) return;
    // Find which folder this entry belongs to and pass THAT folder's
    // metadataKey so TmdDetailsScreen resolves the correct folderSeason.
    String? entryMetadataKey;
    for (final f in _folders) {
      if (f.entries.contains(entry)) {
        entryMetadataKey = f.metadataKey;
        break;
      }
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: item,
          parentMetadataKey: entryMetadataKey,
        ),
      ),
    );
    if (!mounted) return;
    final w = await WatchedStore.load();
    if (!mounted) return;
    setState(() => _watchedKeys = w);
    _refreshResumes();
  }

  Future<VideoItem?> _toVideoItem(Object entry) async {
    if (entry is SmbEntry) {
      final folder = widget.group.folders.firstWhere(
        (f) => f.source == LibraryFolderSource.smb,
        orElse: () => widget.group.primary,
      );
      final serverId = folder.networkServerId ?? '';
      final share = folder.networkShare ?? '';
      final uri =
          await SmbClient.instance.openShare(serverId, share, entry.path);
      return VideoItem(
        id: 'smb_${folder.id}_${entry.path.hashCode}',
        title: entry.name,
        path: 'smb://$share/${entry.path}',
        uri: uri,
        resumeKey: 'smb:$serverId/$share/${entry.path}',
        duration: Duration.zero,
      );
    }
    if (entry is WebDavEntry) {
      final folder = widget.group.folders.firstWhere(
        (f) => f.source == LibraryFolderSource.webdav,
        orElse: () => widget.group.primary,
      );
      final resumeKey =
          'webdav:${folder.networkServerId ?? ''}${entry.path}';
      return VideoItem(
        id: 'webdav_${folder.id}_${entry.path.hashCode}',
        title: entry.name,
        path: entry.path,
        resumeKey: resumeKey,
        duration: Duration.zero,
      );
    }
    if (entry is FtpEntry) {
      final folder = widget.group.folders.firstWhere(
        (f) => f.source == LibraryFolderSource.ftp,
        orElse: () => widget.group.primary,
      );
      final resumeKey =
          'ftp:${folder.networkServerId ?? ''}${entry.path}';
      return VideoItem(
        id: 'ftp_${folder.id}_${entry.path.hashCode}',
        title: entry.name,
        path: entry.path,
        resumeKey: resumeKey,
        duration: Duration.zero,
      );
    }
    if (entry is UpnpEntry) {
      final folder = widget.group.folders.firstWhere(
        (f) => f.source == LibraryFolderSource.upnp,
        orElse: () => widget.group.primary,
      );
      return VideoItem(
        id: 'upnp_${folder.id}_${entry.id}',
        title: entry.name,
        uri: entry.url,
        resumeKey: 'upnp:${folder.networkServerId ?? ''}${entry.id}',
        duration: Duration.zero,
      );
    }
    if (entry is JellyfinItem) {
      final folder = widget.group.folders.firstWhere(
        (f) => f.isJellyfin,
        orElse: () => widget.group.primary,
      );
      final client = JellyfinClient();
      final server =
          await client.serverForUrl(folder.jellyfinServerUrl ?? '');
      if (server == null) return null;
      return client.videoItem(server, entry);
    }
    if (entry is FileEntry) {
      return VideoItem(
        id: 'file_${entry.path}',
        title: entry.name,
        path: entry.path,
        resumeKey: entry.resumeKey ?? entry.path,
        duration: Duration.zero,
      );
    }
    return null;
  }
}

class _SeasonBadge extends StatelessWidget {
  const _SeasonBadge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.onTap,
    required this.resumePositionMs,
    required this.durationMs,
    required this.watched,
    required this.seasonNumber,
    this.episode,
  });

  final Object entry;
  final VoidCallback onTap;
  final int? resumePositionMs;
  final int? durationMs;
  final bool watched;
  final int seasonNumber;
  final TmdEpisode? episode;

  String get _name {
    if (entry is SmbEntry) return (entry as SmbEntry).name;
    if (entry is WebDavEntry) return (entry as WebDavEntry).name;
    if (entry is FtpEntry) return (entry as FtpEntry).name;
    if (entry is UpnpEntry) return (entry as UpnpEntry).name;
    if (entry is JellyfinItem) return (entry as JellyfinItem).name;
    if (entry is FileEntry) return (entry as FileEntry).name;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final parsed = ParsedFileName.parse(_name);
    final hasEpisode = parsed.isEpisode;
    final stillUrl = episode?.stillUrl();
    final progress = (resumePositionMs != null &&
            resumePositionMs! > 0 &&
            durationMs != null &&
            durationMs! > 0)
        ? (resumePositionMs! / durationMs!).clamp(0.0, 1.0)
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TvTile(
            leading: stillUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                      stillUrl,
                      width: 64,
                      height: 40,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.movie_outlined,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  )
                : Icon(
                    Icons.movie_outlined,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
            title: Row(
              children: [
                if (hasEpisode)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      'S${seasonNumber.toString().padLeft(2, '0')}E${parsed.episode.toString().padLeft(2, '0')}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color:
                                Theme.of(context).colorScheme.onPrimaryContainer,
                          ),
                    ),
                  ),
                if (hasEpisode) const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    episode?.nameLabel ??
                        (parsed.isEpisode ? parsed.title : _name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                if (watched)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.check_circle,
                        color: Colors.green, size: 18),
                  ),
              ],
            ),
            onTap: onTap,
          ),
          if (progress != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(1),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary),
              ),
            ),
        ],
      ),
    );
  }
}

class _SeriesHeader extends StatelessWidget {
  const _SeriesHeader({
    required this.meta,
    required this.details,
    required this.onFixMatch,
  });

  final TmdMeta meta;
  final TmdDetails? details;
  final VoidCallback onFixMatch;

  @override
  Widget build(BuildContext context) {
    final movie = meta.movie;
    final rating = movie.voteAverage;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (movie.posterUrl() != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  movie.posterUrl()!,
                  width: 72,
                  height: 108,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    movie.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  if (details?.overview.isNotEmpty == true) ...[
                    const SizedBox(height: 4),
                    Text(
                      details!.overview,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (rating > 0) ...[
                        const Icon(Icons.star, size: 14, color: Colors.amber),
                        const SizedBox(width: 2),
                        Text(
                          rating.toStringAsFixed(1),
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(width: 12),
                      ],
                      TextButton(
                        onPressed: onFixMatch,
                        child: const Text('Fix match'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FixMatchDialog extends StatefulWidget {
  const _FixMatchDialog({
    required this.initialQuery,
    required this.initialYear,
  });

  final String initialQuery;
  final int? initialYear;

  @override
  State<_FixMatchDialog> createState() => _FixMatchDialogState();
}

class _FixMatchDialogState extends State<_FixMatchDialog> {
  final _query = TextEditingController();
  final _year = TextEditingController();
  bool _searching = false;
  List<TmdMovie> _results = const [];

  @override
  void initState() {
    super.initState();
    _query.text = widget.initialQuery;
    if (widget.initialYear != null) _year.text = widget.initialYear.toString();
  }

  @override
  void dispose() {
    _query.dispose();
    _year.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    setState(() => _searching = true);
    final results = await TmdApi().search(
      _query.text.trim(),
      year: int.tryParse(_year.text.trim()),
      kind: TmdKind.tv,
    );
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Fix TMDB match'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              decoration: const InputDecoration(labelText: 'Query'),
            ),
            TextField(
              controller: _year,
              decoration: const InputDecoration(labelText: 'Year (optional)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _searching ? null : _runSearch,
              child: Text(_searching ? 'Searching…' : 'Search'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _results.length,
                itemBuilder: (context, i) {
                  final r = _results[i];
                  return ListTile(
                    title: Text(r.title),
                    subtitle: r.year != null ? Text('${r.year}') : null,
                    onTap: () => Navigator.of(context).pop(r),
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
