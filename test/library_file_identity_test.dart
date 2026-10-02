import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/library_folders.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A library FILE entry's metadata identity has to be the same string the
/// resolved VideoItem carries as its resume key.
///
/// Keying it `folder:<id>` instead gave one film several separate slots — the
/// home card, the SMB browser's details page and Continue Watching each had their
/// own — so a poster picked in one place never appeared in another. The home card
/// and Continue Watching looked synced only because resume is stored against the
/// resumeKey, which is one string both of them shared.
void main() {
  const resumeKey = 'smb:server1/Downloads/Video/Movies/Avengers.mkv';

  LibraryFolder fileEntry() => LibraryFolder(
        id: 'smb_server1_9f2ab',
        name: 'Avengers.mkv',
        path: resumeKey,
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
        source: LibraryFolderSource.smb,
        networkServerId: 'server1',
        networkShare: 'Downloads',
        networkPath: 'Video/Movies/Avengers.mkv',
        isFile: true,
      );

  LibraryFolder folderEntry() => LibraryFolder(
        id: 'smb_server1_77c1',
        name: 'Movies',
        path: 'smb:server1/Downloads/Video/Movies',
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
        source: LibraryFolderSource.smb,
        networkServerId: 'server1',
        networkShare: 'Downloads',
        networkPath: 'Video/Movies',
      );

  final video = VideoItem(
    id: 'v1',
    title: 'Avengers.mkv',
    path: null,
    resumeKey: resumeKey,
    duration: Duration.zero,
  );

  group('LibraryFolder.metadataKey', () {
    test('a file entry keys on the resume key the video carries', () {
      expect(fileEntry().metadataKey, resumeKey);
      expect(fileEntry().metadataKey, TmdStore.identityKeyFor(video));
    });

    test('so the home card and continue watching are one slot', () {
      // The bug: these were different strings, hence two override slots.
      expect(fileEntry().metadataKey, isNot('folder:${fileEntry().id}'));
      expect(fileEntry().metadataKey, TmdStore.identityKeyFor(video));
    });

    test('a folder entry keeps folder:<id>', () {
      final f = folderEntry();
      expect(f.metadataKey, 'folder:${f.id}');
    });

    test('a folder and a file never collide', () {
      expect(folderEntry().metadataKey, isNot(fileEntry().metadataKey));
    });

    test('a local file entry keys on its absolute path', () {
      const local = '/storage/emulated/0/Movies/dune.mkv';
      final entry = LibraryFolder(
        id: 'local_1',
        name: 'dune.mkv',
        path: local,
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
        isFile: true,
      );
      expect(entry.metadataKey, local);
      expect(
        entry.metadataKey,
        TmdStore.identityKeyFor(VideoItem(
          id: 'v2',
          title: 'dune.mkv',
          path: local,
          duration: Duration.zero,
        )),
      );
    });

    test('identity survives a json round-trip', () {
      final entry = fileEntry();
      final back = LibraryFolder.fromJson(entry.toJson());
      expect(back.metadataKey, entry.metadataKey);
      expect(back.isFile, isTrue);
    });
  });
}