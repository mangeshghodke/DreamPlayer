import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/continue_watching.dart';
import 'package:dream_player/services/network_prune.dart';
import 'package:dream_player/services/smb_client.dart';

VideoItem _video(String resumeKey) => VideoItem(
      id: resumeKey,
      title: resumeKey,
      path: resumeKey,
      resumeKey: resumeKey,
      duration: const Duration(minutes: 40),
    );

SmbEntry _entry(String name, {bool isDirectory = false}) => SmbEntry(
      name: name,
      path: name,
      isDirectory: isDirectory,
      size: 0,
      modified: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseSmbResumeKey', () {
    test('round-trips a normal file key', () {
      final p = parseSmbResumeKey('smb:srv1/Video/Movies/House/ep1.mkv');
      expect(p, isNotNull);
      expect(p!.serverId, 'srv1');
      expect(p.share, 'Video');
      expect(p.path, 'Movies/House/ep1.mkv');
      expect(smbResumeKey(p.serverId, p.share, p.path),
          'smb:srv1/Video/Movies/House/ep1.mkv');
    });

    test('trims stray slashes in the path', () {
      final p = parseSmbResumeKey('smb:srv1/Video//Movies/ep.mkv/');
      expect(p, isNotNull);
      expect(p!.path, 'Movies/ep.mkv');
    });

    test('rejects non-smb and malformed keys', () {
      expect(parseSmbResumeKey('/storage/emulated/0/a.mkv'), isNull);
      expect(parseSmbResumeKey('smb_srv1_x'), isNull); // legacy prefix
      expect(parseSmbResumeKey('smb:'), isNull);
      expect(parseSmbResumeKey('smb:srv1'), isNull);
      expect(parseSmbResumeKey('smb:srv1/Video'), isNull); // share, no path
      expect(parseSmbResumeKey('smb:/Video/x.mkv'), isNull); // empty server id
      expect(parseSmbResumeKey('smb:srv1//x.mkv'), isNull); // empty share
    });
  });

  group('missingFileKeys', () {
    const keys = [
      'smb:srv1/Video/Movies/keep.mkv',
      'smb:srv1/Video/Movies/gone.mkv',
      'smb:srv1/Video/Movies/sub/deep.mkv', // nested: never pruned by parent listing
      'smb:srv1/OtherShare/Movies/gone.mkv', // different share
      'smb:srv2/Video/Movies/gone.mkv', // different server
      '/storage/emulated/0/local.mkv', // not smb
    ];

    test('only direct children missing from the listing are returned', () {
      final missing = missingFileKeys(
        serverId: 'srv1',
        share: 'Video',
        dirPath: 'Movies',
        listingNames: {'keep.mkv', 'sub'},
        allKeys: keys,
      );
      expect(missing, ['smb:srv1/Video/Movies/gone.mkv']);
    });

    test('share-root listing uses the bare prefix', () {
      final missing = missingFileKeys(
        serverId: 'srv1',
        share: 'Video',
        dirPath: '',
        listingNames: {'Movies'},
        allKeys: const ['smb:srv1/Video/gone-at-root.mkv'],
      );
      expect(missing, ['smb:srv1/Video/gone-at-root.mkv']);
    });

    test('empty listing prunes all direct children but nothing nested', () {
      final missing = missingFileKeys(
        serverId: 'srv1',
        share: 'Video',
        dirPath: 'Movies',
        listingNames: const {},
        allKeys: keys,
      );
      expect(missing, contains('smb:srv1/Video/Movies/keep.mkv'));
      expect(missing, contains('smb:srv1/Video/Movies/gone.mkv'));
      expect(missing, isNot(contains('smb:srv1/Video/Movies/sub/deep.mkv')));
    });
  });

  group('keysUnderFolder', () {
    test('matches recursively by prefix', () {
      final under = keysUnderFolder('smb:srv1/Video/Movies', const [
        'smb:srv1/Video/Movies/a.mkv',
        'smb:srv1/Video/Movies/sub/b.mkv',
        'smb:srv1/Video/Other/c.mkv',
      ]);
      expect(under, [
        'smb:srv1/Video/Movies/a.mkv',
        'smb:srv1/Video/Movies/sub/b.mkv',
      ]);
    });
  });

  group('SmbClient.isNotFound', () {
    test('only the smb_not_found code counts', () {
      expect(SmbClient.isNotFound(
          PlatformException(code: 'smb_not_found', message: 'gone')), isTrue);
      expect(SmbClient.isNotFound(
          PlatformException(code: 'smb_error', message: 'offline')), isFalse);
      expect(SmbClient.isNotFound(
          PlatformException(code: 'smb_auth', message: 'login')), isFalse);
    });
  });

  group('pruneMissingFromListing (store-level)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('removes CW entries for files absent from a fresh listing', () async {
      await ContinueWatchingStore.save(
          _video('smb:srv1/Video/Movies/keep.mkv'), const Duration(minutes: 5));
      await ContinueWatchingStore.save(
          _video('smb:srv1/Video/Movies/gone.mkv'), const Duration(minutes: 5));
      await ContinueWatchingStore.save(
          _video('smb:srv1/Video/Movies/sub/deep.mkv'), const Duration(minutes: 5));

      final pruned = await NetworkPrune.pruneMissingFromListing(
        serverId: 'srv1',
        share: 'Video',
        dirPath: 'Movies',
        entries: [_entry('keep.mkv'), _entry('sub', isDirectory: true)],
      );

      expect(pruned, 1);
      final remaining =
          (await ContinueWatchingStore.load()).map((e) => ContinueWatchingStore.keyFor(e.video)).toList();
      expect(remaining, contains('smb:srv1/Video/Movies/keep.mkv'));
      expect(remaining, contains('smb:srv1/Video/Movies/sub/deep.mkv'));
      expect(remaining, isNot(contains('smb:srv1/Video/Movies/gone.mkv')));
    });
  });
}
