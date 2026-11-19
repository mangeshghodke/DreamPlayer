import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/tmdb_client.dart';
import 'package:dream_player/utils/extras_names.dart';

void main() {
  group('parseExtrasName', () {
    test('recognizes each Infuse keyword with its label', () {
      final cases = {
        'The Matrix-deleted.mkv': 'Deleted scene',
        'The Matrix-trailer.mkv': 'Trailer',
        'The Matrix-behindthescenes.mkv': 'Behind the scenes',
        'The Matrix-featurette.mkv': 'Featurette',
        'The Matrix-interview.mkv': 'Interview',
        'The Matrix-scene.mkv': 'Scene',
        'The Matrix-short.mkv': 'Short',
        'The Matrix-other.mkv': 'Extra',
      };
      cases.forEach((file, label) {
        final parsed = parseExtrasName(file);
        expect(parsed, isNotNull, reason: file);
        expect(parsed!.label, label, reason: file);
        expect(parsed.baseName, 'The Matrix', reason: file);
      });
    });

    test('case-insensitive', () {
      final parsed = parseExtrasName('DUNE-DELETED-1080p.mkv');
      expect(parsed?.kind, 'deleted');
      expect(parsed?.baseName, 'DUNE');
    });

    test('the base keeps release noise that follows the keyword', () {
      // The keyword and the release-group tail both come after the title, so
      // only the part BEFORE the keyword is the base.
      final parsed = parseExtrasName('Dune-Deleted-1080p.x265-GROUP.mkv');
      expect(parsed?.baseName, 'Dune');
      expect(parsed?.label, 'Deleted scene');
    });

    test('a keyword inside a real title (no separator) never matches', () {
      expect(parseExtrasName('Scenes from a Marriage.mkv'), isNull);
      expect(parseExtrasName('Shortest Day.mkv'), isNull);
      expect(parseExtrasName('Interview with a Vampire.mkv'), isNull);
      expect(parseExtrasName('Trailer Park Boys.S01E01.mkv'), isNull);
    });

    test('a keyword at the very start of the stem is a title, not an extra', () {
      // "Trailer Park Boys.S01E01.mkv" is a real show; a lone "trailer.mkv"
      // in a folder is too ambiguous to claim.
      expect(parseExtrasName('trailer.mkv'), isNull);
      expect(parseExtrasName('Trailer Park Boys.S01E01.mkv'), isNull);
      expect(parseExtrasName('deleted scenes.mkv'), isNull);
    });

    test('episode files can be extras too', () {
      final parsed = parseExtrasName('Dark.S01E01-deleted.mkv');
      expect(parsed?.label, 'Deleted scene');
      expect(parsed?.baseName, 'Dark.S01E01');
    });

    test('non-extra files return null', () {
      expect(parseExtrasName('Dune.2021.mkv'), isNull);
      expect(parseExtrasName(''), isNull);
      expect(parseExtrasName('Dune.mkv'), isNull);
    });
  });

  group('splitExtrasFileNames', () {
    test('moves extras to their list and preserves order', () {
      final split = splitExtrasFileNames([
        'Dune.mkv',
        'Dune-deleted.mkv',
        'Dune-trailer.mkv',
        'Oppenheimer.mkv',
      ]);
      expect(split.main, ['Dune.mkv', 'Oppenheimer.mkv']);
      expect(split.extras, ['Dune-deleted.mkv', 'Dune-trailer.mkv']);
    });

    test('an all-extras list leaves the main list empty', () {
      final split = splitExtrasFileNames(['X-deleted.mkv']);
      expect(split.main, isEmpty);
      expect(split.extras, ['X-deleted.mkv']);
    });
  });

  group('TmdTrailer extras split', () {
    TmdDetails detailsFrom(Map<String, dynamic> videosJson) {
      return TmdDetails.fromJson({
        ...videosJson,
        'title': 'T',
      });
    }

    test('trailer/teaser types are trailers, others are extras', () {
      final details = detailsFrom({
        'videos': {
          'results': [
            {'key': 'a', 'site': 'YouTube', 'type': 'Trailer'},
            {'key': 'b', 'site': 'YouTube', 'type': 'Teaser'},
            {'key': 'c', 'site': 'YouTube', 'type': 'Behind the Scenes'},
            {'key': 'd', 'site': 'Vimeo', 'type': 'Featurette'},
            {'key': 'e', 'site': 'YouTube', 'type': 'Bloopers'},
            {'key': 'f', 'site': 'YouTube', 'type': 'Clip'},
          ],
        },
      });
      expect(details.trailers.map((t) => t.key), ['a', 'b']);
      expect(details.extras.map((t) => t.key), ['c', 'd', 'e', 'f']);
      // The type survives so the Extras card can label the row.
      expect(details.extras.first.type, 'Behind the Scenes');
      // Vimeo extras are kept and get a playable URL.
      expect(details.extras[1].watchUrl, 'https://vimeo.com/d');
      expect(details.trailers.first.isExtra, isFalse);
      expect(details.extras.first.isExtra, isTrue);
    });

    test('legacy cache entries with no type parse as trailers', () {
      // Old cached metadata has no 'type' field: default 'Trailer' keeps them
      // in the trailers list so an existing install loses nothing.
      final details = detailsFrom({
        'videos': {
          'results': [
            {'key': 'a', 'site': 'YouTube'},
          ],
        },
      });
      expect(details.trailers, hasLength(1));
      expect(details.extras, isEmpty);
    });

    test('the round-trip through JSON keeps the type', () {
      final details = detailsFrom({
        'videos': {
          'results': [
            {'key': 'c', 'site': 'YouTube', 'type': 'Behind the Scenes'},
          ],
        },
      });
      final meta = TmdMeta(movie: const TmdMovie(id: 1, title: 'T'), details: details);
      final restored =
          TmdMeta.fromJson(meta.toJson()).details!;
      expect(restored.extras, hasLength(1));
      expect(restored.extras.single.type, 'Behind the Scenes');
      expect(restored.extras.single.name, 'Video');
    });
  });

  group('details screen wiring (source-read)', () {
    // The details screen needs live metadata, so the folder-mode filtering is
    // pinned by source: extras must be pulled from BOTH the episodes and the
    // movies lists, or `Show.S01E01-deleted.mkv` would duplicate the episode's
    // row and the section would never fill.
    final screen =
        File('lib/screens/tmd_details_screen.dart').readAsStringSync();

    String section(String start, String end) {
      final s = screen.indexOf(start);
      if (s < 0) return '';
      final e = screen.indexOf(end, s);
      return e > s ? screen.substring(s, e) : screen.substring(s);
    }

    test('extras are excluded from both episode and movie classification', () {
      final filtering = section('final episodes = videos', 'final seasonGroups');
      expect(filtering, isNotEmpty);
      // Both where() clauses start by rejecting extras.
      expect(
          filtering
              .split('.where((e) =>')
              .where((c) => c.contains('isExtrasFileName(e.name)'))
              .length,
          greaterThanOrEqualTo(2));
      // The extras list is built from every video, not from movies only.
      expect(filtering, contains('final extras = videos'));
    });

    test('the extras section plays through the same path as other files', () {
      final sliver = section("'Extras'", 'const SliverToBoxAdapter(child: SizedBox(height: 24))');
      expect(sliver, contains('parseExtrasName(entry.name)'));
      expect(sliver, contains('_openFolderEntry(entry)'));
      expect(sliver, contains('parsed.label'));
    });

    test('the TMDB extras card renders the type as the subtitle', () {
      expect(screen, contains('details.extras.isNotEmpty'));
      expect(screen, contains('_ExtrasCard(extras: details.extras)'));
      final card = screen.substring(
          screen.indexOf('class _ExtrasCard'));
      expect(card, contains('subtitle: Text(extra.type)'));
      expect(card, contains('launchTmdVideo(context, extra)'));
    });
  });
}