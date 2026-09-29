import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'tmdb_client.dart';

/// Which piece of artwork the user is overriding.
enum ArtworkKind { poster, backdrop }

/// A single candidate image for a movie/show, from any configured provider.
///
/// [url] is stored in the *same* slot as a TMDB `poster_path`, i.e. it may be a
/// bare TMDB file path (`/abc.jpg`) or a full URL (TheTVDB artwork lives on a
/// different host). `metadataImageUrl` already passes absolute URLs through and
/// prefixes TMDB paths with the CDN, so a chosen image can be written straight
/// into [TmdMovie.posterPath] without any per-provider special-casing.
class MetaImage {
  const MetaImage({
    required this.url,
    required this.provider,
    this.width = 0,
    this.height = 0,
    this.voteAverage = 0,
    this.language,
  });

  final String url;
  final MetadataProvider provider;
  final int width;
  final int height;
  final double voteAverage;
  final String? language;

  /// Width/height, or 0 when the provider didn't report dimensions.
  double get aspect => (width > 0 && height > 0) ? width / height : 0;

  /// Display URL for a [width]-sized render (TMDB CDN sizing / TheTVDB as-is).
  String displayUrl(int width) {
    final full = metadataImageUrl(url);
    if (full == null) return url;
    // Only TMDB paths can be re-sized through the CDN; TheTVDB URLs are already
    // absolute and are served at their native resolution.
    if (url.startsWith('http://') || url.startsWith('https://')) return full;
    return metadataImageUrl(url, width: width) ?? full;
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'provider': provider.name,
        if (width > 0) 'width': width,
        if (height > 0) 'height': height,
        if (voteAverage != 0) 'voteAverage': voteAverage,
        if (language != null && language!.isNotEmpty) 'language': language,
      };

  factory MetaImage.fromJson(Map<String, dynamic> json) => MetaImage(
        url: json['url'] as String? ?? '',
        provider: json['provider'] == 'theTvdb'
            ? MetadataProvider.theTvdb
            : MetadataProvider.tmdb,
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        voteAverage: (json['voteAverage'] as num?)?.toDouble() ?? 0,
        language: json['language'] as String?,
      );
}

/// User's "Change poster" / "Change backdrop" picks, keyed by the same
/// [TmdStore.identityKeyFor] identity key the rest of the metadata cache uses.
///
/// Deliberately a **separate** prefs store rather than a field on [TmdMeta]:
/// re-resolution (stale movie-part re-resolve, `seasonFor` merges, details
/// enrichment, TheTVDB re-fetch) replaces the cached [TmdMeta] wholesale, so an
/// override stored inside it would be silently dropped on the next refresh. Here
/// it is applied at read time by [TmdService.metaFor], so a pick survives every
/// kind of re-resolution and — just as important — survives a "Fix match" that
/// changes which film this key points at.
class ArtworkOverrideStore {
  ArtworkOverrideStore._();

  static const String _prefsKey = 'dreamplayer.artworkOverrides';

  /// Maps an identity key to a map of ArtworkKind name → [MetaImage] JSON.
  static Map<String, Map<String, dynamic>>? _memo;

  /// Clears the in-memory memo so a test can start from a known state.
  /// [load] short-circuits once memoised, so without this each test would
  /// inherit the previous one's overrides.
  static void resetForTest() => _memo = null;

  static Future<void> load() async {
    if (_memo != null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      _memo = {};
      return;
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _memo = json.map(
        (key, value) => MapEntry(key, (value as Map).cast<String, dynamic>()),
      );
    } catch (_) {
      _memo = {};
    }
  }

  static Map<String, dynamic> _entryFor(String key) {
    final map = _memo ??= {};
    return map.putIfAbsent(key, () => <String, dynamic>{});
  }

  /// The picked image for [key]/[kind], or null when the user hasn't chosen one.
  static MetaImage? overrideFor(String key, ArtworkKind kind) {
    final raw = (_memo ?? const <String, dynamic>{})[key]?[kind.name];
    if (raw is! Map) return null;
    try {
      final image = MetaImage.fromJson(raw.cast<String, dynamic>());
      return image.url.isEmpty ? null : image;
    } catch (_) {
      return null;
    }
  }

  static bool isOverridden(String key, ArtworkKind kind) =>
      overrideFor(key, kind) != null;

  static Future<void> set(String key, ArtworkKind kind, MetaImage image) async {
    if (key.isEmpty || image.url.isEmpty) return;
    await load();
    _entryFor(key)[kind.name] = image.toJson();
    await _persist();
  }

  /// Drops one override, letting the provider default show through again.
  static Future<void> clear(String key, ArtworkKind kind) async {
    await load();
    final entry = (_memo ?? const <String, dynamic>{})[key];
    if (entry is Map && entry.remove(kind.name) != null) {
      await _persist();
    }
  }

  /// Drops every stored pick, so a provider change starts from the new
  /// provider's default artwork instead of keeping a pick that was chosen
  /// against the old one.
  static Future<void> clearAll() async {
    _memo = {};
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_memo ?? {}));
  }
}

/// Normalised form used to match a title across providers: lowercase,
/// punctuation and whitespace stripped. "Komi-san", "Komi san" and
/// "KOMI SAN" all collapse to `komisan`.
String normaliseMetaTitle(String title) =>
    title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '').trim();

/// Verified TMDB ↔ TheTVDB id pairs, keyed by normalised title + kind.
///
/// The two providers share no ids, so finding one title in both means a title
/// search. That search is strict (exact normalised-title match) and, for many
/// real titles, simply misses — aliases, Japanese vs English names, subtitle
/// variants. This store turns that into a one-off: a pair is recorded **only
/// after a strict match has already succeeded**, so a map hit can never
/// surface artwork from a different show. Every later open of that title is a
/// map lookup instead of a network round-trip.
///
/// Misses are deliberately not cached. A miss usually means the title really
/// isn't in the other provider, and remembering that would keep a newly-added
/// provider (or a fixed alias) from ever contributing.
class CrossProviderIdStore {
  CrossProviderIdStore._();

  static const String _prefsKey = 'dreamplayer.crossProviderIds';

  /// 'movie:komisan' → {'tmdb': 197189, 'theTvdb': 371980}
  static Map<String, Map<String, int>>? _memo;

  static String _key(String title, TmdKind kind) =>
      '${kind.name}:${normaliseMetaTitle(title)}';

  /// Clears the in-memory memo so a test can start from a known state.
  static void resetForTest() => _memo = null;

  static Future<void> load() async {
    if (_memo != null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      _memo = {};
      return;
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _memo = json.map(
        (key, value) => MapEntry(
          key,
          (value as Map).map((k, v) => MapEntry(k as String, (v as num).toInt())),
        ),
      );
    } catch (_) {
      _memo = {};
    }
  }

  static int? lookup(
    String title,
    TmdKind kind,
    MetadataProvider provider,
  ) =>
      (_memo ?? const <String, Map<String, int>>{})[_key(title, kind)]?[provider.name];

  /// Records one provider's id, preserving any id already stored for the other.
  static Future<void> record(
    String title,
    TmdKind kind,
    MetadataProvider provider,
    int id,
  ) async {
    if (id <= 0) return;
    await load();
    final map = _memo ??= {};
    final entry = map.putIfAbsent(_key(title, kind), () => <String, int>{});
    if (entry[provider.name] == id) return;
    entry[provider.name] = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(map));
  }
}
