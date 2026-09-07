import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages the app language override. When null, the device system language is
/// used. Persists the user's choice across launches.
class LanguageService extends ChangeNotifier {
  LanguageService._();
  static final LanguageService instance = LanguageService._();

  /// Shared-preferences key for the stored language code.
  static const _prefKey = 'dreamplayer.languageCode';

  /// The effective locale. `null` means "follow system".
  Locale? _locale;

  /// The effective locale. `null` means "follow system".
  Locale? get locale => _locale;

  /// User-facing label for the current language selection.
  String get label {
    if (_locale == null) return 'System default';
    return _locale!.languageCode;
  }

  /// Loads the persisted language preference. Call once at app start.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefKey);
    if (code != null && code.isNotEmpty) {
      _locale = Locale(code);
    }
    notifyListeners();
  }

  /// Sets the app language. Pass `null` to follow the system language.
  Future<void> setLanguage(Locale? locale) async {
    _locale = locale;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(_prefKey);
    } else {
      await prefs.setString(_prefKey, locale.languageCode);
    }
  }
}
