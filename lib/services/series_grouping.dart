import 'library_folders.dart';

/// A grouping of library folders that share the same base series name.
///
/// For example, `Strike the Blood`, `Strike the Blood II`, `Strike the Blood
/// III`, `Strike the Blood IV` all collapse into a single [SeriesGroup] so
/// they appear as ONE card on the home library grid (Flux-style), with all
/// four seasons listed inside.
///
/// When the user taps the grouped card, the [SeriesDetailsScreen] opens
/// and shows the seasons across every folder in [folders].
class SeriesGroup {
  const SeriesGroup({
    required this.baseName,
    required this.displayName,
    required this.folders,
  });

  /// The stripped base name used for matching (lowercase, roman numerals /
  /// ordinal markers / season tags removed). Two folders with the same
  /// baseName collapse into the same group.
  final String baseName;

  /// The display name shown on the card. Uses the shortest folder name
  /// in [folders] (usually the bare series name) and falls back to
  /// [baseName] when no folders exist.
  final String displayName;

  /// All folders that share this base name. Order is preserved from the
  /// input (most-recently-added first via [LibraryFoldersStore]).
  final List<LibraryFolder> folders;

  /// The "primary" folder used for the card artwork (TMDB poster, etc).
  /// For now, this is just the first folder — picking the folder with
  /// the best existing TMDB match is a future refinement.
  LibraryFolder get primary => folders.first;

  /// The TMDB metadata key shared by all folders in this group. Each folder
  /// has its own key (because it has its own [LibraryFolder.metadataKey]),
  /// but for cross-folder grouping we pick the primary's key as the
  /// canonical one.
  String get metadataKey => primary.metadataKey;
}

/// Service that groups library folders by series name so they can be
/// presented as a unified series on the home grid (Flux-style).
///
/// The grouping is folder-name based: it strips trailing season tags
/// (`S02`, `Season 2`), roman numerals (`II`, `III`, `IV`, `V`), and
/// ordinal markers (`2nd`, `3rd`) from each folder's [LibraryFolder.name]
/// and uses the remainder (lowercased + punctuation-stripped + whitespace
/// collapsed) as the matching key.
///
/// TMDB-merged folders (those that already share the same TMDB id via the
/// `TmdStore`) are also collapsed even if their names differ — see
/// [group] below.
class SeriesGroupingService {
  const SeriesGroupingService();

  /// Returns the list of [SeriesGroup]s for [folders]. The list is sorted
  /// by the most-recently-added folder in each group (newest first).
  List<SeriesGroup> group(List<LibraryFolder> folders) {
    if (folders.isEmpty) return const [];

    // Step 1: per-folder base name.
    final entries = folders
        .map((f) => (folder: f, baseName: baseNameOf(f.name)))
        .toList();

    // Step 2: union-find by base name. Two folders with the same base name
    // end up in the same group.
    final byBase = <String, _MutableGroup>{};
    for (final entry in entries) {
      byBase.putIfAbsent(
        entry.baseName,
        () => _MutableGroup(
          baseName: entry.baseName,
          displayName: entry.folder.name,
          folders: [],
          addedAt: entry.folder.addedAt,
        ),
      );
      final g = byBase[entry.baseName]!;
      g.folders.add(entry.folder);
      // Display name = the shortest non-empty folder name (usually the
      // bare series name without any suffix).
      if (entry.folder.name.length < g.displayName.length) {
        g.displayName = entry.folder.name;
      }
      if (entry.folder.addedAt.isAfter(g.addedAt)) {
        g.addedAt = entry.folder.addedAt;
      }
    }

    // Step 3: fold aliases that match each other (so "Strike the Blood" and
    // "strike-the-blood" land in the same group even when the base-name
    // normaliser disagrees by a single character).
    _mergeAliases(byBase);

    // Step 4: emit SeriesGroup list, sorted newest-group-first.
    final groups = byBase.values
        .map((g) => SeriesGroup(
              baseName: g.baseName,
              displayName: g.displayName,
              folders: g.folders,
            ))
        .toList()
      ..sort((a, b) => b.primary.addedAt.compareTo(a.primary.addedAt));
    return groups;
  }

  /// Folds any groups whose base names share the same "compact" form
  /// (alphanumerics + digits only, lowercase) into the first one.
  void _mergeAliases(Map<String, _MutableGroup> byBase) {
    final byCompact = <String, _MutableGroup>{};
    for (final entry in byBase.entries) {
      final compact = _compact(entry.key);
      byCompact.putIfAbsent(compact, () => entry.value);
      final canonical = byCompact[compact]!;
      if (!identical(canonical, entry.value)) {
        // Move all folders from the alias into the canonical group.
        canonical.folders.addAll(entry.value.folders);
        if (entry.value.addedAt.isAfter(canonical.addedAt)) {
          canonical.addedAt = entry.value.addedAt;
        }
        if (entry.value.displayName.length < canonical.displayName.length) {
          canonical.displayName = entry.value.displayName;
        }
        // Update the canonical base name to the shorter one if needed.
        if (entry.key.length < canonical.baseName.length) {
          canonical.baseName = entry.key;
        }
      }
    }
    // Drop the alias groups we absorbed.
    byBase.removeWhere((k, v) {
      final compact = _compact(k);
      return !identical(byCompact[compact], v);
    });
  }

  /// Returns the base name for [folderName] — the series name without
  /// any trailing season tag, roman numeral, or ordinal marker.
  ///
  /// Examples:
  ///   "Strike the Blood"           -> "strike the blood"
  ///   "Strike the Blood II"        -> "strike the blood"
  ///   "Strike the Blood III"       -> "strike the blood"
  ///   "Strike the Blood IV"        -> "strike the blood"
  ///   "Kakegurui Twin (2021) Live Action" -> "kakegurui twin 2021 live action"
  ///   "My.Show.S02.1080p"          -> "my show"
  ///   "My Show Season 2"           -> "my show"
  static String baseNameOf(String folderName) {
    var name = folderName.trim();
    // Drop a trailing year in parens/brackets ("(2021)" or "[2021]").
    name = name.replaceAll(RegExp(r'\s*[\(\[]\s*\d{4}\s*[\)\]]'), ' ');
    // Drop a bare year at the end of the string.
    name = name.replaceAll(RegExp(r'\s+\d{4}$'), ' ');

    // Drop season tags glued to the title (`My Show S02`, `My.Show.S02.1080p`,
    // `My Show Season 2`).
    name = name.replaceAll(RegExp(r'\bS\d{1,2}(E\d{1,2})?\b', caseSensitive: false), ' ');
    name = name.replaceAll(RegExp(r'\bSeason\s+\d{1,2}\b', caseSensitive: false), ' ');

    // Drop roman numerals that act as a suffix to the series name
    // (`Strike the Blood II` → `Strike the Blood`). Require a word character
    // immediately before the roman numeral AND at least one non-word
    // character (whitespace / start) somewhere before — this way the
    // whole-name case (`VI`) is preserved but `Strike the Blood II` is
    // still cleaned.
    name = name.replaceAll(
      RegExp(r'(?<=\S)(?:^|\s)+(?:II|III|IV|V|VI|VII|VIII|IX|X|XI|XII)(?=\s|$)'),
      ' ',
    );

    // Drop ordinal markers (`2nd`, `3rd`, `4th`, ...) at end of string.
    name = name.replaceAll(
      RegExp(r'(?:^|\s)\d+(?:st|nd|rd|th)(?=\s|$)', caseSensitive: false),
      ' ',
    );

    // Drop file-quality noise that sometimes leaks into folder names
    // (`1080p`, `720p`, `BluRay`, `WEB-DL`, `x265`, etc).
    const noise = [
      '1080p', '720p', '2160p', '4k',
      'bluray', 'blu-ray', 'web-dl', 'webrip', 'hdrip',
      'hdtv', 'dvdrip', 'remux',
      'x264', 'x265', 'h264', 'h265', 'h 264', 'h 265',
      'hevc', 'avc',
    ];
    for (final n in noise) {
      name = name.replaceAll(RegExp('(?<![\\w])${RegExp.escape(n)}(?![\\w])', caseSensitive: false), ' ');
    }

    // Normalize: lowercase, strip all punctuation, collapse whitespace.
    name = name.toLowerCase();
    name = name.replaceAll(RegExp(r'[\.\-_/\\]'), ' ');
    name = name.replaceAll(RegExp(r'[<>(){}\[\]"`]'), ' ');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    return name;
  }

  /// "Compact" form for alias matching: alphanumerics + digits only,
  /// lowercase. Used so that punctuation / whitespace differences
  /// between folder names don't split an otherwise-identical series.
  static String _compact(String baseName) =>
      baseName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

class _MutableGroup {
  _MutableGroup({
    required this.baseName,
    required this.displayName,
    required this.folders,
    required this.addedAt,
  });

  String baseName;
  String displayName;
  final List<LibraryFolder> folders;
  DateTime addedAt;
}
