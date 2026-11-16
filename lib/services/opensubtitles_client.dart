import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/opensubtitles_api_key.dart';

/// Thrown for OpenSubtitles API errors with a user-friendly message.
class OpensubtitlesException implements Exception {
  OpensubtitlesException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// A single search hit from `GET /api/v1/subtitles`.
class OpensubtitlesResult {
  const OpensubtitlesResult({
    required this.fileId,
    required this.fileName,
    required this.language,
    required this.downloads,
    required this.ratings,
    required this.url,
    this.release,
    this.comments,
    this.uploaderName,
    this.featureType,
  });

  final int fileId;
  final String fileName;
  final String language; // e.g. 'en'
  final int downloads;
  final double ratings;
  final String url; // not the download link - use POST /download
  final String? release;
  final String? comments;
  final String? uploaderName;
  final String? featureType;

  factory OpensubtitlesResult.fromJson(Map<String, dynamic> j) {
    final attrs = j['attributes'] as Map<String, dynamic>? ?? const {};
    final files = attrs['files'] as List? ?? const [];
    final file = files.isNotEmpty ? files.first as Map<String, dynamic> : <String, dynamic>{};
    return OpensubtitlesResult(
      fileId: (file['file_id'] as num?)?.toInt() ?? 0,
      fileName: file['file_name'] as String? ?? '',
      language: attrs['language'] as String? ?? '',
      downloads: (attrs['download_count'] as num?)?.toInt() ?? 0,
      ratings: (attrs['ratings'] as num?)?.toDouble() ?? 0,
      url: attrs['url'] as String? ?? '',
      release: attrs['release'] as String?,
      comments: attrs['comments'] as String?,
      uploaderName: (attrs['uploader'] as Map?)?['name'] as String?,
      featureType: attrs['feature_type'] as String?,
    );
  }
}

/// Persistent token cache (24h). Anonymous downloads don't call login.
class _TokenCache {
  String? token;
  DateTime? expiry;
  bool get isValid => token != null && expiry != null && DateTime.now().isBefore(expiry!);
}

/// Single HttpClient, keep-alive, 15s connect / 30s read.
class OpensubtitlesClient {
  OpensubtitlesClient._();
  static final instance = OpensubtitlesClient._();

  static const _host = 'api.opensubtitles.com';
  static const _userAgent = 'DreamPlayer/0.2.6';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30);

  final _tokenCache = _TokenCache();
  String? _cachedUsername;
  bool _didLoadPersisted = false;

  String get _apiKey => opensubtitlesDefaultApiKey;

  bool get hasApiKey => _apiKey.isNotEmpty;
  String? get username => _cachedUsername;
  bool get isLoggedIn => _tokenCache.isValid;

  static const _prefToken = 'dreamplayer.opensubtitlesToken';
  static const _prefUser = 'dreamplayer.opensubtitlesUser';
  static const _prefExpiry = 'dreamplayer.opensubtitlesExpiryMs';

  Future<void> _ensureLoaded() async {
    if (_didLoadPersisted) return;
    _didLoadPersisted = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final tok = prefs.getString(_prefToken);
      final exp = prefs.getInt(_prefExpiry);
      final user = prefs.getString(_prefUser);
      if (tok != null && tok.isNotEmpty && exp != null) {
        final expiry = DateTime.fromMillisecondsSinceEpoch(exp);
        if (DateTime.now().isBefore(expiry)) {
          _tokenCache.token = tok;
          _tokenCache.expiry = expiry;
          _cachedUsername = user;
        }
      }
    } catch (_) {}
  }

  Map<String, String> _headers({String? bearer}) => {
        'Api-Key': _apiKey,
        'User-Agent': _userAgent,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (bearer != null && bearer.isNotEmpty) 'Authorization': 'Bearer $bearer',
      };

  Future<Map<String, dynamic>> _getJson(Uri uri, {String? bearer}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final req = await _client.getUrl(uri);
        _headers(bearer: bearer).forEach(req.headers.set);
        final resp = await req.close().timeout(const Duration(seconds: 30));
        final body = await resp.transform(utf8.decoder).join();
        if (resp.statusCode >= 400) {
          final msg = _friendlyGetError(resp.statusCode, body);
          throw OpensubtitlesException(msg, statusCode: resp.statusCode);
        }
        return jsonDecode(body) as Map<String, dynamic>;
      } on SocketException catch (e) {
        if (attempt == 1) throw OpensubtitlesException('Network error - check connection and retry (${e.osError?.message ?? e.message})');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      } on TimeoutException {
        if (attempt == 1) throw OpensubtitlesException('Search timed out - retry');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    throw OpensubtitlesException('Network error - retry');
  }

  Future<Map<String, dynamic>> _postJson(Uri uri, Map<String, dynamic> payload,
      {String? bearer}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final req = await _client.postUrl(uri);
        _headers(bearer: bearer).forEach(req.headers.set);
        req.write(jsonEncode(payload));
        final resp = await req.close().timeout(const Duration(seconds: 30));
        final body = await resp.transform(utf8.decoder).join();
        if (resp.statusCode >= 400) {
          final msg = _friendlyPostError(resp.statusCode, body);
          throw OpensubtitlesException(msg, statusCode: resp.statusCode);
        }
        return body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
      } on SocketException catch (e) {
        if (attempt == 1) throw OpensubtitlesException('Network error - check connection and retry (${e.osError?.message ?? e.message})');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      } on TimeoutException {
        if (attempt == 1) throw OpensubtitlesException('Download timed out - retry');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    throw OpensubtitlesException('Network error - retry');
  }

  String _friendlyGetError(int code, String body) {
    try {
      final j = jsonDecode(body) as Map;
      final m = j['message'] as String?;
      if (m != null && m.isNotEmpty) return m;
    } catch (_) {}
    if (code == 401) return 'Invalid API key - check OPENSUBTITLES_API_KEY';
    if (code == 429) return 'Too many requests - try again shortly';
    return 'Search failed ($code)';
  }

  String _friendlyPostError(int code, String body) {
    try {
      final j = jsonDecode(body) as Map;
      final m = j['message'] as String?;
      if (m != null && m.isNotEmpty) {
        if (m.toLowerCase().contains('quota') || m.toLowerCase().contains('download limit')) {
          return 'Daily download limit reached - sign in for 20/day (or wait 24h for anonymous 5/day)';
        }
        return m;
      }
    } catch (_) {}
    if (code == 401) return 'Sign in required for this download (daily anonymous limit reached)';
    if (code == 403) return 'Daily download limit reached - sign in for 20/day';
    if (code == 429) return 'Too many requests - try again shortly';
    return 'Download failed ($code)';
  }

  // --- Auth ---

  /// Login and cache JWT (~24h). Throws on bad credentials.
  Future<String> login({required String username, required String password}) async {
    if (!hasApiKey) throw OpensubtitlesException('Missing OPENSUBTITLES_API_KEY');
    if (username.isEmpty || password.isEmpty) throw OpensubtitlesException('Enter username and password');
    final uri = Uri.https(_host, '/api/v1/login');
    final j = await _postJson(uri, {'username': username, 'password': password});
    final token = j['token'] as String? ?? '';
    if (token.isEmpty) throw OpensubtitlesException('Login failed - check username/password');
    _tokenCache.token = token;
    _tokenCache.expiry = DateTime.now().add(const Duration(hours: 23));
    _cachedUsername = username;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefToken, token);
      await prefs.setInt(_prefExpiry, _tokenCache.expiry!.millisecondsSinceEpoch);
      await prefs.setString(_prefUser, username);
    } catch (_) {}
    return token;
  }

  String? get cachedToken => _tokenCache.isValid ? _tokenCache.token : null;

  Future<void> logout() async {
    _tokenCache.token = null;
    _tokenCache.expiry = null;
    _cachedUsername = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefToken);
      await prefs.remove(_prefExpiry);
      await prefs.remove(_prefUser);
    } catch (_) {}
  }

  /// Fetch user info (remaining downloads etc.) - requires login.
  Future<Map<String, dynamic>> fetchUserInfo() async {
    await _ensureLoaded();
    final tok = cachedToken;
    if (tok == null) throw OpensubtitlesException('Not signed in');
    final uri = Uri.https(_host, '/api/v1/infos/user');
    return _getJson(uri, bearer: tok);
  }

  // --- Search ---

  /// Search by filename/query. `languages` is e.g. 'en' or 'en,hi'.
  Future<List<OpensubtitlesResult>> search({
    required String query,
    String languages = 'en',
    String? movieHash,
    int page = 1,
  }) async {
    await _ensureLoaded();
    if (!hasApiKey) throw OpensubtitlesException('Missing OPENSUBTITLES_API_KEY - add it to .env');
    if (query.trim().isEmpty && (movieHash == null || movieHash.isEmpty)) {
      throw OpensubtitlesException('Enter a search term');
    }
    final langs = languages.trim().isEmpty ? 'en' : languages.trim();
    final params = <String, String>{
      'languages': langs,
      'order_by': 'download_count',
      'order_direction': 'desc',
      'page': '$page',
    };
    final q = query.trim();
    if (q.isNotEmpty) params['query'] = q;
    if (movieHash != null && movieHash.isNotEmpty) {
      params['moviehash'] = movieHash;
    }
    Future<List<OpensubtitlesResult>> fetch(Map<String, String> p) async {
      final uri = Uri.https(_host, '/api/v1/subtitles', p);
      final j = await _getJson(uri, bearer: cachedToken);
      final data = j['data'] as List? ?? const [];
      return data.map((e) => OpensubtitlesResult.fromJson(e as Map<String, dynamic>)).where((r) => r.fileId != 0).toList();
    }

    final res = await fetch(params);
    // Hash-exact search often returns 0 hits even though query matches exist.
    // Fall back to query-only so the CC → Search flow never shows "No results"
    // just because the file hash is unknown on OpenSubtitles.
    if (res.isEmpty && params.containsKey('moviehash') && params.containsKey('query')) {
      final fallback = Map<String, String>.from(params)..remove('moviehash');
      return fetch(fallback);
    }
    return res;
  }

  // --- Download ---

  /// `POST /api/v1/download` → temporary `link`. Anonymous: just Api-Key (5/day).
  /// Authenticated: also Bearer. Throws with quota message when exhausted.
  Future<DownloadInfo> requestDownload(int fileId, {String? bearer}) async {
    await _ensureLoaded();
    if (!hasApiKey) throw OpensubtitlesException('Missing OPENSUBTITLES_API_KEY');
    if (fileId == 0) throw OpensubtitlesException('Invalid subtitle');
    final uri = Uri.https(_host, '/api/v1/download');
    final token = bearer ?? cachedToken;
    final j = await _postJson(uri, {'file_id': fileId}, bearer: token);
    final link = j['link'] as String? ?? '';
    if (link.isEmpty) throw OpensubtitlesException('No download link returned');
    return DownloadInfo(
      link: link,
      fileName: j['file_name'] as String? ?? 'subtitle.srt',
      remaining: (j['remaining'] as num?)?.toInt(),
      resetTime: j['reset_time'] as String?,
    );
  }

  /// Fetch the temporary `link` URL to bytes. Link needs no auth headers.
  /// Retries once on transient `SocketException` (CDN RST on pooled keep-alive).
  Future<List<int>> fetchBytes(String link) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final uri = Uri.parse(link);
        final req = await _client.getUrl(uri);
        req.headers.set('User-Agent', _userAgent);
        req.headers.set('Accept', '*/*');
        // dl.* does not need Api-Key; keep connection short-lived.
        req.persistentConnection = false;
        final resp = await req.close().timeout(const Duration(seconds: 30));
        if (resp.statusCode >= 400) throw OpensubtitlesException('Subtitle download failed (${resp.statusCode})');
        final bytes = <int>[];
        await for (final chunk in resp) {
          bytes.addAll(chunk);
        }
        if (bytes.isEmpty) throw OpensubtitlesException('Empty subtitle file');
        return bytes;
      } on SocketException catch (e) {
        if (attempt == 1) throw OpensubtitlesException('Network error - check connection and retry (${e.osError?.message ?? e.message})');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      } on TimeoutException {
        if (attempt == 1) throw OpensubtitlesException('Download timed out - retry');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    throw OpensubtitlesException('Network error - retry');
  }

  void dispose() => _client.close(force: true);
}

class DownloadInfo {
  const DownloadInfo({required this.link, required this.fileName, this.remaining, this.resetTime});
  final String link;
  final String fileName;
  final int? remaining;
  final String? resetTime;
}

/// File name stems that OpenSubtitles returns for files the uploader didn't
/// name meaningfully - numeric upload ids (`1324.srt`) or boilerplate. These
/// would otherwise surface in the CC sheet as "1324" or "Subtitle".
const Set<String> _meaninglessSubtitleStems = {
  'subtitle',
  'subtitles',
  'sub',
  'download',
  'downloads',
  'unknown',
  'undefined',
  'mysubtitles',
};

/// True when an OpenSubtitles `file_name` stem is a meaningless upload id
/// (numeric/symbolic only) or generic boilerplate rather than a real name.
bool _isMeaninglessSubtitleName(String stem) {
  final s = stem.trim().toLowerCase();
  if (s.isEmpty) return true;
  if (_meaninglessSubtitleStems.contains(s)) return true;
  return !RegExp(r'[a-zA-Z]').hasMatch(s);
}

/// Derives a human-friendly file name for a downloaded subtitle when the
/// OpenSubtitles API's `file_name` is a meaningless upload id (e.g. `1324.srt`)
/// or generic boilerplate - the "Random 4-digit number.srt" users see in the
/// subtitle picker. Real, informative names pass through untouched.
///
/// The derived name is built from the [videoTitle] (cleaned to file-safe
/// characters) plus the [language] tag and the original extension. Pass the
/// result to [DownloadedSubtitlesStore.saveForVideo] so both the persisted
/// file name and every downstream label (CC sheet, native track label) read
/// as the *exact* subtitle name instead of a random id.
String meaningfulSubtitleFileName({
  required String apiFileName,
  required String language,
  required String videoTitle,
}) {
  final dot = apiFileName.lastIndexOf('.');
  final ext = (dot >= 0 ? apiFileName.substring(dot + 1) : 'srt').toLowerCase();
  final stem = dot >= 0 ? apiFileName.substring(0, dot) : apiFileName;
  if (!_isMeaninglessSubtitleName(stem)) return apiFileName;

  var base = videoTitle.trim();
  if (base.isEmpty) base = 'Subtitle';
  base = base.replaceAll(RegExp(r'[^\w. -]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final underscored = base.replaceAll(' ', '_');
  const validExt = {'srt', 'ass', 'ssa', 'vtt', 'ttml', 'dfxp', 'sami', 'smi', 'sub', 'sbv'};
  final fixedExt = validExt.contains(ext) ? ext : 'srt';
  final lang = language.trim().toLowerCase();
  if (lang.isNotEmpty && !underscored.toLowerCase().endsWith('.$lang')) {
    return '$underscored.$lang.$fixedExt';
  }
  return '$underscored.$fixedExt';
}

/// Strips a file name down to its display label (base without the last
/// extension): `Star_Wars.eng.srt` → `Star_Wars.eng`. Used by the CC sheet's
/// Downloaded section so the label matches the native track name.
String subtitleFileNameLabel(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return fileName;
  return fileName.substring(0, dot);
}

/// OpenSubtitles file hash (64-bit, first+last 64KiB). Matches the API's
/// `moviehash` param for exact-file matches.
Future<String?> opensubtitlesHashForFile(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    final len = await f.length();
    if (len < 131072) return null;
    final raf = await f.open(mode: FileMode.read);
    try {
      const chunk = 64 * 1024;
      final head = await raf.read(chunk);
      await raf.setPosition(len - chunk);
      final tail = await raf.read(chunk);
      int hash = len;
      int read64(List<int> b, int off) {
        return (b[off] & 0xFF) |
            ((b[off + 1] & 0xFF) << 8) |
            ((b[off + 2] & 0xFF) << 16) |
            ((b[off + 3] & 0xFF) << 24) |
            ((b[off + 4] & 0xFF) << 32) |
            ((b[off + 5] & 0xFF) << 40) |
            ((b[off + 6] & 0xFF) << 48) |
            ((b[off + 7] & 0xFF) << 56);
      }

      for (var i = 0; i < head.length; i += 8) {
        if (i + 8 > head.length) break;
        hash = (hash + read64(head, i)) & 0xFFFFFFFFFFFFFFFF;
      }
      for (var i = 0; i < tail.length; i += 8) {
        if (i + 8 > tail.length) break;
        hash = (hash + read64(tail, i)) & 0xFFFFFFFFFFFFFFFF;
      }
      return hash.toRadixString(16).padLeft(16, '0');
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
}
