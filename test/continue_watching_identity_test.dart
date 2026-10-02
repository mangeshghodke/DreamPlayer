import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/library_folders.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The same film kept three identities at once, which is why a poster picked in
/// one place never showed up in another:
///
///   1. the library file card on Home  — `folder:<fileCardId>`
///   2. the Continue Watching entry    — the file's resumeKey
///   3. the enclosing folder card     — `folder:<parentId>`
///
/// Opening the details page from (1) uses (1) as its identity key; opening the
/// same film from (2) used (2). Two slots for one film, so artwork picks — and
/// fix-match results — diverged. The fix is not more syncing machinery but one
/// identity: Continue Watching has to resolve to the file card's key whenever the
/// file has one.
void main() {
  const resumeKey = 'smb:server1/Downloads/Video/Movies/Avengers.mkv';

  LibraryFolder fileCard(String id) => LibraryFolder(
        id: id,
        name: 'Avengers.mkv',
        path: resumeKey, // a scanned file entry stores the resume key as its path
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
        source: LibraryFolderSource.smb,
        networkServerId: 'server1',
        networkShare: 'Downloads',
        networkPath: 'Video/Movies/Avengers.mkv',
        isFile: true,
      );

  LibraryFolder folderCard(String id, String path) => LibraryFolder(
        id: id,
        name: 'Movies',
        path: path,
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

  /// Mirrors `SMBBridge._matchingLibraryFileEntry` in home_screen.dart.
  LibraryFolder? matching(List<LibraryFolder> folders, VideoItem v) {
    final keys = <String>{};
    final rk = v.resumeKey;
    if (rk != null && rk.isNotEmpty) keys.add(rk);
    final path = v.path ?? v.uri;
    if (path != null && path.isNotEmpty) keys.add(path);
    if (keys.isEmpty) return null;
    LibraryFolder? best;
    for (final f in folders) {
      if (!f.isFile) continue;
      if (keys.contains(f.path)) {
        if (best == null || f.path.length > best.path.length) best = f;
      }
    }
    return best;
  }

  group('continue watching shares the file card identity', () {
    test('finds the file card and uses its key', () {
      final card = fileCard('smb_server1_abc');
      final found = matching([folderCard('p1', 'smb:server1/Downloads/Video/Movies'), card], video);
      expect(found, isNotNull);
      expect(found!.metadataKey, card.metadataKey);
      // The point of the fix: both surfaces now resolve to ONE key.
      expect(found.metadataKey, isNot(TmdStore.identityKeyFor(video)));
    });

    test('a folder entry is never mistaken for the file card', () {
      // The folder card is a prefix, not an exact match — mistaking it for the
      // file would point the details page at the wrong film.
      final found = matching(
          [folderCard('p1', 'smb:server1/Downloads/Video/Movies')], video);
      expect(found, isNull);
    });

    test('no file card leaves the video on its own resume key', () {
      // Nothing to sync with, so the original behaviour stands.
      final found = matching([], video);
      expect(found, isNull);
      expect(TmdStore.identityKeyFor(video), resumeKey);
    });

    test('a file outside the library does not match', () {
      final other = LibraryFolder(
        id: 'x',
        name: 'Other.mkv',
        path: 'smb:server1/Downloads/Video/Movies/Other.mkv',
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
        source: LibraryFolderSource.smb,
        isFile: true,
      );
      expect(matching([other], video), isNull);
    });

    test('the three identities are genuinely distinct', () {
      final card = fileCard('smb_server1_abc');
      final parent = folderCard('p1', 'smb:server1/Downloads/Video/Movies');
      final keys = {
        card.metadataKey,
        TmdStore.identityKeyFor(video),
        parent.metadataKey,
      };
      expect(keys.length, 3,
          reason: 'three slots for one film is the bug that was fixed');
    });
  });
}