import 'package:dream_player/services/exo_player.dart';
import 'package:dream_player/utils/chapter_nav.dart';
import 'package:flutter_test/flutter_test.dart';

ExoChapter ch(String title, int startMs, {int? endMs}) =>
    ExoChapter(title: title, startMs: startMs, endMs: endMs);

/// The shape a VCB-Studio anime MKV actually produces: an opening, the main
/// body split into parts, and an ending.
final anime = [
  ch('Opening', 0),
  ch('Part A', 90000),
  ch('Part B', 1500000),
  ch('Ending', 3000000),
];

void main() {
  group('indexAt', () {
    test('finds the chapter containing the position', () {
      expect(ChapterNav.indexAt(anime, 0), 0);
      expect(ChapterNav.indexAt(anime, 89999), 0);
      expect(ChapterNav.indexAt(anime, 90000), 1);
      expect(ChapterNav.indexAt(anime, 2999999), 2);
    });

    test('is -1 before the first marker and past nothing', () {
      expect(ChapterNav.indexAt(anime, -1), -1);
    });

    test('the last chapter holds everything after it', () {
      expect(ChapterNav.indexAt(anime, 99999999), 3);
    });

    test('duplicate starts resolve to the last, so next cannot stall', () {
      final dupes = [ch('A', 0), ch('B', 0), ch('C', 5000)];
      expect(ChapterNav.indexAt(dupes, 0), 1);
      expect(ChapterNav.next(dupes, 0)?.title, 'C');
    });

    test('an empty list is -1', () {
      expect(ChapterNav.indexAt(const [], 5000), -1);
    });
  });

  group('next', () {
    test('steps to the following chapter', () {
      expect(ChapterNav.next(anime, 0)?.title, 'Part A');
      expect(ChapterNav.next(anime, 90000)?.title, 'Part B');
    });

    test('is null at the last chapter — no silent wrap to the start', () {
      expect(ChapterNav.next(anime, 3000000), isNull);
      expect(ChapterNav.next(anime, 9999999), isNull);
    });

    test('before the first marker it lands on the first', () {
      expect(ChapterNav.next([ch('Opening', 5000)], 0)?.title, 'Opening');
    });

    test('an empty list has no next', () {
      expect(ChapterNav.next(const [], 0), isNull);
    });
  });

  group('previous', () {
    test('within the grace window it goes to the chapter before', () {
      expect(ChapterNav.previous(anime, 90500)?.title, 'Opening');
    });

    test('inside the grace window it goes back a chapter', () {
      // 1s into "Part B" is still "just started", so this means "previous
      // chapter" — which is what a viewer pressing twice in a row expects.
      expect(ChapterNav.previous(anime, 1501000)?.title, 'Part A');
    });

    test('past the grace window it restarts the current chapter', () {
      // 5s into "Part B": the useful answer is "take me back to the start of
      // Part B", not all the way to Part A.
      expect(ChapterNav.previous(anime, 1505000)?.title, 'Part B');
    });

    test('a second press then walks back a chapter', () {
      final first = ChapterNav.previous(anime, 1505000)!;
      expect(first.title, 'Part B');
      // Landed on Part B's start, so we are inside the grace window again.
      expect(ChapterNav.previous(anime, first.startMs + 200)?.title, 'Part A');
    });

    test('the grace window is configurable', () {
      expect(ChapterNav.previous(anime, 90400, graceMs: 0)?.title, 'Part A');
      expect(ChapterNav.previous(anime, 90400, graceMs: 1000)?.title, 'Opening');
    });

    test('in the first chapter it restarts that chapter', () {
      expect(ChapterNav.previous(anime, 5000)?.title, 'Opening');
      expect(ChapterNav.previous(anime, 60000)?.title, 'Opening');
    });

    test('an empty list has no previous', () {
      expect(ChapterNav.previous(const [], 0), isNull);
    });
  });

  group('current', () {
    test('names the chapter playing', () {
      expect(ChapterNav.current(anime, 95000)?.title, 'Part A');
      expect(ChapterNav.current(anime, 0)?.title, 'Opening');
      expect(ChapterNav.current(const [], 0), isNull);
    });
  });
}