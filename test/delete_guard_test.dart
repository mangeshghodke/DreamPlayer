import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/file_browser.dart';

void main() {
  FileEntry f(String path, {bool dir = false}) =>
      FileEntry(name: 'x', path: path, isDirectory: dir, size: 0);

  group('canDelete', () {
    // Driven through the isAndroid seam so the eligible cases are actually
    // verified on the desktop/CI host instead of silently returning.
    test('offers delete for a local absolute path (Android)', () {
      expect(
        FileBrowserService.canDelete(
          f('/storage/emulated/0/Movies/a.mkv'),
          isAndroid: true,
        ),
        isTrue,
      );
    });

    test('offers delete for a SAF document uri (Android)', () {
      expect(
        FileBrowserService.canDelete(
          f('content://com.android.externalstorage.documents/document/primary%3AMovies%2Fa.mkv'),
          isAndroid: true,
        ),
        isTrue,
      );
    });

    test('never offers delete off Android', () {
      expect(
        FileBrowserService.canDelete(
          f('/storage/emulated/0/Movies/a.mkv'),
          isAndroid: false,
        ),
        isFalse,
      );
    });

    test('never offers delete for a directory', () {
      expect(
        FileBrowserService.canDelete(f('/storage/emulated/0/Movies', dir: true)),
        isFalse,
      );
    });

    test('never offers delete for a network source', () {
      // This is the important guard: a mis-fired tap on a NAS share is
      // irreversible, so these must be refused regardless of platform.
      for (final p in [
        'smb://192.168.1.16/share/a.mkv',
        'ftp://host/a.mkv',
        'sftp://host/a.mkv',
        'http://host/a.mkv',
        'https://host/a.mkv',
        'jellyfin:host/a.mkv',
        'upnp:a.mkv',
        'webdav_1/a.mkv',
      ]) {
        expect(FileBrowserService.canDelete(f(p)), isFalse, reason: p);
      }
    });
  });
}
