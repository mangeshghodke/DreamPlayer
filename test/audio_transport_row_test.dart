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
      'centre pill swaps to the music row only for audio-only, not in PiP',
      () {
        expect(player.contains('_isAudioOnly && !_inPip'), isTrue);
        expect(player.contains('? _audioTransportRow()'), isTrue);
      },
    );

    test('row has shuffle, prev, play/pause, next, repeat', () {
      final rowStart = player.indexOf('Widget _audioTransportRow()');
      expect(rowStart, greaterThan(0));
      final row = player.substring(rowStart, rowStart + 4200);
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
      final rowStart = player.indexOf('Widget _audioTransportRow()');
      final row = player.substring(rowStart, rowStart + 4600);
      expect(row.contains('FittedBox('), isTrue);
      expect(row.contains('BoxFit.scaleDown'), isTrue);
    });

    test('landscape audio-only splits the screen: badges/title left, disc right', () {
      expect(
        player.contains('if (constraints.maxWidth > constraints.maxHeight)'),
        isTrue,
      );
      // Right half hosts the disc, left half hosts badges + title.
      expect(player.contains('width: halfW'), isTrue);
      expect(player.contains('right: 0,\n                            top: 0,\n                            bottom: 0,\n                            width: halfW,'), isTrue);
      expect(player.contains('VinylDisc('), isTrue);
    });

    test('transport row sits in the left half in landscape audio-only', () {
      expect(
        player.contains('MediaQuery.orientationOf(context) ==\n                              Orientation.landscape'),
        isTrue,
      );
      expect(player.contains('FractionallySizedBox('), isTrue);
      expect(player.contains('widthFactor: 0.5'), isTrue);
      expect(player.contains('Alignment.centerLeft'), isTrue);
    });
  });
}
