import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The player screen needs a live platform view, so it cannot be pumped as a
/// widget — these tests read the source, like player_transport_order_test.dart.
///
/// Regression pin for the 2026-11-12 iOS crash (dreamplayer_crash.log):
/// the swipe overlay's `Positioned.fill` slider was placed inside a `Column`
/// (a Flex). On mount, `Positioned.applyParentData` casts the child's
/// FlexParentData to StackParentData and throws — the whole frame fails,
/// the screen goes grey, the video platform view is lost and only audio
/// keeps playing. `Positioned*` is only legal as a DIRECT child of a `Stack`.
void main() {
  final src = File('lib/screens/player_screen.dart').readAsStringSync();

  test('swipe overlay renders the slider as a direct Stack child, never inside a Column', () {
    const marker = '// Swipe-gesture feedback overlay';
    final start = src.indexOf(marker);
    expect(start, isNot(-1), reason: 'swipe overlay block not found');
    // The block runs until the next sibling in the outer Stack's children.
    final end = src.indexOf('if (_buffering && _backendReady', start);
    expect(end, isNot(-1), reason: 'end of swipe overlay block not found');
    final block = src.substring(start, end);

    expect(block.contains('Positioned.fill'), isTrue,
        reason: 'the opposite-side slider must still be rendered');
    expect(block.contains('Column('), isFalse,
        reason: 'a Positioned inside a Column (Flex) throws '
            '"FlexParentData is not a subtype of StackParentData" on mount '
            'and kills the whole player frame (iOS crash 2026-11-12)');
    // The spread form ...[ Center(...), Positioned.fill(...) ] is what puts
    // the Positioned at Stack level.
    expect(block.contains('...['), isTrue,
        reason: 'overlay must spread multiple direct Stack children');
  });

  test('no Positioned widget appears inside any Column in the file', () {
    // Belt-and-braces: scan every Column( ... ) span for a nested Positioned.
    // (Column bodies here are short enough that a naive span scan is fine.)
    final columnStarts = RegExp(r'Column\(').allMatches(src).map((m) => m.start).toList();
    for (final s in columnStarts) {
      // Find the matching close paren of this Column(.
      var depth = 0;
      var i = s + 'Column('.length - 1; // at the '('
      for (; i < src.length; i++) {
        if (src[i] == '(') depth++;
        if (src[i] == ')') {
          depth--;
          if (depth == 0) break;
        }
      }
      final body = src.substring(s, i);
      expect(body.contains(RegExp(r'\bPositioned(\.fill)?\(')), isFalse,
          reason: 'Column at offset $s contains a Positioned — illegal, '
              'throws StackParentData cast on mount');
    }
  });
}
