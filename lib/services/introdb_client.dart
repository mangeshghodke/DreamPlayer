import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/skip_segments.dart';
import 'aniskip_store.dart';

/// Optional user API key for TheIntroDB (stored in shared_preferences under
/// `dreamplayer.introdbApiKey`). The v4 API works KEYLESS out of the box
/// (30 req/window anonymous); a key only adds the requester's own pending
/// submissions and raises the limit — so the Settings field is optional.
class IntroDbKeyStore {
  IntroDbKeyStore._();

  static const String prefsKey = 'dreamplayer.introdbApiKey';

  static Future<String> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(prefsKey) ?? '';
  }

  static Future<void> save(String key) async {
    final prefs = await SharedPreferences.getInstance();
    if (key.isEmpty) {
      await prefs.remove(prefsKey);
    } else {
      await prefs.setString(prefsKey, key);
    }
  }
}

/// TheIntroDB v4 (https://theintrodb.org) — community skip timestamps for
/// **mainstream movies and TV**, keyed by TMDB id (which DreamPlayer already
/// resolves), so no MAL bridge is needed. Keyless by default; an optional
/// `Authorization: Bearer <key>` (Settings → Metadata) lifts the rate limit.
///
/// `GET /v4/media?tmdb_id=<id>[&season=<s>&episode=<e>]` — season+episode
/// together = TV episode, neither = movie. Response groups segments by type
/// (`intro`/`recap`/`credits`/`preview`), each a list of `{start_ms, end_ms}`
/// where `start_ms` null means "from 0" and `end_ms` null means "to the end".
/// 404 `{"code":"no_submissions"}` = no data (cached as a negative).
///
/// Verified live 2026-11-05: Game of Thrones (tmdb 1399) S01E01 →
/// intro 435985–535607 ms, credits 3629920→null; Inception (tmdb 27205) →
/// intro null–38000 ms.
class IntroDbClient {
  IntroDbClient({HttpClient? httpClient}) : _http = httpClient;

  static const String baseUrl = 'https://api.theintrodb.org/v4';

  final HttpClient? _http;

  HttpClient get _client => _http ?? HttpClient();

  /// Segments for a TMDB movie or TV episode. Cache first (incl. negatives),
  /// then network. Empty list = known to have no data; null = lookup failed.
  Future<List<SkipSegment>?> mediaSegments({
    required int tmdbId,
    int? season,
    int? episode,
    int? durationMs,
  }) async {
    final isTv = season != null && episode != null;
    final key = isTv
        ? 'introdb:ep:tmdb:$tmdbId:S${season.toString().padLeft(2, '0')}'
            'E${episode.toString().padLeft(2, '0')}'
        : 'introdb:movie:tmdb:$tmdbId';
    final cached = await AniskipStore.cached(key);
    if (cached != null) return cached.segments;

    final query = <String, String>{'tmdb_id': '$tmdbId'};
    if (isTv) {
      query['season'] = '$season';
      query['episode'] = '$episode';
    }
    if (durationMs != null && durationMs > 0) {
      query['duration_ms'] = '$durationMs';
    }
    final uri = Uri.parse('$baseUrl/media').replace(queryParameters: query);
    try {
      final client = _client;
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 6));
      final apiKey = await IntroDbKeyStore.load();
      if (apiKey.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      final res = await req.close().timeout(const Duration(seconds: 6));
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 404) {
        await AniskipStore.save(key, null);
        return const [];
      }
      if (res.statusCode != 200) {
        await AniskipStore.save(key, null);
        return null;
      }
      final segs = parseMediaResponse(body, durationMs: durationMs);
      await AniskipStore.save(key, segs.isEmpty ? null : segs);
      return segs;
    } catch (_) {
      return null; // offline must never break playback
    } finally {
      if (_http == null) _client.close(force: true);
    }
  }

  /// Parse a `/v4/media` 200 body into segments. Pure — unit-tested against
  /// live-measured responses. `preview` segments are dropped (no UI for them).
  /// Null start = 0; null end = durationMs (credits run to the file end).
  static List<SkipSegment> parseMediaResponse(String body, {int? durationMs}) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    const kinds = {
      'intro': SkipSegmentKind.intro,
      'recap': SkipSegmentKind.recap,
      'credits': SkipSegmentKind.credits,
    };
    final out = <SkipSegment>[];
    for (final entry in kinds.entries) {
      final list = decoded[entry.key];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final start = item['start_ms'];
        final end = item['end_ms'];
        final startMs = start is num ? start.toInt() : 0;
        final endMs = end is num
            ? end.toInt()
            : (durationMs != null && durationMs > startMs
                ? durationMs
                : startMs + 1);
        if (endMs <= startMs) continue;
        out.add(SkipSegment(
            startMs: startMs, endMs: endMs, kind: entry.value));
      }
    }
    return out;
  }
}
