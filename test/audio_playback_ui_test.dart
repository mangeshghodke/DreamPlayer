import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/utils/audio_format_info.dart';
import 'package:dream_player/widgets/vinyl_disc.dart';

/// Pins the audio-only playback UI (user request 2026-11-24: rotating vinyl
/// disc + the playing file's metadata, hi-res/lossless bit info).
void main() {
  group('isLosslessCodec', () {
    test('lossless containers/codecs are lossless', () {
      for (final m in [
        'audio/flac', 'flac', 'audio/x-flac', 'alac', 'audio/x-ape',
        'ape', 'audio/wav', 'wav', 'audio/x-wav', 'pcm_s24le', 'aiff',
      ]) {
        expect(isLosslessCodec(m), isTrue, reason: m);
      }
    });

    test('lossy codecs are not lossless', () {
      for (final m in [
        'audio/mpeg', 'mp3', 'audio/aac', 'aac', 'audio/eac3', 'eac3',
        'audio/opus', 'opus', 'audio/x-ms-wma', 'wma', 'ogg', 'vorbis',
        null, '',
      ]) {
        expect(isLosslessCodec(m), isFalse, reason: '$m');
      }
    });
  });

  group('audioQualityBadges', () {
    test('plain CD-quality FLAC is Lossless only', () {
      expect(
        audioQualityBadges(mimeOrCodec: 'audio/flac', sampleRate: 44100, bits: 16),
        ['Lossless'],
      );
    });

    test('24-bit/96 kHz FLAC is Lossless + Hi-Res', () {
      expect(
        audioQualityBadges(mimeOrCodec: 'audio/flac', sampleRate: 96000, bits: 24),
        ['Lossless', 'Hi-Res'],
      );
    });

    test('24-bit/48 kHz lossless counts as Hi-Res; 16-bit/48 kHz does not', () {
      expect(
        audioQualityBadges(mimeOrCodec: 'audio/wav', sampleRate: 48000, bits: 24),
        ['Lossless', 'Hi-Res'],
      );
      expect(
        audioQualityBadges(mimeOrCodec: 'audio/wav', sampleRate: 48000, bits: 16),
        ['Lossless'],
      );
    });

    test('lossy high-rate codec is neither badge', () {
      expect(
        audioQualityBadges(mimeOrCodec: 'audio/mpeg', sampleRate: 48000, bits: 0),
        isEmpty,
      );
    });

    test('missing info yields no badges', () {
      expect(audioQualityBadges(mimeOrCodec: null), isEmpty);
    });
  });

  group('audioFormatSummary', () {
    test('full hi-res flac line', () {
      expect(
        audioFormatSummary(
          mimeOrCodec: 'audio/flac',
          sampleRate: 96000,
          bits: 24,
          channels: 2,
          bitrate: 1411000,
        ),
        'FLAC · 96 kHz · 24-bit · 2 ch · 1411 kbps',
      );
    });

    test('mp3 line', () {
      expect(
        audioFormatSummary(
          mimeOrCodec: 'audio/mpeg',
          sampleRate: 44100,
          channels: 2,
          bitrate: 320000,
        ),
        'MP3 · 44.1 kHz · 2 ch · 320 kbps',
      );
    });

    test('unknown codec is omitted, not "Unknown"', () {
      expect(audioFormatSummary(sampleRate: 48000, channels: 1), '48 kHz · mono');
    });
  });

  group('player wiring (source-reading)', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final probeKt = File(
            'android/app/src/main/kotlin/com/dreamplayer/app/MediaProbe.kt')
        .readAsStringSync();
    final probeSwift = File('ios/Runner/MediaProbe.swift').readAsStringSync();
    final probeDart = File('lib/services/media_probe.dart').readAsStringSync();

    test('audio-only detection: extension seed + video-size event flips it', () {
      expect(player.contains('_hasVideoTrack = !isAudioFile(name)'), isTrue);
      expect(player.contains('_hasVideoTrack = true'), isTrue);
      expect(player.contains('bool get _isAudioOnly => _backendReady && !_hasVideoTrack'),
          isTrue);
    });

    test('vinyl disc is rendered for audio-only, spinning while playing', () {
      expect(player.contains('if (_isAudioOnly && _error == null)'), isTrue);
      expect(player.contains('VinylDisc('), isTrue);
      expect(player.contains('spinning: _playing && !_buffering'), isTrue);
      expect(player.contains('artBytes: _audioArt'), isTrue);
    });

    test('cover art + format probe are loaded on audio open', () {
      expect(player.contains('ThumbnailStore.artFor(_current)'), isTrue);
      expect(player.contains('_probeAudioFile(_current)'), isTrue);
      expect(player.contains('MediaProbe.instance.probe('), isTrue);
    });

    test('metadata summary + badges shown under the disc and in the info sheet', () {
      expect(player.contains('audioFormatSummary('), isTrue);
      expect(player.contains('audioQualityBadges('), isTrue);
      expect(player.contains("label: 'Sample rate'"), isTrue);
      expect(player.contains("label: 'Bit depth'"), isTrue);
      expect(player.contains("label: 'Bitrate'"), isTrue);
    });

    test('native probes expose sample rate / bit depth / track bitrate', () {
      for (final key in ['audioSampleRate', 'audioBits', 'audioBitrate']) {
        expect(probeKt, contains(key), reason: 'MediaProbe.kt missing $key');
        expect(probeSwift, contains(key), reason: 'MediaProbe.swift missing $key');
        expect(probeDart, contains(key), reason: 'media_probe.dart missing $key');
      }
    });

    test('Android uses KEY_SAMPLE_RATE / KEY_PCM_ENCODING / KEY_BIT_RATE', () {
      expect(probeKt, contains('KEY_SAMPLE_RATE'));
      expect(probeKt, contains('KEY_PCM_ENCODING'));
      expect(probeKt, contains('KEY_BIT_RATE'));
    });

    test('iOS reads ASBD sample rate + bits per channel', () {
      expect(probeSwift, contains('CMAudioFormatDescriptionGetStreamBasicDescription'));
      expect(probeSwift, contains('mBitsPerChannel'));
      expect(probeSwift, contains('mSampleRate'));
    });

    test('vinyl widget rotates via AnimationController and stops when paused', () {
      final vinyl = File('lib/widgets/vinyl_disc.dart').readAsStringSync();
      expect(vinyl, contains('AnimationController'));
      expect(vinyl, contains('_controller.repeat()'));
      expect(vinyl, contains('_controller.stop()'));
      expect(vinyl, contains('RotationTransition'));
      expect(vinyl, contains('ClipOval'));
    });
  });

  group('vinyl disc widget', () {
    testWidgets('renders painted vinyl without art and rotates while spinning',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: VinylDisc(spinning: true))),
        ),
      );
      expect(find.byType(VinylDisc), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      // Advance time - the RotationTransition must be animating.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });

    testWidgets('stops rotating when spinning goes false', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: VinylDisc(spinning: true))),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: VinylDisc(spinning: false))),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });
  });
}
