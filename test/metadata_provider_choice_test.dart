import 'package:dream_player/services/the_tvdb_client.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Settings provider choice has to actually change WHICH provider resolves
/// first — the previous behaviour was hard-coded TMDB-then-TheTVDB at two call
/// sites, so choosing TheTVDB could not do anything. [providerOrderFor] is the
/// pure decision those call sites now share, which is what makes it testable.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('providerOrderFor', () {
    test('TMDB choice with both keys: TMDB first, TheTVDB only as fallback', () {
      expect(
        providerOrderFor(
          choice: MetadataProviderChoice.tmdb,
          tmdbConfigured: true,
          theTvdbConfigured: true,
          theTvdbFallbackEnabled: true,
        ),
        [MetadataProvider.tmdb, MetadataProvider.theTvdb],
      );
    });

    test('choosing TMDB does NOT pull in TheTVDB when the fallback is off', () {
      expect(
        providerOrderFor(
          choice: MetadataProviderChoice.tmdb,
          tmdbConfigured: true,
          theTvdbConfigured: true,
          theTvdbFallbackEnabled: false,
        ),
        [MetadataProvider.tmdb],
      );
    });

    test('choosing TheTVDB puts TheTVDB FIRST', () {
      final order = providerOrderFor(
        choice: MetadataProviderChoice.theTvdb,
        tmdbConfigured: true,
        theTvdbConfigured: true,
        theTvdbFallbackEnabled: true,
      );
      expect(order.first, MetadataProvider.theTvdb);
      expect(order, [MetadataProvider.theTvdb, MetadataProvider.tmdb]);
    });

    test('choosing TheTVDB ignores the fallback switch (it is the primary now)',
        () {
      expect(
        providerOrderFor(
          choice: MetadataProviderChoice.theTvdb,
          tmdbConfigured: true,
          theTvdbConfigured: true,
          theTvdbFallbackEnabled: false,
        ),
        [MetadataProvider.theTvdb, MetadataProvider.tmdb],
      );
    });

    test('TheTVDB-only (no TMDB key) never queries TMDB', () {
      expect(
        providerOrderFor(
          choice: MetadataProviderChoice.theTvdb,
          tmdbConfigured: false,
          theTvdbConfigured: true,
          theTvdbFallbackEnabled: false,
        ),
        [MetadataProvider.theTvdb],
      );
    });

    test('choosing TheTVDB with no TheTVDB key degrades to TMDB', () {
      expect(
        providerOrderFor(
          choice: MetadataProviderChoice.theTvdb,
          tmdbConfigured: true,
          theTvdbConfigured: false,
          theTvdbFallbackEnabled: true,
        ),
        [MetadataProvider.tmdb],
      );
    });

    test('TMDB choice with no TMDB key uses TheTVDB rather than nothing', () {
      expect(
        providerOrderFor(
          choice: MetadataProviderChoice.tmdb,
          tmdbConfigured: false,
          theTvdbConfigured: true,
          theTvdbFallbackEnabled: false,
        ),
        [MetadataProvider.theTvdb],
      );
    });

    test('never returns an empty order', () {
      for (final choice in MetadataProviderChoice.values) {
        for (final tmdb in [true, false]) {
          for (final tvdb in [true, false]) {
            for (final fallback in [true, false]) {
              expect(
                providerOrderFor(
                  choice: choice,
                  tmdbConfigured: tmdb,
                  theTvdbConfigured: tvdb,
                  theTvdbFallbackEnabled: fallback,
                ),
                isNotEmpty,
                reason: 'choice=$choice tmdb=$tmdb tvdb=$tvdb fallback=$fallback',
              );
            }
          }
        }
      }
    });

    test('never asks a provider for something it has no key for', () {
      for (final choice in MetadataProviderChoice.values) {
        expect(
          providerOrderFor(
            choice: choice,
            tmdbConfigured: false,
            theTvdbConfigured: true,
            theTvdbFallbackEnabled: true,
          ),
          isNot(contains(MetadataProvider.tmdb)),
        );
        expect(
          providerOrderFor(
            choice: choice,
            tmdbConfigured: true,
            theTvdbConfigured: false,
            theTvdbFallbackEnabled: true,
          ),
          isNot(contains(MetadataProvider.theTvdb)),
        );
      }
    });
  });

  group('provider choice persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to TMDB when nothing is stored', () async {
      expect(await TheTvdbClient.providerChoice(),
          MetadataProviderChoice.tmdb);
    });

    test('round-trips TheTVDB', () async {
      await TheTvdbClient.setProviderChoice(MetadataProviderChoice.theTvdb);
      expect(await TheTvdbClient.providerChoice(),
          MetadataProviderChoice.theTvdb);
    });

    test('round-trips back to TMDB', () async {
      await TheTvdbClient.setProviderChoice(MetadataProviderChoice.theTvdb);
      await TheTvdbClient.setProviderChoice(MetadataProviderChoice.tmdb);
      expect(await TheTvdbClient.providerChoice(),
          MetadataProviderChoice.tmdb);
    });
  });

  group('clearing a stored provider choice', () {
    test('a corrupt stored value falls back to TMDB rather than throwing',
        () async {
      SharedPreferences.setMockInitialValues(
          {TheTvdbClient.providerPrefsKey: 'garbage'});
      expect(await TheTvdbClient.providerChoice(),
          MetadataProviderChoice.tmdb);
    });
  });
}
