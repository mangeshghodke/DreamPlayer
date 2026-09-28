import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/credential_dialogs.dart';

/// Regression guard for the Settings credential dialogs (OpenSubtitles
/// sign-in and the TMDB API-key editor).
///
/// Both used to put a bare `Column(mainAxisSize: MainAxisSize.min)` straight
/// into `AlertDialog.content`. On short viewports (landscape phone) and at
/// large text scales the content is taller than the dialog's capped height,
/// so the Column overflowed the bottom of the box. Both now wrap their
/// content in a `SingleChildScrollView`.
///
/// Asserts on [TextField] geometry, NOT on label text heights — a floating
/// label Text is naturally ~16 px and is not a valid size proxy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> openDialog(
    WidgetTester tester,
    Future<void> Function(BuildContext) opener,
  ) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => opener(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// No layout exception may be reported while the dialog is on screen.
  void expectNoOverflow(WidgetTester tester) {
    expect(
      tester.takeException(),
      isNull,
      reason: 'dialog reported a layout overflow',
    );
  }

  /// Fields must render as full-height boxes, not collapse or clip.
  void expectFieldsSized(WidgetTester tester, int expectedCount) {
    final fields = find.byType(TextField).evaluate();
    expect(
      fields.length,
      expectedCount,
      reason: 'expected $expectedCount input fields in dialog',
    );
    for (final field in fields) {
      final box = field.renderObject as RenderBox;
      expect(box.size.height, greaterThan(40),
          reason: 'TextField collapsed to ${box.size}');
      expect(box.size.width, greaterThan(80),
          reason: 'TextField too narrow: ${box.size}');
    }
  }

  // phone-landscape is the tightest realistic case (only 360 logical px of
  // height); the 2.0x text-scale case covers the other reported trigger.
  final sizes = {
    'phone-landscape': const Size(915, 360),
    'small-phone-portrait': const Size(360, 640),
    'ipad-portrait': const Size(834, 1194),
  };

  for (final entry in sizes.entries) {
    testWidgets('OpenSubtitles sign-in dialog has no overflow (${entry.key})',
        (tester) async {
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await openDialog(tester, (ctx) => showOpensubtitlesSignInDialog(ctx));

      expect(find.byType(AlertDialog), findsOneWidget);
      expectFieldsSized(tester, 2);
      expectNoOverflow(tester);
    });

    testWidgets('TMDB API-key dialog has no overflow (${entry.key})',
        (tester) async {
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await openDialog(
          tester, (ctx) => showTmdbApiKeyDialog(ctx, ''));

      expect(find.byType(AlertDialog), findsOneWidget);
      expectFieldsSized(tester, 1);
      expectNoOverflow(tester);
    });
  }

  testWidgets('OpenSubtitles sign-in dialog has no overflow at 2.0x text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(textScaler: const TextScaler.linear(2.0)),
        child: child!,
      ),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () => showOpensubtitlesSignInDialog(ctx),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expectNoOverflow(tester);
  });
}
