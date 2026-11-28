import 'package:dream_player/utils/lrc_lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isSyncedLrc', () {
    test('detects timestamped lines', () {
      expect(isSyncedLrc('[00:12.50]hello'), isTrue);
      expect(isSyncedLrc('[ti:Song]\n[00:01.00]line'), isTrue);
    });
    test('metadata-only tags are not synced', () {
      expect(isSyncedLrc('[ti:Song]\n[ar:Artist]\n[offset:500]'), isFalse);
      expect(isSyncedLrc('just plain lyrics\nno tags'), isFalse);
      expect(isSyncedLrc(null), isFalse);
      expect(isSyncedLrc(''), isFalse);
    });
  });

  group('parseLrcLines', () {
    test('parses mm:ss.xx and mm:ss.xxx timestamps', () {
      final lines = parseLrcLines('[00:01.50]a\n[01:02.345]b');
      expect(lines.length, 2);
      expect(lines[0].timeMs, 1500);
      expect(lines[0].text, 'a');
      expect(lines[1].timeMs, 62345);
      expect(lines[1].text, 'b');
    });
    test('one line with several tags yields one entry per tag, sorted', () {
      final lines = parseLrcLines('[00:20.00][00:10.00]chorus');
      expect(lines.length, 2);
      expect(lines[0].timeMs, 10000);
      expect(lines[1].timeMs, 20000);
      expect(lines[0].text, 'chorus');
    });
    test('metadata tags produce no lines', () {
      final lines = parseLrcLines('[ti:Title]\n[ar:X]\n[00:05.00]real');
      expect(lines.length, 1);
      expect(lines[0].text, 'real');
    });
    test('fully unsynced lyrics become a single 0 ms line', () {
      final lines = parseLrcLines('line one\nline two');
      expect(lines.length, 1);
      expect(lines[0].timeMs, 0);
      expect(lines[0].text, contains('line one'));
    });
    test('empty input yields nothing', () {
      expect(parseLrcLines(null), isEmpty);
      expect(parseLrcLines('   '), isEmpty);
    });
  });

  group('lrcIndexAt', () {
    final lines = parseLrcLines('[00:01.00]a\n[00:05.00]b\n[00:09.00]c');
    test('picks the last line at or before the position', () {
      expect(lrcIndexAt(lines, 0), -1);
      expect(lrcIndexAt(lines, 1000), 0);
      expect(lrcIndexAt(lines, 4999), 0);
      expect(lrcIndexAt(lines, 5000), 1);
      expect(lrcIndexAt(lines, 999999), 2);
    });
  });
}
