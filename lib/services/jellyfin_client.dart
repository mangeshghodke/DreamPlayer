import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:multicast_dns/multicast_dns.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';
import '../utils/codec_info.dart' show languageName;

/// A saved (or discovered) Jellyfin / Emby server.
class JellyfinServer {
  const JellyfinServer({
    required this.name,
    required this.url,
    this.username = '',
    this.token,
    this.userId,
    this.allowSelfSigned = false,
    this.autoDiscovered = false,
  });

  final String name;

  /// Normalized base URL without trailing slash, e.g. `http://192.168.1.16:8096`.
  final String url;

  final String username;
  final String? token;
  final String? userId;

  /// Trusts any certificate when talking to this server (self-signed HTTPS).
  final bool allowSelfSigned;

  /// True when this came from mDNS discovery (not persisted).
  final bool autoDiscovered;

  bool get isAuthenticated => token != null && token!.isNotEmpty && userId != null;

  String get urlHost {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  static const Object _unset = Object();

  JellyfinServer copyWith({
    String? name,
    String? url,
    String? username,
    Object? token = _unset,
    Object? userId = _unset,
    bool? allowSelfSigned,
    bool? autoDiscovered,
  }) {
    return JellyfinServer(
      name: name ?? this.name,
      url: url ?? this.url,
      username: username ?? this.username,
      token: identical(token, _unset) ? this.token : token as String?,
      userId: identical(userId, _unset) ? this.userId : userId as String?,
      allowSelfSigned: allowSelfSigned ?? this.allowSelfSigned,
      autoDiscovered: autoDiscovered ?? this.autoDiscovered,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'username': username,
        'token': token,
        'userId': userId,
        'allowSelfSigned': allowSelfSigned,
      };

  factory JellyfinServer.fromJson(Map<String, dynamic> json) {
    return JellyfinServer(
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      token: json['token'] as String?,
      userId: json['userId'] as String?,
      allowSelfSigned: (json['allowSelfSigned'] as bool?) ?? false,
    );
  }
}

/// An external subtitle track reported by a Jellyfin media source.
class JellyfinExternalSub {
  const JellyfinExternalSub({
    required this.index,
    required this.codec,
    required this.deliveryUrl,
    this.language = '',
    this.title = '',
    this.path = '',
    this.isDefault = false,
    this.isForced = false,
  });

  final int index;
  final String codec;
  final String deliveryUrl;
  final String language;

  /// The exact subtitle file name Jellyfin exposes (its `Title` — usually the
  /// `.srt`/`.ass` file name, e.g. `Show.S01E01.eng.srt`).
  final String title;

  /// The server-side file path of the subtitle (Jellyfin `Path`), whose
  /// basename is the real file name when `Title` is empty.
  final String path;

  final bool isDefault;
  final bool isForced;

  /// MIME type for Media3 / AetherEngine.
  String get mimeType => switch (codec.toLowerCase()) {
        'subrip' || 'srt' => 'application/x-subrip',
        'ass' || 'ssa' => 'text/x-ssa',
        'vtt' => 'text/vtt',
        'ttml' || 'dfxp' => 'application/ttml+xml',
        'sami' || 'smi' => 'application/x-sami',
        _ => 'application/x-subrip',
      };

  /// File extension for the delivery URL suffix.
  String get extension => switch (codec.toLowerCase()) {
        'ass' || 'ssa' => 'ass',
        'vtt' => 'vtt',
        'ttml' || 'dfxp' => 'ttml',
        _ => 'srt',
      };

  /// Display name for the subtitle picker — always the *exact* subtitle file
  /// name when Jellyfin provides one (previously empty/Jellyfin `DisplayTitle`
  /// only surfaced generic names like "English" or "Track N").
  ///
  /// Resolution order:
  /// 1. [title] — Jellyfin's `Title` (the file name for external subs).
  /// 2. basename of [path] — the real `.srt`/`.ass` name on the server.
  /// 3. [language]'s full English name (e.g. `eng` → `English`).
  /// 4. neutral `External subtitle N` fallback (never "undefined").
  String get displayTitle {
    if (title.isNotEmpty) return title;
    final base = path.split(RegExp(r'[/\\]')).last;
    if (base.isNotEmpty) return base;
    final lang = languageName(language);
    if (lang.isNotEmpty) return lang;
    return 'External subtitle ${index + 1}';
  }

  factory JellyfinExternalSub.fromJson(Map<String, dynamic> json) {
    // DeliveryUrl may be a relative path like
    // /Videos/{id}/{msId}/Subtitles/{idx}/Stream.srt
    // or a full URL. We store it as-is; the caller builds the full URL.
    return JellyfinExternalSub(
      index: (json['Index'] as num?)?.toInt() ?? 0,
      codec: json['Codec'] as String? ?? 'subrip',
      deliveryUrl: json['DeliveryUrl'] as String? ?? '',
      language: json['Language'] as String? ?? '',
      title: json['Title'] as String? ?? '',
      path: json['Path'] as String? ?? '',
      isDefault: (json['IsDefault'] as bool?) ?? false,
      isForced: (json['IsForced'] as bool?) ?? false,
    );
  }
}

/// A library / folder / playable item as returned by the Jellyfin API.
class JellyfinItem {
  const JellyfinItem({
    required this.id,
    required this.name,
    this.isFolder = false,
    this.mediaType,
    this.type,
    this.runTimeTicks,
    this.width,
    this.height,
    this.mediaSourceId,
    this.container,
    this.indexNumber,
    this.parentIndexNumber,
    this.parentId,
    this.sizeBytes,
    this.externalSubtitles = const [],
    this.chapters = const [],
  });

  final String id;
  final String name;
  final bool isFolder;

  /// `Video`, `Audio` or null.
  final String? mediaType;

  /// e.g. `Movie`, `Episode`, `Series`, `CollectionFolder`, `Folder`.
  final String? type;
  final int? runTimeTicks;
  final int? width;
  final int? height;

  /// Media source id for the direct stream URL (falls back to [id]).
  final String? mediaSourceId;
  final String? container;

  /// Episode number within its season (`IndexNumber`).
  final int? indexNumber;

  /// Season number for `Type == Episode` (`ParentIndexNumber`).
  final int? parentIndexNumber;

  /// Parent folder id (`ParentId`) for sibling listing (auto-play next).
  final String? parentId;

  /// File size in bytes from `MediaSources[0].Size` (or the top-level `Size`).
  /// Used on file rows instead of our own duration label.
  final int? sizeBytes;

  /// External subtitle tracks reported by the server (SRT/ASS/VTT files
  /// sitting next to the video on the server, served via `DeliveryUrl`).
  final List<JellyfinExternalSub> externalSubtitles;

  /// Chapters from `MediaSources[0].Chapters` (Jellyfin parses MKV `Chapters`).
  /// Each entry has `Name` + `StartPositionTicks` (100 ns units).
  final List<VideoChapter> chapters;

  Duration get duration => Duration(microseconds: (runTimeTicks ?? 0) ~/ 10);

  bool get isPlayable => !isFolder && (mediaType == 'Video' || mediaType == 'Audio');

  String get resolution => width != null && height != null ? '${width!}x${height!}' : '';

  /// `S01E04` from [parentIndexNumber]/[indexNumber], or '' when unknown.
  String get seasonLabel {
    final s = parentIndexNumber;
    final e = indexNumber;
    if (s == null || e == null || s <= 0 || e <= 0) return '';
    return 'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
  }

  String get durationLabel {
    if (duration <= Duration.zero) return '';
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60);
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}h';
    return '${m}m';
  }

  /// Human-readable file size (`4.2 GB`) matching the WebDAV/file-browser
  /// rows, or '' when the server didn't report a size.
  String get sizeLabel {
    final bytes = sizeBytes;
    if (bytes == null || bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }

  factory JellyfinItem.fromJson(Map<String, dynamic> json) {
    final mediaSources = json['MediaSources'] as List? ?? const [];
    final firstSource = mediaSources.isNotEmpty ? mediaSources.first : null;
    String? mediaSourceId;
    int? sizeBytes;
    List<JellyfinExternalSub> externalSubs = const [];
    List<VideoChapter> chapters = const [];
    if (firstSource is Map<String, dynamic>) {
      mediaSourceId = firstSource['Id'] as String?; // ignore: unnecessary_null_comparison
      sizeBytes = (firstSource['Size'] as num?)?.toInt() ??
          (json['Size'] as num?)?.toInt();
      // Parse external subtitle tracks from MediaStreams.
      final streams = firstSource['MediaStreams'] as List? ?? const [];
      externalSubs = streams
          .whereType<Map<String, dynamic>>()
          .where((s) =>
              s['Type'] == 'Subtitle' &&
              (s['IsExternal'] as bool?) == true &&
              (s['SupportsExternalStream'] as bool?) != false)
          .map((s) => JellyfinExternalSub.fromJson(s))
          .toList();
      // Parse chapters that Jellyfin extracted from the container.
      // Jellyfin puts them at `Item.Chapters` when `Fields=Chapters` is
      // requested (top-level), not always inside `MediaSources[0].Chapters`
      // — check both. Each entry: {Name, StartPositionTicks} (100 ns units).
      // Chapters live at Item.Chapters when Fields=Chapters is requested.
      final topChapters = json['Chapters'] as List?;
      List<dynamic> rawChapters = const [];
      if (topChapters != null && topChapters.isNotEmpty) {
        rawChapters = topChapters;
      } else if (firstSource is Map<String, dynamic>) { // ignore: unnecessary_type_check
        rawChapters = (firstSource['Chapters'] as List?) ?? const [];
      }
      if (rawChapters.isNotEmpty) {
        final parsed = rawChapters
            .whereType<Map<String, dynamic>>()
            .map((c) {
              final name = (c['Name'] as String?)?.trim();
              final ticks = (c['StartPositionTicks'] as num?)?.toInt() ?? 0;
              return VideoChapter(
                title: name != null && name.isNotEmpty ? name : 'Chapter',
                startMs: ticks ~/ 10000,
              );
            })
            .toList()
          ..sort((a, b) => a.startMs.compareTo(b.startMs));
        // Backfill endMs from the next chapter's start (and de-dupe fallback titles).
        chapters = List.generate(parsed.length, (i) {
          final c = parsed[i];
          final end = i + 1 < parsed.length ? parsed[i + 1].startMs : null;
          final title = c.title == 'Chapter' ? 'Chapter ${i + 1}' : c.title;
          return VideoChapter(title: title, startMs: c.startMs, endMs: end);
        });
      }
    }
    final mediaType = json['MediaType'] as String?;
    return JellyfinItem(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      isFolder: (json['IsFolder'] as bool?) ?? false,
      mediaType: mediaType,
      type: json['Type'] as String?,
      runTimeTicks: (json['RunTimeTicks'] as num?)?.toInt(),
      width: (json['Width'] as num?)?.toInt(),
      height: (json['Height'] as num?)?.toInt(),
      mediaSourceId: mediaSourceId ?? json['Id'] as String?,
      container: json['Container'] as String?,
      indexNumber: (json['IndexNumber'] as num?)?.toInt(),
      parentIndexNumber: (json['ParentIndexNumber'] as num?)?.toInt(),
      parentId: json['ParentId'] as String?,
      sizeBytes: sizeBytes,
      externalSubtitles: externalSubs,
      chapters: chapters,
    );
  }
}

/// Metadata about a Jellyfin folder/series fetched from the server itself
/// (name, overview, year, genres, rating, artwork). Kept separate from
/// [TmdMovie]: Jellyfin image URLs are server-relative and embed the session
/// token, whereas TMDB URLs are always `image.tmdb.org`.
class JellyfinItemInfo {
  const JellyfinItemInfo({
    required this.id,
    required this.name,
    this.type,
    this.overview = '',
    this.year,
    this.genres = const [],
    this.communityRating = 0,
    this.runTimeTicks,
    this.imageUrl,
    this.backdropUrl,
  });

  final String id;
  final String name;

  /// Jellyfin type: `Series`, `Movie`, `CollectionFolder`, `Folder`, ...
  final String? type;
  final String overview;
  final int? year;
  final List<String> genres;
  final double communityRating;
  final int? runTimeTicks;

  /// Full server URL to the poster art (token embedded as `api_key`).
  final String? imageUrl;
  final String? backdropUrl;

  bool get isTv => type == 'Series';
  bool get isMovie => type == 'Movie';

  Duration get duration => Duration(microseconds: (runTimeTicks ?? 0) ~/ 10);

  String get durationLabel {
    if (duration <= Duration.zero) return '';
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60);
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}h';
    return '${m}m';
  }

  String get kindLabel {
    if (isTv) return 'TV Series';
    if (isMovie) return 'Movie';
    return '';
  }

  /// Builds the model from a Jellyfin API item response. Image URLs carry the
  /// session token, so they're constructed here — they can go stale after a
  /// re-login, which is why callers refresh the cache on open.
  factory JellyfinItemInfo.fromApi(
    Map<String, dynamic> json, {
    required String serverUrl,
    required String token,
  }) {
    final id = json['Id'] as String? ?? '';
    final imageTags = json['ImageTags'] as Map? ?? const {};
    final backdropTags = json['BackdropImageTags'] as List? ?? const [];
    final primaryTag = imageTags['Primary'] as String? ?? '';
    final backdropTag = backdropTags.isNotEmpty
        ? backdropTags.first as String?
        : (imageTags['Backdrop'] as String? ??
            imageTags['Thumb'] as String? ??
            '');
    String? imageUrl;
    if (id.isNotEmpty && primaryTag.isNotEmpty) {
      imageUrl =
          '$serverUrl/Items/$id/Images/Primary?tag=$primaryTag&api_key=$token';
    }
    String? backdropUrl;
    if (id.isNotEmpty && backdropTag != null && backdropTag.isNotEmpty) {
      backdropUrl =
          '$serverUrl/Items/$id/Images/Backdrop?tag=$backdropTag&api_key=$token';
    }
    return JellyfinItemInfo(
      id: id,
      name: json['Name'] as String? ?? '',
      type: json['Type'] as String?,
      overview: json['Overview'] as String? ?? '',
      year: (json['ProductionYear'] as num?)?.toInt(),
      genres: (json['Genres'] as List?)?.whereType<String>().toList() ??
          const [],
      communityRating: ((json['CommunityRating'] as num?) ?? 0).toDouble(),
      runTimeTicks: (json['RunTimeTicks'] as num?)?.toInt(),
      imageUrl: imageUrl,
      backdropUrl: backdropUrl,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'overview': overview,
        'year': year,
        'genres': genres,
        'communityRating': communityRating,
        'runTimeTicks': runTimeTicks,
        'imageUrl': imageUrl,
        'backdropUrl': backdropUrl,
      };

  factory JellyfinItemInfo.fromJson(Map<String, dynamic> json) {
    return JellyfinItemInfo(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: json['type'] as String?,
      overview: json['overview'] as String? ?? '',
      year: json['year'] as int?,
      genres: (json['genres'] as List?)?.whereType<String>().toList() ??
          const [],
      communityRating: ((json['communityRating'] as num?) ?? 0).toDouble(),
      runTimeTicks: json['runTimeTicks'] as int?,
      imageUrl: json['imageUrl'] as String?,
      backdropUrl: json['backdropUrl'] as String?,
    );
  }
}

/// Result of a connection test.
class JellyfinConnectionInfo {
  const JellyfinConnectionInfo({required this.serverName, required this.version, required this.serverId});
  final String serverName;
  final String version;
  final String serverId;
}

class JellyfinException implements Exception {
  const JellyfinException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// REST + mDNS client for Jellyfin / Emby servers.
///
/// The stream URL carries the token as an `api_key` query parameter (Jellyfin
/// accepts it there or as an `X-Emby-Token` header), so playback works through
/// the existing ExoPlayer/Media3 (Android) and AetherEngine (iOS) HTTP stacks
/// with zero native changes.
class JellyfinClient {
  JellyfinClient([this._prefs]);

  static const _serversKey = 'dreamplayer.jellyfinServers';

  final SharedPreferences? _prefs;
  SharedPreferences? _cachedPrefs;

  Future<SharedPreferences> get _sharedPrefs async => _cachedPrefs ??= _prefs ?? await SharedPreferences.getInstance();

  /// The `MediaBrowser Client=...` auth header value.
  ///
  /// Uses the **stable** per-install [deviceId]. It previously used
  /// `DateTime.now()` here, which minted a brand-new DeviceId on *every*
  /// request — the server saw each call as a different device, sessions never
  /// lined up, and the device list in Jellyfin filled with junk entries.
  Future<String> get _authHeader async {
    return 'MediaBrowser Client="DreamPlayer", Device="DreamPlayer", '
        'DeviceId="${await deviceId}", Version="1.0.0"';
  }

  /// Normalizes user input into a usable base URL.
  static String normalizeUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (!u.contains('://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// Builds an [HttpClient] honoring [allowSelfSigned].
  HttpClient _httpClient({required bool allowSelfSigned}) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    if (allowSelfSigned) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    return client;
  }

  /// GET and decode JSON as `dynamic` — the raw response (a JSON object for
  /// most Jellyfin endpoints, a JSON array for e.g. `/Items/{id}/Ancestors`).
  Future<dynamic> _getJsonRaw(
    String url, {
    required bool allowSelfSigned,
    Map<String, String>? headers,
    int timeoutSeconds = 15,
  }) async {
    final client = _httpClient(allowSelfSigned: allowSelfSigned);
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSeconds));
      headers?.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close().timeout(Duration(seconds: timeoutSeconds));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) {
        throw const JellyfinException('Session expired — sign in again.');
      }
      if (res.statusCode >= 400) {
        throw JellyfinException('Server error ${res.statusCode}');
      }
      return jsonDecode(body);
    } on SocketException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on HandshakeException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on TimeoutException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on FormatException {
      throw const JellyfinException('Server returned an unexpected response.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    required bool allowSelfSigned,
    Map<String, String>? headers,
    int timeoutSeconds = 15,
  }) async {
    final decoded = await _getJsonRaw(
      url,
      allowSelfSigned: allowSelfSigned,
      headers: headers,
      timeoutSeconds: timeoutSeconds,
    );
    return decoded as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(
    String url, {
    required bool allowSelfSigned,
    Map<String, String>? headers,
    Map<String, dynamic>? body,
    int timeoutSeconds = 15,
  }) async {
    final client = _httpClient(allowSelfSigned: allowSelfSigned);
    try {
      final req = await client
          .postUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSeconds));
      headers?.forEach((k, v) => req.headers.set(k, v));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(Duration(seconds: timeoutSeconds));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) {
        throw const JellyfinException('Login failed — check username and password.');
      }
      if (res.statusCode >= 400) {
        throw JellyfinException('Server error ${res.statusCode}');
      }
      if (text.isEmpty) return const {};
      return jsonDecode(text) as Map<String, dynamic>;
    } on SocketException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on HandshakeException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on TimeoutException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on FormatException {
      throw const JellyfinException('Server returned an unexpected response.');
    } finally {
      client.close(force: true);
    }
  }

  /// GET /System/Info/Public — works without authentication.
  Future<JellyfinConnectionInfo> testConnection(String rawUrl, {bool allowSelfSigned = false}) async {
    final url = normalizeUrl(rawUrl);
    if (url.isEmpty) {
      throw const JellyfinException('Enter a server URL.');
    }
    final json = await _getJson('$url/System/Info/Public', allowSelfSigned: allowSelfSigned);
    final serverName = json['ServerName'] as String? ?? json['LocalAddress'] as String? ?? url;
    return JellyfinConnectionInfo(
      serverName: serverName,
      version: json['Version'] as String? ?? '?',
      serverId: json['Id'] as String? ?? url,
    );
  }

  /// POST /Users/AuthenticateByName — returns a server with token + userId.
  Future<JellyfinServer> authenticate(
    JellyfinServer server, {
    required String username,
    required String password,
  }) async {
    if (password.isEmpty) {
      throw const JellyfinException('Enter a password.');
    }
    final json = await _postJson(
      '${server.url}/Users/AuthenticateByName',
      allowSelfSigned: server.allowSelfSigned,
      headers: {
        // Standard `Authorization: MediaBrowser ...` — supported by Jellyfin
        // core since **10.8**, so one code path covers every version.
        //
        // Do NOT send `X-Emby-Authorization` (alone or alongside). Jellyfin
        // 10.12 flipped `EnableLegacyAuthorization` to false by default and
        // 12.0's migration force-disables it even on servers upgraded from
        // 10.x — which makes the legacy header return a bare 400 "Error
        // processing request." before credentials are even examined. Legacy is
        // slated for permanent removal in 10.13+.
        //
        // Sending both is also not safe: there are reports of the
        // legacy+standard combination producing spurious 401s (jellyfin#16086).
        'Authorization': await _authHeader,
        // No token exists yet at login time, so don't send an empty one.
        if (server.token != null && server.token!.isNotEmpty)
          'X-Emby-Token': server.token!,
      },
      body: {'Username': username, 'Pw': password},
    );
    final user = json['User'] as Map<String, dynamic>? ?? const {};
    final token = json['AccessToken'] as String?;
    if (token == null || token.isEmpty) {
      throw const JellyfinException('Login failed — check username and password.');
    }
    return server.copyWith(
      username: username,
      token: token,
      userId: user['Id'] as String?,
    );
  }

  List<JellyfinItem> _itemsFromJson(Map<String, dynamic> json) {
    final items = json['Items'] as List? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinItem.fromJson)
        .where((it) => it.id.isNotEmpty)
        .toList();
  }

  /// Top-level media libraries for the signed-in user.
  Future<List<JellyfinItem>> getLibraries(JellyfinServer server) async {
    final userId = server.userId ?? '';
    final json = await _getJson(
      '${server.url}/Users/$userId/Views?api_key=${server.token}',
      allowSelfSigned: server.allowSelfSigned,
    );
    return _itemsFromJson(json);
  }

  /// Children of a folder/library. Empty [parentId] returns top-level items.
  Future<List<JellyfinItem>> getItems(JellyfinServer server, String parentId) async {
    final userId = server.userId ?? '';
    final uri = Uri.parse('${server.url}/Users/$userId/Items').replace(
      queryParameters: {
        'api_key': server.token ?? '',
        'ParentId': parentId,
        'Recursive': 'false',
        'Fields':
            'MediaSources,Width,Height,IndexNumber,ParentIndexNumber,Chapters',
      },
    );
    final json = await _getJson(uri.toString(), allowSelfSigned: server.allowSelfSigned);
    return _itemsFromJson(json);
  }

  /// Single item by id (external subtitles + chapters included).
  Future<JellyfinItem?> getItem(JellyfinServer server, String itemId) async {
    if (itemId.isEmpty) return null;
    final userId = server.userId ?? '';
    final uri = Uri.parse('${server.url}/Users/$userId/Items/$itemId').replace(
      queryParameters: {
        'api_key': server.token ?? '',
        'Fields': 'MediaSources,Width,Height,Chapters',
      },
    );
    final json = await _getJson(uri.toString(), allowSelfSigned: server.allowSelfSigned);
    return JellyfinItem.fromJson(json);
  }

  static final RegExp _dlnaStreamUrl = RegExp(
    r'^(https?://[^/]+)/dlna/(?:videos|audios)/([0-9a-fA-F-]{32,36})/',
  );

  /// Rewrites a Jellyfin-style DLNA stream URL into the app's direct-play
  /// path when the host matches a saved Jellyfin server. Returns null when
  /// [url] is not a Jellyfin DLNA link or no saved server matches.
  ///
  /// Why: Jellyfin's DLNA endpoint refuses direct-play for items carrying
  /// external subtitles (no subtitle delivery in its default profile) and
  /// falls back to a live HEVC→H.264 MPEG-TS **transcode** (`CI=1`, chunked,
  /// `Accept-Ranges: none`) — unseekable, probe-hostile on both players, and
  /// it silently strips Dolby Vision/HDR. The saved-server path plays the
  /// original container bytes and delivers sidecars as proper sub tracks.
  Future<VideoItem?> upgradeDlnaUrl({
    required String url,
    required String title,
    int? sizeBytes,
  }) async {
    final m = _dlnaStreamUrl.firstMatch(url);
    if (m == null) return null;
    final itemId = m.group(2)!;
    final server = await _serverByOrigin(url);
    if (server == null) {
      return null;
    }
    // Metadata must never block playback: any failure falls back to the raw
    // DLNA URL (same principle as the TMDB resolver).
    try {
      final item = await getItem(server, itemId);
      if (item == null || !item.isPlayable) {
        return null;
      }
      final video = videoItem(server, item);
      return VideoItem(
        id: video.id,
        title: title.isNotEmpty ? title : video.title,
        uri: video.uri,
        resumeKey: video.resumeKey,
        duration: video.duration,
        resolution: video.resolution,
        sizeBytes: sizeBytes ?? video.sizeBytes,
        allowSelfSigned: video.allowSelfSigned,
        jellyfinServerId: video.jellyfinServerId,
        jellyfinItemId: video.jellyfinItemId,
        externalSubtitles: video.externalSubtitles,
        chapters: video.chapters,
      );
    } catch (_) {
      return null;
    }
  }

  /// Matches a URL against saved Jellyfin servers by scheme+host+port (never
  /// by raw string — trailing slashes / default ports must not break the
  /// match). Returns null when nothing matches.
  Future<JellyfinServer?> _serverByOrigin(String url) async {
    String originOf(String raw) {
      final u = Uri.tryParse(raw);
      if (u == null) return '';
      final port = u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80);
      return '${u.scheme}://${u.host}:$port';
    }

    final origin = originOf(url);
    if (origin.isEmpty) return null;
    for (final s in await loadServers()) {
      try {
        if (originOf(s.url) == origin) return s;
      } catch (_) {}
    }
    return null;
  }

  /// A Jellyfin direct-play stream URL handed to "Open in external player":
  /// `/Videos/{itemId}/stream?...` or
  /// `/Videos/{itemId}/{sourceId}/stream?...`. Returns the item id or null
  /// when [url] doesn't match this shape.
  static String? itemIdFromStreamUrl(String url) {
    if (url.isEmpty) return null;
    try {
      final m = _videosStreamUrl.firstMatch(url);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  static final RegExp _videosStreamUrl = RegExp(
    r'^https?://[^/]+/Videos/([^/]+)(?:/[^/]+)?/stream',
  );

  /// Enriches a Jellyfin direct-play URL — the kind Jellyfin hands to
  /// "Open in external player" — with the item's metadata **and external
  /// subtitles** when the host matches a saved Jellyfin server.
  ///
  /// Without this, a video opened from the Jellyfin app via "Open with" /
  /// external player comes in as a bare stream URL with no sidecar subtitle
  /// tracks. Matching the URL back to a saved server + item id lets the app
  /// attach [VideoItem.externalSubtitles] (DeliveryUrls with api_key) the
  /// same way in-app Jellyfin playback does.
  ///
  /// Best-effort: any failure (no saved server, unknown item, network error)
  /// returns null so the caller plays the raw URL — never blocks playback.
  Future<VideoItem?> enrichJellyfinStreamVideoItem({
    required String url,
    required String title,
  }) async {
    if (url.isEmpty) return null;
    final itemId = itemIdFromStreamUrl(url);
    if (itemId == null) return null;
    final server = await _serverByOrigin(url);
    if (server == null) return null;
    try {
      final item = await getItem(server, itemId);
      if (item == null || !item.isPlayable) return null;
      final video = videoItem(server, item);
      return VideoItem(
        id: video.id,
        title: title.isNotEmpty ? title : video.title,
        // Play exactly what Jellyfin handed us — the URL carries a valid
        // token and is what the user actually opened.
        uri: url,
        resumeKey: video.resumeKey,
        duration: video.duration,
        resolution: video.resolution,
        sizeBytes: video.sizeBytes,
        allowSelfSigned: server.allowSelfSigned,
        jellyfinServerId: video.jellyfinServerId,
        jellyfinItemId: video.jellyfinItemId,
        externalSubtitles: video.externalSubtitles,
        chapters: video.chapters,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetches the full metadata (overview, year, genres, rating, artwork URLs)
  /// for a single item — used for library folders bookmarked from the browser
  /// so the home card + details screen can show the show's real info without
  /// waiting on a TMDB lookup.
  Future<JellyfinItemInfo?> getItemInfo(JellyfinServer server, String itemId) async {
    if (itemId.isEmpty) return null;
    final userId = server.userId ?? '';
    final uri = Uri.parse('${server.url}/Users/$userId/Items/$itemId').replace(
      queryParameters: {
        'api_key': server.token ?? '',
        'Fields':
            'Overview,Genres,ProductionYear,CommunityRating,RunTimeTicks,OfficialRating',
      },
    );
    final json = await _getJson(uri.toString(), allowSelfSigned: server.allowSelfSigned);
    return JellyfinItemInfo.fromApi(
      json,
      serverUrl: server.url,
      token: server.token ?? '',
    );
  }

  /// Parent chain of an item (immediate parent first) — season/folder →
  /// series → library. Raw `BaseItemDto` maps (each carries `Id` + `Type`),
  /// or `[]` on any failure. Used to resolve the real Series behind a
  /// bookmarked folder, since a plain Jellyfin folder has no poster of its own.
  Future<List<Map<String, dynamic>>> getItemAncestors(
    JellyfinServer server,
    String itemId,
  ) async {
    if (itemId.isEmpty) return const [];
    try {
      final uri = Uri.parse('${server.url}/Items/$itemId/Ancestors').replace(
        queryParameters: {'api_key': server.token ?? ''},
      );
      final decoded = await _getJsonRaw(
        uri.toString(),
        allowSelfSigned: server.allowSelfSigned,
      );
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList();
      }
      if (decoded is Map<String, dynamic>) {
        return (decoded['Items'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            const [];
      }
      return const [];
    } catch (_) {
      // Best-effort — a failure just means we keep the folder's own info.
      return const [];
    }
  }

  /// The item whose info should represent [itemId] as a bookmark: the item
  /// itself when it is a Series/Movie, otherwise the nearest Series ancestor.
  /// Jellyfin answers `/Items/{folderId}/Images/Primary` with a random child
  /// image for a folder without its own poster, so bookmarking must resolve
  /// the show — otherwise the home card shows a random still from the series
  /// instead of the main poster.
  Future<JellyfinItemInfo?> getPrimaryPosterInfo(
    JellyfinServer server,
    String itemId,
  ) async {
    final info = await getItemInfo(server, itemId);
    if (info == null) return null;
    final posterId = resolvePosterItemId(
      info.type,
      itemId,
      await getItemAncestors(server, itemId),
    );
    if (posterId == itemId || posterId == null) return info;
    final seriesInfo = await getItemInfo(server, posterId);
    return seriesInfo ?? info;
  }

  /// Pure decision logic for [getPrimaryPosterInfo]: which item id carries the
  /// main poster for [ownId]? [ownId] when it is itself a Series/Movie, else
  /// the first Series in the [ancestors] chain, else null (keep the folder's
  /// own info).
  static String? resolvePosterItemId(
    String? ownType,
    String ownId,
    List<Map<String, dynamic>> ancestors,
  ) {
    if (ownType == 'Series' || ownType == 'Movie') return ownId;
    for (final ancestor in ancestors) {
      if (ancestor['Type'] == 'Series') {
        final seriesId = ancestor['Id'] as String?;
        if (seriesId != null && seriesId.isNotEmpty) return seriesId;
      }
    }
    return null;
  }

  /// The saved/authenticated server matching [url] (normalized), or null.
  Future<JellyfinServer?> serverForUrl(String url) async {
    if (url.isEmpty) return null;
    final servers = await loadServers();
    for (final s in servers) {
      if (s.url == url) return s;
    }
    return null;
  }

  /// A playable item as a [VideoItem] ready for the player/details screen.
  VideoItem videoItem(JellyfinServer server, JellyfinItem item) {
    // Build full delivery URLs for external subtitles. Jellyfin's
    // DeliveryUrl is a relative path without the token — append api_key
    // so Media3 / AetherEngine can fetch it without extra headers.
    final externalSubsRaw = item.externalSubtitles.map((sub) {
      String url;
      if (sub.deliveryUrl.isNotEmpty) {
        url = sub.deliveryUrl.startsWith('http')
            ? sub.deliveryUrl
            : '${server.url}${sub.deliveryUrl}';
        if (!url.contains('api_key=')) {
          url += url.contains('?') ? '&' : '?';
          url += 'api_key=${server.token ?? ''}';
        }
      } else {
        url = '${server.url}/Videos/${item.id}/${item.mediaSourceId ?? item.id}'
            '/Subtitles/${sub.index}/Stream.${sub.extension}'
            '?api_key=${server.token ?? ''}';
      }
      return VideoExternalSub(
        uri: url,
        label: sub.displayTitle,
        language: sub.language,
        mimeType: sub.mimeType,
        isDefault: sub.isDefault,
      );
    }).toList();
    // **External > embedded always.** [promoteFirstExternalAsDefault] is
    // also called at the `open()` site in the player screen, but doing
    // it here too means the CC sheet's track-list reflects the correct
    // default before the engine ever sees the payload (helpful for
    // pre-resolution UI work and for tests).
    final externalSubs = promoteFirstExternalAsDefault(externalSubsRaw);
    return VideoItem(
      id: 'jellyfin_${server.urlHost}_${item.id}',
      title: item.name,
      uri: streamUrl(server, item),
      resumeKey: resumeKey(server, item),
      duration: item.duration,
      resolution: item.resolution,
      allowSelfSigned: server.allowSelfSigned,
      jellyfinServerId: server.urlHost,
      jellyfinItemId: item.id,
      externalSubtitles: externalSubs,
      chapters: item.chapters,
    );
  }

  /// Direct-play stream URL (token as `api_key`). Plays via the existing HTTP
  /// data sources on both platforms; [allowSelfSigned] is honored through the
  /// same opt-in permissive path as self-signed WebDAV.
  String streamUrl(JellyfinServer server, JellyfinItem item) {
    final base = item.mediaType == 'Audio'
        ? '${server.url}/Audio/${item.id}/stream'
        : '${server.url}/Videos/${item.id}/stream';
    final uri = Uri.parse(base).replace(queryParameters: {
      'static': 'true',
      'mediaSourceId': item.mediaSourceId ?? item.id,
      'api_key': server.token ?? '',
    });
    return uri.toString();
  }

  /// Server-transcoded HLS URL. The Jellyfin backend re-encodes the file to
  /// H.264 + a broadly-supported audio codec in an HLS live playlist, so files
  /// whose codecs the device can't decode natively still play. Hitting
  /// `master.m3u8` directly starts the transcode job — no PlaybackInfo round
  /// trip needed. [maxBitrateBps] caps the output quality; [devId] tags the
  /// server-side job so [stopActiveEncoding] can find it later.
  String transcodeUrl(
    JellyfinServer server,
    JellyfinItem item, {
    required String devId,
    int maxBitrateBps = defaultTranscodeBitrateBps,
  }) {
    final uri = Uri.parse('${server.url}/Videos/${item.id}/master.m3u8')
        .replace(queryParameters: {
      'MediaSourceId': item.mediaSourceId ?? item.id,
      'DeviceId': devId,
      'VideoCodec': 'h264',
      // AAC first; AC3/EAC3 kept for receivers that accept them without a
      // full re-encode on the audio leg.
      'AudioCodec': 'aac,ac3,eac3,mp3',
      'VideoBitrate': '$maxBitrateBps',
      'MaxStreamingBitrate': '$maxBitrateBps',
      'TranscodeReasons': 'CodecNotSupported',
      'api_key': server.token ?? '',
    });
    return uri.toString();
  }

  /// Default transcode ceiling: ~20 Mbps covers most 1080p sources without
  /// hammering the server CPU.
  static const int defaultTranscodeBitrateBps = 20000000;

  /// Stable per-install device id so this client's server-side transcode jobs
  /// can be identified and stopped ([stopActiveEncoding]).
  Future<String> get deviceId async {
    final prefs = await _sharedPrefs;
    var id = prefs.getString(_deviceIdKey);
    if (id == null || id.isEmpty) {
      id = 'dp${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  /// Builds the direct-play [VideoItem] for [item] as a server-transcoded
  /// fallback: same identity/resume key, but the playable URI is the HLS
  /// master playlist. Returns null when [video] isn't a Jellyfin item or its
  /// server is no longer saved (nothing to fall back to).
  Future<VideoItem?> transcodeFallbackFor(VideoItem video) async {
    final itemId = video.jellyfinItemId;
    final serverId = video.jellyfinServerId;
    if (itemId == null || itemId.isEmpty || serverId == null) return null;
    final servers = await loadServers();
    JellyfinServer? server;
    for (final s in servers) {
      if (s.urlHost == serverId && s.isAuthenticated) {
        server = s;
        break;
      }
    }
    if (server == null) return null;
    final item = JellyfinItem(id: itemId, name: video.title);
    return VideoItem(
      id: video.id,
      title: video.title,
      uri: transcodeUrl(server, item, devId: await deviceId),
      resumeKey: video.resumeKey,
      duration: video.duration,
      sizeBytes: video.sizeBytes,
      resolution: video.resolution,
      allowSelfSigned: server.allowSelfSigned,
      jellyfinServerId: serverId,
      jellyfinItemId: itemId,
    );
  }

  /// Best-effort stop of this device's server-side transcode job(s). Called
  /// when a transcoded playback session closes so the server stops burning
  /// CPU on a stream nobody is watching.
  Future<void> stopActiveEncoding(String serverUrl) async {
    try {
      final id = await deviceId;
      final client = _httpClient(allowSelfSigned: false);
      try {
        final req = await client.deleteUrl(
          Uri.parse('$serverUrl/Videos/ActiveEncodings')
              .replace(queryParameters: {'DeviceId': id}),
        );
        final token = (await serverForUrl(serverUrl))?.token;
        if (token != null && token.isNotEmpty) {
          req.headers.set('X-Emby-Token', token);
        }
        await req.close().timeout(const Duration(seconds: 5));
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // Best-effort — the job also dies when the session times out.
    }
  }

  /// True when [uri] points at a Jellyfin transcode playlist rather than a
  /// direct stream (used to avoid retrying the fallback twice).
  static bool isTranscodeUri(String? uri) =>
      uri != null && uri.contains('master.m3u8');

  static const _deviceIdKey = 'dreamplayer.jellyfinDeviceId';

  /// Stable resume key for a Jellyfin item, surviving session token rotation.
  String resumeKey(JellyfinServer server, JellyfinItem item) =>
      'jellyfin:${server.urlHost}/${item.id}';

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<List<JellyfinServer>> loadServers() async {
    final prefs = await _sharedPrefs;
    final raw = prefs.getString(_serversKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map<String, dynamic>>()
          .map(JellyfinServer.fromJson)
          .where((s) => s.url.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveServers(List<JellyfinServer> servers) async {
    final prefs = await _sharedPrefs;
    await prefs.setString(
      _serversKey,
      jsonEncode(servers.map((s) => s.toJson()).toList()),
    );
  }

  static const _folderMetaKey = 'dreamplayer.jellyfinFolderMeta';

  /// Cached metadata for every library folder bookmarked from the browser,
  /// keyed by the folder's `LibraryFolder.id` (`jellyfin_folder_<host>_<item>`).
  Future<Map<String, JellyfinItemInfo>> loadAllFolderMeta() async {
    final prefs = await _sharedPrefs;
    final raw = prefs.getString(_folderMetaKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final result = <String, JellyfinItemInfo>{};
      for (final entry in map.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          final info = JellyfinItemInfo.fromJson(value);
          if (info.id.isNotEmpty || info.name.isNotEmpty) {
            result[entry.key] = info;
          }
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveFolderMeta(String folderId, JellyfinItemInfo info) async {
    final all = await loadAllFolderMeta();
    all[folderId] = info;
    final prefs = await _sharedPrefs;
    await prefs.setString(
      _folderMetaKey,
      jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  Future<void> removeFolderMeta(String folderId) async {
    final all = await loadAllFolderMeta();
    if (all.remove(folderId) == null) return;
    final prefs = await _sharedPrefs;
    await prefs.setString(
      _folderMetaKey,
      jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  // ---------------------------------------------------------------------------
  // Discovery: Jellyfin UDP-7359 broadcast probe + mDNS (_jellyfin._tcp /
  // _emby._tcp for legacy Emby — Jellyfin removed its mDNS responder, so the
  // broadcast probe is the reliable path for a modern server).
  // ---------------------------------------------------------------------------

  /// Scans the local network for Jellyfin/Emby servers. Returns reachable
  /// servers (unauth'd).
  Future<List<JellyfinServer>> discoverServers() async {
    final probeResults = <String, String>{}; // url -> server name (7359 probe)
    final mdnsResults = <String, (String, int)>{}; // address:port (mDNS)
    var lockHeld = false;
    try {
      lockHeld = await _multicastAcquired();
      final probe = await _jellyfinProbe();
      for (final hit in probe) {
        final url = hit['address'] as String?;
        if (url == null || url.isEmpty) continue;
        final name = hit['name'] as String? ?? url;
        probeResults[url] = name;
      }
    } catch (_) {}

    // mDNS discovery — multicast_dns may throw MissingPluginException on
    // platforms without native mDNS; the try/catch handles that gracefully,
    // and the 7359 broadcast probe above is the primary discovery path for
    // modern Jellyfin servers anyway.
    try {
      final resolver = MDnsClient();
      try {
        await resolver.start().timeout(const Duration(seconds: 3));
        for (final service in const ['_jellyfin._tcp', '_emby._tcp']) {
          try {
            await for (final ptr
                in resolver.lookup<PtrResourceRecord>(
                      ResourceRecordQuery.serverPointer(service),
                      timeout: const Duration(seconds: 2),
                    )) {
              await _resolveService(resolver, ptr.name, mdnsResults);
              await _resolveService(resolver, ptr.domainName, mdnsResults);
            }
          } catch (_) {}
        }
      } catch (_) {
        // Multicast may be unavailable (Android Wi-Fi, no network). Return what
        // was found so far — manual add remains the fallback.
      } finally {
        if (lockHeld) {
          await _multicastReleased();
        }
        try {
          resolver.stop();
        } catch (_) {}
      }
    } catch (_) {}

    final servers = <JellyfinServer>[];
    final seen = <String>{};
    for (final entry in probeResults.entries) {
      if (seen.add(entry.key)) {
        servers.add(JellyfinServer(
          name: entry.value,
          url: entry.key,
          autoDiscovered: true,
        ));
      }
    }
    for (final (address, port) in mdnsResults.values) {
      final url = 'http://$address:$port';
      if (seen.add(url)) {
        try {
          final info = await testConnection(url).timeout(
            const Duration(seconds: 3),
            onTimeout: () => throw const JellyfinException('timeout'),
          );
          servers.add(JellyfinServer(
            name: info.serverName,
            url: url,
            autoDiscovered: true,
          ));
        } catch (_) {
          // Unreachable/unauth'd probe — skip.
        }
      }
    }
    servers.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return servers;
  }

  /// Runs the native UDP-7359 broadcast probe ("who is JellyfinServer?") on
  /// Android (`MulticastLockManager.kt`) / iOS (`JellyfinDiscovery.swift`).
  /// Returns [{address, name, id}].
  static Future<List<Map<dynamic, dynamic>>> _jellyfinProbe() async {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      try {
        final res =
            await _multicastChannel.invokeListMethod<dynamic>('discoverJellyfin');
        if (res != null) {
          return res.whereType<Map<dynamic, dynamic>>().toList();
        }
      } catch (_) {}
    }
    return const [];
  }

  /// Resolves the SRV + A records for an mDNS service instance name and records
  /// every reachable `address:port` pair. SRV targets that are bare IPs are
  /// used directly (no A lookup possible for an address literal).
  Future<void> _resolveService(
    MDnsClient resolver,
    String instanceName,
    Map<String, (String, int)> found,
  ) async {
    try {
      await for (final srv
          in resolver.lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(instanceName),
                timeout: const Duration(seconds: 2),
              )) {
        final target = srv.target.replaceAll(RegExp(r'\.$'), '');
        final isIp = InternetAddress.tryParse(target) != null;
        if (isIp) {
          found['$target:${srv.port}'] = (target, srv.port);
          continue;
        }
        try {
          await for (final ip
              in resolver.lookup<IPAddressResourceRecord>(
                    ResourceRecordQuery.addressIPv4(srv.target),
                    timeout: const Duration(seconds: 2),
                  )) {
            found['${ip.address.address}:${srv.port}'] = (
              ip.address.address,
              srv.port,
            );
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  static final MethodChannel _multicastChannel =
      MethodChannel('dreamplayer/multicast');

  /// Holds the Android Wi-Fi MulticastLock for the duration of an mDNS scan.
  /// Without it the Wi-Fi driver drops multicast frames so discovery finds
  /// nothing. Non-Android platforms (no channel registered) report false.
  static Future<bool> _multicastAcquired() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _multicastChannel.invokeMethod<void>('acquire');
        return true;
      } catch (_) {}
    }
    return false;
  }

  static Future<void> _multicastReleased() async {
    try {
      await _multicastChannel.invokeMethod<void>('release');
    } catch (_) {}
  }

  /// Maps low-level IO errors to plain-language messages.
  static String friendlyError(Object e) {
    if (e is HandshakeException) {
      return 'Certificate not trusted — enable "Allow self-signed".';
    }
    if (e is SocketException) {
      return 'Can\'t connect — check the address.';
    }
    if (e is TimeoutException) {
      return 'Timed out — is the server on and the port right?';
    }
    if (e is JellyfinException) return e.message;
    return 'Something went wrong ($e)';
  }
}
