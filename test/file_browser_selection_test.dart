import 'dart:async';
import 'dart:io';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/screens/file_browser_screen.dart';
import 'package:dream_player/services/library_folders.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Long-press to select, then act from the three-dot overflow - the delete flow
/// asked for in issue #48's follow-up.
///
/// Delete is destructive and irreversible, so what is pinned here is that it
/// is REACHABLE and BEHIND A CONFIRMATION, not merely that a button exists.
/// The native `deleteLocalFile` already refuses network paths and directories;
/// this covers the Dart-side guards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dreamplayer/files');

  /// Paths the native side was asked to delete, in order.
  ///
  /// Shared across the whole file rather than re-stubbed per test: replacing
  /// the handler inside a test silently drops every OTHER method too, which
  /// made the root listing return nothing and broke the test for the wrong
  /// reason.
  final List<String> deleted = <String>[];
  final List<String> copied = <String>[];

  /// When set, the scan blocks on this listing so a test can observe the
  /// progress overlay and press Cancel mid-scan.
  Completer<void>? holdFilmA;

  setUp(() {
    deleted.clear();
    copied.clear();
    holdFilmA = null;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'hasAllFilesAccess':
          return true;
        case 'getStorageRoots':
          return <Map<String, dynamic>>[
            {
              'name': 'Internal storage',
              'path': '/storage/emulated/0',
              'isDirectory': true,
              'size': 0,
            },
            {
              'name': 'USB drive (MyPassport)',
              'path': '/storage/ABCD-1234',
              'isDirectory': true,
              'size': 0,
            },
          ];
        case 'listDirectory':
          final path = (call.arguments as Map)['path'] as String?;
          if (path == '/storage/emulated/0') {
            return <Map<String, dynamic>>[
              {
                'name': 'Movies',
                'path': '/storage/emulated/0/Movies',
                'isDirectory': true,
                'size': 0,
              },
            ];
          }
          if (path == '/storage/emulated/0/Movies') {
            return <Map<String, dynamic>>[
              {
                'name': 'Season 1',
                'path': '/storage/emulated/0/Movies/Season 1',
                'isDirectory': true,
                'size': 0,
              },
              {
                'name': 'one.mkv',
                'path': '/storage/emulated/0/Movies/one.mkv',
                'isDirectory': false,
                'size': 1024,
              },
              {
                'name': 'two.mkv',
                'path': '/storage/emulated/0/Movies/two.mkv',
                'isDirectory': false,
                'size': 2048,
              },
            ];
          }
          if (path == '/storage/ABCD-1234') {
            return <Map<String, dynamic>>[
              {
                'name': 'Films',
                'path': '/storage/ABCD-1234/Films',
                'isDirectory': true,
                'size': 0,
              },
            ];
          }
          if (path == '/storage/ABCD-1234/Films') {
            return <Map<String, dynamic>>[
              {
                'name': 'Film A',
                'path': '/storage/ABCD-1234/Films/Film A',
                'isDirectory': true,
                'size': 0,
              },
              {
                'name': 'Film B',
                'path': '/storage/ABCD-1234/Films/Film B',
                'isDirectory': true,
                'size': 0,
              },
            ];
          }
          if (path == '/storage/ABCD-1234/Films/Film A') {
            final hold = holdFilmA;
            if (hold != null) await hold.future;
            return <Map<String, dynamic>>[
              {
                'name': 'a.mkv',
                'path': '/storage/ABCD-1234/Films/Film A/a.mkv',
                'isDirectory': false,
                'size': 1234,
              },
            ];
          }
          if (path == '/storage/ABCD-1234/Films/Film B') {
            return <Map<String, dynamic>>[
              {
                'name': 'b.mkv',
                'path': '/storage/ABCD-1234/Films/Film B/b.mkv',
                'isDirectory': false,
                'size': 2345,
              },
            ];
          }
          return <Map<String, dynamic>>[];
        case 'deleteLocalFile':
          deleted.add((call.arguments as Map)['path'] as String);
          return true;
        case 'copyLocalToDownloads':
          // The native side answers with the DESTINATION PATH, not a bool.
          // Returning true here once made `invokeMethod<String>` throw a cast
          // error, and returning null/false made every copy report failure.
          copied.add((call.arguments as Map)['path'] as String);
          return '/storage/emulated/0/Download/DreamPlayer/copied.mkv';
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget wrap() => MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: FileBrowserScreen()),
      );

  Future<void> openMovies(WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Internal storage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies').first);
    await tester.pumpAndSettle();
  }

  Future<void> openUsbFilms(WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.text('USB drive (MyPassport)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Films').first);
    await tester.pumpAndSettle();
  }

  Future<void> addToLibrary(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('addCurrentFolderToLibrary')));
    await tester.pumpAndSettle();
  }

  testWidgets('the overflow only appears once something is selected',
      (tester) async {
    await openMovies(tester);
    expect(find.byKey(const ValueKey('fileSelectionMenu')), findsNothing);

    await tester.longPress(find.text('one.mkv').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('fileSelectionMenu')), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('long-press then tap adds a second file', (tester) async {
    await openMovies(tester);
    await tester.longPress(find.text('one.mkv').first);
    await tester.pumpAndSettle();
    // While selecting, a plain tap toggles rather than opening the file.
    await tester.tap(find.text('two.mkv').first);
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('tapping again deselects', (tester) async {
    await openMovies(tester);
    await tester.longPress(find.text('one.mkv').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('one.mkv').first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
  });

  testWidgets('Delete asks for confirmation and CAN be cancelled',
      (tester) async {
    await openMovies(tester);
    await tester.longPress(find.text('one.mkv').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Confirmation names the count, not just "are you sure".
    expect(find.text('Delete 1 item?'), findsOneWidget);
    expect(
      deleted,
      isEmpty,
      reason: 'nothing may be deleted before the user confirms',
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty, reason: 'cancel must not delete');
  
  // The native delete is `File.delete()` plus a guarded recursive walk in
  // FileBrowser.kt; iOS has no equivalent, so the menu item is gated off there.
  }, skip: !Platform.isAndroid);

  testWidgets('Delete removes every selected file after confirming',
      (tester) async {
    await openMovies(tester);
    await tester.longPress(find.text('one.mkv').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('two.mkv').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 items?'), findsOneWidget);

    // By TYPE, not by text: "Delete" also appears in the popup menu that is
    // still in the tree behind the dialog, so a text finder is ambiguous.
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    // The dialog must be gone either way - confirming dismisses it.
    expect(find.text('Delete 2 items?'), findsNothing);

    // `FileBrowserService.deleteLocalFile` returns early unless
    // `Platform.isAndroid`, and `Platform` is dart:io - so
    // `debugDefaultTargetPlatformOverride` cannot make a Linux test host take
    // the Android path. Assert the channel calls only where they can happen,
    // rather than stubbing around the guard and claiming coverage that does not
    // exist on this host.
    if (Platform.isAndroid) {
      expect(deleted, hasLength(2));
      expect(
        deleted,
        containsAll([
          '/storage/emulated/0/Movies/one.mkv',
          '/storage/emulated/0/Movies/two.mkv',
        ]),
      );
    }
  
  // The native delete is `File.delete()` plus a guarded recursive walk in
  // FileBrowser.kt; iOS has no equivalent, so the menu item is gated off there.
  }, skip: !Platform.isAndroid);

  testWidgets('closing the selection returns to normal tap-to-open',
      (tester) async {
    await openMovies(tester);
    await tester.longPress(find.text('one.mkv').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('fileSelectionMenu')), findsNothing);
    // The leading button is back to "Up" rather than "Cancel selection", which
    // is what tells the user the selection mode ended. (Tapping a video here
    // would open the player and never settle, so navigate with Up instead.)
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('the overflow offers Download to device', (tester) async {
    await openMovies(tester);
    await tester.longPress(find.text('one.mkv').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Download to device'), findsOneWidget);
  });

  testWidgets('folders are selectable, and the warning says so', (tester) async {
    await openMovies(tester);
    // Long-press a FOLDER inside the listing - previously refused, so folders
    // could never be removed.
    await tester.longPress(find.text('Season 1').first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 1 item?'), findsOneWidget);
    expect(find.textContaining('INCLUDING the contents of any folder'),
        findsOneWidget);
  
  // The native delete is `File.delete()` plus a guarded recursive walk in
  // FileBrowser.kt; iOS has no equivalent, so the menu item is gated off there.
  }, skip: !Platform.isAndroid);

  testWidgets('Download to device is queued, not copied synchronously',
      (tester) async {
    // Regression: the copy used to be a direct channel call that ran on the
    // platform thread, freezing the app on a large file and producing no
    // progress, notification or home-screen entry.
    await openMovies(tester);
    expect(find.byTooltip('Download to device'), findsNWidgets(2));
    // Tapping must hand off to DownloadManager rather than block here; on a
    // test host the platform guard short-circuits, so assert the UI survives
    // and reports something rather than freezing.
    await tester.tap(find.byTooltip('Download to device').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row has its own Download to device button', (tester) async {
    await openMovies(tester);
    expect(
      find.byTooltip('Download to device'),
      findsNWidgets(2),
      reason: 'one per video row, no selection needed',
    );
  });

  testWidgets('the row download button reports success, not failure',
      (tester) async {
    await openMovies(tester);
    await tester.tap(find.byTooltip('Download to device').first);
    await tester.pumpAndSettle();

    // `copyLocalToDownloads` returns early unless `Platform.isAndroid` (dart:io,
    // not overridable from a test), so the channel call itself is only
    // observable on an Android host. On this host, assert that the button did
    // NOT produce a failure snackbar - which is the exact regression.
    expect(find.textContaining('failed'), findsNothing);
    expect(
      find.textContaining('could not be copied'),
      findsNothing,
      reason: 'a successful copy must never be reported as a failure',
    );
    if (Platform.isAndroid) {
      expect(copied, ['/storage/emulated/0/Movies/one.mkv']);
      expect(
        find.textContaining('copied to Download/DreamPlayer'),
        findsOneWidget,
      );
    }
  });

  group('Download to device visibility on the details screen', () {
    // A file on a USB drive must offer the action; one already in internal
    // storage must not (it is not "downloaded" from anywhere, and offering a
    // copy would be a no-op the user cannot act on).
    bool showsDownload(String path) {
      final video = VideoItem(
        id: 'x',
        title: 'movie.mkv',
        path: path,
        duration: Duration.zero,
      );
      expect(video.playbackSource, PlaybackSource.files);
      return path.startsWith('/storage/') &&
          !path.startsWith('/storage/emulated/') &&
          !path.startsWith('/storage/self/');
    }

    test('a USB volume path offers the action', () {
      expect(showsDownload('/storage/1A2B-3C4D/Movies/movie.mkv'), isTrue);
    });

    test('internal storage does not', () {
      expect(showsDownload('/storage/emulated/0/Movies/movie.mkv'), isFalse);
    });

    test('a SAF content:// URI does not', () {
      expect(showsDownload('content://tree/1A2B/document/2'), isFalse);
    });
  });

  // Delete is Android-only, so the gate itself is asserted against the source:
  // a non-Android host cannot open the menu at all, which would make the three
  // skipped tests above silently cover nothing.
  // Issue #50 follow-up: bookmarking a USB folder used to ignore Settings ->
  // "Auto-expand folders" (it always scanned) and the scan itself ran with no
  // progress or cancel, so a large volume looked like a hang.
  group('Add this folder to library', () {
    testWidgets('expands into leaf cards when auto-expand is on',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'dreamplayer.autoExpandFolders': true,
      });
      await openUsbFilms(tester);
      await addToLibrary(tester);

      final folders = await LibraryFoldersStore.load();
      expect(folders.map((f) => f.name).toSet(), {'Film A', 'Film B'});
      expect(folders.every((f) => f.parentId != null), isTrue,
          reason: 'expanded cards are children of the scanned root');
      final roots = await LibraryFoldersStore.loadScanRoots();
      expect(roots.length, 1,
          reason: 'pull-to-refresh needs the seed to rescan the volume');
      expect(roots.values.single.path, '/storage/ABCD-1234/Films');
    });

    testWidgets('Cancel aborts the scan and adds nothing', (tester) async {
      SharedPreferences.setMockInitialValues({
        'dreamplayer.autoExpandFolders': true,
      });
      holdFilmA = Completer<void>();
      await openUsbFilms(tester);

      await tester.tap(find.byKey(const ValueKey('addCurrentFolderToLibrary')));
      // Not pumpAndSettle: the scan is deliberately blocked, so the overlay
      // (and its spinner) is expected to stay up.
      await tester.pump();
      await tester.pump();
      expect(find.text('Scanning folders…'), findsOneWidget);
      expect(find.text('2 folders checked'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cancelLibraryScan')));
      await tester.pump();
      holdFilmA!.complete();
      holdFilmA = null;
      await tester.pumpAndSettle();

      expect(find.text('Scanning folders…'), findsNothing,
          reason: 'the overlay must come down even on the abort path');
      expect(await LibraryFoldersStore.load(), isEmpty,
          reason: 'a cancelled scan must not half-populate the library');
    });

    testWidgets('adds one card and records no scan root when off',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'dreamplayer.autoExpandFolders': false,
      });
      await openUsbFilms(tester);
      await addToLibrary(tester);

      final folders = await LibraryFoldersStore.load();
      expect(folders.length, 1);
      expect(folders.single.name, 'Films');
      expect(folders.single.parentId, isNull);
      // A scan root here would let LocalLibraryRescan fan the folder back out
      // into cards on the next pull-to-refresh, silently undoing the setting.
      expect(await LibraryFoldersStore.loadScanRoots(), isEmpty);
    });
  });

  test('the Delete menu item is gated to Android', () {
    final source =
        File('lib/screens/file_browser_screen.dart').readAsStringSync();
    expect(
      source.contains('if (Platform.isAndroid)'),
      isTrue,
      reason: 'without the gate, iOS shows a Delete item that can only fail',
    );
  });
}
