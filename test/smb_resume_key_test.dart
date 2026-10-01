import 'package:dream_player/services/library_folders.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors `smbParts(fromResumeKey:)` in ios/Runner/AvPlayerView.swift.
///
/// The native side splits `smb:<serverId>/<share>/<path>` and treats the FIRST
/// segment as the share. Any producer that forgets the share therefore does not
/// fail loudly — it silently connects to a share named after the first folder.
({String id, String share, String path})? parseSmbResumeKey(String? key) {
  if (key == null || !key.startsWith('smb:')) return null;
  final segments = key
      .substring(4)
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  if (segments.length < 2) return null;
  return (
    id: segments[0],
    share: segments[1],
    path: segments.sublist(2).join('/'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The shapes FolderScanner produces for a bookmarked SMB folder, with the share
  // deliberately one that is NOT the first path segment.
  const serverId = 'BBD88C48-0071-42B1-9135-0B9E20EA3976';
  const share = 'Downloads';
  const childPath = 'Video/Movies';

  LibraryFolder scannedFolder() => LibraryFolder(
    id: 'smb_$serverId',
    name: 'Movies',
    // This is the value FolderScanner assigns. The share has to be here, or the
    // native parser reads "Video" as the share.
    path: 'smb:$serverId/$share/$childPath',
    addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    source: LibraryFolderSource.smb,
    networkServerId: serverId,
    networkShare: share,
    networkPath: childPath,
  );

  LibraryFolder scannedVideo() => LibraryFolder(
    id: 'smb_${serverId}_file',
    name: '24.mkv',
    path: 'smb:$serverId/$share/$childPath/24.mkv',
    addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    source: LibraryFolderSource.smb,
    networkServerId: serverId,
    networkShare: share,
    networkPath: '$childPath/24.mkv',
    isFile: true,
    videoUri: 'smb://$serverId/$share/$childPath/24.mkv',
  );

  group('SMB resume key', () {
    test('folder key parses back to the real share, not the first folder', () {
      final parsed = parseSmbResumeKey(scannedFolder().path);
      expect(parsed, isNotNull);
      expect(parsed!.share, share,
          reason: 'share must come from networkShare, not the path');
      expect(parsed.path, childPath);
      expect(parsed.id, serverId);
    });

    test('video key parses back to the real share and full path', () {
      final parsed = parseSmbResumeKey(scannedVideo().path);
      expect(parsed!.share, share);
      expect(parsed.path, '$childPath/24.mkv');
    });

    test('path and videoUri agree on the share', () {
      final folder = scannedVideo();
      final fromKey = parseSmbResumeKey(folder.path)!;
      // videoUri is smb://<serverId>/<share>/<path>
      final uriSegments = folder.videoUri!
          .substring('smb://'.length)
          .split('/')
          .where((s) => s.isNotEmpty)
          .toList();
      expect(uriSegments[1], fromKey.share);
      expect(uriSegments.sublist(2).join('/'), fromKey.path);
    });

    test('a key missing the share does not round-trip', () {
      // Regression guard for the bug itself: this is what the scanner used to
      // write, and it silently reconnected to a share named "Video".
      final parsed = parseSmbResumeKey('smb:$serverId/$childPath/24.mkv');
      expect(parsed!.share, 'Video');
      expect(parsed.path, 'Movies/24.mkv');
      expect(parsed.share, isNot(share));
    });

    test('rejects non-SMB and malformed keys', () {
      expect(parseSmbResumeKey(null), isNull);
      expect(parseSmbResumeKey('/storage/emulated/0/x.mkv'), isNull);
      expect(parseSmbResumeKey('smb:$serverId'), isNull);
    });
  });
}