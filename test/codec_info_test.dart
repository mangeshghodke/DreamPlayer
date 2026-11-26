import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/models/hdr_format.dart';
import 'package:dream_player/utils/codec_info.dart';

void main() {
  group('detectHdrFormat', () {
    test('null hint is SDR', () {
      expect(detectHdrFormat(null), HdrFormat.sdr);
      expect(detectHdrFormat(''), HdrFormat.sdr);
    });

    test('detects Dolby Vision variants', () {
      expect(detectHdrFormat('DV P8'), HdrFormat.dolbyVision);
      expect(detectHdrFormat('DV P5'), HdrFormat.dolbyVision);
      expect(detectHdrFormat('Dolby Vision'), HdrFormat.dolbyVision);
      expect(detectHdrFormat('dovi'), HdrFormat.dolbyVision);
    });

    test('detects HDR10+', () {
      expect(detectHdrFormat('HDR10+'), HdrFormat.hdr10plus);
      expect(detectHdrFormat('HDR10 Plus'), HdrFormat.hdr10plus);
    });

    test('detects HDR10', () {
      expect(detectHdrFormat('HDR10'), HdrFormat.hdr10);
      expect(detectHdrFormat('HDR'), HdrFormat.hdr10);
    });

    test('SDR hint stays SDR', () {
      expect(detectHdrFormat('SDR'), HdrFormat.sdr);
    });

    test('safe on full titles (no false positives)', () {
      expect(detectHdrFormat('Adventure Time.S01E03.mkv'), HdrFormat.sdr);
      expect(detectHdrFormat('Dave 2021.1080p.mkv'), HdrFormat.sdr);
      expect(detectHdrFormat('DVD Rip.mkv'), HdrFormat.sdr);
      expect(detectHdrFormat('The.Office.S09.720p.mkv'), HdrFormat.sdr);
    });

    test('title-style hints still detect', () {
      expect(detectHdrFormat('hdr10+test_lake_2021_02_01.mp4'),
          HdrFormat.hdr10plus);
      expect(detectHdrFormat('dolby-vision-people.mp4'),
          HdrFormat.dolbyVision);
      expect(detectHdrFormat('Movie.2023.2160p.HDR10.mkv'), HdrFormat.hdr10);
      expect(detectHdrFormat('Cooking.Show.4K.HLG.ts'), HdrFormat.hlg);
      expect(detectHdrFormat('HDR10Plus.Remux.mkv'), HdrFormat.hdr10plus);
    });
  });

  group('formatAudioCodec', () {
    test('maps common codecs to display labels', () {
      expect(formatAudioCodec('eac3'), 'E-AC3');
      expect(formatAudioCodec('ac3'), 'AC-3');
      expect(formatAudioCodec('dts'), 'DTS');
      expect(formatAudioCodec('dts_hd'), 'DTS-HD');
      expect(formatAudioCodec('truehd'), 'TrueHD');
      expect(formatAudioCodec('true-hd'), 'TrueHD');
      expect(formatAudioCodec('audio/true-hd'), 'TrueHD');
      expect(formatAudioCodec('aac'), 'AAC');
      expect(formatAudioCodec('flac'), 'FLAC');
    });

    test('falls back to uppercase for unknown codecs', () {
      expect(formatAudioCodec('mp4a'), 'AAC');
      expect(formatAudioCodec(null), 'Unknown');
    });
  });

  group('formatVideoCodec', () {
    test('maps common video codecs', () {
      expect(formatVideoCodec('h264'), 'H.264');
      expect(formatVideoCodec('hevc'), 'HEVC');
      expect(formatVideoCodec('av1'), 'AV1');
      expect(formatVideoCodec('vp9'), 'VP9');
    });

    test('maps Dolby Vision codecs', () {
      expect(formatVideoCodec('dvhe'), 'Dolby Vision');
      expect(formatVideoCodec('dvh1'), 'Dolby Vision');
    });

    test('handles Media3/container codec strings with profile suffixes', () {
      expect(formatVideoCodec('dvhe.08.06'), 'Dolby Vision');
      expect(formatVideoCodec('dvh1.08.06'), 'Dolby Vision');
      expect(formatVideoCodec('hvc1.2.4.L153.B0'), 'HEVC');
      expect(formatVideoCodec('avc1.640028'), 'H.264');
      expect(formatVideoCodec('av01.0.08M.08'), 'AV1');
    });
  });

  group('formatMedia3Audio', () {
    test('maps lossless/HD MIME types', () {
      expect(formatMedia3Audio('audio/vnd.dts', 'dts'), 'DTS');
      expect(formatMedia3Audio('audio/vnd.dts.hd', 'dts-hd'), 'DTS-HD');
      expect(formatMedia3Audio('audio/vnd.dolby.truehd', 'mlp'), 'TrueHD');
      expect(formatMedia3Audio('audio/eac3', 'ec-3'), 'E-AC3');
      expect(formatMedia3Audio('audio/ac3', 'ac-3'), 'AC-3');
    });

    test('falls back to codecs string', () {
      expect(formatMedia3Audio(null, 'dts'), 'DTS');
      expect(formatMedia3Audio(null, 'mlp'), 'TrueHD');
      expect(formatMedia3Audio(null, 'mp4a.40.2'), 'AAC');
    });

    test('unknown input', () {
      expect(formatMedia3Audio(null, null), 'Unknown');
      expect(formatMedia3Audio('audio/x-odd', 'zzz'), 'X-ODD');
    });
  });

  group('detectMedia3HdrFormat', () {
    test('detects Dolby Vision from codec prefix', () {
      expect(
        detectMedia3HdrFormat(colorTransfer: 6, videoCodecs: 'dvhe.08.06'),
        HdrFormat.dolbyVision,
      );
    });

    test('detects HDR10 from ST2084 transfer', () {
      expect(
        detectMedia3HdrFormat(colorTransfer: 6, videoCodecs: 'hvc1.2.4.L153'),
        HdrFormat.hdr10,
      );
    });

    test('detects HLG from HLG transfer', () {
      expect(
        detectMedia3HdrFormat(colorTransfer: 7, videoCodecs: 'hvc1.2.4.L153'),
        HdrFormat.hlg,
      );
    });

    test('defaults to SDR', () {
      expect(
        detectMedia3HdrFormat(colorTransfer: 3, videoCodecs: 'avc1.640028'),
        HdrFormat.sdr,
      );
    });
  });

  group('detectLiveHdrFormat', () {
    test('detects Dolby Vision from codec', () {
      expect(
        detectLiveHdrFormat(videoCodec: 'dvhe', gamma: 'smpte2084'),
        HdrFormat.dolbyVision,
      );
    });

    test('detects HDR10 from PQ gamma', () {
      expect(
        detectLiveHdrFormat(videoCodec: 'hevc', gamma: 'smpte2084'),
        HdrFormat.hdr10,
      );
    });

    test('detects HLG', () {
      expect(
        detectLiveHdrFormat(videoCodec: 'hevc', gamma: 'arib-std-b67'),
        HdrFormat.hlg,
      );
    });

    test('defaults to SDR', () {
      expect(
        detectLiveHdrFormat(videoCodec: 'h264', gamma: 'bt709'),
        HdrFormat.sdr,
      );
    });
  });

  group('channelsLabel', () {
    test('maps common counts to surround labels', () {
      expect(channelsLabel(1), 'Mono');
      expect(channelsLabel(2), '2.0');
      expect(channelsLabel(6), '5.1');
      expect(channelsLabel(8), '7.1');
    });

    test('falls back to N.0', () {
      expect(channelsLabel(4), '4.0');
    });

    test('issue #71: full SMPTE layouts instead of N.0 (Atmos JOC reports 16ch)', () {
      expect(channelsLabel(3), '2.1');
      expect(channelsLabel(5), '5.0');
      // 7 channels was shown as "7.0" - it is a 6.1 layout.
      expect(channelsLabel(7), '6.1');
      // E-AC3 JOC (Dolby Atmos) carries 16 channels in the frame - it is a
      // 7.1.4 object layout, not "16.0".
      expect(channelsLabel(16), '7.1.4');
    });

    test('unknown count', () {
      expect(channelsLabel(null), '?');
      expect(channelsLabel(0), '?');
    });
  });

  group('resolutionBadgeLabel', () {
    test('issue #71: short badge labels instead of pixel sizes', () {
      expect(resolutionBadgeLabel('8K'), '8K');
      expect(resolutionBadgeLabel('4K'), '4K');
      expect(resolutionBadgeLabel('2K'), 'QHD');
      expect(resolutionBadgeLabel('1080p'), 'FHD');
      expect(resolutionBadgeLabel('1080i'), 'FHD');
      expect(resolutionBadgeLabel('720p'), 'HD');
      expect(resolutionBadgeLabel('480p'), 'SD');
      expect(resolutionBadgeLabel('576p'), 'SD');
      expect(resolutionBadgeLabel('SD'), 'SD');
    });

    test('null/empty stays null, unknown labels pass through', () {
      expect(resolutionBadgeLabel(null), isNull);
      expect(resolutionBadgeLabel(''), isNull);
      expect(resolutionBadgeLabel('1440p'), '1440p');
    });
  });

  group('languageName', () {
    test('maps ISO codes to full English names', () {
      expect(languageName('eng'), 'English');
      expect(languageName('deu'), 'German');
      expect(languageName('fra'), 'French');
      expect(languageName('jpn'), 'Japanese');
    });

    test('handles 2-letter and case variations', () {
      expect(languageName('EN'), 'English');
      expect(languageName('hi'), 'Hindi');
    });

    test('falls back to the raw code', () {
      expect(languageName('zzz'), 'zzz');
      expect(languageName(null), '');
      expect(languageName(''), '');
    });
  });

  group('formatLiveAudioLabel', () {
    test('uses metadata profile when codec families match', () {
      expect(
        formatLiveAudioLabel(
          liveCodec: 'dts',
          liveChannels: 6,
          metaCodec: 'dts_hd',
          metaProfile: 'MA',
        ),
        'DTS-HD MA 5.1',
      );
    });

    test('keeps live codec when no metadata profile', () {
      expect(
        formatLiveAudioLabel(liveCodec: 'eac3', liveChannels: 6),
        'E-AC3 5.1',
      );
    });

    test('does not merge different codec families', () {
      expect(
        formatLiveAudioLabel(
          liveCodec: 'aac',
          liveChannels: 2,
          metaCodec: 'dts_hd',
          metaProfile: 'MA',
        ),
        'AAC 2.0',
      );
    });
  });
}
