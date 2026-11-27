import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Vinyl disc behavior (2026-11-27): the disc just SPINS while audio plays.
/// The DJ scratch (drag-to-scrub, flick-to-spin) was built, then removed the
/// same day - relative seeks on the stale ~1/s _position made the audio run
/// away and neither engine can reverse, so it never felt like a turntable
/// (user report). Pins: no gesture handlers on the disc, spin via ticker,
/// title anchored below the disc. The player screen needs a live platform
/// view, so the wiring is pinned by reading the source.
void main() {
  final player = File('lib/screens/player_screen.dart').readAsStringSync();
  final vinyl = File('lib/widgets/vinyl_disc.dart').readAsStringSync();

  group('vinyl disc: spin only, no DJ scratch (source-reading)', () {
    test('disc rotation is parent-driven by the spin ticker', () {
      expect(vinyl, contains('Transform.rotate('));
      expect(vinyl, contains('required this.angle'));
      expect(player.contains('TickerProviderStateMixin'), isTrue);
      expect(player.contains('createTicker(_discTick)'), isTrue);
      expect(player.contains('_discAngle +='), isTrue);
      // spins only while playing
      expect(player.contains('if (!(_playing && !_buffering)) return;'), isTrue);
    });

    test('DJ scratch removed: no pan handlers, no scratch seek, no rate flick', () {
      expect(player, isNot(contains('_onDiscPanUpdate')));
      expect(player, isNot(contains('_onDiscPanStart')));
      expect(player, isNot(contains('_onDiscPanEnd')));
      expect(player, isNot(contains('_scratchPos')));
      expect(player, isNot(contains('_seekBackend(_scratchPos)')));
      expect(player, isNot(contains('_spinDecayTimer')));
      expect(player, isNot(contains('scratchSecondsPerTurn')));
      expect(player, isNot(contains('spinVelocityThreshold')));
      // the disc layer has no GestureDetector anymore
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
