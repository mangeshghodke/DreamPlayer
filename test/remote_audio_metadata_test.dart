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
      // smb:// must be matched on uri OR path: on iOS the playback uri is a
      // dreamplayersmb:// token, so a `uri ?? path` check alone would miss it
      // (user report 2026-11-28: no album art on iPad for SMB audio).
      expect(src.contains('[uri, path].compactMap({ \$0 }).first(where: { \$0.hasPrefix("smb://") })'), isTrue);
    });

    test('iOS MediaProbe probes smb:// through a libsmb2 head+tail temp file', () {
      final src = File('ios/Runner/MediaProbe.swift').readAsStringSync();
      expect(src.contains('probeSmb'), isTrue);
      expect(src.contains('fetchHeadTailToTemp'), isTrue);
      // same uri-vs-path shadowing fix as getThumbnail (2026-11-28: no tags on
      // iPad for SMB audio because the dreamplayersmb:// uri hid the smb:// path).
      expect(src.contains('[uri, path].compactMap({ \$0 }).first(where: { \$0.hasPrefix("smb://") })'), isTrue);
      expect(src.contains('"resumeKey"'), isTrue);
    });

    test('iOS parses FLAC/ID3/WAV tags + lyrics + artwork from the file head', () {
      final src = File('ios/Runner/MediaProbe.swift').readAsStringSync();
      expect(src.contains('enum AudioFileTags'), isTrue);
      expect(src.contains('parseFlac'), isTrue);
      expect(src.contains('parseId3'), isTrue);
      expect(src.contains('parseWav'), isTrue);
      expect(src.contains('"LYRICS"'), isTrue);
      expect(src.contains('case .commonKeyLyrics'), isTrue);
      expect(src.contains('AudioFileTags.isSupported(filePath)'), isTrue);
      final fb = File('ios/Runner/FileBrowser.swift').readAsStringSync();
      // artwork falls back to the FLAC PICTURE / ID3 APIC parser when AVAsset
      // yields nothing (iOS cannot read FLAC/WAV at all)
      expect(fb.contains('AudioFileTags.parse(fileAt: url.path).artwork'), isTrue);
    });

    test('Android parses embedded lyrics from the file head (FLAC/ID3/WAV)', () {
      final parser = File('android/app/src/main/kotlin/com/dreamplayer/app/AudioTagParser.kt')
          .readAsStringSync();
      expect(parser.contains('"LYRICS"'), isTrue);
      expect(parser.contains('"USLT"'), isTrue);
      expect(parser.contains('parseFlac'), isTrue);
      expect(parser.contains('audioLyrics'), isTrue);
      final probe = File('android/app/src/main/kotlin/com/dreamplayer/app/MediaProbe.kt')
          .readAsStringSync();
      expect(probe.contains('mergeHeadTagsHttp'), isTrue);
      expect(probe.contains('mergeHeadTagsLocal'), isTrue);
      expect(probe.contains('AudioTagParser.parse'), isTrue);
    });

    test('Dart probe result carries audioLyrics and the player renders synced lyrics', () {
      final model = File('lib/services/media_probe.dart').readAsStringSync();
      expect(model.contains("m['audioLyrics'] as String?"), isTrue);
      final player = File('lib/screens/player_screen.dart').readAsStringSync();
      expect(player.contains('parseLrcLines(probe.audioLyrics)'), isTrue);
      expect(player.contains('_audioLyricsBlock(colorScheme)'), isTrue);
      expect(player.contains("label: 'Lyrics'"), isTrue);
      expect(player.contains('lrcIndexAt(_lyrics, _position.inMilliseconds)'), isTrue);
    });

    test('engine label is platform-aware: AetherEngine on iOS, never Media3 there', () {
      final player = File('lib/screens/player_screen.dart').readAsStringSync();
      expect(player.contains("String get _engineDisplayName"), isTrue);
      expect(player.contains("Platform.isIOS ? 'AetherEngine' : 'Media3'"), isTrue);
      // both the info-sheet Engine row and the audio sheet ENGINE pill use it
      expect(player.contains("(label: 'Engine', value: _engineDisplayName)"), isTrue);
      expect(player.contains("'ENGINE · \${_engineDisplayName.toUpperCase()}'"), isTrue);
      expect(player.contains("_mpvReady ? 'MPV' : 'Media3'"), isFalse);
    });

    test('SMBBridge exposes the shared head+tail temp fetch', () {
      final src = File('ios/Runner/SMBBridge.swift').readAsStringSync();
      expect(src.contains('func fetchHeadTailToTemp'), isTrue);
      expect(src.contains('openFromSmbUri'), isTrue);
    });
  });
}
