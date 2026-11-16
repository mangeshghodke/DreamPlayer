import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';

/// The Settings FAQ must render on BOTH platforms. The playback-engine entry
/// is Android-only (iOS has a single AetherEngine path), but the rest are
/// platform-agnostic - including the TheTVDB entry, which is what tells a user
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

  /// Scrolls a row into view without tapping it. The settings list is a lazy
  /// ListView, so adding a new section above the FAQ can push a row past the
  /// initially-built viewport and make a bare `find.text` fail even though the
  /// row exists and is reachable by scrolling.
  Future<void> reveal(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  /// Opens the collapsible FAQ section, which is collapsed by default, so the
  /// entries inside it are built and findable.
  ///
  /// This has to come first: an ExpansionTile does not build its children until
  /// expanded, so a bare `find.text(question)` on a collapsed section returns
  /// nothing at all -- not even a lazily-reachable row to scroll to.
  Future<void> openFaqSection(WidgetTester tester) async {
    final section = find.text('FAQ');
    await tester.scrollUntilVisible(
      section,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(section);
    await tester.pumpAndSettle();
  }

  /// Scrolls the FAQ question into view, then taps it to expand.
  ///
  /// The settings list is a lazy ListView, so a long list (Android hides
  /// nothing here but has more rows) may not have built the FAQ at all -
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

      await openFaqSection(tester);
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

      // Provider FIRST, then only that provider's credential. TMDB is the
      // default, so TMDB's key field shows and TheTVDB's does not - but both
      // are reachable through the provider table.
      expect(
        find.text(AppLocalizations.of(
          tester.element(find.byType(SettingsScreen)),
        ).settingsTmdbApiKey),
        findsOneWidget,
      );
      expect(find.text('TheTVDB API key'), findsNothing);
      for (final name in const ['tmdb', 'theTvdb']) {
        expect(
          find.byKey(ValueKey('providerCell-$name')),
          findsOneWidget,
          reason: 'both providers must be offered in the provider table',
        );
      }

      // Issue #46: the long intro paragraph is gone. It had to go - it was
      // three screens of prose in front of two buttons - but the guarantee it
      // was making (TMDB is NOT mandatory) now has to come from somewhere, so
      // assert it structurally: the adult toggle and both provider tiles are
      // the whole section.
      expect(
        find.textContaining('You can use either one on its own'),
        findsNothing,
        reason: 'the verbose Metadata intro must stay removed',
      );
      expect(find.text('Include adult content'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('playback-engine FAQ stays Android-only', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await openFaqSection(tester);
    await reveal(tester, 'Which playback engine should I use?');
    expect(find.text('Which playback engine should I use?'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS hides the two-engine FAQ (single AetherEngine path)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await openFaqSection(tester);
    expect(find.text('Which playback engine should I use?'), findsNothing);
    // The shared FAQ entries must still be there.
    expect(find.text('Do I need TMDB, or can I use TheTVDB only?'),
        findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
