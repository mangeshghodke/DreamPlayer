import '../services/exo_player.dart';

/// What kind of scene a skip segment covers (issue #60).
enum SkipSegmentKind { intro, recap, credits }

/// One skippable scene: [startMs, endMs). Source is either an embedded
/// container chapter or a community timestamp (AniSkip).
class SkipSegment {
  const SkipSegment({
    required this.startMs,
    required this.endMs,
    required this.kind,
  });

  final int startMs;
  final int endMs;
  final SkipSegmentKind kind;

  /// Where a "Skip …" button seeks: the end of the segment.
  int get targetMs => endMs;

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'endMs': endMs,
        'kind': kind.name,
      };

  static SkipSegment? fromJson(Map<dynamic, dynamic> m) {
    final start = m['startMs'];
    final end = m['endMs'];
    if (start is! num || end is! num) return null;
    final kindName = m['kind'] as String?;
    final kind = SkipSegmentKind.values
        .where((k) => k.name == kindName)
        .firstOrNull;
    if (kind == null) return null;
    return SkipSegment(
      startMs: start.toInt(),
      endMs: end.toInt(),
      kind: kind,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SkipSegment &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(startMs, endMs, kind);
}

/// Pure skip-segment logic (issue #60): chapter-name detection, merging with
/// remote (AniSkip) segments, and the "which segment is the playhead in / next
/// to" queries the player pill and auto-skip use. No Flutter, no IO.
class SkipSegments {
  const SkipSegments._();

  /// Word-boundary matchers so "Operetta" or "Credit to…" don't misfire.
  static final RegExp _introName =
      RegExp(r'\b(opening|intro|op)\b', caseSensitive: false);
  static final RegExp _recapName =
      RegExp(r'\b(recap|previously)\b', caseSensitive: false);
  static final RegExp _creditsName =
      RegExp(r'\b(ending|end|credits?|ed)\b', caseSensitive: false);

  static bool isIntroName(String title) => _introName.hasMatch(title);
  static bool isRecapName(String title) => _recapName.hasMatch(title);
  static bool isCreditsName(String title) => _creditsName.hasMatch(title);

  /// Segments derived from embedded chapter names. The intro/recap segment
  /// runs to the NEXT chapter's start (the scene ends where the next begins);
  /// the credits segment is the LAST credits-named chapter (credits sit at the
  /// end of the file) and runs to its own end.
  static List<SkipSegment> fromChapters(List<ExoChapter> chapters) {
    final out = <SkipSegment>[];
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final nextStart = i + 1 < chapters.length ? chapters[i + 1].startMs : null;
      final end = (nextStart != null && nextStart > ch.startMs)
          ? nextStart
          : (ch.endMs ?? ch.startMs);
      if (isIntroName(ch.title)) {
        out.add(SkipSegment(startMs: ch.startMs, endMs: end, kind: SkipSegmentKind.intro));
      } else if (isRecapName(ch.title)) {
        out.add(SkipSegment(startMs: ch.startMs, endMs: end, kind: SkipSegmentKind.recap));
      }
    }
    // Credits: last match wins (credits are at the end; an early "End" chapter
    // of a multi-part file must not shadow them).
    for (final ch in chapters.reversed) {
      if (isCreditsName(ch.title)) {
        final end = ch.endMs != null && ch.endMs! > ch.startMs ? ch.endMs! : ch.startMs;
        out.add(SkipSegment(startMs: ch.startMs, endMs: end, kind: SkipSegmentKind.credits));
        break;
      }
    }
    return out;
  }

  /// Merge chapter-derived and remote segments. Per kind, the CHAPTER wins
  /// when it has one (a labeled chapter matches this exact file); remote
  /// fills the kinds the chapters don't label.
  static List<SkipSegment> merge(
    List<SkipSegment> chapterSegments,
    List<SkipSegment> remoteSegments,
  ) {
    final out = <SkipSegment>[];
    for (final kind in SkipSegmentKind.values) {
      final fromChapters =
          chapterSegments.where((s) => s.kind == kind).toList();
      if (fromChapters.isNotEmpty) {
        out.addAll(fromChapters);
      } else {
        out.addAll(remoteSegments.where((s) => s.kind == kind));
      }
    }
    out.sort((a, b) => a.startMs.compareTo(b.startMs));
    return out;
  }

  /// The segment the playhead is INSIDE of (auto-skip trigger), or null.
  static SkipSegment? inside(List<SkipSegment> segments, int positionMs) {
    for (final s in segments) {
      if (positionMs >= s.startMs && positionMs < s.endMs) return s;
    }
    return null;
  }

  /// The segment worth prompting for: the one the playhead is inside, else
  /// the next one starting within [leadMs]. Null when nothing is near — the
  /// pill hides rather than showing "Skip intro" for the whole episode.
  static SkipSegment? promptable(
    List<SkipSegment> segments,
    int positionMs, {
    int leadMs = 5000,
  }) {
    final current = inside(segments, positionMs);
    if (current != null) return current;
    for (final s in segments) {
      if (positionMs < s.startMs && s.startMs - positionMs <= leadMs) {
        return s;
      }
    }
    return null;
  }

  /// First segment of [kind], or null.
  static SkipSegment? firstOf(List<SkipSegment> segments, SkipSegmentKind kind) {
    for (final s in segments) {
      if (s.kind == kind) return s;
    }
    return null;
  }
}
