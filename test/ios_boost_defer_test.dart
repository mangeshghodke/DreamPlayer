import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins how the volume gesture reaches the engine's boost.
///
/// iOS applies the boost as engine DSP and EVERY DSP change rebuilds the
/// audio session (~0.3 s of held picture), so pushing the value on every
/// gesture increment reloads the video on every step — the user sees the
/// picture reload as the volume climbs past 100%.
///
/// The gesture therefore does NOT push the boost while it runs on iOS: the
/// final value is pushed once, when the gesture ends. Android applies the
/// boost as a PCM gain, which is live, so it keeps pushing per increment.
///
/// The rules are read out of the source instead of pumped as a widget: the
/// player screen needs a live platform view, and these are properties of the
/// source tree, not of the rendered pixels.
void main() {
  final source = File('lib/screens/player_screen.dart').readAsStringSync();

  test('the gesture defers the iOS boost to the end of the swipe', () {
    final live = source.indexOf('bool get _boostAppliesLive');
    expect(live, greaterThan(-1), reason: 'the platform split disappeared');
    expect(
      source.substring(live, live + 200),
      contains('TargetPlatform.iOS'),
      reason: 'iOS must be the platform that defers the boost',
    );

    final apply = source.indexOf('void _applySwipeValue()');
    final end = source.indexOf('void _endSwipe()');
    expect(apply, greaterThan(-1));
    expect(end, greaterThan(apply));

    final swipe = source.substring(apply, end);
    expect(
      swipe.contains('if (boostChanged && !_boostAppliesLive)'),
      isTrue,
      reason: 'the gesture must not push the boost on iOS',
    );
  });

  test('the end of the swipe pushes the final boost once', () {
    final end = source.indexOf('void _endSwipe()');
    expect(end, greaterThan(-1));
    final body = source.substring(end, end + 700);
    expect(
      body.contains('_SwipeType.volume && !_boostAppliesLive'),
      isTrue,
      reason: 'the volume gesture end must push the boost on iOS',
    );
    expect(
      body.contains('setAudioBoost(_audioBoost)'),
      isTrue,
      reason: 'the final boost value must reach the engine',
    );
  });

  test('an unchanged system volume is not pushed again', () {
    final apply = source.indexOf('void _applySwipeValue()');
    final end = source.indexOf('void _endSwipe()');
    final swipe = source.substring(apply, end);
    expect(
      swipe.contains('if (systemChanged) _exo?.setSystemVolume(split.system);'),
      isTrue,
      reason: 'the pinned-at-max system volume must not be re-pushed',
    );
  });

  test('the native side debounces the shaping apply', () {
    final swift = File('ios/Runner/AvPlayerView.swift').readAsStringSync();
    final apply = swift.indexOf('private func applyAudioShaping()');
    expect(apply, greaterThan(-1));
    final body = swift.substring(apply, apply + 1600);
    expect(
      body.contains('shapingWorkItem?.cancel()'),
      isTrue,
      reason: 'a burst of changes must fold into one session rebuild',
    );
    expect(
      body.contains('engine.state == .playing'),
      isFalse,
      reason:
          'the debounce must not depend on the engine state: the rebuild '
          'itself puts the engine into .loading, so a state-based check '
          'would apply the next change immediately and rebuild again',
    );
  });
}
