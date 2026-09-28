import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/metadata_search.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:dream_player/services/the_tvdb_client.dart';

/// The Get info / Fix match / Group poster dialogs no longer show a provider
/// picker — they search every configured provider and present one merged,
/// de-duplicated list. These tests cover the merge contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  TmdMovie movie(
    int id,
    String title, {
    int? year,
    TmdKind kind = TmdKind.movie,
    MetadataProvider provider = MetadataProvider.tmdb,
  }) => TmdMovie(
        id: id,
        title: title,
        year: year,
        kind: kind,
        provider: provider,
      );

  group('hasAnyProvider', () {
    test('false when no provider is configured', () async {
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: ''),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
      );
      expect(await search.hasAnyProvider, isFalse);
      search.dispose();
    });

    test('true when only a TMDB key is present', () async {
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: 'a' * 32),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
      );
      expect(await search.hasAnyProvider, isTrue);
      search.dispose();
    });

    test('true when only TheTVDB credentials are present', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(theTvdbApiKeyPrefsKey, 'tvdb-key');
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: ''),
        theTvdb: TheTvdbClient(prefs: prefs),
      );
      expect(await search.hasAnyProvider, isTrue);
      search.dispose();
    });
  });

  group('search', () {
    test('returns empty for a blank query without touching the network',
        () async {
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: 'a' * 32),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
      );
      expect(await search.search('   ', kind: TmdKind.movie), isEmpty);
      search.dispose();
    });

    test('returns empty when nothing is configured', () async {
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: ''),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
      );
      expect(await search.search('Dune', kind: TmdKind.movie), isEmpty);
      search.dispose();
    });
  });

  group('byId', () {
    test('rejects a non-positive id', () async {
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: 'a' * 32),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
      );
      expect(await search.byId(0, TmdKind.movie), isEmpty);
      expect(await search.byId(-5, TmdKind.tv), isEmpty);
      search.dispose();
    });

    test('returns empty when nothing is configured', () async {
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: ''),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
      );
      expect(await search.byId(27205, TmdKind.movie), isEmpty);
      search.dispose();
    });
  });

  group('seasonNames', () {
    test('returns empty for a movie (no seasons)', () async {
      final search = MetadataSearch(
        tmdb: TmdApi(apiKey: 'a' * 32),
        theTvdb: TheTvdbClient(prefs: await SharedPreferences.getInstance()),
      );
      expect(await search.seasonNames(movie(1, 'Dune')), isEmpty);
      search.dispose();
    });
  });

  group('cross-provider dedupe', () {
    test('a TMDB hit and its TheTVDB twin collapse to one row (TMDB wins)',
        () {
      // Same title, year and kind from both providers — the dialog must show
      // one entry. TMDB is listed first, so it wins the tie.
      final merged = MetadataSearch.dedupe([
        movie(27205, 'Dune', year: 2021, provider: MetadataProvider.tmdb),
        movie(48135, 'Dune', year: 2021, provider: MetadataProvider.theTvdb),
      ]);
      expect(merged.length, 1);
      expect(merged.single.provider, MetadataProvider.tmdb);
      expect(merged.single.id, 27205);
    });

    test('TheTVDB-only titles still appear alongside TMDB hits', () {
      final merged = MetadataSearch.dedupe([
        movie(1, 'Dune', year: 2021),
        movie(2, 'Foundation', year: 2021, kind: TmdKind.tv,
            provider: MetadataProvider.theTvdb),
      ]);
      expect(merged.length, 2);
    });

    test('different kinds and years stay separate', () {
      final merged = MetadataSearch.dedupe([
        movie(1, 'Dune', year: 2021),
        movie(2, 'Dune', year: 1984),
        movie(3, 'Dune', year: 2021, kind: TmdKind.tv),
      ]);
      expect(merged.length, 3);
    });

    test('punctuation and case differences are treated as the same title',
        () {
      final merged = MetadataSearch.dedupe([
        movie(1, 'Dune: Part Two', year: 2024),
        movie(2, 'DUNE part two', year: 2024,
            provider: MetadataProvider.theTvdb),
      ]);
      expect(merged.length, 1);
    });

    test('an apostrophe normalizes to a space on both sides', () {
      // "Can't" → "can t" for BOTH providers, so the two still collapse even
      // though it looks like a typo at a glance.
      final merged = MetadataSearch.dedupe([
        movie(1, "Komi Can't Communicate"),
        movie(2, "komi can't communicate", provider: MetadataProvider.theTvdb),
      ]);
      expect(merged.length, 1);
    });

    test('entries with no id or no title are dropped', () {
      final merged = MetadataSearch.dedupe([
        movie(0, 'Broken'),
        movie(5, '   '),
        movie(9, 'Keeper'),
      ]);
      expect(merged.length, 1);
      expect(merged.single.title, 'Keeper');
    });
  });
}
