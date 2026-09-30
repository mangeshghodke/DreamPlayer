import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/font_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FontStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to the platform font', () async {
      await FontStore.load();
      expect(FontStore.family, isNull);
    });

    test('exposes a large searchable catalog', () {
      final catalog = FontStore.catalog;
      expect(catalog.length, greaterThan(500),
          reason: 'the point of the feature is breadth of choice');
      // Sorted, so the list is stable between launches.
      final sorted = [...catalog]..sort();
      expect(catalog, sorted);
      expect(catalog, contains('Inter'));
    });

    test('persists and restores a chosen family', () async {
      await FontStore.setFamily('Poppins');
      await FontStore.load();
      expect(FontStore.family, 'Poppins');
    });

    test('treats an empty choice as "platform default"', () async {
      await FontStore.setFamily('Poppins');
      await FontStore.setFamily('');
      expect(FontStore.family, isNull);
      await FontStore.load();
      expect(FontStore.family, isNull);
    });

    test('leaves the theme untouched when no font is chosen', () {
      final base = ThemeData.dark().textTheme;
      expect(FontStore.apply(base), same(base));
    });

    test('never blanks text when a font cannot be loaded', () async {
      // A family that does not exist must be ignored, not rendered blank.
      await FontStore.setFamily('Definitely Not A Real Font 12345');
      final base = ThemeData.dark().textTheme;
      final themed = FontStore.apply(base);
      expect(themed, isNotNull);
      // Whatever happens, the body style must still carry a usable family or
      // be the untouched base.
      expect(themed.bodyMedium?.fontFamily, isNot(''));
    });

    test('a real family actually reaches every text style', () async {
      await FontStore.setFamily('Poppins');
      final base = ThemeData.dark().textTheme;
      final themed = FontStore.apply(base);

      // Regression guard: an earlier version used a raw
      // TextStyle(fontFamily: name), which asks the engine for a family that
      // is never registered, so the app silently kept the default font and the
      // setting looked broken. google_fonts registers e.g. "Poppins_regular",
      // so the family must actually change.
      expect(themed.bodyMedium?.fontFamily, isNotNull);
      expect(themed.bodyMedium?.fontFamily, isNot(base.bodyMedium?.fontFamily));
      expect(themed.bodyMedium?.fontFamily, contains('Poppins'));
      // And it must be applied across the theme, not just bodyMedium.
      expect(themed.titleLarge?.fontFamily, isNotNull);
      expect(themed.labelSmall?.fontFamily, isNotNull);
    });

    test('resolves display names containing spaces', () async {
      await FontStore.setFamily('AR One Sans');
      final themed = FontStore.apply(ThemeData.dark().textTheme);
      // Registered id strips the spaces ("AROneSans_regular").
      expect(themed.bodyMedium?.fontFamily, contains('AROneSans'));
    });
  });
}
