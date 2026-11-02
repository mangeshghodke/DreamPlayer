import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/utils/playback_stats.dart';

const _screen = 'lib/screens/player_screen.dart';
const _native =
    'android/app/src/main/kotlin/com/dreamplayer/app/ExoPlayerView.kt';

void main() {
  group('formatters', () {
    test('formatBitrate renders kbps and Mbps', () {
      expect(formatBitrate(12500), '12.5 Mbps');
      expect(formatBitrate(820), '820 kbps');
      expect(formatBitrate(800), '800 kbps');
    });

    test('formatFps trims trailing zeros and keeps two decimals', () {
      expect(formatFps(23.976), '23.98');
      expect(formatFps(60), '60');
      expect(formatFps(29.97), '29.97');
      expect(formatFps(0), '');
      expect(formatFps(null), '');
    });

    test('resolutionLabel prefers the real dimensions', () {
      expect(PlaybackStats(width: 3840, height: 2160).resolutionLabel,
          '3840 x 2160');
      expect(PlaybackStats().resolutionLabel, '');
    });
  });

  group('RenderedFpsMeter', () {
    test('does not fire on the first sample', () {
      final m = RenderedFpsMeter();
      expect(m.fromCounters(1000, DateTime(2026)), null);
    });

    test('measures from the second sample on', () {
      final m = RenderedFpsMeter();
      m.fromCounters(100, DateTime(2026));
      expect(
        m.fromCounters(160, DateTime(2026).add(const Duration(seconds: 1))),
        closeTo(60, 1),
      );
    });

    test('re-arms when the counter shrinks (new decoder session)', () {
      final m = RenderedFpsMeter();
      m.fromCounters(100, DateTime(2026));
      expect(
        m.fromCounters(160, DateTime(2026).add(const Duration(seconds: 1))),
        closeTo(60, 1),
      );
      // A reopen resets the cumulative counter — the next sample must keep
      // the last good reading, never compute a huge negative fps.
      expect(
        m.fromCounters(5, DateTime(2026).add(const Duration(seconds: 2))),
        closeTo(60, 1),
      );
      m.fromCounters(65, DateTime(2026).add(const Duration(seconds: 3)));
      expect(
        m.fromCounters(125, DateTime(2026).add(const Duration(seconds: 4))),
        closeTo(60, 1),
      );
    });
  });

  group('statsFromMpvProperties', () {
    test('parses the raw property strings', () {
      final s = statsFromMpvProperties(
        containerFps: '23.976000',
        estimatedVfFps: '60.000000',
        videoBitrate: '12500',
        audioBitrate: '640',
        frameDropCount: '3',
        decoderFrameDropCount: '0',
        width: 3840,
        height: 2160,
        speed: 1.0,
        durationMs: 60000,
        positionMs: 5000,
        labels: {'video': 'HEVC', 'audio': 'DTS-HD MA', 'decoder': 'software'},
      );
      expect(s.sourceFps, closeTo(23.976, 0.01));
      expect(s.renderedFps, 60.0);
      expect(s.videoBitrateKbps, 12500);
      expect(s.audioBitrateKbps, 640);
      expect(s.droppedFrames, 3);
      expect(s.videoCodec, 'HEVC');
      expect(s.audioLabel, 'DTS-HD MA');
      expect(s.decoderLine, 'software');
      expect(s.width, 3840);
      expect(s.positionMs, 5000);
    });

    test('nothing readable parses to an empty snapshot', () {
      final s = statsFromMpvProperties();
      expect(s.isEmpty, isTrue);
      expect(s.toLines(), isEmpty);
    });

    test('lines omit empty labels but keep real ones', () {
      final s = statsFromMpvProperties(containerFps: '24', labels: const {});
      final lines = s.toLines();
      expect(lines, containsPair('Source fps', '24'));
      expect(lines.containsKey('Video'), isFalse);
    });  });

  group('statsFromGetStatsMap', () {
    test('converts bits/second to kbps and keeps counters raw', () {
      final s = statsFromGetStatsMap(
        {
          'videoWidth': 3840,
          'videoHeight': 2160,
          'videoFps': 23.976,
          'videoBitrate': 12000000,
          'audioBitrate': 640000,
          'renderedOutputBufferCount': 4000,
          'droppedBufferCount': 2,
          'playbackSpeed': 1.5,
          'positionMs': 12000,
          'durationMs': 600000,
        },
        labels: {
          'video': 'HEVC',
          'audio': 'E-AC3 (JOC) · 5.1 · English',
          'decoder': 'c2.qti.hevc.decoder · hardware',
        },
      );
      expect(s.width, 3840);
      expect(s.sourceFps, closeTo(23.976, 0.01));
      expect(s.videoBitrateKbps, 12000.0);
      expect(s.audioBitrateKbps, 640.0);
      expect(s.droppedFrames, 2);
      expect(s.speed, 1.5);
      expect(s.decoderLine, contains('hardware'));
    });

    test('swallows stringly-typed values too', () {
      final s = statsFromGetStatsMap({
        'videoWidth': '3840',
        'droppedBufferCount': '7',
      });
      expect(s.width, 3840);
      expect(s.droppedFrames, 7);
    });
  });

  test('PlaybackStats.toLines renders a full snapshot', () {
    final s = statsFromMpvProperties(
      containerFps: '23.976',
      estimatedVfFps: '60',
      videoBitrate: '12500',
      audioBitrate: '640',
      frameDropCount: '2',
      width: 3840,
      height: 2160,
      speed: 1.0,
      durationMs: 605000,
      positionMs: 5000,
      labels: {
        'video': 'HEVC',
        'audio': 'DTS-HD MA · 5.1',
        'decoder': 'software',
      },
    );
    final lines = s.toLines();
    expect(lines['Resolution'], '3840 x 2160');
    expect(lines['Video'], 'HEVC');
    expect(lines['Audio'], 'DTS-HD MA · 5.1');
    expect(lines['Decoder'], 'software');
    expect(lines['Source fps'], '23.98');
    expect(lines['Rendered fps'], '60');
    expect(lines['Video bitrate'], '12.5 Mbps');
    expect(lines['Audio bitrate'], '640 kbps');
    expect(lines['Dropped frames'], '2');
    expect(lines['Speed'], '1.0x');
    expect(lines['Position'], '0:05 / 10:05');
  });

  group('HUD wiring (source-reading pins)', () {
    // The player screen needs a live platform view, so it cannot be pumped
    // as a widget — pin the wiring from the sources instead.
    late String screenSrc;
    late String nativeSrc;

    setUp(() {
      screenSrc = File(_screen).readAsStringSync();
      nativeSrc = File(_native).readAsStringSync();
    });

    test('the ⋮ sheet localizes the toggle and pops before applying', () {
      expect(screenSrc, contains('.playerPlaybackStats'));
      final rowI = screenSrc.indexOf(
        '_tvListTile(\n                      leading: const Icon(Icons.show_chart,',
      );
      expect(rowI, greaterThan(0));
    });

    test('polling is skipped while in pip and stops when hidden', () {
      expect(screenSrc, contains('_inPip) return;'));
      expect(screenSrc, contains('_statsTimer?.cancel();'));
    });

    test('opening a video drops the previous file snapshot', () {
      final snapshotI = screenSrc.indexOf('_statsSnapshot = null;');
      final tokenI = screenSrc.indexOf('_mpvChapterProbeToken++');
      expect(snapshotI, greaterThan(0));
      expect(tokenI, greaterThan(snapshotI));
    });

    test('rendered fps is derived from cumulative counters on Media3', () {
      expect(screenSrc, contains('_exoStatsFpsMeter.fromCounters'));
      expect(nativeSrc, contains('"getStats"'));
      expect(nativeSrc, contains('renderedOutputBufferCount'));
      expect(nativeSrc, contains('droppedBufferCount'));
    });

    test('the HUD overlay is IgnorePointer-wrapped and pip-gated', () {
      expect(screenSrc, contains('PlaybackStatsHud(stats: _statsSnapshot)'));
      expect(
        screenSrc,
        contains('if (_statsHudVisible && !_inPip)\n              Positioned('),
      );
    });
  });
}
