import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/layout_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LayoutStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to the pre-existing poster behaviour', () async {
      final store = await LayoutStore.load();
      expect(store.mode, LibraryViewMode.poster);
      expect(store.columns, 0, reason: '0 = automatic');
    });

    test('round-trips mode and columns through prefs', () async {
      final store = await LayoutStore.load();
      await store.setMode(LibraryViewMode.compact);
      await store.setColumns(5);
      // A fresh load of the same singleton sees the persisted values.
      expect(store.mode, LibraryViewMode.compact);
      expect(store.columns, 5);
      expect(store.columnsForWidth(1200), 5);
    });

    test('clamps an explicit column count on narrow screens', () async {
      final store = await LayoutStore.load();
      // A phone cannot show 6 readable cards — the cap must win.
      await store.setColumns(6);
      expect(store.columnsForWidth(360), 2, reason: 'cap for <480 is 2');
      expect(store.columnsForWidth(600), 3, reason: 'cap for <760 is 3');
      expect(store.columnsForWidth(800), 4, reason: 'cap for <1000 is 4');
      expect(store.columnsForWidth(1200), 6, reason: 'cap for <1400 is 6');
      expect(store.columnsForWidth(1600), 6, reason: 'requested 6 exactly');
    });

    test('caps at 8 columns on very wide displays', () async {
      final store = await LayoutStore.load();
      await store.setColumns(99);
      expect(store.columns, LayoutStore.maxColumns);
      expect(store.columnsForWidth(2000), LayoutStore.maxColumns);
    });

    test('automatic mode reproduces the old responsive ladder', () {
      // Regression guard: these are the exact values the home screen used
      // before the preference existed.
      expect(LayoutStore.autoColumnsForWidth(360), 2);
      expect(LayoutStore.autoColumnsForWidth(500), 3);
      expect(LayoutStore.autoColumnsForWidth(800), 4);
      expect(LayoutStore.autoColumnsForWidth(1200), 6);
      expect(LayoutStore.autoColumnsForWidth(2000), 6);
    });

    test('restoring automatic overrides a previous explicit choice', () async {
      final store = await LayoutStore.load();
      await store.setColumns(5);
      expect(store.columnsForWidth(1200), 5);
      await store.setColumns(0);
      expect(store.columnsForWidth(1200), 6);
      expect(store.columnsForWidth(360), 2);
    });

    test('compact mode shortens the text block, poster does not', () async {
      final store = await LayoutStore.load();
      expect(store.textBlockHeight(84), 84);
      await store.setMode(LibraryViewMode.compact);
      expect(store.textBlockHeight(84), lessThan(84));
      expect(store.textBlockHeight(84), greaterThan(0));
    });

    test('survives a corrupt pref value', () async {
      SharedPreferences.setMockInitialValues({'dreamplayer.layout': 'garbage'});
      final store = await LayoutStore.load();
      expect(store.mode, LibraryViewMode.poster);
      expect(store.columns, 0);
    });

    test('notifies listeners when the layout changes', () async {
      final store = await LayoutStore.load();
      var notifications = 0;
      store.addListener(() => notifications++);
      await store.setColumns(4);
      await store.setMode(LibraryViewMode.compact);
      expect(notifications, 2);
      // Setting the same value again is a no-op.
      await store.setColumns(4);
      expect(notifications, 2);
    });
  });
}
