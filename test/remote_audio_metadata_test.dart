import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dream_player/utils/remote_head_fetch.dart';

/// Remote audio metadata (embedded tags + cover art) must be read from the
/// FILE ITSELF for every source - local, content://, smb://, http(s) (WebDAV,
/// Jellyfin, UPnP), ftp(s) - not just local files. TMDB stays video-only by
/// design, so audio never resolves there; the in-file metadata is the only
/// source. These tests pin the wiring: pure helpers are unit-tested, the
/// native/Dart plumbing is pinned by reading the sources (the player screen
/// needs a live platform view, so it cannot be pumped as a widget).
void main() {
  group('needsTempDownload', () {
    test('ftp/sftp need a Dart-side temp download', () {
      expect(needsTempDownload('ftp://nas/music/a.flac', false), isTrue);
      expect(needsTempDownload('ftps://nas/a.mp3', false), isTrue);
      expect(needsTempDownload('sftp://nas/a.wav', false), isTrue);
    });

    test('self-signed http needs it, plain http and smb do not', () {
      expect(needsTempDownload('https://nas:5006/a.m4a', true), isTrue);
      expect(needsTempDownload('http://nas:8096/a.flac', true), isTrue);
      expect(needsTempDownload('https://nas:5006/a.m4a', false), isFalse);
      expect(needsTempDownload('http://192.168.1.16:8096/a.mkv', false), isFalse);
      expect(needsTempDownload('smb://srv/share/a.flac', false), isFalse);
      expect(needsTempDownload('/storage/emulated/0/a.mp3', false), isFalse);
      expect(needsTempDownload(null, false), isFalse);
    });
  });

  group('extensionOf', () {
    test('extracts a lowercased dot-extension from uris and paths', () {
      expect(extensionOf('smb://srv/share/Album/Song.M4A'), '.m4a');
      expect(extensionOf('https://x/y/track.flac?token=abc'), '.flac');
      expect(extensionOf('/storage/emulated/0/Music/song.mp3#frag'), '.mp3');
      expect(extensionOf('https://x/y/noext'), '');
      expect(extensionOf('https://x/y/dot.'), '');
    });
  });

  group('smbServerIdFromResumeKey', () {
    test('parses smb:<serverId>/<share>/<path>', () {
      expect(smbServerIdFromResumeKey('smb:abc123/Movies/song.flac'), 'abc123');
      expect(smbServerIdFromResumeKey('smb:abc123'), 'abc123');
      expect(smbServerIdFromResumeKey('webdav_x/y'), isNull);
      expect(smbServerIdFromResumeKey(null), isNull);
      expect(smbServerIdFromResumeKey('smb:/share/x'), isNull);
    });
  });

  group('source pins: remote audio metadata wiring', () {
    test('ThumbnailStore has no Dart-side remote gate and passes source args', () {
      final src = File('lib/services/thumbnail_store.dart').readAsStringSync();
      // The old `_isRemote`/`_isLocal` early-return gate is gone.
      expect(src.contains('_isRemote('), isFalse);
      expect(src.contains('_isLocal('), isFalse);
      // Remote sources go through the channel with auth headers + resume key,
      // and the temp-download fallback for ftp/self-signed https is wired.
      expect(src.contains('needsTempDownload('), isTrue);
      expect(src.contains('getThumbnailFile'), isTrue);
      expect(src.contains('fetchHeadTailTempFile'), isTrue);
      expect(src.contains('headers: item.httpHeaders'), isTrue);
      expect(src.contains('resumeKey: item.resumeKey'), isTrue);
    });

    test('FileBrowserService sends headers/resumeKey and exposes getThumbnailFile', () {
      final src = File('lib/services/file_browser.dart').readAsStringSync();
      expect(src.contains("'getThumbnailFile'"), isTrue);
      expect(src.contains("'resumeKey': resumeKey"), isTrue);
      expect(src.contains("'headers': headers"), isTrue);
      expect(src.contains("'allowSelfSigned': allowSelfSigned"), isTrue);
    });

    test('MediaProbe passes resumeKey and temp-downloads head+tail', () {
      final src = File('lib/services/media_probe.dart').readAsStringSync();
      expect(src.contains("'resumeKey': resumeKey"), isTrue);
      expect(src.contains('fetchHeadTailTempFile'), isTrue);
    });

    test('player screen probes audio files from any source', () {
      final src = File('lib/screens/player_screen.dart').readAsStringSync();
      expect(src.contains('ThumbnailStore.artFor(_current)'), isTrue);
      expect(src.contains('needsTempDownload(uri, video.allowSelfSigned)'), isTrue);
      expect(src.contains('resumeKey: video.resumeKey'), isTrue);
    });

    test('Android getThumbnail reads smb via loopback, http with headers, temp files', () {
      final src = File('android/app/src/main/kotlin/com/dreamplayer/app/FileBrowser.kt').readAsStringSync();
      expect(src.contains('"getThumbnailFile"'), isTrue);
      expect(src.contains('SmbHttpProxy.start('), isTrue);
      expect(src.contains('SmbHttpProxy.stop('), isTrue);
      expect(src.contains('it.setDataSource(httpUri, headers ?: emptyMap())'), isTrue);
      expect(src.contains('it.setDataSource(httpUrl, headers ?: emptyMap())'), isTrue);
    });

    test('Android MediaProbe already tags smb:// and http(s) probes', () {
      final src = File('android/app/src/main/kotlin/com/dreamplayer/app/MediaProbe.kt').readAsStringSync();
      expect(src.contains('probeSmb('), isTrue);
      expect(src.contains('METADATA_KEY_TITLE'), isTrue);
      expect(src.contains('METADATA_KEY_ARTIST'), isTrue);
      expect(src.contains('METADATA_KEY_ALBUM'), isTrue);
    });

    test('iOS getThumbnail reads http with headers, smb via libsmb2 temp fetch', () {
      final src = File('ios/Runner/FileBrowser.swift').readAsStringSync();
      expect(src.contains('"getThumbnailFile"'), isTrue);
      expect(src.contains('AVURLAssetHTTPHeaderFieldsKey'), isTrue);
      expect(src.contains('fetchHeadTailToTemp'), isTrue);
      expect(src.contains('u.hasPrefix("smb://")'), isTrue);
    });

    test('iOS MediaProbe probes smb:// through a libsmb2 head+tail temp file', () {
      final src = File('ios/Runner/MediaProbe.swift').readAsStringSync();
      expect(src.contains('probeSmb'), isTrue);
      expect(src.contains('fetchHeadTailToTemp'), isTrue);
      expect(src.contains('u.hasPrefix("smb://")'), isTrue);
      expect(src.contains('"resumeKey"'), isTrue);
    });

    test('SMBBridge exposes the shared head+tail temp fetch', () {
      final src = File('ios/Runner/SMBBridge.swift').readAsStringSync();
      expect(src.contains('func fetchHeadTailToTemp'), isTrue);
      expect(src.contains('openFromSmbUri'), isTrue);
    });
  });
}
