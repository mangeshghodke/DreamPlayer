import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Vinyl disc (audio-only playback): the disc just SPINS while audio plays,
/// via its own AnimationController (the pre-DJ implementation, restored
/// 2026-11-27 after the parent-driven Transform.rotate variant spun ever
/// faster - a Ticker callback receives TOTAL elapsed time, not the per-frame
/// delta, so accumulating it quadratically sped the disc up). The DJ scratch
/// (drag-to-scrub, flick-to-spin) was removed the same day: no engine can
/// reverse, so it never felt like a turntable. Pins: no gesture handlers on
/// the disc, spin via spinning prop, title anchored below the disc. The
/// player screen needs a live platform view, so wiring is pinned by source.
void main() {
  final player = File('lib/screens/player_screen.dart').readAsStringSync();
  final vinyl = File('lib/widgets/vinyl_disc.dart').readAsStringSync();

  group('vinyl disc: spin only (source-reading)', () {
    test('widget spins via its own AnimationController, not a parent ticker', () {
      expect(vinyl, contains('AnimationController'));
      expect(vinyl, contains('RotationTransition'));
      expect(vinyl, contains('_controller.repeat()'));
      expect(vinyl, contains('required this.spinning'));
      // no parent-driven angle, no Ticker in the player
      expect(vinyl, isNot(contains('Transform.rotate')));
      expect(player, isNot(contains('TickerProviderStateMixin')));
      expect(player, isNot(contains('createTicker')));
      expect(player.contains('spinning: _playing && !_buffering'), isTrue);
    });

    test('no DJ scratch: no pan handlers or scratch state left', () {
      expect(player, isNot(contains('_onDiscPanUpdate')));
      expect(player, isNot(contains('_onDiscPanStart')));
      expect(player, isNot(contains('_scratchPos')));
      expect(player, isNot(contains('_spinDecayTimer')));
      final layerAt = player.indexOf('if (_isAudioOnly && _error == null && !_inPip)');
      expect(layerAt, greaterThan(-1));
      final layer = player.substring(layerAt, layerAt + 3200);
      expect(layer, isNot(contains('GestureDetector')));
      expect(layer, contains('VinylDisc('));
    });

    test('title is anchored BELOW the disc, not behind it', () {
      expect(
        player.contains('constraints.maxHeight / 2 + discSize / 2 + 12'),
        isTrue,
      );
      // clamped so short screens cannot push it off the bottom
      expect(player.contains('constraints.maxHeight - 96'), isTrue);
    });

    test('landscape keeps the disc in the right half', () {
      expect(player.contains('width: mq.width / 2'), isTrue);
      expect(player.contains('right: 0,'), isTrue);
    });
  });
}
