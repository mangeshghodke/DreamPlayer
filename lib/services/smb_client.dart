import 'package:flutter/services.dart';

import '../utils/server_failover.dart';
import 'server_alt_store.dart';

/// A saved SMB server (see `SMBClient.swift` / `SMBClient.kt`). Passwords
/// never cross to Dart — only `hasPassword` (native sides keep them in
/// Keychain / Keystore).
class SmbServer {
  const SmbServer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.domain,
    required this.anonymous,
    required this.hasPassword,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String domain;
  final bool anonymous;
  final bool hasPassword;

  String get credentialLabel =>
      anonymous || username.isEmpty ? 'Guest' : username;

  String get subtitle {
    final auth = domain.isNotEmpty ? '$domain\\$credentialLabel' : credentialLabel;
    return '$host:$port · $auth';
  }

  SmbServer copyWith({String? host, int? port}) {
    return SmbServer(
      id: id,
      name: name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username,
      domain: domain,
      anonymous: anonymous,
      hasPassword: hasPassword,
    );
  }

  factory SmbServer.fromMap(Map<dynamic, dynamic> m) {
    return SmbServer(
      id: (m['id'] as String?) ?? '',
      name: (m['name'] as String?) ?? '',
      host: (m['host'] as String?) ?? '',
      port: (m['port'] as num?)?.toInt() ?? 445,
      username: (m['username'] as String?) ?? '',
      domain: (m['domain'] as String?) ?? '',
      anonymous: (m['anonymous'] as bool?) ?? false,
      hasPassword: (m['hasPassword'] as bool?) ?? false,
    );
  }
}

/// A share or folder/file entry returned by the native SMB browser.
class SmbEntry {
  const SmbEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
    this.subtitlePath,
    this.subtitlePaths,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final int modified;

  /// For video entries: the relative path of an auto-paired subtitle file
  /// (`.srt`/`.ass`/...) sitting next to the video in the same folder.
  final String? subtitlePath;

  /// All matching subtitle files for this video (e.g. `.srt` + `.eng.srt`).
  final List<String>? subtitlePaths;

  factory SmbEntry.fromMap(Map<dynamic, dynamic> m) {
    final rawPaths = m['subtitlePaths'] as List?;
    return SmbEntry(
      name: (m['name'] as String?) ?? '',
      path: (m['path'] as String?) ?? '',
      isDirectory: (m['isDirectory'] as bool?) ?? false,
      size: (m['size'] as num?)?.toInt() ?? 0,
      modified: (m['modified'] as num?)?.toInt() ?? 0,
      subtitlePath: m['subtitlePath'] as String?,
      subtitlePaths: rawPaths?.whereType<String>().toList(),
    );
  }
}

/// A host found on the LAN by the native subnet scan.
class SmbDiscovered {
  const SmbDiscovered({
    required this.host,
    required this.hostname,
    this.dialect,
    this.serverGuid,
  });

  final String host;
  final String hostname;

  /// Negotiated SMB dialect as reported by the server, e.g. `SMB 3.1.1`.
  ///
  /// Only present once the native side completed a real SMB negotiate
  /// (libsmb2 against IPC$), which is also what qualifies a host to appear here
  /// at all — a bare TCP connect to 445 no longer adds a server. Android's
  /// jcifs-ng sweep has no equivalent handshake, so it stays null there.
  final String? dialect;

  /// The server's SMB GUID — a stable identity for a host whose IP may change.
  final String? serverGuid;

  factory SmbDiscovered.fromMap(Map<dynamic, dynamic> m) {
    return SmbDiscovered(
      host: (m['host'] as String?) ?? '',
      hostname: (m['hostname'] as String?) ?? '',
      dialect: m['dialect'] as String?,
      serverGuid: m['serverGuid'] as String?,
    );
  }
}

/// Result of a quick connection test.
typedef SmbTestResult = ({bool ok, String? error});

/// Wraps the native `dreamplayer/smb` channel (see `SMBClient.swift` /
/// `SMBClient.kt`).
class SmbClient {
  SmbClient._();

  static final SmbClient instance = SmbClient._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/smb');

  Future<List<SmbServer>> listServers() async {
    final result = await _channel.invokeListMethod<dynamic>('listServers');
    if (result == null) return const [];
    return result
        .map((e) => SmbServer.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Saves a server; pass [id] to update an existing one.
  Future<SmbServer> saveServer({
    String? id,
    required String name,
    required String host,
    int port = 445,
    String username = '',
    String password = '',
    String domain = '',
    bool anonymous = false,
  }) async {
    final result = await _channel.invokeMethod<dynamic>('saveServer', {
      if (id != null && id.isNotEmpty) 'id': id,
      'name': name,
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'domain': domain,
      'anonymous': anonymous,
    });
    return SmbServer.fromMap((result as Map<dynamic, dynamic>?) ?? const {});
  }

  Future<void> deleteServer(String id) async {
    await _channel.invokeMethod<void>('deleteServer', {'id': id});
  }

  /// Tests a connection without saving (used by the add/edit dialog).
  Future<SmbTestResult> testConnection({
    required String host,
    int port = 445,
    String username = '',
    String password = '',
    String domain = '',
    bool anonymous = false,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'testConnection',
      {
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'domain': domain,
        'anonymous': anonymous,
      },
    );
    return (
      ok: result?['ok'] == true,
      error: result?['error'] as String?,
    );
  }

  Future<List<SmbEntry>> listShares(String serverId) async {
    final result = await _channel.invokeListMethod<dynamic>('listShares', {
      'id': serverId,
    });
    if (result == null) return const [];
    return result
        .map((e) => SmbEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Remembers a share name for a server (for shares the server won't
  /// enumerate, so unusual names can be added by hand after the auto-probe).
  Future<bool> addShare(String serverId, String shareName) async {
    final result = await _channel.invokeMethod<bool>('addShare', {
      'id': serverId,
      'share': shareName,
    });
    return result ?? false;
  }

  Future<List<SmbEntry>> listDirectory(
    String serverId,
    String share,
    String path,
  ) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectory', {
      'id': serverId,
      'share': share,
      'path': path,
    });
    if (result == null) return const [];
    return result
        .map((e) => SmbEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// True only when the server *answered definitively* that the path is gone
  /// (native maps the SMB NT not-found statuses / libsmb2 ENOENT-ENOTDIR to
  /// the `smb_not_found` code). NEVER true on a network, timeout or auth
  /// failure — callers prune stored entries on this alone, so an offline NAS
  /// must never satisfy it.
  static bool isNotFound(PlatformException e) => e.code == 'smb_not_found';

  /// Existence probe for one share-relative path (file or directory).
  /// Returns `exists: false` on `smb_not_found`; rethrows every other
  /// [PlatformException] (server offline, auth, ...) so the caller can tell
  /// "deleted" apart from "unreachable".
  Future<({bool exists, bool isDirectory})> statPath(
    String serverId,
    String share,
    String path,
  ) async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('statPath', {
        'id': serverId,
        'share': share,
        'path': path,
      });
      return (exists: true, isDirectory: (r?['isDirectory'] as bool?) ?? false);
    } on PlatformException catch (e) {
      if (isNotFound(e)) return (exists: false, isDirectory: false);
      rethrow;
    }
  }

  /// Full directory listing (videos AND sidecar subtitles) without the
  /// video-only filter and without the native subtitle-attachment logic, so
  /// the sidecar service can pair subtitles by name (Nova parity). Mirrors
  /// the FTP `listDirectoryAll` channel method.
  Future<List<SmbEntry>> listDirectoryAll(
    String serverId,
    String share,
    String path,
  ) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectoryAll', {
      'id': serverId,
      'share': share,
      'path': path,
    });
    if (result == null) return const [];
    return result
        .map((e) => SmbEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Opens a file on the share for streaming and returns a playable URL.
  /// iOS serves it via an AetherEngineSMB `SMBConnection` custom source
  /// (`dreamplayersmb://<token>`); each call returns its own URL so a folder
  /// playlist can open every video up-front. Call [closeShare] when the
  /// browsing session ends to tear down the streams and disconnect.
  Future<String> openShare(String serverId, String share, String path) async {
    final result = await _channel.invokeMethod<String>('openShare', {
      'id': serverId,
      'share': share,
      'path': path,
    });
    if (result == null || result.isEmpty) {
      throw PlatformException(code: 'openShare', message: 'Could not open share');
    }
    return result;
  }

  Future<void> closeShare(String serverId) async {
    await _channel.invokeMethod<void>('closeShare', {'id': serverId});
  }

  /// Invalidate the native directory-listing cache for a server (or all servers
  /// when [serverId] is null). Called after server/share changes or on
  /// pull-to-refresh — the listing itself is cached for 60 s on the native
  /// side so re-visiting a folder is instant.
  Future<void> invalidateListingCache({String? serverId}) async {
    await _channel.invokeMethod<void>('invalidateListingCache', {
      'id': ?serverId,
    });
  }

  /// Background size fetch: opens each file at [paths] and calls length()
  /// on the native side. Returns a map of path→size for entries where
  /// size > 0. Called after listDirectory so the UI shows entries immediately
  /// and sizes fill in progressively.
  Future<Map<String, int>> fetchSizes(
      String serverId, String share, List<String> paths) async {
    final result = await _channel.invokeMapMethod<String, int>('fetchSizes', {
      'id': serverId,
      'share': share,
      'paths': paths,
    });
    return result ?? {};
  }

  /// Nova-parity sidecar prefetch: reads a subtitle file's bytes directly off
  /// the share (via the same jcifs-ng machinery as the playback data source).
  /// Returns null when the file doesn't exist / is unreadable, so sidecar
  /// discovery can treat it as "no subtitle".
  Future<Uint8List?> fetchBytes(String serverId, String share, String path,
      {int maxBytes = 50 * 1024 * 1024}) async {
    return _channel.invokeMethod<Uint8List>('fetchBytes', {
      'id': serverId,
      'share': share,
      'path': path,
      'maxBytes': maxBytes,
    });
  }

  /// LAN scan for reachable SMB hosts (native subnet 445 probe + name
  /// resolution). Returns empty when off-Wi-Fi or nothing responds.
  Future<List<SmbDiscovered>> discoverServers() async {
    final result = await _channel.invokeListMethod<dynamic>('discoverServers');
    if (result == null) return const [];
    return result
        .map((e) => SmbDiscovered.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Runs [op] against the saved server; on a channel failure, if an
  /// alternate address is stored for this server, the saved server is
  /// re-pointed at it (password is kept — empty password means "keep stored"
  /// on both platforms) and [op] retried. If the alt also fails, the primary
  /// address is restored and the original error rethrown.
  /// Returns the result plus the *effective* server (re-pointed on failover).
  Future<({T value, SmbServer server})> withAltFailover<T>(
    SmbServer server,
    Future<T> Function() op,
  ) async {
    return runWithAltFailover<({T value, SmbServer server})>(
      primary: () async => (value: await op(), server: server),
      alt: await ServerAltStore.altFor('smb', server.id),
      runAlt: (alt) async {
        final parsed = parseSmbAltAddress(alt);
        if (parsed == null) throw StateError('Bad alternate address: $alt');
        await _repoint(server, parsed.host, parsed.port);
        return (value: await op(), server: server.copyWith(host: parsed.host, port: parsed.port));
      },
      persistAlt: (a) async {
        // Called with the alt before runAlt (already re-pointed there) and
        // with null when runAlt failed — restore the primary address then.
        if (a == null) await _repoint(server, server.host, server.port);
      },
    );
  }

  Future<void> _repoint(SmbServer server, String host, int port) {
    return saveServer(
      id: server.id,
      name: server.name,
      host: host,
      port: port,
      username: server.username,
      domain: server.domain,
      anonymous: server.anonymous,
      password: '', // empty keeps the stored credential natively
    );
  }

  /// Quick reachability probe used for the saved-server online/offline dot.
  Future<bool> checkServer(String host, int port) async {
    final result = await _channel.invokeMethod<bool>('checkServer', {
      'host': host,
      'port': port,
    });
    return result ?? false;
  }

  /// Starts a loopback HTTP bridge (`http://127.0.0.1:<port>/<token>`) that
  /// serves [path] on [share] of [serverId] with byte-range support — the
  /// libmpv fallback engine cannot read `smb://`, so Android serves the same
  /// jcifs-ng handle over HTTP. Returns the playable URL.
  Future<String> startLoopback(String serverId, String share, String path) async {
    return (await _channel.invokeMethod<String>('startLoopback', {
          'id': serverId,
          'share': share,
          'path': path,
        })) ??
        '';
  }

  /// Tears down the loopback bridge previously returned by [startLoopback].
  Future<void> stopLoopback(String token) async {
    await _channel.invokeMethod<void>('stopLoopback', {'token': token});
  }
}
