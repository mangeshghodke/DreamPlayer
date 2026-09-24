import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/the_tvdb_client.dart';
import 'package:dream_player/services/tmdb_client.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('uses secure channel storage and migrates legacy credentials', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('dreamplayer/the_tvdb_credentials.test');
    final calls = <MethodCall>[];
    var storedKey = '';
    var storedPin = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'read':
              return {'apiKey': storedKey, 'pin': storedPin};
            case 'write':
              final args = Map<String, dynamic>.from(call.arguments as Map);
              storedKey = args['apiKey'] as String? ?? '';
              storedPin = args['pin'] as String? ?? '';
              return null;
            case 'clear':
              storedKey = '';
              storedPin = '';
              return null;
            default:
              return null;
          }
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('dreamplayer.theTvdbApiKey', 'legacy-key');
    await preferences.setString('dreamplayer.theTvdbPin', 'legacy-pin');
    final store = TheTvdbCredentialStore(channel: channel);

    await store.load();
    expect(store.apiKey, 'legacy-key');
    expect(store.pin, 'legacy-pin');
    expect(preferences.getString('dreamplayer.theTvdbApiKey'), isNull);
    expect(preferences.getString('dreamplayer.theTvdbPin'), isNull);

    await store.save(apiKey: 'secure-key', pin: '1234');
    expect(storedKey, 'secure-key');
    expect(storedPin, '1234');
    await store.clear();
    expect(store.isConfigured, isFalse);
    expect(calls.map((call) => call.method), [
      'read',
      'write',
      'write',
      'clear',
    ]);
  });

  test('does not fall back to plaintext when secure storage fails', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('dreamplayer/the_tvdb_credentials.failure');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'unavailable');
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('dreamplayer.theTvdbApiKey', 'legacy-key');
    final store = TheTvdbCredentialStore(channel: channel);

    await expectLater(store.load(), throwsA(isA<TheTvdbException>()));
    expect(preferences.getString('dreamplayer.theTvdbApiKey'), 'legacy-key');
    await expectLater(
      store.save(apiKey: 'new-key', pin: '1234'),
      throwsA(isA<TheTvdbException>()),
    );
    expect(preferences.getString('dreamplayer.theTvdbApiKey'), 'legacy-key');
  });

  test('maps search results and preserves TheTVDB provider', () {
    final movies = TheTvdbClient.mapSearchResponse({
      'status': 'success',
      'data': [
        {
          'id': 121361,
          'name': 'Breaking Bad',
          'type': 'series',
          'year': '2008',
          'aliases': ['ブレイキング・バッド'],
          'image': '/banners/v4/series/121361.jpg',

          'score': 95,
        },
      ],
    }, kind: TmdKind.tv);

    expect(movies, hasLength(1));
    expect(movies.single.id, 121361);
    expect(movies.single.title, 'Breaking Bad');
    expect(movies.single.year, 2008);
    expect(movies.single.kind, TmdKind.tv);
    expect(movies.single.provider, MetadataProvider.theTvdb);
    expect(
      movies.single.posterUrl(),
      'https://artworks.thetvdb.com/banners/v4/series/121361.jpg',
    );
    expect(movies.single.voteAverage, 0);
    expect(movies.single.alternateTitles, contains('ブレイキング・バッド'));
  });

  test('matches a query against TheTVDB alternate titles', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('dreamplayer.theTvdbApiKey', 'secret');
    final client = TheTvdbClient(
      prefs: preferences,
      maxRetries: 0,
      transport: (request) async {
        if (request.method == 'POST') {
          return const TheTvdbResponse(
            statusCode: 200,
            body: '{"status":"success","data":{"token":"token"}}',
          );
        }
        return TheTvdbResponse(
          statusCode: 200,
          body: jsonEncode({
            'status': 'success',
            'data': [
              {
                'id': 7,
                'name': 'Canonical Title',
                'aliases': ['日本語タイトル'],
              },
            ],
          }),
        );
      },
    );

    final match = await client.bestForQuery('日本語タイトル');
    expect(match, isNotNull);
    expect(match!.movie.title, 'Canonical Title');
    client.dispose();
  });

  test('keeps Unicode queries and parses prefixed IDs', () async {
    final preferences = await SharedPreferences.getInstance();

    await preferences.setString('dreamplayer.theTvdbApiKey', 'secret');
    Uri? requestUri;
    final client = TheTvdbClient(
      prefs: preferences,
      maxRetries: 0,
      transport: (request) async {
        if (request.method == 'POST') {
          return const TheTvdbResponse(
            statusCode: 200,
            body: '{"status":"success","data":{"token":"token"}}',
          );
        }
        requestUri = request.uri;
        return const TheTvdbResponse(
          statusCode: 200,
          body: '{"status":"success","data":[]}',
        );
      },
    );

    await client.search('進撃の巨人', kind: TmdKind.tv);
    expect(requestUri?.queryParameters['query'], '進撃の巨人');
    expect(
      TheTvdbClient.mapSearchResult({
        'id': 'series-121361',
        'name': 'Example',
        'type': 'series',
      }, kind: TmdKind.tv)?.id,
      121361,
    );
    client.dispose();
  });

  test('maps extended details, artwork, cast, and season names', () {
    final response = {
      'status': 'success',
      'data': {
        'id': 121361,
        'name': 'Breaking Bad',
        'firstAired': '2008-01-20',
        'averageRuntime': 47,
        'overview': 'A chemistry teacher turns to crime.',
        'genres': [
          {'id': 1, 'name': 'Drama'},
          {'id': 2, 'name': 'Crime'},
        ],
        'artworks': [
          {'type': 'poster', 'image': '/series/poster.jpg'},
          {'type': 'background', 'image': '/series/background.jpg'},
        ],
        'characters': [
          {
            'name': 'Walter White',
            'personName': 'Bryan Cranston',
            'personImgURL': '/people/bryan.jpg',
          },
        ],
        'seasons': [
          {'number': 1, 'name': 'Season 1', 'image': '/seasons/one.jpg'},
        ],
      },
    };

    final details = TheTvdbClient.mapExtendedResponse(
      response,
      kind: TmdKind.tv,
    );

    expect(details, isNotNull);
    expect(details!.title, 'Breaking Bad');
    expect(details.year, 2008);
    expect(details.runtimeMinutes, 47);
    expect(details.genres, ['Drama', 'Crime']);
    expect(
      details.posterPath,
      'https://artworks.thetvdb.com/series/poster.jpg',
    );
    expect(
      details.backdropPath,
      'https://artworks.thetvdb.com/series/background.jpg',
    );
    expect(details.cast.single.name, 'Bryan Cranston');
    expect(details.cast.single.character, 'Walter White');
    expect(
      details.cast.single.profileUrl(),
      'https://artworks.thetvdb.com/people/bryan.jpg',
    );
    expect(TheTvdbClient.mapSeasonNamesResponse(response), {1: 'Season 1'});
  });

  test('maps and filters default-series episodes', () {
    final response = {
      'status': 'success',
      'data': {
        'episodes': [
          {
            'id': 1,
            'seriesId': 121361,
            'seasonNumber': 1,
            'number': 1,
            'name': 'Pilot',
            'aired': '2008-01-20',
            'runtime': 58,
            'overview': 'The first episode.',
            'image': '/episodes/one.jpg',
          },
          {
            'id': 2,
            'seriesId': 121361,
            'seasonNumber': 2,
            'number': 1,
            'name': 'Season two premiere',
            'aired': '2009-03-08',
            'runtime': 47,
            'image': '/episodes/two.jpg',
          },
        ],
      },
    };

    final episodes = TheTvdbClient.mapEpisodesResponse(response, season: 2);

    expect(episodes, hasLength(1));
    expect(episodes.single.episodeNumber, 1);
    expect(episodes.single.name, 'Season two premiere');
    expect(episodes.single.airDate, '2009-03-08');
    expect(episodes.single.runtimeMinutes, 47);
    expect(
      episodes.single.stillUrl(),
      'https://artworks.thetvdb.com/episodes/two.jpg',
    );
  });

  test('reports absent credentials and makes no search request', () async {
    final preferences = await SharedPreferences.getInstance();
    var requests = 0;
    final client = TheTvdbClient(
      prefs: preferences,
      retryDelay: Duration.zero,
      transport: (request) async {
        requests++;
        return const TheTvdbResponse(statusCode: 200, body: '{}');
      },
    );

    expect(client.isConfigured, isFalse);
    expect(await client.isConfiguredAsync, isFalse);
    expect(await client.search('Anything'), isEmpty);
    expect(requests, 0);
    await expectLater(client.login(), throwsA(isA<TheTvdbException>()));
    client.dispose();
  });

  test('persists and clears API credentials', () async {
    final preferences = await SharedPreferences.getInstance();
    final client = TheTvdbClient(prefs: preferences);

    await client.setCredentials(apiKey: 'secret', pin: '1234');
    expect(preferences.getString('dreamplayer.theTvdbApiKey'), 'secret');
    expect(preferences.getString('dreamplayer.theTvdbPin'), '1234');
    expect(client.isConfigured, isTrue);
    expect(client.pin, '1234');

    await client.clearCredentials();
    expect(preferences.getString('dreamplayer.theTvdbApiKey'), isNull);
    expect(preferences.getString('dreamplayer.theTvdbPin'), isNull);
    expect(client.isConfigured, isFalse);
    client.dispose();
  });

  test('uses the default TheTVDB season order', () {
    final seasons = TheTvdbClient.mapSeasonsResponse({
      'status': 'success',
      'data': {
        'defaultSeasonType': 2,
        'seasonTypes': [
          {'id': 1, 'type': 'official', 'name': 'Aired Order'},
          {'id': 2, 'type': 'alternate', 'name': 'Alternate Order'},
        ],
        'seasons': [
          {
            'number': 1,
            'name': 'Aired season',
            'type': {'id': 1},
          },
          {
            'number': 1,
            'name': 'Alternate season',
            'type': {'id': 2},
          },
          {
            'number': 2,
            'name': 'Alternate season two',
            'type': {'id': 2},
          },
        ],
      },
    });

    expect(seasons.map((season) => season.name), [
      'Alternate season',
      'Alternate season two',
    ]);
  });

  test('loads all episode pages and deduplicates records', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('dreamplayer.theTvdbApiKey', 'secret');
    final pages = <String>[];
    final client = TheTvdbClient(
      prefs: preferences,
      maxRetries: 0,
      transport: (request) async {
        if (request.method == 'POST') {
          return const TheTvdbResponse(
            statusCode: 200,
            body: '{"status":"success","data":{"token":"token"}}',
          );
        }
        final page = request.uri.queryParameters['page'] ?? '0';
        pages.add(page);
        return TheTvdbResponse(
          statusCode: 200,
          body: jsonEncode({
            'status': 'success',
            'data': {
              'episodes': [
                {
                  'number': page == '0' ? 1 : 2,
                  'seasonNumber': 1,
                  'name': page == '0' ? 'One' : 'Two',
                  'aired': page == '0' ? '2024-01-01' : '2024-01-02',
                },
              ],
            },
            'links': {
              'next': page == '0'
                  ? 'https://api4.thetvdb.com/v4/series/1/episodes/default?page=1'
                  : null,
              'page_size': 2,
            },
          }),
        );
      },
    );

    final episodes = await client.seasonEpisodes(1, season: 1);
    expect(episodes.map((episode) => episode.episodeNumber), [1, 2]);
    expect(pages, ['0', '1']);
    client.dispose();
  });

  test(
    'testing explicit credentials does not overwrite saved credentials',
    () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('dreamplayer.theTvdbApiKey', 'old-key');
      final client = TheTvdbClient(
        prefs: preferences,
        maxRetries: 0,
        transport: (request) async => const TheTvdbResponse(
          statusCode: 200,
          body: '{"status":"success","data":{"token":"token"}}',
        ),
      );

      await client.login(apiKey: 'new-key', persist: false);
      expect(preferences.getString('dreamplayer.theTvdbApiKey'), 'old-key');
      expect(client.apiKey, 'old-key');
      client.dispose();
    },
  );

  test('caches login token and re-logs in after a 401', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('dreamplayer.theTvdbApiKey', 'secret');
    var loginCount = 0;
    var searchCount = 0;
    final client = TheTvdbClient(
      prefs: preferences,
      maxRetries: 0,
      retryDelay: Duration.zero,
      transport: (request) async {
        if (request.method == 'POST') {
          loginCount++;
          return TheTvdbResponse(
            statusCode: 200,
            body: '{"status":"success","data":{"token":"token-$loginCount"}}',
          );
        }
        searchCount++;
        if (searchCount == 1) {
          return const TheTvdbResponse(statusCode: 401, body: '{}');
        }
        return const TheTvdbResponse(
          statusCode: 200,
          body: '{"status":"success","data":[]}',
        );
      },
    );

    expect(await client.search('Breaking Bad', kind: TmdKind.tv), isEmpty);
    expect(loginCount, 2);
    expect(searchCount, 2);
    client.dispose();
  });
}
