import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/simkl_keys.dart';

/// A single item to mark watched on SIMKL (via POST /sync/history).
class SimklWatchItem {
  const SimklWatchItem({
    required this.tmdbId,
    required this.isTv,
    this.season,
    this.episode,
    this.watchedAt,
  });

  final int tmdbId;
  final bool isTv;
  final int? season;
  final int? episode;
  final DateTime? watchedAt;
}

/// PIN-flow code shown to the user so they can authorize at https://simkl.com/pin.
class SimklPinCode {
  const SimklPinCode({
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
  });

  final String userCode;
  final String verificationUrl;
  final int expiresIn;
  final int interval;
}

class SimklException implements Exception {
  const SimklException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Snapshot of watched state pulled from SIMKL.
class SimklWatched {
  const SimklWatched({
    this.movieIds = const {},
    this.showSeasons = const {},
  });

  final Set<int> movieIds;
  /// tmdbShowId -> (seasonNumber -> watched episode count)
  final Map<int, Map<int, int>> showSeasons;

  bool isEpisodeWatched(int showId, int season, int episode) {
    final seasons = showSeasons[showId];
    if (seasons == null) return false;
    final count = seasons[season];
    return count != null && episode > 0 && episode <= count;
  }
}

class SimklClient {
  SimklClient([this._prefs]);

  static const String _prefsKey = 'dreamplayer.simkl';
  static const String _base = 'https://api.simkl.com';
  static const String _appName = 'DreamPlayer';
  static const String _appVersion = '0.3.1';
  static const String _userAgent = 'DreamPlayer/0.3.1';

  final SharedPreferences? _prefs;
  SharedPreferences? _cachedPrefs;

  Future<SharedPreferences> get _sharedPrefs async =>
      _cachedPrefs ??= _prefs ?? await SharedPreferences.getInstance();

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  bool get isConfigured => simklClientId.isNotEmpty;

  // MARK: - Persistence

  Future<Map<String, dynamic>> _load() async {
    final prefs = await _sharedPrefs;
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, dynamic> data) async {
    final prefs = await _sharedPrefs;
    await prefs.setString(_prefsKey, jsonEncode(data));
  }

  Future<String?> _accessToken() async {
    final data = await _load();
    return data['accessToken'] as String?;
  }

  /// SIMKL tokens are long-lived (~5 years). No refresh grant; treat expiry as sign-out.
  Future<bool> isAuthenticated() async {
    if (!isConfigured) return false;
    final data = await _load();
    final token = data['accessToken'] as String?;
    if (token == null || token.isEmpty) return false;
    final expiresAt = (data['expiresAt'] as num?)?.toInt() ?? 0;
    if (expiresAt > 0 && DateTime.now().millisecondsSinceEpoch > expiresAt) {
      return false;
    }
    return true;
  }

  Future<DateTime?> lastSyncAt() async {
    final data = await _load();
    final ms = (data['lastSyncAt'] as num?)?.toInt();
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> signOut() async {
    final prefs = await _sharedPrefs;
    await prefs.remove(_prefsKey);
  }

  // MARK: - PIN flow

  Future<SimklPinCode> requestPinCode() async {
    if (!isConfigured) {
      throw const SimklException('SIMKL is not configured (missing client id).');
    }
    final uri = _uri('/oauth/pin', {});
    try {
      final req = await _client.getUrl(uri).timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) {
        throw SimklException(_friendlyStatus(res.statusCode, body));
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final userCode = json['user_code'] as String? ?? '';
      if (userCode.isEmpty) {
        throw const SimklException('SIMKL did not return a PIN code.');
      }
      return SimklPinCode(
        userCode: userCode,
        verificationUrl:
            json['verification_url'] as String? ?? json['verification_uri'] as String? ?? 'https://simkl.com/pin',
        expiresIn: (json['expires_in'] as num?)?.toInt() ?? 900,
        interval: (json['interval'] as num?)?.toInt() ?? 5,
      );
    } on SimklException {
      rethrow;
    } on SocketException {
      throw const SimklException("Can't reach SIMKL - check your connection.");
    } on TimeoutException {
      throw const SimklException('SIMKL request timed out.');
    } on FormatException {
      throw const SimklException('SIMKL returned an unexpected response.');
    }
  }

  /// Polls GET /oauth/pin/{userCode} until the user approves or the code expires.
  Future<bool> pollForToken(SimklPinCode code) async {
    final deadline = DateTime.now().add(Duration(seconds: code.expiresIn));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: code.interval));
      try {
        final uri = _uri('/oauth/pin/${Uri.encodeComponent(code.userCode)}', {});
        final req = await _client.getUrl(uri).timeout(const Duration(seconds: 15));
        req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        final res = await req.close().timeout(const Duration(seconds: 30));
        final body = await res.transform(utf8.decoder).join();
        if (res.statusCode >= 400) {
          throw SimklException(_friendlyStatus(res.statusCode, body));
        }
        final json = jsonDecode(body) as Map<String, dynamic>;
        // Pending: {"result":"KO","message":"Authorization pending"}
        if (json['result'] == 'KO') continue;
        // The server deleted the code and re-created a fresh one when polled
        // after success; detection is a response containing device_code.
        if (json.containsKey('device_code') && json['access_token'] == null) {
          return false;
        }
        final token = json['access_token'] as String?;
        if (token != null && token.isNotEmpty) {
          final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 157680000;
          await _persistToken({'access_token': token, 'expires_in': expiresIn});
          return true;
        }
        // Still pending without explicit KO - continue.
      } on SimklException {
        rethrow;
      } on SocketException {
        // Transient - keep polling until deadline.
        continue;
      } on TimeoutException {
        continue;
      } on FormatException {
        continue;
      }
    }
    return false;
  }

  /// OAuth authorization_code exchange (for browser-based flow via url_launcher).
  /// Call after the deep-link delivers `code`.
  Future<void> exchangeCode(String code, {String? redirectUri}) async {
    if (!isConfigured) {
      throw const SimklException('SIMKL is not configured (missing client id).');
    }
    final body = <String, dynamic>{
      'code': code,
      'client_id': simklClientId,
      'grant_type': 'authorization_code',
      if (simklClientSecret.isNotEmpty) 'client_secret': simklClientSecret,
      if (redirectUri != null && redirectUri.isNotEmpty) 'redirect_uri': redirectUri,
    };
    final res = await _post('/oauth/token', body: body, auth: false);
    await _persistToken(res);
  }

  Future<void> _persistToken(Map<String, dynamic> body) async {
    final accessToken = body['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw const SimklException('No access token returned.');
    }
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 0;
    final data = await _load();
    data['accessToken'] = accessToken;
    // SIMKL has no refresh token.
    if (body['refresh_token'] != null) data['refreshToken'] = body['refresh_token'];
    data['expiresAt'] = expiresIn > 0
        ? DateTime.now().millisecondsSinceEpoch + expiresIn * 1000
        : 0;
    await _save(data);
  }

  // MARK: - Sync writes (POST /sync/history)

  /// Marks [items] watched on SIMKL (POST /sync/history).
  Future<void> markWatched(List<SimklWatchItem> items) async => addToHistory(items);

  Future<void> addToHistory(List<SimklWatchItem> items) async {
    if (items.isEmpty) return;
    final movies = <Map<String, dynamic>>[];
    final shows = <Map<String, dynamic>>[];
    for (final item in items) {
      final watchedAt = (item.watchedAt ?? DateTime.now()).toUtc().toIso8601String();
      if (item.isTv) {
        shows.add({
          'ids': {'tmdb': item.tmdbId},
          'seasons': [
            {
              'number': item.season ?? 1,
              'episodes': [
                {'number': item.episode ?? 1},
              ],
            },
          ],
          'watched_at': watchedAt,
        });
      } else {
        movies.add({
          'ids': {'tmdb': item.tmdbId},
          'watched_at': watchedAt,
        });
      }
    }
    final body = <String, dynamic>{
      if (movies.isNotEmpty) 'movies': movies,
      if (shows.isNotEmpty) 'shows': shows,
    };
    await _post('/sync/history', body: body, auth: true);
    await _markSynced();
  }

  Future<void> addToHistoryOne(SimklWatchItem item) => addToHistory([item]);

  // MARK: - Sync reads

  /// Activities check (cheap) - returns raw activities map or null on failure.
  Future<Map<String, dynamic>?> getActivities() async {
    try {
      final res = await _get('/sync/activities', auth: true);
      return res as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// Two-phase helper: if [dateFrom] is null pulls full library, otherwise delta.
  Future<Map<String, dynamic>> _getAllItems({String? dateFrom, String? extended}) async {
    final path = '/sync/all-items';
    final qp = <String, String>{};
    if (dateFrom != null) qp['date_from'] = dateFrom;
    if (extended != null) qp['extended'] = extended;
    // Build manually to append query params after the required client_id set.
    final base = _uri(path, qp);
    final token = await _accessToken();
    if (token == null || token.isEmpty) throw const SimklException('Not signed in to SIMKL.');
    try {
      final req = await _client.getUrl(base).timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) {
        throw const SimklException('SIMKL session expired - sign in again.');
      }
      if (res.statusCode >= 400) {
        throw SimklException(_friendlyStatus(res.statusCode, body));
      }
      if (body.isEmpty) return const {};
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      return const {};
    } on SimklException {
      rethrow;
    } on SocketException {
      throw const SimklException("Can't reach SIMKL - check your connection.");
    } on TimeoutException {
      throw const SimklException('SIMKL request timed out.');
    } on FormatException {
      throw const SimklException('SIMKL returned an unexpected response.');
    }
  }

  Future<Set<int>> getWatchedTmdbIds() async {
    final watched = await fetchWatched();
    final out = <int>{}..addAll(watched.movieIds)..addAll(watched.showSeasons.keys);
    return out;
  }

  /// Full watched snapshot (fetches completed + watching as watched proxy).
  Future<SimklWatched> fetchWatched() async {
    final data = await _getAllItems(extended: 'full');
    // data shape: {shows: [...], movies: [...], anime: [...]}
    final movieIds = <int>{};
    for (final m in (data['movies'] as List? ?? const [])) {
      final entry = m as Map<String, dynamic>;
      // Only include items that are actually watched/completed; Simkl stores
      // movies in completed/plantowatch/dropped. Treat completed as watched.
      final status = entry['status'] as String?;
      if (status != null && status != 'completed' && status != 'watching') {
        // For movies watching doesn't exist; keep completed only.
        if (status == 'plantowatch' || status == 'dropped') continue;
      }
      final ids = entry['ids'] as Map<String, dynamic>?;
      final tmdb = (ids?['tmdb'] as num?)?.toInt();
      if (tmdb != null) movieIds.add(tmdb);
    }
    // If no status filtering yields empty, fall back to all movies (older data).
    // Keep as is; the status-aware filter above already handles it.

    final showSeasons = <int, Map<int, int>>{};
    for (final s in (data['shows'] as List? ?? const [])) {
      final entry = s as Map<String, dynamic>;
      final ids = entry['ids'] as Map<String, dynamic>?;
      final tmdb = (ids?['tmdb'] as num?)?.toInt();
      if (tmdb == null) continue;
      // Count watched episodes per season from seasons[].episodes[] when present,
      // otherwise use total_episodes_watched / watched_episodes_count.
      final seasons = <int, int>{};
      final seasonsRaw = entry['seasons'] as List?;
      if (seasonsRaw != null) {
        for (final sn in seasonsRaw) {
          final d = sn as Map<String, dynamic>;
          final number = (d['number'] as num?)?.toInt();
          final episodes = d['episodes'] as List?;
          if (number != null && episodes != null) seasons[number] = episodes.length;
        }
      }
      if (seasons.isEmpty) {
        final count = (entry['total_episodes_watched'] as num?)?.toInt() ??
            (entry['watched_episodes_count'] as num?)?.toInt() ?? 0;
        if (count > 0) seasons[1] = count;
      }
      if (seasons.isNotEmpty) showSeasons[tmdb] = seasons;
    }
    return SimklWatched(movieIds: movieIds, showSeasons: showSeasons);
  }

  /// Watchlist (plantowatch) - TMDB ids for movies + shows.
  Future<Set<int>> getWatchlist() async {
    final data = await _get('/sync/all-items', auth: true);
    // Without extended, the response groups by type; collect plantowatch items.
    final out = <int>{};
    for (final key in ['movies', 'shows', 'anime']) {
      final list = (data as Map<String, dynamic>)[key] as List?;
      if (list == null) continue;
      for (final entry in list) {
        final m = entry as Map<String, dynamic>;
        if (m['status'] != 'plantowatch') continue;
        final ids = m['ids'] as Map<String, dynamic>?;
        final tmdb = (ids?['tmdb'] as num?)?.toInt();
        if (tmdb != null) out.add(tmdb);
      }
    }
    return out;
  }

  /// Compatibility alias expected by the task description.
  Future<Set<int>> getWatchedHistory() => getWatchedTmdbIds();

  Future<void> _markSynced() async {
    final data = await _load();
    data['lastSyncAt'] = DateTime.now().millisecondsSinceEpoch;
    await _save(data);
  }

  // MARK: - HTTP

  Uri _uri(String path, Map<String, String> extraQuery) {
    final qp = <String, String>{
      'client_id': simklClientId,
      'app-name': _appName,
      'app-version': _appVersion,
      ...extraQuery,
    };
    final base = Uri.parse('$_base$path');
    final merged = <String, String>{...base.queryParameters, ...qp};
    return base.replace(queryParameters: merged);
  }

  Future<dynamic> _get(String path, {required bool auth}) async {
    final token = auth ? await _accessToken() : null;
    if (auth && (token == null || token.isEmpty)) {
      throw const SimklException('Not signed in to SIMKL.');
    }
    final uri = _uri(path, {});
    try {
      final req = await _client.getUrl(uri).timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401 && auth) {
        throw const SimklException('SIMKL session expired - sign in again.');
      }
      if (res.statusCode >= 400) {
        throw SimklException(_friendlyStatus(res.statusCode, body));
      }
      if (body.isEmpty) return const {};
      final decoded = jsonDecode(body);
      return decoded;
    } on SimklException {
      rethrow;
    } on SocketException {
      throw const SimklException("Can't reach SIMKL - check your connection.");
    } on TimeoutException {
      throw const SimklException('SIMKL request timed out.');
    } on FormatException {
      throw const SimklException('SIMKL returned an unexpected response.');
    }
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    required Map<String, dynamic> body,
    required bool auth,
  }) async {
    final token = auth ? await _accessToken() : null;
    if (auth && (token == null || token.isEmpty)) {
      throw const SimklException('Not signed in to SIMKL.');
    }
    final uri = _uri(path, {});
    try {
      final req = await _client.postUrl(uri).timeout(const Duration(seconds: 15));
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 30));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401 && auth) {
        throw const SimklException('SIMKL session expired - sign in again.');
      }
      if (res.statusCode >= 400) {
        throw SimklException(_friendlyStatus(res.statusCode, text));
      }
      if (text.isEmpty) return const {};
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return const {};
    } on SimklException {
      rethrow;
    } on SocketException {
      throw const SimklException("Can't reach SIMKL - check your connection.");
    } on TimeoutException {
      throw const SimklException('SIMKL request timed out.');
    } on FormatException {
      throw const SimklException('SIMKL returned an unexpected response.');
    }
  }

  static String _friendlyStatus(int code, [String? body]) {
    // Try to surface Simkl's error.message when present.
    if (body != null && body.isNotEmpty) {
      try {
        final j = jsonDecode(body) as Map<String, dynamic>;
        final msg = j['message'] as String?;
        if (msg != null && msg.isNotEmpty) return msg;
        final err = j['error'] as String?;
        if (err != null && err.isNotEmpty) return err;
      } catch (_) {}
    }
    switch (code) {
      case 401:
        return 'SIMKL authorization failed.';
      case 403:
        return 'SIMKL access denied.';
      case 404:
        return 'SIMKL resource not found.';
      case 412:
        return 'SIMKL client_id is wrong or disabled.';
      case 429:
        return 'SIMKL rate limit reached - try again shortly.';
      default:
        return 'SIMKL returned an error ($code).';
    }
  }

  // Keep for the task's doc link requirement.
  static String get oauthTokenUrl => 'https://api.simkl.com/oauth/token';
  static String get baseUrl => _base;
}
