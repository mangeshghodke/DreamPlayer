import 'package:dream_player/screens/series_seasons_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// The season-level artwork cascade (issue #33). Season rows used to resolve the
/// GROUP's metadata key, so a pick made on any season rewrote every season and
/// the parent too — including a season's change altering the parent, which is
/// impossible with genuinely separate keys.
void main() {
  const show = 'folder:show';
  const s1 = 'folder:season1';
  const s2 = 'folder:season2';

  final folders = <({int? season, String key})>[
    (season: 1, key: s1),
    (season: 2, key: s2),
  ];

  group('seasonFolderKey', () {
    test('each season gets its own key, never the group key', () {
      expect(seasonFolderKey(1, folders, show), s1);
      expect(seasonFolderKey(2, folders, show), s2);
      expect(seasonFolderKey(1, folders, show), isNot(show));
    });

    test('two seasons never resolve to the same key', () {
      expect(seasonFolderKey(1, folders, show),
          isNot(seasonFolderKey(2, folders, show)));
    });

    test('a season with no folder falls back to null (show default shows)', () {
      expect(seasonFolderKey(3, folders, show), isNull);
    });

    test('a season folder sharing the group key is ignored', () {
      // A season whose key is the show's is the cascade case; it must not be
      // offered as an independent target or it would share the show's override.
      final only = <({int? season, String key})>[(season: 1, key: show)];
      expect(seasonFolderKey(1, only, show), isNull);
    });

    test('an empty key is ignored', () {
      final withBlank = <({int? season, String key})>[
        (season: 1, key: ''),
        (season: 1, key: s1),
      ];
      expect(seasonFolderKey(1, withBlank, show), s1);
    });

    test('a season with a null folderSeason never matches', () {
      final loose = <({int? season, String key})>[(season: null, key: s1)];
      expect(seasonFolderKey(1, loose, show), isNull);
    });

    test('no folders at all is null, not a crash', () {
      expect(seasonFolderKey(1, const [], show), isNull);
    });
  });
}
