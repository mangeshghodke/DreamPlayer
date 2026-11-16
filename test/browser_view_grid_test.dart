import 'package:dream_player/screens/smb_screen.dart';
import 'package:dream_player/services/browser_view_store.dart';
import 'package:dream_player/widgets/browser_entry_card.dart';
import 'package:dream_player/widgets/browser_view_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helper.dart';

/// The network browsers got a Windows 11 style "View and more" (the three-dot
/// at the top right) with **View -> List / Grid**.
///
/// These tests pin the two halves of that:
///
///  * the shared menu opens the chooser and the choice is applied + persisted;
///  * the SMB browser really renders the grid (folders AND files) once Grid is
///    picked - a menu that works but is never wired to a browser would look
///    finished and change nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('three-dot -> View -> Grid switches the view', (tester) async {
    await BrowserViewStore.load();
    await tester.pumpWidget(localizedApp(
      Scaffold(
        appBar: AppBar(actions: const [BrowserViewMenu()]),
        body: ListenableBuilder(
          listenable: BrowserViewStore.instance,
          builder: (context, _) => BrowserViewStore.instance.isGrid
              ? BrowserEntryGrid(
                  itemCount: 3,
                  itemBuilder: (context, index) =>
                      BrowserEntryCard(title: 'Entry $index'),
                )
              : ListView.builder(
                  itemCount: 3,
                  itemBuilder: (context, index) =>
                      ListTile(title: Text('Entry $index')),
                ),
        ),
      ),
    ));

    expect(find.byType(GridView), findsNothing);
    expect(find.text('Entry 0'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('View'), findsOneWidget);

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(find.text('List'), findsOneWidget);
    expect(find.text('Grid'), findsOneWidget);

    await tester.tap(find.text('Grid'));
    await tester.pumpAndSettle();

    expect(BrowserViewStore.instance.mode, BrowserViewMode.grid);
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(BrowserEntryCard), findsNWidgets(3));
  });

  testWidgets('the choice survives a restart', (tester) async {
    await BrowserViewStore.load();
    await BrowserViewStore.instance.setMode(BrowserViewMode.grid);

    await BrowserViewStore.load();
    expect(BrowserViewStore.instance.mode, BrowserViewMode.grid);
  });

  group('SMB browser', () {
    const channel = MethodChannel('dreamplayer/smb');

    Map<String, Object?> server() => {
          'id': 'server-1',
          'name': 'NAS',
          'host': '192.168.1.16',
          'port': 445,
          'username': 'mangesh',
          'domain': '',
          'anonymous': false,
          'hasPassword': true,
        };

    Map<String, Object?> shareEntry() => {
          'name': 'downloads',
          'path': 'downloads',
          'isDirectory': true,
          'size': 0,
          'modified': 0,
        };

    Map<String, Object?> folderEntry() => {
          'name': 'Movies',
          'path': 'downloads/Movies',
          'isDirectory': true,
          'size': 0,
          'modified': 0,
        };

    Map<String, Object?> fileEntry() => {
          'name': 'Big Buck Bunny.mkv',
          'path': 'downloads/Big Buck Bunny.mkv',
          'isDirectory': false,
          'size': 1024 * 1024 * 42,
          'modified': 0,
        };

    Future<void> pumpFolder(WidgetTester tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'listServers':
            return [server()];
          case 'checkServer':
            return true;
          case 'listShares':
            return [shareEntry()];
          case 'listDirectory':
            return [folderEntry(), fileEntry()];
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await BrowserViewStore.load();
      await tester.pumpWidget(localizedApp(const SmbScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('NAS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('downloads'));
      await tester.pumpAndSettle();
    }

    testWidgets('the three-dot appears as soon as a server is picked',
        (tester) async {
      await pumpFolder(tester);

      expect(find.byType(BrowserViewMenu), findsOneWidget);
      expect(find.text('Movies'), findsOneWidget);
      expect(find.textContaining('Big Buck Bunny'), findsWidgets);
    });

    testWidgets('the three-dot is already on the shares list', (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'listServers':
            return [server()];
          case 'checkServer':
            return true;
          case 'listShares':
            return [shareEntry()];
          case 'listDirectory':
            return [folderEntry(), fileEntry()];
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await BrowserViewStore.load();
      await tester.pumpWidget(localizedApp(const SmbScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('NAS'));
      await tester.pumpAndSettle();

      // The shares list is an entry list, so the view switch belongs here -
      // not only after a share has been opened.
      expect(find.byType(BrowserViewMenu), findsOneWidget);
      expect(find.text('downloads'), findsOneWidget);
    });

    testWidgets('Grid shows folders AND files as tiles', (tester) async {
      await pumpFolder(tester);

      await tester.tap(find.byType(BrowserViewMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grid'));
      await tester.pumpAndSettle();

      expect(BrowserViewStore.instance.isGrid, isTrue);
      expect(find.byType(GridView), findsOneWidget);
      // One tile per entry: the folder AND the file.
      expect(find.byType(BrowserEntryCard), findsNWidgets(2));
      expect(find.text('Movies'), findsOneWidget);
      expect(find.textContaining('Big Buck Bunny'), findsWidgets);
      // A folder is a folder tile, not a blank one.
      expect(find.byIcon(Icons.folder), findsOneWidget);
    });
  });
}
