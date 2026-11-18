import 'package:flutter/foundation.dart';

import 'tmdb_client.dart';
import 'trakt_client.dart';
import 'watched_store.dart';

/// Trakt sync: pulls watched state from Trakt into [WatchedStore] for files
/// whose TMDB metadata is already resolved in [TmdStore]. The push direction
/// lives in the player (per-mark on end) and Settings (bulk).
///
/// One-way (mark-only) on the pull: local marks are never cleared here -
/// un-watching on another device intentionally does not propagate until a
/// two-way engine exists. Failures are silent best-effort: a dead Trakt or a
/// flaky connection must never interrupt startup or playback.
class TraktSync {
  TraktSync._();

  /// Don't hit /sync/watched more than once per [minInterval]; a fresh
  /// sign-in and a manual Settings pull force it.
  static const Duration minInterval = Duration(hours: 6);

  /// Fire-and-forget startup pull. Returns how many files were newly marked.
  static Future<int> pullWatched({bool force = false}) async {
    try {
      final client = TraktClient();
      if (!client.isConfigured || !await client.isAuthenticated) return 0;
      if (!force && await _throttled(client)) return 0;
      final watched = await client.fetchWatched();
      final marked = await applyWatched(watched);
      await client.markPulled();
      return marked;
    } catch (_) {
      return 0;
    }
  }

  /// Applies a fetched snapshot to [WatchedStore]. Returns count marked.
  static Future<int> applyWatched(TraktWatched watched) async {
    final cache = await TmdStore.loadAll();
    final keys = matchKeys(cache: cache, watched: watched);
    for (final key in keys) {
      await WatchedStore.set(key, true);
    }
    return keys.length;
  }

  /// Pure matcher (unit-tested): identity keys in [cache] whose TMDB title is
  /// watched on Trakt.
  ///
  /// Movies match exactly. Episodes parse `SxxEyy` from the filename tail of
  /// the identity key and match when the episode falls within the watched
  /// count Trakt reports for that season. Whole-season/folder keys (no S/E)
  /// and non-TMDB matches (an external provider id is not a TMDB id) never
  /// match - pushing or pulling those would silently target the wrong title.
  @visibleForTesting
  static Set<String> matchKeys({
    required Map<String, TmdMeta> cache,
    required TraktWatched watched,
  }) {
    final result = <String>{};
    for (final entry in cache.entries) {
      final meta = entry.value;
      final id = meta.movie.tmdbId;
      if (id == null || id == 0) continue;
      if (meta.movie.kind == TmdKind.tv) {
        final base = entry.key.split('/').last.split(r'\').last;
        final parsed = ParsedFileName.parse(base);
        if (!parsed.isEpisode) continue;
        if (watched.isEpisodeWatched(id, parsed.season, parsed.episode)) {
          result.add(entry.key);
        }
      } else if (watched.movieIds.contains(id)) {
        result.add(entry.key);
      }
    }
    return result;
  }

  static Future<bool> _throttled(TraktClient client) async {
    final last = await client.lastPullAt();
    if (last == null) return false;
    return DateTime.now().difference(last) < minInterval;
  }
}