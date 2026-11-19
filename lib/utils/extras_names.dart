/// Infuse-style extras naming (competitor-gap #9).
///
/// A file is an "extra" when a hyphen/space/underscore/dot-delimited token of
/// its name (before the extension) is one of the keywords Infuse uses:
/// `trailer`, `deleted`, `behindthescenes`, `featurette`, `interview`,
/// `scene`, `short`, `other`. The part of the name BEFORE the keyword is the
/// title the extra belongs to, so `The Matrix-deleted-1080p.mkv` groups under
/// `The Matrix`.
///
/// Pure string helpers only - no Flutter imports - so the rules can be
/// unit-tested and reused by every browser.
library;

/// The Infuse keyword -> human label shown on the extras row.
const Map<String, String> extrasKindLabels = {
  'trailer': 'Trailer',
  'deleted': 'Deleted scene',
  'behindthescenes': 'Behind the scenes',
  'featurette': 'Featurette',
  'interview': 'Interview',
  'scene': 'Scene',
  'short': 'Short',
  'other': 'Extra',
};

/// One parsed extras file. [baseName] is the title it belongs to (empty when
/// the keyword is the FIRST chunk, e.g. `trailer.mkv`).
class ExtrasName {
  const ExtrasName({
    required this.fileName,
    required this.kind,
    required this.label,
    required this.baseName,
  });

  final String fileName;

  /// The raw lowercase keyword that matched, e.g. `deleted`.
  final String kind;

  /// Human label for the UI, e.g. `Deleted scene`.
  final String label;

  /// The part of the name before the keyword (the main title).
  final String baseName;
}

/// Parses [fileName] into an [ExtrasName], or null when it is not an extra.
ExtrasName? parseExtrasName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final lower = stem.toLowerCase();

  String? matchedKind;
  int matchedAt = -1;
  for (final kind in extrasKindLabels.keys) {
    var from = 0;
    while (true) {
      final i = lower.indexOf(kind, from);
      if (i < 0) break;
      // The keyword must be a delimited chunk: preceded by a separator and
      // followed by a separator (or the end of stem). The separator BEFORE is
      // mandatory - a keyword at the very start of the stem is a real title
      // (`Trailer Park Boys.S01E01.mkv`, `Scenes from a Marriage`), and a
      // lone `trailer.mkv` is too ambiguous to claim.
      final beforeOk = i > 0 && '-_. '.contains(stem[i - 1]);
      final after = i + kind.length;
      final afterOk = after == lower.length || '-_. '.contains(stem[after]);
      if (beforeOk && afterOk) {
        matchedKind = kind;
        matchedAt = i;
        break;
      }
      from = i + kind.length;
    }
    if (matchedKind != null) break;
  }
  if (matchedKind == null) return null;

  final baseName = stem.substring(0, matchedAt)
      .replaceAll(RegExp(r'[-_. ]+$'), '')
      .trim();
  return ExtrasName(
    fileName: fileName,
    kind: matchedKind,
    label: extrasKindLabels[matchedKind]!,
    baseName: baseName,
  );
}

/// True when [fileName] is an extras file (same rule as [parseExtrasName]).
bool isExtrasFileName(String fileName) => parseExtrasName(fileName) != null;

/// Splits [fileNames] into (main, extras) preserving input order. Files that
/// are extras are removed from the main list, so an `-interview` file never
/// shows up as a second movie in a library card.
({List<String> main, List<String> extras}) splitExtrasFileNames(
  List<String> fileNames,
) {
  final main = <String>[];
  final extras = <String>[];
  for (final name in fileNames) {
    (parseExtrasName(name) == null ? main : extras).add(name);
  }
  return (main: main, extras: extras);
}