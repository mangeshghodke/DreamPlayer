import 'dart:convert';

import 'package:dream_player/services/metadata_provider_adapter.dart';
import 'package:dream_player/services/r18dev_adapter.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// r18.dev adapter for issue #52.
///
/// The fixtures are TRIMMED from live responses captured 2026-10-25 against
/// `https://r18.dev`:
///
/// * `GET /videos/vod/movies/detail/-/dvd_id=SVFLA-012/json` - the CODE
///   lookup. A small record: `content_id`, `title`, `release_date`,
///   `runtime_minutes`, `images.jacket_image.large2`, `actresses`,
///   `categories`, `maker`.
/// * `GET /videos/vod/movies/detail/-/combined=1svfla012/json` - the FULL
///   record: `jacket_full_url`, `gallery`, `actresses`/`directors` with
///   names, `categories` with English + Japanese names, `maker_name_ja`,
///   `release_date`, `runtime_mins`, `title_en`/`title_ja`.
///
/// Two facts drive the design and are pinned here: the catalogue is keyed by
/// CODE (there is no free-text search), and `content_id` is a STRING while
/// `TmdMovie.id` is an integer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  const lookupEnvelope = '''
  {
    "content_id": "1svfla012",
    "title": "Isn't My Ass Delicious? The Girl Who Straddles And Face-rides A Cunnilingus",
    "release_date": "2025-11-20",
    "runtime_minutes": 248,
    "dvd_id": "SVFLA-012",
    "images": {
      "jacket_image": {
        "large": " ",
        "large2": "https://pics.dmm.co.jp/mono/movie/adult/1svfla012/1svfla012ps.jpg"
      }
    },
    "actresses": [{"name": "Aizawamiyu"}],
    "categories": [{"name": "Cunnilingus"}, {"name": "Academy Uniform"}],
    "maker": {"name": "FLAVORY"}
  }
  ''';

  const combinedEnvelope = '''
  {
    "content_id": "1svfla012",
    "dvd_id": "SVFLA-012",
    "title_en": "Isn't My Ass Delicious? The Girl Who Straddles",
    "title_ja": "「わたしのアナル美味しいでしょ？」",
    "release_date": "2025-11-20",
    "runtime_mins": 248,
    "jacket_full_url": "https://pics.dmm.co.jp/mono/movie/adult/1svfla012/1svfla012ps.jpg",
    "jacket_thumb_url": "https://pics.dmm.co.jp/mono/movie/adult/1svfla012/1svfla012pl.jpg",
    "label_name_en": null,
    "label_name_ja": "FLAVORY（フレーバリー）",
    "maker_name_en": null,
    "maker_name_ja": "FLAVORY（フレーバリー）",
    "actresses": [
      {"id": 1088602, "name_kana": "あいざわみゆ", "name_kanji": "逢沢みゆ", "name_romaji": "Aizawamiyu"}
    ],
    "actors": [],
    "directors": [
      {"id": 118512, "name_kana": "もとふじぺろ", "name_kanji": "元藤ペロ", "name_romaji": "Pero Motofuji"}
    ],
    "categories": [
      {"id": 38, "name_en": "Cunnilingus", "name_ja": "クンニ"},
      {"id": 1018, "name_en": "Academy Uniform", "name_ja": "女子校生"}
    ],
    "gallery": [
      {"image_full": "https://pics.dmm.co.jp/digital/video/1svfla012/1svfla012-1.jpg"}
    ],
    "comment_en": null
  }
  ''';

  Future<R18DevAdapter> enabled({
    Map<String, dynamic>? lookup,
    Map<String, dynamic>? combined,
    List<Uri>? log,
  }) async {
    final seen = log ?? <Uri>[];
    final adapter = R18DevAdapter(
      transport: (uri) async {
        seen.add(uri);
        if (uri.path.contains('/combined=')) {
          return combined ?? _decode(combinedEnvelope);
        }
        return lookup ?? _decode(lookupEnvelope);
      },
    );
    await adapter.setEnabled(true);
    return adapter;
  }

  group('code recognition', () {
    test('a hyphenated catalogue code is accepted', () {
      expect(R18DevAdapter.codeFromQuery('SVFLA-012'), 'SVFLA-012');
    });

    test('the separator-less spelling resolves to the same code', () {
      // The live service answers both `SVFLA-012` and `SVFLA012`.
      expect(R18DevAdapter.codeFromQuery('SVFLA012'), 'SVFLA-012');
    });

    test('a code typed with a space resolves to the same code', () {
      // The site strips spaces from the code before looking it up.
      expect(R18DevAdapter.codeFromQuery('SVFLA 012'), 'SVFLA-012');
    });

    test('a title is not a code', () {
      expect(R18DevAdapter.codeFromQuery('Some Movie'), isNull);
    });

    test('a bare number is not a code', () {
      expect(R18DevAdapter.codeFromQuery('12345'), isNull);
    });

    test('an empty query is not a code', () {
      expect(R18DevAdapter.codeFromQuery('   '), isNull);
    });

    test('the code is taken from the front of a file name', () {
      expect(
        R18DevAdapter.codeFromTitle('SVFLA-012 Some Long Title 1080p'),
        'SVFLA-012',
      );
    });

    test('a file name with no code yields nothing', () {
      expect(R18DevAdapter.codeFromTitle('Holiday 2024.mkv'), isNull);
    });
  });

  group('stable ids', () {
    test('the same id always produces the same integer', () {
      expect(
        R18DevAdapter.stableId('1svfla012'),
        R18DevAdapter.stableId('1svfla012'),
      );
    });

    test('different ids produce different integers', () {
      expect(
        R18DevAdapter.stableId('1svfla012'),
        isNot(R18DevAdapter.stableId('1abc123')),
      );
    });

    test('the integer is positive, because id <= 0 is dropped', () {
      expect(R18DevAdapter.stableId('1svfla012'), greaterThan(0));
    });
  });

  group('search', () {
    test('a catalogue code finds the record', () async {
      final adapter = await enabled();
      final results = await adapter.search('SVFLA-012');
      expect(results, hasLength(1));
      final movie = results.single;
      expect(movie.provider, MetadataProvider.external);
      expect(movie.providerId, '1svfla012');
      expect(movie.year, 2025);
      expect(
        movie.posterPath,
        'https://pics.dmm.co.jp/mono/movie/adult/1svfla012/1svfla012ps.jpg',
      );
    });

    test('the code is looked up with the dvd_id endpoint', () async {
      final log = <Uri>[];
      final adapter = await enabled(log: log);
      await adapter.search('SVFLA-012');
      expect(log.single.path, contains('dvd_id=SVFLA-012'));
    });

    test('a title finds nothing - there is no free-text search', () async {
      final adapter = await enabled();
      expect(await adapter.search('Some Movie'), isEmpty);
    });

    test('TV is refused - it is a movie catalogue', () async {
      final adapter = await enabled();
      expect(await adapter.search('SVFLA-012', kind: TmdKind.tv), isEmpty);
    });

    test('a record with no content_id is not a match', () async {
      final adapter = await enabled(lookup: {'content_id': '', 'title': 'x'});
      expect(await adapter.search('SVFLA-012'), isEmpty);
    });

    test('a disabled provider is not queried', () async {
      final log = <Uri>[];
      final adapter = R18DevAdapter(
        transport: (uri) async {
          log.add(uri);
          return _decode(lookupEnvelope);
        },
      );
      await adapter.setEnabled(false);
      expect(await adapter.search('SVFLA-012'), isEmpty);
      expect(log, isEmpty);
    });
  });

  group('details', () {
    test('the full record carries the studio, cast and genres', () async {
      final adapter = await enabled();
      final movie = (await adapter.search('SVFLA-012')).single;
      final details = await adapter.details(movie);
      expect(details, isNotNull);
      expect(details!.genres, contains('Cunnilingus'));
      expect(details.cast.map((c) => c.name), contains('Aizawamiyu'));
      expect(details.tagline, contains('FLAVORY'));
      expect(details.runtimeMinutes, 248);
      expect(details.year, 2025);
      expect(
        details.posterPath,
        'https://pics.dmm.co.jp/mono/movie/adult/1svfla012/1svfla012ps.jpg',
      );
    });

    test('the studio is used when there is no English maker name', () async {
      final adapter = await enabled();
      final movie = (await adapter.search('SVFLA-012')).single;
      final details = await adapter.details(movie);
      // The live record has maker_name_en = null and maker_name_ja set.
      expect(details!.tagline, contains('FLAVORY'));
    });

    test('the sample-video marker is not listed as a genre', () async {
      final adapter = await enabled(
        combined: {
          'content_id': '1svfla012',
          'title_en': 'Title',
          'categories': [
            {'name_en': 'Cunnilingus'},
            {'name_en': 'Sample Video'},
          ],
        },
      );
      final movie = (await adapter.search('SVFLA-012')).single;
      final details = await adapter.details(movie);
      expect(details!.genres, ['Cunnilingus']);
    });

    test('the sample-video frames become the stills gallery', () async {
      final adapter = await enabled();
      final movie = (await adapter.search('SVFLA-012')).single;
      final details = await adapter.details(movie);
      expect(details!.stills, hasLength(1));
      expect(details.stills.first, contains('1svfla012-1.jpg'));
    });

    test('a movie from another provider is refused', () async {
      final adapter = await enabled();
      expect(
        await adapter.details(
          TmdMovie(id: 1, title: 'x', provider: MetadataProvider.tmdb),
        ),
        isNull,
      );
    });
  });

  group('bestMatch', () {
    test('a file named after its code matches exactly', () async {
      final adapter = await enabled();
      final match = await adapter.bestMatch(
        const ParsedFileName(title: 'SVFLA-012'),
      );
      expect(match, isNotNull);
      expect(match!.score, 1.0);
      expect(match.movie.providerId, '1svfla012');
    });

    test('a code inside a longer file name still matches', () async {
      final adapter = await enabled();
      final match = await adapter.bestMatch(
        ParsedFileName(title: 'SVFLA-012 Some Title'),
      );
      expect(match, isNotNull);
      expect(match!.score, 1.0);
    });

    test('a file with no code matches nothing', () async {
      final adapter = await enabled();
      final match = await adapter.bestMatch(
        ParsedFileName(title: 'Holiday 2024'),
      );
      expect(match, isNull);
    });

    test('the code is read from the RAW name, not the parsed title', () async {
      // The filename parser strips the trailing number as a movie-part
      // suffix, so the parsed title of `SVFLA-012.mkv` is just "SVFLA"
      // (issue #52). The adapter has to use the original name.
      final adapter = await enabled();
      final parsed = ParsedFileName.parse('SVFLA-012.mkv');
      expect(parsed.title, 'SVFLA');
      final match = await adapter.bestMatch(parsed);
      expect(match, isNotNull);
      expect(match!.movie.providerId, '1svfla012');
      expect(match.score, 1.0);
    });

    test('a code after a studio prefix is read from the raw name', () async {
      final adapter = await enabled();
      final parsed = ParsedFileName.parse('[FLAVORY] SVFLA-012.mkv');
      final match = await adapter.bestMatch(parsed);
      expect(match, isNotNull);
      expect(match!.movie.providerId, '1svfla012');
    });
  });

  group('registry', () {
    test('the adapter registers under its own id', () async {
      final registry = MetadataProviderRegistry.instance;
      registry.unregister('r18dev');
      final adapter = R18DevAdapter(
        transport: (uri) async => _decode(lookupEnvelope),
      );
      await adapter.setEnabled(true);
      registry.register(adapter);
      try {
        expect(registry.byId('r18dev'), isNotNull);
        expect(
          (await registry.configured()).map((e) => e.id),
          contains('r18dev'),
        );
      } finally {
        registry.unregister('r18dev');
      }
    });
  });
}

Map<String, dynamic> _decode(String body) =>
    jsonDecode(body) as Map<String, dynamic>;
