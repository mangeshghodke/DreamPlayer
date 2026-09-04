import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/jellyfin_screen.dart';

Future<void> _pumpAndCheck(
  WidgetTester tester,
  Size physical, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: const JellyfinScreen(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    tester.takeException(),
    isNull,
    reason: 'overflow at ${physical.width}x${physical.height}@3'
        ' textScale=$textScale',
  );
}

void main() {
  testWidgets('server list empty state has no overflow at device sizes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpAndCheck(tester, const Size(1080, 2400)); // portrait
    await _pumpAndCheck(tester, const Size(2400, 1080)); // landscape
    await _pumpAndCheck(tester, const Size(2400, 1080), textScale: 1.3);
  });
}
