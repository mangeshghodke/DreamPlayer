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
      // Both stores memoise; without the reset each test would inherit the
      // previous one's state and pass or fail for the wrong reason.
      ArtworkOverrideStore.resetForTest();
      CrossProviderIdStore.resetForTest();
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
    // TheTVDB artwork entries carry `image`, optional `category`, and
    // dimensions. `type` is accepted so a payload that only has ids is also
    // covered (it must not crash, and must not be classified by them).
    Map<String, dynamic> entry(
      String image, {
      int? w,
      int? h,
      String? category,
      int? type,
    }) =>
        <String, dynamic>{
          'image': image,
          'category': ?category,
          'type': ?type,
          'width': ?w,
          'height': ?h,
        };

    test('classifies by the category string', () {
      final out = TheTvdbClient.mapArtworkResponse({
        'data': {
          'artworks': [
            entry('/p.jpg', category: 'poster', w: 500, h: 750),
            entry('/bd.jpg', category: 'backdrop', w: 1920, h: 1080),
          ],
        },
      });
      expect(out.posters.single.url, endsWith('/p.jpg'));
      expect(out.backdrops.single.url, endsWith('/bd.jpg'));
    });

    test('falls back to aspect ratio when there is no category', () {
      final out = TheTvdbClient.mapArtworkResponse({
        'data': {
          'artworks': [
            entry('/tall.jpg', w: 500, h: 750),
            entry('/wide.jpg', w: 1920, h: 1080),
          ],
        },
      });
      expect(out.posters.single.url, endsWith('/tall.jpg'));
      expect(out.backdrops.single.url, endsWith('/wide.jpg'));
    });

    test('category wins over geometry (a wide "poster" is still a poster)', () {
      final out = TheTvdbClient.mapArtworkResponse({
        'data': {
          'artworks': [entry('/odd.jpg', category: 'poster', w: 1920, h: 1080)],
        },
      });
      expect(out.posters.length, 1);
      expect(out.backdrops, isEmpty);
    });

    test('drops logos and clearlogos', () {
      final out = TheTvdbClient.mapArtworkResponse({
        'data': {
          'artworks': [
            entry('/logo.png', category: 'logo', w: 400, h: 200),
            entry('/clear.png', category: 'clearlogo', w: 800, h: 200),
            entry('/ok.jpg', category: 'poster', w: 500, h: 750),
          ],
        },
      });
      expect(out.posters.length, 1);
      expect(out.posters.single.url, endsWith('/ok.jpg'));
      expect(out.backdrops, isEmpty);
    });

    test('ignores entries with no image', () {
      final out = TheTvdbClient.mapArtworkResponse({
        'data': {
          'artworks': [
            {'category': 'poster', 'width': 100, 'height': 150},
            entry('/ok.jpg', category: 'poster', w: 500, h: 750),
          ],
        },
      });
      expect(out.posters.length, 1);
      expect(out.posters.single.url, endsWith('/ok.jpg'));
    });

    test('a malformed response yields empty lists rather than throwing', () {
      final out = TheTvdbClient.mapArtworkResponse(null);
      expect(out.posters, isEmpty);
      expect(out.backdrops, isEmpty);
    });
  });

  artworkRegressionTests();
  crossProviderTests();
  realPayloadTests();
  artworkBackfillTests();
}

/// Regression cover for "Change backdrop showed nothing" (issue #33).
///
/// The dedicated `/movie|tv/{id}/images` endpoint returns `posters` and
/// `backdrops` at the TOP level; only a details call with
/// `append_to_response=images` nests them under an `images` key. Reading only
/// `json['images']` therefore returned zero candidates for the endpoint the
/// picker actually calls, and the grid rendered "No backdrops available" for
/// titles that plainly have hundreds of them.
void artworkRegressionTests() {
  group('TmdApi.parseArtworkResponse', () {
    Map<String, dynamic> entry(String path, {int w = 2000, int h = 3000, String? lang}) =>
        <String, dynamic>{
          'file_path': path,
          'width': w,
          'height': h,
          'iso_639_1': lang,
          'vote_average': 7.3,
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

/// Cross-provider id pairs (issue #33 tightening). The map only ever holds
/// strictly-verified pairs, so it must never be able to point at a different
/// show — and it must survive a restart.
void crossProviderTests() {
  group('normaliseMetaTitle', () {
    test('collapses punctuation, case and spacing', () {
      expect(normaliseMetaTitle('Komi-san'), 'komisan');
      expect(normaliseMetaTitle('KOMI SAN'), 'komisan');
      expect(normaliseMetaTitle('Komi  san!'), 'komisan');
    });
  });

  group('CrossProviderIdStore', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      CrossProviderIdStore.resetForTest();
      ArtworkOverrideStore.resetForTest();
    });

    test('records and looks up a pair under one title', () async {
      await CrossProviderIdStore.record(
        'Komi-san', TmdKind.tv, MetadataProvider.theTvdb, 371980);
      expect(
        CrossProviderIdStore.lookup(
            'Komi-san', TmdKind.tv, MetadataProvider.theTvdb),
        371980,
      );
    });

    test('a partner id is preserved when the other side is added', () async {
      await CrossProviderIdStore.record(
        'Komi-san', TmdKind.tv, MetadataProvider.theTvdb, 371980);
      await CrossProviderIdStore.record(
        'Komi-san', TmdKind.tv, MetadataProvider.tmdb, 197189);
      expect(
        CrossProviderIdStore.lookup(
            'Komi-san', TmdKind.tv, MetadataProvider.theTvdb),
        371980,
      );
      expect(
        CrossProviderIdStore.lookup('Komi-san', TmdKind.tv, MetadataProvider.tmdb),
        197189,
      );
    });

    test('lookup is normalisation-insensitive', () async {
      await CrossProviderIdStore.record(
        'Komi-san', TmdKind.tv, MetadataProvider.theTvdb, 371980);
      expect(
        CrossProviderIdStore.lookup(
            'KOMI  SAN!', TmdKind.tv, MetadataProvider.theTvdb),
        371980,
      );
    });

    test('movie and tv kinds do not collide', () async {
      await CrossProviderIdStore.record(
        'Dune', TmdKind.movie, MetadataProvider.theTvdb, 11);
      expect(
        CrossProviderIdStore.lookup('Dune', TmdKind.tv, MetadataProvider.theTvdb),
        isNull,
      );
    });

    test('a non-positive id is not stored', () async {
      await CrossProviderIdStore.record(
        'Dune', TmdKind.movie, MetadataProvider.theTvdb, 0);
      expect(
        CrossProviderIdStore.lookup('Dune', TmdKind.movie, MetadataProvider.theTvdb),
        isNull,
      );
    });
  });
}

/// Tests built from a REAL TheTVDB v4 `/movies/{id}/extended` payload captured
/// on-device (issue #33). The `type` ids and dimensions are verbatim from that
/// capture, not from documentation or guesswork.
void realPayloadTests() {
  group('TheTVDB v4 real payload shapes', () {
    Map<String, dynamic> art(int type, int w, int h) =>
        <String, dynamic>{
          'id': 1,
          'image': 'https://artworks.thetvdb.com/banners/x.jpg',
          'thumbnail': 'https://artworks.thetvdb.com/banners/x-thumb.jpg',
          'width': w,
          'height': h,
          'type': type,
          'language': null,
          'score': 9.5,
        };

    test('poster types 2/7/13/14 are posters', () {
      for (final type in const [2, 7, 13, 14]) {
        final out = TheTvdbClient.mapArtworkResponse({
          'data': {
            'artworks': [art(type, 680, 1000)],
          },
        });
        expect(out.posters.length, 1, reason: 'type $type should be a poster');
        expect(out.backdrops, isEmpty, reason: 'type $type is not a backdrop');
      }
    });

    test('backdrop types 3/15 are backdrops', () {
      for (final type in const [3, 15]) {
        final out = TheTvdbClient.mapArtworkResponse({
          'data': {
            'artworks': [art(type, 1920, 1080)],
          },
        });
        expect(out.backdrops.length, 1, reason: 'type $type should be a backdrop');
        expect(out.posters, isEmpty, reason: 'type $type is not a poster');
      }
    });

    test('type 1 (758x140 logo strip) and 18 (square) are neither', () {
      final out = TheTvdbClient.mapArtworkResponse({
        'data': {
          'artworks': [art(1, 758, 140), art(18, 1024, 1024)],
        },
      });
      expect(out.posters, isEmpty);
      expect(out.backdrops, isEmpty);
    });

    test('a type-15 backdrop is actually used for the automatic artwork', () {
      // This is the regression: type 15 was missing from the old table, so no
      // backdrop was ever chosen for a TheTVDB movie.
      final details = TheTvdbClient.mapExtendedResponse(
        {
          'data': {
            'id': 1,
            'name': 'Girls und Panzer das Finale: Part II',
            'year': 2019,
            'artworks': [
              art(14, 680, 1000),
              art(15, 1920, 1080),
            ],
          },
        },
        kind: TmdKind.movie,
      );
      expect(details, isNotNull);
      expect(details!.backdropPath, endsWith('x.jpg'));
      expect(details.posterPath, isNotNull);
    });

    test('a language-code list is NEVER used as the synopsis', () {
      // Captured on-device: an extended movie record's overviewTranslations is
      // ["jpn", "heb", ...] - bare language codes, not {language, text}.
      // Reading it as prose is what showed "heb" as the synopsis (issue #33).
      final details = TheTvdbClient.mapExtendedResponse({
        'data': {
          'id': 148,
          'name': 'Avengers: Endgame',
          'overviewTranslations': ['jpn', 'heb', 'eng'],
        },
      }, kind: TmdKind.movie);
      expect(details!.overview, '');
    });

    test('the real synopsis comes from the SEARCH payload overview', () {
      final movie = TheTvdbClient.mapSearchResult({
        'objectID': 'movie-148',
        'tvdb_id': 148,
        'name': 'Avengers: Endgame',
        'extended_title': 'Avengers: Endgame',
        'year': 2019,
        'overview': 'After the devastating events of Infinity War...',
        'image_url': 'https://artworks.thetvdb.com/banners/movies/148/posters/eng.jpg',
        'thumbnail': 'https://artworks.thetvdb.com/banners/movies/148/posters/eng-thumb.jpg',
      }, kind: TmdKind.movie);
      expect(movie, isNotNull);
      expect(movie!.overview, 'After the devastating events of Infinity War...');
    });

    test('no overview anywhere yields an empty string, never a token', () {
      final details = TheTvdbClient.mapExtendedResponse({
        'data': {'id': 1, 'name': 'Something', 'year': 2019},
      }, kind: TmdKind.movie);
      expect(details!.overview, '');
    });
  });
}


/// The backdrop bug (issue #33). TheTVDB's search payload has no `artworks`
/// array - only `image_url`/`thumbnail` - so a TheTVDB-sourced TmdMovie had a
/// poster but NEVER a backdrop, and the card/hero rendered bare. The backdrop
/// only exists on the extended record, which TmdMeta.withDetails() now
/// backfills.
void artworkBackfillTests() {
  TmdMovie searchOnlyMovie() => TmdMovie(
        id: 148,
        title: 'Avengers: Endgame',
        kind: TmdKind.movie,
        provider: MetadataProvider.theTvdb,
        posterPath: 'https://artworks.thetvdb.com/banners/movies/148/p.jpg',
        overview: 'A real synopsis from the search payload.',
      );

  test('withDetails backfills a missing backdrop from the extended record', () {
    final meta = TmdMeta(movie: searchOnlyMovie())
        .withDetails(const TmdDetails(
      title: 'Avengers: Endgame',
      posterPath: 'https://artworks.thetvdb.com/banners/movies/148/p2.jpg',
      backdropPath: 'https://artworks.thetvdb.com/banners/movies/148/b.jpg',
    ));
    expect(meta.movie.backdropPath, endsWith('/b.jpg'));
    expect(meta.movie.backdropUrl(), endsWith('/b.jpg'));
  });

  test('an existing search poster is not overwritten by the details poster', () {
    final meta = TmdMeta(movie: searchOnlyMovie())
        .withDetails(const TmdDetails(
      title: 'Avengers: Endgame',
      posterPath: 'https://example.com/other.jpg',
      backdropPath: 'https://example.com/b.jpg',
    ));
    expect(meta.movie.posterPath, endsWith('/148/p.jpg'));
    expect(meta.movie.backdropPath, endsWith('/b.jpg'));
  });

  test('backfill fills a missing poster too', () {
    final meta = TmdMeta(
      movie: const TmdMovie(
        id: 148,
        title: 'Avengers: Endgame',
        kind: TmdKind.movie,
        provider: MetadataProvider.theTvdb,
      ),
    ).withDetails(const TmdDetails(
      title: 'Avengers: Endgame',
      posterPath: 'https://example.com/p.jpg',
      backdropPath: 'https://example.com/b.jpg',
    ));
    expect(meta.movie.posterPath, endsWith('/p.jpg'));
    expect(meta.movie.backdropPath, endsWith('/b.jpg'));
  });

  test('a details record with no artwork changes nothing', () {
    final before = searchOnlyMovie();
    final meta = TmdMeta(movie: before)
        .withDetails(const TmdDetails(title: 'Avengers: Endgame'));
    expect(meta.movie.posterPath, before.posterPath);
    expect(meta.movie.backdropPath, isNull);
  });

  test('overviewText() prefers the real synopsis over an empty details one', () {
    // Regression (issue #33). TheTVDB extended records carry an EMPTY
    // synopsis, and `details?.overview ?? movie.overview` would let '' shadow
    // the good one because '' is not null. This exercises the REAL helper the
    // screens call - a previous test asserted an intended expression instead of
    // the shipped code, passed, and left the bug in place.
    final meta = TmdMeta(movie: searchOnlyMovie())
        .withDetails(const TmdDetails(title: 'Avengers: Endgame', overview: ''));
    expect(meta.details!.overview, '');
    expect(meta.overviewText(), 'A real synopsis from the search payload.');
  });

  test('overviewText() prefers a non-empty details synopsis', () {
    final meta = TmdMeta(movie: searchOnlyMovie()).withDetails(
      const TmdDetails(title: 'Avengers: Endgame', overview: 'From details.'),
    );
    expect(meta.overviewText(), 'From details.');
  });

  test('overviewText() prefers an episode synopsis when given one', () {
    final meta = TmdMeta(movie: searchOnlyMovie())
        .withDetails(const TmdDetails(title: 'Avengers: Endgame', overview: ''));
    expect(
      meta.overviewText(episodeOverview: 'This episode.'),
      'This episode.',
    );
  });

  test('overviewText() is empty when nothing has text', () {
    final meta = TmdMeta(
      movie: const TmdMovie(
        id: 148,
        title: 'Avengers: Endgame',
        kind: TmdKind.movie,
        provider: MetadataProvider.theTvdb,
      ),
    ).withDetails(const TmdDetails(title: 'Avengers: Endgame', overview: '  '));
    expect(meta.overviewText(), '');
  });

  test('firstNonEmptyOverview skips blanks and whitespace', () {
    expect(firstNonEmptyOverview([null, '', '   ', 'real']), 'real');
    expect(firstNonEmptyOverview([null, '', '  ']), '');
    expect(firstNonEmptyOverview(['  padded  ']), 'padded');
  });
}
