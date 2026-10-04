import '../services/exo_player.dart';

/// Chapter-jump arithmetic, kept pure so it can be unit-tested without a
/// player, a platform channel or a video.
///
/// Every function answers the question from a POSITION rather than from an
/// index the caller has to keep in sync, because the position is the only thing
/// that is true after a seek, an external bookmark jump, or a resume.
class ChapterNav {
  const ChapterNav._();

  /// Index of the chapter containing [positionMs], or -1 when the position is
  /// before the first chapter's start.
  ///
  /// Ties (two markers sharing a start, which malformed rips do produce) resolve
  /// to the LAST one, so `next` never lands on a chapter already playing.
  static int indexAt(List<ExoChapter> chapters, int positionMs) {
    var index = -1;
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i].startMs <= positionMs) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  /// The chapter AFTER the one playing, or null at the last one.
  ///
  /// Null rather than "wrap to the first": a next button that silently jumps
  /// back to the opening is how you lose an hour of watching.
  static ExoChapter? next(List<ExoChapter> chapters, int positionMs) {
    if (chapters.isEmpty) return null;
    final index = indexAt(chapters, positionMs);
    if (index < 0) return chapters.first;
    return index + 1 < chapters.length ? chapters[index + 1] : null;
  }

  /// The PREVIOUS chapter — or a restart of the current one when playback is
  /// already past its start.
  ///
  /// That grace window is what makes a second press walk backwards instead of
  /// getting stuck: pressing "previous" one second into a long OP restarts the
  /// OP, and pressing it again jumps to whatever came before.
  static ExoChapter? previous(
    List<ExoChapter> chapters,
    int positionMs, {
    int graceMs = 3000,
  }) {
    if (chapters.isEmpty) return null;
    final index = indexAt(chapters, positionMs);
    if (index < 0) return chapters.first;
    if (positionMs - chapters[index].startMs > graceMs) return chapters[index];
    return index > 0 ? chapters[index - 1] : chapters[index];
  }

  /// Title of the chapter at [positionMs], or null before the first marker.
  static ExoChapter? current(List<ExoChapter> chapters, int positionMs) {
    final index = indexAt(chapters, positionMs);
    return index < 0 ? null : chapters[index];
  }
}