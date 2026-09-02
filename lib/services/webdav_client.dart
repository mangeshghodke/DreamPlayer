import 'package:flutter/services.dart';

/// A saved WebDAV server (see `WebDAVClient.kt`). The password never crosses
/// to Dart — only `hasPassword` is exposed; the ready-made `Authorization`
/// header is fetched via [WebDavClient.authorizationHeader].
class WebDavServer {
  const WebDavServer({
    required this.id,
    required this.name,
    required this.url,
    required this.username,
    required this.hasPassword,
    this.allowSelfSigned = false,
  });

  final String id;
  final String name;

  /// Base URL of the WebDAV root, e.g. `http://192.168.1.16:8080/dav`.
  final String url;
  final String username;
  final bool hasPassword;

  /// Trusts any certificate on this server (self-signed). Applied to both
  /// browsing and playback.
  final bool allowSelfSigned;

  String get subtitle {
    final auth = username.isEmpty ? 'No login' : username;
    final ssl = allowSelfSigned ? ' · self-signed OK' : '';
    return '$url · $auth$ssl';
  }

  factory WebDavServer.fromMap(Map<dynamic, dynamic> m) {
    return WebDavServer(
      id: (m['id'] as String?) ?? '',
      name: (m['name'] as String?) ?? '',
      url: (m['url'] as String?) ?? '',
      username: (m['username'] as String?) ?? '',
      hasPassword: (m['hasPassword'] as bool?) ?? false,
      allowSelfSigned: (m['allowSelfSigned'] as bool?) ?? false,
    );
  }
}

/// A folder/file entry returned by the native WebDAV browser.
class WebDavEntry {
  const WebDavEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
  });

  final String name;

  /// Path relative to the server's WebDAV root (e.g. `/Movies/file.mkv`).
  final String path;
  final bool isDirectory;
  final int size;

  factory WebDavEntry.fromMap(Map<dynamic, dynamic> m) {
    return WebDavEntry(
      name: (m['name'] as String?) ?? '',
      path: (m['path'] as String?) ?? '',
      isDirectory: (m['isDirectory'] as bool?) ?? false,
      size: (m['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Wraps the native `dreamplayer/webdav` channel (see `WebDAVClient.kt`).
class WebDavClient {
  WebDavClient._();

  static final WebDavClient instance = WebDavClient._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/webdav');

  Future<List<WebDavServer>> listServers() async {
    final result = await _channel.invokeListMethod<dynamic>('listServers');
    if (result == null) return const [];
    return result
        .map((e) => WebDavServer.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Saves a server; pass [id] to update an existing one. An empty [password]
  /// keeps the stored one when editing.
  Future<WebDavServer> saveServer({
    String? id,
    required String name,
    required String url,
    String username = '',
    String password = '',
    bool allowSelfSigned = false,
  }) async {
    final result = await _channel.invokeMethod<dynamic>('saveServer', {
      if (id != null && id.isNotEmpty) 'id': id,
      'name': name,
      'url': url,
      'username': username,
      'password': password,
      'allowSelfSigned': allowSelfSigned,
    });
    return WebDavServer.fromMap((result as Map<dynamic, dynamic>?) ?? const {});
  }

  Future<void> deleteServer(String id) async {
    await _channel.invokeMethod<void>('deleteServer', {'id': id});
  }

  /// Invalidate the native listing cache for a server URL (or all servers
  /// when [url] is null). Called after edits or pull-to-refresh — the
  /// listing itself is cached for 60 s on the native side so re-visiting
  /// a folder is instant.
  Future<void> invalidateListingCache({String? url}) async {
    await _channel.invokeMethod<void>('invalidateListingCache', {
      'url': ?url,
    });
  }

  /// Tests a connection without saving (used by the add/edit dialog).
  Future<({bool ok, String? error})> testConnection({
    required String url,
    String username = '',
    String password = '',
    bool allowSelfSigned = false,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'testConnection',
      {
        'url': url,
        'username': username,
        'password': password,
        'allowSelfSigned': allowSelfSigned,
      },
    );
    return (
      ok: result?['ok'] == true,
      error: result?['error'] as String?,
    );
  }

  /// Lists a folder at [path] (relative to the server root, `/` for the root).
  Future<List<WebDavEntry>> listDirectory(String serverId, String path) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectory', {
      'id': serverId,
      'path': path,
    });
    if (result == null) return const [];
    return result
        .map((e) => WebDavEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// The ready-made `Authorization` header for [serverId]'s saved credentials
  /// (e.g. `Basic base64(user:pass)`). Used to build the HTTP headers passed
  /// to the player for WebDAV video URLs.
  Future<String> authorizationHeader(String serverId) async {
    final result = await _channel.invokeMethod<String>(
      'authorizationHeader',
      {'id': serverId},
    );
    if (result == null || result.isEmpty) {
      throw PlatformException(code: 'authorizationHeader', message: 'No auth header');
    }
    return result;
  }

  /// Performs a GET on [url] and returns the body bytes on HTTP 200, or null
  /// on any other status (404/403/5xx). When [serverId] is given the request
  /// uses that server's saved credentials + self-signed trust (password never
  /// crosses to Dart); otherwise [headers]/[allowSelfSigned] are used as-is
  /// for generic http(s) sources. Used to probe + download sidecar subtitle
  /// URLs, keeping the payload local instead of streaming it.
  Future<Uint8List?> fetchUrl({
    String? serverId,
    required String url,
    Map<String, String> headers = const {},
    bool allowSelfSigned = false,
  }) async {
    final result = await _channel.invokeMethod<Uint8List>('fetchUrl', {
      if (serverId != null && serverId.isNotEmpty) 'id': serverId,
      'url': url,
      if (headers.isNotEmpty) 'headers': headers,
      if (allowSelfSigned) 'allowSelfSigned': true,
    });
    return result;
  }
}
