import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/tmdb_client.dart';
import '../services/the_tvdb_client.dart';
import 'cached_image.dart';

/// What a Fix match dialog returns: the pinned title plus the optional season
/// the user picked (or that was auto-matched from the folder name). [season]
/// null means "series only / movie" — no [TmdMeta.folderSeason].
class TmdbFixMatchPick {
  const TmdbFixMatchPick({required this.movie, this.season});

  final TmdMovie movie;
  final int? season;
}

/// Shared Fix match / Get Info dialog (issue #22): title search, Movie/TV
/// toggle, **TMDB id lookup** when the query is numeric (movie and TV ids are
/// separate namespaces — both are probed and shown), and a **season picker**
/// for multi-season shows so "Railgun S" can pin to Season 2 instead of only
/// the main show. When [folderName] uniquely matches one season, that season
/// is returned immediately without the extra step.
///
/// Returns null on cancel.
Future<TmdbFixMatchPick?> showTmdbFixMatchDialog(
  BuildContext context, {
  String? initialQuery,
  int? initialYear,
  TmdKind? initialKind,
  String? folderName,
}) {
  return showDialog<TmdbFixMatchPick>(
    context: context,
    builder: (context) => TmdbFixMatchDialog(
      initialQuery: initialQuery,
      initialYear: initialYear,
      initialKind: initialKind,
      folderName: folderName,
    ),
  );
}

class TmdbFixMatchDialog extends StatefulWidget {
  const TmdbFixMatchDialog({
    super.key,
    this.initialQuery,
    this.initialYear,
    this.initialKind,
    this.folderName,
  });

  final String? initialQuery;
  final int? initialYear;
  final TmdKind? initialKind;
  final String? folderName;

  @override
  State<TmdbFixMatchDialog> createState() => _TmdbFixMatchDialogState();
}

class _TmdbFixMatchDialogState extends State<TmdbFixMatchDialog> {
  final _controller = TextEditingController();
  final _api = TmdApi();
  final _theTvdb = TheTvdbClient();

  List<TmdMovie>? _results;
  bool _searching = false;
  int _searchGeneration = 0;
  bool _noKey = false;
  String? _error;
  late TmdKind _kind;
  MetadataProvider _provider = MetadataProvider.tmdb;

  /// Season-picker step: non-null once a multi-season TV show is selected.
  TmdMovie? _seasonFor;
  Map<int, String> _seasonNames = const {};
  bool _loadingSeasons = false;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery ?? '';
    _kind = widget.initialKind ?? TmdKind.movie;
    if (_controller.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  @override
  void dispose() {
    _theTvdb.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    final generation = ++_searchGeneration;
    if (query.isEmpty) return;
    if (_provider == MetadataProvider.tmdb) {
    final key = await _api.effectiveApiKey();
    if (!mounted || generation != _searchGeneration) return;
    if (key.isEmpty) {
      setState(() {
        _searching = false;
        _results = null;
        _noKey = true;
      });
      return;
    }
    } else {
      bool configured;
      try {
        configured = await _theTvdb.isConfiguredAsync;
      } catch (_) {
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          _searching = false;
          _error = 'Secure TheTVDB credential storage is unavailable.';
          _noKey = true;
        });
        return;
      }
      if (!mounted || generation != _searchGeneration) return;
      if (!configured) {
        setState(() {
          _searching = false;
          _results = null;
          _noKey = true;
        });
        return;
      }
    }
    setState(() {
      _searching = true;
      _results = null;
      _error = null;
      _noKey = false;
      _seasonFor = null;
    });
    try {
      final results = <TmdMovie>[];
      if (RegExp(r'^\d{1,10}$').hasMatch(query)) {
        final id = int.parse(query);
        if (_provider == MetadataProvider.tmdb) {
        final byKind = await Future.wait([
          _api.byId(id, TmdKind.movie),
          _api.byId(id, TmdKind.tv),
        ]);
        results.addAll(byKind.whereType<TmdMovie>());
      } else {
          final byId = await _theTvdb.byId(id, kind: _kind);
          if (byId != null) results.add(byId);
      }
      }
      final primary = _provider == MetadataProvider.tmdb
          ? await _api.search(query, year: widget.initialYear,
        kind: _kind)
          : await _theTvdb.search(query, year: widget.initialYear, kind: _kind);
      final fallbackKind = _kind == TmdKind.tv ? TmdKind.movie : TmdKind.tv;
      final fallback = _provider == MetadataProvider.tmdb
          ? await _api.search(query, kind: fallbackKind)
          : await _theTvdb.search(query, kind: fallbackKind);
      results.addAll(primary);
      results.addAll(fallback);
      final seen = <String>{};
      results.removeWhere((m) => !seen.add(m.providerKey));
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _results = results);
    } catch (e) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _onPickShow(TmdMovie movie) async {
    if (movie.kind != TmdKind.tv) {
      Navigator.of(context).pop(TmdbFixMatchPick(movie: movie));
      return;
    }
    setState(() {
      _loadingSeasons = true;
      _error = null;
    });
    Map<int, String> names;
    try {
      names = movie.provider == MetadataProvider.theTvdb
          ? await _theTvdb.seasonNames(movie)
          : await _api.seasonNames(movie);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingSeasons = false;
        _error = 'Could not load seasons: $error';
      });
      return;
    }
    if (!mounted) return;
    final seasons = {
      for (final e in names.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    };
    if (seasons.length <= 1) {
      // Single season (or no names) — no picker needed.
      Navigator.of(context).pop(
        TmdbFixMatchPick(
        movie: movie,
        season: seasons.isEmpty ? null : seasons.keys.first,
        ),
      );
      return;
    }
    final auto = widget.folderName?.trim();
    final autoSeason = (auto == null || auto.isEmpty)
        ? null
        : TmdService.matchFolderToSeasonName(auto, names);
    if (autoSeason != null && names.containsKey(autoSeason)) {
      // Folder name uniquely identifies a season (suffix / exact match) —
      // skip the extra tap (issue #22 Railgun S → Season 2).
      Navigator.of(
        context,
      ).pop(TmdbFixMatchPick(movie: movie, season: autoSeason));
      return;
    }
    setState(() {
      _seasonFor = movie;
      _seasonNames = names;
      _loadingSeasons = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final title = _seasonFor != null
        ? 'Choose season'
        : l10n.detailsGetInfo;
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_seasonFor != null) ...[
                Text(
                  _seasonFor!.title,
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.45,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _seasonNames.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.live_tv),
                          title: const Text('Whole series'),
                          subtitle: const Text('No specific season'),
                          onTap: () => Navigator.of(context).pop(
                            TmdbFixMatchPick(movie: _seasonFor!, season: null),
                          ),
                        );
                      }
                      final ordered = _seasonNames.entries.toList()
                        ..sort((a, b) => a.key.compareTo(b.key));
                      final entry = ordered[index - 1];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          entry.key == 0
                              ? Icons.theaters
                              : Icons.movie_filter,
                          color: colorScheme.primary,
                        ),
                        title: Text(
                          entry.key == 0
                              ? 'Specials · ${entry.value}'
                              : 'Season ${entry.key} · ${entry.value}',
                        ),
                        onTap: () => Navigator.of(context).pop(
                            TmdbFixMatchPick(
                                movie: _seasonFor!, season: entry.key,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ] else ...[
                TextField(
                  controller: _controller,
                  autofocus: true,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: '${l10n.detailsSearchTitle} · ${_provider.label} id',
                    prefixIcon: const Icon(Icons.search),
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<TmdKind>(
                  segments: const [
                    ButtonSegment(value: TmdKind.tv, label: Text('TV Series')),
                    ButtonSegment(value: TmdKind.movie, label: Text('Movie')),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (sel) =>
                      setState(() => _kind = sel.first),
                ),
                const SizedBox(height: 8),
                SegmentedButton<MetadataProvider>(
                  segments: const [
                    ButtonSegment(
                      value: MetadataProvider.tmdb,
                      label: Text('TMDB'),
                    ),
                    ButtonSegment(
                      value: MetadataProvider.theTvdb,
                      label: Text('TheTVDB'),
                    ),
                  ],
                  selected: {_provider},
                  onSelectionChanged: (selection) {
                    setState(() => _provider = selection.first);
                    _search();
                  },
                ),
                const SizedBox(height: 8),
                if (_searching || _loadingSeasons)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child:
                        Center(child: CircularProgressIndicator()),
                  )
                else if (_noKey)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Search is unavailable right now. Try again in a moment.',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: colorScheme.onSurfaceVariant),
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
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(l10n.detailsNoResults),
                    )
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            MediaQuery.of(context).size.height * 0.4,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _results!.length,
                        itemBuilder: (context, index) {
                          final movie = _results![index];
                          return ListTile(
                            leading: movie.posterUrl(width: 92) != null
                                ? CachedImage(
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
                                if (movie.kind == TmdKind.tv)
                                  'TV Series',
                                movie.provider.label,
                                if (movie.year != null)
                                  '${movie.year}',
                                if (movie.voteAverage > 0)
                                  movie.voteAverage.toStringAsFixed(1),
                              ].join('  ·  '),
                            ),
                            onTap: () => _onPickShow(movie),
                          );
                        },
                      ),
                    ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_seasonFor != null)
          TextButton(
            onPressed: () => setState(() => _seasonFor = null),
            child: Text(l10n.commonCancel),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.commonCancel),
          ),
      ],
    );
  }
}
