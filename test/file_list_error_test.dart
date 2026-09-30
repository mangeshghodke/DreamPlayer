import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/file_browser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dreamplayer/files');

  /// Drives the MethodChannel with a canned listDirectory reply.
  Future<void> mockList(List<Object?> reply) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listDirectory') return reply;
      return null;
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('FileBrowserService.listDirectory', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('parses a normal listing and clears any previous error', () async {
      final svc = FileBrowserService.instance;
      await mockList([
        {'name': 'a.mkv', 'path': '/d/a.mkv', 'isDirectory': false, 'size': 1},
        {'error': 'not_found', 'path': '/d'},
      ]);
      // First call fails, so the error is recorded.
      await svc.listDirectory('/d');
      expect(svc.lastListError, 'not_found');

      // A good listing clears it — a stale error must not leak forward.
      await mockList([
        {'name': 'a.mkv', 'path': '/d/a.mkv', 'isDirectory': false, 'size': 1},
      ]);
      final entries = await svc.listDirectory('/d');
      expect(entries.map((e) => e.name), ['a.mkv']);
      expect(svc.lastListError, isNull);
    });

    test('drops the error pseudo-entry so it is never listed as a file',
        () async {
      final svc = FileBrowserService.instance;
      await mockList([
        {'error': 'no_permission', 'path': '/Volumes/Movies'},
      ]);
      final entries = await svc.listDirectory('/Volumes/Movies');
      expect(entries, isEmpty,
          reason: 'an error row must never look like a media file');
      expect(svc.lastListError, 'no_permission');
    });

    test('explains each iOS failure mode in plain language', () async {
      final svc = FileBrowserService.instance;
      await mockList([
        {'error': 'no_permission', 'path': '/Volumes/Movies'},
      ]);
      await svc.listDirectory('/Volumes/Movies');
      expect(svc.lastListErrorText, contains('refused access'));
      expect(svc.lastListErrorText, contains('external drive'));

      await mockList([
        {'error': 'stale_bookmark', 'path': '/Volumes/Movies'},
      ]);
      await svc.listDirectory('/Volumes/Movies');
      expect(svc.lastListErrorText, contains('no longer grant access'));
    });

    test('has no message for a successful listing', () async {
      final svc = FileBrowserService.instance;
      await mockList(const []);
      await svc.listDirectory('/d');
      expect(svc.lastListError, isNull);
      expect(svc.lastListErrorText, isNull);
    });
  });
}
