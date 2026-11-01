import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the press-and-hold temporary 2x boost (issue #57).
///
/// The player screen needs a live platform view, so the contract is read
/// out of the source: a hold raises the rate to 2x, releasing restores the
/// user's own speed, the stored preference is never touched, and the
/// gesture is excluded where it makes no sense (TV, pip, touch-locked,
/// paused, not-yet-ready backend).
void main() {
  final source = File('lib/screens/player_screen.dart').readAsStringSync();

  String section(String startMarker, String endMarker) {
    final start = source.indexOf(startMarker);
    expect(start, greaterThan(-1), reason: '$startMarker moved');
    final end = source.indexOf(endMarker, start);
    expect(end, greaterThan(start), reason: '$endMarker not found after $startMarker');
    return source.substring(start, end);
  }

  /// The section with line comments stripped, so assertions match code only.
  String codeOf(String text) => text
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');

  test('the tap catcher registers a 300 ms long-press deadline', () {
    final catcher = section(
      'child: RawGestureDetector(',
      '// Error / placeholder content lives ABOVE',
    );
    expect(catcher, contains('LongPressGestureRecognizer:'));
    expect(
      catcher,
      contains('duration: const Duration(milliseconds: 300)'),
      reason: "GestureDetector's fixed 500 ms deadline is too slow to read "
          'as deliberate next to the 260 ms tap window',
    );
    for (final other in [
      'TapGestureRecognizer:',
      'DoubleTapGestureRecognizer:',
      'ScaleGestureRecognizer:',
    ]) {
      expect(
        catcher,
        contains(other),
        reason: 'the existing recognizers must survive the conversion',
      );
    }
  });

  test('the hold applies 2x through the live engine', () {
    final hold = section(
      '// ---- Press-and-hold temporary 2x boost',
      '// ---- Unified gesture handling',
    );
    expect(hold.length, greaterThan(500), reason: 'the hold section moved');
    expect(hold, contains('_speedHoldRate = 2.0'));
    expect(hold, contains('_onLongPressStart'));
    expect(hold, contains('_applyHoldRate('));
    expect(hold, contains('_mpvPlayer?.setRate(rate)'));
    expect(hold, contains('_exo?.setSpeed(rate)'));
  });

  test('release restores the user speed and never persists the hold', () {
    final hold = section(
      '// ---- Press-and-hold temporary 2x boost',
      '// ---- Unified gesture handling',
    );
    final endHold = hold.indexOf('void _endSpeedHold()');
    expect(endHold, greaterThan(-1));
    final body = hold.substring(endHold);
    expect(body, contains('_applyHoldRate(_playbackSpeed)'));
    final code = codeOf(hold);
    expect(
      code,
      isNot(contains('PlaybackSpeedStore')),
      reason: 'the boost is session state — the saved preference must not '
          'learn about 2x',
    );
    expect(
      code,
      isNot(contains('_playbackSpeed = ')),
      reason: 'the hold must leave the UI speed untouched',
    );
  });

  test('the hold is excluded where it makes no sense', () {
    final hold = section(
      '// ---- Press-and-hold temporary 2x boost',
      '// ---- Unified gesture handling',
    );
    final guard = hold.indexOf('_isTv || !_backendReady || _touchLocked || _inPip');
    expect(guard, greaterThan(-1), reason: 'the entry guards moved');
    expect(hold, contains("!_playing"));
  });

  test('the hold passes the speed gate before applying anything', () {
    final hold = section(
      '// ---- Press-and-hold temporary 2x boost',
      '// ---- Unified gesture handling',
    );
    final gateAt = hold.indexOf('!await _gate()');
    final applyAt = hold.indexOf('_speedHoldActive = true');
    final guardAt = hold.indexOf('_isTv || !_backendReady || _touchLocked || _inPip');
    expect(gateAt, greaterThan(-1), reason: 'the gate call moved');
    expect(gateAt, greaterThan(guardAt));
    expect(applyAt, greaterThan(gateAt));
  });

  test('the badge shows while the hold is active', () {
    final badge = section(
      '// Hold-to-2x badge (issue #57)',
      '// Horizontal-swipe seek preview (timestamp + frame thumbnail)',
    );
    expect(badge, contains('if (_speedHoldActive)'));
    expect(badge, contains('speedLabel(_speedHoldRate)'));
    expect(badge, contains('IgnorePointer'));
    final badgePos = source.indexOf('// Hold-to-2x badge (issue #57)');
    final seekPos = source.indexOf('// Horizontal-swipe seek preview (timestamp + frame thumbnail)');
    final stackPos = source.indexOf('child: Stack(');
    expect(badgePos, greaterThan(stackPos), reason: 'badge must be inside the video Stack');
    expect(badgePos, lessThan(seekPos), reason: 'badge must be above seek preview in the Stack');
  });

  test('the hold never survives an open', () {
    final open = section(
      'Future<void> _openCurrent() async',
      'final cachedMeta = TmdService.instance.metaFor',
    );
    final reset = open.indexOf('_speedHoldActive = false;');
    expect(reset, greaterThan(-1), reason: '_openCurrent must clear the hold state');
    // The reset belongs to the per-open state block at the top, before the
    // decoder override is restored and long before any playback starts.
    final decoderRestore = open.indexOf('_restoreDecoderOverride()');
    expect(decoderRestore, greaterThan(-1));
    expect(reset, lessThan(decoderRestore), reason: 'the reset belongs near the per-open state block');
  });
}