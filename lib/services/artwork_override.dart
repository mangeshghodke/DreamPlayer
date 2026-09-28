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

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_memo ?? {}));
  }
}
