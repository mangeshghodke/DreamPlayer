import 'package:dream_player/services/app_debug_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disabled under flutter_test so no filesystem work happens', () {
    expect(AppDebugLog.enabled, isFalse);
  });

  test('mark is a safe no-op when disabled', () {
    // Must not throw or touch disk: `mark` is called from UI paths.
    expect(() => AppDebugLog.mark('TMD-OPEN: probe'), returnsNormally);
  });

  test('flush completes with nothing buffered', () async {
    await expectLater(AppDebugLog.flush(), completes);
  });
}
