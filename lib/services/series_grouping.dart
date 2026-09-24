import 'library_folders.dart';

/// A grouping of library folders that share the same base series name.
///
/// For example, `Strike the Blood`, `Strike the Blood II`, `Strike the Blood
/// III`, `Strike the Blood IV` all collapse into a single [SeriesGroup] so
/// they appear as ONE card on the home library grid (Flux-style), with all
/// four seasons listed inside.
///
/// When the user taps the grouped card, the [SeriesSeasonsScreen] opens
/// and shows the seasons across every folder in [folders].
class SeriesGroup {
  const SeriesGroup({
    required this.baseName,
    required this.displayName,
    required this.folders,
    this.primaryFolder,
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

  final LibraryFolder? primaryFolder;

  /// The "primary" folder used for the card artwork (TMDB poster, etc).
  /// Prefer the shortest-name folder (the canonical show name, e.g.
  /// "Strike the Blood" over "Strike the Blood Final") so the group's
  /// metadataKey resolves to the correct base-season poster.
  LibraryFolder get primary {
    final selected = primaryFolder;
    if (selected != null && folders.contains(selected)) return selected;
    return folders.reduce(
      (a, b) => a.name.length <= b.name.length ? a : b,
    );
  }

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

    // Step 3b: fold groups where one compact form is a long prefix of another
    // (e.g. "striketheblood" vs "strikethebloodkietaiseisouhen").  The extra
    // suffix may be a Japanese arc name, OVA subtitle, or other text that
    // baseNameOf can't strip.  Only merge when the shared prefix is at least
    // as long as the remaining extra text (and ≥ 6 chars) to avoid false
    // positives like "house" + "houseofcards".
    _mergePrefixGroups(byBase);

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

  List<SeriesGroup> groupExplicitSeasonFolders(
      List<LibraryFolder> folders) {
    if (folders.isEmpty) return const [];

    final byKey = <String, _MutableGroup>{};
    final keyByFolder = <LibraryFolder, String>{};
    for (final folder in folders) {
      if (folder.isFile || _explicitSeasonNumber(folder.name) == null) {
        continue;
      }
      final baseName = baseNameOf(folder.name);
      final key = '${_scopeKey(folder)}\u0000$baseName';
      keyByFolder[folder] = key;
      final group = byKey.putIfAbsent(
        key,
        () => _MutableGroup(
          baseName: baseName,
          displayName: folder.name,
          folders: [],
          addedAt: folder.addedAt,
        ),
      );
      group.folders.add(folder);
      if (folder.name.length < group.displayName.length) {
        group.displayName = folder.name;
      }
      if (folder.addedAt.isAfter(group.addedAt)) {
        group.addedAt = folder.addedAt;
      }
    }

    final result = <SeriesGroup>[];
    final emitted = <String>{};
    for (final folder in folders) {
      final key = keyByFolder[folder];
      if (key == null) {
        result.add(SeriesGroup(
          baseName: baseNameOf(folder.name),
          displayName: folder.name,
          folders: [folder],
        ));
        continue;
      }
      if (!emitted.add(key)) continue;
      final group = byKey[key]!;
      final primary = _explicitSeasonPrimary(group.folders);
      result.add(SeriesGroup(
        baseName: group.baseName,
        displayName: primary.name,
        folders: group.folders,
        primaryFolder: primary,
      ));
    }
    return result;
  }

  static int? _explicitSeasonNumber(String name) {
    final short = RegExp(
      r'\bS(\d{1,2})(?=E\d{1,2}\b|\b)',
      caseSensitive: false,
    ).firstMatch(name);
    if (short != null) return int.tryParse(short.group(1)!);
    final word = RegExp(
      r'\bSeason\s*(\d{1,2})\b',
      caseSensitive: false,
    ).firstMatch(name);
    return word == null ? null : int.tryParse(word.group(1)!);
  }

  static String _scopeKey(LibraryFolder folder) {
    return switch (folder.source) {
      LibraryFolderSource.files => 'files',
      LibraryFolderSource.smb =>
        'smb|${folder.networkServerId ?? ''}|${folder.networkShare ?? ''}',
      LibraryFolderSource.webdav =>
        'webdav|${folder.networkServerId ?? folder.networkLabel ?? ''}',
      LibraryFolderSource.ftp =>
        'ftp|${folder.networkServerId ?? folder.networkLabel ?? ''}',
      LibraryFolderSource.upnp =>
        'upnp|${folder.networkServerId ?? folder.networkLabel ?? ''}',
      LibraryFolderSource.jellyfin =>
        'jellyfin|${(folder.jellyfinServerUrl ?? '').replaceAll(RegExp(r'/+$'), '').toLowerCase()}',
    };
  }

  static LibraryFolder _explicitSeasonPrimary(List<LibraryFolder> folders) {
    final seasonOne = folders
        .where((folder) => _explicitSeasonNumber(folder.name) == 1)
        .toList();
    final candidates = seasonOne.isEmpty ? folders : seasonOne;
    return candidates.reduce(
      (a, b) => a.name.length <= b.name.length ? a : b,
    );
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

  /// Merges groups whose compact names share a long common prefix.
  ///
  /// Handles cases like `"striketheblood"` vs
  /// `"strikethebloodkietaiseisouhen"` where an unstrippable suffix (Japanese
  /// arc name, OVA subtitle, etc.) prevents the compact dedup from firing.
  ///
  /// The rule: if compact A is a prefix of compact B and the shared prefix is
  /// at least as long as the remaining extra text (and ≥ 6 chars), merge them.
  /// This prevents false positives like `"house"` + `"houseofcards"` (shared 5
  /// < extra 7 → no merge) while catching real franchises like
  /// `"striketheblood"` (15) + `"strikethebloodkietaiseisouhen"` (30) →
  /// shared 15 ≥ extra 15 → merge.
  void _mergePrefixGroups(Map<String, _MutableGroup> byBase) {
    final keys = byBase.keys.toList();
    // Sort shorter-first so the canonical (shorter) entry is always the target.
    keys.sort((a, b) => a.length.compareTo(b.length));

    for (int i = 0; i < keys.length; i++) {
      final shortKey = keys[i];
      final shortGroup = byBase[shortKey];
      if (shortGroup == null) continue; // already absorbed
      final shortCompact = _compact(shortKey);

      for (int j = i + 1; j < keys.length; j++) {
        final longKey = keys[j];
        final longGroup = byBase[longKey];
        if (longGroup == null) continue;
        final longCompact = _compact(longKey);

        // Check if shortCompact is a prefix of longCompact.
        if (!longCompact.startsWith(shortCompact)) continue;

        final shared = shortCompact.length;
        final extra = longCompact.length - shared;
        // Require the shared prefix to be substantial (≥ 10 chars) and the
        // extra suffix to be at least as long as the prefix.  This catches
        // real franchises like "Strike the Blood" (15) +
        // "Strike the Blood Kieta Seisou Hen" (30, extra 15 ≥ 15) while
        // keeping "Kakegurui" (9) + "Kakegurui Twin" (extra 4 < 9) and
        // "House" (5) + "House of Cards" (shared < 10) separate.
        if (shared < 10 || extra < shared) continue;

        // Merge long into short (short is the canonical group).
        shortGroup.folders.addAll(longGroup.folders);
        if (longGroup.addedAt.isAfter(shortGroup.addedAt)) {
          shortGroup.addedAt = longGroup.addedAt;
        }
        if (longGroup.displayName.length < shortGroup.displayName.length) {
          shortGroup.displayName = longGroup.displayName;
        }
        if (longKey.length < shortGroup.baseName.length) {
          shortGroup.baseName = longKey;
        }
        byBase.remove(longKey);
      }
    }
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
    // Strip trailing slash (SMB/network directory entries include it).
    name = name.replaceAll(RegExp(r'/+$'), ' ');
    // Drop fansub group tags in square brackets ([VCB-Studio], [SubGroup], etc).
    name = name.replaceAll(RegExp(r'\[.*?\]'), ' ');
    // Drop a trailing year in parens/brackets ("(2021)" or "[2021]").
    name = name.replaceAll(RegExp(r'\s*[\(\[]\s*\d{4}\s*[\)\]]'), ' ');
    // Drop a bare year at the end of the string.
    name = name.replaceAll(RegExp(r'\s+\d{4}$'), ' ');

    // Drop season tags glued to the title (`My Show S02`, `My.Show.S02.1080p`,
    // `My Show Season 2`).
    name = name.replaceAll(RegExp(r'\bS\d{1,2}(E\d{1,2})?\b', caseSensitive: false), ' ');
    name = name.replaceAll(RegExp(r'\bSeason\s*\d{1,2}\b', caseSensitive: false), ' ');

    // Drop roman numerals that act as a suffix to the series name
    // (`Strike the Blood II` → `Strike the Blood`). Require a word character
    // immediately before the roman numeral AND at least one non-word
    // character (whitespace / start) somewhere before — this way the
    // whole-name case (`VI`) is preserved but `Strike the Blood II` is
    // still cleaned.
    name = name.replaceAll(
      RegExp(r'(?<=\S)(?:^|\s)+(?:II|III|IV|V|VI|VII|VIII|IX|X|XI|XII)(?=\s|$)',
          caseSensitive: false),
      ' ',
    );

    // Drop season-name suffixes like "Grand", "Final", "Z" that act as
    // ordinal season labels.
    name = name.replaceAll(
      RegExp(r'\b(?:Grand|Ultimate|Final|Z)\b', caseSensitive: false),
      ' ',
    );

    // Drop ordinal markers (`2nd`, `3rd`, `4th`, ...) at end of string.
    name = name.replaceAll(
      RegExp(r'(?:^|\s)\d+(?:st|nd|rd|th)(?=\s|$)', caseSensitive: false),
      ' ',
    );

    // Drop trailing part numbers ONLY when a season-like tag is already
    // present in the name (S01, Season N, roman numeral).  This keeps
    // season-folder names like "House S02 1080p" → "house" while leaving
    // movie-part folders like "GIRLS und PANZER das FINALE 01" intact
    // so each part gets its own card instead of being grouped.
    name = _conditionallyStripTrailingNumber(name);

    // Drop file-quality noise that sometimes leaks into folder names
    // (`1080p`, `720p`, `BluRay`, `WEB-DL`, `x265`, etc).
    const noise = [
      '1080p', '720p', '2160p', '4k',
      'bluray', 'blu-ray', 'web-dl', 'webrip', 'hdrip',
      'hdtv', 'dvdrip', 'remux',
      'x264', 'x265', 'h264', 'h265', 'h 264', 'h 265',
      'hevc', 'avc',
      '10bit', '8bit', '10 bit', '8 bit',
      'aac', 'dts', 'flac', 'ac3', 'eac3', 'truehd', 'dca',
      'english', 'multi', 'dual', 'japanese', 'hindi', 'korean',
      'bdrip', 'hdrip',
      'panda', 'subs', 'raw', 'internal', 'uncensored',
    ];
    // Strip audio channel counts (5.1, 7.1, 2.0, etc.) — always noise.
    name = name.replaceAll(RegExp(r'(?<!\w)\d+\.\d+(?!\w)'), ' ');
    for (final n in noise) {
      name = name.replaceAll(RegExp('(?<![\\w])${RegExp.escape(n)}(?![\\w])', caseSensitive: false), ' ');
    }
    // Re-strip trailing part numbers that became trailing after noise removal.
    name = _conditionallyStripTrailingNumber(name);

    // Normalize: lowercase, strip all punctuation, collapse whitespace.
    name = name.toLowerCase();
    name = name.replaceAll(RegExp(r'[\.\-_/\\]'), ' ');
    name = name.replaceAll(RegExp(r'[<>(){}\[\]"`]'), ' ');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Final trailing number strip after normalization (catches cases like
    // "house s02 1080p" that survived earlier passes — only when season tag).
    name = _conditionallyStripTrailingNumber(name).trim();
    return name;
  }

  /// "Compact" form for alias matching: alphanumerics + digits only,
  /// lowercase. Used so that punctuation / whitespace differences
  /// between folder names don't split an otherwise-identical series.
  static String _compact(String baseName) =>
      baseName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Strips a trailing number from [name] only when a season-like tag
  /// (S01, Season N, roman numeral) is already present.  This keeps
  /// movie-part folders (e.g. "das FINALE 01") as separate entries
  /// while still collapsing season folders (e.g. "House S02 1080p").
  static String _conditionallyStripTrailingNumber(String name) {
    final hasSeasonTag = RegExp(
      r'\bS\d{1,2}\b|\bSeason\s*\d+|\b(?:I{1,3}|IV|V|VI{0,3}|IX|X)\b',
      caseSensitive: false,
    ).hasMatch(name);
    if (hasSeasonTag) {
      return name.replaceAll(RegExp(r'\s+\d{1,3}\s*$'), ' ');
    }
    return name;
  }
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
