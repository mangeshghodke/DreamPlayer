import 'package:dream_player/services/library_folders.dart';
import 'package:dream_player/services/local_library_rescan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A scanner entry as `FolderScanner` would emit it: `parentId` set, `id`
/// derived from a path hash, `addedAt` stamped at scan time.
LibraryFolder scanned(
  String path, {
  String? name,
  String? id,
  bool isFile = false,
  int? sizeBytes,
  DateTime? addedAt,
}) {
  return LibraryFolder(
    // Scanner ids are unique per entry; deriving one from the path keeps the
    // fixture honest (a shared id would collapse two distinct entries).
    id: id ?? 'root_1_${path.hashCode}',
    name: name ?? path.split('/').last,
    path: path,
    addedAt: addedAt ?? DateTime.fromMillisecondsSinceEpoch(9999),
    parentId: 'root_1',
    isFile: isFile,
    videoPath: isFile ? path : null,
    videoSizeBytes: sizeBytes,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildPlan', () {
    test('an unchanged scan writes nothing', () {
      final existing = [
        scanned('tree:b/House', name: 'House'),
        scanned('tree:b/Dune', name: 'Dune'),
      ];
      final fresh = [
        scanned('tree:b/House', name: 'House', id: 'root_1_DIFFERENT'),
        scanned('tree:b/Dune', name: 'Dune', id: 'root_1_OTHER'),
      ];

      final plan = LocalLibraryRescan.buildPlan(
        existing: existing,
        scanned: fresh,
        allowRemovals: true,
      );

      expect(plan.isEmpty, isTrue);
      expect(plan.unchanged, 2);
      expect(plan.added, 0);
    });

    test('a file added on disk becomes a new card', () {
      final existing = [scanned('tree:b/House', name: 'House')];
      final fresh = [
        scanned('tree:b/House', name: 'House'),
        scanned('tree:b/House/Show.S02E01.mkv', isFile: true, sizeBytes: 900),
      ];

      final plan = LocalLibraryRescan.buildPlan(
        existing: existing,
        scanned: fresh,
        allowRemovals: true,
      );

      expect(plan.added, 1);
      expect(plan.removeIds, isEmpty);
      expect(plan.upserts.single.path, 'tree:b/House/Show.S02E01.mkv');
      expect(plan.upserts.single.isFile, isTrue);
    });

    test('a folder deleted on disk is pruned', () {
      final existing = [
        scanned('tree:b/House', name: 'House', id: 'old_house'),
        scanned('tree:b/Dune', name: 'Dune', id: 'old_dune'),
      ];
      final fresh = [scanned('tree:b/House', name: 'House')];

      final plan = LocalLibraryRescan.buildPlan(
        existing: existing,
        scanned: fresh,
        allowRemovals: true,
      );

      expect(plan.removeIds, ['old_dune']);
      expect(plan.added, 0);
    });

    test('a matched entry keeps its id so folder:<id> metadata survives', () {
      // This is the load-bearing invariant: `metadataKey` is `folder:<id>` for a
      // folder, so a regenerated id silently drops its cached TMDB poster and
      // artwork overrides.
      final original = DateTime.fromMillisecondsSinceEpoch(1000);
      final existing = [
        scanned('tree:b/House', name: 'House', id: 'keep_me', addedAt: original),
      ];
      final fresh = [
        scanned('tree:b/House', name: 'House', id: 'regenerated_hash'),
      ];

      final plan = LocalLibraryRescan.buildPlan(
        existing: existing,
        scanned: fresh,
        allowRemovals: true,
      );

      // Nothing changed, so nothing is written at all.
      expect(plan.isEmpty, isTrue);

      // Force a write by changing the content, then check identity survives.
      final renamed = LocalLibraryRescan.buildPlan(
        existing: existing,
        scanned: [
          scanned('tree:b/House', name: 'House MD', id: 'regenerated_hash'),
        ],
        allowRemovals: true,
      );
      expect(renamed.upserts.single.id, 'keep_me');
      expect(renamed.upserts.single.addedAt, original);
      expect(renamed.upserts.single.name, 'House MD');
      expect(renamed.added, 0, reason: 'a rename is an update, not a new card');
    });

    test('a resized file is updated in place, not re-added', () {
      final existing = [
        scanned('tree:b/House/ep.mkv', isFile: true, sizeBytes: 100, id: 'ep'),
      ];
      final fresh = [
        scanned('tree:b/House/ep.mkv', isFile: true, sizeBytes: 250, id: 'ep2'),
      ];

      final plan = LocalLibraryRescan.buildPlan(
        existing: existing,
        scanned: fresh,
        allowRemovals: true,
      );

      expect(plan.added, 0);
      expect(plan.removeIds, isEmpty);
      expect(plan.upserts.single.id, 'ep');
      expect(plan.upserts.single.videoSizeBytes, 250);
    });

    test('an untrustworthy scan adds but never removes', () {
      // The unmounted-SD-card / revoked-permission case: the listing failed, so
      // the missing entries are "could not read", not "deleted".
      final existing = [
        scanned('tree:b/House', name: 'House', id: 'h'),
        scanned('tree:b/Dune', name: 'Dune', id: 'd'),
      ];
      final fresh = [scanned('tree:b/House', name: 'House', id: 'h2')];

      final plan = LocalLibraryRescan.buildPlan(
        existing: existing,
        scanned: fresh,
        allowRemovals: false,
      );

      expect(plan.removeIds, isEmpty);
      expect(plan.unchanged, 1);
    });

    test('a file reachable twice is only added once', () {
      final fresh = [
        scanned('tree:b/TV/ep.mkv', isFile: true, id: 'a'),
        scanned('tree:b/TV/ep.mkv', isFile: true, id: 'b'),
      ];

      final plan = LocalLibraryRescan.buildPlan(
        existing: const [],
        scanned: fresh,
        allowRemovals: true,
      );

      expect(plan.added, 1);
    });

    test('identity separates folders from files at the same path', () {
      expect(scanIdentityOf(scanned('tree:b/House')), isNot(scanIdentityOf(scanned('tree:b/House', isFile: true))));
    });
  });

  group('reconstructRoot', () {
    test('recovers the folder that was scanned from its children', () {
      // Bookmarked "House" directly: children sit under tree:b/House.
      final root = LocalLibraryRescan.reconstructRoot('b', [
        scanned('tree:b/House/Season 01', name: 'Season 01'),
        scanned('tree:b/House/Dune', name: 'Dune'),
      ]);

      expect(root, isNotNull);
      expect(root!.path, 'tree:b/House');
      expect(root.name, 'House');
      expect(root.source, LibraryFolderSource.files);
    });

    test('a lone file child yields its directory, not the file', () {
      final root = LocalLibraryRescan.reconstructRoot('b', [
        scanned('tree:b/House/ep.mkv', isFile: true),
      ]);

      expect(root!.path, 'tree:b/House');
      expect(root.name, 'House');
    });

    test('children directly under the tree root give an unnamed seed', () {
      // Correct path, but no display name — and such a root is never trusted
      // with removals, so a wrong guess cannot delete a library.
      final root = LocalLibraryRescan.reconstructRoot('b', [
        scanned('tree:b/House', name: 'House'),
        scanned('tree:b/Dune', name: 'Dune'),
      ]);

      expect(root!.path, 'tree:b');
      expect(root.name, isEmpty);
    });

    test('absolute paths work too', () {
      final root = LocalLibraryRescan.reconstructRoot('p', [
        scanned('/storage/emulated/0/Movies/House', name: 'House'),
        scanned('/storage/emulated/0/Movies/Dune', name: 'Dune'),
      ]);

      expect(root!.path, '/storage/emulated/0/Movies');
      expect(root.name, 'Movies');
    });

    test('refuses a mixed local/network group', () {
      final network = LibraryFolder(
        id: 'n',
        name: 'Share',
        path: 'smb:s1/Movies',
        addedAt: DateTime.fromMillisecondsSinceEpoch(1),
        source: LibraryFolderSource.smb,
        parentId: 'b',
      );
      expect(
        LocalLibraryRescan.reconstructRoot('b', [
          scanned('tree:b/House', name: 'House'),
          network,
        ]),
        isNull,
      );
    });

    test('returns null when there is nothing to go on', () {
      expect(LocalLibraryRescan.reconstructRoot('b', const []), isNull);
    });
  });

  group('LibraryFoldersStore rescan support', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    LibraryFolder root(String id) => LibraryFolder(
          id: id,
          name: 'House',
          path: 'tree:b/House',
          addedAt: DateTime.fromMillisecondsSinceEpoch(5),
        );

    LibraryFolder child(String id, String parentId) => LibraryFolder(
          id: id,
          name: 'Season 01',
          path: 'tree:b/House/$id',
          addedAt: DateTime.fromMillisecondsSinceEpoch(6),
          parentId: parentId,
        );

    test('scan roots round-trip', () async {
      await LibraryFoldersStore.saveScanRoot(root('root_1'));
      final loaded = await LibraryFoldersStore.loadScanRoots();
      expect(loaded['root_1']?.path, 'tree:b/House');
      expect(loaded['root_1']?.name, 'House');
    });

    test('removing one child keeps the root; removing the last drops it', () async {
      await LibraryFoldersStore.saveScanRoot(root('root_1'));
      await LibraryFoldersStore.bulkAdd([
        child('c1', 'root_1'),
        child('c2', 'root_1'),
      ]);

      await LibraryFoldersStore.remove('c1');
      expect((await LibraryFoldersStore.loadScanRoots()).containsKey('root_1'), isTrue,
          reason: 'siblings still reference it');

      await LibraryFoldersStore.remove('c2');
      expect((await LibraryFoldersStore.loadScanRoots()).containsKey('root_1'), isFalse,
          reason: 'nothing references it any more');
    });

    test('an emptied folder keeps its root so later files are found', () async {
      // The rescan prunes the last child when the user deletes the files
      // themselves; forgetting the seed here would make a file added later
      // undiscoverable.
      await LibraryFoldersStore.saveScanRoot(root('root_1'));
      await LibraryFoldersStore.bulkAdd([child('c1', 'root_1')]);

      await LibraryFoldersStore.applyDiff(upserts: const [], removeIds: ['c1']);
      expect((await LibraryFoldersStore.loadScanRoots()).containsKey('root_1'), isTrue);
    });

    test('clearAll drops the roots with the folders', () async {
      await LibraryFoldersStore.saveScanRoot(root('root_1'));
      await LibraryFoldersStore.clearAll();
      expect(await LibraryFoldersStore.loadScanRoots(), isEmpty);
    });

    test('applyDiff adds, updates, removes and keeps grid order', () async {
      final first = LibraryFolder(
        id: 'a',
        name: 'Alpha',
        path: 'tree:b/Alpha',
        addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        parentId: 'root',
      );
      final second = LibraryFolder(
        id: 'b',
        name: 'Beta',
        path: 'tree:b/Beta',
        addedAt: DateTime.fromMillisecondsSinceEpoch(2000),
        parentId: 'root',
      );
      final third = LibraryFolder(
        id: 'c',
        name: 'Gamma',
        path: 'tree:b/Gamma',
        addedAt: DateTime.fromMillisecondsSinceEpoch(3000),
        parentId: 'root',
      );
      await LibraryFoldersStore.bulkAdd([third, second, first]);

      await LibraryFoldersStore.applyDiff(
        upserts: [
          second.copyWith(name: 'Beta (2021)'),
          LibraryFolder(
            id: 'd',
            name: 'Delta',
            path: 'tree:b/Delta',
            addedAt: DateTime.fromMillisecondsSinceEpoch(4000),
            parentId: 'root',
          ),
        ],
        removeIds: ['a'],
      );

      final all = await LibraryFoldersStore.load();
      expect(all.map((f) => f.id).toList(), ['c', 'b', 'd'],
          reason: 'update keeps its slot, new entries append, nothing reshuffles');
      expect(all.firstWhere((f) => f.id == 'b').name, 'Beta (2021)');
    });

    test('applyDiff is a no-op when there is nothing to do', () async {
      await LibraryFoldersStore.bulkAdd([
        LibraryFolder(
          id: 'a',
          name: 'Alpha',
          path: 'tree:b/Alpha',
          addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      ]);
      await LibraryFoldersStore.applyDiff(upserts: const [], removeIds: const []);
      expect((await LibraryFoldersStore.load()).length, 1);
    });
  });

  group('LocalRescanResult', () {
    test('counts only real changes', () {
      const none = LocalRescanResult(rootsScanned: 2);
      expect(none.changed, 0);
      const some = LocalRescanResult(rootsScanned: 2, added: 1, removed: 3);
      expect(some.changed, 4);
      expect(some.toString(), contains('added: 1'));
    });
  });
}