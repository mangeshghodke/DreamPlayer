// Pure helpers for grouping episodes by season and computing watched progress.
//
// No Flutter imports — usable in unit tests. Widgets consume the computed
// values through seasonHeader/watchedBadge/seasonBadge and the
// SeasonProgressRing widget.

// Groups [entries] by season, sorting each season by episode number.
//
// [seasonOf] and [episodeOf] extract the season/episode numbers for an entry.
// Entries with season <= 0 are ignored (callers should filter to episodes only).
Map<int, List<T>> groupBySeason<T>(
  List<T> entries,
  int Function(T) seasonOf,
  int Function(T) episodeOf,
) {
  final groups = <int, List<T>>{};
  for (final e in entries) {
    final s = seasonOf(e);
    if (s < 0) continue; // negative = unparseable; 0 = unnumbered (treat as season 0)
    (groups[s] ??= <T>[]).add(e);
  }
  for (final list in groups.values) {
    list.sort((a, b) => episodeOf(a).compareTo(episodeOf(b)));
  }
  return groups;
}

/// Number of entries in [seasonEntries] whose key is in [watchedKeys].
///
/// [keyOf] may return null for entries that must not be counted (e.g. folders).
int watchedCount<T>(
  List<T> seasonEntries,
  Set<String> watchedKeys,
  String? Function(T) keyOf,
) {
  var c = 0;
  for (final e in seasonEntries) {
    final k = keyOf(e);
    if (k != null && k.isNotEmpty && watchedKeys.contains(k)) c++;
  }
  return c;
}

/// Watched counts per season for a grouped map.
Map<int, int> watchedCountsBySeason<T>(
  Map<int, List<T>> grouped,
  Set<String> watchedKeys,
  String? Function(T) keyOf,
) {
  final result = <int, int>{};
  for (final entry in grouped.entries) {
    result[entry.key] = watchedCount(entry.value, watchedKeys, keyOf);
  }
  return result;
}

/// Progress in 0..1 for a season or folder.
double seasonProgress({required int watched, required int total}) {
  if (total <= 0) return 0;
  return (watched / total).clamp(0.0, 1.0);
}

/// "Season 1", "Season 2" … "Episodes" for unnumbered (season 0).
String seasonHeader(int seasonNumber) =>
    seasonNumber <= 0 ? 'Episodes' : 'Season $seasonNumber';

/// "3/10"
String watchedBadge(int watched, int total) => '$watched/$total';

/// "S1 2/5" — or "Ep 2/5" for unnumbered (season 0).
String seasonBadge(int season, int watched, int total) =>
    season <= 0 ? 'Ep ${watchedBadge(watched, total)}' : 'S$season ${watchedBadge(watched, total)}';
