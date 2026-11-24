import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/keep_screen_on_store.dart';

/// Pins the "keep screen on while playing" fix (user report 2026-11-24:
/// "screen stay awake is not working, it follows auto screen off" on
/// 0.5.7/0.5.8). Root cause: only the Media3 platform view set
/// `keepScreenOn`, and in hybrid composition a platform view's own window
/// flag does not reliably keep the SCREEN on; the MPV surface view set
/// nothing. The fix sets `FLAG_KEEP_SCREEN_ON` on the ACTIVITY window
/// (Android) / `isIdleTimerDisabled` (iOS) via the `dreamplayer/system`
/// channel, driven by the `dreamplayer.keepScreenOn` pref (default ON).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KeepScreenOnStore', () {
    test('defaults to ON when the pref is missing', () async {
      SharedPreferences.setMockInitialValues({});
      final store = KeepScreenOnStore.instance;
      await store.load();
      expect(store.enabled, isTrue);
    });

    test('persists false and true under the documented pref key', () async {
      SharedPreferences.setMockInitialValues({});
      final store = KeepScreenOnStore.instance;
      await store.load();
      await store.setEnabled(false);
      expect(store.enabled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('dreamplayer.keepScreenOn'), isFalse);
      // The native side reads the flutter.-prefixed key in
      // FlutterSharedPreferences / UserDefaults - the same key with the
      // prefix applied by shared_preferences.
      expect(prefs.getBool('flutter.${KeepScreenOnStore.prefsKey}'), isNull,
          reason: 'shared_preferences stores the raw key; the platform adds '
              'the flutter. prefix in its own storage file');
      await store.setEnabled(true);
      expect(store.enabled, isTrue);
    });
  });

  group('wiring (source-reading)', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final controls =
        File('lib/services/system_controls.dart').readAsStringSync();
    final mainKt = File(
            'android/app/src/main/kotlin/com/dreamplayer/app/MainActivity.kt')
        .readAsStringSync();
    final appDelegate =
        File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final avPlayer = File('ios/Runner/AvPlayerView.swift').readAsStringSync();
    final settings = File('lib/screens/settings_screen.dart').readAsStringSync();
    final mainDart = File('lib/main.dart').readAsStringSync();

    test('Dart and both platforms agree on the channel + method + arg', () {
      expect(controls.contains("MethodChannel('dreamplayer/system')"), isTrue);
      expect(controls.contains("'setKeepScreenOn'"), isTrue);
      expect(controls.contains("'enabled': enabled"), isTrue);
      expect(mainKt.contains('"setKeepScreenOn"'), isTrue);
      expect(mainKt.contains('FLAG_KEEP_SCREEN_ON'), isTrue);
      expect(appDelegate.contains('"dreamplayer/system"'), isTrue);
      expect(appDelegate.contains('"setKeepScreenOn"'), isTrue);
      expect(appDelegate.contains('isIdleTimerDisabled'), isTrue);
    });

    test('Android sets/clears the flag on the ACTIVITY window', () {
      final at = mainKt.indexOf('"setKeepScreenOn"');
      expect(at, greaterThan(-1));
      final block = mainKt.substring(at, at + 400);
      expect(block, contains('window.addFlags'));
      expect(block, contains('window.clearFlags'));
      // Must NOT be a platform view's keepScreenOn - that is the old,
      // unreliable path in hybrid composition.
      expect(block, isNot(contains('.keepScreenOn =')));
    });

    test('player screen applies the setting on open and clears on dispose', () {
      expect(player.contains('setKeepScreenOn(KeepScreenOnStore.instance.enabled)'),
          isTrue);
      expect(player.contains('setKeepScreenOn(false)'), isTrue);
      final initAt = player.indexOf('void initState()');
      final setAt = player.indexOf('setKeepScreenOn(KeepScreenOnStore');
      final disposeAt = player.indexOf('void dispose()');
      final clearAt = player.indexOf('setKeepScreenOn(false)');
      expect(setAt, greaterThan(initAt));
      expect(disposeAt, greaterThan(-1));
      expect(clearAt, greaterThan(disposeAt));
    });

    test('iOS open() honors the pref (default ON), deinit still restores', () {
      expect(avPlayer.contains('flutter.dreamplayer.keepScreenOn'), isTrue);
      expect(avPlayer.contains('isIdleTimerDisabled = keepOn'), isTrue);
      expect(avPlayer.contains('isIdleTimerDisabled = false'), isTrue);
    });

    test('Settings → Player has the toggle, loaded from the store', () {
      expect(settings.contains('settingsKeepScreenOn'), isTrue);
      expect(settings.contains('KeepScreenOnStore.instance.setEnabled'), isTrue);
      expect(settings.contains('_loadKeepScreenOn()'), isTrue);
      expect(mainDart.contains('KeepScreenOnStore.instance.load()'), isTrue);
    });

    test('WAKE_LOCK permission is declared (FLAG_KEEP_SCREEN_ON needs it)', () {
      final manifest = File(
              'android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest, contains('android.permission.WAKE_LOCK'));
    });
  });
}
