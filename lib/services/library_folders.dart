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

  bool get isJellyfin => source == LibraryFolderSource.jellyfin;
  bool get isNetwork => source != LibraryFolderSource.files;

  /// Stable identity for TMDB metadata (`folder:<id>` in TmdStore) — the
  /// `folder:` prefix keeps it clear of per-video identity keys.
  String get metadataKey => 'folder:$id';

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
    );
  }
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
    changes.notify();
  }
}
