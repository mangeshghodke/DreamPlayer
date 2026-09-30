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
      // Re-load from prefs: this is the regression guard for persisting the
      // enum itself ("LibraryViewMode.compact") instead of its value
      // ("compact"), which fromString could never match — the setting then
      // silently reverted to poster on every app start.
      final reloaded = await LayoutStore.load();
      expect(reloaded.mode, LibraryViewMode.compact);
      expect(reloaded.columns, 5);
      expect(reloaded.columnsForWidth(1200), 5);
    });

    test('persists the raw value string, not the enum toString', () async {
      final store = await LayoutStore.load();
      await store.setMode(LibraryViewMode.compact);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dreamplayer.layout'), 'compact:0');
    });

    test('list mode is always one column, ignoring the override', () async {
      final store = await LayoutStore.load();
      await store.setColumns(6);
      expect(store.columnsForWidth(1200), 6);
      await store.setMode(LibraryViewMode.list);
      expect(store.isList, isTrue);
      expect(store.columnsForWidth(1200), 1, reason: 'a list is one per row');
      expect(store.columnsForWidth(360), 1);
    });

    test('persists and restores list mode', () async {
      final store = await LayoutStore.load();
      await store.setMode(LibraryViewMode.list);
      expect((await LayoutStore.load()).mode, LibraryViewMode.list);
    });

    test('honours an explicit column count on a narrow phone', () async {
      // The request was "see more titles at once", so an explicit 4 must
      // actually build 4 columns on a ~360dp phone rather than being silently
      // clamped back to the 2 that would fit.
      final store = await LayoutStore.load();
      await store.setColumns(4);
      expect(store.columnsForWidth(360), 4);
      expect(store.columnsForWidth(1080), 4);
    });

    test('clamps the stored count to the supported 0-8 range', () async {
      final store = await LayoutStore.load();
      await store.setColumns(99);
      expect(store.columns, LayoutStore.maxColumns);
      expect(store.columnsForWidth(360), LayoutStore.maxColumns);
      await store.setColumns(-4);
      expect(store.columns, 0, reason: 'negative means automatic');
      expect(store.columnsForWidth(360), 2, reason: 'falls back to the ladder');
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
