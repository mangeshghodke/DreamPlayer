import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';

/// The Player settings section must stay reachable on a TV (Fire Stick).
///
/// The engine picker, decoder mode, auto-play-next, PiP and the on-screen
/// badges are all TV-relevant. Only the touch-only swipe-gestures row is
/// hidden there - a blanket "hide the whole section on TV" gate took the
/// engine picker with it.
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

  String l10n(WidgetTester tester, String Function(AppLocalizations) pick) {
    return pick(AppLocalizations.of(tester.element(find.byType(SettingsScreen))));
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }

  Future<void> openPlayerSection(WidgetTester tester) async {
    await tester.pumpAndSettle();
    final playerTile = find.text(l10n(tester, (l) => l.settingsPlayer));
    await scrollTo(tester, playerTile);
    expect(playerTile, findsOneWidget);
    await tester.tap(playerTile);
    await tester.pumpAndSettle();
  }

  testWidgets('TV keeps the Player section and the engine picker',
      (tester) async {
    // 1920x1080 at density 2.0 = 960dp wide, the Fire Stick's real width.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openPlayerSection(tester);

    final engineRow =
        find.text(l10n(tester, (l) => l.settingsDefaultEngine));
    await scrollTo(tester, engineRow);
    expect(engineRow, findsOneWidget);

    // Touch-only: no gesture on a remote.
    expect(find.text(l10n(tester, (l) => l.settingsSwipeGestures)), findsNothing);
  });

  testWidgets('Phone keeps the swipe-gestures row', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openPlayerSection(tester);

    final swipeRow = find.text(l10n(tester, (l) => l.settingsSwipeGestures));
    await scrollTo(tester, swipeRow);
    expect(swipeRow, findsOneWidget);
  });
}
