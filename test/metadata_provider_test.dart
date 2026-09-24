import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/tmdb_client.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('legacy movie metadata defaults to TMDB', () {
    final movie = TmdMovie.fromMetaJson(const {
      'id': 42,
      'title': 'Example',
      'kind': 'movie',
    });

    expect(movie.provider, MetadataProvider.tmdb);
    expect(movie.tmdbId, 42);
    expect(movie.providerKey, 'tmdb:movie:42');
  });

  test('provider and absolute artwork survive metadata JSON round-trip', () {
    final meta = TmdMeta(
      movie: TmdMovie(
        id: 121361,
        title: 'Example',
        kind: TmdKind.tv,
        provider: MetadataProvider.theTvdb,
        alternateTitles: const ['Canonical Alias'],
        posterPath: 'https://artworks.thetvdb.com/poster.jpg',
      ),
      details: TmdDetails(
        title: 'Example',
        stills: const ['https://artworks.thetvdb.com/still.jpg'],
      ),
    );

    final restored = TmdMeta.fromJson(meta.toJson());
    expect(restored.movie.provider, MetadataProvider.theTvdb);
    expect(restored.movie.tmdbId, isNull);
    expect(restored.movie.alternateTitles, ['Canonical Alias']);
    expect(
      restored.movie.posterUrl(),
      'https://artworks.thetvdb.com/poster.jpg',
    );
    expect(restored.details!.stills, [
      'https://artworks.thetvdb.com/still.jpg',
    ]);
  });

  test('metadata store keeps provider-qualified matches', () async {
    final meta = TmdMeta(
      movie: TmdMovie(
        id: 7,
        title: 'Anime',
        kind: TmdKind.tv,
        provider: MetadataProvider.theTvdb,
      ),
    );

    await TmdStore.save('video:anime', meta);
    final restored = (await TmdStore.loadAll())['video:anime'];
    expect(restored, isNotNull);
    expect(restored!.movie.providerKey, 'theTvdb:tv:7');
  });
}
