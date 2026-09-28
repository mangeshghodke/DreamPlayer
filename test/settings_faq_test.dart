import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';

/// The Settings FAQ must render on BOTH platforms. The playback-engine entry
/// is Android-only (iOS has a single AetherEngine path), but the rest are
/// platform-agnostic — including the TheTVDB entry, which is what tells a user
/// they can run on TheTVDB alone. The Metadata section that the FAQ refers to
/// must also be present on iOS.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap() => MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // SettingsScreen is a tab body (no own Scaffold).
        home: const Scaffold(body: SettingsScreen()),
      );

  /// Scrolls the FAQ question into view, then taps it to expand.
  ///
  /// The settings list is a lazy ListView, so a long list (Android hides
  /// nothing here but has more rows) may not have built the FAQ at all —
  /// `ensureVisible` needs an existing finder, hence the scroll first.
  Future<void> expandFaq(WidgetTester tester, String question) async {
    final finder = find.text(question);
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(finder, findsOneWidget,
        reason: 'FAQ question "$question" is missing');
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  for (final entry in {
    'android': TargetPlatform.android,
    'ios': TargetPlatform.iOS,
  }.entries) {
    testWidgets('${entry.key}: TheTVDB FAQ is present and expands',
        (tester) async {
      debugDefaultTargetPlatformOverride = entry.value;
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await expandFaq(tester, 'Do I need TMDB, or can I use TheTVDB only?');

      // The answer must actually surface, not just the header.
      expect(
        find.textContaining('Either one works on its own'),
        findsOneWidget,
        reason: 'TheTVDB FAQ answer did not render',
      );
      expect(
        find.textContaining('thetvdb.com/api'),
        findsOneWidget,
        reason: 'TheTVDB FAQ should link the user to the API key page',
      );

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('${entry.key}: Metadata section mentions both providers',
        (tester) async {
      debugDefaultTargetPlatformOverride = entry.value;
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final metadata = find.text(AppLocalizations.of(
        tester.element(find.byType(SettingsScreen)),
      ).settingsMetadata);
      await tester.ensureVisible(metadata);
      await tester.tap(metadata);
      await tester.pumpAndSettle();

      // Both provider tiles must be reachable, not one or the other.
      expect(
        find.text(AppLocalizations.of(
          tester.element(find.byType(SettingsScreen)),
        ).settingsTmdbApiKey),
        findsOneWidget,
      );
      expect(find.text('TheTVDB metadata'), findsOneWidget);
      expect(
        find.textContaining('You can use either one on its own'),
        findsOneWidget,
        reason: 'the intro should not imply TMDB is mandatory',
      );

      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('playback-engine FAQ stays Android-only', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text('Which playback engine should I use?'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS hides the two-engine FAQ (single AetherEngine path)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text('Which playback engine should I use?'), findsNothing);
    // The shared FAQ entries must still be there.
    expect(find.text('Do I need TMDB, or can I use TheTVDB only?'),
        findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
