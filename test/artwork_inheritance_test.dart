import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/artwork_override.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A file's artwork used to diverge from its folder's. Metadata already inherits
/// folder -> file (`carryMeta`, and the home screen's `_matchingLibraryFolder`
/// fallback), but artwork overrides did not, so the same film showed one poster
/// on its home card and a different one on its continue-watching card — and only
/// after you played the file, because that is what gives the file its own
/// metadata entry and shadows the folder's.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const folderKey = 'folder:abc123';
  const fileKey = 'smb:server1/Downloads/Video/Movies/Avengers.mkv';

  const folderMeta = TmdMeta(
    movie: TmdMovie(id: 1, title: 'Avengers',
        posterPath: '/f-poster.jpg', backdropPath: '/f-backdrop.jpg'),
  );
  const fileMeta = TmdMeta(
    movie: TmdMovie(id: 1, title: 'Avengers',
        posterPath: '/x-poster.jpg', backdropPath: '/x-backdrop.jpg'),
  );

  Future<void> override(String key, ArtworkKind kind, String url) =>
      ArtworkOverrideStore.set(
          key, kind, MetaImage(url: url, provider: MetadataProvider.tmdb));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ArtworkOverrideStore.resetForTest();
    final service = TmdService.instance;
    await service.ensureLoaded();
    await service.clearAllResolved();
    // Seed through the service, not TmdStore.save: the service keeps its own
    // cache and only these calls populate it.
    await service.setManualFolder(folderKey, folderMeta.movie);
    await service.setManualFolder(fileKey, fileMeta.movie);
  });

  group('artwork inheritance from a folder', () {
    test('a file with no override of its own shows the folder artwork',
        () async {
      await override(folderKey, ArtworkKind.backdrop, '/chosen.jpg');

      final inherited = TmdService.instance
          .metaFor(fileKey, inheritArtworkFrom: folderKey);
      expect(inherited!.movie.backdropPath, '/chosen.jpg');
      // Its own poster is untouched — nothing was overridden on the file.
      expect(inherited.movie.posterPath, '/x-poster.jpg');
    });

    test("the file's own override always wins", () async {
      await override(folderKey, ArtworkKind.backdrop, '/folder-chosen.jpg');
      await override(fileKey, ArtworkKind.backdrop, '/file-chosen.jpg');

      final meta =
          TmdService.instance.metaFor(fileKey, inheritArtworkFrom: folderKey);
      expect(meta!.movie.backdropPath, '/file-chosen.jpg');
    });

    test('inheritance is per kind, not all-or-nothing', () async {
      await override(folderKey, ArtworkKind.poster, '/folder-poster.jpg');
      await override(fileKey, ArtworkKind.backdrop, '/file-backdrop.jpg');

      final meta =
          TmdService.instance.metaFor(fileKey, inheritArtworkFrom: folderKey);
      expect(meta!.movie.posterPath, '/folder-poster.jpg');
      expect(meta.movie.backdropPath, '/file-backdrop.jpg');
    });

    test('inheritance is one-way: a folder never picks up a file override',
        () async {
      await override(fileKey, ArtworkKind.backdrop, '/file-chosen.jpg');

      // The home card reads its own key with no fallback at all.
      final folderRead = TmdService.instance.metaFor(folderKey);
      expect(folderRead!.movie.backdropPath, '/f-backdrop.jpg');
    });

    test('no fallback behaves exactly as before', () async {
      await override(folderKey, ArtworkKind.backdrop, '/folder-chosen.jpg');

      final meta = TmdService.instance.metaFor(fileKey);
      expect(meta!.movie.backdropPath, '/x-backdrop.jpg');
    });

    test('a folder with no override leaves the file untouched', () async {
      final meta =
          TmdService.instance.metaFor(fileKey, inheritArtworkFrom: folderKey);
      expect(meta!.movie.backdropPath, '/x-backdrop.jpg');
      expect(meta.movie.posterPath, '/x-poster.jpg');
    });

    test('the folder itself is unaffected by inheritance in the other direction',
        () async {
      await override(folderKey, ArtworkKind.poster, '/folder-poster.jpg');
      // Reading the file must not mutate the folder's entry.
      TmdService.instance.metaFor(fileKey, inheritArtworkFrom: folderKey);
      expect(TmdService.instance.metaFor(folderKey)!.movie.posterPath,
          '/folder-poster.jpg');
    });

    test('the two surfaces really do key on different identities', () {
      // Why this happens at all: the home card keys on the library folder,
      // continue watching on the file's resumeKey.
      final video = VideoItem(
        id: 'v1',
        title: 'Avengers',
        path: null,
        resumeKey: fileKey,
        duration: Duration.zero,
      );
      expect(TmdStore.identityKeyFor(video), fileKey);
      expect(TmdStore.identityKeyFor(video), isNot(folderKey));
    });
  });
}