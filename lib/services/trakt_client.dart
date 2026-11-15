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

/// Snapshot of watched movie IDs pulled from Trakt.
class TraktWatched {
  const TraktWatched({this.movieIds = const {}});
  final Set<int> movieIds;
}

/// Trakt API client (Standard API — free, no per-user fee).
///
/// Uses OAuth 2.0 device flow: the app shows a user code, the user authorizes
/// at https://trakt.tv/activate, then the app polls for an access token.
class TraktClient {
  TraktClient([this._prefs]);

  static const String _prefsKey = 'dreamplayer.trakt';
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

  /// The set of watched TMDB movie IDs on Trakt.
  Future<TraktWatched> watchedMovies() async {
    final token = await _accessToken;
    final res = await _request('GET', Uri.parse('$_base/sync/watched/movies'),
        headers: {'Authorization': 'Bearer $token'});
    final data = await _readJson(res);
    if (res.statusCode != 200) {
      throw TraktException(
          'watched movies failed: ${data?['error_description'] ?? data?['error'] ?? res.statusCode}');
    }
    final ids = <int>{};
    for (final entry in (data as List? ?? const [])) {
      final movie = entry['movie'] as Map?;
      final id = movie?['ids']?['tmdb'];
      if (id is int) ids.add(id);
    }
    return TraktWatched(movieIds: ids);
  }

  /// Mark a list of movies as watched on Trakt (POST /sync/history).
  Future<void> markWatched(List<Map<String, dynamic>> movies) async {
    final token = await _accessToken;
    final res = await _request('POST', Uri.parse('$_base/sync/history'),
        headers: {'Authorization': 'Bearer $token'},
        body: jsonEncode({'movies': movies}));
    if (res.statusCode != 200 && res.statusCode != 201) {
      final data = await _readJson(res);
      throw TraktException(
          'mark watched failed: ${data?['error_description'] ?? data?['error'] ?? res.statusCode}');
    }
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
      // Token expired (or within 1 minute) — attempt a refresh.
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
      // best-effort — keep the old token
    }
  }
}
