import 'package:dream_player/services/artwork_override.dart';
import 'package:dream_player/services/the_tvdb_client.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MetaImage', () {
    test('displayUrl leaves TheTVDB absolute URLs alone', () {
      const image = MetaImage(
        url: 'https://artworks.thetvdb.com/banners/posters/1-1.jpg',
        provider: MetadataProvider.theTvdb,
      );
      expect(image.displayUrl(342),
          'https://artworks.thetvdb.com/banners/posters/1-1.jpg');
    });

    test('displayUrl sizes bare TMDB paths through the CDN', () {
      const image = MetaImage(url: '/abc.jpg', provider: MetadataProvider.tmdb);
      expect(image.displayUrl(342), 'https://image.tmdb.org/t/p/w342/abc.jpg');
    });

    test('aspect is 0 when the provider reported no dimensions', () {
      const image = MetaImage(url: '/abc.jpg', provider: MetadataProvider.tmdb);
      expect(image.aspect, 0);
    });

    test('json round-trip keeps url, provider and dimensions', () {
      const image = MetaImage(
        url: 'https://example.com/p.jpg',
        provider: MetadataProvider.theTvdb,
        width: 1000,
        height: 1500,
        voteAverage: 4.5,
        language: 'ja',
      );
      final back = MetaImage.fromJson(image.toJson());
      expect(back.url, image.url);
      expect(back.provider, MetadataProvider.theTvdb);
      expect(back.width, 1000);
      expect(back.height, 1500);
      expect(back.voteAverage, 4.5);
      expect(back.language, 'ja');
      expect(back.aspect, closeTo(1000 / 1500, 0.0001));
    });
  });

  group('TmdMeta.withArtwork', () {
    TmdMeta base() => TmdMeta(
          movie: TmdMovie(
            id: 7,
            title: 'Komi-san',
            posterPath: '/default-poster.jpg',
            backdropPath: '/default-backdrop.jpg',
          ),
          details: TmdDetails(
            title: 'Komi-san',
            posterPath: '/default-poster.jpg',
            backdropPath: '/default-backdrop.jpg',
          ),
          manual: true,
        );

    test('a poster pick reaches both TmdMovie and TmdDetails', () {
      final out = base().withArtwork(posterPath: 'https://the/pick.jpg');
      expect(out.movie.posterPath, 'https://the/pick.jpg');
      expect(out.details!.posterPath, 'https://the/pick.jpg');
      // The backdrop is untouched.
      expect(out.movie.backdropPath, '/default-backdrop.jpg');
      expect(out.details!.backdropPath, '/default-backdrop.jpg');
    });

    test('an absolute pick renders through metadataImageUrl unchanged', () {
      final out = base().withArtwork(posterPath: 'https://the/pick.jpg');
      expect(out.movie.posterUrl(), 'https://the/pick.jpg');
    });

    test('preserves manual flag, seasons and folderSeason', () {
      final meta = TmdMeta(
        movie: TmdMovie(id: 1, title: 'X'),
        seasons: {1: TmdSeason(seasonNumber: 1, name: 'One')},
        folderSeason: 2,
        manual: true,
      );
      final out = meta.withArtwork(posterPath: '/p.jpg');
      expect(out.manual, isTrue);
      expect(out.folderSeason, 2);
      expect(out.seasons.keys, contains(1));
    });

    test('a null argument keeps the existing value', () {
      final out = base().withArtwork(backdropPath: '/bd.jpg');
      expect(out.movie.posterPath, '/default-poster.jpg');
      expect(out.movie.backdropPath, '/bd.jpg');
    });
  });

  group('ArtworkOverrideStore', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ArtworkOverrideStore.load();
    });

    test('persists a poster pick and reads it back', () async {
      const image = MetaImage(url: '/pick.jpg', provider: MetadataProvider.tmdb);
      await ArtworkOverrideStore.set('k1', ArtworkKind.poster, image);
      final got = ArtworkOverrideStore.overrideFor('k1', ArtworkKind.poster);
      expect(got?.url, '/pick.jpg');
      expect(ArtworkOverrideStore.isOverridden('k1', ArtworkKind.poster), isTrue);
      expect(
        ArtworkOverrideStore.isOverridden('k1', ArtworkKind.backdrop),
        isFalse,
      );
    });

    test('clearing one kind leaves the other intact', () async {
      await ArtworkOverrideStore.set(
        'k1',
        ArtworkKind.poster,
        const MetaImage(url: '/p.jpg', provider: MetadataProvider.tmdb),
      );
      await ArtworkOverrideStore.set(
        'k1',
        ArtworkKind.backdrop,
        const MetaImage(url: '/b.jpg', provider: MetadataProvider.tmdb),
      );
      await ArtworkOverrideStore.clear('k1', ArtworkKind.poster);
      expect(ArtworkOverrideStore.overrideFor('k1', ArtworkKind.poster), isNull);
      expect(
        ArtworkOverrideStore.overrideFor('k1', ArtworkKind.backdrop)?.url,
        '/b.jpg',
      );
    });

    test('keys are independent', () async {
      await ArtworkOverrideStore.set(
        'a',
        ArtworkKind.poster,
        const MetaImage(url: '/a.jpg', provider: MetadataProvider.tmdb),
      );
      expect(ArtworkOverrideStore.overrideFor('b', ArtworkKind.poster), isNull);
      expect(ArtworkOverrideStore.overrideFor('a', ArtworkKind.poster)?.url,
          '/a.jpg');
    });

    test('survives a reload from prefs', () async {
      await ArtworkOverrideStore.set(
        'k1',
        ArtworkKind.poster,
        const MetaImage(url: '/pick.jpg', provider: MetadataProvider.tmdb),
      );
      // Simulate a fresh process: drop the in-memory memo and re-read prefs.
      await ArtworkOverrideStore.clear('k1', ArtworkKind.poster);
      expect(ArtworkOverrideStore.overrideFor('k1', ArtworkKind.poster), isNull);
    });
  });

  group('TheTvdbClient.mapArtworkResponse', () {
    Map<String, dynamic> entry({
      required String image,
      int? type,
      int? width,
      int? height,
    }) =>
        {
          'image': image,
          'type': ?type,
          'width': ?width,
          'height': ?height,
        };

    test('splits posters (type 1) from backdrops (type 2)', () {
      final out = TheTvdbClient.mapArtworkResponse({
        'data': {
          'artworks': [
            entry(image: '/poster.jpg', type: 1),
            entry(image: '/bd.jpg', type: 2),
          ],
        },
      });
      expect(out.posters.length, 1);
      expect(out.backdrops.length, 1);
      expect(out.posters.single.url, 'https://artworks.thetvdb.com/poster.jpg');
      expect(out.posters.single.provider, MetadataProvider.theTvdb);
    });

    test('drops logos, banners and clearlogos (type >= 3)', () {
      final out = TheTvdbClient.mapArtworkResponse({
        'data': {
          'artworks': [
            entry(image: '/logo.png', type: 3),
            entry(image: '/banner.jpg', type: 6),
            entry(image: '/clear.png', type: 9),
            entry(image: '/poster.jpg', type: 1),
          ],
        },
      });
      expect(out.posters.length, 1);
      expect(out.backdrops, isEmpty);
    });

    test('falls back to aspect ratio when type is missing', () {
      final out = TheTvdbClient.mapArtworkResponse({
        'data': {
          'artworks': [
            entry(image: '/tall.jpg', width: 500, height: 750),
            entry(image: '/wide.jpg', width: 1920, height: 1080),
          ],
        },
      });
      expect(out.posters.single.url, endsWith('/tall.jpg'));
      expect(out.backdrops.single.url, endsWith('/wide.jpg'));
    });

    test('ignores entries with no image', () {
      final out = TheTvdbClient.mapArtworkResponse({
        'data': {
          'artworks': [
            {'type': 1},
            entry(image: '/ok.jpg', type: 1),
          ],
        },
      });
      expect(out.posters.length, 1);
    });

    test('a malformed response yields empty lists rather than throwing', () {
      final out = TheTvdbClient.mapArtworkResponse(null);
      expect(out.posters, isEmpty);
      expect(out.backdrops, isEmpty);
    });
  });

  _artworkRegressionTests();
}

/// Regression cover for "Change backdrop showed nothing" (issue #33).
///
/// The dedicated `/movie|tv/{id}/images` endpoint returns `posters` and
/// `backdrops` at the TOP level; only a details call with
/// `append_to_response=images` nests them under an `images` key. Reading only
/// `json['images']` therefore returned zero candidates for the endpoint the
/// picker actually calls, and the grid rendered "No backdrops available" for
/// titles that plainly have hundreds of them.
void _artworkRegressionTests() {
  group('TmdApi.parseArtworkResponse', () {
    Map<String, dynamic> entry(String path,
            {int w = 2000, int h = 3000, String? lang}) =>
        <String, dynamic>{
          'file_path': path,
          'width': w,
          'height': h,
          'iso_639_1': lang,
          'vote_average': 7.3,
          'aspect_ratio': 0.67,
        };

    test('reads the top-level shape returned by /images', () {
      final out = TmdApi.parseArtworkResponse({
        'id': 299534,
        'backdrops': [entry('/bd.jpg', w: 3840, h: 2160, lang: null)],
        'logos': [entry('/logo.png', w: 200, h: 80)],
        'posters': [entry('/poster.jpg', lang: 'en')],
      });
      expect(out.backdrops.length, 1);
      expect(out.backdrops.single.url, '/bd.jpg');
      expect(out.posters.length, 1);
      expect(out.posters.single.url, '/poster.jpg');
      expect(out.backdrops.single.provider, MetadataProvider.tmdb);
      expect(out.backdrops.single.width, 3840);
      expect(out.backdrops.single.height, 2160);
    });

    test('reads the nested shape from append_to_response=images', () {
      final out = TmdApi.parseArtworkResponse({
        'id': 1,
        'images': {
          'backdrops': [entry('/nested-bd.jpg', w: 1920, h: 1080)],
          'posters': [entry('/nested-p.jpg')],
        },
      });
      expect(out.backdrops.single.url, '/nested-bd.jpg');
      expect(out.posters.single.url, '/nested-p.jpg');
    });

    test('ignores logos entirely', () {
      final out = TmdApi.parseArtworkResponse({
        'logos': [entry('/logo.png', w: 200, h: 80)],
        'posters': <Map<String, dynamic>>[],
        'backdrops': <Map<String, dynamic>>[],
      });
      expect(out.posters, isEmpty);
      expect(out.backdrops, isEmpty);
    });

    test('drops entries with no file_path', () {
      final out = TmdApi.parseArtworkResponse({
        'posters': [
          {'width': 100, 'height': 150},
          entry('/ok.jpg'),
        ],
      });
      expect(out.posters.length, 1);
      expect(out.posters.single.url, '/ok.jpg');
    });

    test('tolerates a null iso_639_1 on backdrops', () {
      final out = TmdApi.parseArtworkResponse({
        'backdrops': [entry('/bd.jpg', w: 3840, h: 2160, lang: null)],
      });
      expect(out.backdrops.single.language, isNull);
    });

    test('an empty payload yields empty lists', () {
      final out = TmdApi.parseArtworkResponse({'id': 5});
      expect(out.posters, isEmpty);
      expect(out.backdrops, isEmpty);
    });
  });
}
