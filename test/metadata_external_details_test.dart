import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/metadata_provider_adapter.dart';
import 'package:dream_player/services/tmdb_client.dart';

/// Issue #52, second half: picking an AVDb title in the "Get info" dialog
/// corrupted it.
///
/// `TmdService.detailsFor` dispatched on `theTvdb ? TheTVDB : TMDB`, so an
/// **external** movie fell into the TMDB branch. An adapter's id space is its
/// own - AVDb's #495175 is not TMDB's #495175 - so the app fetched an
/// unrelated TMDB film and wrote its synopsis and poster over the AVDb match.
///
/// The adapter is asked for its own record instead.
class _RecordingAdapter extends MetadataProviderAdapter {
  _RecordingAdapter();

  final List<int> asked = [];

  @override
  String get id => 'recording';

  @override
  String get label => 'Recording';

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<List<TmdMovie>> search(
    String query, {
    TmdKind kind = TmdKind.movie,
  }) async => const [];

  @override
  Future<TmdDetails?> details(TmdMovie movie) async {
    asked.add(movie.id);
    return TmdDetails(
      title: 'from the adapter',
      overview: 'the adapter\'s own synopsis',
      posterPath: 'https://adapter/poster.jpg',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'detailsFor asks the adapter, not TMDB, for an external movie',
    () async {
      final adapter = _RecordingAdapter();
      final registry = MetadataProviderRegistry.instance;
      registry.unregister('recording');
      registry.register(adapter);
      try {
        const key = 'smb:server/share/SVFLA-012.mkv';
        await TmdStore.save(
          key,
          TmdMeta(
            movie: TmdMovie(
              id: 495175,
              title: 'SVFLA-012',
              kind: TmdKind.movie,
              provider: MetadataProvider.external,
            ),
          ),
        );
        await TmdService.instance.ensureLoaded();

        final details = await TmdService.instance.detailsFor(key, force: true);

        expect(adapter.asked, [495175]);
        expect(details?.title, 'from the adapter');
        expect(details?.overview, 'the adapter\'s own synopsis');
      } finally {
        registry.unregister('recording');
      }
    },
  );

  test('detailsForMovie asks the adapter for an external movie', () async {
    final adapter = _RecordingAdapter();
    final registry = MetadataProviderRegistry.instance;
    registry.unregister('recording');
    registry.register(adapter);
    try {
      final details = await TmdService.instance.detailsForMovie(
        TmdMovie(
          id: 495175,
          title: 'SVFLA-012',
          kind: TmdKind.movie,
          provider: MetadataProvider.external,
        ),
      );
      expect(adapter.asked, [495175]);
      expect(details?.title, 'from the adapter');
    } finally {
      registry.unregister('recording');
    }
  });
}
