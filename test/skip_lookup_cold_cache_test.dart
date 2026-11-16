import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the cold-cache skip-pill race (issue #65): on the FIRST play of a new
/// episode/movie the TMDB match (and sometimes the season list) resolves
/// AFTER the first playback event, so `_maybeRemoteSkipLookup` must not latch
/// its "already looked up" flag while metadata is missing - it has to re-fire
/// when the match lands, or the Skip pill only appears on the second play.
///
/// The player screen needs a live platform view, so the contract is read out
/// of the source, the same pattern as hold_speed_test.dart.
void main() {
  final source = File('lib/screens/player_screen.dart').readAsStringSync();

  /// Sections are resolved lazily inside each test - expect() may not run at
  /// main() level.
  String section(String startMarker, String endMarker) {
    final start = source.indexOf(startMarker);
    if (start < 0) fail('$startMarker moved');
    final end = source.indexOf(endMarker, start);
    if (end <= start) fail('$endMarker not found after $startMarker');
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

  String lookup() => codeOf(section(
        'void _maybeRemoteSkipLookup()',
        'Future<void> _mergeRemoteSegments(',
      ));

  test('the lookup latch only sticks on a definitive decision', () {
    // The latch must NOT be set before the early returns - the original bug
    // set it on the first line, so a null _tmdbMeta on a cold first play
    // permanently killed the lookup.
    final lk = lookup();
    final firstLatch = lk.indexOf('_remoteSkipLookedUp = true');
    expect(firstLatch, greaterThan(0));
    expect(
      lk.substring(0, firstLatch),
      isNot(contains('_remoteSkipLookedUp = true')),
      reason: 'no latch before the off/covered/meta guards',
    );
    expect(lk, contains('if (_remoteSkipLookedUp || _remoteSkipInFlight) return;'));
  });

  test('missing metadata returns WITHOUT latching (cold-cache re-fire)', () {
    final lk = lookup();
    final metaNull = lk.indexOf('if (meta == null || tmdbId == null)');
    expect(metaNull, greaterThan(-1), reason: 'meta-null guard moved');
    final branch = lk.substring(metaNull, metaNull + 400);
    expect(codeOf(branch), contains('return;'));
    expect(
      codeOf(branch),
      isNot(contains('_remoteSkipLookedUp = true')),
      reason: 'the meta-null branch must leave the lookup unlatched so it '
          're-fires when the TMDB match lands (issue #65)',
    );
  });

  test('unparsed TV episode with no cached seasons also retries later', () {
    final lk = lookup();
    final epNull = lk.indexOf('if (ep == null)');
    expect(epNull, greaterThan(-1), reason: 'ep-null guard moved');
    final branch = codeOf(lk.substring(epNull, epNull + 500));
    expect(branch, contains('wide.seasons.isEmpty'));
    expect(
      branch.substring(0, branch.indexOf('wide.seasons.isEmpty')),
      isNot(contains('_remoteSkipLookedUp = true')),
      reason: 'seasons-not-cached-yet must not latch either',
    );
  });

  test('remote fetch is guarded against duplicates and always released', () {
    expect(lookup(), contains('_remoteSkipInFlight = true'));
    final merge = codeOf(section(
      'Future<void> _mergeRemoteSegments(',
      'void _introDbFallback()',
    ));
    expect(merge, contains('finally'));
    expect(merge, contains('_remoteSkipInFlight = false'));
  });

  test('the legacy IntroDB fallback fires at most once per open', () {
    final fallback = codeOf(section('void _introDbFallback()', 'void _skipSegment('));
    expect(fallback, contains('if (!IntroDb.available || _introDbFallbackFired) return;'));
    expect(fallback, contains('_introDbFallbackFired = true;'));
  });

  test('metadata arriving mid-playback re-fires the lookup', () {
    final onChanged = section('void _onTmdbChanged()', 'void _pushNowPlayingMetadata()');
    expect(onChanged, contains('_maybeRemoteSkipLookup();'));

    final open = section('final cachedMeta = TmdService.instance.metaFor(_resumeKey);', '// A-B loop points are per-video.');
    expect(open, contains('_maybeRemoteSkipLookup();'));
  });

  test('all three latches reset per open', () {
    final reset = section('_remoteSegments = const [];', '_autoSkippedStarts.clear();');
    expect(reset, contains('_remoteSkipLookedUp = false;'));
    expect(reset, contains('_remoteSkipInFlight = false;'));
    expect(reset, contains('_introDbFallbackFired = false;'));
  });

  test('segments landing mid-playback re-evaluate the pill via setState', () {
    final merge = section('Future<void> _mergeRemoteSegments(', 'void _introDbFallback()');
    expect(merge, contains('setState(() => _remoteSegments = merged)'));
  });
}
