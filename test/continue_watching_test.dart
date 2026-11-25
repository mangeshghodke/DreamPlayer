import 'package:dream_player/models/hdr_format.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/continue_watching.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const video = VideoItem(
    id: 'webdav_0e417606-0deb-4af7-9d64-8914349788ba/Movies/Identity.2003.mkv',
    title: 'Identity.2003.mkv',
    uri: 'http://192.168.1.16:8080/dav/Movies/Identity.2003.mkv',
    resumeKey: 'webdav_0e417606-0deb-4af7-9d64-8914349788ba/Movies/Identity.2003.mkv',
    duration: Duration.zero,
  );

  test('save skips sub-10s positions', () async {
    SharedPreferences.setMockInitialValues({});
    await ContinueWatchingStore.save(video, const Duration(seconds: 5));
    expect(await ContinueWatchingStore.load(), isEmpty);
  });

  test('save/load round-trips and dedups by key', () async {
    SharedPreferences.setMockInitialValues({});
    await ContinueWatchingStore.save(video, const Duration(minutes: 10));
    var entries = await ContinueWatchingStore.load();
    expect(entries, hasLength(1));
    expect(entries.first.position, const Duration(minutes: 10));

    await ContinueWatchingStore.save(video, const Duration(minutes: 11));
    entries = await ContinueWatchingStore.load();
    expect(entries, hasLength(1));
    expect(entries.first.position, const Duration(minutes: 11));
  });

  test('remove drops the entry', () async {
    SharedPreferences.setMockInitialValues({});
    await ContinueWatchingStore.save(video, const Duration(minutes: 10));
    await ContinueWatchingStore.remove(
      ContinueWatchingStore.keyFor(video),
    );
    expect(await ContinueWatchingStore.load(), isEmpty);
  });

  test('save persists the FULL item incl. hdrHint (washed-out HDR regression)', () async {
    // Regression: ContinueWatchingStore.save used to rebuild a stripped
    // VideoItem without hdrHint, so a restored continue-watching entry looked
    // SDR and the player armed the Media3 GL picture-effects pipeline, which
    // strips the native HDR/DV layer (washed-out colors from Home, fine from
    // the source browser where the fresh item carries the hint).
    SharedPreferences.setMockInitialValues({});
    const dv = VideoItem(
      id: 'smb:x/Movies/Movie.DV.HDR.mkv',
      title: 'Movie.DV.HDR.mkv',
      path: 'smb://share/Movies/Movie.DV.HDR.mkv',
      uri: 'smb://server/share/Movies/Movie.DV.HDR.mkv',
      resumeKey: 'smb:server/share/Movies/Movie.DV.HDR.mkv',
      duration: Duration.zero,
      hdrHint: 'Movie.DV.HDR.mkv',
      externalSubtitles: [
        VideoExternalSub(uri: 'smb://server/share/Movies/Movie.en.srt', label: 'Movie.en.srt'),
      ],
    );
    await ContinueWatchingStore.save(dv, const Duration(minutes: 3));
    final entry = (await ContinueWatchingStore.load()).single;
    expect(entry.video.hdrHint, 'Movie.DV.HDR.mkv');
    expect(entry.video.hdrFormat, HdrFormat.dolbyVision);
    expect(entry.video.uri, dv.uri);
    expect(entry.video.externalSubtitles, hasLength(1));
  });

  test('player arms picture effects only for SDR-hinted items; native gate defers to the real format', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    expect(player, contains('video.hdrFormat == HdrFormat.sdr'));
    final kt = File('android/app/src/main/kotlin/com/dreamplayer/app/ExoPlayerView.kt').readAsStringSync();
    // the GL pipeline must NOT be created at open() before the real format is known
    final openAt = kt.indexOf('pictureEffectsArmed = call.argument');
    final prepareAt = kt.indexOf('player.prepare()', openAt);
    final between = kt.substring(openAt, prepareAt);
    expect(between, isNot(contains('setVideoEffects')));
    // and it engages lazily only for SDR content once the format is known
    final gate = kt.substring(kt.indexOf('private fun enforcePictureEffectsHdrGate()'));
    expect(gate, contains('setVideoEffects(buildPictureEffects())'));
    expect(gate, contains('HDR/DV'));
  });
}
