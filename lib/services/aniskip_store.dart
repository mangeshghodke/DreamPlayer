import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/skip_segments.dart';

/// How the player treats skip segments (issue #60): [off] never looks them
/// up, [prompt] shows a "Skip …" button, [auto] seeks past them by itself.
enum SkipMode { off, prompt, auto }

/// Local cache for community skip timestamps (AniSkip) and the skip mode
/// (issue #60). Everything lives in one JSON map under `dreamplayer.aniskip`
/// so a playback session works fully offline — including from SMB/USB —
/// once the title was resolved once online. Negative results are cached too
/// (`found: false`), so a show AniSkip doesn't know isn't re-queried per
/// episode.
class AniskipStore {
  AniskipStore._();

  static const String prefsKey = 'dreamplayer.aniskip';
  static const String modePrefsKey = 'dreamplayer.skipSegmentsMode';

  /// Episode cache key for a TMDB TV show: `aniskip:ep:tmdb:tv:<id>:S<ss>E<ee>`.
  static String episodeKey(int tmdbTvId, int season, int episode) =>
      'aniskip:ep:tmdb:tv:$tmdbTvId:S${season.toString().padLeft(2, '0')}'
      'E${episode.toString().padLeft(2, '0')}';

  /// MAL-id cache key for a TMDB title: `aniskip:mal:<providerKey>`.
  static String malKey(String providerKey) => 'aniskip:mal:$providerKey';

  static Future<Map<String, dynamic>> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  }

  static Future<void> _saveAll(Map<String, dynamic> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(all));
  }

  /// Cached segments for [key], or null when nothing is cached. A cached
  /// negative ([found] false with no segments) returns an empty list so the
  /// caller can tell "known absent" apart from "not looked up yet".
  static Future<({bool found, List<SkipSegment> segments})?> cached(
      String key) async {
    final all = await _loadAll();
    final entry = all[key];
    if (entry is! Map) return null;
    final segs = <SkipSegment>[];
    final rawSegs = entry['segments'];
    if (rawSegs is List) {
      for (final s in rawSegs) {
        if (s is Map) {
          final seg = SkipSegment.fromJson(s);
          if (seg != null) segs.add(seg);
        }
      }
    }
    return (found: entry['found'] == true, segments: segs);
  }

  /// Persist lookup result. [segments] null means "looked, not found".
  static Future<void> save(String key, List<SkipSegment>? segments) async {
    final all = await _loadAll();
    all[key] = {
      'found': segments != null && segments.isNotEmpty,
      'segments': [for (final s in segments ?? const []) s.toJson()],
    };
    await _saveAll(all);
  }

  static Future<int?> cachedMalId(String malKey) async {
    final all = await _loadAll();
    final v = all[malKey];
    return v is num ? v.toInt() : null;
  }

  static Future<void> saveMalId(String malKey, int malId) async {
    final all = await _loadAll();
    all[malKey] = malId;
    await _saveAll(all);
  }

  static Future<SkipMode> loadMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(modePrefsKey);
    return SkipMode.values.where((m) => m.name == raw).firstOrNull ??
        SkipMode.prompt;
  }

  static Future<void> saveMode(SkipMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(modePrefsKey, mode.name);
  }
}
