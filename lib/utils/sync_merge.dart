import 'dart:convert';

/// Pure iCloud-sync blob logic (competitor-gap #3): encode / parse / merge the
/// JSON blob that travels through NSUbiquitousKeyValueStore between the
/// user's iPhone and iPad. No Flutter, no IO — unit-tested in
/// `test/icloud_sync_test.dart`.
///
/// Blob shape (versioned so the format can evolve):
/// ```json
/// { "v": 1, "updatedAtMs": 1763…, "watched": ["key", …],
///   "resume": { "<resume store key suffix>": ms, … }, "cw": [entryJson, …] }
/// ```
///
/// Merge rule: watched is a UNION, resume keeps the FURTHER-ALONG position per
/// key, continue-watching keeps the newest entry per video key — and a resume
/// entry whose base key is watched is DROPPED (playing to the end clears the
/// resume; without the drop, the other device's older position would
/// resurrect a finished video).

/// SharedPreferences key of the watched marks list.
const String watchedPrefsKey = 'dreamplayer.watched';

/// SharedPreferences key of the continue-watching JSON list.
const String continueWatchingPrefsKey = 'dreamplayer.continueWatching';

/// Prefix of every per-video resume position key (`resume_pos_ms_<suffix>`).
const String resumePrefsPrefix = 'resume_pos_ms_';

/// KV-store quota guard: the ubiquity KV store caps a value at 1 MB, so the
/// blob is capped at this many resume / cw entries (most recent kept).
const int maxSyncedResumeEntries = 500;
const int maxSyncedCwEntries = 500;

class SyncBlob {
  const SyncBlob({
    required this.watched,
    required this.resume,
    required this.cw,
    required this.updatedAtMs,
  });

  final Set<String> watched;
  final Map<String, int> resume;
  final List<Map<String, dynamic>> cw;
  final int updatedAtMs;

  factory SyncBlob.empty([int updatedAtMs = 0]) => SyncBlob(
        watched: const {},
        resume: const {},
        cw: const [],
        updatedAtMs: updatedAtMs,
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'updatedAtMs': updatedAtMs,
        'watched': watched.toList()..sort(),
        'resume': resume,
        'cw': cw,
      };

  String encode() => jsonEncode(toJson());

  factory SyncBlob.decode(String? raw) {
    if (raw == null || raw.isEmpty) return SyncBlob.empty();
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return SyncBlob.empty();
      final watched = (j['watched'] is List)
          ? (j['watched'] as List)
              .whereType<String>()
              .toSet()
          : <String>{};
      final resumeRaw = j['resume'] is Map ? j['resume'] as Map : const {};
      final resume = <String, int>{};
      for (final e in resumeRaw.entries) {
        if (e.key is String && e.value is num) {
          resume[e.key as String] = (e.value as num).toInt();
        }
      }
      final cwRaw = j['cw'] is List ? j['cw'] as List : const [];
      final cw = cwRaw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
      return SyncBlob(
        watched: watched,
        resume: resume,
        cw: cw,
        updatedAtMs: (j['updatedAtMs'] is num)
            ? (j['updatedAtMs'] as num).toInt()
            : 0,
      );
    } catch (_) {
      return SyncBlob.empty();
    }
  }

  /// The base resume key with any engine prefix (`media3:`/`mpv:`) stripped —
  /// watched marks are stored against the base key.
  static String baseKeyOf(String storeKeySuffix) {
    for (final engine in const ['media3:', 'mpv:']) {
      if (storeKeySuffix.startsWith(engine)) {
        return storeKeySuffix.substring(engine.length);
      }
    }
    return storeKeySuffix;
  }

  /// Merge [a] and [b] (order irrelevant): union watched, max position per
  /// resume key, newest cw entry per video key, max updatedAt — then drop
  /// resume entries whose base key is watched.
  static SyncBlob merge(SyncBlob a, SyncBlob b) {
    final watched = {...a.watched, ...b.watched};
    final resume = <String, int>{};
    for (final src in [a.resume, b.resume]) {
      src.forEach((k, v) {
        final cur = resume[k];
        if (cur == null || v > cur) resume[k] = v;
      });
    }
    // Newest cw entry per video key.
    final cwByKey = <String, Map<String, dynamic>>{};
    for (final src in [a.cw, b.cw]) {
      for (final e in src) {
        final video = e['video'];
        final key = video is Map
            ? (video['resumeKey'] ?? video['path'] ?? video['uri'] ?? '')
                .toString()
            : '';
        final ts = (e['updatedAtMs'] is num) ? (e['updatedAtMs'] as num).toInt() : 0;
        final cur = cwByKey[key];
        final curTs = cur != null && cur['updatedAtMs'] is num
            ? (cur['updatedAtMs'] as num).toInt()
            : 0;
        if (cur == null || ts >= curTs) cwByKey[key] = e;
      }
    }
    // Played-to-end clears the resume on the device that finished it; don't
    // let an older position from the other device resurrect it.
    resume.removeWhere((k, _) => watched.contains(baseKeyOf(k)));
    return SyncBlob(
      watched: watched,
      resume: resume,
      cw: cwByKey.values.toList(),
      updatedAtMs: a.updatedAtMs > b.updatedAtMs ? a.updatedAtMs : b.updatedAtMs,
    );
  }

  /// Caps the blob to the KV-store quota: most-recent-first slices of resume
  /// and cw. `updatedAtMs` per cw entry ranks cw; resume is ranked by
  /// position descending as a proxy for recency (positions only grow).
  SyncBlob capped() {
    final r = resume.entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    final c = cw.toList()
      ..sort((x, y) => ((y['updatedAtMs'] as num?)?.toInt() ?? 0)
          .compareTo((x['updatedAtMs'] as num?)?.toInt() ?? 0));
    return SyncBlob(
      watched: watched,
      resume: Map.fromEntries(r.take(maxSyncedResumeEntries)),
      cw: c.take(maxSyncedCwEntries).toList(),
      updatedAtMs: updatedAtMs,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SyncBlob &&
      other.updatedAtMs == updatedAtMs &&
      other.watched.length == watched.length &&
      other.resume.length == resume.length &&
      other.cw.length == cw.length &&
      encode() == other.encode();

  @override
  int get hashCode => encode().hashCode;
}
