import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/library_folders.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:dream_player/utils/display_title.dart';

LibraryFolder folder(String name) => LibraryFolder(
      id: name.hashCode.toString(),
      name: name,
      path: '/storage/emulated/0/Movies/$name',
      addedAt: DateTime(2026),
    );

void main() {
  group('videoDisplayTitle', () {
    test('prefers the provider title over the filename', () {
      const meta = TmdMeta(
        movie: TmdMovie(id: 1, title: 'Interstellar', kind: TmdKind.movie),
      );
      const video = VideoItem(
        id: 'v',
        title: 'Interstellar.2014.IMAX.2160p.UHD.mkv',
        path: '/a/Interstellar.mkv',
        duration: Duration(minutes: 169),
      );
      expect(videoDisplayTitle(video, meta), 'Interstellar');
    });

    test('falls back to the filename when there is no match', () {
      const video = VideoItem(
        id: 'v',
        title: 'golmaal marathi video.mp4',
        path: '/a/x.mp4',
        duration: Duration.zero,
      );
      expect(videoDisplayTitle(video, null), 'golmaal marathi video.mp4');
      expect(
        videoDisplayTitle(
          video,
          const TmdMeta(movie: TmdMovie(id: 2, title: '')),
        ),
        'golmaal marathi video.mp4',
        reason: 'an empty provider title must not blank the label',
      );
    });
  });

  group('folderDisplayTitle', () {
    test('a manual group name wins over everything', () {
      const meta = TmdMeta(
        movie: TmdMovie(id: 1, title: 'Harry Potter', kind: TmdKind.tv),
      );
      expect(
        folderDisplayTitle(
          folder: folder('Harry Potter Series'),
          meta: meta,
          displayNameOverride: 'My Favourites',
        ),
        'My Favourites',
      );
    });

    test('a single season shows that season name', () {
      final meta = TmdMeta(
        movie: TmdMovie(id: 1, title: 'Strike the Blood', kind: TmdKind.tv),
        seasons: {
          2: TmdSeason(
            seasonNumber: 2,

            name: 'Strike the Blood II',
          ),
        },
        folderSeason: 2,
      );
      expect(
        folderDisplayTitle(folder: folder('Strike the Blood II'), meta: meta),
        'Strike the Blood II',
      );
    });

    test('falls back through provider, jellyfin, then folder name', () {
      const withMeta = TmdMeta(
        movie: TmdMovie(id: 1, title: 'Dune', kind: TmdKind.movie),
      );
      expect(
        folderDisplayTitle(
          folder: folder('Dune.2021.2160p'),
          meta: withMeta,
          jellyfinName: 'Jellyfin Dune',
        ),
        'Dune',
      );
      expect(
        folderDisplayTitle(
          folder: folder('Some Movie'),
          jellyfinName: 'Jellyfin Name',
        ),
        'Jellyfin Name',
      );
      expect(
        folderDisplayTitle(folder: folder('Raw Folder Name')),
        'Raw Folder Name',
      );
    });
  });
}
