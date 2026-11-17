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
  final storeZip = File(
    'android/app/src/main/kotlin/com/dreamplayer/app/StoreZip.kt',
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

    test('both servers tag each send batch so it is received once', () {
      // runId identifies one server run, seq one send batch from the phone.
      // The page stores the pair, so a page reload does not re-download a
      // batch it already saved.
      expect(kotlin, contains('runId'));
      expect(kotlin, contains('sharedSeq'));
      expect(swift, contains('runId'));
      expect(swift, contains('sharedSeq'));
      // Bumped on every send.
      expect(kotlin.contains('sharedSeq += 1'), isTrue);
      expect(swift.contains('self.sharedSeq += 1'), isTrue);
    });

    test('a server restart gets a NEW runId - a re-send is never "already saved"', () {
      // The reported bug: runId was created once per process while
      // clearSharedFiles/stop reset the seq to 0, so after a restart or a
      // "Clear list" the next send carried the same runId with a seq the
      // page had already saved - and was skipped forever ("can only send
      // one time"). The id must be regenerated on every start, and the seq
      // must NOT be reset outside start.
      expect(kotlin.contains('runId = java.util.UUID.randomUUID().toString()'), isTrue);
      expect(swift.contains('self.runId = UUID().uuidString'), isTrue);
      // seq reset only inside start(), next to the new runId.
      expect(kotlin.contains('sharedSeq = 0'), isTrue);
      expect(swift.contains('self.sharedSeq = 0'), isTrue);
      // clearSharedFiles must not reset the seq under the same runId.
      final ktClear = RegExp(r'"clearSharedFiles" -> \{[^}]*\}');
      final swClear = RegExp(r'case "clearSharedFiles":[^=]*?result\(nil\)');
      expect(ktClear.firstMatch(kotlin)?.group(0) ?? '', isNot(contains('sharedSeq = 0')));
      expect(swClear.firstMatch(swift)?.group(0) ?? '', isNot(contains('sharedSeq = 0')));
    });

    test('a 401 shows a visible login warning instead of failing silently', () {
      // fetch() never raises the browser's native auth popup (only a
      // top-level navigation does), so after the password changes in the
      // app the poll gets a 401 - which used to be swallowed by .catch()
      // and the page just sat there. Now a banner is shown, and its
      // "Log in again" button reloads the page (which does raise the
      // popup).
      expect(kotlin, contains('id="authWarn"'));
      expect(swift, contains('id=\\"authWarn\\"'));
      expect(kotlin.contains('r.status === 401'), isTrue);
      expect(swift.contains('r.status === 401'), isTrue);
      expect(kotlin.contains('showAuthWarn(true)'), isTrue);
      expect(swift.contains('showAuthWarn(true)'), isTrue);
      expect(kotlin.contains('Log in again'), isTrue);
      expect(swift.contains('Log in again'), isTrue);
      expect(kotlin.contains('location.reload()'), isTrue);
      expect(swift.contains('location.reload()'), isTrue);
      // the file/zip fetch and the upload XHR surface it too
      expect(kotlin.contains('resp.status === 401'), isTrue);
      expect(swift.contains('resp.status === 401'), isTrue);
      expect(kotlin.contains('xhr.status === 401'), isTrue);
      expect(swift.contains('xhr.status === 401'), isTrue);
    });

    test('the poll and the downloads are never served from cache', () {
      // A cached /files response would hide a new batch forever (the page
      // would keep seeing the old seq); a cached zip would re-deliver stale
      // bytes. Both the fetch and every relevant response say no-store.
      expect(kotlin.contains("cache: 'no-store'"), isTrue);
      expect(swift.contains("cache: 'no-store'"), isTrue);
      expect(kotlin.contains('Cache-Control: no-store'), isTrue);
      expect(swift.contains('Cache-Control: no-store'), isTrue);
    });

    test('the /files response carries the batch identity', () {
      expect(kotlin.contains('obj.put("runId", runId)'), isTrue);
      expect(kotlin.contains('obj.put("seq", sharedSeq)'), isTrue);
      expect(kotlin.contains('obj.put("files", arr)'), isTrue);
      expect(swift.contains('"runId": runId'), isTrue);
      expect(swift.contains('"seq": seq'), isTrue);
      expect(swift.contains('"files": list'), isTrue);
    });

    test('the page receives the batch itself - nothing is a link', () {
      // A picked FOLDER arrives as "Folder/sub/file" names, so the page
      // walks that path back into real directories in the destination
      // folder instead of showing the user a tree to click through.
      expect(kotlin.contains('async function saveWithFs'), isTrue);
      expect(swift.contains('async function saveWithFs'), isTrue);
      expect(kotlin.contains('getDirectoryHandle'), isTrue);
      expect(swift.contains('getDirectoryHandle'), isTrue);
      // The only anchor the page ever creates is the invisible fallback
      // download - no anchor is ever appended to the file list.
      expect(kotlin.contains('deviceFilesList.appendChild(a)'), isFalse);
      expect(swift.contains('deviceFilesList.appendChild(a)'), isFalse);
      expect(kotlin.contains("a.style.display = 'none'"), isTrue);
      expect(swift.contains("a.style.display = 'none'"), isTrue);
      // ...and it clicks itself, so the user never has to.
      expect(kotlin.contains('a.click();'), isTrue);
      expect(swift.contains('a.click();'), isTrue);
    });

    test('the page says "already saved" only once', () {
      // The 1s poll used to repeat that line, which overwrote the
      // "Saved N files to <folder>" message the moment it appeared - so a
      // finished send read as nothing happening (the reported bug).
      expect(kotlin.contains('announcedSeq'), isTrue);
      expect(swift.contains('announcedSeq'), isTrue);
    });

    test('the page saves each batch exactly once', () {
      // The received runId|seq pair is remembered, so a reload inside the
      // same server run does not download the same files again.
      expect(kotlin.contains("localStorage.getItem('dp.received')"), isTrue);
      expect(kotlin.contains("localStorage.setItem('dp.received'"), isTrue);
      expect(swift.contains("localStorage.getItem('dp.received')"), isTrue);
      expect(swift.contains("localStorage.setItem('dp.received'"), isTrue);
    });

    test('the page asks for a folder once, then never again', () {
      // The directory picker needs a user gesture, so it is opened by the
      // "Receive into a folder" button; every later batch is automatic.
      expect(kotlin.contains('window.showDirectoryPicker'), isTrue);
      expect(swift.contains('window.showDirectoryPicker'), isTrue);
      expect(kotlin.contains('fsSupported && !destRoot'), isTrue);
      expect(swift.contains('fsSupported && !destRoot'), isTrue);
    });

    test('the page falls back to the browser downloader without a picker', () {
      // Firefox/Safari have no directory picker: the browser's own
      // downloader takes each file, so a large video streams to disk
      // instead of being buffered in the page.
      expect(kotlin.contains('saveWithDownload'), isTrue);
      expect(swift.contains('saveWithDownload'), isTrue);
    });

    test('the poll is fast enough to feel immediate', () {
      // A send should start on the PC within about a second, not three.
      expect(kotlin.contains('setInterval(loadDeviceFiles, 1000)'), isTrue);
      expect(swift.contains('setInterval(loadDeviceFiles, 1000)'), isTrue);
    });

    test('both servers embed credentials in the fetch URL', () {
      // The fallback anchor is a plain navigation, so the credentials ride
      // in the URL userinfo; the fetch() calls rely on the page's own
      // Basic-auth session.
      expect(
        kotlin.contains(r"location.protocol + '//' + '$authInfo'"),
        isTrue,
      );
      expect(
        swift.contains(r"location.protocol + '//' + '\(authInfo)'"),
        isTrue,
      );
    });

    test('both servers stream the whole batch as one store-only zip', () {
      // PairDrop's answer to multi-file sends: ONE archive, not N
      // downloads, so the browser's "multiple downloads" prompt never
      // fires and the folder structure travels inside the zip.
      expect(kotlin, contains(r'"$PATH_PREFIX/files.zip"'));
      expect(swift, contains('/files.zip'));
      // The writer is STORE-only (method 0) with ZIP64 - a 50 GB remux
      // must not cost CPU, and must not overflow the 4 GiB fields.
      expect(storeZip, contains('object StoreZip'));
      expect(storeZip, contains('0x04034b50')); // local header signature
      expect(storeZip, contains('0x06064b50')); // ZIP64 EOCD
      expect(kotlin, contains('StoreZip.write')); // the route uses it
      expect(swift, contains('0x04034b50'));
      expect(swift, contains('0x06064b50'));
      // The zip route is authenticated like every other route (it sits
      // after the auth check in the same when/if chain).
      expect(kotlin.indexOf(r'"$PATH_PREFIX/files.zip"') > kotlin.indexOf('if (!authorized(headers))'), isTrue);
      expect(swift.indexOf('/files.zip') > swift.indexOf('WWW-Authenticate'), isTrue);
    });

    test('the page takes a multi-file batch as ONE zip on fallback browsers', () {
      // No directory picker (Firefox/Safari) + more than one file -> a
      // single anchor to files.zip, never a per-file loop.
      expect(kotlin.contains('!destRoot && files.length > 1'), isTrue);
      expect(swift.contains('!destRoot && files.length > 1'), isTrue);
      expect(kotlin.contains('saveZip(files)'), isTrue);
      expect(swift.contains('saveZip(files)'), isTrue);
      expect(kotlin.contains('files.zip'), isTrue);
      expect(swift.contains('files.zip'), isTrue);
      // The archive is named like PairDrop's: DreamPlayer_files_<date>.zip
      expect(kotlin.contains("'DreamPlayer_files_'"), isTrue);
      expect(swift.contains("'DreamPlayer_files_'"), isTrue);
      // A single file still goes direct - no point wrapping one file.
      expect(kotlin.contains('saveWithDownload(f, i)'), isTrue);
      expect(swift.contains('saveWithDownload(f, i)'), isTrue);
    });
  });

  group('send files + send folder to the computer', () {
    test('the snackbar says it is sending and offers no link action', () {
      // The transfer page receives the batch on its own now, so there is
      // no URL to open and nothing to copy from the snackbar.
      expect(screen, contains('Sending '));
      expect(screen.contains("label: 'Copy URL'"), isFalse);
    });

    test('the page offers both buttons while running', () {
      expect(screen, contains('Send files'));
      expect(screen, contains('Send folder'));
      expect(screen, contains('_sendFilesToComputer'));
      expect(screen, contains('_sendFolderToComputer'));
      // Both are gated on the server running.
      expect(screen.contains('running && !_picking'), isTrue);
    });

    test('iOS gets a third "Send photos" button wired to the Photos picker', () {
      // The Photos-app picker is iOS-only (PHPicker); Android users pick
      // images through "Send files".
      expect(screen, contains('Send photos'));
      expect(screen, contains('_sendPhotosToComputer'));
      expect(screen.contains('if (Platform.isIOS)'), isTrue);
      expect(screen.contains("'Sending 1 photo'"), isTrue);
      // The Dart side hands the picked photos to the same shareFiles push
      // flow - no copying in Dart.
      expect(screen.contains('pickPhotos()'), isTrue);
      expect(browser, contains("'pickPhotos'"));
      expect(browser.contains('invokeListMethod<dynamic>(\'pickPhotos\')'), isTrue);
    });

    test('iOS copies picked photos to stable files named Photos/<name>', () {
      final fb = File('ios/Runner/FileBrowser.swift').readAsStringSync();
      expect(fb, contains('import PhotosUI'));
      expect(fb, contains('case "pickPhotos":'));
      expect(fb, contains('PHPickerViewController'));
      // .any, not .images: camera VIDEOS (.mov/.mp4) must be visible too.
      // Photos come back as .heic - the original registered type is kept,
      // JPEG is only the fallback for items that cannot export as a file.
      expect(fb, contains("config.filter = .any(of: [.images, .videos])"));
      expect(fb.contains("config.filter = .images\n"), isFalse);
      expect(fb, contains('registeredTypeIdentifiers.first'));
      expect(fb, contains('UTType(id)?.preferredFilenameExtension'));
      // PHPicker file URLs are temporary - they must be copied before the
      // server streams them later.
      expect(fb, contains('loadFileRepresentation'));
      expect(fb, contains('dp_photos'));
      expect(fb.contains('copyItem(at: url, to: dest)'), isTrue);
      // The "Photos/" prefix makes the receiving page group them into a
      // folder, like a picked folder's tree.
      expect(fb.contains('"Photos/\\(safe)"'), isTrue);
    });

    test('iOS picker always closes and always completes the channel call', () {
      final fb = File('ios/Runner/FileBrowser.swift').readAsStringSync();
      // The system checkmark/cancel buttons do NOT auto-dismiss PHPicker.
      expect(fb.contains('picker.dismiss(animated: true)'), isTrue);
      // A swipe-down dismisses without didFinishPicking - the presentation
      // delegate must still complete the call, or the Dart _picking flag
      // sticks and every Send button stays greyed out.
      expect(fb, contains('presentationControllerDidDismiss'));
      expect(fb.contains('picker.presentationController?.delegate = self'), isTrue);
    });

    test('the download filename never carries a folder slash', () {
      // Names like "Photos/IMG_0001.HEIC" must download as "IMG_0001.HEIC":
      // a slash in the Content-Disposition filename makes download managers
      // save a broken ".part" file or a bare name.
      expect(kotlin.contains("name.substringAfterLast('/')"), isTrue);
      expect(swift.contains('(name as NSString).lastPathComponent'), isTrue);
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
