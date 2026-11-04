import 'package:dream_player/services/aniskip_client.dart';
import 'package:dream_player/services/aniskip_store.dart';
import 'package:dream_player/utils/skip_segments.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('parseAniSkipResponse', () {
    // Measured live against api.aniskip.com (2026-11-04), One Piece MAL 21 ep 1.
    test('maps op/mixed-op to intro, recap, ed/mixed-ed to credits', () {
      const body = '''{
        "found": true,
        "results": [
          {"interval": {"startTime": 310.571, "endTime": 400.571}, "skipType": "op", "skipId": "d4f34b6d-0547-4438-ac93-b25b577eddd5", "episodeLength": 1443.984},
          {"interval": {"startTime": 1396.006, "endTime": 1434}, "skipType": "ed", "skipId": "5751c57a-2bcd-4dd9-be93-58e6af0f8c81", "episodeLength": 1434.985},
          {"interval": {"startTime": 132.773, "endTime": 201.296}, "skipType": "recap", "skipId": "d617614e-6cf2-4b26-9abf-b68de94bb1f2", "episodeLength": 1444},
          {"interval": {"startTime": 186.231, "endTime": 276.231}, "skipType": "mixed-op", "skipId": "07298009-522c-4201-b08a-20b8ba993f53", "episodeLength": 1439.98},
          {"interval": {"startTime": 1401, "endTime": 1435}, "skipType": "mixed-ed", "skipId": "81f38816-cb48-4ba2-bbb9-2fc4e6e28a91", "episodeLength": 1435.06}
        ],
        "message": "Successfully found skip times",
        "statusCode": 200
      }''';
      final segs = AniskipClient.parseAniSkipResponse(body);
      expect(segs.length, 5);
      expect(segs.where((s) => s.kind == SkipSegmentKind.intro).length, 2);
      expect(segs.where((s) => s.kind == SkipSegmentKind.recap).single.startMs, 132773);
      expect(segs.where((s) => s.kind == SkipSegmentKind.credits).length, 2);
      // seconds -> ms
      expect(segs.first.startMs, 310571);
      expect(segs.first.endMs, 400571);
    });

    test('found:false (HTTP 404 body) yields empty', () {
      const body = '{"found":false,"results":[],"message":"No skip times found","statusCode":404}';
      expect(AniskipClient.parseAniSkipResponse(body), isEmpty);
    });

    test('garbage yields empty, zero-length intervals dropped', () {
      expect(AniskipClient.parseAniSkipResponse('not json'), isEmpty);
      const body = '{"found":true,"results":[{"interval":{"startTime":5,"endTime":5},"skipType":"op"},{"interval":{"startTime":1,"endTime":2},"skipType":"filler"}]}';
      expect(AniskipClient.parseAniSkipResponse(body), isEmpty);
    });
  });

  group('parseAniListMalId', () {
    test('prefers exact normalized title match', () {
      const body = '''{"data":{"Page":{"media":[
        {"id":101922,"idMal":38000,"title":{"romaji":"Kimetsu no Yaiba"}},
        {"id":142329,"idMal":47778,"title":{"romaji":"Kimetsu no Yaiba: Yuukaku-hen"}}
      ]}}}''';
      expect(AniskipClient.parseAniListMalId(body, 'Kimetsu no Yaiba'), 38000);
    });

    test('falls back to first entry with a MAL id', () {
      const body = '''{"data":{"Page":{"media":[
        {"id":1,"idMal":null,"title":{"romaji":"X"}},
        {"id":2,"idMal":21,"title":{"romaji":"One Piece"}}
      ]}}}''';
      expect(AniskipClient.parseAniListMalId(body, 'whatever'), 21);
    });

    test('no MAL ids anywhere -> null', () {
      const body = '{"data":{"Page":{"media":[{"id":1,"idMal":null,"title":{"romaji":"X"}}]}}}';
      expect(AniskipClient.parseAniListMalId(body, 'x'), isNull);
      expect(AniskipClient.parseAniListMalId('nope', 'x'), isNull);
    });
  });

  group('AniskipStore', () {
    test('mode defaults to prompt and round-trips', () async {
      expect(await AniskipStore.loadMode(), SkipMode.prompt);
      await AniskipStore.saveMode(SkipMode.auto);
      expect(await AniskipStore.loadMode(), SkipMode.auto);
      await AniskipStore.saveMode(SkipMode.off);
      expect(await AniskipStore.loadMode(), SkipMode.off);
    });

    test('unknown stored mode falls back to prompt', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AniskipStore.modePrefsKey, 'bogus');
      expect(await AniskipStore.loadMode(), SkipMode.prompt);
    });

    test('episode cache: miss, negative, and positive round-trip', () async {
      const key = 'aniskip:ep:tmdb:tv:94605:S01E01';
      expect(await AniskipStore.cached(key), isNull);

      await AniskipStore.save(key, null); // negative
      final neg = await AniskipStore.cached(key);
      expect(neg, isNotNull);
      expect(neg!.found, isFalse);
      expect(neg.segments, isEmpty);

      const segs = [
        SkipSegment(startMs: 5617, endMs: 95617, kind: SkipSegmentKind.intro),
        SkipSegment(startMs: 1295128, endMs: 1385128, kind: SkipSegmentKind.credits),
      ];
      await AniskipStore.save(key, segs);
      final pos = await AniskipStore.cached(key);
      expect(pos!.found, isTrue);
      expect(pos.segments, segs);
    });

    test('episodeKey shape', () {
      expect(AniskipStore.episodeKey(94605, 1, 5), 'aniskip:ep:tmdb:tv:94605:S01E05');
      expect(AniskipStore.episodeKey(1399, 12, 123), 'aniskip:ep:tmdb:tv:1399:S12E123');
    });

    test('mal id cache round-trips', () async {
      expect(await AniskipStore.cachedMalId('aniskip:mal:tmdb:tv:94605'), isNull);
      await AniskipStore.saveMalId('aniskip:mal:tmdb:tv:94605', 38000);
      expect(await AniskipStore.cachedMalId('aniskip:mal:tmdb:tv:94605'), 38000);
    });
  });
}
