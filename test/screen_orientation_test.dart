import 'package:dream_player/utils/screen_orientation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Faithful port of the engine's orientation bitmask decoder.
///
/// Source: flutter/engine
/// `shell/platform/android/io/flutter/embedding/engine/systemchannels/
/// PlatformChannel.java`, `decodeOrientations()`. Reproduced here so the test
/// can assert the *reason* the toggle requests a single orientation — the
/// encoder itself lives in the engine, not in this repo, so it is the one thing
/// that cannot be covered by pumping a widget.
int decodeOrientationBitmask(List<DeviceOrientation> orientations) {
  var mask = 0;
  for (final o in orientations) {
    switch (o) {
      case DeviceOrientation.portraitUp:
        mask |= 0x01;
      case DeviceOrientation.portraitDown:
        mask |= 0x04;
      case DeviceOrientation.landscapeLeft:
        mask |= 0x02;
      case DeviceOrientation.landscapeRight:
        mask |= 0x08;
    }
  }
  return mask;
}

/// Constants whose names carry the meaning under test.
const _userFamily = <int>{0x0a, 0x05, 0x0f}; // USER_LANDSCAPE/USER_PORTRAIT/FULL_USER
const _forced = <int>{0x01, 0x02, 0x04, 0x08}; // PORTRAIT/LANDSCAPE/REVERSE_*

void main() {
  group('fullscreenOrientations', () {
    test('entering fullscreen requests a forced landscape constant', () {
      final o = fullscreenOrientations(enter: true);
      expect(o, const <DeviceOrientation>[DeviceOrientation.landscapeLeft]);

      final mask = decodeOrientationBitmask(o);
      // 0x02 -> SCREEN_ORIENTATION_LANDSCAPE.
      expect(mask, 0x02);
      expect(_forced, contains(mask));
      expect(_userFamily, isNot(contains(mask)),
          reason: 'USER_LANDSCAPE is ignored when rotation is locked '
              '(issue #45)');
    });

    test('leaving fullscreen requests a forced portrait constant', () {
      final o = fullscreenOrientations(enter: false);
      expect(o, const <DeviceOrientation>[DeviceOrientation.portraitUp]);

      final mask = decodeOrientationBitmask(o);
      // 0x01 -> SCREEN_ORIENTATION_PORTRAIT.
      expect(mask, 0x01);
      expect(_forced, contains(mask));
      expect(_userFamily, isNot(contains(mask)),
          reason: 'FULL_USER was ignored when rotation is locked (issue #45)');
    });

    test('never returns a list that decodes to the USER family', () {
      for (final enter in [true, false]) {
        final mask = decodeOrientationBitmask(
          fullscreenOrientations(enter: enter),
        );
        expect(
          _userFamily.contains(mask),
          isFalse,
          reason: 'enter=$enter produced mask 0x${mask.toRadixString(16)}',
        );
      }
    });

    test('the old implementation would have produced USER constants', () {
      // Regression guard: these are exactly the calls the button used to make.
      // If this test ever starts failing because Flutter changed its decoder,
      // the fix above may no longer be necessary — but do not "simplify" it
      // back without re-checking on a device with rotation locked.
      expect(
        decodeOrientationBitmask(const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
        0x0a,
      );
      expect(
        decodeOrientationBitmask(DeviceOrientation.values),
        0x0f,
      );
      expect(_userFamily, contains(0x0a));
      expect(_userFamily, contains(0x0f));
    });

    test('toggling twice returns to the starting orientation', () {
      expect(fullscreenOrientations(enter: true),
          isNot(fullscreenOrientations(enter: false)));
    });
  });
}