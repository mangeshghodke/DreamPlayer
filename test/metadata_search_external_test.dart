import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/metadata_provider_adapter.dart';
import 'package:dream_player/services/metadata_search.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:dream_player/services/the_tvdb_client.dart';

/// Issue #52: the "Get info" / "Fix match" / "Choose poster" dialogs were
/// gated on a TMDB or TheTVDB **API key** and never consulted the registered
/// adapters. A user with AVDb enabled (which needs no key at all) was told to
/// "add a TMDB or TheTVDB API key", and the search never ran - no results, no
/// error, nothing.
///
/// These pin the adapter-aware behaviour of [MetadataSearch].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  TmdMovie externalMovie(int id, String title) => TmdMovie(
    id: id,
    title: title,
    kind: TmdKind.movie,
    provider: MetadataProvider.external,
  );

  group('hasAnyProvider (issue #52)', () {
    test('is true with only an adapter enabled and no API key', () async {
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: ''),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
        adapters: [_FakeAdapter()],
      );
      expect(await search.hasAnyProvider, isTrue);
      search.dispose();
    });

    test('is false when the only adapter is disabled', () async {
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: ''),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
        adapters: [_FakeAdapter(configured: false)],
      );
      expect(await search.hasAnyProvider, isFalse);
      search.dispose();
    });
  });

  group('search (issue #52)', () {
    test('returns the adapter hits when no built-in is configured', () async {
      final adapter = _FakeAdapter(hits: [externalMovie(495175, 'SVFLA-012')]);
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: ''),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
        adapters: [adapter],
      );
      final results = await search.search('SVFLA-012', kind: TmdKind.movie);
      expect(results.length, 1);
      expect(results.single.title, 'SVFLA-012');
      expect(results.single.provider, MetadataProvider.external);
      expect(adapter.queries, contains('SVFLA-012'));
      search.dispose();
    });

    test(
      'a TV-kind search falls back to the movie kind for the adapter',
      () async {
        // AVDb is a movie catalogue, so it answers nothing for TmdKind.tv. The
        // dialog's kind-first fallback has to reach it again with the other
        // kind, or a file whose name looks like an episode finds nothing.
        final adapter = _FakeAdapter(hits: [externalMovie(7, 'Some Film')]);
        final search = MetadataSearch(
          tmdb: TmdApi(apiKey: ''),
          theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
          adapters: [adapter],
        );
        final results = await search.search('Some Film', kind: TmdKind.tv);
        expect(results.length, 1);
        expect(adapter.kinds, containsAllInOrder([TmdKind.tv, TmdKind.movie]));
        search.dispose();
      },
    );

    test('an adapter that throws does not sink the search', () async {
      final adapter = _ThrowingAdapter();
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: ''),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
        adapters: [adapter],
      );
      expect(await search.search('Anything', kind: TmdKind.movie), isEmpty);
      search.dispose();
    });
  });

  group('byId (issue #52)', () {
    test('an adapter is probed with the id as text', () async {
      // AVDb's id space is its own, so the id is handed over as TEXT and the
      // adapter decides what it means with it (AVDb routes a numeric term to
      // `ids=`).
      final adapter = _FakeAdapter(hits: [externalMovie(604629, 'Whatever')]);
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: ''),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
        adapters: [adapter],
      );
      final results = await search.byId(604629, TmdKind.movie);
      expect(results.length, 1);
      expect(adapter.queries, contains('604629'));
      search.dispose();
    });
  });

  group('seasonNames (issue #52)', () {
    test('an external series never asks TMDB for seasons', () async {
      // An external id is not a TMDB id, so asking TMDB would answer with an
      // unrelated series' season names.
      final adapter = _FakeAdapter();
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: 'a' * 32),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
        adapters: [adapter],
      );
      final names = await search.seasonNames(
        TmdMovie(
          id: 495175,
          title: 'SVFLA-012',
          kind: TmdKind.tv,
          provider: MetadataProvider.external,
        ),
      );
      expect(names, isEmpty);
      search.dispose();
    });
  });
}

/// A stand-in adapter that records what it was asked and answers with a
/// fixed list of hits.
class _FakeAdapter extends MetadataProviderAdapter {
  _FakeAdapter({this.hits = const [], this.configured = true});

  final List<TmdMovie> hits;
  final bool configured;
  final List<String> queries = [];
  final List<TmdKind> kinds = [];

  @override
  String get id => 'fake';

  @override
  String get label => 'Fake';

  @override
  Future<bool> isConfigured() async => configured;

  @override
  Future<List<TmdMovie>> search(
    String query, {
    TmdKind kind = TmdKind.movie,
  }) async {
    queries.add(query);
    kinds.add(kind);
    // AVDb is a movie catalogue, so the fake behaves like one: the TV kind
    // finds nothing and the dialog's kind-first fallback has to retry.
    return kind == TmdKind.movie ? hits : const [];
  }

  @override
  Future<TmdDetails?> details(TmdMovie movie) async =>
      TmdDetails(title: 'fake details', overview: 'from the adapter');
}

/// An adapter whose search always fails, to prove one broken provider cannot
/// take the whole search down.
class _ThrowingAdapter extends MetadataProviderAdapter {
  @override
  String get id => 'throwing';

  @override
  String get label => 'Throwing';

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<List<TmdMovie>> search(
    String query, {
    TmdKind kind = TmdKind.movie,
  }) async => throw StateError('provider is down');

  @override
  Future<TmdDetails?> details(TmdMovie movie) async => null;
}
