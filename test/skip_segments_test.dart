import 'package:dream_player/services/exo_player.dart';
import 'package:dream_player/utils/skip_segments.dart';
import 'package:flutter_test/flutter_test.dart';

ExoChapter ch(String title, int startMs, [int? endMs]) =>
    ExoChapter(title: title, startMs: startMs, endMs: endMs);

void main() {
  group('fromChapters', () {
    test('intro chapter spans to the next chapter start', () {
      final segs = SkipSegments.fromChapters([
        ch('Opening', 5000, 95000),
        ch('Part A', 95000, 600000),
        ch('Credits', 1300000, 1400000),
      ]);
      final intro = SkipSegments.firstOf(segs, SkipSegmentKind.intro);
      expect(intro, isNotNull);
      expect(intro!.startMs, 5000);
      expect(intro.endMs, 95000); // next chapter start, not the chapter end
      final credits = SkipSegments.firstOf(segs, SkipSegmentKind.credits);
      expect(credits!.startMs, 1300000);
      expect(credits.endMs, 1400000);
    });

    test('recap chapter is detected separately from intro', () {
      final segs = SkipSegments.fromChapters([
        ch('Recap', 0, 30000),
        ch('Opening', 30000, 120000),
        ch('Episode', 120000),
      ]);
      expect(SkipSegments.firstOf(segs, SkipSegmentKind.recap)?.startMs, 0);
      expect(SkipSegments.firstOf(segs, SkipSegmentKind.intro)?.startMs, 30000);
    });

    test('last credits-named chapter wins, not an early "End"', () {
      final segs = SkipSegments.fromChapters([
        ch('Part 1', 0, 600000),
        ch('End', 600000, 700000), // mid-file "End" of part 1
        ch('Credits', 1300000, 1400000),
      ]);
      final credits = SkipSegments.firstOf(segs, SkipSegmentKind.credits);
      expect(credits!.startMs, 1300000);
    });

    test('word-boundary matching: "Operetta" is not an intro', () {
      final segs = SkipSegments.fromChapters([ch('Operetta', 0, 60000)]);
      expect(segs, isEmpty);
    });

    test('anime "OP"/"ED" names match', () {
      final segs = SkipSegments.fromChapters([
        ch('OP', 0, 90000),
        ch('ED', 1300000, 1400000),
      ]);
      expect(SkipSegments.firstOf(segs, SkipSegmentKind.intro), isNotNull);
      expect(SkipSegments.firstOf(segs, SkipSegmentKind.credits), isNotNull);
    });
  });

  group('merge', () {
    test('chapter wins per kind, remote fills the gaps', () {
      final chapterSegs = [
        const SkipSegment(startMs: 1000, endMs: 90000, kind: SkipSegmentKind.intro),
      ];
      final remoteSegs = [
        const SkipSegment(startMs: 5600, endMs: 95600, kind: SkipSegmentKind.intro),
        const SkipSegment(startMs: 130000, endMs: 200000, kind: SkipSegmentKind.recap),
        const SkipSegment(startMs: 1295000, endMs: 1385000, kind: SkipSegmentKind.credits),
      ];
      final merged = SkipSegments.merge(chapterSegs, remoteSegs);
      // intro from chapters (1000-90000), recap+credits from remote
      expect(merged.length, 3);
      expect(SkipSegments.firstOf(merged, SkipSegmentKind.intro)!.startMs, 1000);
      expect(SkipSegments.firstOf(merged, SkipSegmentKind.recap)!.startMs, 130000);
      expect(SkipSegments.firstOf(merged, SkipSegmentKind.credits)!.startMs, 1295000);
      // sorted by start
      expect(merged[0].startMs <= merged[1].startMs, isTrue);
      expect(merged[1].startMs <= merged[2].startMs, isTrue);
    });
  });

  group('inside / promptable', () {
    final segs = [
      const SkipSegment(startMs: 5000, endMs: 95000, kind: SkipSegmentKind.intro),
      const SkipSegment(startMs: 1300000, endMs: 1400000, kind: SkipSegmentKind.credits),
    ];

    test('inside returns the containing segment', () {
      expect(SkipSegments.inside(segs, 5000)?.kind, SkipSegmentKind.intro);
      expect(SkipSegments.inside(segs, 94999)?.kind, SkipSegmentKind.intro);
      expect(SkipSegments.inside(segs, 95000), isNull); // end is exclusive
      expect(SkipSegments.inside(segs, 0), isNull);
    });

    test('promptable shows inside the segment and within the 5 s lead-in', () {
      expect(SkipSegments.promptable(segs, 50000)?.kind, SkipSegmentKind.intro);
      expect(SkipSegments.promptable(segs, 2000)?.kind, SkipSegmentKind.intro); // 3 s before
    });

    test('promptable boundary: exactly leadMs before start is shown, further is not', () {
      expect(SkipSegments.promptable(segs, 0, leadMs: 5000), isNotNull); // exactly 5000 ms before
      expect(SkipSegments.promptable(segs, 0, leadMs: 4999), isNull);
      expect(SkipSegments.promptable(segs, 96000), isNull); // past intro, far from credits
      expect(SkipSegments.promptable(segs, 1296000)?.kind, SkipSegmentKind.credits); // 4 s before credits
    });
  });

  group('SkipSegment json', () {
    test('round-trips', () {
      const s = SkipSegment(startMs: 1, endMs: 2, kind: SkipSegmentKind.recap);
      final back = SkipSegment.fromJson(s.toJson());
      expect(back, s);
    });

    test('rejects garbage', () {
      expect(SkipSegment.fromJson({'startMs': 'x'}), isNull);
      expect(SkipSegment.fromJson({'startMs': 1, 'endMs': 2, 'kind': 'nope'}), isNull);
    });
  });
}
