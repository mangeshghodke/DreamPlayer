import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The webpage's Cancel transfers / Clear list buttons must be the same size.
/// A stale standalone `.cancel { width: 100%; margin-top: 14px }` rule (from
/// the old single full-width button) made the flex row taller and the clear
/// button stretched to the full line while cancel kept its margin - visibly
/// unequal. These tests read both server pages (they cannot be rendered here).
void main() {
  final swift = File('ios/Runner/UploadServer.swift')
      .readAsStringSync()
      .replaceAll('\\"', '"'); // Swift string literals escape quotes
  final kt = File(
    'android/app/src/main/kotlin/com/dreamplayer/app/UploadServer.kt',
  ).readAsStringSync();

  for (final entry in {'swift': swift, 'kotlin': kt}.entries) {
    test('${entry.key}: both buttons sit in the .actions row', () {
      final src = entry.value;
      expect(src, contains('class="actions"'));
      expect(src, contains('class="cancel" id="cancel"'));
      expect(src, contains('class="clear" id="clear"'));
    });

    test('${entry.key}: action buttons are equal-width flex items', () {
      final src = entry.value;
      // flex: 1 1 0 + min-width: 0 makes both buttons exactly equal width
      // regardless of label length or emoji width.
      expect(src, contains('flex: 1 1 0'));
      expect(src, contains('min-width: 0'));
      expect(src, contains('align-items: stretch'));
      // The old full-width standalone button rule must not come back: no
      // rule that styles the transfers ACTIONS row may set a full width.
      // (Other buttons on the page may - the receive-folder chooser is a
      // single full-width button by design.)
      final rule = RegExp(r'\.[a-zA-Z-]+[^{]*\{[^}]*\}');
      var checked = 0;
      for (final m in rule.allMatches(src)) {
        final css = m.group(0)!;
        if (css.startsWith('.actions') ||
            css.startsWith('.cancel') ||
            css.startsWith('.clear')) {
          checked++;
          expect(css, isNot(contains('width: 100%')));
        }
      }
      expect(checked, greaterThan(0));
    });
  }
}
