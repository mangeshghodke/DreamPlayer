import 'package:dream_player/services/library_folders.dart';
import 'package:dream_player/services/series_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

LibraryFolder _folder(
  String name, {
  LibraryFolderSource source = LibraryFolderSource.files,
  DateTime? addedAt,
  String id = '',
  String? networkServerId,
  String? networkShare,
  String? jellyfinServerUrl,
  bool isFile = false,
}) {
  return LibraryFolder(
    id: id.isEmpty ? name : id,
    name: name,
    path: '/storage/emulated/0/$name',
    addedAt: addedAt ?? DateTime(2026, 9, 5),
    source: source,
    networkServerId: networkServerId,
    networkShare: networkShare,
    jellyfinServerUrl: jellyfinServerUrl,
    isFile: isFile,
  );
}

void main() {
  group('SeriesGroupingService.baseNameOf', () {
    test('bare series name stays intact', () {
      expect(SeriesGroupingService.baseNameOf('Strike the Blood'),
          'strike the blood');
    });

    test('roman numerals at the end are stripped', () {
      expect(SeriesGroupingService.baseNameOf('Strike the Blood II'),
          'strike the blood');
      expect(SeriesGroupingService.baseNameOf('Strike the Blood III'),
          'strike the blood');
      expect(SeriesGroupingService.baseNameOf('Strike the Blood IV'),
          'strike the blood');
      expect(SeriesGroupingService.baseNameOf('Strike the Blood V'),
          'strike the blood');
    });

    test('S02 / Season 2 tags are stripped', () {
      expect(SeriesGroupingService.baseNameOf('My.Show.S02.1080p'),
          'my show');
      expect(SeriesGroupingService.baseNameOf('My Show Season 2'),
          'my show');
      expect(SeriesGroupingService.baseNameOf('My Show Season02'),
          'my show');
      expect(SeriesGroupingService.baseNameOf('My Show S02E05'),
          'my show');
    });

    test('year in parens is stripped', () {
      expect(
          SeriesGroupingService.baseNameOf('Kakegurui Twin (2021) Live Action'),
          'kakegurui twin live action');
    });

    test('year at end is stripped', () {
      expect(SeriesGroupingService.baseNameOf('Kakegurui Twin 2021'),
          'kakegurui twin');
    });

    test('quality tags are stripped', () {
      expect(SeriesGroupingService.baseNameOf('My.Show.S02.1080p.BluRay.x265'),
          'my show');
    });

    test('punctuation is normalized to spaces', () {
      expect(SeriesGroupingService.baseNameOf('My.Show.Name'),
          'my show name');
      expect(SeriesGroupingService.baseNameOf('My-Show-Name'),
          'my show name');
      expect(SeriesGroupingService.baseNameOf('My_Show_Name'),
          'my show name');
    });

    test('whitespace is collapsed', () {
      expect(SeriesGroupingService.baseNameOf('My   Show    Name'),
          'my show name');
    });

    test('a title that is itself a roman numeral is NOT erased', () {
      // "VI" as the whole folder name should be preserved (no preceding
      // space → regex requires `(?:^|\s)` before).
      expect(SeriesGroupingService.baseNameOf('VI'), 'vi');
    });
  });

  group('SeriesGroupingService.groupExplicitSeasonFolders', () {
    test('groups explicit Komi season folders without changing folders', () {
      const service = SeriesGroupingService();
      final season1 = _folder(
        'Komi-san wa, Komyushou Desu. S1 [Ma10p_1080p]',
        id: 'komi-s1',
      );
      final season2 = _folder(
        'Komi-san wa, Komyushou Desu. S2 [Ma10p_1080p]',
        id: 'komi-s2',
      );

      final groups = service.groupExplicitSeasonFolders([season2, season1]);

      expect(groups, hasLength(1));
      expect(groups.single.folders, [season2, season1]);
      expect(groups.single.primary, same(season1));
      expect(groups.single.displayName, season1.name);
      expect(groups.single.metadataKey, season1.metadataKey);
    });

    test('groups scanner-style Season01 and Season02 folders', () {
      const service = SeriesGroupingService();
      final season1 = _folder('Komi-san Season01', id: 'komi-01');
      final season2 = _folder('Komi-san Season02', id: 'komi-02');

      final groups = service.groupExplicitSeasonFolders([season1, season2]);

      expect(groups, hasLength(1));
      expect(groups.single.folders, [season1, season2]);
      expect(groups.single.primary, same(season1));
    });

    test('keeps same title on different SMB servers separate', () {
      const service = SeriesGroupingService();
      final first = _folder(
        'Komi-san S1',
        id: 'server-a',
        source: LibraryFolderSource.smb,
        networkServerId: 'server-a',
        networkShare: 'media',
      );
      final second = _folder(
        'Komi-san S2',
        id: 'server-b',
        source: LibraryFolderSource.smb,
        networkServerId: 'server-b',
        networkShare: 'media',
      );

      final groups = service.groupExplicitSeasonFolders([first, second]);

      expect(groups, hasLength(2));
      expect(groups.every((g) => g.folders.length == 1), isTrue);
    });

    test('keeps Girls und Panzer movie parts as singleton groups', () {
      const service = SeriesGroupingService();
      final folders = [
        for (var i = 1; i <= 4; i++)
          _folder(
            '[VCB-Studio] GIRLS und PANZER das FINALE '
            '${i.toString().padLeft(2, '0')} [Ma10p_1080p]',
            id: 'gup-$i',
          ),
      ];

      final groups = service.groupExplicitSeasonFolders(folders);

      expect(groups, hasLength(4));
      expect(groups.every((g) => g.folders.length == 1), isTrue);
    });

    test('does not group bare series or movie part names', () {
      const service = SeriesGroupingService();
      final folders = [
        _folder('Komi-san wa, Komyushou Desu.'),
        _folder('Komi-san wa, Komyushou Desu. II'),
        _folder('Movie 01'),
        _folder('Movie 02'),
      ];

      final groups = service.groupExplicitSeasonFolders(folders);

      expect(groups, hasLength(4));
      expect(groups.every((g) => g.folders.length == 1), isTrue);
    });

    test('does not group file entries even when their names look seasonal', () {
      const service = SeriesGroupingService();
      final first = _folder('Komi-san S01E01.mkv', id: 'file-1', isFile: true);
      final second = _folder('Komi-san S01E02.mkv', id: 'file-2', isFile: true);

      final groups = service.groupExplicitSeasonFolders([first, second]);

      expect(groups, hasLength(2));
      expect(groups.every((g) => g.folders.length == 1), isTrue);
    });
  });

  group('SeriesGroupingService.group', () {
    test('Strike the Blood I-IV collapse into one group', () {
      final service = const SeriesGroupingService();
      final folders = [
        _folder('Strike the Blood'),
        _folder('Strike the Blood II'),
        _folder('Strike the Blood III'),
        _folder('Strike the Blood IV'),
      ];
      final groups = service.group(folders);
      expect(groups, hasLength(1));
      expect(groups.first.folders, hasLength(4));
      // display name is the shortest folder name = bare series name
      expect(groups.first.displayName, 'Strike the Blood');
    });

    test('full Strike the Blood set: bare + II + III + IV + Final + Kieta', () {
      final service = const SeriesGroupingService();
      final folders = [
        _folder('Strike the Blood'),
        _folder('Strike the Blood II'),
        _folder('Strike the Blood III'),
        _folder('Strike the Blood IV'),
        _folder('Strike the Blood Final'),
        _folder('Strike the Blood Kieta Seisou Hen'),
      ];
      final groups = service.group(folders);
      // All six collapse into one group: roman numerals + "Final" are
      // stripped by baseNameOf, and "Kieta Seisou Hen" merges via the
      // prefix fallback (shared 15 ≥ extra 15).
      expect(groups, hasLength(1));
      expect(groups.first.folders, hasLength(6));
      expect(groups.first.displayName, 'Strike the Blood');
    });

    test('different series stay in separate groups', () {
      final service = const SeriesGroupingService();
      final folders = [
        _folder('Kakegurui Twin'),
        _folder('Kakegurui'),
        _folder('Strike the Blood II'),
        _folder('Strike the Blood'),
      ];
      final groups = service.group(folders);
      expect(groups, hasLength(3));
    });

    test('Girls und Panzer movie parts remain separate', () {
      const service = SeriesGroupingService();
      final folders = [
        for (var i = 1; i <= 4; i++)
          _folder(
            '[VCB-Studio] GIRLS und PANZER das FINALE '
            '${i.toString().padLeft(2, '0')} [Ma10p_1080p]',
            id: 'gup-broad-$i',
          ),
      ];

      expect(service.group(folders), hasLength(4));
    });

    test('S02/S03 folders collapse into one group', () {
      final service = const SeriesGroupingService();
      final folders = [
        _folder('My.Show.S02.1080p.BluRay'),
        _folder('My.Show.S03.1080p.BluRay'),
      ];
      final groups = service.group(folders);
      expect(groups, hasLength(1));
      expect(groups.first.folders, hasLength(2));
    });

    test('Kakegurui Twin (2021) Live Action vs Kakegurui Twin are separate', () {
      final service = const SeriesGroupingService();
      final folders = [
        _folder('Kakegurui Twin (2021) Live Action'),
        _folder('Kakegurui Twin'),
      ];
      final groups = service.group(folders);
      expect(groups, hasLength(2));
    });

    test('empty input returns empty output', () {
      final service = const SeriesGroupingService();
      expect(service.group(const []), isEmpty);
    });

    test('groups are sorted newest-first', () {
      final service = const SeriesGroupingService();
      final folders = [
        _folder('Old Show', addedAt: DateTime(2026, 1, 1)),
        _folder('New Show', addedAt: DateTime(2026, 9, 5)),
        _folder('Mid Show', addedAt: DateTime(2026, 5, 1)),
      ];
      final groups = service.group(folders);
      expect(groups.first.displayName, 'New Show');
      expect(groups.last.displayName, 'Old Show');
    });

    test('display name is the shortest folder name in the group', () {
      final service = const SeriesGroupingService();
      final folders = [
        _folder('Strike the Blood II - 1080p BluRay'),
        _folder('Strike the Blood'),
        _folder('Strike the Blood III'),
      ];
      final groups = service.group(folders);
      expect(groups.first.displayName, 'Strike the Blood');
    });
  });
}
