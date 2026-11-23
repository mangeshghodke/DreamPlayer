import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/utils/media_extensions.dart';

void main() {
  group('media_extensions', () {
    test('audio files are playable media but not video', () {
      for (final name in [
        'track01.m4a',
        'Atmos Album - 01.flac',
        'song.WAV',
        'podcast.mp3',
        'voice.aac',
        'live.ogg',
        'modern.opus',
        'old.wma',
        'cd.aiff',
        'rip.mka',
      ]) {
        expect(isAudioFile(name), isTrue, reason: name);
        expect(isPlayableMedia(name), isTrue, reason: name);
        expect(isVideoFile(name), isFalse, reason: name);
      }
    });

    test('video files are playable media and video', () {
      for (final name in ['movie.mkv', 'ep.mp4', 'clip.webm', 'x.mov']) {
        expect(isVideoFile(name), isTrue, reason: name);
        expect(isPlayableMedia(name), isTrue, reason: name);
        expect(isAudioFile(name), isFalse, reason: name);
      }
    });

    test('non-media files are not playable', () {
      for (final name in ['notes.txt', 'cover.jpg', 'subs.srt', 'noext']) {
        expect(isPlayableMedia(name), isFalse, reason: name);
      }
    });
  });

  group('native listing sets carry the audio extensions (source-reading)', () {
    // The video/audio extension lists are duplicated in every native browser;
    // if one drifts, a music file silently disappears from that browser only.
    const audioExts = ['m4a', 'flac', 'wav'];
    const kotlinFiles = [
      'android/app/src/main/kotlin/com/dreamplayer/app/FileBrowser.kt',
      'android/app/src/main/kotlin/com/dreamplayer/app/SMBClient.kt',
      'android/app/src/main/kotlin/com/dreamplayer/app/WebDAVClient.kt',
      'android/app/src/main/kotlin/com/dreamplayer/app/FtpClient.kt',
      'android/app/src/main/kotlin/com/dreamplayer/app/UpnpClient.kt',
      'android/app/src/main/kotlin/com/dreamplayer/app/UploadServer.kt',
    ];
    const swiftFiles = [
      'ios/Runner/FileBrowser.swift',
      'ios/Runner/WebDAVClient.swift',
      'ios/Runner/FtpClient.swift',
      'ios/Runner/SMBBridge.swift',
      'ios/Runner/UpnpClient.swift',
      'ios/Runner/UploadServer.swift',
    ];

    for (final f in kotlinFiles) {
      test('$f lists audio extensions', () {
        final src = File(f).readAsStringSync();
        for (final ext in audioExts) {
          expect(src, contains('"$ext"'), reason: '$f missing .$ext');
        }
      });
    }

    for (final f in swiftFiles) {
      test('$f lists audio extensions', () {
        final src = File(f).readAsStringSync();
        for (final ext in audioExts) {
          expect(src, contains('"$ext"'), reason: '$f missing .$ext');
        }
      });
    }

    test('iOS Info.plist opens audio document types', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(plist, contains('<string>public.audio</string>'));
      expect(plist, contains('<string>com.apple.m4a-audio</string>'));
      expect(plist, contains('<string>com.dreamplayer.app.flac</string>'));
    });

    test('Android manifest already offers audio/* for Open with', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android:mimeType="audio/*"'));
    });

    test('TMDB catalogue matching stays video-only (music must not hit TMDB/AVDb/r18)',
        () {
      final src = File('lib/services/tmdb_client.dart').readAsStringSync();
      final fnStart = src.indexOf('bool _looksLikeVideoFile');
      final fnEnd = src.indexOf('}', fnStart);
      final fnBody = src.substring(fnStart, fnEnd);
      expect(fnBody, isNot(contains("'.m4a'")));
      expect(fnBody, isNot(contains("'.flac'")));
      expect(fnBody, isNot(contains("'.wav'")));
    });

    test('TV passthrough covers Atmos-in-m4a (E-AC3-JOC)', () {
      final src = File(
        'android/app/src/main/kotlin/com/dreamplayer/app/PlayerCodecs.kt',
      ).readAsStringSync();
      expect(src, contains('AUDIO_E_AC3_JOC'));
      final fnStart = src.indexOf('fun isPassthroughFormat');
      final fnEnd = src.indexOf('}', src.indexOf('->', fnStart));
      final body = src.substring(fnStart, fnEnd);
      expect(body, contains('AUDIO_E_AC3_JOC'));
      expect(body, contains('AUDIO_AC3'));
      expect(body, contains('AUDIO_DTS'));
      expect(body, contains('AUDIO_TRUEHD'));
    });
  });
}
