import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Audio-only playback gets a music transport row (shuffle / prev / play-pause
/// / next / repeat) in place of the centre video pill - mirrors Mpv-infinity's
/// audio screen (AudioPlayerControls.kt: transport row + shuffle/repeat row;
/// PolyForm, ideas only). The player screen needs a live platform view, so the
/// wiring is pinned by reading the source.
void main() {
  final player = File('lib/screens/player_screen.dart').readAsStringSync();

  group('audio transport row wiring (source-reading)', () {
    test(
      'centre pill is hidden for audio-only; the music row sits in the bottom bar under the seekbar',
      () {
        expect(player.contains('_isAudioOnly && !_inPip'), isTrue);
        // centre pill hidden while audio plays...
        expect(player.contains('? const SizedBox.shrink()'), isTrue);
        // ...and the row renders inside the bottom bar (Mpv-infinity layout:
        // seekbar, then transport row at the very bottom).
        expect(player.contains('_audioTransportRow(inBottomBar: true)'), isTrue);
        expect(player.contains('if (_isAudioOnly && !_inPip)'), isTrue);
      },
    );

    test('row has shuffle, prev, play/pause, next, repeat', () {
      final rowStart = player.indexOf('Widget _audioTransportRow({');
      expect(rowStart, greaterThan(0));
      final row = player.substring(rowStart, rowStart + 8000);
      expect(row.contains('Icons.shuffle'), isTrue);
      expect(row.contains('Icons.skip_previous'), isTrue);
      expect(row.contains('Icons.skip_next'), isTrue);
      expect(row.contains('Icons.repeat_one'), isTrue);
      expect(row.contains('Icons.repeat'), isTrue);
      expect(row.contains('_togglePlayPause'), isTrue);
    });

    test(
      'shuffle/repeat buttons reuse the ⋮ sheet store + live engine path',
      () {
        expect(player.contains('void _toggleShuffleButton()'), isTrue);
        expect(
          player.contains('PlaybackModesStore.saveShuffle(_shuffle)'),
          isTrue,
        );
        expect(player.contains('void _cycleRepeatButton()'), isTrue);
        expect(player.contains('_exo?.setRepeatMode(next.index)'), isTrue);
        expect(player.contains('PlaybackModesStore.saveRepeat(next)'), isTrue);
      },
    );

    test('prev/next reuse the folder sibling listing, sequential + wrapping', () {
      expect(
        player.contains('Future<VideoItem?> _pickSibling(int delta)'),
        isTrue,
      );
      // Manual skip is sequential (shuffle only affects auto-advance) and
      // wraps at both ends.
      expect(
        player.contains(
          'nextPlaybackIndex(idx, siblings.length, wrap: true, shuffle: false)',
        ),
        isTrue,
      );
      expect(
        player.contains('(idx - 1 < 0 ? siblings.length - 1 : idx - 1)'),
        isTrue,
      );
      expect(
        player.contains('Future<void> _playSibling(VideoItem next)'),
        isTrue,
      );
      expect(player.contains('Future<void> _skipTrack(int delta)'), isTrue);
    });

    test('prev/next are disabled when the folder holds a single track', () {
      expect(player.contains('(_siblingCount ?? 0) > 1'), isTrue);
      expect(player.contains('_siblingCount = null;'), isTrue);
      expect(player.contains('_orderedSiblings().then'), isTrue);
    });

    test('transport pill scales down instead of overflowing narrow screens', () {
      // Reported 2026-11-27: 14 px right overflow in portrait.
      final rowStart = player.indexOf('Widget _audioTransportRow({');
      final row = player.substring(rowStart, rowStart + 8000);
      expect(row.contains('FittedBox('), isTrue);
      expect(row.contains('BoxFit.scaleDown'), isTrue);
    });

    test('landscape audio-only splits the screen: badges/title left, disc right', () {
      expect(
        player.contains('if (constraints.maxWidth > constraints.maxHeight)'),
        isTrue,
      );
      // Overlay's left half hosts badges + title; the interactive disc layer
      // (main stack) owns the right half.
      expect(player.contains('width: halfW'), isTrue);
      expect(player.contains('left: 0,'), isTrue);
      expect(player.contains('right: 0,'), isTrue);
      expect(player.contains('width: mq.width / 2'), isTrue);
      expect(player.contains('VinylDisc('), isTrue);
    });

    test('bottom-bar music row has the big white play circle (Mpv-infinity look)', () {
      final rowStart = player.indexOf('Widget _audioTransportRow(');
      final row = player.substring(rowStart, rowStart + 5200);
      expect(row.contains('inBottomBar'), isTrue);
      expect(row.contains('BoxShape.circle'), isTrue);
      expect(row.contains('Colors.white'), isTrue);
      expect(row.contains('SizedBox(width: 340'), isTrue);
    });
  });

  group('audio cover style toggle + now-playing metadata (source-reading)', () {
    test('vinyl stays default; top-bar button toggles plain art, persisted', () {
      final store = File('lib/services/audio_art_style_store.dart').readAsStringSync();
      expect(store.contains("prefsKey = 'dreamplayer.audioPlainArt'"), isTrue);
      expect(store.contains('_plainArt = false'), isTrue);
      expect(player.contains('_toggleAudioArtStyle'), isTrue);
      expect(player.contains('AudioArtStyleStore.instance.setPlainArt'), isTrue);
      expect(player.contains('if (_isAudioOnly && !_inPip)'), isTrue);
      expect(player.contains('Icons.album'), isTrue);
      expect(player.contains('Icons.image'), isTrue);
    });

    test('plain art renders a rounded card instead of the interactive disc', () {
      expect(player.contains('showPlainArt'), isTrue);
      expect(player.contains('ClipRRect('), isTrue);
      expect(player.contains('_audioPlainArt && _audioArt != null'), isTrue);
    });

    test('top bar + notification title use the embedded tag for audio', () {
      expect(player.contains('if (_isAudioOnly) {\n      final tag = _audioProbe?.audioTitle;'), isTrue);
      expect(player.contains('exo.setNowPlayingArtworkData(_audioArt)'), isTrue);
    });

    test('artwork-bytes channel exists on both platforms', () {
      final exo = File('lib/services/exo_player.dart').readAsStringSync();
      expect(exo, contains('setNowPlayingArtworkData'));
      expect(exo, contains("'setNowPlayingArtworkData'"));
      final kt = File('android/app/src/main/kotlin/com/dreamplayer/app/ExoPlayerView.kt').readAsStringSync();
      expect(kt, contains('"setNowPlayingArtworkData"'));
      expect(kt, contains('PlaybackManager.setArtworkData'));
      final pm = File('android/app/src/main/kotlin/com/dreamplayer/app/PlaybackManager.kt').readAsStringSync();
      expect(pm, contains('fun setArtworkData'));
      expect(pm, contains('BitmapFactory.decodeByteArray'));
      final swift = File('ios/Runner/AvPlayerView.swift').readAsStringSync();
      expect(swift, contains('"setNowPlayingArtworkData"'));
      expect(swift, contains('setNowPlayingArtworkData'));
      expect(swift, contains('UIImage(data:'));
    });
  });
}
