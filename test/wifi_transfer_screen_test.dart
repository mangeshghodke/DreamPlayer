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
      expect(codeOf(screen), contains('_UploadRow(item: item)'));
      expect(codeOf(screen), contains('WifiUploadStatus.done'));
      expect(codeOf(screen), contains('WifiUploadStatus.failed'));
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

    test('swift hops progress events to the main thread', () {
      expect(swift, contains('DispatchQueue.main.async'));
    });
  });
}