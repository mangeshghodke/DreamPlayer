import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';

/// Exception thrown by [PlexClient] calls so screens can surface plain text.
class PlexException implements Exception {
  const PlexException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A saved Plex Media Server entry.
class PlexServer {
  const PlexServer({
    required this.name,
    required this.url,
    this.username = '',
    this.token,
    this.machineIdentifier,
    this.allowSelfSigned = false,
    this.altUrl,
    this.autoDiscovered = false,
  });

  final String name;
  final String url;
  final String username;

  /// `X-Plex-Token` from `/users/sign_in.json`. Empty means "needs sign-in".
  final String? token;
  final String? machineIdentifier;
  final bool allowSelfSigned;

  /// Alternate address (e.g. https://public.example.com) for failover, like
  /// Jellyfin/WebDAV.
  final String? altUrl;
  final bool autoDiscovered;

  bool get isAuthenticated => token != null && token!.isNotEmpty;

  String get urlHost {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  PlexServer copyWith({
    String? name,
    String? url,
    String? username,
    String? token,
    String? machineIdentifier,
    bool? allowSelfSigned,
    String? altUrl,
    bool? autoDiscovered,
  }) {
    return PlexServer(
      name: name ?? this.name,
      url: url ?? this.url,
      username: username ?? this.username,
      token: token ?? this.token,
      machineIdentifier: machineIdentifier ?? this.machineIdentifier,
      allowSelfSigned: allowSelfSigned ?? this.allowSelfSigned,
      altUrl: altUrl ?? this.altUrl,
      autoDiscovered: autoDiscovered ?? this.autoDiscovered,
    );
  }

  PlexServer withClearedToken() {
    return PlexServer(
      name: name,
      url: url,
      username: username,
      token: null,
      machineIdentifier: machineIdentifier,
      allowSelfSigned: allowSelfSigned,
      altUrl: altUrl,
      autoDiscovered: autoDiscovered,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'username': username,
        'token': token,
        'machineIdentifier': machineIdentifier,
        'allowSelfSigned': allowSelfSigned,
        'altUrl': altUrl,
        'autoDiscovered': autoDiscovered,
      };

  factory PlexServer.fromJson(Map<String, dynamic> json) {
    return PlexServer(
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      token: json['token'] as String?,
      machineIdentifier: json['machineIdentifier'] as String?,
      allowSelfSigned: json['allowSelfSigned'] as bool? ?? false,
      altUrl: json['altUrl'] as String?,
      autoDiscovered: json['autoDiscovered'] as bool? ?? false,
    );
  }
}

/// Connection probe result (used by the server dialog's Test button and
/// auto-discovery).
class PlexConnectionInfo {
  const PlexConnectionInfo({
    required this.url,
    this.serverName,
    this.version,
    this.machineIdentifier,
  });

  final String url;
  final String? serverName;
  final String? version;
  final String? machineIdentifier;

  String get displayName =>
      (serverName == null || serverName!.isEmpty) ? url : serverName!;
}

/// One browsable item from Plex: a library section, show, season, movie or
/// episode.
class PlexItem {
  const PlexItem({
    required this.id,
    required this.name,
    required this.type,
    required this.isFolder,
    this.sectionKey,
    this.sectionType,
    this.parentId,
    this.index,
    this.parentIndex,
    this.seriesTitle,
    this.seasonTitle,
    this.durationMs,
    this.resolutionLabel,
    this.sizeBytes,
    this.rating,
    this.year,
    this.partId,
    this.container,
    this.thumbPath,
    this.chapters = const [],
  });

  /// Metadata id (`ratingKey`), or `section:<key>` for library sections.
  final String id;
  final String name;
  final String type;
  final bool isFolder;

  /// Raw section key when this entry is a library section.
  final String? sectionKey;
  final String? sectionType;
  final String? parentId;
  final int? index;

  /// Season number for an episode (parentIndex).
  final int? parentIndex;
  final String? seriesTitle;
  final String? seasonTitle;
  final int? durationMs;
  final String? resolutionLabel;
  final int? sizeBytes;
  final double? rating;
  final int? year;

  /// `Media.Part` id for direct streaming.
  final String? partId;
  final String? container;

  /// Server-relative thumb path, e.g. `/library/metadata/…/thumb/…`.
  final String? thumbPath;
  final List<VideoChapter> chapters;

  bool get isPlayable => type == 'movie' || type == 'episode';

  bool get isEpisode => type == 'episode';

  /// Top-level library sections are navigable, so are also folders.
  bool get isSection => sectionKey != null;

  /// `SxxEyy` code for an episode, built from structured Plex fields.
  String? get episodeCode {
    if (!isEpisode) return null;
    final seasonNum = parentIndex ?? 0;
    final episodeNum = index ?? 0;
    return 'S${seasonNum.toString().padLeft(2, '0')}E${episodeNum.toString().padLeft(2, '0')}';
  }

  /// Resume-stable identity, stable across a server restart (unlike the
  /// discovery-derived host).
  String get stableId => id;

  @override
  bool operator ==(Object other) =>
      other is PlexItem && other.id == id && other.type == type;

  @override
  int get hashCode => id.hashCode ^ type.hashCode;

  // -------------------------------------------------------------------
  // Plex JSON parsing
  // -------------------------------------------------------------------

  factory PlexItem.fromSectionJson(Map<String, dynamic> json) {
    return PlexItem(
      id: 'section:${PlexItem.attr(json, 'key') ?? ''}',
      name: (PlexItem.attr(json, 'title') as String?) ?? '',
      type: 'section',
      sectionKey: PlexItem.attr(json, 'key')?.toString(),
      sectionType: PlexItem.attr(json, 'type') as String?,
      isFolder: true,
      thumbPath: PlexItem.attr(json, 'thumb') as String?,
      sizeBytes: PlexItem._asInt(PlexItem.attr(json, 'size')),
    );
  }

  factory PlexItem.fromMetadataJson(Map<String, dynamic> json) {
    final type = (PlexItem.attr(json, 'type') as String?) ?? '';
    final isFolder = type == 'show' || type == 'season';

    // Media[0].Part[0] carries the direct-play part id and container.
    String? partId;
    String? container;
    final media = json['Media'];
    if (media is List && media.isNotEmpty) {
      final first = media.first;
      if (first is Map) {
        final parts = _listField(first, 'Part');
        if (parts.isNotEmpty && parts.first is Map) {
          final part = parts.first as Map;
          partId = PlexItem.attr(_cast(part), 'id')?.toString();
          container =
              PlexItem.attr(_cast(part), 'container') as String?;
        }
      }
    }

    return PlexItem(
      id: PlexItem.attr(json, 'ratingKey')?.toString() ??
          PlexItem.attr(json, 'key')?.toString() ??
          '',
      name: (PlexItem.attr(json, 'title') as String?) ?? '',
      type: type,
      isFolder: isFolder,
      parentId: PlexItem.attr(json, 'parentRatingKey')?.toString(),
      index: PlexItem._asInt(PlexItem.attr(json, 'index')),
      parentIndex: PlexItem._asInt(PlexItem.attr(json, 'parentIndex')),
      seriesTitle: PlexItem.attr(json, 'grandparentTitle') as String?,
      seasonTitle: PlexItem.attr(json, 'parentTitle') as String?,
      durationMs: PlexItem._asInt(PlexItem.attr(json, 'duration')),
      resolutionLabel: PlexItem._resolutionFromJson(json),
      sizeBytes: PlexItem._partSize(json),
      rating: _asDouble(PlexItem.attr(json, 'rating')),
      year: PlexItem._asInt(PlexItem.attr(json, 'year')),
      partId: partId,
      container: container,
      thumbPath: PlexItem.attr(json, 'thumb') as String?,
    );
  }

  static List<dynamic> _listField(dynamic container, String key) {
    final value = PlexItem.attr(_cast(container), key);
    if (value is List) return value;
    if (value is Map) return [value];
    return const [];
  }

  static Map<String, dynamic> _cast(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    return {
      for (final e in (value as Map).entries)
        e.key.toString(): e.value,
    };
  }

  static int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }

  static double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    return double.tryParse(value.toString());
  }

  /// Reads a field both bare and `@`-prefixed — Plex JSON attributes come
  /// through as `@ratingKey`, `@title`, `@type`, ….
  static dynamic attr(Map<String, dynamic> json, String key) {
    return json[key] ?? json['@$key'];
  }

  static String? _resolutionFromJson(Map<String, dynamic> json) {
    final media = json['Media'];
    if (media is List && media.isNotEmpty && media.first is Map) {
      final first = _cast(media.first);
      final res = PlexItem.attr(first, 'videoResolution') as String?;
      if (res != null && res.isNotEmpty) return res;
    }
    return null;
  }

  static int? _partSize(Map<String, dynamic> json) {
    final media = json['Media'];
    if (media is List && media.isNotEmpty && media.first is Map) {
      final parts = _listField(media.first, 'Part');
      if (parts.isNotEmpty && parts.first is Map) {
        return _asInt(PlexItem.attr(_cast(parts.first), 'size'));
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'isFolder': isFolder,
        'sectionKey': sectionKey,
        'sectionType': sectionType,
        'parentId': parentId,
        'index': index,
        'parentIndex': parentIndex,
        'seriesTitle': seriesTitle,
        'seasonTitle': seasonTitle,
        'durationMs': durationMs,
        'resolutionLabel': resolutionLabel,
        'sizeBytes': sizeBytes,
        'rating': rating,
        'year': year,
        'partId': partId,
        'container': container,
        'thumbPath': thumbPath,
        'chapters': [for (final c in chapters) c.toJson()],
      };

  factory PlexItem.fromJson(Map<String, dynamic> json) {
    final chaptersList = json['chapters'];
    return PlexItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? '',
      isFolder: json['isFolder'] as bool? ?? false,
      sectionKey: json['sectionKey'] as String?,
      sectionType: json['sectionType'] as String?,
      parentId: json['parentId'] as String?,
      index: _asInt(json['index']),
      parentIndex: _asInt(json['parentIndex']),
      seriesTitle: json['seriesTitle'] as String?,
      seasonTitle: json['seasonTitle'] as String?,
      durationMs: _asInt(json['durationMs']),
      resolutionLabel: json['resolutionLabel'] as String?,
      sizeBytes: _asInt(json['sizeBytes']),
      rating: _asDouble(json['rating']),
      year: _asInt(json['year']),
      partId: json['partId'] as String?,
      container: json['container'] as String?,
      thumbPath: json['thumbPath'] as String?,
      chapters: chaptersList is List
          ? chaptersList
              .whereType<Map<String, dynamic>>()
              .map(VideoChapter.fromJson)
              .toList()
          : const [],
    );
  }
}

/// Plex Media Server REST client.
class PlexClient {
  PlexClient([this._prefsOverride]);

  static const String _serversKey = 'dreamplayer.plexServers';
  static const String _deviceIdKey = 'dreamplayer.plexDeviceId';
  static const String _clientProductName = 'DreamPlayer';
  static const String _clientProductVersion = '0.5.6';

  final SharedPreferences? _prefsOverride;
  Future<SharedPreferences>? _prefsFuture;

  // -----------------------------------------------------------------------
  // Prefs / server persistence
  // -----------------------------------------------------------------------

  Future<SharedPreferences> _getPrefs() {
    if (_prefsOverride != null) return Future.value(_prefsOverride);
    return _prefsFuture ??= SharedPreferences.getInstance();
  }

  Future<List<PlexServer>> loadServers() async {
    final prefs = await _getPrefs();
    final raw = prefs.getString(_serversKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(PlexServer.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveServers(List<PlexServer> servers) async {
    final prefs = await _getPrefs();
    await prefs.setString(
      _serversKey,
      jsonEncode([for (final s in servers) s.toJson()]),
    );
  }

  Future<List<PlexServer>> addServer(PlexServer server) async {
    final existing = await loadServers();
    final servers = [...existing];
    final index = servers.indexWhere((s) => s.url == server.url);
    if (index >= 0) {
      servers[index] = server;
    } else {
      servers.add(server);
    }
    await saveServers(servers);
    return servers;
  }

  Future<List<PlexServer>> removeServer(String url) async {
    final servers =
        (await loadServers()).where((s) => s.url != url).toList();
    await saveServers(servers);
    return servers;
  }

  /// Stable per-install client identifier for `X-Plex-Client-Identifier`.
  Future<String> clientIdentifier() async {
    final prefs = await _getPrefs();
    var id = prefs.getString(_deviceIdKey);
    if (id == null || id.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch.toString();
      id = 'dp-${now.hashCode.toUnsigned(32).toRadixString(16)}-$now';
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  // -----------------------------------------------------------------------
  // URL / error helpers
  // -----------------------------------------------------------------------

  /// Normalizes a typed URL: adds the scheme and Plex's default port.
  static String normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    // Strip any existing path — Plex servers are root-homed.
    final uri = Uri.tryParse(url);
    if (uri != null && uri.path.isNotEmpty && uri.path != '/') {
      final trimmed = url.substring(0, url.length - uri.path.length);
      url = trimmed;
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    final hasScheme = url.startsWith('http://') || url.startsWith('https://');
    if (!hasScheme) {
      url = 'http://$url';
    }
    // Plex default port is 32400. Only fill it in for bare host[:port] URLs
    // that had no port at all.
    final parsed = Uri.parse(url);
    if (parsed.hasPort) return url;
    return '$url:32400';
  }

  /// Maps socket/HTTP failures to user-readable strings.
  static String friendlyError(Object e) {
    if (e is PlexException) return e.message;
    if (e is SocketException) {
      return 'Could not reach the server (${e.message})';
    }
    if (e is TimeoutException) return 'The server did not respond in time';
    if (e is FormatException) return 'The server sent an unexpected response';
    if (e is HandshakeException) {
      return 'TLS handshake failed — enable self-signed certificates';
    }
    return 'Unexpected error: $e';
  }

  HttpClient _httpClient({required bool allowSelfSigned}) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    if (allowSelfSigned) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    return client;
  }

  Map<String, String> _plexHeaders({
    required String identifier,
    String? token,
  }) {
    return {
      'Accept': 'application/json',
      'X-Plex-Product': _clientProductName,
      'X-Plex-Version': _clientProductVersion,
      'X-Plex-Device': _clientProductName,
      'X-Plex-Client-Identifier': identifier,
      if (token != null && token.isNotEmpty) 'X-Plex-Token': token,
    };
  }

  // -----------------------------------------------------------------------
  // HTTP plumbing
  // -----------------------------------------------------------------------

  Future<Map<String, dynamic>> _getJson(
    String url, {
    required bool allowSelfSigned,
    String? token,
    int timeoutSeconds = 15,
  }) async {
    final identifier = await clientIdentifier();
    final headers = _plexHeaders(identifier: identifier, token: token);
    final client = _httpClient(allowSelfSigned: allowSelfSigned);
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSeconds));
      headers.forEach((k, v) => req.headers.set(k, v));
      final res =
          await req.close().timeout(Duration(seconds: timeoutSeconds));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) {
        if (token == null || token.isEmpty) {
          throw const PlexException('Sign-in required');
        }
        throw const PlexException('Server did not accept the saved sign-in');
      }
      if (res.statusCode >= 400) {
        throw PlexException('Server error ${res.statusCode}');
      }
      return _decodeMap(body);
    } on PlexException {
      rethrow;
    } on Exception catch (e) {
      throw PlexException(friendlyError(e));
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postForm(
    String url, {
    required Map<String, String> fields,
    required bool allowSelfSigned,
    int timeoutSeconds = 15,
  }) async {
    final identifier = await clientIdentifier();
    final headers = _plexHeaders(identifier: identifier);
    final client = _httpClient(allowSelfSigned: allowSelfSigned);
    try {
      final req = await client
          .postUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSeconds));
      headers.forEach((k, v) => req.headers.set(k, v));
      req.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      final body = fields.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}='
              '${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      req.add(utf8.encode(body));
      final res =
          await req.close().timeout(Duration(seconds: timeoutSeconds));
      final responseBody = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) {
        throw const PlexException('Wrong username or password');
      }
      if (res.statusCode >= 400) {
        throw PlexException('Server error ${res.statusCode}');
      }
      return _decodeMap(responseBody);
    } on PlexException {
      rethrow;
    } on Exception catch (e) {
      throw PlexException(friendlyError(e));
    } finally {
      client.close(force: true);
    }
  }

  /// Plex usually answers JSON when `Accept: application/json` is sent, but
  /// `identity` and `users/sign_in` sometimes reply XML — fall back to regex
  /// extraction so the caller never crashes on a supported response.
  Map<String, dynamic> _decodeMap(String body) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return {'_raw': body};
  }

  /// Pull `MediaContainer` out of a decoded JSON body (or the raw fallback).
  Map<String, dynamic> _container(Map<String, dynamic> json) {
    final inner = json['MediaContainer'];
    if (inner is Map<String, dynamic>) return inner;
    return json;
  }

  /// Look up a list-or-single-object field the way Plex returns it.
  List<dynamic> _listOf(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is List) return value;
    if (value is Map) return [value];
    return const [];
  }

  // -----------------------------------------------------------------------
  // Auth / probe
  // -----------------------------------------------------------------------

  /// Pings `/identity` — no auth required — so the server dialog can verify a
  /// URL without credentials.
  Future<PlexConnectionInfo> testConnection(
    String rawUrl, {
    required bool allowSelfSigned,
    String? altUrl,
  }) async {
    final url = normalizeUrl(rawUrl);
    final json = await _getJson('$url/identity',
        allowSelfSigned: allowSelfSigned);
    final container = _container(json);
    var friendly = _asString(container['@friendlyName'] ?? container['friendlyName']);
    var machineId = _asString(
        container['@machineIdentifier'] ?? container['machineIdentifier']);
    var version = _asString(container['@version'] ?? container['version']);

    final raw = json['_raw'] as String?;
    if ((friendly == null || machineId == null) && raw != null) {
      friendly ??= _extractAttr(raw, 'friendlyName');
      machineId ??= _extractAttr(raw, 'machineIdentifier');
      version ??= _extractAttr(raw, 'version');
    }

    return PlexConnectionInfo(
      url: url,
      serverName: friendly,
      version: version,
      machineIdentifier: machineId,
    );
  }

  /// Signs in a local Plex.tv/user account via `/users/sign_in.json` and
  /// returns the server enriched with the `X-Plex-Token` authentication token.
  Future<PlexServer> authenticate(
    PlexServer server,
    String username,
    String password,
  ) async {
    final url = _base(server);
    if (username.trim().isEmpty || password.isEmpty) {
      throw PlexException('Username and password are required');
    }
    final json = await _postForm(
      '$url/users/sign_in.json',
      fields: {
        'login': username.trim(),
        'password': password,
      },
      allowSelfSigned: server.allowSelfSigned,
    );
    var token = _findAuthenticationToken(json);
    final raw = json['_raw'] as String?;
    if (token == null && raw != null) {
      token ??= _extractAttr(raw, 'authenticationToken');
      token ??= _extractAttr(raw, 'authToken');
    }
    if (token == null || token.isEmpty) {
      throw PlexException(
          'Server did not return an authentication token');
    }
    return server.copyWith(username: username.trim(), token: token);
  }

  String? _findAuthenticationToken(Map<String, dynamic> json) {
    // Direct response header case is handled by http package? No — headers
    // only; here we scan the JSON body.
    for (final key in const [
      'authenticationToken',
      'authToken',
      '@authenticationToken',
    ]) {
      final value = json[key];
      if (value is String && value.isNotEmpty) return value;
    }
    final container = _container(json);
    for (final key in const [
      'authenticationToken',
      'authToken',
      '@authenticationToken',
    ]) {
      final value = container[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return _scanForToken(json, depth: 0);
  }

  String? _scanForToken(dynamic node, {required int depth}) {
    if (depth > 6) return null;
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString();
        if (key == 'authenticationToken' || key == 'authToken') {
          final value = entry.value;
          if (value is String && value.isNotEmpty) return value;
        }
      }
      for (final value in node.values) {
        final found = _scanForToken(value, depth: depth + 1);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _scanForToken(value, depth: depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  // -----------------------------------------------------------------------
  // Browsing
  // -----------------------------------------------------------------------

  String _base(PlexServer server) => server.url;

  /// Top-level libraries (movie, show, music sections).
  Future<List<PlexItem>> getLibraries(PlexServer server) async {
    final json = await _getJson(
      '${_base(server)}/library/sections',
      allowSelfSigned: server.allowSelfSigned,
      token: server.token,
    );
    final directories =
        _listOf(_container(json), 'Directory');
    return [
      for (final entry in directories)
        if (entry is Map<String, dynamic>) PlexItem.fromSectionJson(entry)
    ];
  }

  /// Children of a section (`Library/sections/.../all`) or of a show/season
  /// (`/library/metadata/{id}/children`).
  Future<List<PlexItem>> getItems(
    PlexServer server,
    String parentId,
  ) async {
    if (parentId.startsWith('section:')) {
      final key = parentId.substring('section:'.length);
      final json = await _getJson(
        '${_base(server)}/library/sections/$key/all',
        allowSelfSigned: server.allowSelfSigned,
        token: server.token,
      );
      final metadata = _listOf(_container(json), 'Metadata');
      return [
        for (final entry in metadata)
          if (entry is Map<String, dynamic>) PlexItem.fromMetadataJson(entry)
      ];
    }
    final json = await _getJson(
      '${_base(server)}/library/metadata/$parentId/children',
      allowSelfSigned: server.allowSelfSigned,
      token: server.token,
    );
    final metadata = _listOf(_container(json), 'Metadata');
    return [
      for (final entry in metadata)
        if (entry is Map<String, dynamic>) PlexItem.fromMetadataJson(entry)
    ];
  }

  /// Chapters/intro markers for one ratingKey.
  Future<List<VideoChapter>> getMarkers(
    PlexServer server,
    String ratingKey,
  ) async {
    final json = await _getJson(
      '${_base(server)}/library/metadata/$ratingKey/markers',
      allowSelfSigned: server.allowSelfSigned,
      token: server.token,
    );
    final markers = _listOf(_container(json), 'Marker');
    final chapters = <VideoChapter>[];
    for (final entry in markers) {
      if (entry is! Map<String, dynamic>) continue;
      final startMs =
          PlexItem._asInt(PlexItem.attr(entry, 'startTimeOffset')) ?? 0;
      final endMs = PlexItem._asInt(PlexItem.attr(entry, 'endTimeOffset'));
      final type = PlexItem.attr(entry, 'type') as String?;
      final title =
          (PlexItem.attr(entry, 'title') as String?) ?? type;
      chapters.add(VideoChapter(
        title: _markerTitle(title, type, chapters.length),
        startMs: startMs,
        endMs: endMs,
      ));
    }
    chapters.sort((a, b) => a.startMs.compareTo(b.startMs));
    return chapters;
  }

  static String _markerTitle(String? title, String? type, int fallbackIndex) {
    if (title != null && title.trim().isNotEmpty) return title.trim();
    if (type != null && type.trim().isNotEmpty) return type.trim();
    return 'Chapter ${fallbackIndex + 1}';
  }

  /// Direct-play URL for one playable item. Requires `partId` — episodes and
  /// movies always carry it; browsing entries don't.
  String? streamUrl(PlexServer server, PlexItem item) {
    if (item.partId == null) return null;
    final container =
        (item.container?.isNotEmpty == true) ? item.container! : 'mkv';
    if (server.token == null || server.token!.isEmpty) {
      throw PlexException('Server not signed in');
    }
    final url =
        '${_base(server)}/library/parts/${item.partId}/file.$container'
        '?X-Plex-Token=${Uri.encodeQueryComponent(server.token!)}';
    if (server.altUrl != null && server.altUrl!.isNotEmpty) {
      // The direct URL stays on the primary address; the caller can fall back
      // to [streamUrlOn] with the alternate URL if the primary is unreachable.
      return url;
    }
    return url;
  }

  String streamUrlOn(PlexServer server, PlexItem item, String base) {
    if (item.partId == null) {
      throw PlexException('Item is not directly streamable');
    }
    final container =
        (item.container?.isNotEmpty == true) ? item.container! : 'mkv';
    return '$base/library/parts/${item.partId}/file.$container'
        '?X-Plex-Token=${Uri.encodeQueryComponent(server.token ?? '')}';
  }

  /// Builds a [VideoItem] for the details-screen flow. Chapters are attached
  /// when the caller pre-fetched them (`getMarkers`).
  VideoItem videoItem(PlexServer server, PlexItem item) {
    final url = streamUrl(server, item) ??
        '${_base(server)}/library/metadata/${item.id}/file'
            '?X-Plex-Token=${Uri.encodeQueryComponent(server.token ?? '')}';
    return VideoItem(
      id: 'plex_${_clientPrefix(server)}_${item.stableId}',
      title: _displayTitle(item),
      uri: url,
      resumeKey: 'plex:${_clientPrefix(server)}/${item.stableId}',
      duration: Duration(milliseconds: item.durationMs ?? 0),
      sizeBytes: item.sizeBytes,
      resolution: item.resolutionLabel,
      allowSelfSigned: server.allowSelfSigned,
      chapters: item.chapters,
      seriesName: item.seriesTitle,
      seasonNumber: item.parentIndex,
      episodeNumber: item.index,
    );
  }

  String _displayTitle(PlexItem item) {
    if (item.type == 'episode') {
      final series = item.seriesTitle ?? '';
      final code = item.episodeCode ?? '';
      final title = item.name;
      return series.isEmpty
          ? (code.isEmpty ? title : '$code $title')
          : '$series ${code.isEmpty ? '' : '$code '}$title'.trim();
    }
    return item.name;
  }

  String _clientPrefix(PlexServer server) => server.urlHost;

  /// Failover helper mirroring Jellyfin/WebDAV: try the primary URL, then the
  /// alternate if the primary is unreachable.
  Future<({PlexServer server, T value})> withAltFailover<T>(
    PlexServer server,
    Future<T> Function(PlexServer server) action,
  ) async {
    try {
      final value = await action(server);
      return (server: server, value: value);
    } on Exception catch (primaryError) {
      final alt = server.altUrl;
      if (alt == null || alt.isEmpty) rethrow;
      try {
        // Switch the acting URL to the alternate for the retry.
        final shifted = server.copyWith(url: alt, altUrl: server.url);
        final value = await action(shifted);
        return (server: shifted, value: value);
      } on Exception {
        throw PlexException(friendlyError(primaryError));
      }
    }
  }

  static String? _extractAttr(String text, String name) {
    // Handles `name="value"` (XML) and `"name": "value"` (JSON).
    final xml = RegExp('$name="([^"]*)"');
    final xmlMatch = xml.firstMatch(text);
    if (xmlMatch != null) return xmlMatch.group(1);
    final json = RegExp('"$name"\\s*:\\s*"([^"]*)"');
    final jsonMatch = json.firstMatch(text);
    if (jsonMatch != null) return jsonMatch.group(1);
    return null;
  }

  static String? _asString(dynamic value) {
    if (value is String) return value;
    return null;
  }
}
