import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';
import 'package:dream_player/services/mpv_interpolation_store.dart';
import 'package:dream_player/utils/mpv_interpolation.dart';

/// Frame interpolation (issue #53) is driven by three mpv details that each
/// silently do nothing on their own - the options below pin them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mpv interpolation options', () {
    test('enabling switches the sync mode, interpolation and the filter', () {
      final options = mpvInterpolationOptions(
        const MpvInterpolationConfig(targetFps: 48),
      );

      expect(options, contains(const MpvOption('video-sync', 'display-resample')));
      expect(options, contains(const MpvOption('interpolation', 'yes')));
      expect(options, contains(const MpvOption('tscale', 'oversample')));
      expect(options, contains(const MpvOption('interpolation-threshold', '-1')));
    });

    test('the target frame rate is NOT one of the plain options', () {
      final options = mpvInterpolationOptions(
        const MpvInterpolationConfig(targetFps: 48),
      );

      // The frame rate goes in through the display-fps override, whose option
      // name differs between mpv versions and has to be read back.
      for (final option in options) {
        expect(mpvDisplayFpsOptionNames, isNot(contains(option.name)));
      }
    });

    test('the frame rate override is tried newest name first', () {
      // mpv keeps the option value (`override-display-fps`) apart from the
      // detected refresh rate (`display-fps`, read-only).
      expect(mpvDisplayFpsOptionNames.first, 'override-display-fps');
      expect(mpvDisplayFpsOptionNames, contains('display-fps'));
      expect(mpvDisplayFpsOptionNames.last, 'display-fps');
    });

    test('the filter follows the chosen quality', () {
      for (final filter in MpvInterpolationFilter.values) {
        final options = mpvInterpolationOptions(
          MpvInterpolationConfig(targetFps: 60, filter: filter),
        );
        expect(options, contains(MpvOption('tscale', filter.mpvName)));
      }
    });

    test('disabling turns interpolation off and restores the audio sync', () {
      final options = mpvInterpolationOptions(const MpvInterpolationConfig());

      expect(options, contains(const MpvOption('interpolation', 'no')));
      expect(options, contains(const MpvOption('video-sync', 'audio')));
      expect(options, isNot(contains(const MpvOption('video-sync', 'display-resample'))));
    });

    test('a zero frame rate means off', () {
      expect(const MpvInterpolationConfig().enabled, isFalse);
      expect(
        const MpvInterpolationConfig(targetFps: 48).enabled,
        isTrue,
      );
    });
  });

  group('mpv interpolation store', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to off with the sharpest filter', () async {
      final cfg = await MpvInterpolationStore.load();

      expect(cfg.targetFps, 0);
      expect(cfg.filter, MpvInterpolationFilter.oversample);
    });

    test('round-trips the target frame rate and the filter', () async {
      await MpvInterpolationStore.save(
        const MpvInterpolationConfig(
          targetFps: 48,
          filter: MpvInterpolationFilter.bicubic,
        ),
      );

      final cfg = await MpvInterpolationStore.load();
      expect(cfg.targetFps, 48);
      expect(cfg.filter, MpvInterpolationFilter.bicubic);
    });

    test('an unknown filter falls back to the default', () async {
      SharedPreferences.setMockInitialValues({
        'dreamplayer.mpvInterpolationFps': 60,
        'dreamplayer.mpvInterpolationFilter': 'nonsense',
      });

      final cfg = await MpvInterpolationStore.load();
      expect(cfg.targetFps, 60);
      expect(cfg.filter, MpvInterpolationFilter.oversample);
    });

    test('48 fps is one of the offered targets', () {
      expect(MpvInterpolationStore.targetFpsChoices, contains(48));
      expect(MpvInterpolationStore.targetFpsChoices, contains(0));
    });
  });

  group('settings row', () {
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

    Future<void> openPlayerSection(WidgetTester tester) async {
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(SettingsScreen)),
      );
      final playerTile = find.text(l.settingsPlayer);
      await tester.scrollUntilVisible(
        playerTile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(playerTile);
      await tester.pumpAndSettle();
    }

    testWidgets('the row appears on Android', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await openPlayerSection(tester);

      final row = find.text(
        AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
            .settingsMpvInterpolation,
      );
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(row, findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the row is absent on iOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await openPlayerSection(tester);

      expect(
        find.text(
          AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
              .settingsMpvInterpolation,
        ),
        findsNothing,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
