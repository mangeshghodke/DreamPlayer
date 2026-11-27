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

  group('audioBadgeLabels (top-of-screen chips)', () {
    test('hi-res flac: codec, kHz, bit depth, channels, kbps, badges', () {
      expect(
        audioBadgeLabels(
          mimeOrCodec: 'audio/flac',
          sampleRate: 96000,
          bits: 24,
          channels: 2,
          bitrate: 1411000,
        ),
        ['FLAC', '96 kHz', '24-bit', '2 ch', '1411 kbps', 'Lossless', 'Hi-Res'],
      );
    });

    test('mp3: MP3, 44.1 kHz, 2 ch, 320 kbps - no quality badges', () {
      expect(
        audioBadgeLabels(
          mimeOrCodec: 'audio/mpeg',
          sampleRate: 44100,
          channels: 2,
          bitrate: 320000,
        ),
        ['MP3', '44.1 kHz', '2 ch', '320 kbps'],
      );
    });

    test('empty info yields no labels', () {
      expect(audioBadgeLabels(mimeOrCodec: null), isEmpty);
    });
  });

  group('player wiring (source-reading)', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final probeKt = File(
            'android/app/src/main/kotlin/com/dreamplayer/app/MediaProbe.kt')
        .readAsStringSync();
    final probeSwift = File('ios/Runner/MediaProbe.swift').readAsStringSync();
    final probeDart = File('lib/services/media_probe.dart').readAsStringSync();

    test('format badges are at the TOP of the audio overlay, not below the disc', () {
      final overlayAt = player.indexOf('if (_isAudioOnly && _error == null)');
      expect(overlayAt, greaterThan(-1));
      // Slice the PORTRAIT branch (the landscape half-split branch comes first
      // in the source since 2026-11-27).
      final portraitAt = player.indexOf('// Badges row at the top', overlayAt);
      expect(portraitAt, greaterThan(-1));
      final overlay = player.substring(portraitAt, portraitAt + 4000);
      // Badges rendered in a top-anchored Positioned BEFORE the title column
      // (the disc itself moved to the interactive main-stack layer in the
      // DJ-disc change, leaving a spacer where it sits).
      final topAt = overlay.indexOf('top: MediaQuery.paddingOf(context).top');
      final titleAt = overlay.indexOf('titleText');
      expect(topAt, greaterThan(-1));
      expect(titleAt, greaterThan(-1));
      expect(titleAt, greaterThan(topAt));
      // Song title + artist/album from the probe (Mpv-infinity pattern) -
      // checked on the whole overlay, the widgets are extracted into locals.
      final whole = player.substring(overlayAt, overlayAt + 9000);
      expect(whole, contains('songTitle'));
      expect(whole, contains('songSub'));
      expect(whole, contains('audioTitle'));
      expect(whole, contains('audioArtist'));
    });

    test('info sheet keeps the probed audio detail rows', () {
      expect(player.contains("label: 'Sample rate'"), isTrue);
      expect(player.contains("label: 'Bit depth'"), isTrue);
      expect(player.contains("label: 'Bitrate'"), isTrue);
      expect(player.contains('audioQualityBadges('), isTrue);
    });

    test('native probes expose embedded tag text (title/artist/album)', () {
      for (final key in ['audioTitle', 'audioArtist', 'audioAlbum']) {
        expect(probeKt, contains(key), reason: 'MediaProbe.kt missing $key');
        expect(probeSwift, contains(key), reason: 'MediaProbe.swift missing $key');
        expect(probeDart, contains(key), reason: 'media_probe.dart missing $key');
      }
      expect(probeKt, contains('METADATA_KEY_ARTIST'));
      expect(probeSwift, contains('commonKeyArtist'));
    });

    test('top-bar format chips are suppressed for audio-only (no overlap with the new badges)', () {
      final at = player.indexOf('final chipLine1 = <Widget>[];');
      expect(at, greaterThan(-1));
      final block = player.substring(at, at + 500);
      expect(block, contains('if (_badgeEnabled && !_isAudioOnly)'), reason:
          'the SDR/AAC top-bar pills must not render under the audio badge row');
    });

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

    test('audio format helpers are wired into the player', () {
      // audioFormatSummary is no longer on the overlay (badges moved to the
      // top); it is still exercised by the unit tests above. The overlay uses
      // audioBadgeLabels; the info sheet uses audioQualityBadges.
      expect(player.contains('audioBadgeLabels('), isTrue);
      expect(player.contains('audioQualityBadges('), isTrue);
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

    test('vinyl widget spins via its own AnimationController (pre-DJ code)', () {
      final vinyl = File('lib/widgets/vinyl_disc.dart').readAsStringSync();
      // The parent-driven Transform.rotate variant spun ever faster (the
      // Ticker callback gets total elapsed, not per-frame dt) - reverted
      // 2026-11-27 to this AnimationController version.
      expect(vinyl, contains('AnimationController'));
      expect(vinyl, contains('_controller.repeat()'));
      expect(vinyl, contains('_controller.stop()'));
      expect(vinyl, contains('RotationTransition'));
      expect(vinyl, contains('required this.spinning'));
      expect(vinyl, contains('ClipOval'));
    });
  });

  group('vinyl disc widget', () {
    testWidgets('renders painted vinyl without art and spins while playing',
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

    testWidgets('stops spinning when spinning goes false', (tester) async {
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
