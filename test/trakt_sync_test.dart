import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/tmdb_client.dart';
import 'package:dream_player/services/trakt_client.dart';
import 'package:dream_player/services/trakt_sync.dart';

TmdMeta _meta(int id, TmdKind kind, {String? providerId}) => TmdMeta(
      movie: TmdMovie(
        id: id,
        title: 'T',
        kind: kind,
        providerId: providerId,
        provider: providerId == null
            ? MetadataProvider.tmdb
            : MetadataProvider.external,
      ),
    );

void main() {
  group('TraktSync.matchKeys', () {
    test('movies match by exact TMDB id', () {
      final cache = {
        'file:///a.mkv': _meta(100, TmdKind.movie),
        'file:///b.mkv': _meta(200, TmdKind.movie),
        'file:///c.mkv': _meta(0, TmdKind.movie), // unresolved id
      };
      final keys = TraktSync.matchKeys(
        cache: cache,
        watched: const TraktWatched(movieIds: {100}),
      );
      expect(keys, {'file:///a.mkv'});
    });

    test('non-TMDB titles never match (external provider id)', () {
      final cache = {
        'smb_srv/X': _meta(700, TmdKind.movie, providerId: '604629'),
      };
      final keys = TraktSync.matchKeys(
        cache: cache,
        watched: const TraktWatched(movieIds: {700}),
      );
      expect(keys, isEmpty);
    });

    test('episodes within the watched season count are marked', () {
      final cache = {
        // House S02E04 — Trakt reports season 2 count = 5 → watched.
        'smb_srv/Media/House/House.S02E04.mkv': _meta(500, TmdKind.tv),
        // S02E07 beyond the count → not watched.
        'smb_srv/Media/House/House.S02E07.mkv': _meta(500, TmdKind.tv),
        // Different show id → not marked.
        'smb_srv/Media/Other/Other.S02E04.mkv': _meta(600, TmdKind.tv),
        // Whole-season folder key has no SxxEyy → skipped.
        'folder:abc': _meta(500, TmdKind.tv),
        // Non-episode TV entry → skipped.
        'smb_srv/Media/House/Season 2.folder': _meta(500, TmdKind.tv),
      };
      const watched = TraktWatched(showSeasons: {
        500: {2: 5},
      });
      final keys = TraktSync.matchKeys(cache: cache, watched: watched);

      expect(keys, {'smb_srv/Media/House/House.S02E04.mkv'});
    });

    test('windows backslash separators parse too', () {
      final cache = {
        'smb_srv\\Media\\House\\House.S02E04.mkv': _meta(500, TmdKind.tv),
      };
      const watched = TraktWatched(showSeasons: {
        500: {2: 5},
      });
      final keys = TraktSync.matchKeys(cache: cache, watched: watched);

      expect(keys, {'smb_srv\\Media\\House\\House.S02E04.mkv'});
    });

    test('trailing name dashes before SxxEyy do not confuse the parser', () {
      final cache = {
        'some-folder.S01E02.mkv': _meta(800, TmdKind.tv),
      };
      const watched = TraktWatched(showSeasons: {
        800: {1: 5},
      });
      final keys = TraktSync.matchKeys(cache: cache, watched: watched);

      expect(keys, {'some-folder.S01E02.mkv'});
    });
  });

  group('TraktWatched parsing', () {
    final moviesJson = [
      {'movie': {'ids': {'tmdb': 1}}},
      {'movie': {'ids': {'tmdb': 2}}},
      {'movie': {'ids': {}}}, // no tmdb id
      {'movie': {'ids': {'tmdb': 'not-int'}}},
    ];
    final showsJson = [
      {'show': {'ids': {'tmdb': 10}}, 'seasons': [
        {'number': 1, 'episodes': List.generate(4, (_) => {})},
        {'number': 3, 'episodes': List.generate(10, (_) => {})},
        {'number': 4}, // no episodes
      ]},
      {'show': {'ids': {}}}, // no tmdb id
      'garbage',
    ];

    test('movieIdsFromJson reads int tmdb ids only', () {
      final ids = TraktWatched.movieIdsFromJson(moviesJson);
      expect(ids, {1, 2});
    });

    test('showSeasonsFromJson counts per season', () {
      final seasons = TraktWatched.showSeasonsFromJson(showsJson);
      expect(seasons, {10: {1: 4, 3: 10}});
    });

    test('isEpisodeWatched uses counts as thresholds', () {
      final watched = TraktWatched(showSeasons: {
        10: {1: 4},
      });
      expect(watched.isEpisodeWatched(10, 1, 4), isTrue);
      expect(watched.isEpisodeWatched(10, 1, 5), isFalse); // beyond count
      expect(watched.isEpisodeWatched(10, 2, 1), isFalse); // unseen season
      expect(watched.isEpisodeWatched(99, 1, 1), isFalse); // unseen show
      expect(watched.isEpisodeWatched(10, 1, 0), isFalse); // bad episode
    });

    test('isEpisodeWatched without any seasons returns false', () {
      final watched = const TraktWatched(movieIds: {1});
      expect(watched.isEpisodeWatched(1, 1, 1), isFalse);
    });
  });

  group('traktHistoryBody', () {
    test('splits movies and shows into their own arrays', () {
      final body = traktHistoryBody([
        const TraktWatchItem(
          tmdbId: 1, isTv: false,
        ),
        const TraktWatchItem(
          tmdbId: 2,
          isTv: true,
          season: 3,
          episode: 5,
        ),
      ]);
      expect(body, {
        'movies': [
          {'ids': {'tmdb': 1}, 'watched_at': isNotNull}
        ],
        'shows': [
          {
            'ids': {'tmdb': 2},
            'seasons': [
              {
                'number': 3,
                'episodes': [
                  {'number': 5, 'watched_at': isNotNull},
                ],
              },
            ],
          },
        ],
      });
    });

    test('single-show item posts with watched_at filled', () {
      final body = traktHistoryBody([
        TraktWatchItem(tmdbId: 9, isTv: true, season: 1, episode: 1),
      ]);
      expect(body['shows'], hasLength(1));
      final ep = (body['shows'][0] as Map)['seasons'][0]['episodes'][0];
      expect(ep['number'], 1);
      expect(ep['watched_at'], isNotNull);
    });
  });
}
