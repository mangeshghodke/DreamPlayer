import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins that iOS has NO volume boost and NO bass boost.
///
/// The boost is engine DSP on iOS, and every DSP change makes the engine
/// rebuild the audio session at the playhead (`reanchorForAudioShaping` ->
/// `reloadAtCurrentPosition`) — which reloads the video. A boost that rides
/// the volume swipe therefore reloaded the picture on every step above 100%
/// (the user report: "as I increase volume above 100% every volume number
/// reloads the video").
///
/// The bass boost has the same shape (a stage in the same filter chain, so
/// changing it rebuilds the session too) and was unreachable anyway: its row
/// only appears while spatial audio is engaged.
///
/// So the iOS gesture stops at 100%, the Settings row is gone, the native
/// shaping carries no make-up gain and no low shelf, and both channel
/// methods are logged no-ops. Night mode and spatial audio stay.
/// Android keeps its boost and bass — there the boost is a PCM gain in the
/// audio sink (live, with a peak limiter) and the bass is a session effect.
///
/// The rules are read out of the source instead of pumped as a widget: the
/// player screen needs a live platform view, and these are properties of the
/// source tree, not of the rendered pixels.
void main() {
  final player = File('lib/screens/player_screen.dart').readAsStringSync();
  final settings =
      File('lib/screens/settings_screen.dart').readAsStringSync();
  final swift = File('ios/Runner/AvPlayerView.swift').readAsStringSync();
  final paywall = File('lib/screens/paywall_sheet.dart').readAsStringSync();

  test('the player clamps the boost off on iOS', () {
    expect(
      player.contains('_volumeBoostEnabled = !Platform.isIOS'),
      isTrue,
      reason: 'iOS must not run the boost',
    );
  });

  test('the Settings row for the boost is Android-only', () {
    final row = settings.indexOf('settingsVolumeBoost');
    expect(row, greaterThan(-1), reason: 'the row moved');
    final start = settings.lastIndexOf('if (', row);
    final slice = settings.substring(start, row);
    expect(
      slice.contains('TargetPlatform.android'),
      isTrue,
      reason: 'the boost row must not be offered on iOS',
    );
    expect(
      slice.contains('TargetPlatform.iOS'),
      isFalse,
      reason: 'the boost row must not be offered on iOS',
    );
  });

  test('the native shaping carries no make-up gain from a boost', () {
    final make = swift.indexOf('private func makeAudioShaping()');
    expect(make, greaterThan(-1));
    final body = swift.substring(make, make + 1800);
    expect(
      body.contains('boostDB'),
      isFalse,
      reason: 'the iOS shaping must not carry a boost make-up gain',
    );
    expect(
      body.contains('bassGainDB'),
      isFalse,
      reason: 'the iOS shaping must not carry a bass shelf',
    );
    expect(
      body.contains('nightModeEnabled'),
      isTrue,
      reason: 'night mode stays on iOS',
    );
  });

  test('the native bass channel method is a logged no-op', () {
    final start = swift.indexOf('case "setBassBoost":');
    expect(start, greaterThan(-1));
    final body = swift.substring(start, start + 400);
    expect(
      body.contains('ignored on iOS'),
      isTrue,
      reason: 'a stale call must not resurrect the bass shelf',
    );
    expect(
      body.contains('applyAudioShaping()'),
      isFalse,
      reason: 'the bass must not touch the engine shaping',
    );
  });

  test('the bass row in the player menu is Android-only', () {
    final row = player.indexOf('playerBassBoostTitle');
    expect(row, greaterThan(-1), reason: 'the row moved');
    final start = player.lastIndexOf('if (', row);
    final slice = player.substring(start, row);
    expect(
      slice.contains('TargetPlatform.android'),
      isTrue,
      reason: 'the bass row must not be offered on iOS',
    );
  });

  test('the native boost channel method is a logged no-op', () {
    final start = swift.indexOf('case "setAudioBoost":');
    expect(start, greaterThan(-1));
    final body = swift.substring(start, start + 400);
    expect(
      body.contains('ignored on iOS'),
      isTrue,
      reason: 'a stale call must not resurrect the boost',
    );
    expect(
      body.contains('applyAudioShaping()'),
      isFalse,
      reason: 'the boost must not touch the engine shaping',
    );
  });

  test('the paywall list does not promise a boost', () {
    expect(
      paywall.contains('Volume boost'),
      isFalse,
      reason: 'the subscription must not advertise a feature that is gone',
    );
    expect(
      paywall.contains('Night mode'),
      isTrue,
      reason: 'night mode stays in the subscription',
    );
    expect(
      paywall.contains('Bass boost'),
      isFalse,
      reason: 'the subscription must not advertise a feature that is gone',
    );
  });
}
