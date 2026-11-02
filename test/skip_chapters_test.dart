import 'package:dream_player/services/exo_player.dart';
import 'package:dream_player/utils/skip_chapters.dart';
import 'package:flutter_test/flutter_test.dart';

ExoChapter ch(String title, int startMs, {int? endMs}) =>
    ExoChapter(title: title, startMs: startMs, endMs: endMs);

/// The real VCB-Studio anime shape: Opening / Part A / Part B / Ending.
List<ExoChapter> animeChapters() => [
      ch('Opening', 0, endMs: 90000),
      ch('Part A', 90000, endMs: 600000),
      ch('Part B', 600000, endMs: 1320000),
      ch('Ending', 1320000, endMs: 1410000),
    ];

void main() {
  group('name matching', () {
    test('intro names', () {
      expect(SkipChapters.isIntroName('Opening'), isTrue);
      expect(SkipChapters.isIntroName('OP'), isTrue);
      expect(SkipChapters.isIntroName('Intro 2'), isTrue);
      expect(SkipChapters.isIntroName('オープニング'), isFalse); // no JP match by design
      expect(SkipChapters.isIntroName('Operetta'), isFalse); // word boundary
      expect(SkipChapters.isIntroName('Part A'), isFalse);
    });

    test('credits names', () {
      expect(SkipChapters.isCreditsName('Ending'), isTrue);
      expect(SkipChapters.isCreditsName('Credits'), isTrue);
      expect(SkipChapters.isCreditsName('ED'), isTrue);
      expect(SkipChapters.isCreditsName('The End'), isTrue);
      expect(SkipChapters.isCreditsName('Part B'), isFalse);
      expect(SkipChapters.isCreditsName('Weekend'), isFalse); // word boundary
    });
  });

  group('skip targets', () {
    test('skip intro seeks to the next chapter start (end of intro)', () {
      expect(SkipChapters.skipIntroTargetMs(animeChapters()), 90000);
    });

    test('skip credits seeks to the credits chapter start', () {
      expect(SkipChapters.skipCreditsTargetMs(animeChapters()), 1320000);
    });

    test('intro running to EOF has no skip target', () {
      final only = [ch('Opening', 0, endMs: 600000)];
      expect(SkipChapters.skipIntroTargetMs(only), isNull);
    });

    test('intro with no next chapter -> null', () {
      final cs = [ch('Intro', 5000)];
      expect(SkipChapters.skipIntroTargetMs(cs), isNull);
    });

    test('intro skips to the next chapter start even with its own endMs', () {
      final cs = [ch('OP', 0, endMs: 80000), ch('Ep', 95000)];
      expect(SkipChapters.skipIntroTargetMs(cs), 95000);
    });

    test('no intro/credits chapters -> nulls', () {
      final cs = [ch('Part A', 0), ch('Part B', 600000)];
      expect(SkipChapters.skipIntroTargetMs(cs), isNull);
      expect(SkipChapters.skipCreditsTargetMs(cs), isNull);
    });

    test('last credits-named chapter wins when several exist', () {
      final cs = [
        ch('Ending', 1000000),
        ch('Part A', 1100000),
        ch('Credits', 1300000),
      ];
      expect(SkipChapters.findCredits(cs)?.title, 'Credits');
    });
  });

  group('visibility', () {
    test('skip intro visible only while before the target', () {
      final cs = animeChapters();
      expect(SkipChapters.shouldShowSkipIntro(cs, 0), isTrue);
      expect(SkipChapters.shouldShowSkipIntro(cs, 89999), isTrue);
      expect(SkipChapters.shouldShowSkipIntro(cs, 90000), isFalse);
      expect(SkipChapters.shouldShowSkipIntro(cs, 700000), isFalse);
    });

    test('skip credits visible only while before the credits', () {
      final cs = animeChapters();
      expect(SkipChapters.shouldShowSkipCredits(cs, 1319999), isTrue);
      expect(SkipChapters.shouldShowSkipCredits(cs, 1320000), isFalse);
    });
  });
}
