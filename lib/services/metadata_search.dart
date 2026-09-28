import 'package:flutter/foundation.dart';

import 'tmdb_client.dart';
import 'the_tvdb_client.dart';

/// Provider-agnostic metadata search for the "Get info" / "Fix match" and
/// "Group poster" dialogs.
///
/// The user never picks a provider. Every provider that has credentials is
/// queried, the results are merged into one list, and near-duplicates are
/// collapsed — so a title that exists in both TMDB and TheTVDB appears once.
/// TMDB is listed first because it stays the primary provider; TheTVDB
/// contributes anything TMDB didn't return (and takes over entirely when no
/// TMDB key is configured).
///
/// This mirrors the preference order the automatic resolver already uses
/// (`TmdService` tries TMDB first, then falls back to TheTVDB when there is
/// no confident match) — the dialogs now simply *look* like that too.
class MetadataSearch {
  MetadataSearch({TmdApi? tmdb, TheTvdbClient? theTvdb})
      : _tmdb = tmdb ?? TmdApi(),
        _theTvdb = theTvdb ?? TheTvdbClient(),
        _ownsTheTvdb = theTvdb == null;

  final TmdApi _tmdb;
  final TheTvdbClient _theTvdb;
  final bool _ownsTheTvdb;

  /// TMDB is available once any key (build-time or user-entered) resolves.
  Future<bool> get _tmdbConfigured async {
    try {
      return (await _tmdb.effectiveApiKey()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> get _theTvdbConfigured async {
    try {
      return await _theTvdb.isConfiguredAsync;
    } catch (_) {
      // Secure storage unavailable — treat as "not configured" so the dialog
      // degrades to a clear "add a key" message instead of an error.
      return false;
    }
  }

  /// True when at least one provider can be searched. When false the dialogs
  /// show the "add an API key" hint rather than an empty result list.
  Future<bool> get hasAnyProvider async =>
      await _tmdbConfigured || await _theTvdbConfigured;

  /// Title search across every configured provider.
  ///
  /// [year] is applied to the selected [kind] only; the other-kind sweep runs
  /// without a year so a mis-detected movie/series toggle still finds the
  /// title (matches the pre-existing single-provider behavior).
  Future<List<TmdMovie>> search(
    String query, {
    required TmdKind kind,
    int? year,
  }) async {
    if (query.trim().isEmpty) return const [];
    final hasTmdb = await _tmdbConfigured;
    final hasTheTvdb = await _theTvdbConfigured;
    if (!hasTmdb && !hasTheTvdb) return const [];

    final primary = await _gather(
      (p) => _searchOne(p, query, year: year, kind: kind),
      hasTmdb: hasTmdb,
      hasTheTvdb: hasTheTvdb,
    );
    if (primary.isNotEmpty) return primary;

    // Kind-first fallback: the toggle is never just a reorder.
    final otherKind = kind == TmdKind.tv ? TmdKind.movie : TmdKind.tv;
    return _gather(
      (p) => _searchOne(p, query, kind: otherKind),
      hasTmdb: hasTmdb,
      hasTheTvdb: hasTheTvdb,
    );
  }

  /// Numeric-id lookup. Movie and TV ids live in separate namespaces per
  /// provider, so every provider is probed for both kinds and the hits are
  /// merged (a title present in both providers collapses to one row).
  Future<List<TmdMovie>> byId(int id, TmdKind kind) async {
    if (id <= 0) return const [];
    final hasTmdb = await _tmdbConfigured;
    final hasTheTvdb = await _theTvdbConfigured;
    if (!hasTmdb && !hasTheTvdb) return const [];

    final otherKind = kind == TmdKind.tv ? TmdKind.movie : TmdKind.tv;
    final results = <TmdMovie>[];
    for (final probeKind in [kind, otherKind]) {
      if (hasTmdb) {
        try {
          final hit = await _tmdb.byId(id, probeKind);
          if (hit != null) results.add(hit);
        } catch (_) {
          // A failing provider must not sink the other one.
        }
      }
      if (hasTheTvdb) {
        try {
          final hit = await _theTvdb.byId(id, kind: probeKind);
          if (hit != null) results.add(hit);
        } catch (_) {
          // Same — keep whatever the other provider returned.
        }
      }
    }
    return dedupe(results);
  }

  /// Season names for a picked series, dispatched on that entry's provider.
  Future<Map<int, String>> seasonNames(TmdMovie movie) async {
    if (movie.kind != TmdKind.tv) return const {};
    final names = movie.provider == MetadataProvider.theTvdb
        ? await _theTvdb.seasonNames(movie)
        : await _tmdb.seasonNames(movie);
    return {
      for (final e in names.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    };
  }

  Future<List<TmdMovie>> _searchOne(
    MetadataProvider provider,
    String query, {
    int? year,
    required TmdKind kind,
  }) =>
      provider == MetadataProvider.tmdb
          ? _tmdb.search(query, year: year, kind: kind)
          : _theTvdb.search(query, year: year, kind: kind);

  /// Runs one search across every configured provider in parallel, keeping
  /// TMDB's hits ahead of TheTVDB's, and collapsing cross-provider duplicates.
  Future<List<TmdMovie>> _gather(
    Future<List<TmdMovie>> Function(MetadataProvider provider) search, {
    required bool hasTmdb,
    required bool hasTheTvdb,
  }) async {
    final futures = <Future<List<TmdMovie>>>[];
    if (hasTmdb) {
      futures.add(_guard(() => search(MetadataProvider.tmdb)));
    }
    if (hasTheTvdb) {
      futures.add(_guard(() => search(MetadataProvider.theTvdb)));
    }
    final lists = await Future.wait(futures);
    return dedupe(lists.expand((l) => l));
  }

  /// A provider that throws must not fail the whole search — the other
  /// provider's results (or an empty list) are still worth showing.
  Future<List<TmdMovie>> _guard(Future<List<TmdMovie>> Function() run) async {
    try {
      return await run();
    } catch (_) {
      return const [];
    }
  }

  /// Collapses entries that describe the same title, keeping the first
  /// occurrence (TMDB is passed first, so it wins the tie).
  ///
  /// Exposed for tests: the dedupe rule is the whole point of the merged
  /// result list, so it needs direct coverage.
  @visibleForTesting
  static List<TmdMovie> dedupe(Iterable<TmdMovie> movies) {
    final out = <TmdMovie>[];
    final seen = <String>{};
    for (final m in movies) {
      if (m.id <= 0 || m.title.trim().isEmpty) continue;
      if (seen.add(dedupeKey(m))) out.add(m);
    }
    return out;
  }

  @visibleForTesting
  static String dedupeKey(TmdMovie m) {
    final title =
        m.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    return '${m.kind.name}|$title|${m.year ?? ''}';
  }

  void dispose() {
    if (_ownsTheTvdb) _theTvdb.dispose();
  }
}
