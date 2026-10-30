import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';
import 'package:dream_player/services/entitlements.dart';
import 'package:dream_player/services/spatial_audio_store.dart';

/// Spatial audio is a PREMIUM feature on iOS.
///
/// The switch lives in Settings -> Audio, defaults OFF, and a free user who
/// turns it on gets the paywall instead of the feature. Android is exempt:
/// its spatial audio is the platform Spatializer, which the app only
/// reports and never controls, so there is nothing to gate there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );
  }

  String audioTitle(WidgetTester tester) {
    return AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
        .settingsAudio;
  }

  String spatialTitle(WidgetTester tester) {
    return AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
        .settingsSpatialAudio;
  }

  Future<void> openAudioSection(WidgetTester tester) async {
    await tester.pumpAndSettle();
    final tile = find.text(audioTitle(tester));
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  testWidgets('iOS Settings shows the spatial audio switch, off by default',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openAudioSection(tester);

    final switchFinder = find.widgetWithText(SwitchListTile, spatialTitle(tester));
    expect(switchFinder, findsOneWidget);
    final tile = tester.widget<SwitchListTile>(switchFinder);
    expect(tile.value, isFalse);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android Settings does not show the spatial audio switch',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openAudioSection(tester);

    expect(find.widgetWithText(SwitchListTile, spatialTitle(tester)),
        findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  test('the switch defaults OFF and persists', () async {
    expect(await SpatialAudioStore.load(), isFalse);

    await SpatialAudioStore.save(true);
    expect(await SpatialAudioStore.load(), isTrue);

    await SpatialAudioStore.save(false);
    expect(await SpatialAudioStore.load(), isFalse);
  });

  test('a free user is gated, an entitled user is not', () {
    // Free user, paywall live: the switch may not be turned on.
    expect(
      spatialAudioMayBeEnabled(advanced: false, paywallActive: true),
      isFalse,
    );
    // Entitled (paying or in-trial): straight through.
    expect(
      spatialAudioMayBeEnabled(advanced: true, paywallActive: true),
      isTrue,
    );
    // Paywall not live (Android, or a build without PAYWALL_ENABLED): the
    // feature is never gated, so nothing is blocked.
    expect(
      spatialAudioMayBeEnabled(advanced: false, paywallActive: false),
      isTrue,
    );
  });

  test('the Dart pref key and the native key agree', () {
    // shared_preferences prefixes its keys with "flutter." on iOS, and the
    // native side reads the opt-in straight from UserDefaults. A rename on
    // either side would silently leave the feature stuck OFF, so the two
    // spellings are pinned together here.
    expect(SpatialAudioStore.prefsKey, 'dreamplayer.spatialAudio');

    final swift = File('ios/Runner/AvPlayerView.swift');
    expect(swift.existsSync(), isTrue);
    expect(
      swift.readAsStringSync(),
      contains('flutter.dreamplayer.spatialAudio'),
    );
  });

  test('a lapsed entitlement turns the saved opt-in off', () async {
    await SpatialAudioStore.save(true);

    // Android is the only platform where the paywall can be lit in a test
    // build (the debug "simulate free user" override), and the feature is
    // the same code path on both platforms.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() async {
      await Entitlements.instance.setDebugFreeUser(false);
      debugDefaultTargetPlatformOverride = null;
    });

    // An entitled user keeps it on.
    expect(await SpatialAudioStore.effectiveEnabled(), isTrue);
    expect(await SpatialAudioStore.load(), isTrue);

    // Now the entitlement lapses (trial over, subscription ended). The native
    // side reads the pref directly, so a stale ON value would keep the paid
    // feature working for free — it has to be corrected AND persisted.
    await Entitlements.instance.setDebugFreeUser(true);
    expect(await SpatialAudioStore.effectiveEnabled(), isFalse);
    expect(await SpatialAudioStore.load(), isFalse);
  });
}
