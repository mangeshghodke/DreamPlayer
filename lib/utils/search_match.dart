/// Text matching for the library search screen.
///
/// Deliberately pure and Flutter-free so the rules are unit-tested without a
/// widget tree: the screen only decides *which* fields to search, and this
/// file decides *how* they compare.
library;

/// Accented Latin letters folded to their ASCII base. Search runs against
/// filenames and TMDB titles, which mix both spellings (`Amélie` vs `Amelie`,
/// `Pokémon` vs `Pokemon`), so a user typing the unaccented form must still
/// find the entry.
const Map<String, String> _folded = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'ą': 'a',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'ď': 'd',
  'đ': 'd',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ė': 'e',
  'ę': 'e',
  'ě': 'e',
  'ğ': 'g',
  'ģ': 'g',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'į': 'i',
  'ı': 'i',
  'ł': 'l',
  'ľ': 'l',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ō': 'o',
  'ő': 'o',
  'ř': 'r',
  'ś': 's',
  'š': 's',
  'ş': 's',
  'ť': 't',
  'ţ': 't',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ū': 'u',
  'ů': 'u',
  'ű': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
  'ß': 'ss',
  'æ': 'ae',
  'œ': 'oe',
};

/// Lowercases, folds accents and turns every run of punctuation/whitespace
/// into a single space, so `"Dark.S01E05 [1080p]"` matches `"dark s01e05"`.
String normalizeForSearch(String input) {
  final lower = input.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    final folded = _folded[char] ?? char;
    final isWord = RegExp(r'[a-z0-9]').hasMatch(folded);
    if (isWord) {
      buffer.write(folded);
    } else {
      buffer.write(' ');
    }
  }
  return buffer.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// Whether every token of [query] appears somewhere in [fields].
///
/// All fields are joined into one haystack on purpose: a title split across
/// the show name and the episode code (`Dark` + `S01E05`) is one searchable
/// string, not two independent ones.
bool searchMatches(String query, Iterable<String?> fields) {
  final needle = normalizeForSearch(query);
  if (needle.isEmpty) return true;
  final haystack = fields
      .whereType<String>()
      .map(normalizeForSearch)
      .where((f) => f.isNotEmpty)
      .join(' ');
  if (haystack.isEmpty) return false;
  for (final token in needle.split(' ')) {
    if (!haystack.contains(token)) return false;
  }
  return true;
}

/// Match rank for ordering results, or `null` when [query] does not match.
///
/// 0 - [primary] starts with the whole query (the entry the user is typing).
/// 1 - [primary] contains it somewhere.
/// 2 - only a secondary field (episode code, original title, member folder)
///     matched.
int? searchRank(
  String query, {
  required String primary,
  Iterable<String?> secondary = const [],
}) {
  if (!searchMatches(query, [primary, ...secondary])) return null;
  final needle = normalizeForSearch(query);
  final normalizedPrimary = normalizeForSearch(primary);
  if (normalizedPrimary.startsWith(needle)) return 0;
  if (normalizedPrimary.contains(needle)) return 1;
  return 2;
}
