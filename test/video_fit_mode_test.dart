import 'package:dream_player/services/exo_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the Nova-style aspect ratio / video format options.
///
/// Nova Video Player's PlayerActivity exposes a "Format" menu with 8 entries:
/// Original / Fullscreen / Stretched / 4:3 / 16:9 / 1.85:1 / 2.39:1 / Optimized.
/// DreamPlayer mirrors these as the `VideoFitMode` enum (8 values, matching
/// by enum order/labels). The "Optimized" entry is NOT included — it requires
/// per-screen AR detection that Nova handles internally on Android.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VideoFitMode enum', () {
    test('has 8 values matching Nova’s Format menu', () {
      expect(VideoFitMode.values.length, 8);
      // Order must match the Dart→native channel mapping in ExoPlayerView.kt.
      expect(VideoFitMode.values[0], VideoFitMode.fit);
      expect(VideoFitMode.values[1], VideoFitMode.fullscreen);
      expect(VideoFitMode.values[2], VideoFitMode.crop);
      expect(VideoFitMode.values[3], VideoFitMode.stretch);
      expect(VideoFitMode.values[4], VideoFitMode.ratio4x3);
      expect(VideoFitMode.values[5], VideoFitMode.ratio16x9);
      expect(VideoFitMode.values[6], VideoFitMode.ratio185);
      expect(VideoFitMode.values[7], VideoFitMode.ratio239);
    });

    test('stable integer values match the native channel protocol', () {
      // The channel sends `mode` as int; ExoPlayerView.kt has a when(mode) switch
      // that maps each integer to the right Media3 resize mode + forcedAspect.
      expect(VideoFitMode.fit.value, 0);
      expect(VideoFitMode.fullscreen.value, 1);
      expect(VideoFitMode.crop.value, 2);
      expect(VideoFitMode.stretch.value, 3);
      expect(VideoFitMode.ratio4x3.value, 4);
      expect(VideoFitMode.ratio16x9.value, 5);
      expect(VideoFitMode.ratio185.value, 6);
      expect(VideoFitMode.ratio239.value, 7);
    });

    test('labels match Nova’s string-array resource', () {
      expect(VideoFitMode.fit.label, 'Fit');
      expect(VideoFitMode.fullscreen.label, 'Fullscreen');
      expect(VideoFitMode.crop.label, 'Crop to screen');
      expect(VideoFitMode.stretch.label, 'Stretch to screen');
      expect(VideoFitMode.ratio4x3.label, '4:3');
      expect(VideoFitMode.ratio16x9.label, '16:9');
      expect(VideoFitMode.ratio185.label, '1.85:1');
      expect(VideoFitMode.ratio239.label, '2.39:1');
    });

    test('fixedAspect returns a double for the fixed-ratio modes', () {
      expect(VideoFitMode.ratio4x3.fixedAspect, closeTo(4.0 / 3.0, 1e-9));
      expect(VideoFitMode.ratio16x9.fixedAspect, closeTo(16.0 / 9.0, 1e-9));
      expect(VideoFitMode.ratio185.fixedAspect, closeTo(1.85, 1e-9));
      expect(VideoFitMode.ratio239.fixedAspect, closeTo(2.39, 1e-9));
    });

    test('fixedAspect is null for non-fixed modes', () {
      expect(VideoFitMode.fit.fixedAspect, isNull);
      expect(VideoFitMode.fullscreen.fixedAspect, isNull);
      expect(VideoFitMode.crop.fixedAspect, isNull);
      expect(VideoFitMode.stretch.fixedAspect, isNull);
    });

    test('fromValue round-trips every enum value', () {
      for (final m in VideoFitMode.values) {
        expect(VideoFitMode.fromValue(m.value), m);
      }
    });

    test('fromValue falls back to Fit on unknown / null', () {
      expect(VideoFitMode.fromValue(null), VideoFitMode.fit);
      expect(VideoFitMode.fromValue(-1), VideoFitMode.fit);
      expect(VideoFitMode.fromValue(99), VideoFitMode.fit);
    });
  });

  group('FitModeStore', () {
    test('defaults to Fit when nothing is persisted', () async {
      SharedPreferences.setMockInitialValues({});
      final mode = await FitModeStore.load();
      expect(mode, VideoFitMode.fit);
    });

    test('persists and reloads the chosen mode (round-trip)', () async {
      SharedPreferences.setMockInitialValues({});
      for (final m in VideoFitMode.values) {
        await FitModeStore.save(m);
        expect(await FitModeStore.load(), m);
      }
    });

    test('persists the new Nova-style modes (1.85:1, 2.39:1, Fullscreen)', () async {
      SharedPreferences.setMockInitialValues({});
      await FitModeStore.save(VideoFitMode.fullscreen);
      expect((await FitModeStore.load()).value, 1);
      await FitModeStore.save(VideoFitMode.ratio185);
      expect((await FitModeStore.load()).value, 6);
      await FitModeStore.save(VideoFitMode.ratio239);
      expect((await FitModeStore.load()).value, 7);
    });
  });
}
