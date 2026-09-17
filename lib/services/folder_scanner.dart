import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'file_browser.dart';
import 'ftp_client.dart';
import 'jellyfin_client.dart';
import 'library_folders.dart';
import 'smb_client.dart';
import 'upnp_client.dart';
import 'webdav_client.dart';

/// Deep recursive folder scanner. Traverses a library folder's subdirectories
/// up to [maxDepth] levels and returns a flat list of [LibraryFolder] entries
/// for every video file and subfolder discovered.
///
/// Used by the add-folder / bookmark flows to populate the home grid with
/// expanded poster cards (like the existing 1-level auto-expand, but deeper).
///
/// The scanner is **cancellable** — set [cancel] to `true` from any isolate
/// to abort the scan gracefully (entries discovered so far are still returned).
class FolderScanner {
  FolderScanner({int? maxDepth}) : maxDepth = maxDepth ?? _defaultScanDepth();

  /// Maximum recursion depth. 1 = immediate children only (legacy behavior),
  /// 5 = five levels deep (the default).
  final int maxDepth;

  /// Returns the user-configured scan depth from SharedPreferences.
  /// Falls back to 5 (the default).
  static int _defaultScanDepth() {
    // Synchronous fallback — the caller should use savedScanDepth() for
    // the actual user-configured value.
    return 5;
  }

  /// Reads the scan depth from SharedPreferences (async). Preferred over
  /// the constructor default for bookmark flows that can await.
  static Future<int> savedScanDepth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt('dreamplayer.scanDepth') ?? 5;
    } catch (_) {
      return 5;
    }
  }

  /// Set to `true` to abort the scan. The scanner stops recursing and returns
  /// whatever entries it has collected so far.
  bool cancel = false;

  /// Number of directories scanned so far (for progress reporting).
  int scannedDirs = 0;

  /// Scans [folder] recursively and returns all discovered subfolders and
  /// video files as a flat list of [LibraryFolder] entries ready for
  /// [LibraryFoldersStore.bulkAdd].
  ///
  /// Each entry has:
  /// - `parentId` = [folder.id] (so "Remove from library" deletes the batch)
  /// - `id` = `${folder.id}_${relativePath.hashCode}` (unique per entry)
  /// - `name` = file or directory name
  /// - `path` / `networkPath` = full path from the root
  /// - `isFile` = `true` for video files, `false` for directories
  Future<List<LibraryFolder>> scan(LibraryFolder folder) async {
    cancel = false;
    scannedDirs = 0;
    final results = <LibraryFolder>[];
    await _scanRecursive(folder, folder, 0, results);
    return results;
  }

  Future<void> _scanRecursive(
    LibraryFolder root,
    LibraryFolder current,
    int depth,
    List<LibraryFolder> results,
  ) async {
    if (cancel || depth >= maxDepth) return;

    scannedDirs++;

    // List children of the current directory.
    final List<Object> children;
    try {
      children = await _listDirectory(current);
    } catch (_) {
      // Network source unreachable or permission denied — skip, don't kill scan.
      return;
    }

    // Check if any direct child is a video file or subdirectory.
    // Leaf folders that directly contain videos (no subdirs) become a
    // single library entry. Pure containers and mixed folders (subdirs +
    // loose files like TV Shows/lanterns.mkv) are expanded instead.
    final isJellyfinTree = root.source == LibraryFolderSource.jellyfin;
    final hasVideoFiles = children.any(
      (c) => !_isDirectory(c) && (isJellyfinTree ? true : _isVideoFile(_nameOf(c))),
    );
    final hasSubdirs = children.any(_isDirectory);

    // Only add this directory as a library entry if it is a leaf folder
    // (has videos but no subdirs). Mixed/container folders are expanded
    // into their children instead — otherwise a loose file like
    // TV Shows/lanterns s01e05.mkv would be hidden behind the parent card.
    // The root itself (depth 0) is never added.
    if (depth > 0 && hasVideoFiles && !hasSubdirs) {
      results.add(current);
    }

    // Process children: recurse into subdirectories, and collect loose
    // video files as standalone entries (at root, or inside a mixed
    // container where the parent would otherwise hide them).
    for (final child in children) {
      if (cancel) return;

      final name = _nameOf(child);
      if (name.isEmpty) continue;

      final isDir = _isDirectory(child);

      if (isDir) {
        final childRelativePath = _relativePath(current, root);
        var childId =
            '${root.id}_${childRelativePath.isEmpty ? name : "$childRelativePath/$name".hashCode}';
        // Jellyfin: item ids are stable server ids — use them directly so two
        // seasons/episodes with the same name never collide.
        if (isJellyfinTree) {
          final jid = _jellyfinItemId(child);
          if (jid.isNotEmpty) childId = '${root.id}_$jid';
        }

        // Build the child folder entry — it will be added inside its own
        // _scanRecursive call if it is a leaf.
        final childFolder = _buildFolderEntry(
          root: current,
          name: name,
          child: child,
          parentId: root.id,
          id: childId,
        );
        await _scanRecursive(root, childFolder, depth + 1, results);
      } else if ((isJellyfinTree ? !_isDirectory(child) : _isVideoFile(name)) &&
          (depth == 0 || (depth > 0 && hasSubdirs))) {
        // Expand loose video files: at root level always, and inside
        // mixed containers (e.g. TV Shows/ containing both subfolders and
        // lanterns s01e05.mkv) so the file isn't hidden.
        final childRelativePath = _relativePath(current, root);
        var childId =
            '${root.id}_${childRelativePath.isEmpty ? name : "$childRelativePath/$name".hashCode}';
        if (isJellyfinTree) {
          final jid = _jellyfinItemId(child);
          if (jid.isNotEmpty) childId = '${root.id}_$jid';
        }
        final fileEntry = _buildFileEntry(
          root: current,
          name: name,
          child: child,
          parentId: root.id,
          id: childId,
        );
        results.add(fileEntry);
      }
    }
  }

  // ── Directory listing per source ──────────────────────────────────────

  Future<List<Object>> _listDirectory(LibraryFolder folder) async {
    switch (folder.source) {
      case LibraryFolderSource.files:
        return _listLocal(folder);
      case LibraryFolderSource.smb:
        return _listSmb(folder);
      case LibraryFolderSource.webdav:
        return _listWebDav(folder);
      case LibraryFolderSource.ftp:
        return _listFtp(folder);
      case LibraryFolderSource.upnp:
        return _listUpnp(folder);
      case LibraryFolderSource.jellyfin:
        return _listJellyfin(folder);
    }
  }

  Future<List<Object>> _listLocal(LibraryFolder folder) async {
    final entries = await FileBrowserService.instance
        .listDirectory(folder.path)
        .timeout(const Duration(seconds: 15));
    return entries;
  }

  Future<List<Object>> _listSmb(LibraryFolder folder) async {
    final entries = await SmbClient.instance
        .listDirectory(
          folder.networkServerId ?? '',
          folder.networkShare ?? '',
          folder.networkPath ?? '',
        )
        .timeout(const Duration(seconds: 15));
    return entries;
  }

  Future<List<Object>> _listWebDav(LibraryFolder folder) async {
    final entries = await WebDavClient.instance
        .listDirectory(folder.networkServerId ?? '', folder.networkPath ?? '')
        .timeout(const Duration(seconds: 15));
    return entries;
  }

  Future<List<Object>> _listFtp(LibraryFolder folder) async {
    final entries = await FtpClient.instance
        .listDirectory(folder.networkServerId ?? '', folder.networkPath ?? '')
        .timeout(const Duration(seconds: 15));
    return entries;
  }

  Future<List<Object>> _listUpnp(LibraryFolder folder) async {
    final entries = await UpnpClient.instance
        .browse(folder.networkServerId ?? '', folder.networkPath ?? '')
        .timeout(const Duration(seconds: 15));
    return entries;
  }

  Future<List<Object>> _listJellyfin(LibraryFolder folder) async {
    final client = JellyfinClient();
    final server =
        await client.serverForUrl(folder.jellyfinServerUrl ?? '');
    if (server == null || !server.isAuthenticated) return const [];
    final items = await client
        .getItems(server, folder.jellyfinItemId ?? '')
        .timeout(const Duration(seconds: 15));
    // Jellyfin items are JellyfinItem objects — wrap as-is; _nameOf/_isDirectory handle them.
    return items;
  }

  // ── Entry builders ────────────────────────────────────────────────────

  LibraryFolder _buildFolderEntry({
    required LibraryFolder root,
    required String name,
    required Object child,
    required String parentId,
    required String id,
  }) {
    // For season subfolders, prefix the show name and use a non-strippable
    // season tag (Season02 without space) so each season stays a separate
    // card on Home — auto-grouping strips " Season 02"/"S02" but not
    // "Season02", so "House Season02" and "House Season03" keep distinct
    // baseNames and the user can manually group them.
    var effectiveName = name;
    final seasonNum = _seasonNumberFromName(name) ??
        (child is JellyfinItem && child.type == 'Season' ? child.indexNumber : null);
    if (seasonNum != null && seasonNum > 0 && root.name.isNotEmpty) {
      // Only prefix when the season name itself doesn't already contain the
      // show name (e.g. "Season 2" under "House" → "House Season02").
      final lower = name.toLowerCase();
      final rootLower = root.name.toLowerCase();
      if (!lower.contains(rootLower)) {
        effectiveName = '${root.name} Season${seasonNum.toString().padLeft(2, '0')}';
      } else if (name.contains(RegExp(r'Season\s+\d+', caseSensitive: false))) {
        // Already prefixed but with a strippable space — make it non-strippable.
        effectiveName = name.replaceAll(
          RegExp(r'Season\s+(\d+)', caseSensitive: false),
          'Season${seasonNum.toString().padLeft(2, '0')}',
        );
      }
    }
    switch (root.source) {
      case LibraryFolderSource.files:
        final entry = child as FileEntry;
        return LibraryFolder(
          id: id,
          name: effectiveName,
          path: entry.path,
          addedAt: DateTime.now(),
          source: LibraryFolderSource.files,
          parentId: parentId,
        );
      case LibraryFolderSource.smb:
        final childPath = _networkChildPath(root, name);
        return LibraryFolder(
          id: id,
          name: effectiveName,
          path: 'smb:${root.networkServerId}/$childPath',
          addedAt: DateTime.now(),
          source: LibraryFolderSource.smb,
          networkServerId: root.networkServerId,
          networkShare: root.networkShare,
          networkPath: childPath,
          networkLabel: root.networkLabel,
          parentId: parentId,
        );
      case LibraryFolderSource.webdav:
        final childPath = _networkChildPath(root, name);
        return LibraryFolder(
          id: id,
          name: effectiveName,
          path: 'webdav:${root.networkServerId}$childPath',
          addedAt: DateTime.now(),
          source: LibraryFolderSource.webdav,
          networkServerId: root.networkServerId,
          networkPath: childPath,
          networkLabel: root.networkLabel,
          parentId: parentId,
        );
      case LibraryFolderSource.ftp:
        final childPath = _networkChildPath(root, name);
        return LibraryFolder(
          id: id,
          name: effectiveName,
          path: 'ftp:${root.networkServerId}$childPath',
          addedAt: DateTime.now(),
          source: LibraryFolderSource.ftp,
          networkServerId: root.networkServerId,
          networkPath: childPath,
          networkLabel: root.networkLabel,
          parentId: parentId,
        );
      case LibraryFolderSource.upnp:
        final childPath = _networkChildPath(root, name);
        return LibraryFolder(
          id: id,
          name: effectiveName,
          path: 'upnp:${root.networkServerId}$childPath',
          addedAt: DateTime.now(),
          source: LibraryFolderSource.upnp,
          networkServerId: root.networkServerId,
          networkPath: childPath,
          networkLabel: root.networkLabel,
          parentId: parentId,
        );
      case LibraryFolderSource.jellyfin:
        // For Jellyfin, we need the item ID from the child object.
        final itemId = _jellyfinItemId(child);
        return LibraryFolder(
          id: id,
          name: effectiveName,
          path: 'jellyfin:${root.jellyfinServerUrl}_$itemId',
          addedAt: DateTime.now(),
          source: LibraryFolderSource.jellyfin,
          jellyfinServerUrl: root.jellyfinServerUrl,
          jellyfinItemId: itemId,
          parentId: parentId,
        );
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  /// Builds the network path for a child relative to the root folder.
  String _networkChildPath(LibraryFolder root, String childName) {
    final rootPath = root.networkPath ?? '';
    return rootPath.isEmpty ? childName : '$rootPath/$childName';
  }

  /// Extracts the Jellyfin item ID from a child object.
  String _jellyfinItemId(Object child) {
    if (child is JellyfinItem) return child.id;
    return '';
  }

  /// Parses a season number from a folder name like "Season 2", "Season02",
  /// "S02", "Season 02". Returns null when no season tag is found.
  int? _seasonNumberFromName(String name) {
    final m1 = RegExp(r'Season\s*0*(\d{1,2})', caseSensitive: false).firstMatch(name);
    if (m1 != null) return int.tryParse(m1.group(1)!);
    final m2 = RegExp(r'\bS0*(\d{1,2})\b', caseSensitive: false).firstMatch(name);
    if (m2 != null) return int.tryParse(m2.group(1)!);
    return null;
  }

  String _nameOf(Object entry) {
    final raw = switch (entry) {
      FileEntry e => e.name,
      SmbEntry e => e.name,
      WebDavEntry e => e.name,
      FtpEntry e => e.name,
      UpnpEntry e => e.name,
      JellyfinItem e => e.name,
      _ => null,
    };
    if (raw == null) return '';
    // Strip trailing slashes from SMB/network directory entries.
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  bool _isDirectory(Object entry) {
    if (entry is FileEntry) return entry.isDirectory;
    if (entry is SmbEntry) return entry.isDirectory;
    if (entry is WebDavEntry) return entry.isDirectory;
    if (entry is FtpEntry) return entry.isDirectory;
    if (entry is UpnpEntry) return entry.isDirectory;
    if (entry is JellyfinItem) return entry.isFolder;
    return false;
  }

  /// Relative path of [current] from [root] (for unique ID generation).
  String _relativePath(LibraryFolder current, LibraryFolder root) {
    if (current.path == root.path) return '';
    // For local paths, strip the root prefix.
    if (current.source == LibraryFolderSource.files) {
      final rootPath = root.path;
      if (current.path.startsWith(rootPath)) {
        return current.path.substring(rootPath.length).replaceFirst(RegExp(r'^/'), '');
      }
    }
    // For network paths, use the networkPath relative to root's networkPath.
    final rootNet = root.networkPath ?? '';
    final currentNet = current.networkPath ?? '';
    if (currentNet.startsWith(rootNet)) {
      return currentNet.substring(rootNet.length).replaceFirst(RegExp(r'^/'), '');
    }
    // Fallback: use the name.
    return current.name;
  }

  LibraryFolder _buildFileEntry({
    required LibraryFolder root,
    required String name,
    required Object child,
    required String parentId,
    required String id,
  }) {
    final info = _fileInfo(child);
    switch (root.source) {
      case LibraryFolderSource.files:
        final entry = child as FileEntry;
        return LibraryFolder(
          id: id,
          name: name,
          path: entry.path,
          addedAt: DateTime.now(),
          source: LibraryFolderSource.files,
          parentId: parentId,
          isFile: true,
          videoPath: entry.path,
          videoSizeBytes: entry.size > 0 ? entry.size : null,
        );
      case LibraryFolderSource.smb:
        final childPath = _networkChildPath(root, name);
        return LibraryFolder(
          id: id,
          name: name,
          path: 'smb:${root.networkServerId}/$childPath',
          addedAt: DateTime.now(),
          source: LibraryFolderSource.smb,
          networkServerId: root.networkServerId,
          networkShare: root.networkShare,
          networkPath: childPath,
          networkLabel: root.networkLabel,
          parentId: parentId,
          isFile: true,
          videoUri: 'smb://${root.networkServerId}/${root.networkShare}/$childPath',
          videoSizeBytes: info.size,
        );
      case LibraryFolderSource.webdav:
        final childPath = _networkChildPath(root, name);
        return LibraryFolder(
          id: id,
          name: name,
          path: 'webdav:${root.networkServerId}$childPath',
          addedAt: DateTime.now(),
          source: LibraryFolderSource.webdav,
          networkServerId: root.networkServerId,
          networkPath: childPath,
          networkLabel: root.networkLabel,
          parentId: parentId,
          isFile: true,
          videoSizeBytes: info.size,
        );
      case LibraryFolderSource.ftp:
        final childPath = _networkChildPath(root, name);
        return LibraryFolder(
          id: id,
          name: name,
          path: 'ftp:${root.networkServerId}$childPath',
          addedAt: DateTime.now(),
          source: LibraryFolderSource.ftp,
          networkServerId: root.networkServerId,
          networkPath: childPath,
          networkLabel: root.networkLabel,
          parentId: parentId,
          isFile: true,
          videoSizeBytes: info.size,
        );
      case LibraryFolderSource.upnp:
        final childPath = _networkChildPath(root, name);
        return LibraryFolder(
          id: id,
          name: name,
          path: 'upnp:${root.networkServerId}$childPath',
          addedAt: DateTime.now(),
          source: LibraryFolderSource.upnp,
          networkServerId: root.networkServerId,
          networkPath: childPath,
          networkLabel: root.networkLabel,
          parentId: parentId,
          isFile: true,
          videoSizeBytes: info.size,
        );
      case LibraryFolderSource.jellyfin:
        final itemId = _jellyfinItemId(child);
        return LibraryFolder(
          id: id,
          name: name,
          path: 'jellyfin:${root.jellyfinServerUrl}_$itemId',
          addedAt: DateTime.now(),
          source: LibraryFolderSource.jellyfin,
          jellyfinServerUrl: root.jellyfinServerUrl,
          jellyfinItemId: itemId,
          parentId: parentId,
          isFile: true,
          videoSizeBytes: info.size,
        );
    }
  }

  /// Extracts file info (size) from a child object.
  ({int size}) _fileInfo(Object child) {
    if (child is FileEntry) return (size: child.size);
    if (child is WebDavEntry) return (size: child.size);
    if (child is FtpEntry) return (size: child.size);
    if (child is UpnpEntry) return (size: 0);
    if (child is JellyfinItem) return (size: 0);
    if (child is SmbEntry) return (size: child.size);
    return (size: 0);
  }

  /// Quick check: does the filename look like a video file?
  static bool _isVideoFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.mkv') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.m2ts') ||
        lower.endsWith('.wmv') ||
        lower.endsWith('.flv') ||
        lower.endsWith('.ogv') ||
        lower.endsWith('.rmvb') ||
        lower.endsWith('.mpg') ||
        lower.endsWith('.mpeg') ||
        lower.endsWith('.vob') ||
        lower.endsWith('.3gp');
  }
}
