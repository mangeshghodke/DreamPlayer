import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/entitlements.dart';
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
    // The channel case persists only — NO mid-session reload (a reload did
    // not engage the stage live); it applies on the next open.
    final caseStart = av.indexOf('case "setUpscale"');
    final caseBlock =
        av.substring(caseStart, av.indexOf('result(nil)', caseStart));
    expect(caseBlock, contains('UserDefaults.standard.set(upOn'));
    expect(caseBlock, isNot(contains('reloadSession(at:')));
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
    // The switch shows the EFFECTIVE value (lapsed entitlement corrected).
    expect(settings, contains('IosUpscaleStore().effectiveEnabled()'));
  });

  test('a lapsed entitlement turns the saved upscale opt-in off', () async {
    SharedPreferences.setMockInitialValues({});
    final store = IosUpscaleStore();
    await store.setEnabled(true);

    // Android is the only platform where the paywall can be lit in a test
    // build (the debug "simulate free user" override); same code path.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() async {
      await Entitlements.instance.setDebugFreeUser(false);
      debugDefaultTargetPlatformOverride = null;
    });

    // Entitled user keeps it on.
    expect(await store.effectiveEnabled(), isTrue);
    expect(await store.load(), isTrue);

    // Entitlement lapses: the engine reads the pref straight from
    // UserDefaults, so a stale ON would keep the paid feature on for free —
    // it must be corrected AND persisted.
    await Entitlements.instance.setDebugFreeUser(true);
    expect(await store.effectiveEnabled(), isFalse);
    expect(await store.load(), isFalse);
  });

  test('the player corrects a stale opt-in before open on iOS', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final i = player.indexOf('SpatialAudioStore.effectiveEnabled()');
    expect(player.substring(i, i + 400), contains('IosUpscaleStore().effectiveEnabled()'));
  });

  test('the paywall feature list and trial screen both name upscaling', () {
    final paywall = File('lib/screens/paywall_sheet.dart').readAsStringSync();
    expect(paywall, contains("'Video upscaling (MetalFX, iOS 26+)'"));
    final trial = File('lib/screens/trial_intro_screen.dart').readAsStringSync();
    expect(trial, contains("'Video upscaling (MetalFX)'"));
  });

  test('player shows only the status chip — no popup toggle or live push', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    // The toggle lives in Settings -> Player only: no panel, no top-bar
    // button, no setUpscale call from the player screen.
    expect(player, isNot(contains('_IosUpscalePanel')));
    expect(player, isNot(contains('_onIosUpscaleToggled')));
    expect(player, isNot(contains('Icons.auto_awesome')));
    expect(player, isNot(contains('exo.setUpscale(')));
    // Status chip from the event map stays.
    expect(player, contains('_liveUpscaleActive = e.upscaleActive;'));
    expect(player, contains("label: _liveUpscaleLabel.isNotEmpty"));
  });

  test('controller surface carries the upscale fields', () {
    final exo = File('lib/services/exo_player.dart').readAsStringSync();
    expect(exo, contains("upscaleActive: m['upscaleActive'] == true"));
  });

  test('os_version gates on iOS 26 and caches', () {
    final src = File('lib/utils/os_version.dart').readAsStringSync();
    expect(src, contains('major >= 26'));
    expect(src, contains('_cachedOsMajor'));
  });
}
