import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';

/// Repro for: Settings -> Metadata -> TheTVDB -> paste key -> Save shows a red
/// screen with `failed assertion: _dependency.isEmpty: is not true`.
///
/// That assertion is `InheritedElement.debugDeactivated()`. A dependency was
/// still registered on an InheritedElement when it deactivated, i.e. something
/// in the dialog subtree depended on an InheritedElement that is not its
/// ancestor.
///
/// An earlier fix swapped the Save label's `AppLocalizations.of(context)` for
/// the dialog's own context and did NOT resolve it, so the real cause is
/// elsewhere - this test exists to produce the full stack instead of guessing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dreamplayer/the_tvdb_credentials');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'read':
          return <String, dynamic>{'apiKey': null, 'pin': null};
        case 'write':
        case 'clear':
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );
  }

  /// Scrolls a row into view and taps it.
  ///
  /// `ensureVisible` alone is not enough here: the settings list is a lazy
  /// ListView that keeps growing (the collapsible FAQ section was added at the
  /// bottom), so a row can sit just past the built viewport where the finder
  /// still resolves but the derived tap offset misses and the tap lands on
  /// nothing. Scroll first, then ensure, then tap.
  Future<void> openRow(WidgetTester tester, Finder f) async {
    if (f.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        f,
        250,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets('saving a TheTVDB key does not trip the dependents assertion',
      (tester) async {
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await tester.pumpAndSettle();

    // Open the Metadata section, then the TheTVDB credentials dialog.
    final metadata = find.text(
      AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
          .settingsMetadata,
    );
      await openRow(tester, metadata);

    // TheTVDB's credential field is only shown once TheTVDB is the selected
    // provider (issue #46), so pick it first. Default is TMDB.
    await openRow(tester, find.byKey(const ValueKey('providerCell-theTvdb')));
    await tester.pumpAndSettle();

    final tvdbTile = find.text('TheTVDB API key');
    expect(tvdbTile, findsOneWidget);
      await openRow(tester, tvdbTile.first);

    // Paste a key and save.
    final fields = find.byType(TextField);
    expect(fields, findsWidgets);
    await tester.enterText(fields.first, 'test-key-1234');
    await tester.pumpAndSettle();

    final save = find.text(
      AppLocalizations.of(tester.element(find.byType(SettingsScreen))).commonSave,
    );
    await tester.ensureVisible(save);
    await tester.tap(save);

    // The assertion (if any) surfaces here with a full stack.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('saving a TMDB key does not trip the dependents assertion',
      (tester) async {
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await tester.pumpAndSettle();

    final metadata = find.text(
      AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
          .settingsMetadata,
    );
      await openRow(tester, metadata);

    final tmdbTile = find.text(
      AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
          .settingsTmdbApiKey,
    );
    expect(tmdbTile, findsOneWidget);
      await openRow(tester, tmdbTile);

    // 32-character key so the length validation passes and Save really pops.
    final fields = find.byType(TextField);
    expect(fields, findsOneWidget);
    await tester.enterText(fields.first, 'a' * 32);
    await tester.pumpAndSettle();

    final save = find.text(
      AppLocalizations.of(tester.element(find.byType(SettingsScreen))).commonSave,
    );
    await tester.ensureVisible(save);
    await tester.tap(save);

    // Surfaces 'A TextEditingController was used after being disposed' with a
    // full stack if the controller is disposed before the dialog finishes
    // animating out.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
