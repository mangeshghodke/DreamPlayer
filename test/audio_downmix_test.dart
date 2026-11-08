import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/audio_downmix_store.dart';

/// Pins the "Downmix to stereo" feature (Settings -> Audio).
///
/// The feature folds 5.1/7.1 audio into 2.0 so the centre channel (dialogue)
/// stays loud on stereo headphones/speakers. It is deliberately FREE on both
/// platforms — NOT paywall-gated like the iOS DSP trio — because it applies
/// to any 5.1/7.1 file, including ordinary SDR content that free users can
/// already play. These tests pin that decision and the wiring:
///
///  - the store round-trips and is NOT entitlement-corrected (no
///    `effectiveDspSetting`), even under an iOS target with no entitlement;
///  - the Settings row saves WITHOUT a gate (no `_settingsGate` in its
///    onChanged) and the paywall's "What's included" list does not mention
///    downmix;
///  - the native contract: the pref is spelled `dreamplayer.audioDownmix` in
///    Dart and `flutter.dreamplayer.audioDownmix` in BOTH native readers
///    (Android FlutterSharedPreferences, iOS UserDefaults), Android answers
///    a `setAudioDownmix` channel case, the sink chain runs the downmix
///    processor BEFORE the boost limiter, MPV sets `audio-channels=stereo`,
///    and iOS answers the channel + emits `audioDownmix`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final settings =
      File('lib/screens/settings_screen.dart').readAsStringSync();
  final store = File('lib/services/audio_downmix_store.dart').readAsStringSync();
  final player = File('lib/screens/player_screen.dart').readAsStringSync();
  final exo = File('lib/services/exo_player.dart').readAsStringSync();
  final factory =
      File('android/app/src/main/kotlin/com/dreamplayer/app/DreamRenderersFactory.kt')
          .readAsStringSync();
  final exoView =
      File('android/app/src/main/kotlin/com/dreamplayer/app/ExoPlayerView.kt')
          .readAsStringSync();
  final processor = File(
          'android/app/src/main/kotlin/com/dreamplayer/app/DownmixAudioProcessor.kt')
      .readAsStringSync();
  final swift = File('ios/Runner/AvPlayerView.swift').readAsStringSync();
  final paywall = File('lib/screens/paywall_sheet.dart').readAsStringSync();

  group('store', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to off and round-trips', () async {
      expect(await AudioDownmixStore.load(), isFalse);
      await AudioDownmixStore.save(true);
      expect(await AudioDownmixStore.load(), isTrue);
      expect(await AudioDownmixStore.effectiveEnabled(), isTrue);
      await AudioDownmixStore.save(false);
      expect(await AudioDownmixStore.load(), isFalse);
    });

    test('pref key is dreamplayer.audioDownmix', () {
      expect(AudioDownmixStore.prefsKey, 'dreamplayer.audioDownmix');
      expect(store.contains("'dreamplayer.audioDownmix'"), isTrue);
    });

    test('NOT entitlement-corrected, even on iOS without entitlement', () async {
      // The setting is free: a saved ON must survive with no entitlement,
      // on iOS too — unlike the gated DSP trio which uses effectiveDspSetting.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        SharedPreferences.setMockInitialValues({});
        await AudioDownmixStore.save(true);
        expect(await AudioDownmixStore.effectiveEnabled(), isTrue,
            reason: 'downmix is free; no paywall correction may clear it');
        expect(store.contains('effectiveDspSetting'), isFalse,
            reason: 'the store must not route through the paywall correction');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('settings row is free (not paywalled)', () {
    test('row exists once and saves without a gate', () {
      expect(settings.contains('settingsAudioDownmix'), isTrue);
      // Extract the downmix row's onChanged block and pin that it does NOT
      // call _settingsGate (a gated row would, like the night-mode row).
      final rowStart = settings.indexOf('settingsAudioDownmixDesc)');
      final rowEnd = settings.indexOf('SwitchListTile', rowStart);
      final block = settings.substring(
          rowStart, rowEnd == -1 ? rowStart + 400 : rowEnd);
      expect(block.contains('AudioDownmixStore.save(value)'), isTrue);
      expect(block.contains('_settingsGate'), isFalse,
          reason: 'downmix must stay free on iOS — no paywall gate');
    });

    test('paywall feature list does not include downmix', () {
      expect(paywall.toLowerCase().contains('downmix'), isFalse);
    });
  });

  group('native wiring', () {
    test('Android reads the pref with the flutter. prefix', () {
      expect(exoView.contains('"flutter.dreamplayer.audioDownmix"'), isTrue);
      expect(exoView.contains('"setAudioDownmix"'), isTrue);
      expect(exoView.contains('audioDownmixProcessor.setEnabled'), isTrue);
      expect(exoView.contains('map["audioDownmix"]'), isTrue);
    });

    test('sink chain runs downmix before the boost limiter', () {
      final chain = factory.indexOf('setAudioProcessors');
      final chainSnippet = factory.substring(chain, chain + 220);
      final iDelay = chainSnippet.indexOf('audioDelayProcessor');
      final iDown = chainSnippet.indexOf('audioDownmixProcessor');
      final iBoost = chainSnippet.indexOf('audioBoostProcessor');
      expect(iDelay >= 0 && iDown > iDelay && iBoost > iDown, isTrue,
          reason: 'order must be delay -> downmix -> boost(limiter)');
    });

    test('processor keeps centre at -3dB and only runs on PCM16', () {
      expect(processor.contains('MIX_GAIN'), isTrue);
      expect(processor.contains('ENCODING_PCM_16BIT'), isTrue);
      expect(
          processor.contains('UnhandledAudioFormatException'), isTrue,
          reason: 'non-PCM (bitstream passthrough) must bypass the chain');
    });

    test('iOS reads the same pref, answers the channel, emits the state', () {
      expect(swift.contains('"flutter.dreamplayer.audioDownmix"'), isTrue);
      expect(swift.contains('"setAudioDownmix"'), isTrue);
      expect(swift.contains('"audioDownmix": audioDownmixEnabled'), isTrue);
      expect(swift.contains('setSupportsMultichannelContent(false)'), isTrue);
    });

    test('MPV forces stereo output when enabled', () {
      expect(player.contains("'audio-channels'"), isTrue);
      expect(player.contains("downmix ? 'stereo' : 'auto'"), isTrue);
    });

    test('Dart controller exposes setAudioDownmix and the state field', () {
      expect(exo.contains('Future<void> setAudioDownmix(bool enabled)'), isTrue);
      expect(exo.contains("'setAudioDownmix'"), isTrue);
      expect(exo.contains("m['audioDownmix'] == true"), isTrue);
      expect(player.contains('exo.setAudioDownmix(_audioDownmix)'), isTrue);
    });
  });
}
