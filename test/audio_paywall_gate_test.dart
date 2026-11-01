import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/paywall_sheet.dart';
import 'package:dream_player/screens/settings_screen.dart';
import 'package:dream_player/services/entitlements.dart';
import 'package:dream_player/services/exo_player.dart';

/// The iOS audio DSP controls are premium; Android is free forever.
///
/// Two of them ship on iOS: **spatial audio** (Apple's system spatialization,
/// opted into by the app) and **night mode** (the engine's dynamic-range
/// compressor). Both are choice-gated: the switch defaults OFF and a free
/// user who turns it ON gets the paywall instead of the feature. Turning it
/// back OFF is always free.
///
/// Android is never gated. `Entitlements.advanced` returns true
/// unconditionally there, so every gate resolves to "available" and the
/// paywall sheet can never open — that is the immunity guarantee the whole
/// Android sideload distribution depends on.
///
/// What this file pins is the WIRING, because the decision layer is already
/// covered by `entitlements_test.dart` (`checkGate`, `dspSettingMayStayEnabled`,
/// `effectiveDspSetting`, the Android immunity) and the spatial store by
/// `spatial_audio_gate_test.dart`. A refactor that dropped the
/// `await _settingsGate()` from the night-mode row, or moved the save BEFORE
/// the gate, would keep every existing test green while shipping the paid
/// feature for free.
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

  String nightTitle(WidgetTester tester) {
    return AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
        .settingsNightMode;
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

  Finder nightSwitch(WidgetTester tester) {
    final tile = find.widgetWithText(SwitchListTile, nightTitle(tester));
    expect(tile, findsOneWidget, reason: 'the night-mode row moved');
    return find.descendant(of: tile, matching: find.byType(Switch));
  }

  /// Closes the paywall sheet the gate opened, the way a dismissing user
  /// would.
  ///
  /// The sheet ticks a countdown timer every second, so `pumpAndSettle`
  /// never settles while it is open — pump explicitly instead.
  Future<void> dismissPaywall(WidgetTester tester) async {
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  group('Android is free', () {
    testWidgets('night mode can be turned on with no entitlement',
        (tester) async {
      // Android's `advanced` is hardcoded true, so the gate resolves to
      // "available" and the paywall never opens.
      expect(Entitlements.instance.isEntitled, isTrue);

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await openAudioSection(tester);

      await tester.tap(nightSwitch(tester));
      await tester.pumpAndSettle();

      expect(await NightModeStore.load(), isTrue);
      expect(find.byType(PaywallSheet), findsNothing);
    });

    testWidgets('the spatial-audio row is not even offered on Android',
        (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await openAudioSection(tester);

      expect(find.widgetWithText(SwitchListTile, spatialTitle(tester)),
          findsNothing);
    });
  });

  group('a free user is blocked', () {
    // The paywall can only be lit in a test build on Android (the debug
    // "simulate free user" override), and the gate code path is the same
    // one iOS takes.
    setUp(() async {
      await Entitlements.instance.setDebugFreeUser(true);
    });

    tearDown(() async {
      await Entitlements.instance.setDebugFreeUser(false);
    });

    testWidgets('turning night mode on opens the paywall and saves nothing',
        (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await openAudioSection(tester);

      await tester.tap(nightSwitch(tester));
      // The paywall sheet ticks a timer every second, so pump explicitly
      // instead of pumpAndSettle (which would never settle).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // The gate is still waiting on the sheet: nothing was persisted.
      expect(find.byType(PaywallSheet), findsOneWidget);
      expect(await NightModeStore.load(), isFalse);

      // Dismissing the sheet leaves the feature OFF.
      await dismissPaywall(tester);
      expect(await NightModeStore.load(), isFalse);
    });

    testWidgets('turning night mode OFF is always free', (tester) async {
      // A saved ON (from an earlier entitled session) must be switchable
      // off without a paywall — the gate is on turning the feature ON.
      await NightModeStore.save(true);

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await openAudioSection(tester);

      await tester.tap(nightSwitch(tester));
      await tester.pumpAndSettle();

      expect(await NightModeStore.load(), isFalse);
      expect(find.byType(PaywallSheet), findsNothing);
    });
  });

  group('the wiring', () {
    final settings =
        File('lib/screens/settings_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final paywall = File('lib/screens/paywall_sheet.dart').readAsStringSync();

    test('the Settings night-mode row gates ON and saves AFTER the gate',
        () {
      final row = settings.indexOf('settingsNightMode)');
      expect(row, greaterThan(-1), reason: 'the row moved');
      final body = settings.substring(row, row + 700);
      expect(body, contains('_settingsGate()'),
          reason: 'turning night mode on must be gated');
      expect(
        body.indexOf('_settingsGate()'),
        lessThan(body.indexOf('NightModeStore.save')),
        reason: 'the gate must run BEFORE the setting is stored',
      );
    });

    test('the Settings spatial-audio row gates ON and saves AFTER the gate',
        () {
      final row = settings.indexOf('settingsSpatialAudio)');
      expect(row, greaterThan(-1), reason: 'the row moved');
      final body = settings.substring(row, row + 700);
      expect(body, contains('_spatialAudioGate()'),
          reason: 'turning spatial audio on must be gated');
      expect(
        body.indexOf('_spatialAudioGate()'),
        lessThan(body.indexOf('SpatialAudioStore.save')),
        reason: 'the gate must run BEFORE the setting is stored',
      );
    });

    test('the player night-mode switch and row both gate ON', () {
      final row = player.indexOf('playerNightModeTitle');
      expect(row, greaterThan(-1), reason: 'the row moved');
      final body = player.substring(row, row + 1800);
      // The switch and the row tap are two separate handlers; both gate.
      expect(body, contains('_gate()'),
          reason: 'turning night mode on from the player must be gated');
      expect(body, contains('NightModeStore.save'),
          reason: 'the row still saves the setting');
    });

    test('the correction is iOS-only, so Android keeps the setting', () {
      final ent =
          File('lib/services/entitlements.dart').readAsStringSync();
      expect(
        ent.contains('defaultTargetPlatform != TargetPlatform.iOS'),
        isTrue,
        reason: 'a lapsed entitlement may only correct the setting on iOS',
      );
    });

    test('the paywall advertises exactly the two iOS audio features', () {
      expect(paywall.contains('Spatial audio'), isTrue);
      expect(paywall.contains('Night mode'), isTrue);
      expect(paywall.contains('Volume boost'), isFalse);
      expect(paywall.contains('Bass boost'), isFalse);
    });
  });
}
