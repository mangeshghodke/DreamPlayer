import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lets the user pick any of the ~1900 Google Fonts (issue #34, item 4).
///
/// Two things this must survive, both learned the hard way:
///  * A font that cannot be loaded must NOT break the theme. `google_fonts`
///    throws when it cannot fetch/parse a family, and a media player is used
///    on offline LANs — so every application is guarded and falls back to the
///    platform font.
///  * Fetched fonts are cached on disk by the package, so a family only needs
///    a connection the first time it is chosen.
class FontStore {
  FontStore._();

  static const String _prefsKey = 'dreamplayer.fontFamily';

  /// Null means "use the platform font" — the default and the safe fallback.
  static String? _family;

  static String? get family => _family;

  /// Every family name in the catalog, sorted. The list is large (~1900), so
  /// the picker is a lazy list behind a search field.
  static List<String> get catalog {
    final names = GoogleFonts.asMap().keys.toList()..sort();
    return names;
  }

  static Future<FontStore> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _family = prefs.getString(_prefsKey);
    } catch (_) {
      _family = null;
    }
    return FontStore._();
  }

  static Future<void> setFamily(String? family) async {
    // An empty string is the same as "no choice"; normalise to null so the
    // theme falls back cleanly.
    _family = (family == null || family.trim().isEmpty) ? null : family.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_family == null) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, _family!);
      }
    } catch (_) {
      // Non-fatal; the choice still applies for this session.
    }
  }

  /// Applies the chosen family to [base].
  ///
  /// Returns [base] untouched when there is no choice, when the family is not
  /// in the catalog, or when the font fails to load — a broken font must never
  /// leave the app with unrenderable text.
  static TextTheme apply(TextTheme base) {
    final name = _family;
    if (name == null) return base;
    if (!GoogleFonts.asMap().containsKey(name)) return base;
    try {
      final themed = _buildTextTheme(name, base);
      // A font that resolved to nothing usable leaves the family unset; keep
      // the base theme in that case.
      if (themed.bodyMedium?.fontFamily == null) return base;
      return themed;
    } catch (_) {
      // Includes google_fonts' own "unable to load font" failure.
      return base;
    }
  }

  static TextTheme _buildTextTheme(String name, TextTheme base) {
    // `getFont` is the documented entry point: it resolves the display name
    // ("AR One Sans") to the registered family id and triggers the load. It
    // throws for an unknown family, hence the guard.
    if (!GoogleFonts.asMap().containsKey(name)) return base;
    final style = GoogleFonts.getFont(name);
    return _mapTheme(base, style);
  }

  /// Re-applies [style]'s family across [base] while keeping every size,
  /// weight and colour the app already had.
  static TextTheme _mapTheme(TextTheme base, TextStyle style) {
    TextStyle? apply(TextStyle? s) {
      if (s == null) return null;
      return s.copyWith(
        fontFamily: style.fontFamily,
        fontFamilyFallback: style.fontFamilyFallback,
      );
    }

    return base.copyWith(
      displayLarge: apply(base.displayLarge),
      displayMedium: apply(base.displayMedium),
      displaySmall: apply(base.displaySmall),
      headlineLarge: apply(base.headlineLarge),
      headlineMedium: apply(base.headlineMedium),
      headlineSmall: apply(base.headlineSmall),
      titleLarge: apply(base.titleLarge),
      titleMedium: apply(base.titleMedium),
      titleSmall: apply(base.titleSmall),
      bodyLarge: apply(base.bodyLarge),
      bodyMedium: apply(base.bodyMedium),
      bodySmall: apply(base.bodySmall),
      labelLarge: apply(base.labelLarge),
      labelMedium: apply(base.labelMedium),
      labelSmall: apply(base.labelSmall),
    );
  }
}

/// Lets a settings change ask the root widget to rebuild the theme.
///
/// The app's `MaterialApp` is built inside a `ListenableBuilder`, so a font
/// change has to nudge that builder rather than only the settings screen.
class AppSettingsBus extends ValueNotifier<int> {
  AppSettingsBus._() : super(0);
  static final AppSettingsBus instance = AppSettingsBus._();

  void notify() => value++;
}
