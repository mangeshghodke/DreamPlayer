import 'package:dream_player/services/library_folders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LibraryFolder folder(
    String id, {
    String name = 'House',
    String path = 'tree:bookmark1',
    DateTime? addedAt,
  }) {
    return LibraryFolder(
      id: id,
      name: name,
      path: path,
      addedAt: addedAt ?? DateTime.fromMillisecondsSinceEpoch(1000),
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LibraryFolder', () {
    test('json round-trip preserves fields', () {
      final original = LibraryFolder(
        id: 'b1',
        name: 'Dune',
        path: '/sdcard/Movies',
        addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        yearHint: 2021,
      );
      final restored = LibraryFolder.fromJson(original.toJson());
      expect(restored.id, 'b1');
      expect(restored.name, 'Dune');
      expect(restored.path, '/sdcard/Movies');
      expect(restored.addedAt, original.addedAt);
      expect(restored.isJellyfin, false);
      expect(restored.yearHint, 2021);
    });

    test('metadataKey is folder:<id>', () {
      expect(folder('abc').metadataKey, 'folder:abc');
    });

    test('json round-trip preserves jellyfin source fields', () {
      final original = LibraryFolder(
        id: 'jellyfin_folder_192.168.1.16_ser1',
        name: 'Succession',
        path: 'jellyfin:ser1',
        addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        source: LibraryFolderSource.jellyfin,
        jellyfinServerUrl: 'http://192.168.1.16:8096',
        jellyfinItemId: 'ser1',
      );
      final restored = LibraryFolder.fromJson(original.toJson());
      expect(restored.isJellyfin, true);
      expect(restored.source, LibraryFolderSource.jellyfin);
      expect(restored.jellyfinServerUrl, 'http://192.168.1.16:8096');
      expect(restored.jellyfinItemId, 'ser1');
      expect(restored.path, 'jellyfin:ser1');
    });

    test('missing source field defaults to files (legacy entries)', () {
      final restored = LibraryFolder.fromJson({
        'id': 'old',
        'name': 'Legacy',
        'path': '/sdcard',
        'addedAtMs': 1000,
      });
      expect(restored.isJellyfin, false);
      expect(restored.jellyfinItemId, isNull);
    });
  });

  group('LibraryFoldersStore', () {
    test('load returns empty when nothing stored', () async {
      expect(await LibraryFoldersStore.load(), isEmpty);
    });

    test('add persists, most recently added first', () async {
      await LibraryFoldersStore.add(folder('a'));
      await LibraryFoldersStore.add(folder('b'));
      final loaded = await LibraryFoldersStore.load();
      expect(loaded.map((f) => f.id), ['b', 'a']);
    });

    test('add with an existing id moves it to the front', () async {
      await LibraryFoldersStore.add(folder('a'));
      await LibraryFoldersStore.add(folder('b'));
      await LibraryFoldersStore.add(folder('a'));
      final loaded = await LibraryFoldersStore.load();
      expect(loaded.map((f) => f.id), ['a', 'b']);
    });

    test('remove deletes the folder', () async {
      await LibraryFoldersStore.add(folder('a'));
      await LibraryFoldersStore.add(folder('b'));
      await LibraryFoldersStore.remove('a');
      final loaded = await LibraryFoldersStore.load();
      expect(loaded.map((f) => f.id), ['b']);
    });

    test('corrupt json falls back to empty', () async {
      SharedPreferences.setMockInitialValues(
        {'dreamplayer.libraryFolders': 'not json'},
      );
      expect(await LibraryFoldersStore.load(), isEmpty);
    });
  });
}
