import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:dream_player/utils/mpv_audio_select.dart';

void main() {
  group('pickMpvDefaultAudioId', () {
    test('returns the isDefault track id', () {
      final id = pickMpvDefaultAudioId(const [
        AudioTrack('1', null, 'hin', isDefault: false),
        AudioTrack('2', null, 'eng', isDefault: true),
        AudioTrack('3', null, 'jpn', isDefault: false),
      ]);
      expect(id, '2');
    });

    test('ignores auto/no sentinels', () {
      final id = pickMpvDefaultAudioId(const [
        AudioTrack('auto', null, null, isDefault: true),
        AudioTrack('no', null, null, isDefault: true),
        AudioTrack('1', null, 'eng', isDefault: false),
      ]);
      expect(id, isNull);
    });

    test('null when no track is flagged', () {
      expect(
        pickMpvDefaultAudioId(const [
          AudioTrack('1', null, 'hin'),
          AudioTrack('2', null, 'eng', isDefault: false),
        ]),
        isNull,
      );
    });

    test('empty list is null', () {
      expect(pickMpvDefaultAudioId(const []), isNull);
    });
  });

  group('parseMpvDefaultFlag', () {
    test('truthy spellings', () {
      expect(parseMpvDefaultFlag('yes'), isTrue);
      expect(parseMpvDefaultFlag('true'), isTrue);
      expect(parseMpvDefaultFlag('1'), isTrue);
      expect(parseMpvDefaultFlag(' YES '), isTrue);
    });

    test('falsy spellings', () {
      expect(parseMpvDefaultFlag('no'), isFalse);
      expect(parseMpvDefaultFlag('false'), isFalse);
      expect(parseMpvDefaultFlag('0'), isFalse);
    });

    test('unknown / empty is null', () {
      expect(parseMpvDefaultFlag(''), isNull);
      expect(parseMpvDefaultFlag('maybe'), isNull);
    });
  });
}
