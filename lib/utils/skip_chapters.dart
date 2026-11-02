import '../services/exo_player.dart';

// Pure skip-intro / skip-credits logic on top of the existing chapter list.
// Chapter NAME matching only — no network. The optional IntroDB lookup lives
// in lib/services/intro_db.dart and is compiled in via
// --dart-define=INTRODB_BASE_URL (off by default).

/// Word-boundary matchers so "Operetta" or "Credit to..." quirks don't
/// misfire: `opening`, `intro`, `op` (anime), `ending`, `credits`/`credit`,
/// `ed`.
final RegExp _introName = RegExp(
  r'\b(opening|intro|op)\b',
  caseSensitive: false,
);
final RegExp _creditsName = RegExp(
  r'\b(ending|end|credits?|ed)\b',
  caseSensitive: false,
);

class SkipChapters {
  const SkipChapters._();

  static bool isIntroName(String title) => _introName.hasMatch(title);

  static bool isCreditsName(String title) => _creditsName.hasMatch(title);

  /// The first chapter whose name reads as an opening/intro, or null.
  static ExoChapter? findIntro(List<ExoChapter> chapters) {
    for (final ch in chapters) {
      if (isIntroName(ch.title)) return ch;
    }
    return null;
  }

  /// The LAST chapter whose name reads as ending/credits (credits sit at the
  /// end of the file), or null.
  static ExoChapter? findCredits(List<ExoChapter> chapters) {
    for (final ch in chapters.reversed) {
      if (isCreditsName(ch.title)) return ch;
    }
    return null;
  }

  /// Where "Skip intro" seeks: the start of the chapter AFTER the intro
  /// (i.e. the end of the intro). Null when there is no intro, or when the
  /// intro is the last chapter — there is then nothing to skip *to* (seeking
  /// to its endMs would just end the video).
  static int? skipIntroTargetMs(List<ExoChapter> chapters) {
    final intro = findIntro(chapters);
    if (intro == null) return null;
    final i = chapters.indexOf(intro);
    if (i + 1 >= chapters.length) return null;
    final target = chapters[i + 1].startMs;
    return target > intro.startMs ? target : null;
  }

  /// Where "Skip credits" seeks: the start of the credits chapter, or null.
  static int? skipCreditsTargetMs(List<ExoChapter> chapters) {
    return findCredits(chapters)?.startMs;
  }

  /// Show the "Skip intro" affordance while the playhead is still inside (or
  /// before) the intro and a real skip target exists.
  static bool shouldShowSkipIntro(List<ExoChapter> chapters, int positionMs) {
    final target = skipIntroTargetMs(chapters);
    return target != null && positionMs < target;
  }

  /// Show "Skip credits" while the playhead is before the credits start.
  static bool shouldShowSkipCredits(List<ExoChapter> chapters, int positionMs) {
    final target = skipCreditsTargetMs(chapters);
    return target != null && positionMs < target;
  }
}
