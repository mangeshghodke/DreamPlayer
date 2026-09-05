import 'package:dream_player/services/library_folders.dart';
import 'package:dream_player/services/series_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

LibraryFolder _folder(String name,
    {LibraryFolderSource source = LibraryFolderSource.files,
    DateTime? addedAt,
    String id = ''}) {
  return LibraryFolder(
    id: id.isEmpty ? name : id,
    name: name,
    path: '/storage/emulated/0/$name',
    addedAt: addedAt ?? DateTime(2026, 9, 5),
    source: source,
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
