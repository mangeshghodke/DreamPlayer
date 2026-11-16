import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/utils/upload_url.dart';

void main() {
  group('sanitizeUploadName', () {
    test('keeps a normal name unchanged', () {
      expect(sanitizeUploadName('Movie.mkv'), 'Movie.mkv');
    });

    test('strips directory components', () {
      expect(sanitizeUploadName('../../../etc/passwd'), 'passwd');
      expect(sanitizeUploadName('folder/sub/Movie.mkv'), 'Movie.mkv');
      expect(sanitizeUploadName('C:\\\\Users\\\\x\\\\Movie.mkv'), 'Movie.mkv');
    });

    test('removes control characters', () {
      expect(sanitizeUploadName('Mov\x00ie.mkv'), 'Movie.mkv');
      expect(sanitizeUploadName('Mov\x1Fie.mkv'), 'Movie.mkv');
    });

    test('rejects dot and dot-dot', () {
      expect(sanitizeUploadName('.'), 'upload.bin');
      expect(sanitizeUploadName('..'), 'upload.bin');
    });

    test('rejects empty after trimming', () {
      expect(sanitizeUploadName('   '), 'upload.bin');
      expect(sanitizeUploadName('\t\n'), 'upload.bin');
    });

    test('prefixes Windows-reserved base names', () {
      expect(sanitizeUploadName('CON.mkv'), '_CON.mkv');
      expect(sanitizeUploadName('NUL.txt'), '_NUL.txt');
      expect(sanitizeUploadName('COM1.mkv'), '_COM1.mkv');
      expect(sanitizeUploadName('LPT9.log'), '_LPT9.log');
      // Not reserved: a name merely containing the reserved string.
      expect(sanitizeUploadName('CONcerto.mkv'), 'CONcerto.mkv');
    });

    test('caps length keeping the extension', () {
      final long = 'a' * 200 + '.mkv';
      final result = sanitizeUploadName(long);
      expect(result.length, kUploadNameMaxLength);
      expect(result.endsWith('.mkv'), isTrue);
      expect(result.startsWith('a' * (kUploadNameMaxLength - 4)), isTrue);
    });

    test('drops a bizarre extension when capping', () {
      final long = 'a' * 200 + '.verylongextension';
      final result = sanitizeUploadName(long);
      expect(result.length, kUploadNameMaxLength);
      expect(result.endsWith('.verylongextension'), isFalse);
    });
  });

  group('dedupeUploadName', () {
    test('returns the name when unused', () {
      expect(dedupeUploadName('Movie.mkv', {}), 'Movie.mkv');
    });

    test('appends (2), (3) before the extension', () {
      expect(dedupeUploadName('Movie.mkv', {'Movie.mkv'}), 'Movie (2).mkv');
      expect(
          dedupeUploadName('Movie.mkv', {'Movie.mkv', 'Movie (2).mkv'}),
          'Movie (3).mkv');
    });

    test('works without an extension', () {
      expect(dedupeUploadName('README', {'README'}), 'README (2)');
    });

    test('falls back to a timestamp after 9999 attempts', () {
      final existing = <String>{
        'Movie.mkv',
        for (var i = 1; i <= 10000; i++) 'Movie ($i).mkv',
      };
      final result = dedupeUploadName('Movie.mkv', existing);
      expect(result.startsWith('Movie ('), isTrue);
      expect(result.endsWith('.mkv'), isTrue);
    });
  });

  group('buildUploadUrls', () {
    test('builds the short address for each LAN address', () {
      // The URL must stay typeable from a PC browser: ip, port, one short
      // fixed path - no token (user request).
      expect(buildUploadUrls(['192.168.1.10', '10.0.0.5'], 8080), [
        'http://192.168.1.10:8080/wifi-transfer/',
        'http://10.0.0.5:8080/wifi-transfer/',
      ]);
    });

    test('skips empty addresses', () {
      expect(buildUploadUrls(['192.168.1.10', ''], 8080),
          ['http://192.168.1.10:8080/wifi-transfer/']);
    });

    test('has no token in the path', () {
      for (final url in buildUploadUrls(['192.168.1.10'], 8080)) {
        expect(url.contains('/u/'), isFalse);
        expect(url.length, lessThan(45));
      }
    });
  });

  group('uploadEndpointPath', () {
    test('builds the raw-body POST path', () {
      expect(uploadEndpointPath('My Movie.mkv'),
          '/wifi-transfer/upload?name=My%20Movie.mkv');
    });
  });

  group('formatUploadBytes', () {
    test('formats B / KB / MB / GB', () {
      expect(formatUploadBytes(512), '512 B');
      expect(formatUploadBytes(2048), '2 KB');
      expect(formatUploadBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatUploadBytes(3 * 1024 * 1024 * 1024), '3.00 GB');
    });

    test('unknown size reports a question mark', () {
      expect(formatUploadBytes(-1), '?');
    });
  });
}
