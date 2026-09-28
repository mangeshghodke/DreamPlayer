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
/// elsewhere — this test exists to produce the full stack instead of guessing.
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

  testWidgets('saving a TheTVDB key does not trip the dependents assertion',
      (tester) async {
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await tester.pumpAndSettle();

    // Open the Metadata section, then the TheTVDB credentials dialog.
    final metadata = find.text(
      AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
          .settingsMetadata,
    );
    await tester.ensureVisible(metadata);
    await tester.tap(metadata);
    await tester.pumpAndSettle();

    final tvdbTile = find.text('TheTVDB metadata');
    expect(tvdbTile, findsOneWidget);
    await tester.ensureVisible(tvdbTile.first);
    await tester.tap(tvdbTile);
    await tester.pumpAndSettle();

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
}
