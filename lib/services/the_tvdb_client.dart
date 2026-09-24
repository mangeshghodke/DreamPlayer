import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tmdb_client.dart';

const String theTvdbApiKeyPrefsKey = 'dreamplayer.theTvdbApiKey';
const String theTvdbPinPrefsKey = 'dreamplayer.theTvdbPin';
const String theTvdbApiBaseUrl = 'https://api4.thetvdb.com/v4';
const String theTvdbArtworkBaseUrl = 'https://artworks.thetvdb.com';

class TheTvdbException implements Exception {
  const TheTvdbException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class TheTvdbRequest {
  const TheTvdbRequest({
    required this.method,
    required this.uri,
    this.headers = const {},
    this.body,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;
}

class TheTvdbResponse {
  const TheTvdbResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

class _TheTvdbEnvelope {
  const _TheTvdbEnvelope({required this.data, this.links});

  final dynamic data;
  final Map<String, dynamic>? links;
}

typedef TheTVDBException = TheTvdbException;
typedef TheTVDBRequest = TheTvdbRequest;
typedef TheTVDBResponse = TheTvdbResponse;

typedef TheTvdbTransport =
    Future<TheTvdbResponse> Function(TheTvdbRequest request);

class TheTvdbCredentialStore {
  TheTvdbCredentialStore({
    SharedPreferences? preferences,
    SharedPreferences? prefs,
    MethodChannel? channel,
  }) : _providedPreferences = preferences ?? prefs,
       _channel = preferences == null && prefs == null
           ? channel ?? _defaultChannel
           : channel;

  static const String apiKeyKey = theTvdbApiKeyPrefsKey;
  static const String pinKey = theTvdbPinPrefsKey;
  static const MethodChannel _defaultChannel = MethodChannel(
    'dreamplayer/the_tvdb_credentials',
  );

  final SharedPreferences? _providedPreferences;
  final MethodChannel? _channel;
  SharedPreferences? _cachedPreferences;
  bool _loaded = false;
  String? _apiKey;
  String? _pin;

  bool get _inTests =>
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  bool get _canUseSecureStorage =>
      _providedPreferences == null &&
      _channel != null &&
      (!_inTests || !identical(_channel, _defaultChannel));

  Future<SharedPreferences> get _legacyPreferences async {
    final provided = _providedPreferences;
    if (provided != null) return provided;
    final cached = _cachedPreferences;
    if (cached != null) return cached;
    final loaded = await SharedPreferences.getInstance();
    _cachedPreferences = loaded;
    return loaded;
  }

  String? get apiKey {
    if (_loaded) return _apiKey;
    return _providedPreferences?.getString(apiKeyKey);
  }

  String? get pin {
    if (_loaded) return _pin;
    return _providedPreferences?.getString(pinKey);
  }

  bool get isConfigured => apiKey?.trim().isNotEmpty ?? false;

  Future<bool> get isConfiguredAsync async {
    await load();
    return isConfigured;
  }

  Future<void> load() async {
    if (_loaded) return;
    if (!_canUseSecureStorage) {
      await _loadLegacy();
      return;
    }
    final values = await _readSecure();
    _apiKey = _stringValue(values?['apiKey']);
    _pin = _stringValue(values?['pin']);
    final legacy = await _legacyPreferences;
    final legacyKey = legacy.getString(apiKeyKey);
    final legacyPin = legacy.getString(pinKey);
    if (_apiKey == null && legacyKey != null) {
      await _writeSecure(apiKey: legacyKey, pin: _pin ?? legacyPin);
      _apiKey = legacyKey;
      _pin ??= legacyPin;
    } else if (_apiKey != null && _pin == null && legacyPin != null) {
      await _writeSecure(apiKey: _apiKey!, pin: legacyPin);
      _pin = legacyPin;
    }
    if (_apiKey != null || _pin != null) {
      await legacy.remove(apiKeyKey);
      await legacy.remove(pinKey);
    }
    _loaded = true;
  }

  Future<void> save({required String apiKey, String? pin}) async {
    final normalizedKey = apiKey.trim();
    final normalizedPin = pin?.trim();
    if (normalizedKey.isEmpty) {
      await clear();
      return;
    }
    if (_canUseSecureStorage) {
      await _writeSecure(apiKey: normalizedKey, pin: normalizedPin);
      final legacy = await _legacyPreferences;
      await legacy.remove(apiKeyKey);
      await legacy.remove(pinKey);
      _setLoaded(normalizedKey, normalizedPin);
      return;
    }
    final preferences = await _legacyPreferences;
    await preferences.setString(apiKeyKey, normalizedKey);
    if (normalizedPin == null || normalizedPin.isEmpty) {
      await preferences.remove(pinKey);
    } else {
      await preferences.setString(pinKey, normalizedPin);
    }
    _setLoaded(normalizedKey, normalizedPin);
  }

  Future<void> clear() async {
    if (_canUseSecureStorage) {
      await _clearSecure();
    }
    final preferences = await _legacyPreferences;
    await preferences.remove(apiKeyKey);
    await preferences.remove(pinKey);
    _setLoaded(null, null);
  }

  Future<void> _loadLegacy() async {
    try {
      final preferences = await _legacyPreferences;
      _apiKey = preferences.getString(apiKeyKey);
      _pin = preferences.getString(pinKey);
    } catch (_) {
      _apiKey = null;
      _pin = null;
    }
    _loaded = true;
  }

  Future<Map<dynamic, dynamic>?> _readSecure() async {
    try {
      return await _channel!
          .invokeMethod<Map<dynamic, dynamic>>('read')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      throw const TheTvdbException(
        'Secure TheTVDB credential storage is unavailable.',
      );
    }
  }

  Future<void> _writeSecure({required String apiKey, String? pin}) async {
    try {
      await _channel!.invokeMethod<void>('write', {
        'apiKey': apiKey,
        'pin': pin,
      });
    } catch (_) {
      throw const TheTvdbException(
        'Secure TheTVDB credential storage is unavailable.',
      );
    }
  }

  Future<void> _clearSecure() async {
    try {
      await _channel!.invokeMethod<void>('clear');
    } catch (_) {
      throw const TheTvdbException(
        'Secure TheTVDB credential storage is unavailable.',
      );
    }
  }

  void _setLoaded(String? apiKey, String? pin) {
    _apiKey = apiKey;
    _pin = pin;
    _loaded = true;
  }

  static String? _stringValue(dynamic value) {
    if (value is String && value.isNotEmpty) return value;
    return null;
  }
}

class TheTvdbClient {
  static final TheTvdbCredentialStore defaultCredentialStore =
      TheTvdbCredentialStore();

  factory TheTvdbClient({
    SharedPreferences? prefs,
    SharedPreferences? preferences,
    HttpClient? httpClient,
    HttpClient? client,
    TheTvdbTransport? transport,
    String baseUrl = theTvdbApiBaseUrl,
    int maxRetries = 2,
    Duration retryDelay = const Duration(milliseconds: 250),
  }) {
    return TheTvdbClient._(
      credentials: prefs != null || preferences != null
          ? TheTvdbCredentialStore(preferences: prefs ?? preferences)
          : defaultCredentialStore,
      httpClient: httpClient ?? client,
      transport: transport,
      baseUrl: baseUrl,
      maxRetries: maxRetries,
      retryDelay: retryDelay,
    );
  }

  TheTvdbClient._({
    required this._credentials,
    required this._httpClient,
    required this._transport,
    required String baseUrl,
    required int maxRetries,
    required this._retryDelay,
  }) : _baseUrl = _trimTrailingSlashes(baseUrl),
       _maxRetries = maxRetries < 0 ? 0 : maxRetries;

  static const String defaultBaseUrl = theTvdbApiBaseUrl;
  static const String defaultArtworkBaseUrl = theTvdbArtworkBaseUrl;
  static const String apiKeyPrefsKey = theTvdbApiKeyPrefsKey;
  static const String pinPrefsKey = theTvdbPinPrefsKey;
  static const String apiKeyPrefKey = theTvdbApiKeyPrefsKey;
  static const String pinPrefKey = theTvdbPinPrefsKey;
  static const String fallbackPrefsKey = 'dreamplayer.theTvdbFallbackEnabled';

  static Future<bool> isFallbackEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(fallbackPrefsKey) ?? true;
  }

  static Future<void> setFallbackEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(fallbackPrefsKey, enabled);
  }

  final TheTvdbCredentialStore _credentials;
  final TheTvdbTransport? _transport;
  final String _baseUrl;
  final int _maxRetries;
  final Duration _retryDelay;
  HttpClient? _httpClient;
  String? _token;
  Future<String>? _loginInFlight;
  bool _disposed = false;

  TheTvdbCredentialStore get credentials => _credentials;

  String get baseUrl => _baseUrl;

  bool get isConfigured => _credentials.isConfigured;

  bool get isAuthenticated => _token?.isNotEmpty ?? false;

  String? get cachedToken => _token;

  String? get apiKey => _credentials.apiKey;

  String? get pin => _credentials.pin;

  Future<void> setCredentials({required String apiKey, String? pin}) async {
    await _credentials.save(apiKey: apiKey, pin: pin);
    _token = null;
  }

  Future<void> saveCredentials({required String apiKey, String? pin}) =>
      setCredentials(apiKey: apiKey, pin: pin);

  Future<void> setApiKey(String apiKey) async {
    await _credentials.load();
    await setCredentials(apiKey: apiKey, pin: _credentials.pin);
  }

  Future<void> setPin(String? pin) async {
    await _credentials.load();
    final key = _credentials.apiKey;
    if (key == null || key.trim().isEmpty) return;
    await setCredentials(apiKey: key, pin: pin);
  }

  Future<void> clearCredentials() async {
    _token = null;
    await _credentials.clear();
  }

  void invalidateToken() {
    _token = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _token = null;
    _loginInFlight = null;
    _httpClient?.close(force: true);
  }

  Future<bool> get isConfiguredAsync => _credentials.isConfiguredAsync;

  Future<bool> get configured => _credentials.isConfiguredAsync;

  Future<bool> checkConfigured() => _credentials.isConfiguredAsync;

  Future<String> login({
    String? apiKey,
    String? pin,
    bool force = false,
    bool persist = true,
  }) async {
    if (_disposed) {
      throw const TheTvdbException('TheTVDB client is disposed.');
    }
    if (apiKey != null) {
      if (persist) {
        await _credentials.save(apiKey: apiKey, pin: pin ?? _credentials.pin);
      } else {
        await _credentials.load();
      }
    } else {
      await _credentials.load();
    }
    final key = (apiKey ?? _credentials.apiKey)?.trim() ?? '';
    final loginPin = pin ?? _credentials.pin;
    if (key.isEmpty) {
      throw const TheTvdbException('TheTVDB API key is not configured.');
    }
    if (!force && apiKey == null && _token?.isNotEmpty == true) return _token!;
    final active = _loginInFlight;
    if (active != null) return active;
    final future = _loginInternal(apiKey: key, pin: loginPin);
    _loginInFlight = future;
    try {
      final token = await future;
      _token = token;
      return token;
    } finally {
      if (identical(_loginInFlight, future)) _loginInFlight = null;
    }
  }

  Future<String> _loginInternal({required String apiKey, String? pin}) async {
    final body = <String, dynamic>{
      'apikey': apiKey,
      if (pin != null && pin.trim().isNotEmpty) 'pin': pin.trim(),
    };
    final response = await _requestWithRetry(
      TheTvdbRequest(
        method: 'POST',
        uri: _uri('/login'),
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      ),
    );
    final data = _decodeResponse(response);
    final map = _mapValue(data);
    final token = map == null
        ? null
        : _stringValue(
            map['token'] ?? map['bearerToken'] ?? map['accessToken'],
          );
    if (token == null || token.isEmpty) {
      throw const TheTvdbException('TheTVDB login did not return a token.');
    }
    return token;
  }

  Future<List<TmdMovie>> search(
    String query, {
    int? year,
    TmdKind kind = TmdKind.movie,
  }) async {
    if (query.trim().isEmpty || !await _hasCredentials()) return const [];
    final parameters = <String, String>{
      'query': _queryText(query),
      'type': kind == TmdKind.tv ? 'series' : 'movie',
      if (year != null && year > 0) 'year': '$year',
    };
    final data = await _authorizedGet('/search', parameters);
    return mapSearchResponse(data, kind: kind);
  }

  Future<List<TmdMovie>> searchSeries(String query, {int? year}) =>
      search(query, year: year, kind: TmdKind.tv);

  Future<List<TmdMovie>> searchMovies(String query, {int? year}) =>
      search(query, year: year, kind: TmdKind.movie);

  Future<TmdDetails?> details(Object item, {TmdKind? kind}) async {
    final id = item is TmdMovie ? item.id : _intValue(item);
    final resolvedKind = kind ?? (item is TmdMovie ? item.kind : TmdKind.movie);
    if (id == null || id <= 0 || !await _hasCredentials()) return null;
    return extended(id, kind: resolvedKind);
  }

  Future<TmdDetails?> extended(int id, {TmdKind kind = TmdKind.movie}) async {
    if (id <= 0 || !await _hasCredentials()) return null;
    final path = kind == TmdKind.tv
        ? '/series/$id/extended'
        : '/movies/$id/extended';
    final data = await _authorizedGet(path);
    return mapExtendedResponse(data, kind: kind);
  }

  Future<TmdDetails?> seriesDetails(int id) => extended(id, kind: TmdKind.tv);

  Future<TmdDetails?> movieDetails(int id) => extended(id, kind: TmdKind.movie);

  Future<TmdDetails?> extendedSeries(int id) => seriesDetails(id);

  Future<TmdDetails?> extendedMovie(int id) => movieDetails(id);

  Future<List<TmdEpisode>> episodes(
    Object series, {
    int? season,
    int page = 0,
  }) async {
    final id = series is TmdMovie ? series.id : _intValue(series);
    if (id == null || id <= 0 || !await _hasCredentials()) return const [];
    final envelope = await _episodePage(id, season: season, page: page);
    return mapEpisodesResponse(envelope.data, season: season);
  }

  Future<List<TmdEpisode>> seasonEpisodes(
    Object series, {
    int? season,
    int page = 0,
  }) async {
    final id = series is TmdMovie ? series.id : _intValue(series);
    if (id == null || id <= 0 || !await _hasCredentials()) return const [];
    var nextPage = page < 0 ? 0 : page;
    final result = <TmdEpisode>[];
    final seen = <String>{};
    final visitedPages = <int>{};
    for (var requestCount = 0; requestCount < 50; requestCount++) {
      if (!visitedPages.add(nextPage)) break;
      final envelope = await _episodePage(id, season: season, page: nextPage);
      final pageItems = mapEpisodesResponse(envelope.data, season: season);
      for (final item in pageItems) {
        final key = [item.episodeNumber, item.name, item.airDate].join('|');
        if (seen.add(key)) result.add(item);
      }
      final linkPage = _nextPageFromLinks(envelope.links);
      final pageSize = _intValue(envelope.links?['page_size']) ?? 500;
      final hasNext = linkPage != null
          ? linkPage > nextPage
          : pageItems.length >= pageSize;
      if (!hasNext) break;
      final following = linkPage ?? nextPage + 1;
      if (following <= nextPage) break;
      nextPage = following;
    }
    return result;
  }

  Future<List<TmdEpisode>> episodesForSeries(
    TmdMovie series, {
    int? season,
    int page = 0,
  }) => seasonEpisodes(series, season: season, page: page);

  Future<_TheTvdbEnvelope> _episodePage(
    int id, {
    int? season,
    required int page,
  }) {
    final parameters = <String, String>{
      'page': '$page',
      if (season != null && season > 0) 'season': '$season',
    };
    return _authorizedGetEnvelope('/series/$id/episodes/default', parameters);
  }

  Future<Map<int, String>> seasonNames(Object series) async {
    final id = series is TmdMovie ? series.id : _intValue(series);
    if (id == null || id <= 0 || !await _hasCredentials()) return const {};
    final data = await _authorizedGet('/series/$id/extended');
    return mapSeasonNamesResponse(data);
  }

  Future<List<TmdSeason>> seasons(Object series) async {
    final id = series is TmdMovie ? series.id : _intValue(series);
    if (id == null || id <= 0 || !await _hasCredentials()) return const [];
    final data = await _authorizedGet('/series/$id/extended');
    return mapSeasonsResponse(data);
  }

  Future<TmdMovie?> byId(int id, {TmdKind kind = TmdKind.movie}) async {
    if (id <= 0 || !await _hasCredentials()) return null;
    final path = kind == TmdKind.tv ? '/series/$id' : '/movies/$id';
    final data = await _authorizedGet(path);
    return mapSearchResult(data, kind: kind);
  }

  Future<TmdMatch?> bestMatch(ParsedFileName parsed) async {
    if (!await _hasCredentials()) return null;
    final hasSeries =
        parsed.isEpisode || (parsed.seriesName?.trim().isNotEmpty ?? false);
    final kind = hasSeries ? TmdKind.tv : TmdKind.movie;
    final query = _queryText(
      hasSeries ? (parsed.seriesName ?? parsed.title) : parsed.title,
    );
    if (query.isEmpty) return null;
    var results = await _safeSearch(query, year: parsed.year, kind: kind);
    if (results.isEmpty && parsed.year != null) {
      results = await _safeSearch(query, kind: kind);
    }
    if (results.isEmpty) return null;
    results.sort(
      (a, b) => _candidateScore(
        b,
        query,
        parsed.year,
      ).compareTo(_candidateScore(a, query, parsed.year)),
    );
    final best = results.first;
    final score = _candidateScore(best, query, parsed.year);
    if (score < 0.5) return null;
    return TmdMatch(best, score);
  }

  Future<TmdMatch?> bestForQuery(
    String query, {
    int? year,
    bool liveAction = false,
    bool preferMovie = false,
    bool hasMovieSequelPattern = false,
    int? desiredPart,
  }) async {
    if (!await _hasCredentials()) return null;
    final clean = _queryText(query);
    if (clean.isEmpty) return null;
    final series = await _safeSearch(clean, year: year, kind: TmdKind.tv);
    final movies = await _safeSearch(clean, year: year, kind: TmdKind.movie);
    TmdMatch? best;
    void consider(TmdMovie candidate, double tieBoost) {
      final partBonus = _partBonus(clean, desiredPart, candidate.title);
      final liveActionPenalty =
          liveAction &&
              RegExp(
                r'(?:^|\W)(anime|animation|animated)(?:\W|$)',
                caseSensitive: false,
              ).hasMatch(candidate.title)
          ? 0.15
          : 0.0;
      final score =
          _candidateScore(candidate, clean, year) +
          tieBoost +
          partBonus -
          liveActionPenalty;
      if (score < 0.5) return;
      if (best == null || score > best!.score) {
        best = TmdMatch(candidate, score);
      }
    }

    if (preferMovie) {
      for (final candidate in movies) {
        consider(candidate, hasMovieSequelPattern ? 0.15 : 0.001);
      }
      for (final candidate in series) {
        consider(candidate, 0);
      }
    } else {
      for (final candidate in series) {
        consider(candidate, 0.001);
      }
      for (final candidate in movies) {
        consider(candidate, 0);
      }
    }
    return best;
  }

  static List<TmdMovie> mapSearchResponse(
    dynamic response, {
    TmdKind kind = TmdKind.movie,
  }) {
    return _searchItems(response)
        .map((item) => mapSearchResult(item, kind: kind))
        .whereType<TmdMovie>()
        .toList();
  }

  static TmdMovie? mapSearchResult(dynamic response, {TmdKind? kind}) {
    final map = _mapValue(response);
    if (map == null) return null;
    final rawType = _stringValue(
      map['type'] ?? map['entityType'] ?? map['kind'],
    );
    final resolvedKind =
        kind ??
        (rawType?.toLowerCase() == 'series' ||
                rawType?.toLowerCase() == 'tv' ||
                rawType?.toLowerCase() == 'show'
            ? TmdKind.tv
            : TmdKind.movie);
    final id = _idValue(map);
    final title = _stringValue(
      map['name'] ??
          map['title'] ??
          map['seriesName'] ??
          map['movieName'] ??
          map['translatedName'],
    );
    if (id == null || id <= 0 || title == null || title.isEmpty) return null;
    final artwork = _selectArtwork(map);
    return TmdMovie(
      id: id,
      title: title,
      year: _yearFromMap(map),
      posterPath: artwork.poster,
      backdropPath: artwork.backdrop,
      overview:
          _stringValue(
            map['overview'] ??
                map['summary'] ??
                map['description'] ??
                _firstString(
                  map['overviews'] ??
                      map['overviewTranslations'] ??
                      map['overview_translated'],
                ),
          ) ??
          '',
      voteAverage: _ratingValue(map['rating'] ?? map['voteAverage']),
      kind: resolvedKind,
      provider: MetadataProvider.theTvdb,
      originalTitle: _stringValue(
        map['originalName'] ?? map['originalTitle'] ?? map['sortTitle'],
      ),
      alternateTitles: _alternateTitlesFromMap(map),
    );
  }

  static List<TmdMovie> mapSearch(
    dynamic response, {
    TmdKind kind = TmdKind.movie,
  }) => mapSearchResponse(response, kind: kind);

  static String? absoluteArtworkUrl(dynamic value) => _absoluteTvdbUrl(value);

  static TmdDetails? mapExtendedResponse(
    dynamic response, {
    TmdKind kind = TmdKind.movie,
  }) {
    final map = _dataMap(response);
    if (map == null) return null;
    final title = _stringValue(map['name'] ?? map['title']);
    if (title == null || title.isEmpty) return null;
    final artwork = _selectArtwork(map, preferBackdrop: kind == TmdKind.tv);
    final episodeItems = _episodeItems(map['episodes'] ?? map['episodeList']);
    final seasonItems = kind == TmdKind.tv
        ? mapSeasonsResponse(map)
        : const <TmdSeason>[];
    final explicitEpisodeCount = _intValue(
      map['numberOfEpisodes'] ??
          map['episodeCount'] ??
          map['number_of_episodes'],
    );
    final explicitSeasonCount = _intValue(
      map['numberOfSeasons'] ?? map['seasonCount'] ?? map['number_of_seasons'],
    );
    return TmdDetails(
      title: title,
      tagline: _stringValue(map['tagline'] ?? map['summary']),
      overview:
          _stringValue(
            map['overview'] ??
                map['summary'] ??
                map['description'] ??
                _firstString(
                  map['overviews'] ??
                      map['overviewTranslations'] ??
                      map['overview_translated'],
                ),
          ) ??
          '',
      voteAverage: _ratingValue(map['rating'] ?? map['voteAverage']),
      voteCount:
          _intValue(map['votes'] ?? map['voteCount'] ?? map['ratingCount']) ??
          0,
      year: _yearFromMap(map),
      runtimeMinutes: _runtimeFromMap(map),
      genres: _genresFromMap(map),
      cast: _castFromMap(map),
      stills: _artworkStills(map),
      posterPath: artwork.poster,
      backdropPath: artwork.backdrop,
      originalTitle: _stringValue(map['originalName'] ?? map['originalTitle']),
      numberOfSeasons: explicitSeasonCount ?? seasonItems.length,
      numberOfEpisodes: explicitEpisodeCount ?? episodeItems.length,
    );
  }

  static TmdDetails? mapDetailsResponse(
    dynamic response, {
    TmdKind kind = TmdKind.movie,
  }) => mapExtendedResponse(response, kind: kind);

  static TmdDetails? mapExtended(
    dynamic response, {
    TmdKind kind = TmdKind.movie,
  }) => mapExtendedResponse(response, kind: kind);

  static List<TmdEpisode> mapEpisodesResponse(dynamic response, {int? season}) {
    return _episodeItems(response)
        .map((item) => mapEpisodeResponse(item, season: season))
        .whereType<TmdEpisode>()
        .toList();
  }

  static TmdEpisode? mapEpisodeResponse(dynamic response, {int? season}) {
    final map = _mapValue(response);
    if (map == null) return null;
    final actualSeason = _intValue(
      map['seasonNumber'] ?? map['season_number'] ?? map['season'],
    );
    if (season != null &&
        season > 0 &&
        actualSeason != null &&
        actualSeason != season) {
      return null;
    }
    final episodeNumber = _intValue(
      map['number'] ??
          map['episodeNumber'] ??
          map['episode_number'] ??
          map['absoluteNumber'] ??
          map['absolute_number'],
    );
    if (episodeNumber == null || episodeNumber <= 0) return null;
    final still = _absoluteTvdbUrl(
      _firstValue(map, const [
        'image',
        'image_url',
        'imageUrl',
        'still',
        'thumbnail',
      ]),
    );
    final stills = _artworkStills(map);
    return TmdEpisode(
      episodeNumber: episodeNumber,
      name: _stringValue(map['name'] ?? map['title']) ?? '',
      overview:
          _stringValue(
            map['overview'] ??
                map['summary'] ??
                map['description'] ??
                _firstString(
                  map['overviews'] ??
                      map['overviewTranslations'] ??
                      map['overview_translated'],
                ),
          ) ??
          '',
      stillPath: still,
      airDate: _stringValue(
        map['aired'] ?? map['airDate'] ?? map['firstAired'],
      ),
      runtimeMinutes: _intValue(map['runtime'] ?? map['runtimeMinutes']),
      voteAverage: _ratingValue(map['rating'] ?? map['voteAverage']),
      cast: _castFromMap(map),
      guestStars: const [],
      stills: stills,
    );
  }

  static List<TmdEpisode> mapEpisodes(dynamic response, {int? season}) =>
      mapEpisodesResponse(response, season: season);

  static TmdEpisode? mapEpisode(dynamic response, {int? season}) =>
      mapEpisodeResponse(response, season: season);

  static List<TmdSeason> mapSeasonsResponse(dynamic response) {
    final context = _dataMap(response);
    final items = _seasonItems(response);
    final defaultTypeId = _defaultSeasonTypeId(context);
    final defaultTypeName = _defaultSeasonTypeName(context);
    final matching = items.where((item) {
      if (defaultTypeId != null && _seasonTypeId(item) != null) {
        return _seasonTypeId(item) == defaultTypeId;
      }
      if (defaultTypeName != null && _seasonTypeName(item) != null) {
        return _seasonTypeName(item) == defaultTypeName;
      }
      return true;
    }).toList();
    final selected = matching.isEmpty ? items : matching;
    final byNumber = <int, TmdSeason>{};
    for (final item in selected) {
      final number = _intValue(
        item['number'] ??
            item['seasonNumber'] ??
            item['season_number'] ??
            item['id'],
      );
      if (number == null || byNumber.containsKey(number)) continue;
      final artwork = _selectArtwork(item);
      final name = _stringValue(item['name'] ?? item['title']);
      byNumber[number] = TmdSeason(
        seasonNumber: number,
        name: name?.isNotEmpty == true ? name! : 'Season $number',
        overview:
            _stringValue(
              item['overview'] ??
                  item['summary'] ??
                  _firstString(item['overviewTranslations']),
            ) ??
            '',
        posterPath: artwork.poster,
        episodes: _episodeItems(
          item['episodes'] ?? item['episodeList'],
        ).map(mapEpisodeResponse).whereType<TmdEpisode>().toList(),
      );
    }
    return byNumber.values.toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
  }

  static List<TmdSeason> mapSeasons(dynamic response) =>
      mapSeasonsResponse(response);

  static Map<int, String> mapSeasonNamesResponse(dynamic response) {
    return {
      for (final season in mapSeasonsResponse(response))
        season.seasonNumber: season.name,
    };
  }

  static Map<int, String> mapSeasonNames(dynamic response) =>
      mapSeasonNamesResponse(response);

  static double scoreTitle(String query, String title) {
    final normalizedQuery = _normaliseScoreText(query);
    final normalizedTitle = _normaliseScoreText(title);
    if (normalizedQuery.isEmpty || normalizedTitle.isEmpty) return 0;
    if (normalizedQuery == normalizedTitle) return 1;
    if (normalizedQuery.contains(normalizedTitle) ||
        normalizedTitle.contains(normalizedQuery)) {
      final shorter = normalizedQuery.length < normalizedTitle.length
          ? normalizedQuery.length
          : normalizedTitle.length;
      final longer = normalizedQuery.length > normalizedTitle.length
          ? normalizedQuery.length
          : normalizedTitle.length;
      return 0.75 + 0.25 * (shorter / longer);
    }
    final distance = _levenshtein(normalizedQuery, normalizedTitle);
    final length = normalizedQuery.length > normalizedTitle.length
        ? normalizedQuery.length
        : normalizedTitle.length;
    return (1 - distance / length).clamp(0.0, 1.0).toDouble();
  }

  static double scoreTitleYear(
    String query,
    int? queryYear,
    String title,
    int? titleYear,
  ) {
    var score = scoreTitle(query, title) + scoreYear(queryYear, titleYear);
    return score.clamp(0.0, 1.5).toDouble();
  }

  static double scoreYear(int? expectedYear, int? actualYear) {
    if (expectedYear == null || actualYear == null) return 0;
    return expectedYear == actualYear ? 0.2 : -0.15;
  }

  static double titleScore(String query, String title) =>
      scoreTitle(query, title);

  static double titleYearScore(
    String query,
    int? queryYear,
    String title,
    int? titleYear,
  ) => scoreTitleYear(query, queryYear, title, titleYear);

  Future<List<TmdMovie>> _safeSearch(
    String query, {
    int? year,
    required TmdKind kind,
  }) async {
    try {
      return await search(query, year: year, kind: kind);
    } on TheTvdbException {
      return const [];
    } on SocketException {
      return const [];
    } on TimeoutException {
      return const [];
    }
  }

  double _candidateScore(TmdMovie candidate, String query, int? year) {
    var score = scoreTitleYear(query, year, candidate.title, candidate.year);
    for (final alternateTitle in candidate.alternateTitles) {
      final alternateScore = scoreTitleYear(
        query,
        year,
        alternateTitle,
        candidate.year,
      );
      if (alternateScore > score) score = alternateScore;
    }
    return score;
  }

  double _partBonus(String query, int? desiredPart, String title) {
    final requested =
        desiredPart ??
        int.tryParse(
          RegExp(r'\b(\d{1,3})\s*$').firstMatch(query.trim())?.group(1) ?? '',
        );
    if (requested == null) return 0;
    final match = RegExp(
      r'\bpart\s+(\d+|[ivxlcdm]+)\b',
      caseSensitive: false,
    ).firstMatch(title);
    if (match == null) return -0.2;
    final raw = match.group(1)!.toUpperCase();
    final actual = int.tryParse(raw) ?? _romanNumber(raw);
    return actual == requested ? 0.4 : -0.3;
  }

  Future<bool> _hasCredentials() async {
    await _credentials.load();
    return _credentials.isConfigured;
  }

  Future<dynamic> _authorizedGet(
    String path, [
    Map<String, String>? queryParameters,
  ]) async {
    final envelope = await _authorizedGetEnvelope(path, queryParameters);
    return envelope.data;
  }

  Future<_TheTvdbEnvelope> _authorizedGetEnvelope(
    String path, [
    Map<String, String>? queryParameters,
  ]) async {
    for (var authAttempt = 0; authAttempt < 2; authAttempt++) {
      final token = await _ensureToken();
      final response = await _requestWithRetry(
        TheTvdbRequest(
          method: 'GET',
          uri: _uri(path, queryParameters),
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ),
      );
      if (response.statusCode == 401 && authAttempt == 0) {
        _token = null;
        continue;
      }
      return _decodeEnvelope(response);
    }
    throw const TheTvdbException(
      'TheTVDB authorization failed.',
      statusCode: 401,
    );
  }

  Future<String> _ensureToken() async {
    if (_token?.isNotEmpty == true) return _token!;
    return login();
  }

  Future<TheTvdbResponse> _requestWithRetry(TheTvdbRequest request) async {
    Object? lastError;
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        final response = await _send(request);
        if (attempt < _maxRetries && _isTransientStatus(response.statusCode)) {
          await _waitBeforeRetry();
          continue;
        }
        return response;
      } on SocketException catch (error) {
        lastError = error;
        if (attempt >= _maxRetries) {
          throw TheTvdbException('Network error: ${error.message}');
        }
        await _waitBeforeRetry();
      } on TimeoutException catch (error) {
        lastError = error;
        if (attempt >= _maxRetries) {
          throw const TheTvdbException('TheTVDB request timed out.');
        }
        await _waitBeforeRetry();
      } on HttpException catch (error) {
        lastError = error;
        if (attempt >= _maxRetries) {
          throw TheTvdbException('Network error: ${error.message}');
        }
        await _waitBeforeRetry();
      }
    }
    if (lastError != null) {
      throw TheTvdbException('TheTVDB request failed: $lastError');
    }
    throw const TheTvdbException('TheTVDB request failed.');
  }

  Future<TheTvdbResponse> _send(TheTvdbRequest request) async {
    if (_disposed) {
      throw const TheTvdbException('TheTVDB client is disposed.');
    }
    final transport = _transport;
    if (transport != null) return transport(request);
    final client = _httpClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
    final httpRequest = await client.openUrl(request.method, request.uri);
    request.headers.forEach(httpRequest.headers.set);
    final body = request.body;
    if (body != null) {
      httpRequest.headers.contentLength = utf8.encode(body).length;
      httpRequest.write(body);
    }
    final response = await httpRequest.close().timeout(
      const Duration(seconds: 30),
    );
    final responseBody = await response.transform(utf8.decoder).join();
    return TheTvdbResponse(statusCode: response.statusCode, body: responseBody);
  }

  dynamic _decodeResponse(TheTvdbResponse response) =>
      _decodeEnvelope(response).data;

  _TheTvdbEnvelope _decodeEnvelope(TheTvdbResponse response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TheTvdbException(
        _responseError(response),
        statusCode: response.statusCode,
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const TheTvdbException('TheTVDB returned invalid JSON.');
    }
    final map = _mapValue(decoded);
    final status = map == null
        ? null
        : _stringValue(map['status'])?.toLowerCase();
    if (status != null && status != 'success' && status != 'ok') {
      throw TheTvdbException(
        _stringValue(map?['message'] ?? map?['error']) ??
            'TheTVDB returned an error.',
      );
    }
    return _TheTvdbEnvelope(
      data: _payload(decoded),
      links: _mapValue(map?['links']),
    );
  }

  String _responseError(TheTvdbResponse response) {
    try {
      final decoded = jsonDecode(response.body);
      final map = _mapValue(decoded);
      final message = map == null
          ? null
          : _stringValue(map['message'] ?? map['error']);
      if (message != null && message.isNotEmpty) return message;
    } catch (_) {}
    return 'TheTVDB request failed (${response.statusCode}).';
  }

  bool _isTransientStatus(int statusCode) {
    return statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        (statusCode >= 500 && statusCode < 600);
  }

  Future<void> _waitBeforeRetry() async {
    if (_retryDelay > Duration.zero) {
      await Future<void>.delayed(_retryDelay);
    }
  }

  Uri _uri(String path, [Map<String, String>? queryParameters]) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$_baseUrl$normalizedPath');
    if (queryParameters == null || queryParameters.isEmpty) return uri;
    return uri.replace(queryParameters: queryParameters);
  }

  static String _trimTrailingSlashes(String value) {
    var result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}

typedef TheTVDBClient = TheTvdbClient;
typedef TheTvdbApi = TheTvdbClient;
typedef TheTVDBApi = TheTvdbClient;

int? _nextPageFromLinks(Map<String, dynamic>? links) {
  final next = _stringValue(links?['next']);
  if (next == null || next.isEmpty) return null;
  final uri = Uri.tryParse(next);
  return _intValue(uri?.queryParameters['page']);
}

dynamic _payload(dynamic value) {
  final map = _mapValue(value);
  if (map == null) return value;
  for (final key in const ['data', 'result', 'response', 'payload']) {
    if (map.containsKey(key)) return map[key];
  }
  return map;
}

Map<String, dynamic>? _dataMap(dynamic value) {
  final payload = _payload(value);
  final map = _mapValue(payload);
  if (map == null) return null;
  for (final key in const ['data', 'result', 'response', 'payload']) {
    final nested = _mapValue(map[key]);
    if (nested != null) return nested;
  }
  return map;
}

List<dynamic> _searchItems(dynamic value) {
  var current = _payload(value);
  for (var depth = 0; depth < 4; depth++) {
    final list = _listValue(current);
    if (list != null) return list;
    final map = _mapValue(current);
    if (map == null) return const [];
    final next = _firstListValue(map, const [
      'results',
      'items',
      'records',
      'data',
      'values',
    ]);
    if (next != null) {
      current = next;
      continue;
    }
    if (_idValue(map) != null) return [map];
    return const [];
  }
  return const [];
}

List<dynamic> _episodeItems(dynamic value) {
  var current = _payload(value);
  for (var depth = 0; depth < 4; depth++) {
    final list = _listValue(current);
    if (list != null) return list;
    final map = _mapValue(current);
    if (map == null) return const [];
    final next = _firstListValue(map, const [
      'episodes',
      'items',
      'results',
      'records',
      'data',
      'values',
    ]);
    if (next != null) {
      current = next;
      continue;
    }
    if (_intValue(map['number'] ?? map['episodeNumber']) != null) return [map];
    return const [];
  }
  return const [];
}

List<Map<String, dynamic>> _seasonItems(dynamic value) {
  var current = _payload(value);
  for (var depth = 0; depth < 4; depth++) {
    final list = _mapList(current);
    if (list.isNotEmpty) return list;
    final map = _mapValue(current);
    if (map == null) return const [];
    final next = _firstListValue(map, const [
      'seasons',
      'items',
      'results',
      'records',
      'data',
      'values',
    ]);
    if (next != null) {
      current = next;
      continue;
    }
    return const [];
  }
  return const [];
}

int? _defaultSeasonTypeId(Map<String, dynamic>? map) {
  final direct = _intValue(map?['defaultSeasonType']);
  if (direct != null) return direct;
  for (final type in _mapList(map?['seasonTypes'] ?? map?['season_types'])) {
    if (_seasonTypeName(type) == 'official') return _intValue(type['id']);
  }
  return null;
}

String? _defaultSeasonTypeName(Map<String, dynamic>? map) {
  final id = _intValue(map?['defaultSeasonType']);
  if (id == null) return 'official';
  for (final type in _mapList(map?['seasonTypes'] ?? map?['season_types'])) {
    if (_intValue(type['id']) == id) return _seasonTypeName(type);
  }
  return null;
}

int? _seasonTypeId(Map<String, dynamic> item) {
  final value = item['type'] ?? item['seasonType'] ?? item['season_type'];
  final map = _mapValue(value);
  return _intValue(map?['id'] ?? value);
}

String? _seasonTypeName(Map<String, dynamic> item) {
  final value = item['type'] ?? item['seasonType'] ?? item['season_type'];
  final map = _mapValue(value);
  final name = _stringValue(map?['type'] ?? map?['name'] ?? value);
  return name?.trim().toLowerCase();
}

List<Map<String, dynamic>> _mapList(dynamic value) {
  final list = _listValue(value);
  if (list == null) return const [];
  return list.map(_mapValue).whereType<Map<String, dynamic>>().toList();
}

List<dynamic>? _listValue(dynamic value) => value is List ? value : null;

Map<String, dynamic>? _mapValue(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return null;
}

List<dynamic>? _firstListValue(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = _listValue(map[key]);
    if (value != null) return value;
  }
  return null;
}

dynamic _firstValue(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value != null) return value;
  }
  return null;
}

String? _firstString(dynamic value) {
  if (value is List) {
    for (final item in value) {
      final result = _stringValue(item);
      if (result != null && result.isNotEmpty) return result;
    }
  }
  if (value is Map) {
    for (final item in value.values) {
      final result = _stringValue(item);
      if (result != null && result.isNotEmpty) return result;
    }
  }
  return _stringValue(value);
}

String? _stringValue(dynamic value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

int? _intValue(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

int? _idValue(Map<String, dynamic> map) {
  final direct = _intValue(
    map['id'] ??
        map['tvdb_id'] ??
        map['tvdbId'] ??
        map['objectID'] ??
        map['objectId'] ??
        map['recordId'],
  );
  if (direct != null) return direct;
  final raw = _stringValue(
    map['id'] ??
        map['tvdb_id'] ??
        map['tvdbId'] ??
        map['objectID'] ??
        map['objectId'] ??
        map['recordId'],
  );
  if (raw == null) return null;
  return int.tryParse(RegExp(r'(\d+)$').firstMatch(raw)?.group(1) ?? raw);
}

int? _yearFromMap(Map<String, dynamic> map) {
  final direct = _intValue(map['year'] ?? map['releaseYear']);
  if (direct != null) return direct;
  for (final key in const [
    'firstAired',
    'first_aired',
    'firstRelease',
    'first_release',
    'releaseDate',
    'release_date',
  ]) {
    final value = _stringValue(map[key]);
    if (value == null) continue;
    final match = RegExp(r'\b(18|19|20)\d{2}\b').firstMatch(value);
    if (match != null) return int.tryParse(match.group(0)!);
  }
  return null;
}

int? _runtimeFromMap(Map<String, dynamic> map) {
  final direct = _intValue(
    map['runtime'] ??
        map['runtimeMinutes'] ??
        map['averageRuntime'] ??
        map['average_runtime'] ??
        map['runTime'],
  );
  if (direct != null) return direct;
  final list = _listValue(map['runTimes'] ?? map['runtimes']);
  if (list != null && list.isNotEmpty) return _intValue(list.first);
  return null;
}

double _ratingValue(dynamic value) {
  if (value is num) {
    final number = value.toDouble();
    if (number > 10) return number / 10;
    return number;
  }
  final number = double.tryParse(_stringValue(value) ?? '');
  if (number == null) return 0;
  return number > 10 ? number / 10 : number;
}

List<String> _alternateTitlesFromMap(Map<String, dynamic> map) {
  final result = <String>[];
  final seen = <String>{};

  void add(dynamic value) {
    if (value is String) {
      final title = value.trim();
      if (title.isNotEmpty && seen.add(title.toLowerCase())) {
        result.add(title);
      }
      return;
    }
    if (value is Map) {
      add(
        value['name'] ??
            value['title'] ??
            value['translatedName'] ??
            value['translatedTitle'] ??
            value['value'],
      );
      return;
    }
    if (value is List) {
      for (final item in value) {
        add(item);
      }
    }
  }

  for (final key in const [
    'aliases',
    'alternateNames',
    'alternateTitles',
    'translatedNames',
    'nameTranslations',
    'translations',
    'names',
    'titles',
  ]) {
    add(map[key]);
  }
  add(map['originalName'] ?? map['originalTitle'] ?? map['sortTitle']);
  return result;
}

List<String> _genresFromMap(Map<String, dynamic> map) {
  final values = _listValue(map['genres'] ?? map['genre']);
  if (values == null) return const [];
  final result = <String>[];
  for (final value in values) {
    final name = value is Map
        ? _stringValue(value['name'] ?? value['title'])
        : _stringValue(value);
    if (name != null && name.isNotEmpty && !result.contains(name)) {
      result.add(name);
    }
  }
  return result;
}

class _ArtworkSelection {
  const _ArtworkSelection({this.poster, this.backdrop});

  final String? poster;
  final String? backdrop;
}

_ArtworkSelection _selectArtwork(
  Map<String, dynamic> map, {
  bool preferBackdrop = false,
}) {
  final direct = _absoluteTvdbUrl(
    _firstValue(map, const [
      'image',
      'image_url',
      'imageUrl',
      'poster',
      'thumbnail',
    ]),
  );
  var poster = preferBackdrop ? null : direct;
  var backdrop = preferBackdrop ? direct : null;
  final entries = _artworkEntries(map['artworks'] ?? map['artwork']);
  for (final entry in entries) {
    final url = _absoluteTvdbUrl(
      _firstValue(entry, const [
        'image',
        'image_url',
        'imageUrl',
        'url',
        'thumbnail',
        'thumbnailUrl',
      ]),
    );
    if (url == null) continue;
    final typeId = _intValue(entry['type'] ?? entry['artworkType']);
    final type =
        _stringValue(
          entry['type'] ??
              entry['artworkType'] ??
              entry['name'] ??
              entry['slug'],
        )?.toLowerCase() ??
        '';
    final thumbnail = _absoluteTvdbUrl(
      _firstValue(entry, const ['thumbnail', 'thumbnailUrl', 'thumb']),
    );
    final isPoster = typeId == 2 || typeId == 7 || type.contains('poster');
    final isBackdrop =
        typeId == 1 ||
        typeId == 3 ||
        typeId == 6 ||
        typeId == 8 ||
        type.contains('background') ||
        type.contains('backdrop') ||
        type.contains('banner') ||
        type.contains('fanart');
    if (isPoster) {
      poster ??= thumbnail ?? url;
    } else if (isBackdrop) {
      backdrop ??= url;
    } else {
      poster ??= thumbnail ?? url;
      final width = _intValue(entry['width']);
      final height = _intValue(entry['height']);
      if (backdrop == null &&
          url != poster &&
          width != null &&
          height != null &&
          width > height) {
        backdrop = url;
      }
    }
  }
  return _ArtworkSelection(poster: poster, backdrop: backdrop);
}

List<String> _artworkStills(Map<String, dynamic> map) {
  final result = <String>[];
  for (final entry in _artworkEntries(map['artworks'] ?? map['artwork'])) {
    final type =
        _stringValue(
          entry['type'] ??
              entry['artworkType'] ??
              entry['name'] ??
              entry['slug'],
        )?.toLowerCase() ??
        '';
    final hasEpisode = entry['episodeId'] != null || entry['episode'] != null;
    final isStill = type.contains('still') || type.contains('episode');
    if (!hasEpisode && !isStill) continue;
    final url = _absoluteTvdbUrl(
      _firstValue(entry, const [
        'image',
        'image_url',
        'imageUrl',
        'url',
        'thumbnail',
        'thumbnailUrl',
      ]),
    );
    if (url != null && !result.contains(url)) result.add(url);
  }
  return result;
}

List<Map<String, dynamic>> _artworkEntries(dynamic value) {
  final list = _listValue(value);
  if (list != null) return _mapList(list);
  final map = _mapValue(value);
  if (map == null) return const [];
  if (map.containsKey('image') ||
      map.containsKey('image_url') ||
      map.containsKey('imageUrl')) {
    return [map];
  }
  return _mapList(map['artworks'] ?? map['artwork'] ?? map['items']);
}

String? _absoluteTvdbUrl(dynamic value) {
  final source = value is Map
      ? _firstValue(_mapValue(value) ?? const <String, dynamic>{}, const [
          'image',
          'image_url',
          'imageUrl',
          'url',
          'thumbnail',
          'thumbnailUrl',
        ])
      : value;
  final text = _firstString(source)?.trim();
  if (text == null || text.isEmpty) return null;
  if (text.startsWith('//')) return 'https:$text';
  if (text.startsWith('artworks.thetvdb.com/')) return 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri != null &&
      uri.hasScheme &&
      (uri.scheme == 'http' || uri.scheme == 'https')) {
    return uri.toString();
  }
  return '$theTvdbArtworkBaseUrl/${text.replaceFirst(RegExp(r'^/+'), '')}';
}

List<TmdCastMember> _castFromMap(Map<String, dynamic> map) {
  final result = <TmdCastMember>[];
  final seen = <String>{};

  void add(String? actor, String? character, String? image) {
    final name = actor?.trim() ?? '';
    if (name.isEmpty) return;
    final key = '$name|${character?.trim() ?? ''}';
    if (!seen.add(key)) return;
    result.add(
      TmdCastMember(
        name: name,
        character: character?.trim().isEmpty ?? true ? null : character!.trim(),
        profilePath: _absoluteTvdbUrl(image),
      ),
    );
  }

  final characters = _mapList(map['characters'] ?? map['character']);
  for (final character in characters) {
    final characterName = _stringValue(
      character['characterName'] ?? character['role'] ?? character['name'],
    );
    final actorName = _stringValue(
      character['personName'] ??
          character['peopleName'] ??
          character['actorName'] ??
          character['person_name'],
    );
    final people = _mapList(character['people'] ?? character['actors']);
    if (people.isNotEmpty) {
      for (final person in people) {
        final personName = _stringValue(
          person['name'] ?? person['personName'] ?? person['actorName'],
        );
        add(
          personName ?? actorName,
          _stringValue(
                person['characterName'] ??
                    person['character'] ??
                    person['role'],
              ) ??
              characterName,
          _firstValue(person, const [
            'personImgURL',
            'personImgUrl',
            'personImg',
            'image',
            'url',
          ]),
        );
      }
    } else {
      add(
        actorName ?? characterName,
        _stringValue(character['role'] ?? character['character']) ??
            characterName,
        _firstValue(character, const [
          'personImgURL',
          'personImgUrl',
          'personImg',
          'image',
          'url',
        ]),
      );
    }
  }

  final people = _mapList(map['people'] ?? map['cast'] ?? map['actors']);
  for (final person in people) {
    final actor = _stringValue(
      person['name'] ?? person['personName'] ?? person['actorName'],
    );
    final characterValues = _listValue(person['characters'] ?? person['roles']);
    if (characterValues == null || characterValues.isEmpty) {
      add(
        actor,
        _stringValue(person['character'] ?? person['role']),
        _firstValue(person, const [
          'personImgURL',
          'personImgUrl',
          'personImg',
          'image',
          'url',
        ]),
      );
      continue;
    }
    for (final value in characterValues) {
      final character = value is Map
          ? _stringValue(value['name'] ?? value['character'] ?? value['role'])
          : _stringValue(value);
      add(
        actor,
        character,
        _firstValue(person, const [
          'personImgURL',
          'personImgUrl',
          'personImg',
          'image',
          'url',
        ]),
      );
    }
  }
  return result;
}

String _normaliseScoreText(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _queryText(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (index) => index);
  for (var i = 0; i < a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0);
    current[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final substitution = previous[j] + (a[i] == b[j] ? 0 : 1);
      final insertion = current[j] + 1;
      final deletion = previous[j + 1] + 1;
      current[j + 1] = substitution < insertion
          ? substitution < deletion
                ? substitution
                : deletion
          : insertion < deletion
          ? insertion
          : deletion;
    }
    previous = current;
  }
  return previous.last;
}

int _romanNumber(String value) {
  const values = {
    'I': 1,
    'V': 5,
    'X': 10,
    'L': 50,
    'C': 100,
    'D': 500,
    'M': 1000,
  };
  var result = 0;
  var previous = 0;
  for (final character in value.toUpperCase().split('').reversed) {
    final number = values[character] ?? 0;
    if (number < previous) {
      result -= number;
    } else {
      result += number;
      previous = number;
    }
  }
  return result;
}
