import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/metadata_provider_adapter.dart';
import 'package:dream_player/services/the_tvdb_client.dart';
import 'package:dream_player/services/tmdb_client.dart';

/// Issue #52: a library FOLDER whose name is not a catalogue code could not
/// be resolved, even when the video inside it was named after one.
///
/// The folder card resolves through `resolveFolder`, whose candidates are the
/// folder's own name and the CLEANED file names. The cleaned name of
/// `SVFLA-012.mkv` is "SVFLA" (the parser strips a trailing number as a
/// movie-part suffix), so the code never reached the adapter - the card stayed
/// bare until the file was opened.
class _CodeAdapter extends MetadataProviderAdapter {
  final List<String> queries = [];

  @override
  String get id => 'codeadapter';

  @override
  String get label => 'Code adapter';

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<List<TmdMovie>> search(
    String query, {
    TmdKind kind = TmdKind.movie,
  }) async {
    queries.add(query);
    if (query != 'SVFLA-012') return const [];
    return [
      TmdMovie(
        id: 42,
        title: 'The catalogue record',
        year: 2025,
        kind: TmdKind.movie,
        provider: MetadataProvider.external,
        alternateTitles: const ['SVFLA-012'],
        providerId: '1svfla012',
      ),
    ];
  }

  @override
  Future<TmdDetails?> details(TmdMovie movie) async => TmdDetails(
    title: 'The catalogue record',
    overview: 'the adapter\'s own synopsis',
    posterPath: 'https://adapter/poster.jpg',
    year: 2025,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await TheTvdbClient.setProviderChoice(MetadataProviderChoice.external);
  });

  test('a folder is resolved through the code in its file name', () async {
    final adapter = _CodeAdapter();
    final registry = MetadataProviderRegistry.instance;
    registry.unregister('codeadapter');
    registry.register(adapter);
    try {
      const key = 'folder:javtest';
      final meta = await TmdService.instance.resolveFolder(
        key,
        'JAVTest',
        fileNames: const ['SVFLA-012.mkv'],
      );
      expect(meta, isNotNull);
      expect(meta!.movie.title, 'The catalogue record');
      expect(meta.movie.provider, MetadataProvider.external);
      expect(meta.movie.providerId, '1svfla012');
      expect(adapter.queries, contains('SVFLA-012'));
      // The CLEANED name must not be what was searched.
      expect(adapter.queries, isNot(contains('SVFLA')));
    } finally {
      registry.unregister('codeadapter');
    }
  });

  test('a folder with several videos is not resolved from one of them', () async {
    // The card stands for every film in the folder, so a single poster would
    // be a guess.
    final adapter = _CodeAdapter();
    final registry = MetadataProviderRegistry.instance;
    registry.unregister('codeadapter');
    registry.register(adapter);
    try {
      final meta = await TmdService.instance.resolveFolder(
        'folder:javtest3',
        'JAVTest',
        fileNames: const ['SVFLA-012.mkv', 'MIAA-818.mkv'],
      );
      expect(adapter.queries, isNot(contains('SVFLA-012')));
      expect(meta, isNull);
    } finally {
      registry.unregister('codeadapter');
    }
  });

  test('with TMDB as the resolver the folder keeps its own name', () async {
    await TheTvdbClient.setProviderChoice(MetadataProviderChoice.tmdb);
    final adapter = _CodeAdapter();
    final registry = MetadataProviderRegistry.instance;
    registry.unregister('codeadapter');
    registry.register(adapter);
    try {
      final meta = await TmdService.instance.resolveFolder(
        'folder:javtest2',
        'JAVTest',
        fileNames: const ['SVFLA-012.mkv'],
      );
      // No code lookup when the external provider is not the primary one.
      expect(adapter.queries, isNot(contains('SVFLA-012')));
      expect(meta, isNull);
    } finally {
      registry.unregister('codeadapter');
    }
  });
}
