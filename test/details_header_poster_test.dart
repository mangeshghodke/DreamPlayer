import 'package:dream_player/screens/tmd_details_screen.dart';
import 'package:dream_player/services/artwork_override.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The details header preferred the *season's* poster over the movie's, and
/// `withArtwork` only patches `movie` and `details` — never `seasons[]`. So a
/// poster picked from the ⋮ menu updated the home card and left the details
/// page showing the season's own artwork. An explicit pick has to win.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const seasonKey = 'folder:show-s02';
  const showKey = 'folder:show';
  const fileKey = 'smb:server1/Downloads/TV/Lanterns/S01E02.mkv';

  final meta = TmdMeta(
    movie: const TmdMovie(
      id: 7,
      title: 'Lanterns',
      kind: TmdKind.tv,
      posterPath: '/show-poster.jpg',
    ),
    seasons: {
      2: TmdSeason(
        seasonNumber: 2,
        name: 'Season 2',
        posterPath: '/season2-poster.jpg',
      ),
    },
  );

  String? poster({required int season, required bool overridden}) =>
      detailsHeaderPosterUrl(
        meta,
        effectiveSeason: season,
        posterOverridden: overridden,
      );

  group('detailsHeaderPosterUrl', () {
    test('uses the season poster when a season is resolved', () {
      expect(poster(season: 2, overridden: false),
          meta.seasons[2]!.posterUrl(width: 342));
    });

    test('an explicit pick beats the season poster', () {
      // The bug: the pick is in movie.posterPath but the header showed seasons[].
      expect(poster(season: 2, overridden: true),
          meta.movie.posterUrl(width: 342));
      expect(poster(season: 2, overridden: true),
          isNot(meta.seasons[2]!.posterUrl(width: 342)));
    });

    test('no season resolved means the series poster either way', () {
      expect(poster(season: 0, overridden: false),
          meta.movie.posterUrl(width: 342));
      expect(poster(season: 0, overridden: true),
          meta.movie.posterUrl(width: 342));
    });

    test('a season with no poster falls back to the series poster', () {
      final bare = TmdMeta(movie: meta.movie);
      expect(
        detailsHeaderPosterUrl(bare,
            effectiveSeason: 2, posterOverridden: false),
        bare.movie.posterUrl(width: 342),
      );
    });
  });

  group('isOverridden drives the decision', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      ArtworkOverrideStore.resetForTest();
    });

    Future<void> pick(String key) => ArtworkOverrideStore.set(
          key,
          ArtworkKind.poster,
          const MetaImage(url: '/chosen.jpg', provider: MetadataProvider.tmdb),
        );

    test('reports false for a key with no pick', () {
      expect(ArtworkOverrideStore.isOverridden(fileKey, ArtworkKind.poster),
          isFalse);
    });

    test('reports true once the key has a pick', () async {
      await pick(fileKey);
      expect(ArtworkOverrideStore.isOverridden(fileKey, ArtworkKind.poster),
          isTrue);
    });

    test('a show-level pick is what a season-level screen must honour', () async {
      await pick(showKey);
      // The chain is consulted by the caller, so the show key counts too.
      expect(ArtworkOverrideStore.isOverridden(showKey, ArtworkKind.poster),
          isTrue);
      expect(ArtworkOverrideStore.isOverridden(seasonKey, ArtworkKind.poster),
          isFalse);
    });
  });
}