import 'package:dream_player/services/tmdb_client.dart';
import 'package:dream_player/utils/episode_label.dart';
import 'package:flutter_test/flutter_test.dart';

/// Issue #38 follow-up: with no connection there is no TMDB name, and the old
/// fallback was `ParsedFileName.title`, which for `Dark.S01E05.mkv` is the SHOW
/// name — so every episode in a season rendered as "Dark".
void main() {
  group('episodeRowTitle', () {
    test('uses the TMDB name when available', () {
      final parsed = ParsedFileName.parse('Dark.S01E05.mkv');
      expect(
        episodeRowTitle(
          parsed: parsed,
          fileName: 'Dark.S01E05.mkv',
          tmdbName: 'Tarnished Cities',
        ),
        'Tarnished Cities',
      );
    });

    test('falls back to S01E05 offline, NOT the show name', () {
      final parsed = ParsedFileName.parse('Dark.S01E05.mkv');
      final title = episodeRowTitle(
        parsed: parsed,
        fileName: 'Dark.S01E05.mkv',
      );
      expect(title, 'S01E05');
      expect(title, isNot(contains('Dark')));
    });

    test('distinct numbers offline, so a season is still scannable', () {
      final titles = [1, 2, 3, 4, 5, 6]
          .map((e) => episodeRowTitle(
                parsed: ParsedFileName.parse('Dark.S01E0$e.mkv'),
                fileName: 'Dark.S01E0$e.mkv',
              ))
          .toList();
      expect(titles, [
        'S01E01',
        'S01E02',
        'S01E03',
        'S01E04',
        'S01E05',
        'S01E06',
      ]);
      expect(titles.toSet().length, 6, reason: 'no two rows may look alike');
    });

    test('season number is honoured, not assumed to be 1', () {
      expect(
        episodeRowTitle(
          parsed: ParsedFileName.parse('Show.S03E12.mkv'),
          fileName: 'Show.S03E12.mkv',
        ),
        'S03E12',
      );
    });

    test('movies fall back to the file name', () {
      final parsed = ParsedFileName.parse('Cocktail 2 (2026).mkv');
      expect(
        episodeRowTitle(parsed: parsed, fileName: 'Cocktail 2 (2026).mkv'),
        'Cocktail 2 (2026).mkv',
      );
    });

    test('an empty file name still renders something', () {
      expect(
        episodeRowTitle(
          parsed: const ParsedFileName(title: ''),
          fileName: '   ',
        ),
        'Video',
      );
    });

    test('a blank TMDB name is treated as missing', () {
      expect(
        episodeRowTitle(
          parsed: ParsedFileName.parse('Dark.S01E05.mkv'),
          fileName: 'Dark.S01E05.mkv',
          tmdbName: '   ',
        ),
        'S01E05',
      );
    });
  });

  group('titleIsEpisodeCode', () {
    test('true offline, so the badge line is suppressed', () {
      final parsed = ParsedFileName.parse('Dark.S01E05.mkv');
      final title = episodeRowTitle(
        parsed: parsed,
        fileName: 'Dark.S01E05.mkv',
      );
      expect(titleIsEpisodeCode(parsed: parsed, title: title), isTrue);
    });

    test('false when TMDB named the episode', () {
      final parsed = ParsedFileName.parse('Dark.S01E05.mkv');
      expect(
        titleIsEpisodeCode(parsed: parsed, title: 'Tarnished Cities'),
        isFalse,
      );
    });

    test('false for a movie', () {
      final parsed = ParsedFileName.parse('Cocktail 2 (2026).mkv');
      expect(
        titleIsEpisodeCode(parsed: parsed, title: 'Cocktail 2 (2026).mkv'),
        isFalse,
      );
    });
  });

  test('episodeCode pads to two digits', () {
    expect(episodeCode(1, 5), 'S01E05');
    expect(episodeCode(12, 345), 'S12E345');
  });
}
