import 'dart:convert';
import 'dart:io';

import '../utils/skip_segments.dart';
import 'aniskip_store.dart';

/// Community skip-timestamp lookup (issue #60).
///
/// Two keyless, free APIs are chained:
///
/// 1. **AniList** (GraphQL, no key) maps the TMDB title DreamPlayer already
///    resolved to a MAL id: `Page { media(search: …, type: ANIME) { idMal } }`.
///    AniList has no TMDB-id argument, so the title search is the bridge; the
///    MAL id is cached per TMDB title in [AniskipStore].
/// 2. **AniSkip v2** (`GET api.aniskip.com/v2/skip-times/{malId}/{episode}`)
///    returns the actual intro/recap/credits intervals for that episode.
///    `types` is a REPEATED query param and `episodeLength` (seconds) is
///    required; a 404 body (`found: false`) means "no data".
///
/// Note: AniSkip is anime-only (MAL-keyed). Live-action shows/movies get
/// their skip segments from embedded chapter names instead — the IntroDB
/// domain named in the issue (`api.introdb.dev`) does not resolve anymore
/// (checked 2026-11-04), so AniSkip is the working community source.
///
/// Results (including negatives) are cached in [AniskipStore], so playback
/// from SMB/USB/offline uses the cache without any network.
class AniskipClient {
  AniskipClient({HttpClient? httpClient}) : _http = httpClient;

  static const String anilistUrl = 'https://graphql.anilist.co';
  static const String aniskipBaseUrl = 'https://api.aniskip.com';

  final HttpClient? _http;

  HttpClient get _client => _http ?? HttpClient();

  /// Segments for one episode of a TMDB TV show. Cache first, then network.
  /// Returns an empty list when the show/episode is known to have no data,
  /// null when the lookup could not run at all (offline etc.).
  Future<List<SkipSegment>?> segmentsForEpisode({
    required int tmdbTvId,
    required String providerKey,
    required String title,
    required int season,
    required int episode,
    int? durationMs,
  }) async {
    final key = AniskipStore.episodeKey(tmdbTvId, season, episode);
    final cached = await AniskipStore.cached(key);
    if (cached != null) return cached.segments;

    final malId = await resolveMalId(providerKey: providerKey, title: title);
    if (malId == null) {
      await AniskipStore.save(key, null);
      return const [];
    }
    final segments = await fetchSkipTimes(
      malId: malId,
      episode: episode,
      durationMs: durationMs,
    );
    await AniskipStore.save(key, segments);
    return segments;
  }

  /// TMDB title → MAL id via AniList, cached under [AniskipStore.malKey].
  Future<int?> resolveMalId({
    required String providerKey,
    required String title,
  }) async {
    final malKey = AniskipStore.malKey(providerKey);
    final cached = await AniskipStore.cachedMalId(malKey);
    if (cached != null) return cached;
    final body = await _post(
      anilistUrl,
      jsonEncode({
        'query':
            '{ Page(perPage: 8) { media(search: ${jsonEncode(title)}, type: ANIME, sort: SEARCH_MATCH) { idMal title { romaji } } } }',
      }),
    );
    final malId = body == null ? null : parseAniListMalId(body, title);
    if (malId != null) await AniskipStore.saveMalId(malKey, malId);
    return malId;
  }

  /// AniSkip v2 skip-times for one episode. Null on network/parse failure,
  /// empty list when AniSkip has no data (HTTP 404 / found:false).
  Future<List<SkipSegment>?> fetchSkipTimes({
    required int malId,
    required int episode,
    int? durationMs,
  }) async {
    final durSec =
        durationMs != null && durationMs > 0 ? durationMs / 1000 : 0;
    // `types` must be REPEATED params, not comma-joined — the API rejects a
    // single comma-joined value with a 400 validation error.
    final uri2 = Uri.parse(
      '$aniskipBaseUrl/v2/skip-times/$malId/$episode'
      '?types=op&types=ed&types=recap&types=mixed-op&types=mixed-ed'
      '&episodeLength=${durSec.toStringAsFixed(3)}',
    );
    try {
      final client = _client;
      final req = await client
          .getUrl(uri2)
          .timeout(const Duration(seconds: 6));
      final res = await req.close().timeout(const Duration(seconds: 6));
      final body =
          await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 6));
      if (res.statusCode == 404) return const [];
      if (res.statusCode != 200) return null;
      return parseAniSkipResponse(body);
    } catch (_) {
      return null; // offline must never break playback
    } finally {
      if (_http == null) _client.close(force: true);
    }
  }

  Future<String?> _post(String url, String body) async {
    try {
      final client = _client;
      final req = await client
          .postUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
      req.headers.contentType = ContentType.json;
      req.write(body);
      final res = await req.close().timeout(const Duration(seconds: 6));
      final text =
          await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      return text;
    } catch (_) {
      return null;
    } finally {
      if (_http == null) _client.close(force: true);
    }
  }

  /// Parse an AniSkip v2 response body into segments. Pure — unit-tested.
  /// skipType mapping: op/mixed-op → intro, recap → recap, ed/mixed-ed →
  /// credits. Seconds → ms.
  static List<SkipSegment> parseAniSkipResponse(String body) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    if (decoded['found'] != true) return const [];
    final results = decoded['results'];
    if (results is! List) return const [];
    final out = <SkipSegment>[];
    for (final r in results) {
      if (r is! Map) continue;
      final interval = r['interval'];
      if (interval is! Map) continue;
      final start = interval['startTime'];
      final end = interval['endTime'];
      if (start is! num || end is! num) continue;
      final type = r['skipType'] as String?;
      final kind = switch (type) {
        'op' || 'mixed-op' => SkipSegmentKind.intro,
        'recap' => SkipSegmentKind.recap,
        'ed' || 'mixed-ed' => SkipSegmentKind.credits,
        _ => null,
      };
      if (kind == null) continue;
      final startMs = (start * 1000).round();
      final endMs = (end * 1000).round();
      if (endMs <= startMs) continue;
      out.add(SkipSegment(startMs: startMs, endMs: endMs, kind: kind));
    }
    return out;
  }

  /// Pick the MAL id out of an AniList search response. Pure — unit-tested.
  /// Prefers an exact normalized-title match, else the first entry with a
  /// MAL id (AniList SEARCH_MATCH ranks the canonical entry first).
  static int? parseAniListMalId(String body, String queryTitle) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final media = decoded['data'] is Map
        ? (decoded['data'] as Map)['Page'] is Map
            ? ((decoded['data'] as Map)['Page'] as Map)['media']
            : null
        : null;
    if (media is! List) return null;
    final want = _normalize(queryTitle);
    int? firstWithMal;
    for (final m in media) {
      if (m is! Map) continue;
      final mal = m['idMal'];
      if (mal is! num || mal <= 0) continue;
      final romaji = m['title'] is Map ? (m['title'] as Map)['romaji'] : null;
      if (romaji is String && _normalize(romaji) == want) return mal.toInt();
      firstWithMal ??= mal.toInt();
    }
    return firstWithMal;
  }

  static String _normalize(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
}
