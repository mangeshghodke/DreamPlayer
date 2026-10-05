import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/media_probe.dart';
import 'package:dream_player/utils/codec_info.dart';

void main() {
  group('friendlyResolution', () {
    test('standard buckets', () {
      expect(friendlyResolution(3840, 2160), '4K');
      expect(friendlyResolution(1920, 1080), '1080p');
      expect(friendlyResolution(1280, 720), '720p');
      expect(friendlyResolution(720, 480), '480p');
      expect(friendlyResolution(7680, 4320), '8K');
    });

    // The bug this exists for: 2160p releases are routinely cropped to 2.39:1
    // to save bits, which lands the long edge just UNDER 3840. A Spider-Man
    // 2160p DV rip measured 3832x1600 on ffprobe and the chip called it 2K.
    test('2.39:1 scope crops of a 2160p release are 4K, not 2K', () {
      expect(friendlyResolution(3832, 1600), '4K'); // the measured file
      expect(friendlyResolution(3840, 1600), '4K');
      expect(friendlyResolution(3840, 1608), '4K');
      expect(friendlyResolution(4096, 1716), '4K'); // DCI 4K scope
      expect(friendlyResolution(4000, 1600), '4K');
    });

    test('2.39:1 crops at 1080p stay 1080p', () {
      expect(friendlyResolution(1920, 800), '1080p');
      expect(friendlyResolution(2048, 858), '1080p');
    });

    test('genuine 2K is 2K, including DCI 2K', () {
      expect(friendlyResolution(2560, 1440), '2K');
      expect(friendlyResolution(2048, 1080), '2K');
    });

    test('a tall portrait 2K frame is not mistaken for 4K', () {
      // The classification is on both edges precisely so a portrait video
      // can't be promoted by its long edge alone.
      expect(friendlyResolution(1440, 2560), '2K');
      expect(friendlyResolution(1080, 1920), '1080p');
    });

    test('unknown dimensions degrade instead of throwing', () {
      expect(friendlyResolution(0, 0), '0p');
      expect(friendlyResolution(1080, 0), '1080p');
    });
  });

  test('the file-info card and the player chip cannot disagree', () {
    // Both surfaces read the same label for the same track, which is the whole
    // point of collapsing the two implementations into one.
    for (final dims in [
      [3832, 1600],
      [3840, 2160],
      [2560, 1440],
      [1920, 1080],
    ]) {
      final probe = MediaProbeResult(width: dims[0], height: dims[1]);
      expect(probe.resolutionLabel, friendlyResolution(dims[0], dims[1]));
    }
  });

  test('probe without dimensions reports nothing rather than guessing', () {
    expect(const MediaProbeResult().resolutionLabel, isNull);
  });
}
