import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// DJ-style interactive vinyl disc (user request 2026-11-27): dragging around
/// the disc scrubs the audio (clockwise forward / anticlockwise back), a fast
/// flick on release keeps the disc spinning and speeds playback up, decaying
/// back to normal. The player screen needs a live platform view, so the wiring
/// is pinned by reading the source.
void main() {
  final player = File('lib/screens/player_screen.dart').readAsStringSync();
  final vinyl = File('lib/widgets/vinyl_disc.dart').readAsStringSync();

  group('DJ disc (source-reading)', () {
    test('disc rotation is parent-driven, shared by ticker and gestures', () {
      expect(vinyl, contains('Transform.rotate('));
      expect(vinyl, contains('required this.angle'));
      expect(vinyl, isNot(contains('AnimationController')));
      expect(player.contains('TickerProviderStateMixin'), isTrue);
      expect(player.contains('createTicker(_discTick)'), isTrue);
      expect(player.contains('_discAngle +='), isTrue);
    });

    test('disc sits in the main stack inside a pan GestureDetector', () {
      expect(
        player.contains('if (_isAudioOnly && _error == null && !_inPip)'),
        isTrue,
      );
      expect(player.contains('onPanStart: _onDiscPanStart'), isTrue);
      expect(player.contains('onPanUpdate: _onDiscPanUpdate'), isTrue);
      expect(player.contains('onPanEnd: _onDiscPanEnd'), isTrue);
      expect(player.contains('VinylDisc('), isTrue);
      expect(player.contains('angle: _discAngle'), isTrue);
    });

    test('angular delta maps to scratch seek, clockwise forward', () {
      expect(player.contains('math.atan2'), isTrue);
      expect(player.contains('scratchSecondsPerTurn'), isTrue);
      // delta sign is preserved (no abs) so anticlockwise scrubs backwards.
      expect(player.contains('_scratchAccumSec += delta'), isTrue);
      expect(player.contains('_seekBy(Duration(milliseconds: ms))'), isTrue);
    });

    test('fast flick on release spins the disc and changes playback rate', () {
      expect(player.contains('spinVelocityThreshold'), isTrue);
      expect(player.contains('_discSpinRevPerSec'), isTrue);
      expect(player.contains('_applyHoldRate(_spinRate)'), isTrue);
      // non-1x rate is paywall-gated on iOS like the hold-2x
      expect(player.contains('if (!await _gate())'), isTrue);
      // decays back to the user's speed
      expect(player.contains('_playbackSpeed - _spinRate'), isTrue);
    });

    test('disc state resets on new file and on dispose', () {
      expect(player.contains('_resetDiscSpin();'), isTrue);
      expect(player.contains('_discTicker?.stop();'), isTrue);
      expect(player.contains('_spinDecayTimer?.cancel();'), isTrue);
    });

    test('landscape keeps the disc in the right half', () {
      expect(player.contains('width: mq.width / 2'), isTrue);
      expect(player.contains('right: 0,'), isTrue);
    });
  });
}
