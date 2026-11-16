import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the skip-pill auto-hide (user request): the "Skip
/// intro/recap/credits" pill disappears 5 s after the playhead ENTERS a
/// segment, so a 1-2 minute recap no longer keeps the button on screen for
/// its whole length.
///
/// The player screen needs a live platform view, so the contract is read
/// out of the source: visibility honours the hide flag, the hide timer is
/// armed exactly once per entry, both engines drive it, and the timer is
/// cancelled on dispose / per-open reset.
void main() {
  final source = File('lib/screens/player_screen.dart').readAsStringSync();

  /// Slice of the source between two markers (pure: no expects, so it can
  /// be called from a top-level initializer as well as inside a test).
  String section(String startMarker, String endMarker) {
    final start = source.indexOf(startMarker);
    if (start < 0) return '';
    final end = source.indexOf(endMarker, start);
    return end > start ? source.substring(start, end) : source.substring(start);
  }

  /// The section with line comments stripped, so assertions match code only.
  String codeOf(String text) => text
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');

  final updater = codeOf(section(
    'void _updateSkipPill()',
    '/// Per-open reset of the skip-pill auto-hide state.',
  ));

  test('visibility honours the auto-hide flag', () {
    final getter = section(
      'bool get _skipIntroVisible',
      'void _updateSkipPill()',
    );
    expect(codeOf(getter), contains('_skipPillExpired'));
  });

  test('the hide window is 5 seconds', () {
    expect(source, contains('_skipPillVisibleFor = Duration(seconds: 5)'));
  });

  test('the timer arms once the playhead is INSIDE the segment', () {
    // The 5 s pre-roll lead (pill shown up to 5 s before a segment starts)
    // must not consume the hide window, so arming is gated on `inside`.
    expect(updater, contains('SkipSegments.inside(_allSkipSegments,'));
    expect(updater, contains('|| !inside) return;'));
  });

  test('the timer fires exactly once, not once per tick', () {
    // Without both guards a still-inside, already-expired pill would re-arm
    // on every position tick and never hide at all.
    expect(updater, contains('_skipPillTimer != null'));
    expect(updater, contains('(inside && _skipPillExpired && !_skipPillWasInside)'));
  });

  test('leaving the segment clears the state so re-entry re-shows the pill', () {
    // p == null (or pip / backend not ready) resets: the pill must come
    // back for 5 s when the user seeks into the segment again.
    expect(updater, contains('_resetSkipPill();'));
  });

  test('both engines drive the state machine on position updates', () {
    final handler = section(
      'void _onExoEvent(ExoPlayerEvent e)',
      'Future<void> _maybeAutoPlayNext() async',
    );
    expect(handler, contains('_updateSkipPill();'));

    final mpvListener = section(
      '_mpvSubs.add(player.stream.position.listen((v) {',
      '}));',
    );
    expect(mpvListener, contains('_updateSkipPill();'));
  });

  test('remote segments landing late re-run the state machine', () {
    // Issue #65: the pill pops up the moment the in-flight fetch lands, so
    // its hide window must start from that moment, not from the last tick.
    final merge = section(
      'Future<void> _mergeRemoteSegments(',
      '/// Legacy opt-in IntroDB lookup',
    );
    expect(merge, contains('_updateSkipPill();'));
    final fallback = section(
      'void _introDbFallback()',
      'void _skipSegment(SkipSegment',
    );
    expect(fallback, contains('_updateSkipPill();'));
  });

  test('per-open reset and dispose cancel the timer', () {
    final reset = section(
      'void _resetSkipPill()',
      'void _maybeRemoteSkipLookup()',
    );
    expect(codeOf(reset), contains('_skipPillTimer?.cancel();'));
    expect(codeOf(reset), contains('_skipPillExpired = false;'));

    final disposeSection = section('void dispose() {', 'void _restartHideTimer()');
    expect(disposeSection, contains('_skipPillTimer?.cancel();'));
  });

  test('the manual skip paths stay available while the pill is hidden', () {
    // The player menu rows are the fallback for the whole time the pill is
    // hidden; they must not share the pill's visibility.
    final rows = section(
      "if (_allSkipSegments.isNotEmpty) ...[",
      'List<SkipSegment> get _allSkipSegments',
    );
    expect(rows, contains('_tvListTile('));
    expect(rows, contains('_skipSegment(s);'));
  });
}