import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/models/library_video.dart';
import 'package:dream_player/screens/home_screen.dart';
import 'package:dream_player/services/library_folders.dart';

LibraryVideo v(String path) => LibraryVideo(
      id: path.hashCode,
      path: path,
      title: path.split('/').last,
    );

LibraryFolder folder(String path) => LibraryFolder(
      id: path.hashCode.toString(),
      name: path.split('/').last,
      path: path,
      addedAt: DateTime(2026),
    );

void main() {
  group('otherVideosExcludingLibrary', () {
    test('keeps device videos outside the library', () {
      final result = otherVideosExcludingLibrary(
        [
          v('/storage/emulated/0/DCIM/Camera/VID_20260101.mp4'),
          v('/storage/emulated/0/Download/clip.mp4'),
        ],
        [folder('/storage/emulated/0/Movies')],
      );
      expect(result.map((e) => e.path), [
        '/storage/emulated/0/DCIM/Camera/VID_20260101.mp4',
        '/storage/emulated/0/Download/clip.mp4',
      ]);
    });

    test('excludes files at or under a library folder', () {
      final result = otherVideosExcludingLibrary(
        [
          v('/storage/emulated/0/Movies/Interstellar.mkv'),
          v('/storage/emulated/0/Movies/Harry Potter/Sorcerers.mkv'),
          v('/storage/emulated/0/Download/clip.mp4'),
        ],
        [folder('/storage/emulated/0/Movies')],
      );
      expect(result.map((e) => e.path), [
        '/storage/emulated/0/Download/clip.mp4',
      ]);
    });

    test('does not prefix-match a sibling folder with a shared name', () {
      // "/Movies" must not swallow "/MoviesArchive" — a classic bug when
      // comparing with a bare startsWith.
      final result = otherVideosExcludingLibrary(
        [
          v('/storage/emulated/0/MoviesArchive/old.mkv'),
          v('/storage/emulated/0/Movies/real.mkv'),
        ],
        [folder('/storage/emulated/0/Movies')],
      );
      expect(result.map((e) => e.path), [
        '/storage/emulated/0/MoviesArchive/old.mkv',
      ]);
    });

    test('tolerates trailing slashes on library roots', () {
      // SMB/WebDAV listings return "Folder/".
      final result = otherVideosExcludingLibrary(
        [
          v('/storage/emulated/0/Movies/Interstellar.mkv'),
          v('/storage/emulated/0/Other/clip.mp4'),
        ],
        [folder('/storage/emulated/0/Movies/')],
      );
      expect(result.map((e) => e.path), [
        '/storage/emulated/0/Other/clip.mp4',
      ]);
    });

    test('shows everything when the library is empty', () {
      final scanned = [v('/a/one.mp4'), v('/a/two.mp4')];
      expect(
        otherVideosExcludingLibrary(scanned, const []).length,
        scanned.length,
      );
    });

    test('drops entries with an empty path', () {
      final result = otherVideosExcludingLibrary(
        [v('   '), v('/a/keep.mp4')],
        const [],
      );
      expect(result.map((e) => e.path), ['/a/keep.mp4']);
    });
  });

  group('LibraryVideo.toVideoItem', () {
    test('produces a playable local item keyed on its path', () {
      final item = v('/storage/emulated/0/Download/clip.mp4').toVideoItem();
      expect(item.path, '/storage/emulated/0/Download/clip.mp4');
      expect(item.uri, isNull, reason: 'MediaStore rows are plain local files');
      expect(item.resumeKey, '/storage/emulated/0/Download/clip.mp4');
    });

    test('carries resolution and duration through', () {
      final item = const LibraryVideo(
        id: 7,
        path: '/a/b.mkv',
        title: 'b',
        duration: 125000,
        width: 3840,
        height: 2160,
      ).toVideoItem();
      expect(item.resolution, '3840x2160');
      expect(item.duration, const Duration(milliseconds: 125000));
    });
  });
}
