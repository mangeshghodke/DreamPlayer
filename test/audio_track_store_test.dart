import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/audio_track_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('mpv track id string round-trips under engine=mpv', () async {
    await AudioTrackStore.save(
      '/a/b.mkv',
      engine: 'mpv',
      trackIndex: '2',
    );
    expect(
      await AudioTrackStore.load('/a/b.mkv', engine: 'mpv'),
      '2',
    );
  });

  test('media3 flat index round-trips under engine=media3', () async {
    await AudioTrackStore.save(
      '/a/b.mkv',
      engine: 'media3',
      trackIndex: 3,
    );
    expect(
      await AudioTrackStore.load('/a/b.mkv', engine: 'media3'),
      3,
    );
  });

  test('engines are isolated (mpv save does not leak into media3)', () async {
    await AudioTrackStore.save(
      '/a/b.mkv',
      engine: 'mpv',
      trackIndex: '1',
    );
    expect(
      await AudioTrackStore.load('/a/b.mkv', engine: 'media3'),
      isNull,
    );
    expect(
      await AudioTrackStore.load('/a/b.mkv', engine: 'mpv'),
      '1',
    );
  });

  test('clear only removes the given engine key', () async {
    await AudioTrackStore.save(
      '/a/b.mkv',
      engine: 'mpv',
      trackIndex: '2',
    );
    await AudioTrackStore.save(
      '/a/b.mkv',
      engine: 'media3',
      trackIndex: 0,
    );
    await AudioTrackStore.clear('/a/b.mkv', engine: 'mpv');
    expect(
      await AudioTrackStore.load('/a/b.mkv', engine: 'mpv'),
      isNull,
    );
    expect(
      await AudioTrackStore.load('/a/b.mkv', engine: 'media3'),
      0,
    );
  });

  test('empty resume key is a no-op', () async {
    await AudioTrackStore.save('', engine: 'mpv', trackIndex: '1');
    expect(await AudioTrackStore.load('', engine: 'mpv'), isNull);
  });
}
