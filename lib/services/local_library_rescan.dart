import 'folder_scanner.dart';
import 'library_folders.dart';

/// Identity of one scanned entry: WHERE it is, not what it is called.
///
/// Deliberately not the scanner's `id`. Scanner ids embed `String.hashCode`,
/// which carries no cross-version guarantee — a regenerated id would orphan the
/// entry's `folder:<id>` TMDB metadata and artwork overrides, so every refresh
/// would drop the poster off the grid.
String scanIdentityOf(LibraryFolder folder) => '${folder.source.name}|'
    '${folder.isFile ? 'f' : 'd'}|'
    '${folder.isFile ? (folder.videoPath ?? folder.path) : folder.path}';

/// What a rescan wants done to the library. Pure data, so the reconciliation
/// rules can be tested without a device or platform channel.
class RescanPlan {
  const RescanPlan({
    required this.upserts,
    required this.removeIds,
    required this.added,
    required this.unchanged,
  });

  /// Entries to write: genuinely new ones, plus matched ones whose content
  /// changed (renamed, resized). Unchanged entries are absent — writing them
  /// would be a no-op that still costs a prefs round-trip.
  final List<LibraryFolder> upserts;

  /// Ids whose file/folder is gone from disk.
  final List<String> removeIds;

  /// How many of [upserts] are new rather than refreshed.
  final int added;

  /// Matched entries that were already correct.
  final int unchanged;

  bool get isEmpty => upserts.isEmpty && removeIds.isEmpty;
  int get changeCount => upserts.length + removeIds.length;
}

/// Re-scans **local** library folders so files added or deleted on the device
/// show up on the home grid (issue #39).
///
/// Only [LibraryFolderSource.files]. A network source costs one round-trip per
/// subfolder (≈50 folders is 5-10 s on a LAN), which is why it is refreshed
/// explicitly instead of on every pull — and a pull-to-refresh that stalls for
/// ten seconds on a NAS library is worse than the staleness it fixes.
///
/// Two safety rules, because the destructive half of a rescan is the dangerous
/// half:
///
/// 1. A directory whose listing FAILED (revoked permission, unmounted SD card,
///    folder moved) must never read as "empty". [FolderScanner.failedDirs] > 0
///    turns removals off and keeps only the additions — losing a card is
///    annoying, losing a library because a card reader glitched is not
///    acceptable. The entries it skipped are pruned by the next clean scan.
/// 2. A root we had to RECONSTRUCT rather than read from the persisted scan
///    root may be the wrong directory, so it adds but never removes.
class LocalLibraryRescan {
  const LocalLibraryRescan();

  Future<LocalRescanResult> run() async {
    final folders = await LibraryFoldersStore.load();
    final roots = await LibraryFoldersStore.loadScanRoots();

    // Children of each local scan root. Entries with no parentId were added one
    // at a time (a single bookmarked folder), not expanded — there is nothing to
    // reconcile for those: the card IS the folder, so new files inside it show
    // up when the folder is opened, which already re-lists every time.
    final childrenByParent = <String, List<LibraryFolder>>{};
    for (final folder in folders) {
      final parentId = folder.parentId;
      if (parentId == null) continue;
      if (folder.source != LibraryFolderSource.files) continue;
      childrenByParent.putIfAbsent(parentId, () => []).add(folder);
    }

    // Persisted local roots with no children are still rescanned: that is the
    // "user deleted everything, then added something new" case, and dropping
    // them here would strand the root record forever.
    for (final root in roots.values) {
      if (root.source != LibraryFolderSource.files) continue;
      childrenByParent.putIfAbsent(root.id, () => []);
    }

    if (childrenByParent.isEmpty) {
      return const LocalRescanResult();
    }

    final maxDepth = await FolderScanner.savedScanDepth();
    var added = 0;
    var removed = 0;
    var updated = 0;
    var rootsScanned = 0;
    final skipped = <String>[];

    for (final entry in childrenByParent.entries) {
      final existing = entry.value;
      final persisted = roots[entry.key];
      var root = persisted;
      var confident = persisted != null;
      if (root == null) {
        root = reconstructRoot(entry.key, existing);
        confident = root != null && root.name.isNotEmpty;
      }
      if (root == null) {
        skipped.add(entry.key);
        continue;
      }

      final scanner = FolderScanner(maxDepth: maxDepth);
      List<LibraryFolder> fresh;
      try {
        fresh = await scanner.scan(root);
      } catch (_) {
        skipped.add(entry.key);
        continue;
      }
      rootsScanned++;

      // An empty result for a root that HAS children is the signature of an
      // unreadable directory, not of an emptied one — never treat it as
      // "delete everything".
      final unreadable = scanner.failedDirs > 0 || (fresh.isEmpty && existing.isNotEmpty);
      final diff = buildPlan(
        existing: existing,
        scanned: fresh,
        allowRemovals: confident && !unreadable,
      );

      if (!diff.isEmpty) {
        await LibraryFoldersStore.applyDiff(
          upserts: diff.upserts,
          removeIds: diff.removeIds,
        );
        added += diff.added;
        removed += diff.removeIds.length;
        updated += diff.upserts.length - diff.added;
      }

      // Persist a reconstructed root so the next refresh starts from the exact
      // directory rather than guessing it again. ONLY when it was confident:
      // an unnamed guess (children sitting directly in `tree:<id>`, so the
      // seed's display name is unknowable) is deliberately re-guessed every
      // time, because freezing it in the store would make the NEXT refresh
      // trust it for removals — the exact thing it was too unsure to allow.
      if (persisted == null && confident && root.id.isNotEmpty) {
        await LibraryFoldersStore.saveScanRoot(root);
      }
    }

    // Scan roots are NOT pruned here. A root whose children were all removed
    // looks identical to a root the user emptied on purpose, and dropping the
    // seed in that case would make files added later undiscoverable. They are
    // dropped by `LibraryFoldersStore.remove` instead, where the intent is
    // known.
    return LocalRescanResult(
      rootsScanned: rootsScanned,
      added: added,
      removed: removed,
      updated: updated,
      skippedRoots: skipped,
    );
  }

  /// The reconciliation itself, as a pure function.
  ///
  /// [allowRemovals] false means "this scan is not trustworthy enough to
  /// delete": additions still apply, nothing is removed.
  static RescanPlan buildPlan({
    required List<LibraryFolder> existing,
    required List<LibraryFolder> scanned,
    required bool allowRemovals,
  }) {
    final byIdentity = <String, LibraryFolder>{
      for (final folder in existing) scanIdentityOf(folder): folder,
    };
    final upserts = <LibraryFolder>[];
    final seen = <String>{};
    var added = 0;
    var unchanged = 0;

    for (final fresh in scanned) {
      final identity = scanIdentityOf(fresh);
      // The scanner can legitimately meet the same file twice (a loose file
      // inside a mixed container is also reachable through its folder entry).
      if (!seen.add(identity)) continue;
      final prior = byIdentity[identity];
      if (prior == null) {
        upserts.add(fresh);
        added++;
        continue;
      }
      // Keep the id and addedAt of what is already stored: `metadataKey` is
      // `folder:<id>` for a folder, and home orders by addedAt. Carrying the
      // scan's values over instead would reset both on every refresh.
      final merged = fresh.copyWith(id: prior.id, addedAt: prior.addedAt);
      if (merged.sameContentAs(prior)) {
        // Counted, never written: a no-op upsert still costs a prefs write.
        unchanged++;
      } else {
        upserts.add(merged);
      }
    }

    final removeIds = <String>[];
    if (allowRemovals) {
      for (final folder in existing) {
        if (!seen.contains(scanIdentityOf(folder))) removeIds.add(folder.id);
      }
    }

    return RescanPlan(
      upserts: upserts,
      removeIds: removeIds,
      added: added,
      unchanged: unchanged,
    );
  }

  /// Best-effort scan root for libraries bookmarked BEFORE scan roots were
  /// persisted (the parent was dropped, so the only evidence left is the
  /// children's paths).
  ///
  /// The longest common directory prefix of the children IS the directory that
  /// was scanned: bookmark "Movies" and the children are `tree:X/House`,
  /// `tree:X/Dune` → `tree:X`; bookmark "House" directly → `tree:X/House`.
  /// Returns null when there is nothing to go on, or when any child is not
  /// local (a mixed group is not ours to rescan).
  static LibraryFolder? reconstructRoot(String parentId, List<LibraryFolder> children) {
    if (children.isEmpty) return null;
    if (children.any((c) => c.source != LibraryFolderSource.files)) return null;

    final segments = <List<String>>[
      for (final child in children)
        (child.isFile ? (child.videoPath ?? child.path) : child.path)
            .split('/')
            .where((s) => s.isNotEmpty)
            .toList(),
    ];
    if (segments.any((s) => s.isEmpty)) return null;

    var common = segments.first;
    for (final parts in segments.skip(1)) {
      var i = 0;
      while (i < common.length && i < parts.length && common[i] == parts[i]) {
        i++;
      }
      common = common.sublist(0, i);
    }
    if (common.isEmpty) return null;

    // A lone file child contributes its own filename as the last segment;
    // the directory that was scanned is its parent.
    final allFiles = children.every((c) => c.isFile);
    if (allFiles && common.length == segments.first.length) {
      common = common.sublist(0, common.length - 1);
      if (common.isEmpty) return null;
    }

    // Empty segments were dropped above to compare segment-by-segment, which
    // costs an absolute path its leading slash — and `listDirectory` needs it:
    // "storage/emulated/0/Movies" is not the same directory as
    // "/storage/emulated/0/Movies".
    final absolute = (children.first.isFile
            ? children.first.videoPath ?? children.first.path
            : children.first.path)
        .startsWith('/');
    final path = common.join('/');
    final name = common.last;
    return LibraryFolder(
      id: parentId,
      // `tree:<bookmarkId>` has no display name of its own — the scan root is
      // then unnamed, which only matters for prefixing a bare "Season 01"
      // child, and such a root is never trusted with removals anyway.
      name: name.startsWith('tree:') && common.length == 1 ? '' : name,
      path: absolute ? '/$path' : path,
      addedAt: DateTime.now(),
      source: LibraryFolderSource.files,
    );
  }
}

/// Counts for logging and the refresh summary. [skippedRoots] holds roots that
/// could not be rescanned at all (no usable seed, or the scan threw).
class LocalRescanResult {
  const LocalRescanResult({
    this.rootsScanned = 0,
    this.added = 0,
    this.removed = 0,
    this.updated = 0,
    this.skippedRoots = const [],
  });

  final int rootsScanned;
  final int added;
  final int removed;
  final int updated;
  final List<String> skippedRoots;

  int get changed => added + removed + updated;

  @override
  String toString() => 'LocalRescanResult(roots: $rootsScanned, '
      'added: $added, removed: $removed, updated: $updated, '
      'skipped: ${skippedRoots.length})';
}