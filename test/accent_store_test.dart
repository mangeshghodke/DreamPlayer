import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/accent_store.dart';
import 'package:dream_player/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AccentStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to the original violet accent', () async {
      final store = await AccentStore.load();
      expect(store.accent.id, 'violet');
      expect(store.accent.color, AppTheme.defaultSeed);
    });

    test('persists and restores a chosen accent', () async {
      final store = await AccentStore.load();
      final cyan = AccentStore.accents.firstWhere((a) => a.id == 'cyan');
      await store.setAccent(cyan);
      expect(store.accent.id, 'cyan');
      // A fresh load sees the persisted id.
      final reloaded = await AccentStore.load();
      expect(reloaded.accent.id, 'cyan');
    });

    test('ignores an unknown persisted id', () async {
      SharedPreferences.setMockInitialValues(
        {'dreamplayer.accent': 'chartreuse-that-does-not-exist'},
      );
      final store = await AccentStore.load();
      expect(store.accent.id, 'violet');
    });

    test('every accent changes the generated ColorScheme', () {
      // Guards against a palette entry that is visually identical to another
      // after ColorScheme.fromSeed munges it.
      final schemes = {
        for (final a in AccentStore.accents)
          AppTheme.dark(seed: a.color).colorScheme.primary,
      };
      expect(schemes.length, AccentStore.accents.length);
    });

    test('notifies listeners only on a real change', () async {
      final store = await AccentStore.load();
      var n = 0;
      store.addListener(() => n++);
      await store.setAccent(AccentStore.accents[1]);
      expect(n, 1);
      await store.setAccent(AccentStore.accents[1]);
      expect(n, 1, reason: 'selecting the same accent is a no-op');
    });

    test('accent colours stay distinct from the dark scaffold', () {
      // Each seed must be light enough to read on #0E0E11.
      const scaffold = Color(0xFF0E0E11);
      for (final a in AccentStore.accents) {
        expect(
          a.color.computeLuminance(),
          greaterThan(scaffold.computeLuminance() * 3),
          reason: '${a.id} is too dark to read on the app background',
        );
      }
    });

    test('indicatorColorFor is the NavigationBar indicator colour', () {
      // The splash and the nav pill must be the same colour, so pin both
      // sides of the definition: the theme really uses primaryContainer as
      // the indicator, and the store exposes exactly that value.
      final themeSource = File('lib/theme/app_theme.dart').readAsStringSync();
      expect(themeSource, contains('indicatorColor: colorScheme.primaryContainer'));
      for (final a in AccentStore.accents) {
        final scheme =
            ColorScheme.fromSeed(seedColor: a.color, brightness: Brightness.dark);
        expect(AccentStore.indicatorColorFor(a), scheme.primaryContainer,
            reason: '${a.id}: splash colour would differ from the nav pill');
      }
    });

    test('persists the indicator colour for the native splash', () async {
      final store = await AccentStore.load();
      final prefs = await SharedPreferences.getInstance();
      final hex = prefs.getString(AccentStore.indicatorPrefsKey);
      expect(hex, isNotNull);
      expect(hex, startsWith('0x'));
      final parsed = int.parse(hex!.substring(2), radix: 16);
      expect(parsed, AccentStore.indicatorColorFor(store.accent).toARGB32());

      // A change of accent rewrites it.
      final pink = AccentStore.accents.firstWhere((a) => a.id == 'pink');
      await store.setAccent(pink);
      final hex2 = (await SharedPreferences.getInstance())
          .getString(AccentStore.indicatorPrefsKey);
      expect(int.parse(hex2!.substring(2), radix: 16),
          AccentStore.indicatorColorFor(pink).toARGB32());
    });
  });
}
