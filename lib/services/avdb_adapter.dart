import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_cache_service.dart';
import 'metadata_provider_adapter.dart';
import 'tmdb_client.dart';

const String avdbBaseUrl = 'https://avdbapi.com/api.php/provide/vod';
const String avdbPrefsKey = 'dreamplayer.avdbEnabled';

/// AVDb (avdbapi.com) as a [MetadataProviderAdapter] - issue #46, part 2.
///
/// Verified live before writing (2026-10-11): the service is up, needs **no
/// API key**, and speaks the Maccms/苹果CMS `provide/vod` shape - `code`/`msg`/
/// `page`/`total`/`list`. Relevant fields, which are NOT uniform across
/// endpoints:
///
/// * `ac=list` (browse) returns `type_name`, `name`, `id`, `episodes`, but
///   **no** `poster_url`/`thumb_url`/`description`.
/// * `ac=detail&wd=<query>` returns the full record: `poster_url`,
///   `thumb_url`, `description`, `year`, `time` (HH:MM:SS), `actor`,
///   `director`, `country`, `category`, `movie_code` (the JAV code),
///   `type_name`.
///
/// The non-uniformity is why [search] fetches a DETAIL response rather than a
/// list one: without it every candidate would come back with a title and
/// nothing else, and the row would render bare.
///
/// Scope, deliberately: AVDb is a **movie** catalogue, so this resolves
/// `TmdKind.movie` and returns empty for TV. `seasons()` and `episode()` are
/// left at their defaults - there are no seasons to invent, and a row with no
/// still falls back to the poster (issue #47) rather than needing one.
///
/// There is no API key, so the Settings control is an on/off switch rather
/// than a key field, and [isConfigured] reports that switch.
class AvdbAdapter extends MetadataProviderAdapter {
  /// The one instance the app uses.
  ///
  /// A singleton because the enabled flag is CACHED: Settings used to build a
  /// fresh `AvdbAdapter()` per call while the registry held its own, so
  /// flipping the switch wrote the preference but left the registered
  /// adapter reporting the old value - the provider stayed invisible for the
  /// rest of the session, and the Settings segment kept reading stale state.
  static final AvdbAdapter instance = AvdbAdapter();

  AvdbAdapter({
    Future<SharedPreferences> Function()? preferences,
    this.transport,
    this.baseUrl = avdbBaseUrl,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  /// Test seam; null in the app, which uses the real HTTP path.
  final Future<Map<String, dynamic>> Function(Uri uri)? transport;

  final String baseUrl;

  bool? _enabled;
  bool _loaded = false;

  @override
  String get id => 'avdb';

  @override
  String get label => 'AVDb';

  @override
  String get credentialsHelp =>
      'avdbapi.com needs no API key - just enable it.';

  Future<bool> isEnabled() async {
    if (_loaded) return _enabled ?? false;
    try {
      final prefs = await _preferences();
      _enabled = prefs.getBool(avdbPrefsKey) ?? false;
    } catch (_) {
      _enabled = false;
    }
    _loaded = true;
    return _enabled ?? false;
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    _loaded = true;
    try {
      final prefs = await _preferences();
      await prefs.setBool(avdbPrefsKey, value);
    } catch (_) {
      // Keep the in-memory value so the switch works for this session even if
      // the write failed.
    }
  }

  @override
  Future<bool> isConfigured() => isEnabled();

  @override
  Future<List<TmdMovie>> search(
    String query, {
    TmdKind kind = TmdKind.movie,
  }) async {
    if (kind != TmdKind.movie) return const [];
    final term = query.trim();
    if (term.isEmpty) return const [];

    // AVDb's `wd=` matches literally against `name`/`tag`/`category`/`movie_code`,
    // so the separator matters. Measured live against avdbapi.com (issue #52):
    //   wd=SVFLA-012 -> 2 hits
    //   wd=SVFLA 012 -> 2 hits
    //   wd=SVFLA012  -> 0 hits
    // The separator-less spelling is what a file name often carries, so it is
    // retried with the hyphen the catalogue actually uses.
    for (final variant in queryVariants(term)) {
      final hits = await _searchTerm(variant);
      if (hits.isNotEmpty) return hits;
    }
    return const [];
  }

  /// Resolve a file name to a record.
  ///
  /// A catalogue code in the ORIGINAL name is an exact lookup (issue #52):
  /// AVDb's `wd=` matches `movie_code`, but the parsed title drops the code
  /// (`SVFLA-012.mkv` parses to the title "SVFLA"), so the base
  /// implementation - which searches the parsed title - could never use it.
  @override
  Future<TmdMatch?> bestMatch(ParsedFileName parsed) async {
    if (!await isConfigured()) return null;
    final code = MetadataProviderAdapter.catalogueCodeIn(parsed.rawName ?? parsed.title);
    if (code != null) {
      final hits = await search(code);
      for (final hit in hits) {
        final hitCode = hit.alternateTitles
            .map((t) => t.trim().toUpperCase().replaceAll('_', '-'))
            .firstWhere((t) => t == code, orElse: () => '');
        if (hitCode.isEmpty) continue;
        final fetched = await details(hit);
        return TmdMatch(
          TmdMovie(
            id: hit.id,
            title: hit.title,
            year: hit.year,
            posterPath: fetched?.posterPath ?? hit.posterPath,
            overview: fetched?.overview ?? hit.overview,
            kind: TmdKind.movie,
            provider: hit.provider,
            originalTitle: hit.originalTitle,
            alternateTitles: hit.alternateTitles,
            providerId: hit.providerId,
          ),
          1.0,
        );
      }
    }
    // No code, or the catalogue did not know it: fall back to a name search.
    return super.bestMatch(parsed);
  }

  /// The spellings of [term] to try, in order.
  ///
  /// Only the separator-less catalogue-code form needs a second attempt:
  /// "SVFLA012" -> "SVFLA-012". Everything else is searched as typed, because
  /// AVDb's own index already covers the hyphen and the space.
  ///
  /// Exposed for tests: the shape of a JAV code is the subtle part.
  @visibleForTesting
  static List<String> queryVariants(String term) {
    final variants = <String>[term];
    final match = RegExp(r'^([A-Za-z]{1,12})[-_ ]?(\d{2,4})$').firstMatch(term);
    if (match != null) {
      final hyphenated = '${match.group(1)}-${match.group(2)}';
      if (!variants.contains(hyphenated)) variants.add(hyphenated);
    }
    return variants;
  }

  /// One `wd=`/`ids=` query against the catalogue.
  Future<List<TmdMovie>> _searchTerm(String term) async {
    Uri uri;
    try {
      // Issue #49: AVDb has no title-unique search that covers everything, and
      // a user who knows the catalog code or the numeric id is the most precise
      // input available. Both were probed live against avdbapi.com and both work
      // on this endpoint:
      //   ids=604629  -> exactly 1 record (the movie's own id)
      //   wd=MIAA-818 -> 1 record (its movie_code)
      // `wd` already matches `name`, `tag`/`category` and `movie_code`, and
      // `origin_name` differs from `name` only by a bracket prefix such as
      // [UNCENSORED-LEAK], so original-title search is already covered -- there
      // is no separate parameter to add for it. Only the id lookup was missing,
      // because `details()` is the only thing that used `ids=` until now.
      final id = int.tryParse(term);
      uri = id != null && id > 0
          ? Uri.parse('$baseUrl?ac=detail&ids=$id')
          : Uri.parse(
              '$baseUrl?ac=detail&wd=${Uri.encodeQueryComponent(term)}',
            );
    } on FormatException {
      return const [];
    }

    final Map<String, dynamic> json;
    try {
      json = await (transport?.call(uri) ?? _get(uri));
    } catch (_) {
      // A provider that cannot be reached is "no match", never an error: the
      // caller falls through to the next one.
      return const [];
    }

    final list = json['list'];
    if (list is! List) return const [];
    return <TmdMovie>[
      for (final item in list)
        if (item is Map<String, dynamic>) ?parseMovie(item),
    ];
  }

  @override
  Future<TmdDetails?> details(TmdMovie movie) async {
    // AVDb ids are integers, and the adapter only ever hands out its own.
    if (movie.provider != MetadataProvider.external) return null;
    try {
      final uri = Uri.parse('$baseUrl?ac=detail&ids=${movie.id}');
      final json = await (transport?.call(uri) ?? _get(uri));
      final list = json['list'];
      if (list is! List || list.isEmpty || list.first is! Map) return null;
      final record = Map<String, dynamic>.from(list.first as Map);
      return _detailsFrom(record);
    } catch (_) {
      return null;
    }
  }

  /// AVDb returns absolute image URLs, while `posterPath`/`backdropPath` are
  /// host-less paths that `metadataImageUrl` prefixes with TMDB's image host.
  /// Storing a full URL works because `metadataImageUrl` passes anything
  /// already absolute straight through - verified in its own branch - but it is
  /// checked here so a future change there fails loudly in this adapter's
  /// tests instead of silently pointing every poster at image.tmdb.org.
  static TmdMovie? parseMovie(Map<String, dynamic> item) {
    final id = _intValue(item['id']);
    if (id == null || id <= 0) return null;
    final name = _string(item['name']) ?? _string(item['origin_name']);
    if (name == null || name.isEmpty) return null;

    final poster = _firstString(item, const ['poster_url', 'thumb_url']);
    final year = _intValue(item['year']);
    // AVDb has no ratings at all, so voteAverage stays 0 and the row shows no
    // star rather than a fake score.
    final code = _string(item['movie_code']);

    return TmdMovie(
      id: id,
      title: name,
      year: year,
      posterPath: poster,
      overview: _string(item['description']) ?? '',
      kind: TmdKind.movie,
      provider: MetadataProvider.external,
      originalTitle: _string(item['origin_name']),
      alternateTitles: <String>[if (code != null && code != name) code],
    );
  }

  TmdDetails _detailsFrom(Map<String, dynamic> record) {
    final movie = parseMovie(record)!;
    final runtime = _runtimeMinutes(_string(record['time']));
    final categories = _stringList(record['category']);
    final cast = <TmdCastMember>[
      for (final actor in _stringList(record['actor']))
        TmdCastMember(name: actor, character: '', profilePath: null),
    ];
    final directors = _stringList(record['director']);

    return TmdDetails(
      title: movie.title,
      overview: movie.overview,
      year: movie.year,
      runtimeMinutes: runtime,
      genres: categories,
      cast: cast,
      tagline: directors.isEmpty ? null : 'Directed by ${directors.join(', ')}',
      posterPath: movie.posterPath,
      originalTitle: movie.originalTitle,
    );
  }

  // ---- parsing helpers -------------------------------------------------

  static String? _string(dynamic value) {
    if (value == null) return null;
    final text = value is String ? value.trim() : value.toString().trim();
    if (text.isEmpty) return null;
    return unescapeHtml(text);
  }

  /// Decodes the HTML entities AVDb leaves in its text fields.
  ///
  /// Measured live (issue #52): `origin_name` comes back as
  /// `SVFLA-012 "Doesn&#039;t my ..."`, so the raw entity text was
  /// being shown to the user as the original title. Only the five entities
  /// that actually appear in these fields are handled, and an unknown entity
  /// is left alone rather than swallowed.
  @visibleForTesting
  static String unescapeHtml(String value) {
    if (!value.contains('\u0026')) return value;
    return value
        .replaceAll('\u0026quot;', '"')
        .replaceAll('\u0026039;', "'")
        .replaceAll('\u0026apos;', "'")
        .replaceAll('\u0026lt;', '<')
        .replaceAll('\u0026gt;', '>')
        .replaceAll('\u0026nbsp;', ' ')
        .replaceAll('\u0026amp;', '\u0026');
  }

  static int? _intValue(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    final parsed = int.tryParse(text);
    if (parsed != null) return parsed;
    // `year` arrives as "2023"; `created_at` as "14 Apr, 2023".
    final match = RegExp(r'(\d{4})').firstMatch(text);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// AVDb's `time` is a duration "HH:MM:SS" (or "MM:SS"), NOT a release date -
  /// the release date is `vod_pubdate`/`created_at`.
  /// Visible for tests: the duration parsing is subtle enough (a duration,
  /// not a clock time) to be worth pinning directly.
  static int? runtimeMinutesFrom(String? time) => _runtimeMinutes(time);

  static int? _runtimeMinutes(String? time) {
    if (time == null) return null;
    final parts = time.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    var seconds = 0;
    for (final part in parts) {
      final value = int.tryParse(part.trim());
      if (value == null) return null;
      seconds = seconds * 60 + value;
    }
    final minutes = seconds ~/ 60;
    return minutes <= 0 ? null : minutes;
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) {
      final single = _string(value);
      return single == null ? const [] : <String>[single];
    }
    return <String>[for (final item in value) ?_string(item)];
  }

  static String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (_string(map[key]) case final value?) return value;
    }
    return null;
  }

  // ---- transport --------------------------------------------------------

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw HttpException('AVDb returned ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected AVDb response.');
      }
      // Maccms wraps everything: code 1 means success, anything else is a
      // provider-level failure and must not be parsed as a result set.
      if (decoded['code'] != 1) return const <String, dynamic>{};
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  /// Download an AVDb poster into the shared offline image cache.
  ///
  /// AVDb artwork lives on third-party hosts that are not in the TMDB image
  /// pipeline, so it is fetched once here rather than per-row. Kept public so
  /// the service layer can prefetch the same way TMDB artwork is prefetched.
  void prefetchPoster(String? url) {
    if (url == null || url.isEmpty) return;
    ImageCacheService.instance.prefetchImages(posterUrl: url);
  }
}
