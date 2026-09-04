import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';
import 'package:dream_player/screens/subtitle_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('settings exposes the Simplified Chinese interface', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SettingsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('应用语言'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('支持'), findsOneWidget);

    await tester.tap(find.text('主题'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('选择主题'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
  });

  testWidgets('subtitle appearance controls use Simplified Chinese', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: SubtitleSettingsScreen(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('字幕'), findsOneWidget);
    expect(find.text('字幕预览示例'), findsOneWidget);
    expect(find.text('文字大小'), findsOneWidget);
    expect(find.text('颜色'), findsOneWidget);
    expect(find.text('背景'), findsOneWidget);
    expect(find.text('Black outline'), findsNothing);
  });
}
