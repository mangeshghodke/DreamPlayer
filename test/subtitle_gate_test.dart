import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Subtitle styling is a paywalled iOS feature (#36), and the caption font
/// picker — the six built-ins, the nine bundled families and the whole Google
/// Fonts catalog — lives inside `SubtitleSettingsScreen`. So the screen is the
/// chokepoint: one ungated route and every font becomes free.
///
/// Android must stay immune (hardcoded `advanced = true` in `Entitlements`),
/// which `checkGate` already gives us; what this file pins is that the gate is
/// still ON the only route into the screen.
void main() {
  final player = File('lib/screens/player_screen.dart').readAsStringSync();
  final settings =
      File('lib/screens/subtitle_settings_screen.dart').readAsStringSync();

  test('the font picker is private to the subtitle settings screen', () {
    final otherSources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('subtitle_settings_screen.dart'));

    for (final file in otherSources) {
      final text = file.readAsStringSync();
      expect(text, isNot(contains('_SubtitleFontSheet')),
          reason: '${file.path} reaches the font sheet directly — it must be '
              'opened only from the gated SubtitleSettingsScreen');
    }

    // The sheet itself is only built by `_openFontPicker` (the declaration's
    // own constructor call is the other match, so match the builder).
    final opens =
        RegExp(r'=> _SubtitleFontSheet\(').allMatches(settings).length;
    expect(opens, 1,
        reason: 'one construction site keeps the picker a single control');
  });

  test('the subtitle settings screen has exactly one entry point', () {
    final routes = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('subtitle_settings_screen.dart'))
        .expand((f) => RegExp(r'SubtitleSettingsScreen')
            .allMatches(f.readAsStringSync())
            .map((m) => '${f.path}:${m.start}'))
        .toList();

    // Mentions in its own file (declaration, state class) do not count; the
    // only other mention must be the push in the player CC sheet.
    expect(routes, hasLength(1),
        reason: 'a second route into subtitle styling would bypass the '
            'paywall unless it also calls _gate()');
    expect(routes.single, contains('player_screen.dart'));
  });

  test('the route is guarded by _gate() before it pushes', () {
    final push = player.indexOf('SubtitleSettingsScreen');
    expect(push, isNonNegative);
    final before = player.substring(0, push);
    final guard = before.lastIndexOf('await _gate()');
    expect(guard, isNonNegative,
        reason: 'SubtitleSettingsScreen must be gated on iOS (#36)');

    // The gate must short-circuit, not just be awaited.
    expect(before.substring(guard, guard + 40), contains('_gate()'));
    expect(before.substring(guard, push), contains('return;'),
        reason: 'a failed gate has to abort the navigation');

    // And nothing in between may bypass it by resetting the guard.
    expect(before.substring(guard, push), isNot(contains('_gate = ')));
  });

  test('_gate consults the single entitlement authority', () {
    final start = player.indexOf('Future<bool> _gate()');
    expect(start, isNonNegative);
    // Read the whole method body — a fixed character window silently stops
    // covering the body as soon as a comment is added to it.
    final end = player.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final body = player.substring(start, end);
    expect(body, contains('checkGate('));
    expect(body, contains('advanced: Entitlements.instance.isEntitled'));
    expect(body, contains('paywallActive: Entitlements.instance.effectivePaywallEnabled'));
    expect(body, contains('showPaywall('));
  });
}
