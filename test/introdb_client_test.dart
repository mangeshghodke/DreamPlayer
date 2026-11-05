import 'package:dream_player/services/aniskip_store.dart';
import 'package:dream_player/services/introdb_client.dart';
import 'package:dream_player/utils/skip_segments.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('parseMediaResponse (live-measured bodies, 2026-11-05)', () {
    test('TV episode: Game of Thrones tmdb=1399 S01E01', () {
      const body =
          '{"tvdb_id":121361,"type":"tv","season":1,"episode":1,"intro":[{"start_ms":435985,"end_ms":535607}],"credits":[{"start_ms":3629920,"end_ms":null}]}';
      final segs = IntroDbClient.parseMediaResponse(body, durationMs: 3700000);
      final intro = SkipSegments.firstOf(segs, SkipSegmentKind.intro);
      expect(intro, isNotNull);
      expect(intro!.startMs, 435985);
      expect(intro.endMs, 535607);
      final credits = SkipSegments.firstOf(segs, SkipSegmentKind.credits);
      expect(credits!.startMs, 3629920);
      // null end_ms on credits = runs to the end of the file -> durationMs
      expect(credits.endMs, 3700000);
    });

    test('movie with intro starting at 0: Inception tmdb=27205', () {
      const body =
          '{"tvdb_id":113,"type":"movie","intro":[{"start_ms":null,"end_ms":38000}]}';
      final segs = IntroDbClient.parseMediaResponse(body, durationMs: 8880000);
      final intro = SkipSegments.firstOf(segs, SkipSegmentKind.intro);
      expect(intro!.startMs, 0); // null start = from the beginning
      expect(intro.endMs, 38000);
    });

    test('recap type maps to recap kind', () {
      const body =
          '{"tvdb_id":1,"type":"tv","season":1,"episode":2,"recap":[{"start_ms":1000,"end_ms":30000}]}';
      final segs = IntroDbClient.parseMediaResponse(body);
      final recap = SkipSegments.firstOf(segs, SkipSegmentKind.recap);
      expect(recap, isNotNull);
      expect(recap!.endMs, 30000);
    });

    test('preview is dropped, garbage/404 bodies yield empty', () {
      const withPreview =
          '{"tvdb_id":1,"type":"movie","preview":[{"start_ms":1,"end_ms":2}]}';
      expect(IntroDbClient.parseMediaResponse(withPreview), isEmpty);
      expect(IntroDbClient.parseMediaResponse('not json'), isEmpty);
      expect(IntroDbClient.parseMediaResponse(
          '{"error":"no submissions for this media","code":"no_submissions"}'),
          isEmpty);
    });

    test('null end without duration falls back to start+1 (not inverted)', () {
      const body =
          '{"tvdb_id":1,"type":"movie","credits":[{"start_ms":5000,"end_ms":null}]}';
      final segs = IntroDbClient.parseMediaResponse(body);
      expect(segs.single.endMs, 5001);
    });
  });

  group('IntroDbKeyStore', () {
    test('defaults to empty (keyless) and round-trips', () async {
      expect(await IntroDbKeyStore.load(), '');
      await IntroDbKeyStore.save('abc123');
      expect(await IntroDbKeyStore.load(), 'abc123');
      await IntroDbKeyStore.save(''); // empty clears
      expect(await IntroDbKeyStore.load(), '');
    });
  });

  group('cache keys', () {
    test('IntroDB keys are distinct from AniSkip keys', () async {
      // AniskipStore stores both under one map; the prefixes keep them apart.
      const introKey = 'introdb:ep:tmdb:1399:S01E01';
      const aniskipKey = 'aniskip:ep:tmdb:tv:1399:S01E01';
      expect(introKey, isNot(aniskipKey));
      await AniskipStore.save(introKey, const [
        SkipSegment(startMs: 1, endMs: 2, kind: SkipSegmentKind.intro),
      ]);
      final cached = await AniskipStore.cached(introKey);
      expect(cached!.found, isTrue);
      expect(cached.segments.single.kind, SkipSegmentKind.intro);
      expect(await AniskipStore.cached(aniskipKey), isNull);
    });
  });
}
