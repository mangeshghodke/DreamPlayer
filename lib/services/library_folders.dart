import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'continue_watching.dart' show StoreChangeNotifier;

/// Where a library folder's contents are listed from.
enum LibraryFolderSource {
  /// On-device storage (SAF tree bookmark / absolute path / iOS folder
  /// bookmark) listed through the native file browser.
  files,

  /// A Jellyfin / Emby folder, listed through the server API.
  jellyfin,

  /// SMB / LAN share folder (jcifs-ng on Android), listed via [SmbClient].
  smb,

  /// WebDAV folder, listed via [WebDavClient].
  webdav,

  /// FTP / SFTP folder, listed via [FtpClient].
  ftp,

  /// UPnP / DLNA container, listed via [UpnpClient].
  upnp,
}

/// A folder the user explicitly chose to add to the library (e.g. a TV show
/// folder). Reference-only: videos are never imported — they stay in place and
/// are listed/played through the folder's SAF tree (`tree:<id>`), absolute
/// path, or (for [LibraryFolderSource.jellyfin]) the Jellyfin API. This is the
/// only thing the library shows: nothing is auto-scanned.
class LibraryFolder {
  const LibraryFolder({
    required this.id,
    required this.name,
    required this.path,
    required this.addedAt,
    this.source = LibraryFolderSource.files,
    this.jellyfinServerUrl,
    this.jellyfinItemId,
    this.networkServerId,
    this.networkShare,
    this.networkPath,
    this.networkLabel,
    this.yearHint,
    this.isFile = false,
    this.parentId,
    this.videoPath,
    this.videoUri,
    this.videoSizeBytes,
  });

  /// Bookmark id from the folder picker (`FileEntry.bookmarkId`), or a
  /// source-specific id (e.g. `jellyfin_<host>_<item>` / `smb_<id>_<share>`) .
  final String id;

  /// Display name of the folder (also the TMDB search query).
  final String name;

  /// `tree:<id>` for SAF bookmarks, an absolute path, or synthetic ids for
  /// network sources (`smb:<server>/<share>/<path>`, `webdav:<id>/<path>`,
  /// `ftp:<id>/<path>`, `upnp:<device>/<id>`).
  final String path;
  final DateTime addedAt;

  /// Where the folder's contents are listed from.
  final LibraryFolderSource source;

  /// Normalized base URL of the Jellyfin server (matched against saved
  /// servers by URL — the token is never stored here). Jellyfin only.
  final String? jellyfinServerUrl;

  /// Jellyfin folder/series id whose children are listed. Jellyfin only.
  final String? jellyfinItemId;

  /// Network share identifiers — SMB/WebDAV/FTP/UPnP. Only the fields
  /// relevant to [source] are set; the rest are null.
  final String? networkServerId;
  final String? networkShare;
  final String? networkPath;
  final String? networkLabel;

  /// Best-effort release year for the TMDB search, derived from the files
  /// inside the folder when the folder name itself carries no year (e.g. a
  /// folder named `Kakegurui Twin-1080p BD` whose episodes say `(2021)`).
  /// Lets `TmdService.resolveFolder` disambiguate same-titled entries that
  /// differ only by year. Null when unknown.
  final int? yearHint;

  /// When true, this entry represents a standalone video file (not a
  /// directory). Expanded by the auto-expand feature from a parent folder.
  final bool isFile;

  /// Groups expanded children — all entries with the same [parentId] were
  /// expanded from one parent folder. Used by "Remove from library" to delete
  /// the whole batch. Null for non-expanded entries.
  final String? parentId;

  /// Absolute path for file entries (for opening in the player).
  final String? videoPath;

  /// Content/document URI for file entries (e.g. `content://` SAF URIs).
  final String? videoUri;

  /// File size in bytes for display on the card.
  final int? videoSizeBytes;

  bool get isJellyfin => source == LibraryFolderSource.jellyfin;
  bool get isNetwork => source != LibraryFolderSource.files;

  /// Stable identity for TMDB metadata (`folder:<id>` in TmdStore) — the
  /// `folder:` prefix keeps it clear of per-video identity keys.
  /// Metadata identity for this entry.
  ///
  /// A FILE entry's identity is its canonical resume key — the very string
  /// [NetworkVideoResolver] puts on the VideoItem it resolves from `path`. That
  /// makes every surface that shows the file agree on a single slot: the home
  /// card, the browser's details page, and Continue Watching.
  ///
  /// It used to be `folder:<id>` for both kinds, which gave one film two or
  /// three separate slots: a poster picked from the SMB browser never reached the
  /// home card, and picking it on the home card never reached Continue Watching.
  ///
  /// A real FOLDER keeps `folder:<id>` — a folder has no resume key, its id is
  /// stable across scans, and a folder card stands for the whole folder rather
  /// than any one file.
  String get metadataKey => isFile ? path : 'folder:$id';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'addedAtMs': addedAt.millisecondsSinceEpoch,
        'source': source.name,
        'jellyfinServerUrl': jellyfinServerUrl,
        'jellyfinItemId': jellyfinItemId,
        'networkServerId': networkServerId,
        'networkShare': networkShare,
        'networkPath': networkPath,
        'networkLabel': networkLabel,
        'yearHint': yearHint,
        if (isFile) 'isFile': true,
        if (parentId != null) 'parentId': parentId,
        if (videoPath != null) 'videoPath': videoPath,
        if (videoUri != null) 'videoUri': videoUri,
        if (videoSizeBytes != null) 'videoSizeBytes': videoSizeBytes,
      };

  factory LibraryFolder.fromJson(Map<String, dynamic> json) {
    final source = switch (json['source'] as String?) {
      'jellyfin' => LibraryFolderSource.jellyfin,
      'smb' => LibraryFolderSource.smb,
      'webdav' => LibraryFolderSource.webdav,
      'ftp' => LibraryFolderSource.ftp,
      'upnp' => LibraryFolderSource.upnp,
      _ => LibraryFolderSource.files,
    };
    return LibraryFolder(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      addedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['addedAtMs'] as num?)?.toInt() ?? 0,
      ),
      source: source,
      jellyfinServerUrl: json['jellyfinServerUrl'] as String?,
      jellyfinItemId: json['jellyfinItemId'] as String?,
      networkServerId: json['networkServerId'] as String?,
      networkShare: json['networkShare'] as String?,
      networkPath: json['networkPath'] as String?,
      networkLabel: json['networkLabel'] as String?,
      yearHint: (json['yearHint'] as num?)?.toInt(),
      isFile: json['isFile'] as bool? ?? false,
      parentId: json['parentId'] as String?,
      videoPath: json['videoPath'] as String?,
      videoUri: json['videoUri'] as String?,
      videoSizeBytes: (json['videoSizeBytes'] as num?)?.toInt(),
    );
  }

  /// Copy with overrides. A rescan must be able to keep an entry's `id` and
  /// `addedAt` while refreshing everything else — `metadataKey` is
  /// `folder:<id>` for a folder, so a regenerated id silently orphans that
  /// folder's cached TMDB metadata and artwork overrides.
  LibraryFolder copyWith({
    String? id,
    String? name,
    String? path,
    DateTime? addedAt,
    LibraryFolderSource? source,
    String? jellyfinServerUrl,
    String? jellyfinItemId,
    String? networkServerId,
    String? networkShare,
    String? networkPath,
    String? networkLabel,
    int? yearHint,
    bool? isFile,
    String? parentId,
    String? videoPath,
    String? videoUri,
    int? videoSizeBytes,
  }) {
    return LibraryFolder(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      addedAt: addedAt ?? this.addedAt,
      source: source ?? this.source,
      jellyfinServerUrl: jellyfinServerUrl ?? this.jellyfinServerUrl,
      jellyfinItemId: jellyfinItemId ?? this.jellyfinItemId,
      networkServerId: networkServerId ?? this.networkServerId,
      networkShare: networkShare ?? this.networkShare,
      networkPath: networkPath ?? this.networkPath,
      networkLabel: networkLabel ?? this.networkLabel,
      yearHint: yearHint ?? this.yearHint,
      isFile: isFile ?? this.isFile,
      parentId: parentId ?? this.parentId,
      videoPath: videoPath ?? this.videoPath,
      videoUri: videoUri ?? this.videoUri,
      videoSizeBytes: videoSizeBytes ?? this.videoSizeBytes,
    );
  }

  /// Whether two entries describe the same thing on disk, ignoring the fields
  /// that are bookkeeping rather than content ([id], [addedAt]).
  ///
  /// Used by the rescan to tell "this folder is unchanged" from "this folder
  /// was renamed or resized", so only real changes are written back.
  bool sameContentAs(LibraryFolder other) =>
      other.name == name &&
      other.path == path &&
      other.isFile == isFile &&
      other.videoPath == videoPath &&
      other.videoSizeBytes == videoSizeBytes &&
      other.source == source &&
      other.parentId == parentId;
}

/// Persists the user's library folders (shared_preferences JSON), most recently
/// added first.
class LibraryFoldersStore {
  LibraryFoldersStore._();

  static const String _prefsKey = 'dreamplayer.libraryFolders';

  /// Fires whenever the folder list changes, so the home screen reloads.
  static final StoreChangeNotifier changes = StoreChangeNotifier();

  static Future<List<LibraryFolder>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return <LibraryFolder>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => LibraryFolder.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> add(LibraryFolder folder) async {
    final all = await load();
    all.removeWhere((f) => f.id == folder.id);
    all.insert(0, folder);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((f) => f.toJson()).toList()),
    );
    changes.notify();
  }

  static Future<void> remove(String id) async {
    final all = await load();
    all.removeWhere((f) => f.id == id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((f) => f.toJson()).toList()),
    );
    // Removing the last card of an expanded folder forgets its scan root too.
    // Deliberately NOT done by [applyDiff]: there "no children left" is
    // indistinguishable from "the user emptied the folder", and dropping the
    // seed would make files added later undiscoverable. Here the removal is an
    // explicit user action, so the intent is known.
    await _pruneUnreferencedRoots(all);
    changes.notify();
  }

  /// Adds multiple folders in a single prefs write. Deduplicates by [id]
  /// (existing entries with the same id are replaced) AND by
  /// `(source, networkPath)` (old manually-bookmarked entries for the same
  /// location are replaced by the new scanner entries). Most-recently-added
  /// first — the list is reversed so the oldest of the batch ends up on top.
  static Future<void> bulkAdd(List<LibraryFolder> folders) async {
    if (folders.isEmpty) return;
    final all = await load();
    // Remove old entries that match new entries by id OR by (source, networkPath).
    for (final folder in folders) {
      all.removeWhere((f) =>
          f.id == folder.id ||
          (f.source == folder.source &&
              f.networkPath != null &&
              f.networkPath == folder.networkPath));
    }
    all.insertAll(0, folders);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((f) => f.toJson()).toList()),
    );
    changes.notify();
  }

  /// Removes all entries that share the same [parentId] (expanded children
  /// of one parent folder). If [parentId] is null, this is a no-op.
  static Future<void> removeByParentId(String parentId) async {
    final all = await load();
    all.removeWhere((f) => f.parentId == parentId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((f) => f.toJson()).toList()),
    );
    changes.notify();
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    await prefs.remove(_scanRootsKey);
    changes.notify();
  }

  /// Applies a rescan diff in ONE prefs write: [upserts] replace entries with
  /// the same id **in place** (so a refresh never reshuffles the grid),
  /// [upserts] with an unknown id are appended, and [removeIds] are dropped.
  ///
  /// One write and one [changes] notify on purpose — calling [bulkAdd] and
  /// [remove] per entry would make the home grid rebuild once per folder, and
  /// `bulkAdd`'s insert-at-0 would float every rescanned folder to the top.
  static Future<void> applyDiff({
    required List<LibraryFolder> upserts,
    required List<String> removeIds,
  }) async {
    if (upserts.isEmpty && removeIds.isEmpty) return;
    final all = await load();
    if (removeIds.isNotEmpty) {
      final gone = removeIds.toSet();
      all.removeWhere((f) => gone.contains(f.id));
    }
    for (final folder in upserts) {
      final index = all.indexWhere((f) => f.id == folder.id);
      if (index >= 0) {
        all[index] = folder;
      } else {
        all.add(folder);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((f) => f.toJson()).toList()),
    );
    changes.notify();
  }

  /// Whether the auto-expand-folders feature is enabled (default `true`).
  static Future<bool> isAutoExpandEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('dreamplayer.autoExpandFolders') ?? true;
  }

  // ── Scan roots ────────────────────────────────────────────────────────
  //
  // When a folder is bookmarked and expanded, the parent is REMOVED from the
  // library and only its children are kept (each tagged `parentId`). That
  // left no record of what had been scanned, so a rescan had no seed — the
  // grid could only ever show the snapshot taken at bookmark time (issue #39).
  // These persist the root so a later rescan knows where to look.

  static const String _scanRootsKey = 'dreamplayer.libraryScanRoots';

  /// Scan roots keyed by [LibraryFolder.id] (which is also the children's
  /// `parentId`).
  static Future<Map<String, LibraryFolder>> loadScanRoots() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_scanRootsKey);
    if (raw == null || raw.isEmpty) return <String, LibraryFolder>{};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map(
        (key, value) => MapEntry(
          key,
          LibraryFolder.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (_) {
      return <String, LibraryFolder>{};
    }
  }

  static Future<void> saveScanRoot(LibraryFolder root) async {
    final roots = await loadScanRoots();
    roots[root.id] = root;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _scanRootsKey,
      jsonEncode(roots.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  static Future<void> removeScanRoot(String id) async {
    final roots = await loadScanRoots();
    if (roots.remove(id) == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _scanRootsKey,
      jsonEncode(roots.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  /// Drops scan roots whose id no longer appears as a `parentId` in the
  /// library, so the record cannot outlive the entries it describes.
  static Future<void> pruneScanRoots() async {
    await _pruneUnreferencedRoots(await load());
  }

  static Future<void> _pruneUnreferencedRoots(
    List<LibraryFolder> remaining,
  ) async {
    final live = {for (final f in remaining) if (f.parentId != null) f.parentId!};
    final roots = await loadScanRoots();
    final stale = roots.keys.where((id) => !live.contains(id)).toList();
    if (stale.isEmpty) return;
    for (final id in stale) {
      roots.remove(id);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _scanRootsKey,
      jsonEncode(roots.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }
}
