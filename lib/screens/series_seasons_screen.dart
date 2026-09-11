import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    LibraryFolder folder,
  })> _folders = [];
  TmdMeta? _meta;
  TmdDetails? _details;
  Set<String> _watchedKeys = {};
  Map<String, int> _resumePositionsMs = {};
  Map<String, int> _durationsMs = {};
  Set<String> _hiddenSeasonFolderIds = {};

  String get _groupKey => widget.group.metadataKey;

  static const _hiddenSeasonsPrefKey = 'dreamplayer.hiddenSeriesSeasons';

  Future<void> _loadHiddenSeasons() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_hiddenSeasonsPrefKey) ?? const [];
    if (mounted) {
      setState(() => _hiddenSeasonFolderIds = list.toSet());
    } else {
      _hiddenSeasonFolderIds = list.toSet();
    }
  }

  Future<void> _saveHiddenSeasons() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _hiddenSeasonsPrefKey, _hiddenSeasonFolderIds.toList());
  }

  @override
  void initState() {
    super.initState();
    TmdService.instance.addListener(_onMetadataChanged);
    WatchedStore.load().then((w) {
      if (mounted) setState(() => _watchedKeys = w);
    });
    _loadHiddenSeasons().then((_) => _load());
  }

  @override
  void dispose() {
    TmdService.instance.removeListener(_onMetadataChanged);
    super.dispose();
  }

  void _onMetadataChanged() {
    if (!mounted) return;
    final meta = TmdService.instance.metaFor(_groupKey);
    // Only update _meta when:
    // 1. We have no meta yet (initial load), OR
    // 2. The incoming meta has MORE seasons than the current one (enhancement
    //    from _fetchSeasonData), OR
    // 3. The incoming meta has a different movie.id (fix-match / new resolve).
    // This prevents stale cached data from overwriting a correct _meta when
    // multiple auto-expanded folders share the same metadataKey.
    final current = _meta;
    if (current != null && meta != null && meta.movie.id == current.movie.id) {
      if (meta.seasons.length <= current.seasons.length) return;
    }
    // detailsFor is async — fire and forget; if it returns, refresh again.
    TmdService.instance.detailsFor(_groupKey).then((d) {
      if (!mounted) return;
      setState(() => _details = d);
    });
    setState(() => _meta = meta);
  }

  Future<void> _toggleWatched(Object entry) async {
    final key = _resumeKeyFor(entry);
    if (key == null || key.isEmpty) return;
    final now = !_watchedKeys.contains(key);
    final updated = {..._watchedKeys};
    now ? updated.add(key) : updated.remove(key);
    setState(() => _watchedKeys = updated);
    await WatchedStore.set(key, now);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = TmdService.instance;
      await service.ensureLoaded();

      // === PHASE 1: List files (no network dependency) ===
      final folderEntries = <({
        String folderLabel,
        String metadataKey,
        List<Object> entries,
        int? folderSeason,
        LibraryFolder folder,
      })>[];

      for (final folder in widget.group.folders) {
        List<Object> entries;
        try {
          entries = await _listFolder(folder);
        } catch (_) {
          // Network source unreachable — skip this folder, don't kill the whole load.
          continue;
        }

        // Scan subdirectories inside this folder.
        final subfolderEntries = <({String folderLabel, String metadataKey, List<Object> entries, int? folderSeason, LibraryFolder folder})>[];
        for (final e in entries) {
          if (!_isFolder(e)) continue;
          final subName = _nameOf(e);
          final subFolderId = '${folder.id}_${subName.hashCode}';
          // Skip seasons the user removed from this series view.
          if (_hiddenSeasonFolderIds.contains(subFolderId)) continue;
          final p = ParsedFileName.parse(subName);
          int? subSeason = p.season > 0 ? p.season : null;
          final subFolderSynthetic = LibraryFolder(
            id: '${folder.id}_${subName.hashCode}',
            name: subName,
            path: folder.source == LibraryFolderSource.smb
                ? 'smb:${folder.networkServerId}/${folder.networkShare}/${folder.networkPath!.isNotEmpty ? "${folder.networkPath}/" : ""}$subName'
                : (e is FileEntry ? e.path : folder.path),
            addedAt: folder.addedAt,
            source: folder.source,
            networkServerId: folder.networkServerId,
            networkShare: folder.networkShare,
            networkPath: folder.source == LibraryFolderSource.smb
                 ? '${folder.networkPath!.isNotEmpty ? "${folder.networkPath}/" : ""}$subName'
                : (e is FileEntry ? e.path : folder.networkPath),
          );
          final subEntries = await _listFolder(subFolderSynthetic).catchError((_) => <Object>[]);
          if (subSeason == null) {
            for (final f in subEntries) {
              if (f is FileEntry && !f.isDirectory) {
                final epS = _seasonOfFromFileEntry(f);
                if (epS > 0) {
                  subSeason = epS;
                  break;
                }
              }
            }
          }
          subfolderEntries.add((
            folderLabel: subName,
            metadataKey: '${folder.metadataKey}_sub',
            entries: subEntries,
            folderSeason: subSeason ?? 1,
            folder: subFolderSynthetic,
          ));
        }
        if (subfolderEntries.isNotEmpty) {
          folderEntries.addAll(subfolderEntries);
        } else {
          // Guess season from folder/filename parsing.
          int? folderSeason;
          final parsed = ParsedFileName.parse(folder.name);
          if (parsed.season > 0) {
            folderSeason = parsed.season;
          } else {
            for (final e in entries) {
              final epSeason = _seasonOf(e);
              if (epSeason > 0) {
                folderSeason = epSeason;
                break;
              }
            }
          }
          folderEntries.add((
            folderLabel: folder.name,
            metadataKey: folder.metadataKey,
            entries: entries,
            folderSeason: folderSeason,
            folder: folder,
          ));
        }
      }
      if (!mounted) return;

      // Show files immediately — no TMDB yet.
      setState(() {
        _folders
          ..clear()
          ..addAll(folderEntries);
        _loading = false;
      });

      // Refresh resume positions for everything we found.
      _refreshResumes();

      // === PHASE 2: TMDB in background (best-effort, offline-safe) ===
      try {
        // Resolve metadata for the group (poster/title/overview).
        var meta = service.metaFor(_groupKey);
        meta ??= await service.resolveFolder(
          _groupKey,
          widget.group.displayName,
          yearHint: widget.group.primary.yearHint,
        );

        final details = await service.detailsFor(_groupKey);

        if (!mounted) return;
        setState(() {
          _meta = meta;
          _details = details;
        });

        // Resolve per-folder metadata so each folder gets its own
        // folderSeason (e.g. "Strike the Blood" → Season 1,
        // "Strike the Blood Final" → Season 5).
        for (int i = 0; i < _folders.length; i++) {
          final f = _folders[i];
          if (f.metadataKey == _groupKey) continue;
          try {
            var fMeta = service.metaFor(f.metadataKey);
            fMeta ??= await service.resolveFolder(
              f.metadataKey,
              f.folder.name,
              yearHint: f.folder.yearHint,
            );
            if (fMeta?.movie.id != null) {
              final tmdbSeason = service.matchFolderToSeason(f.folder.name, fMeta!.movie.id);
              if (tmdbSeason != null && tmdbSeason != f.folderSeason) {
                _folders[i] = (folderLabel: f.folderLabel, metadataKey: f.metadataKey, entries: f.entries, folderSeason: tmdbSeason, folder: f.folder);
              }
            }
          } catch (_) {}
        }

        // Refine folderSeason using TMDB season names (if available).
        if (meta?.movie.id != null) {
          bool changed = false;
          for (int i = 0; i < _folders.length; i++) {
            final f = _folders[i];
            final tmdbSeason = service.matchFolderToSeason(f.folder.name, meta!.movie.id);
            if (tmdbSeason != null && tmdbSeason != f.folderSeason) {
              _folders[i] = (folderLabel: f.folderLabel, metadataKey: f.metadataKey, entries: f.entries, folderSeason: tmdbSeason, folder: f.folder);
              changed = true;
            }
          }
          if (changed && mounted) setState(() {});

          await _fetchSeasonData(meta);
        }
      } catch (_) {
        // TMDB offline — files already shown, metadata stays null.
      }
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

  int _seasonOfFromFileEntry(FileEntry entry) {
    final name = entry.name;
    if (name.isEmpty) return 1;
    final parsed = ParsedFileName.parse(name);
    if (parsed.season > 0) return parsed.season;
    return 1;
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
    final genericName = sg.seasonHeader(seasonNumber);
    if (tmdbName != null && tmdbName.isNotEmpty && tmdbName != genericName) {
      return '$genericName · $tmdbName';
    }
    return genericName;
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
        // Show season-specific info ONLY when there's a single season
        // displayed (e.g. user added "Strike the Blood Final" directly,
        // which has no subdirectories — _folders has 0-1 entries).
        // When there are multiple seasons (_folders.length > 1), show the
        // series-level poster/info instead.
        TmdSeason? seasonInfo;
        if (_folders.length <= 1 && meta.seasons.isNotEmpty) {
          final folder = _folders.isNotEmpty ? _folders.first : null;
          if (folder != null) {
            final fMeta = TmdService.instance.metaFor(folder.metadataKey);
            final folderSeason = folder.folderSeason ?? fMeta?.folderSeason;
            if (folderSeason != null) {
              final seasons = fMeta?.seasons ?? meta.seasons;
              if (seasons.containsKey(folderSeason)) {
                seasonInfo = seasons[folderSeason];
              }
            }
          }
        }
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          sliver: SliverToBoxAdapter(
            child: _SeriesHeader(
              meta: meta,
              details: _details,
              metadataKey: _groupKey,
              onFixMatch: () => _fixMatch(),
              onRemoveInfo: () => _removeInfo(),
              season: seasonInfo,
              seriesTitle: seasonInfo != null ? meta.movie.title : null,
            ),
          ),
        ),
      );
      }
      // No-match state: show a simple header with just Get Info button.
      else {
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            sliver: SliverToBoxAdapter(
              child: _SeriesHeader(
                meta: null,
                details: null,
                metadataKey: _groupKey,
                onFixMatch: () => _fixMatch(),
                onRemoveInfo: null,
                season: null,
                seriesTitle: null,
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

    // Cast row (Nova-style) — above seasons.
    if (_details != null && _details!.cast.isNotEmpty) {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverToBoxAdapter(
            child: _CastRow(cast: _details!.cast),
          ),
        ),
      );
    }

    // Season poster cards grid (Nova-style) — only for groups with
    // multiple seasons. Single-season folders skip straight to episodes.
    if (sortedSeasons.length > 1) {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Seasons',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.58,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final s = sortedSeasons[index];
                final posterUrl = _meta?.seasons[s]?.posterUrl(width: 300) ??
                    _meta?.movie.posterUrl(width: 300);
                final tmdbName = _meta?.seasons[s]?.name;
                final genericName = 'Season $s';
                final seasonName = (tmdbName != null && tmdbName != genericName)
                    ? '$genericName · $tmdbName'
                    : genericName;
                final matchFolder = _folders
                    .where((f) => f.folderSeason == s)
                    .firstOrNull
                    ?.folder ??
                    widget.group.folders.where((f) {
                      final p = ParsedFileName.parse(f.name);
                      return p.season == s;
                    }).firstOrNull ??
                    _folders.where((f) {
                      final sOfEntries = f.entries.map(_seasonOf).where((n) => n > 0).firstOrNull;
                      return sOfEntries == s;
                    }).firstOrNull?.folder;
                return _SeasonPosterCard(
                  seasonNumber: s,
                  posterUrl: posterUrl,
                  seasonName: seasonName,
                  onTap: () {
                    if (matchFolder != null) {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => TmdDetailsScreen(folder: matchFolder),
                        ),
                      );
                    }
                  },
                  onLongPress: matchFolder != null ? () => _removeSeason(matchFolder) : null,
                );
              },
              childCount: sortedSeasons.length,
            ),
          ),
        ),
      );
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 12)));
    }

    // When there are multiple seasons, each season card opens its own
    // dedicated season view (with that season's details + episodes).
    // When there is only 1 season (or 0), render episodes directly here.
    if (sortedSeasons.length <= 1) {
      final totalCount = grouped.values.fold<int>(0, (sum, l) => sum + l.length);
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Text(
                  'Episodes',
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
                      onToggleWatched: () => _toggleWatched(entry),
                    ),
                ],
              ),
            ),
          ),
        );
      }
    }

    return slivers;
  }

  /// Remove a season from the series view.
  ///
  /// When the group has multiple real library folders (e.g. "Strike the
  /// Blood" + "Strike the Blood Final" as separate library entries), removing
  /// a season removes that real folder from the store.
  ///
  /// When the season is a synthetic subdirectory of a single real library
  /// folder (created on-the-fly by [_load]), the season is added to the
  /// persisted hidden-seasons list so it stops appearing here; the real
  /// parent folder — and therefore the show card on the home screen — stays.
  Future<void> _removeSeason(LibraryFolder folder) async {
    // Check if this folder is a real library entry or a synthetic subfolder.
    final isReal = widget.group.folders.any((f) => f.id == folder.id);

    // Find the real parent for synthetic subfolders.
    final realParent = isReal
        ? null
        : widget.group.folders.cast<LibraryFolder?>().firstWhere(
              (f) => f != null && folder.id.startsWith('${f.id}_'),
              orElse: () => null,
            );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isReal ? 'Remove season' : 'Remove season'),
        content: Text(
          isReal
              ? '"${folder.name}" will be removed from your library. '
                  'The files stay on your device.'
              : '"${folder.name}" will no longer appear in this series view. '
                  'The other seasons and the show stay in your library.',
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

    final targetId = realParent?.id ?? folder.id;

    if (isReal) {
      // Remove the real folder from the library.
      await LibraryFoldersStore.remove(targetId);
      if (folder.source == LibraryFolderSource.files) {
        try {
          await FileBrowserService.instance.removeLibraryBookmark(targetId);
        } catch (_) {}
      }
      // Clear TMDB only when removing the last folder in the group.
      final remainingFolders =
          widget.group.folders.where((f) => f.id != targetId).toList();
      if (remainingFolders.isEmpty) {
        try {
          await TmdService.instance.clear(folder.metadataKey);
        } catch (_) {}
      }
    } else {
      // Synthetic subfolder: hide only this season, keep the parent + show.
      _hiddenSeasonFolderIds.add(folder.id);
      await _saveHiddenSeasons();
    }

    // Stay on this screen — just drop the removed season card. Home screen
    // re-reads the store when the user backs out (didPopNext), so the show
    // card reflects the removal there too.
    if (!mounted) return;
    setState(() {
      _folders.removeWhere((f) => f.folder.id == folder.id);
    });
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

  Future<void> _removeInfo() async {
    await TmdService.instance.clear(_groupKey);
    if (!mounted) return;
    setState(() {
      _meta = null;
      _details = null;
    });
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
    this.onToggleWatched,
  });

  final Object entry;
  final VoidCallback onTap;
  final int? resumePositionMs;
  final int? durationMs;
  final bool watched;
  final int seasonNumber;
  final TmdEpisode? episode;
  final VoidCallback? onToggleWatched;

  String get _name {
    if (entry is SmbEntry) return (entry as SmbEntry).name;
    if (entry is WebDavEntry) return (entry as WebDavEntry).name;
    if (entry is FtpEntry) return (entry as FtpEntry).name;
    if (entry is UpnpEntry) return (entry as UpnpEntry).name;
    if (entry is JellyfinItem) return (entry as JellyfinItem).name;
    if (entry is FileEntry) return (entry as FileEntry).name;
    return '';
  }

  int? _entrySize() {
    if (entry is SmbEntry) return (entry as SmbEntry).size;
    if (entry is WebDavEntry) return (entry as WebDavEntry).size;
    if (entry is FtpEntry) return (entry as FtpEntry).size;
    if (entry is UpnpEntry) return (entry as UpnpEntry).size;
    if (entry is FileEntry) return (entry as FileEntry).size;
    return 0;
  }

  String _sizeLabel(int bytes) {
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
    final parsed = ParsedFileName.parse(_name);
    final hasEpisode = parsed.isEpisode;
    final stillUrl = episode?.stillUrl();
    final epData = episode;
    final sizeValue = _entrySize() ?? 0;
    final fileSizeLabel = sizeValue > 0 ? _sizeLabel(sizeValue) : '';
    final ratingValue = episode?.voteAverage ?? 0;
    final hasRating = ratingValue > 0;
    final hasOverviewText = episode != null && episode!.overview.isNotEmpty;

    final double? progress = (resumePositionMs != null &&
            resumePositionMs! > 0 &&
            durationMs != null &&
            durationMs! > 0)
        ? (resumePositionMs! / durationMs!).clamp(0.0, 1.0)
        : null;

    final titleWidget = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (hasEpisode) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              'S${seasonNumber.toString().padLeft(2, '0')}E${parsed.episode.toString().padLeft(2, '0')}',
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
            epData?.nameLabel ?? (parsed.isEpisode ? parsed.title : _name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
        if (hasRating) ...[
          const SizedBox(width: 6),
          const Icon(Icons.star, size: 13, color: Colors.amber),
          const SizedBox(width: 2),
          Text(
            ratingValue.toStringAsFixed(1),
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
        if (hasOverviewText)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              episode!.overview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        if (fileSizeLabel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              fileSizeLabel,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        if (progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(1),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            ),
          ),
      ],
    );

    return TvTile(
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
                  color: colorScheme.secondary,
                ),
              ),
            )
          : Icon(
              Icons.movie_outlined,
              color: colorScheme.secondary,
            ),
      title: titleWidget,
      subtitle: subtitleWidget,
      trailing: onToggleWatched != null
          ? IconButton(
              tooltip: watched ? 'Mark as unwatched' : 'Mark as watched',
              icon: Icon(
                watched ? Icons.check_circle : Icons.check_circle_outline,
                color: watched ? Colors.green.shade400 : colorScheme.onSurfaceVariant,
                size: 22,
              ),
              onPressed: onToggleWatched,
            )
          : null,
      onTap: onTap,
    );
  }
}

class _SeriesHeader extends StatefulWidget {
  const _SeriesHeader({
    this.meta,
    this.details,
    required this.metadataKey,
    required this.onFixMatch,
    this.onRemoveInfo,
    this.season,
    this.seriesTitle,
  });

  final TmdMeta? meta;
  final TmdDetails? details;
  final String metadataKey;
  final VoidCallback onFixMatch;
  final VoidCallback? onRemoveInfo;

  /// When set, shows this season's info instead of the series-level info.
  final TmdSeason? season;

  /// The series title to show as subtitle when displaying season info.
  final String? seriesTitle;

  @override
  State<_SeriesHeader> createState() => _SeriesHeaderState();
}

class _SeriesHeaderState extends State<_SeriesHeader> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final movie = widget.meta?.movie;
    final season = widget.season;
    final bool showSeason = season != null && season.name.isNotEmpty;
    final bool hasMeta = movie != null && movie.title.isNotEmpty;

    // Use season poster/overview when showing season info, series otherwise.
    // Always show the show's rating (seasons don't have their own on TMDB).
    final String displayTitle = showSeason
        ? (season.name.toLowerCase().startsWith('season')
            ? season.name
            : 'Season ${season.seasonNumber} · ${season.name}')
        : (movie?.title ?? '');
    final String? displayPoster = showSeason ? season.posterUrl() : movie?.posterUrl();
    final String displayOverview = showSeason ? season.overview : (widget.details?.overview ?? '');
    final double displayRating = movie?.voteAverage ?? 0;
    final List<String> displayGenres = showSeason ? [] : (widget.details?.genres ?? []);

    // No-match state: simple card with just Get Info button.
    if (!hasMeta) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 20, color: Colors.grey),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'No metadata loaded',
                  style: TextStyle(fontSize: 14),
                ),
              ),
              TextButton(
                onPressed: widget.onFixMatch,
                child: const Text('Get Info'),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (displayPoster != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  displayPoster,
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
                    displayTitle,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  // Show series name as subtitle when displaying season info.
                  if (showSeason && widget.seriesTitle != null)
                    Text(
                      widget.seriesTitle!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    ),
                  if (movie.year != null && !showSeason)
                    Text(
                      '${movie.year}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    ),
                  if (displayOverview.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Overview',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      displayOverview,
                      maxLines: _expanded ? null : 4,
                      overflow:
                          _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Text(
                        _expanded ? 'Less' : 'More',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (displayRating > 0) ...[
                        const Icon(Icons.star, size: 14, color: Colors.amber),
                        const SizedBox(width: 2),
                        Text(
                          displayRating.toStringAsFixed(1),
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Flexible(
                        child: TextButton(
                          onPressed: widget.onFixMatch,
                          child: Text(widget.onRemoveInfo != null ? 'Fix match' : 'Get Info'),
                        ),
                      ),
                      if (widget.onRemoveInfo != null)
                        Flexible(
                          child: TextButton(
                            onPressed: widget.onRemoveInfo,
                            child: const Text('Remove'),
                          ),
                        ),
                    ],
                  ),
                  // Genres (like SMB browser) — only for series-level view.
                  if (displayGenres.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final genre in displayGenres)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              genre,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ],
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
    _controller.text = widget.initialQuery;
    _kind = TmdKind.tv;
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
                hintText: 'Search TMDB...',
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

/// Poster card for a season in [SeriesSeasonsScreen].
class _SeasonPosterCard extends StatelessWidget {
  const _SeasonPosterCard({
    required this.seasonNumber,
    this.posterUrl,
    required this.seasonName,
    required this.onTap,
    this.onLongPress,
  });

  final int seasonNumber;
  final String? posterUrl;
  final String seasonName;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress != null
          ? () {
              HapticFeedback.mediumImpact();
              onLongPress!();
            }
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: posterUrl != null
                  ? Image.network(
                      posterUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _placeholder(colorScheme),
                    )
                  : _placeholder(colorScheme),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: (theme.textTheme.bodySmall?.fontSize ?? 12) * 1.4 * 2,
            child: Text(
              seasonName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.surfaceContainerHighest,
            colorScheme.surfaceContainer,
          ],
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Icon(
          Icons.folder_outlined,
          size: 48,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Horizontal scrollable cast row (Nova-style).
class _CastRow extends StatelessWidget {
  const _CastRow({required this.cast});
  final List<TmdCastMember> cast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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

  Widget _avatarFallback(ColorScheme colorScheme, String name) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
