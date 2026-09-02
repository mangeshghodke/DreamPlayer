import 'package:flutter/services.dart';

/// A saved FTP / SFTP server (see `FtpClient.kt`). The password never crosses
/// to Dart — only `hasPassword` is exposed.
class FtpServer {
  const FtpServer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.path,
    required this.username,
    required this.hasPassword,
    required this.isSftp,
  });

  final String id;
  final String name;
  final String host;
  final int port;

  /// Base path on the server, e.g. `/` or `/movies`. Always starts with `/`.
  final String path;
  final String username;
  final bool hasPassword;

  /// True = SFTP (SSH), false = plain FTP.
  final bool isSftp;

  String get protocolLabel => isSftp ? 'SFTP' : 'FTP';

  String get subtitle {
    final auth = username.isEmpty ? 'No login' : username;
    final base = '$host:$port$path';
    return '$protocolLabel · $base · $auth';
  }

  factory FtpServer.fromMap(Map<dynamic, dynamic> m) {
    return FtpServer(
      id: (m['id'] as String?) ?? '',
      name: (m['name'] as String?) ?? '',
      host: (m['host'] as String?) ?? '',
      port: (m['port'] as num?)?.toInt() ?? ((m['isSftp'] as bool?) == true ? 22 : 21),
      path: (m['path'] as String?) ?? '/',
      username: (m['username'] as String?) ?? '',
      hasPassword: (m['hasPassword'] as bool?) ?? false,
      isSftp: (m['isSftp'] as bool?) ?? false,
    );
  }
}

/// A folder/file entry returned by the native FTP browser.
class FtpEntry {
  const FtpEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
  });

  final String name;

  /// Absolute path on the server (e.g. `/movies/file.mkv`).
  final String path;
  final bool isDirectory;
  final int size;

  factory FtpEntry.fromMap(Map<dynamic, dynamic> m) {
    return FtpEntry(
      name: (m['name'] as String?) ?? '',
      path: (m['path'] as String?) ?? '',
      isDirectory: (m['isDirectory'] as bool?) ?? false,
      size: (m['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Wraps the native `dreamplayer/ftp` channel (see `FtpClient.kt`).
class FtpClient {
  FtpClient._();

  static final FtpClient instance = FtpClient._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/ftp');

  Future<List<FtpServer>> listServers() async {
    final result = await _channel.invokeListMethod<dynamic>('listServers');
    if (result == null) return const [];
    return result
        .map((e) => FtpServer.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Saves a server; pass [id] to update an existing one. An empty [password]
  /// keeps the stored one when editing.
  Future<FtpServer> saveServer({
    String? id,
    required String name,
    required String host,
    int port = 21,
    String path = '/',
    String username = '',
    String password = '',
    bool isSftp = false,
  }) async {
    final result = await _channel.invokeMethod<dynamic>('saveServer', {
      if (id != null && id.isNotEmpty) 'id': id,
      'name': name,
      'host': host,
      'port': port,
      'path': path,
      'username': username,
      'password': password,
      'isSftp': isSftp,
    });
    return FtpServer.fromMap((result as Map<dynamic, dynamic>?) ?? const {});
  }

  Future<void> deleteServer(String id) async {
    await _channel.invokeMethod<void>('deleteServer', {'id': id});
  }

  /// Invalidate the native listing cache for a server id (or all servers
  /// when [id] is null). The listing itself is cached for 60 s on the
  /// native side so re-visiting a folder is instant.
  Future<void> invalidateListingCache({String? id}) async {
    await _channel.invokeMethod<void>('invalidateListingCache', {
      'id': ?id,
    });
  }

  /// Tests a connection without saving (used by the add/edit dialog).
  Future<({bool ok, String? error})> testConnection({
    required String host,
    int port = 21,
    String path = '/',
    String username = '',
    String password = '',
    bool isSftp = false,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'testConnection',
      {
        'host': host,
        'port': port,
        'path': path,
        'username': username,
        'password': password,
        'isSftp': isSftp,
      },
    );
    return (
      ok: result?['ok'] == true,
      error: result?['error'] as String?,
    );
  }

  /// Lists a folder at [path] (absolute, `/` for the server root prefix).
  Future<List<FtpEntry>> listDirectory(String serverId, String path) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectory', {
      'id': serverId,
      'path': path,
    });
    if (result == null) return const [];
    return result
        .map((e) => FtpEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Full directory listing (videos AND sidecar subtitles) without the
  /// video-only filter the browser uses — the sidecar service needs every
  /// entry to pair subtitles by name (Nova `RawListerFactory.getFileList()`).
  Future<List<FtpEntry>> listDirectoryAll(String serverId, String path) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectoryAll', {
      'id': serverId,
      'path': path,
    });
    if (result == null) return const [];
    return result
        .map((e) => FtpEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Nova-parity sidecar prefetch: reads a subtitle file's bytes so the caller
  /// can write them to a local cache. Returns null on 404/no-access — sidecar
  /// discovery treats that as "no subtitle".
  Future<Uint8List?> fetchBytes(String serverId, String path,
      {int maxBytes = 50 * 1024 * 1024}) async {
    return _channel.invokeMethod<Uint8List>('fetchBytes', {
      'id': serverId,
      'path': path,
      'maxBytes': maxBytes,
    });
  }
}
