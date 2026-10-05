import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/utils/mpv_volume.dart';

void main() {
  group('mpvVolumePercent', () {
    test('no boost is just the system volume', () {
      expect(mpvVolumePercent(baseFraction: 1.0, audioBoost: 1.0, nightMode: false), 100);
      expect(mpvVolumePercent(baseFraction: 0.6, audioBoost: 1.0, nightMode: false), 60);
      expect(mpvVolumePercent(baseFraction: 0.0, audioBoost: 1.0, nightMode: false), 0);
    });

    // The actual #41 report: boost 3x at full volume should be 300.
    test('boost scales the base volume', () {
      expect(mpvVolumePercent(baseFraction: 1.0, audioBoost: 3.0, nightMode: false), 300);
      expect(mpvVolumePercent(baseFraction: 1.5, audioBoost: 2.0, nightMode: false), 300);
    });

    // The regression the reporter found: the swipe gesture used to write the
    // raw base through, so any swipe silently discarded the boost.
    test('swiping volume KEEPS the boost instead of wiping it', () {
      const boost = 3.0;
      expect(
        mpvVolumePercent(baseFraction: 0.6, audioBoost: boost, nightMode: false),
        180,
        reason: 'swiping to 60% must not drop back to 60',
      );
      // Relative loudness is preserved across the gesture.
      final full = mpvVolumePercent(baseFraction: 1.0, audioBoost: boost, nightMode: false);
      final half = mpvVolumePercent(baseFraction: 0.5, audioBoost: boost, nightMode: false);
      expect(half, closeTo(full / 2, 0.001));
    });

    test('night mode stacks on top of boost', () {
      expect(mpvVolumePercent(baseFraction: 1.0, audioBoost: 1.0, nightMode: true), 160);
      expect(
        mpvVolumePercent(baseFraction: 1.0, audioBoost: 1.25, nightMode: true),
        200,
      );
    });

    test('ignores a negligible boost so it cannot nudge the volume', () {
      expect(mpvVolumePercent(baseFraction: 1.0, audioBoost: 1.005, nightMode: false), 100);
    });

    // mpv clamps volume to volume-max, so the helper must never hand it a value
    // above the ceiling it configures.
    test('clamps at the fixed ceiling', () {
      expect(
        mpvVolumePercent(baseFraction: 1.0, audioBoost: 3.0, nightMode: true),
        kMpvVolumeMax,
      );
      expect(
        mpvVolumePercent(baseFraction: 1.0, audioBoost: 10.0, nightMode: false),
        kMpvVolumeMax,
      );
    });

    test('never returns a negative volume', () {
      expect(
        mpvVolumePercent(baseFraction: -0.5, audioBoost: 3.0, nightMode: false),
        0,
      );
    });
  });
}
