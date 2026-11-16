import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';

/// The hardware SDR tone-mapping toggle (issue #55) drives the ANDROID video
/// codec (MediaCodec's `KEY_COLOR_TRANSFER_REQUEST`), so it must not appear
/// on iOS - where playback runs through AetherEngine and the setting would
/// resolve to nothing.
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

  String toneMapTitle(WidgetTester tester) {
    return AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
        .settingsHwSdrToneMap;
  }

  String playerTitle(WidgetTester tester) {
    return AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
        .settingsPlayer;
  }

  Future<void> openPlayerSection(WidgetTester tester) async {
    await tester.pumpAndSettle();
    final playerTile = find.text(playerTitle(tester));
    expect(playerTile, findsOneWidget);
    await tester.ensureVisible(playerTile);
    await tester.tap(playerTile);
    await tester.pumpAndSettle();
  }

  testWidgets('Settings hides hardware SDR tone-mapping on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openPlayerSection(tester);

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text(toneMapTitle(tester)), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Settings shows hardware SDR tone-mapping on Android',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openPlayerSection(tester);

    expect(find.text(toneMapTitle(tester)), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
