import 'dart:convert';

import 'package:dream_player/screens/library_search_screen.dart';
import 'package:dream_player/widgets/library_list_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helper.dart';

Map<String, dynamic> _folder({
  required String id,
  required String name,
  required String path,
  bool isFile = false,
  String? parentId,
  String? videoPath,
  int addedAtMs = 1000,
}) => {
  'id': id,
  'name': name,
  'path': path,
  'addedAtMs': addedAtMs,
  'source': 'files',
  if (isFile) 'isFile': true,
  'parentId': ?parentId,
  'videoPath': ?videoPath,
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'dreamplayer.libraryFolders': jsonEncode([
        _folder(id: 'show', name: 'Dark.S01', path: '/tv/Dark.S01'),
        _folder(
          id: 'ep',
          name: 'Dark.S01E05.mkv',
          path: '/tv/Dark.S01/Dark.S01E05.mkv',
          isFile: true,
          parentId: 'show',
          videoPath: '/tv/Dark.S01/Dark.S01E05.mkv',
          addedAtMs: 1001,
        ),
        _folder(id: 'dune', name: 'Dune', path: '/movies/Dune'),
      ]),
    });
  });

  Future<void> pumpSearch(WidgetTester tester) async {
    await tester.pumpWidget(localizedApp(const LibrarySearchScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('shows a prompt until the user types', (tester) async {
    await pumpSearch(tester);

    expect(find.byType(LibraryListRow), findsNothing);
    expect(find.textContaining('Search your library'), findsWidgets);
  });

  testWidgets('finds the show folder and its episode file', (tester) async {
    await pumpSearch(tester);

    await tester.enterText(find.byType(TextField), 'dark');
    await tester.pumpAndSettle();

    // One row for the show folder, one for the file entry it contains -
    // the search works on what Home already renders, offline.
    expect(find.byType(LibraryListRow), findsNWidgets(2));
    expect(find.textContaining('Dune'), findsNothing);
  });

  testWidgets('movie folders match too', (tester) async {
    await pumpSearch(tester);

    await tester.enterText(find.byType(TextField), 'dune');
    await tester.pumpAndSettle();

    expect(find.byType(LibraryListRow), findsOneWidget);
    expect(find.textContaining('Dune'), findsWidgets);
  });

  testWidgets('accented titles match an unaccented query', (tester) async {
    SharedPreferences.setMockInitialValues({
      'dreamplayer.libraryFolders': jsonEncode([
        _folder(id: 'a', name: 'Amélie', path: '/movies/Amelie'),
      ]),
    });
    await pumpSearch(tester);

    await tester.enterText(find.byType(TextField), 'amelie');
    await tester.pumpAndSettle();

    expect(find.byType(LibraryListRow), findsOneWidget);
  });

  testWidgets('an unmatched query shows the empty state', (tester) async {
    await pumpSearch(tester);

    await tester.enterText(find.byType(TextField), 'zzzzz');
    await tester.pumpAndSettle();

    expect(find.byType(LibraryListRow), findsNothing);
    expect(
      find.textContaining('Nothing in your library matches'),
      findsOneWidget,
    );
  });
}
