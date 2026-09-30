import 'package:flutter/material.dart';

class AppTheme {
  /// The original violet, kept as the default when no accent is chosen.
  static const Color defaultSeed = Color(0xFF7C4DFF);

  static ThemeData dark({Color seed = defaultSeed}) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFF0E0E11),
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFF0E0E11),
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: colorScheme.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF16161A),
        indicatorColor: colorScheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      searchBarTheme: const SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(Color(0xFF1C1C21)),
        elevation: WidgetStatePropertyAll(0),
        hintStyle: WidgetStatePropertyAll(
          TextStyle(color: Color(0xFF8A8A93)),
        ),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF16161A),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colorScheme.onSurfaceVariant,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF232329),
      ),
    );
  }
}
