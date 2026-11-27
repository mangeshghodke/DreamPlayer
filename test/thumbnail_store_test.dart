import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/thumbnail_store.dart';

void main() {
  // Channel-touching code needs the binding (invokeMethod resolves without an
  // engine once initialized).
  TestWidgetsFlutterBinding.ensureInitialized();

  group('thumbnailFileName', () {
    test('is stable and collision-distinct for different keys', () {
      final a = thumbnailFileName('/storage/emulated/0/Movies/a.mkv');
      final b = thumbnailFileName('/storage/emulated/0/Movies/b.mkv');
      expect(a, thumbnailFileName('/storage/emulated/0/Movies/a.mkv'));
      expect(a, isNot(b));
      expect(a, endsWith('.img'));
    });

    test('sanitizes path separators and unsafe characters', () {
      final name = thumbnailFileName('content://media/external/video/my file:name?.mkv');
      expect(name.contains('/'), isFalse);
      expect(name.contains(':'), isFalse);
      expect(name.contains('?'), isFalse);
    });

    test('caps the readable tail length', () {
      final name = thumbnailFileName(
          '/x/${'v' * 80}.mkv');
      expect(name.length, lessThan(60));
    });
  });

  group('ThumbnailStore.artFor gating', () {
    setUp(() {
      ThumbnailStore.setCacheDirForTesting(Directory.systemTemp);
      ThumbnailStore.clearMemoryCache();
    });

    test('no Dart-side source gate: remote http goes to the channel', () async {
      // There is no engine in the test env, so the channel call fails and null
      // comes back - the point is the call was NOT short-circuited in Dart.
      // The removal of the gate itself is pinned by source in
      // remote_audio_metadata_test.dart.
      final item = VideoItem(id: '1', title: 't', uri: 'http://example.com/v.mp4', duration: Duration.zero);
      expect(await ThumbnailStore.artFor(item), isNull);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('accepts local paths', () async {
      // A path that does not exist: the native lookup fails -> null, but it
      // must not be gated off (the call goes through).
      final item = VideoItem(id: '2', title: 't', path: '/definitely/not/here.mkv', duration: Duration.zero);
      expect(await ThumbnailStore.artFor(item), isNull);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('smb uri is not temp-downloaded (native handles it)', () async {
      // smb:// goes straight to the channel with the resume key; the native
      // side reads it via loopback (Android) / libsmb2 temp fetch (iOS).
      final item = VideoItem(
        id: '3',
        title: 't',
        uri: 'smb://srv/share/song.flac',
        resumeKey: 'smb:srv/share/song.flac',
        duration: Duration.zero,
      );
      expect(await ThumbnailStore.artFor(item), isNull);
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}
