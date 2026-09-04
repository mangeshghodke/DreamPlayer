import 'package:flutter/material.dart';

class AppTheme {
  static const Color _seed = Color(0xFF7C4DFF);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    final dark = brightness == Brightness.dark;
    final scaffold = dark ? const Color(0xFF0E0E11) : colorScheme.surface;
    final container = dark
        ? const Color(0xFF16161A)
        : colorScheme.surfaceContainer;

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: brightness,
      scaffoldBackgroundColor: scaffold,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
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
        backgroundColor: container,
        indicatorColor: colorScheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(
          dark ? const Color(0xFF1C1C21) : colorScheme.surfaceContainerHigh,
        ),
        elevation: const WidgetStatePropertyAll(0),
        hintStyle: WidgetStatePropertyAll(
          TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      ),
      cardTheme: CardThemeData(
        color: container,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colorScheme.onSurfaceVariant,
      ),
      dividerTheme: DividerThemeData(
        color: dark ? const Color(0xFF232329) : colorScheme.outlineVariant,
      ),
    );
  }
}
