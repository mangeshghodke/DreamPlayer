import 'package:flutter/foundation.dart';

import 'metadata_provider_adapter.dart';
import 'tmdb_client.dart';
import 'the_tvdb_client.dart';

/// Provider-agnostic metadata search for the "Get info" / "Fix match" and
/// "Group poster" dialogs.
///
/// The user never picks a provider. Every provider that has credentials is
/// queried, the results are merged into one list, and near-duplicates are
/// collapsed - so a title that exists in both TMDB and TheTVDB appears once.
/// TMDB is listed first because it stays the primary provider; TheTVDB
/// contributes anything TMDB didn't return (and takes over entirely when no
/// TMDB key is configured).
///
/// This mirrors the preference order the automatic resolver already uses
/// (`TmdService` tries TMDB first, then falls back to TheTVDB when there is
/// no confident match) - the dialogs now simply *look* like that too.
///
/// **External adapters count as providers too** (issue #52). AVDb needs no API
/// key, so a user who enabled it and holds no TMDB/TheTVDB key used to be
/// told to "add an API key" by this very dialog while the adapter sat
/// registered and configured - the automatic resolver could reach it, the
/// manual one could not. The adapters are now searched alongside the
/// built-ins, and they lead the list when the user picked the external
/// provider in Settings → Metadata, exactly like `providerOrderFor` does for
/// the automatic path.
class MetadataSearch {
  MetadataSearch({
    TmdApi? tmdb,
    TheTvdbClient? theTvdb,
    List<MetadataProviderAdapter>? adapters,
  }) : _tmdb = tmdb ?? TmdApi(),
       _theTvdb = theTvdb ?? TheTvdbClient(),
       _ownsTheTvdb = theTvdb == null,
       _adapterOverride = adapters;

  final TmdApi _tmdb;
  final TheTvdbClient _theTvdb;
  final bool _ownsTheTvdb;

  /// Test seam: when set, these adapters are used instead of the registry's.
  final List<MetadataProviderAdapter>? _adapterOverride;

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
      // Secure storage unavailable - treat as "not configured" so the dialog
      // degrades to a clear "add a key" message instead of an error.
      return false;
    }
  }

  /// Registered adapters that are actually usable, in registration order.
  ///
  /// Mirrors `MetadataProviderRegistry.configured()`, but honours the test
  /// override so a dialog test can supply its own adapter.
  Future<List<MetadataProviderAdapter>> _configuredAdapters() async {
    final override = _adapterOverride;
    if (override == null) {
      return MetadataProviderRegistry.instance.configured();
    }
    final result = <MetadataProviderAdapter>[];
    for (final adapter in override) {
      try {
        if (await adapter.isConfigured()) result.add(adapter);
      } catch (_) {
        // A misbehaving adapter must not block the others.
      }
    }
    return result;
  }

  /// True when at least one provider can be searched. When false the dialogs
  /// show the "add an API key" hint rather than an empty result list.
  ///
  /// An enabled external adapter counts: AVDb needs no key, so keying this off
  /// TMDB/TheTVDB alone told a key-less user to go and get a key they did not
  /// need (issue #52).
  Future<bool> get hasAnyProvider async =>
      await _tmdbConfigured ||
      await _theTvdbConfigured ||
      (await _configuredAdapters()).isNotEmpty;

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
    final adapters = await _configuredAdapters();
    if (!hasTmdb && !hasTheTvdb && adapters.isEmpty) return const [];

    final targets = _orderedProviders(
      choice: await _providerChoice(),
      hasTmdb: hasTmdb,
      hasTheTvdb: hasTheTvdb,
      adapters: adapters,
    );

    final primary = await _gather(targets, query, year: year, kind: kind);
    if (primary.isNotEmpty) return primary;

    // Kind-first fallback: the toggle is never just a reorder.
    final otherKind = kind == TmdKind.tv ? TmdKind.movie : TmdKind.tv;
    return _gather(targets, query, kind: otherKind);
  }

  /// Numeric-id lookup. Movie and TV ids live in separate namespaces per
  /// provider, so every provider is probed for both kinds and the hits are
  /// merged (a title present in both providers collapses to one row).
  Future<List<TmdMovie>> byId(int id, TmdKind kind) async {
    if (id <= 0) return const [];
    final hasTmdb = await _tmdbConfigured;
    final hasTheTvdb = await _theTvdbConfigured;
    final adapters = await _configuredAdapters();
    if (!hasTmdb && !hasTheTvdb && adapters.isEmpty) return const [];

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
          // Same - keep whatever the other provider returned.
        }
      }
      // An adapter's own id space is not TMDB's, so the id is handed over as
      // TEXT and the adapter decides what it means with it - AVDb routes a
      // numeric term to `ids=` and anything else to a title search.
      for (final adapter in adapters) {
        try {
          results.addAll(await adapter.search('$id', kind: probeKind));
        } catch (_) {
          // Same - keep whatever the other provider returned.
        }
      }
    }
    return dedupe(results);
  }

  /// Season names for a picked series, dispatched on that entry's provider.
  Future<Map<int, String>> seasonNames(TmdMovie movie) async {
    if (movie.kind != TmdKind.tv) return const {};
    if (movie.provider == MetadataProvider.external) {
      // An external catalogue has no TMDB seasons to ask for. Asking TMDB for
      // an AVDb id would have returned a completely unrelated series.
      for (final adapter in await _configuredAdapters()) {
        try {
          final seasons = await adapter.seasons(movie);
          if (seasons.isNotEmpty) {
            return {
              for (final season in seasons)
                if (season.name.trim().isNotEmpty)
                  season.seasonNumber: season.name.trim(),
            };
          }
        } catch (_) {
          // Try the next adapter.
        }
      }
      return const {};
    }
    final names = movie.provider == MetadataProvider.theTvdb
        ? await _theTvdb.seasonNames(movie)
        : await _tmdb.seasonNames(movie);
    return {
      for (final e in names.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    };
  }

  /// One searcher per usable provider, in the order the results should be
  /// listed.
  ///
  /// The order follows the user's Settings → Metadata choice, so a user who
  /// picked AVDb sees its hits first (and wins the dedupe tie). The built-ins
  /// keep their historical TMDB-then-TheTVDB order otherwise.
  List<_SearchTarget> _orderedProviders({
    required MetadataProviderChoice choice,
    required bool hasTmdb,
    required bool hasTheTvdb,
    required List<MetadataProviderAdapter> adapters,
  }) {
    final targets = <_SearchTarget>[];
    if (choice == MetadataProviderChoice.external) {
      // The external provider is PRIMARY here, exactly like it is for the
      // automatic resolver (`providerOrderFor`).
      for (final adapter in adapters) {
        targets.add(_SearchTarget.adapter(adapter));
      }
      if (hasTmdb) {
        targets.add(const _SearchTarget.builtIn(MetadataProvider.tmdb));
      }
      if (hasTheTvdb) {
        targets.add(const _SearchTarget.builtIn(MetadataProvider.theTvdb));
      }
      return targets;
    }
    if (choice == MetadataProviderChoice.theTvdb) {
      if (hasTheTvdb) {
        targets.add(const _SearchTarget.builtIn(MetadataProvider.theTvdb));
      }
      if (hasTmdb) {
        targets.add(const _SearchTarget.builtIn(MetadataProvider.tmdb));
      }
    } else {
      if (hasTmdb) {
        targets.add(const _SearchTarget.builtIn(MetadataProvider.tmdb));
      }
      if (hasTheTvdb) {
        targets.add(const _SearchTarget.builtIn(MetadataProvider.theTvdb));
      }
    }
    for (final adapter in adapters) {
      targets.add(_SearchTarget.adapter(adapter));
    }
    return targets;
  }

  Future<MetadataProviderChoice> _providerChoice() async {
    try {
      return await TheTvdbClient.providerChoice();
    } catch (_) {
      return MetadataProviderChoice.tmdb;
    }
  }

  /// Runs one search across every usable provider in parallel, keeping the
  /// providers' hits in list order, and collapsing cross-provider duplicates.
  Future<List<TmdMovie>> _gather(
    List<_SearchTarget> targets,
    String query, {
    int? year,
    required TmdKind kind,
  }) async {
    final lists = await Future.wait(
      targets.map(
        (target) => _guard(
          () => target.search(query, _tmdb, _theTvdb, year: year, kind: kind),
        ),
      ),
    );
    return dedupe(lists.expand((l) => l));
  }

  /// A provider that throws must not fail the whole search - the other
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
    final title = m.title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    return '${m.kind.name}|$title|${m.year ?? ''}';
  }

  void dispose() {
    if (_ownsTheTvdb) _theTvdb.dispose();
  }
}

/// A provider the dialog can search, in a form that carries its own call.
///
/// The two built-ins need the search's own clients (TMDB's key, TheTVDB's
/// credentials), while an adapter is self-contained - so the target owns the
/// dispatch instead of a `switch` over the provider enum, which would have
/// needed a second case for every adapter that is ever added.
class _SearchTarget {
  const _SearchTarget.builtIn(this.builtIn) : adapter = null;

  _SearchTarget.adapter(this.adapter) : builtIn = null;

  /// Which built-in this target is, or null for an adapter.
  final MetadataProvider? builtIn;

  final MetadataProviderAdapter? adapter;

  Future<List<TmdMovie>> search(
    String query,
    TmdApi tmdb,
    TheTvdbClient theTvdb, {
    int? year,
    required TmdKind kind,
  }) {
    final external = adapter;
    if (external != null) {
      // An adapter has its own catalogue and its own idea of what a year means
      // (AVDb has no ratings and no year filter), so neither is forwarded.
      return external.search(query, kind: kind);
    }
    return builtIn == MetadataProvider.theTvdb
        ? theTvdb.search(query, year: year, kind: kind)
        : tmdb.search(query, year: year, kind: kind);
  }
}
