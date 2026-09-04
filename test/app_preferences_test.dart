import 'package:dream_player/services/app_preferences.dart';
import 'package:dream_player/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPreferencesController.instance.load();
  });

  tearDown(() async {
    await AppPreferencesController.instance.setLanguage(AppLanguage.system);
    await AppPreferencesController.instance.setThemeMode(ThemeMode.system);
  });

  test('appearance preferences default to the system', () {
    final controller = AppPreferencesController.instance;
    expect(controller.language, AppLanguage.system);
    expect(controller.locale, isNull);
    expect(controller.themeMode, ThemeMode.system);
  });

  test('language and theme changes persist', () async {
    final controller = AppPreferencesController.instance;
    await controller.setLanguage(AppLanguage.simplifiedChinese);
    await controller.setThemeMode(ThemeMode.light);

    expect(controller.locale, const Locale('zh'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('dreamplayer.locale'), 'zh');
    expect(prefs.getString('dreamplayer.themeMode'), 'light');
  });

  test('light and dark themes expose matching brightness', () {
    expect(AppTheme.light().brightness, Brightness.light);
    expect(AppTheme.dark().brightness, Brightness.dark);
  });
}
