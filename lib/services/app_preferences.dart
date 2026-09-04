import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage { system, english, simplifiedChinese }

/// App-wide appearance preferences.  This notifier deliberately lives above
/// [MaterialApp] so language and theme changes apply immediately without
/// rebuilding the navigation stack.
class AppPreferencesController extends ChangeNotifier {
  AppPreferencesController._();

  static final AppPreferencesController instance =
      AppPreferencesController._();

  static const _languageKey = 'dreamplayer.locale';
  static const _themeKey = 'dreamplayer.themeMode';

  AppLanguage _language = AppLanguage.system;
  ThemeMode _themeMode = ThemeMode.system;

  AppLanguage get language => _language;
  ThemeMode get themeMode => _themeMode;

  Locale? get locale => switch (_language) {
    AppLanguage.system => null,
    AppLanguage.english => const Locale('en'),
    AppLanguage.simplifiedChinese => const Locale('zh'),
  };

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _language = switch (prefs.getString(_languageKey)) {
      'en' => AppLanguage.english,
      'zh' => AppLanguage.simplifiedChinese,
      _ => AppLanguage.system,
    };
    _themeMode = switch (prefs.getString(_themeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setLanguage(AppLanguage value) async {
    if (_language == value) return;
    _language = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _languageKey,
      switch (value) {
        AppLanguage.system => 'system',
        AppLanguage.english => 'en',
        AppLanguage.simplifiedChinese => 'zh',
      },
    );
  }

  Future<void> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, value.name);
  }
}
