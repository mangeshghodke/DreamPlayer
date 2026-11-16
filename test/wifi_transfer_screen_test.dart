import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the WiFi file transfer page wiring: the home "+" row, the page's
/// toggle + short address + live progress rows, the removal of the old
/// Settings toggle (one home for the feature), the shared event channel, and
/// both native servers serving the same short, token-free path.
void main() {
  final screen =
      File('lib/screens/wifi_transfer_screen.dart').readAsStringSync();
  final home = File('lib/screens/home_screen.dart').readAsStringSync();
  final settings =
      File('lib/screens/settings_screen.dart').readAsStringSync();
  final service =
      File('lib/services/wifi_upload.dart').readAsStringSync();
  final kotlin = File(
    'android/app/src/main/kotlin/com/dreamplayer/app/UploadServer.kt',
  ).readAsStringSync();
  final swift =
      File('ios/Runner/UploadServer.swift').readAsStringSync();
  final manager =
      File('lib/services/download_manager.dart').readAsStringSync();
  final browser =
      File('lib/services/file_browser.dart').readAsStringSync();
  final ktBrowser = File(
    'android/app/src/main/kotlin/com/dreamplayer/app/FileBrowser.kt',
  ).readAsStringSync();
  final swiftBrowser =
      File('ios/Runner/FileBrowser.swift').readAsStringSync();

  String codeOf(String text) => text
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');

  group('home + menu', () {
    test('the menu offers WiFi file transfer', () {
      expect(home, contains("'WiFi file transfer'"));
      expect(home, contains("pop('wifi-transfer')"));
      expect(home, contains("case 'wifi-transfer':"));
      expect(home, contains('const WifiTransferScreen()'));
    });
  });

  group('the transfer page', () {
    test('offers an optional page password', () {
      expect(screen, contains('Username'));
      expect(screen, contains('Password'));
      expect(service, contains('setCredentials'));
      expect(service, contains('hasCredentials'));
    });

    test('has fields that save as you type (no Save button)', () {
      expect(codeOf(screen), contains('Username *'));
      expect(codeOf(screen), contains('Password *'));
      expect(codeOf(screen), contains('Port (optional)'));
      expect(codeOf(screen).contains('_onFieldChanged()'), isTrue);
    });

    test('Start service / Stop service button, no toggle', () {
      expect(codeOf(screen), contains('Start service'));
      expect(codeOf(screen), contains('Stop service'));
      expect(codeOf(screen).contains('SwitchListTile('), isFalse);
      expect(codeOf(screen).contains('onChanged: _setEnabled'), isFalse);
    });

    test('shows the short address with a copy action', () {
      expect(screen, contains('SelectableText('));
      expect(screen, contains('_copyUrl(url)'));
      // No token path anywhere in the visible URL.
      expect(screen.contains('/u/'), isFalse);
    });

    test('lists live transfers with progress bars', () {
      expect(codeOf(screen), contains('LinearProgressIndicator('));
      expect(codeOf(screen), contains('_UploadRow('));
      expect(codeOf(screen), contains('item: item)'));
      expect(codeOf(screen), contains('WifiUploadStatus.done'));
      expect(codeOf(screen), contains('WifiUploadStatus.failed'));
    });

    test('a completed transfer shows a green check, not the accent dot', () {
      final rowStart = codeOf(screen).indexOf('class _UploadRow');
      final row = codeOf(screen).substring(rowStart);
      // done branch: green check circle (same convention as watched marks and
      // the Downloads screen), plus a green progress bar.
      expect(row, contains('Icons.check_circle'));
      expect(row, contains('Colors.green.shade400'));
      // the dot container must only exist in the non-done branch: the done
      // ternary returns the check icon before the Container is built.
      final doneIdx = row.indexOf('done');
      final dotIdx = row.indexOf('BoxShape.circle');
      expect(doneIdx >= 0 && dotIdx > doneIdx, isTrue);
    });

    test('subscribes to the native progress events and refreshes on open', () {
      expect(screen, contains('subscribeEvents()'));
      expect(screen, contains('unsubscribeEvents()'));
      expect(screen, contains('refresh()'));
    });
  });

  group('one home for the feature', () {
    test('the old Settings toggle is gone', () {
      expect(settings.contains('WiFi upload to this device'), isFalse);
      expect(settings.contains('WifiUploadService'), isFalse);
    });
  });

  group('service', () {
    test('listens on the shared event channel', () {
      expect(service, contains("EventChannel('dreamplayer/upload_events')"));
      expect(service, contains('_onNativeEvent'));
    });

    test('a finished upload is registered in DownloadManager', () {
      // The file already lands in the download directory; registering it is
      // what makes it show up in the home "Downloaded" grid.
      expect(service, contains('registerUploadedFile('));
      expect(manager, contains('registerUploadedFile('));
      expect(manager, contains("'upload'"));
    });
  });

  group('native servers serve the short path with progress', () {
    for (final entry in {'kotlin': kotlin, 'swift': swift}.entries) {
      test('${entry.key} uses /wifi-transfer/ and no token mechanism', () {
        expect(entry.value, contains('/wifi-transfer/'));
        // The word "token" appears in the doc comments ("token-free"), so
        // assert on the mechanism instead: no token variable, no /u/ route.
        expect(entry.value.contains('var token'), isFalse);
        expect(entry.value.contains('let t = token'), isFalse);
        expect(entry.value.contains('/u/'), isFalse);
      });

      test('${entry.key} pushes start/progress/done events', () {
        expect(entry.value, contains('"start"'));
        expect(entry.value, contains('"progress"'));
        expect(entry.value, contains('"done"'));
        expect(entry.value, contains('dreamplayer/upload_events'));
      });

      test('${entry.key} sends the file path with the done event', () {
        expect(
          entry.value.contains('"path"') ||
              entry.value.contains('"path": file.path'),
          isTrue,
        );
      });

      test('${entry.key} enforces HTTP Basic auth when credentials are set', () {
        expect(entry.value, contains('WWW-Authenticate'));
        expect(entry.value, contains('Basic realm'));
        expect(
          entry.value.contains('authorization') ||
              entry.value.contains('Authorization'),
          isTrue,
        );
      });

      test('${entry.key} serves the cancel endpoint', () {
        expect(entry.value, contains('/cancel'));
        expect(entry.value, contains('"cancelled"'));
      });
    }

    test('kotlin hops progress events to the main thread', () {
      expect(kotlin, contains('Looper.getMainLooper()'));
    });

    test('kotlin serves the download-from-device endpoints', () {
      expect(kotlin, contains('/files'));
      expect(kotlin, contains('/file?name'));
      expect(kotlin, contains('streamSharedFile'));
      expect(kotlin, contains('application/octet-stream'));
    });

    test('swift serves the download-from-device endpoints', () {
      expect(swift, contains('/files'));
      expect(swift, contains('/file?name'));
      expect(swift, contains('streamSharedFile'));
      expect(swift, contains('application/octet-stream'));
    });

    test('both servers render the shared files as a folder tree', () {
      // A picked folder arrives as "Photos/a.jpg" paths: the page groups them
      // into one expandable folder entry instead of a flat list.
      expect(kotlin, contains('buildTree'));
      expect(kotlin, contains('countFiles'));
      expect(kotlin, contains('deviceFilesCard'));
      expect(swift, contains('buildTree'));
      expect(swift, contains('countFiles'));
      expect(swift, contains('deviceFilesCard'));
      // Expanded by default - sending a folder means seeing its contents.
      expect(kotlin.contains("body.style.display = 'block'"), isTrue);
      expect(swift.contains("body.style.display = 'block'"), isTrue);
      // The 3s poll must not rebuild an unchanged list, or the folder the
      // user just opened collapses under them.
      expect(kotlin.contains('lastSharedSig'), isTrue);
      expect(swift.contains('lastSharedSig'), isTrue);
    });

    test('both servers embed credentials in the download URL', () {
      // External download managers don't carry the browser's Basic-auth
      // cache, so the credentials ride in the URL userinfo.
      expect(
        kotlin.contains(r"location.protocol + '//' + '$authInfo'"),
        isTrue,
      );
      expect(
        swift.contains(r"location.protocol + '//' + '\(authInfo)'"),
        isTrue,
      );
    });
  });

  group('send files + send folder to the computer', () {
    test('the page offers both buttons while running', () {
      expect(screen, contains('Send files'));
      expect(screen, contains('Send folder'));
      expect(screen, contains('_sendFilesToComputer'));
      expect(screen, contains('_sendFolderToComputer'));
      // Both are gated on the server running.
      expect(screen.contains('running && !_picking'), isTrue);
    });

    test('the page lists what is shared with the computer', () {
      expect(screen, contains('_service.sharedFiles.isNotEmpty'));
      expect(screen, contains('_SharedFileRow('));
      expect(screen, contains('formatUploadBytes(file.size)'));
    });

    test('the service registers shared files over the channel', () {
      expect(service, contains("'shareFiles'"));
      expect(service.contains("'clearSharedFiles'"), isTrue);
      expect(service, contains('List<SharedFile> get sharedFiles'));
      // Files are NOT copied in Dart - the list is just handed to native.
      expect(service.contains('File(path)'), isFalse);
      expect(service.contains('.copy('), isFalse);
    });

    test('the dart wrapper exposes both pickers', () {
      expect(browser.contains('Future<List<Map<String, dynamic>>> pickFiles()'), isTrue);
      expect(browser.contains('Future<List<Map<String, dynamic>>> pickFolderContents()'), isTrue);
    });

    test('android walks the picked folder tree, no copy', () {
      expect(ktBrowser, contains('"pickFiles"'));
      expect(ktBrowser, contains('"pickFolderContents"'));
      expect(ktBrowser, contains('walkTree'));
      expect(ktBrowser, contains('EXTRA_ALLOW_MULTIPLE'));
      expect(ktBrowser, contains('REQ_PICK_FOLDER_CONTENTS'));
      expect(ktBrowser, contains('MIME_TYPE_DIR'));
      // The picked folder's own name prefixes every path, or the PC page
      // renders the folder's files as a flat list with no folder entry.
      expect(ktBrowser.contains('rootName'), isTrue);
      expect(ktBrowser.contains(r'"$rootName/"'), isTrue);
    });

    test('ios prefixes the picked folder name on every file', () {
      // Same contract as Android: "Folder/relative/path" names.
      expect(swiftBrowser.contains('let folderName = url.lastPathComponent'), isTrue);
      expect(swiftBrowser.contains('"name": "\\(folderName)/\\(rel)"'), isTrue);
    });

    test('ios multi-selects both files and a folder', () {
      expect(swiftBrowser, contains('"pickFiles"'));
      expect(swiftBrowser, contains('"pickFolderContents"'));
      expect(swiftBrowser, contains('allowsMultipleSelection = true'));
      expect(swiftBrowser, contains('.folder'));
    });
  });
}
