import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'metadata_provider_adapter.dart';
import 'tmdb_client.dart';

const String r18devBaseUrl = 'https://r18.dev';
const String r18devPrefsKey = 'dreamplayer.r18devEnabled';

/// r18.dev as a [MetadataProviderAdapter] - issue #52, second half.
///
/// The reporter asked for "a more reliable source for JAV metadata (poster,
/// cast, release date, studio, genres)" and pointed at r18.dev's JSON API.
/// The endpoint was verified live before writing (2026-10-25):
///
/// * `GET /videos/vod/movies/detail/-/dvd_id=<code>/json` - the **code
///   lookup**. The site strips spaces from what you type, so the code has to
///   be space-free; both `SVFLA-012` and `SVFLA012` resolve to the same
///   record. The reply is a small record: `content_id`, `title`,
///   `release_date`, `runtime_minutes`, `images.jacket_image.large2`,
///   `actresses`, `categories`, `maker`.
/// * `GET /videos/vod/movies/detail/-/combined=<content_id>/json` - the
///   **full record**: `jacket_full_url`, `gallery`, `actresses`/`actors`/
///   `directors` with names, `categories` with English and Japanese names,
///   `maker_name_ja`/`label_name_ja` (the studio), `release_date`,
///   `runtime_mins`, and the Japanese plus machine-translated English title.
///
/// Two things shaped the design:
///
/// * **The catalogue is keyed by code, not by title.** There is no free-text
///   search endpoint, so a title query finds nothing - only a catalogue code
///   does. That is the common case for this kind of file anyway, because the
///   code is in the file name.
/// * **`content_id` is a STRING** ("1svfla012"), while `TmdMovie.id` is an
///   integer. The real id is carried in `TmdMovie.providerId` and [id] holds a
///   stable FNV-1a hash of it, so the cache key stays unique and the record
///   can still be re-fetched after a restart.
///
/// No API key is involved, so the Settings control is an on/off switch, like
/// AVDb's.
class R18DevAdapter extends MetadataProviderAdapter {
  /// The one instance the app uses - the enabled flag is cached, so a fresh
  /// instance per call would report a stale value (the same trap AVDb had).
  static final R18DevAdapter instance = R18DevAdapter();

  R18DevAdapter({
    Future<SharedPreferences> Function()? preferences,
    this.transport,
    this.baseUrl = r18devBaseUrl,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  /// Test seam; null in the app, which uses the real HTTP path.
  final Future<Map<String, dynamic>> Function(Uri uri)? transport;

  final String baseUrl;

  bool? _enabled;
  bool _loaded = false;

  @override
  String get id => 'r18dev';

  @override
  String get label => 'r18.dev';

  @override
  String get credentialsHelp => 'r18.dev needs no API key - just enable it.';

  Future<bool> isEnabled() async {
    if (_loaded) return _enabled ?? false;
    try {
      final prefs = await _preferences();
      _enabled = prefs.getBool(r18devPrefsKey) ?? false;
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
      await prefs.setBool(r18devPrefsKey, value);
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
    if (!await isConfigured()) return const [];
    if (kind != TmdKind.movie) return const [];
    // The typed query may be the bare code, or a whole file name that
    // contains it.
    final code = codeFromQuery(query) ?? MetadataProviderAdapter.catalogueCodeIn(query);
    if (code == null) return const [];
    final record = await _lookupCode(code);
    if (record == null) return const [];
    final movie = parseMovie(record);
    return movie == null ? const [] : <TmdMovie>[movie];
  }

  /// The full record for a title this adapter returned.
  @override
  Future<TmdDetails?> details(TmdMovie movie) async {
    if (!await isConfigured()) return null;
    if (movie.provider != MetadataProvider.external) return null;
    final contentId = movie.providerId;
    if (contentId == null || contentId.isEmpty) return null;
    final record = await _getJson(
      '$baseUrl/videos/vod/movies/detail/-/combined=$contentId/json',
    );
    if (record == null) return null;
    return detailsFrom(record);
  }

  /// Resolve a file name to a record by its catalogue code.
  ///
  /// The default implementation scores by TITLE, which cannot work here: the
  /// record's title is the marketing blurb ("Isn't My Ass Delicious? ...")
  /// while the file name carries the code. A code lookup is exact, so it is
  /// an exact match by construction.
  @override
  Future<TmdMatch?> bestMatch(ParsedFileName parsed) async {
    if (!await isConfigured()) return null;
    // The code has to come from the ORIGINAL name: the parsed title drops it
    // (`SVFLA-012.mkv` parses to "SVFLA"). See
    // [MetadataProviderAdapter.catalogueCodeIn].
    final code = MetadataProviderAdapter.catalogueCodeIn(parsed.rawName ?? parsed.title);
    if (code == null) return null;
    final record = await _lookupCode(code);
    if (record == null) return null;
    final movie = parseMovie(record);
    if (movie == null) return null;
    final fetched = await details(movie);
    return TmdMatch(
      TmdMovie(
        id: movie.id,
        title: movie.title,
        year: movie.year,
        posterPath: fetched?.posterPath ?? movie.posterPath,
        overview: fetched?.overview ?? movie.overview,
        kind: TmdKind.movie,
        provider: movie.provider,
        originalTitle: movie.originalTitle,
        alternateTitles: movie.alternateTitles,
        providerId: movie.providerId,
      ),
      1.0,
    );
  }

  /// The catalogue code in a query, or null when there is not one.
  ///
  /// The site accepts the code with or without its hyphen (`SVFLA-012` and
  /// `SVFLA012` are the same record) and strips spaces, so the code is
  /// normalised to upper case with no separator. A title that merely CONTAINS
  /// a code is not enough - the code has to be the whole query, because
  /// r18.dev has no partial-code search.
  ///
  /// Exposed for tests: recognising a code is the whole matching rule here.
  @visibleForTesting
  static String? codeFromQuery(String query) {
    final cleaned = query
        .trim()
        .replaceAll(' ', '')
        .replaceAll('"', '')
        .replaceAll("'", '')
        .toUpperCase();
    if (cleaned.isEmpty) return null;
    // A catalogue code: two to six letters, then two to five digits.
    final match = RegExp(r'^([A-Z]{2,6})-?(\d{2,5})$').firstMatch(cleaned);
    if (match == null) return null;
    return '${match.group(1)}-${match.group(2)}';
  }

  /// The leading catalogue code in a file name, or null.
  ///
  /// A file is often named "ABC-123 Some Title", so the code is taken from
  /// the front of the name rather than requiring the whole thing to be a
  /// code.
  @visibleForTesting
  static String? codeFromTitle(String title) {
    final match = RegExp(
      r'^([A-Za-z]{2,6})[-\s]?(\d{2,5})\b',
    ).firstMatch(title.trim());
    if (match == null) return null;
    return '${match.group(1)!.toUpperCase()}-${match.group(2)}';
  }

  /// The code lookup record.
  Future<Map<String, dynamic>?> _lookupCode(String code) async {
    final record = await _getJson(
      '$baseUrl/videos/vod/movies/detail/-/dvd_id=$code/json',
    );
    if (record == null) return null;
    // A miss comes back as a record without a content_id, not as an error.
    final contentId = record['content_id'];
    if (contentId is! String || contentId.isEmpty) return null;
    return record;
  }

  /// A lookup record as a [TmdMovie].
  ///
  /// The lookup reply carries a small `images` map rather than a poster URL,
  /// and `release_date` is already a "YYYY-MM-DD" string.
  static TmdMovie? parseMovie(Map<String, dynamic> record) {
    final contentId = record['content_id'];
    if (contentId is! String || contentId.isEmpty) return null;
    final title = _string(record['title']) ?? _string(record['title_en']);
    if (title == null || title.isEmpty) return null;

    final images = record['images'];
    String? poster;
    if (images is Map) {
      final jacket = images['jacket_image'];
      if (jacket is Map) {
        poster = _string(jacket['large2']) ?? _string(jacket['large']);
      }
    }
    poster ??= _string(record['jacket_full_url']);

    final release = _string(record['release_date']);
    final year = release != null && release.length >= 4
        ? int.tryParse(release.substring(0, 4))
        : null;

    final dvdId = _string(record['dvd_id']);
    return TmdMovie(
      id: stableId(contentId),
      title: title,
      year: year,
      posterPath: poster,
      overview: _string(record['comment_en']) ?? '',
      kind: TmdKind.movie,
      provider: MetadataProvider.external,
      originalTitle: _string(record['title_ja']),
      alternateTitles: <String>[if (dvdId != null && dvdId != title) dvdId],
      providerId: contentId,
    );
  }

  /// The full `combined` record as a [TmdDetails].
  ///
  /// Everything the reporter asked for is here: the poster
  /// (`jacket_full_url`), the cast (`actresses`/`actors`), the studio
  /// (`maker_name_*`/`label_name_*`), the genres (`categories`) and the
  /// release date.
  static TmdDetails? detailsFrom(Map<String, dynamic> record) {
    final title = _string(record['title_en']) ?? _string(record['title_ja']);
    if (title == null || title.isEmpty) return null;

    final release = _string(record['release_date']);
    final year = release != null && release.length >= 4
        ? int.tryParse(release.substring(0, 4))
        : null;

    final cast = <TmdCastMember>[
      for (final person in _people(record['actresses'])) person,
      for (final person in _people(record['actors'])) person,
    ];
    final genres = <String>[
      for (final category in _categories(record['categories']))
        if (category != null && !_isArtifactGenre(category)) category,
    ];
    final makers = <String>[
      ?_string(record['maker_name_en']),
      ?_string(record['maker_name_ja']),
    ];
    final labels = <String>[
      ?_string(record['label_name_en']),
      ?_string(record['label_name_ja']),
    ];
    final studio = makers.isNotEmpty
        ? makers.first
        : (labels.isNotEmpty ? labels.first : null);
    final directors = _people(record['directors']);

    return TmdDetails(
      title: title,
      overview: _string(record['comment_en']) ?? '',
      year: year,
      runtimeMinutes: _int(record['runtime_mins']),
      genres: genres,
      cast: cast,
      // The studio is the "maker"/"label" - there is no studio field in
      // TmdDetails, and the tagline is where the details screen shows it.
      tagline: _tagline(studio, directors),
      posterPath:
          _string(record['jacket_full_url']) ??
          _string(record['jacket_thumb_url']),
      stills: _gallery(record),
      originalTitle: _string(record['title_ja']),
    );
  }

  /// A stable positive integer for a string id.
  ///
  /// FNV-1a, 64-bit. `String.hashCode` is NOT stable across runs or Flutter
  /// releases, so it cannot be used for a value that ends up in a persisted
  /// cache key.
  @visibleForTesting
  static int stableId(String value) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    // Must be positive: the dedupe rule drops anything with id <= 0.
    final masked = hash & 0x7FFFFFFFFFFFFFFF;
    return masked == 0 ? 1 : masked;
  }

  // ---- parsing helpers -------------------------------------------------

  static String? _string(dynamic value) {
    if (value == null) return null;
    final text = value is String ? value.trim() : value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static int? _int(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  static List<TmdCastMember> _people(dynamic value) {
    if (value is! List) return const [];
    final out = <TmdCastMember>[];
    for (final entry in value) {
      if (entry is! Map) continue;
      final name =
          _string(entry['name_romaji']) ??
          _string(entry['name_kanji']) ??
          _string(entry['name_kana']) ??
          // The CODE lookup reply carries a bare `name`.
          _string(entry['name']);
      if (name == null) continue;
      out.add(TmdCastMember(name: name, character: ''));
    }
    return out;
  }

  static List<String?> _categories(dynamic value) {
    if (value is! List) return const [];
    final out = <String?>[];
    for (final entry in value) {
      if (entry is! Map) {
        out.add(_string(entry));
        continue;
      }
      out.add(_string(entry['name_en']) ?? _string(entry['name_ja']));
    }
    return out;
  }

  /// The one-line subtitle under the title: the studio, and the director when
  /// there is one.
  static String? _tagline(String? studio, List<TmdCastMember> directors) {
    final parts = <String>[
      if (studio != null && studio.isNotEmpty) studio,
      if (directors.isNotEmpty)
        'Directed by ${directors.map((d) => d.name).join(', ')}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// "Sample Video" is not a genre - it is the site's own marker for the
  /// preview clip, and it comes back in the `categories` list of every record.
  static bool _isArtifactGenre(String value) {
    const artifacts = {'sample video', 'over 4 hours'};
    return artifacts.contains(value.trim().toLowerCase());
  }

  /// The sample-video frames, as the details screen's stills gallery.
  static List<String> _gallery(Map<String, dynamic> record) {
    final gallery = record['gallery'];
    if (gallery is! List) return const [];
    final out = <String>[];
    for (final entry in gallery) {
      if (entry is! Map) continue;
      final url = _string(entry['image_full']) ?? _string(entry['image_thumb']);
      if (url != null) out.add(url);
      if (out.length >= 16) break;
    }
    return out;
  }

  // ---- transport --------------------------------------------------------

  Future<Map<String, dynamic>?> _getJson(String url) async {
    final uri = Uri.parse(url);
    try {
      final json = await (transport?.call(uri) ?? _get(uri));
      if (json.isEmpty) return null;
      return json;
    } catch (_) {
      // A provider that cannot be reached is "no match", never an error.
      return null;
    }
  }

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
        throw HttpException('r18.dev returned ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected r18.dev response.');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }
}
