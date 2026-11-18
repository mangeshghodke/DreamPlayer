import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/trakt_keys.dart';

/// PIN-flow code shown to the user so they can authorize at
/// https://trakt.tv/activate.
class TraktPinCode {
  const TraktPinCode({
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
    required this.deviceCode,
  });

  final String userCode;
  final String verificationUrl;
  final int expiresIn;
  final int interval;
  final String deviceCode;
}

class TraktException implements Exception {
  const TraktException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A single item to mark watched on Trakt (POST /sync/history).
///
/// Mirrors [SimklWatchItem]: a TV item carries its season/episode so Trakt
/// files it under `shows` with a `seasons` block, NOT as a movie. Pushing an
/// episode as a movie is how the first version of this integration silently
/// mis-filed every TV mark.
class TraktWatchItem {
  const TraktWatchItem({
    required this.tmdbId,
    required this.isTv,
    this.season,
    this.episode,
    this.watchedAt,
  });

  final int tmdbId;
  final bool isTv;

  /// Season/episode for TV items (null for movies).
  final int? season;
  final int? episode;

  /// When the item was watched; defaults to now.
  final DateTime? watchedAt;

  /// The API payload fragment for this item. Movies post to the `movies` array
  /// and shows to `shows`; [traktHistoryBody] puts each in the right one.
  Map<String, dynamic> toJson() {
    final at = (watchedAt ?? DateTime.now()).toUtc().toIso8601String();
    if (isTv) {
      return {
        'ids': {'tmdb': tmdbId},
        'seasons': [
          {
            'number': season ?? 0,
            'episodes': [
              {'number': episode ?? 0, 'watched_at': at},
            ],
          },
        ],
      };
    }
    return {
      'ids': {'tmdb': tmdbId},
      'watched_at': at,
    };
  }
}

/// The POST /sync/history body for [items]: movies and shows in their own
/// arrays, and an empty array omitted entirely rather than posted as [].
/// Pure so the split can be unit-tested without a server.
Map<String, dynamic> traktHistoryBody(List<TraktWatchItem> items) {
  final movies = <Map<String, dynamic>>[];
  final shows = <Map<String, dynamic>>[];
  for (final item in items) {
    final json = item.toJson();
    if (item.isTv) {
      shows.add(json);
    } else {
      movies.add(json);
    }
  }
  return {
    if (movies.isNotEmpty) 'movies': movies,
    if (shows.isNotEmpty) 'shows': shows,
  };
}

/// Watched state pulled from Trakt. Movies are a flat id set; TV shows report
/// per-season watched episode *counts* (Trakt semantics: listing an episode
/// under a season means the first N episodes are watched), not per-episode
/// flags.
class TraktWatched {
  const TraktWatched({
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

  /// Parses the `/sync/watched/movies` response. Pure.
  static Set<int> movieIdsFromJson(dynamic data) {
    final ids = <int>{};
    final list = data is List ? data : const [];
    for (final entry in list) {
      if (entry is! Map) continue;
      final movie = entry['movie'];
      if (movie is! Map) continue;
      final idsMap = movie['ids'];
      final id = idsMap is Map ? idsMap['tmdb'] : null;
      if (id is int) ids.add(id);
    }
    return ids;
  }

  /// Parses the `/sync/watched/shows` response into per-season counts.
  /// Pure.
  static Map<int, Map<int, int>> showSeasonsFromJson(dynamic data) {
    final out = <int, Map<int, int>>{};
    final list = data is List ? data : const [];
    for (final entry in list) {
      if (entry is! Map) continue;
      final show = entry['show'];
      if (show is! Map) continue;
      final idsMap = show['ids'];
      final id = idsMap is Map ? idsMap['tmdb'] : null;
      if (id is! int) continue;
      final seasons = <int, int>{};
      final seasonList = entry['seasons'];
      if (seasonList is List) {
        for (final s in seasonList) {
          if (s is! Map) continue;
          final number = (s['number'] as num?)?.toInt();
          final epList = s['episodes'];
          final episodes = epList is List ? epList.length : 0;
          if (number == null || episodes == 0) continue;
          seasons[number] = episodes;
        }
      }
      out[id] = seasons;
    }
    return out;
  }
}

/// Trakt API client (Standard API - free, no per-user fee).
///
/// Uses OAuth 2.0 device flow: the app shows a user code, the user authorizes
/// at https://trakt.tv/activate, then the app polls for an access token.
class TraktClient {
  TraktClient([this._prefs]);

  static const String _prefsKey = 'dreamplayer.trakt';

  /// Prefs key holding the last successful watched-pull timestamp.
  static const String lastPullKey = 'dreamplayer.traktLastPullAt';
  static const String _base = 'https://api.trakt.tv';
  static const String _apiVersion = '2';
  static const String _userAgent = 'DreamPlayer';

  final SharedPreferences? _prefs;
  SharedPreferences? _cachedPrefs;

  Future<SharedPreferences> get _sharedPrefs async =>
      _cachedPrefs ??= _prefs ?? await SharedPreferences.getInstance();

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// True when a Trakt client id is configured at build time.
  bool get isConfigured => traktClientId.isNotEmpty;

  /// True when an access token is stored.
  Future<bool> get isAuthenticated async {
    final prefs = await _sharedPrefs;
    return prefs.getString('$_prefsKey:accessToken')?.isNotEmpty ?? false;
  }

  // MARK: - Persistence

  Future<Map<String, dynamic>> _load() async {
    final prefs = await _sharedPrefs;
    return {
      'accessToken': prefs.getString('$_prefsKey:accessToken') ?? '',
      'refreshToken': prefs.getString('$_prefsKey:refreshToken') ?? '',
      'expiresAt': prefs.getInt('$_prefsKey:expiresAt') ?? 0,
      'scope': prefs.getString('$_prefsKey:scope') ?? '',
    };
  }

  Future<void> _save(String accessToken, String refreshToken, int expiresIn,
      String scope) async {
    final prefs = await _sharedPrefs;
    await prefs.setString('$_prefsKey:accessToken', accessToken);
    await prefs.setString('$_prefsKey:refreshToken', refreshToken);
    await prefs.setInt(
        '$_prefsKey:expiresAt',
        DateTime.now().millisecondsSinceEpoch + expiresIn * 1000);
    await prefs.setString('$_prefsKey:scope', scope);
  }

  Future<void> clear() async {
    final prefs = await _sharedPrefs;
    for (final suffix in const [
      'accessToken', 'refreshToken', 'expiresAt', 'scope',
    ]) {
      await prefs.remove('$_prefsKey:$suffix');
    }
  }

  // MARK: - low-level request

  Future<HttpClientResponse> _request(String method, Uri uri,
      {Map<String, String>? headers, dynamic body}) async {
    final req = await _client.openUrl(method, uri);
    req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.headers.add('trakt-api-version', _apiVersion);
    req.headers.add('trakt-api-key', traktClientId);
    if (headers != null) {
      for (final entry in headers.entries) {
        req.headers.set(entry.key, entry.value);
      }
    }
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(body));
    }
    return req.close();
  }

  Future<dynamic> _readJson(HttpClientResponse resp) async {
    final body = await resp.transform(utf8.decoder).join();
    if (body.isEmpty) return null;
    return jsonDecode(body);
  }

  // MARK: - OAuth device flow

  /// Starts device authorization and returns the PIN code to show the user.
  Future<TraktPinCode> deviceCode() async {
    if (!isConfigured) {
      throw const TraktException('Trakt client id not configured');
    }
    final res = await _request('POST', Uri.parse('$_base/oauth/device/code'),
        body: jsonEncode({'client_id': traktClientId}));
    final data = await _readJson(res);
    if (res.statusCode != 200) {
      throw TraktException(
          'device code failed: ${data?['error_description'] ?? data?['error'] ?? res.statusCode}');
    }
    return TraktPinCode(
      userCode: data['user_code'] as String,
      verificationUrl: data['verification_url'] as String,
      expiresIn: (data['expires_in'] as num).toInt(),
      interval: (data['interval'] as num).toInt(),
      deviceCode: data['device_code'] as String,
    );
  }

  /// Exchanges the device code for an access token.
  Future<void> deviceToken(String deviceCode) async {
    if (!isConfigured) {
      throw const TraktException('Trakt client id not configured');
    }
    final res = await _request('POST', Uri.parse('$_base/oauth/device/token'),
        body: jsonEncode({
          'client_id': traktClientId,
          'client_secret': traktClientSecret,
          'device_code': deviceCode,
        }));
    final data = await _readJson(res);
    if (res.statusCode != 200) {
      throw TraktException(
          'device token failed: ${data?['error_description'] ?? data?['error'] ?? res.statusCode}');
    }
    await _save(data['access_token'] as String,
        data['refresh_token'] as String? ?? '',
        (data['expires_in'] as num).toInt(),
        data['scope'] as String? ?? '');
  }

  // MARK: - Watched

  /// Full watched snapshot: movies plus per-season episode counts for shows.
  /// Two requests (Trakt has no combined endpoint); either failing throws, so
  /// the caller treats the whole pull as failed rather than applying a half
  /// snapshot.
  Future<TraktWatched> fetchWatched() async {
    final token = await _accessToken;
    final movies = await _getJson('$_base/sync/watched/movies', token,
        what: 'watched movies');
    final shows = await _getJson('$_base/sync/watched/shows', token,
        what: 'watched shows');
    return TraktWatched(
      movieIds: TraktWatched.movieIdsFromJson(movies),
      showSeasons: TraktWatched.showSeasonsFromJson(shows),
    );
  }

  Future<dynamic> _getJson(String url, String token, {required String what}) async {
    final res = await _request('GET', Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'});
    final data = await _readJson(res);
    if (res.statusCode != 200) {
      throw TraktException(
          '$what failed: ${data?['error_description'] ?? data?['error'] ?? res.statusCode}');
    }
    return data;
  }

  /// Mark [items] watched on Trakt (POST /sync/history). Movies and TV
  /// episodes are split into their own arrays - a season/episode posted as a
  /// movie lands on the wrong list on Trakt and can never come back correctly.
  Future<void> markWatched(List<TraktWatchItem> items) async {
    if (items.isEmpty) return; // avoid posting an empty {} body
    final token = await _accessToken;
    final res = await _request('POST', Uri.parse('$_base/sync/history'),
        headers: {'Authorization': 'Bearer $token'},
        body: jsonEncode(traktHistoryBody(items)));
    if (res.statusCode != 200 && res.statusCode != 201) {
      final data = await _readJson(res);
      throw TraktException(
          'mark watched failed: ${data?['error_description'] ?? data?['error'] ?? res.statusCode}');
    }
  }

  /// When watched state was last pulled from Trakt (drives the 6 h throttle
  /// and the Settings subtitle). Null when never pulled.
  ///
  /// Kept in its own prefs key rather than inside the token blob: a pull stamp
  /// must never rewrite (or be wiped by) token bookkeeping.
  Future<DateTime?> lastPullAt() async {
    final prefs = await _sharedPrefs;
    final ms = prefs.getInt(lastPullKey) ?? 0;
    return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> markPulled([DateTime? at]) async {
    final prefs = await _sharedPrefs;
    await prefs.setInt(
        lastPullKey, (at ?? DateTime.now()).millisecondsSinceEpoch);
  }

  Future<String> get _accessToken async {
    final state = await _load();
    final token = state['accessToken'] as String? ?? '';
    if (token.isEmpty) {
      throw const TraktException('not authenticated with Trakt');
    }
    final expiresAt = state['expiresAt'] as int? ?? 0;
    if (expiresAt > 0 &&
        DateTime.now().millisecondsSinceEpoch > expiresAt - 60_000) {
      // Token expired (or within 1 minute) - attempt a refresh.
      await _refreshToken(state['refreshToken'] as String? ?? '');
    }
    return (await _load())['accessToken'] as String;
  }

  Future<void> _refreshToken(String refreshToken) async {
    if (refreshToken.isEmpty || traktClientSecret.isEmpty) return;
    try {
      final res = await _request('POST', Uri.parse('$_base/oauth/token'),
          body: jsonEncode({
            'client_id': traktClientId,
            'client_secret': traktClientSecret,
            'redirect_uri': 'urn:ietf:wg:oauth:2.0:oob',
            'refresh_token': refreshToken,
            'grant_type': 'refresh_token',
          }));
      if (res.statusCode != 200) return; // best-effort refresh
      final data = await _readJson(res);
      await _save(data['access_token'] as String? ?? '',
          data['refresh_token'] as String? ?? refreshToken,
          (data['expires_in'] as num).toInt(),
          data['scope'] as String? ?? '');
    } catch (_) {
      // best-effort - keep the old token
    }
  }
}
