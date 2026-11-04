import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/ios_upscale_store.dart';

/// iOS MetalFX upscale wiring (engine #846 via the AetherEngine fork):
/// the Settings toggle only appears on iOS 26+, the pref rides every load,
/// the event map carries the stage status, and Android answers a no-op.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('store defaults to off and persists the toggle', () async {
    SharedPreferences.setMockInitialValues({});
    final store = IosUpscaleStore();
    expect(await store.load(), isFalse);
    expect(await store.setEnabled(true), isTrue);
    expect(await IosUpscaleStore().load(), isTrue);
    SharedPreferences.setMockInitialValues({});
  });

  test('AvPlayerView reads the pref into every LoadOptions', () {
    final av = File('ios/Runner/AvPlayerView.swift').readAsStringSync();
    expect(av, contains('options.upscalesLowResolutionVideo'));
    expect(av, contains('flutter.dreamplayer.iosUpscale'));
    // Status is emitted and observed, not just set.
    expect(av, contains(r'engine.$activeUpscale.sink'));
    expect(av, contains('"upscaleActive"'));
    expect(av, contains('"upscaleSource"'));
    expect(av, contains('"upscaleTarget"'));
    // The channel case exists and reloads at the playhead on change.
    expect(av, contains('case "setUpscale"'));
    expect(av, contains('reloadSession(at:'));
  });

  test('Android answers setUpscale as a logged no-op', () {
    final kt = File(
            'android/app/src/main/kotlin/com/dreamplayer/app/ExoPlayerView.kt')
        .readAsStringSync();
    expect(kt, contains('"setUpscale" ->'));
  });

  test('iOS AppDelegate answers osMajorVersion on dreamplayer/device', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(appDelegate, contains('"dreamplayer/device"'));
    expect(appDelegate, contains('"osMajorVersion"'));
    expect(appDelegate, contains('UIDevice.current.systemVersion'));
    final android = File(
            'android/app/src/main/kotlin/com/dreamplayer/app/MainActivity.kt')
        .readAsStringSync();
    expect(android, contains('"osMajorVersion" -> result.success(Build.VERSION.SDK_INT)'));
  });

  test('Settings toggle is iOS-only AND iOS 26+ only, paywall-gated', () {
    final settings = File('lib/screens/settings_screen.dart').readAsStringSync();
    expect(settings, contains('isIos26OrLater()'));
    expect(
      settings,
      contains(
          'defaultTargetPlatform == TargetPlatform.iOS &&\n                    _iosUpscaleSupported'),
    );
    // Turning it on goes through the paywall gate before the save.
    final row = settings.substring(settings.indexOf('Video upscaling (MetalFX)'));
    expect(row, contains('if (value && !await _settingsGate()) return;'));
    expect(row, contains('IosUpscaleStore().setEnabled(value)'));
  });

  test('player pushes the pref before open and shows the chip', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    expect(player, contains('exo.setUpscale('));
    expect(player, contains('IosUpscaleStore.prefsKey'));
    expect(player, contains('_liveUpscaleActive = e.upscaleActive;'));
    expect(player, contains("label: _liveUpscaleLabel.isNotEmpty"));
  });

  test('controller surface carries the upscale fields', () {
    final exo = File('lib/services/exo_player.dart').readAsStringSync();
    expect(exo, contains('Future<void> setUpscale(bool enabled);'));
    expect(exo, contains("upscaleActive: m['upscaleActive'] == true"));
  });

  test('os_version gates on iOS 26 and caches', () {
    final src = File('lib/utils/os_version.dart').readAsStringSync();
    expect(src, contains('major >= 26'));
    expect(src, contains('_cachedOsMajor'));
  });
}
