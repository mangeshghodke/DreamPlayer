import 'dart:convert';

import 'package:dream_player/services/avdb_adapter.dart';
import 'package:dream_player/services/metadata_provider_adapter.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AVDb adapter for issue #46 part 2.
///
/// The fixtures below are TRIMMED from live responses captured 2026-10-11
/// against `https://avdbapi.com/api.php/provide/vod` - deliberately keeping
/// the fields that differ between endpoints, because that difference is what
/// the adapter has to survive:
///
/// * `ac=list` returns no `poster_url`/`description` at all.
/// * `ac=detail&wd=` returns everything, and wraps it in Maccms `code`/`list`.
/// * `time` is a DURATION "01:58:34", while the release date lives in
///   `created_at`/`vod_pubdate` - reading one as the other is a real bug.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const detailEnvelope = '''
  {
    "code": 1,
    "msg": "Data list",
    "page": 1,
    "pagecount": 1,
    "total": 999,
    "list": [
      {
        "type_name": "Censored",
        "episodes": {"server_name": "VIP #1", "server_data": {}},
        "id": 83,
        "name": "MIAA-818 Targeted By A Big Dick Gangster Patient",
        "slug": "miaa-818",
        "origin_name": "MIAA-818 (original)",
        "tag": "",
        "category": ["Nurse", "Wife", "Censored"],
        "poster_url": "https://upload18.cc/v/miaa-818/poster.jpg",
        "thumb_url": "https://upload18.cc/v/miaa-818/thumb.jpg",
        "actor": ["Jun Suehiro"],
        "director": ["Captain Gangwon"],
        "movie_code": "MIAA-818",
        "created_at": "14 Apr, 2023",
        "country": ["Japan"],
        "year": "2023",
        "quality": "HD",
        "status": "Release",
        "time": "01:58:34",
        "description": "A young wife nurse..."
      }
    ]
  }
  ''';

  /// A list-mode record: no poster, no description. Used to prove the adapter
  /// does not invent data it was not given.
  const listEnvelope = '''
  {
    "code": 1,
    "msg": "Data list",
    "page": 1,
    "total": 523914,
    "list": [
      {
        "type_name": "Chinese AV",
        "id": 638394,
        "name": "TZ164 - Sakura Girl Sex Record [EP9]",
        "origin_name": "TZ164 櫻花妹性愛實錄",
        "category": ["Chinese AV"],
        "actor": ["Updating"],
        "movie_code": "TZ164",
        "vod_time": "2026-10-11 01:21:53"
      }
    ]
  }
  ''';

  AvdbAdapter buildAdapter({Map<String, dynamic>? response}) {
    return AvdbAdapter(
      transport: (uri) async => response ?? _decode(detailEnvelope),
    );
  }

  group('AVDb search', () {
    test('maps a detail record into a TmdMovie', () async {
      final adapter = buildAdapter();
      final results = await adapter.search('miaa-818');
      expect(results, hasLength(1));
      final movie = results.single;
      expect(movie.id, 83);
      expect(movie.title, startsWith('MIAA-818'));
      expect(movie.year, 2023);
      expect(movie.kind, TmdKind.movie);
      expect(movie.provider, MetadataProvider.external);
    });

    test('prefers poster_url over thumb_url', () async {
      final adapter = buildAdapter();
      final movie = (await adapter.search('miaa-818')).single;
      expect(movie.posterPath, 'https://upload18.cc/v/miaa-818/poster.jpg');
    });

    test('falls back to thumb_url when poster_url is absent', () async {
      final adapter = buildAdapter(
        response: _decode(
          detailEnvelope.replaceAll(
            '"poster_url": "https://upload18.cc/v/miaa-818/poster.jpg",',
            '',
          ),
        ),
      );
      final movie = (await adapter.search('miaa-818')).single;
      expect(movie.posterPath, 'https://upload18.cc/v/miaa-818/thumb.jpg');
    });

    test('keeps the JAV code as an alternate title for matching', () async {
      final adapter = buildAdapter();
      final movie = (await adapter.search('miaa-818')).single;
      expect(movie.alternateTitles, contains('MIAA-818'));
    });

    test(
      'a record with no artwork yields a null poster, not a bad URL',
      () async {
        // ac=list genuinely omits it; the row must fall back to its icon rather
        // than pointing at image.tmdb.org with an AVDb path.
        final adapter = buildAdapter(response: _decode(listEnvelope));
        final movie = (await adapter.search('sakura')).single;
        expect(movie.posterPath, isNull);
        expect(movie.posterUrl(), isNull);
      },
    );

    test('refuses TV - AVDb is a movie catalogue', () async {
      final adapter = buildAdapter();
      expect(await adapter.search('anything', kind: TmdKind.tv), isEmpty);
    });

    test('an empty query is not sent to the network', () async {
      var calls = 0;
      final adapter = AvdbAdapter(
        transport: (uri) async {
          calls++;
          return _decode(detailEnvelope);
        },
      );
      expect(await adapter.search('   '), isEmpty);
      expect(calls, 0);
    });

    test(
      'a provider-level failure is treated as no match, not an error',
      () async {
        // Maccms signals failure with code != 1; a body without `list` must not
        // blow up the caller that is mid-resolution across providers.
        final adapter = buildAdapter(response: const <String, dynamic>{});
        expect(await adapter.search('miaa-818'), isEmpty);
      },
    );

    test('a throwing transport also yields no match', () async {
      final adapter = AvdbAdapter(
        transport: (uri) async => throw StateError('offline'),
      );
      expect(await adapter.search('miaa-818'), isEmpty);
    });

    test('the query is sent as a detail search, not a list browse', () async {
      Uri? seen;
      final adapter = AvdbAdapter(
        transport: (uri) async {
          seen = uri;
          return _decode(detailEnvelope);
        },
      );
      await adapter.search('miaa 818');
      expect(seen!.queryParameters['ac'], 'detail');
      expect(seen!.queryParameters['wd'], 'miaa 818');
    });

    // Issue #52: the reporter typed the catalogue code three ways -
    // "SVFLA-012", "SVFLA012" and "SVFLA 012". Measured live against
    // avdbapi.com: the hyphen and the space both match, the separator-less
    // spelling matches NOTHING. The adapter therefore retries the
    // separator-less form with the hyphen the catalogue actually uses.
    group('catalogue-code spellings (issue #52)', () {
      test('queryVariants adds the hyphenated form of a bare code', () {
        expect(AvdbAdapter.queryVariants('SVFLA012'), [
          'SVFLA012',
          'SVFLA-012',
        ]);
      });

      test('queryVariants leaves an already-hyphenated code alone', () {
        expect(AvdbAdapter.queryVariants('SVFLA-012'), ['SVFLA-012']);
      });

      test('queryVariants leaves an ordinary title alone', () {
        expect(AvdbAdapter.queryVariants('Some Movie'), ['Some Movie']);
      });

      test('a separator-less code is retried with the hyphen', () async {
        final seen = <String>[];
        final adapter = AvdbAdapter(
          transport: (uri) async {
            final term = uri.queryParameters['wd'] ?? '';
            seen.add(term);
            // The bare form finds nothing, exactly like the live service.
            if (term == 'SVFLA012') {
              return {'code': 1, 'list': const []};
            }
            return _decode(detailEnvelope);
          },
        );
        final results = await adapter.search('SVFLA012');
        expect(results, hasLength(1));
        expect(seen, ['SVFLA012', 'SVFLA-012']);
      });

      test('the code is read from the RAW name, not the parsed title', () async {
        // The filename parser strips the trailing number as a movie-part
        // suffix, so the parsed title of `MIAA-818.mkv` is just "MIAA"
        // (issue #52). The adapter has to use the original name.
        final seen = <String>[];
        final adapter = AvdbAdapter(
          transport: (uri) async {
            seen.add(uri.queryParameters['wd'] ?? '');
            return _decode(detailEnvelope);
          },
        );
        await adapter.setEnabled(true);
        final parsed = ParsedFileName.parse('MIAA-818.mkv');
        expect(parsed.title, 'MIAA');
        final match = await adapter.bestMatch(parsed);
        expect(match, isNotNull);
        expect(match!.score, 1.0);
        expect(match.movie.alternateTitles, contains('MIAA-818'));
        expect(seen, contains('MIAA-818'));
      });

      test('the first spelling that hits is the one that is used', () async {
        final seen = <String>[];
        final adapter = AvdbAdapter(
          transport: (uri) async {
            final term = uri.queryParameters['wd'] ?? '';
            seen.add(term);
            return _decode(detailEnvelope);
          },
        );
        await adapter.search('SVFLA-012');
        expect(seen, ['SVFLA-012']);
      });
    });

    // The live `origin_name` carries HTML entities ("SVFLA-012
    // "Doesn&#039;t my ...""), which used to be shown raw.
    group('HTML entities (issue #52)', () {
      test('decodes the entities AVDb leaves in its text', () {
        // The live `origin_name` is HTML-escaped by the catalogue:
        // SVFLA-012 \u0026quot;Doesn\u0026039;t my ...\u0026quot;
        expect(
          AvdbAdapter.unescapeHtml(
            'SVFLA-012 \u0026quot;Doesn\u0026039;t my \u0026quot;',
          ),
          'SVFLA-012 "Doesn\'t my "',
        );
      });

      test('a plain string is untouched', () {
        expect(
          AvdbAdapter.unescapeHtml('MIAA-818 (original)'),
          'MIAA-818 (original)',
        );
      });

      test('an escaped ampersand stays a single ampersand', () {
        expect(AvdbAdapter.unescapeHtml('a &amp; b'), 'a & b');
      });

      test('the parsed original title carries the decoded text', () async {
        final adapter = buildAdapter(
          response: _decode(
            detailEnvelope.replaceAll(
              'MIAA-818 (original)',
              'SVFLA-012 \u0026quot;Doesn\u0026039;t my ...\u0026quot;',
            ),
          ),
        );
        final movie = (await adapter.search('miaa-818')).single;
        expect(movie.originalTitle, 'SVFLA-012 "Doesn\'t my ..."');
      });
    });

    // Issue #49: a user who knows the numeric id is the most precise input
    // there is. Probed live -- `ids=604629` returns exactly one record, while
    // the title of that same record is not reliably reachable through `wd`.
    group('id search', () {
      Future<Uri?> capture(String query) async {
        Uri? seen;
        final adapter = AvdbAdapter(
          transport: (uri) async {
            seen = uri;
            return _decode(detailEnvelope);
          },
        );
        await adapter.search(query);
        return seen;
      }

      test('a numeric query uses ids= rather than wd=', () async {
        final uri = await capture('604629');
        expect(uri!.queryParameters['ids'], '604629');
        expect(uri.queryParameters.containsKey('wd'), isFalse);
      });

      test('a non-numeric query still uses wd=', () async {
        final uri = await capture('miaa-818');
        expect(uri!.queryParameters['wd'], 'miaa-818');
        expect(uri.queryParameters.containsKey('ids'), isFalse);
      });

      test('whitespace around an id is tolerated', () async {
        final uri = await capture('  604629  ');
        expect(uri!.queryParameters['ids'], '604629');
      });

      test('zero and negatives are not treated as ids', () async {
        // 0 and -1 are meaningless ids, and sending them would replace a title
        // search the user actually meant with a lookup that cannot exist.
        expect((await capture('0'))!.queryParameters['wd'], '0');
        expect((await capture('-5'))!.queryParameters['wd'], '-5');
      });

      test('a numeric code like a movie id is not misread', () async {
        // Codes such as "118abp00123" are non-numeric, but a purely numeric
        // one would legitimately be an id -- so this asserts the documented
        // behaviour rather than pretending the ambiguity does not exist.
        final uri = await capture('12345');
        expect(uri!.queryParameters['ids'], '12345');
      });
    });
  });

  group('AVDb details', () {
    test('maps runtime from the HH:MM:SS duration, not the date', () async {
      final adapter = buildAdapter();
      final movie = (await adapter.search('miaa-818')).single;
      final details = await adapter.details(movie);
      expect(details, isNotNull);
      // 1h58m34s -> 118 minutes. Reading "01:58:34" as a time-of-day or
      // using created_at ("14 Apr, 2023") instead would give a wrong number.
      expect(details!.runtimeMinutes, 118);
      expect(details.year, 2023);
      expect(details.genres, contains('Nurse'));
      expect(details.cast.map((c) => c.name), contains('Jun Suehiro'));
      expect(details.overview, 'A young wife nurse...');
    });

    test('parses MM:SS and rejects nonsense', () async {
      expect(AvdbAdapter.runtimeMinutesFrom('45:30'), 45);
      expect(AvdbAdapter.runtimeMinutesFrom('1:58:34'), 118);
      expect(AvdbAdapter.runtimeMinutesFrom('not a time'), isNull);
      expect(AvdbAdapter.runtimeMinutesFrom(null), isNull);
    });

    test('refuses a movie from another provider', () async {
      final adapter = buildAdapter();
      final tmdbMovie = TmdMovie(id: 1, title: 'x');
      expect(await adapter.details(tmdbMovie), isNull);
    });
  });

  group('AVDb enable switch', () {
    // The adapter is a singleton in the app, so its cached flag leaks between
    // cases unless every test states the starting state explicitly.
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await AvdbAdapter.instance.setEnabled(false);
    });

    test(
      'defaults to disabled, so nothing is queried out of the box',
      () async {
        SharedPreferences.setMockInitialValues({});
        final adapter = AvdbAdapter();
        expect(await adapter.isConfigured(), isFalse);
      },
    );

    test('persists the switch and reloads it', () async {
      SharedPreferences.setMockInitialValues({});
      await AvdbAdapter.instance.setEnabled(true);
      expect(await AvdbAdapter.instance.isConfigured(), isTrue);
    });

    test('turning it off again persists', () async {
      final adapter = AvdbAdapter();
      await adapter.setEnabled(true);
      await adapter.setEnabled(false);
      expect(await AvdbAdapter().isConfigured(), isFalse);
    });
  });

  group('registry integration', () {
    test('AVDb registers and is skipped until enabled', () async {
      SharedPreferences.setMockInitialValues({});
      await AvdbAdapter.instance.setEnabled(false);
      final registry = MetadataProviderRegistry.instance;
      registry.unregister('avdb');
      registry.register(AvdbAdapter.instance);
      try {
        expect(registry.byId('avdb'), isNotNull);
        expect(await registry.configured(), isEmpty);

        await AvdbAdapter.instance.setEnabled(true);
        expect(
          (await registry.configured()).map((a) => a.id),
          contains('avdb'),
        );
      } finally {
        registry.unregister('avdb');
      }
    });
  });
}

Map<String, dynamic> _decode(String body) =>
    jsonDecode(body) as Map<String, dynamic>;
