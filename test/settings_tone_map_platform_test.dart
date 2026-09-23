import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';

/// HDR tone-map (MPV) is Android-only: libmpv never runs on iOS (AetherEngine
/// handles playback), so the Settings tile must not appear there.
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
      // SettingsScreen is a tab body (no own Scaffold) — Material ancestor
      // required by ExpansionTile/ListTile.
      home: Scaffold(body: child),
    );
  }

  String toneMapTitle(WidgetTester tester) {
    return AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
        .settingsToneMapMode;
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

  testWidgets('Settings hides HDR tone-map (MPV) on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openPlayerSection(tester);

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text(toneMapTitle(tester)), findsNothing);
    // Reset before the binding verifies foundation invariants (addTearDown
    // runs too late — after _verifyInvariants).
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Settings shows HDR tone-map (MPV) on Android', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openPlayerSection(tester);

    expect(find.text(toneMapTitle(tester)), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
