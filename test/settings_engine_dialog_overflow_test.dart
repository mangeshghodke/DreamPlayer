import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';

/// Regression: the "Default playback engine" chooser is an [AlertDialog] whose
/// content is a non-scrollable `Column` of four `RadioListTile`s, each carrying
/// a title AND a description. That is roughly 410 px of content, but a landscape
/// phone gives the dialog only ~230 px, so it overflowed the bottom by ~184 px.
///
/// Landscape is the worst case because the dialog is height-constrained by the
/// viewport, not the width -- rotating a phone is the only way most users hit
/// it, which is why it survived.
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

  String label(WidgetTester tester, String Function(AppLocalizations) pick) =>
      pick(AppLocalizations.of(tester.element(find.byType(SettingsScreen))));

  Future<void> openEngineDialog(WidgetTester tester) async {
    await tester.pumpAndettleSafe();
    final playerTile = find.text(
      label(tester, (l) => l.settingsPlayer),
    );
    await tester.ensureVisible(playerTile);
    await tester.tap(playerTile);
    await tester.pumpAndSettle();

    final engineTile = find.text(
      label(tester, (l) => l.settingsDefaultEngine),
    );
    await tester.ensureVisible(engineTile);
    await tester.tap(engineTile);
    await tester.pumpAndSettle();
  }

  testWidgets('default-engine dialog does not overflow in landscape', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openEngineDialog(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('default-engine dialog does not overflow in portrait', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openEngineDialog(tester);

    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

extension on WidgetTester {
  /// pumpAndSettle with a guard — the settings screen has a live disk-size
  /// refresh post-frame callback, which can keep the scheduler busy.
  Future<void> pumpAndettleSafe() => pump(const Duration(milliseconds: 300));
}