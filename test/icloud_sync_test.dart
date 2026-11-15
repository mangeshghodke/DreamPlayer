import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/icloud_sync.dart';
import 'package:dream_player/utils/sync_merge.dart';

void main() {
  group('SyncBlob.decode', () {
    test('decodes a well-formed blob', () {
      final b = SyncBlob.decode('''{
        "v": 1,
        "updatedAtMs": 1000,
        "watched": ["key/a", "key/b"],
        "resume": {"key/c": 120000, "key/d": 5000},
        "cw": [{"video": {"path": "key/e"}, "updatedAtMs": 900}]
      }''');
      expect(b.watched, {'key/a', 'key/b'});
      expect(b.resume, {'key/c': 120000, 'key/d': 5000});
      expect(b.cw.length, 1);
      expect(b.updatedAtMs, 1000);
    });

    test('returns empty on null / garbage / non-map', () {
      expect(SyncBlob.decode(null), SyncBlob.empty());
      expect(SyncBlob.decode(''), SyncBlob.empty());
      expect(SyncBlob.decode('not json'), SyncBlob.empty());
      expect(SyncBlob.decode('[1,2,3]'), SyncBlob.empty());
      expect(SyncBlob.decode('{"v":1}'), SyncBlob.empty(0));
    });

    test('ignores non-string watched and non-num resume values', () {
      final b = SyncBlob.decode(
          '{"v":1,"watched":[1,2,"key/a"],"resume":{"k":"notanum","k2":3}}');
      expect(b.watched, {'key/a'});
      expect(b.resume, {'k2': 3});
    });
  });

  group('SyncBlob.merge', () {
    test('unions watched, takes max resume, newest cw per key', () {
      final a = SyncBlob(
        watched: {'a', 'b'},
        resume: {'x': 100, 'y': 200},
        cw: [
          {'video': {'path': 'v1'}, 'updatedAtMs': 100},
          {'video': {'path': 'v2'}, 'updatedAtMs': 50},
        ],
        updatedAtMs: 1000,
      );
      final b = SyncBlob(
        watched: {'b', 'c'},
        resume: {'x': 300, 'z': 50},
        cw: [
          {'video': {'path': 'v1'}, 'updatedAtMs': 200},
        ],
        updatedAtMs: 2000,
      );
      final m = SyncBlob.merge(a, b);
      expect(m.watched, {'a', 'b', 'c'});
      expect(m.resume, {'x': 300, 'y': 200, 'z': 50});
      expect(m.cw.length, 2);
      // v1 keeps the newer (200) entry; order is a's then b's but deduped.
      final v1 = m.cw.firstWhere((e) => e['video']['path'] == 'v1');
      expect(v1['updatedAtMs'], 200);
      expect(m.updatedAtMs, 2000);
    });

    test('merge is order-independent', () {
      final a = SyncBlob(watched: {'a'}, resume: {'x': 1}, cw: [], updatedAtMs: 1);
      final b = SyncBlob(watched: {'b'}, resume: {'x': 2}, cw: [], updatedAtMs: 2);
      expect(SyncBlob.merge(a, b), SyncBlob.merge(b, a));
    });

    test('drops resume entries whose base key is watched', () {
      // Engine-prefixed keys are stripped to the base before the watched check.
      final a = SyncBlob(
        watched: {'video/ep.mkv'},
        resume: {'media3:video/ep.mkv': 12345, 'video/other.mkv': 678},
        cw: [],
        updatedAtMs: 1,
      );
      final b = SyncBlob.empty();
      final m = SyncBlob.merge(a, b);
      expect(m.resume.containsKey('media3:video/ep.mkv'), isFalse);
      expect(m.resume, {'video/other.mkv': 678});
    });

    test('empty merge is identity', () {
      final e = SyncBlob.empty();
      final x = SyncBlob(watched: {'a'}, resume: {'k': 5}, cw: [], updatedAtMs: 9);
      expect(SyncBlob.merge(x, e), x);
      expect(SyncBlob.merge(e, x), x);
    });
  });

  group('SyncBlob.capped', () {
    test('keeps the most recent 500 resume / cw entries', () {
      final resume = <String, int>{};
      for (var i = 0; i < 600; i++) {
        resume['k$i'] = i * 1000;
      }
      // build a list of 600 entries with increasing timestamps
      final cwList = List.generate(600, (i) => {
        'video': {'path': 'v$i'},
        'updatedAtMs': i,
      });
      final b = SyncBlob(
        watched: {},
        resume: resume,
        cw: cwList,
        updatedAtMs: 1,
      ).capped();
      expect(b.resume.length, maxSyncedResumeEntries);
      expect(b.resume.values.first, 599 * 1000); // highest position kept first
      expect(b.resume.values.reduce((a, b) => a < b ? a : b), 100 * 1000); // lowest kept
      expect(b.cw.length, maxSyncedCwEntries);
      expect((b.cw.last['updatedAtMs'] as num), 100); // lowest kept (descending order)
    });
  });

  group('baseKeyOf', () {
    test('strips engine prefixes', () {
      expect(SyncBlob.baseKeyOf('media3:video/ep.mkv'), 'video/ep.mkv');
      expect(SyncBlob.baseKeyOf('mpv:video/ep.mkv'), 'video/ep.mkv');
    });
    test('returns unchanged when no prefix', () {
      expect(SyncBlob.baseKeyOf('video/ep.mkv'), 'video/ep.mkv');
      expect(SyncBlob.baseKeyOf(''), '');
    });
  });

  group('collect / apply round-trip', () {
    test('collect reads watched / resume / cw from prefs', () async {
      SharedPreferences.setMockInitialValues({
        'dreamplayer.watched': ['a', 'b'],
        'resume_pos_ms_media3:x': 100,
        'resume_pos_ms_y': 200,
        'resume_pos_ms_zzz': 0, // not > 0, skipped
        'dreamplayer.continueWatching': '''[{"video":{"path":"v1"},"updatedAtMs":5}]''',
      });
      final prefs = await SharedPreferences.getInstance();
      final blob = ICloudSyncService.collect(prefs);
      expect(blob.watched, {'a', 'b'});
      expect(blob.resume, {'media3:x': 100, 'y': 200});
      expect(blob.cw.length, 1);
      expect(blob.cw.first['video']['path'], 'v1');
    });

    test('apply writes watched / resume / cw back to prefs', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final blob = SyncBlob(
        watched: {'p', 'q'},
        resume: {'r': 77},
        cw: [{'video': {'path': 'v2'}, 'updatedAtMs': 9}],
        updatedAtMs: 3,
      );
      await ICloudSyncService.apply(prefs, blob);
      expect(prefs.getStringList('dreamplayer.watched'), ['p', 'q']);
      expect(prefs.getInt('resume_pos_ms_r'), 77);
      expect(prefs.getString('dreamplayer.continueWatching'),
          '''[{"video":{"path":"v2"},"updatedAtMs":9}]''');
    });
  });
}
