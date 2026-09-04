import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/ftp_screen.dart';
import 'package:dream_player/screens/webdav_screen.dart';

/// Regression guard for the network-source dialogs (WebDAV / FTP): every
/// input field must render as a full-height TextField box (not collapsed /
/// missing) at phone and iPad window sizes. Asserts on [TextField] geometry,
/// NOT on label text heights (a floating label Text is naturally ~16 px).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> openAddDialog(
    WidgetTester tester,
    Size size,
    StatefulWidget screen,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: screen,
    ));
    await tester.pump(const Duration(milliseconds: 300));
    final add = find.byTooltip('Add server');
    expect(add, findsOneWidget, reason: 'Add-server FAB not shown');
    await tester.tap(add);
    await tester.pump(const Duration(milliseconds: 500));
  }

  void expectAllFieldsSized(WidgetTester tester, int expectedCount) {
    // The dialog's Host label proves the form opened.
    expect(find.text('Host'), findsOneWidget);
    final fields = find.byType(TextField).evaluate();
    expect(fields.length, expectedCount,
        reason: 'expected $expectedCount input fields in dialog');
    for (final field in fields) {
      final box = field.renderObject as RenderBox;
      expect(box.size.height, greaterThan(40),
          reason: 'TextField collapsed to ${box.size}');
      expect(box.size.width, greaterThan(80),
          reason: 'TextField too narrow: ${box.size}');
    }
  }

  for (final entry in {
    'phone': const Size(411, 915),
    'ipad-portrait': const Size(834, 1194),
    'ipad-landscape': const Size(1194, 834),
  }.entries) {
    testWidgets('FTP add-server fields sized (${entry.key})', (tester) async {
      await openAddDialog(tester, entry.value, FtpScreen());
      // name, host, port, path, username, password.
      expectAllFieldsSized(tester, 6);
    });

    testWidgets('WebDAV add-server fields sized (${entry.key})',
        (tester) async {
      await openAddDialog(tester, entry.value, WebDavScreen());
      // name, host, port, path, username, password.
      expectAllFieldsSized(tester, 6);
    });
  }
}
